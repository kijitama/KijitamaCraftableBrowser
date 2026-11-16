function ConvertTo-AiChatLink([string]$Name,[string]$Url,[string]$Id) {
    $name=$Name.Trim();$url=$Url.Trim()
    if(!$name -or $name.Length -gt $config.quickLink.maxNameLength){throw ('表示名は1～'+$config.quickLink.maxNameLength+'文字で入力してください。')}
    $uri=$null
    if($url.Length -gt $config.quickLink.maxUrlLength -or ![Uri]::TryCreate($url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or !$uri.Host -or $uri.UserInfo){throw 'URLはユーザー名・パスワードを含まないhttps://から始まるアドレスを入力してください。'}
    if(!$Id){$Id=[guid]::NewGuid().ToString('N')}
    [pscustomobject]@{id=$Id;name=$name;url=$uri.AbsoluteUri}
}
function Save-AiChatLinks([object[]]$Links) {
    if($Links.Count -gt $config.quickLink.maxEntries -and $Links.Count -gt @($config.quickLink.links).Count){throw ('登録できるリンクは'+$config.quickLink.maxEntries+'件までです。')}
    $clean=@(foreach($link in $Links){ConvertTo-AiChatLink $link.name $link.url $link.id})
    if(@($clean.id|Select-Object -Unique).Count -ne $clean.Count){throw 'リンクの識別子が重複しています。'}
    $path=Join-Path $appRoot 'Config/system.json'
    $latest=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
    $latest.quickLink.links=$clean
    Save-JsonFile $latest $path
    $config.quickLink.links=$clean
    Refresh-AiChatLinks
}
function Clear-AiChatEditor {
    $script:editingAiChatId=$null
    $ui.AiChatName.Clear();$ui.AiChatUrl.Clear()
    $ui.SaveAiChatLink.Content='追加'
    $ui.CancelAiChatEdit.Visibility='Collapsed'
}
function Save-AiChatEditor {
    $item=ConvertTo-AiChatLink $ui.AiChatName.Text $ui.AiChatUrl.Text $script:editingAiChatId
    $links=@($config.quickLink.links)
    if($script:editingAiChatId){
        if($editingAiChatId -notin $links.id){throw '編集中のリンクがありません。追加し直してください。'}
        $links=@(foreach($link in $links){if($link.id -eq $editingAiChatId){$item}else{$link}})
    }else{$links+=@($item)}
    Save-AiChatLinks $links
    Clear-AiChatEditor
    $ui.SettingsStatus.Text='クイックリンクを保存しました。'
}
function Invoke-AiChatRowAction([string]$Id,[string]$Action) {
    $links=@($config.quickLink.links);$index=-1
    for($i=0;$i -lt $links.Count;$i++){if($links[$i].id -eq $Id){$index=$i;break}}
    if($index -lt 0){return}
    switch($Action){
        edit {$script:editingAiChatId=$Id;$ui.AiChatName.Text=$links[$index].name;$ui.AiChatUrl.Text=$links[$index].url;$ui.SaveAiChatLink.Content='変更を保存';$ui.CancelAiChatEdit.Visibility='Visible';[void]$ui.AiChatName.Focus();return}
        delete {$links=@($links|Where-Object id -NE $Id)}
        up {if($index -eq 0){return};$links[$index-1],$links[$index]=$links[$index],$links[$index-1]}
        down {if($index -eq $links.Count-1){return};$links[$index+1],$links[$index]=$links[$index],$links[$index+1]}
        default {return}
    }
    Save-AiChatLinks $links
    if($Action -eq 'delete' -and $editingAiChatId -eq $Id){Clear-AiChatEditor}
    $ui.SettingsStatus.Text='クイックリンクを更新しました。'
}
function Refresh-AiChatLinks {
    $links=@($config.quickLink.links)
    $ui.AiChatLinks.ItemsSource=$links
    $ui.QuickLinkCount.Text="登録 $($links.Count)件 / 上限 $($config.quickLink.maxEntries)件"
    $ui.AiChatEmpty.Visibility=if($links.Count){'Collapsed'}else{'Visible'}
    $menu=[Windows.Controls.ContextMenu]::new()
    foreach($link in $links){
        $item=[Windows.Controls.MenuItem]::new()
        $label=[Windows.Controls.TextBlock]::new();$label.Text=$link.name
        $item.Header=$label;$item.ToolTip=$link.url;$item.CommandParameter=$link.id
        $item.add_Click({param($sender,$eventArgs) Invoke-UiAction {
            $link=@($config.quickLink.links|Where-Object id -EQ $sender.CommandParameter)[0]
            if($link){$checked=ConvertTo-AiChatLink $link.name $link.url $link.id;New-BrowserTab $checked.url}
        }})
        [void]$menu.Items.Add($item)
    }
    if($links.Count){[void]$menu.Items.Add([Windows.Controls.Separator]::new())}
    $settings=[Windows.Controls.MenuItem]::new();$settings.Header='リンクを設定…'
    $settings.add_Click({Show-SettingsScreen $true;$ui.AiChatSettingsGroup.BringIntoView();[void]$ui.AiChatName.Focus()})
    [void]$menu.Items.Add($settings)
    $menu.PlacementTarget=$ui.AiChatMenu;$menu.Placement='Bottom'
    $ui.AiChatMenu.ContextMenu=$menu
}
function Initialize-AiChatLinks {
    foreach($name in @('AiChatMenu','AiChatSettingsGroup','AiChatName','AiChatUrl','SaveAiChatLink','CancelAiChatEdit','AiChatLinks','AiChatEmpty','QuickLinkMenuLabel','SaveQuickLinkLabel','QuickLinkCount')){$ui[$name]=$window.FindName($name)}
    $ui.QuickLinkMenuLabel.Text=$config.quickLink.menuLabel
    Update-QuickLinkLabel
    $ui.SaveQuickLinkLabel.add_Click({Invoke-SettingsAction {Save-QuickLinkLabel $ui.QuickLinkMenuLabel.Text}})
    $ui.AiChatMenu.add_Click({$ui.AiChatMenu.ContextMenu.IsOpen=$true})
    $ui.SaveAiChatLink.add_Click({Invoke-SettingsAction {Save-AiChatEditor}})
    $ui.CancelAiChatEdit.add_Click({Clear-AiChatEditor})
    $ui.AiChatLinks.AddHandler([Windows.Controls.Button]::ClickEvent,[Windows.RoutedEventHandler]{param($sender,$eventArgs)
        $button=$eventArgs.OriginalSource
        if($button -is [Windows.Controls.Button] -and $button.DataContext.id){$eventArgs.Handled=$true;Invoke-SettingsAction {Invoke-AiChatRowAction $button.DataContext.id ([string]$button.CommandParameter)}}
    })
    Clear-AiChatEditor
    Refresh-AiChatLinks
}


function Update-QuickLinkLabel {
    $text=[string]$config.quickLink.menuLabel
    if([string]::IsNullOrWhiteSpace($text)){$text=$config.quickLink.defaultMenuLabel}
    $ui.AiChatMenu.Content=$text+' ▾'
    $ui.AiChatMenu.ToolTip=$text+'：登録したサイトを新しいタブで開く'
    [Windows.Automation.AutomationProperties]::SetName($ui.AiChatMenu,$text)
}
function Save-QuickLinkLabel([string]$Label) {
    $label=$Label.Trim()
    if($label.Length -gt $config.quickLink.maxMenuLabelLength){throw ('メニューの表示名は空欄、または1～'+$config.quickLink.maxMenuLabelLength+'文字で入力してください。')}
    $path=Join-Path $appRoot 'Config/system.json'
    $latest=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
    $latest.quickLink.menuLabel=$label
    Save-JsonFile $latest $path
    $config.quickLink.menuLabel=$label
    $ui.QuickLinkMenuLabel.Text=$label
    Update-QuickLinkLabel
    $ui.SettingsStatus.Text='メニューボタンの表示名を保存しました。'
}



function Update-ProfileDeleteAvailability {
    $item=$ui.SettingsProfiles.SelectedItem
    $ui.SettingsDeleteProfile.IsEnabled=($null -ne $item -and !(Test-DefaultProfile $item.id) -and !$script:pdfTask -and !$script:imageTask)
    $ui.SettingsDeleteProfile.ToolTip=if ($item -and (Test-DefaultProfile $item.id)) { 'デフォルトのプロフィールは削除できません。' } else { '選択したプロフィールを削除します。' }
}
function Invoke-UiAction([scriptblock]$Action) {
    try { & $Action } catch { Show-ActionToast ('処理できませんでした：'+$_.Exception.Message) }
}
function Start-PdfExport {
    if ($script:pdfTask) { return }
    if (!$script:browser -or !$browser.CoreWebView2) { throw 'ページの表示後にPDF保存を押してください。' }
    $dir=Resolve-AppPath $config.pdf.outputDirectory
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $title=$browser.CoreWebView2.DocumentTitle -replace '[\x00-\x1f<>:"/\\|?*]','_'
    if (!$title) { $title='page' }
    $script:pdfPath=Join-Path $dir (New-ExportFileName $title '.pdf')
    $script:pdfTask=$browser.CoreWebView2.PrintToPdfAsync($pdfPath,$null)
    $ui.SavePdf.IsEnabled=$false
    foreach ($name in @('Profiles','AddProfile','SettingsDeleteProfile')) { $ui[$name].IsEnabled=$false }
    Show-ActionToast 'PDFを保存しています…'
}
function Update-PdfExport {
    if (!$script:pdfTask -or !$pdfTask.IsCompleted) { return }
    try {
        if (!$pdfTask.GetAwaiter().GetResult()) { throw 'PDFを書き込めませんでした。保存先を確認してください。' }
        Show-ActionToast ('PDFを保存しました：'+[IO.Path]::GetFileName($pdfPath))
        Show-ListActionFeedback 'ShowPdfs'
    } catch { Show-ActionToast ('PDF保存に失敗しました：'+$_.Exception.Message) }
    $script:pdfTask=$null
    Refresh-PdfList
    $ui.SavePdf.IsEnabled=$true
    foreach ($name in @('Profiles','AddProfile')) { $ui[$name].IsEnabled=$true }
    Update-ProfileDeleteAvailability
}
function Refresh-ImageList { Refresh-SavedFileList Image }
function Refresh-PdfList { Refresh-SavedFileList Pdf }
function Show-LeftList([bool]$Pdf) {
    $ui.DownloadListPanel.Visibility='Collapsed'; $ui.ShowDownloads.FontWeight='Normal'
    $ui.ImageListPanel.Visibility='Collapsed'; $ui.ShowImages.FontWeight='Normal'
    $ui.FavoritesPanel.Visibility='Collapsed'
    $ui.ShowLikes.FontWeight='Normal'
    $ui.HistoryPanel.Visibility=if ($Pdf) { 'Collapsed' } else { 'Visible' }
    $ui.PdfListPanel.Visibility=if ($Pdf) { 'Visible' } else { 'Collapsed' }
    $ui.ShowHistory.FontWeight=if ($Pdf) { 'Normal' } else { 'Bold' }
    $ui.ShowPdfs.FontWeight=if ($Pdf) { 'Bold' } else { 'Normal' }
    $script:historyCollapsed=$false
    Set-HistoryPanel; Save-AppPreferences
    if ($Pdf) { Refresh-PdfList }
}
function Show-LikesList {
    $ui.DownloadListPanel.Visibility='Collapsed'; $ui.ShowDownloads.FontWeight='Normal'
    $ui.ImageListPanel.Visibility='Collapsed'; $ui.ShowImages.FontWeight='Normal'
    $ui.HistoryPanel.Visibility='Collapsed'; $ui.PdfListPanel.Visibility='Collapsed'; $ui.FavoritesPanel.Visibility='Visible'
    $ui.ShowLikes.FontWeight='Bold'; $ui.ShowHistory.FontWeight='Normal'; $ui.ShowPdfs.FontWeight='Normal'
    $script:historyCollapsed=$false; Set-HistoryPanel; Save-AppPreferences; Refresh-Favorites
}
function Refresh-History {
    $keyword=$ui.HistorySearch.Text.Trim()
    $filtered=@($script:historyItems | Where-Object {
        !$keyword -or ([string]$_.title).IndexOf($keyword,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or ([string]$_.url).IndexOf($keyword,[StringComparison]::OrdinalIgnoreCase) -ge 0
    })
    $ui.History.ItemsSource=$null
    $filtered=@(Sort-SidebarItems $filtered History visitedAt)
    $ui.History.ItemsSource=$filtered
    $ui.HistorySearchStatus.Text="$($filtered.Count)件（全$(@($script:historyItems).Count)件）"
}
function Refresh-Favorites {
    Update-FavoriteIndicator
    $query=$ui.FavoriteSearch.Text.Trim()
    $visible=@($script:favoriteItems|Where-Object { !$query -or ([string]$_.title).IndexOf($query,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or ([string]$_.url).IndexOf($query,[StringComparison]::OrdinalIgnoreCase) -ge 0 })
    $visible=@(Sort-SidebarItems $visible Favorite addedAt)
    $ui.Favorites.ItemsSource=$null; $ui.Favorites.ItemsSource=$visible
    $ui.FavoriteCount.Text="$($visible.Count)件（全$(@($script:favoriteItems).Count)件）"
}
function Set-HistoryPanel {
    if ($script:historyCollapsed) { $ui.LeftPanel.Visibility='Collapsed'; $ui.HistoryColumn.Width=[Windows.GridLength]::new(0); $ui.ToggleHistory.Content='開く'; $ui.ToggleHistory.Tag=Get-LucideImage 'arrow-right'; $ui.ToggleHistory.ToolTip='左の一覧を開く' }
    else { $ui.LeftPanel.Visibility='Visible'; $ui.HistoryColumn.Width=[Windows.GridLength]::new($config.ui.historyWidth); $ui.ToggleHistory.Content='閉じる'; $ui.ToggleHistory.Tag=Get-LucideImage 'arrow-left'; $ui.ToggleHistory.ToolTip='左の一覧を閉じる' }
    [Windows.Automation.AutomationProperties]::SetName($ui.ToggleHistory,[string]$ui.ToggleHistory.ToolTip)
}
function Show-SettingsScreen([bool]$Show) {
    if ($Show) { Refresh-SettingsProfiles $profiles.activeId; $ui.SettingsStatus.Text=''; $ui.BrowserScreen.Visibility='Collapsed'; $ui.SettingsScreen.Visibility='Visible' }
    else { $ui.SettingsScreen.Visibility='Collapsed'; $ui.BrowserScreen.Visibility='Visible' }
}
function Refresh-SettingsProfiles([string]$SelectedId) {
    $ui.SettingsProfiles.ItemsSource=@($profiles.items)
    $ui.SettingsProfiles.SelectedItem=@($profiles.items | Where-Object id -eq $SelectedId)[0]
}
function Sync-ProfileSelector {
    $ui.Profiles.ItemsSource=@($profiles.items)
    $ui.Profiles.SelectedItem=@($profiles.items | Where-Object id -eq $profiles.activeId)[0]
}
function Invoke-SettingsAction([scriptblock]$Action) {
    try { & $Action } catch { $ui.SettingsStatus.Text='処理できませんでした: '+$_.Exception.Message }
}
function Start-CraftableBrowser {
    Initialize-Store
    Initialize-BrowserAssemblies
    $script:window = [Windows.Markup.XamlReader]::Parse((Get-Content "$appRoot/View/MainWindow.xaml" -Raw))
    $script:ui = @{}
    foreach ($name in @('Profiles','ProfileName','AddProfile','Back','Forward','Reload','Home','Go','Address','Status','SideColumn','BrowserPanel')) { $ui[$name]=$window.FindName($name) }
    Initialize-ActionToast
    Initialize-WebDownloads
    Initialize-BrowserTabs
    $window.Icon=[Windows.Media.Imaging.BitmapFrame]::Create([uri](Resolve-AppPath $config.ui.iconPath))
    $window.Title=$config.ui.title; $window.Width=$config.ui.width; $window.Height=$config.ui.height
    foreach ($name in @('History','HistorySearch','HistorySearchStatus','HistoryColumn')) { $ui[$name]=$window.FindName($name) }
    $ui.HistorySearch.add_TextChanged({ Refresh-History })
    foreach ($name in @('HistoryPanel','ToggleHistory','BrowserScreen','SettingsScreen','OpenSettings','CloseSettings')) { $ui[$name]=$window.FindName($name) }
    $script:historyCollapsed=[bool]$config.ui.historyCollapsed
    $ui.ToggleHistory.add_Click({ Invoke-UiAction { $script:historyCollapsed=!$script:historyCollapsed; Set-HistoryPanel; Save-AppPreferences } })
    foreach($name in @('SettingsViewport','SettingsLayout','SettingsGeneralColumn','SettingsAiColumn')){$ui[$name]=$window.FindName($name)}
    $ui.SettingsViewport.add_SizeChanged({ Update-SettingsLayout })
    $ui.SettingsScreen.add_IsVisibleChanged({ Update-SettingsLayout })
    $ui.OpenSettings.add_Click({ Show-SettingsScreen $true })
    $ui.CloseSettings.add_Click({ Show-SettingsScreen $false })
    $ui.HomeUrl=$window.FindName('HomeUrl'); $ui.SaveHomeUrl=$window.FindName('SaveHomeUrl')
    $ui.HomeUrl.Text=$config.browser.homeUrl
    $ui.SaveHomeUrl.add_Click({ Invoke-SettingsAction {
        Save-HomeUrl $ui.HomeUrl.Text
        $ui.HomeUrl.Text=$config.browser.homeUrl
        $ui.SettingsStatus.Text='ホームURLを保存しました。homeボタンから開けます。'
    } })
    foreach ($name in @('LeftPanel','PdfListPanel','PdfSearch','RefreshPdfs','PdfListStatus','PdfFiles','ShowHistory','ShowPdfs','ShowLikes')) { $ui[$name]=$window.FindName($name) }
    Initialize-ImageCapture
    Initialize-ListDeletion
    $ui.ShowLikes.add_Click({ Invoke-UiAction { Show-LikesList } })
    $ui.ShowHistory.FontWeight='Bold'
    $ui.ShowHistory.add_Click({ Invoke-UiAction { Show-LeftList $false } })
    $ui.ShowPdfs.add_Click({ Invoke-UiAction { Show-LeftList $true } })
    $ui.PdfSearch.add_TextChanged({ Refresh-PdfList })
    $ui.RefreshPdfs.add_Click({ Refresh-PdfList })
    $ui.PdfFiles.AddHandler([Windows.Controls.Button]::ClickEvent,[Windows.RoutedEventHandler]{ param($s,$e)
        $item=$e.OriginalSource.DataContext
        if ($item.path) { Invoke-UiAction {
            if (!(Test-Path -LiteralPath $item.path -PathType Leaf) -or [IO.Path]::GetExtension($item.path) -ne '.pdf') { Refresh-PdfList; throw 'PDFが見つかりません。' }
            $info=[Diagnostics.ProcessStartInfo]::new(); $info.FileName=$item.path; $info.UseShellExecute=$true
            [void][Diagnostics.Process]::Start($info)
        } }
    })
    foreach ($name in @('OpenLicense','CloseLicense','LicenseScreen','LicenseText')) { $ui[$name]=$window.FindName($name) }
    $ui.OpenLicense.add_Click({ Invoke-UiAction {
        $ui.LicenseText.Text=Get-AppLicenseText
        $ui.LicenseText.ScrollToHome()
        $ui.BrowserScreen.Visibility='Collapsed'; $ui.LicenseScreen.Visibility='Visible'
    } })
    $ui.CloseLicense.add_Click({ $ui.LicenseScreen.Visibility='Collapsed'; $ui.BrowserScreen.Visibility='Visible' })
    foreach ($name in @('FavoritesPanel','Favorites','FavoriteSearch','FavoriteCount','AddFavorite','FavoriteLimit','SaveFavoriteLimit')) { $ui[$name]=$window.FindName($name) }
    $ui.FavoriteLimit.Text=[string]$config.favorites.maxEntries
    $ui.FavoriteSearch.add_TextChanged({ Refresh-Favorites })
    $ui.AddFavorite.add_Click({ Invoke-UiAction {
        if (!$browser.CoreWebView2) { throw 'ページ表示後に登録してください。' }
        $added=Add-Favorite $browser.CoreWebView2.Source $browser.CoreWebView2.DocumentTitle
        Refresh-Favorites
        if($added){Show-ListActionFeedback 'ShowLikes'}
        Show-ActionToast $(if ($added) { 'スキに登録しました。' } else { 'このURLは登録済みです。' })
    } })
    $ui.Favorites.AddHandler([Windows.Controls.Button]::ClickEvent,[Windows.RoutedEventHandler]{param($s,$e) if ($e.OriginalSource.DataContext.url) { Invoke-UiAction { Navigate-Browser $e.OriginalSource.DataContext.url } }})
    $ui.Favorites.add_PreviewMouseRightButtonDown({param($s,$e)
        $container=[Windows.Controls.ItemsControl]::ContainerFromElement($s,$e.OriginalSource)
        if ($container -is [Windows.Controls.ListBoxItem]) { $container.IsSelected=$true }
        else { $s.SelectedIndex=-1 }
    })
    $ui.Favorites.ContextMenu.Items[0].add_Click({ Invoke-UiAction {
        $item=$ui.Favorites.SelectedItem
        if ($item) { Remove-Favorite $item.id; Refresh-Favorites; Show-ActionToast 'スキから削除しました。' }
    } })
    $window.FindName('FavoriteLimitHelp').Text="プロフィールごとの登録上限（$($config.favorites.limitRange.minimum)～$($config.favorites.limitRange.maximum)件）"
    $ui.SaveFavoriteLimit.add_Click({ Invoke-SettingsAction {
        $limit=0
        if (![int]::TryParse($ui.FavoriteLimit.Text,[ref]$limit) -or $limit -lt $config.favorites.limitRange.minimum -or $limit -gt $config.favorites.limitRange.maximum) { throw "上限は$($config.favorites.limitRange.minimum)～$($config.favorites.limitRange.maximum)の整数で指定してください。" }
        $config.favorites.maxEntries=$limit; Save-AppPreferences; Refresh-Favorites
        $ui.SettingsStatus.Text='スキの上限を保存しました。既存の登録は保持します。'
    } })
    $ui.SkipExitConfirmation=$window.FindName('SkipExitConfirmation')
    $ui.SkipExitConfirmation.IsChecked=[bool]$config.ui.skipExitConfirmation
    $ui.SkipExitConfirmation.add_Click({
        try {
            Save-ExitConfirmationPreference ([bool]$ui.SkipExitConfirmation.IsChecked)
            $ui.SettingsStatus.Text='ブラウザ終了時の確認設定を保存しました。'
        } catch {
            $ui.SkipExitConfirmation.IsChecked=[bool]$config.ui.skipExitConfirmation
            $ui.SettingsStatus.Text='保存できませんでした: '+$_.Exception.Message
        }
    })
    $ui.FactoryReset=$window.FindName('FactoryReset')
    $ui.ResetSettingsGroup=$window.FindName('ResetSettingsGroup')
    $ui.ResetSettingsGroup.Visibility=if($script:showResetSettings){'Visible'}else{'Collapsed'}
    $ui.ResetComplete=$window.FindName('ResetComplete')
    $ui.ResetPristine=$window.FindName('ResetPristine')
    $ui.FactoryReset.add_Click({ Invoke-SettingsAction {
        if(!$script:showResetSettings){throw '初期化する場合は、SHIFTキーを押しながらアプリを起動してください。'}
        if ($script:imageTask -or $script:pdfTask -or $script:summaryStage -or $script:codexProcess) { throw 'PDF保存・AI処理・接続確認の終了後に実行してください。' }
        $root=Split-Path $appRoot -Parent
        $mode=if($ui.ResetPristine.IsChecked){'pristine'}elseif($ui.ResetComplete.IsChecked){'complete'}else{'keepFiles'}
        $null=@(Get-ResetTargets $root $config $mode)
        $message=if($mode -eq 'pristine'){'完全初期化を実行します。全利用データ・PDF・画像・ログ・検証データ・取得済み部品・Releases内の過去の配布物を削除し、起動前の初期状態に戻します。次回起動には部品の再取得が必要です。アプリ本体・アクセス権・PCのCodexログインは保持します。削除は元に戻せません。'}elseif($mode -eq 'complete'){'すべてのデータを削除します。全プロフィール・ログイン情報・履歴・スキ・AIデータ、標準保存先のPDF・画像、ログ・検証データを削除し、設定を初期値に戻します。保存ファイルも失われ、元に戻せません。アプリ本体・PCのCodexログイン・アプリ外のコピーは対象外です。'}else{'全プロフィール・ログイン情報・履歴・スキ・AIデータを削除し、設定を初期値に戻します。PDF・画像は残します。保存先の設定は初期値に戻ります。元に戻せません。'}
        $message+=' アプリを終了して実行します。他の起動中の本アプリを閉じてください。実行しますか？' 
        if ([Windows.MessageBox]::Show($window,$message,'アプリを初期化','YesNo','Warning') -ne 'Yes') { return }
        $worker=Join-Path $appRoot 'Services/ResetWorker.ps1'
        [Windows.Clipboard]::Clear()
        Start-Process (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-STA','-File',('"'+$worker+'"'),'-ParentProcessId',[string]$PID,'-Mode',$mode) -WindowStyle Hidden -ErrorAction Stop
        $script:resetRequested=$true
        $window.Close()
    } })
    Initialize-PageAnalysis
    foreach($name in @('AiBlockedDomains','AiBlockSubdomains','SaveAiBlockedDomains')){$ui[$name]=$window.FindName($name)}
    $ui.AiBlockedDomains.Text=@($config.ai.blockedDomains) -join "`r`n"
    $ui.AiBlockSubdomains.IsChecked=Get-AiBlockSubdomains
    $ui.SaveAiBlockedDomains.add_Click({ Invoke-SettingsAction {
        Save-AiBlockedDomains $ui.AiBlockedDomains.Text ([bool]$ui.AiBlockSubdomains.IsChecked)
        if($script:summaryStage){Stop-PageSummary '送信禁止設定を変更したため処理を中止しました。'}
        Update-PageAnalysisAvailability
        $ui.AiBlockedDomains.Text=@($config.ai.blockedDomains) -join "`r`n"
        $ui.SettingsStatus.Text='AI送信禁止ドメインを保存しました。要約に適用します。'
    } })
    foreach ($name in @('SavePdf','PdfDirectory','SavePdfDirectory','BrowsePdfDirectory')) { $ui[$name]=$window.FindName($name) }
    $ui.PdfDirectory.Text=$config.pdf.outputDirectory
    $ui.BrowsePdfDirectory.add_Click({ Invoke-SettingsAction {
        $dialog=[Microsoft.Win32.OpenFolderDialog]::new()
        $dialog.Title='PDFの保存先フォルダーを選択'
        $dialog.Multiselect=$false
        $current=Resolve-AppPath $config.pdf.outputDirectory
        if (Test-Path -LiteralPath $current -PathType Container) { $dialog.InitialDirectory=$current }
        if ($dialog.ShowDialog($window)) {
            $previous=$config.pdf.outputDirectory
            try {
                $config.pdf.outputDirectory=$dialog.FolderName
                Save-AppPreferences
            } catch { $config.pdf.outputDirectory=$previous; throw }
            $ui.PdfDirectory.Text=$config.pdf.outputDirectory
            Refresh-PdfList; $ui.SettingsStatus.Text='PDF出力先を保存しました: '+$config.pdf.outputDirectory
        }
    } })
    $ui.SavePdf.add_Click({ Invoke-UiAction { Start-PdfExport } })
    $ui.SavePdfDirectory.add_Click({ Invoke-SettingsAction {
        $value=$ui.PdfDirectory.Text.Trim()
        if (!$value) { throw '保存先フォルダーを入力してください。' }
        $dir=Resolve-AppPath $value
        [IO.Directory]::CreateDirectory($dir) | Out-Null
        $config.pdf.outputDirectory=$value
        Save-AppPreferences
        Refresh-PdfList; $ui.SettingsStatus.Text='PDF出力先を保存しました: '+$dir
    } })
    foreach ($name in @('CodexPath','DetectCodex','BrowseCodex','SaveCodex','CheckCodex','CodexProgress','CodexStatus')) { $ui[$name]=$window.FindName($name) }
    Initialize-AiUsage
    foreach($name in @('SummaryCharacterLimit','SaveAiCharacterLimits','AiCharacterLimitHelp')){$ui[$name]=$window.FindName($name)}
    $ui.SummaryCharacterLimit.Text=[string]$config.ai.summary.maxCharacters
    $ui.AiCharacterLimitHelp.Text="設定範囲：$($config.ai.characterLimitRange.minimum)～$($config.ai.characterLimitRange.maximum)文字。"
    $ui.SaveAiCharacterLimits.add_Click({Invoke-SettingsAction {
        Save-AiCharacterLimits $ui.SummaryCharacterLimit.Text
        $ui.SummaryCharacterLimit.Text=[string]$config.ai.summary.maxCharacters
        $ui.SettingsStatus.Text='文字数上限を保存しました。次の要約から反映されます。'
    }})
    $ui.CodexPath.Text=$config.codexCli.path
    $ui.DetectCodex.add_Click({ Invoke-SettingsAction { $ui.CodexPath.Text=Find-CodexCli; $ui.CodexStatus.Text='検出しました。「接続確認」を押してください。' } })
    $ui.BrowseCodex.add_Click({
        $dialog=[Microsoft.Win32.OpenFileDialog]::new(); $dialog.Filter='Codex CLI (codex.exe)|codex.exe'; $dialog.CheckFileExists=$true
        if ($dialog.ShowDialog($window)) { $ui.CodexPath.Text=$dialog.FileName }
    })
    $ui.SaveCodex.add_Click({ Invoke-SettingsAction { $config.codexCli.path=$ui.CodexPath.Text.Trim(); Save-AppPreferences; $ui.CodexStatus.Text='パスを保存しました（未確認）。' } })
    $ui.CheckCodex.add_Click({ try { Start-CodexCheck } catch { $ui.CodexStatus.Text='NG：'+$_.Exception.Message } })
    foreach ($name in @('SettingsProfiles','SettingsProfileName','RenameProfile','SettingsDeleteProfile','ClearHistory','SettingsStatus')) { $ui[$name]=$window.FindName($name) }
    $ui.SettingsProfiles.add_SelectionChanged({
        $ui.SettingsProfileName.Text=if ($ui.SettingsProfiles.SelectedItem) { $ui.SettingsProfiles.SelectedItem.name } else { '' }
        Update-ProfileDeleteAvailability
    })
    $ui.RenameProfile.add_Click({ Invoke-SettingsAction {
        $item=$ui.SettingsProfiles.SelectedItem
        if (!$item) { throw 'プロフィールを選択してください。' }
        Rename-ProfileEntry $item.id $ui.SettingsProfileName.Text
        Sync-ProfileSelector
        Refresh-SettingsProfiles $item.id
        $ui.SettingsStatus.Text='プロフィール名を保存しました。'
    } })
    $ui.SettingsDeleteProfile.add_Click({ Invoke-SettingsAction {
        $item=$ui.SettingsProfiles.SelectedItem
        if (!$item) { throw 'プロフィールを選択してください。' }
        if ([Windows.MessageBox]::Show($window,('「'+$item.name+'」を一覧から削除しますか？ このプロフィールのタブをすべて閉じます。編集中の記事を保存してください。ログインデータは復旧用に残ります。'),'プロフィール削除','YesNo','Question') -ne 'Yes') { return }
        $wasActive=$item.id -eq $profiles.activeId
        Assert-TabSwitchAllowed
        Remove-ProfileEntry $item.id
        Close-ProfileTabs $item.id
        Sync-ProfileSelector
        Refresh-SettingsProfiles $profiles.activeId
        if ($wasActive) { Open-ProfileBrowser }
        $ui.SettingsStatus.Text='プロフィールを一覧から削除しました。'
    } })
    $ui.ClearHistory.add_Click({ Invoke-SettingsAction {
        if ([Windows.MessageBox]::Show($window,'全プロフィールの閲覧履歴をすべて消去します。元に戻せません。実行しますか？','閲覧履歴の初期化','YesNo','Warning') -ne 'Yes') { return }
        if ($script:browser -and $browser.CoreWebView2) { $browser.CoreWebView2.Stop() }
        Clear-AllHistory
        $ui.HistorySearch.Clear()
        Refresh-History
        $ui.SettingsStatus.Text='すべての閲覧履歴を消去しました。次の閲覧から新しく記録します。'
    } })
    $ui.HistoryColumn.Width=[Windows.GridLength]::new($config.ui.historyWidth)
    Set-HistoryPanel
    $ui.History.AddHandler([Windows.Controls.Button]::ClickEvent,[Windows.RoutedEventHandler]{ param($s,$e)
        $item=$e.OriginalSource.DataContext
        if ($item.url) { Invoke-UiAction { Navigate-Browser $item.url } }
    })
    $ui.SideColumn.Width=[Windows.GridLength]::new(0)
    $ui.Profiles.ItemsSource=@($profiles.items)
    $ui.Profiles.SelectedItem=@($profiles.items | Where-Object id -eq $profiles.activeId)[0]
    $ui.Profiles.add_SelectionChanged({
        Invoke-UiAction {
            $selected=$ui.Profiles.SelectedItem
            if (!$selected -or $selected.id -eq $profiles.activeId) { return }
            if ($script:pdfTask -or $script:imageTask) { $ui.Profiles.SelectedItem=@($profiles.items | Where-Object id -eq $profiles.activeId)[0]; throw '保存・撮影が完了してからプロフィールを切り替えてください。' }
            $profiles.activeId=$selected.id
            Save-JsonFile $profiles $profilesPath
            Open-ProfileBrowser
        }
    })
    $ui.AddProfile.add_Click({ Invoke-SettingsAction {
        $name=$ui.ProfileName.Text.Trim()
        if (!$name) { throw 'プロフィール名を入力してください。' }
        if ($profiles.items.name -contains $name) { throw '同じ名前のプロフィールがあります。' }
        $profiles.items += [pscustomobject]@{id=[Guid]::NewGuid().ToString();name=$name}
        Save-JsonFile $profiles $profilesPath
        $ui.Profiles.ItemsSource=@($profiles.items)
        $ui.Profiles.SelectedItem=@($profiles.items | Where-Object id -eq $profiles.activeId)[0]
        Refresh-SettingsProfiles $profiles.items[-1].id
        $ui.ProfileName.Clear(); $ui.SettingsStatus.Text='プロフィールを追加しました。閲覧画面に戻り、上部の一覧から切り替えてログインしてください。'
    } })
    $ui.Go.add_Click({ Invoke-UiAction { Navigate-Browser $ui.Address.Text } })
    Initialize-AddressSuggestions
    $ui.Home.add_Click({ Invoke-UiAction { Navigate-Browser ((Get-Content (Join-Path $appRoot 'Config/system.json') -Raw | ConvertFrom-Json).browser.homeUrl) } })
    $ui.Back.add_Click({ Invoke-UiAction { if ($browser.CanGoBack) { $browser.GoBack() } } })
    $ui.Forward.add_Click({ Invoke-UiAction { if ($browser.CanGoForward) { $browser.GoForward() } } })
    $ui.Reload.add_Click({ Invoke-UiAction { $browser.Reload() } })

    Initialize-SidebarLists
    Initialize-AiChatLinks
    Initialize-ButtonDesign
    Initialize-BrowserLayout
    Initialize-AppUpdates
    $window.add_ContentRendered({ if ($script:startupWindow) { $startupWindow.Close() }; Invoke-UiAction { Open-ProfileBrowser } })
    $window.add_Closing({ param($s,$e)
        if ($script:resetRequested) { return }
        if ($script:pdfTask) { $e.Cancel=$true; $ui.Status.Text='PDF保存の完了後に終了してください。'; return }
        if (!$config.ui.skipExitConfirmation -and [Windows.MessageBox]::Show($window,'ブラウザを終了しますか？','終了','YesNo','Question') -ne 'Yes') { $e.Cancel=$true }
    })
    $window.add_Closed({ if ($script:addressSuggestionTimer) { $script:addressSuggestionTimer.Stop() }; Stop-ListActionFeedback; if ($script:summaryStage) { Stop-PageSummary } })
    $window.add_Closed({ if ($script:codexProcess) { if (!$codexProcess.HasExited) { $codexProcess.Kill($true) }; $codexProcess.Dispose() }; Close-AllBrowserTabs; if ($script:timer) { $timer.Stop() } })
    $script:timer=[Windows.Threading.DispatcherTimer]::new()
    $timer.Interval=[TimeSpan]::FromMilliseconds($config.timing.pollMilliseconds)
    $timer.add_Tick({
        Update-AppUpdateCheck
        Update-CodexCheck
        Update-PageSummary
        Update-ImageCapture
        Update-PdfExport
        if ($script:initTask -and $initTask.IsFaulted) { $ui.Status.Text='初期化失敗: '+$initTask.Exception.GetBaseException().Message }
        if ($script:initTask -and !$initTask.IsCompleted -and (([DateTime]::UtcNow-$initStarted).TotalSeconds -gt $config.webView2.initializationTimeoutSeconds)) { $ui.Status.Text='初期化に時間がかかっています。WebView2 Runtimeを確認してください。' }
    })
    $timer.Start()
    $window.ShowDialog() | Out-Null
}













function Initialize-ListDeletion {
    foreach($name in @('History','PdfFiles','ImageFiles')) {
        $list=$ui[$name]
        $list.add_PreviewMouseRightButtonDown({param($s,$e)
            $container=[Windows.Controls.ItemsControl]::ContainerFromElement($s,$e.OriginalSource)
            if($container -is [Windows.Controls.ListBoxItem]){$container.IsSelected=$true}
            else{$s.SelectedIndex=-1}
        })
        $list.add_ContextMenuOpening({param($s,$e)
            if(!$s.SelectedItem){$e.Handled=$true}
        })
        $list.ContextMenu.Items[0].add_Click({param($sender,$eventArgs)
            $list=$sender.Parent.PlacementTarget
            $item=$list.SelectedItem
            if(!$item){return}
            Invoke-UiAction {
                if($list.Name -eq 'History') {
                    Remove-HistoryEntry $item.url
                    Refresh-History
                    Update-AddressSuggestions
                    $ui.Status.Text='閲覧履歴から削除しました。'
                } else {
                    if([Windows.MessageBox]::Show($window,('ファイルを削除します。元に戻せません。'+"`n`n"+$item.path),'ファイルの削除','YesNo','Warning') -ne 'Yes'){return}
                    if($list.Name -eq 'PdfFiles') {
                        Remove-SavedListFile $item.path $config.pdf.outputDirectory '.pdf'
                        Refresh-PdfList
                    } else {
                        Remove-SavedListFile $item.path $config.images.outputDirectory @('.png','.jpg','.jpeg','.webp')
                        Refresh-ImageList
                    }
                    $ui.Status.Text='ファイルを削除しました: '+$item.name
                }
            }
        })
    }
}






function Update-SettingsLayout {
    if(!$ui.SettingsViewport -or !$ui.SettingsLayout){return}
    $wide=$ui.SettingsViewport.ActualWidth -ge [double]$config.ui.settingsLayout.twoColumnMinWidth
    $halfGap=[double]$config.ui.settingsLayout.columnGap / 2
    if($wide) {
        $ui.SettingsLayout.ColumnDefinitions[1].Width=[Windows.GridLength]::new(1,[Windows.GridUnitType]::Star)
        [Windows.Controls.Grid]::SetRow($ui.SettingsAiColumn,0)
        [Windows.Controls.Grid]::SetColumn($ui.SettingsAiColumn,1)
        $ui.SettingsGeneralColumn.Margin=[Windows.Thickness]::new(0,0,$halfGap,0)
        $ui.SettingsAiColumn.Margin=[Windows.Thickness]::new($halfGap,0,0,0)
    } else {
        $ui.SettingsLayout.ColumnDefinitions[1].Width=[Windows.GridLength]::new(0)
        [Windows.Controls.Grid]::SetRow($ui.SettingsAiColumn,1)
        [Windows.Controls.Grid]::SetColumn($ui.SettingsAiColumn,0)
        $ui.SettingsGeneralColumn.Margin=[Windows.Thickness]::new(0)
        $ui.SettingsAiColumn.Margin=[Windows.Thickness]::new(0)
    }
}


function Update-AddressSuggestions {
    if ($script:addressComposing -or !$ui.Address.IsKeyboardFocusWithin) { return }
    $edit=$ui.Address.Template.FindName('PART_EditableTextBox',$ui.Address)
    if (!$edit) { return }
    $text=$edit.Text; $start=$edit.SelectionStart; $length=$edit.SelectionLength
    $items=[Collections.Generic.List[object]]::new()
    foreach ($item in $script:historyItems) {
        if (!$text -or ([string]$item.url).IndexOf($text,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or ([string]$item.title).IndexOf($text,[StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $items.Add($item)
            if ($items.Count -ge $config.ui.addressSuggestions.maxResults) { break }
        }
    }
    $script:updatingAddressSuggestions=$true
    try {
        $ui.Address.ItemsSource=$items.ToArray()
        $ui.Address.SelectedIndex=-1
        $ui.Address.Text=$text
        $edit.Text=$text
        $edit.Select($start,$length)
        # ComboBox queues SelectAll when its popup opens; restore after that callback.
        $restore={
            if ($edit.IsKeyboardFocused -and $edit.Text -ceq $text -and !$script:addressComposing) {
                $edit.Select($start,$length)
            }
        }.GetNewClosure()
        [void]$edit.Dispatcher.BeginInvoke([Action]$restore,[Windows.Threading.DispatcherPriority]::Background)
        $ui.Address.IsDropDownOpen=($items.Count -gt 0)
    } finally { $script:updatingAddressSuggestions=$false }
}
function Initialize-AddressSuggestions {
    $script:addressComposing=$false
    $script:addressUserEditing=$false
    $script:addressSuggestionTimer=[Windows.Threading.DispatcherTimer]::new([Windows.Threading.DispatcherPriority]::Background)
    $addressSuggestionTimer.Interval=[TimeSpan]::FromMilliseconds($config.ui.addressSuggestions.delayMilliseconds)
    $addressSuggestionTimer.add_Tick({ $script:addressSuggestionTimer.Stop(); Update-AddressSuggestions })
    $ui.Address.AddHandler([Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,[Windows.Controls.TextChangedEventHandler]{
        param($sender,$e)
        if ($script:updatingAddressSuggestions -or !$ui.Address.IsKeyboardFocusWithin) { return }
        $script:addressUserEditing=$true
        $script:addressSuggestionTimer.Stop()
        if (!$script:addressComposing) { $script:addressSuggestionTimer.Start() }
    })
    $ui.Address.AddHandler([Windows.Input.TextCompositionManager]::PreviewTextInputStartEvent,[Windows.Input.TextCompositionEventHandler]{
        $script:addressComposing=$true; $script:addressSuggestionTimer.Stop()
    },$true)
    $ui.Address.AddHandler([Windows.Input.TextCompositionManager]::PreviewTextInputEvent,[Windows.Input.TextCompositionEventHandler]{
        $script:addressComposing=$false; $script:addressSuggestionTimer.Stop(); $script:addressSuggestionTimer.Start()
    },$true)
    $ui.Address.add_LostKeyboardFocus({
        if (!$ui.Address.IsKeyboardFocusWithin) { $script:addressSuggestionTimer.Stop(); $script:addressComposing=$false }
    })
    $ui.Address.add_SelectionChanged({
        if (!$script:updatingAddressSuggestions) { $script:addressSuggestionTimer.Stop() }
    })
    $ui.Address.add_PreviewKeyDown({ param($s,$e)
        if ($script:addressComposing -or $e.Key -eq 'ImeProcessed') { return }
        if ($e.Key -eq 'Return') {
            $script:addressSuggestionTimer.Stop(); $e.Handled=$true
            Invoke-UiAction { Navigate-Browser $ui.Address.Text }
        } elseif ($e.Key -eq 'Escape') {
            $script:addressSuggestionTimer.Stop(); $ui.Address.IsDropDownOpen=$false; $e.Handled=$true
        } elseif ($e.Key -in @('Down','Up')) { $script:addressSuggestionTimer.Stop() }
    })
}




function Get-AppLicenseText {
    $catalog=Get-Content -LiteralPath (Join-Path $appRoot 'Config/licenses.json') -Raw -Encoding utf8 | ConvertFrom-Json
    $parts=@($config.productName,('提供元：'+$catalog.publisher),('公式サイト：'+$catalog.website),('提供元ページ：'+$catalog.publisherPage),('GitHub：'+$catalog.github),$catalog.notes)
    foreach ($document in $catalog.documents) {
        $path=Join-Path $appRoot $document.file
        $heading=$document.title+"`n"+$document.description+"`n出典："+$document.source
        if (Test-Path -LiteralPath $path -PathType Leaf) { $parts+=($heading+"`n`n"+(Get-Content -LiteralPath $path -Raw -Encoding utf8)) }
        else { $parts+=($heading+"`nライセンス文書が見つかりません: "+$document.file) }
    }
    return ($parts -join "`r`n`r`n────────────────────`r`n`r`n")
}


function Initialize-BrowserLayout {
 foreach($name in @('HeaderSaveActions','CompactSave','CompactFavorite','CompactPdf','CompactCapture')){
  $ui[$name]=$window.FindName($name)
 }
 $ui.CompactSave.add_Click({
  $ui.CompactFavorite.IsEnabled=$ui.AddFavorite.IsEnabled
  $ui.CompactPdf.IsEnabled=$ui.SavePdf.IsEnabled
  $ui.CompactCapture.IsEnabled=$ui.CaptureImage.IsEnabled
  $ui.CompactSave.ContextMenu.PlacementTarget=$ui.CompactSave
  $ui.CompactSave.ContextMenu.Placement='Bottom'
  $ui.CompactSave.ContextMenu.IsOpen=$true
 })
 $ui.CompactFavorite.add_Click({if($ui.AddFavorite.IsEnabled){$ui.AddFavorite.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}})
 $ui.CompactPdf.add_Click({if($ui.SavePdf.IsEnabled){$ui.SavePdf.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}})
 $ui.CompactCapture.add_Click({if($ui.CaptureImage.IsEnabled){$ui.CaptureImage.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}})
 $window.add_SizeChanged({Update-BrowserLayout})
 Update-BrowserLayout
}
function Update-BrowserLayout {
 if(!$ui.HeaderSaveActions){return}
 $compact=$window.ActualWidth -lt 1200
 $ui.HeaderSaveActions.Visibility=if($compact){'Collapsed'}else{'Visible'}
 $ui.CompactSave.Visibility=if($compact){'Visible'}else{'Collapsed'}
}


function Sort-SidebarItems($Items,[string]$Kind,[string]$DateProperty) {
 $ascending=$script:sidebarSort -and $script:sidebarSort[$Kind] -eq 'old'
 $index=0
 $records=@(foreach($item in $Items){
  $date=[DateTimeOffset]::MinValue
  $known=[DateTimeOffset]::TryParse([string]$item.$DateProperty,[ref]$date)
  [pscustomobject]@{Item=$item;Key=if($known){$date.UtcTicks}else{0};Order= -$index}
  $index++
 })
 $records|Sort-Object Key,Order -Descending:(!$ascending)|ForEach-Object Item
}
function Refresh-SavedFileList([string]$Kind) {
 $list=$ui[$Kind+'Files'];if(!$list){return}
 try{
  $dir=switch($Kind){Image {Resolve-AppPath $config.images.outputDirectory} Pdf {Resolve-AppPath $config.pdf.outputDirectory} Download {Get-WebDownloadDirectory}}
  $query=$ui[$Kind+'Search'].Text.Trim()
  $all=@()
  if(Test-Path -LiteralPath $dir -PathType Container){
   $all=@(Get-ChildItem -LiteralPath $dir -File -ErrorAction Stop|Where-Object {
    $file=$_
    switch($Kind){
     Image {$file.Extension -in @('.png','.jpg','.jpeg','.webp') -and (!$script:imageTask -or $file.FullName -ne $script:imagePath)}
     Pdf {$file.Extension -eq '.pdf' -and (!$script:pdfTask -or $file.FullName -ne $script:pdfPath)}
     Download {$file.Extension -ne '.crdownload' -and (!$script:downloadPaths -or !$script:downloadPaths.Contains($file.FullName))}
    }
   })
  }
  $ascending=$script:sidebarSort -and $script:sidebarSort[$Kind] -eq 'old'
  $items=@($all|Where-Object {!$query -or $_.Name.IndexOf($query,[StringComparison]::OrdinalIgnoreCase) -ge 0}|
   Sort-Object LastWriteTime,Name -Descending:(!$ascending)|ForEach-Object {
    [pscustomobject]@{name=$_.Name;path=$_.FullName;modified=$_.LastWriteTime.ToString('yyyy/MM/dd HH:mm')}
   })
  $list.ItemsSource=$items
  $ui[$Kind+'ListStatus'].Text="$($items.Count)件（全$($all.Count)件）"
  $ui[$Kind+'ListStatus'].ToolTip=$dir
 }catch{$list.ItemsSource=@();$ui[$Kind+'ListStatus'].Text='一覧を読み込めません。保存先の場所・権限を確認してください。'}
}
function Update-SidebarList([string]$Kind) {
 switch($Kind){Favorite {Refresh-Favorites} History {Refresh-History} Pdf {Refresh-PdfList} Image {Refresh-ImageList} Download {Refresh-DownloadList}}
}
function Initialize-SidebarLists {
 $script:sidebarSort=@{}
 foreach($kind in @('Favorite','History','Pdf','Image','Download')){
  $script:sidebarSort[$kind]='new'
  foreach($order in @('New','Old')){
   $button=$window.FindName($kind+'Sort'+$order)
   $ui[$kind+'Sort'+$order]=$button
   $button.CommandParameter=[pscustomobject]@{Kind=$kind;Order=$order.ToLowerInvariant()}
   $image=(Get-LucideImage 'arrow-left').Clone()
   $image.Drawing.Transform=[Windows.Media.RotateTransform]::new($(if($order -eq 'New'){-90}else{90}),12,12)
   $image.Freeze();$button.Tag=$image
   $button.FontWeight=if($order -eq 'New'){'Bold'}else{'Normal'}
   $button.add_Click({
    param($sender,$eventArgs)
    $choice=$sender.CommandParameter
    $script:sidebarSort[$choice.Kind]=$choice.Order
    $ui[$choice.Kind+'SortNew'].FontWeight=if($choice.Order -eq 'new'){'Bold'}else{'Normal'}
    $ui[$choice.Kind+'SortOld'].FontWeight=if($choice.Order -eq 'old'){'Bold'}else{'Normal'}
    Update-SidebarList $choice.Kind
   })
  }
 }
 $window.FindName('RefreshFavorites').add_Click({Load-Favorites;Refresh-Favorites})
 $window.FindName('RefreshHistory').add_Click({Load-History;Refresh-History})
}


function Initialize-ActionToast {
 $ui.ActionToast=$window.FindName('ActionToast')
 $ui.ActionToastText=$window.FindName('ActionToastText')
}
function Show-ActionToast([string]$Message) {
 if(!$ui.ActionToast){return}
 $ui.ActionToastText.Text=$Message
 $timing=$config.ui.actionToast
 $fade=[double]$timing.fadeSeconds
 $hold=[double]$timing.displaySeconds
 $opacity=[double]$timing.opacity
 $animation=[Windows.Media.Animation.DoubleAnimationUsingKeyFrames]::new()
 [void]$animation.KeyFrames.Add([Windows.Media.Animation.LinearDoubleKeyFrame]::new(0,[Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::Zero)))
 [void]$animation.KeyFrames.Add([Windows.Media.Animation.LinearDoubleKeyFrame]::new($opacity,[Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromSeconds($fade))))
 [void]$animation.KeyFrames.Add([Windows.Media.Animation.LinearDoubleKeyFrame]::new($opacity,[Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromSeconds($fade+$hold))))
 [void]$animation.KeyFrames.Add([Windows.Media.Animation.LinearDoubleKeyFrame]::new(0,[Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromSeconds($fade+$hold+$fade))))
 $animation.FillBehavior='Stop'
 $ui.ActionToast.BeginAnimation([Windows.UIElement]::OpacityProperty,$animation,[Windows.Media.Animation.HandoffBehavior]::SnapshotAndReplace)
}







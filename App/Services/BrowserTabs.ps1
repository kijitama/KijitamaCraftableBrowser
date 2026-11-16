function Initialize-TabStrip {
    foreach ($name in @('TabsScroll','TabsScrollLeft','TabsScrollRight')) { $ui[$name]=$window.FindName($name) }
    $ui.TabsScroll.add_ScrollChanged({
        $ui.TabsScrollLeft.IsEnabled=($ui.TabsScroll.HorizontalOffset -gt 0)
        $ui.TabsScrollRight.IsEnabled=($ui.TabsScroll.HorizontalOffset -lt $ui.TabsScroll.ScrollableWidth)
    })
    $ui.TabsScrollLeft.add_Click({
        $ui.TabsScroll.ScrollToHorizontalOffset($ui.TabsScroll.HorizontalOffset - [Math]::Max(1,$ui.TabsScroll.ViewportWidth * 0.8))
    })
    $ui.TabsScrollRight.add_Click({
        $ui.TabsScroll.ScrollToHorizontalOffset($ui.TabsScroll.HorizontalOffset + [Math]::Max(1,$ui.TabsScroll.ViewportWidth * 0.8))
    })
    $ui.TabsScroll.add_PreviewMouseWheel({
        param($sender,$eventArgs)
        if ($sender.ScrollableWidth -gt 0) {
            $sender.ScrollToHorizontalOffset($sender.HorizontalOffset - $eventArgs.Delta)
            $eventArgs.Handled=$true
        }
    })
}

function Initialize-BrowserTabs {
    $script:browserTabs=[Collections.Generic.List[object]]::new()
    $script:activeBrowserTab=$null
    $script:profileTabSessions=@{}
    $script:visibleProfileId=$null
    $ui.BrowserTabs=$window.FindName('BrowserTabs')
    $ui.NewTab=$window.FindName('NewTab')
    Initialize-TabStrip
    $script:browserTabHost=[Windows.Controls.Grid]::new()
    $ui.BrowserPanel.Child=$browserTabHost
    $ui.NewTab.add_Click({ Invoke-UiAction { New-BrowserTab $config.browser.homeUrl } })
}
function Get-BrowserTabForCore($Core) {
    foreach ($session in $script:profileTabSessions.Values) {
        foreach ($tab in $session.Tabs) { if (!$tab.Closed -and [object]::ReferenceEquals($tab.Core,$Core)) { return $tab } }
    }
}
function Assert-TabSwitchAllowed {
    if ($script:pdfTask -or $script:imageTask) { throw 'PDF保存・撮影が完了してからタブを切り替えてください。' }
}
function Update-ActiveTabUi {
    if (!$script:activeBrowserTab) { return }
    $tab=$script:activeBrowserTab
    $ui.Back.IsEnabled=($null -ne $tab.Core -and $tab.Core.CanGoBack)
    $ui.Forward.IsEnabled=($null -ne $tab.Core -and $tab.Core.CanGoForward)
    if (!$script:addressUserEditing -or !$ui.Address.IsKeyboardFocusWithin) {
        $script:updatingAddressSuggestions=$true
        try { $ui.Address.Text=$tab.Url; $ui.Address.IsDropDownOpen=$false }
        finally { $script:updatingAddressSuggestions=$false }
    }
    $ui.Status.Text=$tab.Status
    Update-FavoriteIndicator
    Update-PageAnalysisAvailability
}
function Select-BrowserTab($Tab) {
    if (!$Tab -or $Tab.Closed -or [object]::ReferenceEquals($Tab,$script:activeBrowserTab)) { return }
    Assert-TabSwitchAllowed
    if ($script:summaryStage) { Stop-PageSummary 'タブを切り替えたため要約を中止しました。' }
    if ($ui.SummaryText) { $ui.SummaryText.Clear(); $ui.SummarySource.Text='' }
    if ($script:addressSuggestionTimer) { $script:addressSuggestionTimer.Stop() }
    $script:addressUserEditing=$false
    $script:profileTabSessions[$Tab.ProfileId].Active=$Tab
    $script:activeBrowserTab=$Tab
    $script:browser=$Tab.View
    $script:initTask=$Tab.InitTask
    $script:initStarted=$Tab.Started
    foreach ($entry in $script:browserTabs) {
        $selected=[object]::ReferenceEquals($entry,$Tab)
        $entry.View.Visibility=if($selected){'Visible'}else{'Collapsed'}
        $entry.Header.Background=if($selected){[Windows.Media.Brushes]::AliceBlue}else{[Windows.Media.Brushes]::White}
        $entry.Select.FontWeight=if($selected){'SemiBold'}else{'Normal'}
    }
    $ui.TabsScroll.UpdateLayout()
    $Tab.Header.BringIntoView()
    Update-ActiveTabUi
}
function Close-ProfileTabs([string]$ProfileId) {
    if (!$script:profileTabSessions.ContainsKey($ProfileId)) { return }
    $session=$script:profileTabSessions[$ProfileId]
    foreach ($tab in @($session.Tabs.ToArray())) {
        $tab.Closed=$true
        $tab.View.Dispose()
        $browserTabHost.Children.Remove($tab.View)
        $ui.BrowserTabs.Children.Remove($tab.Header)
    }
    $session.Tabs.Clear()
    $script:profileTabSessions.Remove($ProfileId)
    if ($ProfileId -eq $script:visibleProfileId) {
        $script:activeBrowserTab=$null; $script:browser=$null; $script:initTask=$null
        $script:visibleProfileId=$null
    }
}
function Close-AllBrowserTabs {
    foreach ($id in @($script:profileTabSessions.Keys)) { Close-ProfileTabs $id }
    $script:browserTabs=[Collections.Generic.List[object]]::new()
    if ($script:browserTabHost) { $script:browserTabHost.Children.Clear() }
    if ($ui.BrowserTabs) { $ui.BrowserTabs.Children.Clear() }
    $script:activeBrowserTab=$null; $script:browser=$null; $script:initTask=$null
}
function Restore-ProfileTabs {
    foreach ($session in $script:profileTabSessions.Values) {
        foreach ($tab in $session.Tabs) { $tab.View.Visibility='Collapsed' }
    }
    $ui.BrowserTabs.Children.Clear()
    $id=[string]$profiles.activeId
    if (!$script:profileTabSessions.ContainsKey($id)) {
        $script:profileTabSessions[$id]=[pscustomobject]@{Tabs=[Collections.Generic.List[object]]::new();Active=$null}
    }
    $session=$script:profileTabSessions[$id]
    $script:visibleProfileId=$id
    $script:browserTabs=$session.Tabs
    $script:activeBrowserTab=$null; $script:browser=$null
    foreach ($tab in $session.Tabs) { [void]$ui.BrowserTabs.Children.Add($tab.Header) }
    if ($session.Active -and !$session.Active.Closed) { Select-BrowserTab $session.Active }
    elseif ($session.Tabs.Count) { Select-BrowserTab $session.Tabs[0] }
    else { New-BrowserTab $config.browser.homeUrl }
}
function Record-TabHistory($Tab) {
    if (!$Tab -or $Tab.Closed -or !$Tab.Core -or !(Test-AllowedUrl $Tab.Core.Source)) { return }
    if ($Tab.ProfileId -eq $profiles.activeId) {
        Record-History $Tab.Core.Source $Tab.Core.DocumentTitle; Refresh-History
    } else {
        $dir=Join-Path $dataDir $config.history.directory
        [void][IO.Directory]::CreateDirectory($dir)
        $path=Join-Path $dir ($Tab.ProfileId+'.json')
        $items=if(Test-Path -LiteralPath $path){@(Get-Content -LiteralPath $path -Raw|ConvertFrom-Json)}else{@()}
        $title=if($Tab.Core.DocumentTitle){$Tab.Core.DocumentTitle}else{$Tab.Core.Source}
        $item=[pscustomobject]@{url=$Tab.Core.Source;title=$title;visitedAt=[DateTime]::UtcNow.ToString('o')}
        $next=@(@($item)+@($items|Where-Object {$_.url -cne $item.url})|Select-Object -First $config.history.maxEntries)
        Save-JsonFile $next $path
    }
}
function Close-BrowserTab($Tab) {
    if (!$Tab -or $Tab.Closed) { return }
    Assert-TabSwitchAllowed
    $index=$script:browserTabs.IndexOf($Tab)
    $wasActive=[object]::ReferenceEquals($Tab,$script:activeBrowserTab)
    if ($wasActive -and $script:summaryStage) { Stop-PageSummary 'タブを閉じたため要約を中止しました。' }
    $Tab.Closed=$true
    [void]$script:browserTabs.Remove($Tab)
    $browserTabHost.Children.Remove($Tab.View)
    $ui.BrowserTabs.Children.Remove($Tab.Header)
    $Tab.View.Dispose()
    if ($wasActive) {
        $script:activeBrowserTab=$null; $script:browser=$null
        if ($script:browserTabs.Count) { Select-BrowserTab $script:browserTabs[[Math]::Min($index,$script:browserTabs.Count-1)] }
        else { New-BrowserTab $config.browser.homeUrl }
    }
}
function New-BrowserTab([string]$Url) {
    Assert-TabSwitchAllowed
    if (!(Test-AllowedUrl $Url)) { throw (Get-NavigationDeniedMessage $Url) }
    if ($script:browserTabs.Count -ge $config.ui.tabs.maxCount) { throw "タブ数の上限（$($config.ui.tabs.maxCount)件）です。不要なタブを閉じてください。" }
    if (!$script:profileTabSessions.ContainsKey([string]$profiles.activeId)) {
        $script:profileTabSessions[[string]$profiles.activeId]=[pscustomobject]@{Tabs=$script:browserTabs;Active=$null}
        $script:visibleProfileId=[string]$profiles.activeId
    }
    $view=[Microsoft.Web.WebView2.Wpf.WebView2]::new()
    $props=[Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties]::new()
    $props.UserDataFolder=Join-Path $dataDir (Join-Path $config.storage.webProfilesDirectory $profiles.activeId)
    $view.CreationProperties=$props
    $header=[Windows.Controls.Border]::new(); $header.CornerRadius=[Windows.CornerRadius]::new(6)
    $header.BorderBrush=[Windows.Media.Brushes]::LightSteelBlue; $header.BorderThickness=[Windows.Thickness]::new(1); $header.Margin=[Windows.Thickness]::new(2)
    $row=[Windows.Controls.StackPanel]::new(); $row.Orientation='Horizontal'; $header.Child=$row
    $title=[Windows.Controls.TextBlock]::new();$title.Text='読み込み中…';$title.TextTrimming='CharacterEllipsis';$title.Width=$config.ui.tabs.titleWidth
    $select=[Windows.Controls.Button]::new();$select.Content=$title;$select.Padding=[Windows.Thickness]::new(7,4,7,4);$select.Margin=[Windows.Thickness]::new(0);$select.BorderThickness=[Windows.Thickness]::new(0)
    $close=[Windows.Controls.Button]::new();$close.Content='×';$close.ToolTip='このタブを閉じる';$close.Padding=[Windows.Thickness]::new(6,4,6,4);$close.Margin=[Windows.Thickness]::new(0);$close.BorderThickness=[Windows.Thickness]::new(0)
    # Tab headers use their own content; Tag holds the tab identity, not an icon.
    $select.ContentTemplate=$null; $close.ContentTemplate=$null
    [void]$row.Children.Add($select);[void]$row.Children.Add($close)
    $tab=[pscustomobject]@{ProfileId=[string]$profiles.activeId;View=$view;Core=$null;Header=$header;Select=$select;Title=$title;Url=$Url;Status='ページを読み込んでいます…';InitTask=$null;Started=[DateTime]::UtcNow;Closed=$false}
    $select.Tag=$tab;$close.Tag=$tab;$view.Tag=$tab
    $select.add_Click({param($s,$e) Invoke-UiAction { Select-BrowserTab $s.Tag }})
    $close.add_Click({param($s,$e) Invoke-UiAction { Close-BrowserTab $s.Tag }})
    $script:browserTabs.Add($tab)
    [void]$ui.BrowserTabs.Children.Add($header)
    [void]$browserTabHost.Children.Add($view)
    $view.add_CoreWebView2InitializationCompleted({
        param($sender,$eventArgs)
        $tab=$sender.Tag
        if ($tab.Closed) { return }
        if (!$eventArgs.IsSuccess) { $tab.Status='初期化失敗: '+$eventArgs.InitializationException.Message; $tab.Title.Text='読み込み失敗'; if($tab -eq $script:activeBrowserTab){Update-ActiveTabUi}; return }
        $core=$sender.CoreWebView2;$tab.Core=$core
        $core.Settings.AreDevToolsEnabled=$false
        $core.Settings.AreDefaultContextMenusEnabled=$true
        $core.add_NavigationStarting({param($s,$e)
            if (!(Test-AllowedUrl $e.Uri)) { $e.Cancel=$true; $t=Get-BrowserTabForCore $s; if($t){$t.Status=Get-NavigationDeniedMessage $e.Uri;if($t -eq $script:activeBrowserTab){Update-ActiveTabUi}} }
        })
        $core.add_FrameNavigationStarting({param($s,$e)
            if (!(Test-AllowedFrameUrl $e.Uri)) { $e.Cancel=$true; $t=Get-BrowserTabForCore $s; if($t){$t.Status=Get-NavigationDeniedMessage $e.Uri $true;if($t -eq $script:activeBrowserTab){Update-ActiveTabUi}} }
        })
        $core.add_NewWindowRequested({param($s,$e) $e.Handled=$true; $t=Get-BrowserTabForCore $s; if($t -and $t.ProfileId -eq $profiles.activeId){Invoke-UiAction { New-BrowserTab $e.Uri }}})
        $core.add_PermissionRequested({param($s,$e) $e.State=[Microsoft.Web.WebView2.Core.CoreWebView2PermissionState]::Deny})
        $core.add_DownloadStarting({param($s,$e) Start-WebDownload $s $e})
        $core.add_ContextMenuRequested({param($s,$e) Show-WebContextMenu $s $e})
        $core.add_LaunchingExternalUriScheme({param($s,$e) $e.Cancel=$true})
        $core.add_SourceChanged({param($s,$e)
            $t=Get-BrowserTabForCore $s;if(!$t){return};$t.Url=$s.Source
            if($t -eq $script:activeBrowserTab){Update-ActiveTabUi}
            if(!$e.IsNewDocument){Invoke-UiAction {Record-TabHistory $t}}
        })
        $core.add_DocumentTitleChanged({param($s,$e)
            $t=Get-BrowserTabForCore $s;if(!$t){return}
            $t.Title.Text=if($s.DocumentTitle){$s.DocumentTitle}else{$t.Url}
            $t.Select.ToolTip=$t.Title.Text+"`n"+$t.Url
            [Windows.Automation.AutomationProperties]::SetName($t.Select,$t.Title.Text)
            Invoke-UiAction {Record-TabHistory $t}
        })
        $core.add_HistoryChanged({param($s,$e) $t=Get-BrowserTabForCore $s;if($t -and $t -eq $script:activeBrowserTab){Update-ActiveTabUi}})
        $core.add_NavigationCompleted({param($s,$e)
            $t=Get-BrowserTabForCore $s;if(!$t){return}
            if($e.IsSuccess){$t.Status='';Invoke-UiAction {Record-TabHistory $t}}
            elseif($e.WebErrorStatus.ToString() -ne 'OperationCanceled'){$t.Status='表示失敗: '+$e.WebErrorStatus}
            if($t -eq $script:activeBrowserTab){Update-ActiveTabUi}
        })
        $core.add_ProcessFailed({param($s,$e) $t=Get-BrowserTabForCore $s;if($t){$t.Status='ブラウザー処理が停止しました。タブを開き直してください。';if($t -eq $script:activeBrowserTab){Update-ActiveTabUi}}})
        $core.Navigate($tab.Url)
    })
    Select-BrowserTab $tab
    $tab.InitTask=$view.EnsureCoreWebView2Async()
    $script:initTask=$tab.InitTask
}




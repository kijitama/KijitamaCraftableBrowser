function Set-UpdateProgress([bool]$Busy) {
    $visibility=if($Busy){'Visible'}else{'Collapsed'}
    foreach($name in @('UpdateCheckProgress','FooterUpdateProgress')){if($ui[$name]){$ui[$name].Visibility=$visibility}}
    foreach($name in @('UpdateCheckProgress','FooterUpdateBar')){if($ui[$name] -is [Windows.Controls.ProgressBar]){$ui[$name].IsIndeterminate=$Busy}}
}
function ConvertTo-UpdateNotice($Notice) {
    if ($Notice.schemaVersion -ne 1 -or $Notice.product -cne 'KijitamaCraftableBrowser') { throw '更新情報の形式が正しくありません。' }
    foreach ($key in @('latestVersion','affectedFrom','affectedBefore')) {
        if ([string]$Notice.$key -notmatch '^\d+\.\d+\.\d+$') { throw '更新情報のバージョンが不正です。' }
        $null=[version]$Notice.$key
    }
    if ([version]$Notice.affectedFrom -ge [version]$Notice.affectedBefore -or [version]$Notice.affectedBefore -gt [version]$Notice.latestVersion) { throw '更新対象の範囲が不正です。' }
    if ($Notice.severity -notin @('normal','recommended','urgent')) { throw '更新の重要度が不正です。' }
    if ($Notice.message -isnot [string] -or [string]::IsNullOrWhiteSpace($Notice.message) -or $Notice.message.Length -gt $config.updates.maxMessageCharacters) { throw '更新案内の文章が不正です。' }
    $uri=$null
    if (![Uri]::TryCreate([string]$Notice.downloadUrl,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or !$uri.IsDefaultPort) { throw '配布ページのURLが不正です。' }
    $allowed=$false
    foreach($prefix in $config.updates.allowedDownloadUrlPrefixes) {
        if ($uri.AbsoluteUri.StartsWith([string]$prefix,[StringComparison]::OrdinalIgnoreCase)) { $allowed=$true }
    }
    if (!$allowed) { throw '公式配布ページ以外のURLが指定されています。' }
    $zipUrl=''
    if (![string]::IsNullOrWhiteSpace([string]$Notice.zipUrl)) {
        $zip=$null
        if (![Uri]::TryCreate([string]$Notice.zipUrl,[UriKind]::Absolute,[ref]$zip) -or $zip.Scheme -ne 'https' -or $zip.Host -ne 'github.com' -or $zip.UserInfo -or !$zip.IsDefaultPort -or $zip.Query -or $zip.Fragment -or $zip.AbsolutePath -notmatch '^/[^/]+/[^/]+/releases/download/[^/]+/[^/]+\.zip$') { throw '最新版ZIPのURLが不正です。' }
        $zipAllowed=$false
        foreach($prefix in $config.updates.allowedDownloadUrlPrefixes){if($zip.AbsoluteUri.StartsWith([string]$prefix,[StringComparison]::OrdinalIgnoreCase)){$zipAllowed=$true}}
        if(!$zipAllowed){throw '最新版ZIPは公式リポジトリの配布ファイルを指定してください。'}
        $zipUrl=$zip.AbsoluteUri
    }
    return [pscustomobject]@{schemaVersion=1;product='KijitamaCraftableBrowser';latestVersion=[string]$Notice.latestVersion;affectedFrom=[string]$Notice.affectedFrom;affectedBefore=[string]$Notice.affectedBefore;severity=[string]$Notice.severity;message=$Notice.message;downloadUrl=$uri.AbsoluteUri;zipUrl=$zipUrl}
}
function Show-UpdateNotice($Notice,[bool]$Notify) {
    $current=[version]$config.updates.currentVersion
    $script:availableUpdate=$Notice
    $ui.DownloadLatest.IsEnabled=![string]::IsNullOrWhiteSpace($Notice.zipUrl)
    $ui.LatestDownloadStatus.Text=if($Notice.zipUrl){'ZIPを設定済みのダウンロード先へ保存します。展開・実行・上書きは行いません。'}else{'最新版ZIPの配布URLはまだ登録されていません。'}
    $ui.OpenUpdatePage.Visibility='Collapsed'
    $ui.UpdateCheckStatus.Foreground=[Windows.Media.Brushes]::Black
    if ($current -ge [version]$Notice.latestVersion) { $ui.UpdateCheckStatus.Text='公開されている更新情報では、更新は必要ありません。'; return }
    $affected=$current -ge [version]$Notice.affectedFrom -and $current -lt [version]$Notice.affectedBefore
    $label=if(!$affected){'新しいバージョンがあります'}else{switch($Notice.severity){normal{'新しいバージョンがあります'} recommended{'更新をおすすめします'} urgent{'安全に関わる重要な更新があります'}}}
    $message=$label+'（'+$Notice.latestVersion+'）'+[Environment]::NewLine+$Notice.message
    $ui.UpdateCheckStatus.Text=$message
    if($affected -and $Notice.severity -eq 'urgent'){$ui.UpdateCheckStatus.Foreground=[Windows.Media.Brushes]::Firebrick}
    $script:availableUpdate=$Notice
    $ui.OpenUpdatePage.Visibility='Visible'
    if($Notify){
        $icon=if($affected -and $Notice.severity -eq 'urgent'){'Warning'}else{'Information'}
        [void][Windows.MessageBox]::Show($window,$message+[Environment]::NewLine+[Environment]::NewLine+'設定画面の「アプリの更新」から公式配布ページを開けます。','アプリの更新','OK',$icon)
    }
}
function Stop-AppUpdateCheck {
    Set-UpdateProgress $false
    if($script:updateClient){$script:updateClient.CancelPendingRequests();$script:updateClient.Dispose();$script:updateClient=$null}
    $script:updateTask=$null
    $script:updateWatch=$null
}
function Start-AppUpdateCheck([bool]$Manual=$false) {
    if($script:updateTask){return}
    $ui.UpdateCheckStatus.Foreground=[Windows.Media.Brushes]::Black
    try {
        $settings=$config.updates
        if(!$settings -or [string]::IsNullOrWhiteSpace($settings.feedUrl)){$ui.UpdateCheckStatus.Text='更新情報の公開先は未設定です。';return}
        if(!$Manual -and !$settings.enabled){$ui.UpdateCheckStatus.Text='起動時の更新確認は無効です。';return}
        if([string]$settings.currentVersion -notmatch '^\d+\.\d+\.\d+$' -or $settings.timeoutSeconds -lt 1 -or $settings.maxResponseBytes -lt $settings.minimumResponseBytes){throw '更新確認の設定が不正です。'}
        $null=[version]$settings.currentVersion
        $uri=$null
        if(![Uri]::TryCreate([string]$settings.feedUrl,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or !$uri.IsDefaultPort){throw '更新情報のURLはhttpsで指定してください。'}
        $handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false;$handler.UseCookies=$false
        $script:updateClient=[Net.Http.HttpClient]::new($handler)
        $updateClient.Timeout=[TimeSpan]::FromSeconds($settings.timeoutSeconds)
        $updateClient.MaxResponseContentBufferSize=$settings.maxResponseBytes
        $script:availableUpdate=$null
        $ui.DownloadLatest.IsEnabled=$false
        $ui.LatestDownloadStatus.Text='更新情報を確認後、配布ZIPをダウンロードできます。'
        $ui.OpenUpdatePage.Visibility='Collapsed'
        Set-UpdateProgress $true
        $script:updateWatch=[Diagnostics.Stopwatch]::StartNew()
        $script:updateTask=$updateClient.GetStringAsync($uri)
        $ui.CheckAppUpdates.IsEnabled=$false
        $ui.UpdateCheckStatus.Text='更新情報を確認しています…'
    }catch{$ui.UpdateCheckStatus.Text='更新状況を確認できませんでした。'+$_.Exception.GetBaseException().Message;Stop-AppUpdateCheck;$ui.CheckAppUpdates.IsEnabled=$true}
}
function Update-AppUpdateCheck {
    if(!$script:updateTask){return}
    if(!$updateTask.IsCompleted){
        if($script:updateWatch -and $updateWatch.Elapsed.TotalSeconds -ge $config.updates.timeoutSeconds){
            Stop-AppUpdateCheck
            $ui.CheckAppUpdates.IsEnabled=$true
            $ui.UpdateCheckStatus.Text='時間内に更新情報を取得できなかったため、確認をスキップしました。「更新チェック」から再確認できます。'
        }
        return
    }
    try {
        $notice=ConvertTo-UpdateNotice ($updateTask.GetAwaiter().GetResult() | ConvertFrom-Json)

        Stop-AppUpdateCheck
        Show-UpdateNotice $notice $true
    }catch{
        if($_.Exception.GetBaseException() -is [OperationCanceledException]){
            $ui.UpdateCheckStatus.Text='時間内に更新情報を取得できなかったため、確認をスキップしました。「更新チェック」から再確認できます。'
        }else{
            $ui.UpdateCheckStatus.Text='更新状況を確認できませんでした。接続状況を確認し、「更新チェック」から再確認してください。'
        }
    }
    finally{Stop-AppUpdateCheck;$ui.CheckAppUpdates.IsEnabled=$true}
}
function Initialize-AppUpdates {
    foreach($name in @('CheckAppUpdates','UpdateCheckStatus','OpenUpdatePage','CurrentAppVersion','FooterAppVersion','UpdateCheckProgress','FooterUpdateProgress','FooterUpdateBar','DownloadLatest','LatestDownloadStatus')){$ui[$name]=$window.FindName($name)}
    $ui.CurrentAppVersion.Text='現在のバージョン：'+$config.updates.currentVersion
    $ui.FooterAppVersion.Text='Ver. '+$config.updates.currentVersion
    $ui.UpdateCheckStatus.Text=if($config.updates.feedUrl){'まだ更新情報を確認していません。'}else{'更新情報の公開先は未設定です。'}
    $ui.CheckAppUpdates.add_Click({Start-AppUpdateCheck $true})
    $ui.DownloadLatest.add_Click({Invoke-SettingsAction {Start-LatestAppDownload}})
    $ui.OpenUpdatePage.add_Click({Invoke-UiAction {if($script:availableUpdate){$notice=ConvertTo-UpdateNotice $availableUpdate;Show-SettingsScreen $false;Navigate-Browser $notice.downloadUrl}}})
    $window.add_ContentRendered({Start-AppUpdateCheck $false})
    $window.add_Closed({Stop-AppUpdateCheck})
}



function Start-LatestAppDownload {
    if(!$script:availableUpdate){throw '先に更新チェックを実行してください。'}
    $notice=ConvertTo-UpdateNotice $availableUpdate
    if(!$notice.zipUrl){throw '最新版ZIPの配布URLはまだ登録されていません。'}
    if(!(Test-AllowedUrl $notice.zipUrl)){throw '閲覧設定で配布先への接続が許可されていません。'}
    if(!$script:browser -or !$browser.CoreWebView2){throw 'ブラウザーの準備完了後に再度お試しください。'}
    # Use the existing WebView2 DownloadStarting pipeline: configured folder,
    # unique file names, download-list refresh and completion toast.
    Navigate-Browser $notice.zipUrl
    Show-SettingsScreen $false
}



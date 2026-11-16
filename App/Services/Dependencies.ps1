function Confirm-WebViewDependencyInstall {
    $message='ブラウザの起動に必要なWebView2の部品を、Microsoft公式の配布元からダウンロードし、アプリのフォルダー内に配置します。インターネット接続が必要です。'+[Environment]::NewLine+[Environment]::NewLine+
        '取得したファイルを検証してから配置します。許可しますか？「いいえ」を選ぶと、取得せずに起動を終了します。'
    return ([Windows.MessageBox]::Show($message,'必要部品の導入確認',
        [Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Question,
        [Windows.MessageBoxResult]::No) -eq [Windows.MessageBoxResult]::Yes)
}
function Install-WebViewPackage([byte[]]$Bytes) {
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))
    if ($hash -ne $config.webView2.packageSha256) { throw 'ダウンロード内容の検証に失敗しました。部品は読み込みません。' }
    $arch=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
    if ($arch -notin @('x64','x86','arm64')) { throw '未対応のCPUです。' }
    $managed=Resolve-AppPath $config.webView2.assemblyDirectory
    $native=Resolve-AppPath $config.webView2.nativeDirectory
    $entries=@{
        'lib_manual/netcoreapp3.0/Microsoft.Web.WebView2.Core.dll'=(Join-Path $managed 'Microsoft.Web.WebView2.Core.dll')
        'lib_manual/netcoreapp3.0/Microsoft.Web.WebView2.Wpf.dll'=(Join-Path $managed 'Microsoft.Web.WebView2.Wpf.dll')
        "runtimes/win-$arch/native/WebView2Loader.dll"=(Join-Path $native 'WebView2Loader.dll')
        'LICENSE.txt'=(Join-Path $managed 'LICENSE.txt')
        'NOTICE.txt'=(Join-Path $managed 'NOTICE.txt')
    }
    $stream=[IO.MemoryStream]::new($Bytes,$false)
    $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Read)
    try {
        foreach ($key in $entries.Keys) { if (!$zip.GetEntry($key)) { throw "必要部品がありません: $key" } }
        foreach ($key in $entries.Keys) {
            $dest=$entries[$key]
            [IO.Directory]::CreateDirectory((Split-Path $dest -Parent))|Out-Null
            $inputStream=$zip.GetEntry($key).Open()
            try { $outputStream=[IO.File]::Create($dest); try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose() } } finally { $inputStream.Dispose() }
        }
        # Keep the license screen available even after downloaded binaries are reset.
        $licenseDirectory=Join-Path $appRoot 'Licenses'
        [IO.Directory]::CreateDirectory($licenseDirectory)|Out-Null
        Copy-Item -LiteralPath (Join-Path $managed 'LICENSE.txt') -Destination (Join-Path $licenseDirectory 'WebView2-LICENSE.txt') -Force
        Copy-Item -LiteralPath (Join-Path $managed 'NOTICE.txt') -Destination (Join-Path $licenseDirectory 'WebView2-NOTICE.txt') -Force
        $hash | Set-Content (Join-Path $managed 'installed.sha256')
    } finally { $zip.Dispose(); $stream.Dispose() }
}
function Ensure-WebViewDependencies {
    $managed=Resolve-AppPath $config.webView2.assemblyDirectory
    $native=Resolve-AppPath $config.webView2.nativeDirectory
    $ready=$true
    foreach ($file in @("$managed/Microsoft.Web.WebView2.Core.dll","$managed/Microsoft.Web.WebView2.Wpf.dll","$native/WebView2Loader.dll","$managed/LICENSE.txt","$managed/NOTICE.txt","$managed/installed.sha256")) { if (!(Test-Path -LiteralPath $file)) { $ready=$false } }
    if ($ready -and (Get-Content "$managed/installed.sha256" -Raw).Trim() -eq $config.webView2.packageSha256) { return }
    if (!(Confirm-WebViewDependencyInstall)) {
        $script:startupCancelled=$true
        throw [OperationCanceledException]::new('必要部品の導入が許可されなかったため、起動を終了しました。')
    }
    $script:dependencyWindow=[Windows.Markup.XamlReader]::Parse('<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="初回起動の準備" Width="470" Height="160" WindowStartupLocation="CenterScreen" ResizeMode="NoResize"><StackPanel Margin="22"><TextBlock Text="Microsoft公式のWebView2部品を取得しています…" TextWrapping="Wrap"/><ProgressBar Height="12" Margin="0,20,0,0" IsIndeterminate="True" Foreground="Green"/><TextBlock Text="初回のみインターネット接続が必要です。" Margin="0,10,0,0"/></StackPanel></Window>')
    $script:dependencyClient=[Net.Http.HttpClient]::new()
    $dependencyClient.Timeout=[TimeSpan]::FromSeconds($config.webView2.downloadTimeoutSeconds)
    $script:dependencyTask=$dependencyClient.GetByteArrayAsync([Uri]$config.webView2.packageUrl)
    $script:dependencyFailure=$null; $script:dependencyDone=$false
    $script:dependencyTimer=[Windows.Threading.DispatcherTimer]::new()
    $dependencyTimer.Interval=[TimeSpan]::FromMilliseconds($config.timing.dependencyPollMilliseconds)
    $dependencyTimer.add_Tick({
        if (!$dependencyTask.IsCompleted) { return }
        $dependencyTimer.Stop()
        try { Install-WebViewPackage ($dependencyTask.GetAwaiter().GetResult()); $script:dependencyDone=$true }
        catch { $script:dependencyFailure=$_.Exception.Message }
        $dependencyWindow.Close()
    })
    try { $dependencyTimer.Start(); [void]$dependencyWindow.ShowDialog() }
    finally { $dependencyTimer.Stop(); $dependencyClient.CancelPendingRequests(); $dependencyClient.Dispose() }
    if (!$dependencyDone) { throw ('必要部品を取得できませんでした。ネット接続と書き込み権限を確認して再起動してください。 '+$dependencyFailure) }
}


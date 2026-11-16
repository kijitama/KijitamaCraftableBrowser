param([ValidateSet(-1,0,1)][int]$ShiftAtLaunch=-1)
$ErrorActionPreference = 'Stop'
$appRoot = $PSScriptRoot
if($ShiftAtLaunch -eq -1){
    Add-Type -AssemblyName System.Windows.Forms
    $ShiftAtLaunch=[int](([Windows.Forms.Control]::ModifierKeys -band [Windows.Forms.Keys]::Shift) -ne 0)
}
$script:showResetSettings=($ShiftAtLaunch -eq 1)
if ($PSVersionTable.PSVersion.Major -lt 7 -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    $arguments = @('-NoProfile','-STA','-File', ('"' + $PSCommandPath + '"'))
    $arguments += @('-ShiftAtLaunch', [string]$ShiftAtLaunch)
    Start-Process $pwsh -ArgumentList $arguments -WindowStyle Hidden
    return
}
try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    . "$appRoot/Model/SystemSettings.ps1"
    $script:config=Read-SystemConfiguration
    . "$appRoot/Services/InstallationSecurity.ps1"
    Initialize-InstallationSecurity
    . "$appRoot/Model/Store.ps1"
    . "$appRoot/Services/Browser.ps1"
    . "$appRoot/Services/BrowserTabs.ps1"
    . "$appRoot/Services/Downloads.ps1"
    . "$appRoot/Services/ImageCapture.ps1"
    . "$appRoot/Services/ButtonDesign.ps1"
    . "$appRoot/Services/Dependencies.ps1"
    . "$appRoot/Services/CodexCli.ps1"
    . "$appRoot/Services/Summary.ps1"
    . "$appRoot/Services/AiChatLinks.ps1"
    . "$appRoot/Services/Reset.ps1"
    . "$appRoot/Services/Updates.ps1"
    . "$appRoot/Controller/Main.ps1"
    $script:startupWindow=[Windows.Markup.XamlReader]::Parse('<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Title="起動準備中" Width="480" Height="170" WindowStartupLocation="CenterScreen" WindowStyle="None" ResizeMode="NoResize" ShowInTaskbar="True"><Border BorderBrush="#CCCCCC" BorderThickness="1" Padding="24"><StackPanel><TextBlock Text="セットアップ・起動準備を行っています" FontSize="18"/><TextBlock Text="必要な部品がない場合は、導入の許可を確認します。しばらくお待ちください。" TextWrapping="Wrap" Margin="0,12,0,12"/><ProgressBar Height="10" IsIndeterminate="True" Foreground="Green"/></StackPanel></Border></Window>')
    $script:startupFailure=$null
    $script:startupCancelled=$false
    $startupWindow.add_ContentRendered({
        $startupWindow.Dispatcher.BeginInvoke([Action]{
            try { Start-CraftableBrowser }
            catch { $script:startupFailure=$_; $startupWindow.Close() }
        },[Windows.Threading.DispatcherPriority]::Background) | Out-Null
    })
    [void]$startupWindow.ShowDialog()
    if ($script:startupCancelled) { return }
    if ($script:startupFailure) { throw $startupFailure }
} catch {
    $message = $_.Exception.ToString() + "`n" + $_.ScriptStackTrace
    # Fixed fallback is necessary when configuration itself cannot be loaded.
    $errorPath=Join-Path $appRoot 'Logs/startup-error.log'
    if ($script:config -and (Get-Command Get-StartupErrorPath -ErrorAction SilentlyContinue)) {
        try { $errorPath=Get-StartupErrorPath } catch { }
    }
    [IO.Directory]::CreateDirectory((Split-Path $errorPath -Parent)) | Out-Null
    $message | Set-Content -LiteralPath $errorPath -Encoding utf8
    [System.Windows.MessageBox]::Show($message, '起動できませんでした') | Out-Null
    throw
}










param([ValidateSet(-1,0,1)][int]$ShiftAtLaunch=-1)
$ErrorActionPreference='Stop'
function Find-PowerShell7 {
    param($Settings)
    $candidates=New-Object 'System.Collections.Generic.List[string]'
    foreach($dir in $Settings.searchDirectories){
        $expanded=[Environment]::ExpandEnvironmentVariables($dir)
        $candidates.Add((Join-Path $expanded 'pwsh.exe'))
    }
    $command=Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if($command){$candidates.Add($command.Source)}
    foreach($path in ($candidates | Select-Object -Unique)){
        if(!(Test-Path -LiteralPath $path -PathType Leaf)){continue}
        try{
            $info=New-Object Diagnostics.ProcessStartInfo
            $info.FileName=$path
            $info.Arguments='-NoLogo -NoProfile -NonInteractive -Command "exit [int]($PSVersionTable.PSVersion.Major -ne 7)"'
            $info.UseShellExecute=$false;$info.CreateNoWindow=$true
            $p=[Diagnostics.Process]::Start($info)
            try{
                if(!$p.WaitForExit($Settings.probeTimeoutMilliseconds)){$p.Kill();continue}
                if($p.ExitCode -eq 0){return $path}
            }finally{$p.Dispose()}
        }catch{}
    }
    return $null
}
function Get-PowerShellAssetName([string]$Version,[string]$Architecture){
    if($Version -notmatch '^7\.\d+\.\d+$'){throw 'PowerShellの安定版を確認できませんでした。'}
    if($Architecture -notin @('AMD64','ARM64','x86')){throw '未対応のCPUです。'}
    $arch=@{AMD64='x64';ARM64='arm64';x86='x86'}[$Architecture]
    return "PowerShell-$Version-win-$arch.msi"
}
function Assert-PowerShellDownloadUrl([string]$Url) {
    if($Url -notmatch '^https://github\.com/PowerShell/PowerShell/releases/download/v7\.\d+\.\d+/PowerShell-7\.\d+\.\d+-win-(x64|x86|arm64)\.msi$'){
        throw '公式のPowerShell配布URLを確認できませんでした。'
    }
}
function Assert-MicrosoftInstaller([string]$Path) {
    $signature=Get-AuthenticodeSignature -LiteralPath $Path
    if($signature.Status -ne 'Valid' -or !$signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)'){
        throw 'インストーラーのMicrosoft署名を検証できませんでした。実行を中止しました。'
    }
}
Add-Type -AssemblyName System.Windows.Forms
if($ShiftAtLaunch -eq -1){$ShiftAtLaunch=[int](([Windows.Forms.Control]::ModifierKeys -band [Windows.Forms.Keys]::Shift) -ne 0)}
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$form=$null;$client=$null;$work=$null;$installer=$null
try {
    $settings=Get-Content (Join-Path $PSScriptRoot 'bootstrap.json') -Raw|ConvertFrom-Json
    foreach($key in @('probeTimeoutMilliseconds','downloadPollMilliseconds','installerPollMilliseconds')){
        $v=$settings.$key
        if(($v -isnot [int] -and $v -isnot [long]) -or $v -lt 1 -or $v -gt [int]::MaxValue){throw "設定 $key は正の整数で指定してください。"}
    }
    $pwsh=Find-PowerShell7 $settings
    if(!$pwsh){
        $answer=[Windows.Forms.MessageBox]::Show(
            '動作に必要なPowerShell 7がありません。Microsoft公式のインストーラーをダウンロードして、セットアップを開始しますか？ 「いいえ」を選ぶと、取得せずに起動を終了します。インターネット接続が必要です。セットアップ画面でインストールを完了してください。管理者の許可を求められる場合があります。',
            '初回起動の準備','YesNo','Question','Button2')
        if($answer -ne 'Yes'){exit 0}
        $form=New-Object Windows.Forms.Form
        $form.Text='初回起動の準備';$form.Width=490;$form.Height=160
        $form.StartPosition='CenterScreen';$form.ControlBox=$false
        $label=New-Object Windows.Forms.Label
        $label.Text='PowerShell 7の公式配布情報を確認しています…'
        $label.SetBounds(20,20,440,45);$form.Controls.Add($label)
        $bar=New-Object Windows.Forms.ProgressBar
        $bar.Style='Marquee';$bar.SetBounds(20,75,440,18);$form.Controls.Add($bar)
        $form.Show();[Windows.Forms.Application]::DoEvents()
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        $releases=Invoke-RestMethod -Uri $settings.releaseApi -Headers @{'User-Agent'='KijitamaCraftableBrowser'} -TimeoutSec $settings.metadataTimeoutSeconds
        $release=@($releases | Where-Object {
            !$_.draft -and !$_.prerelease -and $_.tag_name -match ('^v'+[regex]::Escape($settings.releaseLine)+'\.\d+$')
        } | Sort-Object { [version]($_.tag_name -replace '^v','') } -Descending | Select-Object -First 1)
        if($release.Count -ne 1){throw '対応する安定版の配布情報が見つかりませんでした。'}
        $release=$release[0]
        $arch=$env:PROCESSOR_ARCHITEW6432
        if(!$arch){$arch=$env:PROCESSOR_ARCHITECTURE}
        $name=Get-PowerShellAssetName ($release.tag_name -replace '^v','') $arch
        $asset=@($release.assets|Where-Object name -EQ $name)
        if($asset.Count -ne 1){throw 'このPC向けのインストーラーが見つかりませんでした。'}
        Assert-PowerShellDownloadUrl $asset[0].browser_download_url
        $work=Join-Path ([IO.Path]::GetTempPath()) ('KCB-Setup-'+[Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($work)
        $installer=Join-Path $work $name
        $label.Text='PowerShell 7をダウンロードしています…'
        $client=New-Object Net.WebClient
        $task=$client.DownloadFileTaskAsync([Uri]$asset[0].browser_download_url,$installer)
        $deadline=[DateTime]::UtcNow.AddSeconds($settings.downloadTimeoutSeconds)
        while(!$task.IsCompleted){
            if([DateTime]::UtcNow -gt $deadline){$client.CancelAsync();throw 'ダウンロードが時間切れになりました。'}
            [Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds $settings.downloadPollMilliseconds
        }
        $task.GetAwaiter().GetResult()
        $label.Text='Microsoftの署名を検証しています…';[Windows.Forms.Application]::DoEvents()
        Assert-MicrosoftInstaller $installer
        $label.Text='セットアップ画面でインストールを完了してください。'
        $process=Start-Process -FilePath (Join-Path $env:WINDIR 'System32/msiexec.exe') -ArgumentList @('/i',('"'+$installer+'"'),'/norestart') -PassThru
        try{
            while(!$process.HasExited){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds $settings.installerPollMilliseconds}
            if($process.ExitCode -eq 1602){exit 0}
            if($process.ExitCode -notin @(0,3010)){throw "インストールが完了しませんでした（コード：$($process.ExitCode)）。"}
        }finally{$process.Dispose()}
        foreach($key in @('probeTimeoutMilliseconds','downloadPollMilliseconds','installerPollMilliseconds')){
        $v=$settings.$key
        if(($v -isnot [int] -and $v -isnot [long]) -or $v -lt 1 -or $v -gt [int]::MaxValue){throw "設定 $key は正の整数で指定してください。"}
    }
    $pwsh=Find-PowerShell7 $settings
        if(!$pwsh){throw 'PowerShell 7を検出できません。PCを再起動してからアプリを起動してください。'}
    }
    if($form){$form.Close();$form.Dispose();$form=$null}
    $launcher=Get-Content (Join-Path $PSScriptRoot 'launcher.json') -Raw|ConvertFrom-Json
    $scriptPath=[IO.Path]::GetFullPath((Join-Path $root $launcher.script))
    if(!$scriptPath.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or !(Test-Path -LiteralPath $scriptPath -PathType Leaf)){
        throw 'アプリの起動先が不正です。'
    }
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$pwsh
    $info.Arguments='-NoLogo -NoProfile -STA -WindowStyle Hidden -File "'+$scriptPath+'"'
    $info.Arguments+=' -ShiftAtLaunch '+$ShiftAtLaunch
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.WorkingDirectory=$root
    $app=[Diagnostics.Process]::Start($info)
    $app.Dispose()
} catch {
    if($form){$form.Close()}
    [void][Windows.Forms.MessageBox]::Show(
        ($_.Exception.Message+[Environment]::NewLine+'導入できない場合はMicrosoft公式案内からPowerShell 7をインストールし、起動し直してください。'+[Environment]::NewLine+$settings.helpUrl),
        '起動準備を完了できませんでした','OK','Error')
    exit 1
} finally {
    if($client){$client.Dispose()}
    if($form){$form.Dispose()}
    if($work -and $installer -and (Test-Path -LiteralPath $installer)){Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue}
    if($work -and (Test-Path -LiteralPath $work)){try{[IO.Directory]::Delete($work)}catch{}}
}

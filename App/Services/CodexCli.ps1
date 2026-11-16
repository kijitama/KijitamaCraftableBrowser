function Find-CodexCli {
    $cmd=Get-Command codex.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($dir in $config.codexCli.searchDirectories) {
        $path=[Environment]::ExpandEnvironmentVariables($dir)
        if (Test-Path -LiteralPath $path) {
            $found=Get-ChildItem -LiteralPath $path -Filter codex.exe -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($found) { return $found.FullName }
        }
    }
    throw 'Codex CLIが見つかりません。「参照」でcodex.exeを選択してください。'
}
function Start-CodexCheck {
    Assert-AiEnabled
    if ($script:codexProcess) { return }
    $path=$ui.CodexPath.Text.Trim().Trim('"')
    if (!(Test-Path -LiteralPath $path -PathType Leaf) -or [IO.Path]::GetExtension($path) -ne '.exe') { throw 'CLIのcodex.exeを指定してください。' }
    $config.codexCli.path=$path
    Save-AppPreferences
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$path
    $info.ArgumentList.Add('login'); $info.ArgumentList.Add('status')
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $script:codexProcess=[Diagnostics.Process]::new(); $codexProcess.StartInfo=$info
    try {
        [void]$codexProcess.Start()
        $script:codexOutput=$codexProcess.StandardOutput.ReadToEndAsync()
        $script:codexError=$codexProcess.StandardError.ReadToEndAsync()
        $script:codexStarted=[DateTime]::UtcNow
        $ui.CodexProgress.Visibility='Visible'; $ui.CheckCodex.IsEnabled=$false
        $ui.CodexStatus.Text='接続確認中…'
    } catch { $codexProcess.Dispose(); $script:codexProcess=$null; throw }
}
function Update-CodexCheck {
    if (!$script:codexProcess) { return }
    try {
        if (!$codexProcess.HasExited) {
            if (([DateTime]::UtcNow-$codexStarted).TotalSeconds -lt $config.codexCli.timeoutSeconds) { return }
            $codexProcess.Kill($true)
            $ui.CodexStatus.Text='NG：確認がタイムアウトしました。'
        } else {
            if (!$codexOutput.IsCompleted -or !$codexError.IsCompleted) { return }
            $output=$codexOutput.GetAwaiter().GetResult()+$codexError.GetAwaiter().GetResult()
            if ($codexProcess.ExitCode -eq 0 -and $output -match 'Logged in') {
                $ui.CodexStatus.Text='OK：CLIを起動でき、ログイン済みです。（AI応答・ネットワーク疎通は未確認）'
            } else { $ui.CodexStatus.Text='NG：ログイン状態を確認できません。CLIのパスとログイン状態を確認してください。' }
        }
    } catch { $ui.CodexStatus.Text='NG：接続確認に失敗しました。' }
    $codexProcess.Dispose(); $script:codexProcess=$null
    $ui.CodexProgress.Visibility='Collapsed'; $ui.CheckCodex.IsEnabled=$true
}


function Test-AiEnabled { return ($config.codexCli.enabled -eq $true) }
function Assert-AiEnabled {
    if (!(Test-AiEnabled)) { throw 'AI機能は無効です。設定画面でCodex CLI接続を有効にしてください。' }
}
function Update-AiUsageUi {
    $enabled=Test-AiEnabled
    $ui.AiSupport.IsEnabled=$true
    Update-PageAnalysisAvailability
    $ui.CheckCodex.IsEnabled=$enabled -and !$script:codexProcess
    $ui.CodexEnabled.IsChecked=$enabled
    $ui.CodexDisabled.IsChecked=!$enabled
    if(!$enabled){$ui.CodexStatus.Text='無効：AI機能と接続確認は実行しません。'}
}
function Set-AiUsage([bool]$Enabled) {
    $config.codexCli | Add-Member -NotePropertyName enabled -NotePropertyValue $Enabled -Force
    if(!$Enabled){
        if($script:summaryStage){Stop-PageSummary 'AI機能が無効になったため中止しました。'}
        if($script:codexProcess){
            if(!$codexProcess.HasExited){$codexProcess.Kill($true)}
            $codexProcess.Dispose();$script:codexProcess=$null
            $ui.CodexProgress.Visibility='Collapsed'
        }
    }
    Update-AiUsageUi
    Save-AppPreferences
    if($Enabled){$ui.CodexStatus.Text='有効：未確認。「接続確認」で確認できます。'}
    $ui.SettingsStatus.Text='AI機能の有効／無効を保存しました。'
}
function Initialize-AiUsage {
    foreach($name in @('CodexEnabled','CodexDisabled')){$ui[$name]=$window.FindName($name)}
    Update-AiUsageUi
    $ui.CodexEnabled.add_Click({Invoke-SettingsAction {Set-AiUsage $true}})
    $ui.CodexDisabled.add_Click({Invoke-SettingsAction {Set-AiUsage $false}})
}




param([int]$ParentProcessId,[ValidateSet('keepFiles','complete','pristine')][string]$Mode='keepFiles')
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
. "$PSScriptRoot/Reset.ps1"
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
try {
    $appRoot=Join-Path $root 'App'
    . "$appRoot/Model/SystemSettings.ps1"
    $settings=Read-SystemConfiguration
    $parent=Get-Process -Id $ParentProcessId -ErrorAction SilentlyContinue
    if ($parent -and !$parent.WaitForExit([int]$settings.reset.parentExitTimeoutMilliseconds)) { throw 'アプリの終了を確認できません。初期化は実行していません。' }
    $destination=$null
    for ($attempt=0;$attempt -lt $settings.reset.retryCount;$attempt++) {
        try { Invoke-FactoryReset $root $Mode; break }
        catch { if ($attempt -eq ($settings.reset.retryCount-1)) { throw }; Start-Sleep -Seconds $settings.reset.retryDelaySeconds }
    }
    $message=if($Mode -eq 'pristine'){'完全初期化が完了しました。取得済み部品・利用データ・保存ファイル・過去の配布物を削除しました。次回起動時は初回セットアップを行います。配布する場合は再起動前の状態で配布してください。'}elseif($Mode -eq 'complete'){'すべてのデータの削除が完了しました。アプリのユーザーデータ、標準保存先のPDF・画像、ログ・検証データを削除し、設定を初期値に戻しました。アプリ本体とアクセス権の保護は保持しています。'}else{'アプリの初期化が完了しました。プロフィール・履歴・スキ・AI一時データなどを削除しました。PDF・画像は保持しています。保存先設定は初期値に戻ります。'}
    [Windows.MessageBox]::Show(($message+$(if($Mode -ne 'pristine'){' アプリを再起動してください。'}else{''})),'初期化完了')|Out-Null
} catch {
    [Windows.MessageBox]::Show(('初期化を完了できませんでした。'+"`n"+$_.Exception.Message),'初期化失敗')|Out-Null
}

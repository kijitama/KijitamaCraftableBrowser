function Assert-ConfigLeafName([string]$Value,[string]$Key) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -in @('.','..') -or $Value.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $Value.EndsWith('.') -or $Value.EndsWith(' ')) {
        throw "設定 $Key は単独のファイル名・フォルダー名で指定してください。"
    }
}
function Get-ConfiguredLogDirectory($Settings) {
    $root=Split-Path $appRoot -Parent
    $base=[IO.Path]::GetFullPath((Join-Path $appRoot 'Logs')).TrimEnd('\')
    $path=[IO.Path]::GetFullPath((Join-Path $root ([string]$Settings.storage.logsDirectory)))
    # Reset and ACL protection own App/Logs. Do not permit an arbitrary external log location.
    if (!$path.Equals($base,[StringComparison]::OrdinalIgnoreCase) -and !$path.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)) {
        throw 'storage.logsDirectory は App/Logs またはその配下を指定してください。'
    }
    return $path
}
function Read-SystemConfiguration {
    $value=Get-Content -LiteralPath (Join-Path $appRoot 'Config/system.json') -Raw | ConvertFrom-Json
    foreach ($key in @('webProfilesDirectory','summaryWorkDirectory','startupErrorFile')) { Assert-ConfigLeafName ([string]$value.storage.$key) "storage.$key" }
    if ($value.storage.webProfilesDirectory -ieq $value.storage.summaryWorkDirectory -or $value.storage.webProfilesDirectory -ieq $value.history.directory -or $value.storage.webProfilesDirectory -ieq $value.favorites.directory -or $value.storage.summaryWorkDirectory -ieq $value.history.directory -or $value.storage.summaryWorkDirectory -ieq $value.favorites.directory) { throw 'データ保存フォルダー名は用途ごとに分けてください。' }
    $null=Get-ConfiguredLogDirectory $value
    $integers=@{
        'updates.maxMessageCharacters'=$value.updates.maxMessageCharacters
        'updates.minimumResponseBytes'=$value.updates.minimumResponseBytes
        'exports.titleMaxCharacters'=$value.exports.titleMaxCharacters
        'exports.uniqueSuffixLength'=$value.exports.uniqueSuffixLength
        'timing.pollMilliseconds'=$value.timing.pollMilliseconds
        'timing.dependencyPollMilliseconds'=$value.timing.dependencyPollMilliseconds
        'reset.parentExitTimeoutMilliseconds'=$value.reset.parentExitTimeoutMilliseconds
        'reset.retryCount'=$value.reset.retryCount
        'reset.retryDelaySeconds'=$value.reset.retryDelaySeconds
        'favorites.limitRange.minimum'=$value.favorites.limitRange.minimum
        'favorites.limitRange.maximum'=$value.favorites.limitRange.maximum
    }
    foreach ($entry in $integers.GetEnumerator()) {
        if (($entry.Value -isnot [int] -and $entry.Value -isnot [long]) -or $entry.Value -lt 1 -or $entry.Value -gt [int]::MaxValue) { throw "設定 $($entry.Key) は正の整数で指定してください。" }
    }
    if ($value.exports.uniqueSuffixLength -gt ([guid]::Empty.ToString('N').Length)) { throw 'ファイル名の識別文字数がGUIDの長さを超えています。' }
    if ($value.favorites.limitRange.minimum -gt $value.favorites.limitRange.maximum) { throw 'スキ上限の最小値と最大値が逆転しています。' }
    if ([string]::IsNullOrWhiteSpace($value.exports.timestampFormat)) { throw 'ファイル名の日時書式を指定してください。' }
    try { $stamp=[DateTime]::Now.ToString([string]$value.exports.timestampFormat,[Globalization.CultureInfo]::InvariantCulture); Assert-ConfigLeafName $stamp 'exports.timestampFormat' }
    catch { throw 'ファイル名の日時書式が不正です。パス区切りなどは使用できません。' }
    $opacity=$value.ui.actionToast.opacity
    if (($opacity -isnot [double] -and $opacity -isnot [decimal] -and $opacity -isnot [int] -and $opacity -isnot [long]) -or [double]::IsNaN([double]$opacity) -or $opacity -lt 0 -or $opacity -gt 1) {
        throw 'ui.actionToast.opacity は0～1の数値で指定してください（0：透明、1：不透明）。'
    }
    foreach($key in @('common','credibility','freshness')){
        if([string]::IsNullOrWhiteSpace([string]$value.ai.summary.optionalPrompts.$key)){throw "ai.summary.optionalPrompts.$key を指定してください。"}
    }
    Assert-ImageSettings $value.images
    return $value
}
function Get-StartupErrorPath {
    Assert-ConfigLeafName ([string]$config.storage.startupErrorFile) 'storage.startupErrorFile'
    Join-Path (Get-ConfiguredLogDirectory $config) $config.storage.startupErrorFile
}
function New-ExportFileName([string]$Title,[ValidateSet('.pdf','.png','.jpg','.webp')][string]$Extension) {
    $Title=$Title -replace '[\x00-\x1f<>:"/\\|?*]','_'
    if ([string]::IsNullOrWhiteSpace($Title)) { $Title='page' }
    if ($Title.Length -gt $config.exports.titleMaxCharacters) { $Title=$Title.Substring(0,[int]$config.exports.titleMaxCharacters) }
    $stamp=[DateTime]::Now.ToString([string]$config.exports.timestampFormat,[Globalization.CultureInfo]::InvariantCulture)
    $suffix=[Guid]::NewGuid().ToString('N').Substring(0,[int]$config.exports.uniqueSuffixLength)
    $name=$stamp+'_'+$Title+'_'+$suffix+$Extension
    Assert-ConfigLeafName $name 'exports'
    return $name
}


function Assert-ImageSettings($Settings) {
    if($Settings.format -notin @('png','jpg','webp') -or $Settings.splitLarge -isnot [bool]){throw '撮影画像の形式・分割設定が不正です。'}
    foreach($key in @('maxHeight','maxPixels','timeoutSeconds','splitHeight','maxParts','quality')){
        $v=$Settings.$key
        if(($v -isnot [int] -and $v -isnot [long]) -or $v -lt 1 -or $v -gt [int]::MaxValue){throw "images.$key は正の整数で指定してください。"}
    }
    if($Settings.quality -gt 100){throw '画像品質は1～100で指定してください。'}
    $overlap=$Settings.overlapPixels
    if(($overlap -isnot [int] -and $overlap -isnot [long]) -or $overlap -lt 0 -or $overlap -ge [math]::Min($Settings.splitHeight,$Settings.maxHeight)){throw '分割画像の重なり幅は分割高さ未満の0以上の整数で指定してください。'}
}

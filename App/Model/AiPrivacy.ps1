function ConvertTo-AiBlockedDomain([string]$Value) {
    $value=$Value.Trim()
    if($value.EndsWith('.')){$value=$value.Substring(0,$value.Length-1)}
    if(!$value -or $value -match '[\s/:\\@?#*]'){throw '禁止ドメインはURLではなく、example.comのように1行に1件入力してください。'}
    try {$value=[Globalization.IdnMapping]::new().GetAscii($value).ToLowerInvariant()} catch {throw '禁止ドメインの形式が不正です。'}
    if([Uri]::CheckHostName($value) -notin @([UriHostNameType]::Dns,[UriHostNameType]::IPv4)){throw '禁止ドメインの形式が不正です。'}
    foreach($label in $value.Split('.')) { if($label -notmatch '^(?!-)[a-z0-9-]{1,63}(?<!-)$'){throw '禁止ドメインの形式が不正です。'} }
    return $value
}

function Get-AiBlockSubdomains {
    # Keep the previous protection when loading a configuration from an older version.
    if($config.ai.blockSubdomains -is [bool]) { return $config.ai.blockSubdomains }
    return $true
}

function Assert-AiPageAllowed([string]$Url) {
    $uri=$null
    if(![Uri]::TryCreate($Url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin @('https','http') -or !$uri.Host){throw 'サイトのドメインを確認できないため、AIへの送信を拒否しました。'}
    $hostName=$uri.IdnHost.TrimEnd('.').ToLowerInvariant()
    foreach($entry in @($config.ai.blockedDomains)) {
        if([string]::IsNullOrWhiteSpace([string]$entry)){continue}
        $domain=ConvertTo-AiBlockedDomain $entry
        if($hostName -eq $domain -or ((Get-AiBlockSubdomains) -and $hostName.EndsWith('.'+$domain,[StringComparison]::OrdinalIgnoreCase))) {
            throw 'このサイトは要約禁止ドメインです。URL・タイトル・本文をAIへ送信しません。'
        }
    }
}

function Save-AiBlockedDomains([string]$Text,[bool]$IncludeSubdomains=$true) {
    $domains=@($Text -split '\r?\n' | Where-Object { ![string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ConvertTo-AiBlockedDomain $_ } | Select-Object -Unique)
    $path=Join-Path $appRoot 'Config/system.json'
    $latest=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
    $latest.ai|Add-Member -Force NoteProperty blockedDomains $domains
    $latest.ai|Add-Member -Force NoteProperty blockSubdomains $IncludeSubdomains
    Save-JsonFile $latest $path
    $config.ai|Add-Member -Force NoteProperty blockedDomains $domains
    $config.ai|Add-Member -Force NoteProperty blockSubdomains $IncludeSubdomains
}

function Remove-AiUrlText([string]$Text,[string]$PageUrl) {
    if($PageUrl){$Text=$Text.Replace($PageUrl,'[URL省略]')}
    return [regex]::Replace($Text,'(?i)(?:https?://|www\.)[^\s<>"「」]+','[URL省略]')
}

function Get-PageAnalysisPayload($Page) {
    Assert-AiPageAllowed $Page.url
    # Allowlist fields; never serialize the source address or extraction result directly.
    return [ordered]@{
        title=Remove-AiUrlText ([string]$Page.title) ([string]$Page.url)
        text=Remove-AiUrlText ([string]$Page.text) ([string]$Page.url)

    }
}


function Initialize-DefaultProfile {
    $changed=$false
    $defaultId=if ($profiles.PSObject.Properties['defaultId']) { [string]$profiles.defaultId } else { '' }
    $entry=@($profiles.items | Where-Object id -eq $defaultId) | Select-Object -First 1
    if (!$entry) {
        $entry=@($profiles.items | Where-Object id -eq 'default') | Select-Object -First 1
        if (!$entry) { $entry=@($profiles.items | Where-Object name -eq 'メイン') | Select-Object -First 1 }
        if (!$entry) {
            $entry=[pscustomobject]@{id=[Guid]::NewGuid().ToString();name='デフォルト'}
            $profiles.items=@($entry)+@($profiles.items)
        }
        $profiles | Add-Member -NotePropertyName defaultId -NotePropertyValue $entry.id -Force
        $changed=$true
    }
    if ($entry.name -eq 'メイン') { $entry.name='デフォルト'; $changed=$true }
    if ($changed) { Save-JsonFile $profiles $profilesPath }
}
function Test-DefaultProfile([string]$Id) {
    return ($Id -eq $profiles.defaultId)
}
function Resolve-AppPath([string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return $Path }
    return [IO.Path]::GetFullPath((Join-Path (Split-Path $appRoot -Parent) $Path))
}
function Save-AppPreferences {
    $path=Join-Path $appRoot 'Config/system.json'
    $latest=Get-Content $path -Raw | ConvertFrom-Json
    $latest.ui.historyCollapsed=$script:historyCollapsed
    $latest | Add-Member -NotePropertyName favorites -NotePropertyValue $config.favorites -Force
    $latest | Add-Member -NotePropertyName codexCli -NotePropertyValue $config.codexCli -Force
    $latest | Add-Member -NotePropertyName pdf -NotePropertyValue $config.pdf -Force
    Save-JsonFile $latest $path
}
function Save-JsonFile($Value, [string]$Path) {
    $temp = $Path + '.tmp'
    ConvertTo-Json -InputObject $Value -Depth 15 | Set-Content -LiteralPath $temp -Encoding utf8
    [IO.File]::Move($temp, $Path, $true)
}
function Save-HomeUrl([string]$Value) {
    $Value=$Value.Trim()
    if (!(Test-AllowedUrl $Value)) { throw '閲覧が許可されたURLを入力してください。https://とドメイン制限の設定を確認してください。' }
    $path=Join-Path $appRoot 'Config/system.json'
    $latest=Get-Content $path -Raw | ConvertFrom-Json
    $latest.browser.homeUrl=$Value
    Save-JsonFile $latest $path
    $config.browser.homeUrl=$Value
}
function Initialize-Store {
    $script:config = Read-SystemConfiguration
    if ($config.schemaVersion -ne '1.0' -or $config.browser.navigationPolicy.defaultAction -ne 'deny' -or !$config.browser.navigationPolicy.allowedDomains) { throw 'システム設定が不正です。' }
    $script:dataDir = Resolve-AppPath $config.storage.dataDirectory
    [IO.Directory]::CreateDirectory($dataDir) | Out-Null
    $script:profilesPath = Join-Path $dataDir $config.storage.profilesFile
    if (Test-Path $profilesPath) { $script:profiles = Get-Content $profilesPath -Raw | ConvertFrom-Json }
    else { $script:profiles = [pscustomobject]@{activeId='default';items=@([pscustomobject]@{id='default';name='デフォルト'})}; Save-JsonFile $profiles $profilesPath }
    Initialize-DefaultProfile
    foreach ($p in $profiles.items) { if ($p.id -notmatch '^[a-zA-Z0-9-]+$') { throw 'プロフィールIDが不正です。' } }
    if (!( $profiles.items | Where-Object id -eq $profiles.activeId)) { throw '使用中のプロフィールが見つかりません。' }
}
function Test-AllowedFrameUrl([string]$Url) {
    if ($Url -in @($config.browser.navigationPolicy.allowedInternalFrameUrls)) { return $true }
    return (Test-AllowedUrl $Url)
}
function Load-History {
    if ($config.history.maxEntries -isnot [long] -and $config.history.maxEntries -isnot [int]) { throw '履歴件数は整数で指定してください。' }
    if ($config.history.maxEntries -lt 1) { throw '履歴件数は1以上で指定してください。' }
    $dir=Join-Path $dataDir $config.history.directory
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $script:historyPath=Join-Path $dir ($profiles.activeId+'.json')
    $script:historyItems=@()
    if (Test-Path $historyPath) { $script:historyItems=@(Get-Content $historyPath -Raw | ConvertFrom-Json | Select-Object -First $config.history.maxEntries) }
}
function Load-Favorites {
    if ($config.favorites.maxEntries -isnot [long] -and $config.favorites.maxEntries -isnot [int]) { throw 'スキ上限は整数で指定してください。' }
    if ($config.favorites.maxEntries -lt $config.favorites.limitRange.minimum -or $config.favorites.maxEntries -gt $config.favorites.limitRange.maximum) { throw "スキ上限は$($config.favorites.limitRange.minimum)～$($config.favorites.limitRange.maximum)で指定してください。" }
    $dir=Join-Path $dataDir $config.favorites.directory
    [IO.Directory]::CreateDirectory($dir)|Out-Null
    $script:favoritesPath=Join-Path $dir ($profiles.activeId+'.json')
    $script:favoriteItems=@()
    if (Test-Path $favoritesPath) { $script:favoriteItems=@(Get-Content $favoritesPath -Raw|ConvertFrom-Json) }
}
function Add-Favorite([string]$Url,[string]$Title) {
    if (!(Test-AllowedUrl $Url)) { throw 'このページは登録できません。' }
    if (@($favoriteItems | Where-Object url -CEQ $Url).Count) { return $false }
    if ($favoriteItems.Count -ge $config.favorites.maxEntries) { throw 'スキの上限です。削除するか設定画面で上限を増やしてください。' }
    if (!$Title) { $Title=$Url }
    $next=@([pscustomobject]@{id=[guid]::NewGuid().ToString();url=$Url;title=$Title;addedAt=[DateTime]::UtcNow.ToString('o')})+@($favoriteItems)
    Save-JsonFile @($next) $favoritesPath
    $script:favoriteItems=$next
    return $true
}
function Remove-Favorite([string]$Id) {
    $next=@($favoriteItems|Where-Object id -ne $Id)
    Save-JsonFile @($next) $favoritesPath
    $script:favoriteItems=$next
}
function Record-History([string]$Url,[string]$Title) {
    if (!(Test-AllowedUrl $Url)) { return }
    if ([string]::IsNullOrWhiteSpace($Title)) { $Title=$Url }
    $item=[pscustomobject]@{url=$Url;title=$Title;visitedAt=[DateTime]::UtcNow.ToString('o')}
    $script:historyItems=@(@($item)+@($script:historyItems | Where-Object { $_.url -cne $Url }) | Select-Object -First $config.history.maxEntries)
    Save-JsonFile @($historyItems) $historyPath
}
function Remove-ProfileEntry([string]$Id) {
    if (Test-DefaultProfile $Id) { throw 'デフォルトのプロフィールは削除できません。' }
    $remaining=@($profiles.items | Where-Object id -ne $Id)
    if ($remaining.Count -eq $profiles.items.Count) { throw 'プロフィールが見つかりません。' }
    if (!$remaining.Count) { throw 'デフォルトのプロフィールが見つかりません。' }
    $next=[pscustomobject]@{activeId=$profiles.activeId;defaultId=$profiles.defaultId;items=$remaining}
    if ($next.activeId -eq $Id) { $next.activeId=$remaining[0].id }
    Save-JsonFile $next $profilesPath
    $script:profiles=$next
}
function Rename-ProfileEntry([string]$Id,[string]$Name) {
    $Name=$Name.Trim()
    if (!$Name) { throw 'プロフィール名を入力してください。' }
    if (@($profiles.items | Where-Object { $_.id -ne $Id -and $_.name -eq $Name }).Count) { throw '同じ名前のプロフィールがあります。' }
    if (!@($profiles.items | Where-Object id -eq $Id).Count) { throw 'プロフィールが見つかりません。' }
    $next=$profiles | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    ($next.items | Where-Object id -eq $Id).name=$Name
    Save-JsonFile $next $profilesPath
    $script:profiles=$next
}
function Clear-AllHistory {
    $root=[IO.Path]::GetFullPath($dataDir).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    $dir=[IO.Path]::GetFullPath((Join-Path $dataDir $config.history.directory))
    if (!$dir.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)) { throw '履歴の保存先がデータフォルダー外です。' }
    if (Test-Path $dir) {
        if ((Get-Item -LiteralPath $dir).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '履歴の保存先にリンクは指定できません。' }
        foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File) {
            if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '履歴ファイルにリンクが含まれます。' }
            Save-JsonFile @() $file.FullName
        }
    }
    $script:historyItems=@()
}
function Test-AllowedUrl([string]$Url) {
    $uri = $null
    if (![Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return $false }
    if ($uri.Scheme -notin $config.browser.navigationPolicy.allowedSchemes -or $uri.UserInfo) { return $false }
    if ($config.browser.navigationPolicy.domainRestrictionEnabled -is [bool] -and $config.browser.navigationPolicy.domainRestrictionEnabled -eq $false) { return $true }
    $hostName = $uri.IdnHost.TrimEnd('.').ToLowerInvariant()
    foreach ($domain in $config.browser.navigationPolicy.allowedDomains) {
        $domain = $domain.ToLowerInvariant()
        if ($domain.StartsWith('*.')) {
            if ($hostName.EndsWith($domain.Substring(1)) -and $hostName.Length -gt $domain.Length - 1) { return $true }
        } elseif ($hostName -eq $domain) { return $true }
    }
    return $false
}


function Remove-HistoryEntry([string]$Url) {
    $next=@($script:historyItems | Where-Object { $_.url -cne $Url })
    Save-JsonFile $next $script:historyPath
    $script:historyItems=$next
}
function Remove-SavedListFile([string]$Path,[string]$Directory,[string[]]$Extension) {
    $full=[IO.Path]::GetFullPath($Path)
    $dir=[IO.Path]::GetFullPath((Resolve-AppPath $Directory)).TrimEnd('\','/')
    if (![string]::Equals([IO.Path]::GetDirectoryName($full),$dir,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($full) -notin $Extension) { throw '保存先の一覧にあるファイルだけを削除できます。' }
    if (!(Test-Path -LiteralPath $full -PathType Leaf)) { throw 'ファイルが見つかりません。一覧を更新してください。' }
    Remove-Item -LiteralPath $full -ErrorAction Stop
}
function Save-AiCharacterLimits([string]$SummaryValue) {
    $summaryLimit=0
    $min=[int]$config.ai.characterLimitRange.minimum
    $max=[int]$config.ai.characterLimitRange.maximum
    if (![int]::TryParse($SummaryValue.Trim(),[ref]$summaryLimit) -or $summaryLimit -lt $min -or $summaryLimit -gt $max) { throw "要約の文字数上限は$min～$maxの整数で入力してください。" }
    $path=Join-Path $appRoot 'Config/system.json'
    $latest=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
    $latest.ai.summary.maxCharacters=$summaryLimit
    Save-JsonFile $latest $path
    $config.ai.summary.maxCharacters=$summaryLimit
}

function Save-ExitConfirmationPreference([bool]$Skip) {
    $path=Join-Path $appRoot 'Config/system.json'
    $latest=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $latest.ui | Add-Member -NotePropertyName skipExitConfirmation -NotePropertyValue $Skip -Force
    Save-JsonFile $latest $path
    $config.ui | Add-Member -NotePropertyName skipExitConfirmation -NotePropertyValue $Skip -Force
}



function Get-ResetTargets([string]$Root,$Settings,[ValidateSet('keepFiles','complete','pristine')][string]$Mode='keepFiles') {
    $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    $targets=@('App/Data')
    if($Mode -in @('complete','pristine')) {
        $targets+=@('data/pdf','data/images')
    }
    if($Mode -eq 'pristine') {
        $targets+=@('App/Lib','App/Logs','App/startup-error.log','App/Config/system.json.tmp')
        Assert-PristineContents $rootFull $targets (Get-PreservedExportDirectories $rootFull $Settings)
    }
    # Custom locations require manual review rather than recursively deleting an arbitrary directory.
    $value=$Settings.storage.dataDirectory
    $resolved=if ([IO.Path]::IsPathRooted($value)) { [IO.Path]::GetFullPath($value) } else { [IO.Path]::GetFullPath((Join-Path $rootFull $value)) }
    $expected=[IO.Path]::GetFullPath((Join-Path $rootFull 'App/Data'))
    if (!$resolved.Equals($expected,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'データ保存先が標準以外です。App/Dataに戻してから実行してください。外部フォルダーは自動削除しません。'
    }
    foreach ($relative in $targets) {
        $path=[IO.Path]::GetFullPath((Join-Path $rootFull $relative))
        Assert-ResetPath $rootFull $path
        $path
    }
}
function Assert-ResetPath([string]$Root,[string]$Path) {
    $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    $full=[IO.Path]::GetFullPath($Path)
    if (!$full.StartsWith($rootFull+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '対象がアプリフォルダー外です。' }
    $cursor=$full
    while ($cursor.Length -ge $rootFull.Length) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'リンクを含む保存先は初期化できません。' }
        $cursor=Split-Path $cursor -Parent
    }
    if (Test-Path -LiteralPath $full -PathType Container) {
        foreach ($item in Get-ChildItem -LiteralPath $full -Force -Recurse) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '保存先にリンクが含まれています。初期化を中止しました。' }
        }
    }
}
function Invoke-FactoryReset([string]$Root,[ValidateSet('keepFiles','complete','pristine')][string]$Mode='keepFiles') {
    $settings=Get-Content (Join-Path $Root 'App/Config/system.json') -Raw | ConvertFrom-Json
    $defaults=Get-Content (Join-Path $Root 'App/Config/defaults.json') -Raw | ConvertFrom-Json
    if ($defaults.codexCli.path -or $defaults.storage.dataDirectory -ne 'App/Data' -or $defaults.pdf.outputDirectory -ne 'data/pdf') { throw '初期設定ファイルが不正です。' }
    $targets=@(Get-ResetTargets $Root $settings $Mode)
    $preserved=@(Get-PreservedExportDirectories $Root $settings)
    foreach ($relative in @('App/startup-error.log','App/Logs','App/Config/system.json.tmp')) {
        $path=Join-Path $Root $relative
        Assert-ResetPath $Root $path
        $targets+=$path
    }
    # All paths are validated before any deletion. Complete mode retains application code and dependencies.
    foreach ($target in $targets) {
        if (!(Test-Path -LiteralPath $target)) { continue }
        $files=if (Test-Path -LiteralPath $target -PathType Container) { @(Get-ChildItem -LiteralPath $target -File -Force -Recurse) } else { @(Get-Item -LiteralPath $target) }
        foreach ($file in $files) {
            if(Test-PreservedExportPath $file.FullName $preserved){continue}
            if ($Mode -eq 'keepFiles' -and $file.Extension.ToLowerInvariant() -in @('.pdf','.png','.jpg','.jpeg','.gif','.webp')) { continue }
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
        }
        if($Mode -in @('complete','pristine') -and (Test-Path -LiteralPath $target -PathType Container)) {
            foreach($directory in @(Get-ChildItem -LiteralPath $target -Directory -Force -Recurse | Sort-Object { $_.FullName.Length } -Descending)) {
                if(!@(Get-ChildItem -LiteralPath $directory.FullName -Force).Count){Remove-Item -LiteralPath $directory.FullName -Force -ErrorAction Stop}
            }
        }
    }
    if($Mode -eq 'pristine') {
        foreach($target in @($targets | Select-Object -Unique | Sort-Object { $_.Length } -Descending)) {
            if((Test-Path -LiteralPath $target -PathType Container) -and !@(Get-ChildItem -LiteralPath $target -Force).Count) { Remove-Item -LiteralPath $target -Force -ErrorAction Stop }
        }
    }
    $defaults | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $Root 'App/Config/system.json') -Encoding utf8
}



function Assert-PristineContents([string]$Root,[string[]]$Targets,[string[]]$Preserved=@()) {
    foreach($item in Get-ChildItem -LiteralPath $Root -Force -Recurse) {
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'リンクを含む配置先は完全初期化できません。'}
    }
    $manifest=Get-Content (Join-Path $Root 'App/Config/distribution-files.json') -Raw|ConvertFrom-Json
    $allowed=@($manifest.files | ForEach-Object { $_.Replace('\','/').ToLowerInvariant() })
    $extra=@()
    foreach($file in Get-ChildItem -LiteralPath $Root -File -Recurse -Force) {
        if(Test-PreservedExportPath $file.FullName $Preserved){continue}
        $relative=[IO.Path]::GetRelativePath($Root,$file.FullName).Replace('\','/')
        $removed=$false
        foreach($target in $Targets){$t=$target.Replace('\','/').TrimEnd('/');if($relative -ieq $t -or $relative.StartsWith($t+'/',[StringComparison]::OrdinalIgnoreCase)){$removed=$true;break}}
        if(!$removed -and $relative.ToLowerInvariant() -notin $allowed){$extra+=$relative}
    }
    if($extra.Count){throw ("配布対象外のファイルがあります。別の場所へ退避してから完全初期化してください。自動削除はしません。`n"+($extra -join "`n"))}
}

function Get-PreservedExportDirectories([string]$Root,$Settings) {
    foreach($entry in @(@{value=$Settings.pdf.outputDirectory;standard='data/pdf'},@{value=$Settings.images.outputDirectory;standard='data/images'})){
        $actual=if([IO.Path]::IsPathRooted($entry.value)){[IO.Path]::GetFullPath($entry.value).TrimEnd('\','/')}else{[IO.Path]::GetFullPath((Join-Path $Root $entry.value)).TrimEnd('\','/')}
        $standard=[IO.Path]::GetFullPath((Join-Path $Root $entry.standard)).TrimEnd('\','/')
        if(!$actual.Equals($standard,[StringComparison]::OrdinalIgnoreCase)){$actual}
    }
}
function Test-PreservedExportPath([string]$Path,[string[]]$Directories) {
    foreach($directory in $Directories){
        if($Path.Equals($directory,[StringComparison]::OrdinalIgnoreCase) -or $Path.StartsWith($directory+'\',[StringComparison]::OrdinalIgnoreCase)){return $true}
    }
    return $false
}

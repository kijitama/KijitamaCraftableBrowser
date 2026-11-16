function Get-InstallationPrincipals {
    @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
}

function Test-PrivateInstallationAccess([string]$Path,[switch]$AllowWebViewCapability) {
    $allowed=@(Get-InstallationPrincipals)
    $acl=Get-Acl -LiteralPath $Path -ErrorAction Stop
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $allowed) { return $false }
    $rules=$acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])
    foreach($rule in $rules) {
        if ($AllowWebViewCapability -and $rule.IdentityReference.Value -like 'S-1-15-3-*') { continue }
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $allowed) { return $false }
    }
    $current=$allowed[0]
    return (@($rules | Where-Object { $_.IdentityReference.Value -eq $current -and $_.AccessControlType -eq 'Allow' -and ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl }).Count -gt 0)
}

function Protect-PrivateInstallation([string]$Root) {
    $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    if ($rootFull -eq [IO.Path]::GetPathRoot($rootFull).TrimEnd('\','/') -or !(Test-Path -LiteralPath (Join-Path $rootFull 'App/Start.ps1') -PathType Leaf)) {
        throw 'アプリの配置先を確認できないためアクセス権を変更しません。'
    }
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $owner=(Get-Acl -LiteralPath $rootFull).GetOwner([Security.Principal.SecurityIdentifier])
    if ($owner.Value -ne $sid.Value) { throw 'このアプリフォルダーの所有者が現在のWindowsユーザーではありません。自分のユーザーフォルダーへ新しく展開してください。' }
    # Enumerate without following junctions or symlinks. Do not change any ACL until preflight completes.
    $items=[Collections.Generic.List[IO.FileSystemInfo]]::new()
    $pending=[Collections.Generic.Stack[string]]::new(); $pending.Push($rootFull)
    while($pending.Count) {
        $directory=Get-Item -LiteralPath $pending.Pop() -Force
        if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'リンクを含むアプリフォルダーは保護できません。通常のフォルダーへ配置してください。' }
        $items.Add($directory)
        foreach($item in Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction Stop) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'リンクを含むアプリフォルダーは保護できません。' }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) } else { $items.Add($item) }
        }
    }
    foreach($item in $items) {
        $isWebProfile=$item.FullName.StartsWith((Join-Path (Join-Path $rootFull $config.storage.dataDirectory) $config.storage.webProfilesDirectory).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)
        $acl=[IO.FileSystemAclExtensions]::GetAccessControl($item,([Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Owner))
        if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @(Get-InstallationPrincipals)) { $acl.SetOwner($sid) }
        foreach($existing in @($acl.GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier]))) {
            # Keep WebView2's existing sandbox capability grants, not ordinary user grants.
            if ($isWebProfile -and $existing.IdentityReference.Value -like 'S-1-15-3-*') { continue }
            $acl.RemoveAccessRuleSpecific($existing)
        }
        if ($item.FullName.TrimEnd('\','/') -eq $rootFull) {
            $acl.SetAccessRuleProtection($true,$false)
            foreach($principal in @(Get-InstallationPrincipals)) {
                $identity=[Security.Principal.SecurityIdentifier]::new($principal)
                $rule=[Security.AccessControl.FileSystemAccessRule]::new($identity,'FullControl','ContainerInherit, ObjectInherit','None','Allow')
                $acl.AddAccessRule($rule)
            }
        } else {
            # Discard old explicit grants; inherit the private parent's rules.
            $acl.SetAccessRuleProtection($false,$false)
        }
        try { [IO.FileSystemAclExtensions]::SetAccessControl($item,$acl) }
        catch { throw ('アクセス権の設定に失敗しました：'+$item.FullName+' : '+$_.Exception.Message) }
    }
    foreach($item in $items) {
        $isWebProfile=$item.FullName.StartsWith((Join-Path (Join-Path $rootFull $config.storage.dataDirectory) $config.storage.webProfilesDirectory).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)
        if (!(Test-PrivateInstallationAccess $item.FullName -AllowWebViewCapability:$isWebProfile)) { throw ('アクセス権を保護できませんでした：'+$item.FullName) }
    }
}

function Initialize-InstallationSecurity {
    $root=Split-Path $appRoot -Parent
    if (!(Test-PrivateInstallationAccess $root)) { Protect-PrivateInstallation $root }
    # Check executable/configuration files on every start without walking browser caches.
    $checks=@($root,$appRoot,(Join-Path $appRoot 'Start.ps1'))
    foreach($relative in @('Config','Controller','Model','Services','View','Launcher')) {
        $path=Join-Path $appRoot $relative
        if(Test-Path -LiteralPath $path){$checks+=$path;$checks+=@(Get-ChildItem -LiteralPath $path -File -Recurse | ForEach-Object FullName)}
    }
    foreach($relative in @('App/Data','App/Lib','App/Logs','data')) {
        $path=Join-Path $root $relative
        if(Test-Path -LiteralPath $path){$checks+=$path}
    }
    foreach($path in $checks) {
        if(!(Test-PrivateInstallationAccess $path)){throw 'アプリのアクセス権が変更されています。起動を中止しました。配置先の保護を再設定してください。'}
    }
}

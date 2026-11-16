$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if(!(Test-Path $compiler)){$compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework/v4.0.30319/csc.exe'}
$config=Get-Content (Join-Path $root 'App/Config/system.json') -Raw -Encoding UTF8|ConvertFrom-Json
if([string]$config.updates.currentVersion -notmatch '^\d+\.\d+\.\d+$'){throw 'updates.currentVersion は3桁のバージョンで指定してください。'}
$version=[version]($config.updates.currentVersion+'.0')
foreach($part in @($version.Major,$version.Minor,$version.Build,$version.Revision)){if($part -gt 65534){throw 'EXEバージョンの各値が大きすぎます。'}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('KCB-Version-'+[guid]::NewGuid().ToString('N')+'.cs')
try {
    $code='using System.Reflection; [assembly: AssemblyVersion("'+$version+'")] [assembly: AssemblyFileVersion("'+$version+'")]'
    [IO.File]::WriteAllText($temp,$code,[Text.UTF8Encoding]::new($false))
    & $compiler /nologo /target:winexe /platform:anycpu /optimize+ /reference:System.Windows.Forms.dll ("/win32icon:"+ (Join-Path $PSScriptRoot 'icon.ico')) ("/out:"+(Join-Path $root 'KijitamaCraftableBrowser.exe')) (Join-Path $PSScriptRoot 'Launcher.cs') $temp
    if($LASTEXITCODE -ne 0){throw 'ランチャーのビルドに失敗しました。'}
} finally { if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force} }
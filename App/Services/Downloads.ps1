function Get-WebDownloadDirectory {
 if($config.downloads.outputDirectory){return [IO.Path]::GetFullPath($config.downloads.outputDirectory)}
 if(!('Kijitama.DownloadFolder' -as [type])){
 Add-Type @"
using System;
using System.Runtime.InteropServices;
namespace Kijitama {
 public static class DownloadFolder {
  [DllImport("shell32.dll")] static extern int SHGetKnownFolderPath(ref Guid id,uint flags,IntPtr token,out IntPtr path);
  public static string Get() {
   Guid id=new Guid("374DE290-123F-4565-9164-39C4925E467B"); IntPtr p;
   Marshal.ThrowExceptionForHR(SHGetKnownFolderPath(ref id,0,IntPtr.Zero,out p));
   try{return Marshal.PtrToStringUni(p);}finally{Marshal.FreeCoTaskMem(p);}
  }
 }
}
"@
 }
 return [Kijitama.DownloadFolder]::Get()
}
function Get-UniqueDownloadPath([string]$Directory,[string]$Name) {
 $name=[IO.Path]::GetFileName($Name)
 if(!$name){$name='download'}
 foreach($char in [IO.Path]::GetInvalidFileNameChars()){$name=$name.Replace([string]$char,'_')}
 $name=$name.TrimEnd('.',' ')
 if(!$name){$name='download'}
 if($name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])([.]|$)'){$name='_'+$name}
 $stem=[IO.Path]::GetFileNameWithoutExtension($name);$ext=[IO.Path]::GetExtension($name)
 $path=Join-Path $Directory $name;$i=1
 while((Test-Path -LiteralPath $path) -or $script:downloadPaths.Contains($path)){
  $path=Join-Path $Directory ("$stem ($i)$ext");$i++
 }
 return $path
}
function Set-WebDownloadStatus([string]$Message) {
 $text=if($Message.StartsWith('保存しました：')){'保存しました：'+[IO.Path]::GetFileName($Message.Substring('保存しました：'.Length))}else{$Message}
 Show-ActionToast $text
}
function Start-WebDownload($Core,$EventArgs) {
 Register-TabDownload (Get-BrowserTabForCore $Core) ([string]$EventArgs.DownloadOperation.Uri)
 $deferral=$EventArgs.GetDeferral()
 $preserveSelectedPath=$false
 if($script:downloadIntent -and [object]::ReferenceEquals($script:downloadIntent.Core,$Core) -and [DateTime]::UtcNow -lt $script:downloadIntent.Expires -and $script:downloadIntent.Url -eq $EventArgs.DownloadOperation.Uri){
  $preserveSelectedPath=$true;$script:downloadIntent=$null
 }
 $action={Complete-WebDownload $EventArgs $deferral $preserveSelectedPath}.GetNewClosure()
 [void]$window.Dispatcher.BeginInvoke([Action]$action)
}
function Complete-WebDownload($EventArgs,$deferral,[bool]$preserveSelectedPath) {
  try{
   $EventArgs.Handled=$true
   if($preserveSelectedPath){
    # WebView2 already displayed Save As and obtained overwrite consent.
    $path=$EventArgs.ResultFilePath
    if(![IO.Path]::IsPathFullyQualified($path)){throw '選択した保存先を確認できませんでした。'}
    if($script:downloadPaths.Contains($path)){throw 'このファイルはダウンロード中です。別の名前を指定してください。'}
   }else{
    $directory=Get-WebDownloadDirectory
    [void][IO.Directory]::CreateDirectory($directory)
    $path=Get-UniqueDownloadPath $directory ([IO.Path]::GetFileName($EventArgs.ResultFilePath))
   }
   [void]$script:downloadPaths.Add($path)
   $EventArgs.ResultFilePath=$path
   $script:webDownloads.Add([pscustomobject]@{Operation=$EventArgs.DownloadOperation;Path=$path})
   $EventArgs.DownloadOperation.add_StateChanged({param($sender,$args) Update-WebDownloads})
   Set-WebDownloadStatus ('ダウンロード中：'+[IO.Path]::GetFileName($path))
  }catch{
   $EventArgs.Cancel=$true;Set-WebDownloadStatus ('保存できませんでした：'+$_.Exception.Message)
  }finally{$deferral.Complete()}

}
function Update-WebDownloads {
 foreach($item in @($script:webDownloads.ToArray())){
  if([string]$item.Operation.State -eq 'InProgress'){continue}
  [void]$script:downloadPaths.Remove($item.Path);[void]$script:webDownloads.Remove($item)
  if([string]$item.Operation.State -eq 'Completed'){
   Refresh-DownloadList
   Set-WebDownloadStatus ('保存しました：'+$item.Path)
  }else{Set-WebDownloadStatus ('ダウンロードできませんでした：'+[IO.Path]::GetFileName($item.Path)+'（'+$item.Operation.InterruptReason+'）')}
 }
}
function Show-WebContextMenu($Core,$EventArgs) {
 $EventArgs.Handled=$true;$deferral=$EventArgs.GetDeferral()
 $commands=@{};foreach($item in $EventArgs.MenuItems){$commands[$item.Name]=$item}
 $menu=[Windows.Controls.ContextMenu]::new();$target=$EventArgs.ContextMenuTarget;$entries=@()
 if($target.HasLinkUri){
  $entries+=@(
   @{Text='新しいタブで開く';Action='open';Url=$target.LinkUri},
   @{Text='名前を付けてリンク先を保存…';Command='saveLinkAs';NativeSave=$true;Url=$target.LinkUri},
   @{Text='リンクのアドレスをコピー';Action='copy';Url=$target.LinkUri}
  )
 }
 if($target.Kind.ToString() -eq 'Image'){
  if($entries.Count){$entries+=@{Separator=$true}}
  $entries+=@(
   @{Text='新しいタブで画像を開く';Action='open';Url=$target.SourceUri},
   @{Text='画像をダウンロード';Action='image';Url=$target.SourceUri;Frame=$target.FrameUri;Ask=$false},
   @{Text='名前を付けて画像を保存…';Action='image';Url=$target.SourceUri;Frame=$target.FrameUri;Ask=$true},
   @{Text='画像をコピー';Command='copyImage'},
   @{Text='画像アドレスをコピー';Action='copy';Url=$target.SourceUri}
  )
 }
 if(!$entries.Count){
  foreach($name in @('undo','redo','cut','copy','paste','selectAll')){
   if($commands.ContainsKey($name)){$entries+=@{Text=$commands[$name].Label;Command=$name}}
  }
 }
 foreach($entry in $entries){
  if($entry.Separator){[void]$menu.Items.Add([Windows.Controls.Separator]::new());continue}
  $item=[Windows.Controls.MenuItem]::new();$item.Header=$entry.Text
  $item.Tag=[pscustomobject]@{Entry=$entry;Core=$Core;Args=$EventArgs;Commands=$commands}
  if($entry.Command){$item.IsEnabled=$commands.ContainsKey($entry.Command) -and $commands[$entry.Command].IsEnabled}
  $item.add_Click({
   param($sender,$args)
   $data=$sender.Tag;$entry=$data.Entry
   try{
    switch($entry.Action){
     'open' {if(!(Test-AllowedUrl $entry.Url)){throw 'この画像またはリンクは新しいタブで開けません。'};New-BrowserTab $entry.Url}
     'image' {Start-ContextImageDownload $data.Core $entry.Url $entry.Frame $entry.Ask}
     'copy' {[Windows.Clipboard]::SetText([string]$entry.Url)}
     default {
      if($entry.NativeSave){
       $directory=Get-WebDownloadDirectory
       [void][IO.Directory]::CreateDirectory($directory)
       $data.Core.Profile.DefaultDownloadFolderPath=$directory
       $script:downloadIntent=[pscustomobject]@{Core=$data.Core;Url=$entry.Url;Expires=[DateTime]::UtcNow.AddSeconds($config.webView2.initializationTimeoutSeconds)}
      }
      $data.Args.SelectedCommandId=$data.Commands[$entry.Command].CommandId
     }
    }
   }catch{Set-WebDownloadStatus $_.Exception.Message}
  })
  [void]$menu.Items.Add($item)
 }
 $menu.Tag=$deferral;$menu.add_Closed({param($sender,$args) $sender.Tag.Complete()})
 if(!$menu.Items.Count){$deferral.Complete();return}
 $menu.IsOpen=$true
}
function Initialize-WebDownloads {
 foreach($name in @('DownloadListPanel','DownloadSearch','RefreshDownloads','DownloadListStatus','DownloadFiles','ShowDownloads')){$ui[$name]=$window.FindName($name)}
 $ui.ShowDownloads.add_Click({Invoke-UiAction {Show-DownloadList}})
 $ui.DownloadSearch.add_TextChanged({Refresh-DownloadList})
 $ui.RefreshDownloads.add_Click({Refresh-DownloadList})
 $ui.DownloadFiles.AddHandler([Windows.Controls.Button]::ClickEvent,[Windows.RoutedEventHandler]{
  param($sender,$eventArgs)
  $item=$eventArgs.Source.DataContext
  if(!$item.path){$item=$eventArgs.OriginalSource.DataContext}
  if($item.path){
   $eventArgs.Handled=$true
   Invoke-UiAction {
    if(!(Test-Path -LiteralPath $item.path -PathType Leaf)){Refresh-DownloadList;throw 'ファイルが見つかりません。'}
    Start-Process explorer.exe -ArgumentList ('/select,"'+$item.path+'"')
   }
   $ui.DownloadFiles.SelectedIndex=-1
  }
 })
 $script:webDownloads=[Collections.Generic.List[object]]::new()
 $script:downloadPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 $script:downloadIntent=$null
 foreach($name in @('DownloadDirectory','BrowseDownloadDirectory','SaveDownloadDirectory','ResetDownloadDirectory')){$ui[$name]=$window.FindName($name)}
 $ui.DownloadDirectory.Text=Get-WebDownloadDirectory
 $ui.BrowseDownloadDirectory.add_Click({Invoke-SettingsAction {
  $dialog=[Microsoft.Win32.OpenFolderDialog]::new();$dialog.Title='ダウンロード保存先を選択';$dialog.InitialDirectory=Get-WebDownloadDirectory
  if($dialog.ShowDialog($window)){$ui.DownloadDirectory.Text=$dialog.FolderName}
 }})
 $ui.SaveDownloadDirectory.add_Click({Invoke-SettingsAction {
  $value=$ui.DownloadDirectory.Text.Trim()
  if(!$value -or ![IO.Path]::IsPathFullyQualified($value)){throw '保存先を絶対パスで指定してください。'}
  $value=[IO.Path]::GetFullPath($value);[void][IO.Directory]::CreateDirectory($value)
  Save-WebDownloadDirectory $value
 }})
 $ui.ResetDownloadDirectory.add_Click({Invoke-SettingsAction {Save-WebDownloadDirectory ''}})
}
function Save-WebDownloadDirectory([string]$Value) {
 $path=Join-Path $appRoot 'Config/system.json';$latest=Get-Content $path -Raw|ConvertFrom-Json
 $latest.downloads.outputDirectory=$Value;Save-JsonFile $latest $path
 $config.downloads.outputDirectory=$Value;$ui.DownloadDirectory.Text=Get-WebDownloadDirectory
 $ui.SettingsStatus.Text='ダウンロード保存先を保存しました。'
}


function Start-ContextImageDownload($Core,[string]$Url,[string]$Frame,[bool]$Ask) {
 $job=[pscustomobject]@{Core=$Core;Url=$Url;Frame=$Frame;Ask=$Ask;Task=$null;Stage='tree';Started=[DateTime]::UtcNow}
 if($Url.StartsWith('data:image/')){
  $job.Stage='data'
 }else{
  $job.Stage='enable';$job.Task=$Core.CallDevToolsProtocolMethodAsync('Page.enable','{}')
 }
 $timer=[Windows.Threading.DispatcherTimer]::new()
 $timer.Interval=[TimeSpan]::FromMilliseconds($config.timing.dependencyPollMilliseconds)
 $timer.Tag=$job
 $timer.add_Tick({
  param($sender,$args)
  $job=$sender.Tag
  try{
   if(([DateTime]::UtcNow-$job.Started).TotalSeconds -gt $config.images.timeoutSeconds){throw '画像の取得が時間切れになりました。'}
   if($job.Stage -eq 'data'){
    $sender.Stop()
    if($job.Url -notmatch '^data:(image/[^;,]+);base64,(.*)$'){throw 'この画像形式は保存できません。'}
    Save-ContextImage ([Convert]::FromBase64String($Matches[2])) $job.Url $Matches[1] $job.Ask
    return
   }
   if(!$job.Task.IsCompleted){return}
   $result=$job.Task.GetAwaiter().GetResult()|ConvertFrom-Json
   if($job.Stage -eq 'enable'){
    $job.Task=$job.Core.CallDevToolsProtocolMethodAsync('Page.getFrameTree','{}');$job.Stage='tree';return
   }
   if($job.Stage -eq 'tree'){
    $frames=[Collections.Generic.List[object]]::new()
    $frames.Add($result.frameTree)
    for($i=0;$i -lt $frames.Count;$i++){foreach($child in $frames[$i].childFrames){if($child){$frames.Add($child)}}}
    $frameId=$result.frameTree.frame.id
    foreach($node in $frames){if($node.frame.url -eq $job.Frame){$frameId=$node.frame.id;break}}
    $job.Task=$job.Core.CallDevToolsProtocolMethodAsync('Page.getResourceContent',(@{frameId=$frameId;url=$job.Url}|ConvertTo-Json -Compress))
    $job.Stage='content';return
   }
   $sender.Stop()
   $bytes=if($result.base64Encoded){[Convert]::FromBase64String($result.content)}else{[Text.Encoding]::UTF8.GetBytes($result.content)}
   Save-ContextImage $bytes $job.Url '' $job.Ask
  }catch{$sender.Stop();Set-WebDownloadStatus ('画像を保存できませんでした：'+$_.Exception.Message)}
 })
 $timer.Start()
 Set-WebDownloadStatus '表示中の画像を取得しています…'
}
function Save-ContextImage([byte[]]$Bytes,[string]$Url,[string]$Mime,[bool]$Ask) {
 if(!$Bytes.Length){throw '画像の内容が空です。'}
 $directory=Get-WebDownloadDirectory
 [void][IO.Directory]::CreateDirectory($directory)
 $name=if($Url.StartsWith('data:')){'image'}else{[IO.Path]::GetFileName(([Uri]$Url).AbsolutePath)}
 if(!$name){$name='image'}
 if(!$Mime){
  if($Bytes.Length -ge 8 -and $Bytes[0] -eq 137 -and $Bytes[1] -eq 80){$Mime='image/png'}
  elseif($Bytes.Length -ge 3 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 216){$Mime='image/jpeg'}
  elseif($Bytes.Length -ge 3 -and $Bytes[0] -eq 71 -and $Bytes[1] -eq 73){$Mime='image/gif'}
  elseif($Bytes.Length -ge 12 -and [Text.Encoding]::ASCII.GetString($Bytes,8,4) -eq 'WEBP'){$Mime='image/webp'}
 }
 $extensions=@{'image/png'='.png';'image/jpeg'='.jpg';'image/gif'='.gif';'image/webp'='.webp';'image/svg+xml'='.svg';'image/avif'='.avif';'image/bmp'='.bmp'}
 if($extensions.ContainsKey($Mime)){$name=[IO.Path]::GetFileNameWithoutExtension($name)+$extensions[$Mime]}
 elseif([IO.Path]::GetExtension($name) -notin @('.png','.jpg','.jpeg','.gif','.webp','.svg','.avif','.bmp','.ico')){throw '画像のファイル形式を確認できませんでした。'}
 $path=Get-UniqueDownloadPath $directory $name
 $overwrite=$false
 if($Ask){
  $chosen=Show-WebSaveDialog $path '名前を付けて画像を保存'
  if(!$chosen){Set-WebDownloadStatus '画像の保存をキャンセルしました。';return}
  $path=$chosen;$overwrite=$true
 }
 $mode=if($overwrite){[IO.FileMode]::Create}else{[IO.FileMode]::CreateNew}
 $stream=[IO.File]::Open($path,$mode,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$stream.Write($Bytes,0,$Bytes.Length)}finally{$stream.Dispose()}
 Refresh-DownloadList
 Set-WebDownloadStatus ('保存しました：'+$path)
}


function Show-WebSaveDialog([string]$Path,[string]$Title) {
 $dialog=[Microsoft.Win32.SaveFileDialog]::new()
 $dialog.Title=$Title;$dialog.InitialDirectory=[IO.Path]::GetDirectoryName($Path)
 $dialog.FileName=[IO.Path]::GetFileName($Path);$dialog.Filter='すべてのファイル|*.*';$dialog.OverwritePrompt=$true
 if($dialog.ShowDialog($window)){return $dialog.FileName}
 return $null
}



function Refresh-DownloadList { Refresh-SavedFileList Download }
function Show-DownloadList {
 foreach($name in @('FavoritesPanel','HistoryPanel','PdfListPanel','ImageListPanel')){$ui[$name].Visibility='Collapsed'}
 foreach($name in @('ShowLikes','ShowHistory','ShowPdfs','ShowImages')){$ui[$name].FontWeight='Normal'}
 $ui.DownloadListPanel.Visibility='Visible';$ui.ShowDownloads.FontWeight='Bold'
 $script:historyCollapsed=$false
 Set-HistoryPanel;Save-AppPreferences;Refresh-DownloadList
}





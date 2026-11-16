function Initialize-ImageCapture {
    Initialize-ImageDirectorySettings
    foreach($name in @('CaptureImage','ShowImages','ImageListPanel','ImageSearch','RefreshImages','ImageListStatus','ImageFiles')) { $ui[$name]=$window.FindName($name) }
    $ui.CaptureImage.add_Click({ Invoke-UiAction { Start-ImageCapture } })
    $ui.ShowImages.add_Click({ Invoke-UiAction { Show-ImageList } })
    $ui.ImageSearch.add_TextChanged({ Refresh-ImageList })
    $ui.RefreshImages.add_Click({ Refresh-ImageList })
    $ui.ImageFiles.AddHandler([Windows.Controls.Button]::ClickEvent,[Windows.RoutedEventHandler]{param($s,$e)
        $item=$e.OriginalSource.DataContext
        if($item.path){ Invoke-UiAction {
            if(!(Test-Path -LiteralPath $item.path -PathType Leaf) -or [IO.Path]::GetExtension($item.path) -notin @('.png','.jpg','.jpeg','.webp')){Refresh-ImageList;throw '画像が見つかりません。'}
            $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$item.path;$info.UseShellExecute=$true
            [void][Diagnostics.Process]::Start($info)
        } }
    })
}
function Show-ImageList {
    $ui.DownloadListPanel.Visibility='Collapsed'; $ui.ShowDownloads.FontWeight='Normal'
    foreach($name in @('FavoritesPanel','HistoryPanel','PdfListPanel')){$ui[$name].Visibility='Collapsed'}
    foreach($name in @('ShowLikes','ShowHistory','ShowPdfs')){$ui[$name].FontWeight='Normal'}
    $ui.ImageListPanel.Visibility='Visible';$ui.ShowImages.FontWeight='Bold'
    $script:historyCollapsed=$false;Set-HistoryPanel;Save-AppPreferences;Refresh-ImageList
}
function Get-ImageCapturePlan([double]$Width,[double]$Height,$Settings) {
    if([double]::IsNaN($Width) -or [double]::IsInfinity($Width) -or [double]::IsNaN($Height) -or [double]::IsInfinity($Height) -or $Width -le 0 -or $Height -le 0){throw 'ページサイズを取得できません。'}
    $width=[math]::Ceiling($Width);$height=[math]::Ceiling($Height)
    $large=$height -gt $Settings.maxHeight -or $width*$height -gt $Settings.maxPixels
    if(!$large){return [pscustomobject]@{x=0;y=0;width=$width;height=$height;scale=1}}
    if(!$Settings.splitLarge){throw 'ページが撮影サイズの上限を超えています。設定で「大きいサイズは分割して保存する」をONにするか、PDF保存をご利用ください。'}
    $partHeight=[math]::Floor([math]::Min([math]::Min($Settings.splitHeight,$Settings.maxHeight),$Settings.maxPixels/$width))
    if($partHeight -le $Settings.overlapPixels){throw 'ページの幅が大きすぎるため、安全に分割撮影できません。'}
    $step=$partHeight-$Settings.overlapPixels
    $count=1+[math]::Ceiling(($height-$partHeight)/$step)
    if($count -gt $Settings.maxParts){throw ('分割枚数が上限（'+$Settings.maxParts+'枚）を超えています。PDF保存をご利用ください。')}
    for($i=0;$i -lt $count;$i++){
        $y=$i*$step
        [pscustomobject]@{x=0;y=$y;width=$width;height=[math]::Min($partHeight,$height-$y);scale=1}
    }
}
function Start-ImageCapture {
    if($script:imageTask){return}
    if(!$script:browser -or !$browser.CoreWebView2){throw 'ページの読み込み後に撮影してください。'}
    $script:imageCore=$browser.CoreWebView2
    $script:imageSource=$imageCore.Source
    $script:imageSettings=$config.images | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    Assert-ImageSettings $imageSettings
    $title=$imageCore.DocumentTitle
    if(!$title){$title='page'}
    $dir=Resolve-AppPath $imageSettings.outputDirectory
    [void][IO.Directory]::CreateDirectory($dir)
    $extension='.'+$imageSettings.format
    $script:imageBasePath=Join-Path $dir (New-ExportFileName $title $extension)
    $script:imagePath=$imageBasePath
    $script:imageSaved=0;$script:imagePart=0;$script:imagePlan=@()
    $script:imageStarted=[DateTime]::UtcNow
    $script:imageStage='metrics'
    $script:imageTask=$imageCore.CallDevToolsProtocolMethodAsync('Page.getLayoutMetrics','{}')
    $ui.CaptureImage.IsEnabled=$false
    Show-ActionToast 'ページ全体を撮影しています…'
}
function Start-ImageCapturePart {
    $format=if($imageSettings.format -eq 'jpg'){'jpeg'}else{$imageSettings.format}
    $parameters=@{format=$format;captureBeyondViewport=$true;fromSurface=$true;clip=$imagePlan[$imagePart]}
    if($format -ne 'png'){$parameters.quality=[int]$imageSettings.quality}
    $script:imagePath=if($imagePlan.Count -gt 1){[IO.Path]::Combine([IO.Path]::GetDirectoryName($imageBasePath),[IO.Path]::GetFileNameWithoutExtension($imageBasePath)+('_{0:D3}' -f ($imagePart+1))+[IO.Path]::GetExtension($imageBasePath))}else{$imageBasePath}
    $script:imageStarted=[DateTime]::UtcNow
    $script:imageStage='capture'
    $script:imageTask=$imageCore.CallDevToolsProtocolMethodAsync('Page.captureScreenshot',($parameters|ConvertTo-Json -Depth 5 -Compress))
    if($imagePlan.Count -gt 1){Show-ActionToast ('分割撮影中：'+($imagePart+1)+'/'+$imagePlan.Count+'枚')}
}
function Update-ImageCapture {
    if(!$script:imageTask){return}
    try {
        if(([DateTime]::UtcNow-$imageStarted).TotalSeconds -gt $imageSettings.timeoutSeconds){throw '撮影がタイムアウトしました。'}
        if(!$browser -or $browser.CoreWebView2 -ne $imageCore -or $imageCore.Source -ne $imageSource){throw 'ページが切り替わったため撮影を中止しました。'}
        if(!$imageTask.IsCompleted){return}
        $result=$imageTask.GetAwaiter().GetResult() | ConvertFrom-Json
        if($imageStage -eq 'metrics'){
            $script:imagePlan=@(Get-ImageCapturePlan $result.cssContentSize.width $result.cssContentSize.height $imageSettings)
            Start-ImageCapturePart
            return
        }
        $bytes=[Convert]::FromBase64String($result.data)
        if(!$bytes.Length){throw '画像データを取得できませんでした。'}
        try {
            [IO.File]::WriteAllBytes($imagePath+'.tmp',$bytes)
            [IO.File]::Move($imagePath+'.tmp',$imagePath)
        } finally {if(Test-Path -LiteralPath ($imagePath+'.tmp')){Remove-Item -LiteralPath ($imagePath+'.tmp') -Force}}
        $script:imageSaved++
        $script:imagePart++
        if($imagePart -lt $imagePlan.Count){Start-ImageCapturePart;return}
        $script:imageTask=$null
        Refresh-ImageList
        Show-ListActionFeedback 'ShowImages'
        if($imageSaved -gt 1){Show-ActionToast ('画像を'+$imageSaved+'枚に分割して保存しました。')}else{Show-ActionToast ('画像を保存しました：'+[IO.Path]::GetFileName($imagePath))}
    } catch {
        $script:imageTask=$null
        Refresh-ImageList
        $partial=if($imageSaved -gt 0){$imagePlan.Count.ToString()+'枚中'+$imageSaved+'枚を保存済みです。'}else{''}
        Show-ActionToast ('撮影できませんでした：'+$partial+$_.Exception.Message)
    }
    $ui.CaptureImage.IsEnabled=$true
}
function Save-ImageDirectory([string]$Value) {
    if($script:imageTask){throw '撮影が完了してから保存先を変更してください。'}
    $value=$Value.Trim()
    if(!$value){throw '保存先フォルダーを入力してください。'}
    $directory=Resolve-AppPath $value
    [void][IO.Directory]::CreateDirectory($directory)
    $path=Join-Path $appRoot 'Config/system.json'
    $latest=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
    $latest.images.outputDirectory=$value
    Save-JsonFile $latest $path
    $config.images.outputDirectory=$value
    $ui.ImageDirectory.Text=$value
    Refresh-ImageList
    $ui.SettingsStatus.Text='撮影画像の保存先を保存しました：'+$directory
}
function Initialize-ImageDirectorySettings {
    foreach($name in @('ImageDirectory','SaveImageDirectory','BrowseImageDirectory','ImageFormatJpg','ImageFormatPng','ImageFormatWebp','SplitLargeImages')){$ui[$name]=$window.FindName($name)}
    $ui.ImageDirectory.Text=$config.images.outputDirectory
    $ui.ImageFormatJpg.IsChecked=$config.images.format -eq 'jpg'
    $ui.ImageFormatPng.IsChecked=$config.images.format -eq 'png'
    $ui.ImageFormatWebp.IsChecked=$config.images.format -eq 'webp'
    $ui.SplitLargeImages.IsChecked=$config.images.splitLarge
    foreach($name in @('ImageFormatJpg','ImageFormatPng','ImageFormatWebp')){$ui[$name].add_Checked({Invoke-SettingsAction {Save-ImageCaptureOptions}})}
    $ui.SplitLargeImages.add_Click({Invoke-SettingsAction {Save-ImageCaptureOptions}})
    $ui.SaveImageDirectory.add_Click({Invoke-SettingsAction {Save-ImageDirectory $ui.ImageDirectory.Text}})
    $ui.BrowseImageDirectory.add_Click({Invoke-SettingsAction {
        $dialog=[Microsoft.Win32.OpenFolderDialog]::new()
        $dialog.Title='撮影画像の保存先フォルダーを選択'
        $dialog.Multiselect=$false
        $current=Resolve-AppPath $config.images.outputDirectory
        if(Test-Path -LiteralPath $current -PathType Container){$dialog.InitialDirectory=$current}
        if($dialog.ShowDialog($window)){Save-ImageDirectory $dialog.FolderName}
    }})
}

function Save-ImageCaptureOptions {
    if($script:restoringImageOptions){return}
    try {
        if($script:imageTask){throw '撮影が完了してから設定を変更してください。'}
        $format=if($ui.ImageFormatJpg.IsChecked){'jpg'}elseif($ui.ImageFormatWebp.IsChecked){'webp'}else{'png'}
        $path=Join-Path $appRoot 'Config/system.json'
        $latest=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
        $latest.images.format=$format
        $latest.images.splitLarge=[bool]$ui.SplitLargeImages.IsChecked
        Save-JsonFile $latest $path
        $config.images.format=$format
        $config.images.splitLarge=$latest.images.splitLarge
        $ui.SettingsStatus.Text='撮影画像の保存形式・分割設定を保存しました。'
    }catch{
        $script:restoringImageOptions=$true
        try{
            $ui.ImageFormatJpg.IsChecked=$config.images.format -eq 'jpg'
            $ui.ImageFormatPng.IsChecked=$config.images.format -eq 'png'
            $ui.ImageFormatWebp.IsChecked=$config.images.format -eq 'webp'
            $ui.SplitLargeImages.IsChecked=$config.images.splitLarge
        }finally{$script:restoringImageOptions=$false}
        throw
    }
}

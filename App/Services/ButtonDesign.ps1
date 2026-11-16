function Get-LucideImage([string]$Name) {
    if (!$script:iconCache) { $script:iconCache=@{} }
    if ($iconCache.ContainsKey($Name)) { return $iconCache[$Name] }
    $svg=[xml](Get-Content (Join-Path $appRoot "Assets/Lucide/$Name.svg") -Raw)
    $group=[Windows.Media.DrawingGroup]::new()
    $group.Children.Add([Windows.Media.GeometryDrawing]::new([Windows.Media.Brushes]::Transparent,$null,[Windows.Media.RectangleGeometry]::new([Windows.Rect]::new(0,0,24,24))))
    $pen=[Windows.Media.Pen]::new([Windows.Media.Brushes]::SlateGray,1.8)
    $pen.StartLineCap='Round'; $pen.EndLineCap='Round'; $pen.LineJoin='Round'
    foreach ($node in $svg.DocumentElement.ChildNodes) {
        $geometry=$null
        switch ($node.LocalName) {
            'path' { $geometry=[Windows.Media.Geometry]::Parse($node.GetAttribute('d')) }
            'circle' { $geometry=[Windows.Media.EllipseGeometry]::new([Windows.Point]::new([double]$node.cx,[double]$node.cy),[double]$node.r,[double]$node.r) }
            'rect' { $geometry=[Windows.Media.RectangleGeometry]::new([Windows.Rect]::new([double]$node.x,[double]$node.y,[double]$node.width,[double]$node.height),[double]$node.rx,[double]$node.rx) }
            'line' { $geometry=[Windows.Media.LineGeometry]::new([Windows.Point]::new([double]$node.x1,[double]$node.y1),[Windows.Point]::new([double]$node.x2,[double]$node.y2)) }
            'polyline' { $geometry=[Windows.Media.Geometry]::Parse('M'+$node.points) }
            'polygon' { $geometry=[Windows.Media.Geometry]::Parse('M'+$node.points+' Z') }
            default { continue }
        }
        if ($geometry) { $group.Children.Add([Windows.Media.GeometryDrawing]::new($null,$pen,$geometry)) }
    }
    $image=[Windows.Media.DrawingImage]::new($group); $image.Freeze(); $iconCache[$Name]=$image
    return $image
}
function Initialize-ButtonDesign {
    $map=Get-Content (Join-Path $appRoot 'Config/button-icons.json') -Raw|ConvertFrom-Json
    foreach ($entry in $map.PSObject.Properties) {
        $button=$window.FindName($entry.Name)
        if (!$button) { continue }
        $button.Tag=Get-LucideImage $entry.Value
        [Windows.Automation.AutomationProperties]::SetName($button,[string]$button.Content)
        if (!$button.ToolTip) { $button.ToolTip=[string]$button.Content }
    }
    foreach ($name in @('Back','Forward')) { $ui[$name].Content='' }
    $ui.Back.ToolTip='戻る'; $ui.Forward.ToolTip='進む'
    [Windows.Automation.AutomationProperties]::SetName($ui.Back,'戻る')
    [Windows.Automation.AutomationProperties]::SetName($ui.Forward,'進む')
    $favoriteList=$window.FindName('Favorites')
    if ($favoriteList) {
        $deleteIcon=[Windows.Controls.Image]::new(); $deleteIcon.Source=Get-LucideImage 'trash'; $deleteIcon.Width=16; $deleteIcon.Height=16
        $favoriteList.ContextMenu.Items[0].Icon=$deleteIcon
    }
    foreach ($name in @('FactoryReset','SettingsDeleteProfile','ClearHistory')) { $window.FindName($name).Foreground=[Windows.Media.Brushes]::Firebrick }
    foreach ($name in @('AiSupport','AddFavorite')) { $window.FindName($name).Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#EDF7F4') }
    Set-HistoryPanel
}
function Show-ListActionFeedback([string]$Name) {
    $button=$ui[$Name]
    if(!$button){return}
    if(!$script:listFeedback){$script:listFeedback=@{}}
    if(!$script:listFeedback.ContainsKey($Name)) {
        $state=[pscustomobject]@{Button=$button;Timer=[Windows.Threading.DispatcherTimer]::new();Active=$false;Original=@{}}
        $handler={
            $state.Timer.Stop()
            foreach($property in $state.Original.Keys){
                $value=$state.Original[$property]
                if($value -eq [Windows.DependencyProperty]::UnsetValue){$state.Button.ClearValue($property)}else{$state.Button.SetValue($property,$value)}
            }
            $state.Active=$false
        }.GetNewClosure()
        $state.Timer.add_Tick($handler)
        $script:listFeedback[$Name]=$state
    }
    $state=$script:listFeedback[$Name]
    $state.Timer.Stop()
    if(!$state.Active) {
        foreach($property in @([Windows.Controls.Control]::BackgroundProperty,[Windows.Controls.Control]::ForegroundProperty,[Windows.Controls.Control]::BorderBrushProperty,[Windows.FrameworkElement]::TagProperty)) {
            $state.Original[$property]=$button.ReadLocalValue($property)
        }
    }
    $style=$config.ui.actionFeedback
    $converter=[Windows.Media.BrushConverter]::new()
    $color=$converter.ConvertFromString($style.foreground)
    $button.Background=$converter.ConvertFromString($style.background)
    $button.Foreground=$color
    $button.BorderBrush=$converter.ConvertFromString($style.border)
    $icon=$state.Original[[Windows.FrameworkElement]::TagProperty]
    if($icon -is [Windows.Media.DrawingImage]) {
        $highlight=$icon.Clone()
        foreach($drawing in $highlight.Drawing.Children){if($drawing -is [Windows.Media.GeometryDrawing] -and $drawing.Pen){$drawing.Pen.Brush=$color}}
        $button.Tag=$highlight
    }
    $state.Active=$true
    $state.Timer.Interval=[TimeSpan]::FromSeconds([double]$style.durationSeconds)
    $state.Timer.Start()
}

function Stop-ListActionFeedback {
    if($script:listFeedback){foreach($state in $script:listFeedback.Values){$state.Timer.Stop()};$script:listFeedback=$null}
}
function Update-FavoriteIndicator {
    $button=$ui.ShowLikes
    if(!$button -or !$button.Tag){return}
    if(!$script:favoriteIndicatorBase) {
        $script:favoriteIndicatorBase=@{}
        foreach($property in @([Windows.Controls.Control]::BackgroundProperty,[Windows.Controls.Control]::ForegroundProperty,[Windows.Controls.Control]::BorderBrushProperty,[Windows.FrameworkElement]::TagProperty)) {
            $script:favoriteIndicatorBase[$property]=$button.ReadLocalValue($property)
        }
    }
    $desired=$script:favoriteIndicatorBase.Clone()
    $url=if($browser -and $browser.CoreWebView2){[string]$browser.CoreWebView2.Source}else{''}
    $registered=$url -and @($script:favoriteItems | Where-Object { $_.url -ceq $url }).Count -gt 0
    if($registered) {
        $style=$config.ui.favoriteIndicator
        $converter=[Windows.Media.BrushConverter]::new()
        $color=$converter.ConvertFromString($style.foreground)
        $desired[[Windows.Controls.Control]::BackgroundProperty]=$converter.ConvertFromString($style.background)
        $desired[[Windows.Controls.Control]::ForegroundProperty]=$color
        $desired[[Windows.Controls.Control]::BorderBrushProperty]=$converter.ConvertFromString($style.border)
        $icon=$script:favoriteIndicatorBase[[Windows.FrameworkElement]::TagProperty]
        if($icon -is [Windows.Media.DrawingImage]) {
            $highlight=$icon.Clone()
            foreach($drawing in $highlight.Drawing.Children){if($drawing -is [Windows.Media.GeometryDrawing] -and $drawing.Pen){$drawing.Pen.Brush=$color}}
            $desired[[Windows.FrameworkElement]::TagProperty]=$highlight
        }
    }
    if($script:listFeedback -and $script:listFeedback.ContainsKey('ShowLikes') -and $script:listFeedback.ShowLikes.Active) {
        # Keep the success highlight, but restore the latest page state when its timer expires.
        $script:listFeedback.ShowLikes.Original=$desired
    } else {
        foreach($property in $desired.Keys){
            if($desired[$property] -eq [Windows.DependencyProperty]::UnsetValue){$button.ClearValue($property)}else{$button.SetValue($property,$desired[$property])}
        }
    }
    $button.ToolTip=if($registered){'このURLはスキに登録済みです。クリックするとスキ一覧を表示します。'}else{'スキ一覧を表示'}
}

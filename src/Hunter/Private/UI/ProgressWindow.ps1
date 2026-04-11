function Start-ProgressWindow {
    if ($script:IsAutomationRun) {
        Write-Log 'Automation-safe mode enabled; skipping progress window.' 'INFO'
        return
    }

    try {
        Add-Type -AssemblyName PresentationFramework  -ErrorAction Stop
        Add-Type -AssemblyName PresentationCore       -ErrorAction Stop
        Add-Type -AssemblyName WindowsBase            -ErrorAction Stop

        # Synchronized hashtable for cross-thread communication
        $script:UiSync = [hashtable]::Synchronized(@{
            Ready       = $false
            Dispatcher  = $null
            Window      = $null
            TaskData    = $null      # JSON string of task snapshots pushed from main thread
            CloseFlag   = $false
            Error       = $null
            HeartbeatUtc = $null
        })

        $syncRef = $script:UiSync   # local ref for the scriptblock closure

        # ---------------------------------------------------------------
        # STA Runspace — owns the WPF window and its dispatcher loop
        # ---------------------------------------------------------------
        $script:UiRunspace = [runspacefactory]::CreateRunspace()
        $script:UiRunspace.ApartmentState = [System.Threading.ApartmentState]::STA
        $script:UiRunspace.ThreadOptions  = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $script:UiRunspace.Open()
        $script:UiRunspace.SessionStateProxy.SetVariable('Sync', $syncRef)

        $script:UiPipeline = [powershell]::Create()
        $script:UiPipeline.Runspace = $script:UiRunspace
        $script:UiPipeline.AddScript({
            param($Sync)

            Add-Type -AssemblyName PresentationFramework  -ErrorAction Stop
            Add-Type -AssemblyName PresentationCore       -ErrorAction Stop
            Add-Type -AssemblyName WindowsBase            -ErrorAction Stop

            # ---------------------------------------------------------------
            # Helper functions (must live inside the runspace scope)
            # ---------------------------------------------------------------
            function Start-GlassAnimation {
                param(
                    [Parameter(Mandatory)]$Target,
                    [System.Windows.DependencyProperty]$Property,
                    [double]$To,
                    [double]$DurationMs = 350,
                    [switch]$AutoReverse,
                    [switch]$Forever
                )

                if ($null -eq $Target) {
                    throw 'Animation target was null.'
                }

                $anim = [System.Windows.Media.Animation.DoubleAnimation]::new()
                $anim.To = $To
                $anim.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds($DurationMs))
                $anim.EasingFunction = [System.Windows.Media.Animation.CubicEase]@{ EasingMode = 'EaseOut' }
                if ($AutoReverse) { $anim.AutoReverse = $true }
                if ($Forever) { $anim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever }
                $Target.BeginAnimation($Property, $anim)
            }

            function Start-GlassColorAnimation {
                param(
                    [System.Windows.Media.SolidColorBrush]$Brush,
                    [string]$ToColor,
                    [double]$DurationMs = 400
                )
                $anim = [System.Windows.Media.Animation.ColorAnimation]::new()
                $anim.To = [System.Windows.Media.ColorConverter]::ConvertFromString($ToColor)
                $anim.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds($DurationMs))
                $anim.EasingFunction = [System.Windows.Media.Animation.CubicEase]@{ EasingMode = 'EaseOut' }
                $Brush.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $anim)
            }

            # ---------------------------------------------------------------
            # XAML — liquid glass overlay
            # ---------------------------------------------------------------
            [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Hunter" Width="520" MinWidth="480" MinHeight="220"
        SizeToContent="Height"
        WindowStartupLocation="Manual"
        ResizeMode="NoResize"
        AllowsTransparency="True" WindowStyle="None"
        Background="Transparent" Topmost="True"
        ShowInTaskbar="True">
    <Window.Resources>
        <Style TargetType="{x:Type ScrollBar}">
            <Setter Property="Visibility" Value="Collapsed"/>
        </Style>
        <Style TargetType="{x:Type ScrollViewer}">
            <Setter Property="VerticalScrollBarVisibility" Value="Disabled"/>
            <Setter Property="HorizontalScrollBarVisibility" Value="Disabled"/>
            <Setter Property="CanContentScroll" Value="False"/>
        </Style>
    </Window.Resources>
    <Grid>
        <Border CornerRadius="16" x:Name="GlassShell">
            <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                    <GradientStop Color="#D8101828" Offset="0.0"/>
                    <GradientStop Color="#E0141E30" Offset="0.4"/>
                    <GradientStop Color="#D0101828" Offset="1.0"/>
                </LinearGradientBrush>
            </Border.Background>
            <Border.BorderBrush>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                    <GradientStop Color="#50FFFFFF" Offset="0.0"/>
                    <GradientStop Color="#15FFFFFF" Offset="0.5"/>
                    <GradientStop Color="#30FFFFFF" Offset="1.0"/>
                </LinearGradientBrush>
            </Border.BorderBrush>
            <Border.BorderThickness>1</Border.BorderThickness>
            <Border.Effect>
                <DropShadowEffect Color="#000000" BlurRadius="24" ShadowDepth="0" Opacity="0.5"/>
            </Border.Effect>
            <Grid>
                <Border CornerRadius="16" IsHitTestVisible="False" VerticalAlignment="Top" Height="80">
                    <Border.Background>
                        <LinearGradientBrush StartPoint="0.5,0" EndPoint="0.5,1">
                            <GradientStop Color="#18FFFFFF" Offset="0.0"/>
                            <GradientStop Color="#00FFFFFF" Offset="1.0"/>
                        </LinearGradientBrush>
                    </Border.Background>
                </Border>
                <Border CornerRadius="16" IsHitTestVisible="False" VerticalAlignment="Bottom"
                        HorizontalAlignment="Right" Width="120" Height="120" Margin="0,0,8,8">
                    <Border.Background>
                        <RadialGradientBrush>
                            <GradientStop Color="#103B82F6" Offset="0.0"/>
                            <GradientStop Color="#00000000" Offset="1.0"/>
                        </RadialGradientBrush>
                    </Border.Background>
                </Border>
                <Grid Margin="18">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>
                    <Grid Grid.Row="0" Margin="0,0,0,12">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="HUNTER" FontSize="14" FontWeight="Bold" Foreground="#60A5FA"
                                   FontFamily="Segoe UI" VerticalAlignment="Top"/>
                        <TextBlock Grid.Column="1" x:Name="TitleStatus" Text="Initializing..." FontSize="11"
                                   Foreground="#9CA3AF" FontFamily="Segoe UI" VerticalAlignment="Top"
                                   Margin="8,0,0,0" TextWrapping="Wrap"/>
                    </Grid>
                    <StackPanel Grid.Row="1" x:Name="PhasePanel" Margin="0,0,0,10" />
                    <Grid Grid.Row="2" Margin="0,4,0,2" Height="10">
                        <Border CornerRadius="5" Background="#0D1117">
                            <Border.BorderBrush>
                                <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                                    <GradientStop Color="#20000000" Offset="0"/>
                                    <GradientStop Color="#10FFFFFF" Offset="1"/>
                                </LinearGradientBrush>
                            </Border.BorderBrush>
                            <Border.BorderThickness>1</Border.BorderThickness>
                        </Border>
                        <Border x:Name="ProgressFill" CornerRadius="5"
                                HorizontalAlignment="Left" Width="0" Height="10" ClipToBounds="True">
                            <Border.Background>
                                <LinearGradientBrush x:Name="ShimmerBrush" StartPoint="0,0" EndPoint="1,0"
                                                     SpreadMethod="Reflect">
                                    <GradientStop Color="#3B82F6" Offset="0.0"/>
                                    <GradientStop Color="#60A5FA" Offset="0.3"/>
                                    <GradientStop Color="#93C5FD" Offset="0.5"/>
                                    <GradientStop Color="#60A5FA" Offset="0.7"/>
                                    <GradientStop Color="#3B82F6" Offset="1.0"/>
                                </LinearGradientBrush>
                            </Border.Background>
                            <Border CornerRadius="5" VerticalAlignment="Top" Height="5" Margin="1,1,1,0"
                                    IsHitTestVisible="False">
                                <Border.Background>
                                    <LinearGradientBrush StartPoint="0.5,0" EndPoint="0.5,1">
                                        <GradientStop Color="#40FFFFFF" Offset="0.0"/>
                                        <GradientStop Color="#00FFFFFF" Offset="1.0"/>
                                    </LinearGradientBrush>
                                </Border.Background>
                            </Border>
                        </Border>
                    </Grid>
                    <TextBlock Grid.Row="3" x:Name="ProgressText" Text="0 / 0 tasks"
                               FontSize="10" Foreground="#6B7280" FontFamily="Segoe UI"
                               HorizontalAlignment="Center" Margin="0,4,0,0" TextWrapping="Wrap"/>
                </Grid>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

            $reader = [System.Xml.XmlNodeReader]::new($xaml)
            $window = [System.Windows.Markup.XamlReader]::Load($reader)

            # Position at top-right of primary screen
            $screen = [System.Windows.SystemParameters]::WorkArea
            $window.MaxWidth = [Math]::Max(480, $screen.Width - 32)
            $window.MaxHeight = [Math]::Max(260, $screen.Height - 32)
            if ($window.Width -gt $window.MaxWidth) {
                $window.Width = $window.MaxWidth
            }
            $window.Left = $screen.Right - $window.Width - 16
            $window.Top  = $screen.Top + 16

            # Draggable
            $window.Add_MouseLeftButtonDown({ $this.DragMove() })

            # Named elements
            $phasePanel  = $window.FindName('PhasePanel')
            $progressFill = $window.FindName('ProgressFill')
            $progressText = $window.FindName('ProgressText')
            $titleStatus  = $window.FindName('TitleStatus')
            $shimmerBrush = $window.FindName('ShimmerBrush')

            # Shimmer animation
            $shimmerTransform = [System.Windows.Media.TranslateTransform]::new()
            $shimmerBrush.RelativeTransform = $shimmerTransform
            $shimmerAnim = [System.Windows.Media.Animation.DoubleAnimation]::new()
            $shimmerAnim.From = 0.0
            $shimmerAnim.To = 1.0
            $shimmerAnim.Duration = [System.Windows.Duration]::new([TimeSpan]::FromSeconds(2))
            $shimmerAnim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
            $shimmerAnim.AutoReverse = $true
            $shimmerTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $shimmerAnim)

            # Phase metadata
            $phaseLabels = [ordered]@{
                '1' = 'Preflight'; '2' = 'Core Setup'; '3' = 'Start / UI'; '4' = 'Explorer'
                '5' = 'Microsoft Cloud'; '6' = 'Remove Apps'; '7' = 'System Tweaks'
                '8' = 'External Tools'; '9' = 'Cleanup'
            }

            $phaseCircles    = @{}
            $phaseLabelsUI   = @{}
            $phaseTaskPanels = @{}
            $phaseGlowBorders = @{}
            $prevPhaseStatuses = @{}

            foreach ($phaseNum in @('1','2','3','4','5','6','7','8','9')) {
                $prevPhaseStatuses[$phaseNum] = 'Pending'
                $phaseInfo = $phaseLabels[$phaseNum]

                $row = [System.Windows.Controls.Grid]::new()
                $row.Margin = [System.Windows.Thickness]::new(0, 3, 0, 3)

                $iconColumn = [System.Windows.Controls.ColumnDefinition]::new()
                $iconColumn.Width = [System.Windows.GridLength]::new(40)
                [void]$row.ColumnDefinitions.Add($iconColumn)

                $labelColumn = [System.Windows.Controls.ColumnDefinition]::new()
                $labelColumn.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
                [void]$row.ColumnDefinitions.Add($labelColumn)

                $glowGrid = [System.Windows.Controls.Grid]::new()
                $glowGrid.Width = 30; $glowGrid.Height = 30
                $glowGrid.Margin = [System.Windows.Thickness]::new(0, 0, 0, 0)
                $glowGrid.VerticalAlignment = 'Top'

                $glowBorder = [System.Windows.Controls.Border]::new()
                $glowBorder.CornerRadius = [System.Windows.CornerRadius]::new(15)
                $glowBorder.Width = 30; $glowBorder.Height = 30
                $glowBorder.Background = [System.Windows.Media.Brushes]::Transparent
                $glowBorder.Opacity = 0
                $glowBorder.IsHitTestVisible = $false

                $circleBorder = [System.Windows.Controls.Border]::new()
                $circleBorder.CornerRadius = [System.Windows.CornerRadius]::new(14)
                $circleBorder.Width = 28; $circleBorder.Height = 28
                $circleBorder.HorizontalAlignment = 'Center'
                $circleBorder.VerticalAlignment = 'Center'
                $circleBorder.BorderThickness = [System.Windows.Thickness]::new(2)
                $circleBorder.BorderBrush = [System.Windows.Media.SolidColorBrush]::new(
                    [System.Windows.Media.ColorConverter]::ConvertFromString('#3B4555'))
                $circleBorder.Background = [System.Windows.Media.Brushes]::Transparent
                $circleBorder.Effect = [System.Windows.Media.Effects.DropShadowEffect]@{
                    Color = '#000000'; BlurRadius = 4; ShadowDepth = 0; Opacity = 0.3; Direction = 270
                }

                $circleText = [System.Windows.Controls.TextBlock]::new()
                $circleText.Text = $phaseNum
                $circleText.FontSize = 12
                $circleText.FontWeight = 'SemiBold'
                $circleText.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe UI')
                $circleText.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                    [System.Windows.Media.ColorConverter]::ConvertFromString('#6B7280'))
                $circleText.HorizontalAlignment = 'Center'
                $circleText.VerticalAlignment = 'Center'

                $scaleTransform = [System.Windows.Media.ScaleTransform]::new(1.0, 1.0)
                $scaleTransform.CenterX = 14; $scaleTransform.CenterY = 14
                $circleBorder.RenderTransform = $scaleTransform

                $glowGrid.Children.Add($glowBorder) | Out-Null
                $glowGrid.Children.Add($circleBorder) | Out-Null
                $glowGrid.Children.Add($circleText) | Out-Null

                $lbl = [System.Windows.Controls.TextBlock]::new()
                $lbl.Text = $phaseInfo
                $lbl.FontSize = 13
                $lbl.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe UI')
                $lbl.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                    [System.Windows.Media.ColorConverter]::ConvertFromString('#9CA3AF'))
                $lbl.VerticalAlignment = 'Top'
                $lbl.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
                $lbl.TextWrapping = 'Wrap'

                [System.Windows.Controls.Grid]::SetColumn($glowGrid, 0)
                [System.Windows.Controls.Grid]::SetColumn($lbl, 1)
                $row.Children.Add($glowGrid) | Out-Null
                $row.Children.Add($lbl) | Out-Null

                $taskPanel = [System.Windows.Controls.StackPanel]::new()
                $taskPanel.Margin = [System.Windows.Thickness]::new(40, 2, 0, 4)
                $taskPanel.Opacity = 0; $taskPanel.MaxHeight = 0

                $wrapper = [System.Windows.Controls.StackPanel]::new()
                $wrapper.Children.Add($row) | Out-Null
                $wrapper.Children.Add($taskPanel) | Out-Null
                $phasePanel.Children.Add($wrapper) | Out-Null

                $phaseCircles[$phaseNum] = @{
                    Grid = $glowGrid; Border = $circleBorder; Text = $circleText; Scale = $scaleTransform
                }
                $phaseLabelsUI[$phaseNum]    = $lbl
                $phaseTaskPanels[$phaseNum]  = $taskPanel
                $phaseGlowBorders[$phaseNum] = $glowBorder
            }

            # ---------------------------------------------------------------
            # Refresh function — called via dispatcher on this STA thread
            # ---------------------------------------------------------------
            $refreshAction = {
                try {
                    $json = $Sync.TaskData
                    if ($null -eq $json) { return }

                    $Tasks = $json | ConvertFrom-Json
                    $expandedTaskPanelHeight = [Math]::Max(800.0, [double]$window.MaxHeight)

                    $checkMark = [char]0x2713

                    $phaseStatuses = @{}
                    foreach ($pn in @('1','2','3','4','5','6','7','8','9')) {
                        $phaseStatuses[$pn] = 'Pending'
                    }

                    $totalTasks = 0; $doneTasks = 0; $failCount = 0; $runningTaskDesc = $null

                    foreach ($t in $Tasks) {
                        if ($null -eq $t) { continue }
                        $totalTasks++
                        $p = [string]$t.Phase
                        switch ($t.Status) {
                            'Running'              { $phaseStatuses[$p] = 'Running'; $runningTaskDesc = $t.Description }
                            'Completed'            { $doneTasks++ }
                            'CompletedWithWarnings' { $doneTasks++ }
                            'Skipped'              { $doneTasks++ }
                            'Failed'               { $doneTasks++; $failCount++ }
                        }
                    }

                    foreach ($pn in @('1','2','3','4','5','6','7','8','9')) {
                        $pTasks = @($Tasks | Where-Object { $null -ne $_ -and [string]$_.Phase -eq $pn })
                        if ($pTasks.Count -eq 0) { continue }
                        $allDone = $true; $hasRunning = $false; $hasFailed = $false
                        foreach ($pt in $pTasks) {
                            if ($pt.Status -eq 'Running')  { $hasRunning = $true; $allDone = $false }
                            elseif ($pt.Status -eq 'Pending') { $allDone = $false }
                            elseif ($pt.Status -eq 'Failed')  { $hasFailed = $true }
                        }
                        if ($hasRunning)              { $phaseStatuses[$pn] = 'Running' }
                        elseif ($allDone -and $hasFailed) { $phaseStatuses[$pn] = 'Failed' }
                        elseif ($allDone)             { $phaseStatuses[$pn] = 'Completed' }
                    }

                    foreach ($pn in @('1','2','3','4','5','6','7','8','9')) {
                        $circle = $phaseCircles[$pn]
                        $label  = $phaseLabelsUI[$pn]
                        $tPanel = $phaseTaskPanels[$pn]
                        $glow   = $phaseGlowBorders[$pn]
                        $status = $phaseStatuses[$pn]
                        $prev   = $prevPhaseStatuses[$pn]
                        $isTransition = ($status -ne $prev)

                        switch ($status) {
                            'Completed' {
                                if ($isTransition) {
                                    $glow.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
                                    $glow.Opacity = 0

                                    $fillBrush = [System.Windows.Media.LinearGradientBrush]::new()
                                    $fillBrush.StartPoint = [System.Windows.Point]::new(0.3, 0)
                                    $fillBrush.EndPoint   = [System.Windows.Point]::new(0.7, 1)
                                    $fillBrush.GradientStops.Add([System.Windows.Media.GradientStop]::new(
                                        [System.Windows.Media.ColorConverter]::ConvertFromString('#60A5FA'), 0.0))
                                    $fillBrush.GradientStops.Add([System.Windows.Media.GradientStop]::new(
                                        [System.Windows.Media.ColorConverter]::ConvertFromString('#3B82F6'), 0.5))
                                    $fillBrush.GradientStops.Add([System.Windows.Media.GradientStop]::new(
                                        [System.Windows.Media.ColorConverter]::ConvertFromString('#2563EB'), 1.0))
                                    $circle.Border.Background = $fillBrush
                                    $circle.Border.BorderBrush = [System.Windows.Media.SolidColorBrush]::new(
                                        [System.Windows.Media.ColorConverter]::ConvertFromString('#60A5FA'))

                                    $popUp = [System.Windows.Media.Animation.DoubleAnimation]::new()
                                    $popUp.To = 1.25
                                    $popUp.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(150))
                                    $popUp.AutoReverse = $true
                                    $popUp.EasingFunction = [System.Windows.Media.Animation.CubicEase]@{ EasingMode = 'EaseOut' }
                                    $circle.Scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $popUp)
                                    $circle.Scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $popUp)

                                    Start-GlassAnimation -Target $tPanel -Property ([System.Windows.UIElement]::OpacityProperty) -To 0 -DurationMs 200
                                    $tPanel.MaxHeight = 0
                                }

                                $circle.Text.Text = [string]$checkMark
                                $circle.Text.FontSize = 14
                                $circle.Text.Foreground = [System.Windows.Media.Brushes]::White

                                if ($label.Foreground -isnot [System.Windows.Media.SolidColorBrush]) {
                                    $label.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                                        [System.Windows.Media.ColorConverter]::ConvertFromString('#4B5563'))
                                } else {
                                    Start-GlassColorAnimation -Brush $label.Foreground -ToColor '#4B5563' -DurationMs 400
                                }
                                $label.TextDecorations = [System.Windows.TextDecorations]::Strikethrough
                            }

                            'Running' {
                                $circle.Border.Background = [System.Windows.Media.Brushes]::Transparent

                                if ($circle.Border.BorderBrush -isnot [System.Windows.Media.SolidColorBrush]) {
                                    $circle.Border.BorderBrush = [System.Windows.Media.SolidColorBrush]::new(
                                        [System.Windows.Media.ColorConverter]::ConvertFromString('#3B82F6'))
                                } else {
                                    Start-GlassColorAnimation -Brush $circle.Border.BorderBrush -ToColor '#3B82F6' -DurationMs 300
                                }

                                $circle.Text.Text = $pn
                                $circle.Text.FontSize = 12
                                if ($circle.Text.Foreground -isnot [System.Windows.Media.SolidColorBrush]) {
                                    $circle.Text.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                                        [System.Windows.Media.ColorConverter]::ConvertFromString('#60A5FA'))
                                } else {
                                    Start-GlassColorAnimation -Brush $circle.Text.Foreground -ToColor '#60A5FA' -DurationMs 300
                                }

                                if ($label.Foreground -isnot [System.Windows.Media.SolidColorBrush]) {
                                    $label.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                                        [System.Windows.Media.ColorConverter]::ConvertFromString('#60A5FA'))
                                } else {
                                    Start-GlassColorAnimation -Brush $label.Foreground -ToColor '#60A5FA' -DurationMs 300
                                }
                                $label.TextDecorations = $null

                                if ($isTransition) {
                                    $glow.Background = [System.Windows.Media.SolidColorBrush]::new(
                                        [System.Windows.Media.ColorConverter]::ConvertFromString('#3B82F6'))
                                    Start-GlassAnimation -Target $glow -Property ([System.Windows.UIElement]::OpacityProperty) `
                                        -To 0.4 -DurationMs 800 -AutoReverse -Forever
                                }

                                $tPanel.Children.Clear()
                                $phaseTasks = @($Tasks | Where-Object { $null -ne $_ -and [string]$_.Phase -eq $pn })
                                foreach ($pt in $phaseTasks) {
                                    $tb = [System.Windows.Controls.TextBlock]::new()
                                    $tb.FontSize   = 11
                                    $tb.FontFamily = [System.Windows.Media.FontFamily]::new('Segoe UI')
                                    $tb.Margin     = [System.Windows.Thickness]::new(0, 1, 0, 1)
                                    $tb.TextWrapping = 'Wrap'
                                    switch ($pt.Status) {
                                        'Completed' {
                                            $tb.Text = "  $($checkMark)  $($pt.Description)"
                                            $tb.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                                                [System.Windows.Media.ColorConverter]::ConvertFromString('#4B5563'))
                                            $tb.TextDecorations = [System.Windows.TextDecorations]::Strikethrough
                                        }
                                        'CompletedWithWarnings' {
                                            $tb.Text = "  $($checkMark)  $($pt.Description)"
                                            $tb.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                                                [System.Windows.Media.ColorConverter]::ConvertFromString('#F59E0B'))
                                            $tb.TextDecorations = [System.Windows.TextDecorations]::Strikethrough
                                        }
                                        'Running' {
                                            $tb.Text = "  $([char]0x25B6)  $($pt.Description)"
                                            $tb.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                                                [System.Windows.Media.ColorConverter]::ConvertFromString('#60A5FA'))
                                        }
                                        'Failed' {
                                            $tb.Text = "  $([char]0x2717)  $($pt.Description)"
                                            $tb.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                                                [System.Windows.Media.ColorConverter]::ConvertFromString('#EF4444'))
                                        }
                                        'Skipped' {
                                            $tb.Text = "  -  $($pt.Description)"
                                            $tb.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                                                [System.Windows.Media.ColorConverter]::ConvertFromString('#4B5563'))
                                            $tb.TextDecorations = [System.Windows.TextDecorations]::Strikethrough
                                        }
                                        default {
                                            $tb.Text = "  $([char]0x25CB)  $($pt.Description)"
                                            $tb.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                                                [System.Windows.Media.ColorConverter]::ConvertFromString('#6B7280'))
                                        }
                                    }
                                    $tPanel.Children.Add($tb) | Out-Null
                                }

                                $tPanel.MaxHeight = $expandedTaskPanelHeight
                                Start-GlassAnimation -Target $tPanel -Property ([System.Windows.UIElement]::OpacityProperty) -To 1.0 -DurationMs 250
                            }

                            'Failed' {
                                if ($isTransition) {
                                    $glow.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
                                    $glow.Opacity = 0
                                }
                                $failGrad = [System.Windows.Media.LinearGradientBrush]::new()
                                $failGrad.StartPoint = [System.Windows.Point]::new(0.3, 0)
                                $failGrad.EndPoint   = [System.Windows.Point]::new(0.7, 1)
                                $failGrad.GradientStops.Add([System.Windows.Media.GradientStop]::new(
                                    [System.Windows.Media.ColorConverter]::ConvertFromString('#F87171'), 0.0))
                                $failGrad.GradientStops.Add([System.Windows.Media.GradientStop]::new(
                                    [System.Windows.Media.ColorConverter]::ConvertFromString('#EF4444'), 0.5))
                                $failGrad.GradientStops.Add([System.Windows.Media.GradientStop]::new(
                                    [System.Windows.Media.ColorConverter]::ConvertFromString('#DC2626'), 1.0))
                                $circle.Border.Background = $failGrad
                                $circle.Border.BorderBrush = [System.Windows.Media.SolidColorBrush]::new(
                                    [System.Windows.Media.ColorConverter]::ConvertFromString('#F87171'))
                                $circle.Text.Text = [char]0x2717
                                $circle.Text.FontSize = 13
                                $circle.Text.Foreground = [System.Windows.Media.Brushes]::White
                                $label.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                                    [System.Windows.Media.ColorConverter]::ConvertFromString('#EF4444'))
                                $label.TextDecorations = $null

                                Start-GlassAnimation -Target $tPanel -Property ([System.Windows.UIElement]::OpacityProperty) -To 0 -DurationMs 200
                                $tPanel.MaxHeight = 0
                            }

                            default {
                                $circle.Border.Background = [System.Windows.Media.Brushes]::Transparent
                                $circle.Border.BorderBrush = [System.Windows.Media.SolidColorBrush]::new(
                                    [System.Windows.Media.ColorConverter]::ConvertFromString('#3B4555'))
                                $circle.Text.Text = $pn
                                $circle.Text.FontSize = 12
                                $circle.Text.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                                    [System.Windows.Media.ColorConverter]::ConvertFromString('#6B7280'))
                                $label.Foreground = [System.Windows.Media.SolidColorBrush]::new(
                                    [System.Windows.Media.ColorConverter]::ConvertFromString('#6B7280'))
                                $label.TextDecorations = $null
                                $tPanel.MaxHeight = 0
                                $tPanel.Opacity = 0
                            }
                        }
                    }

                    foreach ($pn in @('1','2','3','4','5','6','7','8','9')) {
                        $prevPhaseStatuses[$pn] = $phaseStatuses[$pn]
                    }

                    if ($totalTasks -gt 0) {
                        $pct = [Math]::Round(($doneTasks / $totalTasks) * 100, 0)
                        $barMaxWidth = $progressFill.Parent.ActualWidth
                        if ($barMaxWidth -le 0) { $barMaxWidth = 300 }
                        $targetWidth = [Math]::Max(0, ($barMaxWidth * $doneTasks / $totalTasks))
                        Start-GlassAnimation -Target $progressFill `
                            -Property ([System.Windows.FrameworkElement]::WidthProperty) `
                            -To $targetWidth -DurationMs 500
                        $progressText.Text = "$doneTasks / $totalTasks tasks  ($pct%)"
                    }

                    if ($null -ne $runningTaskDesc) {
                        $titleStatus.Text = $runningTaskDesc
                    } elseif ($doneTasks -eq $totalTasks -and $totalTasks -gt 0) {
                        $titleStatus.Text = 'Complete!'
                    }

                    $window.InvalidateMeasure()
                    $window.UpdateLayout()
                    $Sync.TaskData = $null
                    $Sync.Error = $null
                } catch {
                    $Sync.Error = $_.Exception.Message
                    $Sync.TaskData = $null
                }
            }

            # ---------------------------------------------------------------
            # DispatcherTimer — polls synchronized hashtable for updates
            # ---------------------------------------------------------------
            $timer = [System.Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [TimeSpan]::FromMilliseconds(250)
            $timer.Add_Tick({
                $Sync.HeartbeatUtc = [DateTime]::UtcNow
                # Check for close request
                if ($Sync.CloseFlag) {
                    $window.Close()
                    return
                }
                # Check for data update
                if ($null -ne $Sync.TaskData) {
                    & $refreshAction
                }
            }.GetNewClosure())
            $timer.Start()

            # Signal readiness to main thread
            $Sync.Dispatcher = $window.Dispatcher
            $Sync.Window     = $window
            $Sync.Ready      = $true
            $Sync.HeartbeatUtc = [DateTime]::UtcNow

            # Show window and start message pump
            $window.Show()
            [System.Windows.Threading.Dispatcher]::Run()

        }).AddArgument($syncRef) | Out-Null

        # Launch the UI runspace asynchronously
        $null = $script:UiPipeline.BeginInvoke()

        # Wait for the UI thread to signal readiness (up to 10 seconds)
        $waitStart = [DateTime]::UtcNow
        while (-not $script:UiSync.Ready) {
            Start-Sleep -Milliseconds 50
            if (([DateTime]::UtcNow - $waitStart).TotalSeconds -gt 10) {
                if ($null -ne $script:UiPipeline -and $script:UiPipeline.Streams.Error.Count -gt 0) {
                    $uiError = $script:UiPipeline.Streams.Error[0]
                    Write-Log "Progress UI thread did not signal ready within 10s: $uiError" 'WARN'
                } else {
                    Write-Log 'Progress UI thread did not signal ready within 10s' 'WARN'
                }
                break
            }
        }

        if ($script:UiSync.Ready) {
            Write-Log 'Progress overlay started (liquid glass, STA runspace)' 'INFO'
        }
    } catch {
        Write-Log "Failed to start progress overlay: $_" 'WARN'
    }
}

function Test-ProgressWindowHeartbeatFresh {
    if ($null -eq $script:UiSync -or -not $script:UiSync.Ready) {
        return $false
    }

    $heartbeatUtc = $script:UiSync.HeartbeatUtc
    if ($null -eq $heartbeatUtc) {
        return $true
    }

    return (([DateTime]::UtcNow - [DateTime]$heartbeatUtc).TotalSeconds -le [double]$script:ProgressUiHeartbeatTimeoutSec)
}

function Disable-ProgressWindowWatchdog {
    if ($null -eq $script:UiSync) {
        return
    }

    try {
        if ($null -ne $script:UiSync.Dispatcher) {
            $script:UiSync.Dispatcher.BeginInvokeShutdown([System.Windows.Threading.DispatcherPriority]::Send) | Out-Null
        }
    } catch {
    }

    $script:UiSync = $null
    $script:UiPipeline = $null
    $script:UiRunspace = $null
}

function Close-ProgressWindow {
    if ($null -ne $script:UiSync) {
        $progressWindowHealthy = Test-ProgressWindowHeartbeatFresh
        try {
            $script:UiSync.CloseFlag = $true

            # Give the dispatcher timer a moment to process the close
            $waitStart = [DateTime]::UtcNow
            while ($null -ne $script:UiSync.Window -and
                   ([DateTime]::UtcNow - $waitStart).TotalSeconds -lt 3) {
                Start-Sleep -Milliseconds 100
            }

            # Force-shutdown the dispatcher if still alive
            if ($null -ne $script:UiSync.Dispatcher) {
                try {
                    $script:UiSync.Dispatcher.BeginInvokeShutdown(
                        [System.Windows.Threading.DispatcherPriority]::Send)
                } catch { }
            }
        } catch { }

        # Cleanup runspace
        try {
            if ($null -ne $script:UiPipeline) {
                if ($progressWindowHealthy) {
                    $script:UiPipeline.Stop()
                } else {
                    Write-Log 'Progress overlay heartbeat stopped responding. Skipping blocking Stop() during cleanup.' 'WARN'
                }
                $script:UiPipeline.Dispose()
            }
        } catch { }
        try {
            if ($null -ne $script:UiRunspace) {
                $script:UiRunspace.Close()
                $script:UiRunspace.Dispose()
            }
        } catch { }

        $script:UiSync     = $null
        $script:UiPipeline = $null
        $script:UiRunspace = $null
    }
}

function Update-ProgressUI {
    <#
    .SYNOPSIS
    Pushes task state to the UI runspace via the synchronized hashtable.
    The UI thread's DispatcherTimer picks up the data and renders it asynchronously.
    This call is non-blocking — the main thread never waits for the UI to render.
    #>
    param([object[]]$Tasks)

    if ($null -eq $script:UiSync -or -not $script:UiSync.Ready) { return }

    try {
        if (-not (Test-ProgressWindowHeartbeatFresh)) {
            if (-not $script:ProgressUiIssueLogged) {
                $script:ProgressUiIssueLogged = $true
                Add-RunInfrastructureIssue -Message "Progress overlay heartbeat stopped responding for more than $($script:ProgressUiHeartbeatTimeoutSec) seconds. Hunter disabled the overlay and continued headless." -Level 'WARN'
            }

            Disable-ProgressWindowWatchdog
            return
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$script:UiSync.Error) -and -not $script:ProgressUiIssueLogged) {
            $script:ProgressUiIssueLogged = $true
            Add-RunInfrastructureIssue -Message "Progress overlay refresh failed; task execution continued without a reliable live UI: $($script:UiSync.Error)" -Level 'WARN'
        }

        # Serialize task state to JSON — the UI thread deserializes independently
        $snapshot = [System.Collections.Generic.List[object]]::new()
        foreach ($task in @($Tasks)) {
            if ($null -eq $task) { continue }
            [void]$snapshot.Add([ordered]@{
                TaskId      = [string]$task.TaskId
                Phase       = [string]$task.Phase
                Description = [string]$task.Description
                Status      = [string]$task.Status
                Error       = if ($null -ne $task.Error) { [string]$task.Error } else { $null }
            })
        }
        $script:UiSync.TaskData = ($snapshot | ConvertTo-Json -Depth 4 -Compress)
    } catch {
        if (-not $script:ProgressUiIssueLogged) {
            $script:ProgressUiIssueLogged = $true
            Add-RunInfrastructureIssue -Message "Progress overlay updates failed; task execution continued without reliable UI refreshes: $($_.Exception.Message)" -Level 'WARN'
        }
    }
}

function Update-ProgressState {
    param([object[]]$Tasks)
    Update-ProgressUI -Tasks $Tasks
}

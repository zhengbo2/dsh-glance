# dsh-glance · 置顶小条（界面层）
#
# 由 DSH 插件拉起，读 ~/.dsh/glance/state.json，画一个置顶的小窗：
#   空闲 → 一颗球 ；有任务 → 丝滑长成一小条 ；点 ▸ 展开详情
#
# 注意：本文件必须是 UTF-8 **带 BOM**，否则 Windows PowerShell 5.1 会按 GBK 读，
# 中文会把引号吃掉导致语法错误（这个坑踩过一次）。

param(
    [int]$PollMs = 120
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$ErrorActionPreference = 'Stop'

$GlanceHome = $env:DSH_HOME
if ([string]::IsNullOrWhiteSpace($GlanceHome)) { $GlanceHome = Join-Path $HOME '.dsh' }
$GlanceDir  = Join-Path $GlanceHome 'glance'
$StateFile  = Join-Path $GlanceDir 'state.json'
$UiFile     = Join-Path $GlanceDir 'ui.json'
$LogFile    = Join-Path $GlanceDir 'ui.log'

function Write-Log($msg) {
    try {
        if (-not (Test-Path $GlanceDir)) { New-Item -ItemType Directory -Path $GlanceDir -Force | Out-Null }
        $line = '[' + (Get-Date -Format 'HH:mm:ss.fff') + '] ' + $msg
        Add-Content -Path $LogFile -Value $line -Encoding utf8
    } catch {}
}

# ---- Win32：强制显示 + 不抢焦点 -----------------------------------------
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class GlanceWin {
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
  [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int idx, int val);
  public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
  public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
  public const uint SWP_NOMOVE = 0x0002, SWP_NOSIZE = 0x0001, SWP_NOACTIVATE = 0x0010, SWP_SHOWWINDOW = 0x0040;
  public const int GWL_EXSTYLE = -20;
  public const int WS_EX_NOACTIVATE = 0x08000000;
  public const int WS_EX_TOOLWINDOW = 0x00000080;
}
"@

# ---- 单实例：已经有一个在跑，就直接退出 --------------------------------
try {
    $script:Mutex = New-Object System.Threading.Mutex($false, 'Local\dsh-glance-ui')
    if (-not $script:Mutex.WaitOne(0)) {
        Write-Log '已有实例在跑，本次退出'
        exit 0
    }
} catch {
    Write-Log ('互斥锁创建失败，继续单跑: ' + $_.Exception.Message)
}

# ---- 颜色 --------------------------------------------------------------
$C = @{
    idle    = '#9AA3B2'
    thought = '#3B7FF5'
    running = '#D98A1F'
    waiting = '#E06A12'
    done    = '#1F9D55'
    error   = '#D93B3B'
}
$Ink     = '#1B1F27'
$InkDim  = '#6B7280'
$Surface = '#FFFFFF'
$Line    = '#E2E6EE'

function Brush($hex) {
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
    return [System.Windows.Media.SolidColorBrush]::new($c)
}

# ---- 读会话状态 --------------------------------------------------------
function Read-State {
    if (-not (Test-Path $StateFile)) { return $null }
    try {
        $raw = Get-Content -Path $StateFile -Raw -Encoding utf8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

# ---- 读/写窗口自己的状态 ------------------------------------------------
function Read-Ui {
    $d = @{ left = $null; top = $null; opacity = 0.92; topmost = $true }
    if (Test-Path $UiFile) {
        try {
            $o = Get-Content -Path $UiFile -Raw -Encoding utf8 | ConvertFrom-Json
            if ($null -ne $o.left)    { $d.left = [double]$o.left }
            if ($null -ne $o.top)     { $d.top = [double]$o.top }
            if ($null -ne $o.opacity) { $d.opacity = [double]$o.opacity }
            if ($null -ne $o.topmost) { $d.topmost = [bool]$o.topmost }
        } catch {}
    }
    return $d
}

function Save-Ui {
    try {
        if (-not (Test-Path $GlanceDir)) { New-Item -ItemType Directory -Path $GlanceDir -Force | Out-Null }
        $script:Win.Left = [math]::Round($script:Win.Left)
        $script:Win.Top  = [math]::Round($script:Win.Top)
        $o = @{
            left    = [math]::Round($script:Win.Left)
            top     = [math]::Round($script:Win.Top)
            opacity = [math]::Round($script:Ui.opacity, 2)
            topmost = [bool]$script:Ui.topmost
        }
        Set-Content -Path $UiFile -Value ($o | ConvertTo-Json -Compress) -Encoding utf8
    } catch {}
}

$script:Ui = Read-Ui

# ---- 建窗 --------------------------------------------------------------
$win = New-Object System.Windows.Window
$win.WindowStyle = 'None'
$win.AllowsTransparency = $true
$win.Background = [System.Windows.Media.Brushes]::Transparent
$win.Topmost = [bool]$script:Ui.topmost
$win.ShowInTaskbar = $false
$win.ShowActivated = $false
$win.ResizeMode = 'NoResize'
$win.Width = 42
$win.Height = 42
$win.WindowStartupLocation = 'Manual'
# 位置对齐 + 像素对齐：小数坐标会让圆点和圆边糊成一团
$win.UseLayoutRounding = $true
$win.SnapsToDevicePixels = $true

$border = New-Object System.Windows.Controls.Border
$border.CornerRadius = New-Object System.Windows.CornerRadius(21)
$border.SnapsToDevicePixels = $true
$border.Background = Brush $Surface
$border.BorderThickness = New-Object System.Windows.Thickness(1)
$border.BorderBrush = Brush '#D6DCE6'
$shadow = New-Object System.Windows.Media.Effects.DropShadowEffect
$shadow.BlurRadius = 16
$shadow.ShadowDepth = 3
$shadow.Opacity = 0.26
$border.Effect = $null
$win.Content = $border

$grid = New-Object System.Windows.Controls.Grid
$grid.Margin = New-Object System.Windows.Thickness(14, 0, 9, 0)
$border.Child = $grid
$cd0 = New-Object System.Windows.Controls.ColumnDefinition
$cd0.Width = [System.Windows.GridLength]::Auto
[void]$grid.ColumnDefinitions.Add($cd0)
$cd1 = New-Object System.Windows.Controls.ColumnDefinition
$cd1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
[void]$grid.ColumnDefinitions.Add($cd1)

$dot = New-Object System.Windows.Shapes.Ellipse
$dot.Width = 9
$dot.Height = 9
$dot.Fill = Brush $C.idle
$dot.VerticalAlignment = 'Center'
$dot.HorizontalAlignment = 'Left'
[System.Windows.Controls.Grid]::SetColumn($dot, 0)
[void]$grid.Children.Add($dot)

$stack = New-Object System.Windows.Controls.StackPanel
$stack.Orientation = 'Horizontal'
$stack.VerticalAlignment = 'Center'
$stack.Margin = New-Object System.Windows.Thickness(9, 0, 0, 0)
$stack.Opacity = 0
[System.Windows.Controls.Grid]::SetColumn($stack, 1)
[void]$grid.Children.Add($stack)

$font = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI')

$txtState = New-Object System.Windows.Controls.TextBlock
$txtState.FontFamily = $font
$txtState.FontSize = 13
$txtState.Foreground = Brush $Ink
$txtState.VerticalAlignment = 'Center'
[void]$stack.Children.Add($txtState)

$txtTime = New-Object System.Windows.Controls.TextBlock
$txtTime.FontFamily = $font
$txtTime.FontSize = 12
$txtTime.Foreground = Brush $InkDim
$txtTime.VerticalAlignment = 'Center'
$txtTime.Margin = New-Object System.Windows.Thickness(5, 0, 0, 0)
[void]$stack.Children.Add($txtTime)

$btnExp = New-Object System.Windows.Controls.Border
$btnExp.CornerRadius = New-Object System.Windows.CornerRadius(6)
$btnExp.BorderThickness = New-Object System.Windows.Thickness(1)
$btnExp.BorderBrush = Brush $Line
$btnExp.Padding = New-Object System.Windows.Thickness(6, 1, 6, 1)
$btnExp.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
$btnExp.VerticalAlignment = 'Center'
$btnExp.Cursor = [System.Windows.Input.Cursors]::Hand
$btnExp.Opacity = 0
$btnExp.IsHitTestVisible = $false
$btnExpText = New-Object System.Windows.Controls.TextBlock
$btnExpText.Text = '▸'
$btnExpText.FontSize = 11
$btnExpText.Foreground = Brush $InkDim
$btnExp.Child = $btnExpText
[void]$stack.Children.Add($btnExp)

# ---- 状态 --------------------------------------------------------------
$script:Win = $win
$script:Expanded = $false
$script:Phase = 'idle'
$script:Since = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$script:Detail = ''
$script:Tool = ''
$script:Busy = $false
# 这一趟的开始时间（脚本作用域）；状态变来变去都不重置
$script:TaskSince = 0

# 展开后的详情（第二个 TextBlock，单独放在下面一行）
$detailPanel = New-Object System.Windows.Controls.StackPanel
$detailPanel.Orientation = 'Vertical'
$detailPanel.Margin = New-Object System.Windows.Thickness(14, 0, 12, 0)
$detailPanel.VerticalAlignment = 'Center'
$detailPanel.Visibility = 'Collapsed'
$detailPanel.HorizontalAlignment = 'Left'

$txtDetail = New-Object System.Windows.Controls.TextBlock
$txtDetail.FontFamily = $font
$txtDetail.FontSize = 12.5
$txtDetail.Foreground = Brush $Ink
$txtDetail.TextWrapping = 'Wrap'
$txtDetail.MaxWidth = 280
[void]$detailPanel.Children.Add($txtDetail)

$txtMeta = New-Object System.Windows.Controls.TextBlock
$txtMeta.FontFamily = $font
$txtMeta.FontSize = 11
$txtMeta.Foreground = Brush $InkDim
$txtMeta.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
[void]$detailPanel.Children.Add($txtMeta)

$outer = New-Object System.Windows.Controls.StackPanel
$outer.Orientation = 'Vertical'
$row = New-Object System.Windows.Controls.Grid
$row.Margin = New-Object System.Windows.Thickness(0, 0, 0, 0)
[void]$outer.Children.Add($row)

$scroll = New-Object System.Windows.Controls.ScrollViewer
$scroll.VerticalScrollBarVisibility = 'Auto'
$scroll.HorizontalScrollBarVisibility = 'Disabled'
$scroll.MaxHeight = 190
$scroll.Margin = New-Object System.Windows.Thickness(0, 2, 0, 0)
$scroll.Content = $detailPanel
[void]$outer.Children.Add($scroll)

# 把原来挂在 border 上的 grid 换成 outer（行 + 详情）
# 整窗内容分两层：一层是「条/详情」，一层是「空闲的球点」
$ballDot = New-Object System.Windows.Shapes.Ellipse
$ballDot.Width = 10
$ballDot.Height = 10
$ballDot.Fill = Brush $C.idle
$ballDot.HorizontalAlignment = 'Center'
$ballDot.VerticalAlignment = 'Center'
$ballDot.Visibility = 'Visible'

$rootLayer = New-Object System.Windows.Controls.Grid
[void]$rootLayer.Children.Add($outer)
[void]$rootLayer.Children.Add($ballDot)
$border.Child = $rootLayer
[void]$row.Children.Add($grid)
$grid.Margin = New-Object System.Windows.Thickness(14, 0, 9, 0)
$row.Height = 36.0

function Ease {
    $e = New-Object System.Windows.Media.Animation.CubicEase
    $e.EasingMode = 'EaseOut'
    return $e
}

function Animate-Number($target, $prop, $from, $to, $ms) {
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation($to, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds($ms)))
    $anim.EasingFunction = Ease
    $target.BeginAnimation($prop, $anim)
}

function Measure-PillWidth {
    # 用 TextBlock 自己量：状态字 + 时间 + 按钮
    $txtState.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
    $txtTime.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
    $btnExp.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
    $w = 14 + 9 + 9 + $txtState.DesiredSize.Width + 5 + $txtTime.DesiredSize.Width + 8 + $btnExp.DesiredSize.Width + 9
    return [math]::Ceiling($w)
}

function Apply-Shape {
    if ($script:Busy) { return }
    $script:Busy = $true
    try {
        $active = $script:Phase -ne 'idle'

        if (-not $active) {
            $script:Expanded = $false
            $detailPanel.Visibility = 'Collapsed'
            $stack.Visibility = 'Collapsed'
            $btnExp.Visibility = 'Collapsed'
            Animate-Number $win ([System.Windows.Window]::WidthProperty)  $win.Width  42 320
            Animate-Number $win ([System.Windows.Window]::HeightProperty) $win.Height 42 320
            $border.CornerRadius = New-Object System.Windows.CornerRadius(21)
            $row.Height = 42.0
            $grid.Margin = New-Object System.Windows.Thickness(0)
            # 空闲：只留中间那颗球点，去掉阴影（阴影会画出一个方块）
            $outer.Visibility = 'Collapsed'
            $ballDot.Visibility = 'Visible'
            $ballDot.Fill = $dot.Fill
            $border.Effect = $null
        }
        else {
            # 条状态：显示内容层，恢复阴影
            $outer.Visibility = 'Visible'
            $ballDot.Visibility = 'Collapsed'
            $border.Effect = $null
            $dot.HorizontalAlignment = 'Left'
            [System.Windows.Controls.Grid]::SetColumnSpan($dot, 1)
            $stack.Visibility = 'Visible'
            $btnExp.Visibility = 'Visible'
            $row.Height = 36.0
            $grid.Margin = New-Object System.Windows.Thickness(14, 0, 9, 0)

            # 展开时窗口要按卡片的宽度来，否则卡片会被窗口裁掉、露出边框（就是那圈白底）
            $targetW = if ($script:Expanded) { 320 } else { Measure-PillWidth }
            $targetH = if ($script:Expanded) { 96 } else { 36 }

            Animate-Number $win ([System.Windows.Window]::WidthProperty)  $win.Width  $targetW 380
            Animate-Number $win ([System.Windows.Window]::HeightProperty) $win.Height $targetH 380

            $border.CornerRadius = New-Object System.Windows.CornerRadius($(if ($script:Expanded) { 12 } else { 18 }))

            $fo = New-Object System.Windows.Media.Animation.DoubleAnimation(1, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(200)))
            $fo.BeginTime = [TimeSpan]::FromMilliseconds(70)
            $stack.BeginAnimation([System.Windows.Controls.StackPanel]::OpacityProperty, $fo)

            $fb = New-Object System.Windows.Media.Animation.DoubleAnimation(1, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(180)))
            $fb.BeginTime = [TimeSpan]::FromMilliseconds(140)
            $btnExp.BeginAnimation([System.Windows.Controls.Border]::OpacityProperty, $fb)
            $btnExp.IsHitTestVisible = $true
            # 回一条时恢复阴影
            $border.Effect = $null

            if ($script:Expanded) {
                $detailPanel.Visibility = 'Visible'
                $txtDetail.Text = if ($script:Detail) { $script:Detail } else { '（这一步还没有可以说的话）' }
                $parts = @()
                if ($script:Tool) { $parts += ('工具  ' + $script:Tool) }
                $parts += ('状态  ' + $script:Phase)
                $txtMeta.Text = ($parts -join '    ')
            }
            else {
                $detailPanel.Visibility = 'Collapsed'
            }

            # 展开时按内容重新量高度（写死的高度会把文字切掉）
            if ($script:Expanded) {
                $detailPanel.Measure([System.Windows.Size]::new(280, [double]::PositiveInfinity))
                $contentH = [math]::Ceiling($detailPanel.DesiredSize.Height)
                if ($contentH -gt 190) { $contentH = 190 }
                $needH = 36 + $contentH + 18
                if ($needH -lt 78) { $needH = 78 }
                Animate-Number $win ([System.Windows.Window]::HeightProperty) $win.Height $needH 380
                # 展开成卡片时不要阴影：窗口贴着卡片大小，阴影会在边缘糊出一圈白底
                $border.Effect = $null
            }
        }
    }
    finally {
        $script:Busy = $false
    }
}

function Refresh-Elapsed {
    if ($script:Phase -eq 'idle') { $txtTime.Text = ''; return }
    $base = if ($script:TaskSince -gt 0) { $script:TaskSince } else { $script:Since }
    $ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $base
    if ($ms -lt 0) { $ms = 0 }
    $s = [int]([math]::Floor($ms / 1000))
    $m = [int][math]::Floor($s / 60)
    $txtTime.Text = '· ' + ('{0}:{1:d2}' -f $m, ($s % 60))
}

# ---- 每 120ms 读一次状态 -----------------------------------------------
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds($PollMs)
$timer.Add_Tick({
    # 父程序没了就自己退出（DSH 关了不该留一个孤儿窗）
    if (-not (Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)) {
        $script:Missed++
        if ($script:Missed -ge 10) {
            Write-Log 'DSH 已退出，小窗跟着关'
            try { $win.Close() } catch {}
            return
        }
    } else {
        $script:Missed = 0
    }

    $s = Read-State
    if ($null -eq $s) { return }

    $phase = [string]$s.state
    $tone  = [string]$s.tone
    $changed = ($phase -ne $script:Phase)

    if ($phase -eq 'idle') {
        $script:TaskSince = 0
    } elseif ($script:TaskSince -le 0) {
        $script:TaskSince = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }

    $script:Phase  = $phase
    $script:Detail = [string]$s.detail
    $script:Tool   = [string]$s.tool
    if ($null -ne $s.since) { $script:Since = [long]$s.since }

    $txtState.Text = [string]$s.label
    if ($C.ContainsKey($tone)) { $dot.Fill = Brush $C[$tone] }

    Refresh-Elapsed
    if ($changed) {
        if ($phase -eq 'idle') { $btnExpText.Text = '▸' }
        Apply-Shape
    }
})
$timer.Start()

# ---- 拖动：只移动，不展开 ----------------------------------------------
$dragStart = $null
$win.Add_MouseLeftButtonDown({
    param($sender, $e)
    if ($e.OriginalSource -eq $btnExp -or ($btnExp.IsMouseOver)) { return }
    $dragStart = @{ x = $e.GetPosition($win).X; y = $e.GetPosition($win).Y }
    try { $win.DragMove() } catch {}
    $dragStart = $null
    Save-Ui
})

# 点 ▸ 才展开
$btnExp.Add_MouseLeftButtonUp({
    param($sender, $e)
    $e.Handled = $true
    $script:Expanded = -not $script:Expanded
    $btnExpText.Text = if ($script:Expanded) { '✕' } else { '▸' }
    Apply-Shape
})

# ---- 右键：透明度 + 置顶 ------------------------------------------------
$win.Add_MouseRightButtonUp({
    param($sender, $e)
    $e.Handled = $true

    $menu = New-Object System.Windows.Controls.ContextMenu
    $menu.Background = Brush $Surface

    $miAlpha = New-Object System.Windows.Controls.MenuItem
    $miAlpha.Header = '透明度'
    $slider = New-Object System.Windows.Controls.Slider
    $slider.Minimum = 25
    $slider.Maximum = 100
    $slider.Value = [math]::Round($script:Ui.opacity * 100)
    $slider.Width = 140
    $slider.Margin = New-Object System.Windows.Thickness(8, 2, 8, 6)
    $slider.Add_ValueChanged({
        param($s2, $e2)
        $script:Ui.opacity = [double]$s2.Value / 100.0
        $win.Opacity = $script:Ui.opacity
        Save-Ui
    })
    $miAlpha.Items.Add($slider) | Out-Null

    $miTop = New-Object System.Windows.Controls.MenuItem
    $miTop.Header = '始终置顶'
    $miTop.IsCheckable = $true
    $miTop.IsChecked = [bool]$script:Ui.topmost
    $miTop.Add_Click({
        $script:Ui.topmost = -not $script:Ui.topmost
        $win.Topmost = [bool]$script:Ui.topmost
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($win)
        $after = if ($script:Ui.topmost) { [GlanceWin]::HWND_TOPMOST } else { [GlanceWin]::HWND_NOTOPMOST }
        [GlanceWin]::SetWindowPos($helper.Handle, $after, 0, 0, 0, 0, ([GlanceWin]::SWP_NOMOVE -bor [GlanceWin]::SWP_NOSIZE -bor [GlanceWin]::SWP_NOACTIVATE)) | Out-Null
        Save-Ui
    })

    $miHide = New-Object System.Windows.Controls.MenuItem
    $miHide.Header = '隐藏（关 DSH 一起关）'
    $miHide.Add_Click({ $win.Hide() })

    [void]$menu.Items.Add($miAlpha)
    [void]$menu.Items.Add($miTop)
    [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
    [void]$menu.Items.Add($miHide)
    $menu.PlacementTarget = $win
    $menu.IsOpen = $true
})

# ---- 首次显示：居中 + 强制显示（父进程是 Hidden，必须自己亮出来）-------
$win.Add_Loaded({
    $helper = New-Object System.Windows.Interop.WindowInteropHelper($win)
    $hwnd = $helper.Handle

    # 不抢焦点 + 不在 Alt+Tab 里出现
    $ex = [GlanceWin]::GetWindowLong($hwnd, [GlanceWin]::GWL_EXSTYLE)
    [GlanceWin]::SetWindowLong($hwnd, [GlanceWin]::GWL_EXSTYLE, ($ex -bor [GlanceWin]::WS_EX_NOACTIVATE -bor [GlanceWin]::WS_EX_TOOLWINDOW)) | Out-Null

    [GlanceWin]::ShowWindow($hwnd, 5) | Out-Null
    $after = if ($script:Ui.topmost) { [GlanceWin]::HWND_TOPMOST } else { [GlanceWin]::HWND_NOTOPMOST }
    [GlanceWin]::SetWindowPos($hwnd, $after, 0, 0, 0, 0, ([GlanceWin]::SWP_NOMOVE -bor [GlanceWin]::SWP_NOSIZE -bor [GlanceWin]::SWP_SHOWWINDOW)) | Out-Null

    # 位置：有记录就回到上次，没有就屏幕中央
    $area = [System.Windows.SystemParameters]::WorkArea
    if ($null -ne $script:Ui.left -and $null -ne $script:Ui.top) {
        $win.Left = [math]::Round([double]$script:Ui.left)
        $win.Top  = [math]::Round([double]$script:Ui.top)
    }
    else {
        $win.Left = $area.Left + ($area.Width  - $win.Width)  / 2
        $win.Top  = $area.Top  + ($area.Height - $win.Height) / 2
    }
    $win.Opacity = [double]$script:Ui.opacity

    Write-Log ('window ready  hwnd=' + $hwnd + '  at ' + [math]::Round($win.Left) + ',' + [math]::Round($win.Top))
})

try {
    [void]$win.ShowDialog()
} catch {
    Write-Log ('崩溃: ' + $_.Exception.Message)
}

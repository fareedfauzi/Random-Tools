@echo off
set "BATCH_PATH=%~f0"
set "TARGET_PATH=%~1"
powershell -NoProfile -ExecutionPolicy Bypass -STA -Command "$script = [System.IO.File]::ReadAllText($env:BATCH_PATH); $code = $script.Substring($script.IndexOf('GOTO' + ' :EOF') + 9); Invoke-Expression $code"
GOTO :EOF

# --- POWERSHELL CODE BEGINS HERE ---
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# Define User32 PinVoke to destroy icons and prevent memory leaks
if (-not ([System.Management.Automation.PSTypeName]'Win32.User32Icons').Type) {
    $signature = @'
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
    public static extern bool DestroyIcon(System.IntPtr handle);
'@
    Add-Type -MemberDefinition $signature -Name "User32Icons" -Namespace "Win32" -ErrorAction SilentlyContinue | Out-Null
}

# Resolves a .lnk shortcut to its target path
function Resolve-Shortcut {
    param([string]$path)
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($path)
        $target = [System.Environment]::ExpandEnvironmentVariables($shortcut.TargetPath)
        if ([string]::IsNullOrEmpty($target)) {
            return $path
        }
        return $target
    } catch {
        return $path
    }
}

# Extracts executable's icon and converts to WPF Image Source
function Get-WpfIcon {
    param([string]$FilePath)
    try {
        if (Test-Path -LiteralPath $FilePath) {
            $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($FilePath)
            $hIcon = $icon.Handle
            $bitmapSource = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                $hIcon,
                [System.Windows.Int32Rect]::Empty,
                [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions()
            )
            $icon.Dispose()
            try {
                [Win32.User32Icons]::DestroyIcon($hIcon) | Out-Null
            } catch {}
            return $bitmapSource
        }
    } catch {}
    return $null
}

# Query all custom registered programs from HKCU
function Get-RegisteredPrograms {
    $programs = @()
    $classesKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\Classes")
    if ($classesKey -ne $null) {
        $starKey = $classesKey.OpenSubKey("*")
        if ($starKey -ne $null) {
            $shellKey = $starKey.OpenSubKey("shell")
            if ($shellKey -ne $null) {
                $subKeyNames = $shellKey.GetSubKeyNames()
                foreach ($name in $subKeyNames) {
                    if ($name -like "OpenWith_*") {
                        $key = $shellKey.OpenSubKey($name)
                        $friendlyName = $key.GetValue("")
                        if ([string]::IsNullOrEmpty($friendlyName)) {
                            $friendlyName = $name.Substring(9)
                        } else {
                            if ($friendlyName.StartsWith("Open with ", [System.StringComparison]::OrdinalIgnoreCase)) {
                                $friendlyName = $friendlyName.Substring(10)
                            }
                        }
                        
                        $path = ""
                        $cmdKey = $key.OpenSubKey("command")
                        if ($cmdKey -ne $null) {
                            $cmdVal = $cmdKey.GetValue("")
                            if ($cmdVal -match '^"([^"]+)"') {
                                $path = $matches[1]
                            } elseif ($cmdVal -match '^([^\s]+)') {
                                $path = $matches[1]
                            } else {
                                $path = $cmdVal
                            }
                            $cmdKey.Close()
                        }
                        
                        $programs += [PSCustomObject]@{
                            KeyName      = $name
                            FriendlyName = $friendlyName
                            Path         = $path
                        }
                        $key.Close()
                    }
                }
                $shellKey.Close()
            }
            $starKey.Close()
        }
        $classesKey.Close()
    }
    return $programs
}

# Removes a custom registered program from context menu
function Remove-RegisteredProgram {
    param([string]$KeyName)
    try {
        $classesKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\Classes", $true)
        if ($classesKey -ne $null) {
            $starKey = $classesKey.OpenSubKey("*", $true)
            if ($starKey -ne $null) {
                $shellKey = $starKey.OpenSubKey("shell", $true)
                if ($shellKey -ne $null) {
                    $shellKey.DeleteSubKeyTree($KeyName, $false)
                    $shellKey.Close()
                }
                $starKey.Close()
            }
            $classesKey.Close()
        }
    } catch {
        [System.Windows.MessageBox]::Show("Failed to remove program: $_", "Error", 'OK', 'Error')
    }
}

# Checks if context menu extension is installed
function Is-ExtensionInstalled {
    $classesKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\Classes")
    if ($classesKey -ne $null) {
        $exeKey = $classesKey.OpenSubKey("exefile\shell\AddToOpenWith")
        $lnkKey = $classesKey.OpenSubKey("lnkfile\shell\AddToOpenWith")
        $installed = ($exeKey -ne $null) -and ($lnkKey -ne $null)
        if ($exeKey -ne $null) { $exeKey.Close() }
        if ($lnkKey -ne $null) { $lnkKey.Close() }
        $classesKey.Close()
        return $installed
    }
    return $false
}

# Installs context menu extension
function Install-Extension {
    try {
        $classes = @("exefile", "lnkfile")
        foreach ($class in $classes) {
            $keyPath = "Software\Classes\$class\shell\AddToOpenWith"
            $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($keyPath)
            $key.SetValue("", "Add to 'Open With' Menu")
            $key.SetValue("Icon", "shell32.dll,-16769")
            
            $cmdKey = $key.CreateSubKey("command")
            $commandValue = 'cmd.exe /c ""{0}" "%1""' -f $env:BATCH_PATH
            $cmdKey.SetValue("", $commandValue)
            
            $cmdKey.Close()
            $key.Close()
        }
        [System.Windows.MessageBox]::Show("Successfully installed right-click context menu extension!`n`nYou can now right-click any .exe or shortcut (.lnk) and select 'Add to Open With Menu'.", "Extension Installed", 'OK', 'Information')
    } catch {
        [System.Windows.MessageBox]::Show("Failed to install extension: $_", "Error", 'OK', 'Error')
    }
}

# Uninstalls context menu extension
function Uninstall-Extension {
    try {
        $classes = @("exefile", "lnkfile")
        foreach ($class in $classes) {
            $keyPath = "Software\Classes\$class\shell"
            $shellKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($keyPath, $true)
            if ($shellKey -ne $null) {
                $shellKey.DeleteSubKeyTree("AddToOpenWith", $false)
                $shellKey.Close()
            }
        }
        [System.Windows.MessageBox]::Show("Successfully uninstalled right-click context menu extension.", "Extension Uninstalled", 'OK', 'Information')
    } catch {
        [System.Windows.MessageBox]::Show("Failed to uninstall extension: $_", "Error", 'OK', 'Error')
    }
}

# --- PROCESS COMMAND LINE INVOCATION ---
$targetPath = $env:TARGET_PATH
$openManager = $false

if (-not [string]::IsNullOrEmpty($targetPath)) {
    if ($targetPath.EndsWith(".lnk", [System.StringComparison]::OrdinalIgnoreCase)) {
        $targetPath = Resolve-Shortcut -path $targetPath
    }
    
    if (-not (Test-Path $targetPath)) {
        [System.Windows.MessageBox]::Show("Error: The program file does not exist.`nPath: $targetPath", "Error", 'OK', 'Error')
        Exit
    }
    
    $progName = (Get-Item $targetPath).BaseName
    $keyName = "OpenWith_" + $progName.Replace(" ", "_")
    
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("Software\Classes\*\shell\$keyName")
        $key.SetValue("", "Open with $progName")
        $key.SetValue("Icon", $targetPath)
        
        $cmdKey = $key.CreateSubKey("command")
        $cmdKey.SetValue("", ('"{0}" "%1"' -f $targetPath))
        
        $cmdKey.Close()
        $key.Close()
        
        $result = [System.Windows.MessageBox]::Show("Successfully registered '$progName' to your 'Open with...' context menu.`n`nWould you like to open the Context Menu Manager?", "Registration Successful", 'YesNo', 'Information')
        if ($result -eq 'Yes') {
            $openManager = $true
        } else {
            Exit
        }
    } catch {
        [System.Windows.MessageBox]::Show("Failed to register program: $_", "Error", 'OK', 'Error')
        Exit
    }
}

# --- LOAD MANAGER GUI ---
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="OpenWith" Height="600" Width="460"
        Background="#121212" Foreground="#ffffff" FontFamily="Segoe UI"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize">
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="70"/>
            <RowDefinition Height="90"/>
            <RowDefinition Height="90"/>
            <RowDefinition Height="40"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="40"/>
        </Grid.RowDefinitions>
        
        <!-- Header Panel -->
        <Border Grid.Row="0" Background="#1E1E1E" BorderBrush="#2D2D2D" BorderThickness="0,0,0,1">
            <StackPanel VerticalAlignment="Center" Margin="20,0,20,0">
                <TextBlock Text="OpenWith" FontWeight="SemiBold" FontSize="20" Foreground="#FFFFFF"/>
                <TextBlock Text="Easily configure program shortcuts for any file" FontSize="11" Foreground="#888888" Margin="0,2,0,0"/>
            </StackPanel>
        </Border>
        
        <!-- Extension Status Card -->
        <Border Grid.Row="1" Background="#1A1A1A" CornerRadius="6" Margin="20,10,20,10" Padding="15,10" BorderBrush="#2D2D2D" BorderThickness="1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                
                <StackPanel VerticalAlignment="Center">
                    <TextBlock Text="Right-Click Extension" FontWeight="SemiBold" FontSize="13" Foreground="#E0E0E0"/>
                    <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
                        <TextBlock Text="Status: " FontSize="11" Foreground="#888888"/>
                        <TextBlock Name="StatusText" Text="Checking..." FontSize="11" FontWeight="Bold" Foreground="#888888"/>
                    </StackPanel>
                </StackPanel>
                
                <Border Name="StatusButton" Grid.Column="1" Background="#0078D4" Width="120" Height="28" CornerRadius="4" Cursor="Hand" VerticalAlignment="Center">
                    <TextBlock Name="StatusButtonText" Text="Install" Foreground="White" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
            </Grid>
        </Border>
        
        <!-- Register a Program Card -->
        <Border Grid.Row="2" Background="#1A1A1A" CornerRadius="6" Margin="20,0,20,10" Padding="15,10" BorderBrush="#2D2D2D" BorderThickness="1">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                
                <StackPanel VerticalAlignment="Center">
                    <TextBlock Text="Register a Program" FontWeight="SemiBold" FontSize="13" Foreground="#E0E0E0"/>
                    <TextBlock Text="Browse and add a program directly" FontSize="11" Foreground="#888888" Margin="0,4,0,0"/>
                </StackPanel>
                
                <Border Name="AddProgramButton" Grid.Column="1" Background="#0078D4" Width="120" Height="28" CornerRadius="4" Cursor="Hand" VerticalAlignment="Center">
                    <TextBlock Name="AddProgramButtonText" Text="Add Program" Foreground="White" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
            </Grid>
        </Border>
        
        <!-- Programs Header -->
        <Grid Grid.Row="3" Margin="20,5,20,0">
            <TextBlock Text="Registered Programs" FontWeight="SemiBold" FontSize="14" Foreground="#E0E0E0" VerticalAlignment="Center"/>
            <TextBlock Name="CountText" Text="0 program(s)" FontSize="11" Foreground="#888888" HorizontalAlignment="Right" VerticalAlignment="Center"/>
        </Grid>
        
        <!-- Programs List -->
        <ScrollViewer Grid.Row="4" Margin="20,5,20,10" VerticalScrollBarVisibility="Auto">
            <StackPanel Name="ProgramList"/>
        </ScrollViewer>
        
        <!-- Footer -->
        <Border Grid.Row="5" Background="#121212" BorderBrush="#1E1E1E" BorderThickness="0,1,0,0">
            <Grid Margin="20,0,20,0">
                <TextBlock Text="v1.0.0" FontSize="10" Foreground="#555555" VerticalAlignment="Center"/>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# Find controls
$StatusText = $window.FindName("StatusText")
$StatusButton = $window.FindName("StatusButton")
$StatusButtonText = $window.FindName("StatusButtonText")
$AddProgramButton = $window.FindName("AddProgramButton")
$CountText = $window.FindName("CountText")
$ProgramList = $window.FindName("ProgramList")

# Update Status Display
function Update-ExtensionStatus {
    $installed = Is-ExtensionInstalled
    if ($installed) {
        $StatusText.Text = "Installed"
        $StatusText.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(46, 204, 113))
        $StatusButton.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(231, 76, 60))
        $StatusButtonText.Text = "Uninstall"
    } else {
        $StatusText.Text = "Not Installed"
        $StatusText.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(231, 76, 60))
        $StatusButton.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0, 120, 212))
        $StatusButtonText.Text = "Install"
    }
}

# Populate dynamic list of registered programs
function Populate-ProgramList {
    $ProgramList.Children.Clear()
    $programs = Get-RegisteredPrograms
    $CountText.Text = "$($programs.Count) program(s)"
    
    if ($programs.Count -eq 0) {
        $emptyBorder = [System.Windows.Controls.Border]::new()
        $emptyBorder.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(30, 30, 30))
        $emptyBorder.CornerRadius = [System.Windows.CornerRadius]::new(6)
        $emptyBorder.Padding = [System.Windows.Thickness]::new(15)
        $emptyBorder.Margin = [System.Windows.Thickness]::new(0, 10, 0, 0)
        
        $emptyText = [System.Windows.Controls.TextBlock]::new()
        $emptyText.Text = "No programs registered yet.`n`nRight-click any program (.exe) or shortcut (.lnk) and click 'Add to Open With Menu' to register it."
        $emptyText.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $emptyText.TextAlignment = [System.Windows.TextAlignment]::Center
        $emptyText.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(120, 120, 120))
        $emptyText.FontSize = 11
        $emptyText.LineHeight = 16
        
        $emptyBorder.Child = $emptyText
        $ProgramList.Children.Add($emptyBorder) | Out-Null
        return
    }
    
    foreach ($prog in $programs) {
        $border = [System.Windows.Controls.Border]::new()
        $border.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(30, 30, 30))
        $border.CornerRadius = [System.Windows.CornerRadius]::new(6)
        $border.Padding = [System.Windows.Thickness]::new(10)
        $border.Margin = [System.Windows.Thickness]::new(0, 4, 0, 4)
        $border.BorderBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(45, 45, 45))
        $border.BorderThickness = [System.Windows.Thickness]::new(1)
        
        $grid = [System.Windows.Controls.Grid]::new()
        
        $colIcon = [System.Windows.Controls.ColumnDefinition]::new()
        $colIcon.Width = [System.Windows.GridLength]::new(36, [System.Windows.GridUnitType]::Pixel)
        
        $colText = [System.Windows.Controls.ColumnDefinition]::new()
        $colText.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        
        $colAction = [System.Windows.Controls.ColumnDefinition]::new()
        $colAction.Width = [System.Windows.GridLength]::new(75, [System.Windows.GridUnitType]::Pixel)
        
        $grid.ColumnDefinitions.Add($colIcon)
        $grid.ColumnDefinitions.Add($colText)
        $grid.ColumnDefinitions.Add($colAction)
        
        # Icon
        $img = [System.Windows.Controls.Image]::new()
        $img.Width = 24
        $img.Height = 24
        $img.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $img.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
        
        $wpfIcon = Get-WpfIcon -FilePath $prog.Path
        if ($wpfIcon -ne $null) {
            $img.Source = $wpfIcon
        }
        [System.Windows.Controls.Grid]::SetColumn($img, 0)
        $grid.Children.Add($img) | Out-Null
        
        # Text block
        $stack = [System.Windows.Controls.StackPanel]::new()
        $stack.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $stack.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
        
        $nameBlock = [System.Windows.Controls.TextBlock]::new()
        $nameBlock.Text = $prog.FriendlyName
        $nameBlock.FontWeight = [System.Windows.FontWeights]::SemiBold
        $nameBlock.FontSize = 13
        $nameBlock.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Colors]::White)
        
        $pathBlock = [System.Windows.Controls.TextBlock]::new()
        $pathBlock.Text = $prog.Path
        $pathBlock.FontSize = 10
        $pathBlock.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(136, 136, 136))
        $pathBlock.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        $pathBlock.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
        
        $stack.Children.Add($nameBlock) | Out-Null
        $stack.Children.Add($pathBlock) | Out-Null
        
        [System.Windows.Controls.Grid]::SetColumn($stack, 1)
        $grid.Children.Add($stack) | Out-Null
        
        # Remove Button
        $btn = [System.Windows.Controls.Border]::new()
        $btn.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(40, 40, 40))
        $btn.Width = 65
        $btn.Height = 24
        $btn.CornerRadius = [System.Windows.CornerRadius]::new(4)
        $btn.Cursor = [System.Windows.Input.Cursors]::Hand
        $btn.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $btn.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
        
        $btnText = [System.Windows.Controls.TextBlock]::new()
        $btnText.Text = "Remove"
        $btnText.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(231, 76, 60))
        $btnText.FontWeight = [System.Windows.FontWeights]::SemiBold
        $btnText.FontSize = 11
        $btnText.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
        $btnText.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        
        $btn.Child = $btnText
        
        $btn.add_MouseEnter({ 
            $this.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(231, 76, 60))
            $this.Child.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Colors]::White)
        })
        $btn.add_MouseLeave({ 
            $this.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(40, 40, 40))
            $this.Child.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(231, 76, 60))
        })
        
        $keyName = $prog.KeyName
        $progName = $prog.FriendlyName
        $btn.add_MouseLeftButtonDown({
            $confirm = [System.Windows.MessageBox]::Show("Are you sure you want to remove '$progName' from your 'Open with...' context menu?", "Confirm Removal", 'YesNo', 'Question')
            if ($confirm -eq 'Yes') {
                Remove-RegisteredProgram -KeyName $keyName
                Populate-ProgramList
            }
        })
        
        [System.Windows.Controls.Grid]::SetColumn($btn, 2)
        $grid.Children.Add($btn) | Out-Null
        
        $border.Child = $grid
        $ProgramList.Children.Add($border) | Out-Null
    }
}

# Attach event handlers to install/uninstall button
$StatusButton.add_MouseLeftButtonDown({
    $installed = Is-ExtensionInstalled
    if ($installed) {
        Uninstall-Extension
    } else {
        Install-Extension
    }
    Update-ExtensionStatus
})

# Status button hover effects
$StatusButton.add_MouseEnter({
    $installed = Is-ExtensionInstalled
    if ($installed) {
        $this.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(192, 57, 43))
    } else {
        $this.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0, 90, 158))
    }
})

$StatusButton.add_MouseLeave({
    $installed = Is-ExtensionInstalled
    if ($installed) {
        $this.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(231, 76, 60))
    } else {
        $this.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0, 120, 212))
    }
})

# Add Program Button Handlers
$AddProgramButton.add_MouseLeftButtonDown({
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = "Applications & Shortcuts (*.exe;*.lnk)|*.exe;*.lnk|All Files (*.*)|*.*"
    $dialog.Title = "Select Program to Add to 'Open With' Menu"
    
    if ($dialog.ShowDialog() -eq $true) {
        $filePath = $dialog.FileName
        if ($filePath.EndsWith(".lnk", [System.StringComparison]::OrdinalIgnoreCase)) {
            $filePath = Resolve-Shortcut -path $filePath
        }
        
        if (-not (Test-Path $filePath)) {
            [System.Windows.MessageBox]::Show("Error: The program file does not exist.`nPath: $filePath", "Error", 'OK', 'Error')
            return
        }
        
        $progName = (Get-Item $filePath).BaseName
        $keyName = "OpenWith_" + $progName.Replace(" ", "_")
        
        try {
            $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("Software\Classes\*\shell\$keyName")
            $key.SetValue("", "Open with $progName")
            $key.SetValue("Icon", $filePath)
            
            $cmdKey = $key.CreateSubKey("command")
            $cmdKey.SetValue("", ('"{0}" "%1"' -f $filePath))
            
            $cmdKey.Close()
            $key.Close()
            
            [System.Windows.MessageBox]::Show("Successfully registered '$progName' to your 'Open with...' context menu.", "Registration Successful", 'OK', 'Information')
            Populate-ProgramList
        } catch {
            [System.Windows.MessageBox]::Show("Failed to register program: $_", "Error", 'OK', 'Error')
        }
    }
})

$AddProgramButton.add_MouseEnter({
    $this.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0, 90, 158))
})

$AddProgramButton.add_MouseLeave({
    $this.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0, 120, 212))
})

# Initial load and Display
Update-ExtensionStatus
Populate-ProgramList
$window.ShowDialog() | Out-Null


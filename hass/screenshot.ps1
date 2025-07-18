# Add-Type -AssemblyName System.Windows.Forms,System.Drawing
# $screens = [Windows.Forms.Screen]::AllScreens
# $top    = ($screens.Bounds.Top    | Measure-Object -Minimum).Minimum
# $left   = ($screens.Bounds.Left   | Measure-Object -Minimum).Minimum
# $height = (((Get-WmiObject -Class Win32_VideoController).VideoModeDescription  -split '\n')[0]  -split ' ')[2]
# $width = (((Get-WmiObject -Class Win32_VideoController).VideoModeDescription  -split '\n')[0]  -split ' ')[0]
# $bounds   = [Drawing.Rectangle]::FromLTRB($left, $top, $width, $height)
# $bmp      = New-Object System.Drawing.Bitmap ([int]$bounds.width), ([int]$bounds.height)
# $graphics = [Drawing.Graphics]::FromImage($bmp)
# $graphics.CopyFromScreen($bounds.Location, [Drawing.Point]::Empty, $bounds.size)
# $bmp.Save("\\192.168.2.4\config\www\$env:computername.png")
# $graphics.Dispose()
# $bmp.Dispose()

$Path = "\\192.168.2.4\config\www"
# Make sure that the directory to keep screenshots has been created, otherwise create it
If (!(test-path $path)) {
New-Item -ItemType Directory -Force -Path $path
}
Add-Type -AssemblyName System.Windows.Forms
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$image = New-Object System.Drawing.Bitmap($screen.Width, $screen.Height)
$graphic = [System.Drawing.Graphics]::FromImage($image)
$point = New-Object System.Drawing.Point(0, 0)
$graphic.CopyFromScreen($point, $point, $image.Size);
$cursorBounds = New-Object System.Drawing.Rectangle([System.Windows.Forms.Cursor]::Position, [System.Windows.Forms.Cursor]::Current.Size)
[System.Windows.Forms.Cursors]::Default.Draw($graphic, $cursorBounds)
$screen_file = "$Path\" + $env:computername + "-screenshot.png"
$image.Save($screen_file, [System.Drawing.Imaging.ImageFormat]::Png)
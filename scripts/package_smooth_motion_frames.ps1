param([ValidateSet('codex', 'claude')][string]$Character = 'codex')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
$prefix = if ($Character -eq 'codex') { 'CodePax' } else { 'Claude' }
$groups = @(
    @{Key='focus'; Actions=@('Thinking','Reading')},
    @{Key='work'; Actions=@('Typing','Replying')},
    @{Key='rest'; Actions=@('Celebrating','Focusing')}
)
$previewDirectory = Join-Path $root 'work/animation-preview'
New-Item -ItemType Directory -Path $previewDirectory -Force | Out-Null
foreach ($group in $groups) {
    $sheet = [System.Drawing.Bitmap]::new((Join-Path $root "design/brand/animation/$Character-$($group.Key)-sheet-v2.png"))
    try {
        if ($sheet.Width -ne $sheet.Height) { throw 'Expected square 4x4 sheet' }
        for ($actionIndex = 0; $actionIndex -lt 2; $actionIndex++) {
            $action = $group.Actions[$actionIndex]
            for ($index = 0; $index -lt 8; $index++) {
                $column = $index % 4
                $row = $actionIndex * 2 + [int][Math]::Floor($index / 4)
                $left = [int][Math]::Floor($column * $sheet.Width / 4)
                $top = [int][Math]::Floor($row * $sheet.Height / 4)
                $right = [int][Math]::Floor(($column + 1) * $sheet.Width / 4)
                $bottom = [int][Math]::Floor(($row + 1) * $sheet.Height / 4)
                $crop = $sheet.Clone([System.Drawing.Rectangle]::new($left,$top,$right-$left,$bottom-$top),[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                $output = [System.Drawing.Bitmap]::new(216,216,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                $graphics = [System.Drawing.Graphics]::FromImage($output)
                try {
                    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $graphics.DrawImage($crop,0,0,216,216)
                } finally { $graphics.Dispose(); $crop.Dispose() }
                $name = "$prefix$action$index"
                $directory = Join-Path $root "CodePax/Assets.xcassets/$name.imageset"
                New-Item -ItemType Directory -Path $directory -Force | Out-Null
                try {
                    $output.Save((Join-Path $directory "$name.png"),[System.Drawing.Imaging.ImageFormat]::Png)
                    $output.Save((Join-Path $previewDirectory "$name.gif"),[System.Drawing.Imaging.ImageFormat]::Gif)
                } finally { $output.Dispose() }
                $metadata = @{images=@(@{filename="$name.png";idiom='universal'});info=@{author='xcode';version=1}} | ConvertTo-Json -Depth 4
                [System.IO.File]::WriteAllText((Join-Path $directory 'Contents.json'),$metadata,[System.Text.UTF8Encoding]::new($false))
                if ($action -eq 'Focusing' -and $index -eq 0) {
                    Copy-Item -LiteralPath (Join-Path $directory "$name.png") -Destination (Join-Path $root "CodePax/Assets.xcassets/${prefix}Portrait.imageset/${prefix}Portrait.png")
                }
            }
        }
    } finally { $sheet.Dispose() }
}
Write-Output "Packaged 48 eight-frame animation assets for $Character."

param([Parameter(Mandatory = $true)][string]$OutputDirectory)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$logoUrl = "https://modretro.com/cdn/shop/files/M64_logo_white.png?v=1782256617&width=800"
$cache = Join-Path ([System.IO.Path]::GetTempPath()) "m64menu-theme-assets"
[System.IO.Directory]::CreateDirectory($cache) | Out-Null
[System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null

function Save-Asset([string]$Uri, [string]$Destination) {
    if (-not [System.IO.File]::Exists($Destination)) {
        $temporary = "$Destination.$([System.Guid]::NewGuid().ToString('N')).download"
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $temporary
            [System.IO.File]::Move($temporary, $Destination)
        }
        finally { if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) } }
    }
}

function Write-U16([byte[]]$Buffer, [int]$Offset, [int]$Value) {
    $Buffer[$Offset] = [byte](($Value -shr 8) -band 0xFF)
    $Buffer[$Offset + 1] = [byte]($Value -band 0xFF)
}

function Convert-TransparentSprite([string]$Source, [string]$Destination, [int]$Width, [int]$Height) {
    Add-Type -AssemblyName System.Drawing
    $sourceImage = [System.Drawing.Image]::FromFile($Source)
    $canvas = [System.Drawing.Bitmap]::new($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($canvas)
        try {
            $graphics.Clear([System.Drawing.Color]::Transparent)
            $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
            $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.DrawImage($sourceImage, 0, 0, $Width, $Height)
        }
        finally { $graphics.Dispose() }

        $data = $canvas.LockBits([System.Drawing.Rectangle]::new(0, 0, $Width, $Height), [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $pixels = [byte[]]::new($data.Stride * $Height)
            [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $pixels, 0, $pixels.Length)
        }
        finally { $canvas.UnlockBits($data) }

        $sprite = [byte[]]::new(8 + ($Width * $Height * 2))
        Write-U16 $sprite 0 $Width; Write-U16 $sprite 2 $Height
        $sprite[4] = 2; $sprite[5] = 0; $sprite[6] = 1; $sprite[7] = 1
        $output = 8
        for ($y = 0; $y -lt $Height; $y++) {
            for ($x = 0; $x -lt $Width; $x++) {
                $p = ($y * $data.Stride) + ($x * 4)
                $value = (([int]$pixels[$p + 2] -shr 3) -shl 11) -bor (([int]$pixels[$p + 1] -shr 3) -shl 6) -bor (([int]$pixels[$p] -shr 3) -shl 1) -bor [int]($pixels[$p + 3] -ge 128)
                $sprite[$output] = [byte](($value -shr 8) -band 0xFF)
                $sprite[$output + 1] = [byte]($value -band 0xFF)
                $output += 2
            }
        }
        [System.IO.File]::WriteAllBytes($Destination, $sprite)
    }
    finally {
        $canvas.Dispose()
        $sourceImage.Dispose()
    }
}

$logo = Join-Path $cache "m64-logo.png"
Save-Asset $logoUrl $logo
Convert-TransparentSprite $logo (Join-Path $OutputDirectory "m64_logo.sprite") 480 132

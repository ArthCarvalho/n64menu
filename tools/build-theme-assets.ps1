param([Parameter(Mandatory = $true)][string]$OutputDirectory)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Vendored rather than downloaded. Fetching the mark at build time made the build
# depend on a third-party CDN whose URL has already changed once, and it is not
# something a build should reach out to the network for.
$logo = Join-Path $PSScriptRoot "logo\sc64_logo.png"
if (-not [System.IO.File]::Exists($logo)) { throw "Missing logo artwork: $logo" }

[System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null

function Write-U16([byte[]]$Buffer, [int]$Offset, [int]$Value) {
    $Buffer[$Offset] = [byte](($Value -shr 8) -band 0xFF)
    $Buffer[$Offset + 1] = [byte]($Value -band 0xFF)
}

function Convert-TransparentSprite([string]$Source, [string]$Destination, [int]$Width, [int]$Height, [switch]$Erode) {
    Add-Type -AssemblyName System.Drawing
    $sourceImage = [System.Drawing.Image]::FromFile($Source)
    $canvas = [System.Drawing.Bitmap]::new($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($canvas)
        try {
            $graphics.Clear([System.Drawing.Color]::Transparent)
            $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
            $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            # Bilinear rather than bicubic: bicubic overshoots, and the ringing
            # pushes edge alpha back and forth across the cutoff below, which
            # scatters stray texels along the diagonals.
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
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
        # Colour carries the coverage: the menu draws the mark with a texture by
        # flat-colour combiner and no alpha blending, so whatever sits in RGB is
        # what shades the edge.
        #
        # Decimate rather than resample into it. Taking the interpolated RGB left
        # every edge texel a partial grey, which reads as a blurred mark however
        # the console samples it. Resolving each texel to fully on or fully off
        # against the coverage cutoff gives hard pixel edges, matching the pixel
        # art the rest of the interface is built from.
        for ($y = 0; $y -lt $Height; $y++) {
            for ($x = 0; $x -lt $Width; $x++) {
                $p = ($y * $data.Stride) + ($x * 4)
                $alpha = $pixels[$p + 3]
                $covered = $alpha -ge 128
                if ($covered -and $Erode) {
                    # Shade fractional coverage only where the silhouette changes on
                    # both axes. A straight edge changes on one axis only and stays
                    # solid; a diagonal has a clear neighbour horizontally and
                    # vertically, so its partial texel can show the darker underlay.
                    $clearX = $false
                    $clearY = $false
                    foreach ($dx in @(-1, 1)) {
                        $nx = $x + $dx
                        if ($nx -lt 0 -or $nx -ge $Width) { $clearX = $true; break }
                        $np = ($y * $data.Stride) + ($nx * 4)
                        if ($pixels[$np + 3] -lt 128) { $clearX = $true; break }
                    }
                    foreach ($dy in @(-1, 1)) {
                        $ny = $y + $dy
                        if ($ny -lt 0 -or $ny -ge $Height) { $clearY = $true; break }
                        $np = ($ny * $data.Stride) + ($x * 4)
                        if ($pixels[$np + 3] -lt 128) { $clearY = $true; break }
                    }
                    if ($clearX -and $clearY -and $alpha -lt 224) {
                        $covered = $false
                    }
                }
                $value = if ($covered) { (31 -shl 11) -bor (31 -shl 6) -bor (31 -shl 1) -bor 1 } else { 0 }
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

# Rasterize each use at its final framebuffer size. Generating one large sprite
# and scaling it again on the N64 quantizes the diagonal edges twice.
#
# These are half the size they are drawn at, and the menu blits them at an exact
# 2x with point sampling. The console's own mark sits on a far coarser grid than
# a one-to-one sprite gives us: measured off a capture, its pixels are about four
# display pixels across, where one-to-one here yields about two. Halving the grid
# and doubling on output matches it, and an integer scale keeps every block square.
#
# The header mark is sized so the counter inside the 6 survives the coverage
# cutoff. Below roughly 95 wide at this grid that gap closes and the digit fills
# in solid; the band above the rule limits the height.
Convert-TransparentSprite $logo (Join-Path $OutputDirectory "sc64_logo_header.sprite") 95 26
Convert-TransparentSprite $logo (Join-Path $OutputDirectory "sc64_logo_splash.sprite") 168 46
Convert-TransparentSprite $logo (Join-Path $OutputDirectory "sc64_logo_header_inner.sprite") 95 26 -Erode
Convert-TransparentSprite $logo (Join-Path $OutputDirectory "sc64_logo_splash_inner.sprite") 168 46 -Erode

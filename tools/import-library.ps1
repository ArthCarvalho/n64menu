[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputRoot,

    [Parameter(Mandatory = $true)]
    [string]$RomPath,

    [string]$ImagePath,
    [string]$RetroArchThumbnailPath,
    [switch]$Recursive,
    [switch]$DownloadMissingBoxart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RomExtensions = @(".n64", ".v64", ".z64")
$ImageExtensions = @(".bmp", ".gif", ".jpeg", ".jpg", ".png", ".tif", ".tiff")
$MaximumTitles = 40

function Get-Directory([string]$Path, [string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.Directory]::Exists($Path)) {
        throw "$Name does not exist or is not a directory: $Path"
    }
    return [System.IO.Path]::GetFullPath($Path)
}

function Get-Files([string]$Root, [string[]]$Extensions, [System.IO.SearchOption]$SearchOption) {
    return @([System.IO.Directory]::EnumerateFiles($Root, "*", $SearchOption) |
        Where-Object { $Extensions -contains [System.IO.Path]::GetExtension($_).ToLowerInvariant() } |
        Sort-Object)
}

function Get-Names([string]$Rom) {
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @(
        [System.IO.Path]::GetFileNameWithoutExtension($Rom),
        [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($Rom))
    )) {
        if ([string]::IsNullOrWhiteSpace($name) -or $names.Contains($name)) { continue }
        $names.Add($name)

        $withoutRevision = [System.Text.RegularExpressions.Regex]::Replace($name, "\s*\((Rev|Beta|Proto)\s*[^)]*\)", "", "IgnoreCase")
        if (-not $names.Contains($withoutRevision)) { $names.Add($withoutRevision) }
    }
    return @($names)
}

function Get-Key([string]$Name) {
    return [System.Text.RegularExpressions.Regex]::Replace($Name.ToLowerInvariant(), "[^\p{L}\p{Nd}]", "")
}

function New-ImageIndex([string[]]$Images) {
    $exact = @{}
    $normalized = @{}
    foreach ($image in $Images) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($image)
        if (-not $exact.ContainsKey($name)) { $exact[$name] = [System.Collections.Generic.List[string]]::new() }
        $exact[$name].Add($image)

        $key = Get-Key $name
        if (-not $normalized.ContainsKey($key)) { $normalized[$key] = [System.Collections.Generic.List[string]]::new() }
        $normalized[$key].Add($image)
    }
    return @{ Exact = $exact; Normalized = $normalized }
}

function Find-IndexedImage([string[]]$Names, [hashtable]$Index) {
    if ($null -eq $Index) { return $null }
    foreach ($name in $Names) {
        if ($Index.Exact.ContainsKey($name) -and $Index.Exact[$name].Count -eq 1) { return $Index.Exact[$name][0] }
    }
    foreach ($name in $Names) {
        $key = Get-Key $name
        if ($Index.Normalized.ContainsKey($key) -and $Index.Normalized[$key].Count -eq 1) { return $Index.Normalized[$key][0] }
    }
    return $null
}

function Save-Download([string]$Uri, [string]$Destination) {
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Destination)) | Out-Null
    $temporary = "$Destination.$([System.Guid]::NewGuid().ToString('N')).download"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $temporary
        Add-Type -AssemblyName System.Drawing
        $image = [System.Drawing.Image]::FromFile($temporary)
        $image.Dispose()
        [System.IO.File]::Copy($temporary, $Destination, $true)
    }
    finally {
        if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
    }
}

function Find-Artwork([string]$Rom, [hashtable]$Images, [hashtable]$RetroArchImages, [string]$CacheRoot) {
    $directory = [System.IO.Path]::GetDirectoryName($Rom)
    $siblings = @(Get-Files $directory $ImageExtensions ([System.IO.SearchOption]::TopDirectoryOnly))
    $romName = [System.IO.Path]::GetFileNameWithoutExtension($Rom)
    $exactSibling = @($siblings | Where-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) -ieq $romName })
    if ($exactSibling.Count -eq 1) { return $exactSibling[0] }
    if ($siblings.Count -eq 1) { return $siblings[0] }

    $names = @(Get-Names $Rom)
    $match = Find-IndexedImage $names $Images
    if ($null -ne $match) { return $match }
    $match = Find-IndexedImage $names $RetroArchImages
    if ($null -ne $match) { return $match }

    if ($DownloadMissingBoxart) {
        foreach ($name in $names) {
            $safeName = [System.Text.RegularExpressions.Regex]::Replace($name, '[<>:"/\\|?*]', '_')
            $destination = Join-Path $CacheRoot "$safeName.png"
            if ([System.IO.File]::Exists($destination)) { return $destination }
            $encoded = [System.Uri]::EscapeDataString("$name.png")
            $uri = "https://raw.githubusercontent.com/libretro-thumbnails/Nintendo_-_Nintendo_64/master/Named_Boxarts/$encoded"
            try {
                Save-Download $uri $destination
                return $destination
            }
            catch [System.Net.WebException] {
                if (($null -ne $_.Exception.Response) -and ([int]$_.Exception.Response.StatusCode -eq 404)) { continue }
                throw
            }
            catch [System.OutOfMemoryException] {
                if ([System.IO.File]::Exists($destination)) { [System.IO.File]::Delete($destination) }
            }
        }
    }
    return $null
}

function Get-ByteOrder([byte[]]$Magic, [string]$Path) {
    switch ([System.BitConverter]::ToString($Magic)) {
        "80-37-12-40" { return "z64" }
        "37-80-40-12" { return "v64" }
        "40-12-37-80" { return "n64" }
        default { throw "Unrecognized N64 ROM byte order: $Path" }
    }
}

function Convert-Buffer([byte[]]$Buffer, [int]$Count, [string]$Order, [string]$Path) {
    if (($Order -eq "v64") -and (($Count % 2) -ne 0)) { throw "Invalid byte-swapped ROM size: $Path" }
    if (($Order -eq "n64") -and (($Count % 4) -ne 0)) { throw "Invalid little-endian ROM size: $Path" }
    if ($Order -eq "v64") {
        for ($i = 0; $i -lt $Count; $i += 2) {
            $temporary = $Buffer[$i]; $Buffer[$i] = $Buffer[$i + 1]; $Buffer[$i + 1] = $temporary
        }
    }
    elseif ($Order -eq "n64") {
        for ($i = 0; $i -lt $Count; $i += 4) {
            $temporary = $Buffer[$i]; $Buffer[$i] = $Buffer[$i + 3]; $Buffer[$i + 3] = $temporary
            $temporary = $Buffer[$i + 1]; $Buffer[$i + 1] = $Buffer[$i + 2]; $Buffer[$i + 2] = $temporary
        }
    }
}

function Copy-Rom([string]$Source, [string]$Destination) {
    $input = [System.IO.File]::OpenRead($Source)
    $output = [System.IO.File]::Create($Destination)
    try {
        $magic = [byte[]]::new(4)
        if ($input.Read($magic, 0, 4) -ne 4) { throw "ROM is too small: $Source" }
        $input.Position = 0
        $order = Get-ByteOrder $magic $Source
        $buffer = [byte[]]::new(1048576)
        while (($count = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
            Convert-Buffer $buffer $count $order $Source
            $output.Write($buffer, 0, $count)
        }
    }
    finally {
        $output.Dispose()
        $input.Dispose()
    }
}

function Get-RomId([string]$Path) {
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    $input = [System.IO.File]::OpenRead($Path)
    try {
        $magic = [byte[]]::new(4)
        if ($input.Read($magic, 0, 4) -ne 4) { throw "ROM is too small: $Path" }
        $input.Position = 0
        $order = Get-ByteOrder $magic $Path
        $buffer = [byte[]]::new(1048576)
        while (($count = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
            Convert-Buffer $buffer $count $order $Path
            $null = $algorithm.TransformBlock($buffer, 0, $count, $buffer, 0)
        }
        $null = $algorithm.TransformFinalBlock([byte[]]::new(0), 0, 0)
        return [System.BitConverter]::ToString($algorithm.Hash).Replace("-", "").Substring(0, 5)
    }
    finally {
        $input.Dispose()
        $algorithm.Dispose()
    }
}

function Write-U16([byte[]]$Buffer, [int]$Offset, [int]$Value) {
    $Buffer[$Offset] = [byte](($Value -shr 8) -band 0xFF)
    $Buffer[$Offset + 1] = [byte]($Value -band 0xFF)
}

function Convert-Image([string]$Source, [string]$Destination) {
    Add-Type -AssemblyName System.Drawing
    $width = 256; $height = 179
    $sourceImage = [System.Drawing.Image]::FromFile($Source)
    $canvas = [System.Drawing.Bitmap]::new($width, $height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($canvas)
        try {
            $graphics.Clear([System.Drawing.Color]::FromArgb(255, 48, 48, 48))
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $scale = [Math]::Min($width / $sourceImage.Width, $height / $sourceImage.Height)
            $drawWidth = [int][Math]::Round($sourceImage.Width * $scale)
            $drawHeight = [int][Math]::Round($sourceImage.Height * $scale)
            $graphics.DrawImage($sourceImage, [int](($width - $drawWidth) / 2), [int](($height - $drawHeight) / 2), $drawWidth, $drawHeight)
        }
        finally { $graphics.Dispose() }

        $data = $canvas.LockBits([System.Drawing.Rectangle]::new(0, 0, $width, $height), [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $pixels = [byte[]]::new($data.Stride * $height)
            [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $pixels, 0, $pixels.Length)
        }
        finally { $canvas.UnlockBits($data) }

        $sprite = [byte[]]::new(8 + ($width * $height * 2))
        Write-U16 $sprite 0 $width; Write-U16 $sprite 2 $height
        $sprite[4] = 2; $sprite[5] = 0; $sprite[6] = 1; $sprite[7] = 1
        $output = 8
        for ($y = 0; $y -lt $height; $y++) {
            for ($x = 0; $x -lt $width; $x++) {
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

function New-TitleCard([string]$Title, [string]$Destination) {
    Add-Type -AssemblyName System.Drawing
    $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("n64menu-{0}.png" -f [System.Guid]::NewGuid().ToString("N"))
    $canvas = [System.Drawing.Bitmap]::new(256, 179)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($canvas)
        try {
            $graphics.Clear([System.Drawing.Color]::FromArgb(255, 35, 30, 48))
            $font = [System.Drawing.Font]::new("Arial", 19, [System.Drawing.FontStyle]::Bold)
            $brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
            try { $graphics.DrawString($Title, $font, $brush, [System.Drawing.RectangleF]::new(20, 20, 216, 139)) }
            finally { $brush.Dispose(); $font.Dispose() }
        }
        finally { $graphics.Dispose() }
        $canvas.Save($temporary, [System.Drawing.Imaging.ImageFormat]::Png)
        Convert-Image $temporary $Destination
    }
    finally {
        $canvas.Dispose()
        if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
    }
}

$output = Get-Directory $OutputRoot "-OutputRoot"
$romRoot = Get-Directory $RomPath "-RomPath"
$option = if ($Recursive) { [System.IO.SearchOption]::AllDirectories } else { [System.IO.SearchOption]::TopDirectoryOnly }
$roms = @(Get-Files $romRoot $RomExtensions $option)
if ($roms.Count -eq 0) { throw "No N64 ROMs were found." }
if ($roms.Count -gt $MaximumTitles) { throw "n64menu supports at most $MaximumTitles titles." }

$images = $null
if (-not [string]::IsNullOrWhiteSpace($ImagePath)) {
    $images = New-ImageIndex (Get-Files (Get-Directory $ImagePath "-ImagePath") $ImageExtensions $option)
}
$retroArchImages = $null
if (-not [string]::IsNullOrWhiteSpace($RetroArchThumbnailPath)) {
    $retroRoot = Get-Directory $RetroArchThumbnailPath "-RetroArchThumbnailPath"
    if ([System.IO.Path]::GetFileName($retroRoot) -ine "Named_Boxarts") { $retroRoot = Join-Path $retroRoot "Named_Boxarts" }
    $retroArchImages = New-ImageIndex (Get-Files (Get-Directory $retroRoot "Named_Boxarts") $ImageExtensions ([System.IO.SearchOption]::TopDirectoryOnly))
}

$titleRoot = Join-Path $output "menu\title"
$cacheRoot = Join-Path ([System.IO.Path]::GetTempPath()) "n64menu-boxart-cache"
[System.IO.Directory]::CreateDirectory($titleRoot) | Out-Null
$ids = [System.Collections.Generic.List[string]]::new()
foreach ($rom in $roms) {
    if ([System.IO.FileInfo]::new($rom).Length -gt (78 * 1024 * 1024)) { throw "ROM exceeds n64menu's 78 MiB limit: $rom" }
    $id = Get-RomId $rom
    if ($ids.Contains($id)) { throw "Generated ID collision: $id" }
    $ids.Add($id)
    $destination = Join-Path $titleRoot $id
    [System.IO.Directory]::CreateDirectory($destination) | Out-Null
    Copy-Rom $rom (Join-Path $destination "${id}_e.z64")

    $artwork = Find-Artwork $rom $images $retroArchImages $cacheRoot
    if ($null -eq $artwork) {
        $title = [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($rom))
        New-TitleCard $title (Join-Path $destination "${id}_e.sprite")
        Write-Host "GENERATED $title"
    }
    else {
        Convert-Image $artwork (Join-Path $destination "${id}_e.sprite")
        Write-Host "IMPORTED  $([System.IO.Path]::GetFileNameWithoutExtension($rom))"
    }
}

[System.IO.File]::WriteAllBytes(
    (Join-Path $output "menu\title.csv"),
    [System.Text.Encoding]::ASCII.GetBytes(($ids -join ",") + ",`0")
)
Write-Host "Imported $($ids.Count) title(s) into $output"

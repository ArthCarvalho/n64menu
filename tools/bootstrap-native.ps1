param([Parameter(Mandatory = $true)][string]$Zig)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$cache = Join-Path $root ".n64"
$toolchain = Join-Path $cache "toolchain"
$sdk = Join-Path $cache "sdk"
$libdragon = Join-Path $cache "libdragon"
$sourceArchive = Join-Path $cache "n64menu-initial.tar.gz"
$sourceUrl = "https://api.github.com/repos/ArthCarvalho/n64menu/tarball/5281706ada0979bfb4e346d8f7977d79381ba235"
$sourceSha256 = "AE2E5DB2325769E93C7BC0D9704CCB3D2F09246B7CF9646A5C9A2EAA8B9E85B3"
$archive = Join-Path $cache "gcc-toolchain-mips64-win64.zip"
$toolchainUrl = "https://api.github.com/repos/DragonMinded/libdragon/releases/assets/511634373"
$toolchainSha256 = "E5B9866B28F8DF21267D9A66A77672EA5A9AC9A528A0BC18E915DC6D7D4316F3"

function Save-VerifiedDownload([string]$Uri, [string]$Destination, [string]$Sha256, [hashtable]$Headers) {
    if ([System.IO.File]::Exists($Destination) -and (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash -eq $Sha256) {
        return
    }
    if ([System.IO.File]::Exists($Destination)) { [System.IO.File]::Delete($Destination) }

    $temporary = "$Destination.$([System.Guid]::NewGuid().ToString('N')).download"
    try {
        Invoke-WebRequest -UseBasicParsing -Headers $Headers -Uri $Uri -OutFile $temporary
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $temporary).Hash
        if ($actual -ne $Sha256) { throw "Unexpected download checksum: $actual" }
        [System.IO.File]::Move($temporary, $Destination)
    }
    finally {
        if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
    }
}

function Convert-ToGitBashPath([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path).Replace("\", "/")
    if ($full -match '^([A-Za-z]):(.*)$') {
        return "/$($matches[1].ToLowerInvariant())$($matches[2])"
    }
    throw "Git Bash cannot map path: $Path"
}

function Invoke-GitBash([string]$Command) {
    $git = (Get-Command git.exe -ErrorAction Stop).Source
    $bash = Join-Path ([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetDirectoryName($git))) "bin\bash.exe"
    if (-not [System.IO.File]::Exists($bash)) { throw "Git for Windows bash.exe was not found." }
    & $bash -lc $Command
    if ($LASTEXITCODE -ne 0) { throw "Git Bash command failed with exit code $LASTEXITCODE." }
}

if ($root -notmatch '^[A-Za-z]:\\[A-Za-z0-9._\\-]+$') {
    throw "Use a local checkout path containing only letters, numbers, dots, underscores, and hyphens; the historical Makefiles do not safely quote paths."
}

[System.IO.Directory]::CreateDirectory($cache) | Out-Null
Save-VerifiedDownload $sourceUrl $sourceArchive $sourceSha256 @{ "User-Agent" = "n64menu-build" }
if (-not [System.IO.Directory]::Exists($libdragon)) {
    $sourceRoot = Join-Path $cache ("historical-source-{0}" -f [System.Guid]::NewGuid().ToString("N"))
    try {
        [System.IO.Directory]::CreateDirectory($sourceRoot) | Out-Null
        tar.exe -xf $sourceArchive -C $sourceRoot --strip-components=1
        if ($LASTEXITCODE -ne 0) { throw "Could not extract the historical n64menu source." }
        [System.IO.Directory]::Move((Join-Path $sourceRoot "libdragon"), $libdragon)
    }
    finally {
        if ([System.IO.Directory]::Exists($sourceRoot)) { [System.IO.Directory]::Delete($sourceRoot, $true) }
    }
}
Save-VerifiedDownload $toolchainUrl $archive $toolchainSha256 @{
    "Accept" = "application/octet-stream"
    "User-Agent" = "n64menu-build"
}
if (-not [System.IO.File]::Exists((Join-Path $toolchain "bin\mips64-elf-gcc.exe"))) {
    if ([System.IO.Directory]::Exists($toolchain)) { [System.IO.Directory]::Delete($toolchain, $true) }
    $toolchainTemporary = "$toolchain-$([System.Guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.Directory]::CreateDirectory($toolchainTemporary) | Out-Null
        tar.exe -xf $archive -C $toolchainTemporary
        if ($LASTEXITCODE -ne 0) { throw "Could not extract the N64 toolchain." }
        [System.IO.Directory]::Move($toolchainTemporary, $toolchain)
    }
    finally {
        if ([System.IO.Directory]::Exists($toolchainTemporary)) { [System.IO.Directory]::Delete($toolchainTemporary, $true) }
    }
}

$runtimeMarker = Join-Path $sdk ".complete"
if (-not [System.IO.File]::Exists($runtimeMarker)) {
    if ([System.IO.Directory]::Exists($sdk)) { [System.IO.Directory]::Delete($sdk, $true) }
    $backtrace = Join-Path $libdragon "src\backtrace.c"
    $asset = Join-Path $libdragon "src\asset.c"
    $opus = Join-Path $libdragon "src\audio\wav64_opus.c"
    foreach ($file in @($backtrace, $asset, $opus)) {
        $text = [System.IO.File]::ReadAllText($file)
        $text = $text.Replace("typedef struct alignas(8) {", "typedef struct {")
        $text = $text.Replace("} symtable_header_t;", "} __attribute__((aligned(8))) symtable_header_t;")
        $text = $text.Replace(" alignas(8);", " __attribute__((aligned(8)));")
        $text = $text.Replace(" alignas(16);", " __attribute__((aligned(16)));")
        [System.IO.File]::WriteAllText($file, $text)
    }
    $makefile = Join-Path $libdragon "Makefile"
    $make = [System.IO.File]::ReadAllText($makefile)
    if (-not $make.Contains("-Wno-error=maybe-uninitialized")) {
        $make = $make.Replace("-ffile-prefix-map=`$(CURDIR)=libdragon", "-ffile-prefix-map=`$(CURDIR)=libdragon -Wno-error=maybe-uninitialized")
    }
    [System.IO.File]::WriteAllText($makefile, $make)

    $toolchainBash = Convert-ToGitBashPath $toolchain
    $sdkBash = Convert-ToGitBashPath $sdk
    $libdragonBash = Convert-ToGitBashPath $libdragon
    Invoke-GitBash "export PATH='$toolchainBash/bin:/usr/bin'; make -C '$libdragonBash' -j8 N64_INST='$sdkBash' N64_GCCPREFIX='$toolchainBash' install"
    if (-not [System.IO.File]::Exists((Join-Path $sdk "mips64-elf\lib\libdragon.a"))) {
        throw "The libdragon runtime installation is incomplete."
    }
    [System.IO.File]::WriteAllText($runtimeMarker, "ok")
}

$hostTools = Join-Path $cache "host-tools"
[System.IO.Directory]::CreateDirectory($hostTools) | Out-Null
if (-not [System.IO.File]::Exists((Join-Path $hostTools "n64tool.exe"))) {
    $temporary = Join-Path $hostTools "n64tool.building.exe"
    try {
        & $Zig cc -std=gnu11 -O2 -D_WIN32 -o $temporary (Join-Path $libdragon "tools\n64tool.c")
        if ($LASTEXITCODE -ne 0) { throw "Zig could not compile n64tool." }
        [System.IO.File]::Move($temporary, (Join-Path $hostTools "n64tool.exe"))
    }
    finally { if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) } }
}
if (-not [System.IO.File]::Exists((Join-Path $hostTools "n64sym.exe"))) {
    $temporary = Join-Path $hostTools "n64sym.building.exe"
    try {
        & $Zig cc -std=gnu11 -O2 -D_WIN32 -o $temporary (Join-Path $libdragon "tools\n64sym.c")
        if ($LASTEXITCODE -ne 0) { throw "Zig could not compile n64sym." }
        [System.IO.File]::Move($temporary, (Join-Path $hostTools "n64sym.exe"))
    }
    finally { if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) } }
}
$sdkBin = Join-Path $sdk "bin"
[System.IO.Directory]::CreateDirectory($sdkBin) | Out-Null
foreach ($name in @("n64tool.exe", "n64sym.exe")) {
    [System.IO.File]::Copy((Join-Path $hostTools $name), (Join-Path $sdkBin $name), $true)
}

$dfs = Join-Path $root "build\spritemap.dfs"
[System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($dfs)) | Out-Null
$rom = [System.IO.File]::ReadAllBytes((Join-Path $root "sc64menu.n64"))
$dfsOffset = 0x63B10
$dfsBytes = [byte[]]::new($rom.Length - $dfsOffset)
[System.Array]::Copy($rom, $dfsOffset, $dfsBytes, 0, $dfsBytes.Length)
[System.IO.File]::WriteAllBytes($dfs, $dfsBytes)

$toolchainBash = Convert-ToGitBashPath $toolchain
$sdkBash = Convert-ToGitBashPath $sdk
$rootBash = Convert-ToGitBashPath $root
$toolchainNative = $toolchain.Replace("\", "/")
$sdkNative = $sdk.Replace("\", "/")
$commonFlags = "-march=vr4300 -mtune=vr4300 -I${sdkNative}/mips64-elf/include -falign-functions=32 -ffunction-sections -fdata-sections -g -ffile-prefix-map=${root}=/ -ffast-math -ftrapping-math -fno-associative-math -DN64 -O2 -Wall -Werror -Wno-error=deprecated-declarations -Wno-error=unused-variable -Wno-error=unused-but-set-variable -Wno-error=unused-function -Wno-error=unused-parameter -Wno-error=unused-label -Wno-error=unused-const-variable"
$linkFlags = "-g -L${sdkNative}/mips64-elf/lib -ldragon -lm -ldragonsys -Tn64.ld --gc-sections --wrap __do_global_ctors"
Invoke-GitBash "export PATH='${toolchainBash}/bin:/usr/bin'; make -C '$rootBash' build/mockup_menu.elf N64_INST='$sdkNative' N64_GCCPREFIX='$toolchainNative' CC='${toolchainNative}/bin/mips64-elf-gcc' CXX='${toolchainNative}/bin/mips64-elf-g++' AS='${toolchainNative}/bin/mips64-elf-as' LD='${toolchainNative}/bin/mips64-elf-ld' CFLAGS='$commonFlags -std=gnu99 -MMD' CXXFLAGS='$commonFlags -MMD' ASFLAGS='-mtune=vr4300 -march=vr4300 -Wa,--fatal-warnings -I${sdkNative}/mips64-elf/include -MMD' LDFLAGS='$linkFlags'"

$elf = Join-Path $root "build\mockup_menu.elf"
$stripped = Join-Path $root "build\mockup_menu.elf.stripped"
$symbols = Join-Path $root "build\mockup_menu.elf.sym"
[System.Environment]::SetEnvironmentVariable("N64_INST", $toolchain, "Process")
& (Join-Path $hostTools "n64sym.exe") $elf $symbols
if ($LASTEXITCODE -ne 0) { throw "Could not create the menu symbol table." }
[System.IO.File]::Copy($elf, $stripped, $true)
& (Join-Path $toolchain "bin\mips64-elf-strip.exe") -s $stripped
if ($LASTEXITCODE -ne 0) { throw "Could not strip the menu ELF." }

$menuRom = Join-Path $root "mockup_menu.z64"
& (Join-Path $hostTools "n64tool.exe") --title "Mockup Menu" --toc --output $menuRom --align 256 $stripped --align 8 $symbols --align 16 $dfs
if ($LASTEXITCODE -ne 0) { throw "Could not package the menu ROM." }

$bin = Join-Path $root "zig-out\bin"
[System.IO.Directory]::CreateDirectory($bin) | Out-Null
[System.IO.File]::Copy($menuRom, (Join-Path $bin "sc64menu.n64"), $true)

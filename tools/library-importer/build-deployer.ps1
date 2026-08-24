param([Parameter(Mandatory = $true)][string]$OutputDirectory)

$ErrorActionPreference = "Stop"
$commit = "df8432c9f18b9d1c5977cf9502e829be06d39d77"
$root = Join-Path ([System.IO.Path]::GetTempPath()) "m64menu-sc64deployer-$commit"
if ([System.IO.Directory]::Exists($root)) { [System.IO.Directory]::Delete($root, $true) }
git clone --filter=blob:none https://github.com/DrSammyD/SummerCart64.git $root
if ($LASTEXITCODE -ne 0) { throw "Could not clone SummerCart64" }
git -C $root checkout $commit
if ($LASTEXITCODE -ne 0) { throw "Could not checkout SummerCart64 $commit" }
cargo build --release --locked --manifest-path (Join-Path $root "sw\deployer\Cargo.toml")
if ($LASTEXITCODE -ne 0) { throw "Could not build forked sc64deployer" }
[System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$isWindowsHost = $env:OS -eq "Windows_NT"
$extension = if ($isWindowsHost) { ".exe" } else { "" }
[System.IO.File]::Copy(
    (Join-Path $root "sw\deployer\target\release\sc64deployer$extension"),
    (Join-Path $OutputDirectory "sc64deployer$extension"),
    $true
)
[System.IO.File]::Copy((Join-Path $root "LICENSE"), (Join-Path $OutputDirectory "SC64DEPLOYER_LICENSE.txt"), $true)

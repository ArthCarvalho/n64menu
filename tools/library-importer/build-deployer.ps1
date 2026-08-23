param([Parameter(Mandatory = $true)][string]$OutputDirectory)

$ErrorActionPreference = "Stop"
$commit = "a1e7996d2cbece686820a5c785029c68514f17b0"
$root = Join-Path ([System.IO.Path]::GetTempPath()) "m64menu-sc64deployer-$commit"
if ([System.IO.Directory]::Exists($root)) { [System.IO.Directory]::Delete($root, $true) }
git clone --filter=blob:none https://github.com/Polprzewodnikowy/SummerCart64.git $root
if ($LASTEXITCODE -ne 0) { throw "Could not clone SummerCart64" }
git -C $root checkout $commit
if ($LASTEXITCODE -ne 0) { throw "Could not checkout SummerCart64 $commit" }
git -C $root apply (Join-Path $PSScriptRoot "sc64deployer-batch-sync.patch")
if ($LASTEXITCODE -ne 0) { throw "Could not apply batched sync patch" }
cargo build --release --locked --manifest-path (Join-Path $root "sw\deployer\Cargo.toml")
if ($LASTEXITCODE -ne 0) { throw "Could not build patched sc64deployer" }
[System.IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$isWindowsHost = $env:OS -eq "Windows_NT"
$extension = if ($isWindowsHost) { ".exe" } else { "" }
[System.IO.File]::Copy(
    (Join-Path $root "sw\deployer\target\release\sc64deployer$extension"),
    (Join-Path $OutputDirectory "sc64deployer$extension"),
    $true
)
[System.IO.File]::Copy((Join-Path $root "LICENSE"), (Join-Path $OutputDirectory "SC64DEPLOYER_LICENSE.txt"), $true)

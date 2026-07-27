param(
  [Parameter(Mandatory = $true)]
  [string]$BuildDirectory,
  [ValidateSet('Release', 'Debug')]
  [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$BuildDirectory = (Resolve-Path -LiteralPath $BuildDirectory).Path
$tripletBin = Join-Path $BuildDirectory 'vcpkg_installed\x64-windows\bin'
if ($Configuration -eq 'Debug') {
  $tripletBin = Join-Path $BuildDirectory 'vcpkg_installed\x64-windows\debug\bin'
}
$eightBitDll = Join-Path $tripletBin 'libx265.dll'
$main10Dll = Join-Path $BuildDirectory "x265-main10\$Configuration\libx265.dll"
if (!(Test-Path -LiteralPath $main10Dll)) {
  exit 0
}
if (!(Test-Path -LiteralPath $eightBitDll)) {
  throw "8-bit x265 runtime is missing: $eightBitDll"
}
$runtimeDirectories = @(
  $BuildDirectory,
  (Join-Path $BuildDirectory $Configuration),
  (Join-Path $BuildDirectory "x265-runtime\$Configuration")
) | Select-Object -Unique
foreach ($runtimeDirectory in $runtimeDirectories) {
  New-Item -ItemType Directory -Force $runtimeDirectory | Out-Null
  Copy-Item -LiteralPath $eightBitDll -Destination (Join-Path $runtimeDirectory 'libx265_main.dll') -Force
  Copy-Item -LiteralPath $main10Dll -Destination (Join-Path $runtimeDirectory 'libx265.dll') -Force
}

param(
    [Parameter(Mandatory)]
    [string]$VcpkgRoot,
    [string]$BuildDirectory = "build-release",
    [string]$OutputDirectory = "dist",
    [ValidateSet("Release")]
    [string]$Configuration = "Release"
)

$projectRoot = Split-Path -Parent $PSScriptRoot
$VcpkgRoot = (Resolve-Path -LiteralPath $VcpkgRoot).Path
$toolchain = Join-Path $VcpkgRoot "scripts\buildsystems\vcpkg.cmake"
if (-not (Test-Path -LiteralPath $toolchain)) {
    throw "vcpkg toolchain not found: $toolchain"
}

$buildPath = Join-Path $projectRoot $BuildDirectory
$outputPath = Join-Path $projectRoot $OutputDirectory

cmake -S $projectRoot -B $buildPath `
    "-DCMAKE_TOOLCHAIN_FILE=$toolchain" `
    "-DVCPKG_TARGET_TRIPLET=x64-windows" `
    "-DHYPERDR_BUILD_TESTS=OFF"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

cmake --build $buildPath --config $Configuration
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

powershell -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $projectRoot "scripts\prepare_x265_multibit.ps1") `
    -VcpkgRoot $VcpkgRoot -BuildDirectory $buildPath -Configuration $Configuration
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
cpack --config (Join-Path $buildPath "CPackConfig.cmake") `
    -G ZIP -B $outputPath -C $Configuration
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$archive = Get-ChildItem -LiteralPath $outputPath -Filter "HyperDR-*-windows-x64.zip" |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1
if (-not $archive) { throw "CPack did not produce a HyperDR release archive." }

powershell -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $PSScriptRoot "test-release.ps1") -Archive $archive.FullName
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$archive.FullName

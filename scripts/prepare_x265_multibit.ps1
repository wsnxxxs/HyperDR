param(
  [Parameter(Mandatory = $true)]
  [string]$VcpkgRoot,
  [string]$BuildDirectory = (Join-Path $PSScriptRoot '..\build'),
  [ValidateSet('Release', 'Debug')]
  [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$VcpkgRoot = (Resolve-Path -LiteralPath $VcpkgRoot).Path
$BuildDirectory = (Resolve-Path -LiteralPath $BuildDirectory).Path
$triplet = 'x64-windows'
$vcpkgBin = Join-Path $BuildDirectory "vcpkg_installed\$triplet\bin"
if ($Configuration -eq 'Debug') {
  $vcpkgBin = Join-Path $BuildDirectory "vcpkg_installed\$triplet\debug\bin"
}
$eightBitDll = Join-Path $vcpkgBin 'libx265.dll'
if (!(Test-Path -LiteralPath $eightBitDll)) {
  throw "8-bit x265 is missing. Configure the codec-enabled project with vcpkg first: $eightBitDll"
}

$vcpkgSourceDirectory = Join-Path $VcpkgRoot 'buildtrees\x265\src'
$sourceRoot = $null
if (Test-Path -LiteralPath $vcpkgSourceDirectory -PathType Container) {
  $sourceRoot = Get-ChildItem -Directory $vcpkgSourceDirectory |
    Where-Object Name -Like '*.clean' | Select-Object -First 1
}
if ($sourceRoot) {
  $x265SourcePath = $sourceRoot.FullName
}
else {
  # A vcpkg binary-cache hit installs x265 without retaining its source tree.
  # Fetch the exact x265 revision used by the manifest instead of making release
  # packaging depend on whether a previous build happened from source.
  $x265SourcePath = Join-Path $BuildDirectory 'x265-source'
  $x265Commit = 'e444744c03978c1fb4e037168967020cf2648427' # x265 4.2 tag target
  if (-not (Test-Path -LiteralPath (Join-Path $x265SourcePath '.git'))) {
    & git clone --depth 1 --branch 4.2 `
      https://bitbucket.org/multicoreware/x265_git.git $x265SourcePath
    if ($LASTEXITCODE) { throw "Unable to fetch the pinned x265 source ($LASTEXITCODE)." }
  }
  $actualCommit = (& git -C $x265SourcePath rev-parse HEAD).Trim()
  if ($LASTEXITCODE -or $actualCommit -ne $x265Commit) {
    throw "Unexpected x265 source revision: $actualCommit (expected $x265Commit)."
  }
}

$nasmSearchRoot = Join-Path $VcpkgRoot 'downloads\tools\nasm'
$nasm = $null
if (Test-Path -LiteralPath $nasmSearchRoot -PathType Container) {
  $nasm = Get-ChildItem -Recurse -Filter nasm.exe $nasmSearchRoot |
    Select-Object -First 1
}
if (!$nasm) {
  # NASM is another tool vcpkg does not materialize on a binary-cache hit.
  # Mirror vcpkg's pinned acquisition metadata and verify the archive before use.
  $nasmDirectory = Join-Path $BuildDirectory 'tools\nasm-3.01'
  $nasmExecutable = Join-Path $nasmDirectory 'nasm.exe'
  if (-not (Test-Path -LiteralPath $nasmExecutable -PathType Leaf)) {
    $downloadDirectory = Join-Path $BuildDirectory 'downloads'
    $archive = Join-Path $downloadDirectory 'nasm-3.01-win64.zip'
    New-Item -ItemType Directory -Force $downloadDirectory | Out-Null
    Invoke-WebRequest -UseBasicParsing `
      -Uri 'https://vcpkg.github.io/assets/nasm/nasm-3.01-win64.zip' `
      -OutFile $archive
    $expectedSha512 = '771c238ddb17c98d5736ccaba4ade1d1601d896f09e588489cb43a4f6381bc0ae14d1869f5316fe94f847f54867e65cf12665529b1e7ad88e5e7d3e162719a4f'
    $actualSha512 = (Get-FileHash -LiteralPath $archive -Algorithm SHA512).Hash.ToLowerInvariant()
    if ($actualSha512 -ne $expectedSha512) {
      throw "NASM archive hash mismatch: $actualSha512"
    }
    New-Item -ItemType Directory -Force $nasmDirectory | Out-Null
    Expand-Archive -LiteralPath $archive -DestinationPath $nasmDirectory
    $foundNasm = Get-ChildItem -LiteralPath $nasmDirectory -Recurse -Filter nasm.exe |
      Select-Object -First 1
    if (-not $foundNasm) { throw 'The verified NASM archive did not contain nasm.exe.' }
    if ($foundNasm.FullName -ne $nasmExecutable) {
      Copy-Item -LiteralPath $foundNasm.FullName -Destination $nasmExecutable
    }
  }
  $nasm = Get-Item -LiteralPath $nasmExecutable
}

$main10Build = Join-Path $BuildDirectory 'x265-main10'
& cmake -S (Join-Path $x265SourcePath 'source') -B $main10Build -A x64 `
  -DHIGH_BIT_DEPTH=ON -DENABLE_SHARED=ON -DENABLE_CLI=OFF -DENABLE_ASSEMBLY=ON `
  -DENABLE_LIBNUMA=OFF "-DNASM_EXECUTABLE=$($nasm.FullName)" `
  "-DCMAKE_ASM_NASM_COMPILER=$($nasm.FullName)"
if ($LASTEXITCODE) { throw "Main10 x265 configure failed ($LASTEXITCODE)" }
& cmake --build $main10Build --config $Configuration --parallel
if ($LASTEXITCODE) { throw "Main10 x265 build failed ($LASTEXITCODE)" }

$main10Dll = Join-Path $main10Build "$Configuration\libx265.dll"
if (!(Test-Path -LiteralPath $main10Dll)) { throw "Main10 DLL was not produced: $main10Dll" }
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

Write-Host "Installed x265 multibit runtime for single- and multi-config builds:"
foreach ($runtimeDirectory in $runtimeDirectories) { Write-Host "  $runtimeDirectory" }
Write-Host '  libx265.dll      Main10'
Write-Host '  libx265_main.dll 8-bit fallback for the Gain Map'

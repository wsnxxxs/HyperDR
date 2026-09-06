param(
    [string]$Python = "python",
    [string]$HyperDRExecutable = "",
    [string]$TargetTriple = "x86_64-pc-windows-msvc"
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$desktopRoot = Join-Path $projectRoot "apps\desktop"
$panelRoot = Join-Path $projectRoot "apps\panel"
$tauriRoot = Join-Path $desktopRoot "src-tauri"
$stagingRoot = Join-Path $desktopRoot "dist-sidecar"
$buildRoot = Join-Path $desktopRoot "build-sidecar"
$sidecarExe = Join-Path $stagingRoot "hyperdr-panel.exe"
$binariesRoot = Join-Path $tauriRoot "binaries"

if (-not (Get-Command $Python -ErrorAction SilentlyContinue)) {
    throw "Python executable not found: $Python"
}

if (-not $HyperDRExecutable) {
    $candidates = @(
        (Join-Path $projectRoot "build-release\Release\HyperDR.exe"),
        (Join-Path $projectRoot "build-codecs-win\Release\HyperDR.exe"),
        (Join-Path $projectRoot "build\Release\HyperDR.exe"),
        (Join-Path $projectRoot "build\HyperDR.exe")
    )
    $HyperDRExecutable = $candidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
}
if (-not $HyperDRExecutable) {
    throw "HyperDR.exe was not found. Pass -HyperDRExecutable with a codec-enabled Release build."
}
$HyperDRExecutable = (Resolve-Path -LiteralPath $HyperDRExecutable).Path

Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $stagingRoot, $buildRoot, $binariesRoot -Force | Out-Null

$pyinstallerArgs = @(
    "-m", "PyInstaller",
    "--noconfirm",
    "--clean",
    # Tauri externalBin carries one executable. The Python runtime, static
    # panel files, HyperDR.exe and its DLLs therefore travel in one archive.
    "--onefile",
    # Tauri's shell plugin captures stdout and sets CREATE_NO_WINDOW. The
    # console bootloader is therefore silent to users but can still deliver
    # HYPERDR_READY to the desktop shell.
    "--console",
    "--name", "hyperdr-panel",
    "--icon", (Join-Path $tauriRoot "icons\icon.ico"),
    "--distpath", $stagingRoot,
    "--workpath", $buildRoot,
    "--specpath", $buildRoot,
    "--paths", $panelRoot,
    "--add-data", "$(Join-Path $panelRoot 'web');web",
    "--add-data", "$(Join-Path $projectRoot 'schema');schema"
)
$nativeFiles = @($HyperDRExecutable) + @(
    Get-ChildItem -LiteralPath (Split-Path -Parent $HyperDRExecutable) -Filter "*.dll" -File |
        ForEach-Object { $_.FullName }
)
foreach ($nativeFile in $nativeFiles) {
    $pyinstallerArgs += @("--add-binary", "$nativeFile;bin")
}
$pyinstallerArgs += (Join-Path $panelRoot "hyperdr_gui.py")
& $Python @pyinstallerArgs
if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed with exit code $LASTEXITCODE" }
if (-not (Test-Path -LiteralPath $sidecarExe -PathType Leaf)) {
    throw "PyInstaller did not produce $sidecarExe"
}

$targetSidecar = Join-Path $binariesRoot "hyperdr-panel-$TargetTriple.exe"
Copy-Item -LiteralPath $sidecarExe -Destination $targetSidecar -Force

# Tauri only writes the selected bundle targets; it leaves obsolete versions and
# previously enabled formats (for example MSI) behind. Do not offer those as
# current release installers after a rebuild, including when bundling fails.
$cargoTargetRoot = if ($env:CARGO_TARGET_DIR) {
    $env:CARGO_TARGET_DIR
} else {
    Join-Path $tauriRoot "target"
}
if (-not [System.IO.Path]::IsPathRooted($cargoTargetRoot)) {
    $cargoTargetRoot = Join-Path $tauriRoot $cargoTargetRoot
}
$profile = if ($env:TAURI_ENV_DEBUG -eq "true") { "debug" } else { "release" }
$profileRoots = @(
    (Join-Path $cargoTargetRoot $profile),
    (Join-Path (Join-Path $cargoTargetRoot $TargetTriple) $profile)
)
foreach ($profileRoot in $profileRoots) {
    foreach ($bundle in @(
        @{ Directory = "nsis"; Pattern = "HyperDR_*-setup.exe" },
        @{ Directory = "msi"; Pattern = "HyperDR_*.msi" }
    )) {
        $bundleDirectory = Join-Path (Join-Path $profileRoot "bundle") $bundle.Directory
        if (Test-Path -LiteralPath $bundleDirectory -PathType Container) {
            Get-ChildItem -LiteralPath $bundleDirectory -Filter $bundle.Pattern -File |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
        }
    }
}
Write-Output $targetSidecar

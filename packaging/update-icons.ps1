$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$desktopRoot = Join-Path $projectRoot "apps\desktop"
$iconsRoot = Join-Path $desktopRoot "src-tauri\icons"
$sourceIcon = Join-Path $iconsRoot "icon.svg"
$tauriCli = Join-Path $desktopRoot "node_modules\.bin\tauri.cmd"
$webRoot = Join-Path $projectRoot "apps\panel\web"

if (-not (Test-Path -LiteralPath $tauriCli)) {
    throw "Run npm install in apps/desktop before regenerating icons."
}

& $tauriCli icon $sourceIcon --output $iconsRoot --ios-color "#101723"
if ($LASTEXITCODE -ne 0) { throw "Icon generation failed with exit code $LASTEXITCODE" }

Copy-Item -LiteralPath $sourceIcon -Destination (Join-Path $desktopRoot "ui\icon.svg") -Force
Copy-Item -LiteralPath $sourceIcon -Destination (Join-Path $webRoot "icon.svg") -Force
Copy-Item -LiteralPath (Join-Path $iconsRoot "icon.ico") -Destination (Join-Path $webRoot "favicon.ico") -Force
Copy-Item -LiteralPath (Join-Path $iconsRoot "ios\AppIcon-60x60@3x.png") -Destination (Join-Path $webRoot "apple-touch-icon.png") -Force

Write-Host "Updated native icons, splash branding, panel branding, favicon and Apple touch icon."

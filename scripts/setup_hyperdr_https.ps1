param([switch]$Force)

# Use the same certificate authority as the phone workbench. No tool installation
# or operating-system trust change is needed.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $projectRoot
try {
    $arguments = @("-m", "apps.panel.hyperdr_panel.phone_tls_cli")
    if ($Force) { $arguments += "--force" }
    python @arguments
    $result = $LASTEXITCODE
}
finally { Pop-Location }
exit $result

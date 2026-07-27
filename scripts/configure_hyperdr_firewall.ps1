param(
    [string]$PythonPath = "python",
    [string]$RuleName = "HyperDR-LAN-HTTPS",
    [int]$Port = 8756
)

if ($PythonPath -eq "python") {
    $command = Get-Command python -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "Python executable not found. Pass -PythonPath with the full path to python.exe."
    }
    $PythonPath = $command.Source
}

if (-not (Test-Path -LiteralPath $PythonPath)) {
    throw "Python executable not found: $PythonPath"
}

$existing = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
if ($existing) {
    Remove-NetFirewallRule -Name $ruleName
}

New-NetFirewallRule `
    -Name $ruleName `
    -DisplayName "HyperDR LAN HTTPS" `
    -Description "Allow HyperDR HTTPS from the local subnet only." `
    -Direction Inbound `
    -Action Allow `
    -Enabled True `
    -Profile Private `
    -Program $PythonPath `
    -Protocol TCP `
    -LocalPort $Port `
    -RemoteAddress LocalSubnet | Out-Null

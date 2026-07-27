param(
    [string]$BindAddress = "0.0.0.0",
    [int]$Port = 8756,
    [string]$AccessToken = "",
    [string]$Certificate = "",
    [string]$PrivateKey = ""
)

$projectRoot = Split-Path -Parent $PSScriptRoot
$documentsRoot = Split-Path -Parent $projectRoot
$defaultCertificate = Join-Path $documentsRoot "HyperDR-Cert\hyperdr.pem"
$defaultPrivateKey = Join-Path $documentsRoot "HyperDR-Cert\hyperdr-key.pem"

# Once the mkcert bundle exists, a normal double-click should start the same
# trusted HTTPS service that the iPhone needs for WebGPU HDR.
if (-not $Certificate -and -not $PrivateKey -and
    (Test-Path -LiteralPath $defaultCertificate -PathType Leaf) -and
    (Test-Path -LiteralPath $defaultPrivateKey -PathType Leaf)) {
    $Certificate = $defaultCertificate
    $PrivateKey = $defaultPrivateKey
}

$codecExecutable = Join-Path $projectRoot "build-codecs-win\Release\HyperDR.exe"
if (Test-Path -LiteralPath $codecExecutable -PathType Leaf) {
    $env:HYPERDR_EXECUTABLE = $codecExecutable
}
$env:HYPERDR_HOST = $BindAddress
$env:HYPERDR_PORT = [string]$Port
if ($AccessToken) { $env:HYPERDR_ACCESS_TOKEN = $AccessToken }
if ($Certificate -or $PrivateKey) {
    if (-not ($Certificate -and $PrivateKey)) {
        throw "Certificate and PrivateKey must be supplied together."
    }
    $env:HYPERDR_TLS_CERT = (Resolve-Path -LiteralPath $Certificate).Path
    $env:HYPERDR_TLS_KEY = (Resolve-Path -LiteralPath $PrivateKey).Path
}
else {
    Write-Warning "TLS certificate pair not found. Falling back to HTTP; iPhone true HDR will be unavailable."
}

Set-Location -LiteralPath $projectRoot
python apps\panel\hyperdr_gui.py

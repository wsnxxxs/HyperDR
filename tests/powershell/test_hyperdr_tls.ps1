$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root "scripts\hyperdr_tls.ps1")

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$parsedSan = @(Get-HyperDRSanIpAddressFromText `
    -San "IP Address=192.168.1.100, IP Address=127.0.0.1, DNS Name=localhost")
Assert-True `
    -Condition ($parsedSan.Count -eq 2 -and
        $parsedSan -contains "192.168.1.100" -and
        $parsedSan -contains "127.0.0.1") `
    -Message "SAN IP extraction did not return complete address entries"

Assert-True `
    -Condition (-not (Test-HyperDRAddressCovered `
        -CertificateAddresses @("192.168.1.100") `
        -CurrentAddresses @("192.168.1.10"))) `
    -Message "SAN address matching accepted a substring"

Assert-True `
    -Condition (Test-HyperDRAddressCovered `
        -CertificateAddresses @("192.168.1.100", "127.0.0.1") `
        -CurrentAddresses @("192.168.1.100")) `
    -Message "SAN address matching rejected an exact address"

Assert-True `
    -Condition (Test-HyperDRAddressCovered `
        -CertificateAddresses @("2001:db8::1") `
        -CurrentAddresses @("2001:0db8:0:0:0:0:0:1")) `
    -Message "SAN address matching did not canonicalize IPv6"

Assert-True `
    -Condition (-not (Protect-HyperDRPrivateKey `
        -KeyPath (Join-Path $env:TEMP "hyperdr-missing-private-key.pem"))) `
    -Message "private-key protection reported success for a missing file"

$temporaryKey = Join-Path $env:TEMP ("hyperdr-acl-test-" + [Guid]::NewGuid().ToString("N") + ".pem")
try {
    [IO.File]::WriteAllText($temporaryKey, "test key material")
    Assert-True `
        -Condition (Protect-HyperDRPrivateKey -KeyPath $temporaryKey) `
        -Message "private-key protection failed for a writable temporary file"
}
finally {
    Remove-Item -LiteralPath $temporaryKey -Force -ErrorAction SilentlyContinue
}

Write-Host "TLS helper tests passed"

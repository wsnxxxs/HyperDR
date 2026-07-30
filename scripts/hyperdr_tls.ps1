# Shared TLS helpers for HyperDR's Windows launchers.
#
# Dot-source this file; it defines paths and functions but performs no action of
# its own. Both the first-run setup and the normal launcher depend on it so the
# two can never disagree about where a certificate lives or how one is issued.

# Certificates belong to the Windows user, not to the program directory: a
# release archive may be extracted anywhere, and Documents may be redirected
# into a cloud-synced folder, which is no place for a private key.
$HyperDRConfigRoot = Join-Path $env:LOCALAPPDATA "HyperDR"
$HyperDRTlsRoot = Join-Path $HyperDRConfigRoot "tls"
$HyperDRCertificate = Join-Path $HyperDRTlsRoot "hyperdr.pem"
$HyperDRPrivateKey = Join-Path $HyperDRTlsRoot "hyperdr-key.pem"
$HyperDRToolRoot = Join-Path $HyperDRConfigRoot "bin"

# Where releases before 0.2.2 told people to put the mkcert bundle.
$HyperDRLegacyRoot = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "HyperDR-Cert"
$HyperDRLegacyCertificate = Join-Path $HyperDRLegacyRoot "hyperdr.pem"
$HyperDRLegacyPrivateKey = Join-Path $HyperDRLegacyRoot "hyperdr-key.pem"


function Test-HyperDRCertificatePair {
    param([string]$CertPath, [string]$KeyPath)
    return ($CertPath -and $KeyPath -and
        (Test-Path -LiteralPath $CertPath -PathType Leaf) -and
        (Test-Path -LiteralPath $KeyPath -PathType Leaf))
}


function Get-HyperDRLanAddress {
    <#
        .SYNOPSIS
        Every IPv4 address a phone on the same network could reach, the one
        behind the default route first.

        .DESCRIPTION
        Virtual switches and VPN adapters routinely add addresses that no phone
        can reach. Printing those, or putting them in a certificate, only
        produces confusing failures, so the default route decides the order.
    #>
    $preferred = ""
    try {
        $configured = Get-NetIPConfiguration -ErrorAction Stop |
            Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
            Select-Object -First 1
        if ($configured -and $configured.IPv4Address) {
            $preferred = $configured.IPv4Address[0].IPAddress
        }
    }
    catch { }

    $all = @()
    try {
        $all = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object {
                $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*'
            } | Select-Object -ExpandProperty IPAddress)
    }
    catch { }

    if ($preferred) {
        $all = @($preferred) + @($all | Where-Object { $_ -ne $preferred })
    }
    return @($all | Select-Object -Unique)
}


function Get-HyperDRCertificateSan {
    param([string]$CertPath)
    if (-not (Test-Path -LiteralPath $CertPath -PathType Leaf)) { return "" }
    try {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $CertPath
    }
    catch { return "" }
    foreach ($extension in $cert.Extensions) {
        if ($extension.Oid.Value -eq "2.5.29.17") {
            # Format() localises the labels but not the address literals. The
            # parser below extracts those literals and compares canonical IPs.
            return $extension.Format($false)
        }
    }
    return ""
}


function Get-HyperDRSanIpAddressFromText {
    param([string]$San)
    if (-not $San) { return @() }

    $addresses = @()
    $ipv4Pattern = '(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])'
    foreach ($match in [regex]::Matches($San, $ipv4Pattern)) {
        $parsed = $null
        if ([Net.IPAddress]::TryParse($match.Value, [ref]$parsed)) {
            $addresses += $parsed.ToString()
        }
    }

    $ipv6Pattern = '(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![0-9A-Fa-f:])'
    foreach ($match in [regex]::Matches($San, $ipv6Pattern)) {
        $parsed = $null
        if ([Net.IPAddress]::TryParse($match.Value, [ref]$parsed)) {
            $addresses += $parsed.ToString()
        }
    }
    return @($addresses | Select-Object -Unique)
}


function Get-HyperDRCertificateSanIpAddress {
    <#
        .SYNOPSIS
        Return canonical IP-address entries from a certificate SAN.

        .DESCRIPTION
        X509Extension.Format() localises the labels but leaves address literals
        unchanged. Extracting and parsing those literals gives callers exact,
        canonical values instead of the unsafe substring matching previously
        used against the whole formatted extension.
    #>
    param([string]$CertPath)
    $san = Get-HyperDRCertificateSan -CertPath $CertPath
    return @(Get-HyperDRSanIpAddressFromText -San $san)
}


function Test-HyperDRAddressCovered {
    param([string[]]$CertificateAddresses, [string[]]$CurrentAddresses)
    $covered = @{}
    foreach ($address in $CertificateAddresses) {
        $parsed = $null
        if ([Net.IPAddress]::TryParse($address, [ref]$parsed)) {
            $covered[$parsed.ToString()] = $true
        }
    }
    foreach ($address in $CurrentAddresses) {
        $parsed = $null
        if ([Net.IPAddress]::TryParse($address, [ref]$parsed) -and
            $covered.ContainsKey($parsed.ToString())) {
            return $true
        }
    }
    return $false
}


function Test-HyperDRCertificateCoversAddress {
    param([string]$CertPath, [string[]]$Addresses)
    $certificateAddresses = @(Get-HyperDRCertificateSanIpAddress -CertPath $CertPath)
    return Test-HyperDRAddressCovered -CertificateAddresses $certificateAddresses `
        -CurrentAddresses $Addresses
}


function Get-HyperDRCertificateExpiry {
    param([string]$CertPath)
    if (-not (Test-Path -LiteralPath $CertPath -PathType Leaf)) { return $null }
    try {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $CertPath
        return $cert.NotAfter
    }
    catch { return $null }
}


function Protect-HyperDRPrivateKey {
    <#
        .SYNOPSIS
        Restrict the private key to the current Windows user.

        .DESCRIPTION
        Inherited entries are dropped so other accounts on a shared machine
        cannot read the key. The owner keeps full control on purpose: a
        read-only key cannot be replaced, which would silently break every
        later re-issue after the router changes the computer's address.
    #>
    param([string]$KeyPath)
    if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) { return $false }
    try {
        $account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        icacls "$KeyPath" /inheritance:r /grant:r "${account}:(F)" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "无法限制私钥权限（icacls 退出码 $LASTEXITCODE）：$KeyPath"
            return $false
        }
        return $true
    }
    catch {
        Write-Warning ("无法限制私钥权限：" + $_.Exception.Message)
        return $false
    }
}


function Update-HyperDRPathFromRegistry {
    # A freshly installed tool is on the machine but not in this process's PATH
    # until the environment is re-read.
    try {
        $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
        $user = [Environment]::GetEnvironmentVariable("Path", "User")
        $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ";"
    }
    catch { }
}


function Invoke-HyperDRTool {
    <#
        .SYNOPSIS
        Run a native tool and echo its output as plain text.

        .DESCRIPTION
        mkcert and winget write ordinary progress to stderr. Piping that through
        `2>&1` makes PowerShell render it as a red error block complete with a
        stack trace, which reads as a crash to anyone who merely double-clicked
        a .bat file. Flattening the records keeps the message and drops the
        theatre. Returns the tool's exit code.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [string[]]$ToolArguments = @(),
        [string]$Indent = "  "
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Executable @ToolArguments 2>&1 | ForEach-Object {
            $line = if ($_ -is [System.Management.Automation.ErrorRecord]) {
                $_.Exception.Message
            }
            else { $_.ToString() }
            if ($line -and $line.Trim()) { Write-Host ($Indent + $line.TrimEnd()) }
        }
    }
    finally { $ErrorActionPreference = $previous }
    return $LASTEXITCODE
}


function Resolve-HyperDRMkcert {
    <#
        .SYNOPSIS
        Path to a usable mkcert.exe, or "" when none can be found.

        .PARAMETER Install
        Allow installing mkcert through winget when it is missing.
    #>
    param([switch]$Install)

    $found = (Get-Command mkcert -ErrorAction SilentlyContinue)
    if ($found) { return $found.Source }

    $candidates = @(
        (Join-Path $HyperDRToolRoot "mkcert.exe"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\mkcert.exe")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    if (-not $Install) { return "" }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        return ""
    }

    Write-Host "正在通过 winget 安装 mkcert……" -ForegroundColor Cyan
    try {
        [void](Invoke-HyperDRTool -Executable "winget" -ToolArguments @(
                "install", "--id", "FiloSottile.mkcert", "--exact", "--silent",
                "--accept-source-agreements", "--accept-package-agreements"))
    }
    catch {
        Write-Warning ("winget 安装失败：" + $_.Exception.Message)
        return ""
    }

    Update-HyperDRPathFromRegistry
    $found = (Get-Command mkcert -ErrorAction SilentlyContinue)
    if ($found) { return $found.Source }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return ""
}


function Get-HyperDRCaRoot {
    param([string]$Mkcert)
    if (-not $Mkcert) { return "" }
    try {
        $root = (& $Mkcert -CAROOT 2>&1 | Select-Object -First 1)
        if ($root) { return $root.ToString().Trim() }
    }
    catch { }
    return ""
}


function New-HyperDRServerCertificate {
    <#
        .SYNOPSIS
        Issue (or re-issue) the server certificate from the machine's local CA.

        .DESCRIPTION
        Only the leaf changes. The CA that the iPhone trusts is left alone, which
        is what makes a re-issue after a DHCP change invisible to the phone.
        Returns $true on success.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Mkcert,
        [string[]]$Addresses
    )

    $names = @()
    foreach ($address in @($Addresses)) {
        if ($address -and ($names -notcontains $address)) { $names += $address }
    }
    # The host name is a free extra: it helps wherever mDNS or NetBIOS happens
    # to resolve, and costs nothing where it does not. Ask the network stack
    # rather than %COMPUTERNAME%, which is absent from some service and
    # automation environments.
    $hostName = ""
    try { $hostName = [System.Net.Dns]::GetHostName() } catch { $hostName = $env:COMPUTERNAME }
    foreach ($extra in @("127.0.0.1", "localhost", $hostName)) {
        if ($extra -and ($names -notcontains $extra)) { $names += $extra }
    }
    if (-not $names) {
        Write-Warning "没有可用的局域网地址，无法签发证书。"
        return $false
    }

    try {
        New-Item -ItemType Directory -Path $HyperDRTlsRoot -Force -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Warning ("无法创建证书目录 $HyperDRTlsRoot ：" + $_.Exception.Message)
        return $false
    }

    $arguments = @("-cert-file", $HyperDRCertificate, "-key-file", $HyperDRPrivateKey) + $names
    try {
        [void](Invoke-HyperDRTool -Executable $Mkcert -ToolArguments $arguments)
    }
    catch {
        Write-Warning ("签发证书失败：" + $_.Exception.Message)
        return $false
    }
    if (-not (Test-HyperDRCertificatePair $HyperDRCertificate $HyperDRPrivateKey)) {
        Write-Warning "mkcert 未能生成证书文件。"
        return $false
    }

    if (-not (Protect-HyperDRPrivateKey -KeyPath $HyperDRPrivateKey)) {
        return $false
    }
    return $true
}

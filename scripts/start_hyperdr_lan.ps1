param(
    [string]$BindAddress = "0.0.0.0",
    [int]$Port = 8756,
    [string]$AccessToken = "",
    [string]$Certificate = "",
    [string]$PrivateKey = "",
    # Skip the certificate check entirely and serve plain HTTP.
    [switch]$NoTls
)

# The console must be UTF-8 before anything Chinese is printed, otherwise a
# direct `powershell -File` invocation (without Start.bat's chcp) garbles it.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "hyperdr_tls.ps1")


function Import-LegacyCertificate {
    # Returns $true when a pre-0.2.2 bundle was carried into the managed store.
    if (-not (Test-HyperDRCertificatePair $HyperDRLegacyCertificate $HyperDRLegacyPrivateKey)) {
        return $false
    }
    try {
        New-Item -ItemType Directory -Path $HyperDRTlsRoot -Force -ErrorAction Stop | Out-Null
        Copy-Item -LiteralPath $HyperDRLegacyCertificate -Destination $HyperDRCertificate -Force -ErrorAction Stop
        Copy-Item -LiteralPath $HyperDRLegacyPrivateKey -Destination $HyperDRPrivateKey -Force -ErrorAction Stop
    }
    catch {
        Write-Warning ("旧证书迁移失败：" + $_.Exception.Message)
        return $false
    }
    Protect-HyperDRPrivateKey -KeyPath $HyperDRPrivateKey
    Write-Host ""
    Write-Host "已将旧版证书迁移到用户配置目录：" -ForegroundColor Green
    Write-Host "  来源：$HyperDRLegacyRoot"
    Write-Host "  目标：$HyperDRTlsRoot"
    Write-Host "  原文件未删除，确认无误后可自行清理。"
    Write-Host ""
    return $true
}


function Repair-ManagedCertificate {
    <#
        .SYNOPSIS
        Re-issue the managed certificate when it no longer matches this network.

        .DESCRIPTION
        A DHCP lease change is the single most common way a working setup
        breaks. Re-issuing from the same local CA fixes it without the phone
        noticing, so it happens automatically -- but only for the certificate
        HyperDR manages itself, never for one the person passed in by hand.
        Returns $true when the certificate was replaced.
    #>
    param([string]$Reason, [string[]]$Addresses)

    $mkcert = Resolve-HyperDRMkcert
    if (-not $mkcert) {
        Write-Host ""
        Write-Host "================ 证书需要更新 ================" -ForegroundColor Yellow
        Write-Host " $Reason"
        Write-Host ""
        Write-Host " 本应自动重新签发，但这台电脑上找不到 mkcert。"
        Write-Host " 请双击 Setup-HTTPS.bat 完成一次配置，之后就会自动维护。"
        Write-Host "==============================================" -ForegroundColor Yellow
        Write-Host ""
        return $false
    }

    Write-Host ""
    Write-Host "证书需要更新：$Reason" -ForegroundColor Yellow
    Write-Host "正在用本机原有的根证书重新签发……" -ForegroundColor Cyan
    if (-not (New-HyperDRServerCertificate -Mkcert $mkcert -Addresses $Addresses)) {
        Write-Warning "自动重签失败。请双击 Setup-HTTPS.bat 手动配置。"
        return $false
    }
    Write-Host "已重新签发，覆盖地址：$($Addresses -join '、')、127.0.0.1、localhost" -ForegroundColor Green
    Write-Host "iPhone 上已安装的根证书无需重装，直接使用新地址即可。" -ForegroundColor Green
    Write-Host ""
    return $true
}


function Confirm-Certificate {
    <#
        .SYNOPSIS
        Report on the certificate, repairing it when HyperDR owns it.

        .DESCRIPTION
        Nothing here is fatal. A certificate problem must be loud and
        actionable, but it must never stop someone who only wants to convert a
        file over plain HTTP.
    #>
    param([string]$CertPath, [switch]$Managed)

    $expiry = Get-HyperDRCertificateExpiry -CertPath $CertPath
    if (-not $expiry) {
        Write-Warning "无法读取证书 $CertPath 。"
        return
    }
    $addresses = @(Get-HyperDRLanAddress)
    $remainingDays = [math]::Round(($expiry - (Get-Date)).TotalDays)

    if ($remainingDays -lt 30) {
        $reason = if ($remainingDays -lt 0) {
            "证书已于 $($expiry.ToString('yyyy-MM-dd')) 过期。"
        }
        else {
            "证书将在 $remainingDays 天后（$($expiry.ToString('yyyy-MM-dd'))）过期。"
        }
        if ($Managed) {
            if (Repair-ManagedCertificate -Reason $reason -Addresses $addresses) { return }
        }
        else {
            Write-Warning ($reason + " 请重新签发。")
        }
    }

    if (-not $addresses) { return }
    $san = Get-HyperDRCertificateSan -CertPath $CertPath
    if (-not $san) { return }
    $matched = @($addresses | Where-Object { $san -match [regex]::Escape($_) })
    if ($matched) { return }

    $reason = "当前局域网地址 $($addresses -join '、') 不在证书覆盖范围内。"
    if ($Managed) {
        if (Repair-ManagedCertificate -Reason $reason -Addresses $addresses) { return }
    }

    Write-Host ""
    Write-Host "================ 证书与当前网络不匹配 ================" -ForegroundColor Yellow
    Write-Host " 本机局域网地址：$($addresses -join '、')"
    Write-Host " 证书覆盖范围　：$san"
    Write-Host ""
    Write-Host " iPhone 通过这个地址访问时会报证书错误，WebGPU 真 HDR 不可用。"
    Write-Host " 用原有的本地 CA 重新签发即可，iPhone 上的根证书无需重装："
    Write-Host ""
    Write-Host "   mkcert -cert-file `"$CertPath`" -key-file `"$PrivateKey`" $($addresses[0]) 127.0.0.1 localhost"
    Write-Host ""
    Write-Host " 想一劳永逸，请在路由器里为本机设置 DHCP 保留或静态 IP。"
    Write-Host "======================================================" -ForegroundColor Yellow
    Write-Host ""
}


function Show-MissingCertificateHelp {
    Write-Host ""
    Write-Host "================ 未配置 HTTPS，将以 HTTP 启动 ================" -ForegroundColor Yellow
    Write-Host " 上传、转换、下载都可以正常使用。"
    Write-Host " 但 Safari 的 WebGPU 真 HDR 实时预览需要受信任的 HTTPS，本次不可用。"
    Write-Host ""
    Write-Host " 要启用真 HDR，双击 Setup-HTTPS.bat 完成一次性配置。" -ForegroundColor Cyan
    Write-Host ""
    Write-Host " 已查找的位置："
    Write-Host "   1. -Certificate / -PrivateKey 命令行参数"
    Write-Host "   2. HYPERDR_TLS_CERT / HYPERDR_TLS_KEY 环境变量"
    Write-Host "   3. $HyperDRTlsRoot"
    Write-Host "   4. $HyperDRLegacyRoot （旧版位置，仅用于自动迁移）"
    Write-Host "==============================================================" -ForegroundColor Yellow
    Write-Host ""
}


# ---------------------------------------------------------------------------
# Resolve the certificate pair, most explicit source first.
# ---------------------------------------------------------------------------
$certificateSource = ""
$certificateIsManaged = $false

if ($NoTls) {
    Write-Host "已按 -NoTls 要求以 HTTP 启动。" -ForegroundColor DarkGray
}
elseif ($Certificate -or $PrivateKey) {
    # An explicit request that cannot be honoured is an error, not a silent
    # downgrade -- but it should read as a message, not as a stack trace.
    if (-not ($Certificate -and $PrivateKey)) {
        Write-Host ""
        Write-Host "-Certificate 与 -PrivateKey 必须成对提供。" -ForegroundColor Red
        Write-Host ""
        exit 1
    }
    if (-not (Test-HyperDRCertificatePair $Certificate $PrivateKey)) {
        Write-Host ""
        Write-Host "指定的证书或私钥不存在：" -ForegroundColor Red
        foreach ($path in @($Certificate, $PrivateKey)) {
            $mark = if (Test-Path -LiteralPath $path -PathType Leaf) { "存在  " } else { "找不到" }
            Write-Host "  [$mark] $path"
        }
        Write-Host ""
        Write-Host "不带参数直接运行本脚本，会自动使用 $HyperDRTlsRoot 下的证书。"
        Write-Host ""
        exit 1
    }
    $certificateSource = "命令行参数"
}
elseif (Test-HyperDRCertificatePair $env:HYPERDR_TLS_CERT $env:HYPERDR_TLS_KEY) {
    $Certificate = $env:HYPERDR_TLS_CERT
    $PrivateKey = $env:HYPERDR_TLS_KEY
    $certificateSource = "环境变量"
}
else {
    if (-not (Test-HyperDRCertificatePair $HyperDRCertificate $HyperDRPrivateKey)) {
        [void](Import-LegacyCertificate)
    }
    if (Test-HyperDRCertificatePair $HyperDRCertificate $HyperDRPrivateKey) {
        $Certificate = $HyperDRCertificate
        $PrivateKey = $HyperDRPrivateKey
        $certificateSource = $HyperDRTlsRoot
        $certificateIsManaged = $true
    }
}

# A stale environment variable pointing at a missing file must not make the
# Python side believe it is serving HTTPS.
$env:HYPERDR_TLS_CERT = ""
$env:HYPERDR_TLS_KEY = ""

$codecExecutable = Join-Path $projectRoot "build-codecs-win\Release\HyperDR.exe"
if (Test-Path -LiteralPath $codecExecutable -PathType Leaf) {
    $env:HYPERDR_EXECUTABLE = $codecExecutable
}
$env:HYPERDR_HOST = $BindAddress
$env:HYPERDR_PORT = [string]$Port
if ($AccessToken) { $env:HYPERDR_ACCESS_TOKEN = $AccessToken }

if ($certificateSource) {
    Write-Host "TLS 证书来源：$certificateSource" -ForegroundColor DarkGray
    Confirm-Certificate -CertPath $Certificate -Managed:$certificateIsManaged
    $env:HYPERDR_TLS_CERT = (Resolve-Path -LiteralPath $Certificate).Path
    $env:HYPERDR_TLS_KEY = (Resolve-Path -LiteralPath $PrivateKey).Path
}
elseif (-not $NoTls) {
    Show-MissingCertificateHelp
}

Set-Location -LiteralPath $projectRoot
python apps\panel\hyperdr_gui.py

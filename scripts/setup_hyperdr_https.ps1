param(
    # Re-issue even when the existing certificate already covers this network.
    [switch]$Force
)

# First-run HTTPS setup. Safari's WebGPU HDR canvas requires a genuine secure
# context, so trusted HTTPS is not an optional extra for true HDR -- it is the
# install step. Everything this script writes lives under the Windows user
# profile, so it never depends on where the release archive was extracted.

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
. (Join-Path $PSScriptRoot "hyperdr_tls.ps1")

function Write-Heading {
    param([string]$Text)
    Write-Host ""
    Write-Host ("=" * 64) -ForegroundColor DarkCyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host ("=" * 64) -ForegroundColor DarkCyan
}

Write-Heading "HyperDR 受信任 HTTPS 配置"
Write-Host " 本机将生成一个专属的本地根证书颁发机构，并用它签发一张"
Write-Host " 只在你的局域网内有效的服务器证书。"
Write-Host ""
Write-Host " 这个根证书只属于这台电脑，不会随安装包分发，也不会上传到任何地方。"

# --------------------------------------------------------------------------
# 1. mkcert
# --------------------------------------------------------------------------
Write-Heading "第 1 步：准备证书工具"
$mkcert = Resolve-HyperDRMkcert -Install
if (-not $mkcert) {
    Write-Host ""
    Write-Host "找不到 mkcert，也无法自动安装。" -ForegroundColor Red
    Write-Host ""
    Write-Host "请手动安装后重新运行本程序，任选一种："
    Write-Host "  1. winget install FiloSottile.mkcert"
    Write-Host "  2. 从 https://github.com/FiloSottile/mkcert/releases 下载 mkcert.exe，"
    Write-Host "     改名为 mkcert.exe 后放到："
    Write-Host "     $HyperDRToolRoot"
    Write-Host ""
    exit 1
}
Write-Host "  mkcert：$mkcert" -ForegroundColor Green

# --------------------------------------------------------------------------
# 2. Local certificate authority
# --------------------------------------------------------------------------
Write-Heading "第 2 步：安装本机根证书颁发机构"
$caRoot = Get-HyperDRCaRoot -Mkcert $mkcert
$caExisted = $caRoot -and (Test-Path -LiteralPath (Join-Path $caRoot "rootCA-key.pem") -PathType Leaf)
if ($caExisted) {
    Write-Host "  已存在本机 CA，将继续使用它（iPhone 上装过的根证书无需重装）。" -ForegroundColor Green
}
try {
    [void](Invoke-HyperDRTool -Executable $mkcert -ToolArguments @("-install"))
}
catch {
    Write-Warning ("mkcert -install 失败：" + $_.Exception.Message)
    exit 1
}
$caRoot = Get-HyperDRCaRoot -Mkcert $mkcert
$caCertificate = Join-Path $caRoot "rootCA.pem"
if (-not (Test-Path -LiteralPath $caCertificate -PathType Leaf)) {
    Write-Host "找不到根证书 $caCertificate，配置中止。" -ForegroundColor Red
    exit 1
}
Write-Host "  CA 目录：$caRoot" -ForegroundColor Green

# --------------------------------------------------------------------------
# 3. Server certificate
# --------------------------------------------------------------------------
Write-Heading "第 3 步：签发服务器证书"
$addresses = @(Get-HyperDRLanAddress)
if (-not $addresses) {
    Write-Host "未检测到局域网 IPv4 地址。请先连接 Wi-Fi 或以太网后重试。" -ForegroundColor Red
    exit 1
}
Write-Host "  检测到的局域网地址：$($addresses -join '、')"

$san = Get-HyperDRCertificateSan -CertPath $HyperDRCertificate
$covered = $san -and ($addresses | Where-Object { $san -match [regex]::Escape($_) })
if ($covered -and -not $Force) {
    Write-Host "  现有证书已覆盖当前网络，跳过签发。加 -Force 可强制重新签发。" -ForegroundColor Green
}
else {
    if (-not (New-HyperDRServerCertificate -Mkcert $mkcert -Addresses $addresses)) {
        Write-Host "签发失败，配置中止。" -ForegroundColor Red
        exit 1
    }
    Write-Host "  证书：$HyperDRCertificate" -ForegroundColor Green
    Write-Host "  私钥：$HyperDRPrivateKey（已限制为仅当前用户可读）" -ForegroundColor Green
}

$expiry = Get-HyperDRCertificateExpiry -CertPath $HyperDRCertificate
if ($expiry) { Write-Host "  有效期至：$($expiry.ToString('yyyy-MM-dd'))" }

# --------------------------------------------------------------------------
# 4. Root certificate for the phone
# --------------------------------------------------------------------------
Write-Heading "第 4 步：把根证书传到 iPhone"
$desktop = [Environment]::GetFolderPath("Desktop")
$exported = Join-Path $desktop "HyperDR-rootCA.crt"
try {
    Copy-Item -LiteralPath $caCertificate -Destination $exported -Force -ErrorAction Stop
    Write-Host "  已导出到桌面：$exported" -ForegroundColor Green
}
catch {
    Write-Warning ("导出根证书失败：" + $_.Exception.Message)
    Write-Host "  可手动复制：$caCertificate"
    $exported = $caCertificate
}
Write-Host ""
Write-Host "  这个文件只包含公钥，可以安全地通过隔空投送、邮件或聊天工具发送。"
Write-Host "  同目录下的 rootCA-key.pem 是私钥，绝对不要发送给任何人。" -ForegroundColor Yellow
Write-Host ""
Write-Host "  在 iPhone 上需要做两步，缺一不可：" -ForegroundColor Cyan
Write-Host "    1. 打开收到的文件，按提示安装描述文件"
Write-Host "       （设置 → 已下载描述文件 → 安装）"
Write-Host "    2. 设置 → 通用 → 关于本机 → 证书信任设置"
Write-Host "       找到这个证书，打开“启用完全信任”开关"
Write-Host ""
Write-Host "  只做第 1 步而不做第 2 步，Safari 仍会报证书错误。" -ForegroundColor Yellow

# --------------------------------------------------------------------------
# 5. Done
# --------------------------------------------------------------------------
Write-Heading "配置完成"
Write-Host " 现在双击 Start.bat 即可，启动窗口会打印形如"
Write-Host ""
Write-Host "   https://$($addresses[0]):8756/?token=..." -ForegroundColor Green
Write-Host ""
Write-Host " 的地址，在 iPhone Safari 中打开完整地址（含 token）。"
Write-Host ""
Write-Host " 提示：路由器重新分配 IP 后，启动脚本会用同一个 CA 自动重签服务器证书，"
Write-Host " iPhone 无需任何操作。想彻底避免，可在路由器里为本机设置 DHCP 保留。"
Write-Host ""
Write-Host " 如果 iPhone 连不上，多半是防火墙：可运行"
Write-Host "   scripts\configure_hyperdr_firewall.ps1"
Write-Host " 或在 Windows 询问时允许“专用网络”。"
Write-Host ""

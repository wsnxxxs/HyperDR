# 在 iPhone Safari 中使用 HyperDR

HyperDR 现在可以由 Windows 电脑在局域网内提供服务。iPhone 负责选择和上传照片、调节参数、查看预览以及下载结果；RAW 解码和 HEIC 编码仍在电脑上完成。

## 首次使用

想要 iPhone 上的**真 HDR 实时预览**，先双击一次 `Setup-HTTPS.bat`，按它打印的两步在 iPhone 上安装并信任根证书，之后每次双击 `Start.bat` 即可。详见下方“配置受信任 HTTPS”。

只想上传、转换、下载，不需要实时 HDR 预览的，可以跳过这一步，直接用下面的 HTTP 模式。

## 快速启动（HTTP）

1. 确认 iPhone 与电脑连接到同一个可信 Wi-Fi。
2. 双击项目根目录的 `Start.bat`。
3. Windows 防火墙询问时，只允许“专用网络”。
4. 启动窗口会打印一个带临时访问口令的 `iPhone 地址`，例如：

   ```text
   http://<LAN_IP>:8756/?token=xxxxxxxx
   ```

5. 在 iPhone Safari 中打开完整地址。首次成功登录后，地址栏中的口令会自动移除。

HTTP 模式可以上传、转换、下载并查看 SDR 示意预览。Safari 的 WebGPU 真 HDR 实时画布需要受信任的 HTTPS；最终 HEIC 仍可下载并在“照片”中以 HDR 查看。

任务文件保存在 `hdr-workspace`，默认 24 小时后在下一次启动时清理。每个文件默认最多 256 MB，每个任务最多 1 GB；可以分别通过 `HYPERDR_MAX_UPLOAD_MB`、`HYPERDR_MAX_SESSION_MB` 和 `HYPERDR_SESSION_HOURS` 调整。

## 配置受信任 HTTPS

Safari 的 WebGPU 只在安全上下文中开放，所以真 HDR 需要一张**受信任的**证书。点“继续访问”忽略警告没有用：例外不构成安全上下文。

### 推荐做法：Setup-HTTPS.bat

双击项目根目录的 `Setup-HTTPS.bat`，它会自动完成：

1. 检测 `mkcert`，缺失时通过 winget 安装；
2. 创建（或复用）**只属于这台电脑**的本地根证书颁发机构；
3. 按当前局域网 IPv4 签发服务器证书，写入 `%LOCALAPPDATA%\HyperDR\tls`，并把私钥权限收紧为仅当前 Windows 用户；
4. 把根证书导出到桌面，文件名 `HyperDR-rootCA.crt`。

然后把桌面上的 `HyperDR-rootCA.crt` 传到 iPhone（隔空投送、邮件、聊天工具均可，它只含公钥），在 iPhone 上完成**两步**：

1. 打开文件并安装描述文件：设置 → 已下载描述文件 → 安装；
2. 设置 → 通用 → 关于本机 → 证书信任设置，找到这个证书，打开“启用完全信任”。

**只做第 1 步而不做第 2 步，Safari 仍会报证书错误。** 这是最常见的失败原因。

配置完成后双击 `Start.bat` 即可，不需要任何参数。

发布包里不包含任何根证书或私钥。每台电脑都必须生成自己的 CA——如果所有安装共享同一个根 CA 私钥，任何拿到它的人都能对信任了该 CA 的手机伪造任意网站的证书。

### 手动做法

如果不想用向导，也可以自己生成。证书**不要**放在程序目录或其附近；启动脚本固定从下面这个位置读取，与发布包解压到哪里无关：

```text
%LOCALAPPDATA%\HyperDR\tls\hyperdr.pem
%LOCALAPPDATA%\HyperDR\tls\hyperdr-key.pem
```

先确认电脑当前的局域网 IPv4 地址（下面记作 `<LAN_IP>`），然后生成证书：

```powershell
mkcert -install
mkdir "$env:LOCALAPPDATA\HyperDR\tls" -Force
mkcert -cert-file "$env:LOCALAPPDATA\HyperDR\tls\hyperdr.pem" `
       -key-file  "$env:LOCALAPPDATA\HyperDR\tls\hyperdr-key.pem" `
       <LAN_IP> 127.0.0.1 localhost
mkcert -CAROOT
```

把 `mkcert -CAROOT` 所在目录中的 `rootCA.pem` 按上面的两步传到 iPhone 并信任。

### 证书查找顺序

启动脚本按下面的顺序取第一个可用的证书对：

1. `-Certificate` / `-PrivateKey` 命令行参数
2. `HYPERDR_TLS_CERT` / `HYPERDR_TLS_KEY` 环境变量
3. `%LOCALAPPDATA%\HyperDR\tls\`
4. `文档\HyperDR-Cert\`（0.2.2 之前的位置，仅在首次启动时自动复制到 3，不会删除原文件）

如果只想临时指定一对证书：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\start_hyperdr_lan.ps1 `
  -Certificate C:\安全目录\hyperdr.pem `
  -PrivateKey C:\安全目录\hyperdr-key.pem
```

### IP 变化后

证书里的 IP 必须与 iPhone 访问的地址一致。路由器重新分配 IP 后，`Start.bat` 会检测到当前地址不在证书覆盖范围内，**用同一个本地 CA 自动重新签发**服务器证书并在窗口中说明。只有服务器证书被替换，iPhone 上已安装的根证书无需任何操作。

自动重签只作用于 `%LOCALAPPDATA%\HyperDR\tls` 下由 HyperDR 管理的那对证书。通过 `-Certificate` / `-PrivateKey` 或环境变量手动指定的证书只会被检查并提示，不会被改动。

如果这台电脑上找不到 `mkcert`，启动窗口会提示运行 `Setup-HTTPS.bat`。也可以手动重签：

```powershell
mkcert -cert-file "$env:LOCALAPPDATA\HyperDR\tls\hyperdr.pem" `
       -key-file  "$env:LOCALAPPDATA\HyperDR\tls\hyperdr-key.pem" `
       新的IP 127.0.0.1 localhost
```

想彻底避免这件事，请在路由器里为这台电脑设置 DHCP 保留或静态 IP。

证书临近过期（剩余不足 30 天）时同样会自动重签。

### 备份与安全

根 CA 的私钥（`mkcert -CAROOT` 目录中的 `rootCA-key.pem`）是整套配置里**唯一不可再生**的文件。丢失后必须重新生成 CA，并在每一台 iPhone 上重装根证书。建议离线备份，且不要放进会被云端同步的目录——这也是证书不再存放于“文档”的原因之一，那里可能被 OneDrive 重定向。

服务器私钥 `hyperdr-key.pem` 的权限被收紧为仅当前 Windows 用户可访问。私钥不要复制到 iPhone，也不要提交到版本库；仓库的 `.gitignore` 已排除 `*.pem`、`*.key`、`*.pfx`、`*.p12`、`*.crt`、`*.cer`。

Safari 应使用启动窗口打印的 `https://局域网地址:端口/?token=...`，证书中的 IP 必须与访问地址一致。

## HDR 预览层级

- 滑块拖动：在受信任 HTTPS、HDR 屏幕和 Safari 26+ 环境中使用 WebGPU `rgba16float`
  扩展 Display P3 输出。每次建立 HDR 渲染器都会在浏览器 GPU 上用正式 shader 做一次像素读回，
  验证非线性 P3 编码及大于 1 的扩展值未被画布截断；不通过时明确回退到 WebGL2 GPU
  加速的 SDR 示意。该门禁验证浏览器画布像素，物理屏幕的峰值亮度仍由系统 EDR 与面板能力决定。
- 面板按预览框与设备像素比在 960 / 1440 / 2048 三档中请求；不具备 WebGPU HDR
  前置条件时最长边不超过 1280 像素，避免纯 JavaScript CPU 回退拖慢滑杆。
- 状态栏与画面角标会明确显示“真 HDR”“SDR 预览”或“原图”，不会再用 `HDR ON` 混淆真实渲染能力。
- “精确 HDR 预览”：调用与正式转换相同的 RAW、高光恢复、色调和增益图管线，生成 Adaptive HDR HEIC。Safari 26+ 可在网页内显示；不支持 HEIC 网页显示的浏览器会保留下载按钮。
- “开始转换”：按所选 Adaptive/Ultra HDR/PQ/HLG 模式生成最终文件。对 iPhone 预览和分享，优先使用“增益图”。

## 安全边界

- 客户端不能提交 Windows 文件路径、输出目录或可执行文件路径。
- 上传和输出限制在随机任务目录中。
- 服务启动时生成临时访问口令；也可以通过脚本的 `-AccessToken` 固定口令。
- 只应在可信的家庭或工作专用网络中开放端口，不要做路由器公网端口映射。

如果需要手动创建 Windows 防火墙规则，请把范围限制为 TCP 8756 和“专用”配置文件；完成后也可删除该规则。

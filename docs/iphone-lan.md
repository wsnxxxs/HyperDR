# 在 iPhone Safari 中使用 HyperDR

HyperDR 现在可以由 Windows 电脑在局域网内提供服务。iPhone 负责选择和上传照片、调节参数、查看预览以及下载结果；RAW 解码和 HEIC 编码仍在电脑上完成。

## 快速启动（HTTP）

1. 确认 iPhone 与电脑连接到同一个可信 Wi-Fi。
2. 双击项目根目录的 `Start.bat`。
3. Windows 防火墙询问时，只允许“专用网络”。
4. 启动窗口会打印一个带临时访问口令的 `iPhone 地址`，例如：

   ```text
   http://192.168.31.87:8756/?token=xxxxxxxx
   ```

5. 在 iPhone Safari 中打开完整地址。首次成功登录后，地址栏中的口令会自动移除。

HTTP 模式可以上传、转换、下载并查看 SDR 示意预览。Safari 的 WebGPU 真 HDR 实时画布需要受信任的 HTTPS；最终 HEIC 仍可下载并在“照片”中以 HDR 查看。

任务文件保存在 `hdr-workspace`，默认 24 小时后在下一次启动时清理。每个文件默认最多 256 MB，每个任务最多 1 GB；可以分别通过 `HYPERDR_MAX_UPLOAD_MB`、`HYPERDR_MAX_SESSION_MB` 和 `HYPERDR_SESSION_HOURS` 调整。

## 配置受信任 HTTPS

建议使用 `mkcert` 创建一个由本地 CA 签发的证书。不要依赖 Safari 的临时证书警告例外，因为 WebGPU 需要真正的安全上下文。

先确认电脑当前的局域网 IPv4 地址，然后在项目外的安全目录生成证书（下面以 `192.168.31.87` 为例）：

```powershell
mkcert -install
mkcert -cert-file hyperdr.pem -key-file hyperdr-key.pem 192.168.31.87 127.0.0.1 localhost
mkcert -CAROOT
```

把 `mkcert -CAROOT` 所在目录中的 `rootCA.pem` 安全地传到 iPhone：

1. 在 iPhone 上安装该描述文件；
2. 打开“设置 → 通用 → 关于本机 → 证书信任设置”；
3. 对这个本地根证书启用完全信任。

然后在项目根目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\start_hyperdr_lan.ps1 `
  -Certificate C:\安全目录\hyperdr.pem `
  -PrivateKey C:\安全目录\hyperdr-key.pem
```

Safari 应使用启动窗口打印的 `https://局域网地址:端口/?token=...`。证书中的 IP 必须与访问地址一致。私钥不要复制到 iPhone，也不要提交到版本库。

## HDR 预览层级

- 滑块拖动：在受信任 HTTPS、HDR 屏幕和 Safari 26+ 环境中使用 WebGPU `rgba16float` 扩展 Display P3 输出；其他环境明确回退到 WebGL2 GPU 加速的 SDR 示意。
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

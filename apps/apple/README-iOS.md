# 在 iPhone / iPad 上安装 HyperDR（免费 Apple ID）

这份说明讲怎样用免费的 Apple ID（Xcode 里叫 Personal Team）把 HyperDR 装到你自己的 iPhone 或 iPad 上。不需要付费的开发者账号。

现在的 iOS 版只是一个最小外壳：从照片图库选一张照片，在全屏画布上以 HDR 显示，可以缩放和平移。编辑功能等界面设计定稿后再加。

## 需要准备

- 一台装有 Xcode 27.1 的 Mac（与 Mac 版开发用的是同一台即可）。
- iPhone 或 iPad，系统为 iOS / iPadOS 26 或更新。
- 一根数据线（第一次安装必须用线连接；之后可以改用无线，见文末）。
- 一个 Apple ID。

## 第一步：在 Xcode 里登录 Apple ID

1. 打开 Xcode，菜单 **Xcode → Settings…（设置）→ Accounts（账户）**。
2. 点左下角 **+**，选 **Apple ID**，登录你的 Apple ID。
3. 登录后，右侧会出现一个团队，名字是“你的名字 (Personal Team)”。

## 第二步：打开工程并选择团队

1. 在 Finder 里打开仓库中的 `apps/apple/HyperDR.xcodeproj`。
2. 窗口顶部中间的方案（scheme）选择器里选 **HyperDRiOS**（不是 HyperDR，那是 Mac 版）。
3. 左侧导航栏点最上面的蓝色工程图标 **HyperDR**，在 TARGETS 列表里选 **HyperDRiOS**。
4. 打开 **Signing & Capabilities（签名与功能）** 标签：
   - 保持 **Automatically manage signing（自动管理签名）** 勾选；
   - **Team（团队）** 选“你的名字 (Personal Team)”。
5. 如果 Xcode 提示 Bundle Identifier（套装 ID）`com.hyperdr.HyperDR` 无法注册或已被占用，把它改成只属于你的名字，例如 `com.你的英文名.HyperDR`，再等 Xcode 重新生成描述文件。

说明：
- 选择团队和修改 Bundle Identifier 会改动 `project.pbxproj`。这是只属于你这台电脑的设置，**不要提交**；以后拉取更新前如有冲突，可以先撤销这处改动，拉取后再选一次团队。
- iOS 目标没有申请任何需要付费账号的功能（capability），所以免费团队可以签名。

## 第三步：连接设备并打开开发者模式

1. 用数据线把 iPhone / iPad 连到 Mac。设备上弹出“要信任此电脑吗？”时点 **信任**，并输入设备密码。
2. 在 Xcode 顶部的运行目标里选你的设备（第一次连接时 Xcode 可能要花几分钟准备设备）。
3. 打开设备上的开发者模式：
   - **设置 → 隐私与安全性 → 开发者模式**，打开开关；
   - 设备会要求重启，重启后再确认一次“打开”，并输入密码。
   - 如果找不到“开发者模式”这一项，先完成上一步（连接 Xcode 并选中设备），它才会出现。

## 第四步：运行

1. 在 Xcode 里按 **⌘R**（或点左上角的 ▶︎ 运行按钮）。
   - 如果编译时提示缺少 Metal 工具链，在终端运行一次：
     `xcodebuild -downloadComponent MetalToolchain`
2. 第一次装好后，App 可能打不开，设备上提示“不受信任的开发者”。这时：
   - **设置 → 通用 → VPN 与设备管理**，在“开发者 App”下点你的 Apple ID，再点 **信任“你的 Apple ID”**。
3. 回到主屏幕打开 **HyperDR**（或在 Xcode 里再按一次 ⌘R）。

## 七天后会失效

免费团队签出的描述文件只有 **7 天** 有效期。到期后 App 会打不开（提示“无法验证”或“不再可用”）。

- 重新签名的方法：把设备连回 Mac，在 Xcode 里选 HyperDRiOS 和你的设备，再按一次 ⌘R。没有删除 App 的话，App 里的数据会保留。
- 免费团队的其他限制：同一台设备上同时最多装 3 个用免费团队签名的 App；每 7 天最多新建 10 个 App ID（频繁改 Bundle Identifier 会用掉名额）。

## 用法

- 没打开照片时，点屏幕中间的 **选择照片**，从照片图库选一张；也可以点下面的 **从文件打开**，从“文件”App（包括 iCloud 云盘和外接硬盘）选。打开照片后，左上角的 **照片** 按钮换一张，右上角 **⋯** 菜单里有 **从文件打开…**。换图时旧照片会留在屏幕上，直到新照片准备好。
- 从照片图库选取时，照片按原始格式读取（HEIC、带增益图的 JPEG、HLG/PQ 的 HEIF 都会以 HDR 显示）。系统的照片选择器在 App 之外运行，所以 HyperDR 不需要、也不会请求访问整个图库的权限。
- 双指捏合缩放，单指或双指拖动平移，双击在“适合屏幕”和“原始像素”之间切换。
- 底部一行显示屏幕的 HDR 余量：“当前”是现在能用的亮度倍数，“最高”是这块屏幕的上限。“当前”大于 1.0× 就说明正在以 HDR 显示。屏幕亮度调得很低或开着低电量模式时，余量会变小，高光会被压暗而不是被截断。
- 这个外壳为了省内存，把照片缩到长边 4096 像素再显示；全分辨率的处理会在新的渲染管线完成后接上。

## 可选：无线运行

第一次用数据线成功运行后，在 Xcode 菜单 **Window → Devices and Simulators（设备与模拟器）** 里选中你的设备，勾选 **Connect via network（通过网络连接）**。之后只要 Mac 和设备在同一个 Wi-Fi 下，就可以不插线运行和重新签名。

## 给开发者：命令行检查

不签名、只验证能否编译（真机和模拟器）：

```sh
cd apps/apple
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme HyperDRiOS \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme HyperDRiOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

`python3 scripts/test.py apple` 也会跑这两项。

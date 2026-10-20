# 在 iPhone / iPad 上安装 HyperDR（免费 Apple ID）

这份说明讲怎样用免费的 Apple ID（Xcode 里叫 Personal Team）把 HyperDR 装到你自己的 iPhone 或 iPad 上。不需要付费的开发者账号。

iOS 版现在能做这些：

- **打开**：从照片图库或“文件”App 选一张照片，RAW、HEIC/HEIF（含 HLG、PQ）、带增益图的 JPEG、普通 JPEG/PNG 都可以，在全屏画布上以 HDR 显示。
- **编辑**：HDR、光线、颜色、风格、细节五组调节（HDR 来源可选照片自带、真实高光、扩展或 AI），撤销/重做，按住看原图，“对比”里可切换原图、调整后和分屏；放大后按原始像素显示细节，拖动带遮罩的调节时会显示它影响的区域。
- **导出**：目的地有“网页”（HDR JPEG，长边 2560）和“社交平台”（HDR JPEG，长边 2160）；“照片”目的地暂时不可选，显示“尚未开放”。也可以改用自定义格式：HDR JPEG（ISO 增益图）、Adaptive HDR（HEIC）、HEIC PQ、HEIC HLG、AVIF PQ、AVIF HLG、JPEG、16 位 TIFF，可选色域、质量和长边（原尺寸或更小）。内存不够时会提示，并给出“改为长边 N px”。导出时显示进度，可以取消；完成后可以 **存储到文件** 或 **分享**。

- **LUT**：从“文件”导入 LUT 到 App 的 LUT 库；编辑里用到的 LUT 不在库中时，导出前会提示。

暂时没有的：导出到照片图库、相框、后台继续导出。

亲测清单在 `docs/design/user-acceptance.md` 的“P7 三平台”一节（`docs/` 不在 Git 里，在你本机的仓库目录中）。

## 需要准备

- 一台装有 Xcode 27.1 的 Mac（与 Mac 版开发用的是同一台即可）。
- iPhone 或 iPad，系统为 iOS / iPadOS 26 或更新。
- 一根数据线（第一次安装必须用线连接；之后可以改用无线，见文末）。
- 一个 Apple ID。

## 第零步：先构建引擎（含 iOS 部分）

iOS 版要链接 HyperDR 的引擎（导出要用）。在仓库根目录先运行一次：

```sh
bash scripts/build_xcframework.sh --platforms all
```

它会把 Mac、iPhone 真机和模拟器三份引擎都构建好（第一次要等一会儿），需要 `DEVELOPER_DIR` 指向 Xcode（见 AGENTS.md）。以后引擎代码有更新时再运行一次。`python3 scripts/test.py ios` 发现引擎缺失或过期时会自动重新构建，运行过它就不用再单独构建。

## 第一步：在 Xcode 里登录 Apple ID

1. 打开 Xcode，菜单 **Xcode → Settings…（设置）→ Accounts（账户）**。
2. 点左下角 **+**，选 **Apple ID**，登录你的 Apple ID。
3. 登录后，右侧会出现一个团队，名字是“你的名字 (Personal Team)”。

## 第二步：打开工程并选择团队

1. 在 Finder 里打开仓库中的 `apps/apple/HyperDR.xcodeproj`。
2. 窗口顶部中间的方案（scheme）选择器里选 **HyperDRiOS-Release**（日常使用和性能测试用的优化版本；不是 HyperDR，那是 Mac 版）。
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

## 性能测试要用 Release

`HyperDRiOS-Release` 的运行配置为 Release，并且不附加调试器。编解码参数、
浮点精度、内存保护和导出校验与 Debug 相同；Swift 的行回调、校验、缩略图等
密集循环会经过优化编译。`HyperDRiOS` 仍保留 Debug 配置，供断点和界面调试。
不要用 Debug 的导出秒数判断正式版本性能。

原尺寸 RAW / HIF 的真机结果、质量对照和当前优化说明集中在
[导出内存与性能记录](Packages/HyperDRRender/EXPORT_MEMORY.md)，历史 Mac 实验单独归档。

命令行构建正式使用的真机包（沿用已设置的个人团队签名）：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project apps/apple/HyperDR.xcodeproj -scheme HyperDRiOS-Release \
  -configuration Release -destination 'generic/platform=iOS' build
```

## 七天后会失效

免费团队签出的描述文件只有 **7 天** 有效期。到期后 App 会打不开（提示“无法验证”或“不再可用”）。

- 重新签名的方法：把设备连回 Mac，在 Xcode 里选 HyperDRiOS 和你的设备，再按一次 ⌘R。没有删除 App 的话，App 里的数据会保留。
- 免费团队的其他限制：同一台设备上同时最多装 3 个用免费团队签名的 App；每 7 天最多新建 10 个 App ID（频繁改 Bundle Identifier 会用掉名额）。

## 用法

- 没打开照片时，点屏幕中间的 **选择照片**，从照片图库选一张；也可以点下面的 **从文件打开**，从“文件”App（包括 iCloud 云盘和外接硬盘）选。打开照片后，左上角的 **照片** 按钮换一张，右上角 **⋯** 菜单里有 **从文件打开…**。换图时旧照片会留在屏幕上，直到新照片准备好。
- 从照片图库选取时，照片按原始格式读取（HEIC、带增益图的 JPEG、HLG/PQ 的 HEIF 都会以 HDR 显示）。系统的照片选择器在 App 之外运行，所以 HyperDR 不需要、也不会请求访问整个图库的权限。
- 双指捏合缩放，单指或双指拖动平移，双击在“适合屏幕”和“原始像素”之间切换。
- 调节在屏幕下方；iPhone 横屏和足够宽的 iPad 窗口（如横屏全屏）里在侧边；右上角有撤销、重做、**⋯** 菜单（含“重置所有调整”）和 **导出**。照片还在打开时，导出按钮是灰的；导出进行中不能换照片。
- 底部一行显示屏幕的 HDR 余量：“当前”是现在能用的亮度倍数，“最高”是这块屏幕的上限。“当前”大于 1.0× 就说明正在以 HDR 显示。屏幕亮度调得很低或开着低电量模式时，余量会变小，高光会被压暗而不是被截断。
- 导出“网页”完成后会自动弹出系统的存储面板；在面板里点取消只是不存，导出的文件还在，可以再点 **存储到文件…** 或 **分享…**。

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

`python3 scripts/test.py ios` 会跑这两项（需要 Xcode 装有 iOS 平台；`apple` 套件只测 Mac）。

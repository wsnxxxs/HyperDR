# 在 iPhone / iPad 上安装 HyperDR（免费 Apple ID）

这份说明讲怎样用免费的 Apple ID（Xcode 里叫 Personal Team）把 HyperDR 装到你自己的 iPhone 或 iPad 上。不需要付费的开发者账号。

iOS 版现在能做这些：

- **打开**：从照片图库或“文件”App 选一张照片，RAW、HEIC/HEIF（含 HLG、PQ）、带增益图的 JPEG、普通 JPEG/PNG 都可以，在全屏画布上以 HDR 显示。
- **iPad 工作室（Studio）**：iPad 上（分屏或台前调度把窗口缩到手机宽度时除外）是专门的大屏界面：照片在黑色画布上，右侧（竖屏时在底部）一块玻璃面板放全部工具——HDR、光线、颜色、风格、细节、裁切、边框，顶部常驻直方图（比 SDR 白更亮的部分用琥珀色），底部是照片的相机与曝光信息；每个调节是一整行的填充条，左右拖动调节、上下离开微调、双击复位、点数值输入、长按看说明。画面下方的胶囊条可切换调整后 / 分屏 / 原图、在“适合”和 100% 之间缩放，并显示屏幕此刻的 HDR 余量。再点一次当前工具（或 ⌥⌘I）可以把面板收成一条，让照片更大。外接键盘：⌘1…⌘7 切换工具，⌥⌘1/2/3 切换对比，⌘0 缩放，⌘E 导出。
- **编辑**：HDR、光线、颜色、风格、细节五组调节（细节只对 RAW 显示），iPhone 和窄 iPad 窗口的底部栏里光线和颜色合在一个标签（HDR 来源可选照片自带、真实高光、扩展或 AI），撤销/重做，按住看原图，**⋯** 菜单的“对比”里可切换原图、调整后和分屏；放大后按原始像素显示细节，拖动带遮罩的调节时会显示它影响的区域。
- **导出**：上面一排是用途：“网页”（HDR JPEG，长边 2560）、“社交平台”（HDR JPEG，长边 2160）和“照片”（Adaptive HDR，作为一张新照片存入“照片”，第一次会请求添加照片的权限）。下面一排是格式：JPEG、HEIC、AVIF、TIFF，“编码”里再选增益图 HDR、Adaptive HDR、PQ、HLG 或 SDR。下方只列出当前选择用得到的设置（编码、色域、尺寸、质量、边框）；在用途上改任何一项，会从这个用途的设置开始变成自定义格式。按钮上方一行写明将写出的格式、像素、色域和峰值。下次打开会停在上次的选择。内存不够时会提示，并给出“改为长边 N px”。导出时显示进度，可以取消；完成后可以 **存储到“照片”**、**存储到文件** 或 **分享**，文件名沿用原照片的名字（如 `IMG_8681.heic`）。
- **边框**：编辑器的“边框”标签里选样式（画廊、展签、竖幅、拍立得、细边）、纸色和标题内容（参数、相机、日期、签名），导出时可以带上。没有 EXIF 的照片也保留样式原本的底边，只是标题处空着。

- **设置**：iPhone 上是图库右上角的齿轮，iPad 上在图库右侧一栏（竖屏时在底部一条）。里面有 RAW 开发器选择（Automatic / RAW 8 / RAW 9）、LUT 库、导出记录占用的空间和清除、版本、第三方许可和隐私说明；以后的订阅也放在这里。
- **导出记录**：iPhone 上是图库底部的“导出记录”按钮（导出过一次之后出现），iPad 上图库右侧一栏直接列出最近导出的版本，点一个就打开它；它们都打开导出历史（最近导出的 20 个版本，按日期分组）。点开一个版本可以看到导出的文件本身（HDR 显示）、格式与尺寸、当时的调整，并可再次存储到文件、分享或删除。
- **LUT**：从“文件”导入 LUT 到 App 的 LUT 库；编辑里用到的 LUT 不在库中时，导出前会提示。

**系统要求**：App 需要 iOS/iPadOS 27 或更新。RAW 开发器的支持情况取决于系统和照片/相机。

**RAW 开发器**：设置提供 **Automatic（自动） / RAW 8 / RAW 9**，只对之后新打开的照片生效，不重新打开当前照片，也不改写已保存编辑中的解码器版本。

Automatic 优先选择系统和照片支持的 RAW 9，再选 RAW 8（DNG 保留 `9.dng` / `8.dng` 的确切版本）；两者都不支持时，使用受支持的较旧系统默认版本。新照片选用 RAW 9 后若无法解码，只再尝试 RAW 8 一次；RAW 8 不可用时才尝试受支持的较旧系统默认版本。取消、内存分配失败及系统明确报告的 GPU/CI 错误不触发这次回退。

强制选择 RAW 8 或 RAW 9 时，所选版本不受支持就直接报错，不会自动换版本。已保存的编辑始终使用记录的确切版本；没有记录版本的旧编辑保留系统默认语义。

**诊断信息**：设置里的“导出诊断信息”会生成一个 zip，包含最近几次启动的 App 日志、系统（MetricKit）保留的崩溃与卡顿报告，以及设备型号、系统和内存信息，不含照片和文件名。测试中遇到问题时，把它连同操作步骤一起发给开发者。

暂时没有的：后台继续导出。

亲测清单在 `docs/design/user-acceptance.md` 的“P7 三平台”一节（`docs/` 不在 Git 里，在你本机的仓库目录中）。

## 需要准备

- 一台装有 Xcode 27.1 的 Mac（与 Mac 版开发用的是同一台即可）。
- iPhone 或 iPad，系统为 iOS / iPadOS 27 或更新。
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

- 打开 App 就是系统的照片图库（**照片 | 精选集** 由系统提供：iPhone 上在顶部中间，iPad 上在左侧边栏顶部；相簿和实况、人像、全景等媒体类型都在 **精选集** 里），点一张照片就进入编辑；底部的 **从文件打开** 从“文件”App（包括 iCloud 云盘和外接硬盘）选。编辑时左上角的 **×** 关闭照片回到图库（未导出的调整不会保留），右上角 **⋯** 菜单里也有 **从文件打开…**。iPad 上也可以把照片从“照片”或“文件”拖进来，图库右侧一栏（竖屏时是底部一条）里有 **从文件打开**、拖放提示、最近导出、LUT 库和设置。
- 从照片图库选取时，照片按原始格式读取（HEIC、带增益图的 JPEG、HLG/PQ 的 HEIF 都会以 HDR 显示）。系统的照片选择器在 App 之外运行，所以 HyperDR 不需要、也不会请求访问整个图库的权限。
- 双指捏合缩放，单指或双指拖动平移，双击在“适合屏幕”和“原始像素”之间切换。
- 调节在屏幕下方，iPhone 横屏时在侧边；iPad 上是 Studio 面板（见上文），导出在 iPad 上是一个横向的大面板，左边是带边框的 HDR 实时预览；顶部和“照片”App 的编辑界面一样：左上角是关闭、撤销和重做，右上角是 **⋯** 菜单（含“对比”和“重置所有调整”）和 **导出**。照片右上角的 **HDR** 标识表示正在显示 HDR 效果。照片还在打开时，画面中央（换照片时是顶部）会说明正在获取、读取照片还是生成预览，调节和导出按钮是灰的；导出进行中不能换照片。
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

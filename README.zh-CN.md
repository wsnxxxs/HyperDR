<p align="center">
  <img src=".github/readme/icon.svg" width="104" alt="HyperDR 图标">
</p>

<h1 align="center">HyperDR</h1>

<p align="center">
  从拍下到导出，全程 HDR 的照片编辑。iPhone · iPad · Mac<br>
  <a href="README.md">English</a> · 简体中文 · <a href="https://github.com/wsnxxxs/HyperDR/releases">下载 Mac 版</a> · <a href="CHANGELOG.md">更新内容</a>
</p>

<p align="center">
  <img src=".github/readme/mac-zh.png" width="100%" alt="HyperDR 的 Mac 桌面版：左侧是 EDR 画布上的照片，右侧检查器里是直方图、HDR、调整与风格">
</p>

## 这是什么

HyperDR 是一款原生的 Apple 平台照片编辑器，专门为 HDR 照片而做。现在的 iPhone 和相机拍下的照片里，本来就保存着比白色更亮的高光，Mac、iPhone 和 iPad 的屏幕也能把它们真正点亮。可多数修图软件一动滑块，就把照片压回了普通的 SDR，那部分光也就丢了。HyperDR 从读取相机文件开始，到写出成片为止，始终保留这部分高光，并且在你编辑时按屏幕真实的亮度余量把它显示出来。

上面是 Mac 桌面版。左边是照片，画布是一个 Metal EDR 图层，高光在屏幕上能亮到多少就显示多少；右边的检查器最上面是直方图和波形，下面依次是 HDR、光线与色彩、风格等调整。你可以随时按住画布查看原图，或者切换成分屏对照编辑前后的差别。Mac 版是 SwiftUI 写的原生应用，运行在 Apple 芯片上；iPhone 和 iPad 版用的是同一套编辑核心和渲染管线，只是界面按触控重新设计。

## 用 CNN 为普通照片补回 HDR

很多照片本身没有 HDR 信息，比如一张普通的 JPEG、一张从网上存下来的图，或者早年拍的老照片。HyperDR 内置了一个我们自己训练的卷积神经网络，专门做一件事：看一张 SDR 照片，推断出它的高光原本应该亮多少。网络的训练数据是 Apple 设备自己渲染的 HDR 照片和它们的增益图，所以它学到的是 Apple 那种克制、自然的提亮方式，而不是把整张图一起拉亮。

这个模型很小，大约 63.5 万个参数，通过 Core ML 在设备上运行，照片不会离开你的设备。它把照片缩到长边 1024 像素来分析，在每 16×16 像素的网格上输出一个以“档”为单位的增益值，再平滑、放大到原图尺寸。模型给出的结果不是最终答案，而是一个起点：你可以在 HDR 里选择“+ AI”作为高光来源，然后用强度、范围和起始亮度去调它；如果照片本身已经有相机记录的高光，也可以让 AI 只补充文件里缺少的那部分。

AI 只影响 HDR 的那一层，下面那张 SDR 画面保持不动。所以在普通屏幕上看，照片还是你调好的样子；在 HDR 屏幕上，高光才会按模型的判断亮起来。无论你之后换了什么风格或 LUT，AI 的推断都基于同一份显影，不会因为风格变化而跑偏。

## 认得色彩空间的 LUT

HyperDR 有一个自己的 LUT 库，可以导入常见的 `.cube` 文件。和很多软件不同，库里每个 LUT 都会记住它的输入和输出色彩空间，导入时还会从文件名里认出常见的空间名称。一个 LUT 如果需要照片提供它给不了的输入，就会被禁用，而不是假装它是 sRGB 硬套上去，那样颜色一定是错的。

相机 Log 曲线是这里最用心的部分。S-Log3、V-Log、F-Log2、LogC3、LogC4、Canon Log 3 这类 LUT 是为摄像机素材写的，HyperDR 会把 RAW 照片按场景线性重新显影，保留文件自己的基准曝光，关闭色域压缩，再送进 LUT。这样 18% 中灰正好落在曲线预期的位置，宽色域里的颜色也能完整地传给 LUT，效果和在调色软件里套用视频素材是一致的。

挑选 LUT 时，每个选项都直接用你这张照片渲染出小样，所见即所得。LUT 和内置的胶片模拟是二选一的风格，强度在线性光里混合；风格只改变颜色和 SDR 画面，HDR 高光会保留下来。内置胶片包括 Kodak Portra 400、Gold 200、Kodachrome 64、Vision3 500T 和 Fujifilm Velvia 100，颗粒与光晕是按物理过程计算出来的，而且对没有套用风格的照片也同样可以单独使用。

## 用来展示作品的边框

照片修好之后，常常还要发出去、印出来，或者放进作品集。HyperDR 可以直接在导出时给照片加上展示边框，有 Gallery、Label、Story、Hairline 和 Instant 五种样式，每种都可以选五种纸张色调，还可以加上阴影，以及从照片自己的 EXIF 读出的说明文字，比如机身、镜头、光圈和快门。

边框有一个很少有人注意的细节：在 HDR 照片里，边框的纸张是用严格为零的增益写进去的。也就是说，在 HDR 屏幕上只有照片本身会亮起来，白色的卡纸始终是安静的纸白，不会跟着发光刺眼。在 Mac 上，从“文件”菜单打开边框面板，就能在一块实时的 EDR 画布上预览带框的效果，导出的文件和你看到的一致。

## 其他值得一提的地方

预览和导出走的是同一张 GPU 渲染图，由 Core Image 加上我们自己的 Metal 内核组成，在扩展范围的线性 Display P3 下计算，没有另一套导出引擎去重新解读你的编辑。每个文件写完都会读回来校验，通过之后才交给“文件”、“照片”或分享面板。

导出的首选是自适应 HDR：同一个文件里放着一张调好的 SDR 画面和一张 ISO 21496-1 增益图，普通屏幕显示 SDR，HDR 屏幕把高光点亮到它能达到的程度。除此之外也可以写出带增益图的 JPEG、PQ 或 HLG 的 HEIC 与 AVIF，以及普通的 JPEG、HEIC 和 TIFF。你只要选择用途，比如网页、社交平台或照片，格式、尺寸和质量都会自动定好。

RAW 文件由 Apple 的 CIRAWFilter 显影，所用的解码器版本会和编辑一起保存，下次打开、换一台设备或者系统升级之后，照片都会用同一个解码器显影，结果不会悄悄改变。它可以打开 DNG、ARW、CR3、NEF、RAF 等主流 RAW，以及 HEIC、HIF、AVIF、JPEG、PNG 和 TIFF。大文件也能应付，61MP 的 RAW 和 60MP 的 HIF 已经可以在 iPhone 17 Pro 上打开、按 1:1 平移并全尺寸导出。

HyperDR 没有自己的照片库，只读取你在系统选择器里挑出的照片，所有处理都在设备上完成。HEIF 的读写是我们自己的容器代码，HEVC 编码交给 VideoToolbox，应用里不嵌入任何动态库，也不含 (L)GPL 代码。

## 获取与构建

Mac 版可以在 [Releases](https://github.com/wsnxxxs/HyperDR/releases) 下载，解压后把 HyperDR.app 拖进“应用程序”。这个版本是临时签名、没有经过公证的，如果 macOS 拦下了第一次启动，到“系统设置”的“隐私与安全性”里选择“仍要打开”即可。iPhone 和 iPad 版目前需要用 Xcode 自行构建，步骤见[安装说明](apps/apple/README-iOS.md)。所有版本都需要 iOS、iPadOS 27 或 macOS 27，Mac 需要 Apple 芯片。

HyperDR 0.5.1 还是预发布版本。iPhone 上 110MP RAW 的全尺寸编辑还在验证，iOS 也暂时不能在后台继续导出。

想参与开发的话，构建需要装有 Xcode 的 macOS、CMake、Ninja、vcpkg 和 Python 3.12。应用分为几层：SwiftUI 界面在 `apps/apple`，配方与 GPU 渲染在 `HyperDRRecipe` 和 `HyperDRRender` 两个包里，服务层是 `HyperDRKit`，底层的 C++ 引擎在 `modules/`，负责写入器、HEIF 读取、VideoToolbox 编解码和导出校验，Swift 只通过 C ABI 调用它。AI 模型的训练代码在 `HyperDR_Model`。常用的测试命令如下：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3.12 scripts/fetch_test_fixtures.py
python3.12 scripts/test.py native --build-dir build   # C++ 引擎
python3.12 scripts/test.py apple                      # Swift 包、Mac 应用与本地化检查
python3.12 scripts/test.py ios                        # iPhone 与 iPad 的无签名构建
```

## 许可

HyperDR 采用 [GNU AGPL v3.0](LICENSE) 与商业许可双重授权，详见 [LICENSING.md](LICENSING.md)。HyperDR 的名称和应用图标不在这两种许可的范围内。第三方组件各自保留原有许可，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

<p align="center">
  <sub>Copyright © 2026 Renhe Wang</sub>
</p>

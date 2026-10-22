<p align="center">
  <img src=".github/readme/icon.svg" width="104" alt="HyperDR 图标">
</p>

<h1 align="center">HyperDR</h1>

<p align="center">
  <b>从拍下到导出，全程 HDR 的照片编辑。</b><br>
  iPhone · iPad · Mac
</p>

<p align="center">
  <a href="README.md">English</a>&nbsp;&nbsp;·&nbsp;&nbsp;简体中文
</p>

<p align="center">
  <a href="https://github.com/wsnxxxs/HyperDR/releases">下载 Mac 版</a>&nbsp;&nbsp;·&nbsp;&nbsp;<a href="apps/apple/README-iOS.md">在 iPhone 与 iPad 上构建</a>&nbsp;&nbsp;·&nbsp;&nbsp;<a href="CHANGELOG.md">更新内容</a>
</p>

<br>

<p align="center">
  <img src=".github/readme/ipad-zh.png" width="100%" alt="在 iPad 上用 HyperDR 编辑一张 RAW 夜景，右侧为 HDR 调整面板">
</p>

<br>

多数修图软件一动滑块，就把 HDR 照片压回了 SDR。HyperDR 从相机文件到导出成片，
始终保留比白更亮的那部分光，并在编辑时按屏幕真实的亮度余量显示出来。

<br>

## 为什么是 HyperDR

### HDR 是主角，而不是附加项

画布是 Metal EDR 图层，高光在屏幕上能亮到多少，就显示多少。HDR 有自己的来源和独立的调整：

- **真实高光** —— 相机实际记录下来的高光，来自 RAW、HIF、HEIC 或带增益图的文件。
- **+ 扩展** —— 把已有的高光延展到更大的亮度余量。
- **+ AI** —— 设备端 Core ML 模型，预测文件里从未保存过的高光。

标注“只影响 HDR”的调整只塑造高光，不改动下面的 SDR 画面，两个版本都恰到好处。

### 你确认的画面，就是写入的画面

<p align="center">
  <img src=".github/readme/pipeline-zh.svg" width="100%" alt="管线：输入经解码后，由配方驱动同一张 GPU 渲染图，同时供给预览与导出">
</p>

预览与导出走同一张 GPU 渲染图 —— Core Image 加上我们自己的 Metal 内核，
在线性 Display P3、扩展范围下计算。没有另一套“导出引擎”重新解读你的编辑。
每个文件写完都会读回校验，通过后才交给“文件”、“照片”或分享面板。

### 在任何屏幕上都正确的导出

<p align="center">
  <img src=".github/readme/gainmap-zh.svg" width="100%" alt="SDR 底图加增益图，合成自适应 HDR 照片">
</p>

自适应 HDR 同时保存一张调好的 SDR 画面和一张增益图（ISO 21496-1）。
普通屏幕显示你调好的 SDR；HDR 屏幕则把高光点亮到它能达到的程度。
不靠猜测，也不会退化成发灰的画面。

| 输出 | 编码 |
|---|---|
| **自适应 HDR HEIC** | SDR 底图 + ISO 21496-1 增益图，HEVC |
| **增益图 JPEG** | SDR 底图 + ISO 21496-1 增益图 |
| **HDR HEIC · AVIF** | PQ 或 HLG，10 位 |
| **SDR** | JPEG · HEIC · TIFF |

选择用途 —— 网页、社交平台或照片 —— HyperDR 会定好格式、尺寸与质量；
改动任一设置，即成为你自己的格式。

### 来自实测数据的胶片，认得色彩空间的 LUT

- **胶片** —— Kodak Portra 400、Gold 200、Kodachrome 64、Vision3 500T 与 Fujifilm Velvia 100，按实测数据模拟曝光、显影，负片还会印放到相纸上。颗粒、光晕与防光晕层都是建模计算，而非叠加贴图。
- **LUT** —— 每个 LUT 都记住自己的输入与输出空间。相机 Log 曲线（S-Log3、V-Log、F-Log2、LogC3、LogC4、Canon Log 3）由场景线性的 RAW 显影供给，中灰正好落在 LUT 预期的位置。
- **强度** 在线性光中混合；风格改变的是 SDR 底图，HDR 高光保持不变。

### 为展示而生的边框

<p align="center">
  <img src=".github/readme/iphone-zh.png" width="100%" alt="iPhone 上的 HyperDR：HDR 调整、带 EXIF 说明的画廊边框，以及导出面板">
</p>

画廊、展签、竖幅、细边与拍立得五种卡纸样式，五种纸色，可选用照片自身 EXIF 生成的说明文字。
卡纸以严格为零的增益写入，在 HDR 屏幕上发光的只有照片，卡纸永远不会。

### 编辑不会悄悄变样

RAW 由 Apple 的 `CIRAWFilter` 显影，所用解码器的确切版本随编辑一起保存。
无论换一台设备，还是系统升级后再打开，都用同一个解码器显影，不会换成更新或更旧的版本。
若该解码器不可用，HyperDR 会明确告诉你，而不是悄悄换成另一种样子。

### 隐私、原生、自成一体

- 照片只在设备上处理。HyperDR 只读取你在系统照片选择器中选中的照片，也没有自己的图库。
- 每个平台都是原生 SwiftUI，iOS 与 iPadOS 采用 Liquid Glass，不使用 Catalyst。
- HEIF 由 HyperDR 自己的容器代码读写，HEVC 交给 VideoToolbox。App 不嵌入任何动态库，也不含 (L)GPL 代码。
- 为大文件而建：在 iPhone 17 Pro 上，6100 万像素 RAW 与 6000 万像素 HIF 可以打开、1:1 平移并全尺寸导出。

<br>

## 格式

|  | |
|---|---|
| **打开** | Apple 解码器支持的相机 RAW（DNG、ARW、CR3、NEF、RAF、ORF、RW2 …）· HEIC / HEIF / HIF · AVIF · JPEG（含增益图 JPEG）· PNG · TIFF |
| **写出** | 自适应 HDR HEIC · 增益图 JPEG · PQ / HLG 的 HEIC 与 AVIF · SDR 的 JPEG、HEIC 与 TIFF |
| **存到** | “文件” · “照片”（存为新照片）· 分享面板 |

## 获取 HyperDR

**Mac** —— 从 [Releases](https://github.com/wsnxxxs/HyperDR/releases) 下载最新版本，
解压后将 `HyperDR.app` 拖入“应用程序”。此版本为临时签名、未经公证；
首次打开被阻止时，请在“系统设置 → 隐私与安全性”中选择“仍要打开”。

**iPhone 与 iPad** —— 用 Xcode 从源码构建，见[安装说明](apps/apple/README-iOS.md)。

需要 iOS / iPadOS 27，或 Apple 芯片上的 macOS 27。

> HyperDR 0.5.0 为测试版。iPhone 上 1.1 亿像素 RAW 的全尺寸处理仍在验证中，
> iOS 暂不支持在后台继续导出。

<br>

## 开发者

<details>
<summary><b>架构</b></summary>
<br>

| 层 | 位置 | 职责 |
|---|---|---|
| App | `apps/apple/HyperDR`、`apps/apple/HyperDRiOS` | Mac 与 iPhone / iPad 的 SwiftUI 界面 |
| 共享编辑器 | `apps/apple/Shared` | `RecipeEditor`、EDR 画布、导出快照、边框 |
| 配方与渲染 | `Packages/HyperDRRecipe`、`Packages/HyperDRRender` | 以数据表示的编辑；GPU 渲染图（Core Image + Metal、Core ML） |
| 服务 | `Packages/HyperDRKit` | 输入格式、会话、导出规划与 `RecipeExportService` |
| 引擎 | `modules/` | C++ 写入器、HEIF / 图像读取器、VideoToolbox 编解码、有界校验 —— 只通过 `modules/capi/include/hyperdr/hyperdr.h` 的 C ABI 访问 |

核心包不依赖 AppKit 或 UIKit。Swift 直接调用 C ABI，不使用 C++ 互操作。

</details>

<details>
<summary><b>构建与测试</b></summary>
<br>

需要装有 Xcode（含 iOS 与 Metal 工具链）的 macOS，以及 CMake、Ninja、vcpkg 和
Python 3.12。依赖版本由 `vcpkg.json` 固定；每个构建目录使用各自的 vcpkg 安装根目录。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export TMPDIR="$(mktemp -d /tmp/hyperdr-build.XXXXXX)"
python3.12 scripts/fetch_test_fixtures.py
cmake --preset macos-arm64-codecs -B build -DPython3_EXECUTABLE="$(command -v python3.12)"
python3.12 scripts/test.py native --build-dir build   # 引擎
python3.12 scripts/test.py apple                      # xcframework、Swift 包、Mac App、本地化
python3.12 scripts/test.py ios                        # 未签名的 iPhone / iPad 真机与模拟器构建
```

`bash scripts/build_xcframework.sh --platforms all` 构建全部三个 arm64 切片，
并检查每个归档中是否含有 (L)GPL 符号。本地质量门禁见
[tests/quality](tests/quality/README.md)；解析器模糊测试位于 `tests/fuzz`，按需启用。

</details>

<br>

## 许可

HyperDR 采用双重许可：[GNU AGPL v3.0](LICENSE) 或商业许可，详见
[LICENSING.md](LICENSING.md)。HyperDR 名称与 App 图标不在任一许可范围内。
第三方组件保留各自的许可：[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

<br>

<p align="center">
  <sub>Copyright © 2026 Renhe Wang</sub>
</p>

# RAW 显影与 Lightroom DCP 兼容方案

日期：2026-09-21。代码基线：`76c26f2`。

本文件是实现方案与实片调查记录，DCP 功能尚未实现。写入前已等待任务“分析 libultrahdr 增益图算法”完成，方案采用其最终 SDR/HDR 双输入接口。照片和 Adobe 配置文件仅在本机读取，不进入提交。

## 结论

建议保留 LibRaw 解码，增加外部 DCP 色彩配置和基础显影阶段，以选定配置产生的 SDR 作为 HyperDR 的默认观感基准，再生成 HDR。目标先覆盖 Sony ILCE-7RM5 的 Adobe Standard 和 Camera ST。

当前差异包括相机颜色映射、曝光基准和基础色调。只支持 DCP 矩阵无法覆盖这两个实际配置；只提高饱和度也不能解决本次样片的主要明度差异。正确解释 DCP 可以消除一批明确的管线差异，但接近 Lightroom 的程度仍须通过实现后的实片验证确定。

## 1. 实际文件与测量

### 参考照片

`raw处理管线相关图片/` 中有：

- `DSC01925.ARW`：Make=`SONY`，Model=`ILCE-7RM5`，机身固件 v4.00。
- `DSC01925Adobe-Standard.tif`：Adobe Standard。
- `DSC01925_Camera-ST.tif`：Camera ST。

两份 TIFF 都是 9504×6336、RGB 16 bit、无压缩、内嵌 ProPhoto RGB ICC。XMP 记录 Lightroom Classic 15.4.1、Camera Raw Version 18.4、ProcessVersion 15.4；白平衡均为 As Shot，界面温度 5100、Tint +16。曝光、对比度、高光、阴影、白色、黑色、饱和度、自然饱和度、清晰度等均为零，用户点曲线为 Linear。HDREditMode=0，无裁剪，锐化为零，彩色降噪仍为 25。

因此它们是很有价值的 SDR 基础显影参考。XMP 的用户曲线 Linear 不表示配置文件曲线和 Adobe 默认渲染也是恒等变换。5100/+16 是 Lightroom 的界面表示，不能直接当成 LibRaw 白平衡增益。

### 本机配置文件

实际读取位置：

```text
C:/Program Files/Adobe/Adobe Lightroom Classic/Resources/CameraProfiles/
  Adobe Standard/Sony ILCE-7RM5 Adobe Standard.dcp
  Camera/Sony ILCE-7RM5/Sony ILCE-7RM5 Camera ST.dcp
```

读取二进制 IFD 得到以下内容，表维度按 Hue × Saturation × Value 表示：

| 字段 | Adobe Standard | Camera ST |
| --- | --- | --- |
| UniqueCameraModel | Sony ILCE-7RM5 | Sony ILCE-7RM5 |
| CalibrationIlluminant1/2 | 17 / 21，即 A / D65 | 相同 |
| ColorMatrix1/2 | 两组，均存在 | 与 Adobe Standard 相同 |
| ForwardMatrix1/2 | 两组，均存在 | 存在，与 Adobe Standard 不同；本文件两组彼此相同 |
| ProfileHueSatMap | 两张 90×30×1 | 无 |
| ProfileLookTable | 36×8×16 | 90×16×16 |
| ProfileLookTableEncoding | 缺省，linear | 1，sRGB 编码的 V |
| ProfileToneCurve | 无显式曲线 | 128 对 x/y 点 |
| BaselineExposureOffset | 缺省，0 EV | −0.35 EV |
| DefaultBlackRender | 缺省，Auto | 1，None |

两个文件均使用 `II 52 43` 开头的独立相机配置头，即小端标识值 `0x4352`；不能只接受普通 TIFF 的 magic 42。色彩转换也不能因 ColorMatrix 相同就把两个配置视为相同。

配置文件 SHA-256：

```text
Adobe Standard: 91455edee12a62710aeb57a6363f7507df13a793978fe98003593308a922015b
Camera ST:     e6b8c47fe5221a64a62516ab8215f49c9edf8faf6380679af65a30cc212704c9
```

这里的 SHA-256 用于文件身份与缓存；它不是 TIFF XMP 中的 Adobe CameraProfileDigest，不能直接比较二者。

### 本次样片的差异

用项目 Release 可执行文件生成 1440×960 的默认 RAW 预览，取 HPF 第一平面，即 SDR 基底。读取两份 TIFF 原始 16 位数据，按内嵌 ICC 的 TRC 和矩阵转换到 XYZ D50；HyperDR 的线性 P3 数据经过 Bradford 适应到相同白点。

天空区域为归一化坐标 x=[0.20,0.75)、y=[0.08,0.26)。TIFF 每 8 像素采样，预览使用该区域全体像素。结果如下：

| 来源 | 区域亮度 Y 中位数 | 代表色 L* | 代表色 C*ab |
| --- | ---: | ---: | ---: |
| Lightroom Adobe Standard | 0.15943 | 46.90 | 24.58 |
| Lightroom Camera ST | 0.14781 | 45.33 | 28.83 |
| HyperDR 默认 SDR 预览 | 0.23657 | 55.74 | 25.65 |

代表色由区域 XYZ 各分量中位数转换得到。HyperDR 该区域比 Adobe Standard 亮约 48%，相当于亮度比约 +0.57 EV；比 Camera ST 亮约 60%。这是输出区域的亮度比，不是测得的 RAW 曝光补偿，也不是应写死的校正常数。

HyperDR 的 C*ab 并未低于 Adobe Standard，所以至少对这片天空，浅淡观感不能仅解释为缺少饱和度。Camera ST 的色度更高，两个 Lightroom 配置本来就有不同外观。这不是全图 Delta E 验收，也不能由一张天空照片推断肤色表现。

本机证据保存在 `output/dcp-analysis/`：两张经过 ICC 转换的 sRGB 浏览预览、`HyperDR-default.png`、`sky-comparison.json` 以及 HPF。浏览 PNG 仅用于观察，定量数据来自原 TIFF 16 位数据和 HPF 浮点数据。其他任务完成后，用最新可执行文件重跑 `hyperdr-final.hpf`，其 SDR 平面与前一次逐值相同，最大绝对差为 0。

复现预览：

```powershell
./build-release/Release/HyperDR.exe preview-frame raw处理管线相关图片/DSC01925.ARW --output output/dcp-analysis/hyperdr-final.hpf --preview-max-edge 1440 --fast-preview
```

最终检查可执行文件 SHA-256：`bbd623ae2178e80553e52f9cc79d5edc589d3b80e531cb2408d562dfc712e12d`。

## 2. 现有代码可以复用什么

| 位置 | 已有行为 | DCP 接入所需变化 |
| --- | --- | --- |
| `modules/codec/src/raw_decoder.cpp` | LibRaw 黑电平、白平衡、解马赛克、高光处理，取得 camera RGB | 在当前矩阵转换位置选择 DCP；保留实际应用的 WB 和曝光归一化信息 |
| `modules/image/src/dng_color.cpp` | 双光源、倒色温插值、ForwardMatrix、白点求解 | 将白点、插值权重和 XYZ D50 结果作为可复用的求解结果，避免查表另算一套色温 |
| `modules/codec/src/raw_decoder.cpp` 的 `dng_camera_matrix()` | 仅特定嵌入式 DNG 路径使用上述数学 | 独立 ARW+DCP 也能使用，不能继续受 `dng_version != 0` 的分支限制 |
| `modules/look/src/photographic.cpp` | 按场景统计与 EXIF 自动定曝光 | 选 DCP 默认显影时改用配置的曝光基准；自动曝光成为明确的额外操作 |
| `modules/look/src/rendition.cpp` | HyperDR 曲线、chroma、SDR/HDR 生成 | 接受配置显影所得的 SDR，避免再次执行默认 photographic 曲线 |
| `modules/app/src/batch.cpp` 的 `render_native_model_base()` | AI 模型有自己的基础显影入口 | 与普通预览、导出共用同一 DCP 基底 |
| `modules/app/src/decode_cache.cpp`、`fingerprint.cpp` | 解码选项与外部校准资源进入缓存身份 | 添加实际解析到的 DCP 路径及内容 hash，覆盖自动选择结果 |
| `modules/codec/src/ultrahdr_encoder.cpp` | `76c26f2` 新增 `PhotoRenditions` 双输入编码 | 接收完成 DCP 显影的 SDR 与 HyperDR HDR，不承担 RAW 显影 |

当前 `RawDecodeOptions` 没有 DCP 路径，已有 `DngColorProfile` 仅含矩阵类信息，没有 HueSatMap、LookTable、曲线。现有 `.cube` 创意 LUT 和传感器 `--raw-linearization-lut` 都不是 DCP 的替代入口。

当前 RAW 会在 camera matrix 后进行 AP1 方向的 gamut compression，再返回线性 P3。DCP 分支必须在这种不可逆色域压缩之前完成需要 camera RGB 的转换；查表前也不能先将数据裁到 P3 或 sRGB。

## 3. 推荐管线

```text
ARW
  → LibRaw 校准、白平衡、解马赛克及高光处理
  → DCP 相机颜色变换，保留未压成 SDR 的浮点场景数据
  → linear ProPhoto / D50 中的 HueSatMap
  → 曝光基准与渲染黑点处理
  → LookTable
  → 配置曲线或明确的默认基础曲线
  → 输出到 linear Display P3，生成选定配置的 SDR 基底
  → HyperDR 用户调整、HDR 生成
  → PhotoRenditions { sdr, hdr }
  → 各输出编码器
```

矩阵求解使用 RAW 的中性响应和实际 WB，不从 TIFF 的 5100/+16 反推，也不重复乘白平衡。ForwardMatrix 输出 XYZ D50，查表工作空间是 linear ProPhoto；现有只返回 P3 矩阵的接口可以提取共同求解部分，保留原 API 供已有 DNG 调用。

HueSatMap/LookTable 需要色相环绕及表格插值。`Encoding=1` 是 V 的编码规则，不是将 RGB 转成 sRGB 色域。两个校准 HueSatMap 随光源插值，LookTable 单独处理。具体运算应按 [DNG 规范](https://helpx.adobe.com/content/dam/help/en/camera-raw/digital-negative/jcr_content/root/content/flex/items/position/position-par/download_section_733958301/download-1/DNG_Spec_1_7_1_0.pdf)实现。

曝光处理须区分传感器归一化、RAW BaselineExposure、DCP BaselineExposureOffset 和用户曝光。Camera ST 的 −0.35 EV 只能计入一次。当前 LibRaw `adjust_maximum_thr=0.75` 及 WB 归一化也应纳入对照实验，不能直接把 HyperDR 的 1.0 认作 Adobe 的曝光白点。ARW 未提供的 Adobe 默认曝光信息需要单独校准和注明来源，不能假定能从 DCP 取得全部信息。

`DefaultBlackRender=None` 只影响渲染黑点策略，不能关闭 RAW 传感器黑电平校正。Adobe Standard 缺少显式曲线时，Adobe SDK 示例采用 ACR3 默认曲线；可作为首版明确的基准，但不应声称它就是本次 Lightroom ProcessVersion 15.4 的完整默认显影。曲线需按 SDK 的 RGB tone 运算和插值语义实现。参考 [Adobe SDK render 源码](https://android.googlesource.com/platform/external/dng_sdk/+/de700ad461e35af50b28b861943a0b0753b10929/source/dng_render.cpp)。

### SDR 与 HDR 的关系

先把“选定 DCP、调整为零时”的 SDR 校准好。完成曲线的图像已是显示参照基底，不能再按 scene-referred 输入走自动曝光和默认 toe/shoulder。未显影场景缓存仍保持场景语义，不能为了跳过曲线而给整个 RAW 输入错误改名。

同时保留现有场景浮点数据供 HDR 阶段使用。首版 HDR 可以在选定 SDR 基底上应用 HyperDR 的亮度扩展，但必须明确这部分是 HyperDR 的外观设计，不是 Lightroom HDR 复刻。若要利用 RAW 中被 SDR 曲线压缩的真实高光，后续应从场景数据生成 HDR，并为超出 DCP 表范围的值制定连续处理方法；不能将截断的 SDR 反推为恢复的 RAW 高光。

不为此新增几份全分辨率 RGB 常驻副本：复用场景缓存和已有 `PhotoRenditions`，逐行使用查表临时缓冲。普通创意 LUT 保持位于基础显影后的既有位置。S-Log3 场景 LUT 则必须明确其输入来自哪个阶段，不能将完成 DCP 曲线的 SDR 伪装成 Log 场景输入。

新 Ultra HDR 普通导出由 API3 对最终压缩 SDR JPEG 与 HDR 计算增益。DCP 无需重写 gain map 算法。AI/外部 gain 与 Adaptive HEIC 仍按已有分支处理；不把所有输出强行切到同一路编码器。接口细节见 [现有颜色 LUT 与输出管线](color-lut-pipeline.md)。

## 4. 文件与接口落点

建议控制在现有模块边界内：

1. **`codec` 读取配置。** 新增 `dcp_reader.cpp`，读取独立 DCP 的头、IFD、相机名称、矩阵、表、曲线和曝光/黑点字段。只做必要的边界、维度和数值校验。通过规范化的 SONY + ILCE-7RM5 匹配本机 profile；不要用“A7R”模糊匹配其他机型。
2. **`image` 保存数值数据与颜色求解。** 扩展现有 DNG 数学，必要时增加低层 profile 数据头。让 `codec` 与 `look` 共享不依赖文件读取的结构，避免 `look` 反向依赖 `codec`。
3. **`look` 负责配置显影。** 新增 `dcp_render.cpp`，包含 HSM、LookTable、曝光/黑点、曲线与最终工作空间转换。让应用层统一调用，传递已经解析的 profile 与白点上下文。对已经完成基础显影的结果采用明确的接口，不以文件扩展名决定是否再显影。
4. **`app` 连接所有调用点。** 新增拟议参数 `--raw-profile <file.dcp>`，同时覆盖 convert、preview-frame、thumbnail、model-input、model-gain 和基础显影 recipe。此参数目前不存在。`thumbnail` 当前有独立的 RAW 自动曝光逻辑，不能遗漏。
5. **面板只呈现有用选择。** RAW 提供“HyperDR 默认 / Adobe Standard / Camera ST / 选择 DCP 文件”；优先从用户安装的 Lightroom 资源目录及用户指定目录发现匹配配置。无配置时保持原显影；用户明确选择了无法读取或不匹配的配置时给出具体错误，不能悄悄使用另一机型。

首版支持本次两份传统双光源、三通道 DCP 的全部有效字段。第三光源、新型 gain table、单色/多于三通道相机、Adobe Color 等扩展 XMP 外观另列后续支持，不以“能打开文件”宣称已经完整兼容所有 Adobe 配置。

优先按公开规范实现这一小范围模块，以 Adobe SDK 的数值运算作对照，不把整个 SDK 引入现有解码链。若复用 SDK 源码或默认曲线数据，按所用版本随附许可保留声明。产品读取用户本机 DCP；本方案不包含将 Lightroom 配置文件复制进安装包。

### 缓存和可追溯性

自动发现配置必须在缓存键、任务指纹生成之前解析为确定文件。`raw_decode_resources()` 当前四项资源需增加 profile 文件 hash；切换配置、覆盖同路径文件都应失效。仅用 profile 显示名称或路径不够。

解码缓存命中时也须恢复/重新绑定有效 profile 上下文，不能只恢复像素而丢掉后续显影所需的表。预览 preparation、AI 基底/推理缓存、外部 gain recipe 和跳过已有输出的签名都要涵盖配置身份与显影实现版本。若序列化格式改变，更新 decode cache schema；报告增加配置名称、相机、hash、矩阵来源、基础曲线来源和实际曝光策略，并同步 report/settings schema。

## 5. 实施顺序与验收

| 阶段 | 实现内容 | 完成条件 |
| --- | --- | --- |
| 1：读文件、接矩阵 | 显式 DCP 参数、机型匹配、双光源/FM、WB 与曝光尺度追踪 | 能读取本次两份文件；输出诊断与本文字段相符；无 DCP 时保持原行为。此阶段不宣称已经匹配 Lightroom |
| 2：完成 SDR 基础显影 | HSM、LookTable 编码、曲线、基线曝光和黑点策略 | 两份 TIFF 各自对照；用消融图分开观察矩阵、色彩表和曲线贡献；默认不再叠加 HyperDR 自动曝光 |
| 3：连接产品路径 | 面板、缓存、普通/AI 预览、导出、HDR 图像对 | 同一配置的 SDR 基底在各入口一致；切换/覆盖 DCP 正确失效；HDR 强度为零时仍保留选定 SDR 外观 |

测试保持集中：沿用现有 DNG 矩阵测试，补双光源中点/端点、单位表、色相环绕、V 编码、Camera ST −0.35 EV 只生效一次及曲线中性灰。再补切换 profile 的缓存回归和一个预览/导出一致性集成用例即可，不为每个字段各造一套框架。用于自动测试的 profile 可生成小型合成数据，不提交 Adobe 原文件。

实片比较读取 16 位 TIFF ICC 到统一的 XYZ D50/Lab，分别报告绝对明度误差和曝光对齐后的色彩误差；不要通过给每张照片单独拟合曲线掩盖默认曝光问题。统一裁剪和尺寸，避开锐化/降噪差异强的边缘。项目目前不读取普通 TIFF，可以用离线颜色管理比较器，不必把 TIFF 产品支持作为此功能前置。

当前单帧足以验证读取和暴露明显偏差，不足以决定全局校正。第二阶段还需日光肤色、钨丝灯、混合光、饱和红蓝、高反差高光的多帧样本。指标应在有初版结果后设定，不能现在承诺“达到 Lightroom 的某个百分比”。

Lightroom 的 Process Version 涉及 DCP 之外的图像处理；降噪、解马赛克、高光和局部色调也会造成残差。因此验收目标是正确支持目标 DCP，并证明相较当前默认显影更接近对应 Lightroom 参考。[Adobe Process Versions](https://helpx.adobe.com/camera-raw/desktop/get-started/overview-and-setup/process-versions.html)

## 6. 并行任务完成后的复核

对 `76c26f2` 的 `batch.cpp`、`cli.cpp`、`ultrahdr_encoder.cpp` 和新 codec 用例进行了有范围的静态复核，未确认需要额外修复的新缺陷。普通 RAW/SDR Ultra HDR 的导出进入 API3，预览使用同一渲染对；AI/external gain 和保留原生 HDR 的分支没有被误切换。新图像对测试已从测试入口调用。

本轮实际运行的是同一 ARW 的两次默认预览及上述色彩测量，没有重新运行其他任务的完整编解码测试，也没有进行物理 HDR 显示验收。实时预览不包含导出的 JPEG/half-float/增益图量化误差，因此一致性指基础渲染数据来源一致，不是编码后逐像素无损。

若后续使用接口复用外部 Lightroom JPEG，预览也必须对该 JPEG 做正确 ICC 解码；不能预览另一个浮点基底却导出复用 JPEG。

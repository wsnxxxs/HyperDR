# 本机 Adobe Lightroom 实现证据与 HyperDR 改进方向

日期：2026-09-24。HyperDR 代码基线：`3dbe540`。

## 范围与结论

本次读取本机 Lightroom Classic 15.4.1 / Camera Raw 18.4 的安装资源、
PE 导入表、二进制内嵌名称、模型清单、配置和日志，并重新提取项目中两张
Lightroom 导出 TIFF 的元数据。未修改 Adobe 文件，未执行 Adobe 二进制中的
内部接口，未重新运行 Lightroom 导出，也未做反汇编或完整算法还原。

最有价值的发现是：

1. Adobe Color 包含 DCP 之外的 XMP LookTable 和曲线层。
2. 本机 AI look 模型明确声明普通与 HDR 两套输出。
3. Camera Raw 包含 GPU 运算阶段、瓦片渲染与图像金字塔调度组件。
4. 当前参考 TIFF 的“零滑块”仍包含彩色降噪和配置文件处理。
5. HyperDR 已实现传统 DCP 的主要字段，下一步价值更高的是补 XMP look、
   保留 DCP 路径的场景高光和增加全分辨率局部预览。

证据分三类：文件字段是直接事实；二进制名称证明组件存在；由名称推测的
算法职责和性能策略是推断。静态文件不能证明某张照片实际经过的完整执行顺序。

## 1. 相机配置与风格层分别存在

安装资源根目录：`C:/Program Files/Adobe/Adobe Lightroom Classic/Resources/`。
本次枚举得到 4,352 个 CameraProfiles DCP、3,576 个 LensProfiles LCP、
1,039 个 Settings XMP。数量描述本机安装，不代表所有字段都被 HyperDR 支持。

Sony ILCE-7RM5 两个配置的实际 IFD 内容：

| 字段 | Adobe Standard | Camera ST |
| --- | --- | --- |
| CalibrationIlluminant1/2 | 17 / 21 | 17 / 21 |
| ColorMatrix、ForwardMatrix | 双光源矩阵 | 双光源矩阵 |
| HueSatMap | 两张 90×30×1 | 无 |
| LookTable | 36×8×16 | 90×16×16 |
| 显式 ToneCurve | 无 | 128 个点对 |
| LookTableEncoding | 缺省 | 1 |
| BaselineExposureOffset | 缺省 | −0.35 EV |
| DefaultBlackRender | 缺省 | 1 |

来源为 `CameraProfiles/Adobe Standard/Sony ILCE-7RM5 Adobe Standard.dcp`
与 `CameraProfiles/Camera/Sony ILCE-7RM5/Sony ILCE-7RM5 Camera ST.dcp`。
没有显式曲线不等于引擎不会应用默认曲线。

更关键的文件是
[Adobe Color.xmp](</C:/Program Files/Adobe/Adobe Lightroom Classic/Resources/Settings/Adobe/Profiles/Adobe Raw/Adobe Color.xmp:21>)：

- `CameraProfile="Adobe Standard"`。
- 单独的 `LookTable` 引用及嵌入表数据。
- `ToneCurvePV2012` 的七个点：`0,0; 22,16; 40,35; 127,127; 224,230; 240,246; 255,255`。
- 声明支持 scene-referred、普通动态范围及 HDR。

因此，“选 Adobe Standard DCP”与“选 Adobe Color”并非相同配置。
本机文件直接证明 Adobe Color 还有额外的风格数据，但不能单凭 XMP 属性的
排列推断引擎具体的执行顺序。

HyperDR 当前自动发现只扫描 `.dcp`，reader 只接受独立 DCP 头 `0x4352`；
没有上述 Adobe Color XMP look 的导入入口。
证据：[raw_profiles.py](../../apps/panel/hyperdr_panel/raw_profiles.py#L105)、
[dcp_reader.cpp](../../modules/codec/src/dcp_reader.cpp#L19)。
已有 `.cube` LUT 功能也不等于已经解释 Adobe XMP 中的表格式。

全量 DCP 标签扫描发现 26 个文件包含当前 reader 明确拒绝的渲染标签；
这是静态标签审计，未逐个执行解析器。Sony ILCE-7RM5 的 10 个配置没有这些拒绝标签。

## 2. Adaptive look 的 SDR/HDR 数据分离

[ai_look 模型清单](</C:/Program Files/Adobe/Adobe Lightroom Classic/Resources/ModelZoo/ai_look/winml/manifest.json:13>)
声明 WinML 输入为 float，形状 `[1,5,384,512]`。输出如下：

| 普通命名输出 | HDR 命名输出 | 张量形状 |
| --- | --- | --- |
| pgtm | pgtm_hdr | [1,1,196608,1] |
| rgbt_0、rgbt_1、rgbt_2 | rgbt_0_hdr、rgbt_1_hdr、rgbt_2_hdr | 每个 [1,1,98304,1] |
| exposure | exposure_hdr | [1,1,1,1] |

CameraRaw.dll 内同时出现 `ai_look::DoInference`、`pgtm_hdr`、`rgbt_0_hdr`
等名称，支持这个清单确实对应安装的引擎组件。

[Adaptive Color.xmp](</C:/Program Files/Adobe/Adobe Lightroom Classic/Resources/Settings/Adobe/Profiles/Adaptive/Adaptive Color.xmp:19>)
另外记录 `ProcessVersion="15.4"`、`ProfileGainTableMap="100"`、
`RGBTables="100"`，并引用与 Adobe Color 相同标识的 LookTable。

可以确定：本机构建提供带独立 HDR 输出的 AI look 接口，以及用于 profile 的
gain-table/RGB-table 配置。合理推断：它可以分别控制普通与 HDR 外观。
不能确定：五个输入通道的物理含义、输出表的解码与插值公式、训练目标，
或每张使用 Adaptive Color 的照片是否在当前条件下执行这次推理。
也不能把 profile gain table 直接等同于导出 JPEG/HEIC 的增益图。

## 3. AI 功能采用多个任务模型

`Resources/ModelZoo/denoise/winml/` 分别提供 Bayer、X-Trans、linear RAW
路径的模型文件；模型文件存在并不能确定某张照片实际使用哪一个。

可读清单中的示例：

- `select_sky/winml/large`：输入 `[3,320,320]`，输出 `[2,320,320]`。
- `select_sky_refinement/winml/coarse`：输入 `[4,320,320]`。
- `select_sky_refinement/winml/fine`：输入 `[4,640,640]`。
- `universal_refinement/winml`：独立 RGB 输入 `[1,3,480,480]` 与
  分割输入 `[1,1,480,480]`，输出单通道结果。

这些文件支持“任务拆分、分割后精修”的架构判断；不能据此还原完整网络，
也不能断言所有文件按上述顺序串联。组件路径标为 `secured_file`，本次只读清单。
对 HyperDR 的启示是先定义模型输入域、输出语义与版本，按任务选择合适分辨率，
不必为了 HDR 扩展引入整套主体/天空/人像系统。

## 4. GPU 与瓦片管线的二进制证据

`CameraRaw.dll` 的 PE 导入表包含 `d3d11.dll`，延迟导入包含 `d3d12.dll`
与 `dxgi.dll`。下表为内嵌 ASCII 名称及十六进制文件偏移，不是函数入口地址：

| 名称 | 文件偏移 | 能支持的判断 |
| --- | --- | --- |
| cr_gpu_command_buffer::NewComputePass | 0x33AA0C8 | 存在 GPU compute pass 组件 |
| cr_gpu_tile_render_task::ConsolidateWith | 0x344B578 | 存在瓦片渲染任务组件 |
| cr_gpu_pyramid::UpdatePriorityList | 0x344A368 | 存在图像金字塔及优先级管理组件 |
| cr_stage_denoise::Process_gpu | 0x3469BF8 | 存在 GPU 降噪阶段 |
| cr_stage_sharpen_3::Process_gpu | 0x348F930 | 存在 GPU 锐化阶段 |
| cr_stage_tone_map fGpuHelper | 0x330B820 | 存在色调映射 GPU helper |
| cr_stage_exposure fGpuHelper | 0x4E74978 | 存在曝光 GPU helper |
| cr_stage_color_table fGpuHelper | 0x32EAFA0 | 存在颜色表 GPU helper |

`LibraryToolkit.dll` 还有 `buildJpegPixmapPyramid` 字符串。
这是比“安装了 GPU DLL”更强的组件证据，说明 GPU 并非只用于显示画布。
仍不能断言每一步处理或每次导出都使用 GPU。

Camera Raw 的本机日志记录 RTX 5070 Ti、DirectX、GPU3/GPU4 初始化成功；
GPU 配置记录 compute quick self-test passed。这证明所记录启动的 GPU 初始化，
不是所有后续运算的性能跟踪。

二进制同时出现 `Linear ProPhoto RGB`、`Linear Display P3`、
`DXGI_FORMAT_R32G32B32A32_FLOAT` 与 `cr_stage_output_sharpen fp32`。
这些只证明对应空间/格式/组件存在，不能据此宣布全流程统一某个空间或位深。
`ACE.dll` 有颜色转换内部名称，但 CameraRaw 静态导入表未直接列出 ACE；
本次不把二者之间的调用关系作为结论。

## 5. 参考文件的零滑块不是无处理

重新解析项目中 `raw处理管线相关图片/DSC01925Adobe-Standard.tif`
及 `DSC01925_Camera-ST.tif` 的 TIFF IFD 与 XMP，确认两者均为：

- 9504×6336，RGB，每通道 16 位，无压缩，内嵌相同 940 字节 ICC。
- Camera Raw Version 18.4、ProcessVersion 字符串 15.4。
- Exposure/Contrast/Highlights/Shadows/Whites/Blacks 均为零。
- Sharpness=0、LuminanceSmoothing=0，但 ColorNoiseReduction=25。
- 用户 ToneCurveName2012=Linear，HDREditMode=0。
- LensProfileEnable=0，尽管同时存在 LensProfileName。

这说明对比应固定 profile、process version、降噪与镜头开关，不能只看基本滑块。
存在 LensProfileName 不能证明镜头校正启用；用户曲线 Linear 也不能排除
DCP/XMP profile 内部曲线。上述两张样本是 SDR，不能验收 HDR 管线。

`Resources/xmp_schema.json` 是一般资产元数据映射，未包含 `crs` 命名空间；
不能把它当成显影操作图。偏好中的 `AgCameraRawNamedSettings_*` 也可能表示
复制/预设设置组选项，不能当作当前照片的启用阶段。

## 6. 对 HyperDR 的具体行动顺序

| 优先级 | 改进 | 本次证据与收益 |
| --- | --- | --- |
| P1 | 明确 Adobe Standard DCP 与 Adobe Color XMP 的不同；按需增加有限 XMP look 支持 | 补上目前缺少的外观层，避免对错参照 |
| P1 | 为 DCP RAW 保留独立场景 HDR 分支 | 当前 dcp_render.cpp 限幅后被作为 SDR 扩展；避免先丢高光再增亮 |
| P1 | 增加全分辨率可见区域预览 | 借鉴瓦片/金字塔策略，解决缩小预览无法判定细节的问题 |
| P1 | TIFF 16 位 ICC 输入/输出 | 直接接收本机 Lightroom 参考 TIFF，打通编辑器往返 |
| P2 | 测量后选择局部 GPU 运算 | 本机 GPU 能力已启用；先找耗时阶段，再移植可验证的运算 |
| P2 | 审核 LCP 实际字段覆盖 | 本机配置包含分段暗角数据；当前实现只读取基础多项式参数 |

XMP profile 兼容应显式声明已支持的字段，不静默把 Adaptive Color 当作固定 LUT。
模型/配方身份应包含输入域、相机配置、look 与版本，避免缓存错误复用。
SDR、HDR 两个渲染目标可以分别设计，但不应机械复制尚未解释的 Adobe 张量接口。

LCP 的具体例子是
`Resources/LensProfiles/1.0/Tamron/Sony/SONY (TAMRON 28-200mm F2.8-5.6 Di III RXD A071) - RAW.lcp`：
有 792 组校准记录，其中包含 362 组分段暗角点。HyperDR 仍会应用同一记录的
三参数暗角模型，但忽略分段点；对焦距离用于择优，不做连续插值。
文件中的 ApertureValue 是 APEX 值，不能直接当作 f 数。

HDR 互通还需要一项针对性验收：HyperDR 仅在 `is_uhdr_image()` 识别为真时
走 JPEG HDR 解码。不能保证任意 Lightroom“最大兼容”JPEG 都被识别；
未识别的文件可能按普通 SDR JPEG 读取。上轮建议的 HDR JPEG 桥接应理解为
候选路径，必须用实际样本确认输入域和高光范围，不能当成已验证的安全往返。

## 7. 本机可复查证据

临时解析脚本、PE 表、筛选后的名称和 TIFF/模型摘要保存在忽略目录
`output/adobe-local-audit/`。Adobe 二进制、模型、完整 LUT 和照片未加入提交。
`read_local_evidence.py` 使用标准库读取清单与 TIFF 元数据，未解码或修改像素。

文件身份：

- CameraRaw.dll：`cbfe38e539047b3e2b92ca411ed97e0f7db9966bcc521633d244eb982634649c`
- Adobe Color.xmp：`8dae7ad8667ec1a1b95659081b44fa89e480baf6421e186bfec9cf54042d52c`
- Adaptive Color.xmp：`d95cc687a35ab235504f4ffabf502a134cefc194e18e9bab39c4571eb49bd682`

没有执行性能基准、屏幕色彩测量或 Lightroom 新导出。所有改进项都是研究建议，
不是本次已经实施的功能。

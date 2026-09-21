# RAW 管线审查 — 2026-09-06

**修复状态：下文六类已确认缺陷现已修复。** 本文其余部分保留审查时的
复现记录；新增显影控制、RAW 降噪和多帧融合仍属于尚未实现的功能，
不在本次缺陷修复范围内。

修复后，LUT 统一变换像素/黑/白电平；暗场及坏点在裁切前处理；LSC 保持
原可见区域坐标并预留整数余量；曝光补偿使用实际 WB 倍率；负 P3 分量保留
至色域压缩；mosaic 提前验证 CFA 类型和完整 2×2 周期。报告新增实际 WB
来源，解码与分析缓存已更新版本，`raw_gain` 文案也已改为实际的后置线性增益。

新增数值回归覆盖上述缺陷以及半尺寸 LSC、坏点裁切、暗场与 LUT 组合；
RAW、摄影渲染、缓存和报告的针对性检查通过，三项 native 合约检查通过。
真实 ARW 仍以 9504×6336 完成四模式解码和 Ultra HDR 导出；合成 DNG 的
六种 HDR 导出均通过自验证。物理 HDR 显示器和更多相机格式仍未进行实拍验收。

---

当前管线已经能完成相机 RAW → 摄影渲染 → HDR 文件的主要任务，但还不能认为 RAW 校准、广色域处理和 RAW-domain 接口已经完善。优先修复已有功能的数值与坐标问题，再考虑增加新的显影功能。

本次依据 README、rendering.md 和公开接口的现有承诺检查工作区实际代码。基线 HEAD 为 `0584f58`，**包含审查开始前已有的未提交色域等修改**，结论不代表仅 HEAD 的行为。本次未修改产品代码。

## 当前实际流程

```text
RAW 文件
  → LibRaw 读取元数据、解包
  → 可选外部码值 LUT、自动坏点处理
  → 应用 DefaultCrop（RGB 导出路径）
  → LibRaw 坏点表、暗场、黑电平、白平衡及整数缩放
  → 可选镜头阴影增益（uint16，最大 65535）
  → 去马赛克、高光处理、线性 ProPhoto RGB
  → float 白平衡归一化补偿及 raw_gain
  → 线性 Display P3
  → 场景分析、自动曝光、SDR 基图及 HDR gain map
  → 六种编码、自验证、写入文件
```

`decode_raw_mosaic()` 是另一条公开入口：关闭白平衡缩放及去马赛克，在 RGB 转换前截取 CFA 样本，再归一化和 pack。正式转换和生产 AI 模型均没有使用这个入口。

## 已确认的问题

### 1. 外部 LUT 与黑白电平不在同一数值域

位置：`modules/codec/src/raw_decoder.cpp:347`、`:568`、`:793`。

`apply_linearization_lut()` 只修改解包像素；后续仍使用原黑电平，白电平也没有按 LUT 的输出域重新定义。

复现使用非零 BlackLevel=512 的 DNG，首个红像素为 1112，即 512 黑偏置加 600 场景信号。使用 `2 / 0 / 0.5` LUT 后，实际扣黑计算变成 `556 - 512 = 44`；在映射后的黑电平域中，应扣除 `256`，得到 `300`。至于归一化后是否保持原比例，取决于是否同时变换白电平，必须明确定义，不能继续混用两个域。

实测归一化值从 `0.0092275` 变成 `0.000676684`，仅剩原值的 `7.33333%`。更暗的真实信号可能被扣成零，后续曝光无法恢复。

建议：先统一外部 LUT 的输入、输出、黑电平、白电平以及暗场的域约定，再同步变换相应校准量。只检查 LUT 能否影响输出是不够的。

### 2. DefaultCrop 使暗场失效，而转换仍报告成功

位置：`modules/codec/src/raw_decoder.cpp:611`、`:630`，`modules/app/src/report.cpp:36`。

RGB 路径在 `dcraw_process()` 之前更改可见区域；LibRaw 随后要求暗场 PGM 尺寸匹配已经裁切的区域。原图尺寸正确的暗场因此可能被跳过。HyperDR 没有检查对应 `process_warnings`，报告中的 `raw_processing` 仅记录请求的选项，不记录实际执行结果。

复现：96×80 的 DNG 带 80×64 DefaultCrop，提供 96×80、各像素码值为 1000 的有效暗场。RGB 解码与不使用暗场逐像素完全相同，`maxdiff=0`，`degraded=false`。相同暗场在未裁切的 mosaic 入口确实生效，首个样本从 `0.00915541` 变成零。

建议：在统一的传感器坐标中应用暗场、坏点表和空间校准，然后裁切；或明确变换校准资源到裁切坐标。用户显式要求的校准被跳过时，应明确失败或报告未应用，不能只写资源路径。

LibRaw 的尺寸检查与警告行为可见其 [0.22.1 暗场实现](https://github.com/LibRaw/LibRaw/blob/0.22.1/src/preprocessing/ext_preprocess.cpp#L64)。坏点表也按处理时的宽高解释坐标，需一并检查裁切偏移；本次没有单独量化坏点错位。

### 3. 缺少相机白平衡时，高光模式改变整幅曝光

位置：`modules/codec/src/raw_decoder.cpp:549`。

非 Clip 模式的曝光补偿在 `dcraw_process()` 前，只从 `cam_mul` 计算。但 LibRaw 在相机白平衡不可用时可以回退到其他白平衡，实际使用的倍率并不一定是这里预读的值。

复现：移除合成 DNG 的 AsShotNeutral，Clip 的亮度中位数为 `0.0958073`，Blend 为 `0.044125`，相差 `-1.11854 EV`，仍然 `degraded=false`。固定曝光时会直接看到整幅变暗；自动曝光可能抵消一部分，但不能据此认为解码尺度正确。

建议：补偿以实际生效的 WB 倍率为准，并让报告反映相机 WB 或 fallback。LibRaw 的回退约定见 [官方参数文档](https://github.com/LibRaw/LibRaw/blob/0.22.1/doc/API-datastruct.html)。

正常相机 WB 不一定触发该问题：本次真实 ARW 的四模式中位数差异约 `0.00058 EV`，通过现有 `<0.05 EV` 检查。

### 4. 解码保留的负 P3 分量，在摄影渲染前又被截断

位置：`modules/gainmap/src/render.cpp:124`，`modules/look/src/scene_stats.cpp:38`，`modules/gainmap/src/photographic.cpp:57`。

当前工作区的 ProPhoto→P3 已保留负分量，但后续场景统计、局部亮度和最终渲染调用 `positive_finite()`，把合法的负分量变成零，然后才执行亮度计算和共同色度压缩。这不符合“保留越界颜色到色域处理阶段”的承诺，可能改变高饱和颜色的亮度和色相。

直接输入线性 P3 `(-0.2, 0.3, 0.2)`：真实 P3 亮度为 `0.177584`，统计亮度却为 `0.223379`，高出约 25.8%。该输入与事先截断成 `(0, 0.3, 0.2)` 的输入产生完全相同的 SDR 基图，`maxdiff=0`。

建议：将非有限值处理与负分量处理分开；统计和共同色度计算保留有限的带符号 RGB，由明确的色域压缩阶段处理越界颜色。这个问题涉及默认 RAW 渲染路径，优先级高于增加新的可选校准功能。

### 5. X-Trans 被 mosaic 接口误认成 Bayer 并成功打包

位置：`modules/codec/src/raw_decoder.cpp:441`、`:823`。

`detect_bayer_pattern()` 只检查左上 2×2 是否像四种 Bayer 排列，没有先排除 X-Trans，也没有验证整个 CFA 的 2×2 周期。

复现：将合成 DNG 声明为有效的 6×6 X-Trans CFA，其左上角恰好是 GBRG。`decode_raw_mosaic()` 返回 `GBRG`，`pack_bayer()` 成功输出 `48×40×4`。打包后的通道并不持续对应 R/Gr/Gb/B，与公开接口“拒绝 X-Trans”直接矛盾。

建议：先验证 CFA 类型及其 2×2 周期，再允许 pack。该问题属于 RAW-domain 消费者；不能把它解释成 LibRaw 的普通 X-Trans RGB 解码也必然错误。

### 6. 镜头阴影校正有高光截断和裁切坐标问题

位置：`modules/codec/src/raw_decoder.cpp:282`、`:627`。

校正在 LibRaw 白平衡/缩放后对 `uint16` 逐通道乘增益，并硬截到 65535，没有为 LSC 预留额外数值范围。明亮边角经放大后可能在进入 float HDR 域之前就失去细节。现有回调顺序可见 [LibRaw 0.22.1 处理流程](https://github.com/LibRaw/LibRaw/blob/0.22.1/src/postprocessing/dcraw_process.cpp#L108)。

实测统一 2× LSC 与解码后 2× float gain 的中位数几乎相同，但最大线性通道差异达 `2.66279`。此比较证明明亮区域不能按简单线性倍率等价处理；它同时包含整数截断和下游高光处理的作用，不能把该差异全部归因于某一次截断。

空间坐标方面，LSC 总是把整个 map 拉伸到当前 `iwidth/iheight`，不包含 DefaultCrop 的传感器偏移。mosaic 使用原可见区域，RGB 使用裁切区域，同一标定 map 的含义因此不同；现有格式也未明确规定坐标域。

建议：定义校准图的传感器覆盖范围，裁切时保持采样位置一致；同时为校正增益预留整数余量并在 float 中恢复，或使用能保留所需范围的处理方式。

## 功能完整性判断

| 目标 | 当前情况 | 判断 |
| --- | --- | --- |
| 普通 RAW → HDR 照片 | LibRaw、相机 WB、高光恢复、曝光、摄影曲线、gain map、六种编码已经接通 | 主链路可用，有上述默认色域路径问题 |
| 全分辨率输出与方向/裁切 | 全尺寸解码、DefaultCrop、方向以及显式半尺寸预览已有实现 | 真实 ARW 和合成 DNG 的本次检查通过 |
| 校准选项改变缓存/续跑结果 | raw gain、高光模式、半尺寸及外部资源内容参与相关 key/fingerprint | 已有机制，相关 resume 测试通过 |
| 暗场、LUT、LSC、坏点校准 | 有 CLI/C++ 入口，但组合语义和实际应用状态不完整 | 尚不宜作为可靠校准链路宣称完成 |
| RAW-domain 神经网络输入 | 有 mosaic 和 4 通道 pack API，CFA 判定有缺陷；主流程未接入 | 是基础接口，不是完整算法管线 |
| RAW 降噪、去条纹、多帧 HDR 融合 | 当前生产流程没有对应算法；暗场可承担部分固定图样噪声校正 | 若目标包含这些功能，尚未实现 |
| 完整显影器控制 | 无用户 WB 色温/色调、可选去马赛克策略或通用镜头畸变/色差工作流 | 对现有 HDR 转换器定位可接受；对完整显影器不足 |
| 桌面/浏览器校准操作 | 面板传递高光恢复和摄影参数，未暴露外部校准资源及 RAW gain 等完整接口 | CLI 能力不等于 GUI 功能完整 |
| AI 优化 RAW | RAW 先显影成 SDR 基图，模型预测 gain map | 不是 RAW 降噪或传感器动态范围恢复；文档已承认 RAW 分布偏移 |

`raw_gain` 还有一项语义需要澄清：RGB 路径实际在去马赛克、高光处理、16-bit ProPhoto 输出之后乘它；mosaic 路径也在采样归一化后乘。它是后置线性倍率，不能用于避免前面发生的截断；默认自动曝光还可能抵消它对整体亮度的作用。应据产品目的修正文案或处理位置，不必仅为名称增加一套复杂管线。

## 本次验证与边界

- 使用 MSVC Release 和本机 LibRaw 0.22.1，从当前工作区重新构建审查所用转换器、测试和临时探针。
- 六项现有 CTest 全部通过：`raw_highlight_test`、`color_dither_test`、`gain_map_test`、`local_gain_test`、`look_pipeline_test`、`resume_state_test`。
- 真实 ARW `DSC01293.arw`：四种高光模式均解码为 9504×6336，曝光差异通过现有门槛。
- 同一真实 ARW 以默认手动管线设置导出 Ultra HDR JPEG：9504×6336，`success=true`，正常完成内置自验证。
- 合成 DNG 分别导出 Adaptive HEIC、Ultra HDR JPEG、PQ HEIC、HLG HEIC、PQ AVIF、HLG AVIF，六种转换全部成功并执行默认自验证。该检查证明编码链路可运行，不证明所有相机/场景的显示质量。
- 补充探针量化了 LUT、WB fallback、暗场、LSC、负色值处理、X-Trans 判定问题；它们未被现有通过的测试覆盖。
- 没有做物理 HDR 屏幕验收，也未覆盖多品牌 RAW、真实 X-Trans 相机文件、高 ISO 夜景或空间标定实拍样本。预览与导出仍采用不同去马赛克/缩放路径，本次没有量化真实照片的两者视觉差异。

本地复现代码和产物位于忽略目录 `build-release/raw-audit/`：现有 `raw_audit_probe.cpp` 本次重新链接当前库后运行；新增 `raw_review_probe.cpp` 检查负 P3 和 X-Trans。`review-*.json`、`review-exports/` 和 `review-real-export/` 保存本次转换证据。照片和生成文件不纳入提交。

建议实施次序：先修默认摄影路径的负分量处理；将 LUT、暗场和 LSC 作为同一校准域/坐标问题处理；再修 WB fallback 与 Bayer 判定。每项增加能够复现错误的最小数值检查即可，无需扩展成大规模测试框架。

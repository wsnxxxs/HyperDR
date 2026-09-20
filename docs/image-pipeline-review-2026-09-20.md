# 图像管线升级复核（2026-09-20）

检查重点是当前 RAW/DNG 解码、浮点色彩转换、HLG、色域映射、HDR 增益图重建和文件回读，不以模型选择器或界面测试替代图像正确性检查。

## 确认并修复的问题

### HLG 饱和高光损失亮度

新的亮度 OOTF 实现方向正确，但编码前仍逐通道截断逆 OOTF 的结果。P3 像素 `(0, 0, 1000/203)` 符合渲染器的通道范围，转换后却超出 HLG 实际可表达的色容积；截断后回读亮度仅为目标的约 71.32%。HEIC、AVIF 和 HLG LUT 输入编码共用这条路径。

修复位于 `modules/image/include/hyperdr/image/transfer.hpp`：在固定亮度下计算 HLG 的通道上限，超出范围的颜色向同亮度中性色收缩，再执行 OETF。在范围内的颜色保留原行为。新增回归验证饱和蓝色保持亮度、信号值合法，以及普通颜色不被改动。超范围颜色无法同时保留全部饱和度，这是输出表示范围的限制。

### DNG 使用了不匹配的 CameraCalibration

之前读取 CameraCalibration 时没有核对 CameraCalibrationSignature 与 ProfileCalibrationSignature。两个签名不匹配时，仍会把属于另一个参考相机的校正应用到当前配置。合成 DNG 的旧程序复现中，不匹配配置与匹配配置输出完全相同，却与正确的无校正输出存在可测的颜色差异。

修复位于 `modules/codec/src/raw_decoder.cpp`：通过 LibRaw 已有的 TIFF 回调读取这两个标签，只有签名相同时才应用 CameraCalibration；都缺省时按空字符串匹配。回归覆盖匹配、不匹配、仅一方缺失和 ASCII/BYTE 字符串。解码缓存 schema 升至 14，避免继续读取旧颜色结果。

依据：[Adobe DNG 1.7.1 规范](https://helpx.adobe.com/content/dam/help/en/camera-raw/digital-negative/jcr_content/root/content/flex/items/position/position-par/download_section_733958301/download-1/DNG_Spec_1_7_1_0.pdf)，CameraCalibrationSignature/ProfileCalibrationSignature 标签定义与颜色转换章节。签名不匹配时 CameraCalibration 应视为单位矩阵。

## 升级的实际价值

| 改动 | 对照片的意义 |
| --- | --- |
| 相机矩阵移到浮点计算 | 减少整数矩阵转换带来的截断；保留矩阵转换产生的高光和广色域信息，交给后续显影处理。去马赛克等步骤仍由 LibRaw 执行，不能称为全流程浮点 RAW。 |
| DNG 双光源校准与 ForwardMatrix | 颜色转换随实际白平衡变化；暖光拍摄不再一律使用 D65 校准。 |
| DNG opcode | 应用文件携带的坏点、镜头阴影等已支持校正，改善手机 DNG 暗角和边缘颜色；不支持的必需 opcode 仍报告降级。 |
| HLG 亮度 OOTF | 修正逐通道 gamma 带来的色彩比例错误，使 HLG 的读写与正确的亮度模型一致。 |
| 延后色域处理与新的色域映射 | 避免在解码阶段直接丢弃负 RGB 分量；更好地保持越界颜色的亮度和色相。蓝紫色使用独立策略，不是所有颜色统一保持 Oklab 色相。 |
| HDR 源图的全分辨率增益图 | 避免相邻明暗区域共享平均增益；减少细小高光变暗和饱和高光褪色。代价是更大的增益图和处理开销。 |
| 正确 ICC 暗部曲线、10 位 Adaptive 底图及 Ultra HDR 4:4:4 | 减少暗部变黑、量化误差和颜色边缘损失。实际文件仍有编码损失，不能称为完全无损。 |

## 实测证据与范围

- 两项修复完成后重新编译 Release，41 个 CTest 与 3 个跨语言原生契约测试全部通过，包含新增 HLG 高饱和高光和 DNG 校准签名回归。
- 当前 Release 的原生集成用例覆盖 3200 像素宽 HLG 图、HEVC 网格、暗部渐变、细高光条和饱和颜色。额外复测的 Adaptive/Ultra HDR 平均 ΔE ITP 分别约 0.379 / 1.061；这组数字对应合成用例，不代表所有照片。
- 使用当前程序重新将实拍 `DSC02120.HIF` 导出为质量 90、10 位底图的 Adaptive HDR，按中性设置保留源图范围。回读比较 60,217,344 个像素：平均 ΔE ITP **2.129**，高光区域平均 **4.069**，源图与输出峰值均约 **4.926 倍 SDR 白**；4×4 线性均值后的平均 ΔE ITP **0.771**。
- 实拍记录：`.workbuddy/pipeline-current-adaptive.json` 与 `.workbuddy/pipeline-current-adaptive-verify.log`；合成编码记录：`.workbuddy/pipeline-codec-review.log`。
- 本次没有以旧的已导出文件代替当前程序的重新导出，也没有把浮点增益图的重建精度当作有损文件的逐像素无损保证。未做实体 HDR 屏幕验收或所有相机机型覆盖。

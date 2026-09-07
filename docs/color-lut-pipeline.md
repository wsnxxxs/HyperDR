# 颜色 LUT、照片渲染与 SDR/HDR 输出

## 架构审视与调整

这次实现先检查了解码、曝光分析、照片渲染、编码、原生预览、面板命令、缓存与报告。
原架构已经有很好的共同入口：`DecodedImage` 保存不限制上界的线性 Display P3 RGB，
并明确区分场景线性 RAW、已经显影的 SDR 和已经显影的 HDR。应保留这个入口，不能凭
扩展名、像素是否超过 1，或“看起来很灰”猜测照片的传递函数。

需要调整的是出口。此前 `GainMapResult` 同时承担照片渲染结果和 gain map 封装输入；
HLG/PQ HEIC 与 AVIF 编码器也必须先从量化后的低分辨率 gain map 重建 HDR。
这把颜色处理、高光的空间分辨率、SDR 底图和最终格式绑在了一起。纯 SDR 导出也没有
自己的表达方式。在这里直接增加一个 LUT 文件参数，会把 SDR/Log/HDR LUT 的空间
约定混在同一个入口，无法解决这些问题。

现在的职责是：

1. `codec` 解码并管理 ICC/CICP、RAW 校准、白平衡、方向与裁剪。
2. `look` 管理曝光、局部高光权重、色彩、LUT 和照片渲染。
   `PhotoRenditions` 明确携带 SDR 图像和可选 HDR 图像；纯 SDR 的 HDR 缓冲为空。
   此层不依赖容器或 gain map 元数据。
3. 选择 Adaptive HDR / Ultra HDR 时，`gainmap` 从照片的 SDR/HDR 亮度关系生成
   兼容现有单通道配置的空间映射，再交给对应编码器。
4. 选择 HLG/PQ HEIC / AVIF 时，编码器直接接收 HDR 浮点像素；不再经过量化 gain map。
5. 选择 SDR JPEG 时，只编码 SDR 图像，实际输出为带 sRGB ICC 和拍摄 Exif 的普通 JPEG。

曝光分析、局部高光权重和公共色彩计算从 `gainmap` 下移到了 `look`，没有另造一套
相机解码器。旧 `GainMapOptions` 和接受 `GainMapResult` 的编码 API 保留兼容入口。
AI/外部模型本来就预测 gain，因此通过适配器进入照片结果；它们原有的有符号、逐通道
元数据仍保留，不被重新拟合成普通正向单通道图。创意 LUT 先作用于模型的 SDR 底图，
再按原增益图及偏移重建 HDR。预览、直出 HDR 和增益图输出共用这个重建结果；模型
预测仍来自未套创意 LUT 的输入，不因调色而重新拟合。

预览和导出调用相同照片渲染函数。gain map 格式的预览包含打包后的映射误差；直接 HDR
格式的预览读取直接 HDR 图像。原始解码和分析缓存继续独立于 LUT；LUT 内容摘要参与
输出指纹与预览缓存。面板上传的 LUT 按内容摘要保存为照片会话内的不可变资源，撤销、
恢复和导出历史记录引用该资源。

## 三种 LUT 接入位置

`.cube` 的采样表和 `DOMAIN_MIN/MAX` 不足以可靠说明传递函数或色域。用户需要按照 LUT
作者的说明选择输入、输出空间，不进行自动猜测。

| LUT 输入空间 | 接入位置 | 支持的照片来源 | 输出解释 |
| --- | --- | --- | --- |
| sRGB、Display P3、Rec.709 Gamma 2.4 | SDR 显影或 HDR→SDR 映射之后 | RAW、SDR、HLG/PQ、gain map HDR | SDR 风格；HDR 输出沿用原有 HDR/SDR 亮度比例 |
| HLG / BT.2020、PQ / BT.2020 | 转入 LUT 指定的信号编码；已有 HDR 在高光映射之前 | 已有 HDR 直接进入；RAW/SDR 按目标显影为 SDR 或 HDR | 亮度超出参考白才按 HDR 处理；SDR 输出表示 LUT 已完成其色调映射 |
| S-Log3 / S-Gamut3.Cine | RAW 解码、白平衡、色域转换与曝光之后，照片显影曲线之前 | RAW | 可以是 Log→Log，也可以是 Log→SDR 或 Log→HDR |

`rec709` 在 LUT 选项中明确表示 Rec.709 原色、Gamma 2.4 的显示编码。
它不等于 sRGB，也不表示 BT.709 摄像机 OETF；有其他约定的 LUT 应先转换或重新导出。
HLG/PQ 使用项目现有的 BT.2020 变换，以线性值 1 为 203 nit 参考白。
HLG 采用现有 1000 nit、系统 gamma 1.2 的显示映射。不同 HLG 系统假设的 LUT 不能假定
会产生相同结果。

HDR LUT 沿用照片声明或已经渲染的亮度范围，并计入曝光；RAW Log 路径使用曝光后的场景
峰值。将这个范围的中性峰值送入同一个 LUT，再结合调色后的实际像素亮度峰值，确定后续映射
使用的 headroom。HLG/PQ 的编码上限不被当成照片的 headroom；在可表达范围内，恒等 LUT
或只转换 HLG/PQ 编码的 LUT 保持原有范围，压高光的 LUT 则可以降低它。RAW/SDR 已在
LUT 前完成的 HDR 扩展不会在 LUT 后再次乘上 HDR 强度。

RAW/SDR 选择 HDR 输出并使用 HLG/PQ LUT 时，两份已显影的 SDR/HDR 图像分别进入
LUT，并各自进行必要的输出范围映射。SDR 底图不会从 HDR 再次反向生成；在 LUT
可表达的范围内，恒等 LUT 同时保持两份图像，实际调色 LUT 则分别改变它们。

纯 SDR 输出时，RAW/SDR 先得到 SDR 显影结果，再转换到 HLG/PQ 的信号编码供 LUT 采样，
不会先扩展 HDR 再压回 SDR。恒等 LUT 因而保留该 SDR 画面；如果 LUT 主动把亮度抬到参考白
以上，才对调色结果做必要的 SDR 高光映射。SDR 显影使用固定的肩部参数和零 HDR 扩展预算，
RAW 自动曝光也不再读取界面中隐藏的 HDR 范围、强度、扩展起点或大面积亮部参与设置。

若 HLG/PQ LUT 把整个亮度范围压到参考白或以下，结果按 SDR 范围处理。即使选择 HDR 容器，
也保留这个已经压缩的画面，不因为输入分类变化而再次扩展高光。

RAW→S-Log3 是对已校准、去马赛克的场景线性 RGB 进行色域和传递函数转换，不需要写出
一张低位深“灰图”。18% 灰对应 S-Log3 的 420/1023。转换采用 Sony 公布的
S-Gamut3.Cine 原色与 D65 白点；它不模拟某台 Sony 相机额外的专有成像风格。

HLG 则描述一种 HDR 图像信号。相机 HLG/HIF 已经包含白平衡、显影、色彩和高光处理的
决定，不能通过套用 Log 曲线恢复成 RAW。所以当前 S-Log3 输入入口明确要求 RAW。
也不能把 HLG 照片直接当成 S-Log3 数值送入相机 LUT。

Sony 的 [S-Log3 / S-Gamut3.Cine 技术说明](https://pro.sony/s3/cms-static-content/uploadfile/06/1237494271406.pdf)
提供了这里使用的传递函数、灰阶锚点和原色坐标。

## 颜色、高光和动态范围

- LUT 可以改变色相、饱和度、对比度和高光曲线。LUT 本身不会增加传感器捕获的信息，
  也不能恢复 SDR 文件里已截断的高光。
- 普通 SDR 风格 LUT 作用于已映射的 SDR 画面，HDR 版本共享调色结果并沿用亮度比例。
  这是一种明确的风格与亮度分离策略，不等同于把同一 LUT 当 HDR LUT 应用两次。
  手动渲染的亮度比例在接近黑位时平滑趋近 1，避免抬黑 LUT 在 HDR 中留下纯黑断层。
  AI/外部模型使用上文的原增益图重建规则，保留模型自身对黑位的增益和偏移。
- Log/HDR→SDR 的技术 LUT 可以压缩甚至截断原有高光。如果随后选择 HDR 输出，
  得到的是对该 SDR 结果的创作性扩展，不能宣称原始 HDR 层次被保留。
- 输入超出 LUT 的 DOMAIN 范围时采用边界采样；不进行无约束外推。作者制作的高光平台、
  通道截断、黑位平台或狭窄色域，都可能造成不可逆损失。
- 工作空间为线性 Display P3；进入 sRGB/Rec.709 LUT 时会做目标色域适配。
  最终 SDR JPEG 固定转换到 sRGB。选用窄色域 LUT 后不能期待宽色域颜色完全不变。
- 强度 0% 完全绕过 LUT；SDR 和 HDR 分别从各自的原始 RGB 在线性光中混合至完整调色
  结果，100% 完全采用调色结果。HDR LUT 改变亮度范围时，headroom 的线性倍率也随强度
  混合，避免极低强度就丢弃原有高光色彩或突然改变输出范围。
- 直接 HLG/PQ 编码保留渲染图像的空间细节。Adaptive / Ultra HDR 的单通道、低分辨率
  gain map 对细小高光和 SDR/HDR 色彩差异仍是近似表示；需要这种精度时应选择直出格式。
- 手动渲染保留显影时选定的扩展起点以下像素标记。增益图报告中的实际峰值、范围利用率
  和暗部相对变化在增益量化及双线性重建后测量；这不包含后续 JPEG/HEVC 有损编码误差。

## 使用

界面中先选择「仅调色」或「HDR 增强」，再打开照片。「仅调色」将颜色 LUT 置顶，
点击「浏览 LUT 库」导入或选用 `.cube`，调整强度后「保存 JPEG」。首次导入默认按 sRGB
处理，空间设置可展开并按 LUT 作者说明修改，不能视为自动识别。LUT 库在本机持久保存，
支持换照片复用；移出库不会删除照片会话内的副本。启用开关通过强度 0 绕过 LUT。
HDR 模式保留六种 HDR 输出格式与 LUT 调色。AI 模式支持 SDR 风格 LUT；Log/HLG/PQ LUT
使用手动渲染。模式切换保留已有调整，纯 SDR 时隐藏 HDR 扩展控件并明确显示 sRGB 输出。

```powershell
# 任意支持的照片来源，应用普通 sRGB 风格 LUT，只输出 SDR
HyperDR convert DSC02120.HIF --output graded-sdr --encoding sdr-jpeg --lut look.cube --lut-input srgb --lut-output srgb

# RAW，经明确的 S-Log3 / S-Gamut3.Cine → Rec.709 Gamma 2.4 LUT 显影
HyperDR convert photo.ARW --output graded-sdr --encoding sdr-jpeg --lut camera-look.cube --lut-input slog3-sgamut3cine --lut-output rec709

# 已有 HLG 照片，应用 HLG→HLG LUT，直接编码 HLG HEIC
HyperDR convert DSC02120.HIF --output graded-hdr --encoding hlg --lut hlg-look.cube --lut-input hlg --lut-output hlg

# 保持 SDR 兼容底图的 HDR 输出
HyperDR convert DSC02120.HIF --output graded-adaptive --encoding adaptive --lut look.cube --lut-strength 0.7
```

第一版读取独立 1D 或 3D `.cube`，支持标题、注释、DOMAIN 范围、INPUT_RANGE，以及
红通道最快变化的 RGB 表。3D 使用三线性插值。组合式 1D shaper + 3D 文件明确报错，
应从制作软件导出为单一 cube。现有 `--raw-linearization-lut` 仍仅用于传感器码值校准，
不接受它来代替 `--lut`。

## 实片验证

用户提供的 `DSC02120.HIF` 是 9504×6336、CICP 9/18/9 的 BT.2020 HLG HEIF，
没有 gain map。此次补齐了文件发现和选择列表遗漏的 `.hif` 扩展名。
验证文件和报告保存在本地 `output/lut-validation/`，不修改原片，也不纳入源代码提交。

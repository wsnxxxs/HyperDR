# 图像格式与 Lightroom 往返

HyperDR 接收 LibRaw 支持的相机 RAW，以及 JPEG、PNG、TIFF、HEIC/HEIF/HIF 和 AVIF。实际扩展名与文件头清单由 `schema/settings.json` 的 `inputs` 提供给桌面选择器和网页面板；仅修改文件名不能改变图像格式。

普通 TIFF 输入支持经典 TIFF 容器中的单层、条带式、连续排列的无符号 8 位或 16 位 RGB 和灰度像素。解码器读取嵌入的 ICC 配置文件，将色彩转换为内部线性 Display P3，并应用 TIFF/Exif 方向。无 ICC 时使用导入设置的默认色域。平铺、分平面、带 Alpha、CMYK、浮点与 BigTIFF 暂不支持；16 位整数 TIFF 按 SDR 处理，不会因位深被当作 HDR。

输出选择 `sdr-tiff` 会保存无损 Deflate 压缩的 16 位 RGB TIFF，嵌入 Display P3 ICC，并写入可用的 Make、Model、Artist、Copyright、DateTime 与 Software 标签。ISO、快门、光圈、镜头和 GPS 等标签目前不会完整转写。它是 SDR 成片，不含增益图；色域为 Display P3，并非 ProPhoto RGB。`sdr-jpeg` 输出为 8 位 SDR JPEG。HDR 交付仍使用 Ultra HDR JPEG、Adaptive HDR HEIC、PQ/HLG HEIC 或 PQ/HLG AVIF。

从 Lightroom Classic 送入 HyperDR 做 SDR 后续编辑，可导出 **16 位、ProPhoto RGB、嵌入 ICC 的 TIFF**；HyperDR 会读取 ICC 并转换色彩。网页上传的默认单文件上限为 512 MB，可用 `HYPERDR_MAX_UPLOAD_MB` 调整；桌面程序的本地路径导入无需复制或上传。若希望减少文件大小，16 位且嵌入 ICC 的 PNG 也可以使用。需要保留 HDR 时，可测试 Lightroom 的带增益图 JPEG 或 AVIF，但这不是已验证的无损 HDR 往返：JPEG 只有被 libultrahdr 识别为 Ultra HDR 才重建增益图；普通 Adobe XMP 增益图可能只读取 SDR 主图。AVIF 增益图导入取决于构建时的 libavif 支持及文件结构。应在导入后核对 `input_domain` 和高光显示，再用目标照片验证；普通 TIFF 和 PNG 不提供 HDR 增益图往返。

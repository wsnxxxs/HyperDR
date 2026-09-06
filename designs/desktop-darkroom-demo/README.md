# HyperDR 暗房工作台 · HTML Demo

独立的 HTML / CSS / JavaScript 交互演示，基于上一版概念图，按用户反馈将直方图常驻在右上角，提高参数区信息密度。没有修改现有产品前端。

## 打开

在项目根目录运行：

```powershell
python -m http.server 8765 --bind 127.0.0.1 --directory designs/desktop-darkroom-demo
```

浏览器打开 http://127.0.0.1:8765/ 。无构建步骤、无需安装 npm 依赖。通过本地 HTTP 服务打开，以便浏览器正常读取图像像素；不建议直接双击 HTML。

## 可以体验

- 固定在右上角的 RGB / 亮度直方图，基于当前图片的降采样像素计算。
- 原图 / HDR 示意 / 可拖动分屏，缩放和平移、裁切区域标记。
- 亮度、强度、范围、区域参数、高光恢复的演示反馈，撤销 / 重做 / 重置。
- 固定导出入口、三列两行的六种格式网格、当前色域 / 限缩到 sRGB 双选项、质量设置、演示进度和完成状态。
- 版本记录和恢复参数；更换照片后清空旧照片版本。
- 打开本地浏览器可解码图片，拖入图片，下载参数 JSON 和 SDR PNG。
- Ctrl O 打开、Ctrl E 导出、Ctrl Z 撤销、Ctrl Shift Z 重做；C 对比、F 适合窗口、Z 高光标记。

这是设计 demo：滤镜模拟视觉反馈，AI 按钮应用示例参数；不运行 HyperDR 或 AI 模型，不生成真正的 HDR 文件。格式、色域和质量用于演示配置，实际下载图像明确为 SDR PNG。参数 JSON 为演示快照，不是生产 CLI 配置。状态不持久化，刷新恢复示例。

照片是内置 ImageGen 生成的独立素材，提示词见 assets/landscape-prompt.txt。应用标识沿用项目资源。图标使用 [Phosphor Icons 2.1.2](https://www.npmjs.com/package/@phosphor-icons/web)，字体与许可保存在 assets/icons/，运行时不依赖外部 CDN。

## 布局

桌面为顶部固定工具栏、左侧摄影画布、右侧固定直方图 + 独立滚动参数、底部状态条。已移除左侧竖排工具按钮；格式、色域和质量仅在点击顶部“导出”后显示。导出窗口采用居中的横向双栏：左侧照片预览，右侧格式、色域与质量；当前色域排在限缩选项前。1280×720 仍能直接访问导出和三个主要调整项；大屏下展开作用区域。窄屏转为纵向排列。

截图：preview-desktop.png、preview-large.png、preview-export.png、preview-narrow.png。浏览器验证记录见 design-qa.md。

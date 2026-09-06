# 月弧：视觉平衡与材质精修

以用户当前选定的 `moon-curve-northeast-15deg.svg` 为基础，优化视觉平衡与月光效果。

- 保留朝向、尺寸和轮廓；主体左移 4 px、下移 18 px，缓解亮面与厚弧集中在右上方带来的偏重感。
- 调整银白表面的径向渐变，让右下侧逐渐转入蓝灰，降低外表面与内弧的色块分离感。
- 调整内弧明暗、减细轮廓高光并降低环境光晕，保持小尺寸轮廓清楚。

[moon-balanced.svg](moon-balanced.svg) 是本轮原稿；[comparison.svg](comparison.svg) 包含优化前后及 16 / 24 / 32 / 48 px 对照。PNG 均由 SVG 通过 resvg 渲染。

已检查 XML 解析并人工查看渲染对比。本轮仍为设计稿，未替换应用图标。

后续尺寸调整：[moon-balanced-larger.svg](moon-balanced-larger.svg) 将月弧主体围绕 `(252, 266)` 放大 10%，保持朝向、材质和底座不变。已解析 SVG 并查看 PNG 渲染，轮廓完整且保留边距。

后续位置调整：[moon-balanced-larger-offset.svg](moon-balanced-larger-offset.svg) 在放大版基础上向右、向上各移动 8 px。已解析 SVG 并查看渲染。

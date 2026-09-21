# 双模型接入复核与修复记录

2026-09-15 整理备注：本次测试会话、解码缓存及中间张量（约 101 MiB）已集中归档至
`C:/Users/Ryan/Desktop/HyperDR/.workbuddy/archive/20260915-review`，未永久删除。
`review-verification/report.json`、`review-results` 双模型导出样例及截图保留原位。
数值报告中的旧临时路径用于运行溯源；对应文件现位于归档目录，或可通过验收脚本重建。

复核日期：2026-09-14。范围为本地 HyperDR 开发版本；已修改源码、重编译原生程序，并通过真实浏览器操作验证。未修改模型权重，未提交、重置或整理原有 Git 索引。

## 结论

模型接入的数值实现基本正确，但原交付仍有影响实际演示的问题：选择器初始化报错、切换后复用上一模型的状态、解码缓存丢失 EXIF，以及模型选择在部分恢复路径中丢失。这些问题已修复。三个模型的名称和 ID 保持不变：

| ID | 界面名称 |
|---|---|
| `production-v3` | 原内置模型 · Production v3 |
| `research-cnn-v1` | 模型 1 · 纯图像 CNN |
| `research-exif-v1` | 模型 2 · 拍摄参数辅助增益预测 |

新照片保留用户当前选择；旧记录没有模型 ID 时仍还原为 Production v3。模型 2 缺少拍摄参数时，选择框保持模型 2，状态明确说明实际使用模型 1。

## 修复清单

| 问题 | 修复 |
|---|---|
| 选择器调用不存在的 `displayName()`，导致能力响应后的初始化异常 | 使用已有的 `modelLabel()`，补真实选择器挂载测试 |
| 手动模式中切换模型后，再点 AI 仍复用旧 gain 和旧身份；旧异步结果也可能覆盖新选择 | 模型变化始终清理缓存；用请求序号及输入身份屏蔽过期响应；新画面呈现前保持忙碌锁定 |
| 刷新、撤销、导出记录恢复时，模型 ID 或实际执行状态不完整 | 将模型纳入统一设置快照；恢复 AI 时重新取得实际身份；修复恢复函数把描述对象当成 ID 列表的问题 |
| 第二次解码丢失六项拍摄参数，模型 2 意外回退 | 解码缓存完整保存 presence 和数值；浮点值按可往返精度序列化；schema 8 升至 9，旧缓存自然失效 |
| AI 探测没有传入色域和 sRGB 限制，与预览／导出的输入约定不一致 | 前后端传递并校验 `colorGamut/clampSrgb`，加入推理合并请求的 key；输入改变会重新推理，保持当前 AI 模式 |
| 禁用 AI 仍探测可执行程序；无运行时也可能标记 ready；一般探测失败被当作旧版 | 先检查禁用开关，尊重原生 available 状态；只有明确不支持 `model-list` 才走旧版兼容；临时探测错误不缓存 |
| 模型设置签名没有显式包含模型及回退模型版本 | 使用规范 ID，并记录两个版本，避免模型更新后复用旧产物 |
| 导出记录难以区分同图不同模型 | 记录中显示模型名称；回退结果额外显示实际模型和缺失字段 |
| 验收脚本跳过两个单字段缺失用例的最终判断，只检验模型 1 的 CNN 转换 | 将缺失用例加入汇总；补模型 2 空间网络与 EXIF level 的完整组合对照；缺少必要参考时不得返回完整验收成功 |

主要修改位于 `apps/panel/web/js/preview/stage.js`、`settings/model-select.js`、`settings/schema.js`、`run/export-history.js`，以及 `apps/panel/hyperdr_panel/model.py`、`api.py`、`modules/app/src/decode_cache.cpp`、`fingerprint.cpp`。路径均相对于 `C:/Users/Ryan/Desktop/HyperDR`。

## 本次实测

### 自动化与原生构建

- Release 原生程序重编译成功，启用 ncnn。
- 6 个相关 C++ 测试通过：schema、decode_cache、native_model、cli、report、exif。
- Python unittest 共运行 183 项：182 项通过、1 项跳过。跳过的是本机无法创建符号链接的 session 用例；未修改该用例或 session 实现。
- 9 个 JavaScript runner 全部通过，包含新增的选择器挂载测试。
- `git diff --check` 通过。

### 数值与缓存

本次使用新编译程序、同一张 1024×688 float32 输入张量，对照 Windows 环境中的原始 checkpoint；阈值没有放宽。

| 项目 | 本次结果 | 验收阈值 |
|---|---|---|
| 模型 1，PyTorch / ncnn 最大误差 | `5.602836609e-5 stops` | `1e-3` |
| 模型 2，空间网络去均值加 sklearn level 后最大误差 | `6.954152735e-6 stops` | `1e-3` |
| EXIF level 最大误差 | `5.873979370e-8 stops` | `1e-5` |
| 缺 EXIF 回退与模型 1 的网格 | 逐值完全一致，最大差 `0.0` | 完全一致 |
| 冷／热解码缓存的模型 2 gain 包 | 字节完全一致，两次均 `exif_assisted` | 身份和输出一致 |
| 研究资产 manifest 哈希 | 所列资产全部匹配 | 全部匹配 |

EXIF 验证汇总含 14 个用例：8 个折内参数样本、2 个单字段缺失、0 EV、2 个树分裂阈值和高 ISO。模型 2 网格的**均值**等于 level；零输入仍可能因卷积边界产生空间变化，不能声称每个像素都恒等于 level。

机器可读数值记录：`.workbuddy/review-verification/report.json`（本机归档，未入库）。这些结果验证适配正确性，不代表模型质量、RAW 准确率或跨折泛化有提升。

### 真实界面

使用内置 Browser 技能执行实际点击、选择、导入和导出，补齐了原先缺失的界面验收，没有用直接 API 请求代替这部分操作。

- 同图模型 1／2 直接切换；手动 → 切换模型 → AI；刷新恢复；从模型 2 的导出记录恢复，名称和实际状态一致。
- 模型 2 导入 `no-exif.jpg` 后回退模型 1，并列出六个缺失字段，选择框仍保留模型 2。
- `zero-bias.jpg` 的曝光补偿为 0 EV，正常使用模型 2。
- AI 模式中切换导出 sRGB 限制，重新推理并保持模型 2；撤销恢复该选项。
- 同图同格式、无 LUT、相同 AI 微调参数，经界面完成两次 Adaptive HDR 导出，均 `self_verified=true`：

| 模型 | 实际模式 | 实测渲染峰值（线性倍率） | 输出 SHA-256 |
|---|---|---|---|
| 模型 1 | `pixel_only` | `7.72216` | `ab0b1a80b3ae3f443a76f1926e8e10aacca9a1dc89c2d39197285c6a3b01f8df` |
| 模型 2 | `exif_assisted` | `3.63327` | `28b3282e685457755e539955d2baadb5cc33e8e415cb5fb8170ce105443ff334` |

导出文件及对应原始 result 记录保存在 `.workbuddy/review-results`（本机归档，未入库）。不要把渲染峰值倍率与 gainMax stops 混为一谈，也不要用亮度更高来判断模型质量更好。

截图：[模型 1](research-model-review-assets/model1.png)、[模型 2](research-model-review-assets/model2.png)、[导出记录](research-model-review-assets/export-history.png)、[缺 EXIF 回退](research-model-review-assets/missing-exif-fallback.png)、[0 EV](research-model-review-assets/zero-bias.png)。截图用于确认交互、名称和状态，不能替代 HDR 显示设备上的亮度评价。

## 启动与边界

当前验证的是源码面板加新编译的原生程序，不是已安装的 Tauri 桌面包。已有桌面安装不会因源码修改自动更新。演示开发版可在 PowerShell 执行：

```powershell
Set-Location C:/Users/Ryan/Desktop/HyperDR
$env:HYPERDR_EXECUTABLE = 'C:/Users/Ryan/Desktop/HyperDR/build-release/Release/HyperDR.exe'
python apps/panel/hyperdr_gui.py
```

需要分发安装版时，再按 [桌面打包说明](../../apps/desktop/README.md)重建侧车和安装包；本次未覆盖安装目录或旧安装包。

参考验证仍要求 sklearn 1.8.0；运行 HyperDR 本身不需要 PyTorch 或 sklearn。研究模型仍是 fold 0 / seed 908，未改成集成或重新训练。

RAW 拍摄参数补齐依赖可识别的 EXIF/TIFF 头；当前不能把 Sony ARW 的既有冒烟结果扩展为全部 RAW 容器覆盖。非 TIFF 容器仍可能因字段缺失而走明确回退，本次没有加入新的 RAW 容器解析器。

另记录一个交接风险：检查时 `codex/research-model-selector` 尚无可解析的 HEAD 提交，索引呈现大量新增文件；不能据此声称其提交祖先已确认是旧记录中的 `3059f37`。本次保持分支、索引和无关改动不动，提交或合并前应先确认仓库历史。

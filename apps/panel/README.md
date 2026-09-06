# HyperDR 图形界面

一个纯标准库 Python 的本地网页控制台，用来直观地调用 `HyperDR` 转换器。
文件只上传到运行服务的这台电脑，不经过任何外部网络。

**一次一张。** 上传一张照片、看着实时 HDR 预览调参、转换、下载，然后换下一张。
每张照片的参数本来就该单独调，所以面板不做批量——要批量转换整个文件夹，
命令行的 `HyperDR convert --recursive` 才是对的工具。

## 启动

- **Windows**：双击项目根目录的 `Start.bat`，或在终端运行：
  ```
  python apps\panel\hyperdr_gui.py
  ```
- 浏览器会自动打开 `http://127.0.0.1:8756/?token=…`。关闭启动它的终端窗口即可停止。
- 服务默认绑 `0.0.0.0`，启动时会打印同一局域网内手机可用的地址。
- iPhone 上的 WebGPU 真 HDR 需要受信任的 HTTPS。双击一次 `Setup-HTTPS.bat`
  即可完成配置，详见 [`docs/iphone-lan.md`](../../docs/iphone-lan.md)。
  未配置时以 HTTP 启动，上传、转换、下载不受影响，实时预览退回 SDR 示意。

> 需要 Python 3.11 或更新版本。面板统一通过“保存到设备”下载结果，不依赖原生文件夹选择器。

## 目录结构

```
apps/panel/
  hyperdr_gui.py        启动器（处理 --pick 子进程、启动服务）
  hyperdr_panel/        后端包
    app.py              入口分派：--pick 子进程，或启动服务
    config.py           路径与平台标志
    schema.py           设置词表，读取 schema/settings.json（由转换器生成）
    command.py          面板控件 → HyperDR 命令行（全项目唯一的命令拼装处）
    executable.py       可执行文件探测
    session.py          一张图进、一个结果出，以及过期清理
    job.py              正在运行的那个转换进程，与浏览器轮询的日志
    native_preview.py   调用 preview-frame，校验并缓存线性 P3 float32 原生预览包
    model.py            原生嵌入模型的能力检测与 stdout packet 适配
    curve.py            色调曲线诊断接口的兼容封装
    concurrency.py      预览与模型进程共用的解码准入控制
    picker.py           原生 tkinter 文件夹对话框（独立子进程）
    api.py              HTTP 端点，写成可直接单测的纯函数
    security.py         口令、登录限流、响应头策略
    handler.py          HTTP 请求处理与路由
    server.py           端口、TLS、地址、启动
  web/                  前端唯一来源（原生 ES modules，无构建步骤）
    index.html          外壳；只用 data-role 标记挂载点，无内联事件
    css/                tokens / base / shell / components
    js/                 main.js 组合根，以及 core、i18n、settings、preview、run、ui
                        逐文件的说明见 web/README.md
```

前端的每个模块都是一个 `mount*` 函数，接收 store 和它需要的协作者，
只返回别的模块必须调用的东西——没有全局函数，`index.html` 里也没有 `onclick`。
浏览器控件的标签、读数格式和发往 `/api/run` 的选项对象由
`settings/schema.js` 这份 UI 声明驱动。它是浏览器适配层，不是转换器设置
词表的唯一来源；转换器新增或改名设置时，还要重新生成 JSON 并更新这里
的映射（如果该设置出现在界面中）。

`api.py` 与 `handler.py` 的分工是刻意的：端点逻辑不接触套接字，因此
`tests/python/test_api.py` 可以直接调用它们；`handler.py` 只保留必须有真实连接
的部分，小到可以按安全代码逐行审阅。

转换器的设置词表由 C++ 的 `schema.cpp` 维护。`HyperDR schema` 输出全部
设置的定义，`schema/settings.json` 是这份生成快照；Python 后端和 CI 的
契约检查读取它。浏览器的 `settings/schema.js` 只保留控件展示和请求映射，
因此界面新增设置时需要同步更新。

## 先决条件

界面只调用你本地构建好的 `HyperDR`。若尚未构建，先在项目根：
```
cmake -S . -B build -G Ninja -DCMAKE_TOOLCHAIN_FILE=<vcpkg>/scripts/buildsystems/vcpkg.cmake
cmake --build build --config Release
```
界面会自动在 `build/`、`build/Release/` 等位置找到它。
PQ / HLG 需要 Main10 x265；首次完整构建后按项目根 `README.md` 运行一次
`scripts/prepare_x265_multibit.ps1`。

## 能做什么

- 拖拽或点选一张 ARW、DNG、JPG、PNG、HEIC/HEIF、AVIF 照片。再选一张会替换掉它。
  HDR 输入（HLG/PQ 的 HEIC 与 AVIF、Ultra HDR JPEG）的高光会保留下来：转换器直接
  返回线性 Display P3 float32 的 SDR 底图与重建 HDR，不经过 8 位 JPEG 中间层。
- 六种导出格式：**Apple Adaptive HDR、Google Ultra HDR、PQ (HDR10)、HLG、AVIF PQ、AVIF HLG**。
- **整体亮度**在自动曝光之后做 0～+2 EV 偏移，默认 +0.6 EV，同时作用于 SDR 底图与 HDR 输出；每张新照片都会将全部画面调节恢复为默认值。
- **HDR 扩展强度**与 **HDR 扩展范围**；范围是实际亮度余量，Adaptive HDR 最高 3 stops，
  Ultra HDR / PQ 最高 4 stops，HLG 系最高约 2.3 stops（切换格式时自动钳制）。
- **扩展作用区域**给出扩展起点与区域覆盖，默认 25% / 100%，暗部与噪声保护始终启用。
- 高级参数里还有对比度、鲜艳度、高光恢复与编码质量。
- 转换完成后：所有设备都通过结果卡的“保存到设备”下载。

### 为什么没有这些开关

- **并行文件数、跳过已是最新的输出**——只在对一整个文件夹重跑时才有意义。
- **覆盖已存在的输出**——每次运行前会清空本次会话的输出目录，它从来没起过作用。
- **导出后校验**——它不是偏好。转换器在写盘*之前*把刚编码的字节解码回来验一遍，
  校验不过就不写文件。它拦的正是「文件能打开、但到手机上是普通 SDR」这类
  增益图引用写坏的错误，所以始终开启。
- **画面风格（渲染器）**——预览与导出都调用同一套摄影底图、真实增益图与 HDR 重建代码。
  `photographic` 目前是唯一的渲染器（旧的 `neutral` 已删除），面板固定使用它，不把这个
  值交给客户端。
- **命名预设**——预设是「一整套参数的快照」，而面板一次只处理一张图，
  每张图值得动滑块的地方本就不同；需要一套参数复用到一批图，那是命令行的活。

## 偏好设置

齿轮按钮在标题栏，主题开关右侧，快捷键 `Ctrl/⌘ + ,`。它和右栏是**两件不同的东西**：

- **右栏「调整」**——这一张照片的转换参数，会随 `/api/run` 发给转换器，
  每张新照片都恢复默认值。
- **「偏好设置」**——这台设备用起来的方式，一个参数都不会发给转换器。

偏好只存在当前浏览器的 `localStorage`（键 `hyperdr.prefs.v1`），因此**每台设备独立**。
这是刻意的：面板同时是局域网服务器，手机也连同一个进程，把偏好放到服务端会让一个人的
选择悄悄改掉另一个人的会话。

| 分组 | 项目 |
| --- | --- |
| 外观 | 主题（跟随系统 / 浅色 / 深色）、界面语言、动效 |
| 预览 | 预览分辨率上限、真 HDR 预览开关、直方图默认模式、默认斑马纹、载入后默认视图 |
| 输出 | 记住上次的输出格式与色域 |
| 调整 | 记住上次画面调节 |
| 诊断与关于 | 只读：处理服务、AI 模型、HDR 预览通道及降级原因、传输与安全上下文、上传/预览上限、支持的输入格式、运行环境 |

标题栏的主题按钮仍然是两态快捷操作（点一下就换到另一边）；要回到「跟随系统」
在偏好设置里选——旧的两态开关一旦点过就再也回不去了。

「记住上次画面调节」**默认关闭**。关着的时候每张新照片都从默认值开始，上一张的调整
不会悄悄带到下一张——这正是 `settings/schema.js` 一直以来的行为，开关只是把它变成
可选而不是绝对。开启后亮度、HDR 扩展等参数跨图片保留；换输出格式时 HDR 扩展范围
照样钳到该格式的上限，「重置」照样回到默认值。被 pin 起来的 `contrast` / `vibrance`
两个参数任何情况下都不写进快照，否则导出结果会和 `command.py` 的 `PANEL_DEFAULTS` 漂开。

### 服务端参数不在这里

工作目录、预览最大边长、AI 优化开关、会话清理间隔等等仍然只能用环境变量设置
（见 `docs/iphone-lan.md`）：它们在模块导入时就读进常量，而且是整个服务共享的。
诊断页会把这些值的**当前状态**显示出来，所以至少能看见生效的是什么。

### 界面语言

字符串目录在 `web/js/i18n/`：`index.js` 提供 `t()` / `applyStatic()` /
`onLocaleChange()`，`zh-CN.js` 是源目录，`en.js` 必须有完全相同的键。
标记法是 markup 里的 `data-i18n="key"`（填 textContent）与
`data-i18n-attr="aria-label:key;title:key"`（填属性），JS 里则是 `t("key")`。

切换语言**立即生效且不重载页面**——会话只存在内存里，重载会把已上传的图片丢掉。
各个视图都是 mount 一次然后自己改 DOM 的，所以它们通过 `onLocaleChange` 把自己
写过的字符串重新发一遍；已经飘在屏幕上的 toast 和已经滚过去的日志行保持原语言，
直到下次更新。

服务端错误在 `error` 之外多带一个稳定的 `code`（`api.error(..., code=...)`、
`Busy(..., code=...)`，或给异常挂一个 `.code`）。浏览器认得的 code 用本地文案，
不认得就原样显示服务端的句子，所以长尾消息不翻译也能用。

`scripts/check_panel_i18n.py` 在 CI 里守着这些：两个语言包键集必须一致，代码里
`t("...")` 和 `data-i18n` 引用的键必须存在，声明了没人用的键会失败。没有构建步骤，
拼错的键只会静默渲染成键本身，这个检查是唯一的防线。

## 界面与实时预览

- 图像优先布局：左侧大幅预览，右侧粘性控制栏，拖动滑块时预览始终可见。
- RAW 预览由转换器通过 LibRaw 做固定半尺寸解码，再按视口与设备像素比缩放到
  960 / 1440 / 2048 像素；纯 JavaScript CPU 呈现回退固定不超过 1280 像素。
  它不使用相机内嵌 JPEG，因此高光恢复设置会真实反映在预览中。
- **WebGPU 真 HDR** 通道（`rgba16float` + 扩展 Display P3），在 HDR 屏 + 受信任 HTTPS 下
  直接以超过参考白的亮度呈现。启用前会在当前浏览器中用正式 shader 渲染一组已知线性
  Display P3 像素并从浮点画布读回，只有配置确认为 `extended`、传递函数误差合格且红通道
  实际保留大于 1 的值时才启用；否则回退到 SDR 示意，并在指示灯上说明原因。
- `HyperDR preview-frame` 直接提供摄影 SDR 底图、真实增益图和重建 HDR 平面；浏览器只负责
  呈现，不再维护一份色调曲线或增益图近似。
- **直方图**（亮度 / RGB 可切换）叠加扩展起点标记，配合**高光/暗部裁切**读数与**斑马纹**；
  手机端默认折叠但保留裁切摘要。
  裁切是源画面的属性，只在载入时算一次。
- 预览可在适合窗口、100%、200% 与 400% 间切换；鼠标或触屏拖动检查高光过渡，
  不会把 WebGPU HDR 画布复制进 SDR 画布。
- 转换按钮下会即时显示最新一行处理日志；连接持续中断时会结束等待并明确报错。
- 桌面端按住图片看原图、松开恢复；触屏用「HDR ON/OFF」按钮切换。

> 说明：预览是观感示意。导出时转换器还会用 RAW 的高光信息、边缘感知的增益支撑和局部对比，
> 最终细节以 report 里的 `rendered_peak` 为准。

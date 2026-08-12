# HyperDR 图形界面

一个纯标准库 Python 的本地网页控制台，用来直观地调用 `HyperDR` 转换器。
文件只上传到运行服务的这台电脑，不经过任何外部网络。

**一次一张。** 上传一张照片、看着实时 HDR 预览调参、转换、导出，然后换下一张。
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

> 需要 Python 3.11 或更新版本。原生“选择导出文件夹”依赖 tkinter（Windows 官方 Python 自带），
> 且对话框只会弹在运行服务的这台电脑上——手机端改用“保存到设备”下载。

## 目录结构

```
apps/panel/
  hyperdr_gui.py        启动器（处理 --pick 子进程、启动服务）
  hyperdr_panel/        后端包
    config.py           路径与平台标志
    schema.py           设置词表，读取 schema/settings.json（由转换器生成）
    command.py          面板控件 → HyperDR 命令行（全项目唯一的命令拼装处）
    executable.py       可执行文件探测
    session.py          一张图进、一个结果出，以及过期清理
    job.py              正在运行的那个转换进程，与浏览器轮询的日志
    thumbnail.py        实时预览所依据的那张小 JPEG（RAW 走 LibRaw 半尺寸解码，
                        随高光恢复模式变化，不再取机内嵌入 JPEG）
    curve.py            向转换器索取色调曲线
    concurrency.py      curve 与 thumbnail 共用的进程准入控制
    picker.py           原生 tkinter 文件夹对话框（独立子进程）
    api.py              HTTP 端点，写成可直接单测的纯函数
    security.py         口令、登录限流、响应头策略
    handler.py          HTTP 请求处理与路由
    server.py           端口、TLS、地址、启动
  web/                  前端唯一来源（原生 ES modules，无构建步骤）
    index.html          外壳；只用 data-role 标记挂载点，无内联事件
    css/                tokens / base / shell / components
    js/                 main.js 组合根，以及 core、settings、preview、run、ui
                        逐文件的说明见 web/README.md
```

前端的每个模块都是一个 `mount*` 函数，接收 store 和它需要的协作者，
只返回别的模块必须调用的东西——没有全局函数，`index.html` 里也没有 `onclick`。
控件只在 `settings/schema.js` 声明一次，标记、读数格式和发往
`/api/run` 的选项对象都由这份声明驱动，因此三者无法各自漂移。

`api.py` 与 `handler.py` 的分工是刻意的：端点逻辑不接触套接字，因此
`tests/python/test_api.py` 可以直接调用它们；`handler.py` 只保留必须有真实连接
的部分，小到可以按安全代码逐行审阅。

设置词表不再由面板自己维护。`HyperDR schema` 输出全部设置的定义，
`schema/settings.json` 就是这份输出；改动设置后重新生成即可，CI 会检查两者一致。

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
  HDR 输入（HLG/PQ 的 HEIC 与 AVIF、Ultra HDR JPEG）的高光会保留下来：预览用一个
  2 的幂把线性值压进 8 位 JPEG，并通过 `X-Preview-Scale` 告诉浏览器乘回去。
- 六种导出格式：**Apple Adaptive HDR、Google Ultra HDR、PQ (HDR10)、HLG、AVIF PQ、AVIF HLG**。
- **整体亮度**在自动曝光之后做 0～+2 EV 偏移，默认 +1 EV，同时作用于 SDR 底图与 HDR 输出。
- **HDR 扩展强度**与 **HDR 扩展范围**；范围是实际亮度余量，Adaptive HDR 最高 3 stops，
  Ultra HDR / PQ 最高 4 stops，HLG 系最高约 2.3 stops（切换格式时自动钳制）。
- **扩展作用区域**给出扩展起点与区域覆盖，默认 25% / 100%，暗部与噪声保护始终启用。
- 高级参数里还有对比度、鲜艳度、高光恢复与编码质量。
- 转换完成后：桌面端自动拷进预先选定的导出文件夹，任何设备都可以“保存到设备”下载。

### 为什么没有这些开关

- **并行文件数、跳过已是最新的输出**——只在对一整个文件夹重跑时才有意义。
- **覆盖已存在的输出**——每次运行前会清空本次会话的输出目录，它从来没起过作用。
- **导出后校验**——它不是偏好。转换器在写盘*之前*把刚编码的字节解码回来验一遍，
  校验不过就不写文件。它拦的正是「文件能打开、但到手机上是普通 SDR」这类
  增益图引用写坏的错误，所以始终开启。
- **画面风格（渲染器）**——渲染器决定 `/api/curve` 画出来的曲线，能选它就能让预览和
  导出对不上。`photographic` 目前是唯一的渲染器（旧的 `neutral` 已删除），面板固定跑
  `--look photographic`，不把这个值交给客户端。
- **命名预设**——预设是「一整套参数的快照」，而面板一次只处理一张图，
  每张图值得动滑块的地方本就不同；需要一套参数复用到一批图，那是命令行的活。

## 界面与实时预览

- 图像优先布局：左侧大幅预览，右侧粘性控制栏，拖动滑块时预览始终可见。
- RAW 预览由转换器通过 LibRaw 做固定半尺寸解码，再按视口与设备像素比量化到
  960 / 1440 / 2048 像素；纯 JavaScript CPU 回退固定不超过 1280 像素。
  它不使用相机内嵌 JPEG，因此高光恢复设置会真实反映在预览中。
- **WebGPU 真 HDR** 通道（`rgba16float` + 扩展 Display P3），在 HDR 屏 + 受信任 HTTPS 下
  直接以超过参考白的亮度呈现；条件不满足时回退到 SDR 示意，并在指示灯上说明原因。
- 色调曲线由 `HyperDR curve` 提供，预览与编码器用的是同一条，不存在两份各自实现的近似。
- **直方图**（亮度 / RGB 可切换）叠加扩展起点标记，配合**高光/暗部裁切**读数与**斑马纹**；
  手机端默认折叠但保留裁切摘要。
  裁切是源画面的属性，只在载入时算一次。
- 预览可在适合窗口、100%、200% 与 400% 间切换；鼠标或触屏拖动检查高光过渡，
  不会把 WebGPU HDR 画布复制进 SDR 画布。
- 转换按钮下会即时显示最新一行处理日志；连接持续中断时会结束等待并明确报错。
- 桌面端按住图片看原图、松开恢复；触屏用「HDR ON/OFF」按钮切换。

> 说明：预览是观感示意。导出时转换器还会用 RAW 的高光信息、边缘感知的增益支撑和局部对比，
> 最终细节以 report 里的 `rendered_peak` 为准。

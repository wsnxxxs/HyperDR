# 面板前端

面板与 Tauri 桌面端共用的真实前端，服务于 `http://<host>:8756/`。

## 暗房工作区

沿用已确认的暗房操作布局，采用中性灰与蓝色强调色。顶部与侧栏构成连续应用框架，照片预览区内嵌于工作区；浅色模式使用中性浅灰画布。新设备默认深色，保留已有浅色与跟随系统偏好。

- 顶部集中打开照片、编辑状态、撤销/重做、导出记录、导出和偏好设置。次要操作是无边框按钮，只有「导出」是实色主按钮。照片名称、文件类型与大小放在画布上方，预览尺寸放在悬停提示里。
- 编辑状态区分三件事：「尚未导出 / 有未导出的调整」、「已导出 · 待保存」（成品还只在工作区里）和「已保存」（已保存到用户选择的位置）。点击它打开导出窗口。撤销或调整回到某个已导出版本的参数时，该版本自动成为当前结果，不会被当成新的未导出调整。
- 右栏在画面调整上方提供「仅调色 / HDR 增强」，空白页也可选择。仅调色将 LUT 面板置顶，隐藏 HDR/AI 控件，预览与「导出 JPEG」统一使用 SDR 输出；来回切换保留调色和 HDR 参数，重置不改变模式。模式沿用「记住输出设置」偏好。
- RAW 照片的「相机与镜头」（DCP 相机配置与镜头校正）是右栏最后一个折叠分组，标题行写明当前生效的配置。它按相机和镜头设定一次，不再排在画面调整之前把亮度与 HDR 滑块挤出首屏。
- 顶栏「LUT 库」打开与设置同风格的独立管理弹窗，支持搜索、多文件导入和移出库；这些操作不选择 LUT，也不改变照片。右栏仅通过「选择 LUT 风格」下拉框应用风格并调整强度。弹窗支持 Escape、遮罩和关闭按钮退出，并保持右栏布局与滚动位置。没有照片时也可管理库。侧栏显示简洁的空间摘要，点击「空间设置」打开独立小弹窗，不挤动侧栏与预览；初次导入按 sRGB 处理，可按作者说明修改；库会记住这些空间设置。库保存在工作目录的 `lut-library/`，换图、服务重启和照片会话过期不会清除。应用到照片时复制为会话资源，移出库不影响该照片的撤销或历史导出。
- 画布下方提供原图、调整后、分屏对比，以及适应窗口和缩放。缩放比例相对于适应窗口（100% 即适应窗口），在最小和最大比例时对应按钮不可用；滚轮以指针为中心缩放（触控板双指缩放在任何宽度都可用，普通滚轮只在桌面布局生效），放大后可拖动画面；对比、斑马纹和作用遮罩跟随同一图像变换。
- 长按与分屏对比的原图按效果图的正式预览档位获取；档位提高时重新获取原图细节，拖动滑块时保留高清原图。原图独立缓存，普通调参和长按不重复生成，也不会把低清缓存放大冒充高清预览。
- 直方图位于右栏顶部，随调整控件一起滚动；没有左侧工具栏或常驻输出面板。
- 调整控件统一使用中性色细轨道、数值框和分段按钮，不在每条轨道下再写两端刻度。数值框可直接输入：按显示的数字输入（百分比控件输入 25 即 25%），单位可省略，Enter 或离开确认、Escape 放弃、方向键按步长调整；「自动」控件可清空或输入「自动」。强度类参数统一以百分比显示。手动模式的作用区域默认展开且可折叠，AI 模式将次要参数收进细节微调；点击参数名称查看说明。
- AI 预览若生成失败（包括模型结果因服务重启失效），右栏切回手动调整并说明原因，不会在手动画面上继续标示「AI 优化已应用」。
- 颜色 LUT 未选择风格时只显示风格菜单；启用开关、强度和空间设置在选中风格后出现。库为空时给出「打开 LUT 库」入口。
- RAW 高光恢复统一使用混合（Blend），预览、AI 和导出使用相同策略，旧照片设置恢复时也统一为 Blend。它只处理 RAW 通道过曝，不是 HDR 扩展强度，界面不再提供模式切换；专业用户仍可通过 CLI 的 `--highlight-recovery` 选择算法。
- 导出采用横向双栏弹窗，六种格式排列为三列两行，每张卡片第二行写容器与关键特性（如「HEIC · 兼容 SDR」）；色域选项与质量滑块紧随其后。左栏列出这次导出的处理方式、格式、色域、质量与 LUT，结果卡放在其下，进度和导出操作放在横跨两栏的底部。
- 导出按钮随状态切换主次：没有导出或参数已变更时主按钮是「导出照片 / 导出新版本」；当前调整已导出时，「保存」成为主按钮，「再次导出」降为次要按钮。按钮不可用时，旁边写明原因（预览生成中、AI 优化中、未找到转换程序等）。导出进行中显示已用时间。
- JPEG / TIFF 通过 `outputGamut` 选择真正的 sRGB 或 Display P3 文件色域，默认分别为 sRGB / P3，像素转换与嵌入 ICC 保持一致；预览使用同一选择。HDR 的 `clampSrgb` 只限制颜色范围，不改变文件原色标记，也不会影响切换后的 SDR 导出。PQ / HLG 使用 Rec.2020。`colorGamut` 仍只指定无标记输入的默认解释，与输出色域独立。
- 保存方式为「固定文件夹」且文件夹可直接写入时，导出完成后自动保存到该文件夹；「每次询问」和「浏览器下载」仍在点击保存时选择位置。
- 顶部导出记录提供每个不可变版本的独立保存和参数恢复，并标出「与当前调整一致」和「已保存」；与当前调整一致的版本不需要再恢复参数。
- 快捷键：`Ctrl/Cmd O` 打开、`Ctrl/Cmd E` 导出、`Ctrl/Cmd ,` 偏好设置、`Ctrl/Cmd Z` 撤销、`Ctrl/Cmd Shift Z` 重做、`C` 分屏、`F` 适应窗口、`+` / `-` 缩放，焦点不在输入控件时按住空格查看原图。快捷键说明与提示按平台显示（Windows 为 `Ctrl+O`，macOS 为 `⌘O`）；弹窗支持 Escape 关闭与焦点约束。
- 空白工作区随主题变化，隐藏不可用的编辑控件、预览工具条和空直方图，侧栏显示三步导入引导。载入第一张照片时空白卡片变为进度说明（读取照片 → 生成预览）。打开照片后恢复完整调整区。
- 直方图在同一张图中叠加原图与调整后：原图为填充面积加虚线轮廓，调整后为清晰实线；仅保留亮度 / RGB 切换、图例和明暗刻度。
- 底部状态栏用一行说明照片类型与预览方式，例如「RAW · SDR 预览（屏幕不支持 HDR）· 导出不受影响」。
- 原图统计固定为首次载入的 SDR 底图，与画布比较基准一致。横轴位置固定，两组分布按样本总数归一化并共享高度比例，调参不会挤压原图横轴或重算基准。
- 顶栏高度 48px；Windows 窗口按钮使用居中的 40×30px 点击区域和细线图标，空白顶栏可拖动；浏览器与其他平台不显示这些窗口控件。
- 照片载入后，单击画布不再触发文件选择，长按比较原图，松开恢复原来的分屏或效果视图。

预览、AI 优化、直方图、转换和下载接入原有 native/API 流程。Demo 的 CSS 滤镜和模拟导出没有进入产品。


0.3.0 之前这里是 `apps/panel/static/` 的重写，在 `/next` 上与它并存开发：旧前端是唯一免费的对照组，每做完一块都能在同一个进程、同一份数据上逐项对比，而没写完的区域也不会挡住发版。0.3.0 用一个 commit 删掉旧目录，并把默认路由切到这里。

旧面板完整保存在 `v0.2.2` 标签里，任何时候可以取回单个文件作参考：

```
git checkout v0.2.2 -- apps/panel/static/js/preview/stage.js
```

## 界面一致性

- 桌面编辑器、设置与手机工作台共用 `css/tokens.css` 的中性灰、蓝色交互、字号和圆角；手机页跟随系统深浅色。
- 辅助说明使用 12px，控件文字 13px，正文 14px，页面标题 18px。紧凑工具按钮 32px，常规按钮 36px，手机触控按钮至少 44px。
- 导出、记录、快捷键和偏好设置使用同一遮罩、边框与标题栏间距。设置项的说明和控件成行排列，布尔偏好使用带标签的开关，窄窗口自动纵向排列。
- 独立启动页在本地服务就绪前显示，因此内嵌与桌面深色主题一致的基础值；修改公共配色时同步检查 `apps/desktop/ui/splash.html`。

## 技术选择

原生 ES module + 原生 CSS，**没有构建步骤**。改完刷新即可，`packaging/` 与 `Start.bat` 不需要任何改动。

代价是没有类型检查和依赖管理。需要时再单独引入 Vite，不要混在这次重写里。

## 目录

```
web/
├── index.html          顶栏、画布、固定直方图、调整区与导出弹窗
├── phone/              独立手机页面：index.html / app.js / style.css
├── css/
│   ├── tokens.css      唯一写字面颜色/圆角/时长的地方
│   ├── base.css        reset 与元素默认样式
│   ├── shell.css       应用框架布局
│   ├── components.css  原有功能组件（舞台、直方图、控件、结果与偏好）
│   ├── darkroom.css    暗房组件、横向导出弹窗与版本卡片
│   └── phone-workbench.css  手机工作台面板
└── js/
    ├── main.js         组合根：启动，然后把每个区域交给对应模块
    ├── core/           api.js（全部 HTTP 调用）、store.js（共享 UI 状态）、dom.js、
    │                   workspace.js（标签页记住哪张照片，刷新后由服务端解析会话）、
    │                   media.js（触控/粗指针媒体查询）、keys.js（按平台显示的快捷键标签）
    ├── i18n/           index.js（t / applyStatic / onLocaleChange）与语言包
    │                   zh-CN.js 是源目录，en.js 必须有完全相同的键
    ├── settings/       schema.js（控件展示/请求映射）与 controls.js（控件构建）、
    │                   history.js + history-controls.js（照片范围的撤销/重做）、
    │                   model-ids.js（可发送的模型 id 与配置兼容规则，无 import，可直接单测）、
    │                   model-select.js（按 /api/state 渲染模型选择，不在此处写死列表）、
    │                   lut-library.js（LUT 库弹窗）、workflow.js（仅调色 / HDR 增强）
    ├── preview/        stage.js（摄入/渲染器阶梯/分割对照）、scope.js（双分布直方图）、
    │                   histogram.js（固定摄影坐标的分箱，取自线性像素）、
    │                   mask.js（滑杆作用遮罩）、cpu/gpu/sdr-gpu 渲染器、session.js、
    │                   packet.js（v1 全平面与 v2「SDR 底图 + 编码增益」包解码）、
    │                   scheduler.js（只跑一帧，把指针移动合并成最新状态）
    │                   curve-math.js 是 C++ 色调曲线的移植，当前只被
    │                   tests/js/curve_math_runner.mjs 使用，不参与实时渲染
    ├── run/            runner.js（轮询、阶段进度、结果卡）、
    │                   options.js（导出参数与比较键：结果是否过期、哪一版与当前调整一致）、
    │                   save.js（编辑器/导出记录/手机共用的保存动作：能力分档、
    │                   状态机与保存反馈）、
    │                   export-history.js（选择不可变导出并恢复其参数）
    ├── ui/             editor.js（顶部操作/视图/导出弹窗）、toast.js、theme.js、prefs.js 与
    │                   prefs-schema.js（偏好表 + localStorage 校验）、
    │                   desktop.js（只有 Windows 外壳用到的窗口按钮）、
    │                   phone-workbench.js（手机交接面板与二维码）
    └── vendor/         qrcode.mjs（附 LICENSE），唯一的第三方前端代码
```

## 规矩

1. **服务端和前端一起维护。** 需要新增或调整接口时，同时更新 `apps/panel/hyperdr_panel/` 与 `apps/panel/web/js/core/api.js`，并用面板测试验证实际行为。
2. **颜色只写在 `tokens.css`。** 别处一律引用变量。旧样式表 1251 行里同一个灰写了四十多遍、还有三个略微不同的值，面板因此从来没和自己对齐过。画布像素要用的颜色（直方图、斑马纹、遮罩）以 `@property <color>` 注册后由 JS 用 `getComputedStyle` 读回，值仍然只住在 tokens.css。
3. **共享 UI 状态放在 `store.js`。** 视图订阅它；渲染器、定时器、请求
   epoch 等生命周期资源可以由所属模块局部持有，但不要把 store 字段再复制
   成没有必要的可变影子状态。
4. **不用 `<base>` 标签。** 面板的 CSP 设了 `base-uri 'none'`。资源用相对路径引用，这样这棵树也能直接从磁盘打开。
5. **`data-role` 用字面量查找。** `scripts/check_panel_roles.py` 做双向检查（声明 ↔ 读取），变量拼出来的角色名它看不见。
6. **焦点环走 `--focus`，不要直接写 `--accent`。** `base.css` 的 `:focus-visible` 读的是 `--focus`（默认等于 `--accent`）。浮在照片上的控件——对照分割手柄、裁切 chip、视图切换、全屏按钮——把 `--focus` 改写成 `--overlay-ink`，因为强调蓝对中性预览底色只有 2.7:1。另外**不要**在 `:root` 里把整条 ring 拼成一个 `--focus-ring` 变量：自定义属性里的 `var()` 是在*声明它的元素*上代换的，在 `:root` 拼好的 ring 会把 `:root` 的 accent 固化进去，下面所有改写都失效。两层阴影在每个用到的地方分别写出来。
7. **对比度按 AA 记账。** 12–13px 的次要文字（`--ink-muted`）、作为墨色使用的 `--accent`、以及作为文字的 `--warn` / `--danger` 都按 ≥4.5:1 选值，注释里记了实测比值。强调色分两个用途：`--accent` 是墨色与描边（深色模式下必须浅），`--accent-fill` 是承载白字的主按钮底色（白字 ≥4.5:1）；主按钮、开关等填充一律用 `--accent-fill`，不要把 `--accent` 当底色。改这几个值前先按新的背景重算一遍。`--hdr` 只做填充和直方图曲线，它作为浅色模式墨色只有 3.7:1，所以文字用 `--warn`。
8. **文案走目录，键要么是字面量要么登记为动态族。** markup 用
   `data-i18n="key"` 与 `data-i18n-attr="aria-label:key;title:key"`，JS 用
   `t("key")`；`settings/schema.js` 把键当数据存在 `label` / `help` /
   `choices` 里，`scripts/check_panel_i18n.py` 会把这些字面量一起校验。
   两个语言包键集必须一致，用不到的键会失败。拼错的键只会静默渲染成键本身，
   这个检查是唯一的防线。用变量拼出来的键（`ctrl.<key>.label`、
   `err.server.<code>` 等）它看不见，登记在脚本的 `DYNAMIC_PREFIXES` 里。

9. **视图 mount 一次，所以语言切换要自己推回去。** `setLocale()` 先跑
   `applyStatic()` 刷新 markup，再通知 `onLocaleChange` 订阅者；每个自己写过
   DOM 的模块（controls、stage、runner、scope、theme、prefs）在那里把当前状态
   重新发一遍。**不要**改成 `location.reload()`：会话只在内存里，重载会把用户
   已经上传的图片丢掉。已经飘在屏幕上的 toast、已经滚过去的日志行保持原语言，
   直到下次更新，无需为此重建整个渲染层。

10. **偏好是每台设备的，不进 `/api/run`。** `ui/prefs-schema.js` 的表存在
    `localStorage["hyperdr.prefs.v1"]`，读回时逐项按表校验。面板同时是局域网
    服务器，偏好放到服务端会让一个人的选择改掉另一个人的会话。
    右栏那些**是**转换参数，两者不要混。

11. **`group: "pinned"` 不是死代码，别删。** `schema.js` 里 `contrast` 与 `vibrance` 没有控件，但仍然进 store、进 `OPTION_KEYS`、进 `/api/run`。`curve-math.js` 拿 `contrast` 当参数，`stage/scope/mask` 都 watch 它——真删掉的话色调曲线会拿到 `undefined`。同时 `command.py` 的 `PANEL_DEFAULTS` 对这两个键的值与面板默认值一致，所以"面板不发送"和"面板发送默认值"导出结果相同；改任何一边前先对齐另一边。

## Recoverable editing workflow

`core/workspace.js` saves the current tab's session and validated settings and
restores them through `/api/workspace`. `settings/history.js` owns photo-scoped
undo/redo; `history-controls.js` binds buttons and shortcuts. `run/export-history.js`
selects immutable exports and reapplies their settings. The runner reconnects to
an active server job after refresh and preserves the previous result during retries.

Run `node tests/js/history_test.mjs` from the repository root for the editing
history behavior check, alongside the existing Python and frontend contract checks.

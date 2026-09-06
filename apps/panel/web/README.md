# 面板前端

面板唯一的前端，服务于 `http://<host>:8756/`。

0.3.0 之前这里是 `apps/panel/static/` 的重写，在 `/next` 上与它并存开发：旧前端是唯一免费的对照组，每做完一块都能在同一个进程、同一份数据上逐项对比，而没写完的区域也不会挡住发版。0.3.0 一次性完成切换 —— 一个 commit 同时删掉旧目录并把默认路由切到这里。

旧面板完整保存在 `v0.2.2` 标签里，任何时候可以取回单个文件作参考：

```
git checkout v0.2.2 -- apps/panel/static/js/preview/stage.js
```

## 技术选择

原生 ES module + 原生 CSS，**没有构建步骤**。改完刷新即可，`packaging/` 与 `Start.bat` 不需要任何改动。

代价是没有类型检查和依赖管理。如果哪天真的需要，再引入 Vite —— 但那要作为独立决定单独做，不要混在这次重写里。

## 目录

```
web/
├── index.html          外壳，三个区域的挂载点
├── css/
│   ├── tokens.css      唯一写字面颜色/圆角/时长的地方
│   ├── base.css        reset 与元素默认样式
│   ├── shell.css       应用框架布局
│   └── components.css  各区域组件（舞台、直方图、控件、输出块、结果）
└── js/
    ├── main.js         组合根：启动，然后把每个区域交给对应模块
    ├── core/           api.js（全部 HTTP 调用）、store.js（共享 UI 状态）、dom.js
    ├── i18n/           index.js（t / applyStatic / onLocaleChange）与语言包
    │                   zh-CN.js 是源目录，en.js 必须有完全相同的键
    ├── settings/       schema.js（控件展示/请求映射）与 controls.js（控件构建）
    ├── preview/        stage.js（摄入/渲染器阶梯/分割对照）、scope.js（双分布直方图）、
    │                   mask.js（滑杆作用遮罩）、cpu/gpu/sdr-gpu 渲染器、session.js
    │                   curve-math.js 是 C++ 色调曲线的移植，当前只被
    │                   tests/js/curve_math_runner.mjs 使用，不参与实时渲染
    ├── run/            runner.js（轮询、阶段进度、结果卡、下载）
    └── ui/             toast.js、theme.js、prefs.js（偏好浮层）与
                        prefs-schema.js（偏好表 + localStorage 校验）
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
7. **对比度按 AA 记账。** 12–13px 的次要文字（`--ink-muted`）、作为墨色使用的 `--accent`、以及服务状态的 `--warn` 都按 ≥4.5:1 选值，注释里记了实测比值。改这几个值前先按新的背景重算一遍——`--hdr` 只做填充和直方图曲线，它作为浅色模式墨色只有 3.7:1，所以文字用 `--warn`。
8. **文案走目录，键要么是字面量要么登记为动态族。** markup 用
   `data-i18n="key"` 与 `data-i18n-attr="aria-label:key;title:key"`，JS 用
   `t("key")`；`settings/schema.js` 把键当数据存在 `label` / `help` /
   `choices` 里，`scripts/check_panel_i18n.py` 会把这些字面量一起校验。
   两个语言包键集必须一致，用不到的键会失败——拼错的键只会静默渲染成键本身，
   这个检查是唯一的防线。用变量拼出来的键（`ctrl.<key>.label`、
   `err.server.<code>` 等）它看不见，登记在脚本的 `DYNAMIC_PREFIXES` 里。

9. **视图 mount 一次，所以语言切换要自己推回去。** `setLocale()` 先跑
   `applyStatic()` 刷新 markup，再通知 `onLocaleChange` 订阅者；每个自己写过
   DOM 的模块（controls、stage、runner、scope、theme、prefs）在那里把当前状态
   重新发一遍。**不要**改成 `location.reload()`：会话只在内存里，重载会把用户
   已经上传的图片丢掉。已经飘在屏幕上的 toast、已经滚过去的日志行保持原语言，
   直到下次更新——这是刻意的取舍，不值得为它重建整个渲染层。

10. **偏好是每台设备的，不进 `/api/run`。** `ui/prefs-schema.js` 的表存在
    `localStorage["hyperdr.prefs.v1"]`，读回时逐项按表校验。面板同时是局域网
    服务器，所以偏好绝不能挪到服务端——那会让一个人的选择改掉另一个人的会话。
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

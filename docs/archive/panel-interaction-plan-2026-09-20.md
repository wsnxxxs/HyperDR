# 面板交互逻辑优化方案（2026-09-20）

起点是两个具体问题：点击「保存到设备」没有任何反馈；保存路径无法在设置里定义，成品只能落进浏览器下载目录。排查下来这两件事同源，并牵出面板里同一类的其他交互缺口，一并写在第四节。

## 落地状态

第三节的 P0、P1、P2 已在同一轮里实现，第四节的第 1～5 条随之落地（保存有了常驻状态行，三个入口收敛到 `apps/panel/web/js/run/save.js`，保存位置进了偏好设置）。第四节第 6～8 条（灰按钮不说明原因、「停止等待」之后没有出口、toast 作为唯一反馈通道）**未实施**，仍然成立。

第一轮复核修掉的问题：toast 进入 top layer 后丢失了淡入淡出和读屏播报；「每次询问」会把这一次选的文件夹写成「固定文件夹」偏好；选择盘符根目录会让标签为空、从而被当成「尚未选择文件夹」；每次保存都会往用户文件夹里写一个探测文件；手机端按钮文案从「保存到手机」退回成「保存到设备」。同时新增 `tests/python/test_export_target.py`，并把手机前端纳入 `scripts/check_panel_i18n.py` 与 `scripts/test.py frontend` 的扫描范围。

第二轮复核又修掉两处，都是第一轮引入的：进程级的「最后保存位置」让偏好设置里的「打开文件夹」在一次性保存之后指向临时目录，早先那条保存记录的按钮也会跳到后来那次的目录——改成每次保存签发一个不含路径的 `openToken`，按钮定位到自己那次的目录，偏好设置则明确打开记住的那个；`folder_label()` 为了让短路径有标签而直接回传了完整绝对路径，违反「只回传短标签」的约定——短路径改为同样省略锚点，「文件夹是否设过」继续由 `exportFolderReady` 这个布尔回答。专项测试现为 15 例。

下面第六节列的未验证项仍然有效，另外补充：`cargo check` 通过（含 Tauri capability 校验），但没有重新打包桌面安装器，也没有在真实 WebView2 窗口里跑过一次保存。

## 一、根因：三层，缺一层都修不好

### 1. 模态对话框把 toast 压在下面

「保存到设备」这个锚点在导出对话框内（`apps/panel/web/index.html:262`），父级是 `<dialog data-role="export-dialog">`，由 `apps/panel/web/js/ui/editor.js:87` 的 `showModal()` 打开。`showModal()` 会把 dialog 提升到 **top layer**，top layer 画在所有普通流内容之上，**与 z-index 无关**。

toast 是 body 末尾的普通元素（`apps/panel/web/index.html:335`），靠 `z-index: 1100` 浮起（`apps/panel/web/css/components.css:927`）。

结论：只要有模态对话框打开，任何 toast 都画在对话框和它的 `::backdrop` 底下。当前 5 个 `showModal()` 调用点全部受影响——导出对话框、导出记录、LUT 库、LUT 色彩空间、快捷键。

影响不止保存：「转换成功」「转换失败」「已复制命令行」都是在导出对话框开着的时候发的，同样看不见。也就是说，**现在直接给保存动作加一个 toast，用户依然什么都看不到**。这一层必须先修。

（`role="status" aria-live="polite"` 仍会被读屏播报，所以这是纯视觉缺陷，现有的 role/i18n 检查和 JS 测试都测不出来。）

两种修法：

- **A. 让 toast 也进 top layer**：`<div popover="manual">` 或一个空 `<dialog>`，显示时 `showPopover()`。只动 `js/ui/toast.js` 和一条 CSS，一处改动覆盖全部 5 个模态面，且不依赖调用顺序。
- **B. 把 toast 节点挂进当前打开的 dialog**：显示前 `append` 到 `document.querySelector("dialog[open]") ?? document.body`，关闭时搬回。需要处理嵌套和搬迁时机。

推荐 A。不支持 popover 的引擎退回现有 fixed 定位，不会比现状更差。

### 2. 保存是一个裸 `<a download>`，应用层没有状态

`apps/panel/web/index.html:262` 是纯锚点，唯一的 JS 触碰是 `apps/panel/web/js/run/runner.js:76` 换 `href`。没有 click 事件、没有 store 字段、没有成功/失败分支。后果：

- 下载交给浏览器，面板对结果一无所知。`<a download>` 失败**不抛错、不触发任何事件**。
- 桌面壳是无边框 WebView2（`apps/panel/web/js/ui/desktop.js:6` 的 `__HYPERDR_FRAMELESS__`），浏览器自带的下载条/下载按钮在这个窗口里没有落脚处，连「浏览器给的那点反馈」也没有了。
- 最终文件名由 `Content-Disposition` 决定（`apps/panel/hyperdr_panel/handler.py:151`），面板不知道落盘叫什么，自然也说不出「已保存 xxx」。

### 3. 三个保存入口各写一份

结果卡片一份（`index.html:262`），导出记录里每个版本一份（`apps/panel/web/js/run/export-history.js:42`），手机端还有一份（`apps/panel/web/phone/app.js:53`）。反馈和路径改造如果不先收敛成一个模块，就会只修好其中一个。

## 二、保存位置：按能力分三档，按钮只有一个

成品本身在服务端工作区：`hdr-workspace/<session>/output`，打包版在 `%LOCALAPPDATA%\HyperDR\`（`apps/panel/hyperdr_panel/session.py:28`）。`/api/result` 只是把它当附件发出来，所以「落进下载目录」不是选择，是目前唯一存在的机制。

| 档 | 条件 | 行为 | 按钮文案 |
| --- | --- | --- | --- |
| T2 原生目录 | 桌面壳 + 回环 | 服务端直接把成品写进用户选定的文件夹 | 保存到文件夹 |
| T1 文件系统访问 | 安全上下文且支持 `showSaveFilePicker` | 浏览器原生「另存为」，可记住目录句柄 | 另存为… |
| T0 浏览器下载 | 其余（手机、Safari、Firefox、HTTP） | 现状行为 | 保存到设备 |

编辑器永远绑在回环上（`apps/panel/hyperdr_panel/security.py:1`、`server.py:198`），所以 `127.0.0.1` 是安全上下文，T1 在 Chromium 系可用；手机走 LAN，非 HTTPS 时落到 T0——那也正是「保存到设备」这句话唯一成立的场合。

### T2 的做法：对称于已有的 nativePathInput

仓库里已经有一条成熟通道，可以照抄它的规矩：

- 能力位 `nativePathInput = desktop and loopback`（`apps/panel/hyperdr_panel/server.py:164`）
- 路由 `POST /api/native-input` 第一件事就是校验该能力位（`apps/panel/hyperdr_panel/api.py:306`）
- 注释写明绝对路径不回传给浏览器（`apps/panel/hyperdr_panel/api.py:317`）

输出方向：

- 新能力位 `nativePathOutput`，同样是 `desktop and loopback`，随 `/api/state` 下发（`api.py:170`）
- `POST /api/export-folder`：只接受桌面壳提交的路径，服务端校验（存在、是目录、可写、不在工作区内），持久化；返回**用于显示的短标签**（如 `…\Pictures\HyperDR`），不回传完整路径
- `POST /api/save-to`：`{sessionId, exportId}`，服务端从 `renditions.result_path()` 复制到该文件夹，处理重名（`name (2).heic`），返回落盘文件名
- 目录**只能**由桌面壳的原生选择器产生，Web 端永远不允许提交路径字符串

安全边界要写死：三个入口都先过 `nativePathOutput`。面板是有意对 LAN 开放的服务（`security.py:1`），让任意客户端指定服务端写盘位置等于送上门一个任意写入。

桌面壳侧需要 `tauri-plugin-dialog`（`apps/desktop/src-tauri/Cargo.toml` 目前只有 `tauri-plugin-shell`），并在 `capabilities/panel-window.json` 给远程 `http://127.0.0.1:*/*` 加对应权限。这是本方案唯一要动 Rust 和重新打包的部分，因此排在最后。

### 偏好设置怎么摆

`output` 组现在只有 `rememberOutput` 一个开关（`apps/panel/web/js/ui/prefs-schema.js:64`）。加两项：

- `saveTarget`（segmented）：每次询问 / 固定文件夹 / 浏览器下载目录——只显示当前设备够得着的档
- 固定文件夹那一行：显示当前目录标签 +「更改…」+「打开文件夹」

注意 `prefs-schema.js:1-17` 立的规矩：偏好是**每设备**的，服务端范围的东西走环境变量。导出文件夹是真·服务端状态，所以它**不**进 localStorage 快照，而是由 `/api/state` 下发、偏好面板只做展示和触发；`saveTarget` 本身是每设备偏好，留在 localStorage。这条不分清楚，手机连上来会看到一个它根本用不了的路径。

## 三、落地顺序

### P0：纯前端，无新依赖，修掉「没有反馈」

1. toast 进 top layer——`js/ui/toast.js` + `css/components.css:909` 一带
2. 新建 `js/run/save.js`，导出一个 `saveExport({sessionId, exportId, name})`：内部做能力探测、状态机、错误分支，成为唯一的保存实现
3. 结果卡片接上它：`index.html:261` 的 `<a>` 换成 `<button data-role="save">`，并加一行 `data-role="save-state"` 常驻状态（不是 3 秒就消失的 toast）
   - 空闲 →「保存到设备 / 另存为… / 保存到文件夹」
   - 进行中 → 按钮 disabled +「保存中…」
   - 成功 →「已保存 · 文件名.heic」，T1/T2 再加「打开文件夹」
   - 失败 → 给出原因 + 可重试
4. 导出记录（`export-history.js:42`）改调同一个函数
5. 中英文键同步进 `i18n/zh-CN.js` 与 `i18n/en.js`（`scripts/check_panel_i18n.py` 会拦两边不一致）；新 `data-role` 必须同时出现在 markup 和模块的字面量里（`scripts/check_panel_roles.py`）

T0 档怎么拿到「成功」信号：不再用 `<a download>`，改成 `fetch(resultUrl)` → `blob` → `createObjectURL` → 程序化点击 → `revokeObjectURL`。这样 HTTP 错误、会话过期、磁盘满都能 catch 到，代价是成品先进一次内存（单张照片可接受）。要保守的话先 `HEAD` 看大小，超阈值退回直链并明说「已交给浏览器下载」。

### P1：前端 + 少量服务端，把路径变成可选

6. T1：`showSaveFilePicker` 直写；`showDirectoryPicker` 的句柄存 IndexedDB，下次 `queryPermission` 静默复用，失效时在点击手势里 `requestPermission`
7. 偏好 `output` 组加 `saveTarget` 与目录行
8. `/api/state` 加 `nativePathOutput`（此时恒为 false，前端先按能力位写，避免以后再改一遍）

### P2：桌面壳，需要重新打包

9. `tauri-plugin-dialog` + capability + 一个返回所选目录的命令
10. `/api/export-folder`、`/api/save-to` 落地，`nativePathOutput` 真正打开
11.「打开文件夹」只在 T2 显示

## 四、不只是这一个：同类交互缺口

按收益排序，都是这次排查顺手看到的实处，不是泛泛建议。

1. **「已导出」被当成「已保存」**。主界面徽章判定的是「当前参数 == 上次导出的参数」（`js/ui/editor.js:65`），文案是「当前调整已导出」（`i18n/zh-CN.js:112`）。此刻成品还躺在服务端工作区，用户一个字节都没拿到。建议拆成两个状态：**已导出**（有成品）与**已保存**（落到用户选的位置），徽章显示后者。这才是「保存没反馈」在心智上的真正代价。
2. **导出完成后动线断在对话框里**。`showModal()` 之后没有收尾（`editor.js:86`）。建议转换成功后对话框自身变成完成页：成品信息 + 保存 +「继续调整 / 关闭」，保存成功后才给一键关闭。
3. **关掉对话框就没有保存入口**。主界面只剩「导出记录」（`index.html:41`）。结果卡片（或一条轻量成品条）应当留在主界面，而不是只活在导出对话框里。
4. **导出记录里每版一个裸 `<a>`**（`export-history.js:42`）：同 P0 第 4 步收敛。
5. **手机端「保存到手机」同样是裸 `<a>`**（`phone/app.js:53`）。手机上更需要明确反馈——iOS Safari 的下载提示极不显眼。至少给一行常驻状态。
6. **主按钮为什么不能点，界面不说**。`runner.js:138` 用 7 个条件合成 `disabled`，用户只看到一个灰按钮。建议显示当前**第一个**未满足的条件：未选照片 / 预览未就绪 / 转换程序未就绪 / 正在转换。
7. **「停止等待」之后没有出口**。提示说服务端任务可能还在后台跑（`runner.js:317`），但界面不提供重新接管或查看的入口，状态就此悬空。
8. **toast 是唯一反馈通道**，3 秒 / 9 秒后消失（`js/ui/toast.js:9`）。凡是「产生了一个用户之后要去找的东西」的操作（保存、导入 LUT、恢复参数），都该有一个不消失的落点；toast 只留给纯提示。

## 五、验收

- 五个模态面各开一个并触发 toast，都要能看见。这条现在必然失败，正好作为 P0 的前后对比基准。
- 保存成功：按钮回到空闲、状态行显示文件名、文件确实在目标位置。
- 保存失败（停服务、删成品、只读目录）：状态行给出原因，按钮可重试，不会卡在「保存中」。
- 会话过期后点保存：走 401/404 分支，提示重新导出，而不是静默失败。
- 手机（HTTP，非安全上下文）：档位落到 T0，文案仍是「保存到设备」，且有可见反馈。
- `scripts/check_panel_roles.py`、`scripts/check_panel_i18n.py` 与 `tests/js/` 全通过。
- 偏好里选定文件夹后重启面板，选择仍在；另一台设备连上来看不到也用不了这个路径。

## 六、本方案未验证的部分

- 「toast 被模态盖住」是从 `showModal()` 的 top layer 语义、toast 的 DOM 位置和 z-index 推出的，**未在运行中的面板里实拍确认**。实施前先手工复现一次，作为 P0 的对比基准。
- 未确认 WebView2（Tauri 2）里 `showSaveFilePicker` / `showDirectoryPicker` 是否可用，也未确认无边框窗口下 WebView2 默认下载 UI 的实际表现。T1 落地前必须在桌面壳里实测，否则能力探测会把用户送进一个不会弹窗的分支。
- 未测量 blob 中转对大成品的内存开销。
- 桌面壳的 `tauri-plugin-dialog` 权限写法未经编译验证。
- 未改动代码，未运行测试；以上行号对应工作区当前状态。

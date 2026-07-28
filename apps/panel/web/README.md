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
│   └── components.css  各区域组件（舞台、直方图、控件、dock、结果卡）
└── js/
    ├── main.js         组合根：启动，然后把每个区域交给对应模块
    ├── core/           api.js（全部 HTTP 调用）、store.js（唯一可观察状态）、dom.js
    ├── settings/       schema.js（控件单一声明）与 controls.js（控件构建）
    ├── preview/        stage.js（摄入/渲染器阶梯/分割对照）、scope.js（双分布直方图）、
    │                   mask.js（滑杆作用遮罩）、curve.js、cpu/gpu/sdr-gpu 渲染器、session.js
    ├── run/            runner.js（轮询、阶段进度、结果卡、导出）
    └── ui/             toast.js、theme.js
```

## 规矩

1. **服务端契约是冻结的。** 见 `docs/panel-api-contract.md`。需要新字段就先在 `main` 上改服务端和契约，再把 `main` 合并回来。
2. **颜色只写在 `tokens.css`。** 别处一律引用变量。旧样式表 1251 行里同一个灰写了四十多遍、还有三个略微不同的值，面板因此从来没和自己对齐过。画布像素要用的颜色（直方图、斑马纹、遮罩）以 `@property <color>` 注册后由 JS 用 `getComputedStyle` 读回，值仍然只住在 tokens.css。
3. **状态只放在 `store.js`。** 视图订阅它，本身不持有状态。
4. **不用 `<base>` 标签。** 面板的 CSP 设了 `base-uri 'none'`。资源用相对路径引用，这样这棵树也能直接从磁盘打开。
5. **`data-role` 用字面量查找。** `scripts/check_panel_roles.py` 做双向检查（声明 ↔ 读取），变量拼出来的角色名它看不见。

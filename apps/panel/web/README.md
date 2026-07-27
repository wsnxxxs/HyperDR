# 面板前端重写（`/next`）

这是 `apps/panel/static/` 的替代品，在 `feat/panel-rewrite` 分支上与它**并存**开发。

- 旧面板：`http://<host>:8756/` —— 始终可用，始终可发布
- 新面板：`http://<host>:8756/next/`

## 为什么并存

旧前端是唯一免费的对照组。每做完一块，都能在同一个进程、同一份数据上和它逐项对比；任何一个区域没写完也不会挡住 `main` 上的发版。

删除 `static/` 只在最后一次性发生 —— 一个 commit 同时删掉旧目录并把默认路由切到这里。回滚就是 revert 那一个 commit。

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
│   └── shell.css       应用框架布局
└── js/
    ├── main.js         入口：启动，然后把每个区域交给对应屏幕
    └── core/
        ├── api.js      全部 HTTP 调用
        └── store.js    唯一的可观察状态
```

## 规矩

1. **服务端契约是冻结的。** 见 `docs/panel-api-contract.md`。需要新字段就先在 `main` 上改服务端和契约，再把 `main` 合并回来。
2. **颜色只写在 `tokens.css`。** 别处一律引用变量。旧样式表 1251 行里同一个灰写了四十多遍、还有三个略微不同的值，面板因此从来没和自己对齐过。
3. **状态只放在 `store.js`。** 视图订阅它，本身不持有状态。
4. **不用 `<base>` 标签。** 面板的 CSP 设了 `base-uri 'none'`。资源用相对路径引用，这样这棵树也能直接从磁盘打开。
5. **区域可以是空的。** 没写完的地方保留占位符，去和 `/` 上的旧面板对比，而不是先塞一个半成品进去。

## 切换默认（cutover 时做，现在别做）

1. `apps/panel/hyperdr_panel/config.py`：`STATIC_DIR = GUI_DIR / "web"`
2. `handler.py`：删掉 `_serve_web`、`WEB_ROUTE_PREFIX` 与 `/next` 分支
3. `git rm -r apps/panel/static`
4. `packaging/` 里所有 `static` 路径改为 `web`
5. CHANGELOG 写明 breaking，打 `v0.3.0`

旧代码在 `v0.2.2` 标签里完整保存，任何时候可以取回：

```
git checkout v0.2.2 -- apps/panel/static/js/preview/stage.js
```

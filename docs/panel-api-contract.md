# 面板 HTTP 接口契约（重写期冻结）

这份文档记录 `apps/panel/hyperdr_panel/api.py` 与 `handler.py` 在 **v0.2.2** 时刻的全部对外行为。

**它存在的唯一目的**：让前端重写有一个不会移动的靶子。重写期间前端可以任意改变自己的组织方式，但不得要求服务端改变应答的形状。如果新界面确实需要一个现在没有的字段：

1. 先在 `main` 上改服务端和本文档，并保证旧面板仍然通过；
2. 再把 `main` 合并进 `feat/panel-rewrite`。

绕过这条路径，重写就会同时变成后端重写，两边都无法单独发布。

> 注意：这些路由是内置面板的实现细节，不是公开集成接口。本文档冻结的是重写期间的稳定性，不是长期兼容性承诺。

---

## 通用约定

| 项目 | 约定 |
| --- | --- |
| 鉴权 | Cookie `hyperdr_access`（`HttpOnly; SameSite=Strict; Path=/`）。缺失或不匹配一律拒绝。 |
| 失败应答 | 任意非 2xx 状态 + `{"error": "<中文消息>"}`。消息面向用户，可直接显示。 |
| POST 来源 | 强制同源检查，不同源返回 403。 |
| 请求体上限 | 1 MiB（上传除外，走独立路径）。 |
| 缓存 | 所有应答带 `Cache-Control: no-store`。 |
| CSP | `default-src 'self'`，且 **`base-uri 'none'`** —— 前端不能使用 `<base>` 标签。 |

`error` 也可能出现在 200 应答里，客户端必须同时检查状态码和 `error` 字段。

---

## GET `/api/state`

启动时读一次。进程存活期间这些值不变。

```json
{
  "ready": true,                          // 找得到 HyperDR 可执行文件
  "os": "windows",                        // "windows" | "posix"
  "nativeOutputPicker": true,             // 仅 Windows 为 true
  "secureContextExpected": true,
  "transportSecure": true,
  "hdrPreviewRequiresSecureContext": true,
  "previewMaxEdge": 2048,                 // thumbnail.MAX_EDGE
  "maxUploadMB": 256                      // 受 HYPERDR_MAX_UPLOAD_MB 影响
}
```

## GET `/api/preview`

预览用的小图，**不是 JSON**。

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `id` | 是 | 会话 id |
| `hr` | 否 | 高光恢复模式，取值必须在 `schema.SETTINGS["highlight_recovery"]["choices"]` 内 |
| `edge` | 否 | 最长边像素，`320 ≤ edge ≤ previewMaxEdge` |

成功返回图片字节，并携带响应头 `X-Preview-Width`、`X-Preview-Height`、`X-Preview-Max-Edge`。前端应从这些头读取尺寸，而不是解码后再量。

`hr` 参与请求是因为它改变 RAW 解码本身：同一文件在两个模式下是两张不同的预览。

失败：`400` 参数非法，`404` 图片缺失或损坏，`429`（`Busy`）解码器忙，可重试。

## GET `/api/log`

| 参数 | 说明 |
| --- | --- |
| `id` | 任务 id |
| `offset` | 上次返回的 `offset`，首次传 `0` |

```json
{
  "text": "...",        // 从 offset 起的增量日志
  "offset": 12034,      // 下次轮询传回这个值
  "logStart": 0,        // 已丢弃的前缀长度
  "done": false,
  "rc": null,           // 结束后为进程返回码
  "report": null,       // 结束后为报告 JSON
  "sessionId": "…",
  "cancelled": false,
  "timedOut": false,
  "truncated": false    // 日志被截断，或请求的 offset 已低于 logStart
}
```

`404` 表示这不是当前任务（同一时刻只有一个任务）。

## GET `/api/result`

转换产物本身。`id` 为会话 id；`download=1` 时以 `Content-Disposition: attachment` 送出。

手机上原生文件夹选择器不可达，保存只能交给浏览器，`download=1` 就是为这条路径存在的。

`404` 表示会话无结果。

---

## POST `/api/session`

无请求体。`201` → `{"sessionId": "<32 位十六进制>"}`

## POST `/api/upload`

**唯一不收 JSON 的 POST。**

- 查询参数：`id`（会话）、`name`（原始文件名，URL 编码）
- 请求头：`Content-Type: application/octet-stream`
- 请求体：文件原始字节，流式写入，上限 `maxUploadMB`

`201` → `{"name": "<落盘文件名>", "bytes": 12345}`

转换运行期间上传会被拒绝（换掉输入会让转换器脚下的文件变掉）。

因为 `fetch` 至今无法报告请求进度，前端需用 `XMLHttpRequest` 才能画出进度条。

## POST `/api/command`

```json
{ "options": { … } }
```

→ `{"argv": [...], "command": "HyperDR --input \"…\" …"}`

路径以 `<已上传图片>`、`<任务输出>` 占位。由运行时同一个 `build_argv` 生成 —— 这是面板显示的命令行可信的唯一原因。

## POST `/api/curve`

```json
{ "options": { … }, "samples": 257 }   // 2 ≤ samples ≤ 4096
```

→ `look_curve()` 的载荷。`429` 表示忙。

## POST `/api/run`

```json
{ "sessionId": "…", "options": { … } }
```

→ `{"jobId": "…", "argv": [...], "command": "…"}`

`argv[0]` 已被替换为 `"HyperDR"`：可执行文件的真实路径不是浏览器该知道的。

上一次的产物在本次开始前被清除，因此改变编码格式不会留下旧扩展名的残留文件。

`429` 表示已有任务在跑。

## POST `/api/cancel`

`{"jobId": "…"}` → `{"cancelled": true|false}`

## POST `/api/select-output`

无请求体。在**运行服务的那台机器**上弹出原生文件夹对话框，因此仅 Windows 可用（见 `state.nativeOutputPicker`）。

- 选中 → `{"selectionId": "…", "path": "D:\\出片", "name": "出片"}`
- 取消 → `{"cancelled": true}`

路径永远不从浏览器接收，只接收这里签发的 `selectionId`。

## POST `/api/export`

```json
{ "sessionId": "…", "selectionId": "…" }
```

→ `{"path": "D:\\出片\\IMG_0001.avif", "name": "IMG_0001.avif"}`

`selectionId` 失效（进程重启、文件夹被删）时返回 400，前端需引导重新选择。

---

## 状态机

```
newSession ──► upload ──► preview（可反复，随 hr/edge 变化）
                  │
                  └──► run ──► log 轮询直到 done
                                  │
                                  ├─► result（浏览器内查看／下载）
                                  └─► selectOutput ──► export（仅 Windows）
```

同一时刻只有一个任务；`run` 期间 `upload` 被拒绝。

---

## 冻结期间已知的粗糙处

留在这里是为了不假装它们不存在，但**重写期间不修**：

- `/api/log` 是轮询，没有 SSE 或 WebSocket。
- 全局单任务，`job.read` 对非当前任务一律 404，因此前端无法回看历史任务。
- `/api/state` 里 `secureContextExpected` 与 `transportSecure` 恒等，两个字段目前是同一个事实。
- 旧前端 `api.js` 向 `/api/run` 多传了一个 `preview` 字段，服务端从不读取。新前端不再发送。

# T2 借机执行手册（macOS 本地）

裁定对象：ISO 21496-1 gain map 解码时，**空间上采样与 gamma 解码的先后顺序**。
`modules/gainmap/src/reconstruct.cpp` 先在 code 域双线性插值、再 `pow(encoded, 1/gamma)`；
竞争假设是先解码再插值。gamma ≠ 1 时两者不等价，规范文本读法不能裁定，
**只有 Apple 自己的解码器（ImageIO / Core Image）能裁定**。这就是必须借 Mac 的全部原因。

判据早已冻结（`HyperDR_Model/reports/display-domain-protocol-registration.json` 的 T2 条），
夹具、阈值、决策规则都在仓库里，**Mac 上不做任何判断，只产出证据**。

---

## 一、对借来的 Mac 的要求

| 项 | 要求 | 自查命令 |
|---|---|---|
| 系统 | **macOS 15 (Sequoia) 或更新** | `sw_vers -productVersion` |
| 工具链 | Xcode **或** Command Line Tools | `xcode-select -p` |
| Python | `python3` 可用（随 CLT 提供） | `python3 -V` |
| 网络 | **不需要** | — |
| 权限 | 普通用户即可；只在需要安装 CLT 时要管理员 | — |
| 时间 | 全程约 5 分钟（首次编译 30–60 秒） | — |

芯片（Apple Silicon / Intel）不限，脚本会把架构记进证据。

**借机前先问机主跑这一行**，省得到场才发现要装 3 GB 的东西：

```bash
sw_vers -productVersion; xcode-select -p; python3 -V
```

三行都有输出且系统 ≥ 15 就可以直接开跑。若 `xcode-select -p` 报错，需要先
`xcode-select --install`（要管理员密码 + 下载，视网速 5–20 分钟）。

---

## 二、把东西拷过去

传输包：`HyperDR-T2-mac.zip`（约 1 MB）。U 盘、AirDrop、`scp` 都行，
**不要用会改文本行尾或重新压缩的工具**（夹具是按字节哈希核对的）。

```bash
cd ~/Desktop
unzip HyperDR-T2-mac.zip -d hyperdr-t2
cd hyperdr-t2
```

包内保持了仓库的相对目录（`tests/macos_t2/...` 与 `modules/...`），
**不要只把 `tests/macos_t2` 单独拎出来**——校验脚本要按相对路径回溯到仓库根。

---

## 三、跑

```bash
bash tests/macos_t2/run_t2_local.sh
```

脚本依次做这些事，每步都会打印标题：

1. 预检（系统版本、工具链、文件齐全）——不满足就在编译前退出，退出码 2；
2. 记录工具链到 `t2-output/toolchain.txt`；
3. 校验冻结夹具对：两个 HEIC 的哈希、以及**除 gamma 分子那一个字节外完全相同**；
4. 编译 Core Image harness、ImageIO 诊断器，以及**仓库真身** `reconstruct.cpp`；
5. **问 ImageIO 到底看见了什么**：对两个夹具、外加 `tests/macos_t2/reference/` 下
   Apple 自己写的参照文件，逐一打印辅助数据类型、容器结构、CIImage 各路 extent，
   写入 `t2-output/imageio-diagnostic.txt`；
6. 用 ImageIO/Core Image 在 H = 0.5 / 1.0 / 1.5 stops 三个物理 headroom 上解码渲染，
   同时把 Core Image 解出的 base 与 gain 原样喂给 C++ 实现（避开 HEVC 与色彩管理这两个混淆源）；
7. 套用冻结的逐像素决策规则，写出 `t2-output/t2-report.json`。

第 6 步**失败不会中断脚本**——Core Image 拒收本身就是证据，诊断与工具链记录必须进证据包。
结束时会打印 `status:` 与一个 `t2-evidence-<时间戳>.zip`。

参照文件的作用只有一个：**归因**。我们自己写的文件被拒，可能是写入器不合规，
也可能是 harness 问法不对；Apple 自己写的文件在同一套查询下的表现能把两者分开。
它不是夹具，不参与任何判据（见 `reference/README.md`）。

---

## 四、判读（Mac 上只看一眼，正式结论回来再下）

看 `t2-output/t2-report.json` 的 `status` 与 `failures`：

| 结果 | 含义 | 是不是科学结果 |
|---|---|---|
| `status: pass` | 三个 headroom 上 Core Image 与 **code 域插值**逐像素一致，且 gamma=2 探针对"先解码后插值"这一竞争假设至少差 4 倍 | 是。裁定我们的实现顺序正确 |
| `code_domain` 门失败，但报告里 `decoded_domain_first_error` 明显更小 | Apple 走的是**先解码后插值** | 是，而且是要改 `reconstruct.cpp` 的结果 |
| 两个假设都不接近 | Apple 用了别的上采样核（非双线性）或别的权重语义 | 是，但 T2 未裁定顺序，需要扩夹具再来一次 |
| `ImageIO did not expose the ISO gain map` | 见下面「Core Image 拒收时怎么归因」 | 取决于参照文件的表现 |
| 预检退出码 2 | 机器不合格，没产出证据 | 否，换机器 |

### 这次预期会跑完，怎么读

前三次都停在 Core Image 那一步，原因已查明并**不是写入器的问题**：夹具是 8×4，
任一边小于 64 像素就会被补成 64×64 再由 essential 的 `clap` 裁回，ImageIO 不认。
未经任何容器修复的 512×384 输出，macOS 读得好好的。夹具现在改成 128×128 / gain 64×64。

所以这次**预期会走完全程**并产出 `t2-report.json`，`status:` 那一行就是插值顺序的裁定。

同时诊断里有五个对照，它们必须复现已知行为，否则这轮不可比：

| 路径 | 预期 |
|---|---|
| `fixtures-prerepair/*`、`probes/tiny-8x4-auxrepair-only.heic` | `absent`（8×4，已知被拒） |
| `probes/normal-512x384-*.heic` | `PRESENT`（正常尺寸，已知被接受） |
| `reference/*` | `PRESENT` |

**两个 8×4 对照仍然失败、而 128×128 夹具成功**——这一条同时出现，才把"夹具几何是原因"
从推测变成测量。

若 `fixtures/` 仍是 `absent`：几何不是全部原因，把整份带回来，别在现场改夹具。

**四条铁律**：

1. 失败也要把整个证据包带回来，`failures` 数组就是结论本身；
2. 不许为了"看着对"改阈值、改夹具、改 headroom 节点后重跑——
   这些是预注册量，改了这次运行就作废；
3. 不许在 Mac 上手工改任何 JSON；
4. 同一台机器可以重跑（幂等），但每次运行的 zip 都要留着。

---

## 五、带回来什么

整个 `t2-evidence-<时间戳>.zip`，里面包含：

- `imageio-diagnostic.txt` —— Apple 解码器对每个文件的实际暴露情况
- `t2-report.json` —— 正式结论，含哈希溯源与平台信息（Core Image 拒收时没有这个文件，正常）
- `core-image-report.json` —— Core Image 的逐像素原始输出
- `gamma-1-control-cpp.json` / `gamma-2-probe-cpp.json` —— C++ 两种插值顺序的逐像素输出
- `*-decoded-input.bin` —— Core Image 解出的 base/gain，供离线复算
- `toolchain.txt` —— 系统与编译器版本

回到 Windows 后，这些进 `HyperDR_Model` 的证据流程，
并据结果更新 `docs/DESIGN_VERDICT.md` 里 T2 的状态与"渲染链路现状"的插值顺序条目。

---

## 六、可能撞上的坑

| 现象 | 处置 |
|---|---|
| `xcrun: error: unable to find utility "swiftc"` | 没装 CLT：`xcode-select --install` |
| 编译 `reconstruct.cpp` 报错 | 把完整报错抄回来，这是 Windows 端没暴露的可移植性问题，不是科学结果 |
| `fixture source identity mismatch` | 传输过程改动了文本文件行尾或内容，重新解压干净的一份 |
| `T2 requires macOS 15 or newer` | Swift harness 自己的兜底守卫，换机器 |
| Finder 解压出 `__MACOSX` 目录 | 无害，忽略 |
| 提示"无法打开，因为无法验证开发者" | 我们不分发二进制，二进制是当场编译的；若仍出现，说明你在运行别的东西，停下 |

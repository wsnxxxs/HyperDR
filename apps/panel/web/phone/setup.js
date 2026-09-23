const $ = (id) => document.getElementById(id);
const STATE_TIMEOUT_MS = 8000;
let state = null, step = 0, platform = /Android/i.test(navigator.userAgent) ? "android" : "ios";
// The workbench entry from the last successful state check. Kept in page memory
// only; sessionStorage still stores nothing but the step.
let entry = null, loading = null;
const routes = (...labels) => `<div class="route" aria-label="设置路径">${labels.map((label) => `<span>${label}</span>`).join("")}</div>`;
const steps = {
  ios: [
    ["下载这台电脑的证书", '<p>建议在 Safari 中打开本页。点下方按钮，允许下载，完成后仍需前往系统设置安装。</p><a class="download" href="/setup/root.mobileconfig">下载 iPhone / iPad 描述文件</a><a class="download" href="/setup/root.crt">或下载根证书 .crt</a><p>两者包含同一公开根证书，选择一种即可。描述文件可能显示“未签名”或“未经验证”，这表示它没有可验证的签名；请与电脑工作台“证书与检测详情”核对指纹，不能仅凭本页或证书名称判断可信。</p>'],
    ["前往设置，安装证书", '<p>离开浏览器打开“设置”，安装刚下载的描述文件。</p>' + routes('设置 → 已下载描述文件', '若未显示：通用 → VPN 与设备管理', '选择对应的 HyperDR 描述文件 → 安装') + '<p>按系统提示输入设备密码并确认。安装完成后返回本页，继续下一步。</p>'],
    ["开启根证书的完全信任", '<p>安装与信任是两个步骤。仍在“设置”中，按以下路径找到刚安装的证书：</p>' + routes('通用 → 关于本机', '证书信任设置', '为对应证书开启“完全信任”并确认') + '<p class="callout">网页无法代为开启这个开关。确认名称与本页一致后，再开启信任。</p>'],
    ["检查连接并开始", '<p>返回浏览器，点击下方按钮打开 HTTPS 工作台。进入后会自动检测 HDR 预览能力，检测结果也会同步到电脑。</p><a class="download primary" data-entry href="/setup/continue">检查并进入工作台 →</a><p>能打开 HTTPS 不代表屏幕一定支持 HDR；工作台会分别显示能力检测与照片实际预览模式。</p>'],
  ],
  android: [
    ["下载这台电脑的证书", '<p>将公开根证书保存到手机的“下载”文件夹。下载完成不代表已经安装。</p><a class="download" href="/setup/root.crt">下载根证书 .crt</a><p>请记住文件位置，下一步会在系统设置中选取它。</p>'],
    ["在设置中安装 CA 证书", '<p>打开系统“设置”，搜索“安装证书”或“CA 证书”。不同品牌的菜单名称可能不同。</p>' + routes('设置 → 搜索“安装证书”', '选择 CA 证书', '选择下载的 .crt 文件 → 确认安装') + '<p class="callout">请选择“CA 证书”，不要选择 WLAN / Wi-Fi 或 VPN 与应用证书。系统可能提示网络流量可被检查，这是安装受信任 CA 的权限提示；只为你自己的电脑安装。</p><p>若 .crt 文件呈灰色无法选择，可用“文件”应用将它从下载文件夹移到 Documents（文档）后重试。设备可能要求屏幕锁密码；如果设备由单位管理且禁止安装，请联系管理员。</p>'],
    ["检查连接并开始", '<p>安装完成后回到浏览器，点击下方按钮。工作台会检测安全上下文和 HDR 渲染能力，并同步到电脑。</p><a class="download primary" data-entry href="/setup/continue">检查并进入工作台 →</a><p>部分浏览器或受管理设备可能不使用用户安装的 CA。若仍有证书警告，请检查证书与浏览器设置，不要跳过警告。</p>'],
  ],
};
function save() { if (state) { try { sessionStorage.setItem(`hyperdr-setup:${state.fingerprint}`, JSON.stringify({ platform, step })); } catch {} } }
function verifiedEntry(payload) {
  // Only ever follow an HTTPS entry for the address this page was opened from;
  // never a target assembled from a supplied host.
  try {
    const url = new URL(payload.httpsUrl);
    return url.protocol === "https:" && url.hostname === location.hostname ? url.href : entry;
  } catch { return entry; }
}
function applyEntry() {
  for (const link of document.querySelectorAll("[data-entry], #continue-link")) link.href = entry || "/setup/continue";
  if (entry) $("resume").href = entry;
}
function render(focus = false) {
  const list = steps[platform]; step = Math.max(0, Math.min(step, list.length - 1));
  for (const name of ["ios", "android"]) $(name).setAttribute("aria-pressed", String(platform === name));
  $("progress").textContent = `第 ${step + 1} 步 / 共 ${list.length} 步`;
  $("step-title").textContent = list[step][0]; $("step-content").innerHTML = list[step][1];
  $("back").disabled = step === 0; $("next").hidden = step === list.length - 1;
  for (const link of document.querySelectorAll('[href^="/setup/root."]')) {
    if (!state?.rootAvailable) { link.removeAttribute("href"); link.setAttribute("aria-disabled", "true"); link.textContent = "证书暂不可用，请在电脑重新开启连接"; }
  }
  applyEntry();
  save(); if (focus) $("step-title").focus();
}
function stale(message) {
  // An expired certificate download access says nothing about the trust
  // already installed on this phone, or about the preview connection.
  $("error").textContent = message;
  $("error").hidden = false;
  $("reload").hidden = false;
  $("resume").hidden = !entry;
  $("resume-note").hidden = !entry;
}
async function runLoad({ restore = true } = {}) {
  $("error").hidden = true; $("reload").hidden = true;
  $("resume").hidden = true; $("resume-note").hidden = true;
  const control = new AbortController();
  const timer = setTimeout(() => control.abort(), STATE_TIMEOUT_MS);
  try {
    const response = await fetch("/setup/state", { cache: "no-store", signal: control.signal });
    if (response.status === 410) {
      stale("设置入口已过期。手机上已安装的证书仍然有效；重新下载证书需要在电脑上重新开启设置入口。");
      return;
    }
    if (!response.ok) throw new Error(response.status === 401 || response.status === 403 ? "设置链接已失效。请在电脑上重新生成二维码并扫描。" : "无法读取设置。请确认电脑工作台已开启，手机与电脑连接同一 Wi-Fi，然后重试。");
    state = await response.json();
    entry = verifiedEntry(state);
    $("computer").textContent = state.computer;
    $("certificate-name").textContent = state.certificateName;
    $("fingerprint").textContent = state.fingerprint;
    const expiry = typeof state.expiresAt === "number" ? new Date(state.expiresAt * 1000) : new Date(state.expiresAt);
    $("expiry").textContent = `证书有效期至：${Number.isNaN(expiry.valueOf()) ? state.expiresAt : expiry.toLocaleDateString()}`;
    if (restore) {
      try { const saved = JSON.parse(sessionStorage.getItem(`hyperdr-setup:${state.fingerprint}`)); if (saved && steps[saved.platform] && Number.isInteger(saved.step)) { platform = saved.platform; step = saved.step; } } catch {}
    }
    if (!state.rootAvailable) throw new Error("电脑的根证书暂不可用。请在电脑上检查 HTTPS 设置并重新开启手机连接。");
  } catch (error) {
    const message = error.name === "AbortError"
      ? "读取设置超时。请确认手机与电脑连接同一 Wi-Fi，然后重试。"
      : error instanceof TypeError
        ? "无法连接电脑上的设置入口（入口可能已结束，或网络暂时中断）。"
        : error.message || "设置加载失败，请检查局域网连接并重试。";
    if (entry) stale(`${message} 证书下载入口失效不影响已经安装并信任的证书。`);
    else { $("error").textContent = message; $("error").hidden = false; $("reload").hidden = false; }
  } finally {
    clearTimeout(timer);
    render();
  }
}
function load(options) {
  if (loading) return loading;
  loading = runLoad(options).finally(() => { loading = null; });
  return loading;
}
for (const name of ["ios", "android"]) $(name).addEventListener("click", () => { platform = name; step = 0; render(); });
$("back").addEventListener("click", () => { step--; render(true); });
$("next").addEventListener("click", () => { step++; render(true); });
$("reload").addEventListener("click", () => load({ restore: false }));
// Returning from the Settings app must refresh the entry without losing the
// step the person is on.
document.addEventListener("visibilitychange", () => { if (!document.hidden) load({ restore: false }); });
window.addEventListener("pageshow", (event) => { if (event.persisted) load({ restore: false }); });
render(); load();

const CONFIG = window.DASHBOARD_CONFIG || {};
const sb = window.supabase?.createClient(CONFIG.supabaseUrl, CONFIG.supabasePublishableKey, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
});

const PROFILE_META = {
  jing: { name: "井柏然", color: "#355b73" },
  ning: { name: "宁静", color: "#b54b38" },
  xu: { name: "许晴", color: "#795f84" },
  zheng: { name: "郑爽", color: "#8a7750" },
  mao: { name: "毛阿敏", color: "#54745f" },
  chen: { name: "陈意涵", color: "#d69831" },
  yang: { name: "杨洋", color: "#4a6388" }
};
const CATEGORY_NAMES = { result: "结果反馈", question: "题目反馈", bug: "使用问题", idea: "产品建议", other: "其他" };
const STATUS_NAMES = { new: "待查看", reviewing: "处理中", resolved: "已解决", archived: "已归档" };
const $ = selector => document.querySelector(selector);
let currentSession = null;
let lastData = null;

function showOnly(id) {
  ["#auth-view", "#unauthorized-view", "#dashboard-view"].forEach(selector => {
    $(selector).hidden = selector !== id;
  });
}
function setStatus(message, isError = false) {
  const element = $("#login-status");
  element.textContent = message;
  element.style.color = isError ? "#a22f22" : "";
}
function toast(message) {
  const element = $("#toast");
  element.textContent = message;
  element.classList.add("show");
  window.clearTimeout(toast.timer);
  toast.timer = window.setTimeout(() => element.classList.remove("show"), 2200);
}
function safeText(value) { return String(value ?? ""); }
function formatDate(value, includeYear = false) {
  if (!value) return "—";
  const date = new Date(value);
  return new Intl.DateTimeFormat("zh-CN", {
    timeZone: "Asia/Shanghai", month: "2-digit", day: "2-digit",
    ...(includeYear ? { year: "numeric" } : {}), hour: "2-digit", minute: "2-digit", hour12: false
  }).format(date);
}
function formatDay(value) {
  const date = new Date(`${value}T00:00:00+08:00`);
  return new Intl.DateTimeFormat("zh-CN", { timeZone: "Asia/Shanghai", month: "numeric", day: "numeric" }).format(date);
}
function formatDuration(seconds) {
  const value = Number(seconds);
  if (!Number.isFinite(value)) return "—";
  if (value < 60) return `${Math.max(0, Math.round(value))} 秒`;
  const minutes = Math.floor(value / 60);
  const rest = Math.round(value % 60);
  return rest ? `${minutes}分${rest}秒` : `${minutes} 分钟`;
}
function dodText(value) {
  if (value === null || value === undefined) return "DoD —（昨日暂无可比数据）";
  const number = Number(value);
  if (!Number.isFinite(number)) return "DoD —";
  if (number === 0) return "DoD 0.0%（与昨日持平）";
  return `DoD ${number > 0 ? "+" : "−"}${Math.abs(number).toFixed(1)}%`;
}
function emptyNode(tag, className, text) {
  const element = document.createElement(tag);
  element.className = className;
  element.textContent = text;
  return element;
}

async function login(event) {
  event.preventDefault();
  if (!sb) return setStatus("看板配置未加载，请刷新后重试。", true);
  const button = event.currentTarget.querySelector("button");
  const email = new FormData(event.currentTarget).get("email").trim();
  button.disabled = true;
  setStatus("正在发送一次性登录邮件……");
  const { error } = await sb.auth.signInWithOtp({
    email,
    options: { emailRedirectTo: `${location.origin}${location.pathname}` }
  });
  button.disabled = false;
  if (error) return setStatus(`发送失败：${error.message}`, true);
  setStatus("登录邮件已发送。请在同一台设备上打开邮件中的链接。");
}
async function signOut() {
  await sb?.auth.signOut();
  currentSession = null;
  lastData = null;
  history.replaceState({}, document.title, location.pathname);
  showOnly("#auth-view");
  setStatus("已安全退出。");
}
async function verifyAndLoad(session) {
  currentSession = session;
  if (!session) return showOnly("#auth-view");
  const days = Number($("#days-select").value || 7);
  const { data, error } = await sb.rpc("get_dashboard_data", { p_days: days });
  if (error) {
    if (["42501", "P0001"].includes(error.code) || /not authorized|permission/i.test(error.message)) {
      return showOnly("#unauthorized-view");
    }
    showOnly("#dashboard-view");
    showError(`数据读取失败：${error.message}`);
    return;
  }
  showOnly("#dashboard-view");
  $("#account-email").textContent = session.user.email || "管理员";
  renderDashboard(data);
}
async function refreshData() {
  const button = $("#refresh-button");
  button.disabled = true;
  button.textContent = "刷新中……";
  await verifyAndLoad(currentSession);
  button.disabled = false;
  button.textContent = "刷新数据";
}
function showError(message) {
  const error = $("#dashboard-error");
  error.textContent = message;
  error.hidden = false;
}
function renderDashboard(data) {
  lastData = data || {};
  $("#dashboard-error").hidden = true;
  const metrics = data.metrics || {};
  $("#metric-tests").textContent = Number(metrics.today_tests || 0).toLocaleString("zh-CN");
  $("#metric-tests-dod").textContent = dodText(metrics.today_tests_dod_percent);
  $("#metric-duration").textContent = formatDuration(metrics.today_avg_duration_seconds);
  $("#metric-duration-dod").textContent = dodText(metrics.today_duration_dod_percent);
  $("#metric-total").textContent = Number(metrics.total_tests || 0).toLocaleString("zh-CN");
  const totalFeedback = Number(metrics.total_feedback || 0);
  const pendingFeedback = Number(metrics.pending_feedback || 0);
  const processedFeedback = Number(metrics.processed_feedback || 0);
  $("#metric-feedback").textContent = totalFeedback ? pendingFeedback.toLocaleString("zh-CN") : "—";
  $("#metric-feedback-detail").textContent = totalFeedback
    ? `累计 ${totalFeedback.toLocaleString("zh-CN")} · 已处理 ${processedFeedback.toLocaleString("zh-CN")}`
    : "累计 — · 已处理 —";
  $("#summary-period").textContent = `近 ${data.days || 7} 天`;
  $("#summary-title").textContent = buildSummary(data);
  $("#updated-at").textContent = `数据更新于 ${formatDate(data.generated_at, true)} · 时区：北京时间`;
  $("#trend-total").textContent = `共 ${Number(metrics.period_tests || 0)} 次`;
  renderTrend(data.daily || []);
  renderProfiles(data.profiles || [], Number(metrics.period_tests || 0));
  renderRecent(data.recent || []);
  renderFeedback(data.feedback || []);
}
function buildSummary(data) {
  const metrics = data.metrics || {};
  const profiles = [...(data.profiles || [])].sort((a, b) => Number(b.count) - Number(a.count));
  if (!Number(metrics.period_tests)) {
    return `近 ${data.days || 7} 天还没有真实测试记录。看板已经连通，产生新测试后刷新即可看到趋势。`;
  }
  const top = profiles[0];
  const topMeta = PROFILE_META[top?.type] || { name: "未知" };
  const share = Number(metrics.period_tests) ? Number(top?.count || 0) / Number(metrics.period_tests) * 100 : 0;
  const feedbackText = Number(metrics.total_feedback || 0)
    ? `累计收到 ${Number(metrics.total_feedback).toLocaleString("zh-CN")} 条意见，其中 ${Number(metrics.pending_feedback || 0).toLocaleString("zh-CN")} 条待查看。`
    : "目前暂无真实用户意见。";
  return `近 ${data.days} 天共有 ${Number(metrics.period_tests).toLocaleString("zh-CN")} 次测试。最常见结果是${topMeta.name}人格，占 ${share.toFixed(1)}%；本期平均完成耗时 ${formatDuration(metrics.period_avg_duration_seconds)}。${feedbackText}`;
}
function renderTrend(items) {
  const chart = $("#trend-chart");
  chart.replaceChildren();
  chart.style.setProperty("--days", Math.max(items.length, 1));
  const max = Math.max(1, ...items.map(item => Number(item.count || 0)));
  items.forEach(item => {
    const column = emptyNode("div", "trend-column", "");
    const wrap = emptyNode("div", "trend-bar-wrap", "");
    wrap.append(emptyNode("span", "trend-value", Number(item.count || 0).toLocaleString("zh-CN")));
    const bar = emptyNode("i", "trend-bar", "");
    bar.style.height = `${Math.max(2, Number(item.count || 0) / max * 100)}%`;
    wrap.append(bar);
    column.append(wrap, emptyNode("span", "trend-label", formatDay(item.day)));
    chart.append(column);
  });
}
function renderProfiles(items, total) {
  const chart = $("#profile-chart");
  chart.replaceChildren();
  const byType = Object.fromEntries(items.map(item => [item.type, Number(item.count || 0)]));
  Object.entries(PROFILE_META).forEach(([id, meta]) => {
    const count = byType[id] || 0;
    const percent = total ? count / total * 100 : 0;
    const row = emptyNode("div", "profile-row", "");
    row.append(emptyNode("span", "", meta.name));
    const track = emptyNode("div", "profile-track", "");
    const fill = emptyNode("i", "", "");
    fill.style.width = `${percent}%`;
    fill.style.background = meta.color;
    track.append(fill);
    row.append(track, emptyNode("strong", "", `${count} · ${percent.toFixed(1)}%`));
    chart.append(row);
  });
}
function renderRecent(items) {
  const body = $("#recent-results");
  body.replaceChildren();
  $("#recent-empty").hidden = items.length > 0;
  items.forEach(item => {
    const row = document.createElement("tr");
    const time = emptyNode("td", "", formatDate(item.tested_at, true));
    const result = document.createElement("td");
    const meta = PROFILE_META[item.result_type] || { name: safeText(item.result_name), color: "#777" };
    const pill = emptyNode("span", "result-pill", meta.name);
    pill.style.setProperty("--result-color", meta.color);
    result.append(pill);
    const duration = emptyNode("td", "", formatDuration(item.duration_seconds));
    const report = emptyNode("td", "report-id", item.public_id);
    report.title = safeText(item.public_id);
    row.append(time, result, duration, report);
    body.append(row);
  });
}
function renderFeedback(items) {
  const list = $("#feedback-list");
  list.replaceChildren();
  $("#feedback-empty").hidden = items.length > 0;
  items.forEach(item => {
    const article = emptyNode("article", "feedback-item", "");
    const meta = emptyNode("div", "feedback-meta", "");
    meta.append(emptyNode("span", "", CATEGORY_NAMES[item.category] || "其他"), emptyNode("time", "", formatDate(item.submitted_at, true)));
    const message = emptyNode("p", "feedback-message", item.message);
    const actions = emptyNode("div", "feedback-actions", "");
    Object.entries(STATUS_NAMES).forEach(([status, label]) => {
      const button = emptyNode("button", `status-button${item.status === status ? " active" : ""}`, label);
      button.type = "button";
      button.dataset.feedbackId = item.id;
      button.dataset.status = status;
      actions.append(button);
    });
    article.append(meta, message, actions);
    list.append(article);
  });
}
async function updateFeedbackStatus(event) {
  const button = event.target.closest("[data-feedback-id]");
  if (!button) return;
  button.disabled = true;
  const { error } = await sb.rpc("update_feedback_status", { p_feedback_id: button.dataset.feedbackId, p_status: button.dataset.status });
  button.disabled = false;
  if (error) return toast(`更新失败：${error.message}`);
  toast("意见状态已更新");
  await refreshData();
}

async function initialize() {
  $("#test-site-link").href = CONFIG.testSiteUrl || "#";
  if (!sb) { setStatus("Supabase 客户端未加载，请检查网络后刷新。", true); return; }
  const { data: { session } } = await sb.auth.getSession();
  await verifyAndLoad(session);
  sb.auth.onAuthStateChange((event, nextSession) => {
    if (event === "SIGNED_IN" && nextSession?.access_token !== currentSession?.access_token) verifyAndLoad(nextSession);
    if (event === "SIGNED_OUT") showOnly("#auth-view");
  });
}

$("#login-form").addEventListener("submit", login);
$("#signout-button").addEventListener("click", signOut);
$("#unauthorized-signout").addEventListener("click", signOut);
$("#refresh-button").addEventListener("click", refreshData);
$("#days-select").addEventListener("change", refreshData);
$("#feedback-list").addEventListener("click", updateFeedbackStatus);
initialize();

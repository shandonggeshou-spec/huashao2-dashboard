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
const RECENT_PAGE_SIZE = 10;
const FEEDBACK_PAGE_SIZE = 5;
const $ = selector => document.querySelector(selector);
let currentSession = null;
let lastData = null;
let recentPage = 1;
let recentTotalPages = 0;
let recentPageLoading = false;
let feedbackPage = 1;
let feedbackTotalPages = 0;
let feedbackPageLoading = false;
let trendGranularity = "day";
let trendDate = shanghaiToday();
let calendarMonth = trendDate.slice(0, 7);
const trendCache = new Map();

function shanghaiToday() {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Shanghai", year: "numeric", month: "2-digit", day: "2-digit"
  }).formatToParts(new Date());
  const values = Object.fromEntries(parts.map(part => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day}`;
}
function dateKey(date) {
  const year = date.getUTCFullYear();
  const month = String(date.getUTCMonth() + 1).padStart(2, "0");
  const day = String(date.getUTCDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}
function shiftMonth(value, amount) {
  const [year, month] = value.split("-").map(Number);
  const shifted = new Date(Date.UTC(year, month - 1 + amount, 1));
  return `${shifted.getUTCFullYear()}-${String(shifted.getUTCMonth() + 1).padStart(2, "0")}`;
}

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
  recentPage = 1;
  recentTotalPages = 0;
  feedbackPage = 1;
  feedbackTotalPages = 0;
  trendDate = shanghaiToday();
  calendarMonth = trendDate.slice(0, 7);
  trendCache.clear();
  history.replaceState({}, document.title, location.pathname);
  showOnly("#auth-view");
  setStatus("已安全退出。");
}
async function verifyAndLoad(session) {
  currentSession = session;
  if (!session) return showOnly("#auth-view");
  trendCache.clear();
  const [dashboardResponse, recentResponse, feedbackResponse] = await Promise.all([
    sb.rpc("get_dashboard_data", { p_days: 7 }),
    sb.rpc("get_test_results_page", { p_page: recentPage, p_page_size: RECENT_PAGE_SIZE }),
    sb.rpc("get_feedback_page", { p_page: feedbackPage, p_page_size: FEEDBACK_PAGE_SIZE })
  ]);
  const { data, error } = dashboardResponse;
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
  syncTrendDate();
  renderDashboard(data);
  await loadTrendGranularity(trendGranularity, true);
  if (recentResponse.error) {
    renderRecent(data.recent || []);
    $("#recent-title").textContent = "最近 20 条测试";
    $("#recent-note").textContent = "完整分页尚未启用";
    $("#recent-pagination").hidden = true;
    showError("完整记录分页尚未启用：请在 Supabase SQL Editor 执行 pagination.sql。当前暂时显示最近 20 条。");
  } else {
    $("#recent-title").textContent = "全部测试记录";
    renderRecent(recentResponse.data?.items || []);
    renderRecentPagination(recentResponse.data || {});
  }
  if (feedbackResponse.error) {
    renderFeedback(data.feedback || []);
    $("#feedback-note").textContent = "暂时显示最新意见";
    $("#feedback-pagination").hidden = true;
  } else {
    renderFeedback(feedbackResponse.data?.items || []);
    renderFeedbackPagination(feedbackResponse.data || {});
  }
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
  $("#summary-period").textContent = "近 7 天";
  $("#summary-title").textContent = buildSummary(data);
  $("#updated-at").textContent = `数据更新于 ${formatDate(data.generated_at, true)} · 时区：北京时间`;
  $("#trend-total").textContent = `共 ${Number(metrics.period_tests || 0)} 次`;
  $("#profile-total").textContent = `共 ${Number(metrics.period_tests || 0)} 次`;
  renderTrend(data.daily || [], "day");
  renderProfiles(data.profiles || [], Number(metrics.period_tests || 0));
}
function syncTrendSelect(granularity) {
  const select = document.querySelector('[data-range-target="trend"]');
  if (!select) return;
  select.querySelectorAll("[data-granularity]").forEach(button => {
    const selected = button.dataset.granularity === granularity;
    button.classList.toggle("active", selected);
    button.setAttribute("aria-selected", String(selected));
    if (selected) select.querySelector(".range-select-trigger span").textContent = button.textContent;
  });
}
function syncTrendDate() {
  const label = $("#trend-date-label");
  if (label) label.textContent = trendDate;
}
function renderCalendar() {
  const [year, month] = calendarMonth.split("-").map(Number);
  const first = new Date(Date.UTC(year, month - 1, 1));
  const gridStart = new Date(first);
  gridStart.setUTCDate(1 - first.getUTCDay());
  $("#calendar-month-label").textContent = `${year} - ${String(month).padStart(2, "0")}`;
  const days = $("#calendar-days");
  days.replaceChildren();
  for (let index = 0; index < 42; index += 1) {
    const date = new Date(gridStart);
    date.setUTCDate(gridStart.getUTCDate() + index);
    const value = dateKey(date);
    const button = emptyNode("button", "calendar-day", date.getUTCDate());
    button.type = "button";
    button.dataset.date = value;
    button.classList.toggle("outside", date.getUTCMonth() !== month - 1);
    button.classList.toggle("selected", value === trendDate);
    button.classList.toggle("today", value === shanghaiToday());
    button.disabled = value > shanghaiToday();
    button.setAttribute("aria-label", value);
    days.append(button);
  }
  document.querySelectorAll("[data-calendar-shift]").forEach(button => {
    const amount = Number(button.dataset.calendarShift);
    button.disabled = amount > 0 && shiftMonth(calendarMonth, amount) > shanghaiToday().slice(0, 7);
  });
}
function closeCalendar() {
  $("#trend-calendar").hidden = true;
  $("#trend-date-trigger").setAttribute("aria-expanded", "false");
}
function toggleCalendar() {
  const calendar = $("#trend-calendar");
  const willOpen = calendar.hidden;
  closeRangeSelects();
  calendar.hidden = !willOpen;
  $("#trend-date-trigger").setAttribute("aria-expanded", String(willOpen));
  if (willOpen) { calendarMonth = trendDate.slice(0, 7); renderCalendar(); }
}
async function handleCalendar(event) {
  const shift = event.target.closest("[data-calendar-shift]");
  if (shift && !shift.disabled) {
    calendarMonth = shiftMonth(calendarMonth, Number(shift.dataset.calendarShift));
    renderCalendar();
    return;
  }
  const day = event.target.closest("[data-date]");
  if (!day || day.disabled) return;
  trendDate = day.dataset.date;
  calendarMonth = trendDate.slice(0, 7);
  syncTrendDate();
  closeCalendar();
  await loadTrendGranularity(trendGranularity, true);
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
function renderTrend(items, granularity = trendGranularity) {
  const chart = $("#trend-chart");
  chart.replaceChildren();
  chart.dataset.granularity = granularity;
  chart.style.setProperty("--days", Math.max(items.length, 1));
  const max = Math.max(1, ...items.map(item => Number(item.count || 0)));
  items.forEach(item => {
    const column = emptyNode("div", "trend-column", "");
    const wrap = emptyNode("div", "trend-bar-wrap", "");
    wrap.append(emptyNode("span", "trend-value", Number(item.count || 0).toLocaleString("zh-CN")));
    const bar = emptyNode("i", "trend-bar", "");
    bar.style.height = `${Math.max(2, Number(item.count || 0) / max * 100)}%`;
    wrap.append(bar);
    const label = item.label || (item.day ? formatDay(item.day) : safeText(item.bucket_start));
    column.append(wrap, emptyNode("span", "trend-label", label));
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
async function loadTrendGranularity(granularity, force = false) {
  const container = document.querySelector('[data-range-target="trend"]');
  if (!container || (!force && trendGranularity === granularity)) return true;
  container.classList.add("loading");
  const cacheKey = `${granularity}:${trendDate}`;
  let data = trendCache.get(cacheKey);
  if (!data) {
    let response = await sb.rpc("get_trend_data", { p_granularity: granularity, p_date: trendDate });
    if (response.error && trendDate === shanghaiToday() && granularity !== "hour") {
      response = await sb.rpc("get_trend_data", { p_granularity: granularity });
    }
    if (response.error) {
      if (granularity === "day" && trendDate === shanghaiToday()) {
        const fallback = await sb.rpc("get_dashboard_data", { p_days: 10 });
        if (!fallback.error) {
          data = {
            granularity: "day",
            total: Number(fallback.data?.metrics?.period_tests || 0),
            items: fallback.data?.daily || []
          };
        }
      }
      if (!data) {
        container.classList.remove("loading");
        toast(/get_trend_data|schema cache/i.test(response.error.message || "")
          ? "小时或历史趋势尚未启用，请先执行新版趋势 SQL。"
          : "趋势读取失败：" + response.error.message);
        return false;
      }
    } else {
      data = response.data;
    }
    trendCache.set(cacheKey, data);
  }
  trendGranularity = granularity;
  syncTrendSelect(granularity);
  renderTrend(data.items || [], granularity);
  $("#trend-total").textContent = "共 " + Number(data.total || 0).toLocaleString("zh-CN") + " 次";
  container.classList.remove("loading");
  return true;
}
function closeRangeSelects(except = null) {
  document.querySelectorAll(".range-select").forEach(select => {
    if (select === except) return;
    select.querySelector(".range-select-menu").hidden = true;
    select.querySelector(".range-select-trigger").setAttribute("aria-expanded", "false");
  });
}
async function handleRangeSelect(event) {
  const select = event.target.closest(".range-select");
  if (!select) return;
  const trigger = event.target.closest(".range-select-trigger");
  if (trigger) {
    closeCalendar();
    const menu = select.querySelector(".range-select-menu");
    const willOpen = menu.hidden;
    closeRangeSelects(select);
    menu.hidden = !willOpen;
    trigger.setAttribute("aria-expanded", String(willOpen));
    return;
  }
  const option = event.target.closest("[data-granularity]");
  if (!option) return;
  const granularity = option.dataset.granularity;
  closeRangeSelects();
  const loaded = await loadTrendGranularity(granularity);
  if (!loaded) return;
  syncTrendSelect(granularity);
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
function getPageTabs(page, totalPages) {
  if (totalPages <= 7) return Array.from({ length: totalPages }, (_, index) => index + 1);
  const pages = new Set([1, totalPages, page - 1, page, page + 1]);
  const values = [...pages].filter(value => value >= 1 && value <= totalPages).sort((a, b) => a - b);
  const tabs = [];
  values.forEach((value, index) => {
    if (index && value - values[index - 1] > 1) tabs.push("ellipsis");
    tabs.push(value);
  });
  return tabs;
}
function renderRecentPagination({ page, page_size: pageSize, total, total_pages: totalPages }) {
  const pagination = $("#recent-pagination");
  const tabs = $("#recent-page-tabs");
  const normalizedTotal = Number(total || 0);
  const normalizedPage = Math.max(1, Number(page || 1));
  const normalizedPageSize = Math.max(1, Number(pageSize || RECENT_PAGE_SIZE));
  const normalizedTotalPages = Math.max(0, Number(totalPages || 0));
  recentPage = normalizedPage;
  recentTotalPages = normalizedTotalPages;
  $("#recent-note").textContent = normalizedTotal ? "" : "仅显示时间、耗时、结果";
  if (!normalizedTotal) {
    pagination.hidden = true;
    tabs.replaceChildren();
    return;
  }
  const start = (normalizedPage - 1) * normalizedPageSize + 1;
  const end = Math.min(normalizedPage * normalizedPageSize, normalizedTotal);
  $("#recent-note").textContent = "共 " + normalizedTotal.toLocaleString("zh-CN") + " 条真实记录";
  $("#recent-page-summary").textContent = "第 " + start + "–" + end + " 条，共 " + normalizedTotal.toLocaleString("zh-CN") + " 条";
  tabs.replaceChildren();
  getPageTabs(normalizedPage, normalizedTotalPages).forEach(value => {
    if (value === "ellipsis") {
      tabs.append(emptyNode("span", "page-ellipsis", "…"));
      return;
    }
    const button = emptyNode("button", "page-tab" + (value === normalizedPage ? " active" : ""), value);
    button.type = "button";
    button.dataset.page = value;
    button.setAttribute("aria-label", "第 " + value + " 页");
    if (value === normalizedPage) button.setAttribute("aria-current", "page");
    tabs.append(button);
  });
  const previous = pagination.querySelector('[data-page-action="previous"]');
  const next = pagination.querySelector('[data-page-action="next"]');
  previous.disabled = normalizedPage <= 1;
  next.disabled = normalizedPage >= normalizedTotalPages;
  pagination.hidden = false;
}
async function loadRecentPage(page = 1, fallbackItems = []) {
  if (!sb || recentPageLoading) return;
  recentPageLoading = true;
  $("#recent-pagination").classList.add("loading");
  const { data, error } = await sb.rpc("get_test_results_page", {
    p_page: Math.max(1, Number(page || 1)),
    p_page_size: RECENT_PAGE_SIZE
  });
  recentPageLoading = false;
  $("#recent-pagination").classList.remove("loading");
  if (error) {
    if (fallbackItems.length) {
      renderRecent(fallbackItems);
      $("#recent-title").textContent = "最近 20 条测试";
      $("#recent-note").textContent = "完整分页尚未启用";
      $("#recent-pagination").hidden = true;
      showError("完整记录分页尚未启用：请在 Supabase SQL Editor 执行 pagination.sql。当前暂时显示最近 20 条。");
      return;
    }
    $("#recent-note").textContent = "记录读取失败";
    showError("测试记录分页读取失败：" + error.message);
    return;
  }
  $("#recent-title").textContent = "全部测试记录";
  renderRecent(data?.items || []);
  renderRecentPagination(data || {});
}
async function changeRecentPage(event) {
  const target = event.target.closest("button");
  if (!target || target.disabled || recentPageLoading) return;
  let nextPage = Number(target.dataset.page || recentPage);
  if (target.dataset.pageAction === "previous") nextPage = recentPage - 1;
  if (target.dataset.pageAction === "next") nextPage = recentPage + 1;
  if (nextPage < 1 || nextPage > recentTotalPages || nextPage === recentPage) return;
  await loadRecentPage(nextPage);
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
function renderFeedbackPagination({ page, page_size: pageSize, total, total_pages: totalPages }) {
  const pagination = $("#feedback-pagination");
  const tabs = $("#feedback-page-tabs");
  const normalizedTotal = Number(total || 0);
  const normalizedPage = Math.max(1, Number(page || 1));
  const normalizedPageSize = Math.max(1, Number(pageSize || FEEDBACK_PAGE_SIZE));
  feedbackPage = normalizedPage;
  feedbackTotalPages = Math.max(0, Number(totalPages || 0));
  $("#feedback-note").textContent = normalizedTotal ? "共 " + normalizedTotal.toLocaleString("zh-CN") + " 条 · 标记后同步" : "标记后会同步到数据库";
  if (!normalizedTotal) {
    pagination.hidden = true;
    tabs.replaceChildren();
    return;
  }
  const start = (normalizedPage - 1) * normalizedPageSize + 1;
  const end = Math.min(normalizedPage * normalizedPageSize, normalizedTotal);
  $("#feedback-page-summary").textContent = "第 " + start + "–" + end + " 条，共 " + normalizedTotal.toLocaleString("zh-CN") + " 条";
  tabs.replaceChildren();
  getPageTabs(normalizedPage, feedbackTotalPages).forEach(value => {
    if (value === "ellipsis") return tabs.append(emptyNode("span", "page-ellipsis", "…"));
    const button = emptyNode("button", "page-tab" + (value === normalizedPage ? " active" : ""), value);
    button.type = "button";
    button.dataset.feedbackPage = value;
    if (value === normalizedPage) button.setAttribute("aria-current", "page");
    tabs.append(button);
  });
  pagination.querySelector('[data-feedback-action="previous"]').disabled = normalizedPage <= 1;
  pagination.querySelector('[data-feedback-action="next"]').disabled = normalizedPage >= feedbackTotalPages;
  pagination.hidden = false;
}
async function loadFeedbackPage(page = 1) {
  if (!sb || feedbackPageLoading) return;
  feedbackPageLoading = true;
  $("#feedback-pagination").classList.add("loading");
  const { data, error } = await sb.rpc("get_feedback_page", { p_page: Math.max(1, Number(page || 1)), p_page_size: FEEDBACK_PAGE_SIZE });
  feedbackPageLoading = false;
  $("#feedback-pagination").classList.remove("loading");
  if (error) return toast("意见读取失败：" + error.message);
  renderFeedback(data?.items || []);
  renderFeedbackPagination(data || {});
}
async function changeFeedbackPage(event) {
  const target = event.target.closest("button");
  if (!target || target.disabled || feedbackPageLoading) return;
  let nextPage = Number(target.dataset.feedbackPage || feedbackPage);
  if (target.dataset.feedbackAction === "previous") nextPage = feedbackPage - 1;
  if (target.dataset.feedbackAction === "next") nextPage = feedbackPage + 1;
  if (nextPage < 1 || nextPage > feedbackTotalPages || nextPage === feedbackPage) return;
  await loadFeedbackPage(nextPage);
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
document.querySelectorAll(".range-select").forEach(select => select.addEventListener("click", handleRangeSelect));
$("#trend-date-trigger").addEventListener("click", toggleCalendar);
$("#trend-calendar").addEventListener("click", handleCalendar);
document.addEventListener("click", event => {
  if (!event.target.closest(".range-select")) closeRangeSelects();
  if (!event.target.closest(".date-picker")) closeCalendar();
});
document.addEventListener("keydown", event => { if (event.key === "Escape") { closeRangeSelects(); closeCalendar(); } });
$("#recent-pagination").addEventListener("click", changeRecentPage);
$("#feedback-pagination").addEventListener("click", changeFeedbackPage);
$("#feedback-list").addEventListener("click", updateFeedbackStatus);
initialize();

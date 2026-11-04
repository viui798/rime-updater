const ui = {
  profiles: [],
  settings: {},
  selected: new Set(),
  known: new Set(),
  remote: null,
  job: null,
  lastJobId: null,
  deviceSig: "",
  backupSig: "",
  logText: "",
};

const $ = (id) => document.getElementById(id);

function esc(value) {
  return String(value == null ? "" : value).replace(/[&<>"']/g, (ch) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[ch]);
}

async function request(path, options = {}) {
  const res = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}

function jobRunning() {
  return Boolean(ui.job && !ui.job.done);
}

function currentVersion() {
  return ui.remote ? ui.remote.version : null;
}

function versionBadge(current) {
  const latest = currentVersion();
  if (!latest) return '<span class="badge">未检查</span>';
  if (!current) return '<span class="badge warn">版本未知</span>';
  if (current === latest) return '<span class="badge ok">已最新</span>';
  return `<span class="badge warn">可更新到 ${esc(latest)}</span>`;
}

function renderRemote() {
  $("remoteVersion").textContent = ui.remote ? `v${ui.remote.version}` : "—";
  if (ui.remote) {
    $("remoteMeta").textContent =
      `${ui.remote.delta ? "增量包" : "完整包"} · ${ui.remote.asset}`;
    $("remoteLine").textContent = `远端最新 v${ui.remote.version}`;
  } else {
    $("remoteMeta").textContent = "尚未检查";
    $("remoteLine").textContent = `识别到 ${ui.profiles.length} 个用户目录`;
  }
}

function renderDevices() {
  const sig = JSON.stringify([
    ui.profiles.map((p) => [p.path, p.label, p.current, p.kind]),
    currentVersion(),
  ]);
  if (sig === ui.deviceSig) return;
  ui.deviceSig = sig;

  const list = $("devices");
  list.innerHTML = "";
  ui.profiles.forEach((profile) => {
    const item = document.createElement("label");
    item.className = "device" + (ui.selected.has(profile.path) ? "" : " off");
    item.innerHTML = `
      <input type="checkbox" ${ui.selected.has(profile.path) ? "checked" : ""}>
      <div class="device-main">
        <div class="device-name">${esc(profile.label)} ${versionBadge(profile.current)}</div>
        <div class="device-path" title="${esc(profile.path)}">${esc(profile.path)}</div>
      </div>
      <div class="device-version">
        <b>${profile.current ? "v" + esc(profile.current) : "未知"}</b>
        <span>当前版本</span>
      </div>`;
    item.querySelector("input").addEventListener("change", (event) => {
      if (event.target.checked) ui.selected.add(profile.path);
      else ui.selected.delete(profile.path);
      item.classList.toggle("off", !event.target.checked);
      updateButtons();
    });
    list.appendChild(item);
  });

  $("deviceCount").textContent = `${ui.profiles.length} 个`;
  $("emptyHint").classList.toggle("hidden", ui.profiles.length > 0);
}

function renderBackups() {
  const sig = JSON.stringify(ui.profiles.map((p) => [p.path, p.backups]));
  if (sig === ui.backupSig) return;
  ui.backupSig = sig;

  const root = $("backups");
  root.innerHTML = "";
  const withBackups = ui.profiles.filter((p) => p.backups && p.backups.length);
  if (!withBackups.length) {
    root.innerHTML = '<p class="empty">还没有备份。勾选「更新前完整快照」后执行一次更新即可生成。</p>';
    return;
  }
  withBackups.forEach((profile) => {
    const group = document.createElement("div");
    group.className = "backup-group";
    group.innerHTML = `<h3>${esc(profile.label)}</h3>`;
    profile.backups.forEach((backup) => {
      const row = document.createElement("div");
      row.className = "backup-row";
      const from = backup.previous_version ? `v${esc(backup.previous_version)}` : "未知";
      const to = backup.version ? `v${esc(backup.version)}` : "未知";
      row.innerHTML = `<span><code>${esc(backup.stamp)}</code> · ${from} → ${to}</span>`;
      const btn = document.createElement("button");
      btn.className = "btn ghost";
      btn.type = "button";
      btn.textContent = "回滚";
      btn.addEventListener("click", () => rollback(profile, backup));
      row.appendChild(btn);
      group.appendChild(row);
    });
    root.appendChild(group);
  });
}

function renderLog() {
  const text = ui.job ? ui.job.lines.join("\n") : "";
  if (text && text !== ui.logText) {
    ui.logText = text;
    const box = $("log");
    const stick = box.scrollTop + box.clientHeight >= box.scrollHeight - 40;
    box.textContent = text;
    if (stick) box.scrollTop = box.scrollHeight;
  }
  const percent = ui.job ? ui.job.percent : 0;
  $("progressBar").style.width = `${jobRunning() ? percent : ui.job && ui.job.done && ui.job.ok ? 100 : 0}%`;
}

function updateButtons() {
  const running = jobRunning();
  $("checkBtn").disabled = running;
  $("updateBtn").disabled = running || !ui.profiles.length;
  $("dryBtn").disabled = running || !ui.profiles.length;
}

function updateStatus() {
  if (!ui.job) {
    $("jobStatus").textContent = "空闲";
  } else if (!ui.job.done) {
    $("jobStatus").textContent = `${ui.job.title}…`;
  } else if (ui.job.error) {
    $("jobStatus").textContent = "失败";
  } else {
    $("jobStatus").textContent = "完成";
  }
  updateButtons();
}

function handleJob() {
  if (!ui.job || !ui.job.done || ui.job.id === ui.lastJobId) return;
  ui.lastJobId = ui.job.id;
  if (ui.job.ok && ui.job.result && ui.job.result.version
      && (ui.job.kind === "check" || ui.job.kind === "update")) {
    ui.remote = {
      version: ui.job.result.version,
      asset: ui.job.result.asset || (ui.remote && ui.remote.asset) || "",
      delta: Boolean(ui.job.result.delta),
    };
  }
  refresh();
}

function applyState(state) {
  ui.profiles = state.profiles || [];
  ui.settings = state.settings || {};
  ui.job = state.job || null;

  ui.profiles.forEach((profile) => {
    if (!ui.known.has(profile.path)) {
      ui.known.add(profile.path);
      ui.selected.add(profile.path);
    }
  });

  renderRemote();
  renderDevices();
  renderBackups();
  renderLog();
  updateStatus();
  handleJob();
}

async function refresh() {
  try {
    const state = await request("/api/state");
    applyState(state);
  } catch (error) {
    $("jobStatus").textContent = "连接已断开";
  }
}

async function runAction(action, extra = {}) {
  const targets = [...ui.selected];
  if (action === "update" && !targets.length) {
    window.alert("请先勾选至少一个设备。");
    return;
  }
  try {
    const { job } = await request("/api/run", {
      method: "POST",
      body: JSON.stringify({ action, targets, ...extra }),
    });
    ui.job = job;
    ui.lastJobId = null;
    updateStatus();
    renderLog();
    renderDevices();
  } catch (error) {
    $("jobStatus").textContent = error.message;
  }
}

$("checkBtn").addEventListener("click", () => runAction("check"));

function selectedCountLabel() {
  return `${[...ui.selected].length} 个设备`;
}

$("dryBtn").addEventListener("click", () => runAction("update", { dry_run: true }));

$("updateBtn").addEventListener("click", () => {
  const version = ui.remote ? `v${ui.remote.version}` : "远端最新版本";
  if (!window.confirm(`将更新 ${selectedCountLabel()}到 ${version}，继续？`)) return;
  runAction("update", { dry_run: false });
});

function rollback(profile, backup) {
  const from = backup.version ? `v${backup.version}` : "未知";
  const to = backup.previous_version ? `v${backup.previous_version}` : "未知";
  if (!window.confirm(`把「${profile.label}」从 ${from} 回滚到 ${to}？`)) return;
  request("/api/run", {
    method: "POST",
    body: JSON.stringify({
      action: "rollback",
      items: [{ path: profile.path, label: profile.label, kind: profile.kind, stamp: backup.stamp }],
    }),
  })
    .then(({ job }) => {
      ui.job = job;
      ui.lastJobId = null;
      renderLog();
      updateStatus();
    })
    .catch((error) => { $("jobStatus").textContent = error.message; });
}

function openSettings() {
  const form = $("settingsForm");
  const settings = ui.settings || {};
  form.repo.value = settings.repo || "";
  form.proxy.value = settings.proxy || "";
  form.token.value = settings.token || "";
  form.cache_dir.value = settings.cache_dir || "";
  form.deploy.checked = Boolean(settings.deploy);
  form.restart.checked = Boolean(settings.restart);
  form.snapshot.checked = Boolean(settings.snapshot);
  $("settingsHint").textContent = "";
  $("settings").classList.remove("hidden");
}

$("settingsBtn").addEventListener("click", openSettings);

$("quitBtn").addEventListener("click", async () => {
  if (!window.confirm("退出更新器？下次更新时重新打开即可。")) return;
  try {
    await request("/api/quit", { method: "POST", body: "{}" });
  } catch (error) {
    // 服务已经关闭
  }
  document.body.innerHTML =
    '<main><p style="padding:40px 0;color:#888">更新器已退出，可以关闭这个页面。</p></main>';
});
$("closeSettings").addEventListener("click", () => $("settings").classList.add("hidden"));
$("settings").addEventListener("click", (event) => {
  if (event.target === $("settings")) $("settings").classList.add("hidden");
});

$("settingsForm").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.target;
  const payload = {
    repo: form.repo.value.trim(),
    proxy: form.proxy.value.trim(),
    token: form.token.value.trim(),
    cache_dir: form.cache_dir.value.trim(),
    deploy: form.deploy.checked,
    restart: form.restart.checked,
    snapshot: form.snapshot.checked,
  };
  try {
    const { settings } = await request("/api/settings", {
      method: "POST",
      body: JSON.stringify(payload),
    });
    ui.settings = settings;
    $("settingsHint").textContent = "已保存";
    setTimeout(() => $("settings").classList.add("hidden"), 600);
  } catch (error) {
    $("settingsHint").textContent = error.message;
  }
});

refresh();
setInterval(refresh, 1200);

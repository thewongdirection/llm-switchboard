'use strict';

// ---- helpers ---------------------------------------------------------------
const $ = (s, r = document) => r.querySelector(s);
const h = (tag, attrs = {}, ...kids) => {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') e.className = v;
    else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
    else if (v === true) e.setAttribute(k, '');
    else if (v !== false && v != null) e.setAttribute(k, v);
  }
  for (const c of kids.flat()) { if (c == null || c === false) continue; e.append(c.nodeType ? c : document.createTextNode(c)); }
  return e;
};
async function api(path, body) {
  const r = await fetch(path, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { 'X-Switchboard': '1', 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || r.statusText);
  return j;
}
let toastTimer;
function toast(msg, err = false) {
  const t = $('#toast'); t.textContent = msg; t.className = 'show' + (err ? ' err' : '');
  clearTimeout(toastTimer); toastTimer = setTimeout(() => t.className = '', err ? 6000 : 2800);
}
const guard = fn => async (...a) => { try { await fn(...a); } catch (e) { toast(e.message, true); } };
const fmtGB = n => n >= 100 ? Math.round(n) + ' GB' : (Math.round(n * 10) / 10) + ' GB';
const fmtNum = n => n >= 1e6 ? (n / 1e6).toFixed(1) + 'M' : n >= 1e3 ? Math.round(n / 1e3) + 'k' : String(n);
const fmtAge = d => d == null ? '' : d < 1 ? 'today' : d < 31 ? d + ' d ago' : d < 365 ? Math.round(d / 30) + ' mo ago' : Math.round(d / 365) + ' y ago';
const fitBadge = fit => h('span', { class: 'badge ' + fit.tier, title: 'Estimated for your hardware' }, fit.label);

// ---- state -----------------------------------------------------------------
const S = {
  app: null, models: [], server: { state: 'stopped' }, discover: { items: [], status: {} }, downloads: [], projects: [],
  selected: localStorage.getItem('selectedModel') || null, tab: 'installed',
  opts: JSON.parse(localStorage.getItem('launchOpts') || '{"ctx":32768,"kvQuant":false,"vision":false,"extraArgs":"","project":""}'),
  filters: { q: '', fitOnly: true, hideVariants: true, trustedOnly: false, sort: 'rec' },
};
const saveOpts = () => localStorage.setItem('launchOpts', JSON.stringify(S.opts));

// ---- data loading ----------------------------------------------------------
async function loadApp() { S.app = await api('/api/state'); renderBanner(); renderHardware(); }
async function loadModels() {
  S.models = (await api('/api/models')).models;
  if (!S.models.find(m => m.path === S.selected)) S.selected = (S.models.find(m => m.recommended) || S.models[0] || {}).path || null;
  renderInstalled(); renderLaunch();
}
async function loadServer() {
  const prev = S.server.state, before = JSON.stringify(S.server);
  S.server = await api('/api/server');
  if (JSON.stringify(S.server) === before) return false;
  renderStatus(); renderLaunch(); renderInstalled();
  if (S.server.state === 'exited' && prev === 'loading') toast('The model server exited - see the server log.', true);
  return true;
}
async function loadLogs() {
  if (!$('#cardLogs').open) return;
  const { lines } = await api('/api/logs?lines=120');
  const box = $('#logBox'); const atEnd = box.scrollTop + box.clientHeight >= box.scrollHeight - 20;
  box.textContent = lines.length ? lines.join('\n') : 'No output yet.';
  if (atEnd) box.scrollTop = box.scrollHeight;
}
async function loadProjects() { const r = await api('/api/projects'); S.projects = r.projects; S.projectsRoot = r.root; renderLaunch(); }
async function loadDiscover() { S.discover = await api('/api/discover'); renderDiscover(); renderCounts(); }
async function loadDownloads() {
  const prev = S.downloads;
  S.downloads = (await api('/api/downloads')).downloads;
  const finished = S.downloads.some(d => d.status === 'done' && !(prev.find(p => p.id === d.id)?.status === 'done'));
  if (finished) { toast('Download complete.'); await loadModels(); await loadDiscover(); }
  if (S.tab === 'discover') renderDownloads();
}

// ---- status pill -----------------------------------------------------------
function renderStatus() {
  const s = S.server, pill = $('#statusPill'), txt = $('#statusText');
  pill.className = 'pill ' + (s.state === 'ready' ? 'ready' : s.state === 'loading' ? 'loading' : s.state === 'exited' ? 'exited' : 'stopped');
  txt.textContent = s.state === 'ready' ? `Ready - ${s.model}` : s.state === 'loading' ? `Loading ${s.model}...` : s.state === 'exited' ? 'Server exited unexpectedly' : 'Server stopped';
}
function renderCounts() {
  const n = S.discover.items.filter(i => i.unseen && i.tier !== 'toobig').length;
  $('#cntInstalled').textContent = S.models.length || '';
  $('#cntNew').textContent = n ? n + ' new' : '';
}

// ---- banner (setup problems) -----------------------------------------------
function renderBanner() {
  const b = $('#banner'); b.replaceChildren();
  const a = S.app; if (!a) return;
  const wrap = h('div', { class: 'banner' });
  if (a.hardware.needsInput) {
    wrap.append(hardwareForm(true));
  }
  if (!a.llama.found) wrap.append(h('div', { class: 'note error' }, h('strong', {}, 'llama-server not found'),
    'Set the path to llama-server.exe in Settings so models can be started.'));
  if (!a.claude.path) wrap.append(h('div', { class: 'note' }, h('strong', {}, 'Claude Code CLI not found'),
    'Models can still be started, but launching Claude Code needs the CLI. Install it (official installer: ',
    h('code', {}, 'irm https://claude.ai/install.ps1 | iex'), ') or point Settings at your claude.exe.'));
  if (wrap.children.length) b.append(wrap);
}

// ---- hardware --------------------------------------------------------------
function hardwareForm(prompt) {
  const a = S.app, eff = a.hardware.effective, det = a.hardware.detected;
  const gpu = h('input', { type: 'text', value: a.hardware.override ? eff.gpuName : '', placeholder: 'e.g. NVIDIA RTX 4070' });
  const vram = h('input', { type: 'number', min: 0, step: 0.5, value: eff.vramGB || '', placeholder: '0 if none' });
  const ram = h('input', { type: 'number', min: 1, step: 1, value: Math.round(eff.ramGB) || '', placeholder: 'GB' });
  const save = guard(async () => {
    S.app = await api('/api/hardware', { gpuName: gpu.value, vramGB: Number(vram.value || 0), ramGB: Number(ram.value) });
    toast('Hardware saved.'); renderBanner(); renderHardware(); await loadModels(); await loadDiscover();
  });
  const cancel = prompt ? null : h('button', { class: 'btn', onclick: () => renderHardware() }, 'Cancel');
  const auto = (!prompt && a.hardware.override) ? h('button', { class: 'btn', onclick: guard(async () => {
    S.app = await api('/api/hardware', { clear: true }); renderBanner(); renderHardware(); await loadModels(); await loadDiscover();
  }) }, 'Use auto-detect') : null;
  const gpuList = det.gpus.map(g => g.name).join(', ');
  const box = h('div', { class: prompt ? 'note' : '' },
    prompt ? h('strong', {}, "I couldn't work out your GPU memory automatically - please tell me about your hardware") : null,
    prompt && gpuList ? h('div', { class: 'hint' }, `Detected adapters: ${gpuList}. Windows doesn't report their memory reliably.`) : null,
    h('div', { class: 'row' },
      h('div', { class: 'field' }, h('label', {}, 'GPU name (optional)'), gpu),
      h('div', { class: 'field' }, h('label', {}, 'GPU memory (GB)'), vram),
      h('div', { class: 'field' }, h('label', {}, 'System RAM (GB)'), ram)),
    h('div', { class: 'row', style: 'justify-content:flex-end' }, auto, cancel, h('button', { class: 'btn primary', onclick: save }, 'Save hardware')));
  return box;
}
function renderHardware() {
  const c = $('#cardHardware'); c.replaceChildren();
  const a = S.app; if (!a) return;
  const e = a.hardware.effective;
  c.append(h('h2', {}, 'Hardware', h('span', { class: 'badge' }, e.source === 'manual' ? 'Manual' : 'Auto-detected')));
  c.append(h('dl', { class: 'kv' },
    h('dt', {}, 'GPU'), h('dd', {}, e.gpuName),
    h('dt', {}, 'VRAM'), h('dd', {}, e.vramGB ? fmtGB(e.vramGB) + (e.freeVramGB != null ? ` (${fmtGB(e.freeVramGB)} free)` : '') : 'None'),
    h('dt', {}, 'RAM'), h('dd', {}, e.ramGB ? fmtGB(e.ramGB) : 'Unknown'),
    h('dt', {}, 'CPU'), h('dd', {}, e.cpuName ? `${e.cpuName}${e.cores ? ` (${e.cores}C/${e.threads}T)` : ''}` : 'Unknown')));
  c.append(h('div', { style: 'margin-top:12px;display:flex;gap:8px;align-items:center' },
    h('button', { class: 'btn small', onclick: () => { c.querySelector('.editor')?.remove(); c.append(h('div', { class: 'editor' }, h('div', { class: 'sep' }), hardwareForm(false))); } }, 'Edit hardware'),
    h('span', { class: 'hint', style: 'color:var(--muted);font-size:12px' }, S.app.llama.version || '')));
}

// ---- installed models ------------------------------------------------------
function selectedModel() { return S.models.find(m => m.path === S.selected); }
function renderInstalled() {
  const p = $('#paneInstalled'); p.replaceChildren();
  renderCounts();
  if (!S.models.length) {
    p.append(h('div', { class: 'empty' }, h('strong', {}, 'No local models found.'), h('div', {}, 'Open the Discover tab to find and download one that suits your hardware.'),
      h('div', { style: 'margin-top:12px' }, h('button', { class: 'btn primary', onclick: () => setTab('discover') }, 'Browse models'))));
    return;
  }
  for (const m of S.models) {
    const running = S.server.running && S.server.modelPath === m.path;
    p.append(h('div', { class: 'model' + (m.path === S.selected ? ' selected' : ''), onclick: () => { S.selected = m.path; localStorage.setItem('selectedModel', m.path); renderInstalled(); renderLaunch(); } },
      h('input', { type: 'radio', name: 'm', checked: m.path === S.selected, 'aria-label': 'Select ' + m.name }),
      h('div', {},
        h('div', { class: 'name' }, m.name),
        h('div', { class: 'meta' }, h('span', {}, fmtGB(m.sizeGB)), h('span', {}, m.quant), m.paramsB ? h('span', {}, m.paramsB + 'B params') : null,
          m.mmproj ? h('span', {}, 'vision') : null, m.repo ? h('span', {}, m.repo) : null)),
      h('div', { class: 'tags' }, running ? h('span', { class: 'badge gpu' }, 'Running') : null, m.recommended ? h('span', { class: 'badge rec' }, 'Best fit') : null,
        m.isMoe ? h('span', { class: 'badge' }, 'MoE') : null, fitBadge(m.fit))));
  }
}

// ---- launch card -----------------------------------------------------------
function renderLaunch() {
  const c = $('#cardLaunch'); c.replaceChildren();
  const m = selectedModel(), srv = S.server, busy = srv.state === 'loading' || srv.state === 'ready';
  c.append(h('h2', {}, 'Launch'));

  if (busy) {
    c.append(h('div', { class: 'sel-model' }, h('div', { class: 'name' }, srv.model),
      h('div', { class: 'meta' }, srv.state === 'ready' ? `Serving on ${srv.baseUrl} - ${srv.ctx.toLocaleString()} token context` : 'Loading into memory... this can take a minute.')));
  } else if (m) {
    c.append(h('div', { class: 'sel-model' }, h('div', { class: 'name' }, m.name),
      h('div', { class: 'meta' }, `${fmtGB(m.sizeGB)} - `, fitBadge(m.fit))));
  } else {
    c.append(h('div', { class: 'sel-model' }, h('div', { class: 'meta' }, 'Select an installed model to begin.')));
  }
  if (srv.state === 'exited' && srv.error) c.append(h('div', { class: 'note error' }, h('strong', {}, 'Server exited'), h('pre', { style: 'margin:0;white-space:pre-wrap;font-size:12px;max-height:120px;overflow:auto' }, srv.error)));

  if (!busy) {
    const ctx = h('select', { onchange: e => { S.opts.ctx = Number(e.target.value); saveOpts(); } },
      [16384, 32768, 65536, 131072, 262144].map(v => h('option', { value: v, selected: v === S.opts.ctx }, `${(v / 1024)}k tokens${v === 32768 ? ' (recommended)' : ''}`)));
    c.append(h('div', { class: 'field' }, h('label', {}, 'Context window'), ctx,
      h('div', { class: 'hint' }, 'Claude Code sends large prompts; 32k is the practical minimum. Bigger uses more memory.')));
    const kv = h('input', { type: 'checkbox', checked: S.opts.kvQuant, onchange: e => { S.opts.kvQuant = e.target.checked; saveOpts(); } });
    c.append(h('label', { class: 'check' }, kv, 'Compress KV cache (q8) - saves memory'));
    if (m?.mmproj) {
      const vis = h('input', { type: 'checkbox', checked: S.opts.vision, onchange: e => { S.opts.vision = e.target.checked; saveOpts(); } });
      c.append(h('label', { class: 'check' }, vis, 'Enable image input (loads vision projector)'));
    }
    const extra = h('input', { type: 'text', value: S.opts.extraArgs, placeholder: 'e.g. --n-cpu-moe 12', oninput: e => { S.opts.extraArgs = e.target.value; saveOpts(); } });
    c.append(h('details', { class: 'adv' }, h('summary', {}, 'Advanced'), h('div', { class: 'field' }, h('label', {}, 'Extra llama-server arguments'), extra)));
    c.append(h('button', { class: 'btn primary wide', disabled: !m || !S.app?.llama.found, onclick: guard(async () => {
      await api('/api/server/start', { modelPath: m.path, ctx: S.opts.ctx, kvQuant: S.opts.kvQuant, vision: S.opts.vision && !!m.mmproj, extraArgs: S.opts.extraArgs });
      toast('Starting model...'); await loadServer(); renderInstalled(); $('#cardLogs').open = true;
    }) }, 'Start model'));
  } else {
    c.append(h('button', { class: 'btn danger wide', onclick: guard(async () => { await api('/api/server/stop', {}); toast('Model stopped.'); await loadServer(); renderInstalled(); }) }, 'Stop model'));
  }

  // Force stop: kills every llama-server process, including ones started outside this dashboard.
  const procs = srv.processes || [], others = procs.filter(p => !p.ours);
  const forceStop = guard(async () => {
    const what = procs.map(p => `PID ${p.pid} (port ${p.port})`).join(', ');
    if (!confirm(`Force-kill ${procs.length} llama-server process${procs.length > 1 ? 'es' : ''}?\n\n${what}\n\nAnything using the model will be cut off.`)) return;
    const r = await api('/api/server/force-stop', {});
    if (r.failed.length) toast(`Stopped ${r.killed}; could not stop: ${r.failed.join('; ')}`, true);
    else toast(`Force-stopped ${r.killed} llama-server process${r.killed === 1 ? '' : 'es'}.`);
    await loadServer();
  });
  if (others.length) {
    c.append(h('div', { class: 'note', style: 'margin:12px 0 0' }, h('strong', {}, 'Another llama-server is running'),
      `Not started from this dashboard: ${others.map(p => `PID ${p.pid} on port ${p.port}`).join(', ')}. It can block starting a model on the same port.`,
      h('div', { style: 'margin-top:10px' }, h('button', { class: 'btn danger small', onclick: forceStop }, 'Force stop'))));
  } else if (procs.length) {
    c.append(h('div', { style: 'margin-top:8px;text-align:center' }, h('button', { class: 'btn small ghost', onclick: forceStop }, 'Force stop all llama-server')));
  }

  c.append(h('div', { class: 'sep' }));
  const sel = h('select', { onchange: e => { S.opts.project = e.target.value; saveOpts(); } },
    h('option', { value: S.projectsRoot || '' }, '(projects folder root)'),
    S.projects.map(p => h('option', { value: p.path, selected: p.path === S.opts.project }, p.name)));
  c.append(h('div', { class: 'field' }, h('label', {}, 'Project folder'), sel, h('div', { class: 'hint' }, S.projectsRoot || '')));
  c.append(h('button', { class: 'btn primary wide', disabled: srv.state !== 'ready', title: srv.state === 'ready' ? '' : 'Start a model first', onclick: guard(async () => {
    await api('/api/claude/launch', { mode: 'local', projectDir: sel.value || S.projectsRoot });
    toast('Claude Code launched with the local model.');
  }) }, 'Launch with local model'));

  // Restore: back to normal cloud Claude. Nothing is changed globally - the local-model settings only ever
  // exist inside terminals this dashboard opens - so this opens a clean session and can free the GPU.
  c.append(h('div', { class: 'sep' }));
  c.append(h('h2', {}, 'Back to cloud Claude'));
  const stopLocal = h('input', { type: 'checkbox', checked: S.opts.stopLocal !== false, onchange: e => { S.opts.stopLocal = e.target.checked; saveOpts(); } });
  if (srv.running) c.append(h('label', { class: 'check' }, stopLocal, 'Also stop the local model (frees GPU memory)'));
  c.append(h('button', { class: 'btn wide', onclick: guard(async () => {
    const r = await api('/api/claude/launch', { mode: 'cloud', projectDir: sel.value || S.projectsRoot, stopLocal: srv.running && stopLocal.checked });
    toast(r.stoppedLocal ? 'Cloud Claude Code launched; local model stopped.' : 'Cloud Claude Code launched.');
    if (r.stoppedLocal) await loadServer();
  }) }, 'Restore: launch with cloud Claude'));
  c.append(h('div', { class: 'hint', style: 'margin-top:8px;font-size:12px;color:var(--muted)' },
    'Opens Claude Code with your normal Anthropic login. Existing local-model terminals are unaffected - close them yourself.'));
}

// ---- discover --------------------------------------------------------------
function filteredDiscover() {
  const f = S.filters;
  let items = S.discover.items.filter(i => i.tier !== 'toobig' || !f.fitOnly ? true : false);
  if (f.fitOnly) items = items.filter(i => i.tier !== 'toobig');
  if (f.hideVariants) items = items.filter(i => !i.variant);
  if (f.trustedOnly) items = items.filter(i => i.trusted);
  if (f.q) { const q = f.q.toLowerCase(); items = items.filter(i => i.id.toLowerCase().includes(q)); }
  const by = { rec: (a, b) => b.score - a.score, new: (a, b) => (a.ageDays ?? 1e9) - (b.ageDays ?? 1e9), pop: (a, b) => b.downloads - a.downloads, size: (a, b) => b.paramsB - a.paramsB };
  return items.sort(by[f.sort]);
}
function downloadFor(item) { return S.downloads.find(d => d.repo === item.id && d.status === 'downloading'); }
function startDownload(item, quant) {
  return guard(async () => {
    const withVision = !!item.mmproj && S.opts.vision;
    await api('/api/download', { repo: item.id, files: quant.files, mmproj: withVision });
    toast(`Downloading ${item.name} (${quant.quant})...`); await loadDownloads();
  })();
}
function itemRow(item, compact) {
  let q = item.best;
  const sel = h('select', { 'aria-label': 'Quantization', onchange: e => { q = item.quants.find(x => x.quant === e.target.value); } },
    item.quants.map(x => h('option', { value: x.quant, selected: x.quant === item.best.quant }, `${x.quant} - ${fmtGB(x.sizeGB)}${x.fit.tier === 'toobig' ? ' (too big)' : ''}`)));
  const dl = downloadFor(item);
  const btn = item.installed ? h('span', { class: 'badge gpu' }, 'Installed')
    : dl ? h('span', { class: 'badge' }, 'Downloading...')
      : h('button', { class: 'btn small primary', onclick: () => startDownload(item, q) }, 'Download');
  const title = h('div', { class: 'name' }, item.unseen ? h('span', { class: 'unseen-dot', title: 'New since you last looked' }) : null,
    h('a', { href: item.url, target: '_blank', rel: 'noopener noreferrer' }, item.id));
  const tags = h('div', { class: 'tags', style: 'justify-content:flex-start;margin-top:4px' },
    fitBadge(item.best.fit), item.isNew ? h('span', { class: 'badge new' }, 'New release') : null,
    item.isMoe ? h('span', { class: 'badge' }, 'MoE' + (item.activeB ? ` - ${item.activeB}B active` : '')) : null,
    item.trusted ? h('span', { class: 'badge' }, 'Trusted publisher') : null, item.variant ? h('span', { class: 'badge toobig' }, 'Community variant') : null);
  const meta = h('div', { class: 'meta' }, h('span', {}, item.paramsB + 'B params'), h('span', {}, `${fmtGB(item.best.sizeGB)} (${item.best.quant})`),
    h('span', {}, fmtNum(item.downloads) + ' downloads'), h('span', {}, fmtAge(item.ageDays)));
  if (compact) return h('div', { class: 'pick' }, title, meta, tags, h('div', { class: 'foot' }, h('span', {}), btn));
  return h('div', { class: 'drow' }, h('div', {}, title, meta, tags), h('div', { class: 'actions' }, sel, btn));
}
function renderDownloads() {
  const box = $('#dlBox'); if (!box) return;
  box.replaceChildren();
  const active = S.downloads.filter(d => d.status !== 'cancelled');
  if (!active.length) return;
  box.append(h('div', { class: 'section-title' }, 'Downloads'));
  for (const d of active) {
    const pct = d.totalBytes ? Math.min(100, d.doneBytes / d.totalBytes * 100) : 0;
    box.append(h('div', { class: 'dl' },
      h('div', {}, h('strong', {}, d.repo), h('div', { class: 'meta' }, d.status === 'failed' ? d.error : d.status === 'done' ? 'Complete' : `${fmtGB(d.doneBytes / 2 ** 30)} of ${fmtGB(d.totalBytes / 2 ** 30)} - ${pct.toFixed(0)}%`)),
      d.status === 'downloading' ? h('button', { class: 'btn small', onclick: guard(async () => { await api('/api/download/cancel', { id: d.id }); await loadDownloads(); }) }, 'Cancel') : h('span', { class: 'badge ' + (d.status === 'done' ? 'gpu' : 'toobig') }, d.status),
      d.status === 'downloading' ? h('div', { class: 'progress', style: 'grid-column:1/-1' }, h('div', { style: `width:${pct}%` })) : null));
  }
}
function renderDiscover() {
  const p = $('#paneDiscover'); const hadFocus = document.activeElement?.id === 'qBox';
  p.replaceChildren();
  const d = S.discover, st = d.status || {};
  const refreshing = st.state === 'running';
  const stamp = d.fetchedAt ? 'Updated ' + new Date(d.fetchedAt).toLocaleString() : 'Not fetched yet';
  p.append(h('div', { class: 'section-title' }, h('span', {}, 'Models from Hugging Face ', h('span', { class: 'sub' }, stamp + (refreshing ? ` - ${st.message}` : ''))),
    h('div', { style: 'display:flex;gap:8px' },
      d.items.some(i => i.unseen) ? h('button', { class: 'btn small', onclick: guard(async () => { await api('/api/discover/seen', {}); await loadDiscover(); }) }, 'Mark all seen') : null,
      h('button', { class: 'btn small', disabled: refreshing, onclick: guard(async () => { await api('/api/discover/refresh', {}); await loadDiscover(); pollDiscover(); }) }, refreshing ? 'Refreshing...' : 'Refresh list'))));
  if (st.state === 'error') p.append(h('div', { class: 'note error' }, st.message));
  p.append(h('div', { id: 'dlBox' }));

  if (!d.items.length) {
    p.append(h('div', { class: 'empty' }, refreshing ? 'Fetching the latest models - this takes about half a minute...' : 'No model list yet. Click "Refresh list" (needs an internet connection).'));
    renderDownloads(); return;
  }
  const eff = S.app?.hardware.effective;
  const top = d.items.filter(i => !i.variant && i.trusted && (i.tier === 'gpu' || i.tier === 'moe') && !i.installed).slice(0, 4);
  if (top.length) {
    p.append(h('div', { class: 'section-title' }, h('span', {}, 'Recommended for your hardware'),
      h('span', { class: 'sub' }, eff ? `${eff.gpuName}, ${fmtGB(eff.vramGB)} VRAM, ${fmtGB(eff.ramGB)} RAM` : '')));
    p.append(h('div', { class: 'picks' }, top.map(i => itemRow(i, true))));
  }

  const f = S.filters;
  const q = h('input', { id: 'qBox', type: 'search', placeholder: 'Search models...', value: f.q, oninput: e => { f.q = e.target.value; renderDiscover(); } });
  const chk = (label, key) => h('label', {}, h('input', { type: 'checkbox', checked: f[key], onchange: e => { f[key] = e.target.checked; renderDiscover(); } }), label);
  const sort = h('select', { onchange: e => { f.sort = e.target.value; renderDiscover(); } },
    [['rec', 'Best match'], ['new', 'Newest'], ['pop', 'Most downloaded'], ['size', 'Largest']].map(([v, l]) => h('option', { value: v, selected: f.sort === v }, l)));
  p.append(h('div', { class: 'filters' }, q, sort, chk('Fits my hardware', 'fitOnly'), chk('Hide community variants', 'hideVariants'), chk('Trusted publishers only', 'trustedOnly')));
  const list = filteredDiscover();
  if (!list.length) p.append(h('div', { class: 'empty' }, 'Nothing matches these filters.'));
  for (const i of list.slice(0, 60)) p.append(itemRow(i, false));
  if (list.length > 60) p.append(h('div', { class: 'empty' }, `${list.length - 60} more - narrow the search to see them.`));
  renderDownloads();
  if (hadFocus) { const b = $('#qBox'); b.focus(); b.setSelectionRange(b.value.length, b.value.length); }
}
let discTimer;
function pollDiscover() {
  clearTimeout(discTimer);
  discTimer = setTimeout(async () => {
    try { await loadDiscover(); } catch { }
    if (S.discover.status?.state === 'running') pollDiscover();
  }, 2500);
}

// ---- settings --------------------------------------------------------------
function openSettings() {
  const s = S.app.settings, dlg = $('#dlgSettings');
  const f = (label, el, hint) => h('div', { class: 'field' }, h('label', {}, label), el, hint ? h('div', { class: 'hint' }, hint) : null);
  const llama = h('input', { type: 'text', value: s.llamaServerPath });
  const claude = h('input', { type: 'text', value: s.claudePath, placeholder: S.app.claude.path || 'auto-detect' });
  const dirs = h('textarea', {}, (s.modelDirs || []).join('\n'));
  const dldir = h('input', { type: 'text', value: s.downloadDir });
  const proj = h('input', { type: 'text', value: s.projectsDir });
  const port = h('input', { type: 'number', value: s.llamaPort });
  dlg.replaceChildren(h('h2', {}, 'Settings'),
    f('llama-server.exe', llama, S.app.llama.version || ''),
    f('Claude Code CLI (optional override)', claude, S.app.claude.path ? 'Detected: ' + S.app.claude.path : 'Not detected - enter the full path to claude.exe'),
    f('Model folders (one per line)', dirs, 'Scanned recursively for .gguf files.'),
    f('Download folder', dldir, 'Keep this outside cloud-synced folders - models are many GB.'),
    f('Projects folder', proj),
    f('Model server port', port),
    h('div', { class: 'actions' }, h('button', { class: 'btn', onclick: () => dlg.close() }, 'Cancel'),
      h('button', { class: 'btn primary', onclick: guard(async () => {
        S.app = await api('/api/settings', { llamaServerPath: llama.value, claudePath: claude.value, modelDirs: dirs.value.split('\n'), downloadDir: dldir.value, projectsDir: proj.value, llamaPort: Number(port.value) });
        dlg.close(); toast('Settings saved.'); renderBanner(); renderHardware(); await Promise.all([loadModels(), loadProjects(), loadDiscover()]);
      }) }, 'Save')));
  dlg.showModal();
}

// ---- tabs / boot -----------------------------------------------------------
function setTab(t) {
  S.tab = t;
  document.querySelectorAll('.tab').forEach(b => b.classList.toggle('active', b.dataset.tab === t));
  $('#paneInstalled').hidden = t !== 'installed'; $('#paneDiscover').hidden = t !== 'discover';
  if (t === 'discover') { loadDiscover().catch(() => { }); loadDownloads().catch(() => { }); if (S.discover.status?.state === 'running') pollDiscover(); }
}
document.querySelectorAll('.tab').forEach(b => b.addEventListener('click', () => setTab(b.dataset.tab)));
$('#btnSettings').addEventListener('click', () => openSettings());
$('#cardLogs').addEventListener('toggle', () => loadLogs());

(async function boot() {
  try {
    await loadApp();
    await Promise.all([loadModels(), loadServer(), loadProjects(), loadDiscover(), loadDownloads()]);
    if (S.discover.status?.state === 'running') pollDiscover();
  } catch (e) { toast('Cannot reach the dashboard server: ' + e.message, true); }
  setInterval(() => loadServer().catch(() => { }), 2500);
  setInterval(() => loadLogs().catch(() => { }), 2500);
  setInterval(() => { if (S.downloads.some(d => d.status === 'downloading') || S.tab === 'discover') loadDownloads().catch(() => { }); }, 1500);
})();

// lambscape: ванильный JS без сборки и внешних запросов.
// Данные API — только через textContent; innerHTML — лишь для своих SVG-строк.
'use strict';

(() => {
  const TOKEN = (document.querySelector('meta[name="lambscape-token"]') || {}).content || '';
  const THEMES = { onedark: 'One Dark', teal: 'Teal', navy: 'Navy', nord: 'Nord', light: 'One Light' };
  const DENSITY = { compact: 'Плотно', normal: 'Обычно', comfy: 'Свободно' };
  const FONTS = [12, 13, 14, 15];
  const ACCENTS = { blue: 'синий', cyan: 'бирюзовый', green: 'зелёный', yellow: 'жёлтый', orange: 'оранжевый', red: 'красный', purple: 'фиолетовый' };
  const TABS = ['overview', 'sessions', 'bots', 'memory'];
  const NA = '—';

  // --- localStorage: в приватном окне может бросать ---
  const store = {
    get(k, d) { try { const v = localStorage.getItem('lambscape.' + k); return v == null ? d : JSON.parse(v); } catch { return d; } },
    set(k, v) { try { localStorage.setItem('lambscape.' + k, JSON.stringify(v)); } catch { /* без памяти — не беда */ } },
  };

  // --- тема: применяем сразу, скрипт стоит в <head> ---
  const saved = Object(store.get('theme', {}));
  const prefs = {
    preset: Object.hasOwn(THEMES, String(saved.preset)) ? saved.preset : 'onedark',
    accent: typeof saved.accent === 'string' ? saved.accent : '',
    density: Object.hasOwn(DENSITY, String(saved.density)) ? saved.density : 'normal',
    font: FONTS.includes(saved.font) ? saved.font : 13,
  };
  // ?theme=&density= — без записи (для скриншотов)
  const look = { ...prefs };
  const query = new URLSearchParams(location.search);
  if (Object.hasOwn(THEMES, String(query.get('theme')))) look.preset = query.get('theme');
  if (Object.hasOwn(DENSITY, String(query.get('density')))) look.density = query.get('density');
  applyTheme();
  // вид: «Подробно» по умолчанию, выбор помнится; ?view=simple|full — поверх, без записи
  const qv = query.get('view');
  let simple = (qv === 'simple' || qv === 'full' ? qv : store.get('view', 'full')) === 'simple';
  document.documentElement.dataset.view = simple ? 'simple' : 'full';

  function applyTheme() {
    const r = document.documentElement;
    r.dataset.theme = look.preset;
    r.dataset.density = look.density;
    r.style.setProperty('--fs', look.font + 'px');
    const a = look.accent;
    if (/^#[0-9a-f]{6}$/i.test(a)) r.style.setProperty('--accent', a);
    else if (Object.hasOwn(ACCENTS, a)) r.style.setProperty('--accent', `var(--${a})`);
    else r.style.removeProperty('--accent');
    r.style.removeProperty('--accent-ink');
    if (a) {
      // текст на акценте: белый или тёмный — что контрастнее
      const L = lum(getComputedStyle(r).getPropertyValue('--accent'));
      if (L != null) r.style.setProperty('--accent-ink', 1.05 / (L + 0.05) >= (L + 0.05) / 0.058 ? '#ffffff' : '#14161b');
    }
  }

  function lum(hex) {
    const m = /^#?([0-9a-f]{6})$/i.exec(String(hex).trim());
    if (!m) return null;
    const c = [0, 2, 4].map((i) => parseInt(m[1].slice(i, i + 2), 16) / 255)
      .map((v) => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  }

  function setPref(k, v) {
    prefs[k] = v;
    look[k] = v;
    store.set('theme', prefs);
    applyTheme();
    syncPop();
    if (tab === 'memory') drawHistory();
  }

  // --- DOM ---
  const $ = (sel, root = document) => root.querySelector(sel);
  const arr = (v) => (Array.isArray(v) ? v : []);
  const own = (map, key) => (typeof key === 'string' && Object.hasOwn(map, key) ? map[key] : undefined);

  function h(tag, props, ...kids) {
    const n = document.createElement(tag);
    if (tag === 'button') n.type = 'button'; // не submit: форм вокруг почти нет
    for (const [k, v] of Object.entries(props || {})) {
      if (v == null || v === false) continue;
      if (k === 'class') n.className = v;
      else if (k === 'text') n.textContent = v;
      else if (k === 'html') n.innerHTML = v;
      else if (k === 'value') n.value = v;
      else if (k.startsWith('on')) n.addEventListener(k.slice(2), v);
      else n.setAttribute(k, v === true ? '' : v);
    }
    for (const c of kids.flat(Infinity)) if (c != null && c !== false && c !== '') n.append(c);
    return n;
  }

  const SVG = {
    restart: '<path d="M13.2 8a5.2 5.2 0 1 1-1.6-3.8"/><path d="M13.2 2.6v3.2H10"/>',
    copy: '<rect x="5.5" y="5.5" width="8" height="8" rx="1.6"/><path d="M10.5 5.5V3.8a1.3 1.3 0 0 0-1.3-1.3H3.8a1.3 1.3 0 0 0-1.3 1.3v5.4a1.3 1.3 0 0 0 1.3 1.3h1.7"/>',
    ext: '<path d="M9.5 2.5h4v4M13.5 2.5 8 8M11.5 9.5v3a1 1 0 0 1-1 1h-7a1 1 0 0 1-1-1v-7a1 1 0 0 1 1-1h3"/>',
    stop: '<rect x="4.2" y="4.2" width="7.6" height="7.6" rx="1.5"/>',
    chev: '<path d="m6 3.5 4.5 4.5L6 12.5"/>',
    warn: '<path d="M8 2.5 14 13H2L8 2.5ZM8 6.5v3M8 11.3v.2"/>',
    check: '<path d="m3.5 8.5 3 3 6-7"/>',
    close: '<path d="m4 4 8 8M12 4l-8 8"/>',
  };
  const icon = (name, cls = '') => h('span', { class: 'ico ' + cls, 'aria-hidden': 'true', html: `<svg viewBox="0 0 16 16">${SVG[name]}</svg>` });

  // --- форматирование ---
  const isNum = (v) => typeof v === 'number' && Number.isFinite(v);
  const num0 = (v) => (isNum(v) ? v : 0);
  const txt = (v) => (v == null || v === '' ? NA : String(v));
  const sum = (list) => list.reduce((s, v) => s + num0(v), 0);
  const gb = (v) => (!isNum(v) ? NA : v % 1024 === 0 ? String(v / 1024) : (v / 1024).toFixed(1));
  const mb = (v) => (!isNum(v) ? NA : v < 1024 ? Math.round(v) + ' MB' : gb(v) + ' GB');
  const pct = (a, b) => (isNum(a) && isNum(b) && b > 0 ? Math.round((a / b) * 100) + '%' : NA);
  const fx = (x) => String(x >= 10 ? Math.round(x) : +x.toFixed(1)); // 3 · 9.6 · 108
  function dur(s) {
    if (!isNum(s) || s < 0) return NA;
    if (s < 60) return Math.round(s) + ' с';
    if (s < 3600) return Math.round(s / 60) + ' мин';
    if (s < 36000) return +(s / 3600).toFixed(1) + ' ч';
    if (s < 172800) return Math.round(s / 3600) + ' ч';
    return Math.round(s / 86400) + ' д';
  }
  const nowTs = () => (snap && isNum(snap.ts) ? snap.ts : Date.now() / 1000);
  const since = (ts) => (isNum(ts) ? dur(nowTs() - ts) : NA);
  const hhmm = (ts) => new Date(ts * 1000).toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' });
  const hms = (ts) => (isNum(ts) ? new Date(ts * 1000).toLocaleTimeString('ru-RU') : NA);
  const home = (p) => (typeof p === 'string' && p ? p.replace(/^\/Users\/[^/]+/, '~') : null);
  const safeUrl = (u) => (typeof u === 'string' && /^https?:\/\/[^\s]+$/i.test(u) ? u : null);
  function plural(n, one, few, many) {
    const a = n % 10, b = n % 100;
    return `${n} ${a === 1 && b !== 11 ? one : a >= 2 && a <= 4 && (b < 12 || b > 14) ? few : many}`;
  }

  // --- API ---
  async function api(path, body, ms) {
    const opts = body === undefined ? { cache: 'no-store' } : {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Lambscape-Token': TOKEN },
      body: JSON.stringify(body),
    };
    if (ms) opts.signal = AbortSignal.timeout(ms);
    const res = await fetch(path, opts);
    const data = await res.json().catch(() => null);
    if (!res.ok) {
      const e = new Error((data && data.error) || 'HTTP ' + res.status);
      e.status = res.status;
      throw e;
    }
    return data;
  }
  // kind: '' | 'quiet' | 'bad' (висит дольше — успеть прочитать stderr)
  function toast(text, kind = '') {
    const t = $('#toast');
    t.textContent = text;
    t.className = 'toast show ' + kind;
    clearTimeout(toast.timer);
    const ms = kind === 'bad' ? Math.min(12000, 4000 + String(text).length * 30) : kind === 'quiet' ? 1800 : 2800;
    toast.timer = setTimeout(() => t.classList.remove('show'), ms);
  }

  // --- состояние ---
  let snap = null;
  let snapText = '';
  let online = true;
  let tab = 'overview';
  const openSet = new Set(); // раскрытые <details> переживают перерисовку раз в 3 с
  const touched = new Set(); // тронутые пользователем — не раскрываем сами

  // --- опрос: раз в 3 с, только пока вкладка видна ---
  let polling = false;
  async function poll() {
    clearTimeout(poll.timer);
    if (polling || document.visibilityState !== 'visible') return;
    polling = true;
    let fresh = null;
    try {
      const res = await fetch('/api/snapshot', { cache: 'no-store' });
      if (!res.ok) throw new Error('HTTP ' + res.status);
      const text = await res.text();
      if (text !== snapText) {
        fresh = JSON.parse(text);
        snapText = text;
      }
      setOnline(true);
    } catch {
      setOnline(false);
    } finally {
      polling = false;
      if (document.visibilityState === 'visible') poll.timer = setTimeout(poll, 3000);
    }
    // ответ старше показанного не рисуем
    if (fresh && !(snap && fresh.ts < snap.ts)) render(fresh);
  }

  // «Обновить»: ?fresh=1, не чаще раза в 5 с
  let refreshing = 0;
  async function refresh(afterAction) {
    const btn = $('#refresh-btn');
    refreshing++;
    btn.disabled = true;
    btn.classList.add('spinning');
    try {
      const res = await fetch('/api/snapshot?fresh=1', { cache: 'no-store' });
      if (!res.ok) throw new Error('HTTP ' + res.status);
      const text = await res.text();
      const s = JSON.parse(text);
      snapText = text;
      setOnline(true);
      render(s);
      if (!s.fresh_throttled) justNow();
      else if (!afterAction) toast('Уже обновлено секунду назад', 'quiet');
      else { clearTimeout(poll.timer); poll.timer = setTimeout(poll, 1600); } // кэш мог быть снят до действия — дочитаем
    } catch {
      if (!afterAction) toast('Не удалось обновить — панель не отвечает', 'bad');
    } finally {
      if (--refreshing === 0) {
        btn.disabled = false;
        btn.classList.remove('spinning');
      }
    }
  }

  function justNow() {
    const n = $('#h-fresh');
    n.hidden = false;
    clearTimeout(justNow.timer);
    justNow.timer = setTimeout(() => { n.hidden = true; }, 8000);
  }

  function setOnline(ok) {
    const was = online;
    online = ok;
    const t = $('#h-time');
    t.classList.toggle('stale', !ok);
    t.textContent = ok ? hms(snap && snap.ts) : 'нет связи';
    if (!snap && was !== ok) renderTab();
  }

  let hist = null;
  let histState = 'loading';
  let histAt = 0;
  // история — раз в минуту и только пока график виден: в «Памяти», а в «Просто» и в «Обзоре» (мини-график)
  const histTab = () => tab === 'memory' || (simple && tab === 'overview');
  async function pollHistory() {
    clearTimeout(pollHistory.timer);
    if (document.visibilityState !== 'visible' || !histTab()) return;
    try {
      hist = await api('/api/history?hours=24');
      histState = 'ok';
    } catch {
      histState = 'error';
    }
    histAt = Date.now();
    if (histTab()) drawHistory();
    pollHistory.timer = setTimeout(pollHistory, 60000);
  }
  const histSoon = () => {
    clearTimeout(pollHistory.timer);
    pollHistory.timer = setTimeout(pollHistory, Math.max(0, 60000 - (Date.now() - histAt)));
  };

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') {
      poll();
      histSoon();
    } else {
      clearTimeout(poll.timer);
      clearTimeout(pollHistory.timer);
    }
  });

  // --- отрисовка ---
  function render(s) {
    if (!s || typeof s !== 'object') return;
    snap = s;
    for (const id of sel) if (!own(s.actions || {}, id)) sel.delete(id); // цель ушла из снимка — снимаем галочку
    if (document.readyState === 'loading') return; // дорисует init
    renderHeader();
    renderTab();
    // карта сменила цвета групп — перекрашиваем и график
    if (!simple && tab === 'memory' && hist && histColors(arr(hist.series)).join() !== drawHistory.sig) drawHistory();
    bulkBar();
    if (!render.booted) {
      render.booted = true;
      setTimeout(() => document.body.classList.remove('boot'), 900);
    }
  }

  // Подменяет детей, сохраняя фокус по data-key; пока зажата кнопка или выделен текст — не трогает
  let pressedAt = 0; // не дольше 1.5 с: pointerup мог потеряться за окном
  function swap(el, kids) {
    const sel = getSelection();
    if (Date.now() - pressedAt < 1500 || (sel && !sel.isCollapsed && el.contains(sel.anchorNode))) return;
    const key = el.contains(document.activeElement) ? document.activeElement.dataset.key : null;
    // прокрутка списков переживает перерисовку
    const top = new Map([...el.querySelectorAll('[data-scroll]')].map((n) => [n.dataset.scroll, n.scrollTop]));
    el.replaceChildren(...kids.flat(Infinity).filter(Boolean));
    for (const n of el.querySelectorAll('[data-scroll]')) n.scrollTop = top.get(n.dataset.scroll) || 0;
    if (key) {
      const n = el.querySelector(`[data-key="${CSS.escape(key)}"]`);
      if (n) n.focus({ preventScroll: true });
    }
  }

  function renderTab() {
    const el = tab === 'memory' ? $('#mem-a') : $('#v-' + tab);
    if (!snap) {
      return swap(el, [h('section', { class: 'card' },
        none(online ? 'Загружаю снимок…' : 'Панель не отвечает — сервер lambscape выключен? Включить: lambscape on'))]);
    }
    // «Память»: слева карта, подсказки, график, диск; справа — что освободить, группы. В «Просто» — итог и кто больше всех
    if (tab === 'memory') {
      swap(el, simple ? [simpleMem()] : [memCard(true), adviceCard(true)]);
      swap($('#disk'), simple ? [] : diskCard());
      return swap($('#mem-b'), simple ? [topCard()] : viewMemory());
    }
    swap(el, (simple ? SIMPLE : { overview: viewOverview, sessions: viewSessions, bots: viewBots })[tab]());
  }

  const PRESSURE = { normal: ['ok', 'норма'], warn: ['warn', 'высокое'], critical: ['bad', 'критическое'] };
  const swapHot = (m) => isNum(m.swap_used_mb) && m.swap_total_mb > 0 && m.swap_used_mb / m.swap_total_mb > 0.7;

  function renderHeader() {
    const m = snap.memory || {};
    const [cls, label] = own(PRESSURE, m.pressure) || ['', NA];
    const p = $('#h-pressure');
    p.className = 'chip st ' + cls;
    $('b', p).textContent = label;
    const sw = $('#h-swap');
    sw.textContent = `своп ${gb(m.swap_used_mb)}/${gb(m.swap_total_mb)} GB`;
    sw.classList.toggle('hot', swapHot(m));
    const t = $('#h-time');
    t.textContent = hms(snap.ts);
    if (isNum(snap.ts)) t.dateTime = new Date(snap.ts * 1000).toISOString();
    $('#h-ram').replaceChildren(...memSegments(m));
    const S = snap.sessions || {};
    const bots = arr(snap.bots);
    $('#n-sessions').textContent = arr(S.claude).length || '';
    $('#n-bots').textContent = bots.length ? `${bots.filter((b) => b.status === 'running').length}/${bots.length}` : '';
    // ни ботов, ни агентов — вкладку не показываем; по #bots она всё равно открывается
    $('.tabs a[data-tab="bots"]').hidden = !bots.length && !arr(snap.agents).length;
    revealTab();
    const me = snap.self || {}, host = snap.host || {};
    $('#foot').textContent = [
      `lambscape · ${simple ? '' : `PID ${txt(me.pid)} · `}${mb(me.mem_mb)} · CPU ${isNum(me.cpu_pct) ? me.cpu_pct + '%' : NA}`,
      `${txt(host.chip)} · ${gb(host.ram_mb)} GB · macOS ${txt(host.macos)} · аптайм ${dur(host.uptime_s)}`,
    ].join('  ·  ');
  }

  // --- память: части полосы и легенды — кнопки разбора ---
  // [ключ, имя, цвет, id разбора, образец: mix — программы, hw/hc — «не чистится»]
  const PARTS = [
    ['app_mb', 'Приложения', 'c0', 'app', 'mix'], ['wired_mb', 'Зарезервировано', 'c2', 'wired', 'hw'],
    ['compressed_mb', 'Сжато', 'c1', 'compressed', 'mix'], ['cached_mb', 'Кэш файлов', 'c5', 'cached', 'hc'], ['free_mb', 'Свободно', 'free', 'free', 'free'],
  ];
  // цвет программы один во всех категориях; девятой — серый
  const PAL = ['c0', 'c1', 'c2', 'c3', 'c4', 'c7', 'c6', 'c8'];
  const slots = new Map(); // color_key → слот: цвет не прыгает между опросами
  const pc = (key, ck = key) => (key === 'macos' ? 'cm' : slots.has(ck) ? PAL[slots.get(ck)] : 'cr');
  // раздаёт слоты; легенда [имя, MB, цвет]
  function paint(split) {
    const tot = new Map(), names = new Map(), ends = { macos: ['macOS', 0, 'cm'], rest: ['прочее', 0, 'cr'] };
    for (const r of [...arr(split.app), ...arr(split.compressed)]) {
      if (ends[r.key]) ends[r.key][1] += num0(r.mb);
      else {
        tot.set(r.color_key, num0(tot.get(r.color_key)) + num0(r.mb));
        names.set(r.color_key, r.name);
      }
    }
    for (const k of slots.keys()) if (!tot.has(k)) slots.delete(k);
    const order = [...tot.keys()].sort((a, b) => tot.get(b) - tot.get(a));
    for (const k of order) {
      const free = PAL.findIndex((_, i) => ![...slots.values()].includes(i));
      if (free < 0) break;
      if (!slots.has(k)) slots.set(k, free);
    }
    for (const k of order.filter((x) => !slots.has(x))) ends.rest[1] += tot.get(k); // без своего цвета — в «прочее»
    return [ends.macos, ...order.filter((k) => slots.has(k)).map((k) => [names.get(k), tot.get(k), pc(k)]), ends.rest].filter((x) => x[1] > 0);
  }
  const CAN = { yes: 'можно освободить', partly: 'частично: помогает закрыть тяжёлые графические программы', no: 'не освобождается вручную' };
  // части категории [имя, MB, цвет, можно ли освободить, color_key]
  function partsOf(m, [k, name, c, id, sw]) {
    const can = own(CAN, own(m.cleanable || {}, id)) || '';
    const pos = (r) => (r.key === 'macos' ? -1 : r.key === 'rest' ? 9 : slots.has(r.color_key) ? slots.get(r.color_key) : 8);
    const split = [...arr((m.split || {})[id])].sort((a, b) => pos(a) - pos(b));
    if (split.length) {
      return split.map((r) => [txt(r.name), r.mb, pc(r.key, r.color_key), r.key === 'macos' ? 'службы macOS — что можно сделать, в группе «Система»' : can, r.color_key]);
    }
    if (id === 'wired') {
      const named = Math.min(num0(m[k]), sum(arr(((m.breakdown || {}).wired || {}).top).map((p) => p.mb)));
      return [['программы: GPU и драйверы', named, 'cr', can], ['ядро macOS, драйверы, видеопамять', num0(m[k]) - named, 'hw', CAN.no]];
    }
    return [[name, m[k], sw === 'mix' ? c : sw, id === 'cached' ? 'освобождается сам: macOS отдаст, когда понадобится' : id === 'free' ? '' : can]];
  }
  const shown = (m) => PARTS.filter(([k]) => isNum(m[k]) && m[k] > 0);
  // полоса в шапке — та же карта в 3 px; в «Просто» — только категории, без цветов программ
  function memSegments(m) {
    paint(m.split || {});
    return shown(m).map((p) => {
      const i = h('i', { class: simple ? p[2] : null, title: `${p[1]}: ${mb(m[p[0]])}` }, simple ? null : subs(m, p));
      i.style.flexGrow = m[p[0]];
      return i;
    });
  }
  // части категории — <i> с долей и данными для всплывашки
  const subs = (m, p) => partsOf(m, p).filter((x) => num0(x[1]) > 0).map((x) => {
    const i = h('i', { class: x[2] });
    i.style.flexGrow = x[1];
    i._t = [p[1], ...x];
    return i;
  });

  let drill = null; // раскрытый разбор: id части или 'ai'; один на панель
  // только в открытой вкладке: скрытые хранят те же data-key
  const focusKey = (key) => {
    const n = key && $(`#v-${tab} [data-key="${CSS.escape(key)}"]`);
    if (n) n.focus({ preventScroll: true });
  };
  function toggleDrill(id) {
    const was = drill;
    drill = drill === id ? null : id;
    renderTab();
    if (!drill) focusKey(was === 'ai' ? 'kpi:ai' : 'leg:' + was);
  }

  function memCard(big) {
    const m = snap.memory || {};
    const S = m.summary;
    const progs = paint(m.split || {});
    const kern = partsOf(m, PARTS[1]).at(-1)[1];
    if (progs.length) progs.splice(1, 0, ['ядро и драйверы', kern, 'hw']);
    const held = sum(arr(snap.groups).map((g) => g.mem_mb));
    const out = sum(arr((m.breakdown || {}).app).map((r) => r.swapped_mb));
    const open = PARTS.find((p) => p[3] === drill);
    const tap = (id) => ({ 'aria-expanded': String(drill === id), onclick: () => toggleDrill(id) });
    return h('section', { class: 'card' },
      h('h2', { class: 'h' }, 'Память', h('span', { class: 'n', text: gb(m.total_mb) + ' GB' }),
        h('span', { class: 'r mono', text: `занято ${gb(m.used_mb)} GB · ${pct(m.used_mb, m.total_mb)}` })),
      S ? h('p', { class: 'sum' }, 'macOS ≈ ', h('b', { text: mb(S.macos_mb) }), kern > 0 ? [' + ядро ', h('b', { text: mb(kern) })] : null,
        ' · твои программы ≈ ', h('b', { text: mb(S.programs_mb) }),
        ' · кэш ', h('b', { text: mb(S.cache_mb) }), ' (освобождается сам)') : null,
      // полоса — для мыши: наведение — всплывашка, клик — разбор
      h('div', { class: 'comp' + (big ? ' big' : '') + (open ? ' open' : '') }, shown(m).map((p) => {
        const b = h('button', { ...tap(p[3]), class: 'seg', tabindex: '-1', 'aria-label': `${p[1]}: ${mb(m[p[0]])}` }, subs(m, p));
        b.style.flexGrow = m[p[0]];
        return b;
      })),
      h('div', { class: 'legend tap' }, PARTS.map(([k, n, , id, sw]) => h('button', { ...tap(id), 'data-key': 'leg:' + id },
        h('i', { class: sw }), n, id === 'wired' ? h('span', { class: 'muted', text: 'ядро, драйверы, видеопамять' }) : null, h('b', { text: mb(m[k]) })))),
      open ? memDrill(open, m) : null,
      big && progs.length ? h('div', { class: 'legend progs' }, h('span', { class: 'cap', text: 'кто держит:' }),
        progs.filter((x) => num0(x[1]) > 0).map(([n, v, c]) => h('span', {}, h('i', { class: c }), h('span', { class: 'nm', title: n, text: n }), h('b', { text: mb(v) })))) : null,
      big && held > 0 ? h('p', {
        class: 'note-line',
        text: `Программы держат ${mb(held)}, из них ${mb(out)} сжато или в свопе` + (held > num0(m.total_mb) ? ` — поэтому сумма больше ${gb(m.total_mb)} GB.` : '.'),
      }) : null);
  }

  // всплывашка части полосы и мини-графика «Просто», одна на страницу; _tip(x) — строки для точки под мышью
  function tipAt(e) {
    const t = $('#mtip'), i = e.target.closest && e.target.closest('.comp i, .spark');
    const rows = i && (i._tip ? i._tip(e.clientX) : i._t && partTip(i._t));
    t.hidden = !rows;
    if (t.hidden) return;
    t.replaceChildren(...rows);
    const w = t.offsetWidth, ht = t.offsetHeight;
    t.style.left = Math.max(8, Math.min(e.clientX - w / 2, innerWidth - w - 8)) + 'px';
    t.style.top = (e.clientY - ht - 14 < 8 ? e.clientY + 18 : e.clientY - ht - 14) + 'px';
  }
  function partTip([cat, n, v, c, can, ck]) {
    const fc = ck && arr((snap.memory || {}).free_candidates).find((x) => x.key === ck);
    return [h('div', { class: 'tt' }, h('i', { class: c }), h('span', { class: 'trunc', text: n })),
      h('div', {}, cat + ' · ', h('b', { text: mb(v) })), can && h('div', { text: can }),
      fc && fc.hint && h('div', { class: 'muted', text: fc.hint })].filter(Boolean); // null в replaceChildren стал бы текстом «null»
  }

  // «Что можно освободить»: кнопки или подсказка
  function freeCard() {
    const list = arr((snap.memory || {}).free_candidates);
    return list.length ? h('section', { class: 'card' },
      h('h2', { class: 'h' }, 'Что можно освободить', h('span', { class: 'r', text: 'в RAM + сжато' })),
      list.map((c) => h('div', { class: 'fc' },
        h('div', { class: 'fh' }, h('i', { class: pc(c.key) }), h('span', { class: 'trunc nm', title: txt(c.name), text: txt(c.name) }),
          h('span', { class: 'dv', text: `${mb(c.ram_mb)} + ${mb(c.compressed_mb)}` }), h('b', { text: mb(num0(c.ram_mb) + num0(c.compressed_mb)) })),
        arr(c.action_ids).filter((id) => own(snap.actions || {}, id)).map((id) => h('div', { class: 'fa' }, pick(id) || h('span', { class: 'nopick' }),
          h('span', { class: 'trunc', title: actionInfo(id).confirm || '', text: actionInfo(id).label || id }), actBtn(id, 'fc:'))),
        c.hint ? h('p', { class: 'dnote', text: c.hint }) : null))) : null;
  }

  function drillBox(id, title, color, total, body) {
    return h('div', { class: 'drill', role: 'region', 'aria-label': 'Разбор: ' + title },
      h('div', { class: 'dh' }, color ? h('i', { class: color }) : null, h('span', { class: 'dt', text: title }), h('b', { text: total }),
        h('button', { class: 'icon ghost', 'aria-label': 'Свернуть', title: 'Свернуть (Esc)', onclick: () => toggleDrill(id) }, icon('close'))),
      body);
  }
  const dnote = (text) => h('p', { class: 'dnote', text });
  const none = (text) => h('p', { class: 'empty', text });
  // полоска доли: у «Приложений» — в RAM и сжато/своп
  function share(vals, max) {
    return h('span', { class: 'dbar', 'aria-hidden': 'true' }, vals.map((v) => {
      const i = h('i');
      i.style.width = Math.min(100, (num0(v) / max) * 100) + '%';
      return i;
    }));
  }
  const dname = (name, extra) => h('span', { class: 'dn' }, h('span', { class: 'trunc nm', title: txt(name), text: txt(name) }), extra);

  const GKIND = { project: ['g-project', 'проект'], app: ['g-app', 'приложение'], system: ['low', 'система'], other: ['low', 'прочее'] };
  function memDrill([key, name, , id, color], m) {
    const bd = m.breakdown;
    let body;
    if (id === 'free') body = dnote('Ничем не занятая память. Мало свободной — это нормально: macOS сразу отдаёт лишнее под кэш файлов.');
    else if (!bd || typeof bd !== 'object') body = none('Сервер пока не присылает разбор этой части.');
    else if (id === 'app') {
      const list = arr(bd.app);
      const max = Math.max(1, ...list.map((r) => num0(r.ram_mb) + num0(r.swapped_mb)));
      body = list.length ? [h('div', { class: 'drows' }, list.map((r) => {
        const [kc, kl] = own(GKIND, r.kind) || GKIND.other;
        return h('div', { class: 'drow' }, dname(r.name, h('span', { class: 'badge ' + kc, text: kl })),
          h('span', { class: 'dv' }, 'в RAM ', h('b', { text: mb(r.ram_mb) }), ' · сжато/своп ', h('b', { text: mb(r.swapped_mb) })),
          share([r.ram_mb, r.swapped_mb], max));
      })), dnote('В RAM процесса входят и общие с другими страницы — сумма строк бывает больше «Приложений».')]
        : none('Нет данных о процессах в RAM.');
    } else if (id === 'compressed') {
      const list = arr(bd.compressed);
      body = list.length ? [dnote('Сколько у процесса сжато или выгружено в своп: footprint минус то, что в RAM.'),
        h('div', { class: 'drows' }, list.map((r) => h('div', { class: 'drow' }, pick(r.action_id, r.name),
          h('span', { class: 'dn col' }, h('span', { class: 'trunc nm', title: `${txt(r.name)} · PID ${txt(r.pid)}`, text: txt(r.name) }),
            h('span', { class: 'trunc muted small', text: txt(r.group) })),
          h('span', { class: 'num', text: mb(r.mb) }),
          r.action_id ? actBtn(r.action_id, 'drill:') : null)))]
        : none('Сжатого и выгруженного в своп почти нет.');
    } else if (id === 'wired') {
      const w = bd.wired || {};
      const list = arr(w.top);
      body = [w.note ? dnote(w.note) : null, list.length ? h('div', { class: 'drows' }, list.map((r) => h('div', { class: 'drow' },
        dname(r.name, h('span', { class: 'pid', text: 'PID ' + txt(r.pid) })), h('span', { class: 'num', text: mb(r.mb) }))))
        : none('Своих процессов с заметной зарезервированной памятью нет.')];
    } else body = (bd.cached || {}).note ? dnote(bd.cached.note) : none('Пояснения нет.');
    return drillBox(id, name, color, mb(m[key]), body);
  }

  // --- обзор ---
  function viewOverview() {
    return [kpiStrip(),
      h('div', { class: 'span' }, memCard(false)),
      h('div', { class: 'col' }, adviceCard()),
      h('div', { class: 'col' }, sessionsCompact(), arr(snap.bots).length || arr(snap.agents).length ? botsCompact() : null)];
  }

  // плитка-кнопка (props) раскрывает разбор
  function kpi(label, value, unit, sub, warn, props) {
    return h(props ? 'button' : 'div', { class: 'kpi', ...props },
      h('span', { class: 'l' }, warn ? h('i', { class: 'dot warn' }) : null, h('span', { class: 'trunc', title: label, text: label }),
        props ? icon('chev', 'chev') : null),
      h('span', { class: 'v' }, value, value !== NA && unit ? h('small', { text: unit }) : null),
      h('span', { class: 's trunc', text: sub }));
  }

  function kpiStrip() {
    const m = snap.memory || {};
    const ai = snap.ai_mem || {};
    const acts = arr(snap.advice).filter((a) => a.action_id);
    return h('section', { class: 'card kpis span', 'aria-label': 'Итоги памяти' },
      kpi('Занято', gb(m.used_mb), 'GB', `из ${gb(m.total_mb)} GB · ${pct(m.used_mb, m.total_mb)}`),
      kpi('Сжато', gb(m.compressed_mb), 'GB', `${pct(m.compressed_mb, m.used_mb)} занятого`),
      kpi('Своп', gb(m.swap_used_mb), 'GB', `из ${gb(m.swap_total_mb)} GB · ${pct(m.swap_used_mb, m.swap_total_mb)}`, swapHot(m)),
      kpi('ИИ', gb(ai.total_mb), 'GB', isNum(ai.total_mb) ? plural(sum(arr(ai.parts).map((p) => p.count)), 'процесс', 'процесса', 'процессов') : 'нет данных', false, {
        'aria-expanded': String(drill === 'ai'), 'data-key': 'kpi:ai', title: 'Сколько памяти ест ИИ — нажми, чтобы разобрать',
        onclick: () => toggleDrill('ai'),
      }),
      kpi('Можно освободить', acts.length ? gb(sum(acts.map((a) => a.saves_mb))) : NA, 'GB',
        acts.length ? 'по ' + plural(acts.length, 'подсказке', 'подсказкам', 'подсказкам') : 'нечего'),
      drill === 'ai' ? aiDrill(ai) : null);
  }

  function aiDrill(ai) {
    const parts = arr(ai.parts);
    const total = Math.max(1, num0(ai.total_mb));
    return drillBox('ai', 'Память ИИ', null, mb(ai.total_mb), [
      parts.length ? h('div', { class: 'drows' }, parts.map((p) => h('div', { class: 'drow' + (num0(p.mem_mb) ? '' : ' zero') },
        dname(p.label, h('span', { class: 'muted small', text: num0(p.count) ? p.count + ' проц.' : 'не запущено' })),
        h('span', { class: 'num', text: mb(p.mem_mb) }),
        share([p.mem_mb], total))))
        : none('Сервер пока не считает память ИИ.'),
      dnote('Dev-серверы, запущенные из сессий (webpack, vite…), сюда не входят — это не ИИ.')]);
  }

  // подсказки: в «Обзоре» 5 (в «Просто» 3), в «Памяти» все; без кнопки — совет
  const SEV = { high: ['high', 'важно', 'solid'], med: ['med', 'совет', 'amber'], low: ['low', 'инфо', 'low'] };
  function adviceCard(all) {
    const list = arr(snap.advice);
    const cap = all ? list.length : simple ? 3 : 5;
    const more = list.length - cap;
    return h('section', { class: 'card' },
      h('h2', { class: 'h' }, 'Что выключить', list.length ? h('span', { class: 'n', text: list.length }) : null,
        more > 0 ? (simple ? h('button', { class: 'link r', 'data-key': 'adv:more', onclick: () => { setView('full'); go('memory'); } }, `ещё ${more} — в «Подробно»`)
          : h('a', { class: 'r', href: '#memory', text: `ещё ${more} — в «Памяти»` })) : null),
      list.length ? h('div', { class: 'alerts' }, list.slice(0, cap).map((a) => {
        const [cls, label, badge] = own(SEV, a.severity) || SEV.low;
        const id = own(snap.actions || {}, a.action_id) ? a.action_id : null;
        return h('div', { class: 'alert ' + cls },
          h('div', { class: 't' }, h('span', { class: 'badge ' + badge, text: label }), txt(a.title).replace(/ (?=[MGT]B\b)/g, ' ')),
          a.detail ? h('div', { class: 'd' + (id ? '' : ' adv') }, id ? null : icon('chev'), h('span', { text: a.detail })) : null,
          id ? h('div', { class: 'a' }, pick(id, a.title),
            num0(a.saves_mb) > 0 ? h('span', { class: 'save', text: 'освободит ' + mb(a.saves_mb) }) : null,
            actBtn(id, all ? 'adv:' : '')) : null);
      })) : none('Подсказок нет — всё спокойно.'));
  }

  const SST = { busy: ['ok', 'работает'], idle: ['', 'ждёт'], unknown: ['', 'неизвестно'] };
  const isHot = (k) => k.kind === 'dev-server' || (isNum(k.mem_mb) && k.mem_mb >= 500);
  const hotLabel = (kids) => {
    const top = [...kids].sort((a, b) => num0(b.mem_mb) - num0(a.mem_mb))[0];
    return `${String(top.name || '').split(' ')[0] || 'потомок'} ${mb(top.mem_mb)}`;
  };
  const sessions = () => [...arr((snap.sessions || {}).claude)].sort((a, b) => num0(b.mem_mb) - num0(a.mem_mb));

  function sessionsCompact() {
    const list = sessions();
    return h('section', { class: 'card' },
      h('h2', { class: 'h' }, 'Сессии Claude', h('span', { class: 'n', text: list.length }),
        h('span', { class: 'r mono', text: mb(sum(list.map((s) => s.mem_mb))) })),
      list.length ? h('div', { class: 'rows' }, list.map((s) => {
        const hot = arr(s.children).filter(isHot);
        return h('button', {
          class: 'row', 'data-key': 'go:' + s.pid,
          title: [s.name, s.last_action].filter(Boolean).join('\n'),
          onclick: () => go('sessions', 's-' + s.pid),
        },
        h('i', { class: 'dot ' + (own(SST, s.status) || SST.unknown)[0] }),
        h('span', { class: 'grow lines' }, h('span', { class: 'trunc' }, h('span', { class: 'nm', text: txt(s.name) })),
        s.last_action ? h('span', { class: 'trunc muted small', text: s.last_action }) : null),
        hot.length ? h('span', { class: 'chip hot mono', text: hotLabel(hot) }) : null,
        h('span', { class: 'num', text: mb(s.mem_mb) }),
        h('span', { class: 'age', text: since(s.started_ts) }));
      })) : none('Сессий Claude нет.'));
  }

  const BST = { running: ['on', 'Работает'], stopped: ['', 'Остановлен'], partial: ['warn', 'Частично'], 'no-config': ['hollow', 'Не настроен'] };
  function botRow(b) {
    const [cls, label] = own(BST, b.status) || ['', txt(b.status)];
    const id = (verb) => `bot:${b.id}:${verb}`;
    // кнопка — только для глагола, что сервер предложил в actions
    const can = (verb) => arr(b.actions).includes(verb) && !!own((snap && snap.actions) || {}, id(verb));
    const on = b.status === 'running' || b.status === 'partial';
    const use = on ? [isNum(b.mem_mb) ? mb(b.mem_mb) : '', b.uptime_s > 0 ? dur(b.uptime_s) : ''].filter(Boolean).join(' · ') : '';
    return h('div', { class: 'botrow' }, can('stop') ? pick(id('stop'), b.name) : null,
      h('i', { class: 'dot ' + cls }), h('span', { class: 'st' }, label, use ? h('span', { class: 'use', title: 'память · аптайм', text: use }) : null),
      can('start') ? h('button', { class: 'primary', 'data-key': 'act:' + id('start'), onclick: () => confirmAction(id('start')) }, 'Включить') : null,
      can('stop') ? h('button', { 'data-key': 'act:' + id('stop'), onclick: () => confirmAction(id('stop')) }, 'Выключить') : null,
      can('restart') ? h('button', {
        class: 'icon', 'aria-label': 'Перезапустить', title: 'Перезапустить',
        'data-key': 'act:' + id('restart'), onclick: () => confirmAction(id('restart')),
      }, icon('restart')) : null);
  }

  function botsCompact() {
    const bots = arr(snap.bots), ag = arr(snap.agents);
    const live = ag.filter((a) => arr(a.pids).length);
    return h('section', { class: 'card' },
      h('h2', { class: 'h' }, 'Фоновое', h('span', { class: 'n', text: bots.length + ag.length }), h('a', { class: 'r', href: '#bots', text: 'подробнее' })),
      bots.map((b) => h('div', { class: 'brow' }, h('div', { class: 'name trunc', title: txt(b.name), text: txt(b.name) }), botRow(b))),
      ag.length ? h('div', { class: 'brow' }, h('div', { class: 'name', text: 'Фоновые агенты' }),
        h('div', { class: 'botrow' }, h('i', { class: 'dot ' + (live.length ? 'on' : '') }),
          h('span', { class: 'st' }, `работают ${live.length} из ${ag.length}`, agentsMb(ag)),
          h('a', { href: '#bots', text: 'разобрать' }))) : null);
  }
  // в итог — только агенты с кнопками
  const agentIds = (a) => Object.values(a.actions || {}).filter((v) => own(snap.actions || {}, v));
  const agentsMb = (ag, cls = 'use') => h('span', { class: cls, title: 'память агентов, которые можно остановить отсюда',
    text: mb(sum(ag.filter((a) => agentIds(a).length).map((a) => a.mem_mb))) });

  // --- «Просто»: главное без подробностей ---
  const SIMPLE = {
    overview: () => [h('div', { class: 'col' }, simpleMem(), topCard()), h('div', { class: 'col' }, adviceCard(), sessLines(), botLines())],
    sessions: () => [sessLines()],
    bots: () => [botLines()],
  };
  const PWORD = { normal: ['ok', 'норма'], warn: ['warn', 'повышено'], critical: ['bad', 'критично'] };

  // итог: macOS вместе с ядром — с программами сходится с «занято»; полоса — только категории
  function simpleMem() {
    const m = snap.memory || {}, S = m.summary || {}, d = snap.disk || {};
    const [cls, word] = own(PWORD, m.pressure) || ['', NA];
    const disk = [isNum(d.wear_pct) && `износ ${fx(d.wear_pct)} %`, isNum(d.swap_gb_per_day) && `своп ≈${fx(d.swap_gb_per_day)} GB/день`].filter(Boolean);
    return h('section', { class: 'card' },
      h('h2', { class: 'h' }, 'Память'),
      h('p', { class: 'hero' }, 'Занято ', h('b', { text: gb(m.used_mb) }), ` из ${gb(m.total_mb)} GB · давление `, h('b', { class: cls, text: word })),
      h('p', { class: 'sum' }, 'macOS ≈ ', h('b', { title: `службы ${mb(S.macos_mb)} + ядро, драйверы, видеопамять ${mb(S.wired_mb)}`, text: mb(isNum(S.macos_mb) ? S.macos_mb + num0(S.wired_mb) : null) }),
        ' · твои программы ≈ ', h('b', { text: mb(S.programs_mb) }), isNum(S.cache_mb) ? [' · кэш ', h('b', { text: mb(S.cache_mb) }), ' (освободится сам)'] : null),
      h('div', { class: 'comp big' }, memSegments(m)),
      h('div', { class: 'legend' }, shown(m).map(([k, n, c]) => h('span', {}, h('i', { class: c }), n, h('b', { text: mb(m[k]) })))),
      spark(),
      h('p', { class: 'note-line disk1', text: 'Диск: ' + (disk.join(' · ') || 'нет данных') }));
  }

  // занято (заливка) и своп (пунктир) — две полосы в одной рамке, у каждой свой масштаб, но не мельче 2 и 1 GB: шум не раздуваем.
  // Осей нет: диапазоны — в подписи, значения — во всплывашке; мак спал — линия рвётся
  function spark() {
    const pts = arr(hist && hist.points).filter((p) => p && isNum(p.ts) && isNum(p.used_mb)).sort((a, b) => a.ts - b.ts);
    if (pts.length < 2) return h('p', { class: 'note-line', text: histState === 'loading' ? 'Загружаю историю…' : 'История ещё копится.' });
    const t0 = pts[0].ts, t1 = pts.at(-1).ts, gap = 2.5 * (hist.step_s > 0 ? hist.step_s : 300);
    const runs = [];
    pts.forEach((p, i) => { if (!i || p.ts - pts[i - 1].ts > gap) runs.push([]); runs.at(-1).push(p); });
    const X = (p) => (((p.ts - t0) / Math.max(1, t1 - t0)) * 300).toFixed(1);
    const band = (k, y0, y1, min) => {
      const v = pts.map((p) => num0(p[k])), lo = Math.min(...v), hi = Math.max(...v), pad = Math.max(0, min - (hi - lo)) / 2;
      const Y = (x) => (y1 - ((num0(x) - lo + pad) / (hi - lo + 2 * pad)) * (y1 - y0)).toFixed(1);
      return [(base) => runs.map((r) => 'M' + r.map((p) => X(p) + ',' + Y(p[k])).join('L') + (base ? `L${X(r.at(-1))},${base}L${X(r[0])},${base}Z` : '')).join(''),
        `${gb(lo)}–${gb(hi)} GB`];
    };
    const [u, ur] = band('used_mb', 2, 17, 2048), [w, wr] = band('swap_mb', 23, 38, 1024);
    const cap = `за ${t1 - t0 >= 3600 ? Math.round((t1 - t0) / 3600) + ' ч' : dur(t1 - t0)}: занято ${ur} · своп ${wr}`;
    const el = h('div', { class: 'spark', role: 'img', 'aria-label': 'Память ' + cap,
      html: `<svg viewBox="0 0 300 40" preserveAspectRatio="none" aria-hidden="true"><path class="ua" d="${u(19)}"/><path class="su" d="${u()}"/><path class="ss" d="${w()}"/></svg>` });
    el._tip = (cx) => {
      const r = el.getBoundingClientRect(), ts = t0 + ((cx - r.left) / r.width) * (t1 - t0);
      const p = pts.reduce((a, b) => (Math.abs(b.ts - ts) < Math.abs(a.ts - ts) ? b : a));
      return [h('div', { class: 'tt', text: hhmm(p.ts) }), h('div', {}, 'занято ', h('b', { text: mb(p.used_mb) })), h('div', {}, 'своп ', h('b', { text: mb(p.swap_mb) }))];
    };
    return [h('p', { class: 'note-line', text: cap[0].toUpperCase() + cap.slice(1) }), el];
  }

  // «Кто больше всех»: пять программ по RAM + сжато, каждая одним итогом; macOS — в строке-итоге выше
  function topCard() {
    const list = arr((snap.memory || {}).free_candidates).filter((c) => c.key !== 'macos')
      .map((c) => [c.name, num0(c.ram_mb) + num0(c.compressed_mb)]).sort((a, b) => b[1] - a[1]).slice(0, 5);
    const max = Math.max(1, ...list.map((x) => x[1]));
    return h('section', { class: 'card' },
      h('h2', { class: 'h' }, 'Кто больше всех', h('span', { class: 'r', text: 'в RAM + сжато' })),
      list.length ? h('div', { class: 'drows' }, list.map(([n, v]) => h('div', { class: 'drow' }, dname(n), h('span', { class: 'num', text: mb(v) }), share([v], max))))
        : none('Сервер пока не присылает, кто сколько держит.'));
  }

  // сессии одной строкой: имя, MB, работает/ждёт, стоп
  function sessLines() {
    const list = sessions();
    return h('section', { class: 'card' },
      h('h2', { class: 'h' }, 'Сессии Claude', h('span', { class: 'n', text: list.length }), h('span', { class: 'r mono', text: mb(sum(list.map((s) => s.mem_mb))) })),
      list.length ? h('div', { class: 'tbl' }, list.map((s) => {
        const [cls, label] = own(SST, s.status) || SST.unknown;
        return h('div', { class: 'row', title: s.is_self ? 'это текущая сессия — её отсюда не останавливают' : null },
          h('i', { class: 'dot ' + cls }),
          h('span', { class: 'where' }, h('span', { class: 'nm trunc', title: txt(s.name), text: txt(s.name) })),
          h('span', { class: 'num', text: mb(s.mem_mb) }), h('span', { class: 'st', text: label === SST.unknown[1] ? '' : label }),
          s.action_id && !s.is_self ? stopIcon(s.action_id, s.name, 's:') : h('span'));
      })) : none('Сессий Claude нет.'));
  }

  // боты и фоновые агенты одной строкой: точка, имя, MB или состояние, одна кнопка — выключить или включить
  function botLines() {
    const bots = arr(snap.bots), ag = arr(snap.agents);
    const act = (id) => (id && own(snap.actions || {}, id) ? id : null);
    const line = (dot, name, state, id) => h('div', { class: 'row' }, h('i', { class: 'dot ' + dot }),
      h('span', { class: 'nm trunc', title: name, text: name }), h('span', { class: 'st', text: state }),
      id ? h('button', { class: /:(start|enable)$/.test(id) ? 'primary' : null, 'data-key': 'act:' + id, onclick: () => confirmAction(id) }, verbOf(id)[0]) : h('span'));
    return h('section', { class: 'card' },
      h('h2', { class: 'h' }, 'Боты и агенты', h('span', { class: 'n', text: bots.length + ag.length })),
      bots.length + ag.length ? h('div', { class: 'tbl b4' },
        bots.map((b) => {
          const [cls, label] = own(BST, b.status) || ['', txt(b.status)];
          const on = b.status === 'running' || b.status === 'partial', verb = on ? 'stop' : 'start';
          return line(cls, txt(b.name), on && isNum(b.mem_mb) ? mb(b.mem_mb) : label.toLowerCase(), arr(b.actions).includes(verb) ? act(`bot:${b.id}:${verb}`) : null);
        }),
        ag.map((a) => {
          const run = arr(a.pids).length > 0;
          return line(a.disabled ? 'hollow' : run ? 'on' : '', [a.vendor, a.name].filter(Boolean).join(' · ') || txt(a.label),
            run ? mb(a.mem_mb) : a.disabled ? 'выключен' : 'не запущен', act((a.actions || {})[run ? 'stop' : 'enable']));
        })) : none('Ботов и фоновых агентов нет.'));
  }

  // --- сессии ---
  function viewSessions() {
    const S = snap.sessions || {};
    const list = sessions();
    return [
      h('div', { class: 'sec' }, h('h2', { class: 'h' }, 'Claude Code', h('span', { class: 'n', text: list.length }),
        h('span', { class: 'r mono', text: mb(sum(list.map((s) => s.mem_mb))) }))),
      list.length ? h('div', { class: 'grid' }, list.map(sessCard)) : h('section', { class: 'card' }, none('Сессий Claude нет.')),
      h('div', { class: 'grid' }, termsCard(arr(S.terminals)), h('div', { class: 'col' }, muxCard(S.tmux, S.docker), orphansCard(arr(S.orphans)))),
    ];
  }

  // stop процесса, если сервер его предложил
  const procAction = (p) => {
    const id = `stop:proc:${p.pid}:${p.uid}`;
    return snap && snap.actions && snap.actions[id] ? id : null;
  };
  const stopIcon = (id, name, pre = '') => h('button', {
    class: 'icon', 'aria-label': 'Остановить ' + txt(name), title: 'Остановить',
    'data-key': pre + 'act:' + id, onclick: () => confirmAction(id),
  }, icon('stop'));

  function details(key, cls, summary, body, openByDefault) {
    const d = h('details', { class: cls }, h('summary', { 'data-key': key }, summary), body);
    d.open = openSet.has(key) || (!touched.has(key) && !!openByDefault);
    d.addEventListener('toggle', () => {
      touched.add(key);
      if (d.open) openSet.add(key); else openSet.delete(key);
    });
    return d;
  }

  function sessCard(s) {
    const [cls, label] = own(SST, s.status) || SST.unknown;
    const kids = arr(s.children);
    const kidsMb = sum(kids.map((k) => k.mem_mb));
    const hot = kids.filter(isHot);
    return h('article', { class: 'card sess', id: 's-' + s.pid },
      h('div', { class: 'head' }, pick(s.action_id, s.name),
        h('span', { class: 'chip st ' + cls }, h('i', { class: 'dot' }), label),
        h('span', { class: 'name trunc', title: txt(s.name), text: txt(s.name) }),
        // имя вида «my-project-b9» уже с проектом — чип прячем
        s.project ? h('span', { class: 'chip trunc proj' + (String(s.name || '').startsWith(s.project) ? ' dup' : ''), title: txt(s.cwd), text: s.project }) : null,
        h('span', { class: 'mem', title: 'вместе с потомками', text: mb(s.mem_mb) })),
      // последний шаг и запрос — из хвоста транскрипта
      s.last_action ? h('div', { class: 'now' }, h('span', { class: 'muted', text: s.status === 'busy' || s.status === 'shell' ? 'Сейчас: ' : 'Последнее: ' }),
        h('span', { class: 'trunc', title: s.last_action, text: s.last_action }),
        isNum(s.last_action_ts) ? h('span', { class: 'muted', text: `· ${since(s.last_action_ts)} назад` }) : null) : null,
      s.last_prompt ? h('div', { class: 'ask muted', title: s.last_prompt, text: 'Запрос: ' + s.last_prompt }) : null,
      h('div', { class: 'meta-line' },
        h('span', { text: 'PID ' + txt(s.pid) }),
        h('span', { text: 'возраст ' + since(s.started_ts) }),
        h('span', { text: isNum(s.last_activity_ts) ? `активность ${since(s.last_activity_ts)} назад` : 'активность ' + NA }),
        kids.length && isNum(s.mem_mb) ? h('span', { text: 'сам ' + mb(s.mem_mb - kidsMb) }) : null,
        s.version ? h('span', { text: 'v' + s.version }) : null),
      kids.length ? details('kids:' + s.pid, 'kids',
        [icon('chev', 'chev'), `Потомки · ${kids.length}`, hot.length ? h('span', { class: 'chip hot mono', text: hotLabel(hot) }) : null,
          h('span', { class: 'r', text: mb(kidsMb) })],
        kids.map(kidRow), hot.length > 0) : null,
      h('div', { class: 'foot-row' },
        s.resume_cmd ? h('div', { class: 'resume' },
          h('code', { class: 'trunc', title: s.resume_cmd, text: s.resume_cmd }),
          h('button', { class: 'icon', 'aria-label': 'Скопировать команду', title: 'Скопировать', 'data-key': 'copy:' + s.pid, onclick: () => copy(s.resume_cmd) }, icon('copy')))
          : h('span', { class: 'grow muted small', text: 'продолжить нельзя: нет файла сессии' }),
        s.is_self ? h('span', { class: 'chip line', text: 'это текущая сессия' })
          : s.action_id ? actBtn(s.action_id)
            : h('span', { class: 'muted small', title: 'Сервер не предложил действие для этой сессии', text: 'не управляется' })));
  }

  function kidRow(k) {
    const id = procAction(k);
    const kind = ['dev-server', 'mcp', 'shell'].includes(k.kind) ? k.kind : 'other';
    return h('div', { class: 'kid' + (isHot(k) ? ' hot' : '') }, pick(id, k.name) || h('span'),
      h('span', { class: 'badge k-' + kind, text: k.kind || 'other' }),
      h('span', { class: 'trunc', title: `${txt(k.name)} · PID ${txt(k.pid)}`, text: txt(k.name) }),
      h('span', { class: 'r', text: mb(k.mem_mb) }),
      h('span', { class: 'age', text: dur(k.age_s) }),
      id ? stopIcon(id, k.name) : h('span'));
  }

  function termsCard(terms) {
    const n = sum(terms.map((t) => arr(t.shells).length));
    return h('section', { class: 'card' },
      h('h2', { class: 'h' }, 'Терминалы', h('span', { class: 'n', text: n })),
      n ? terms.map((t) => [
        h('div', { class: 'sub', text: `${txt(t.app)} · host ${txt(t.host_pid)}` }),
        h('div', { class: 'rows' }, arr(t.shells).map((sh) => [h('div', { class: 'row shell' }, pick(sh.action_id, 'шелл ' + txt(sh.tty)) || h('span'),
          h('span', { class: 'tty', text: txt(sh.tty) }),
          h('span', { class: 'where', title: txt(sh.cwd) },
            h('span', { class: 'trunc nm', text: sh.project || home(sh.cwd) || NA }),
            sh.project && sh.cwd ? h('span', { class: 'cwd trunc', text: home(sh.cwd) }) : null),
          h('span', { class: 'chip mono', title: 'на переднем плане', text: txt(sh.fg) }),
          sh.action_id ? stopIcon(sh.action_id, 'шелл ' + txt(sh.tty)) : h('span')), arr(sh.children).map(kidRow)])),
      ]) : none('Открытых шеллов нет.'));
  }

  function muxCard(tmux, docker) {
    const line = (name, on, items, fmt) => h('div', { class: 'row' },
      h('i', { class: 'dot ' + (on ? 'ok' : '') }), h('span', { class: 'nm', text: name }),
      h('span', { class: 'grow muted trunc', text: !on ? 'не запущен' : items.length ? items.map(fmt).join(' · ') : 'запущен, пусто' }));
    const pick = (o, ...keys) => txt(keys.map((k) => o && o[k]).find((v) => v != null && v !== ''));
    return h('section', { class: 'card' }, h('h2', { class: 'h' }, 'tmux · Docker'),
      h('div', { class: 'rows' },
        line('tmux', tmux && tmux.running, arr(tmux && tmux.sessions), (s) => pick(s, 'name', 'id') + (s && s.attached ? ' (подключён)' : '')),
        line('Docker', docker && docker.running, arr(docker && docker.containers), (c) => {
          const st = pick(c, 'status', 'state');
          return pick(c, 'name', 'id') + (st !== NA ? ' — ' + st : '');
        })));
  }

  function orphansCard(list) {
    return h('section', { class: 'card' },
      h('h2', { class: 'h' }, 'Сироты', h('span', { class: 'n', text: list.length }),
        list.length ? h('span', { class: 'r mono', text: mb(sum(list.map((o) => o.mem_mb))) }) : null),
      list.length ? h('div', { class: 'rows' }, list.map((o) => h('div', { class: 'row' }, pick(o.action_id, o.name),
        h('div', { class: 'grow' },
          h('div', { class: 'trunc mono', title: txt(o.name), text: txt(o.name) }),
          h('div', { class: 'muted small trunc', title: txt(o.reason), text: `PID ${txt(o.pid)} · ${txt(o.reason)}` })),
        h('span', { class: 'num', text: mb(o.mem_mb) }),
        h('span', { class: 'age', text: dur(o.age_s) }),
        o.action_id ? stopIcon(o.action_id, o.name) : null)))
        : none('Сирот нет.'));
  }

  // --- боты ---
  const NO_BOTS = 'Ботов нет. Добавь их в ~/Library/Application Support/lambscape/bots.toml (пример — bots.example.toml)';
  function viewBots() {
    const bots = arr(snap.bots);
    return [bots.length ? h('div', { class: 'grid' }, bots.map(botCard)) : h('section', { class: 'card' }, none(NO_BOTS)),
      agentsCard()];
  }

  // --- фоновые агенты: сторонние задания launchd ---
  function agentsCard() {
    const list = arr(snap.agents);
    return h('section', { class: 'card' },
      h('h2', { class: 'h' }, 'Фоновые агенты', h('span', { class: 'n', text: list.length }), agentsMb(list, 'r mono')),
      list.length ? list.map(agentRow) : none('Сторонних агентов launchd нет.'),
      h('p', { class: 'note', text: '«Остановить» — до следующего входа в систему. «Не запускать при входе» выключает и автозапуск; «Вернуть» включает обратно.' }));
  }

  function agentRow(a) {
    // действие агента — только описанное сервером в actions
    const id = (verb) => (agentIds(a).includes((a.actions || {})[verb]) ? a.actions[verb] : null);
    const btn = (verb, text, cls) => id(verb) && h('button', { class: cls, 'data-key': 'act:' + id(verb), onclick: () => confirmAction(id(verb)) }, text);
    const run = arr(a.pids).length > 0;
    const name = [a.vendor, a.name].filter(Boolean).join(' · ') || txt(a.label);
    const ro = !agentIds(a).length; // без кнопок — память видна, но не в итоге карточки
    return h('div', { class: 'agent' + (ro ? ' ro' : '') },
      h('div', { class: 'ah' }, pick(id('stop'), name) || h('span', { class: 'nopick' }),
        h('i', { class: 'dot ' + (a.disabled ? 'hollow' : run ? 'on' : ''), title: a.disabled ? 'выключен' : run ? 'работает' : 'не запущен' }),
        h('span', { class: 'trunc nm', title: txt(a.plist), text: name }),
        a.domain === 'system' ? h('span', { class: 'badge low', title: 'системный демон: нужен sudo', text: 'root' }) : null,
        a.run_at_load && !a.disabled ? h('span', { class: 'chip line', title: 'запускается при входе', text: 'автозапуск' }) : null,
        a.keepalive && !a.disabled ? h('span', { class: 'chip line', title: 'launchd поднимет его снова, если просто убить процесс', text: 'KeepAlive' }) : null,
        h('span', { class: 'num', title: ro && run ? 'не входит в итог: отсюда не остановить' : null, text: run ? mb(a.mem_mb) : a.disabled ? 'выключен' : 'не запущен' })),
      a.note ? h('div', { class: 'd', text: a.note }) : null,
      h('div', { class: 'aa' }, h('code', { class: 'trunc', title: txt(a.plist), text: txt(a.label) }),
        btn('stop', 'Остановить'), btn('disable', 'Не запускать при входе'), btn('enable', 'Вернуть', 'primary')),
      a.sudo_hint ? h('div', { class: 'resume sudo' }, h('code', { text: a.sudo_hint }),
        h('button', { class: 'icon', 'aria-label': 'Скопировать команду', title: 'Скопировать', 'data-key': 'copy:' + a.label, onclick: () => copy(a.sudo_hint) }, icon('copy'))) : null);
  }

  function botCard(b) {
    const url = safeUrl(b.url);
    const pids = arr(b.pids);
    const ports = arr(b.ports);
    const unset = b.status === 'no-config';
    return h('section', { class: 'card bot' },
      h('h2', { class: 'h' }, h('span', { class: 'trunc', title: txt(b.name), text: txt(b.name) }),
        url ? h('a', { class: 'r ext', href: url, target: '_blank', rel: 'noopener', title: 'Панель бота — в новой вкладке' },
          url.replace(/^https?:\/\//i, ''), icon('ext')) : null),
      botRow(b),
      unset ? null : h('div', { class: 'facts' },
        h('span', {}, 'порт ', h('b', { text: ports.length ? ports.join(', ') : NA })),
        h('span', { title: pids.join(' ') }, 'PID ', h('b', { text: pids.length ? pids.slice(0, 2).join(' ') + (pids.length > 2 ? ` +${pids.length - 2}` : '') : NA }))),
      // у ненастроенного note с сервера говорит, что вписать и куда, — показываем её предупреждением
      b.note && !unset ? h('p', { class: 'note', text: b.note }) : null,
      unset ? h('p', { class: 'hint' }, icon('warn'), h('span', { text: txt(b.note) })) : null);
  }

  // --- память: что освободить и группы ---
  const GROUP_KINDS = [['project', 'Проекты'], ['app', 'Приложения'], ['system', 'Система'], ['other', 'Прочее']];
  function viewMemory() {
    const groups = arr(snap.groups);
    const max = Math.max(1, ...groups.map((g) => num0(g.mem_mb)));
    const total = (snap.memory || {}).total_mb;
    const known = GROUP_KINDS.map(([k]) => k);
    return [freeCard(), ...GROUP_KINDS.map(([kind, title]) => {
      const list = groups.filter((g) => g.kind === kind || (kind === 'other' && !known.includes(g.kind)));
      if (!list.length && kind === 'other') return null;
      return h('section', { class: 'card' },
        h('h2', { class: 'h' }, title, h('span', { class: 'n', text: list.length }), h('span', { class: 'r mono', text: mb(sum(list.map((g) => g.mem_mb))) })),
        list.length ? list.map((g) => groupRow(g, max, total)) : none('Сейчас таких процессов нет.'));
    })];
  }

  // --- диск: износ SSD и запись свопа; null — «нет данных» ---
  function diskCard() {
    const d = snap.disk || {};
    const v = (x, f) => (isNum(x) ? h('b', { text: f(x) }) : h('span', { class: 'na', text: 'нет данных' }));
    const p = (x) => fx(x) + ' %';
    // своп за сутки — по истории панели: её меньше суток — сколько записано за эти N ч; меньше 2 ч — ещё копится
    const span = isNum(d.swap_24h_span_h) ? Math.min(24, Math.round(d.swap_24h_span_h)) : 24;
    const smart = [d.wear_pct, d.written_tb, d.spare_pct].some(isNum);
    return [h('h2', { class: 'h' }, 'Диск', h('span', { class: 'r trunc', text: [d.model, isNum(d.size_gb) && d.size_gb + ' GB'].filter(Boolean).join(' · ') })),
      h('p', { class: 'sum' }, smart ? ['износ ', v(d.wear_pct, p), ' · записано ', v(d.written_tb, (x) => fx(x) + ' TB'), ' · запас ', v(d.spare_pct, p)]
        : ['износ SSD: ', v(null)]),
      num0(d.media_errors) > 0 ? h('p', { class: 'sum bad', text: `ошибок чтения/записи: ${d.media_errors} — сделай резервную копию` }) : null,
      h('p', { class: 'sum', title: isNum(d.swap_written_gb_boot) ? `с загрузки своп записал ${fx(d.swap_written_gb_boot)} GB` : '' },
        'своп ', isNum(d.swap_gb_per_day) ? ['≈', v(d.swap_gb_per_day, (x) => fx(x) + ' GB/день')] : ['в день: ', v(null)],
        isNum(d.swap_share_pct) ? [' (', v(d.swap_share_pct, p), ' всей записи)'] : null,
        isNum(d.swap_written_24h_gb) ? [` · за последние ${span} ч: `, v(d.swap_written_24h_gb * (span < 24 ? d.swap_24h_span_h / 24 : 1), (x) => fx(x) + ' GB')]
          : [' · за сутки: ', h('span', { class: 'na', text: 'копится' })]),
      h('p', { class: 'note', text: 'Износ не страшен — своп опасен скоростью, а не ресурсом: пока мак пишет и читает своп, всё тормозит.' })];
  }

  // группа = top + «ещё N — X»; «показать все» — с сервера
  const full = new Map(); // id группы → список процессов, 'wait' или текст ошибки
  async function toggleAll(id) {
    if (full.has(id)) full.delete(id);
    else {
      full.set(id, 'wait');
      renderTab();
      const r = await api('/api/group/' + encodeURIComponent(id)).then((d) => (Array.isArray(d) ? d : arr(d && d.members)),
        (e) => 'не загрузилось: ' + e.message);
      if (full.get(id) !== 'wait') return; // пока грузили, свернули
      full.set(id, r);
    }
    renderTab();
  }

  function groupRow(g, max, total) {
    const all = full.get(g.id), rest = g.rest || {};
    const list = Array.isArray(all) ? all : arr(g.top);
    const fill = isNum(g.mem_mb) ? h('i') : null;
    if (fill) fill.style.width = Math.max(0.4, (g.mem_mb / max) * 100) + '%';
    const n = (k) => plural(k, 'процесс', 'процесса', 'процессов');
    const body = list.length || rest.count > 0;
    return [details('grp:' + g.id, 'grp', [
      body ? icon('chev', 'chev') : h('span'),
      h('span', { class: 'gname', title: g.path || '' }, h('span', { class: 'trunc', text: txt(g.name) }),
        h('span', { class: 'cnt', text: isNum(g.count) ? g.count + ' проц.' : NA })),
      h('span', { class: 'gmem' }, mb(g.mem_mb), h('small', { text: pct(g.mem_mb, total) })),
      h('span', { class: 'share', 'aria-hidden': 'true' }, fill),
    ], body ? h('div', { class: 'procs' + (Array.isArray(all) ? ' all' : ''), 'data-scroll': g.id }, list.map(procRow),
      rest.count > 0 ? h('div', { class: 'more' },
        h('span', { text: Array.isArray(all) ? 'всего ' + n(all.length) : all === 'wait' ? 'загружаю…' : all || `ещё ${n(rest.count)} — ${mb(rest.mb)}` }),
        h('button', { class: 'link', 'data-key': 'all:' + g.id, onclick: () => toggleAll(g.id) }, all ? 'свернуть' : 'показать все')) : null) : null),
    arr(g.hints).length ? h('ul', { class: 'tips', 'aria-label': 'Что можно сделать' }, g.hints.map((x) => h('li', {}, h('b', { text: txt(x.title) }),
      x.how ? ' — ' + x.how : '', num0(x.saves_mb) > 0 ? h('span', { class: 'save', text: ' ≈ ' + mb(x.saves_mb) }) : null))) : null];
  }

  const PKIND = { session: 'сессия Claude', agent: 'агент launchd', helper: 'фоновое приложение', 'dev-server': 'dev-сервер', mcp: 'MCP', shell: 'шелл' };
  function procRow(p) {
    const id = p.action_id && own(snap.actions || {}, p.action_id) ? p.action_id : null;
    const why = p.why || own(PKIND, p.kind) || '';
    return h('div', { class: 'proc' },
      h('span', { class: 'pid', text: txt(p.pid) }),
      h('span', { class: 'trunc', title: `${txt(p.name)}${why ? ' — ' + why : ''}` }, txt(p.name), why ? h('span', { class: 'why', text: why }) : null),
      h('span', { class: 'r', text: mb(p.mem_mb) }),
      id ? h('span', { class: 'pa' }, pick(id, p.name), stopIcon(id, p.name)) : h('span'));
  }

  // --- «Память за 24 ч»: группы стопкой, под ними своп ---
  function gbTicks(maxMb) {
    const g = maxMb / 1024;
    const step = [1, 2, 4, 5, 10, 20, 50, 100].find((s) => g / s <= 5) || 200;
    const top = Math.max(step, Math.ceil(g / step) * step);
    return { max: top * 1024, list: Array.from({ length: top / step + 1 }, (_, i) => i * step) };
  }
  // цвет ряда — как у группы на карте (ключ = color_key)
  function histColors(series) {
    const mine = series.map((s) => (s.key === 'system' ? 'cm' : s.key === 'rest' ? 'cr' : slots.has(s.key) ? PAL[slots.get(s.key)] : ''));
    const map = [...slots.values()].map((i) => PAL[i]);
    const free = [...PAL.filter((c) => !map.includes(c)), ...map].filter((c) => !mine.includes(c));
    return mine.map((c) => c || free.shift() || 'cr');
  }
  const PRESS = { 2: ['pw', 'высокое'], 4: ['pc', 'критическое'] };

  function drawHistory() {
    if (simple) return renderTab(); // в «Просто» мини-график — часть карточки памяти
    const box = $('#hist-body');
    const note = $('#hist-note');
    note.textContent = '';
    const H = hist || {};
    const series = arr(H.series).map((s) => ({ key: String(s && s.key), name: txt(s && s.name) }));
    const colors = histColors(series);
    drawHistory.sig = colors.join();
    const pts = arr(H.points).filter((p) => p && isNum(p.ts) && Array.isArray(p.values)).sort((a, b) => a.ts - b.ts);
    if (!pts.length) {
      return box.replaceChildren(none(histState === 'loading' ? 'Загружаю историю…' : histState === 'error' ? 'Не удалось загрузить историю.'
        : 'Пока пусто: панель записывает точку раз в минуту.'));
    }
    const step = H.step_s > 0 ? H.step_s : 300;
    const rows = pts.map((p) => ({ ts: p.ts, used: p.used_mb, swap: p.swap_mb, pr: own(PRESS, String(p.pressure)), v: series.map((_, i) => num0(p.values[i])) }));
    const last = rows.at(-1);
    const t1 = Math.max(num0(H.to_ts), last.ts);
    const from = isNum(H.from_ts) ? H.from_ts : t1 - 86400;
    // данных меньше суток: окно по ним, но не уже часа
    const first = isNum(H.first_sample_ts) ? H.first_sample_ts : rows[0].ts;
    const young = first > from + step;
    const t0 = young ? Math.max(from, Math.min(first, rows[0].ts, t1 - 3600)) : from;
    note.textContent = young ? 'данные копятся с ' + hhmm(first) : `шаг ${Math.round(step / 60)} мин`;

    const W = Math.max(280, Math.round(box.clientWidth) || 320);
    const L = 46, R = 10, T = 8, AH = 168, XB = 22, SG = 22, SH = 46;
    const sTop = T + AH + XB + SG;
    const x = (ts) => L + ((ts - t0) / Math.max(1, t1 - t0)) * (W - L - R);
    const m = (snap && snap.memory) || {};
    const ram = num0(m.total_mb);
    const yt = gbTicks(Math.max(ram, ...rows.map((r) => sum(r.v))) * 1.03);
    const y = (v) => T + AH - (v / yt.max) * AH;
    const swapMax = Math.max(num0(m.swap_total_mb), ...rows.map((r) => num0(r.swap))) || 1;
    const ys = (v) => sTop + SH - (num0(v) / swapMax) * SH;
    const f = (v) => v.toFixed(1);

    // разрывы (мак спал) не тянем; одна точка — узкой полосой
    const runs = [[]];
    rows.forEach((r, i) => {
      if (i && r.ts - rows[i - 1].ts > step * 2.5) runs.push([]);
      runs.at(-1).push(r);
    });
    for (const run of runs) if (run.length === 1) run.unshift({ ...run[0], ts: Math.max(t0, run[0].ts - step) });

    let svg = '';
    for (const g of yt.list) {
      const yy = f(y(g * 1024));
      svg += `<line class="gl" x1="${L}" x2="${W - R}" y1="${yy}" y2="${yy}"/><text class="ax" x="${L - 7}" y="${+yy + 3.5}" text-anchor="end">${g ? g + ' GB' : '0'}</text>`;
    }
    for (const run of runs) {
      const base = run.map(() => 0);
      series.forEach((_, s) => {
        const lo = base.slice();
        run.forEach((r, k) => { base[k] += r.v[s]; });
        const up = run.map((r, k) => `${f(x(r.ts))},${f(y(base[k]))}`);
        const dn = run.map((r, k) => `${f(x(r.ts))},${f(y(lo[k]))}`).reverse();
        svg += `<path class="band ${colors[s]}" d="M${up.join('L')}L${dn.join('L')}Z"/><path class="edge ${colors[s]}" d="M${up.join('L')}"/>`;
      });
    }
    if (ram) {
      const yy = f(y(ram));
      svg += `<line class="ref" x1="${L}" x2="${W - R}" y1="${yy}" y2="${yy}"/><text class="ax" x="${W - R - 2}" y="${+yy - 5}" text-anchor="end">RAM ${gb(ram)} GB</text>`;
    }
    svg += `<line class="gl" x1="${L}" x2="${W - R}" y1="${T + AH}" y2="${T + AH}"/>`;
    // подписи времени: не больше шести, шаг 15 мин…6 ч
    const tk = [900, 1800, 3600, 7200, 10800, 21600].find((s) => (t1 - t0) / s <= 6) || 21600;
    for (let t = Math.ceil(t0 / 900) * 900; t <= t1; t += 900) {
      const d = new Date(t * 1000);
      if ((d.getHours() * 60 + d.getMinutes()) % (tk / 60) === 0 && x(t) > L + 16 && x(t) < W - R - 16) {
        svg += `<text class="ax" x="${f(x(t))}" y="${T + AH + 15}" text-anchor="middle">${hhmm(t)}</text>`;
      }
    }
    // своп — своя полоса и шкала; фон — высокое давление
    for (const r of rows.filter((q) => q.pr)) {
      const a = Math.max(L, x(r.ts - step / 2)), b = Math.min(W - R, x(r.ts + step / 2));
      svg += `<rect class="${r.pr[0]}" x="${f(a)}" y="${sTop}" width="${f(Math.max(0, b - a))}" height="${SH}"/>`;
    }
    svg += `<text class="t" x="${L}" y="${sTop - 7}">своп</text><text class="ax" x="${L - 7}" y="${sTop + 3.5}" text-anchor="end">${gb(swapMax)} GB</text>`;
    svg += `<line class="gl" x1="${L}" x2="${W - R}" y1="${sTop}" y2="${sTop}"/><line class="gl" x1="${L}" x2="${W - R}" y1="${sTop + SH}" y2="${sTop + SH}"/>`;
    for (const run of runs) {
      const line = run.map((r) => `${f(x(r.ts))},${f(ys(r.swap))}`);
      svg += `<path class="sw-a" d="M${line.join('L')}L${f(x(run.at(-1).ts))},${sTop + SH}L${f(x(run[0].ts))},${sTop + SH}Z"/><path class="sw-l" d="M${line.join('L')}"/>`;
    }
    svg += `<circle class="sw-d" cx="${f(x(last.ts))}" cy="${f(ys(last.swap))}" r="4"/>`;
    svg += `<text class="ax" x="${f(x(last.ts) - 8)}" y="${f(Math.max(sTop + 10, ys(last.swap) - 7))}" text-anchor="end">${gb(last.swap)} GB</text>`;
    svg += `<line class="xh" x1="0" x2="0" y1="${T}" y2="${sTop + SH}" visibility="hidden"/>`;

    const Hh = sTop + SH + 4;
    const chart = h('div', {
      class: 'hist', tabindex: '0', role: 'img',
      'aria-label': `Память по группам за 24 часа. Сейчас: ${series.map((s, i) => `${s.name} ${mb(last.v[i])}`).join(', ')}; своп ${mb(last.swap)}, `
        + `за сутки от ${mb(Math.min(...rows.map((r) => num0(r.swap))))} до ${mb(Math.max(...rows.map((r) => num0(r.swap))))}. Стрелки — по точкам.`,
      html: `<svg width="${W}" height="${Hh}" viewBox="0 0 ${W} ${Hh}" aria-hidden="true">${svg}</svg>`,
    });
    const tip = h('div', { class: 'tip', hidden: true });
    chart.append(tip);
    const xh = $('.xh', chart);
    let cur = -1;
    const show = (i) => {
      cur = Math.max(0, Math.min(rows.length - 1, i));
      const r = rows[cur];
      const xx = x(r.ts);
      xh.setAttribute('x1', f(xx));
      xh.setAttribute('x2', f(xx));
      xh.setAttribute('visibility', 'visible');
      const line = (c, v, n) => h('div', { class: 'tr' }, h('i', { class: c }), h('b', { text: v }), h('span', { title: n, text: n }));
      tip.replaceChildren(...[h('div', { class: 'tt', text: hhmm(r.ts) }), ...series.map((s, i) => line(colors[i], mb(r.v[i]), s.name)),
        h('div', { class: 'sep' }), line('csw', mb(r.swap), 'своп'), line('', mb(r.used), 'занято, vm_stat'),
        r.pr && line(r.pr[0], r.pr[1], 'давление')].filter(Boolean)); // null стал бы текстом «null»
      tip.hidden = false;
      const cw = chart.clientWidth, tw = tip.offsetWidth;
      const px = xx * (cw / W);
      tip.style.left = Math.max(0, Math.min(px + tw + 14 > cw ? px - tw - 12 : px + 12, cw - tw)) + 'px';
    };
    const hide = () => { tip.hidden = true; xh.setAttribute('visibility', 'hidden'); };
    const nearest = (clientX) => {
      const rect = chart.getBoundingClientRect();
      const ts = t0 + (((clientX - rect.left) * (W / rect.width) - L) / (W - L - R)) * (t1 - t0);
      let best = 0;
      rows.forEach((r, i) => { if (Math.abs(r.ts - ts) < Math.abs(rows[best].ts - ts)) best = i; });
      return best;
    };
    chart.addEventListener('pointermove', (e) => show(nearest(e.clientX)));
    chart.addEventListener('pointerleave', () => { if (document.activeElement !== chart) hide(); });
    chart.addEventListener('focus', () => show(cur < 0 ? rows.length - 1 : cur));
    chart.addEventListener('blur', hide);
    chart.addEventListener('keydown', (e) => {
      const d = { ArrowLeft: -1, ArrowRight: 1, PageUp: -12, PageDown: 12, Home: -1e9, End: 1e9 }[e.key];
      if (d) { e.preventDefault(); show((cur < 0 ? rows.length - 1 : cur) + d); } else if (e.key === 'Escape') hide();
    });

    const legend = h('div', { class: 'legend' },
      series.map((s, i) => h('span', {}, h('i', { class: colors[i] }), h('span', { class: 'nm', title: s.name, text: s.name }), h('b', { text: mb(last.v[i]) }))),
      h('span', {}, h('i', { class: 'csw line' }), 'своп', h('b', { text: mb(last.swap) })),
      rows.some((r) => r.pr) ? h('span', {}, h('i', { class: 'pw' }), 'давление высокое') : null);
    box.replaceChildren(legend, chart);
  }

  // --- действия: карточка подтверждения → POST /api/action ---
  const actionInfo = (id) => own((snap && snap.actions) || {}, id) || {};
  function verbOf(id) {
    const [kind, , verb] = String(id).split(':');
    if (kind !== 'bot' && kind !== 'agent') return ['Остановить', 'danger'];
    return {
      stop: [kind === 'bot' ? 'Выключить' : 'Остановить', 'danger'], disable: ['Не запускать', 'danger'],
      start: ['Включить', 'primary'], enable: ['Вернуть', 'primary'], restart: ['Перезапустить', 'primary'],
    }[verb] || ['Выполнить', 'primary'];
  }

  // --- массовая разборка: галочки → полоса внизу → одна карточка ---
  const sel = new Set(); // выбранные stop-действия; ушедшие из снимка выпадают
  // у агента одна галочка — на stop; в «Просто» галочек нет
  function pick(id, name) {
    if (simple || !id || !own((snap && snap.actions) || {}, id) || (id.startsWith('agent:') && !id.endsWith(':stop'))) return null;
    return h('input', {
      type: 'checkbox', class: 'pick', 'data-id': id, 'data-key': 'pick:' + id, checked: sel.has(id),
      'aria-label': 'Выбрать: ' + txt(name || actionInfo(id).label), title: 'Выбрать для массовой остановки',
      onchange: (e) => {
        if (e.target.checked) sel.add(id); else sel.delete(id);
        for (const c of document.querySelectorAll('input.pick')) if (c.dataset.id === id) c.checked = sel.has(id); // та же цель в другой карточке
        bulkBar();
      },
    });
  }
  // сколько освободит набор: цели по pid без повторов
  function freed(ids) {
    const by = new Map();
    for (const id of ids) {
      const t = arr(actionInfo(id).targets);
      if (t.length) for (const x of t) by.set(x.pid, num0(x.mb));
      else by.set(id, num0((arr(snap && snap.agents).find((a) => id.startsWith(`agent:${a.label}:`)) || {}).mem_mb));
    }
    return sum([...by.values()]);
  }
  // «убрать из автозапуска» — :disable агента, если предложен
  const offOf = (id) => {
    const d = id.startsWith('agent:') && id.replace(/:stop$/, ':disable');
    return d && d !== id && own((snap && snap.actions) || {}, d) ? d : null;
  };
  function bulkBar() {
    const bar = $('#bulk');
    bar.hidden = simple || !sel.size;
    document.body.classList.toggle('picking', !bar.hidden);
    if (bar.hidden) return;
    const f = freed([...sel]);
    $('#bk-n').textContent = `Выбрано ${sel.size}` + (f ? ` · освободит ≈ ${mb(f)}` : '');
    $('#bk-off').hidden = ![...sel].some(offOf);
  }

  let bulk = null; // пункты массовой карточки
  let abort = false;
  function openBulk(off) {
    if (posting) return toast('Дождись ответа на предыдущее действие', 'quiet');
    // агенты первыми (KeepAlive поднял бы процесс), потомок раньше родителя
    const rank = (id) => (id.startsWith('agent:') ? -1 : arr(actionInfo(id).targets).length);
    bulk = [...sel].map((key) => {
      const id = (off && offOf(key)) || key, a = actionInfo(id);
      return { key, id, label: a.label || id, text: a.confirm || '', warn: a.warning || '', mb: freed([id]), st: '' };
    }).sort((x, y) => rank(x.id) - rank(y.id));
    pending = null;
    const f = freed(bulk.map((x) => x.id));
    $('#cf-title').textContent = (off ? 'Остановить и убрать из автозапуска' : 'Остановить') + ': ' + plural(bulk.length, 'пункт', 'пункта', 'пунктов');
    $('#cf-meta').textContent = f ? '≈' + mb(f) : '';
    $('#cf-warn').hidden = $('#cf-cmd').hidden = true;
    $('#cf-text').textContent = 'По очереди, по одному. Что не выйдет — пропущу, покажу причину и пойду дальше.';
    drawBulk();
    dialogFor('Остановить ' + bulk.length, 'danger');
  }

  function drawBulk() {
    const mark = { busy: () => h('span', { class: 'spin' }), ok: () => icon('check'), bad: () => icon('close'), skip: () => '–' };
    $('#cf-targets').replaceChildren(h('ol', { class: 'bk' }, bulk.map((x, i) => h('li', { class: x.st },
      h('span', { class: 'bs', 'aria-label': { busy: 'выполняется', ok: 'готово', bad: 'ошибка', skip: 'пропущено' }[x.st] || 'в очереди' },
        (mark[x.st] || (() => String(i + 1)))()),
      h('div', { class: 'grow' },
        h('div', { class: 'bl' }, h('span', { class: 'trunc', title: x.label, text: x.label }), h('b', { text: x.mb ? mb(x.mb) : '' })),
        x.msg ? h('div', { class: 'bm', text: x.msg }) : [x.warn ? h('div', { class: 'bw', text: x.warn }) : null,
          x.text ? h('div', { class: 'bc', title: x.text, text: x.text }) : null])))));
    const cur = $('#cf-targets .busy');
    if (cur) cur.scrollIntoView({ block: 'nearest' });
  }

  // по одному, дожидаясь ответа; ошибку отмечаем и идём дальше
  async function runBulk() {
    if (posting) return;
    posting = true;
    abort = false;
    const ok = $('#cf-ok'), cancel = $('#cf-cancel');
    ok.disabled = true;
    ok.classList.add('busy');
    cancel.textContent = 'Прервать';
    let done = 0, got = 0;
    for (const x of bulk) {
      if (abort) {
        x.st = 'skip';
        x.msg = 'пропущено: прервано';
        continue;
      }
      x.st = 'busy';
      drawBulk();
      try {
        const r = await api('/api/action', { action_id: x.id }, 60000);
        if (r && r.ok === false) throw Object.assign(new Error(r.error || 'Не получилось'), { status: 500 });
        x.st = 'ok';
        x.msg = (r && r.message) || 'Готово';
        done++;
        got += num0(r && r.freed_mb);
        sel.delete(x.key);
      } catch (e) {
        x.st = 'bad';
        x.msg = e.status ? e.message : e.name === 'TimeoutError' ? 'Панель не ответила за минуту — проверь, что вышло' : 'Нет связи с панелью';
      }
      drawBulk();
    }
    drawBulk();
    posting = false;
    ok.disabled = false;
    ok.classList.remove('busy');
    ok.hidden = true;
    cancel.textContent = 'Закрыть';
    cancel.focus();
    const msg = `Готово: ${done} из ${bulk.length}` + (got > 0 ? ` · освобождено ≈${mb(got)}` : '');
    $('#cf-title').textContent = msg;
    $('#cf-meta').textContent = '';
    $('#cf-text').textContent = done < bulk.length ? 'Что не вышло — осталось выбранным: можно повторить или снять выбор.' : '';
    toast(msg, done < bulk.length ? 'bad' : '');
    bulkBar();
    refresh(true);
  }
  // pre — приставка data-key для второй такой же кнопки на вкладке
  function actBtn(id, pre = '') {
    return h('button', { 'data-key': pre + 'act:' + id, title: actionInfo(id).label || '', onclick: () => confirmAction(id) }, verbOf(id)[0]);
  }

  // что остановится; длинный список — после 5 под катом
  function targetList(list, verb) {
    if (!list.length) return [];
    const row = (t) => h('div', { class: 'tg' }, h('span', { class: 'trunc', title: txt(t.name), text: txt(t.name) }),
      h('span', { class: 'pid', text: txt(t.pid) }), h('span', { class: 'r', text: mb(t.mb) }));
    return [h('div', { class: 'cap', text: verb === 'Перезапустить' ? 'Перезапустится:' : 'Остановится:' }), ...list.slice(0, 5).map(row),
      list.length > 5 ? h('details', {}, h('summary', { text: `ещё ${list.length - 5}` }), list.slice(5).map(row)) : null];
  }

  let pending = null; // id действия в открытой карточке
  let posting = false; // POST идёт: второй раз не отправим
  let opener = null; // data-key кнопки-открывашки — вернуть фокус
  function confirmAction(id) {
    if (!id) return;
    // пока идёт POST, вторую отправку не начинаем
    if (posting) return toast('Дождись ответа на предыдущее действие', 'quiet');
    const a = own((snap && snap.actions) || {}, id);
    // чего нет в actions (живые и разрешённые), то не подтверждаем
    if (!a) {
      toast('Действие устарело — обновляю');
      refresh(true);
      return;
    }
    const [verb, cls] = verbOf(id);
    const targets = [...arr(a.targets)].sort((x, y) => num0(y.mb) - num0(x.mb));
    const freed = sum(targets.map((t) => t.mb));
    $('#cf-title').textContent = a.label || id;
    $('#cf-meta').textContent = targets.length ? plural(targets.length, 'процесс', 'процесса', 'процессов') + (freed > 0 ? ` · ≈${mb(freed)}` : '') : '';
    $('#cf-warn').hidden = !a.warning;
    $('#cf-warn-t').textContent = a.warning || '';
    $('#cf-text').textContent = a.confirm || '';
    $('#cf-cmd').hidden = !a.command;
    $('#cf-cmd-t').textContent = a.command || '';
    $('#cf-targets').replaceChildren(...targetList(targets, verb).filter(Boolean));
    bulk = null;
    pending = id;
    dialogFor(verb, cls);
  }

  // по умолчанию «Отмена» — Enter ничего не остановит
  function dialogFor(text, cls) {
    const ok = $('#cf-ok'), dlg = $('#confirm');
    ok.className = cls;
    ok.hidden = false;
    $('#cf-ok-t').textContent = text;
    $('#cf-cancel').textContent = 'Отмена';
    opener = (document.activeElement && document.activeElement.dataset && document.activeElement.dataset.key) || null;
    if (!dlg.open) dlg.showModal();
    $('#cf-cancel').focus();
  }

  async function runAction() {
    if (bulk) return runBulk();
    const id = pending;
    if (!id || posting) return;
    posting = true;
    const ok = $('#cf-ok'), cancel = $('#cf-cancel');
    ok.disabled = cancel.disabled = true;
    ok.classList.add('busy');
    let again = true; // после ответа сразу собрать свежий снимок
    try {
      const r = await api('/api/action', { action_id: id }, 60000);
      if (r && r.ok === false) throw Object.assign(new Error(r.error || 'Не получилось'), { status: 500 });
      toast((r && r.message) || 'Готово');
    } catch (e) {
      // 400 — снимок устарел; 403/409/500 — текст сервера; без ответа — тоже перечитываем
      if (e.status === 400) toast('Действие устарело — обновляю');
      else if (e.status) {
        again = false;
        toast(e.message, 'bad');
      } else toast(e.name === 'TimeoutError' ? 'Панель не ответила за минуту — проверь, что получилось' : 'Нет связи с панелью — проверь, что получилось', 'bad');
    } finally {
      posting = false;
      pending = null;
      ok.disabled = cancel.disabled = false;
      ok.classList.remove('busy');
      $('#confirm').close();
    }
    if (again) refresh(true);
  }

  async function copy(text) {
    try {
      await navigator.clipboard.writeText(text);
      toast('Скопировано');
    } catch {
      const t = h('textarea', { class: 'sr', value: text });
      document.body.append(t);
      t.select();
      let ok = false;
      try { ok = document.execCommand('copy'); } catch { /* нет буфера — скажем */ }
      t.remove();
      toast(ok ? 'Скопировано' : 'Не удалось скопировать');
    }
  }

  // --- вкладки по хэшу: #sessions, #bots, #memory ---
  function setTab(name) {
    tab = TABS.includes(name) ? name : 'overview';
    for (const t of TABS) $('#v-' + t).hidden = t !== tab;
    for (const a of document.querySelectorAll('.tabs a')) {
      if (a.dataset.tab === tab) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
    }
    revealTab();
    renderTab();
    bulkBar();
    if (tab === 'memory' && !simple) drawHistory();
    if (histTab()) histSoon();
  }

  // «Просто | Подробно»: перерисовка на месте, без перезагрузки; вкладка та же
  function setView(v) {
    simple = v === 'simple';
    store.set('view', simple ? 'simple' : 'full');
    syncView();
    if (snap) renderHeader();
    renderTab();
    bulkBar();
    if (tab === 'memory' && !simple) drawHistory();
    histSoon(); // нужна ли история этой вкладке — решит pollHistory
  }
  function syncView() {
    document.documentElement.dataset.view = simple ? 'simple' : 'full';
    for (const b of document.querySelectorAll('#view-sw button')) b.setAttribute('aria-pressed', String((b.dataset.v === 'simple') === simple));
  }

  // ряд вкладок прокручивается — держим активную на виду
  function revealTab() {
    const a = $('.tabs a[aria-current="page"]');
    if (!a) return;
    const bar = a.parentElement, r = a.getBoundingClientRect(), b = bar.getBoundingClientRect();
    if (r.left < b.left) bar.scrollLeft += r.left - b.left - 8;
    else if (r.right > b.right) bar.scrollLeft += r.right - b.right + 8;
  }

  function go(name, anchor) {
    history.pushState(null, '', '#' + name);
    setTab(name);
    const el = anchor && document.getElementById(anchor);
    if (el) el.scrollIntoView({ block: 'start' });
  }

  // --- поповер темы ---
  function buildPop() {
    const opt = (attr, value, label, onclick) => h('button', { [attr]: value, onclick }, label);
    $('#theme-pop').replaceChildren(
      h('div', {},
        h('h2', { class: 'h' }, 'Тема', h('button', { class: 'icon ghost r', 'aria-label': 'Закрыть', onclick: () => closePop() }, icon('close'))),
        h('div', { class: 'presets' }, Object.entries(THEMES).map(([k, n]) => opt('data-preset', k,
          [h('span', { class: 'pv', 'data-theme': k, 'aria-hidden': 'true' }, h('i'), h('i'), h('i')), n], () => setPref('preset', k))))),
      h('div', {},
        h('h2', { class: 'h' }, 'Акцент'),
        h('div', { class: 'swatches' },
          Object.entries(ACCENTS).map(([k, n]) => {
            const b = h('button', { class: 'sw', 'data-accent': k, 'aria-label': n, title: n, onclick: () => setPref('accent', k) });
            b.style.background = `var(--${k})`;
            return b;
          }),
          h('input', {
            type: 'color', id: 'accent-pick', 'aria-label': 'Свой цвет акцента', title: 'Свой цвет',
            oninput: (e) => { look.accent = e.target.value; applyTheme(); }, onchange: (e) => setPref('accent', e.target.value),
          }),
          h('button', { class: 'link', onclick: () => setPref('accent', '') }, 'сбросить'))),
      h('div', {},
        h('h2', { class: 'h' }, 'Плотность'),
        h('div', { class: 'opts' }, Object.entries(DENSITY).map(([k, n]) => opt('data-dens', k, n, () => setPref('density', k))))),
      h('div', {},
        h('h2', { class: 'h' }, 'Размер шрифта'),
        h('div', { class: 'opts' }, FONTS.map((px) => opt('data-fsz', px, px + ' px', () => setPref('font', px))))));
  }

  function syncPop() {
    const pop = $('#theme-pop');
    if (!pop || !pop.firstChild) return;
    const mark = (attr, val) => {
      for (const b of pop.querySelectorAll(`[${attr}]`)) b.setAttribute('aria-pressed', String(b.getAttribute(attr) === String(val)));
    };
    mark('data-preset', look.preset);
    mark('data-accent', look.accent);
    mark('data-dens', look.density);
    mark('data-fsz', look.font);
    const cur = getComputedStyle(document.documentElement).getPropertyValue('--accent').trim();
    if (/^#[0-9a-f]{6}$/i.test(cur)) $('#accent-pick').value = cur.toLowerCase();
  }

  function openPop() {
    const pop = $('#theme-pop'), btn = $('#theme-btn');
    const r = btn.getBoundingClientRect();
    pop.style.top = Math.round(r.bottom + 6) + 'px';
    pop.style.right = Math.max(8, Math.round(document.documentElement.clientWidth - r.right)) + 'px';
    pop.hidden = false;
    btn.setAttribute('aria-expanded', 'true');
    syncPop();
    const first = pop.querySelector('[data-preset][aria-pressed="true"]');
    if (first) first.focus();
  }

  function closePop(focusBack = true) {
    const pop = $('#theme-pop');
    if (pop.hidden) return;
    pop.hidden = true;
    $('#theme-btn').setAttribute('aria-expanded', 'false');
    if (focusBack) $('#theme-btn').focus();
  }

  // --- старт ---
  function init() {
    buildPop();
    $('#theme-btn').addEventListener('click', () => ($('#theme-pop').hidden ? openPop() : closePop()));
    $('#refresh-btn').addEventListener('click', () => refresh(false));
    // Esc: поповер темы, потом разбор; <dialog> закрывается сам
    document.addEventListener('keydown', (e) => {
      if (e.key !== 'Escape' || $('#confirm').open) return;
      if (!$('#theme-pop').hidden) closePop();
      else if (drill && $(`#v-${tab} .drill`)) toggleDrill(drill); // разбор на другой вкладке не трогаем
    });
    document.addEventListener('pointerdown', (e) => {
      if (!$('#theme-pop').hidden && !$('#theme-pop').contains(e.target) && !$('#theme-btn').contains(e.target)) closePop(false);
    });
    document.addEventListener('pointerdown', () => { pressedAt = Date.now(); }, true);
    for (const ev of ['pointerup', 'pointercancel']) document.addEventListener(ev, () => { pressedAt = 0; }, true);
    $('#cf-ok').addEventListener('click', runAction);
    // пока идёт POST, Esc не закрывает карточку
    $('#confirm').addEventListener('cancel', (e) => { if (posting) e.preventDefault(); });
    // «Прервать»: текущий пункт доделается, остальные пропустим
    $('#confirm form').addEventListener('submit', (e) => {
      if (!posting) return;
      e.preventDefault();
      abort = true;
      $('#cf-cancel').textContent = 'Прерываю…';
    });
    $('#confirm').addEventListener('close', () => {
      if (posting) return;
      pending = bulk = null;
      focusKey(opener);
      opener = null;
    });
    $('#bk-stop').addEventListener('click', () => openBulk(false));
    $('#bk-off').addEventListener('click', () => openBulk(true));
    $('#bk-clear').addEventListener('click', () => {
      sel.clear();
      for (const c of document.querySelectorAll('input.pick')) c.checked = false;
      bulkBar();
    });
    // всплывашка карты: мышь — наведение, палец — тап
    document.addEventListener('pointermove', (e) => { if (e.pointerType === 'mouse') tipAt(e); });
    document.addEventListener('pointerdown', (e) => { if (e.pointerType !== 'mouse') tipAt(e); });
    addEventListener('scroll', () => { $('#mtip').hidden = true; }, { passive: true });
    window.addEventListener('hashchange', () => { setTab(location.hash.slice(1)); window.scrollTo(0, 0); });
    for (const b of document.querySelectorAll('#view-sw button')) b.addEventListener('click', () => setView(b.dataset.v));
    syncView();
    let resizeTimer;
    window.addEventListener('resize', () => {
      clearTimeout(resizeTimer);
      resizeTimer = setTimeout(() => { if (tab === 'memory') drawHistory(); }, 150);
    });
    setTab(location.hash.slice(1));
    if (snap) render(snap);
    poll();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();

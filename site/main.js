// Agentilo landing page. No dependencies.
(() => {
  const $ = (s, el = document) => el.querySelector(s);
  const $$ = (s, el = document) => [...el.querySelectorAll(s)];
  const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const finePointer = matchMedia("(hover: hover) and (pointer: fine)").matches;

  // ── Headline words ───────────────────────────────────────
  $$(".headline .word").forEach((w, i) => w.style.setProperty("--i", i));
  $$(".hero .reveal").forEach((el, i) => el.style.setProperty("--d", `${i * 0.08}s`));
  requestAnimationFrame(() => requestAnimationFrame(() => document.body.classList.add("ready")));

  // ── Reveal on scroll ─────────────────────────────────────
  const revealer = new IntersectionObserver((entries) => {
    for (const e of entries) if (e.isIntersecting) { e.target.classList.add("in"); revealer.unobserve(e.target); }
  }, { rootMargin: "0px 0px -10% 0px" });
  $$(".cards .card").forEach((el, i) => el.style.setProperty("--d", `${(i % 4) * 0.08}s`));
  $$(".reveal").forEach((el) => revealer.observe(el));

  // ── The notch ────────────────────────────────────────────
  const stage = $(".notch-stage");
  const notch = $("#notch");
  const ring = $(".wing-left .ring");
  const pillPct = $(".pill-pct");
  const scenes = $$(".scene", notch);

  // What the collapsed pill shows for each scene: the most critical window.
  const pill = {
    idle: [0.64, "amber", "64%"], hover: [0.64, "amber", "64%"], limits: [0.64, "amber", "64%"],
    pace: [0.81, "red", "81%"], alert: [0.9, "red", "90%"], agents: [0.81, "red", "81%"],
    approval: [0.81, "red", "81%"], activity: [0.38, "green", "38%"],
  };
  const openScenes = new Set(["limits", "pace", "agents", "approval", "activity"]);

  let pageScene = "idle";
  let hovering = false;

  function render() {
    const open = hovering || openScenes.has(pageScene);
    const scene = hovering && !openScenes.has(pageScene) ? "limits" : pageScene;
    notch.classList.toggle("open", open);
    notch.dataset.scene = scene;
    stage.classList.toggle("alerting", pageScene === "alert" && !hovering);
    for (const s of scenes) s.classList.toggle("on", open && s.dataset.for.split(" ").includes(scene));
    const [p, color, text] = pill[scene] ?? pill.idle;
    ring.style.setProperty("--p", p);
    ring.style.setProperty("--c", `var(--${color})`);
    pillPct.textContent = text;
    pillPct.style.color = `var(--${color})`;
    document.documentElement.style.setProperty("--aura", open ? 0.55 : 1);
    $$(".rail li").forEach((li) => li.classList.toggle("on", li.dataset.ch === pageScene));
  }

  notch.addEventListener("mouseenter", () => { hovering = true; render(); });
  notch.addEventListener("mouseleave", () => { hovering = false; render(); });
  notch.addEventListener("click", () => { if (!finePointer) { hovering = !hovering; render(); } });

  // The section nearest the middle of the window picks the scene.
  const sceneSections = $$("[data-scene]").filter((el) => el !== notch);
  const chapters = $$(".chapter");
  function pickScene() {
    const mid = innerHeight * 0.55;
    let best = null, bestDist = Infinity;
    for (const el of sceneSections) {
      const r = el.getBoundingClientRect();
      if (r.bottom < 0 || r.top > innerHeight) continue;
      const d = r.top <= mid && r.bottom >= mid ? 0 : Math.min(Math.abs(r.top - mid), Math.abs(r.bottom - mid));
      if (d < bestDist) { bestDist = d; best = el; }
    }
    const next = best?.dataset.scene ?? "idle";
    chapters.forEach((c) => c.classList.toggle("active", c === best));
    if (next !== pageScene) { pageScene = next; render(); }
  }

  // ── Live numbers inside the notch ────────────────────────
  const t0 = Date.now();
  const fmtTime = (d) => d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  const fmtDay = (d) => d.toLocaleDateString([], { weekday: "short" });
  const countdown = (s) => {
    s = Math.max(0, Math.round(s));
    const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
    return d ? `${d}d ${h}h` : h ? `${h}h ${String(m).padStart(2, "0")}m` : `${m}m ${String(s % 60).padStart(2, "0")}s`;
  };
  const tickers = $$(".notch .win-head small.dim").map((el, i) => ({ el, secs: [9480, 274000, 13800][i] ?? 9000 }));
  const runOut = $("[data-for='pace'] .pace.red");
  // Codex weekly: 81% used, 4 of 7 days gone, so at this rate it empties in ~22.5h, 2 days early.
  const runOutAt = new Date(t0 + 22.5 * 3600e3);
  const codexReset = new Date(t0 + 3 * 86400e3);
  function tick() {
    const now = Date.now();
    for (const t of tickers) {
      const left = t.secs - (now - t0) / 1000;
      const at = new Date(t0 + t.secs * 1000);
      const day = left > 86400 ? `${fmtDay(at)} ` : "";
      t.el.textContent = `resets ${day}${fmtTime(at)} · ${countdown(left)}`;
    }
    if (runOut) runOut.textContent = `Runs out ${fmtDay(runOutAt)} ${fmtTime(runOutAt)}`;
    const alertLine = $(".alert small");
    if (alertLine) alertLine.textContent = `Runs out ${fmtDay(runOutAt)} ${fmtTime(runOutAt)} · resets ${fmtDay(codexReset)} ${fmtTime(codexReset)}`;
    const cd = $(".countdown");
    if (cd) cd.textContent = `${Math.max(1, 48 - (Math.floor((now - t0) / 1000) % 48))}s`;
  }
  tick();
  setInterval(tick, 1000);

  // ── Heatmap: 26 weeks of plausible, seeded activity ──────
  const heat = $("#heat");
  if (heat) {
    let seed = 7;
    const rnd = () => ((seed = (seed * 16807) % 2147483647) - 1) / 2147483646;
    const total = 26 * 7;
    const frag = document.createDocumentFragment();
    for (let i = 0; i < total; i++) {
      const cell = document.createElement("i");
      const weekday = i % 7, ramp = i / total;
      const v = rnd() * (0.55 + ramp) * (weekday === 0 || weekday === 6 ? 0.5 : 1);
      const streak = i > total - 24;
      cell.dataset.l = streak ? Math.max(1, Math.min(4, Math.round(v * 4))) : v < 0.18 ? 0 : Math.min(4, Math.round(v * 4));
      if (i === total - 1) { cell.className = "today"; cell.dataset.l = 4; }
      frag.append(cell);
    }
    heat.append(frag);
  }

  // ── Scroll effects ───────────────────────────────────────
  const wordmark = $(".wordmark span");
  let ticking = false;
  function onScroll() {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(() => {
      ticking = false;
      pickScene();
      if (wordmark) {
        const r = wordmark.getBoundingClientRect();
        const sweep = 1.3 - (r.top / innerHeight) * 1.3;
        wordmark.style.setProperty("--sweep", Math.max(-0.3, Math.min(1.3, sweep)).toFixed(3));
      }
    });
  }
  // On phones, shrink the notch until its widest scene fits the screen.
  function fitNotch() {
    const s = innerWidth < 700 ? Math.min(0.62, (innerWidth - 16) / 680) : null;
    document.documentElement.style.setProperty("--notch-scale", s ?? "");
    if (s === null) document.documentElement.style.removeProperty("--notch-scale");
  }
  fitNotch();
  addEventListener("scroll", onScroll, { passive: true });
  addEventListener("resize", () => { fitNotch(); onScroll(); });
  onScroll();
  render();

  // ── Magnetic buttons ─────────────────────────────────────
  if (finePointer && !reduced) {
    for (const b of $$(".magnetic")) {
      b.addEventListener("pointermove", (e) => {
        const r = b.getBoundingClientRect();
        b.style.setProperty("--mx", `${(e.clientX - r.left - r.width / 2) * 0.18}px`);
        b.style.setProperty("--my", `${(e.clientY - r.top - r.height / 2) * 0.3}px`);
      });
      b.addEventListener("pointerleave", () => { b.style.setProperty("--mx", "0px"); b.style.setProperty("--my", "0px"); });
    }
  }

  // ── Pace playground: Pace.evaluate from AgentiloCore, verbatim ──
  const WINDOW = 300; // minutes
  const used = $("#used"), elapsed = $("#elapsed");
  const card = $(".pg-card"), meter = $("#pgMeter");
  function evaluate(u, e) {
    if (u >= 100) return { kind: "limit" };
    const expected = (e / WINDOW) * 100;
    const gap = u - expected;
    if (gap <= 5) return { kind: "onTrack", expected };
    if (gap <= 12) return { kind: "ahead", expected };
    const runoutIn = (100 - u) / (u / e); // minutes
    return runoutIn < WINDOW - e ? { kind: "runsOut", expected, runoutIn } : { kind: "ahead", expected };
  }
  const hm = (min) => `${Math.floor(min / 60)}h ${String(Math.round(min % 60)).padStart(2, "0")}m`;
  function updatePace() {
    const u = +used.value, e = +elapsed.value;
    const r = evaluate(u, e);
    const left = WINDOW - e;
    const now = Date.now();
    const color = r.kind === "onTrack" ? "green" : r.kind === "ahead" ? "amber" : "red";
    card.className = `pg-card ${color}`;
    meter.className = `pg-meter ${color}`;
    meter.style.setProperty("--f", u / 100);
    meter.style.setProperty("--x", e / WINDOW);
    $("#pgTickLabel").style.setProperty("--x", e / WINDOW);
    $("#pgPct").textContent = `${u}%`;
    $("#usedOut").textContent = `${u}%`;
    $("#elapsedOut").textContent = `${hm(e)} of 5h`;
    const label = $("#pgPace"), note = $("#pgNote");
    const resetAt = fmtTime(new Date(now + left * 60e3));
    switch (r.kind) {
      case "limit":
        label.textContent = `Limit reached · resets ${resetAt}`;
        note.textContent = `Nothing left until the window resets in ${hm(left)}.`;
        break;
      case "onTrack":
        label.textContent = "On track";
        note.textContent = `Even pace would be ${Math.round(r.expected)}% by now. At this rate you reach the ${resetAt} reset with room to spare.`;
        break;
      case "ahead":
        label.textContent = "Ahead of pace";
        note.textContent = `${Math.round(u - r.expected)} points over an even pace. Worth a glance, not a worry yet.`;
        break;
      case "runsOut": {
        const at = fmtTime(new Date(now + r.runoutIn * 60e3));
        label.textContent = `Runs out ${at}`;
        note.textContent = `At this rate the window is empty in ${hm(r.runoutIn)}, ${hm(left - r.runoutIn)} before it resets at ${resetAt}.`;
        break;
      }
    }
  }
  used?.addEventListener("input", updatePace);
  elapsed?.addEventListener("input", updatePace);
  if (used) updatePace();

  // ── Terminal ─────────────────────────────────────────────
  const term = $("#term code");
  const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;");
  const json = (o, ind = "") => {
    if (Array.isArray(o)) return `[\n${o.map((v) => `${ind}  ${json(v, ind + "  ")}`).join(",\n")}\n${ind}]`;
    if (o && typeof o === "object") return `{\n${Object.entries(o).map(([k, v]) => `${ind}  <span class="k">"${k}"</span>: ${json(v, ind + "  ")}`).join(",\n")}\n${ind}}`;
    if (typeof o === "string") return `<span class="s">"${esc(o)}"</span>`;
    return `<span class="n">${o}</span>`;
  };
  const iso = (ms) => new Date(Math.round(ms / 60e3) * 60e3).toISOString().replace(".000", "");
  const script = [
    { cmd: "agentilo limits --short", out: `<span class="c">Claude S 38% W 64% · Codex S 22% W 81%! · Cursor M 75%</span>` },
    {
      cmd: "curl -s 127.0.0.1:6737/v1/limits | jq '.accounts[1].windows[1]'",
      out: json({ kind: "weekly", title: "Weekly", usedPercent: 81, remainingPercent: 19, resetsAt: iso(codexReset.getTime()), pace: "runsOut", runsOutAt: iso(runOutAt.getTime()) }),
    },
    { cmd: "agentilo quiet 45m", out: `<span class="c">Snoozed until ${new Date(Date.now() + 45 * 60e3).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}</span>` },
  ];
  let typed = false;
  async function typeTerminal() {
    if (typed || !term) return;
    typed = true;
    const sleep = (ms) => new Promise((r) => setTimeout(r, reduced ? 0 : ms));
    let html = "";
    const paint = (extra = "") => { term.innerHTML = html + extra; };
    for (const step of script) {
      html += `<span class="p">~</span> <span class="d">$</span> `;
      for (const ch of step.cmd) { html += esc(ch); paint('<span class="cursor"></span>'); await sleep(22 + Math.random() * 40); }
      html += "\n";
      paint();
      await sleep(260);
      html += `${step.out}\n\n`;
      paint();
      await sleep(700);
    }
    html += `<span class="p">~</span> <span class="d">$</span> `;
    paint('<span class="cursor"></span>');
  }
  if (term) {
    new IntersectionObserver((entries, obs) => {
      if (entries.some((e) => e.isIntersecting)) { typeTerminal(); obs.disconnect(); }
    }, { threshold: 0.35 }).observe(term);
  }

  // ── Copy buttons ─────────────────────────────────────────
  for (const b of $$(".copy")) {
    b.addEventListener("click", async () => {
      try { await navigator.clipboard.writeText(b.dataset.copy); } catch { return; }
      b.classList.add("copied");
      $(".copy-label", b).textContent = "Copied";
      setTimeout(() => { b.classList.remove("copied"); $(".copy-label", b).textContent = "Copy"; }, 1800);
    });
  }

  // ── GitHub stars ─────────────────────────────────────────
  fetch("https://api.github.com/repos/farvisun/agentilo")
    .then((r) => (r.ok ? r.json() : null))
    .then((d) => { if (d?.stargazers_count > 0) $("#stars").textContent = `★ ${d.stargazers_count.toLocaleString()}`; })
    .catch(() => {});
})();

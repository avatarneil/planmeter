/* PlanMeter web client.
 *
 * Same protocol as the iOS app (see Sources/PlanMeterRemote/SecureChannel.swift):
 * per-request ephemeral P-256 ECDH against the Mac's pinned key, HKDF-SHA256
 * request/response keys, AES-256-GCM with the request header as additional
 * data, and an ECDSA P-256 proof over method, path, device id, timestamp,
 * nonce, ephemeral key, cipher, and the ciphertext hash. The device key is a
 * non-extractable WebCrypto key kept in IndexedDB. No dependencies.
 */
(() => {
  "use strict";

  const LABEL = "planmeter-remote-v1";
  const CIPHER = "aes-256-gcm";
  const PATH_RPC = "/v1/rpc";
  const PATH_PAIR = "/v1/pair";
  const PATH_WEB_INVITE = "/v1/web-pairing-invite";
  const DB_NAME = "planmeter";
  const STORE = "kv";

  // ---------- small utils ----------
  const $ = (id) => document.getElementById(id);
  const enc = new TextEncoder();
  const b64 = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf)));
  const unb64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
  const unb64url = (s) => unb64(s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4));
  const b64url = (buf) => b64(buf).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const concat = (...parts) => {
    const total = parts.reduce((n, p) => n + p.byteLength, 0);
    const out = new Uint8Array(total);
    let o = 0;
    for (const p of parts) { out.set(new Uint8Array(p), o); o += p.byteLength; }
    return out;
  };
  const usd = (v) => {
    if (!v) return "$0.00";
    if (v > 0 && v < 0.005) return "<$0.01";
    return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: v >= 1000 ? 0 : 2 }).format(v);
  };
  const tokens = (n) => {
    if (n >= 1e9) return (n / 1e9).toFixed(2) + "B";
    if (n >= 1e6) return (n / 1e6).toFixed(1) + "M";
    if (n >= 1e4) return Math.round(n / 1e3) + "K";
    if (n >= 1e3) return (n / 1e3).toFixed(1) + "K";
    return String(n);
  };
  const pct = (f) => (isFinite(f) ? Math.round(f * 100) + "%" : "–");
  const rel = (date) => {
    const s = Math.round((new Date(date) - Date.now()) / 1000);
    const abs = Math.abs(s);
    const rtf = new Intl.RelativeTimeFormat("en", { numeric: "auto", style: "short" });
    if (abs < 60) return rtf.format(s, "second");
    if (abs < 3600) return rtf.format(Math.round(s / 60), "minute");
    if (abs < 86400) return rtf.format(Math.round(s / 3600), "hour");
    return rtf.format(Math.round(s / 86400), "day");
  };
  const groupName = (g) => ({ personal: "Personal", work: "Work" }[g] || "Other");
  const groupColor = (g) => ({ personal: "var(--personal)", work: "var(--work)" }[g] || "var(--other)");
  const PALETTE = ["#4f7cff", "#f0883e", "#2fb87a", "#c06ad9", "#e5484d", "#0aa8a7", "#d9a400", "#8b8f98"];
  const el = (tag, cls, text) => {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
  };

  // ---------- storage (IndexedDB holds CryptoKey objects) ----------
  function openDB() {
    return new Promise((resolve, reject) => {
      const req = indexedDB.open(DB_NAME, 1);
      req.onupgradeneeded = () => req.result.createObjectStore(STORE);
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
  }
  async function kvGet(key) {
    const db = await openDB();
    return new Promise((resolve, reject) => {
      const r = db.transaction(STORE, "readonly").objectStore(STORE).get(key);
      r.onsuccess = () => resolve(r.result);
      r.onerror = () => reject(r.error);
    });
  }
  async function kvSet(key, value) {
    const db = await openDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORE, "readwrite");
      tx.objectStore(STORE).put(value, key);
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
  }
  async function kvDel(key) {
    const db = await openDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORE, "readwrite");
      tx.objectStore(STORE).delete(key);
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
  }

  // ---------- crypto ----------
  async function deviceKey() {
    let pair = await kvGet("deviceKey");
    if (!pair) {
      pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, false, ["sign", "verify"]);
      await kvSet("deviceKey", pair);
    }
    return pair;
  }

  async function seal(plaintextBytes, serverPubRaw, deviceId, signingKey, method, path) {
    const eph = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
    const serverPub = await crypto.subtle.importKey("raw", serverPubRaw, { name: "ECDH", namedCurve: "P-256" }, false, []);
    const shared = await crypto.subtle.deriveBits({ name: "ECDH", public: serverPub }, eph.privateKey, 256);
    const nonce = crypto.getRandomValues(new Uint8Array(12));
    const timestamp = Math.floor(Date.now() / 1000);
    const ephRaw = new Uint8Array(await crypto.subtle.exportKey("raw", eph.publicKey));
    const base = await crypto.subtle.importKey("raw", shared, "HKDF", false, ["deriveKey"]);
    const derive = (dir) => crypto.subtle.deriveKey(
      { name: "HKDF", hash: "SHA-256", salt: nonce, info: enc.encode(`${LABEL}|${deviceId}|${dir}`) },
      base, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
    const [reqKey, resKey] = await Promise.all([derive("request"), derive("response")]);
    const header = enc.encode(`${LABEL}\n${method.toUpperCase()}\n${path}\n${deviceId}\n${timestamp}\n${b64(nonce)}\n${b64(ephRaw)}\n${CIPHER}\n`);
    const ctTag = await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce, additionalData: header }, reqKey, plaintextBytes);
    const combined = concat(nonce, ctTag);
    const hash = await crypto.subtle.digest("SHA-256", combined);
    const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, signingKey, concat(header, hash));
    return {
      request: { v: 1, deviceId, ephemeralPublicKey: b64(ephRaw), nonce: b64(nonce), timestamp, ciphertext: b64(combined), signature: b64(signature), cipher: CIPHER },
      resKey,
    };
  }

  async function openResponse(sealed, resKey) {
    const nonce = unb64(sealed.nonce);
    const combined = unb64(sealed.ciphertext);
    if (combined.byteLength < 12 + 16) throw new Error("Malformed reply.");
    const plaintext = await crypto.subtle.decrypt({ name: "AES-GCM", iv: nonce, additionalData: nonce }, resKey, combined.subarray(12));
    return JSON.parse(new TextDecoder().decode(plaintext));
  }

  async function exchange(path, payload, serverPubRaw, deviceId, keyPair) {
    const { request, resKey } = await seal(enc.encode(JSON.stringify(payload)), serverPubRaw, deviceId, keyPair.privateKey, "POST", path);
    const res = await fetch(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(request), cache: "no-store", credentials: "omit" });
    if (!res.ok) {
      let msg = `Server returned HTTP ${res.status}.`;
      try { msg = (await res.json()).error || msg; } catch (_) {}
      throw new Error(msg);
    }
    return openResponse(await res.json(), resKey);
  }

  // ---------- state ----------
  const state = { server: null, keyPair: null, days: 30, summary: null, timeline: null, limits: null, models: [], loading: false, timer: null };

  function accountColor(id) {
    const accounts = (state.timeline && state.timeline.accounts) || (state.summary ? state.summary.groups.flatMap((g) => g.accounts.map((a) => a.account)) : []);
    const i = accounts.findIndex((a) => a.id === id);
    if (i < 0) return "#8b8f98";
    const hex = accounts[i].accentColorHex;
    if (hex && accounts.filter((a) => a.accentColorHex === hex).length === 1) return hex;
    return PALETTE[i % PALETTE.length];
  }

  // ---------- pairing ----------
  /// Normalizes a parsed code (see pair-parse.js) into what pair() needs.
  function inviteFrom(text) {
    const p = window.PlanMeterPair && PlanMeterPair.parse(text);
    if (!p) return null;
    return { serverPublicKey: p.key, token: p.token, expiresAt: p.expiresAt.getTime(), serverName: p.serverName || location.hostname, origin: p.origin };
  }

  function parseInvite() {
    return location.hash && location.hash.length > 1 ? inviteFrom(location.href) : null;
  }

  function setStatus(text, isError) {
    const status = $("pairing-status");
    status.className = "status" + (isError ? " err" : "");
    status.textContent = text || "";
  }

  async function pair(invite) {
    setStatus("");
    if (Date.now() > invite.expiresAt) { setStatus("This pairing code has expired. Make a new one on the Mac.", true); return; }
    // The code pins a server key; only use it against the server this page
    // came from, so a code for another machine cannot be replayed here.
    if (invite.origin) {
      let host = null;
      try { host = new URL(invite.origin).hostname; } catch (_) {}
      if (host && host !== location.hostname) {
        setStatus(`This code is for ${host}, but this page is served by ${location.hostname}. Open PlanMeter at that address or make a Web code on the Mac.`, true);
        return;
      }
    }
    setStatus("Pairing…");
    try {
      const keyPair = await deviceKey();
      const pubRaw = new Uint8Array(await crypto.subtle.exportKey("raw", keyPair.publicKey));
      const ua = navigator.userAgent;
      // iPadOS Safari reports a Mac user agent; touch support tells them apart.
      const device = /iPhone/.test(ua) ? "iPhone" : /iPad/.test(ua) || (/Mac/.test(ua) && navigator.maxTouchPoints > 1) ? "iPad" : /Android/.test(ua) ? "Android" : /Mac/.test(ua) ? "Mac" : "Browser";
      const browser = /CriOS|Chrome/.test(ua) ? "Chrome" : /Firefox|FxiOS/.test(ua) ? "Firefox" : /Safari/.test(ua) ? "Safari" : "Browser";
      const reply = await exchange(PATH_PAIR, { token: invite.token, deviceName: `${browser} on ${device}`, devicePublicKey: b64(pubRaw), platform: "web" }, invite.serverPublicKey, "pairing", keyPair);
      const server = { deviceId: reply.deviceId, serverName: reply.serverName, serverPublicKey: b64(invite.serverPublicKey), pairedAt: new Date().toISOString(), origin: location.origin };
      await kvSet("server", server);
      state.server = server;
      state.keyPair = keyPair;
      history.replaceState(null, "", location.pathname);
      showDashboard();
      await refresh();
      state.timer = state.timer || setInterval(() => { if (document.visibilityState === "visible") refresh(); }, 60000);
    } catch (err) {
      setStatus(err.message || String(err), true);
    }
  }

  // ---------- in-page QR scanning ----------
  // Home Screen web apps get their own storage, and iOS hands camera-scanned
  // codes to Safari, so the page has to be able to scan on its own. jsQR
  // (Apache-2.0, vendored) decodes frames; WebCrypto is not involved here.
  let jsqrLoading = null;
  function loadJsQR() {
    if (window.jsQR) return Promise.resolve(window.jsQR);
    if (!jsqrLoading) {
      jsqrLoading = new Promise((resolve, reject) => {
        const s = document.createElement("script");
        s.src = "/jsqr.js";
        s.onload = () => (window.jsQR ? resolve(window.jsQR) : reject(new Error("QR decoder failed to load.")));
        s.onerror = () => reject(new Error("QR decoder failed to load."));
        document.head.append(s);
      });
    }
    return jsqrLoading;
  }

  const scan = { stream: null, raf: 0, canvas: document.createElement("canvas") };

  function decodeCanvas(jsQR, source, sw, sh) {
    // Downscale big frames; jsQR is happy at ~640px and much faster there.
    const scale = Math.min(1, 800 / Math.max(sw, sh));
    const w = Math.max(1, Math.round(sw * scale)), h = Math.max(1, Math.round(sh * scale));
    scan.canvas.width = w; scan.canvas.height = h;
    const ctx = scan.canvas.getContext("2d", { willReadFrequently: true });
    ctx.drawImage(source, 0, 0, w, h);
    const img = ctx.getImageData(0, 0, w, h);
    return jsQR(img.data, w, h, { inversionAttempts: "dontInvert" });
  }

  function handleDecoded(text) {
    const invite = inviteFrom(text);
    if (!invite) { setStatus("That code is not a PlanMeter pairing code.", true); return false; }
    stopScanner();
    pair(invite);
    return true;
  }

  async function startScanner() {
    setStatus("");
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      setStatus("This browser cannot use the camera here. Take a photo of the code instead.", true);
      return;
    }
    let jsQR;
    try { jsQR = await loadJsQR(); } catch (err) { setStatus(err.message, true); return; }
    try {
      scan.stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: "environment" }, width: { ideal: 1280 }, height: { ideal: 720 } }, audio: false });
    } catch (err) {
      const denied = err && (err.name === "NotAllowedError" || err.name === "SecurityError");
      setStatus(denied ? "Camera access was denied. Allow it for this site in Settings, or take a photo of the code." : "No camera available. Take a photo of the code or paste the link.", true);
      return;
    }
    const video = $("scan-video");
    video.srcObject = scan.stream;
    $("scanner").classList.remove("hidden");
    $("pair-options").classList.add("hidden");
    try { await video.play(); } catch (_) {}
    let lastMiss = 0;
    let lastFrame = 0;
    const tick = () => {
      if (!scan.stream) return;
      const now = Date.now();
      // Decoding every animation frame burns battery without improving scan
      // latency perceptibly on a phone.
      if (now - lastFrame >= 120 && video.readyState >= 2 && video.videoWidth) {
        lastFrame = now;
        try {
          const result = decodeCanvas(jsQR, video, video.videoWidth, video.videoHeight);
          if (result && result.data) {
            if (handleDecoded(result.data)) return;
            lastMiss = now;
          } else if (lastMiss && now - lastMiss > 2500) {
            setStatus(""); lastMiss = 0;
          }
        } catch (_) {
          setStatus("Could not read the camera frame. Try taking a photo of the code.", true);
          stopScanner();
          return;
        }
      }
      scan.raf = requestAnimationFrame(tick);
    };
    scan.raf = requestAnimationFrame(tick);
  }

  function stopScanner() {
    if (scan.raf) cancelAnimationFrame(scan.raf);
    scan.raf = 0;
    if (scan.stream) { for (const t of scan.stream.getTracks()) t.stop(); }
    scan.stream = null;
    const video = $("scan-video");
    if (video) video.srcObject = null;
    $("scanner").classList.add("hidden");
    $("pair-options").classList.remove("hidden");
  }

  async function decodePhoto(file) {
    if (!file) return;
    setStatus("Reading photo…");
    try {
      const jsQR = await loadJsQR();
      let bitmap;
      if (window.createImageBitmap) {
        bitmap = await createImageBitmap(file);
      } else {
        bitmap = await new Promise((resolve, reject) => { const i = new Image(); i.onload = () => resolve(i); i.onerror = reject; i.src = URL.createObjectURL(file); });
      }
      const w = bitmap.width || bitmap.naturalWidth, h = bitmap.height || bitmap.naturalHeight;
      // Try the natural orientation, then a smaller pass; photos are large.
      let result = decodeCanvas(jsQR, bitmap, w, h);
      if (!result) {
        scan.canvas.width = 0;
        const scaled = Math.min(1, 400 / Math.max(w, h));
        result = decodeCanvas(jsQR, bitmap, w * scaled, h * scaled);
      }
      if (bitmap.close) bitmap.close();
      if (!result || !result.data) { setStatus("Could not find a QR code in that photo. Try again closer and in focus.", true); return; }
      handleDecoded(result.data);
    } catch (err) {
      setStatus("Could not read that photo.", true);
    }
  }

  async function claimWebInvite(code) {
    const status = $("pairing-status");
    const input = $("pair-code");
    const button = $("pair-code-submit");
    const digits = code.replace(/\D/g, "");
    if (digits.length !== 8) {
      status.className = "status err";
      status.textContent = "Enter the eight-digit code shown on the Mac.";
      return;
    }
    input.disabled = true;
    button.disabled = true;
    status.className = "status";
    status.textContent = "Checking code…";
    try {
      const res = await fetch(PATH_WEB_INVITE, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code: digits }),
        cache: "no-store",
        credentials: "omit",
      });
      if (!res.ok) {
        let message = res.status === 403 ? "That code was not accepted. Check the Mac for a current code." : `Server returned HTTP ${res.status}.`;
        if (res.status !== 403) {
          try { message = (await res.json()).error || message; } catch (_) {}
        }
        throw new Error(message);
      }
      const offer = await res.json();
      const key = unb64(offer.serverPublicKey);
      if (key.byteLength !== 65 || !offer.token || !offer.expiresAt) throw new Error("The Mac returned an invalid pairing offer.");
      await pair({ serverPublicKey: key, token: offer.token, expiresAt: Number(offer.expiresAt) * 1000, serverName: offer.serverName || location.hostname });
    } catch (err) {
      status.className = "status err";
      status.textContent = err.message || String(err);
    } finally {
      input.disabled = false;
      button.disabled = false;
    }
  }

  // ---------- data ----------
  async function call(method, extra) {
    const reply = await exchange(PATH_RPC, Object.assign({ method }, extra || {}), unb64(state.server.serverPublicKey), state.server.deviceId, state.keyPair);
    if (reply.error) throw new Error(reply.error);
    return reply;
  }

  async function refresh() {
    if (!state.server || state.loading) return;
    state.loading = true;
    $("refresh").disabled = true;
    $("subtitle").textContent = "Refreshing…";
    try {
      const days = state.days;
      const [s, t, l, m] = await Promise.all([
        call("summary", { days }),
        call("timeline", { days, resolution: days === 1 ? "hour" : "day" }),
        call("limits"),
        call("models", { days }),
      ]);
      state.summary = s.summary; state.timeline = t.timeline; state.limits = l.limits; state.models = m.models || [];
      $("error").classList.add("hidden");
      render();
      $("subtitle").textContent = `${state.summary.serverName} · updated just now`;
    } catch (err) {
      $("error").textContent = err.message || String(err);
      $("error").classList.remove("hidden");
      $("subtitle").textContent = "Could not reach the Mac";
    } finally {
      state.loading = false;
      $("refresh").disabled = false;
    }
  }

  // ---------- rendering ----------
  function render() {
    const s = state.summary;
    const groups = $("groups");
    groups.replaceChildren();
    for (const g of s.groups) {
      const card = el("section", "card");
      const head = el("div", "group-head");
      const dot = el("span", "dot"); dot.style.background = groupColor(g.group);
      head.append(dot, el("span", "name", groupName(g.group)), el("span", "share", pct(s.total.costUsd > 0 ? g.totals.costUsd / s.total.costUsd : 0)));
      const big = el("div", "big");
      big.append(el("span", "cost", usd(g.totals.costUsd)), el("span", "tok", `${tokens(g.totals.tokens)} tokens`));
      const bar = el("div", "bar"); const fill = el("i"); fill.style.width = `${Math.min(100, s.total.costUsd > 0 ? (g.totals.costUsd / s.total.costUsd) * 100 : 0)}%`; fill.style.background = groupColor(g.group); bar.append(fill);
      const stats = el("div", "stats");
      for (const [label, value] of [["Sessions", String(g.totals.sessions)], ["Cache savings", usd(g.totals.cacheSavingsUsd)], ["Cached", pct(g.totals.inputTokens > 0 ? g.totals.cachedInputTokens / g.totals.inputTokens : 0)]]) {
        const d = el("div"); d.append(el("small", "", label), document.createTextNode(value)); stats.append(d);
      }
      card.append(head, big, bar, stats, el("div", "divider"));
      for (const row of g.accounts) {
        const a = el("div", "acct");
        const ad = el("span", "dot sm"); ad.style.background = accountColor(row.account.id);
        a.append(ad, el("span", "", row.account.name));
        if (row.account.plan) a.append(el("span", "plan", row.account.plan));
        a.append(el("span", "val" + (row.totals.tokens === 0 ? " zero" : ""), usd(row.totals.costUsd)));
        card.append(a);
      }
      groups.append(card);
    }
    renderChart();
    renderLimits();
    renderModels();
    $("foot").textContent = `From ${s.serverName} · data as of ${rel(s.generatedAt)} · API-equivalent token prices, not subscription charges.`;
  }

  function renderChart() {
    const t = state.timeline;
    const chart = $("chart"); const legend = $("legend");
    chart.replaceChildren(); legend.replaceChildren();
    if (!t || !t.points.length) { chart.append(el("p", "muted", "No usage in this range.")); return; }
    const periods = t.periods.map((p) => new Date(p).getTime());
    const byPeriod = new Map(periods.map((p) => [p, []]));
    for (const pt of t.points) {
      const k = new Date(pt.period).getTime();
      if (!byPeriod.has(k)) byPeriod.set(k, []);
      byPeriod.get(k).push(pt);
    }
    const keys = [...byPeriod.keys()].sort((a, b) => a - b);
    const totals = keys.map((k) => byPeriod.get(k).reduce((n, p) => n + p.costUsd, 0));
    // Round the axis top up to a 1/2/5 × 10^n step so tick labels read cleanly.
    const rawMax = Math.max(0.01, ...totals);
    const mag = Math.pow(10, Math.floor(Math.log10(rawMax)));
    const step = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => s * 4 >= rawMax) || 10 * mag;
    const max = step * 4;
    const W = 640, H = 220, padL = 44, padB = 22, padT = 8;
    const plotW = W - padL - 6, plotH = H - padB - padT;
    const svgNS = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(svgNS, "svg");
    svg.setAttribute("viewBox", `0 0 ${W} ${H}`); svg.setAttribute("preserveAspectRatio", "none");
    const mk = (tag, attrs) => { const n = document.createElementNS(svgNS, tag); for (const [k, v] of Object.entries(attrs)) n.setAttribute(k, v); return n; };
    // grid + y labels
    const ticks = 4;
    for (let i = 0; i <= ticks; i++) {
      const y = padT + plotH - (plotH * i) / ticks;
      svg.append(mk("line", { x1: padL, x2: W - 6, y1: y, y2: y, stroke: "currentColor", "stroke-opacity": "0.08" }));
      const label = mk("text", { x: padL - 6, y: y + 4, "text-anchor": "end", "font-size": "11", fill: "currentColor", "fill-opacity": "0.6" });
      label.textContent = usd((max * i) / ticks);
      svg.append(label);
    }
    const n = keys.length;
    const slot = plotW / n; const bw = Math.max(2, slot * 0.7);
    const order = t.accounts.map((a) => a.id);
    keys.forEach((k, i) => {
      let y = padT + plotH;
      const pts = byPeriod.get(k).slice().sort((a, b) => order.indexOf(a.accountId) - order.indexOf(b.accountId));
      for (const p of pts) {
        const h = (p.costUsd / max) * plotH;
        y -= h;
        svg.append(mk("rect", { x: padL + i * slot + (slot - bw) / 2, y, width: bw, height: Math.max(0, h), rx: 2, fill: accountColor(p.accountId) }));
      }
    });
    // x labels
    const every = Math.max(1, Math.ceil(n / 6));
    keys.forEach((k, i) => {
      if (i % every !== 0) return;
      const d = new Date(k);
      const label = mk("text", { x: padL + i * slot + slot / 2, y: H - 6, "text-anchor": "middle", "font-size": "11", fill: "currentColor", "fill-opacity": "0.6" });
      label.textContent = t.resolution === "hour" ? d.toLocaleTimeString([], { hour: "numeric" }) : d.toLocaleDateString([], { month: "short", day: "numeric" });
      svg.append(label);
    });
    chart.append(svg);
    for (const a of t.accounts) {
      const span = el("span"); const d = el("i", "dot sm"); d.style.background = accountColor(a.id); span.append(d, document.createTextNode(a.name)); legend.append(span);
    }
  }

  function renderLimits() {
    const card = $("limits-card"); card.replaceChildren();
    const l = state.limits;
    if (!l || !l.accounts.length) { card.classList.add("hidden"); return; }
    card.classList.remove("hidden");
    card.append(el("h2", "", "Codex limits"));
    for (const entry of l.accounts) {
      const box = el("div", "limit");
      const row = el("div", "row");
      const d = el("span", "dot sm"); d.style.background = groupColor(entry.account.group);
      row.append(d, el("strong", "", entry.account.name));
      if (entry.account.plan) row.append(el("span", "muted small", entry.account.plan));
      if (entry.asOf) row.append(el("span", "r", rel(entry.asOf)));
      box.append(row);
      for (const w of entry.windows) {
        const r = el("div", "row"); r.append(el("span", "small", w.label), el("span", "r", `${Math.round(w.usedPercent)}% · resets ${rel(w.resetsAt)}`));
        const bar = el("div", "bar"); const fill = el("i"); fill.style.width = `${Math.min(100, w.usedPercent)}%`; fill.style.background = w.usedPercent > 90 ? "var(--danger)" : w.usedPercent > 70 ? "var(--warn)" : "var(--accent)"; bar.append(fill);
        box.append(r, bar);
      }
      if (entry.note) box.append(el("div", "note", entry.note));
      card.append(box);
    }
    card.append(el("p", "muted small", l.note));
  }

  let showAllModels = false;
  function renderModels() {
    const card = $("models-card"); card.replaceChildren();
    const rows = state.models;
    if (!rows.length) { card.classList.add("hidden"); return; }
    card.classList.remove("hidden");
    const head = el("div", "head"); head.append(el("h2", "", "By model"));
    if (rows.length > 6) { const b = el("button", "", showAllModels ? "Show less" : `Show all ${rows.length}`); b.onclick = () => { showAllModels = !showAllModels; renderModels(); }; head.append(b); }
    card.append(head);
    for (const r of showAllModels ? rows : rows.slice(0, 6)) {
      const m = el("div", "model");
      const d = el("span", "dot sm"); d.style.background = groupColor(r.group);
      const mid = el("div", "m"); mid.append(el("div", "n", r.model), el("div", "a", r.accountName));
      const v = el("div", "v"); v.append(el("div", "c", r.priced ? usd(r.totals.costUsd) : "unpriced"), el("div", "t", tokens(r.totals.tokens)));
      m.append(d, mid, v); card.append(m);
    }
  }

  function renderSettings() {
    const kv = $("settings-kv"); kv.replaceChildren();
    const s = state.server;
    const add = (k, v, mono) => { kv.append(el("dt", "", k)); kv.append(el("dd", mono ? "mono" : "", v)); };
    add("Mac", s.serverName); add("Origin", s.origin); add("Paired", new Date(s.pairedAt).toLocaleString());
    add("Device id", s.deviceId, true);
    crypto.subtle.digest("SHA-256", unb64(s.serverPublicKey)).then((h) => add("Server key", b64url(h).slice(0, 16), true));
    add("Key storage", "Non-extractable WebCrypto key in IndexedDB (this browser only)");
  }

  function showDashboard() { $("pairing").classList.add("hidden"); $("settings-panel").classList.add("hidden"); $("dashboard").classList.remove("hidden"); }
  function showPairing(msg) { $("dashboard").classList.add("hidden"); $("settings-panel").classList.add("hidden"); $("pairing").classList.remove("hidden"); if (msg) setStatus(msg, true); }

  // ---------- wiring ----------
  $("refresh").onclick = () => refresh();
  $("pair-code-form").onsubmit = (event) => {
    event.preventDefault();
    claimWebInvite($("pair-code").value);
  };
  $("pair-code").oninput = (event) => {
    const digits = event.target.value.replace(/\D/g, "").slice(0, 8);
    event.target.value = digits.length > 4 ? `${digits.slice(0, 4)} ${digits.slice(4)}` : digits;
  };
  $("settings").onclick = () => { if (!state.server) return; renderSettings(); $("dashboard").classList.add("hidden"); $("settings-panel").classList.remove("hidden"); };
  $("close-settings").onclick = () => showDashboard();
  $("unpair").onclick = async () => {
    if (!confirm("Unpair this browser from the Mac? Revoke it on the Mac too to block the key for good.")) return;
    await kvDel("server");
    state.server = null; state.summary = null;
    showPairing("Unpaired. Scan a new pairing code to reconnect.");
  };
  for (const b of $("range").querySelectorAll("button")) {
    b.onclick = () => {
      for (const o of $("range").querySelectorAll("button")) { o.classList.remove("active"); o.removeAttribute("aria-selected"); }
      b.classList.add("active"); b.setAttribute("aria-selected", "true");
      state.days = Number(b.dataset.days);
      refresh();
    };
  }
  $("scan-start").onclick = () => startScanner();
  $("scan-stop").onclick = () => stopScanner();
  $("photo").onchange = (e) => { decodePhoto(e.target.files && e.target.files[0]); e.target.value = ""; };
  $("paste-pair").onclick = () => {
    const invite = inviteFrom($("paste-link").value);
    if (!invite) { setStatus("That does not look like a PlanMeter pairing link.", true); return; }
    $("paste-link").value = "";
    pair(invite);
  };
  $("paste-link").addEventListener("keydown", (e) => { if (e.key === "Enter") $("paste-pair").click(); });
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") stopScanner();
    else if (state.server) refresh();
  });

  (async function main() {
    if (!window.isSecureContext || !crypto.subtle) {
      showPairing("This page must be opened over HTTPS (Tailscale Serve) for the browser to do cryptography.");
      return;
    }
    const invite = parseInvite();
    const saved = await kvGet("server");
    if (invite) {
      showPairing();
      await pair(invite);
      return;
    }
    if (saved && saved.origin === location.origin) {
      state.server = saved;
      state.keyPair = await deviceKey();
      showDashboard();
      await refresh();
      state.timer = state.timer || setInterval(() => { if (document.visibilityState === "visible") refresh(); }, 60000);
    } else {
      showPairing();
    }
  })();
})();

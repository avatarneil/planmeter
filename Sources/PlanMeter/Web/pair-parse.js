// Parses a pairing code into { key, token, expiresAt, serverName, origin }.
// Accepts both QR payloads PlanMeter prints:
//   https://host/#k=…&t=…&e=…&n=…            (web)
//   planmeter://pair?h=…&p=…&k=…&t=…&e=…&n=…  (iOS app)
// Shared by the page and by the Node decode test, hence the UMD-ish tail.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.PlanMeterPair = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  function fromBase64Url(s) {
    let b = s.replace(/-/g, "+").replace(/_/g, "/");
    while (b.length % 4) b += "=";
    const bin = atob(b);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }

  function parse(text) {
    const trimmed = String(text || "").trim();
    if (!trimmed) return null;
    let params;
    let origin = null;
    if (/^planmeter:\/\/pair\?/i.test(trimmed)) {
      params = new URLSearchParams(trimmed.slice(trimmed.indexOf("?") + 1));
      const h = params.get("h");
      const p = params.get("p");
      if (h) origin = (p === "443" ? "https://" : "http://") + h + (p && p !== "443" && p !== "80" ? ":" + p : "");
    } else {
      let url;
      try { url = new URL(trimmed); } catch (e) { return null; }
      if (!url.hash || url.hash.length < 2) return null;
      params = new URLSearchParams(url.hash.slice(1));
      origin = url.origin;
    }
    const k = params.get("k");
    const t = params.get("t");
    const e = Number(params.get("e"));
    if (!k || !t || !Number.isFinite(e)) return null;
    let key;
    try { key = fromBase64Url(k); } catch (err) { return null; }
    if (key.length !== 65 || key[0] !== 4) return null;
    return {
      key,
      token: t,
      expiresAt: new Date(e * 1000),
      serverName: params.get("n") || "",
      origin,
    };
  }

  return { parse, fromBase64Url };
});

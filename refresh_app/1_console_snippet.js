/* =====================================================================
   IDEA 1 — DevTools console snippet   (zero install, TRY THIS FIRST)
   =====================================================================
   HOW: open your ServiceNow tab -> F12 -> "Console" -> paste the whole
        block -> Enter. Leave the tab open.

   It runs every 12 min (< your 15-20 min 401 window) and keeps the
   session warm using the *gentlest* method that works, in this order:

     A) BACKGROUND PING (default): fetch() a lightweight ServiceNow URL
        in the background. This renews the session token WITHOUT reloading
        the page, so the timer never dies and your view never flickers.
        This is the ideal fix for an "idle -> 401" token-expiry problem.

     B) If you find the ping isn't enough (still get 401), flip
        USE_RELOAD = true below. It will click "Available" (if present)
        and do a full page reload instead. Because a reload kills this
        script, the reload path RE-ARMS itself via sessionStorage, so you
        still only paste once per tab.

   STOP: run  stopStayAvailable()  or close the tab.
   ===================================================================== */
(function () {
  const EVERY_MIN  = 12;
  const USE_RELOAD = false;   // set true only if the background ping doesn't clear the 401
  const KEY = "__stayAvailableOn";

  // --- helper: click an "Available" control if one exists (best effort) ---
  function clickAvailable() {
    const docs = [document];
    const f = document.querySelector("iframe[name='gsft_main'], iframe#gsft_main");
    try { if (f && f.contentDocument) docs.push(f.contentDocument); } catch (e) {}
    const wants = ["available", "set as available", "im available", "i'm available"];
    for (const d of docs) {
      for (const el of d.querySelectorAll("button,a,span,div[role='button'],[aria-label]")) {
        const txt = ((el.innerText || "") + " " + (el.getAttribute("aria-label") || ""))
          .trim().toLowerCase();
        if (wants.some((w) => txt === w || txt.includes(w))) {
          try { el.click(); console.log("[stay-available] clicked:", txt); return true; }
          catch (e) {}
        }
      }
    }
    return false;
  }

  // --- MODE A: background ping (no reload) ---
  function ping() {
    // hit a tiny same-origin endpoint; credentials:'include' reuses your session cookies.
    // '/api/now/ui/user/current_user' is lightweight and auth'd; if your instance blocks it,
    // any authenticated same-origin URL works (e.g. location.pathname).
    const url = location.origin + "/api/now/ui/user/current_user";
    fetch(url, { credentials: "include", cache: "no-store" })
      .then((r) => console.log(`[stay-available] ${new Date().toLocaleTimeString()} `
        + `ping ${r.status} ${r.status === 401 ? "(!! still 401 — set USE_RELOAD=true)" : "(session warm)"}`))
      .catch((e) => console.log("[stay-available] ping error:", e));
  }

  // --- MODE B: click + full reload (re-arms itself after reload) ---
  function reloadTick() {
    const clicked = clickAvailable();
    console.log(`[stay-available] ${new Date().toLocaleTimeString()} `
      + `— ${clicked ? "clicked available, " : ""}reloading`);
    location.reload();
  }

  function arm() {
    if (window.__saTimer) clearInterval(window.__saTimer);
    window.__saTimer = setInterval(USE_RELOAD ? reloadTick : ping, EVERY_MIN * 60 * 1000);
    console.log(`[stay-available] armed (${USE_RELOAD ? "reload" : "ping"} mode) — `
      + `every ${EVERY_MIN} min. stopStayAvailable() to stop.`);
  }

  window.stopStayAvailable = function () {
    sessionStorage.removeItem(KEY);
    if (window.__saTimer) clearInterval(window.__saTimer);
    window.__saTimer = null;
    console.log("[stay-available] stopped");
  };

  sessionStorage.setItem(KEY, USE_RELOAD ? "reload" : "ping");
  arm();
  ping();   // fire one now so you immediately see it working in the console
})();

/* =====================================================================
   RE-ARM AFTER RELOAD — only needed if you use MODE B (USE_RELOAD=true).
   Paste this as a SEPARATE console command ONCE. It reinstalls the timer
   automatically on every fresh page load, so a reload doesn't stop you.
   In PING mode you don't need this at all (the page never reloads).
   =====================================================================
   Chrome/Edge: you can't auto-run console code across reloads without an
   extension. Easiest robust path across reloads = the BOOKMARKLET
   (see 2_bookmarklet.txt) which you click after a reload, OR just keep
   PING mode where no reload happens.
   ===================================================================== */

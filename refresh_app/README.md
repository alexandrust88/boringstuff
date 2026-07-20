# keep servicenow "available" — all ideas, test in this order

**your actual symptom:** if the tab sits idle ~15-20 min you get a **401**; a plain **page
refresh** fixes it and you do **not** have to log in again. so this is a *token going stale on
idle*, not a logout. the fix is simply: touch the session every ~12 min. entra/mfa never enters
the picture, which is why the lightest options need no code and no install.

everything here targets a **12-minute** interval (safely under your 15-20 min window).

## what's in this folder
| file | idea | needs |
|---|---|---|
| `1_console_snippet.js` | **1** paste-in-console keep-warm (ping, or reload) | DevTools console access |
| `2_bookmarklet.txt` | **2** one-click bookmarklet (ping, or reload) | ability to add a bookmark |
| `3_extension_and_metarefresh.md` | **3** auto-reload browser extension (GUI) | extension install rights |
| `4_USING_YOUR_CONTEXT.md` | **4** how the Python route reuses YOUR Entra login | read this before 4a/4b |
| `4b_attach_to_my_chrome.py` | **4A** attach to your ALREADY-OPEN Chrome over CDP | python + a Chrome debug port |
| `stay_available.py` + `RUNBOOK.md` | **4B/C** Playwright w/ profile or system-browser reuse | python install (offline ok) |

> **"use my current context":** ideas 1/2/3 already run *inside* your open, logged-in tab — that
> IS your current context, nothing to configure. for the Python route, `4b_attach_to_my_chrome.py`
> connects to your live Chrome window (zero login); see `4_USING_YOUR_CONTEXT.md` for all flavors.

## test order on the airgapped PC (walk down until one sticks)

1. **Idea 1 — console snippet (start here, costs nothing).**
   Open the ServiceNow tab -> F12 -> Console -> paste `1_console_snippet.js` -> Enter.
   It defaults to **ping mode**: a background fetch every 12 min that renews the token with
   **no reload** (no flicker, timer never dies). Watch the console — each tick prints
   `ping 200 (session warm)`. Leave it ~20 min idle otherwise and confirm no 401.
   - If you still see `ping 401` -> set `USE_RELOAD = true` at the top and re-paste; now it
     clicks "Available" (if present) and reloads instead.

2. **Idea 2 — bookmarklet** if you can't keep the console open but can add a bookmark.
   Bookmarklet **A** (ping) is the direct equivalent of idea 1 ping mode, one click to toggle.

3. **Idea 3 — auto-reload extension** if extensions are allowed and a plain reload keeps you
   available. Set interval = 12 min on the tab. Most "click and forget" option.

4. **Idea 4 — Playwright** only if you need it running with **no browser tab open**, or you must
   **reload AND re-click "Available"** unattended (a plain extension can't re-click). Heaviest:
   needs offline python + chromium install. Full steps in `RUNBOOK.md`; you record your exact
   "available" click once with `playwright codegen`.

## which mode: ping vs reload?
- **ping (no reload)** is best if the 401 is purely a *token/session-cookie* timeout — the
  background request renews it and your page never moves. try this first.
- **reload** is needed if the app only re-issues the token on a full page load, or if your
  "available" status resets and must be re-clicked. it's more disruptive (brief flicker) and,
  in a browser, a reload stops console/bookmarklet timers — which is exactly where the
  extension (idea 3) or Playwright (idea 4) earn their keep, since they survive reloads.

## gotchas to expect
- **ServiceNow iframe:** classic UI runs the app inside `iframe[name="gsft_main"]`; the click
  helpers already reach into it. newer workspace UI has no gsft_main and just needs the refresh.
- **CSP:** the ping uses `fetch()`, which runs under ServiceNow's Content-Security-Policy. if the
  console shows a CSP/blocked error, switch that option to reload mode, or use idea 3/4.
- **the ping endpoint** `/api/now/ui/user/current_user` is a light authenticated URL; if your
  instance 404s it, change it in the snippet to any authenticated same-origin path (even
  `location.pathname`) — the point is just an authenticated same-origin request on a timer.
- **verify "available" actually persists.** you weren't sure whether you must re-click available
  after the refresh. watch it across one real cycle: if your status flips to away on reload,
  you need the reload+click path (idea 1 `USE_RELOAD=true`, or idea 4).

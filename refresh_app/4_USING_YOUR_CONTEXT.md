# idea 4 — "use my current context" (reuse your Entra-logged-in session)

the browser ideas (1 console, 2 bookmarklet, 3 extension) ALREADY use your current context —
they run inside your open, logged-in tab. this doc is only about the **Python (Playwright)**
route, which by default launched a fresh, logged-out browser. here are the three ways to make
it reuse YOUR real session so it never logs in. put all in place, test on the box, keep what works.

files:
- `4b_attach_to_my_chrome.py` — flavor A (attach over CDP)  ← the true "current context"
- `stay_available.py`         — flavors B/C (profile reuse + system browser) via config at top
- `RUNBOOK.md`                — offline install of Playwright

---

## flavor A — ATTACH to your already-open Chrome  (recommended)  → `4b_attach_to_my_chrome.py`
connects Playwright to the exact Chrome/Edge window you already have open and logged in, over
the DevTools (CDP) port. it drives your live tab. **no login ever**, because it IS your session.

- one-time: close all Chrome, relaunch with `--remote-debugging-port=9222 --user-data-dir=<a dir>`,
  log into ServiceNow once in that window. then run the script; it finds your ServiceNow tab.
- pro: genuinely your context — same cookies, same conditional-access trust, same tab you watch.
- con: you must start Chrome with the debug flag (one desktop shortcut solves this forever).
- full instructions are in the header of `4b_attach_to_my_chrome.py`.

## flavor B — reuse your Chrome PROFILE on disk  → `stay_available.py` (PROFILE_DIR)
point `PROFILE_DIR` at a **copy of your real Chrome/Edge profile dir** (the one holding your
Entra cookies). the script launches a browser on that profile, already logged in.

- set `PROFILE_DIR` to the copied profile path; optionally `CHANNEL="msedge"`/"chrome".
- pro: no debug port; already authenticated on first run.
- con: **the browser must be CLOSED** — a profile can't be open in two browsers at once. copy the
  profile to a dedicated dir so you're not fighting your daily browser. entra may re-verify the
  new "browser instance" the first time.

## flavor C — system Edge/Chrome + fresh login once  → `stay_available.py` (CHANNEL)
if you can't/don't want to reuse a profile, set `CHANNEL="msedge"` (or "chrome") and leave
`PROFILE_DIR` as the default fresh dir. it drives your INSTALLED Edge/Chrome (no chromium
download needed — nice on airgap) but you log in once; the session then persists in that dir.

- pro: no offline chromium bundle to carry; no debug flag.
- con: one manual login the very first run (persisted afterward).

---

## how to choose
| you want | use |
|---|---|
| drive the exact tab i'm watching, zero login | **A** — `4b_attach_to_my_chrome.py` |
| no debug flag, reuse existing login, ok to close my browser | **B** — profile copy |
| no chromium download, one login is fine | **C** — `CHANNEL="msedge"` |
| no python at all, just keep my open tab warm | ideas **1/2/3** (already your context) |

## keep in mind (all flavors)
- MODE: `ping` (background fetch, no reload — gentlest) vs `reload` (+ re-click "Available").
  start with ping; switch to reload if you still see 401 or your status resets on refresh.
- ServiceNow app lives in `iframe[name="gsft_main"]` on classic UI — the click helpers handle it.
- CSP may block the ping fetch; if the log shows a CSP error, use reload mode.
- flavor A never closes your browser (it's yours); B/C own the browser they launch.

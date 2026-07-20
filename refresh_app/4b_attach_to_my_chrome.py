#!/usr/bin/env python3
"""
4b_attach_to_my_chrome.py — reuse YOUR ALREADY-OPEN, ENTRA-LOGGED-IN Chrome.

This is the "use my current context" version of idea 4. Instead of launching a
fresh (empty, logged-out) browser, it CONNECTS OVER CDP to the Chrome/Edge you
already have running and logged in. It drives your real tab, so there is NEVER a
login step — the whole point.

HOW IT WORKS
------------
Chrome exposes a DevTools (CDP) endpoint when started with a remote-debugging
port. Playwright connects to that endpoint and adopts the live browser + its
tabs, cookies, and Entra session. Your window stays yours; the script just pokes
it every ~12 min to clear the idle 401.

ONE-TIME: start Chrome/Edge with a debugging port
-------------------------------------------------
Close ALL Chrome windows first (a port only opens on a fresh launch), then start it
with the flag. Use a real profile dir so your Entra login is present.

  Windows (Edge):
    "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe" ^
      --remote-debugging-port=9222 --user-data-dir="%LOCALAPPDATA%\\Edge-debug"

  Windows (Chrome):
    "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe" ^
      --remote-debugging-port=9222 --user-data-dir="%LOCALAPPDATA%\\Chrome-debug"

  macOS (Chrome):
    /Applications/Google\\ Chrome.app/Contents/MacOS/Google\\ Chrome \\
      --remote-debugging-port=9222 --user-data-dir="$HOME/chrome-debug"

  Linux:
    google-chrome --remote-debugging-port=9222 --user-data-dir="$HOME/chrome-debug"

Then in THAT window: open ServiceNow and log in through Entra once (this seeds the
debug profile with your session). Leave the window open. Now run this script.

  Note: --user-data-dir must be a dir that CAN hold your login. The very first time,
  you log in once in that debug window; after that the cookies persist there and you
  won't log in again. If your org lets you point --user-data-dir at your NORMAL Chrome
  profile you skip even that first login — but Chrome refuses a debug port on a profile
  that's already open elsewhere, so a dedicated debug profile is the reliable path.

WHY CDP AND NOT A FRESH BROWSER: your Entra/MFA session lives in a real browser
profile. Attaching adopts it as-is; conditional-access sees the same real browser
it already trusts. A fresh Playwright browser looks brand-new and would re-prompt.
"""

import sys
import time
import logging
import datetime
from pathlib import Path

from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout

# ----------------------------------------------------------------------------- CONFIG
CDP_URL       = "http://localhost:9222"   # matches --remote-debugging-port above
SERVICENOW_HINT = "service-now.com"       # substring used to find your ServiceNow tab
INTERVAL_MIN  = 12                        # < your 15-20 min idle-401 window

# What to do each cycle:
#   "ping"   -> a background request that renews the token, NO reload (gentlest)
#   "reload" -> click "Available" (if present) + full page reload
MODE = "ping"

# For ping mode: a light authenticated same-origin URL. Change if your instance 404s it.
PING_PATH = "/api/now/ui/user/current_user"

BASE_DIR = Path(__file__).resolve().parent
SHOT_DIR = BASE_DIR / "shots"
LOG_FILE = BASE_DIR / "attach.log"
# -----------------------------------------------------------------------------------

SHOT_DIR.mkdir(exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s %(message)s",
    handlers=[logging.FileHandler(LOG_FILE, encoding="utf-8"), logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("attach")


def ts() -> str:
    return datetime.datetime.now().strftime("%Y%m%d-%H%M%S")


def find_sn_page(browser):
    """Locate your already-open ServiceNow tab across the live browser's contexts."""
    for ctx in browser.contexts:
        for page in ctx.pages:
            if SERVICENOW_HINT in (page.url or "").lower():
                return page
    return None


def shot(page, tag: str) -> None:
    try:
        p = SHOT_DIR / f"{ts()}_{tag}.png"
        page.screenshot(path=str(p))
        log.info("screenshot -> %s", p.name)
    except Exception as e:  # noqa: BLE001
        log.warning("screenshot failed (%s): %s", tag, e)


def click_available(page) -> bool:
    """Best-effort click of an 'Available' control, reaching into the gsft_main iframe."""
    js = """() => {
      const wants = ['available','set as available',"i'm available","im available"];
      const docs = [document];
      const f = document.querySelector("iframe[name='gsft_main'], iframe#gsft_main");
      try { if (f && f.contentDocument) docs.push(f.contentDocument); } catch(e){}
      for (const d of docs) {
        for (const el of d.querySelectorAll("button,a,span,div[role='button'],[aria-label]")) {
          const t = ((el.innerText||'')+' '+(el.getAttribute('aria-label')||'')).trim().toLowerCase();
          if (wants.some(w => t===w || t.includes(w))) { el.click(); return t; }
        }
      }
      return null;
    }"""
    try:
        hit = page.evaluate(js)
        if hit:
            log.info("clicked available: %s", hit)
            return True
    except Exception as e:  # noqa: BLE001
        log.warning("click_available failed: %s", e)
    return False


def ping(page) -> None:
    """Renew the token via a background fetch in the page's own context (no reload)."""
    js = """async (path) => {
      try {
        const r = await fetch(location.origin + path, {credentials:'include', cache:'no-store'});
        return r.status;
      } catch (e) { return 'error:' + e; }
    }"""
    try:
        status = page.evaluate(js, PING_PATH)
        warm = " (session warm)" if status == 200 else " (!! non-200 — try MODE='reload')"
        log.info("ping %s%s", status, warm if isinstance(status, int) else "")
    except Exception as e:  # noqa: BLE001
        log.warning("ping failed: %s", e)


def cycle(page) -> None:
    if MODE == "reload":
        click_available(page)
        log.info("reloading to clear idle 401")
        page.reload(wait_until="domcontentloaded", timeout=60_000)
    else:
        ping(page)
    shot(page, MODE)


def main() -> None:
    log.info("connecting to your Chrome at %s (mode=%s, every %dmin)", CDP_URL, MODE, INTERVAL_MIN)
    with sync_playwright() as pw:
        try:
            browser = pw.chromium.connect_over_cdp(CDP_URL)
        except Exception as e:  # noqa: BLE001
            log.error("could not attach to Chrome at %s: %s", CDP_URL, e)
            log.error("did you start Chrome/Edge with --remote-debugging-port=9222 ? see the header.")
            sys.exit(1)

        page = find_sn_page(browser)
        if not page:
            log.error("no open tab matching '%s' — open ServiceNow in that Chrome window first.",
                      SERVICENOW_HINT)
            sys.exit(1)
        log.info("attached to tab: %s", page.url)

        try:
            while True:
                try:
                    cycle(page)
                except PWTimeout as e:
                    log.warning("cycle timed out: %s", e)
                except Exception as e:  # noqa: BLE001 - keep the daemon alive
                    log.exception("cycle failed, retrying next interval: %s", e)
                    # the tab may have been closed/navigated; try to re-find it
                    page = find_sn_page(browser) or page
                nxt = datetime.datetime.now() + datetime.timedelta(minutes=INTERVAL_MIN)
                log.info("sleeping %d min (next ~%s)", INTERVAL_MIN, nxt.strftime("%H:%M:%S"))
                time.sleep(INTERVAL_MIN * 60)
        except KeyboardInterrupt:
            log.info("stopped by user (Ctrl-C)")
        # NB: we do NOT close the browser — it's YOUR window, leave it running.


if __name__ == "__main__":
    main()

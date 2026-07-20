#!/usr/bin/env python3
"""
stay_available.py — keep a ServiceNow session warm without ever handling credentials.

USE THIS ONLY IF the browser-side options (console snippet / bookmarklet / auto-reload
extension) don't work for you, OR you need this running with NO browser tab open at all.
For the actual symptom (idle -> 401 after 15-20 min, a plain refresh fixes it, no re-login),
the console snippet or bookmarklet is lighter and needs no install. See README.md.

WHY THIS DESIGN
---------------
- Entra (Azure AD) auth is OAuth/SAML with MFA + conditional access. You do NOT script that.
  Instead we launch a *persistent* Chromium profile: you log in ONCE by hand, the session
  cookies live in the profile dir, and every later run silently reuses them. Your real
  symptom isn't a logout at all — it's an idle *token* expiry that a reload clears — so most
  cycles need zero interaction; the manual-login handler below is just a safety net.
- The box is airgapped and you can't attach a debugger. So this script is built to leave a
  visual + textual trail: it runs HEADED by default, screenshots before/after every cycle,
  and logs everything to a file. When it misbehaves, you read the log + look at the PNGs.

WHAT IT DOES EACH CYCLE
-----------------------
1. Open your ServiceNow URL in the persistent profile.
2. If you're not logged in yet (login/Entra page detected) -> pause and let you log in by hand.
3. Perform the "make me available" action. You have two ways to define that action:
     (a) RECORD it once with Playwright codegen and paste the clicks into do_available() below
         (RECOMMENDED — you don't need to know selectors in advance), OR
     (b) leave do_available() as-is and rely on KEEP_ALIVE (a click + reload) which resets
         most inactivity timers.
4. Screenshot, sleep ~25 min (under your 30-min window), repeat.

FIRST-TIME SETUP AND OFFLINE INSTALL: see RUNBOOK.md next to this file.
"""

import sys
import time
import logging
import datetime
from pathlib import Path

from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout

# ----------------------------------------------------------------------------- CONFIG
# EDIT THESE for your environment.
SERVICENOW_URL = "https://YOUR-INSTANCE.service-now.com/now/nav/ui"  # <-- your landing/module URL
INTERVAL_MIN   = 12                                                  # < your 15-20 min idle-401 window

# --- WHICH BROWSER CONTEXT TO USE ("use my current context") ---------------------
# To reuse YOUR existing Entra login instead of logging in fresh, you have options:
#
#   * BEST for "use my current context": don't use THIS script — use 4b_attach_to_my_chrome.py,
#     which connects to your ALREADY-OPEN Chrome over CDP. That's the true "current context".
#
#   * With THIS script you reuse your login by pointing PROFILE_DIR at a real browser profile
#     that holds your Entra cookies, and (optionally) driving your system Chrome/Edge via CHANNEL.
#     Chrome/Edge must be CLOSED when this runs — a profile can't be open in two browsers at once.
#     Point it at a DEDICATED copy of your profile (safest) rather than your daily one.
#
# PROFILE_DIR: the user-data-dir the browser uses. Options:
#   - a fresh dir (default below): you log in ONCE, it persists here for all later runs.
#   - a copy of your real Chrome profile dir: already logged in, no first-time login needed.
PROFILE_DIR = Path.home() / ".servicenow_available_profile"

# CHANNEL: which browser binary to drive.
#   None      -> Playwright's bundled Chromium (needs the offline chromium bundle; see RUNBOOK)
#   "msedge"  -> your installed Microsoft Edge (no chromium download needed) — often best on airgap
#   "chrome"  -> your installed Google Chrome
CHANNEL = None

# Run with a visible window (True) so you can log in and watch it. Headless is harder to debug
# and more likely to trip conditional-access "is this a real browser" checks. Keep True.
HEADED = True

# If True and do_available() finds no recorded action, we fall back to a generic keep-alive:
# a top-of-page click + reload, which resets inactivity-based session timers.
KEEP_ALIVE_FALLBACK = True

# Where screenshots + log go. Kept next to the script.
BASE_DIR   = Path(__file__).resolve().parent
SHOT_DIR   = BASE_DIR / "shots"
LOG_FILE   = BASE_DIR / "stay_available.log"
# -----------------------------------------------------------------------------------

SHOT_DIR.mkdir(exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s %(message)s",
    handlers=[logging.FileHandler(LOG_FILE, encoding="utf-8"),
              logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("stay-available")


def ts() -> str:
    return datetime.datetime.now().strftime("%Y%m%d-%H%M%S")


def shot(page, tag: str) -> None:
    """Screenshot the page; never let a screenshot failure kill the loop."""
    try:
        p = SHOT_DIR / f"{ts()}_{tag}.png"
        page.screenshot(path=str(p), full_page=False)
        log.info("screenshot -> %s", p.name)
    except Exception as e:  # noqa: BLE001 - screenshots are best-effort
        log.warning("screenshot failed (%s): %s", tag, e)


def looks_like_login(page) -> bool:
    """Heuristic: are we sitting on a Microsoft/Entra or ServiceNow login page?"""
    url = (page.url or "").lower()
    if any(s in url for s in ("login.microsoftonline.com", "/login.do", "sso", "saml", "adfs")):
        return True
    try:
        body = (page.inner_text("body", timeout=3000) or "").lower()
    except PWTimeout:
        return False
    return any(s in body for s in ("sign in", "password", "keep me signed in", "pick an account"))


def wait_for_manual_login(page) -> None:
    """Block until the human finishes Entra login and we're back on ServiceNow."""
    log.warning("LOGIN REQUIRED — a login page is showing. Complete Entra/MFA in the window.")
    log.warning("Waiting up to 10 minutes for you to finish...")
    shot(page, "login_prompt")
    deadline = time.time() + 600
    while time.time() < deadline:
        time.sleep(5)
        if not looks_like_login(page):
            log.info("login looks complete — continuing")
            shot(page, "login_done")
            return
    raise RuntimeError("timed out waiting for manual login")


def do_available(page) -> bool:
    """
    Perform the 'make me available' action.

    >>> HOW TO FILL THIS IN <<<
    On the airgapped PC run:  playwright codegen "<your ServiceNow URL>"
    Click through your normal 'set available' steps. Copy the generated page.* lines
    and paste them here, REPLACING the 'raise NotImplementedError' block below.

    ServiceNow often renders inside an iframe (gsft_main). If codegen wraps your clicks in
    a frame_locator(...), keep that — it matters. Example of what recorded code looks like:

        frame = page.frame_locator("iframe[name='gsft_main']")
        frame.get_by_role("button", name="Available").click()

    Return True if you performed a real action, False to fall through to keep-alive.
    """
    # ----- PASTE RECORDED CLICKS BELOW THIS LINE -----
    raise NotImplementedError  # remove this line once you've pasted your recorded action
    # ----- PASTE RECORDED CLICKS ABOVE THIS LINE -----


def keep_alive(page) -> None:
    """Generic fallback: reset inactivity timers with a click + reload."""
    log.info("keep-alive: click + reload")
    try:
        page.mouse.move(5, 5)
        page.mouse.click(5, 5)
    except Exception:  # noqa: BLE001
        pass
    page.reload(wait_until="domcontentloaded")


def one_cycle(page) -> None:
    log.info("cycle: navigating to %s", SERVICENOW_URL)
    page.goto(SERVICENOW_URL, wait_until="domcontentloaded", timeout=60_000)

    if looks_like_login(page):
        wait_for_manual_login(page)
        page.goto(SERVICENOW_URL, wait_until="domcontentloaded", timeout=60_000)

    shot(page, "before")
    did_action = False
    try:
        did_action = do_available(page)
    except NotImplementedError:
        log.info("do_available() not filled in yet — using keep-alive fallback")
    except Exception as e:  # noqa: BLE001 - one bad cycle shouldn't kill the loop
        log.error("do_available() raised: %s", e)
        shot(page, "action_error")

    if not did_action and KEEP_ALIVE_FALLBACK:
        keep_alive(page)

    shot(page, "after")
    log.info("cycle complete")


def main() -> None:
    log.info("starting; profile=%s channel=%s interval=%dmin headed=%s",
             PROFILE_DIR, CHANNEL, INTERVAL_MIN, HEADED)
    with sync_playwright() as pw:
        launch_kwargs = dict(
            user_data_dir=str(PROFILE_DIR),
            headless=not HEADED,
            viewport={"width": 1400, "height": 900},
            args=["--start-maximized"],
        )
        if CHANNEL:  # drive installed Edge/Chrome instead of the bundled Chromium
            launch_kwargs["channel"] = CHANNEL
        ctx = pw.chromium.launch_persistent_context(**launch_kwargs)
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        try:
            while True:
                try:
                    one_cycle(page)
                except Exception as e:  # noqa: BLE001 - keep the daemon alive across errors
                    log.exception("cycle failed, will retry next interval: %s", e)
                    try:
                        shot(page, "cycle_error")
                    except Exception:  # noqa: BLE001
                        pass
                nxt = datetime.datetime.now() + datetime.timedelta(minutes=INTERVAL_MIN)
                log.info("sleeping %d min (next ~%s)", INTERVAL_MIN, nxt.strftime("%H:%M:%S"))
                time.sleep(INTERVAL_MIN * 60)
        except KeyboardInterrupt:
            log.info("stopped by user (Ctrl-C)")
        finally:
            ctx.close()


if __name__ == "__main__":
    main()

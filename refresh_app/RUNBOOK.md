# stay-available runbook

keep a servicenow session "available" every ~25 min, without ever scripting entra/mfa.
you log in by hand once; a persistent browser profile reuses that session forever after.

files in this folder:
- `stay_available.py` — the loop (headed, screenshots every cycle, logs to `stay_available.log`)
- `RUNBOOK.md` — this file

---

## part a — prep on an INTERNET-CONNECTED machine (same OS/arch as the airgapped PC)

the airgapped box can't download anything, so we fetch everything here and carry it in.
**the connected machine must match the airgapped one**: same OS (windows/linux) and same
python major.minor (e.g. both 3.11). check the airgapped python version first: `python --version`.

```bash
# 1. make a folder to carry across
mkdir sn-transfer && cd sn-transfer

# 2. download the python wheels (no install, just download)
pip download playwright -d ./wheels

# 3. get playwright's chromium browser bundle offline.
#    install playwright locally just to run its downloader, pointed at a folder we keep:
python -m venv .prep && . .prep/bin/activate      # windows: .prep\Scripts\activate
pip install ./wheels/playwright*.whl
set PLAYWRIGHT_BROWSERS_PATH=./ms-playwright        # windows (cmd)
# export PLAYWRIGHT_BROWSERS_PATH=./ms-playwright   # linux/mac
python -m playwright install chromium
deactivate
```

now `sn-transfer/` contains `wheels/` (the pip packages) and `ms-playwright/` (chromium).
copy the whole `sn-transfer/` folder PLUS `stay_available.py` + `RUNBOOK.md` to the airgapped PC
(usb / approved transfer channel).

> alternative if pulling chromium offline is a hassle: playwright can drive the **system
> Chrome/Edge** already on the box. install just the python package, then in
> `launch_persistent_context(...)` add `channel="msedge"` (or `channel="chrome"`) and skip the
> `ms-playwright` bundle entirely. try this first if step 3 fights you.

---

## part b — install on the AIRGAPPED PC (offline)

```bash
cd sn-transfer

# 1. install the python package from the carried wheels, no internet
python -m venv .venv && . .venv/bin/activate       # windows: .venv\Scripts\activate
pip install --no-index --find-links ./wheels playwright

# 2. point playwright at the carried chromium bundle (set this in EVERY shell that runs the script)
set PLAYWRIGHT_BROWSERS_PATH=%CD%\ms-playwright      # windows (cmd)
# export PLAYWRIGHT_BROWSERS_PATH="$PWD/ms-playwright"  # linux/mac

# (if you went the system-Chrome/Edge route instead, skip step 2 and use channel="msedge")
```

---

## part c — record YOUR "make me available" action (do this once, on the airgapped PC)

you told me you're not 100% sure what the exact action is. that's fine — record it:

```bash
python -m playwright codegen "https://YOUR-INSTANCE.service-now.com/now/nav/ui"
```

a browser + an inspector window open. **log in through entra** (this also seeds the profile
you'll reuse — see note below). then click through exactly what you do to become available.
the inspector writes python as you click, e.g.:

```python
frame = page.frame_locator("iframe[name='gsft_main']")
frame.get_by_role("button", name="Available").click()
```

copy those `page.*` / `frame.*` lines into `do_available()` in `stay_available.py`, between the
PASTE markers, and delete the `raise NotImplementedError` line. `return True` at the end.

> servicenow usually renders inside an iframe named `gsft_main`. if codegen produced
> `frame_locator("iframe[name='gsft_main']")`, KEEP it — clicks won't find the button otherwise.

if after recording you find there's no real "available" button and it's just a session timeout,
leave `do_available()` untouched — the built-in keep-alive (click + reload) handles that.

---

## part d — configure + first run

1. edit the top of `stay_available.py`:
   - `SERVICENOW_URL` = your landing/module url
   - `INTERVAL_MIN` = 25 (leave it; must stay under 30)
2. first run (you'll log in by hand, once):
   ```bash
   python stay_available.py
   ```
   - a window opens. if it shows a login/entra page, the script pauses and prints
     "LOGIN REQUIRED" — complete entra + mfa in that window. it auto-continues.
   - the session now lives in `~/.servicenow_available_profile`. later runs reuse it silently.
3. leave it running. every ~25 min it navigates, does the action, screenshots into `shots/`,
   and logs to `stay_available.log`.

---

## part e — debugging without a debugger (your main worry)

everything is designed to leave a trail:
- **`shots/`** — `*_before.png` / `*_after.png` each cycle, plus `*_error.png` on any failure,
  and `login_prompt.png` if it wanted you to log in. flip through these to SEE what it saw.
- **`stay_available.log`** — timestamped line per action, full stack traces on errors.
- one bad cycle never kills the loop; it logs, screenshots, and retries next interval.

common issues:
| symptom | cause | fix |
|---|---|---|
| keeps asking to log in every cycle | entra cookie short-lived / conditional access re-prompts | expected occasionally; if constant, the org forces frequent re-auth — nothing to script around, just re-login when prompted |
| "LOGIN REQUIRED" loops forever | `looks_like_login` misfires on your instance | look at `login_*.png`; adjust the url/text checks in `looks_like_login()` |
| button click does nothing | action is inside the `gsft_main` iframe | re-record with codegen; keep the `frame_locator(...)` wrapper |
| chromium won't launch | `PLAYWRIGHT_BROWSERS_PATH` not set this shell | re-export it, or switch to `channel="msedge"` |

---

## part f — run it unattended (optional)

- **windows:** task scheduler -> "at log on" -> start `python stay_available.py` (set the
  working dir to this folder and the `PLAYWRIGHT_BROWSERS_PATH` env var in the action).
  the script already loops internally, so one launch is enough.
- **linux:** a `@reboot` cron or a small systemd user unit that runs the script; it self-loops.

keep it HEADED so entra re-auth prompts are clickable when they occasionally appear. a fully
headless unattended setup will eventually get stuck on a login it can't complete.

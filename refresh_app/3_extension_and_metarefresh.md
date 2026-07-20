# Idea 3 — browser auto-reload (GUI, no code)

If your org allows browser extensions or you're OK with a periodic full reload,
this is the most "click and forget" option. A reload is exactly what clears your
idle 401, so a dumb timed reload works.

## 3a. Auto-reload extension (easiest if extensions are allowed)
Install any reputable "tab auto reload / auto refresh" extension for your browser:
- Edge/Chrome: search the store for "Auto Refresh Plus" / "Tab Auto Refresh" /
  "Easy Auto Refresh". Pick one with lots of installs + reviews.
- Set the interval to **12 minutes** on the ServiceNow tab. Done.

Pros: survives reloads natively (that's its whole job), GUI timer, no code.
Cons: needs extension install rights; a full reload each cycle (brief flicker);
      if you must re-click "Available" after reload, an extension alone won't do
      that — combine with the console/bookmarklet click, or use Playwright.

## 3b. Native "auto refresh" via a second helper tab (no extension)
Some corp browsers block extensions but allow the DevTools console. In that case
idea 1 (ping mode) is your no-extension answer — it doesn't even reload.

## 3c. Why not an HTML meta-refresh?
`<meta http-equiv="refresh" content="720">` only works on a page you control.
You can't inject it into ServiceNow's own pages, so it's not usable here. Skip it.

---

## Which to reach for
- Extensions allowed + a plain reload keeps you available  -> **3a**, simplest.
- Extensions blocked but console works                     -> **idea 1 ping mode**.
- Must re-click "Available" after each reload, unattended  -> **idea 4 (Playwright)**.

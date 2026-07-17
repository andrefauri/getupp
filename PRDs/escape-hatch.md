# Escape Hatch — Spec (Emergency Break + Pull the Plug)

**Tier:** Production-tier (same tier as blocking module and Timeout — state logic and Family Controls behavior survive into production)
**Depends on:** Timeout (implemented), Streak (implemented), Family Controls blocking module

---

## ⚠️ First task for Claude Code: assess existing Emergency Break code

Emergency Break was partially anticipated in earlier work. Before writing anything, audit and report what already exists:

1. **Timeout spec / countdown screen** — a reserved slot for the Emergency Break entry point on `TimeoutCountdownView.swift`. Find it and confirm how it's stubbed.
2. **`ShieldManager.debugEmergencyUnlock()`** — the debug path that wipes timeout state WITHOUT crediting `totalTimeoutMinutes`. The real Emergency Break must reuse or share this logic, not duplicate it.
3. **`appEnabled`** — the Streak spec notes "disable-breaks-streak ships with the emergency-break feature." Confirm whether the `appEnabled` key and its streak hook exist in `Streak.swift` / `GetuppShared.swift`, and whether `deriveStreak()` already accounts for it.
4. Any other mentions of "emergency," "break," or "escape" in the codebase.

Report findings, then propose the file/change plan before implementing.

---

## Problem

Two escape valves are missing:

1. **Emergency Break** — a one-day surrender. User is blocked (morning window or timeout), can't or won't verify (offline, real emergency, gave up), and needs out for today. Without it, offline = locked out, which is unacceptable. Currently only a debug button exists.
2. **Pull the Plug (toggle off)** — a full surrender. User adapting to GETUPP wants to turn it off entirely for a while without uninstalling. Without it, the only off-switch is deleting the app — which loses the user permanently instead of temporarily.

Both are "give up" actions, so both follow the same design principles: full-screen shameful confirmation, streak loss made explicit and concrete, deliberate friction on the way out — and zero friction on the way back.

## Goals

- Offline users are never permanently locked out (Emergency Break works fully offline).
- Users can pause GETUPP entirely without uninstalling, and return with one tap.
- Giving up always has a visible, consistent cost (streak → 0), so neither path becomes a loophole around the other.
- Both flows are impulse-resistant: 5-second countdown before the confirm button enables.

## Non-goals

- **Emergency Break budget/limits** (e.g., 1 free break per month) — future consideration; track the stat now, gate later.
- **Scheduled pauses / vacation mode** — Pull the Plug is binary on/off; time-boxed pauses are a separate future feature.
- **Streak forgiveness / restore** — a broken streak stays broken. No "repair streak" mechanic in v1.
- **Real (non-debug) emergency unlock UX changes to the shield screens** — shield copy already tells users to open GETUPP; no shield changes in this spec beyond what the timeout shield already does.

---

## Navigation

```
SettingsView
  └── "Escape Hatch" (button row)
        └── EscapeHatchView (the hub — exactly 2 controls, nothing else)
              ├── "Emergency Break"  → full-screen confirmation → post-confirmation state → Home
              └── "Pull the Plug"    → full-screen confirmation → post-confirmation state → Home
```

Additional entry point: the reserved Emergency Break slot on `TimeoutCountdownView` opens the **same** Emergency Break confirmation screen. One confirmation flow, two doors.

### Escape Hatch hub (`EscapeHatchView`)

Only these two rows. Clarity over density — each row has a title + always-visible subtitle:

| Row | Title | Subtitle |
|---|---|---|
| 1 | **Emergency Break** | Unblocks today's apps. Your streak pays the price. |
| 2 | **Pull the Plug** | Turns GETUPP off completely. No blocks, no streak, nothing. |

- Emergency Break row is **disabled** (dimmed, non-tappable, subtitle swapped) when phase is `free` or `preWindow` — there's nothing to escape from. Disabled subtitle: *"Nothing to escape from right now. Impressive foresight though."*
- Determine phase via the same derived-state logic as `Timeout.swift` (never a stored flag).

---

## Confirmation flow (shared pattern, two instances)

**Presentation:** SwiftUI `.fullScreenCover` — deliberate: no swipe-to-dismiss, no system-alert cop-out. The friction is the feature.

**Screen anatomy, top to bottom:**

1. **Fixed title** — Anton, all caps, static (never from a pool).
2. **Implications block** — Space Mono, factual, no jokes. This is the honest-cornerman section. MUST include the live streak number from `deriveStreak()` (e.g., "Your 12-morning streak dies here."). If streak is 0, use the zero-streak variant (see copy).
3. **Dynamic roast line** — Caveat or brand-appropriate accent styling; drawn from a copy pool with the `TimeoutCopy.swift` pattern (pool per moment, random with no-immediate-repeat via App Group last-index key).
4. **Cancel CTA** — the BIG, prominent, acid-yellow brand button. Dismisses the flow and returns to Home (main view). The escape route from the escape route gets the visual priority — inverted dark pattern, on purpose.
5. **Confirm button** — smaller, muted/destructive styling. NEVER acid yellow. Disabled on appear; label shows a live countdown: `UNBLOCK MY APPS (5)` → `(4)` → … → enabled at 0. Tapping it executes the action **immediately** — no second confirmation.

**Countdown rules:**
- 5 seconds, counts on the button label itself.
- Countdown restarts from 5 every time the screen appears (backgrounding/returning does not preserve progress — cheap anti-impulse insurance).

**Post-confirmation state (required, not optional):**
After the action executes, the same full-screen cover transitions to a static "done" state — the walk of shame. Shows what happened, factually, plus one roast line from the post-action pool. Single CTA leading to Home. No auto-dismiss.

---

## Semantics

### Emergency Break

Works in BOTH blocked phases (`blocked` = morning window unverified, `timeout` = verified, apps in timeout). On confirm:

1. Clear all shields.
2. If a timeout is running: wipe `timeoutEndTime` WITHOUT crediting `totalTimeoutMinutes` (same behavior as `debugEmergencyUnlock()` — share the code path).
3. Write a "break used" record to the day log (`DayRecord`) so `deriveStreak()` returns 0. Never mutate a counter — the streak is derived, and stays derived.
4. Increment lifetime stat `emergencyBreaksUsed` (App Group, mirror of `totalTimeoutMinutes`).
5. Schedule untouched — tomorrow's window runs normally. This is a one-day surrender.

**Must work fully offline.** No network calls anywhere in this path — that's the feature's reason to exist. (Confidence this is achievable: ~99% — everything here is local App Group + ManagedSettings.)

### Pull the Plug (toggle off)

On confirm:

1. Stop all DeviceActivity monitoring (unschedule the morning window activity and any `getupp.timeout` activity).
2. Clear any active shields. If a timeout is running, wipe it without crediting minutes (same rule as above).
3. Set `appEnabled = false` in App Group UserDefaults.
4. Write the day-log record that breaks the streak (per the Streak spec's planned `appEnabled` hook — coordinate with whatever the audit found).
5. Preserve ALL settings: blocked-app selection (FamilyActivity tokens), wake window, timeout duration, pending downgrades. Nothing is deleted — only deactivated.
6. While disabled, days simply don't accrue toward anything. No shields, no monitoring, no photo prompt.

**Guard everywhere:** `reconcileState()`, monitor `intervalDidStart`/`intervalDidEnd`, and daily maintenance must all early-return (or no-op shields) when `appEnabled == false`. A disabled GETUPP must never re-shield "helpfully."

### Toggling back ON — frictionless and warm

The asymmetry is the design: friction and shame on the way out, open arms on the way back.

- **No confirmation, no countdown, no guilt.** One tap.
- Restores last saved settings exactly (app selection, window, timeout duration) and re-registers the DeviceActivity schedule for the next window.
- Trigger a **celebration moment** (confetti/animation + one line from the welcome-back copy pool).
- Streak starts fresh from tomorrow's first won morning — no backdating.
- If re-enabled MID-window (current time inside today's configured window): do NOT shield mid-day. Today is a wash; blocking starts at the next `intervalDidStart`. Shielding someone at 2pm the moment they re-enable is a hostile re-onboarding. State this explicitly in code comments — it will look like a bug.

### Home screen disabled state

When `appEnabled == false`, the Home screen (main view) swaps its normal content for a disabled state:

- Clear statement that GETUPP is off (brand voice, see copy).
- One prominent acid-yellow button: **"TURN IT BACK ON"** → executes the re-enable + celebration inline. No navigation to Settings required.
- Nothing else competes with that button.

---

## Rules that look like bugs but aren't

- **Emergency Break does not touch the schedule.** Tomorrow's window fires normally. It is not a pause.
- **Neither path ever credits `totalTimeoutMinutes`.** Surrendered timeout minutes don't count.
- **Re-enable mid-window does not shield today.** Intentional (see above).
- **Pull the Plug deletes nothing.** All settings survive; only `appEnabled` flips.
- **The streak number in the implications block is derived live** on screen appear — never cached, never a stored counter.
- **Countdown resets on every screen appearance.** Not persisted.

---

## Requirements

### P0 (cannot ship without)

- [ ] Escape Hatch row in `SettingsView` → `EscapeHatchView` hub with exactly the 2 rows + subtitles above
- [ ] Emergency Break row disabled with swap-copy when phase is `free`/`preWindow`
- [ ] Shared full-screen confirmation pattern (`.fullScreenCover`): fixed title, implications with live streak number, roast pool line, big yellow cancel → Home, 5s on-button countdown confirm
- [ ] Post-confirmation state with single CTA → Home
- [ ] Emergency Break semantics 1–5, fully offline, sharing the `debugEmergencyUnlock()` no-credit wipe path
- [ ] Pull the Plug semantics 1–6, with `appEnabled == false` guards in reconcile, monitor callbacks, and daily maintenance
- [ ] Countdown-screen reserved slot wired to the same Emergency Break confirmation
- [ ] Home disabled state with one-tap re-enable + celebration + last-settings restore
- [ ] All copy from pools in a dedicated copy file (see Copy) — no hardcoded strings in views
- [ ] `emergencyBreaksUsed` lifetime stat

### P1 (fast follow)

- [ ] Celebration animation polish (v1 can be a simple confetti/emoji burst; don't block ship on animation quality)
- [ ] Haptics: warning haptic when confirm enables; success haptic on re-enable

### P2 (design for, don't build)

- Break budget (N free breaks per period) — `emergencyBreaksUsed` and per-day `DayRecord` entries must make this computable later
- Surfacing `emergencyBreaksUsed` as a shame stat in a future stats screen
- Vacation mode (time-boxed pause) — keep Pull the Plug logic clean enough that a scheduled re-enable could wrap it

---

## Acceptance criteria (key paths)

**Emergency Break, mid-timeout, offline:**
- Given airplane mode, a running timeout, and a 12-morning streak
- When the user completes the Emergency Break confirmation
- Then shields clear immediately, `timeoutEndTime` is gone, `totalTimeoutMinutes` unchanged, `emergencyBreaksUsed` +1, streak derives to 0, post-confirmation screen shows, and tomorrow's window still fires

**Pull the Plug, then relaunch:**
- Given GETUPP disabled via Pull the Plug
- When the app is force-quit and relaunched, and when the next window's `intervalDidStart` would have fired
- Then no shields are applied anywhere, Home shows the disabled state

**Re-enable mid-window:**
- Given GETUPP disabled and current time inside the configured window
- When the user taps "TURN IT BACK ON"
- Then celebration plays, settings restore, schedule re-registers, and NO shield applies until the next window start

**Cancel path:**
- Given either confirmation screen open with countdown running
- When the user taps the cancel CTA
- Then nothing changes anywhere (no writes) and the user lands on Home

**Impulse guard:**
- Given a confirmation screen just appeared
- When the user taps the confirm button before the countdown ends
- Then nothing happens (button is genuinely disabled, not just styled disabled)

---

## Copy

All strings live in a new `EscapeHatchCopy.swift` following the `TimeoutCopy.swift` pattern: pools by moment, random selection with no-immediate-repeat via App Group last-index keys. Frame per brand voice: roast the behavior, never the person; funny-rude, never mean; cornerman, not bully.

### Emergency Break confirmation

- **Title (fixed):** `BREAKING OUT?`
- **Implications (fixed, streak > 0):** "This unblocks your apps for today. Your {N}-morning streak dies right here. Tomorrow morning, the shield comes back like nothing happened."
- **Implications (fixed, streak = 0):** "This unblocks your apps for today. No streak to lose — which is its own kind of statement. Tomorrow, the shield comes back."
- **Roast pool:**
  - "Real emergencies rarely involve TikTok."
  - "This is the adult version of faking a fever."
  - "We'll tell your apps you had an 'emergency.'"
  - "Define 'emergency.' Take your time. You clearly have some."
  - "The bed always negotiates. The bed never wins. Except today, apparently."
- **Confirm:** `UNBLOCK MY APPS (5)` → `UNBLOCK MY APPS`
- **Cancel:** `NEVER MIND — I'M UP`

### Emergency Break post-confirmation

- **Fixed:** "Done. Apps unblocked for today. Streak: 0. See you tomorrow morning."
- **Roast pool:**
  - "Enjoy the scroll. The shield remembers."
  - "Today didn't count. Tomorrow does."
  - "We're not mad. We're just recalibrating our expectations."
- **CTA:** `BACK TO HOME`

### Pull the Plug confirmation

- **Title (fixed):** `PULLING THE PLUG?`
- **Implications (fixed, streak > 0):** "This shuts GETUPP down completely. No morning blocks, no photos, no rules. Your {N}-morning streak dies here. Your settings stay saved for whenever you come back."
- **Implications (fixed, streak = 0):** "This shuts GETUPP down completely. No morning blocks, no photos, no rules. Your settings stay saved for whenever you come back."
- **Roast pool:**
  - "Turning off the smoke alarm because you like the smoke."
  - "The blanket wins. Noted."
  - "We'll be here when bed-rotting stops being fun."
  - "Bold move: uninstalling the consequences instead of the apps."
  - "Your future 7am self would like a word. We'll pass along the message."
- **Confirm:** `SHUT IT DOWN (5)` → `SHUT IT DOWN`
- **Cancel:** `KEEP ME HONEST`

### Pull the Plug post-confirmation

- **Fixed:** "GETUPP is off. No blocks, no streak, no judgment. (Some judgment.) Everything's saved for when you're ready."
- **Roast pool:**
  - "The apps are free. So is the bed. Good luck out there."
  - "We'd say 'you got this' but the evidence is mixed."
  - "Door's unlocked whenever you want your mornings back."
- **CTA:** `BACK TO HOME`

### Home disabled state

- **Fixed statement:** "GETUPP IS OFF. Your mornings are unsupervised. How's that going?"
- **Button:** `TURN IT BACK ON`

### Welcome-back pool (on re-enable, with celebration)

- "THERE you are. The shield missed you. Sort of."
- "Back in the game. First round: tomorrow morning."
- "Good call. The bed never deserved you anyway."
- "Reactivated. Streak starts fresh tomorrow — make it count."

---

## Technical notes for implementation

- **New files (proposed — confirm against audit findings):** `EscapeHatchView.swift`, `EscapeConfirmationView.swift` (shared, parameterized by action), `EscapeHatchCopy.swift`, plus semantics functions living where the audit says they belong (likely `ShieldManager` + a shared helper reachable from the pieces that need the `appEnabled` guard).
- **Target membership (manual, in Xcode — remind André):** views + copy → `Getupp` only. Anything the monitor needs for the `appEnabled` guard must be in `GetuppMonitor` too — follow the `Timeout.swift` / `GetuppShared.swift` precedent, including `KEEP IN SYNC` comments if constants are duplicated for the memory-constrained extensions. Don't "fix" that duplication.
- **No new stored state beyond:** `appEnabled` (Bool), `emergencyBreaksUsed` (Int), copy last-index keys, and the day-log records. Everything else stays derived.
- **Self-tests:** extend the DEBUG self-test harness pattern — pure-logic tests for the `appEnabled` guards and the no-credit wipe rule, runnable from ContentView's debug section (no XCTest target exists).
- **After implementing:** tell André exactly what to rebuild (Cmd+R) and a device test script: (1) break mid-window, (2) break mid-timeout offline in airplane mode, (3) plug pull + relaunch + wait for window start, (4) re-enable mid-window, (5) cancel paths, (6) countdown tap-early.
- Display `emergencyBreaksUsed` on a tiny line in Settings.

## Questions

- **[Claude Code audit, blocking]** Does the `appEnabled` streak hook already exist in `deriveStreak()`, or does it ship with this spec? The audit determines whether step 4 of Pull the Plug is "wire existing" or "build new."
- **[Device test, non-blocking]** Whether the celebration animation performs acceptably on André's device — if janky, ship the copy line alone and polish in P1.
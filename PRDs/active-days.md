# GETUPP — Active Days (Schedule) PRD

**Status:** Draft for build
**Tier:** Production (schedule + streak logic survive into production, same tier as the blocking module and Timeout)
**Depends on:** existing `WakeSchedule`, `Timeout`, `Streak`, `DayRecord`, `dailyMaintenance()`

---

## Problem Statement

GETUPP currently arms the shield **every** morning inside the wake window. Real users don't want the same rule 7 days a week — weekend lie-ins, a fixed day off, or a "only the days I actually rot in bed" pattern. Without configurable days, the honest user's only tools for "not today" are the emergency break (one-off, breaks streak) or turning GETUPP off (indefinite) — both wrong instruments for a *recurring* preference. The result is either resentment or people leaving GETUPP off and never turning it back on.

## Goals

1. Let a user define **which weekdays** GETUPP arms, with two-tap access to the common patterns (Every day / Weekdays / Weekends) and full manual control.
2. Keep the schedule **legible at a glance** — the Settings row answers "what will GETUPP do to me?" without a tap.
3. Make un-scheduled days a **first-class streak concept** (skip, don't break, don't count) that survives Apple's flaky DeviceActivity callbacks.
4. Route deactivation intent (unselecting everything) toward the **honest exit** (Escape Hatch), not a schedule hack.
5. Ship without introducing a same-day loophole or a cross-midnight streak bug.

## Non-Goals

- **Per-day wake windows** (different times on different days). One window, N days for v1. Different-times-per-day is a much larger data model; parking it. (P2)
- **Date-specific exceptions** ("skip Dec 25", vacation ranges). That's a calendar feature, not a weekly schedule. (P2)
- **Cross-midnight wake windows.** Explicitly disallowed — see R6. Enforced in the wake window picker.
- **Localized "work week" definitions** beyond Mon–Fri. "Weekdays" = Mon–Fri everywhere in v1. (P2)
- **Timezone-travel handling.** Schedule follows the device's current calendar; no special logic for crossing zones.

---

## Information Architecture

Settings uses **grouped list section headers** — no new navigation depth. Days sits next to Wake window under a shared header:

```
SCHEDULE
  Wake window          6:30 – 8:00 ›
  Days                    Weekdays ›

BLOCKING
  Timeout                    30 min ›
  Apps to block             8 apps ›

ESCAPE HATCH
  Escape hatch                     ›     ← options stay hidden behind this tap
```

- **Section name:** "Schedule". **Row name:** "Days" (section header supplies context; the right-detail value does the explaining).
- **Escape Hatch stays a door, not a shelf.** Emergency break + GETUPP on/off remain hidden until the user taps into Escape Hatch. These are for genuine need, not habitual hacks — keeping them one level down is deliberate friction.

---

## Data Model

**Single source of truth:** `activeDays: Set<Int>` in App Group UserDefaults, using `Calendar` weekday numbering (1 = Sunday … 7 = Saturday).

- **No mode enum.** Do not store `.everyday | .weekdays | .custom`. Presets are *derived on read* from the set — same principle as `Streak` and `Timeout`. This kills the "mode says Weekdays but the set says Tue/Thu" class of bug and needs no migration when someone hand-picks exactly Mon–Fri.
- **Default:** all 7 days (preserves current every-morning behavior for existing installs).
- **Invariant:** `activeDays` is never empty on disk. The UI guard (below) prevents saving empty; a defensive read treats empty-on-disk as "all 7" and logs an error rather than leaving the user permanently unblockable.

**Same-day downgrade queue (mirrors Timeout R5):**

- `pendingActiveDays: Set<Int>?` — a queued set that removes today, promoted to `activeDays` at the next `dailyMaintenance()`.

**Streak correctness:**

- `DayRecord` gains `scheduled: Bool`.
- `activeSessionDate` (App Group key) — the calendar day the current window *started*. Written at window arm; the anchor for every session-lifecycle write. See R6.

---

## UX — the Days screen (one screen, one Save)

Tapping **Days** opens a single screen. Preset chips sit above the full 7-day list. Custom is **not** a mode or a separate sheet — it's simply what "no preset matched" looks like.

```
Days

  [ Every day ]   [ Weekdays ]   [ Weekends ]     ← chips; lit state derived from the set

  Sunday
  Monday        ✓
  Tuesday
  Wednesday     ✓
  Thursday
  Friday        ✓
  Saturday

  [ Save ]
```

- **Chips fill the list.** Tapping "Weekdays" sets the list to Mon–Fri. Tapping individual days that break a preset simply un-lights the chip — no error, no mode switch.
- **Chip lit state is derived:** all 7 → Every day lit; Mon–Fri → Weekdays lit; Sat+Sun → Weekends lit; else → no chip lit. A hand-picked Mon–Fri correctly lights "Weekdays" (accepted and correct, per the derive-don't-store principle).
- **First day of week** follows `Calendar.current.firstWeekday` — never hardcode Sunday-first (Brazil and much of the world start on Monday).
- **Explicit Save**, not live-apply. The commit moment is required for the empty-state guard and the same-day rule.

### Settings row detail (the value shown on the Days row)

- All 7 → **"Every day"**
- Mon–Fri → **"Weekdays"**
- Sat+Sun → **"Weekends"**
- Contiguous run in the ordered week → **abbreviated range**, e.g. **"Tue to Sat"** (abbreviations always fit; full names truncate on small devices). Contiguity is checked only in the ordered week per `firstWeekday`; **no wraparound** (Sat+Sun+Mon renders as a list, not "Saturday to Monday").
- Otherwise → **abbreviated list**, e.g. "Mon, Wed, Fri"
- A single day renders **plural**: "Mondays" (recurring state, not an event).

---

## Empty-state guard (deactivation funnel)

Unselecting all days is a deactivation attempt in disguise. Meet it — don't just block it.

- The moment the last day is unticked, **Save disables** and this appears inline:

  > **Zero days is just GETUPP off.**
  > [ Turn GETUPP off ]

- The button **dismisses the Days screen without saving**, then lands the user on the **Escape Hatch screen** — and stops. It does **not** auto-toggle. Deliberate friction on the way out is the point, and consistent with why those options are hidden in the first place.

---

## Same-day change rule (loophole guard)

Directly analogous to **Timeout R5 (no same-day downgrade)**.

- **Removing a day that is *today*** — when today is scheduled and the window hasn't ended — does **not** take effect today. It queues to `pendingActiveDays` and is promoted at the next `dailyMaintenance()`. On save, show inline:

  > Today's already running. Starts tomorrow.

  (No emergency-break nudge here — per decision.)
- **Adding days applies immediately** and cancels any queued removal.
- **Removing a *future* day** (or today when today isn't scheduled / window already ended) applies immediately.
- Daily reset is **lazy**: `pendingActiveDays` is promoted inside the idempotent `dailyMaintenance()`, called from multiple processes. No dedicated reset event.

---

## Scheduling engine

**One daily schedule, gated by a predicate — not seven activities.**

- Keep the single daily `DeviceActivitySchedule`. Add `WakeSchedule.isScheduledToday() -> Bool` (reads `activeDays`), consulted by every process (app, monitor, shield).
- Monitor's `intervalDidStart` **no-ops when `!isScheduledToday()`** — no shields, and it does **not** write `activeSessionDate`.
- Registering 7 named activities would multiply the flaky-callback surface by 7 for zero benefit. (~90% confidence this is the right tradeoff.)
- `WakeSchedule.nextWindowStart()` becomes a **bounded search** (scan forward up to 7 days for the next scheduled day). It must have a defined answer when `activeDays` is empty (fall back to "all 7" per the defensive invariant) and must never infinite-loop. This matters because `Timeout` clamps `timeoutEndTime` to `min(proposed, nextWindowStart())`, and with a Monday-only schedule that bound can be up to 6 days out (harmless — timeouts are ≤ hours).

---

## Streak semantics

- **Unscheduled day = skip.** It does not break the streak and does not count toward it. (The compensation for "days off don't break you" is "days off don't build you.")
- **`DayRecord.scheduled: Bool`** disambiguates the two meanings of "no record for a date": *not scheduled* vs *callback flaked*. `dailyMaintenance()` **lazily backfills** records for elapsed days using the day's scheduled status.
  - Known limitation (~75% confidence acceptable): if a user edits days and doesn't open the app for a week, backfill stamps elapsed days with *current* `activeDays`, not the set that governed them at the time. Self-limiting (maintenance runs every foreground) and not worth the complexity to fix in v1.
- **Never show a bare integer.** The number always reads as "N mornings" — a Monday-only user hitting streak 4 is honest under the definition, and the "mornings" framing carries the context. (Existing rule — keep it.)

---

## R6 — Cross-midnight session ownership

**A session belongs to the calendar day its window *started*, regardless of wall-clock midnight.**

Concrete bug avoided: window 1pm–11pm, verify at 22:50, 2h timeout → completion at 00:50 the next day. Crediting on `Date()` would write to the *wrong* `DayRecord` (tomorrow — which may not even be scheduled), producing a phantom day *and* a broken streak.

**Mechanism — `activeSessionDate`:**

- Written to the App Group at window arm (`intervalDidStart`), value = calendar day of window **start**.
- Every subsequent session-lifecycle write uses it instead of `Date()`:
  - `Timeout.beginTimeout()` **inherits** `activeSessionDate` (does not re-derive).
  - `Timeout.completeTimeoutIfElapsed()` credits `DayRecord[activeSessionDate]`, **then clears the key** (the clear is the idempotency latch, same shape as the `timeoutEndTime` latch).
  - Emergency break / `debugEmergencyUnlock()` marks `DayRecord[activeSessionDate]` broken.
  - `Streak.deriveStreak()` attaches `.pending` to `activeSessionDate`, not to "today".
- **Backfill guard:** `dailyMaintenance()` must **not** backfill the day `activeSessionDate` points at while it's still set — deleting the key is what finalizes the day.
- **Consequence:** at 00:50 the UI honestly shows *yesterday* pending; the +1 lands on yesterday; today is untouched (and stays a skip if unscheduled). A timeout running past midnight into an unscheduled day survives trivially.

**Enforced constraint:** wake windows **cannot cross midnight** (end time must be after start time, same day) — enforced in the wake window picker. A window spanning midnight makes "which day is this session?" ambiguous and breaks day-of-week scheduling. (~95% confidence the constraint is correct vs. supporting hypothetical night-shift users.)

---

## User Stories

- As a user who sleeps in on weekends, I want GETUPP to arm only Mon–Fri so that it doesn't block me on my rest days. → tap **Weekdays**.
- As a user with one fixed day off, I want to pick exactly the days I need so that the schedule matches my real week. → hand-pick days.
- As a user glancing at Settings, I want to see my schedule without tapping so that I know what tomorrow holds. → row detail.
- As a user who unticks every day, I want to be shown the honest way to pause so that I don't fake a deactivation through the schedule. → empty-state funnel.
- As a user removing today from the schedule mid-morning, I want the change to be clearly "starts tomorrow" so that I can't accidentally (or deliberately) dodge today's block. → same-day rule.
- As a user with a late-night window that spills past midnight, I want my streak credited to the right day so that the number stays honest. → `activeSessionDate`.

---

## Requirements

### Must-Have (P0)

**P0-1 — `activeDays` store + derived labels**
- [ ] `activeDays: Set<Int>` persisted in App Group; default all 7.
- [ ] No mode enum stored. Chip lit state + row detail derived from the set on read.
- [ ] Defensive read: empty-on-disk → treat as all 7, log error.

**P0-2 — Days screen**
- [ ] One screen: Every day / Weekdays / Weekends chips above a 7-day list, explicit Save.
- [ ] Day order from `Calendar.current.firstWeekday`.
- [ ] Chips fill the list; breaking a preset un-lights its chip with no error.
- Given a user taps "Weekdays", When the list renders, Then Mon–Fri are ticked and only "Weekdays" is lit.
- Given a user hand-picks exactly Sat+Sun, Then "Weekends" lights automatically.

**P0-3 — Settings row detail**
- [ ] Renders Every day / Weekdays / Weekends / abbreviated contiguous range ("Tue to Sat") / abbreviated list / plural single day ("Mondays").
- [ ] Contiguity in ordered week only; no wraparound.

**P0-4 — Empty-state funnel**
- [ ] Unticking the last day disables Save and shows the "Zero days is just GETUPP off." message + button.
- Given zero days selected, When the user taps the button, Then the Days screen dismisses **without saving** and the Escape Hatch screen opens (no auto-toggle).

**P0-5 — Same-day change rule**
- [ ] Removing today (scheduled, window not ended) queues to `pendingActiveDays` + shows "Today's already running. Starts tomorrow."
- [ ] Adding days applies immediately and cancels any queued removal.
- [ ] `pendingActiveDays` promoted in `dailyMaintenance()`.

**P0-6 — Scheduling predicate**
- [ ] `WakeSchedule.isScheduledToday()` consulted by app, monitor, shield.
- [ ] `intervalDidStart` no-ops (no shields, no `activeSessionDate` write) on unscheduled days.
- [ ] `nextWindowStart()` is a bounded forward search with a defined answer for the empty set; cannot infinite-loop.

**P0-7 — Streak: `DayRecord.scheduled`**
- [ ] `scheduled: Bool` added; `dailyMaintenance()` backfills elapsed days.
- [ ] Unscheduled days skip (don't break, don't count).

**P0-8 — Cross-midnight ownership (`activeSessionDate`)**
- [ ] Key written at window arm = window-start day.
- [ ] `beginTimeout` inherits it; `completeTimeoutIfElapsed` credits `DayRecord[activeSessionDate]` then clears it; emergency break marks it; `deriveStreak` pends on it.
- [ ] Backfill skips the day while the key is set.
- [ ] Wake window picker rejects end ≤ start (no cross-midnight window).

### Nice-to-Have (P1)

- Self-test coverage: extend `runStreakSelfTests()` with a scheduled/unscheduled skip fixture and a cross-midnight `activeSessionDate` fixture (pure `deriveStreak()` cases, no device needed).
- Subtle "next arm" hint on the main screen when today is unscheduled ("Next: Monday") so the user isn't surprised by a quiet morning.

### Future Considerations (P2)

- Per-day wake windows.
- Date-specific skips / vacation ranges.
- Localized work-week presets.

---

## Success Metrics

This is a POC (André + Ken testing), so metrics are correctness- and behavior-focused, not adoption dashboards.

**Leading (verify during test week):**
- Zero streak-attribution bugs across the cross-midnight fixture and a live late-window device test.
- Unscheduled mornings produce no shield and no `DayRecord` break — confirmed in the day log.
- Same-day removal never dodges today's block (manual device test at ~1 min before window).

**Lagging (once real users exist):**
- Fewer "turned GETUPP off and never came back" drop-offs vs. the every-day-only baseline — the schedule should absorb "not today" intent that previously leaked to full deactivation.

---

## Open Questions

- **[eng]** Does `nextWindowStart()`'s up-to-6-days bound interact badly with any existing `Timeout` clamp assumptions? Believed fine (timeouts ≤ hours ≪ 6 days) but worth a fixture. *Non-blocking.*
- **[eng/device]** Confirm the monitor reliably reads fresh `activeDays` at `intervalDidStart` given DeviceActivity's process lifecycle. *Non-blocking — the check-on-open layer covers a stale read.*
- **[design]** Does the "Next: Monday" hint (P1) belong in v1, or does it clutter the deliberately minimal main screen? *Non-blocking.*

---

## Timeline / Phasing

No hard deadline. Suggested build order (each independently testable):

1. **P0-1 + P0-2 + P0-3** — store, screen, row detail. Pure UI + persistence; testable without the scheduling engine.
2. **P0-6** — predicate + `nextWindowStart()` bound. Makes days actually govern arming.
3. **P0-7 + P0-8** — streak correctness + cross-midnight. The subtle tier; land the self-test fixtures here.
4. **P0-4 + P0-5** — funnel + same-day rule. The behavioral guards; test on-device near a real window boundary.

**Target membership reminder (manual, in Xcode):** any new schedule-logic file that the monitor/shield read must be added to those targets too — same discipline as `Timeout.swift` and `GetuppShared.swift`. Flag each new file when created.
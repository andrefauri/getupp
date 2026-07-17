# GETUPP — [CLAUDE.md](http://CLAUDE.md)

## What this is

GETUPP is an iOS app that blocks the user's social media apps every morning until they submit a live photo proving they're out of bed. Claude's vision API verifies the photo; on success, apps unblock.

Core loop: wake up → open GETUPP → take photo → AI verifies out-of-bed → social apps unblock for the day.

## Who you're working with

André is not a traditional developer — he's learning to code by building with AI. Practical implications:

- Explain new concepts briefly when introducing them (one or two sentences, analogy + technical term). Don't assume Swift/iOS/Python knowledge.
- Prefer simple, readable code over clever code. One obvious way > three smart ways.
- When something must be done manually in Xcode or on the iPhone, say so explicitly with step-by-step instructions — don't assume he knows the IDE.
- Give direct, honest assessments. No confirmation bias. If an approach is bad, say so and explain why.

## Current phase: POC

Validating three things, in order:

1. AI vision can reliably classify in-bed vs out-of-bed photos

2. Family Controls can block user-selected apps within a daily time window

3. Verified photo → unblock → success screen flow works end to end

POC code is mostly throwaway. Two exceptions to write carefully, as they will survive into production:

- The Family Controls blocking module
- The verification prompt + photo test set

## Repo structure

getupp-app/  
├── [CLAUDE.md](http://CLAUDE.md) ← this file  
├── photo-eval/ ← Python validation script for photo classification  
│ ├── [classify.py](http://classify.py)  
│ ├── prompts/ ← versioned prompt files (v1.txt, v2.txt, ...)  
│ ├── photos/ ← test set; folder name = ground truth (gitignored)  
│ │ ├── in-bed/  
│ │ ├── out-of-bed/  
│ │ └── adversarial/ ← ground truth = in-bed (fail-closed)  
│ ├── results/ ← one CSV per run: {date}*{promptversion}*{model}.csv  
│ ├── [NOTES.md](http://NOTES.md) ← conclusions per prompt iteration  
│ └── .env ← ANTHROPIC_API_KEY (gitignored)  
└── GetUpp/ ← iOS app (Xcode project)

## photo-eval rules

- Never include filename, folder path, or metadata in API requests — only the base64 image and prompt text. Ground truth labels are for local scoring only (avoid data leakage).
- Prompts are data, not code: they live in prompts/ as versioned text files. Never hardcode a classification prompt inside [classify.py](http://classify.py).
- Resize photos to max 1024px longest side, JPEG ~80%, before sending.
- Model must return strict JSON: {"out_of_bed": bool, "confidence": 0-1, "reason": "..."}. Parse defensively; a bad response is a logged error, not a crash.
- Models under evaluation: claude-haiku-4-5 vs claude-sonnet-4-6. Track accuracy, latency, and cost per run.

## iOS app rules

### Stack

- Swift + SwiftUI, iOS (iPhone only)
- Bundle ID: [co.getupp.app](http://co.getupp.app)
- App Group: [group.co.getupp.app](http://group.co.getupp.app)
- Frameworks: FamilyControls, ManagedSettings, DeviceActivity, AVFoundation
- Anthropic API called directly with a key from a gitignored config file. POC-ONLY exception: this is acceptable solely because the app runs only on André's phone. Before any distribution (even TestFlight), API calls must go through a Supabase Edge Function proxy. Never suggest shipping a client-side key.

### Targets

- Getupp — main app
- Monitor extension (DeviceActivityMonitor) — applies/clears shields on schedule window start/end
- Shield extension (ShieldConfiguration) — customizes the block screen

### Workflow and boundaries

- Claude Code edits Swift files in Cursor. André builds and runs manually in Xcode (Cmd+R) on his physical iPhone. There is no CLI build loop — after writing code, tell André to rebuild and what to test.
- NEVER touch code signing, entitlements files, provisioning, or project.pbxproj target membership. André handles all of that in Xcode. When you create a new file, remind him to check it's added to the correct target in Xcode's File Inspector.
- Extensions must stay minimal: no heavy dependencies, tight memory limits.

### Domain constraints (do not "fix" these — they're Apple platform rules)

- FamilyActivityPicker returns opaque tokens. The app cannot know or target specific apps by name. Users manually select what to block.
- The shield screen cannot deep-link back into GETUPP. Its buttons can only close the blocked app. Copy must tell users to open GETUPP.
- Apps cannot programmatically close themselves. No exit() or private APIs.
- DeviceActivity schedules are wall-clock based and callbacks can be unreliable. For testing, use short windows starting a few minutes out — never change the device clock.
- Camera capture only (live photo), never photo library — anti-cheat is the product premise.

### Product decisions already made

- Fail-closed: ambiguous photo → user stays blocked.
- Daily reset via lastVerifiedDate in App Group UserDefaults; monitor extension checks it on intervalDidStart.
  - Emergency unlock must exist (offline = locked out otherwise). Debug button is fine for POC.
  - Photos are never stored: verify via API, keep only pass/fail + timestamp.


### Streak (implemented)

- Retention mechanic: counts consecutive "mornings" won — a scheduled day where the blocking session ran and the emergency break wasn't used. Photo verification is not required for the streak; not scrolling during the window is the actual product outcome. UI always says "mornings," never "days."
- Never stored as a counter — derived on read from an append-only day log (`DayRecord`) so it survives Apple's flaky DeviceActivity callbacks. See `Streak.swift` (pure `deriveStreak()`, no I/O — testable without a device) and the day-log read/write helpers in `GetuppShared.swift`.
  - `Streak.swift` is shared — must live in both the `Getupp` and `GetuppMonitor` targets, same as `GetuppShared.swift`.
- The post-verification buffer is now WIRED (via Timeout): `GetuppShared.currentStreak` passes `Timeout.effectiveStreakDuration()` as `timeoutDuration`, so today shows `.pending` during a running Timeout and the +1 lands on natural completion. Still not wired: `appEnabled` (disable-breaks-streak ships with the emergency-break feature).
- No XCTest target exists, so fixture coverage lives in a DEBUG-only self-test harness (`runStreakSelfTests()` in `Streak.swift`), run from the "Run Self-Tests" button in ContentView's debug Streak section.

### Timeout (implemented)

Post-verification blocking period: after a successful photo, apps STAY blocked for a user-chosen duration. Closes the "verify, then scroll in the kitchen" loophole. Production-tier code (same tier as the blocking module) — full spec lives in the Timeout spec doc; state model + Family Controls logic survive into production.

**State model — derived, never stored:**

- Four phases (`preWindow → blocked → timeout → free`), always derived from App Group values + wall clock. Every process (app, monitor, shield, shield-action) computes state from the same keys, so they cannot disagree. Core logic in `Timeout.swift`.
- `Timeout.swift` imports ONLY Foundation + ManagedSettings so it can live in all four targets (Getupp, GetuppMonitor, GetuppShield, GetuppShieldAction) without dragging heavy frameworks into memory-constrained extensions. It duplicates a few string constants from `GetuppShared.swift` with `KEEP IN SYNC` comments — that duplication is deliberate; don't "fix" it by importing GetuppShared.
- Keys: `timeoutDuration` (setting, default 1800), `pendingTimeoutDuration` + `pendingTimeoutSetDate` (queued downgrade), `timeoutEndTime` (Date — single source of truth for a running Timeout), `totalTimeoutMinutes` (lifetime stat).
- **Invariant:** `timeoutEndTime` and `activeBlockEnd` are mutually exclusive, never both set. `activeBlockEnd` = morning block running, unverified; `timeoutEndTime` = verified, apps in timeout. `Timeout.beginTimeout()` enforces this.

**Three clearing layers** (all ship; all ask "is `timeoutEndTime` elapsed?" of the same key):

1. One-off DeviceActivity schedule (`getupp.timeout` activity) → monitor's `intervalDidEnd`. Skipped when remaining < 15 min (DeviceActivity minimum) — layers 2/3 cover it.
2. Check-on-open: `Timeout.dailyMaintenance()` at the top of `ShieldManager.reconcileState()` (every foreground) and monitor `intervalDidStart`.
3. Shield self-heal: `ShieldActionExtension` runs the same check on every shield-button tap, then `.close`.
- `Timeout.completeTimeoutIfElapsed()` is the ONE completion path: deleting `timeoutEndTime` is the idempotency latch (credits `totalTimeoutMinutes` exactly once, then clears shields).

**Rules that look like bugs but aren't:**

- Monitor's `intervalDidEnd` does NOT clear shields when a future `timeoutEndTime` exists (R3: timeout overrides window end — verify-late-in-window case). Guard: `Timeout.shouldClearShieldAtWindowEnd()`.
- `ShieldManager.init` does NOT clear a verified-but-shielded state when a timeout is running — that's the intended state; clearing it would kill the timeout on relaunch.
- No same-day downgrade (R5): lowering the duration queues to `pendingTimeoutDuration`, promoted at daily maintenance next day. Increases apply immediately and cancel any queued downgrade.
- Daily reset is LAZY (no reset event exists): `Timeout.dailyMaintenance()` is idempotent and called from multiple processes.
- The timeout shield shows the ABSOLUTE end time ("Blocked until 8:32"), never a countdown — iOS may cache shield configs; a stale absolute time is still true.
- `timeoutEndTime` is always clamped to `min(proposed, WakeSchedule.nextWindowStart())` at write/extend time, so a Timeout can never collide with tomorrow's window.
- Debug emergency unlock mid-timeout must go through `ShieldManager.debugEmergencyUnlock()` (wipes timeout state WITHOUT crediting minutes) — plain `removeShield()` gets re-shielded by reconcile.

**Copy:** all Timeout strings live in `TimeoutCopy.swift` (pools by moment, random with no-immediate-repeat via App Group last-index keys — never hardcode Timeout copy in views). The user-facing frame: the APPS are in timeout, the user is not.

**Target membership (manual, in Xcode):** `Timeout.swift` → all four targets. `TimeoutCopy.swift` → Getupp + GetuppShield. `TimeoutCountdownView.swift` → Getupp only. Self-tests: `runTimeoutSelfTests()` in `Timeout.swift` (pure rules only), "Run Timeout Self-Tests" button in ContentView's debug Timeout section.

**Open items:** OQ1 (can the shield-action extension actually clear shields from its process? ~85% yes) — resolved by the layer-3 device test; if it fails, the button degrades to close-only and layers 1–2 carry it. Emergency Break is a separate spec; its entry point is a reserved slot on the countdown screen.

## Brand voice (for any user-facing copy)

The anti-Calm. The productivity/wellness space is pastel, meditative, whispery. GETUPP is the opposite: direct, confrontational, funny. Tough love, not therapy.
 
The cornerman, not the bully. The brand is brutally honest with you but fundamentally on your side — like a boxing cornerman or the older sibling who rips the blanket off. It roasts the behavior (scrolling, bed-rotting), never the person's worth.
 
Distrust as affection. The product literally demands photographic evidence. "Pics or it didn't happen" is the mechanic AND the attitude. The brand doesn't trust you at 7am, and says so, and that's the joke.
Funny-rude, never mean. Provocative, irreverent, self-aware. Humor is load-bearing.
 
Simple and honest. One job: get you out of bed. No feature bloat, no vague wellness promises.

## Separate concerns

André also runs a different product (Gaudi) under a separate entity. GETUPP is fully independent — never mix code, accounts, or business references between them.
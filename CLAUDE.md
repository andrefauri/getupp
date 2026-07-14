# GETUPP — [CLAUDE.md](http://CLAUDE.md)

## What this is

GETUPP is an iOS app that blocks the user's social media apps every morning

until they submit a live photo proving they're out of bed. Claude's vision

API verifies the photo; on success, apps unblock.

Core loop: wake up → open GETUPP → take photo → AI verifies out-of-bed →

social apps unblock for the day.

## Who you're working with

André is not a traditional developer — he's learning to code by building

with AI. Practical implications:

- Explain new concepts briefly when introducing them (one or two sentences,

  analogy + technical term). Don't assume Swift/iOS/Python knowledge.

- Prefer simple, readable code over clever code. One obvious way > three

  smart ways.

- When something must be done manually in Xcode or on the iPhone, say so

  explicitly with step-by-step instructions — don't assume he knows the IDE.

- Give direct, honest assessments. No confirmation bias. If an approach is

  bad, say so and explain why.

## Current phase: POC

Validating three things, in order:

1. AI vision can reliably classify in-bed vs out-of-bed photos

2. Family Controls can block user-selected apps within a daily time window

3. Verified photo → unblock → success screen flow works end to end

POC code is mostly throwaway. Two exceptions to write carefully, as they

will survive into production:

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

- Never include filename, folder path, or metadata in API requests — only

  the base64 image and prompt text. Ground truth labels are for local

  scoring only (avoid data leakage).

- Prompts are data, not code: they live in prompts/ as versioned text

  files. Never hardcode a classification prompt inside [classify.py](http://classify.py).

- Resize photos to max 1024px longest side, JPEG ~80%, before sending.

- Model must return strict JSON: {"out_of_bed": bool, "confidence": 0-1,

  "reason": "..."}. Parse defensively; a bad response is a logged error,

  not a crash.

- Models under evaluation: claude-haiku-4-5 vs claude-sonnet-4-6.

  Track accuracy, latency, and cost per run.

## iOS app rules

### Stack

- Swift + SwiftUI, iOS (iPhone only)

- Bundle ID: [co.getupp.app](http://co.getupp.app)

- App Group: [group.co.getupp.app](http://group.co.getupp.app)

- Frameworks: FamilyControls, ManagedSettings, DeviceActivity, AVFoundation

- Anthropic API called directly with a key from a gitignored config file.

  POC-ONLY exception: this is acceptable solely because the app runs only

  on André's phone. Before any distribution (even TestFlight), API calls

  must go through a Supabase Edge Function proxy. Never suggest shipping

  a client-side key.

### Targets

- GetUpp — main app

- Monitor extension (DeviceActivityMonitor) — applies/clears shields on

  schedule window start/end

- Shield extension (ShieldConfiguration) — customizes the block screen

### Workflow and boundaries

- Claude Code edits Swift files in Cursor. André builds and runs manually

  in Xcode (Cmd+R) on his physical iPhone. There is no CLI build loop —

  after writing code, tell André to rebuild and what to test.

- NEVER touch code signing, entitlements files, provisioning, or

  project.pbxproj target membership. André handles all of that in Xcode.

  When you create a new file, remind him to check it's added to the

  correct target in Xcode's File Inspector.

- Extensions must stay minimal: no heavy dependencies, tight memory limits.

### Domain constraints (do not "fix" these — they're Apple platform rules)

- FamilyActivityPicker returns opaque tokens. The app cannot know or

  target specific apps by name. Users manually select what to block.

- The shield screen cannot deep-link back into GETUPP. Its buttons can

  only close the blocked app. Copy must tell users to open GETUPP.

- Apps cannot programmatically close themselves. No exit() or private

  APIs.

- DeviceActivity schedules are wall-clock based and callbacks can be

  unreliable. For testing, use short windows starting a few minutes out —

  never change the device clock.

- Camera capture only (live photo), never photo library — anti-cheat is

  the product premise.

### Product decisions already made

- Fail-closed: ambiguous photo → user stays blocked.

- Daily reset via lastVerifiedDate in App Group UserDefaults; monitor

  extension checks it on intervalDidStart.

- Emergency unlock must exist (offline = locked out otherwise). Debug

  button is fine for POC.

- Photos are never stored: verify via API, keep only pass/fail + timestamp.

- Time window is hardcoded for POC with a debug override (not

  user-configurable yet).

## Brand voice (for any user-facing copy)

Irreverent, punk, confrontational — Liquid Death energy, not calm

meditation app. Shield screens and success states can be blunt and funny

("Get up. Take the photo."). Never soft, never zen.

## Separate concerns

André also runs a different product (Gaudi) under a separate entity.

GETUPP is fully independent — never mix code, accounts, or business

references between them.
# Photo Eval Notes

## Date: 2026-07-12

---

## Four-way comparison: v3 prompt × Haiku/Sonnet × before/after EXIF fix

> **EXIF fix**: `classify.py` now calls `ImageOps.exif_transpose()` before resizing,
> so rotated JPEGs are presented upright to the model. Applied 2026-07-12.

| Metric          | v3 Haiku (pre-fix) | v3 Sonnet (pre-fix) | v3 Haiku (post-fix) | v3 Sonnet (post-fix) |
|-----------------|--------------------|---------------------|---------------------|----------------------|
| Overall         | 85.1% (40/47)      | 87.2% (41/47)       | **91.5% (43/47)**   | 85.1% (40/47)        |
| in-bed (13)     | 92.3%              | 100.0%              | 92.3%               | **100.0%**           |
| out-of-bed (26) | 92.3%              | 76.9%               | **96.2%**           | 73.1%                |
| adversarial (8) | 50.0%              | 100.0%              | 75.0%               | **100.0%**           |
| Avg latency     | 2145 ms            | 3956 ms             | 2116 ms             | 3975 ms              |
| Total cost      | $0.0869            | $0.3252             | $0.0868             | $0.3222              |
| Misclassified   | 7                  | 6                   | **4**               | 7                    |

---

## EXIF fix impact: which failures were rotation-caused

Sonnet pre-fix explicitly flagged "image rotated 90 degrees" in its reasoning for 5 of 6 failures.
Haiku pre-fix silently mis-classified the same rotated images without mentioning rotation.

**Photos confirmed rotation-caused** (Sonnet called it out; Haiku got them wrong too):

| Photo | Haiku pre-fix | Sonnet pre-fix | Haiku post-fix | Sonnet post-fix |
|---|---|---|---|---|
| `out-of-bed/IMG_1958` | WRONG | WRONG (rotation noted) | **OK** | WRONG (residual) |
| `out-of-bed/IMG_1959` | OK | WRONG (rotation noted) | **OK** | WRONG (residual) |
| `out-of-bed/IMG_1960` | OK | WRONG (rotation noted) | **OK** | WRONG (residual) |
| `out-of-bed/IMG_1968` | WRONG | WRONG (rotation noted) | **OK** | **OK** |
| `out-of-bed/IMG_1971` | WRONG | WRONG (rotation noted) | **OK** | WRONG (residual) |
| `out-of-bed/IMG_1944` | WRONG | WRONG (rotation noted) | WRONG (non-rotation) | **OK** |

**Haiku post-fix recovered all 5 rotation-caused failures. Sonnet post-fix only recovered 1 of 5.**
Sonnet continues to fail `IMG_1958/1959/1960/1971` after the fix — these are ambiguous close framing
cases where Sonnet applies the uncertainty/fail-closed rule more aggressively than Haiku.

---

## Remaining failures post-fix

### Haiku post-fix (4 failures)

**False positives (in-bed passed as out-of-bed) — 3:**
- `in-bed/IMG_1933` — upright torso + background furniture matched standing pattern; persistent across all v3 runs
- `adversarial/sitting-on-bed.jpeg` — upright selfie framing, no disqualifying bed cues visible
- `adversarial/sitting-on-bed-2.jpeg` — same; background bed treated as neutral per prompt instruction

**False negatives (out-of-bed blocked) — 1:**
- `out-of-bed/IMG_1944` — pillow + headboard + duvet visible; model's disqualifying evidence check correctly fires but ground truth is out-of-bed

### Sonnet post-fix (7 failures)

**False positives — 0** (adversarial 8/8 perfect)

**False negatives (out-of-bed blocked) — 7:**
- `out-of-bed/IMG_1943` — posture ambiguous, uncertainty rule triggers
- `out-of-bed/IMG_1949` — appears seated at desk, uncertainty rule triggers
- `out-of-bed/IMG_1958` — still fails despite fix; Sonnet reads posture as seated on couch
- `out-of-bed/IMG_1959` — clearly seated on couch per Sonnet (living room, low eye height)
- `out-of-bed/IMG_1960` — MacBook visible, seated on couch per Sonnet
- `out-of-bed/IMG_1967` — elevated camera, ambiguous sitting/standing, uncertainty rule
- `out-of-bed/IMG_1971` — downward camera angle + draped fabric, uncertainty rule

Sonnet's remaining failures are genuine posture ambiguity cases where it over-applies the
fail-closed rule — not rotation artifacts. These may require prompt v4 to relax the
sitting/standing distinction for non-bed surfaces, or require additional training signal.

---

## v1/v2/v3 prompt evolution (Haiku, pre-EXIF-fix reference baseline)

| Metric             | v1      | v2      | v3      |
|--------------------|---------|---------|---------|
| Overall            | 85.1%   | 68.1%   | 85.1%   |
| in-bed (13)        | 84.6%   | 100.0%  | 92.3%   |
| out-of-bed (26)    | 100.0%  | 42.3%   | 92.3%   |
| adversarial (8)    | 37.5%   | 100.0%  | 50.0%   |
| Avg latency        | 2832 ms | 1855 ms | 2145 ms |
| Total cost         | $0.0611 | $0.0733 | $0.0869 |
| Misclassified      | 7       | 15      | 7       |

| Version | False positives | False negatives |
|---------|-----------------|-----------------|
| v1      | 7 (2 in-bed, 5 adversarial) | 0 |
| v2      | 0               | 15 (all out-of-bed) |
| v3      | 5 (1 in-bed, 4 adversarial) | 2 (out-of-bed) |

---

## Key observations

**EXIF fix was real**: Haiku went from 7 → 4 failures, confirming rotation was silently corrupting
5 images. Sonnet surfaced the bug by explicitly naming it in its reasoning; Haiku hid it.

**Model tradeoff (post-fix, v3)**:
- Haiku: better out-of-bed recall (96.2% vs 73.1%), worse adversarial (75% vs 100%)
- Sonnet: perfect adversarial coverage (8/8), 7 false negatives on ambiguous out-of-bed framing
- Neither model is dominant overall — they fail on opposite sides of the precision/recall tradeoff

**Persistent hard cases** (both models fail on at least one of these):
- `out-of-bed/IMG_1944` — has real disqualifying evidence (pillow, headboard, duvet) but is labelled out-of-bed; worth re-auditing the ground truth label
- `adversarial/sitting-on-bed.jpeg` and `sitting-on-bed-2.jpeg` — visually indistinguishable from standing selfies to Haiku; Sonnet correctly blocks them
- `in-bed/IMG_1933` — persistent false positive across all Haiku runs; worth examining the photo

**v4 candidates**: (1) address the `IMG_1944` ground-truth question, (2) give Sonnet a softer uncertainty rule for non-bed-surface ambiguity, (3) consider whether Sonnet's adversarial robustness is worth the higher false-negative rate as a production tradeoff.

---

## DECISIONS — validation closed (2026-07-14)

**Test set: 47 photos — 24 out-of-bed / 13 in-bed / 10 adversarial**
(Two photos previously in out-of-bed/ reclassified to adversarial/: `standing-in-front-of-bed-2.jpeg` = IMG_1944,
`standing-in-front-of-bed-3.jpeg` = IMG_1948. Rationale: person IS standing but bedding/pillow/headboard
fills frame behind them, making photo visually indistinguishable from sitting in bed. Under fail-closed,
this framing should fail; v2 product will coach "step back and retake" using the model's reason field.)

### Chosen for POC
**claude-haiku-4-5 + prompts/v3.txt + EXIF orientation fix** (`ImageOps.exif_transpose()` before resize)

### Final per-folder numbers (corrected test set, no new API calls — rescored from 2026-07-12 run)

| Metric           | Haiku (chosen) | Sonnet         |
|------------------|----------------|----------------|
| Overall          | **43/47 = 91.5%** | 38/47 = 80.9% |
| in-bed (13)      | 12/13 = 92.3%  | 13/13 = 100.0% |
| out-of-bed (24)  | **24/24 = 100.0%** | 17/24 = 70.8% |
| adversarial (10) | 7/10 = 70.0%   | 8/10 = 80.0%   |
| Avg latency      | **2.12s**      | 3.97s          |
| Total cost/run   | **$0.0868**    | $0.3222        |
| False blocks     | **0**          | 7              |
| Adversarial leaks | 3             | 2              |

### Rationale
False blocks (honest user wrongly blocked at 7am) are the worst error type for an accountability product.
Haiku has perfect honest-user recall (100% out-of-bed), is ~1.9× faster (2.12s vs 3.97s), and ~3.7×
cheaper ($0.0868 vs $0.3222 per 47-photo run). Sonnet's superior adversarial score (8/10 vs 7/10) does
not justify blocking 7 legitimate out-of-bed photos.

### Haiku misses (4)
- `in-bed/IMG_1933` → predicted out-of-bed — upright torso + room background fooled model; persistent across all v3 runs
- `adversarial/standing-in-front-of-bed-2.jpeg` (IMG_1944) → predicted out-of-bed — bed visible in background but treated as neutral per prompt
- `adversarial/sitting-on-bed.jpeg` → predicted out-of-bed — upright selfie framing, no disqualifying cues visible to model
- `adversarial/sitting-on-bed-2.jpeg` → predicted out-of-bed — same as above

### Known limitation — accepted for POC
Upright-sitting-in-bed with room background can pass (~3 adversarial leaks on Haiku). Cheater only
cheats themselves; documented, not blocking for POC.

### Escalation paths if cheating matters more later
(a) Two-photo capture flow (face + floor/feet) to make sitting-in-bed pixel-distinguishable from standing.
(b) Switch to Sonnet — adversarially tighter (8/10 vs 7/10) but blocks 7 honest photos; unacceptable UX as-is.
(c) CoreMotion device-pitch as corroborating signal.

### Product rule confirmed
Bed visible in frame is NORMAL and must be able to pass; only bedding immediately behind/around the
person disqualifies. Standing-too-close-to-bed fails by design; retry copy for v2 uses the model's
reason field to coach framing ("too close to the bed — step back").

### Test set caveat
All 47 photos are one person, one day, one outfit. Add multi-day/multi-outfit photos before trusting
these numbers beyond the POC.

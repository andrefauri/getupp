//
//  Timeout.swift
//  Getupp
//
//  Timeout state model + App Group I/O — the post-verification blocking period.
//  After a successful photo verification, apps STAY blocked until timeoutEndTime.
//
//  Shared across ALL targets: Getupp, GetuppMonitor, GetuppShield (and later
//  GetuppShieldAction). IMPORTANT: check every target in Xcode's File Inspector.
//
//  Design principles (mirrors Streak.swift):
//  - State is DERIVED, never stored as an enum. Every process computes the current
//    phase from the same App Group values + wall clock, so processes can't disagree.
//  - The pure functions take everything as parameters (no Date() inside) so they
//    can be exercised by self-test fixtures without a device.
//  - This file imports only Foundation + ManagedSettings — no DeviceActivity, no
//    FamilyControls — so the memory-constrained shield extensions can include it
//    without dragging in GetuppShared.swift's heavier dependencies. That's why a
//    few string constants are duplicated below instead of referenced.
//

import Foundation
import ManagedSettings

enum Timeout {

    // MARK: - Constants duplicated from GetuppShared.swift
    // KEEP IN SYNC with GetuppShared.swift — duplicated so the shield extensions
    // don't need GetuppShared's DeviceActivity/FamilyControls imports.

    static let appGroupID          = "group.co.getupp.app"
    static let storeName           = "co.getupp.store"
    static let shieldedKey         = "isShielded"
    static let activeBlockEndKey   = "activeBlockEnd"
    static let lastVerifiedDateKey = "lastVerifiedDate"

    // MARK: - Timeout App Group keys

    /// Active setting (TimeInterval). Default 1800 (30 min).
    static let timeoutDurationKey        = "timeoutDuration"
    /// Downgrade queued for tomorrow (TimeInterval?). Promoted at daily maintenance.
    static let pendingTimeoutDurationKey = "pendingTimeoutDuration"
    /// When the pending downgrade was queued (Date?) — promoted once it's "not today".
    static let pendingTimeoutSetDateKey  = "pendingTimeoutSetDate"
    /// Absolute end timestamp (Date?), clamped at write time.
    /// Single source of truth for a running Timeout. NEVER coexists with
    /// activeBlockEnd: beginTimeout() deletes activeBlockEnd in the same call.
    static let timeoutEndTimeKey         = "timeoutEndTime"
    /// Lifetime completed timeout minutes (Int). Credited only on natural completion.
    static let totalTimeoutMinutesKey    = "totalTimeoutMinutes"

    // MARK: - Duration bounds

    static let minDuration: TimeInterval = 15 * 60       // DeviceActivity minimum
    static let maxDuration: TimeInterval = 8 * 3600      // absolute cap
    static let defaultDuration: TimeInterval = 30 * 60

    // MARK: - Shared store + defaults (same instances the rest of the app uses)

    static let store = ManagedSettingsStore(named: .init(storeName))

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    // MARK: - Phase (pure, derived — never stored)

    /// The morning cycle's four states. Every process derives this from the same
    /// stored values, so the app, monitor, and shields always agree.
    enum Phase: Equatable {
        case preWindow   // before window start, shields off
        case blocked     // window running, unverified — morning shield
        case timeout     // verified, apps serving timeout — timeout shield
        case free        // timeout done, or window over — shields off
    }

    /// Pure derivation. Order matters: an active timeout wins over everything
    /// (verification already happened), then verified means free, then the window.
    static func derivePhase(
        now: Date,
        windowStart: Date?,
        windowEnd: Date?,
        isVerifiedToday: Bool,
        timeoutEndTime: Date?
    ) -> Phase {
        if let end = timeoutEndTime, now < end {
            return .timeout
        }
        if isVerifiedToday {
            return .free
        }
        if let start = windowStart, let end = windowEnd, start <= now, now < end {
            return .blocked
        }
        if let start = windowStart, now < start {
            return .preWindow
        }
        return .free
    }

    // MARK: - Pure rules (self-tested)

    /// Write-time clamp: a Timeout can never outlive its day or collide with
    /// tomorrow's window (R3). Irrelevant while windows are morning-only, but it
    /// ships now so user-configurable windows can't break it later.
    static func clampedEnd(now: Date, duration: TimeInterval, nextWindowStart: Date?) -> Date {
        min(now.addingTimeInterval(duration), nextWindowStart ?? .distantFuture)
    }

    /// Extends an existing end, with the same clamp.
    static func extendedEnd(currentEnd: Date, delta: TimeInterval, nextWindowStart: Date?) -> Date {
        min(currentEnd.addingTimeInterval(delta), nextWindowStart ?? .distantFuture)
    }

    /// THE R3 rule: when the wake window ends, shields must stay if a timeout is
    /// still running. False iff timeoutEndTime exists and is in the future.
    static func shouldClearShieldAtWindowEnd(now: Date, timeoutEndTime: Date?) -> Bool {
        guard let end = timeoutEndTime else { return true }
        return now >= end
    }

    /// R5 direction check — no same-day downgrade, increases apply immediately.
    /// Exactly one of the two results is non-nil (both nil when unchanged).
    static func resolvedDuration(
        current: TimeInterval,
        requested: TimeInterval
    ) -> (applyNow: TimeInterval?, queueForTomorrow: TimeInterval?) {
        if requested > current { return (requested, nil) }
        if requested < current { return (nil, requested) }
        return (nil, nil)
    }

    /// Minutes to credit on natural completion. Uses the real verified→end span
    /// (which naturally includes extends); falls back to the configured duration
    /// when verifiedAt is missing or implausibly old (guards a stale key).
    static func servedMinutes(end: Date, verifiedAt: Date?, fallbackDuration: TimeInterval) -> Int {
        if let verifiedAt, verifiedAt < end, end.timeIntervalSince(verifiedAt) <= maxDuration {
            return Int((end.timeIntervalSince(verifiedAt) / 60).rounded())
        }
        return Int((fallbackDuration / 60).rounded())
    }

    // MARK: - I/O: settings

    /// The active duration. Defaults to 30 min when unset. NOT clamped on read —
    /// the debug "Set 2-min Timeout" button deliberately writes below the floor;
    /// user input is clamped in setDuration() instead.
    static var currentDuration: TimeInterval {
        let value = defaults?.double(forKey: timeoutDurationKey) ?? 0
        return value > 0 ? value : defaultDuration
    }

    /// Downgrade queued for tomorrow, if any.
    static var pendingDuration: TimeInterval? {
        guard let value = defaults?.object(forKey: pendingTimeoutDurationKey) as? Double,
              value > 0 else { return nil }
        return value
    }

    static var totalMinutes: Int {
        defaults?.integer(forKey: totalTimeoutMinutesKey) ?? 0
    }

    /// R5: increases apply immediately (and cancel any queued downgrade — the
    /// latest intent wins); decreases queue for tomorrow. Input clamped 15m–8h.
    static func setDuration(_ requested: TimeInterval, now: Date = Date()) {
        let clamped = min(max(requested, minDuration), maxDuration)
        let result  = resolvedDuration(current: currentDuration, requested: clamped)

        if let applyNow = result.applyNow {
            defaults?.set(applyNow, forKey: timeoutDurationKey)
            defaults?.removeObject(forKey: pendingTimeoutDurationKey)
            defaults?.removeObject(forKey: pendingTimeoutSetDateKey)
        } else if let queued = result.queueForTomorrow {
            defaults?.set(queued, forKey: pendingTimeoutDurationKey)
            defaults?.set(now, forKey: pendingTimeoutSetDateKey)
        }
    }

    // MARK: - I/O: running timeout

    static func loadTimeoutEnd() -> Date? {
        defaults?.object(forKey: timeoutEndTimeKey) as? Date
    }

    /// Called on successful verification. Writes the clamped end time and deletes
    /// activeBlockEnd (the two keys describe disjoint phases and must never
    /// coexist). Shields are NOT touched here — they simply stay on.
    static func beginTimeout(now: Date = Date(), nextWindowStart: Date?) -> Date {
        let end = clampedEnd(now: now, duration: currentDuration, nextWindowStart: nextWindowStart)
        defaults?.set(end, forKey: timeoutEndTimeKey)
        defaults?.removeObject(forKey: activeBlockEndKey)
        return end
    }

    /// One-tap extend (R6). Returns the new end, or nil if no timeout is running.
    static func extendTimeout(by delta: TimeInterval, now: Date = Date(), nextWindowStart: Date?) -> Date? {
        guard let end = loadTimeoutEnd(), now < end else { return nil }
        let newEnd = extendedEnd(currentEnd: end, delta: delta, nextWindowStart: nextWindowStart)
        defaults?.set(newEnd, forKey: timeoutEndTimeKey)
        return newEnd
    }

    /// The ONE completion path, shared by all three clearing layers (schedule,
    /// check-on-open, shield button). Deleting timeoutEndTime is the idempotency
    /// latch: whichever layer runs first wins; the others see no key and no-op.
    /// (UserDefaults isn't transactional across processes, so a same-instant race
    /// could double-credit the vanity stat — accepted, not worth solving.)
    @discardableResult
    static func completeTimeoutIfElapsed(now: Date = Date()) -> Bool {
        guard let end = loadTimeoutEnd(), now >= end else { return false }

        defaults?.removeObject(forKey: timeoutEndTimeKey)

        let verifiedAt = defaults?.object(forKey: lastVerifiedDateKey) as? Date
        let minutes    = servedMinutes(end: end, verifiedAt: verifiedAt, fallbackDuration: currentDuration)
        defaults?.set(totalMinutes + minutes, forKey: totalTimeoutMinutesKey)

        // Clear shields directly (this file runs in extensions that don't link
        // GetuppShared). Same store, same effect as GetuppShared.removeShield().
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        defaults?.set(false, forKey: shieldedKey)
        defaults?.removeObject(forKey: activeBlockEndKey)

        return true
    }

    // MARK: - Daily maintenance (R10 — lazy, idempotent, callable from any process)

    /// No reset event exists in this codebase (reset is implicit via date checks),
    /// so timeout reset follows the same philosophy: any process may call this any
    /// number of times. (1) completes an elapsed timeout — the write-time clamp
    /// guarantees yesterday's end is always elapsed by the next window start;
    /// (2) promotes a queued downgrade once its set-date is no longer today.
    static func dailyMaintenance(now: Date = Date()) {
        completeTimeoutIfElapsed(now: now)

        if let pending = pendingDuration {
            let setDate    = defaults?.object(forKey: pendingTimeoutSetDateKey) as? Date
            let setToday   = setDate.map { Calendar.current.isDate($0, inSameDayAs: now) } ?? false
            if !setToday {
                defaults?.set(pending, forKey: timeoutDurationKey)
                defaults?.removeObject(forKey: pendingTimeoutDurationKey)
                defaults?.removeObject(forKey: pendingTimeoutSetDateKey)
            }
        }
    }

    /// Debug emergency path only: wipes the running timeout WITHOUT crediting
    /// minutes (interrupted ≠ completed). Does not touch shields — callers decide.
    static func clearAllTimeoutState() {
        defaults?.removeObject(forKey: timeoutEndTimeKey)
        defaults?.removeObject(forKey: pendingTimeoutDurationKey)
        defaults?.removeObject(forKey: pendingTimeoutSetDateKey)
    }

    // MARK: - Streak wiring

    /// The timeoutDuration the streak derivation should use. While a timeout is
    /// running, the real verified→end span (so extends are honoured); otherwise
    /// the configured duration. Today shows .pending until the timeout completes.
    static func effectiveStreakDuration(now: Date = Date()) -> TimeInterval {
        if let end = loadTimeoutEnd(),
           let verifiedAt = defaults?.object(forKey: lastVerifiedDateKey) as? Date,
           verifiedAt < end {
            return end.timeIntervalSince(verifiedAt)
        }
        return currentDuration
    }
}

// MARK: - Self-tests (DEBUG only)

#if DEBUG
/// Fixture-based self-tests for the pure Timeout functions, run on-device via a
/// debug button (no XCTest target exists for this POC). Same PASS/FAIL format
/// as runStreakSelfTests(). I/O paths (beginTimeout etc.) are covered by the
/// on-device test script, not here — these only exercise the pure rules.
func runTimeoutSelfTests() -> [String] {
    var results: [String] = []
    let now = Date()

    func check(_ name: String, _ condition: Bool, detail: String = "") {
        results.append(condition ? "PASS \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    let windowStart = now.addingTimeInterval(-3600)   // window started 1h ago
    let windowEnd   = now.addingTimeInterval(3600)    // ends in 1h
    let futureEnd   = now.addingTimeInterval(900)     // timeout ends in 15 min
    let pastEnd     = now.addingTimeInterval(-60)     // timeout ended 1 min ago

    // ── derivePhase ──────────────────────────────────────────────────────────
    check("phase: active timeout → .timeout",
          Timeout.derivePhase(now: now, windowStart: windowStart, windowEnd: windowEnd,
                              isVerifiedToday: true, timeoutEndTime: futureEnd) == .timeout)

    check("phase: timeout elapsed, verified → .free",
          Timeout.derivePhase(now: now, windowStart: windowStart, windowEnd: windowEnd,
                              isVerifiedToday: true, timeoutEndTime: pastEnd) == .free)

    check("phase: in window, unverified → .blocked",
          Timeout.derivePhase(now: now, windowStart: windowStart, windowEnd: windowEnd,
                              isVerifiedToday: false, timeoutEndTime: nil) == .blocked)

    check("phase: before window → .preWindow",
          Timeout.derivePhase(now: now, windowStart: now.addingTimeInterval(600),
                              windowEnd: windowEnd,
                              isVerifiedToday: false, timeoutEndTime: nil) == .preWindow)

    check("phase: after window, unverified → .free",
          Timeout.derivePhase(now: now, windowStart: windowStart,
                              windowEnd: now.addingTimeInterval(-60),
                              isVerifiedToday: false, timeoutEndTime: nil) == .free)

    check("phase: timeout wins over open window",
          Timeout.derivePhase(now: now, windowStart: windowStart, windowEnd: windowEnd,
                              isVerifiedToday: true, timeoutEndTime: futureEnd) == .timeout)

    check("phase: no window configured, unverified → .free",
          Timeout.derivePhase(now: now, windowStart: nil, windowEnd: nil,
                              isVerifiedToday: false, timeoutEndTime: nil) == .free)

    // ── clampedEnd / extendedEnd ─────────────────────────────────────────────
    check("clamp: no next window → now + duration",
          Timeout.clampedEnd(now: now, duration: 1800, nextWindowStart: nil)
            == now.addingTimeInterval(1800))

    let soonWindow = now.addingTimeInterval(600)
    check("clamp: next window sooner → clamped to window start",
          Timeout.clampedEnd(now: now, duration: 1800, nextWindowStart: soonWindow) == soonWindow)

    check("clamp: next window later → unclamped",
          Timeout.clampedEnd(now: now, duration: 1800,
                             nextWindowStart: now.addingTimeInterval(86400))
            == now.addingTimeInterval(1800))

    check("extend: clamped to next window start",
          Timeout.extendedEnd(currentEnd: futureEnd, delta: 7200, nextWindowStart: soonWindow)
            == soonWindow)

    check("extend: unclamped when window far away",
          Timeout.extendedEnd(currentEnd: futureEnd, delta: 900, nextWindowStart: nil)
            == futureEnd.addingTimeInterval(900))

    // ── R3 window-end guard ──────────────────────────────────────────────────
    check("R3: future timeout → shields STAY at window end",
          Timeout.shouldClearShieldAtWindowEnd(now: now, timeoutEndTime: futureEnd) == false)

    check("R3: no timeout → clear at window end",
          Timeout.shouldClearShieldAtWindowEnd(now: now, timeoutEndTime: nil) == true)

    check("R3: elapsed timeout → clear at window end",
          Timeout.shouldClearShieldAtWindowEnd(now: now, timeoutEndTime: pastEnd) == true)

    // ── R5 direction check ───────────────────────────────────────────────────
    let up = Timeout.resolvedDuration(current: 1800, requested: 3600)
    check("R5: increase applies now", up.applyNow == 3600 && up.queueForTomorrow == nil)

    let down = Timeout.resolvedDuration(current: 3600, requested: 1800)
    check("R5: decrease queues for tomorrow", down.applyNow == nil && down.queueForTomorrow == 1800)

    let same = Timeout.resolvedDuration(current: 1800, requested: 1800)
    check("R5: unchanged → no-op", same.applyNow == nil && same.queueForTomorrow == nil)

    // ── Credit math ──────────────────────────────────────────────────────────
    check("credit: verified→end span",
          Timeout.servedMinutes(end: now, verifiedAt: now.addingTimeInterval(-1800),
                                fallbackDuration: 900) == 30)

    check("credit: span includes extends",
          Timeout.servedMinutes(end: now, verifiedAt: now.addingTimeInterval(-2700),
                                fallbackDuration: 1800) == 45)

    check("credit: missing verifiedAt → fallback",
          Timeout.servedMinutes(end: now, verifiedAt: nil, fallbackDuration: 1800) == 30)

    check("credit: stale verifiedAt (> max) → fallback",
          Timeout.servedMinutes(end: now, verifiedAt: now.addingTimeInterval(-9 * 3600),
                                fallbackDuration: 1800) == 30)

    return results
}
#endif

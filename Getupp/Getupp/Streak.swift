//
//  Streak.swift
//  Getupp
//
//  Streak data model + pure derivation logic.
//  Shared between the main app and the Monitor extension.
//  IMPORTANT: Add to BOTH targets in Xcode's File Inspector (main app + GetuppMonitor).
//
//  Design principle: the streak is NEVER stored as a counter. Counters mutated by
//  unreliable DeviceActivity callbacks corrupt silently and can't be reconstructed.
//  Instead we keep an append-only log of DayRecords and derive the streak on read.
//
//  deriveStreak() is pure — no I/O, no singletons, no Date() calls inside. Everything
//  it needs is injected, so it can be exercised by synthetic fixtures with no device.
//

import Foundation

// MARK: - Day record

/// One entry per local calendar date. First write wins for a given `date` —
/// duplicate dates are ignored so timezone travel never double-counts a day.
struct DayRecord: Codable {
    let date: String          // local calendar date, "yyyy-MM-dd"
    var wasScheduled: Bool    // snapshotted at window start / first open that day
    var sessionRan: Bool      // set by the Monitor extension on intervalDidStart
    var verified: Bool        // set by the main app on successful photo verification
    var verifiedAt: Date?
    var emergencyUsed: Bool   // set by the main app when the emergency break is confirmed
    var emergencyAt: Date?

    /// A fresh record for `date`, as written the first time a day is touched.
    static func fresh(date: String, wasScheduled: Bool) -> DayRecord {
        DayRecord(
            date: date,
            wasScheduled: wasScheduled,
            sessionRan: false,
            verified: false,
            verifiedAt: nil,
            emergencyUsed: false,
            emergencyAt: nil
        )
    }
}

// MARK: - Day state

enum DayState: Equatable {
    case success   // scheduled session ran (or verified), no emergency break
    case broken    // emergency break used, or app disabled while streak active
    case neutral   // scheduled, but session never ran — system's fault, not the user's
    case rest      // not scheduled that day
    case pending   // today, window not yet resolved
}

// MARK: - Result

struct StreakResult {
    let count: Int              // consecutive successful mornings
    let todayState: DayState

    static let zero = StreakResult(count: 0, todayState: .neutral)
}

// MARK: - Derivation

/// Pure function: derives the current streak from the day log.
/// - Parameters:
///   - records: the full day log, any order.
///   - today: local calendar date "yyyy-MM-dd" for "now".
///   - now: the current instant.
///   - windowEnd: today's wake-window end time.
///   - timeoutDuration: buffer length after verification during which an emergency
///     break can still occur. POC ships this as 0 (instant +1 on verification) —
///     the parameter exists so the future emergency/buffer feature is a derivation
///     change, not a data migration.
///   - appEnabled: whether GETUPP is currently enabled. POC always passes `true`
///     (disable-breaks-streak is not wired yet).
///   - activeSessionDate: R6 — the "yyyy-MM-dd" day of a still-open session
///     (window started, not yet finalized). While set for a PAST date (a timeout
///     running across midnight), that date is held .pending regardless of its
///     record — no premature +1, no break. Clearing the key finalizes the day.
func deriveStreak(
    records: [DayRecord],
    today: String,
    now: Date,
    windowEnd: Date,
    timeoutDuration: TimeInterval,
    appEnabled: Bool,
    activeSessionDate: String? = nil
) -> StreakResult {
    guard appEnabled else {
        return StreakResult(count: 0, todayState: resolveTodayState(
            records: records, today: today, now: now,
            windowEnd: windowEnd, timeoutDuration: timeoutDuration
        ))
    }

    // Index by date; first record for a date wins (defensive — callers should
    // already dedupe on write, but the derivation stays correct either way).
    var byDate: [String: DayRecord] = [:]
    for record in records where byDate[record.date] == nil {
        byDate[record.date] = record
    }

    let todayState = resolveTodayState(
        records: records, today: today, now: now,
        windowEnd: windowEnd, timeoutDuration: timeoutDuration
    )

    // Walk backwards one calendar day at a time from today, skipping rest/neutral/
    // pending, counting consecutive successes, stopping at the first broken day.
    let calendar = Calendar.current
    guard let todayDate = dayFormatter.date(from: today) else {
        return StreakResult(count: 0, todayState: todayState)
    }

    var count = 0
    var cursorDate = todayDate
    var cursorKey = today
    var isToday = true

    // Guard against runaway loops on a corrupt/huge log.
    var daysWalked = 0
    let maxDaysToWalk = 3650 // 10 years — generous upper bound for a POC log

    while daysWalked < maxDaysToWalk {
        daysWalked += 1

        let state: DayState
        if isToday {
            state = todayState
        } else if cursorKey == activeSessionDate {
            // R6: this past day's session is still open (cross-midnight timeout
            // running). Hold it pending — skip, don't count, don't break — until
            // the latch clears and its record resolves from data on disk.
            state = .pending
        } else if let record = byDate[cursorKey] {
            state = resolvePastState(record)
        } else {
            // No record for a past date. Only counts as neutral if there's any
            // earlier history — an empty log (fresh install) has no opinion on
            // dates before the log begins, so we stop rather than walking forever.
            if byDate.isEmpty {
                break
            }
            state = .neutral
        }

        switch state {
        case .success:
            count += 1
        case .broken:
            return StreakResult(count: count, todayState: todayState)
        case .neutral, .rest, .pending:
            break // skip — no increment, no break
        }

        // Stop once we've walked past the earliest record in the log; there's
        // nothing further back to resolve.
        if let earliest = byDate.keys.min(), cursorKey <= earliest, !isToday {
            break
        }

        isToday = false
        guard let previousDate = calendar.date(byAdding: .day, value: -1, to: cursorDate) else {
            break
        }
        cursorDate = previousDate
        cursorKey = dayFormatter.string(from: previousDate)
    }

    return StreakResult(count: count, todayState: todayState)
}

/// Resolves a past (non-today) record to a DayState.
private func resolvePastState(_ record: DayRecord) -> DayState {
    if record.emergencyUsed {
        return .broken
    }
    guard record.wasScheduled else {
        return .rest
    }
    if record.sessionRan || record.verified {
        return .success
    }
    return .neutral
}

/// Resolves today's state per the spec's rules:
/// emergency -> broken; verified and timeout elapsed -> success;
/// verified but timeout still running -> pending;
/// not verified and window still open -> pending;
/// otherwise (window closed, session ran, no emergency) -> success or neutral.
private func resolveTodayState(
    records: [DayRecord],
    today: String,
    now: Date,
    windowEnd: Date,
    timeoutDuration: TimeInterval
) -> DayState {
    guard let record = records.first(where: { $0.date == today }) else {
        // No record yet today. If the window has already closed with nothing
        // recorded, today resolves neutral; otherwise it's still pending.
        return now < windowEnd ? .pending : .neutral
    }

    if record.emergencyUsed {
        return .broken
    }

    guard record.wasScheduled else {
        return .rest
    }

    if record.verified {
        if let verifiedAt = record.verifiedAt {
            return now >= verifiedAt.addingTimeInterval(timeoutDuration) ? .success : .pending
        }
        return .success
    }

    if now < windowEnd {
        return .pending
    }

    return record.sessionRan ? .success : .neutral
}

// MARK: - Shared date formatting

/// Fixed-format, non-lenient formatter for local calendar dates ("yyyy-MM-dd").
/// Shared so app, extension, and derivation all key records identically.
let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    return formatter
}()

// MARK: - Self-tests (DEBUG only)

#if DEBUG
/// Fixture-based self-tests for deriveStreak(), run on-device via a debug button
/// (no XCTest target exists for this POC). Returns one line per fixture:
/// "PASS name" or "FAIL name — expected X/state, got Y/state".
func runStreakSelfTests() -> [String] {
    var results: [String] = []
    let calendar = Calendar.current
    let now = Date()

    func daysAgoString(_ n: Int, from date: Date = now) -> String {
        let d = calendar.date(byAdding: .day, value: -n, to: date) ?? date
        return dayFormatter.string(from: d)
    }

    func successRecord(daysAgo: Int, wasScheduled: Bool = true) -> DayRecord {
        var r = DayRecord.fresh(date: daysAgoString(daysAgo), wasScheduled: wasScheduled)
        r.sessionRan = true
        return r
    }

    func restRecord(daysAgo: Int) -> DayRecord {
        DayRecord.fresh(date: daysAgoString(daysAgo), wasScheduled: false)
    }

    func brokenRecord(daysAgo: Int) -> DayRecord {
        var r = DayRecord.fresh(date: daysAgoString(daysAgo), wasScheduled: true)
        r.emergencyUsed = true
        r.emergencyAt = calendar.date(byAdding: .day, value: -daysAgo, to: now)
        return r
    }

    func check(
        _ name: String,
        records: [DayRecord],
        windowEnd: Date,
        timeoutDuration: TimeInterval = 0,
        appEnabled: Bool = true,
        activeSessionDate: String? = nil,
        expectedCount: Int,
        expectedState: DayState
    ) {
        let result = deriveStreak(
            records: records,
            today: dayFormatter.string(from: now),
            now: now,
            windowEnd: windowEnd,
            timeoutDuration: timeoutDuration,
            appEnabled: appEnabled,
            activeSessionDate: activeSessionDate
        )
        let pass = result.count == expectedCount && result.todayState == expectedState
        if pass {
            results.append("PASS \(name)")
        } else {
            results.append("FAIL \(name) — expected \(expectedCount)/\(expectedState), got \(result.count)/\(result.todayState)")
        }
    }

    let windowOpen   = now.addingTimeInterval(3600)   // window still open
    let windowClosed = now.addingTimeInterval(-3600)  // window already closed

    // 1. Fresh install, window still open -> pending, count 0.
    check("fresh install, window open",
          records: [], windowEnd: windowOpen,
          expectedCount: 0, expectedState: .pending)

    // 2. Fresh install, window closed, nothing recorded -> neutral, count 0.
    check("fresh install, window closed",
          records: [], windowEnd: windowClosed,
          expectedCount: 0, expectedState: .neutral)

    // 3. N consecutive successes (5 mornings incl. today).
    check("5 consecutive successes",
          records: (0...4).map { successRecord(daysAgo: $0) },
          windowEnd: windowClosed,
          expectedCount: 5, expectedState: .success)

    // 4. Emergency mid-streak stops the count immediately (older successes don't count).
    check("emergency mid-streak",
          records: [successRecord(daysAgo: 0), brokenRecord(daysAgo: 1), successRecord(daysAgo: 2)],
          windowEnd: windowClosed,
          expectedCount: 1, expectedState: .success)

    // 5. Emergency during timeout: verified today, then emergency used -> broken, count 0.
    var verifiedThenBroken = DayRecord.fresh(date: dayFormatter.string(from: now), wasScheduled: true)
    verifiedThenBroken.verified = true
    verifiedThenBroken.verifiedAt = now.addingTimeInterval(-600)
    verifiedThenBroken.emergencyUsed = true
    check("emergency during timeout (verified then broken)",
          records: [verifiedThenBroken],
          windowEnd: windowOpen, timeoutDuration: 1800,
          expectedCount: 0, expectedState: .broken)

    // 6. Neutral day inside a streak — streak survives the gap.
    check("neutral day survives inside streak",
          records: [successRecord(daysAgo: 0), successRecord(daysAgo: 2)], // day -1 missing
          windowEnd: windowClosed,
          expectedCount: 2, expectedState: .success)

    // 7. Rest days interleaved: Mon-Fri schedule, Mon->Mon = 5 mornings.
    //    (today = Fri, 5 scheduled successes, preceding weekend rest days present.)
    var restWeekRecords: [DayRecord] = (0...4).map { successRecord(daysAgo: $0) } // Fri..Mon
    restWeekRecords.append(restRecord(daysAgo: 5)) // Sun
    restWeekRecords.append(restRecord(daysAgo: 6)) // Sat
    check("Mon-Fri schedule, Mon->Fri = 5 mornings",
          records: restWeekRecords, windowEnd: windowClosed,
          expectedCount: 5, expectedState: .success)

    // 8. Today pending: window still open, not verified.
    check("today pending — window open, unverified",
          records: [DayRecord.fresh(date: dayFormatter.string(from: now), wasScheduled: true)],
          windowEnd: windowOpen,
          expectedCount: 0, expectedState: .pending)

    // 9. Today verified, timeout still running -> pending (no instant +1 when a
    //    non-zero timeout is configured — exercises the future emergency feature).
    var verifiedTimeoutRunning = DayRecord.fresh(date: dayFormatter.string(from: now), wasScheduled: true)
    verifiedTimeoutRunning.verified = true
    verifiedTimeoutRunning.verifiedAt = now.addingTimeInterval(-60)
    check("today verified, timeout running -> pending",
          records: [verifiedTimeoutRunning],
          windowEnd: windowOpen, timeoutDuration: 1800,
          expectedCount: 0, expectedState: .pending)

    // 10. Today verified, timeout elapsed -> success (+1).
    var verifiedTimeoutElapsed = DayRecord.fresh(date: dayFormatter.string(from: now), wasScheduled: true)
    verifiedTimeoutElapsed.verified = true
    verifiedTimeoutElapsed.verifiedAt = now.addingTimeInterval(-3600)
    check("today verified, timeout elapsed -> success",
          records: [verifiedTimeoutElapsed],
          windowEnd: windowOpen, timeoutDuration: 1800,
          expectedCount: 1, expectedState: .success)

    // 11. POC reality: instant +1 (timeoutDuration = 0) the moment verified is set.
    var verifiedInstant = DayRecord.fresh(date: dayFormatter.string(from: now), wasScheduled: true)
    verifiedInstant.verified = true
    verifiedInstant.verifiedAt = now
    check("POC instant +1 on verification",
          records: [verifiedInstant],
          windowEnd: windowOpen, timeoutDuration: 0,
          expectedCount: 1, expectedState: .success)

    // 12. Disabled app zeroes the count even mid-run (todayState still reflects the
    //     underlying record — only the aggregated streak resets).
    check("disabled app -> streak 0",
          records: (0...4).map { successRecord(daysAgo: $0) },
          windowEnd: windowClosed, appEnabled: false,
          expectedCount: 0, expectedState: .success)

    // 13. Empty log entirely (no interaction ever) -> zero, no crash.
    check("empty log, no interaction",
          records: [], windowEnd: windowClosed,
          expectedCount: 0, expectedState: .neutral)

    // 14. Unresolved past dates (gaps never backfilled by a writer) resolve neutral
    //     and don't break a streak that resumes after them.
    check("unresolved past dates resolve neutral, don't break streak",
          records: [successRecord(daysAgo: 0), successRecord(daysAgo: 3)], // days -1, -2 missing
          windowEnd: windowClosed,
          expectedCount: 2, expectedState: .success)

    // 15. Log with no emergencyUsed records at all (pre-emergency-feature reality) —
    //     mixed success/neutral history still derives correctly.
    check("no emergencyUsed records anywhere (current POC reality)",
          records: [successRecord(daysAgo: 0), restRecord(daysAgo: 1), successRecord(daysAgo: 2)],
          windowEnd: windowClosed,
          expectedCount: 2, expectedState: .success)

    // ── Active Days fixtures (R6 cross-midnight + unscheduled skip) ──────────

    func verifiedRecord(daysAgo: Int) -> DayRecord {
        var r = DayRecord.fresh(date: daysAgoString(daysAgo), wasScheduled: true)
        r.verified = true
        r.verifiedAt = calendar.date(byAdding: .day, value: -daysAgo, to: now)
        return r
    }

    // 16. Cross-midnight, timeout still running (it's 00:50, yesterday's session
    //     open): yesterday is verified on disk but held .pending by the latch —
    //     no premature +1, older successes still count, nothing breaks.
    check("R6: open session holds yesterday pending",
          records: [verifiedRecord(daysAgo: 1)] + (2...4).map { successRecord(daysAgo: $0) },
          windowEnd: windowClosed,
          activeSessionDate: daysAgoString(1),
          expectedCount: 3, expectedState: .neutral)

    // 17. Same log after the timeout completes (latch cleared): the +1 lands on
    //     yesterday from data already on disk.
    check("R6: latch cleared — +1 lands on yesterday",
          records: [verifiedRecord(daysAgo: 1)] + (2...4).map { successRecord(daysAgo: $0) },
          windowEnd: windowClosed,
          activeSessionDate: nil,
          expectedCount: 4, expectedState: .neutral)

    // 18. Emergency break at 00:10 mid-timeout marks YESTERDAY broken. While the
    //     key is still set (transient, mid-wipe) yesterday stays pending…
    check("R6: broken yesterday held pending while key set",
          records: [brokenRecord(daysAgo: 1)] + (2...4).map { successRecord(daysAgo: $0) },
          windowEnd: windowClosed,
          activeSessionDate: daysAgoString(1),
          expectedCount: 3, expectedState: .neutral)

    //     …and once cleared, the broken wall stops the walk (older successes gone).
    check("R6: broken yesterday breaks after latch clears",
          records: [brokenRecord(daysAgo: 1)] + (2...4).map { successRecord(daysAgo: $0) },
          windowEnd: windowClosed,
          activeSessionDate: nil,
          expectedCount: 0, expectedState: .neutral)

    // 19. Post-midnight on an unscheduled day: yesterday's session still open,
    //     today's own record says rest — today is untouched by the open session.
    check("R6: today stays .rest during yesterday's open session",
          records: [restRecord(daysAgo: 0), verifiedRecord(daysAgo: 1), successRecord(daysAgo: 2)],
          windowEnd: windowClosed,
          activeSessionDate: daysAgoString(1),
          expectedCount: 1, expectedState: .rest)

    // 20. Unscheduled days skip (Tue/Thu-style schedule): successes separated by
    //     rest days still chain — days off don't break, don't build.
    check("unscheduled skip: alternating rest days chain successes",
          records: [successRecord(daysAgo: 0), restRecord(daysAgo: 1), successRecord(daysAgo: 2),
                    restRecord(daysAgo: 3), successRecord(daysAgo: 4)],
          windowEnd: windowClosed,
          expectedCount: 3, expectedState: .success)

    return results
}
#endif

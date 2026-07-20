//
//  ActiveDays.swift
//  Getupp
//
//  Which weekdays GETUPP arms — store, maintenance, and pure UI derivations.
//  Shared between the main app and the Monitor extension.
//  IMPORTANT: Add to BOTH targets in Xcode's File Inspector (main app + GetuppMonitor).
//  NEVER add to the shield targets — they don't consult the schedule, and this
//  file leans on GetuppShared/Streak helpers those targets don't link.
//
//  Design principles (mirrors Streak.swift and Timeout.swift):
//  - No mode enum is ever stored. activeDays: Set<Int> (Calendar weekday numbers,
//    1 = Sunday … 7 = Saturday) is the single source of truth; presets ("Weekdays")
//    are DERIVED on read, so the set and its label can never disagree.
//  - Stored as a plain [Int] array key — NOT inside the wakeSchedule JSON blob —
//    so idempotent daily maintenance can promote a queued change from any process
//    without decode round-trips.
//  - The invariant "activeDays is never empty" is guarded three times: the UI
//    refuses to save empty, save() refuses to write empty, and load() treats
//    empty-on-disk as all 7 with an error breadcrumb.
//

import Foundation

enum ActiveDays {

    // MARK: - App Group keys (canonical definitions)
    // activeSessionDateKey is duplicated in Timeout.swift's KEEP IN SYNC block —
    // completeTimeoutIfElapsed() must clear it from the shield-action extension,
    // which can't link this file.

    /// The schedule: [Int] of Calendar weekday numbers. Absent = all 7 (default).
    static let activeDaysKey            = "activeDays"
    /// Queued set containing a same-day removal (R5 analogue — no same-day dodge).
    static let pendingActiveDaysKey     = "pendingActiveDays"
    /// When the pending set was queued — promoted once it's "not today".
    static let pendingActiveDaysSetDateKey = "pendingActiveDaysSetDate"
    /// R6 anchor: "yyyy-MM-dd" of the calendar day the current session's window
    /// STARTED. Every session-lifecycle write uses it instead of "today" so a
    /// timeout running past midnight credits the right DayRecord. Deleting it is
    /// what finalizes the day (same latch shape as timeoutEndTime).
    static let activeSessionDateKey     = "activeSessionDate"

    static let allSeven: Set<Int> = Set(1...7)

    // MARK: - Store

    /// The active schedule. Absent key = fresh install = all 7 (preserves the
    /// every-morning behavior). Empty or invalid on disk should be impossible —
    /// treat as all 7 and log, never leave the user permanently unblockable.
    static func load() -> Set<Int> {
        guard let raw = GetuppShared.defaults?.array(forKey: activeDaysKey) as? [Int] else {
            return allSeven
        }
        let valid = Set(raw.filter { (1...7).contains($0) })
        guard !valid.isEmpty else {
            GetuppShared.logBreadcrumb("ERROR: activeDays empty/invalid on disk — treating as all 7")
            return allSeven
        }
        return valid
    }

    /// Refuses to persist an empty set — the UI guard is the real gate; this is
    /// the last line of defense for the never-empty invariant.
    static func save(_ days: Set<Int>) {
        guard !days.isEmpty else {
            GetuppShared.logBreadcrumb("ERROR: refused to save empty activeDays")
            return
        }
        GetuppShared.defaults?.set(days.sorted(), forKey: activeDaysKey)
    }

    static func loadPending() -> Set<Int>? {
        guard let raw = GetuppShared.defaults?.array(forKey: pendingActiveDaysKey) as? [Int] else {
            return nil
        }
        let valid = Set(raw.filter { (1...7).contains($0) })
        return valid.isEmpty ? nil : valid
    }

    static func savePending(_ days: Set<Int>, now: Date = Date()) {
        guard !days.isEmpty else { return }
        GetuppShared.defaults?.set(days.sorted(), forKey: pendingActiveDaysKey)
        GetuppShared.defaults?.set(now, forKey: pendingActiveDaysSetDateKey)
    }

    static func clearPending() {
        GetuppShared.defaults?.removeObject(forKey: pendingActiveDaysKey)
        GetuppShared.defaults?.removeObject(forKey: pendingActiveDaysSetDateKey)
    }

    // MARK: - Session date (R6)

    static func activeSessionDate() -> String? {
        GetuppShared.defaults?.string(forKey: activeSessionDateKey)
    }

    static func setActiveSessionDate(_ dateKey: String) {
        GetuppShared.defaults?.set(dateKey, forKey: activeSessionDateKey)
    }

    static func clearActiveSessionDate() {
        GetuppShared.defaults?.removeObject(forKey: activeSessionDateKey)
    }

    // MARK: - Scheduling predicate

    /// Pure: is this date's weekday in the set?
    static func isScheduled(on date: Date, days: Set<Int>, calendar: Calendar = .current) -> Bool {
        days.contains(calendar.component(.weekday, from: date))
    }

    /// Convenience for the monitor/app gate — reads the stored set.
    static func isScheduledToday(now: Date = Date()) -> Bool {
        isScheduled(on: now, days: load())
    }

    // MARK: - Daily maintenance (lazy, idempotent, mirrors Timeout.dailyMaintenance)

    /// Called right AFTER Timeout.dailyMaintenance() at its two call sites
    /// (monitor intervalDidStart, ShieldManager.reconcileState). Ordering matters:
    /// an elapsed timeout must complete (and clear activeSessionDate itself)
    /// before the stale sweep below decides the key is orphaned.
    static func scheduleMaintenance(now: Date = Date()) {
        // 1. Promote a queued day change once its set-date is no longer today.
        if let pending = loadPending() {
            let setDate  = GetuppShared.defaults?.object(forKey: pendingActiveDaysSetDateKey) as? Date
            let setToday = setDate.map { Calendar.current.isDate($0, inSameDayAs: now) } ?? false
            if !setToday {
                save(pending)   // save() refuses empty — an empty pending can never win
                clearPending()
                GetuppShared.logBreadcrumb("Active days promoted — now \(pending.sorted())")
            }
        } else if GetuppShared.defaults?.object(forKey: pendingActiveDaysKey) != nil {
            // Key exists but decoded empty/invalid — drop it, never promote empty.
            GetuppShared.logBreadcrumb("ERROR: dropped empty/invalid pendingActiveDays")
            clearPending()
        }

        // 2. Stale-session sweep: a past-day activeSessionDate can only
        // legitimately outlive midnight while its timeout is still running.
        // No timeout → every clearing layer flaked; clear it here so the day
        // finalizes and backfill stops skipping it.
        if let sessionKey = activeSessionDate(),
           let sessionDay = dayFormatter.date(from: sessionKey),
           sessionDay < Calendar.current.startOfDay(for: now),
           Timeout.loadTimeoutEnd() == nil {
            clearActiveSessionDate()
            GetuppShared.logBreadcrumb("Stale activeSessionDate \(sessionKey) cleared")
        }
    }

    // MARK: - Presets (derived on read — never stored)

    enum Preset: CaseIterable {
        case everyday, weekdays, weekends

        var days: Set<Int> {
            switch self {
            case .everyday: return allSeven
            case .weekdays: return [2, 3, 4, 5, 6]   // Mon–Fri
            case .weekends: return [1, 7]            // Sun + Sat
            }
        }

        var label: String {
            switch self {
            case .everyday: return "Every day"
            case .weekdays: return "Weekdays"
            case .weekends: return "Weekends"
            }
        }
    }

    /// The preset a set happens to match, if any. A hand-picked Mon–Fri
    /// correctly reads as .weekdays — that's the derive-don't-store principle.
    static func preset(for days: Set<Int>) -> Preset? {
        Preset.allCases.first { $0.days == days }
    }

    // MARK: - Week ordering

    /// The 7 weekday numbers in display order for a given firstWeekday
    /// (1 = Sunday-first, 2 = Monday-first, …). Never hardcode Sunday-first.
    static func orderedWeekdays(firstWeekday: Int) -> [Int] {
        (0..<7).map { ((firstWeekday - 1 + $0) % 7) + 1 }
    }

    // MARK: - Settings row detail label

    /// "Every day" / "Weekdays" / "Weekends" / "Mondays" / "Tue to Sat" /
    /// "Mon, Wed, Fri". Contiguity is checked only within the ordered week —
    /// no wraparound (Sat+Sun+Mon is a list, not a range). `calendar` supplies
    /// the day names so self-tests can pin an English locale.
    static func detailLabel(
        for days: Set<Int>,
        firstWeekday: Int,
        calendar: Calendar = .current
    ) -> String {
        let normalized = days.isEmpty ? allSeven : days

        if let preset = preset(for: normalized) {
            return preset.label
        }

        let fullNames  = calendar.weekdaySymbols        // index 0 = Sunday
        let shortNames = calendar.shortWeekdaySymbols

        if normalized.count == 1, let day = normalized.first {
            return fullNames[day - 1] + "s"             // recurring state: "Mondays"
        }

        let ordered   = orderedWeekdays(firstWeekday: firstWeekday)
        let positions = normalized.compactMap { ordered.firstIndex(of: $0) }.sorted()

        if let first = positions.first, let last = positions.last,
           last - first == positions.count - 1 {
            return "\(shortNames[ordered[first] - 1]) to \(shortNames[ordered[last] - 1])"
        }

        return positions.map { shortNames[ordered[$0] - 1] }.joined(separator: ", ")
    }

    // MARK: - Save algorithm (same-day rule, mirrors Timeout R5)

    /// Pure resolution of a Days-screen save.
    /// - `todayLocked`: today's window hasn't ended yet (pre-window counts —
    ///   dodging an upcoming window is the same cheat as dodging a running one).
    /// - Removing a locked today doesn't take effect today: it stays in the
    ///   applied set and the full target set queues for tomorrow's maintenance.
    /// - Everything else (additions, future-day removals, unlocked today)
    ///   applies immediately. Every save fully replaces the pending state, so
    ///   adding days back automatically cancels a queued removal.
    static func resolveSave(
        current: Set<Int>,
        proposed: Set<Int>,
        todayWeekday: Int,
        todayLocked: Bool
    ) -> (apply: Set<Int>, queued: Set<Int>?) {
        if todayLocked,
           current.contains(todayWeekday),
           !proposed.contains(todayWeekday) {
            return (proposed.union([todayWeekday]), proposed)
        }
        return (proposed, nil)
    }
}

// MARK: - Self-tests (DEBUG only)

#if DEBUG
/// Fixture-based self-tests for the pure ActiveDays functions, run on-device via
/// a debug button (no XCTest target exists for this POC). Same PASS/FAIL format
/// as runStreakSelfTests(). I/O paths (load/save/maintenance) are covered by the
/// on-device test checklist, not here.
func runActiveDaysSelfTests() -> [String] {
    var results: [String] = []

    func check(_ name: String, _ condition: Bool, detail: String = "") {
        results.append(condition ? "PASS \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    // English calendar so day-name fixtures don't depend on device locale.
    var cal = Calendar(identifier: .gregorian)
    cal.locale = Locale(identifier: "en_US_POSIX")

    func label(_ days: Set<Int>, first: Int) -> String {
        ActiveDays.detailLabel(for: days, firstWeekday: first, calendar: cal)
    }

    // ── Preset detection (chip lit state) ────────────────────────────────────
    check("preset: all 7 → Every day", ActiveDays.preset(for: Set(1...7)) == .everyday)
    check("preset: hand-picked Mon–Fri lights Weekdays", ActiveDays.preset(for: [2, 3, 4, 5, 6]) == .weekdays)
    check("preset: Sat+Sun lights Weekends", ActiveDays.preset(for: [1, 7]) == .weekends)
    check("preset: broken preset lights nothing", ActiveDays.preset(for: [2, 3, 4, 5]) == nil)

    // ── Week ordering ────────────────────────────────────────────────────────
    check("order: Sunday-first", ActiveDays.orderedWeekdays(firstWeekday: 1) == [1, 2, 3, 4, 5, 6, 7])
    check("order: Monday-first", ActiveDays.orderedWeekdays(firstWeekday: 2) == [2, 3, 4, 5, 6, 7, 1])
    check("order: Saturday-first", ActiveDays.orderedWeekdays(firstWeekday: 7) == [7, 1, 2, 3, 4, 5, 6])

    // ── Detail labels ────────────────────────────────────────────────────────
    check("label: Every day", label(Set(1...7), first: 1) == "Every day")
    check("label: Weekdays", label([2, 3, 4, 5, 6], first: 2) == "Weekdays")
    check("label: Weekends", label([1, 7], first: 2) == "Weekends")
    check("label: single day plural", label([2], first: 1) == "Mondays",
          detail: label([2], first: 1))
    check("label: contiguous range (Sun-first)", label([3, 4, 5, 6, 7], first: 1) == "Tue to Sat",
          detail: label([3, 4, 5, 6, 7], first: 1))
    check("label: contiguous range (Mon-first)", label([3, 4, 5, 6, 7], first: 2) == "Tue to Sat",
          detail: label([3, 4, 5, 6, 7], first: 2))
    check("label: no wraparound (Sat,Sun,Mon = list)", label([7, 1, 2], first: 1) == "Sun, Mon, Sat",
          detail: label([7, 1, 2], first: 1))
    check("label: no wraparound (Mon-first order)", label([7, 1, 2], first: 2) == "Mon, Sat, Sun",
          detail: label([7, 1, 2], first: 2))
    check("label: abbreviated list", label([2, 4, 6], first: 1) == "Mon, Wed, Fri",
          detail: label([2, 4, 6], first: 1))
    check("label: empty set normalizes to Every day", label([], first: 1) == "Every day")
    check("label: contiguity follows firstWeekday (Fri+Sat+Sun, Mon-first)",
          label([6, 7, 1], first: 2) == "Fri to Sun",
          detail: label([6, 7, 1], first: 2))
    check("label: same set is a list when Sunday-first splits it",
          label([6, 7, 1], first: 1) == "Sun, Fri, Sat",
          detail: label([6, 7, 1], first: 1))

    // ── Save algorithm (same-day rule) ───────────────────────────────────────
    // today = Monday (2)
    let lockedRemoval = ActiveDays.resolveSave(
        current: Set(1...7), proposed: [3, 4, 5, 6], todayWeekday: 2, todayLocked: true)
    check("save: locked today removal stays today, queues full set",
          lockedRemoval.apply == [2, 3, 4, 5, 6] && lockedRemoval.queued == [3, 4, 5, 6])

    let unlockedRemoval = ActiveDays.resolveSave(
        current: Set(1...7), proposed: [3, 4, 5, 6], todayWeekday: 2, todayLocked: false)
    check("save: unlocked today removal applies now",
          unlockedRemoval.apply == [3, 4, 5, 6] && unlockedRemoval.queued == nil)

    let futureRemoval = ActiveDays.resolveSave(
        current: Set(1...7), proposed: [1, 2, 3, 4, 5], todayWeekday: 2, todayLocked: true)
    check("save: future-day removal applies now even while locked",
          futureRemoval.apply == [1, 2, 3, 4, 5] && futureRemoval.queued == nil)

    let addition = ActiveDays.resolveSave(
        current: [2, 3], proposed: [2, 3, 4], todayWeekday: 2, todayLocked: true)
    check("save: additions apply immediately",
          addition.apply == [2, 3, 4] && addition.queued == nil)

    let todayNotScheduled = ActiveDays.resolveSave(
        current: [3, 4], proposed: [4], todayWeekday: 2, todayLocked: true)
    check("save: today not in current → no lock",
          todayNotScheduled.apply == [4] && todayNotScheduled.queued == nil)

    return results
}
#endif

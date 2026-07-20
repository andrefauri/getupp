//
//  GetuppShared.swift
//  Getupp
//
//  Shared constants and helpers used by BOTH the main app and the Monitor extension.
//  IMPORTANT: This file must be added to BOTH targets in Xcode's File Inspector.
//

import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings

// "enum" with no cases = a namespace that can't be accidentally instantiated.
enum GetuppShared {

    // MARK: - Constants

    static let appGroupID = "group.co.getupp.app"
    static let storeName  = "co.getupp.store"

    // UserDefaults keys shared between the app and extensions.
    static let selectionKey        = "familyActivitySelection"
    static let shieldedKey         = "isShielded"
    static let lastVerifiedDateKey = "lastVerifiedDate"
    static let breadcrumbsKey      = "monitorBreadcrumbs"
    static let isMonitoringKey     = "isMonitoring"
    static let wakeScheduleKey     = "wakeSchedule"
    static let dayLogKey           = "streakDayLog"
    // exemptDate: set to today when user picks "Start tomorrow" (Case A).
    // The Monitor extension skips shielding on that calendar day.
    static let exemptDateKey       = "exemptDate"
    // activeBlockEnd: the wall-clock time when the current block expires.
    // Persists through schedule edits (Case B) so the original end time is honoured.
    static let activeBlockEndKey   = "activeBlockEnd"
    // appEnabled: Pull the Plug's on/off switch. ABSENT means true — a fresh
    // install (or any build before this feature shipped) is enabled by default.
    static let appEnabledKey       = "appEnabled"
    // emergencyBreaksUsed: lifetime stat, mirrors totalTimeoutMinutes. Emergency
    // Break only — Pull the Plug does not increment this.
    static let emergencyBreaksUsedKey = "emergencyBreaksUsed"

    // DeviceActivityName namespace.
    // Legacy name kept so any previously registered activity can be stopped cleanly.
    static let legacyActivityName  = DeviceActivityName("co.getupp.daily")
    // Real daily schedule (Phase A: everyday).
    static let windowActivityName  = DeviceActivityName("getupp.window.everyday")
    // Temporary debug window — never mutates WakeSchedule state.
    static let debugActivityName   = DeviceActivityName("getupp.debug")
    // One-off schedule ending at timeoutEndTime — clearing layer 1 (see Timeout.swift).
    static let timeoutActivityName = DeviceActivityName("getupp.timeout")

    /// All activity names we may ever have registered, for stop-all convenience.
    static let allActivityNames: [DeviceActivityName] = [
        legacyActivityName, windowActivityName, debugActivityName, timeoutActivityName
    ]

    // The shared ManagedSettingsStore — same name in app and extension so
    // shields applied by one are visible/removable by the other.
    static let store = ManagedSettingsStore(named: .init(storeName))

    // MARK: - App Group UserDefaults

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    // MARK: - Selection persistence

    /// Loads the user's saved FamilyActivitySelection from the App Group.
    static func loadSelection() -> FamilyActivitySelection? {
        guard let data = defaults?.data(forKey: selectionKey) else { return nil }
        return try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
    }

    // MARK: - WakeSchedule persistence

    /// Saves a WakeSchedule to the App Group so both app and Monitor extension can read it.
    static func saveWakeSchedule(_ schedule: WakeSchedule) {
        guard let data = try? JSONEncoder().encode(schedule) else { return }
        defaults?.set(data, forKey: wakeScheduleKey)
    }

    /// Loads the persisted WakeSchedule, or nil if none has been saved yet.
    static func loadWakeSchedule() -> WakeSchedule? {
        guard let data = defaults?.data(forKey: wakeScheduleKey) else { return nil }
        return try? JSONDecoder().decode(WakeSchedule.self, from: data)
    }

    // MARK: - Streak day log
    //
    // Append-only log of DayRecords. The streak is NEVER stored as a counter —
    // it's derived on read from this log (see Streak.swift). One record per local
    // calendar date; first write wins so duplicate/skipped dates from timezone
    // travel never double-count.

    /// Local calendar date string ("yyyy-MM-dd") for `now`, used as a DayRecord key.
    static func todayKey(now: Date = Date()) -> String {
        dayFormatter.string(from: now)
    }

    /// R6: the day a session-lifecycle write belongs to — the day the current
    /// window STARTED (activeSessionDate), falling back to today when no session
    /// is open. Windows can't cross midnight, so during the window the two are
    /// identical; they differ only when a timeout runs past midnight — exactly
    /// when writing to "today" would hit the wrong DayRecord.
    private static func sessionKey(now: Date = Date()) -> String {
        ActiveDays.activeSessionDate() ?? todayKey(now: now)
    }

    /// Loads the full day log, oldest-or-newest order not guaranteed.
    static func loadDayLog() -> [DayRecord] {
        guard let data = defaults?.data(forKey: dayLogKey) else { return [] }
        return (try? JSONDecoder().decode([DayRecord].self, from: data)) ?? []
    }

    /// Saves the full day log.
    static func saveDayLog(_ records: [DayRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults?.set(data, forKey: dayLogKey)
    }

    /// Monitor extension's ONE write: marks the session's day as having run.
    /// Kept dumb and minimal per the extension's tight memory limits — creates
    /// the record if it doesn't exist yet (wasScheduled defaults to true,
    /// since intervalDidStart only fires on a scheduled day), else flips the flag.
    static func recordSessionRanToday(now: Date = Date()) {
        let key = sessionKey(now: now)
        var log = loadDayLog()
        if let index = log.firstIndex(where: { $0.date == key }) {
            log[index].sessionRan = true
        } else {
            var record = DayRecord.fresh(date: key, wasScheduled: true)
            record.sessionRan = true
            log.append(record)
        }
        saveDayLog(log)
    }

    /// Main app write: marks the session day's photo verification as passed.
    static func markVerifiedToday(now: Date = Date()) {
        let key = sessionKey(now: now)
        var log = loadDayLog()
        if let index = log.firstIndex(where: { $0.date == key }) {
            log[index].verified   = true
            log[index].verifiedAt = now
        } else {
            var record = DayRecord.fresh(date: key, wasScheduled: true)
            record.verified   = true
            record.verifiedAt = now
            log.append(record)
        }
        saveDayLog(log)
    }

    /// Debug-only undo for markVerifiedToday(), mirrors clearVerifiedDate().
    static func clearVerifiedToday(now: Date = Date()) {
        let key = todayKey(now: now)
        var log = loadDayLog()
        guard let index = log.firstIndex(where: { $0.date == key }) else { return }
        log[index].verified   = false
        log[index].verifiedAt = nil
        saveDayLog(log)
    }

    /// Main app write: marks the session day's Escape Hatch action as a
    /// surrendered day. Used by BOTH Emergency Break and Pull the Plug — either
    /// one breaks the streak the same way. deriveStreak() already treats
    /// emergencyUsed as .broken; this is the one place that sets it.
    /// Anchored to sessionKey: a break at 00:30 mid-timeout must mark the
    /// session's day (yesterday), not today — so callers MUST call this BEFORE
    /// any path that clears activeSessionDate (i.e. before removeShield).
    static func markEmergencyUsedToday(now: Date = Date()) {
        let key = sessionKey(now: now)
        var log = loadDayLog()
        if let index = log.firstIndex(where: { $0.date == key }) {
            log[index].emergencyUsed = true
            log[index].emergencyAt   = now
        } else {
            var record = DayRecord.fresh(date: key, wasScheduled: true)
            record.emergencyUsed = true
            record.emergencyAt   = now
            log.append(record)
        }
        saveDayLog(log)
    }

    /// Snapshots whether today counts as scheduled, so retroactive schedule edits
    /// can't rewrite history (anti-gaming rule #1). Called once per day, on first
    /// app open — first write wins, later calls are no-ops for today's record.
    static func snapshotScheduledToday(schedule: WakeSchedule?, now: Date = Date()) {
        let key = todayKey(now: now)
        var log = loadDayLog()
        guard !log.contains(where: { $0.date == key }) else { return }

        let scheduledDay = ActiveDays.isScheduled(on: now, days: ActiveDays.load())
        let wasScheduled = (schedule?.isEnabled ?? false) && scheduledDay && !isExemptToday()
        log.append(DayRecord.fresh(date: key, wasScheduled: wasScheduled))
        saveDayLog(log)
    }

    /// Lazy resolution: fills in any missing past scheduled dates as neutral
    /// placeholders so the derivation doesn't need to guess. Never touches today
    /// or mutates existing records. Only backfills after the log's earliest
    /// existing record — a fresh install has no history to reconstruct.
    ///
    /// Known limitation (accepted for v1): elapsed days are stamped with the
    /// CURRENT activeDays set, not the set that governed them at the time.
    /// Self-limiting — maintenance runs on every foreground.
    static func backfillDayLog(schedule: WakeSchedule?, now: Date = Date()) {
        guard let schedule else { return }
        var log = loadDayLog()
        guard let earliestDate = log.compactMap({ dayFormatter.date(from: $0.date) }).min() else {
            return // nothing to backfill against yet
        }

        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        var existingDates = Set(log.map(\.date))
        var cursor = earliestDate
        let activeDays = ActiveDays.load()
        // R6 backfill guard: while activeSessionDate is set, that day is still
        // open (cross-midnight timeout) — deleting the key is what finalizes it.
        let openSessionKey = ActiveDays.activeSessionDate()

        while cursor < todayStart {
            defer { cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? todayStart }
            let key = dayFormatter.string(from: cursor)
            guard !existingDates.contains(key), key != openSessionKey else { continue }

            let wasScheduled = schedule.isEnabled
                && ActiveDays.isScheduled(on: cursor, days: activeDays, calendar: calendar)
            log.append(DayRecord.fresh(date: key, wasScheduled: wasScheduled))
            existingDates.insert(key)
        }

        saveDayLog(log)
    }

    /// Convenience: backfills, then derives the current streak.
    /// timeoutDuration comes from the Timeout feature: today stays .pending until
    /// the post-verification timeout completes, then the +1 lands.
    /// appEnabled reads the real Pull the Plug switch — disabling zeroes the streak.
    static func currentStreak(schedule: WakeSchedule?, now: Date = Date()) -> StreakResult {
        backfillDayLog(schedule: schedule, now: now)

        let calendar = Calendar.current
        var windowEndComponents = calendar.dateComponents([.year, .month, .day], from: now)
        windowEndComponents.hour   = schedule?.endHour   ?? 23
        windowEndComponents.minute = schedule?.endMinute ?? 59
        let windowEnd = calendar.date(from: windowEndComponents) ?? now

        return deriveStreak(
            records: loadDayLog(),
            today: todayKey(now: now),
            now: now,
            windowEnd: windowEnd,
            timeoutDuration: Timeout.effectiveStreakDuration(now: now),
            appEnabled: isAppEnabled(),
            activeSessionDate: ActiveDays.activeSessionDate()
        )
    }

    // MARK: - Pull the Plug (appEnabled)

    /// Whether GETUPP is currently active. ABSENT means true (fresh install,
    /// or any build predating this feature, is enabled by default).
    static func isAppEnabled() -> Bool {
        guard let value = defaults?.object(forKey: appEnabledKey) as? Bool else { return true }
        return value
    }

    static func setAppEnabled(_ enabled: Bool) {
        defaults?.set(enabled, forKey: appEnabledKey)
    }

    // MARK: - Emergency Break lifetime stat

    /// Lifetime count of Emergency Breaks used. Pull the Plug does NOT increment
    /// this — it's a separate "give up" action with its own semantics.
    static var emergencyBreaksUsed: Int {
        defaults?.integer(forKey: emergencyBreaksUsedKey) ?? 0
    }

    static func incrementEmergencyBreaksUsed() {
        defaults?.set(emergencyBreaksUsed + 1, forKey: emergencyBreaksUsedKey)
    }

    // MARK: - Shielding

    /// Applies shields to the given selection's apps and categories.
    ///
    /// shieldedKey only becomes true when there's actually something to
    /// shield — it's the one flag every reconcile/UI path trusts to mean
    /// "the OS is really restricting something," so it must never claim a
    /// block that isn't happening. An empty selection sets both shield
    /// properties to nil (correctly, nothing to restrict) but must NOT also
    /// mark shieldedKey true, or Home would show "Apps are blocked" while
    /// nothing is actually blocked.
    static func applyShield(selection: FamilyActivitySelection) {
        let hasSomethingToShield = !selection.applicationTokens.isEmpty || !selection.categoryTokens.isEmpty

        store.shield.applications = selection.applicationTokens.isEmpty
            ? nil
            : selection.applicationTokens

        store.shield.applicationCategories = selection.categoryTokens.isEmpty
            ? nil
            : .specific(selection.categoryTokens)

        defaults?.set(hasSomethingToShield, forKey: shieldedKey)
        if !hasSomethingToShield {
            logBreadcrumb("applyShield called with empty selection — not marking shielded")
        }
    }

    /// Removes all shields, unblocking everything. Also finalizes the session
    /// day (R6): every unshield path — window end, missed-callback reconcile,
    /// escape hatch, debug unlock — ends the session, so the activeSessionDate
    /// latch clears here. (Natural timeout completion clears it separately in
    /// Timeout.completeTimeoutIfElapsed, which can't call this function.)
    static func removeShield() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil

        defaults?.set(false, forKey: shieldedKey)
        defaults?.removeObject(forKey: activeBlockEndKey)
        defaults?.removeObject(forKey: ActiveDays.activeSessionDateKey)
    }

    // MARK: - Daily verification check

    /// Returns true if the user has already verified (passed the photo check) today.
    static func isVerifiedToday() -> Bool {
        guard let lastDate = defaults?.object(forKey: lastVerifiedDateKey) as? Date else {
            return false
        }
        return Calendar.current.isDateInToday(lastDate)
    }

    // MARK: - Active block end tracking

    /// Records today's window-end time as activeBlockEnd. Called after a shield is applied
    /// so reconciliation and Case B edits respect the original end time.
    static func recordActiveBlockEnd(from schedule: WakeSchedule) {
        let calendar = Calendar.current
        var comps    = calendar.dateComponents([.year, .month, .day], from: Date())
        comps.hour   = schedule.endHour
        comps.minute = schedule.endMinute
        comps.second = 0
        if let endDate = calendar.date(from: comps) {
            defaults?.set(endDate, forKey: activeBlockEndKey)
        }
    }

    // MARK: - Exempt-today check (Case A "Start tomorrow")

    /// Returns true if the user chose "Start tomorrow" today — Monitor extension skips shielding.
    static func isExemptToday() -> Bool {
        guard let exemptDate = defaults?.object(forKey: exemptDateKey) as? Date else {
            return false
        }
        return Calendar.current.isDateInToday(exemptDate)
    }

    // MARK: - Debug breadcrumbs

    /// Appends a timestamped message to the breadcrumb log in App Group UserDefaults.
    /// Extensions can't print to Xcode's console, so this is our debugging lifeline.
    static func logBreadcrumb(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        let entry = "[\(timestamp)] \(message)"

        var crumbs = defaults?.stringArray(forKey: breadcrumbsKey) ?? []
        crumbs.append(entry)
        // Keep only the last 20 entries to avoid UserDefaults bloat.
        if crumbs.count > 20 { crumbs = Array(crumbs.suffix(20)) }
        defaults?.set(crumbs, forKey: breadcrumbsKey)
    }

    /// Reads all stored breadcrumbs.
    static func loadBreadcrumbs() -> [String] {
        defaults?.stringArray(forKey: breadcrumbsKey) ?? []
    }
}

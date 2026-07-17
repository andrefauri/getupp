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

    // DeviceActivityName namespace.
    // Legacy name kept so any previously registered activity can be stopped cleanly.
    static let legacyActivityName  = DeviceActivityName("co.getupp.daily")
    // Real daily schedule (Phase A: everyday).
    static let windowActivityName  = DeviceActivityName("getupp.window.everyday")
    // Temporary debug window — never mutates WakeSchedule state.
    static let debugActivityName   = DeviceActivityName("getupp.debug")

    /// All activity names we may ever have registered, for stop-all convenience.
    static let allActivityNames: [DeviceActivityName] = [
        legacyActivityName, windowActivityName, debugActivityName
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

    /// Monitor extension's ONE write: marks today's session as having run.
    /// Kept dumb and minimal per the extension's tight memory limits — creates
    /// today's record if it doesn't exist yet (wasScheduled defaults to true,
    /// since intervalDidStart only fires on a scheduled day), else flips the flag.
    static func recordSessionRanToday(now: Date = Date()) {
        let key = todayKey(now: now)
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

    /// Main app write: marks today's photo verification as passed.
    static func markVerifiedToday(now: Date = Date()) {
        let key = todayKey(now: now)
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

    /// Snapshots whether today counts as scheduled, so retroactive schedule edits
    /// can't rewrite history (anti-gaming rule #1). Called once per day, on first
    /// app open — first write wins, later calls are no-ops for today's record.
    static func snapshotScheduledToday(schedule: WakeSchedule?, now: Date = Date()) {
        let key = todayKey(now: now)
        var log = loadDayLog()
        guard !log.contains(where: { $0.date == key }) else { return }

        let wasScheduled = (schedule?.isActiveDay(now: now) ?? false) && !isExemptToday()
        log.append(DayRecord.fresh(date: key, wasScheduled: wasScheduled))
        saveDayLog(log)
    }

    /// Lazy resolution: fills in any missing past scheduled dates as neutral
    /// placeholders so the derivation doesn't need to guess. Never touches today
    /// or mutates existing records. Only backfills after the log's earliest
    /// existing record — a fresh install has no history to reconstruct.
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

        while cursor < todayStart {
            defer { cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? todayStart }
            let key = dayFormatter.string(from: cursor)
            guard !existingDates.contains(key) else { continue }

            let wasScheduled = schedule.isActiveDay(now: cursor)
            log.append(DayRecord.fresh(date: key, wasScheduled: wasScheduled))
            existingDates.insert(key)
        }

        saveDayLog(log)
    }

    /// Convenience: backfills, then derives the current streak.
    /// POC values: timeoutDuration = 0 (instant +1 on verification),
    /// appEnabled = true (disable-breaks-streak not wired yet).
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
            timeoutDuration: 0,
            appEnabled: true
        )
    }

    // MARK: - Shielding

    /// Applies shields to the given selection's apps and categories.
    static func applyShield(selection: FamilyActivitySelection) {
        store.shield.applications = selection.applicationTokens.isEmpty
            ? nil
            : selection.applicationTokens

        store.shield.applicationCategories = selection.categoryTokens.isEmpty
            ? nil
            : .specific(selection.categoryTokens)

        defaults?.set(true, forKey: shieldedKey)
    }

    /// Removes all shields, unblocking everything.
    static func removeShield() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil

        defaults?.set(false, forKey: shieldedKey)
        defaults?.removeObject(forKey: activeBlockEndKey)
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

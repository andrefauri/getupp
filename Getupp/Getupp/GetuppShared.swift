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

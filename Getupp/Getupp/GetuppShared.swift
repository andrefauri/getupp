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
    static let selectionKey       = "familyActivitySelection"
    static let shieldedKey        = "isShielded"
    static let lastVerifiedDateKey = "lastVerifiedDate"
    static let breadcrumbsKey     = "monitorBreadcrumbs"
    static let isMonitoringKey    = "isMonitoring"

    // DeviceActivityName identifies our daily blocking schedule.
    // Both the app (to register) and extension (to match callbacks) use this.
    static let activityName = DeviceActivityName("co.getupp.daily")

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
    }

    // MARK: - Daily verification check

    /// Returns true if the user has already verified (passed the photo check) today.
    /// Verification doesn't exist yet — this wires the daily-reset logic in advance.
    static func isVerifiedToday() -> Bool {
        guard let lastDate = defaults?.object(forKey: lastVerifiedDateKey) as? Date else {
            return false
        }
        return Calendar.current.isDateInToday(lastDate)
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

//
//  DeviceActivityMonitorExtension.swift
//  GetuppMonitor
//
//  Apple calls these callbacks when a schedule window starts and ends.
//  This extension runs as a separate process — it communicates with the main app
//  only through App Group UserDefaults.
//

import DeviceActivity
import FamilyControls
import ManagedSettings

class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)

        GetuppShared.logBreadcrumb("intervalDidStart — \(activity.rawValue)")

        // Skip if the user already verified today (daily-reset gate).
        if GetuppShared.isVerifiedToday() {
            GetuppShared.logBreadcrumb("Already verified today — skipping shield")
            return
        }

        // Skip if the user chose "Start tomorrow" today (Case A exempt).
        if GetuppShared.isExemptToday() {
            GetuppShared.logBreadcrumb("Exempt today — skipping shield")
            return
        }

        // Apply shields.
        guard let selection = GetuppShared.loadSelection() else {
            GetuppShared.logBreadcrumb("No saved selection — nothing to shield")
            return
        }

        GetuppShared.applyShield(selection: selection)
        GetuppShared.logBreadcrumb("Shield applied (apps: \(selection.applicationTokens.count), categories: \(selection.categoryTokens.count))")

        // Record when this block expires so the app can reconcile correctly,
        // and so schedule edits during a block (Case B) don't change the end time.
        if let schedule = GetuppShared.loadWakeSchedule() {
            GetuppShared.recordActiveBlockEnd(from: schedule)
            GetuppShared.logBreadcrumb("activeBlockEnd set to \(schedule.endDisplayString)")
        }
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)

        GetuppShared.logBreadcrumb("intervalDidEnd — \(activity.rawValue) — removing shield")
        GetuppShared.removeShield()
        // removeShield() already clears activeBlockEndKey.
    }

    // Unused stubs — required by the superclass.
    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
    }

    override func intervalWillStartWarning(for activity: DeviceActivityName) {
        super.intervalWillStartWarning(for: activity)
    }

    override func intervalWillEndWarning(for activity: DeviceActivityName) {
        super.intervalWillEndWarning(for: activity)
    }

    override func eventWillReachThresholdWarning(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventWillReachThresholdWarning(event, activity: activity)
    }
}

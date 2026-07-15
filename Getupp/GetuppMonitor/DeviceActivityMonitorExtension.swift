//
//  DeviceActivityMonitorExtension.swift
//  GetuppMonitor
//
//  Apple calls these callbacks when the schedule window starts and ends.
//  The extension runs as a separate process — it cannot talk to the main app
//  directly; it communicates only through App Group UserDefaults.
//

import DeviceActivity
import FamilyControls
import ManagedSettings

class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)

        GetuppShared.logBreadcrumb("intervalDidStart fired")

        // Skip shielding if the user already verified (got out of bed) today.
        // This is the daily-reset gate — verification will fill lastVerifiedDate later.
        if GetuppShared.isVerifiedToday() {
            GetuppShared.logBreadcrumb("Already verified today — skipping shield")
            return
        }

        // Load the selection the user saved from the picker, then apply shields.
        if let selection = GetuppShared.loadSelection() {
            GetuppShared.applyShield(selection: selection)
            GetuppShared.logBreadcrumb("Shield applied (apps: \(selection.applicationTokens.count), categories: \(selection.categoryTokens.count))")
        } else {
            GetuppShared.logBreadcrumb("No saved selection found — nothing to shield")
        }
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)

        GetuppShared.logBreadcrumb("intervalDidEnd fired — removing shield")
        GetuppShared.removeShield()
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

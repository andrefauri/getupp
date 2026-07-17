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
import Foundation
import ManagedSettings

class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)

        GetuppShared.logBreadcrumb("intervalDidStart — \(activity.rawValue)")

        // The one-off timeout schedule fires an immediate didStart when registered.
        // Shields are already on (they never came off at verification) — nothing
        // to do, and it must NOT count as a morning session.
        if activity == GetuppShared.timeoutActivityName {
            GetuppShared.logBreadcrumb("Timeout schedule armed — no action")
            return
        }

        // Pull the Plug guard: a disabled GETUPP must never shield "helpfully."
        // This also stands in for a disabled-app check inside Timeout.dailyMaintenance()
        // — that function has no appEnabled concept (it stays Foundation+ManagedSettings
        // only, so the memory-constrained shield targets can include it), and the
        // only two callers of dailyMaintenance (here and reconcileState) are both
        // guarded, so skipping it here is equivalent to guarding it there.
        guard GetuppShared.isAppEnabled() else {
            GetuppShared.logBreadcrumb("intervalDidStart — app disabled, skipping")
            return
        }

        // Timeout daily maintenance BEFORE any shield logic (R3 reset ordering):
        // completes a leftover elapsed timeout and promotes a queued downgrade,
        // so yesterday's state is gone before today's morning shields go up.
        Timeout.dailyMaintenance()

        // Record that today's session ran, regardless of what happens below —
        // the streak only cares that the window fired, not whether the shield
        // ends up applied (already-verified and exempt days still "ran").
        GetuppShared.recordSessionRanToday()

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

        // Timeout schedule ended (clearing layer 1): complete the timeout —
        // credits minutes and clears shields via the shared completion path.
        if activity == GetuppShared.timeoutActivityName {
            let completed = Timeout.completeTimeoutIfElapsed()
            GetuppShared.logBreadcrumb("intervalDidEnd — timeout \(completed ? "completed, shields cleared" : "already completed elsewhere")")
            return
        }

        // Pull the Plug guard: if the app was disabled mid-window, there's
        // nothing to clear (Pull the Plug already cleared it) and nothing to
        // re-derive — bail rather than touching shield state on a disabled app.
        guard GetuppShared.isAppEnabled() else {
            GetuppShared.logBreadcrumb("intervalDidEnd — app disabled, skipping")
            return
        }

        // R3: Timeout overrides window end. If the user verified late in the
        // window, the timeout outlives it — shields must survive this boundary
        // and clear only at timeoutEndTime.
        guard Timeout.shouldClearShieldAtWindowEnd(now: Date(), timeoutEndTime: Timeout.loadTimeoutEnd()) else {
            GetuppShared.logBreadcrumb("intervalDidEnd — \(activity.rawValue) — timeout active, shields STAY")
            return
        }

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

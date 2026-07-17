//
//  ShieldManager.swift
//  Getupp
//
//  Production-quality module that manages all Family Controls logic.
//  Views call into this class; no Family Controls code lives in views.
//

import Combine
import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings

// ObservableObject lets SwiftUI views react to changes via @Published properties.
// (The newer @Observable macro requires iOS 17; we target iOS 16.6.)
class ShieldManager: ObservableObject {

    // MARK: - Published properties (UI binds to these)

    /// Whether the user has granted Family Controls permission.
    @Published var authorizationStatus: AuthorizationStatus

    /// The apps and categories the user selected to block.
    @Published var activitySelection = FamilyActivitySelection() {
        didSet { saveSelection() }
    }

    // MARK: - Published properties (verification state)

    @Published var isVerifiedToday: Bool

    // MARK: - Published properties (streak)

    /// Derived from the day log — never a stored counter. See Streak.swift.
    @Published var streak: StreakResult = .zero

    // MARK: - Published properties (shield state)

    @Published var isShielded:   Bool
    @Published var isMonitoring: Bool   // true only when a real WakeSchedule is registered

    // MARK: - Published properties (timeout state)

    /// Non-nil while a post-verification Timeout is running. Mirrors the App Group
    /// key (Timeout.timeoutEndTimeKey) — that key is the source of truth.
    @Published var timeoutEndTime: Date?

    /// Lifetime completed timeout minutes (feeds the streak dialog).
    @Published var totalTimeoutMinutes: Int

    /// The active timeout duration setting (mirrors the App Group key).
    @Published var timeoutDuration: TimeInterval

    /// Downgrade queued for tomorrow, nil when none (R5).
    @Published var pendingTimeoutDuration: TimeInterval?

    /// The wake schedule the user has configured, nil if none set yet.
    @Published var wakeSchedule: WakeSchedule?

    /// Non-nil when the last schedule registration failed.
    @Published var scheduleError: String?

    // For debug display only — shows the currently registered window times.
    @Published var scheduleStart: DateComponents?
    @Published var scheduleEnd:   DateComponents?

    // MARK: - Private

    private let store        = GetuppShared.store
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        self.authorizationStatus = AuthorizationCenter.shared.authorizationStatus

        let defaults = GetuppShared.defaults
        self.isShielded      = defaults?.bool(forKey: GetuppShared.shieldedKey)    ?? false
        self.isMonitoring    = defaults?.bool(forKey: GetuppShared.isMonitoringKey) ?? false
        self.isVerifiedToday = GetuppShared.isVerifiedToday()
        self.wakeSchedule    = GetuppShared.loadWakeSchedule()
        self.scheduleStart   = nil
        self.scheduleEnd     = nil
        self.timeoutEndTime         = Timeout.loadTimeoutEnd()
        self.totalTimeoutMinutes    = Timeout.totalMinutes
        self.timeoutDuration        = Timeout.currentDuration
        self.pendingTimeoutDuration = Timeout.pendingDuration

        self.activitySelection = loadSelection() ?? FamilyActivitySelection()

        // If the user verified but the shield is still up (app was killed mid-flow),
        // clear it — UNLESS a Timeout is running: then verified + shielded is exactly
        // the intended state, and clearing here would kill the timeout on relaunch.
        if self.isVerifiedToday && self.isShielded && Timeout.loadTimeoutEnd() == nil {
            GetuppShared.removeShield()
            self.isShielded = false
        }

        // Reflect the registered schedule times in the UI if we have a WakeSchedule.
        if let schedule = self.wakeSchedule, self.isMonitoring {
            var start = DateComponents()
            start.hour   = schedule.startHour
            start.minute = schedule.startMinute
            var end = DateComponents()
            end.hour   = schedule.endHour
            end.minute = schedule.endMinute
            self.scheduleStart = start
            self.scheduleEnd   = end
        }

        AuthorizationCenter.shared
            .objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.authorizationStatus = AuthorizationCenter.shared.authorizationStatus
            }
            .store(in: &cancellables)

        refreshStreak()
    }

    // MARK: - Authorization

    @MainActor
    func requestAuthorization() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        } catch {
            print("[ShieldManager] Authorization error: \(error)")
        }
        self.authorizationStatus = AuthorizationCenter.shared.authorizationStatus
    }

    // MARK: - Wake Schedule persistence + registration

    /// Persists `schedule` to the App Group and re-registers the DeviceActivity.
    /// Does NOT touch the current shield state — callers handle Case A / Case B side effects.
    func saveWakeSchedule(_ schedule: WakeSchedule) {
        GetuppShared.saveWakeSchedule(schedule)
        self.wakeSchedule = schedule

        do {
            try registerSchedule(schedule)
            self.scheduleError = nil
        } catch {
            self.scheduleError = error.localizedDescription
        }
    }

    /// Case A — "Block me now": apply shield immediately and record when it should end.
    func applyImmediateBlock(for schedule: WakeSchedule) {
        applyShield()
        recordActiveBlockEnd(for: schedule)
        GetuppShared.logBreadcrumb("Day-0 block applied immediately")
    }

    /// Case A — "Start tomorrow": write exemptDate so the Monitor extension skips today.
    func markExemptToday() {
        GetuppShared.defaults?.set(Date(), forKey: GetuppShared.exemptDateKey)
        GetuppShared.logBreadcrumb("Exempt today — schedule starts tomorrow")
    }

    // MARK: - Registration engine

    /// Stops all known window activities, then registers a new repeating schedule.
    /// Phase A: .everyday → single "getupp.window.everyday" activity.
    private func registerSchedule(_ schedule: WakeSchedule) throws {
        let center = DeviceActivityCenter()

        // Stop-all before re-registering so no orphaned activities survive edits.
        center.stopMonitoring([GetuppShared.legacyActivityName, GetuppShared.windowActivityName])

        guard schedule.isEnabled else {
            isMonitoring = false
            GetuppShared.defaults?.set(false, forKey: GetuppShared.isMonitoringKey)
            return
        }

        var start = DateComponents()
        start.hour   = schedule.startHour
        start.minute = schedule.startMinute

        var end = DateComponents()
        end.hour   = schedule.endHour
        end.minute = schedule.endMinute

        let deviceSchedule = DeviceActivitySchedule(
            intervalStart: start,
            intervalEnd:   end,
            repeats:       true
        )

        // Phase A: only .everyday path. Phase B will add per-weekday registrations here.
        try center.startMonitoring(GetuppShared.windowActivityName, during: deviceSchedule)

        isMonitoring  = true
        scheduleStart = start
        scheduleEnd   = end
        GetuppShared.defaults?.set(true, forKey: GetuppShared.isMonitoringKey)
        GetuppShared.logBreadcrumb("Schedule registered — window \(schedule.startDisplayString)–\(schedule.endDisplayString)")
    }

    // MARK: - Debug scheduling

    /// Registers a temporary debug window: starts ~2 minutes from now, lasts 15 minutes.
    /// Uses "getupp.debug" activity name so it doesn't interfere with the real schedule.
    func startDebugWindow() {
        let now       = Date()
        let startDate = now.addingTimeInterval(2  * 60)   // +2 min
        let endDate   = now.addingTimeInterval(17 * 60)   // +17 min = 15-min window

        let cal   = Calendar.current
        let start = cal.dateComponents([.hour, .minute], from: startDate)
        let end   = cal.dateComponents([.hour, .minute], from: endDate)

        let schedule = DeviceActivitySchedule(
            intervalStart: start,
            intervalEnd:   end,
            repeats:       true
        )

        do {
            try DeviceActivityCenter().startMonitoring(GetuppShared.debugActivityName, during: schedule)
            // Update display-only properties for the debug section.
            scheduleStart = start
            scheduleEnd   = end
            GetuppShared.logBreadcrumb("Debug window registered — \(formatTime(start))–\(formatTime(end))")
        } catch {
            print("[ShieldManager] Debug window error: \(error)")
            GetuppShared.logBreadcrumb("Debug window error: \(error)")
        }
    }

    /// Stops ALL registered activities (real + debug). POC emergency unlock.
    func stopMonitoring() {
        DeviceActivityCenter().stopMonitoring(GetuppShared.allActivityNames)
        isMonitoring  = false
        scheduleStart = nil
        scheduleEnd   = nil
        GetuppShared.defaults?.set(false, forKey: GetuppShared.isMonitoringKey)
        GetuppShared.logBreadcrumb("All schedules stopped (Stop Schedule)")
    }

    // MARK: - Foreground reconciliation (R4)

    /// Called on every app-active transition. Compares expected vs actual shield state
    /// and corrects drift from missed DeviceActivity callbacks (known Apple reliability issue).
    func reconcileState() {
        let now      = Date()
        let defaults = GetuppShared.defaults

        // Timeout daily maintenance first (clearing layer 2 — check-on-open):
        // completes an elapsed timeout (credits minutes, clears shields) and
        // promotes a queued downgrade. Idempotent; extensions run it too.
        Timeout.dailyMaintenance(now: now)

        // Re-sync published state that maintenance (or an extension) may have
        // changed behind our back — the App Group is the source of truth.
        isShielded             = defaults?.bool(forKey: GetuppShared.shieldedKey) ?? false
        totalTimeoutMinutes    = Timeout.totalMinutes
        timeoutDuration        = Timeout.currentDuration
        pendingTimeoutDuration = Timeout.pendingDuration

        // Lazy resolution: never trust a callback to fire at window end. Every
        // app-active transition snapshots today and backfills any unresolved
        // past dates so the streak is always correct on read.
        refreshStreak()

        // ── An active Timeout overrides everything else ─────────────────────────
        if let end = Timeout.loadTimeoutEnd(), now < end {
            timeoutEndTime = end
            if !isShielded {
                // Shield was lost mid-timeout (e.g. reboot) — reapply.
                applyShield()
                GetuppShared.logBreadcrumb("Reconcile: timeout active — shield reapplied")
            }
            return
        }

        // No timeout running: publish that, and stop any orphaned one-off
        // timeout schedule left over from a completed/cleared timeout (R10).
        timeoutEndTime = nil
        DeviceActivityCenter().stopMonitoring([GetuppShared.timeoutActivityName])

        // ── activeBlockEnd is authoritative when it exists ──────────────────────
        if let blockEnd = defaults?.object(forKey: GetuppShared.activeBlockEndKey) as? Date {
            if now > blockEnd {
                // Current block has expired — clear everything.
                defaults?.removeObject(forKey: GetuppShared.activeBlockEndKey)
                if isShielded {
                    removeShield()
                    GetuppShared.logBreadcrumb("Reconcile: activeBlockEnd passed — shield cleared")
                }
            } else if !isShielded && !isVerifiedToday {
                // Should still be blocked but shield was lost (e.g. after reboot).
                applyShield()
                GetuppShared.logBreadcrumb("Reconcile: inside active block — shield reapplied")
            }
            return  // activeBlockEnd is the source of truth; schedule times are irrelevant here.
        }

        // ── No activeBlockEnd — derive expected state from WakeSchedule ──────────
        guard let schedule = wakeSchedule, schedule.isEnabled else { return }

        let insideWindow = schedule.isWindowActive(now: now)
        let verified     = GetuppShared.isVerifiedToday()
        let exempt       = GetuppShared.isExemptToday()

        if insideWindow && !verified && !exempt {
            if !isShielded {
                // Missed intervalDidStart.
                applyShield()
                recordActiveBlockEnd(for: schedule, now: now)
                GetuppShared.logBreadcrumb("Reconcile: missed intervalDidStart — shield applied")
            }
        } else if !insideWindow && isShielded && !verified {
            // Missed intervalDidEnd.
            removeShield()
            GetuppShared.logBreadcrumb("Reconcile: missed intervalDidEnd — shield cleared")
        }
    }

    // MARK: - Verification

    func markVerified() {
        let now = Date()
        GetuppShared.defaults?.set(now, forKey: GetuppShared.lastVerifiedDateKey)
        isVerifiedToday = true

        // Timeout (R1): shields STAY on. Write the clamped end time — the single
        // source of truth every clearing layer checks — and register the one-off
        // schedule (layer 1). Only when actually blocked: a debug verification
        // with no shield up shouldn't conjure one.
        if isShielded {
            let end = Timeout.beginTimeout(
                now: now,
                nextWindowStart: wakeSchedule?.nextWindowStart(after: now)
            )
            timeoutEndTime = end
            registerTimeoutSchedule(endingAt: end, now: now)
            GetuppShared.logBreadcrumb("Verified — timeout until \(end.formatted(date: .omitted, time: .shortened))")
        } else {
            GetuppShared.logBreadcrumb("Verified — no shield up, no timeout started")
        }

        GetuppShared.markVerifiedToday()
        refreshStreak()
    }

    /// Clearing layer 1: a one-off (non-repeating) DeviceActivity schedule ending
    /// at timeoutEndTime; the Monitor extension clears shields in intervalDidEnd.
    /// Also called on every extend with the new end time.
    private func registerTimeoutSchedule(endingAt end: Date, now: Date = Date()) {
        let center = DeviceActivityCenter()
        center.stopMonitoring([GetuppShared.timeoutActivityName])

        // DeviceActivity rejects intervals under 15 minutes. Layers 2 and 3 ask
        // the exact same question of the same stored value, so a short timeout
        // still ends on time — just without the scheduled callback.
        guard end.timeIntervalSince(now) >= 15 * 60 else {
            GetuppShared.logBreadcrumb("Timeout < 15 min — L1 schedule skipped, L2/L3 cover it")
            return
        }

        let calendar = Calendar.current
        let schedule = DeviceActivitySchedule(
            intervalStart: calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now),
            intervalEnd:   calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: end),
            repeats:       false
        )

        do {
            try center.startMonitoring(GetuppShared.timeoutActivityName, during: schedule)
            GetuppShared.logBreadcrumb("Timeout schedule registered — ends \(end.formatted(date: .omitted, time: .shortened))")
        } catch {
            // Not fatal: layers 2 and 3 still clear on time.
            GetuppShared.logBreadcrumb("Timeout schedule error: \(error.localizedDescription) — L2/L3 cover it")
        }
    }

    // MARK: - Timeout settings + extend

    /// R5: increases apply immediately; decreases queue for tomorrow.
    /// Returns true if the change queued (so the UI can call the cheat out).
    @discardableResult
    func setTimeoutDuration(_ requested: TimeInterval) -> Bool {
        Timeout.setDuration(requested)
        timeoutDuration        = Timeout.currentDuration
        pendingTimeoutDuration = Timeout.pendingDuration
        return pendingTimeoutDuration != nil
    }

    /// R6: one-tap extend. Adds to the running timeout (clamped to the next
    /// window start) and re-registers the layer-1 schedule with the new end.
    func extendTimeout(by delta: TimeInterval) {
        let now = Date()
        guard let newEnd = Timeout.extendTimeout(
            by: delta,
            now: now,
            nextWindowStart: wakeSchedule?.nextWindowStart(after: now)
        ) else { return }

        timeoutEndTime = newEnd
        registerTimeoutSchedule(endingAt: newEnd, now: now)
        GetuppShared.logBreadcrumb("Timeout extended — now ends \(newEnd.formatted(date: .omitted, time: .shortened))")
    }

    func clearVerifiedDate() {
        GetuppShared.defaults?.removeObject(forKey: GetuppShared.lastVerifiedDateKey)
        isVerifiedToday = false
        GetuppShared.logBreadcrumb("Debug: cleared lastVerifiedDate")

        // Undo any timeout the verification started, so debug state stays coherent.
        Timeout.clearAllTimeoutState()
        timeoutEndTime = nil
        DeviceActivityCenter().stopMonitoring([GetuppShared.timeoutActivityName])

        GetuppShared.clearVerifiedToday()
        refreshStreak()
    }

    // MARK: - Streak

    /// Snapshots today's scheduled state (first open of the day only), backfills
    /// any unresolved past dates, and recomputes the published streak.
    /// Called from init and every app-active transition (reconcileState).
    func refreshStreak() {
        GetuppShared.snapshotScheduledToday(schedule: wakeSchedule)
        streak = GetuppShared.currentStreak(schedule: wakeSchedule)
    }

    // MARK: - Shielding

    func applyShield() {
        GetuppShared.applyShield(selection: activitySelection)
        isShielded = true
    }

    func removeShield() {
        GetuppShared.removeShield()
        isShielded = false
    }

    /// Debug emergency unlock (offline-lockout safety net — must always work).
    /// Wipes the running timeout WITHOUT crediting minutes, then unshields.
    /// Plain removeShield() isn't enough mid-timeout: reconcileState would see
    /// timeoutEndTime still set and immediately re-shield.
    func debugEmergencyUnlock() {
        Timeout.clearAllTimeoutState()
        timeoutEndTime = nil
        DeviceActivityCenter().stopMonitoring([GetuppShared.timeoutActivityName])
        removeShield()
        GetuppShared.logBreadcrumb("Debug emergency unlock — timeout cleared, shield removed")
    }

    // MARK: - Persistence

    func saveSelection() {
        guard let defaults = UserDefaults(suiteName: GetuppShared.appGroupID) else { return }
        guard let data = try? JSONEncoder().encode(activitySelection) else { return }
        defaults.set(data, forKey: GetuppShared.selectionKey)
    }

    private func loadSelection() -> FamilyActivitySelection? {
        guard let data = GetuppShared.defaults?.data(forKey: GetuppShared.selectionKey) else { return nil }
        return try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
    }

    // MARK: - Computed helpers

    var selectedAppCount:      Int { activitySelection.applicationTokens.count }
    var selectedCategoryCount: Int { activitySelection.categoryTokens.count }

    var isBlockedAndUnverified: Bool { isShielded && !isVerifiedToday }

    // MARK: - Private helpers

    /// Records today's window-end time as activeBlockEnd in the App Group.
    private func recordActiveBlockEnd(for schedule: WakeSchedule, now: Date = Date()) {
        let calendar = Calendar.current
        var comps    = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour   = schedule.endHour
        comps.minute = schedule.endMinute
        comps.second = 0
        if let endDate = calendar.date(from: comps) {
            GetuppShared.defaults?.set(endDate, forKey: GetuppShared.activeBlockEndKey)
        }
    }

    private func formatTime(_ dc: DateComponents) -> String {
        String(format: "%02d:%02d", dc.hour ?? 0, dc.minute ?? 0)
    }
}

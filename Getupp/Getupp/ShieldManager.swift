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

    // MARK: - Published properties (Active Days)

    /// Which weekdays GETUPP arms (Calendar numbering, 1 = Sun … 7 = Sat).
    /// Mirrors the App Group key — ActiveDays.load() is the source of truth.
    @Published var activeDays: Set<Int>

    /// Day change queued for tomorrow (same-day removal rule), nil when none.
    @Published var pendingActiveDays: Set<Int>?

    // MARK: - Published properties (Escape Hatch)

    /// Pull the Plug's on/off switch. Mirrors GetuppShared.isAppEnabled().
    @Published var appEnabled: Bool

    /// Lifetime Emergency Break count (mirrors the App Group key).
    @Published var emergencyBreaksUsed: Int

    /// Non-nil while an Escape Hatch confirmation cover should be showing.
    /// Set by EscapeHatchView rows and the TimeoutCountdownView entry point;
    /// both doors open the same flow.
    @Published var activeEscape: EscapeAction?

    /// Drives ContentView's Settings NavigationLink. Escape Hatch lives behind
    /// Settings, but both its Cancel and post-confirmation CTA must land on
    /// Home, not just pop one level — so we bind the top of the stack here and
    /// flip it false to unwind the whole subtree at once.
    @Published var settingsPresented = false

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

        self.appEnabled          = GetuppShared.isAppEnabled()
        self.emergencyBreaksUsed = GetuppShared.emergencyBreaksUsed

        self.activeDays        = ActiveDays.load()
        self.pendingActiveDays = ActiveDays.loadPending()

        // All stored properties must be initialized before any instance method
        // call (loadSelection() below) — this must come after every other
        // `self.x = ...` assignment in this initializer.
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
        // A day-0 block is a real session — it needs its R6 anchor too.
        ActiveDays.setActiveSessionDate(GetuppShared.todayKey())
        GetuppShared.logBreadcrumb("Day-0 block applied immediately")
    }

    /// Case A — "Start tomorrow": write exemptDate so the Monitor extension skips today.
    func markExemptToday() {
        GetuppShared.defaults?.set(Date(), forKey: GetuppShared.exemptDateKey)
        GetuppShared.logBreadcrumb("Exempt today — schedule starts tomorrow")
    }

    // MARK: - Registration engine

    /// Stops all known window activities, then registers a new repeating schedule.
    /// ONE daily activity regardless of active days — the monitor gates each
    /// morning with ActiveDays.isScheduledToday(). Registering per-weekday
    /// activities would multiply the flaky-callback surface by 7 for no benefit.
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

        // Pull the Plug guard: a disabled GETUPP must never re-shield
        // "helpfully." Bail before any daily-maintenance or shield logic runs —
        // everything below this line assumes the app is live.
        guard GetuppShared.isAppEnabled() else {
            appEnabled = false
            return
        }
        appEnabled = true

        // Timeout daily maintenance first (clearing layer 2 — check-on-open):
        // completes an elapsed timeout (credits minutes, clears shields) and
        // promotes a queued downgrade. Idempotent; extensions run it too.
        Timeout.dailyMaintenance(now: now)

        // Schedule maintenance right after (same ordering as the monitor):
        // promotes a queued day change and sweeps a stale session date.
        ActiveDays.scheduleMaintenance(now: now)

        // Re-sync published state that maintenance (or an extension) may have
        // changed behind our back — the App Group is the source of truth.
        isShielded             = defaults?.bool(forKey: GetuppShared.shieldedKey) ?? false
        totalTimeoutMinutes    = Timeout.totalMinutes
        timeoutDuration        = Timeout.currentDuration
        pendingTimeoutDuration = Timeout.pendingDuration
        activeDays             = ActiveDays.load()
        pendingActiveDays      = ActiveDays.loadPending()

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

        // Day-aware (check-on-open layer for Active Days): an unscheduled day
        // is never "inside the window," even if the monitor misread the set.
        let insideWindow = schedule.isWindowActive(activeDays: activeDays, now: now)
        let verified     = GetuppShared.isVerifiedToday()
        let exempt       = GetuppShared.isExemptToday()

        if insideWindow && !verified && !exempt {
            if !isShielded {
                // Missed intervalDidStart — a recovered session still needs its
                // R6 anchor, same as the monitor writes at window arm.
                applyShield()
                recordActiveBlockEnd(for: schedule, now: now)
                ActiveDays.setActiveSessionDate(GetuppShared.todayKey(now: now))
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
                nextWindowStart: wakeSchedule?.nextWindowStart(after: now, activeDays: activeDays)
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
            nextWindowStart: wakeSchedule?.nextWindowStart(after: now, activeDays: activeDays)
        ) else { return }

        timeoutEndTime = newEnd
        registerTimeoutSchedule(endingAt: newEnd, now: now)
        GetuppShared.logBreadcrumb("Timeout extended — now ends \(newEnd.formatted(date: .omitted, time: .shortened))")
    }

    // MARK: - Active Days

    /// Saves a new active-days set with the same-day rule (mirrors Timeout R5):
    /// removing today while today's window hasn't ended queues for tomorrow;
    /// everything else applies immediately and cancels any queued change.
    /// Returns true if the removal queued (so the UI can call the cheat out).
    /// No re-registration — the single daily activity is untouched; the
    /// monitor's isScheduledToday() gate does the day-to-day governing.
    @discardableResult
    func setActiveDays(_ proposed: Set<Int>) -> Bool {
        let now     = Date()
        let current = ActiveDays.load()

        let result = ActiveDays.resolveSave(
            current: current,
            proposed: proposed,
            todayWeekday: Calendar.current.component(.weekday, from: now),
            todayLocked: isTodayWindowLocked(now: now)
        )

        ActiveDays.save(result.apply)
        if let queued = result.queued {
            ActiveDays.savePending(queued, now: now)
        } else {
            ActiveDays.clearPending()
        }

        activeDays        = result.apply
        pendingActiveDays = result.queued
        GetuppShared.logBreadcrumb(
            "Active days saved — \(result.apply.sorted())"
            + (result.queued.map { ", queued for tomorrow: \($0.sorted())" } ?? "")
        )
        return result.queued != nil
    }

    /// The same-day lock: today's window hasn't ended yet. Pre-window counts —
    /// removing today at 6:29 to dodge a 6:30 window is the same cheat as
    /// removing it mid-block.
    private func isTodayWindowLocked(now: Date) -> Bool {
        guard let schedule = wakeSchedule, schedule.isEnabled else { return false }
        let calendar = Calendar.current
        var comps    = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour   = schedule.endHour
        comps.minute = schedule.endMinute
        comps.second = 0
        guard let windowEnd = calendar.date(from: comps) else { return false }
        return now < windowEnd
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

    /// The shared no-credit wipe path. Wipes any running timeout WITHOUT
    /// crediting minutes, then unshields. Plain removeShield() isn't enough
    /// mid-timeout: reconcileState would see timeoutEndTime still set and
    /// immediately re-shield. Both the debug button and the real Escape Hatch
    /// actions (Emergency Break, Pull the Plug) call this — one wipe path,
    /// never duplicated.
    private func wipeTimeoutAndUnshield() {
        Timeout.clearAllTimeoutState()
        timeoutEndTime = nil
        DeviceActivityCenter().stopMonitoring([GetuppShared.timeoutActivityName])
        removeShield()
    }

    /// Debug emergency unlock (offline-lockout safety net — must always work).
    func debugEmergencyUnlock() {
        wipeTimeoutAndUnshield()
        GetuppShared.logBreadcrumb("Debug emergency unlock — timeout cleared, shield removed")
    }

    // MARK: - Escape Hatch

    /// One-day surrender. Works in BOTH blocked phases (morning window
    /// unverified, or verified-but-in-timeout) and must work fully offline —
    /// everything here is local App Group + ManagedSettings, no network calls
    /// anywhere in this path.
    ///
    /// markExemptToday() is required here, not decorative: unlike a normal
    /// morning (which sets isVerifiedToday) or Pull the Plug (which short-
    /// circuits reconcileState via appEnabled), clearing the shield alone
    /// leaves nothing telling reconcileState() "today is already handled."
    /// Without it, reconcileState — which re-runs almost immediately, since
    /// dismissing the confirmation's fullScreenCover re-triggers ContentView's
    /// onAppear — sees "inside window, unverified, not exempt, not shielded"
    /// and reads that as a missed intervalDidStart, re-applying the shield
    /// within the same second. Reusing exemptDate is exactly right: it means
    /// "don't shield again today," which is precisely the one-day-surrender
    /// contract, and it auto-clears at midnight so tomorrow's window is
    /// untouched.
    func emergencyBreak() {
        // Mark BEFORE the wipe (R6): markEmergencyUsedToday anchors to
        // activeSessionDate, and wipeTimeoutAndUnshield → removeShield clears
        // that key. A post-midnight break mid-timeout must mark the session's
        // day (yesterday), not today.
        GetuppShared.markEmergencyUsedToday()
        wipeTimeoutAndUnshield()
        markExemptToday()
        GetuppShared.incrementEmergencyBreaksUsed()
        emergencyBreaksUsed = GetuppShared.emergencyBreaksUsed
        refreshStreak()
        // Deliberately NOT touching the schedule — tomorrow's window fires
        // normally. This is a one-day surrender, not a pause.
        GetuppShared.logBreadcrumb("Emergency Break confirmed — apps unblocked for today")
    }

    /// Full surrender. Stops all monitoring, clears any shield, and flips
    /// appEnabled off. Deletes nothing — selection, wake window, timeout
    /// duration, and any queued downgrade all survive untouched.
    func pullThePlug() {
        // Also write the broken DayRecord, not just appEnabled=false. appEnabled
        // only zeroes the streak WHILE disabled (see deriveStreak's early return);
        // the broken record is what stops the backward walk after re-enable, so
        // successes from before Pull the Plug can't resurrect the old streak
        // ("no backdating"). Looks redundant with appEnabled=false — isn't.
        // BEFORE the wipe (R6): it anchors to activeSessionDate, which
        // wipeTimeoutAndUnshield → removeShield clears.
        GetuppShared.markEmergencyUsedToday()

        stopMonitoring()
        wipeTimeoutAndUnshield()
        GetuppShared.setAppEnabled(false)
        appEnabled = false

        refreshStreak()
        GetuppShared.logBreadcrumb("Pull the Plug confirmed — GETUPP disabled")
    }

    /// Frictionless re-enable. No confirmation, no countdown. Restores the
    /// last-saved schedule and re-registers monitoring for the NEXT window.
    ///
    /// markExemptToday() looks like a leftover debug call — it isn't. Without
    /// it, re-enabling mid-window would let reconcileState (or a missed
    /// intervalDidStart) shield the user again THIS window, which is a hostile
    /// re-onboarding (shielding someone at 2pm the moment they turn it back
    /// on). Today is a wash; blocking resumes at the next intervalDidStart.
    func turnBackOn() {
        GetuppShared.setAppEnabled(true)
        appEnabled = true
        markExemptToday()

        if let schedule = wakeSchedule {
            saveWakeSchedule(schedule)
        }

        refreshStreak()
        GetuppShared.logBreadcrumb("Turned back on — schedule re-registered, today exempt")
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

    /// Derived, never stored — same principle as Timeout.swift. Used by
    /// EscapeHatchView to disable the Emergency Break row when there's nothing
    /// to escape from (.free / .preWindow).
    var currentPhase: Timeout.Phase {
        let now = Date()
        var windowStart: Date?
        var windowEnd: Date?

        // Unscheduled days have no window: derivePhase reads .free (a running
        // timeout still wins), which keeps the Emergency Break row correctly
        // disabled on a rest day.
        if let schedule = wakeSchedule, ActiveDays.isScheduledToday(now: now) {
            let calendar = Calendar.current
            var startComps = calendar.dateComponents([.year, .month, .day], from: now)
            startComps.hour   = schedule.startHour
            startComps.minute = schedule.startMinute
            startComps.second = 0
            windowStart = calendar.date(from: startComps)

            var endComps = calendar.dateComponents([.year, .month, .day], from: now)
            endComps.hour   = schedule.endHour
            endComps.minute = schedule.endMinute
            endComps.second = 0
            windowEnd = calendar.date(from: endComps)
        }

        return Timeout.derivePhase(
            now: now,
            windowStart: windowStart,
            windowEnd: windowEnd,
            isVerifiedToday: isVerifiedToday,
            timeoutEndTime: timeoutEndTime
        )
    }

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

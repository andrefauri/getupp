//
//  ShieldManager.swift
//  Getupp
//
//  This is the production-quality module that manages all Family Controls logic.
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
    /// Possible values: .notDetermined, .denied, .approved
    @Published var authorizationStatus: AuthorizationStatus

    /// The apps and categories the user selected to block.
    /// FamilyActivitySelection holds opaque tokens — we can count them but not see names.
    @Published var activitySelection = FamilyActivitySelection() {
        // Belt-and-suspenders: fires when code sets this directly.
        // NOTE: does NOT fire when SwiftUI writes through a Binding (e.g. the picker).
        // The view handles that case via .onChange(of:).
        didSet { saveSelection() }
    }

    // MARK: - Published properties (verification state)

    /// Whether the user has verified (passed photo check) today.
    @Published var isVerifiedToday: Bool

    // MARK: - Published properties (shield state)

    /// Whether shields are currently active. Persisted so the UI reflects reality after restart.
    @Published var isShielded: Bool

    /// Whether a DeviceActivity schedule is currently registered.
    @Published var isMonitoring: Bool

    /// The scheduled window start/end times, for display in the UI.
    @Published var scheduleStart: DateComponents?
    @Published var scheduleEnd: DateComponents?

    // MARK: - Constants (delegated to GetuppShared so the extension can reuse them)

    private let appGroupID  = GetuppShared.appGroupID
    private let selectionKey = GetuppShared.selectionKey
    private let shieldedKey  = GetuppShared.shieldedKey

    // ManagedSettingsStore is the API that actually applies/removes shields.
    // Using the shared store ensures the extension and app target the same settings.
    private let store = GetuppShared.store

    // Holds our Combine subscription so it stays alive as long as ShieldManager does.
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        // Read current authorization status synchronously at startup.
        self.authorizationStatus = AuthorizationCenter.shared.authorizationStatus

        // Restore persisted shield state. ManagedSettings shields survive app restarts
        // on their own (they're system-level), but we need to know the state for the UI.
        // Must be initialized before loadSelection() below — Swift requires all stored
        // properties to be set before any self method is called.
        let defaults = UserDefaults(suiteName: GetuppShared.appGroupID)
        self.isShielded      = defaults?.bool(forKey: GetuppShared.shieldedKey)    ?? false
        self.isMonitoring    = defaults?.bool(forKey: GetuppShared.isMonitoringKey) ?? false
        self.isVerifiedToday = GetuppShared.isVerifiedToday()
        self.scheduleStart   = nil
        self.scheduleEnd     = nil

        // Restore any selection the user made in a previous session.
        self.activitySelection = loadSelection() ?? FamilyActivitySelection()

        // Reconciliation: if user passed verification today but shield is still active
        // (e.g. app was killed between pass and removeShield), clear it now.
        if self.isVerifiedToday && self.isShielded {
            GetuppShared.removeShield()
            self.isShielded = false
        }

        // AuthorizationCenter loads its true status asynchronously after launch.
        // This subscription catches that update and any future changes (e.g. user
        // revokes permission in Settings) and keeps our @Published status in sync.
        AuthorizationCenter.shared
            .objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.authorizationStatus = AuthorizationCenter.shared.authorizationStatus
            }
            .store(in: &cancellables)
    }

    // MARK: - Authorization

    /// Asks the system to show the Family Controls authorization prompt.
    /// Must be called inside a Task{} because it's async.
    @MainActor
    func requestAuthorization() async {
        do {
            // .individual means this app manages screen time for the device owner (not a child).
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        } catch {
            // Authorization was denied or an error occurred — not a crash.
            print("[ShieldManager] Authorization error: \(error)")
        }
        // Re-read status after the system prompt is dismissed.
        self.authorizationStatus = AuthorizationCenter.shared.authorizationStatus
    }

    // MARK: - Scheduling

    /// Registers a daily DeviceActivity schedule.
    /// When the window starts, the Monitor extension calls intervalDidStart and applies shields.
    /// When it ends, it calls intervalDidEnd and removes them.
    ///
    /// - Parameters:
    ///   - start: When the blocking window begins each day (hour/minute).
    ///   - end:   When it ends each day (hour/minute).
    func startMonitoring(start: DateComponents, end: DateComponents) {
        // DeviceActivitySchedule is wall-clock based (hour:minute), repeating daily.
        let schedule = DeviceActivitySchedule(
            intervalStart: start,
            intervalEnd: end,
            repeats: true
        )

        do {
            // DeviceActivityCenter is the system API that registers the schedule.
            // It launches the Monitor extension process at the scheduled times.
            try DeviceActivityCenter().startMonitoring(GetuppShared.activityName, during: schedule)
            isMonitoring  = true
            scheduleStart = start
            scheduleEnd   = end
            GetuppShared.defaults?.set(true, forKey: GetuppShared.isMonitoringKey)
            GetuppShared.logBreadcrumb("Monitoring started — window \(formatTime(start))–\(formatTime(end))")
        } catch {
            print("[ShieldManager] Failed to start monitoring: \(error)")
            GetuppShared.logBreadcrumb("startMonitoring error: \(error)")
        }
    }

    /// Cancels the registered schedule. The extension won't fire again until re-registered.
    func stopMonitoring() {
        DeviceActivityCenter().stopMonitoring([GetuppShared.activityName])
        isMonitoring = false
        GetuppShared.defaults?.set(false, forKey: GetuppShared.isMonitoringKey)
        GetuppShared.logBreadcrumb("Monitoring stopped")
    }

    /// Convenience: schedules a debug window starting ~2 minutes from now, lasting 15 minutes.
    /// Apple enforces a minimum interval of 15 minutes for DeviceActivity schedules.
    func startDebugWindow() {
        let now = Date()
        let startDate = now.addingTimeInterval(2 * 60)   // 2 minutes from now
        let endDate   = now.addingTimeInterval(17 * 60)  // 17 minutes from now (15 min window)

        let cal = Calendar.current
        let start = cal.dateComponents([.hour, .minute], from: startDate)
        let end   = cal.dateComponents([.hour, .minute], from: endDate)

        startMonitoring(start: start, end: end)
    }

    // Formats DateComponents (hour/minute) as "HH:MM" for display.
    private func formatTime(_ dc: DateComponents) -> String {
        let h = dc.hour ?? 0
        let m = dc.minute ?? 0
        return String(format: "%02d:%02d", h, m)
    }

    // MARK: - Verification

    /// Called when the user passes the photo check.
    /// Writes today's date as lastVerifiedDate (calendar-day, local timezone),
    /// then removes the shield immediately.
    func markVerified() {
        // Store the exact timestamp. isVerifiedToday() uses Calendar.isDateInToday()
        // which compares calendar days in the device's local timezone — not a 24h delta.
        GetuppShared.defaults?.set(Date(), forKey: GetuppShared.lastVerifiedDateKey)
        isVerifiedToday = true
        GetuppShared.logBreadcrumb("Verified — removing shield")
        removeShield()
    }

    /// Debug helper: clears lastVerifiedDate so the next schedule window will re-block.
    func clearVerifiedDate() {
        GetuppShared.defaults?.removeObject(forKey: GetuppShared.lastVerifiedDateKey)
        isVerifiedToday = false
        GetuppShared.logBreadcrumb("Debug: cleared lastVerifiedDate")
    }

    // MARK: - Shielding

    /// Applies shields to all selected apps and categories.
    /// ManagedSettings shields are system-level — they persist even if GETUPP is killed.
    func applyShield() {
        GetuppShared.applyShield(selection: activitySelection)
        isShielded = true
    }

    /// Removes all shields, unblocking every app immediately.
    func removeShield() {
        GetuppShared.removeShield()
        isShielded = false
    }

    // MARK: - Persistence

    /// Encodes the current selection as JSON and saves it to the shared App Group.
    /// The App Group lets the Monitor and Shield extensions read the same data later.
    func saveSelection() {
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            print("[ShieldManager] Could not access App Group UserDefaults")
            return
        }
        do {
            let data = try JSONEncoder().encode(activitySelection)
            defaults.set(data, forKey: selectionKey)
        } catch {
            print("[ShieldManager] Failed to save selection: \(error)")
        }
    }

    /// Loads a previously saved selection from the App Group. Returns nil if none exists.
    private func loadSelection() -> FamilyActivitySelection? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: selectionKey) else { return nil }
        do {
            return try JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        } catch {
            print("[ShieldManager] Failed to load selection: \(error)")
            return nil
        }
    }

    // MARK: - Computed helpers

    /// Number of individual app tokens selected.
    var selectedAppCount: Int {
        activitySelection.applicationTokens.count
    }

    /// Number of category tokens selected (e.g. "Social", "Games").
    var selectedCategoryCount: Int {
        activitySelection.categoryTokens.count
    }
}

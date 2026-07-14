//
//  ShieldManager.swift
//  Getupp
//
//  This is the production-quality module that manages all Family Controls logic.
//  Views call into this class; no Family Controls code lives in views.
//

import Combine
import FamilyControls
import Foundation

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

    // MARK: - Constants

    private let appGroupID = "group.co.getupp.app"
    private let selectionKey = "familyActivitySelection"

    // Holds our Combine subscription so it stays alive as long as ShieldManager does.
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init() {
        // Read current authorization status synchronously at startup.
        self.authorizationStatus = AuthorizationCenter.shared.authorizationStatus

        // Restore any selection the user made in a previous session.
        self.activitySelection = loadSelection() ?? FamilyActivitySelection()

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

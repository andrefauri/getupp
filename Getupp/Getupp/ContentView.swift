//
//  ContentView.swift
//  Getupp
//
//  Main screen state machine + throwaway debug controls.
//

import FamilyControls
import SwiftUI

struct ContentView: View {

    @EnvironmentObject var shieldManager: ShieldManager
    @State private var isPickerPresented = false
    @State private var breadcrumbs: [String] = []

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {

                    // ── MAIN PRODUCT STATE ────────────────────────────────
                    mainStateSection

                    // ── DEBUG CONTROLS ────────────────────────────────────
                    debugSection
                }
                .padding()
            }
            .navigationTitle("GETUPP")
            .onAppear {
                breadcrumbs = GetuppShared.loadBreadcrumbs()
            }
            .familyActivityPicker(
                isPresented: $isPickerPresented,
                selection: $shieldManager.activitySelection
            )
            .onChange(of: shieldManager.activitySelection) { _ in
                shieldManager.saveSelection()
            }
        }
    }

    // MARK: - Main state section

    /// Three mutually exclusive states:
    /// 1. Verified today → done screen
    /// 2. Shielded and not verified → "take the photo" CTA
    /// 3. Otherwise → idle (window hasn't started yet, or manual block)
    @ViewBuilder
    private var mainStateSection: some View {
        if shieldManager.isVerifiedToday {
            verifiedTodayView
        } else if shieldManager.isShielded {
            needsVerificationView
        } else {
            idleView
        }
    }

    private var verifiedTodayView: some View {
        GroupBox {
            VStack(spacing: 12) {
                Text("✓ You're up.")
                    .font(.title.bold())
                    .foregroundColor(.green)
                Text("Apps are unblocked for today.")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var needsVerificationView: some View {
        GroupBox {
            VStack(spacing: 16) {
                Text("Apps are blocked.")
                    .font(.headline)
                    .foregroundColor(.red)
                Text("Prove you're out of bed to unlock them.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                NavigationLink(destination: CameraView()) {
                    Label("Take the Photo", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var idleView: some View {
        GroupBox {
            VStack(spacing: 12) {
                Text("No active block window.")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Text("Use the debug controls below to test the full flow.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Debug section

    private var debugSection: some View {
        VStack(spacing: 16) {
            Text("Debug")
                .font(.caption.uppercaseSmallCaps())
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Authorization
            GroupBox("Authorization") {
                VStack(spacing: 12) {
                    HStack {
                        Text("Status:")
                        Spacer()
                        Text(statusText)
                            .bold()
                            .foregroundColor(statusColor)
                    }
                    Button("Request Authorization") {
                        Task { await shieldManager.requestAuthorization() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(shieldManager.authorizationStatus == .approved)
                }
                .padding(.vertical, 4)
            }

            // App selection
            GroupBox("App Selection") {
                VStack(spacing: 12) {
                    HStack {
                        Text("Apps selected:")
                        Spacer()
                        Text("\(shieldManager.selectedAppCount)").monospacedDigit()
                    }
                    HStack {
                        Text("Categories selected:")
                        Spacer()
                        Text("\(shieldManager.selectedCategoryCount)").monospacedDigit()
                    }
                    Button("Choose Apps to Block") { isPickerPresented = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(shieldManager.authorizationStatus != .approved)
                }
                .padding(.vertical, 4)
            }

            // Manual shield
            GroupBox("Shield") {
                VStack(spacing: 12) {
                    HStack {
                        Text("State:")
                        Spacer()
                        Text(shieldManager.isShielded ? "BLOCKED" : "Unblocked")
                            .bold()
                            .foregroundColor(shieldManager.isShielded ? .red : .green)
                    }
                    HStack(spacing: 12) {
                        Button("Block Now") { shieldManager.applyShield() }
                            .buttonStyle(.borderedProminent).tint(.red)
                            .disabled(shieldManager.isShielded
                                      || shieldManager.selectedAppCount + shieldManager.selectedCategoryCount == 0)
                        Button("Unblock Now") { shieldManager.removeShield() }
                            .buttonStyle(.borderedProminent).tint(.green)
                            .disabled(!shieldManager.isShielded)
                    }
                }
                .padding(.vertical, 4)
            }

            // Verification debug
            GroupBox("Verification") {
                VStack(spacing: 12) {
                    HStack {
                        Text("Verified today:")
                        Spacer()
                        Text(shieldManager.isVerifiedToday ? "Yes" : "No")
                            .bold()
                            .foregroundColor(shieldManager.isVerifiedToday ? .green : .secondary)
                    }
                    HStack(spacing: 12) {
                        // Go to camera (always accessible for testing)
                        NavigationLink(destination: CameraView()) {
                            Label("Verify", systemImage: "camera.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)

                        // Simulate next-morning reset: clears lastVerifiedDate so next
                        // schedule window will re-block as if it's a new day.
                        Button("Clear Verified") {
                            shieldManager.clearVerifiedDate()
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                        .disabled(!shieldManager.isVerifiedToday)
                    }
                }
                .padding(.vertical, 4)
            }

            // Schedule
            GroupBox("Schedule") {
                VStack(spacing: 12) {
                    HStack {
                        Text("Monitoring:")
                        Spacer()
                        Text(shieldManager.isMonitoring ? "Active" : "Off")
                            .bold()
                            .foregroundColor(shieldManager.isMonitoring ? .green : .secondary)
                    }
                    if let start = shieldManager.scheduleStart,
                       let end   = shieldManager.scheduleEnd {
                        HStack {
                            Text("Window:")
                            Spacer()
                            Text("\(formatTime(start)) – \(formatTime(end))").monospacedDigit()
                        }
                    }
                    HStack(spacing: 12) {
                        Button("Debug Window\n(+2 min, 15m)") {
                            shieldManager.startDebugWindow()
                            breadcrumbs = GetuppShared.loadBreadcrumbs()
                        }
                        .buttonStyle(.borderedProminent)
                        .multilineTextAlignment(.center)
                        .disabled(shieldManager.authorizationStatus != .approved)

                        Button("Stop Schedule") {
                            shieldManager.stopMonitoring()
                            breadcrumbs = GetuppShared.loadBreadcrumbs()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!shieldManager.isMonitoring)
                    }
                }
                .padding(.vertical, 4)
            }

            // Extension log
            GroupBox("Extension Log") {
                VStack(alignment: .leading, spacing: 6) {
                    if breadcrumbs.isEmpty {
                        Text("No events yet").foregroundColor(.secondary).font(.caption)
                    } else {
                        ForEach(breadcrumbs.reversed().prefix(8), id: \.self) { crumb in
                            Text(crumb).font(.caption).monospacedDigit()
                        }
                    }
                    Button("Refresh Log") {
                        breadcrumbs = GetuppShared.loadBreadcrumbs()
                    }
                    .font(.caption)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Helpers

    private func formatTime(_ dc: DateComponents) -> String {
        String(format: "%02d:%02d", dc.hour ?? 0, dc.minute ?? 0)
    }

    private var statusText: String {
        switch shieldManager.authorizationStatus {
        case .notDetermined: return "Not Determined"
        case .denied:        return "Denied"
        case .approved:      return "Approved"
        @unknown default:    return "Unknown"
        }
    }

    private var statusColor: Color {
        switch shieldManager.authorizationStatus {
        case .approved: return .green
        case .denied:   return .red
        default:        return .orange
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(ShieldManager())
}

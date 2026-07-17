//
//  ContentView.swift
//  Getupp
//
//  Main screen — two zones:
//    USER ZONE  · Wake Window card + product state (above divider)
//    DEBUG ZONE · Throwaway controls below the DEBUG divider
//

import FamilyControls
import SwiftUI

struct ContentView: View {

    @EnvironmentObject var shieldManager: ShieldManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var isPickerPresented = false
    @State private var showEditSheet     = false
    @State private var breadcrumbs:  [String] = []
    #if DEBUG
    @State private var dayLog:          [DayRecord] = []
    @State private var selfTestResults: [String]    = []
    #endif

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {

                    // ── USER ZONE ─────────────────────────────────────────────
                    streakCard
                    mainStateSection
                    wakeWindowCard
                    appSelectionCard

                    #if DEBUG
                    // ── DEBUG DIVIDER ─────────────────────────────────────────
                    debugDivider

                    // ── DEBUG ZONE ────────────────────────────────────────────
                    debugSection
                    #endif
                }
                .padding()
            }
            .navigationTitle("GETUPP")
            .onAppear {
                breadcrumbs = GetuppShared.loadBreadcrumbs()
                shieldManager.reconcileState()
                #if DEBUG
                dayLog = GetuppShared.loadDayLog()
                #endif
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    shieldManager.reconcileState()
                    breadcrumbs = GetuppShared.loadBreadcrumbs()
                    #if DEBUG
                    dayLog = GetuppShared.loadDayLog()
                    #endif
                }
            }
            .familyActivityPicker(
                isPresented: $isPickerPresented,
                selection: $shieldManager.activitySelection
            )
            .onChange(of: shieldManager.activitySelection) { _ in
                shieldManager.saveSelection()
            }
            .sheet(isPresented: $showEditSheet) {
                WakeWindowEditSheet(existing: shieldManager.wakeSchedule)
                    .environmentObject(shieldManager)
            }
        }
    }

    // MARK: - Streak card (user zone)

    private var streakCard: some View {
        GroupBox {
            VStack(spacing: 4) {
                Text(streakHeadline)
                    .font(.title2.bold())
                Text(streakSubline)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var streakHeadline: String {
        let count = shieldManager.streak.count
        guard count > 0 else { return "No streak. Get up." }
        return "🔥 \(count) morning\(count == 1 ? "" : "s")"
    }

    private var streakSubline: String {
        shieldManager.streak.count > 0 ? "Don't break it." : "Take the photo tomorrow."
    }

    // MARK: - Main state section (user zone)

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
                Text("Set your wake window below to arm the shield.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Wake Window card (user zone)

    private var wakeWindowCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("WAKE WINDOW")
                    .font(.caption.uppercaseSmallCaps())
                    .foregroundColor(.secondary)

                if let schedule = shieldManager.wakeSchedule {
                    Text(schedule.summaryLine)
                        .font(.headline)

                    HStack {
                        Text("Monitoring:")
                        Spacer()
                        Text(shieldManager.isMonitoring ? "Active" : "Off")
                            .bold()
                            .foregroundColor(shieldManager.isMonitoring ? .green : .secondary)
                    }

                    if let err = shieldManager.scheduleError {
                        Text("Error: \(err)")
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    Button("Edit Window") { showEditSheet = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(shieldManager.authorizationStatus != .approved)
                } else {
                    Text("No window set.")
                        .foregroundColor(.secondary)

                    Button("Set Wake Window") { showEditSheet = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(shieldManager.authorizationStatus != .approved)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
    }

    // MARK: - App Selection card (user zone)

    private var appSelectionCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("APPS TO BLOCK")
                    .font(.caption.uppercaseSmallCaps())
                    .foregroundColor(.secondary)

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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Debug divider + section

    #if DEBUG
    private var debugDivider: some View {
        HStack {
            Rectangle().frame(height: 1).foregroundColor(.secondary.opacity(0.3))
            Text("DEBUG")
                .font(.caption.uppercaseSmallCaps())
                .foregroundColor(.secondary)
                .fixedSize()
            Rectangle().frame(height: 1).foregroundColor(.secondary.opacity(0.3))
        }
    }

    private var debugSection: some View {
        VStack(spacing: 16) {

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
                        NavigationLink(destination: CameraView()) {
                            Label("Verify", systemImage: "camera.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)

                        Button("Clear Verified") {
                            shieldManager.clearVerifiedDate()
                            #if DEBUG
                            dayLog = GetuppShared.loadDayLog()
                            #endif
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                        .disabled(!shieldManager.isVerifiedToday)
                    }
                }
                .padding(.vertical, 4)
            }

            // Streak debug
            GroupBox("Streak") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Streak:")
                        Spacer()
                        Text("\(shieldManager.streak.count) (\(String(describing: shieldManager.streak.todayState)))")
                            .monospacedDigit()
                    }

                    if dayLog.isEmpty {
                        Text("No day-log entries yet")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(dayLog.sorted(by: { $0.date > $1.date }).prefix(10), id: \.date) { record in
                                Text("\(record.date) · sched:\(record.wasScheduled ? "✓" : "·") ran:\(record.sessionRan ? "✓" : "·") ver:\(record.verified ? "✓" : "·") emg:\(record.emergencyUsed ? "✓" : "·")")
                                    .font(.caption.monospaced())
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        Button("Refresh Log") {
                            dayLog = GetuppShared.loadDayLog()
                        }
                        .buttonStyle(.bordered)

                        Button("Reset Day Log") {
                            GetuppShared.saveDayLog([])
                            dayLog = []
                            shieldManager.refreshStreak()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)

                        Button("Run Self-Tests") {
                            selfTestResults = runStreakSelfTests()
                        }
                        .buttonStyle(.bordered)
                        .tint(.indigo)
                    }

                    if !selfTestResults.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(selfTestResults, id: \.self) { line in
                                Text(line)
                                    .font(.caption2.monospaced())
                                    .foregroundColor(line.hasPrefix("PASS") ? .green : .red)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // Schedule debug (Stop Schedule + Debug Window)
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
    #endif

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

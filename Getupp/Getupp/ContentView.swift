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
    @State private var showCustomTimeout = false
    @State private var showStreakDialog  = false
    @State private var timeoutCopyLine   = ""
    @State private var breadcrumbs:  [String] = []
    #if DEBUG
    @State private var dayLog:                 [DayRecord] = []
    @State private var selfTestResults:        [String]    = []
    @State private var timeoutSelfTestResults: [String]    = []
    #endif

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {

                    // ── USER ZONE ─────────────────────────────────────────────
                    streakCard
                    mainStateSection
                    wakeWindowCard
                    timeoutCard
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
            .sheet(isPresented: $showCustomTimeout) {
                CustomTimeoutSheet { seconds in
                    applyTimeoutSelection(seconds)
                }
            }
            .sheet(isPresented: $showStreakDialog) {
                StreakDialog(
                    streakCount: shieldManager.streak.count,
                    totalTimeoutMinutes: shieldManager.totalTimeoutMinutes
                )
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
            .contentShape(Rectangle())
            .onTapGesture { showStreakDialog = true }   // R9: streak + benched minutes
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
        if shieldManager.timeoutEndTime != nil {
            timeoutView
        } else if shieldManager.isVerifiedToday {
            verifiedTodayView
        } else if shieldManager.isShielded {
            needsVerificationView
        } else {
            idleView
        }
    }

    private var timeoutView: some View {
        GroupBox {
            TimeoutCountdownView()
                .padding(.vertical, 8)
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

    // MARK: - Timeout card (user zone)

    /// Preset row (R4). Order matters — escalating commitment, 30 min default.
    private let timeoutPresets: [(label: String, seconds: TimeInterval)] = [
        ("15m", 15 * 60), ("30m", 30 * 60), ("1h", 3600), ("2h", 2 * 3600), ("5h", 5 * 3600),
    ]

    private var timeoutCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("TIMEOUT")
                    .font(.caption.uppercaseSmallCaps())
                    .foregroundColor(.secondary)

                Text("After the photo, apps stay blocked for:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    ForEach(timeoutPresets, id: \.label) { preset in
                        presetButton(preset.label, preset.seconds)
                    }
                }

                Button("Custom…") { showCustomTimeout = true }
                    .font(.caption)

                if let pending = shieldManager.pendingTimeoutDuration {
                    Text("\(durationLabel(shieldManager.timeoutDuration)) → \(durationLabel(pending)) tomorrow")
                        .font(.caption.bold())
                        .foregroundColor(.orange)
                }

                if !timeoutCopyLine.isEmpty {
                    Text(timeoutCopyLine)
                        .font(.caption.italic())
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func presetButton(_ label: String, _ seconds: TimeInterval) -> some View {
        let isActive = shieldManager.timeoutDuration == seconds
        Button {
            applyTimeoutSelection(seconds)
        } label: {
            Text(label)
                .font(.callout.bold())
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(isActive ? .indigo : .secondary)
    }

    /// Shared by presets and the custom sheet: applies R5 (increase now,
    /// decrease tomorrow) and picks the matching copy line.
    private func applyTimeoutSelection(_ seconds: TimeInterval) {
        let queued = shieldManager.setTimeoutDuration(seconds)
        timeoutCopyLine = queued
            ? TimeoutCopy.line(for: .downgradeBlocked)
            : TimeoutCopy.line(for: TimeoutCopy.pool(forPresetDuration: seconds))
    }

    private func durationLabel(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 60 && minutes % 60 == 0 { return "\(minutes / 60) h" }
        return "\(minutes) min"
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
                        // Emergency unlock (offline safety net): also wipes any
                        // running timeout, else reconcile would re-shield instantly.
                        Button("Unblock Now") { shieldManager.debugEmergencyUnlock() }
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

            // Timeout debug
            GroupBox("Timeout") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Duration:")
                        Spacer()
                        Text("\(Int(Timeout.currentDuration / 60)) min").monospacedDigit()
                    }
                    HStack {
                        Text("Running until:")
                        Spacer()
                        Text(shieldManager.timeoutEndTime.map {
                            $0.formatted(date: .omitted, time: .shortened)
                        } ?? "—").monospacedDigit()
                    }
                    HStack {
                        Text("Total minutes:")
                        Spacer()
                        Text("\(shieldManager.totalTimeoutMinutes)").monospacedDigit()
                    }

                    HStack(spacing: 12) {
                        // Deliberately below the 15-min floor so tests run fast —
                        // exercises layers 2/3, since layer 1 skips < 15 min.
                        Button("Set 2-min Timeout") {
                            GetuppShared.defaults?.set(120.0, forKey: Timeout.timeoutDurationKey)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)

                        Button("Reset to 30 min") {
                            GetuppShared.defaults?.set(Timeout.defaultDuration, forKey: Timeout.timeoutDurationKey)
                        }
                        .buttonStyle(.bordered)
                    }

                    Button("Run Timeout Self-Tests") {
                        timeoutSelfTestResults = runTimeoutSelfTests()
                    }
                    .buttonStyle(.bordered)
                    .tint(.indigo)

                    if !timeoutSelfTestResults.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(timeoutSelfTestResults, id: \.self) { line in
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
        case .notDetermined:          return "Not Determined"
        case .denied:                 return "Denied"
        case .approved:               return "Approved"
        case .approvedWithDataAccess: return "Approved"
        @unknown default:             return "Unknown"
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

// MARK: - Custom timeout sheet (R4 custom entry)

/// Minimal wheel picker: floor 15 min (DeviceActivity minimum), cap 8 h.
/// Timeout.setDuration clamps too — this UI just makes the bounds visible.
private struct CustomTimeoutSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var hours   = 0
    @State private var minutes = 30

    let onSave: (TimeInterval) -> Void

    private var totalSeconds: TimeInterval {
        TimeInterval(hours * 3600 + minutes * 60)
    }
    private var isValid: Bool {
        totalSeconds >= Timeout.minDuration && totalSeconds <= Timeout.maxDuration
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                HStack(spacing: 0) {
                    Picker("Hours", selection: $hours) {
                        ForEach(0...8, id: \.self) { Text("\($0) h") }
                    }
                    .pickerStyle(.wheel)

                    Picker("Minutes", selection: $minutes) {
                        ForEach([0, 15, 30, 45], id: \.self) { Text("\($0) min") }
                    }
                    .pickerStyle(.wheel)
                }
                .frame(height: 160)

                if !isValid {
                    Text("Between 15 minutes and 8 hours.")
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Button("Save") {
                    onSave(totalSeconds)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
            .padding()
            .navigationTitle("Custom Timeout")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Streak dialog (R9)

/// Streak number big and centered, its label beneath, total timeout minutes
/// below that. Nothing else for now.
private struct StreakDialog: View {
    let streakCount: Int
    let totalTimeoutMinutes: Int

    var body: some View {
        VStack(spacing: 12) {
            Text("\(streakCount)")
                .font(.system(size: 96, weight: .black).monospacedDigit())

            Text("morning\(streakCount == 1 ? "" : "s")")
                .font(.title3.bold())
                .foregroundColor(.secondary)

            Text("apps benched: \(totalTimeoutMinutes) min")
                .font(.headline)
                .foregroundColor(.orange)
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationDetents([.medium])
    }
}

#Preview {
    ContentView()
        .environmentObject(ShieldManager())
}

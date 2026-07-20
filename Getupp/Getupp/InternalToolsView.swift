//
//  InternalToolsView.swift
//  Getupp
//
//  Debug-only tools — throwaway controls for exercising authorization,
//  shielding, verification, streak, timeout, and schedule state by hand.
//  Reachable from Settings → Internal Tools. Stripped from release builds.
//

#if DEBUG
import FamilyControls
import SwiftUI

struct InternalToolsView: View {

    @EnvironmentObject var shieldManager: ShieldManager

    @State private var breadcrumbs:               [String]     = []
    @State private var dayLog:                    [DayRecord]  = []
    @State private var selfTestResults:           [String]     = []
    @State private var timeoutSelfTestResults:    [String]     = []
    @State private var escapeSelfTestResults:     [String]     = []
    @State private var activeDaysSelfTestResults: [String]     = []
    @State private var sessionDateReadout:        String       = "—"

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {

                // Reset — clears cross-test residue (exemptDate, lastVerifiedDate,
                // timeout state, day log, appEnabled, emergencyBreaksUsed, breadcrumbs)
                // back to fresh-install defaults. Deliberately leaves activitySelection
                // and the wake schedule alone — those are real configuration, not
                // test-session noise, and clearing them would make every reset a chore.
                GroupBox("Reset") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Clears exempt/verified/timeout/day-log/escape-hatch state so each manual test starts clean. Leaves your app selection and wake window alone.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button("Reset Test State") {
                            resetTestState()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                    .padding(.vertical, 4)
                }

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
                                dayLog = GetuppShared.loadDayLog()
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

                // Escape Hatch debug
                GroupBox("Escape Hatch") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("App enabled:")
                            Spacer()
                            Text(shieldManager.appEnabled ? "Yes" : "No")
                                .bold()
                                .foregroundColor(shieldManager.appEnabled ? .green : .red)
                        }
                        HStack {
                            Text("Emergency breaks used:")
                            Spacer()
                            Text("\(shieldManager.emergencyBreaksUsed)").monospacedDigit()
                        }

                        HStack(spacing: 12) {
                            Button("Emergency Break") {
                                shieldManager.emergencyBreak()
                                dayLog = GetuppShared.loadDayLog()
                            }
                            .buttonStyle(.bordered)
                            .tint(.orange)

                            Button("Pull the Plug") {
                                shieldManager.pullThePlug()
                                dayLog = GetuppShared.loadDayLog()
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .disabled(!shieldManager.appEnabled)

                            Button("Turn Back On") {
                                shieldManager.turnBackOn()
                            }
                            .buttonStyle(.bordered)
                            .tint(.green)
                            .disabled(shieldManager.appEnabled)
                        }

                        Button("Run Escape Hatch Self-Tests") {
                            escapeSelfTestResults = runEscapeHatchSelfTests()
                        }
                        .buttonStyle(.bordered)
                        .tint(.indigo)

                        if !escapeSelfTestResults.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(escapeSelfTestResults, id: \.self) { line in
                                    Text(line)
                                        .font(.caption2.monospaced())
                                        .foregroundColor(line.hasPrefix("PASS") ? .green : .red)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Active Days debug
                GroupBox("Active Days") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Active days:")
                            Spacer()
                            Text("\(shieldManager.activeDays.sorted().map(String.init).joined(separator: " "))")
                                .monospacedDigit()
                        }
                        HStack {
                            Text("Pending:")
                            Spacer()
                            Text(shieldManager.pendingActiveDays.map {
                                $0.sorted().map(String.init).joined(separator: " ")
                            } ?? "—").monospacedDigit()
                        }
                        HStack {
                            Text("activeSessionDate:")
                            Spacer()
                            Text(sessionDateReadout).monospacedDigit()
                        }

                        HStack(spacing: 12) {
                            Button("Refresh") {
                                sessionDateReadout = ActiveDays.activeSessionDate() ?? "—"
                            }
                            .buttonStyle(.bordered)

                            // R6 escape valve for manual tests — a lingering key
                            // holds yesterday .pending and blocks its backfill.
                            Button("Clear Session Date") {
                                ActiveDays.clearActiveSessionDate()
                                sessionDateReadout = "—"
                                shieldManager.refreshStreak()
                            }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                        }

                        Button("Run Active Days Self-Tests") {
                            activeDaysSelfTestResults = runActiveDaysSelfTests()
                        }
                        .buttonStyle(.bordered)
                        .tint(.indigo)

                        if !activeDaysSelfTestResults.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(activeDaysSelfTestResults, id: \.self) { line in
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
            .padding()
        }
        .navigationTitle("Internal Tools")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            dayLog = GetuppShared.loadDayLog()
            breadcrumbs = GetuppShared.loadBreadcrumbs()
            sessionDateReadout = ActiveDays.activeSessionDate() ?? "—"
        }
    }

    // MARK: - Helpers

    private func formatTime(_ dc: DateComponents) -> String {
        String(format: "%02d:%02d", dc.hour ?? 0, dc.minute ?? 0)
    }

    /// Returns every process's state to a fresh-install-equivalent baseline —
    /// debug-only DATA reset, not a change to any production logic. Deliberately
    /// leaves activitySelection and the wake schedule untouched (real config,
    /// not test noise).
    private func resetTestState() {
        let defaults = GetuppShared.defaults

        defaults?.removeObject(forKey: GetuppShared.exemptDateKey)
        defaults?.removeObject(forKey: GetuppShared.lastVerifiedDateKey)
        defaults?.removeObject(forKey: GetuppShared.appEnabledKey)
        defaults?.removeObject(forKey: GetuppShared.emergencyBreaksUsedKey)
        defaults?.removeObject(forKey: GetuppShared.breadcrumbsKey)
        defaults?.removeObject(forKey: GetuppShared.activeBlockEndKey)

        Timeout.clearAllTimeoutState()
        defaults?.removeObject(forKey: Timeout.totalTimeoutMinutesKey)

        // Active Days: clear queue + session anchor, but leave activeDays itself —
        // the chosen days are real configuration, same as the wake window.
        ActiveDays.clearPending()
        ActiveDays.clearActiveSessionDate()
        shieldManager.pendingActiveDays = nil
        sessionDateReadout = "—"

        GetuppShared.saveDayLog([])

        shieldManager.removeShield()
        shieldManager.isVerifiedToday    = false
        shieldManager.timeoutEndTime     = nil
        shieldManager.emergencyBreaksUsed = 0   // reconcileState() doesn't refresh this one
        shieldManager.reconcileState()

        dayLog                    = []
        breadcrumbs               = []
        selfTestResults           = []
        timeoutSelfTestResults    = []
        escapeSelfTestResults     = []
        activeDaysSelfTestResults = []

        GetuppShared.logBreadcrumb("Reset Test State — cleared exempt/verified/timeout/day-log/escape-hatch state")
        breadcrumbs = GetuppShared.loadBreadcrumbs()
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

#Preview {
    NavigationView {
        InternalToolsView()
            .environmentObject(ShieldManager())
    }
}
#endif

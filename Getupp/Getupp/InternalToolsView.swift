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

    @State private var breadcrumbs:            [String]     = []
    @State private var dayLog:                 [DayRecord]  = []
    @State private var selfTestResults:        [String]     = []
    @State private var timeoutSelfTestResults: [String]     = []

    var body: some View {
        ScrollView {
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
        }
    }

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

#Preview {
    NavigationView {
        InternalToolsView()
            .environmentObject(ShieldManager())
    }
}
#endif

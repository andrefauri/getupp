//
//  SettingsView.swift
//  Getupp
//
//  Settings — Wake Window, Timeout, and Apps to Block live here.
//  DEBUG builds also get a discreet link to Internal Tools at the bottom.
//

import FamilyControls
import SwiftUI

struct SettingsView: View {

    @EnvironmentObject var shieldManager: ShieldManager

    @State private var isPickerPresented = false
    @State private var showEditSheet     = false
    @State private var showCustomTimeout = false
    @State private var timeoutCopyLine   = ""
    @State private var showDays          = false
    @State private var showEscapeHatch   = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                scheduleCard
                timeoutCard
                appSelectionCard
                escapeHatchRow

                #if DEBUG
                internalToolsButton
                #endif
            }
            .padding()
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
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
    }

    // MARK: - Schedule card (wake window + days)

    private var scheduleCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("SCHEDULE")
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

                Divider()

                daysRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
    }

    private var daysRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            NavigationLink(isActive: $showDays) {
                ActiveDaysView(onDeactivationIntent: {
                    // Funnel: pop Days (unsaved), then push the Escape Hatch hub.
                    // The delay lets the pop animation finish — NavigationView
                    // rejects a same-tick pop+push.
                    showDays = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showEscapeHatch = true
                    }
                })
            } label: {
                HStack {
                    Text("Days")
                    Spacer()
                    Text(ActiveDays.detailLabel(
                        for: shieldManager.activeDays,
                        firstWeekday: Calendar.current.firstWeekday
                    ))
                    .foregroundColor(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let pending = shieldManager.pendingActiveDays {
                Text("→ \(ActiveDays.detailLabel(for: pending, firstWeekday: Calendar.current.firstWeekday)) tomorrow")
                    .font(.caption.bold())
                    .foregroundColor(.orange)
            }
        }
    }

    // MARK: - Timeout card

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

    // MARK: - App Selection card

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

    // MARK: - Escape Hatch entry point

    private var escapeHatchRow: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                // isActive-bound so the Days screen's empty-state funnel can
                // land here programmatically.
                NavigationLink(destination: EscapeHatchView(), isActive: $showEscapeHatch) {
                    HStack {
                        Text("Escape Hatch")
                            .font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                if shieldManager.emergencyBreaksUsed > 0 {
                    Text("Emergency breaks used: \(shieldManager.emergencyBreaksUsed)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Internal Tools entry point (DEBUG only)

    #if DEBUG
    /// Deliberately understated — this is what a real user would see if the
    /// row weren't stripped from release builds, so it stays out of the way.
    private var internalToolsButton: some View {
        NavigationLink(destination: InternalToolsView()) {
            Text("Internal Tools")
                .font(.caption2)
                .foregroundColor(Color.black.opacity(0.3))
        }
        .padding(.top, 8)
    }
    #endif
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

#Preview {
    NavigationView {
        SettingsView()
            .environmentObject(ShieldManager())
    }
}

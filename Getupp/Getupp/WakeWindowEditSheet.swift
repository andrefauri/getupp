//
//  WakeWindowEditSheet.swift
//  Getupp
//
//  Modal sheet for configuring the wake window.
//  Handles Case A (day-0 dialog) and Case B (editing while blocked) inline.
//

import SwiftUI

struct WakeWindowEditSheet: View {

    @EnvironmentObject var shieldManager: ShieldManager
    @Environment(\.dismiss) private var dismiss

    // Editable time state — backed by Date so DatePicker works natively.
    @State private var startDate: Date
    @State private var endDate:   Date

    // Case A alert
    @State private var showDay0Alert = false

    // Case B — show the "starts tomorrow" notice after saving while blocked.
    @State private var savedWhileBlocked = false

    init(existing: WakeSchedule?) {
        let s = existing ?? .default
        _startDate = State(initialValue: Self.makeDate(hour: s.startHour, minute: s.startMinute))
        _endDate   = State(initialValue: Self.makeDate(hour: s.endHour,   minute: s.endMinute))
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    DatePicker("Start", selection: $startDate, displayedComponents: .hourAndMinute)
                    DatePicker("End",   selection: $endDate,   displayedComponents: .hourAndMinute)
                }

                if let err = validationError {
                    Section {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                if savedWhileBlocked {
                    Section {
                        Text("Saved. Starts tomorrow. Today's block doesn't move — get up, take the photo.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }
            .navigationTitle("Wake Window")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { handleSave() }
                        .disabled(validationError != nil)
                }
            }
            // Case A — day-0 confirmation dialog
            .alert(day0AlertTitle, isPresented: $showDay0Alert) {
                Button("Block me now")  { confirmDay0(immediately: true)  }
                Button("Start tomorrow") { confirmDay0(immediately: false) }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Want it to catch you today, or start fresh tomorrow?")
            }
        }
    }

    // MARK: - Save logic

    private func handleSave() {
        let draft = draftSchedule

        // Case B: user is currently blocked and unverified.
        // Save and re-register (so future days use the new times), but never clear the shield.
        if shieldManager.isBlockedAndUnverified {
            shieldManager.saveWakeSchedule(draft)
            savedWhileBlocked = true
            return  // stay open so user sees the notice; they dismiss manually.
        }

        // Case A: inside the new window right now, not blocked, not verified.
        if draft.isWindowActive() && !shieldManager.isShielded && !shieldManager.isVerifiedToday {
            showDay0Alert = true
            return
        }

        // Regular save.
        shieldManager.saveWakeSchedule(draft)
        dismiss()
    }

    private func confirmDay0(immediately: Bool) {
        let draft = draftSchedule
        shieldManager.saveWakeSchedule(draft)
        if immediately {
            shieldManager.applyImmediateBlock(for: draft)
        } else {
            shieldManager.markExemptToday()
        }
        dismiss()
    }

    // MARK: - Validation

    private var validationError: String? {
        let draft = draftSchedule
        guard draft.durationMinutes > 0 else { return "End time must be after start time." }
        guard draft.isValid           else { return "Window must be at least 15 minutes." }
        return nil
    }

    // MARK: - Derived schedule from current picker state

    private var draftSchedule: WakeSchedule {
        let cal = Calendar.current
        return WakeSchedule(
            startHour:   cal.component(.hour,   from: startDate),
            startMinute: cal.component(.minute, from: startDate),
            endHour:     cal.component(.hour,   from: endDate),
            endMinute:   cal.component(.minute, from: endDate),
            dayMode:     .everyday,
            customDays:  [],
            isEnabled:   true
        )
    }

    // MARK: - Alert copy

    private var day0AlertTitle: String {
        let draft = draftSchedule
        let now   = Date()
        let fmt   = DateFormatter()
        fmt.dateFormat = "HH:mm"
        let nowStr   = fmt.string(from: now)
        return "It's \(nowStr) — your \(draft.startDisplayString)–\(draft.endDisplayString) window is already live."
    }

    // MARK: - Helpers

    private static func makeDate(hour: Int, minute: Int) -> Date {
        var comps        = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour       = hour
        comps.minute     = minute
        comps.second     = 0
        return Calendar.current.date(from: comps) ?? Date()
    }
}

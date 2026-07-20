//
//  ActiveDaysView.swift
//  Getupp
//
//  The Days screen — preset chips above a 7-day list, explicit Save.
//  Getupp target ONLY (pure UI; the monitor never renders it).
//
//  Custom is not a mode: it's simply what "no preset matched" looks like.
//  Chip lit state is derived from the draft set on every render.
//

import SwiftUI

struct ActiveDaysView: View {

    @EnvironmentObject var shieldManager: ShieldManager
    @Environment(\.dismiss) private var dismiss

    /// Called when the user unticks everything and taps "Turn GETUPP off" —
    /// the owner dismisses this screen WITHOUT saving and opens the Escape
    /// Hatch hub. No auto-toggle; deliberate friction on the way out.
    let onDeactivationIntent: () -> Void

    @State private var draft: Set<Int> = []
    @State private var loaded = false
    @State private var savedQueued = false

    private let calendar = Calendar.current

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                chipRow
                dayList

                if draft.isEmpty {
                    emptyStateFunnel
                } else {
                    saveButton
                }

                if savedQueued {
                    Text("Today's already running. Starts tomorrow.")
                        .font(.caption.bold())
                        .foregroundColor(.orange)
                } else if let pending = shieldManager.pendingActiveDays {
                    Text("→ \(ActiveDays.detailLabel(for: pending, firstWeekday: calendar.firstWeekday)) tomorrow")
                        .font(.caption.bold())
                        .foregroundColor(.orange)
                }
            }
            .padding()
        }
        .navigationTitle("Days")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Latest intent wins: a queued removal shows unticked, not resurrected.
            guard !loaded else { return }
            draft = shieldManager.pendingActiveDays ?? shieldManager.activeDays
            loaded = true
        }
    }

    // MARK: - Preset chips

    private var chipRow: some View {
        HStack(spacing: 8) {
            ForEach(ActiveDays.Preset.allCases, id: \.self) { preset in
                chip(preset)
            }
        }
    }

    private func chip(_ preset: ActiveDays.Preset) -> some View {
        // Lit state is derived from the set — a hand-picked Mon–Fri lights
        // "Weekdays"; breaking a preset simply un-lights it. No modes.
        let lit = ActiveDays.preset(for: draft) == preset
        return Button {
            draft = preset.days
        } label: {
            Text(preset.label)
                .font(.callout.bold())
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(lit ? .indigo : .secondary)
    }

    // MARK: - Day list

    private var dayList: some View {
        GroupBox {
            VStack(spacing: 0) {
                let ordered = ActiveDays.orderedWeekdays(firstWeekday: calendar.firstWeekday)
                ForEach(ordered, id: \.self) { day in
                    dayRow(day)
                    if day != ordered.last {
                        Divider()
                    }
                }
            }
        }
    }

    private func dayRow(_ day: Int) -> some View {
        Button {
            if draft.contains(day) {
                draft.remove(day)
            } else {
                draft.insert(day)
            }
        } label: {
            HStack {
                Text(calendar.weekdaySymbols[day - 1])
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "checkmark")
                    .font(.body.bold())
                    .foregroundColor(.indigo)
                    .opacity(draft.contains(day) ? 1 : 0)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
    }

    // MARK: - Save

    private var saveButton: some View {
        Button("Save") {
            let queued = shieldManager.setActiveDays(draft)
            if queued {
                savedQueued = true   // stay open so the notice lands
            } else {
                dismiss()
            }
        }
        .buttonStyle(.borderedProminent)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Empty-state funnel (deactivation intent)

    private var emptyStateFunnel: some View {
        GroupBox {
            VStack(spacing: 12) {
                Text("Zero days is just GETUPP off.")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Button("Turn GETUPP off") {
                    onDeactivationIntent()
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}

#Preview {
    NavigationView {
        ActiveDaysView(onDeactivationIntent: {})
            .environmentObject(ShieldManager())
    }
}

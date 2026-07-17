//
//  TimeoutCountdownView.swift
//  Getupp
//
//  The countdown block shown while a Timeout is running — used in two places:
//  the post-verification success screen (CameraView) and the main screen's
//  state section (ContentView). Main app target only.
//
//  The absolute end time is required, not decorative: iOS callbacks can run
//  late, and a visible target makes lateness self-checkable instead of feeling
//  broken.
//

import Combine
import SwiftUI

struct TimeoutCountdownView: View {

    @EnvironmentObject var shieldManager: ShieldManager

    /// Fires at most once when the countdown hits zero, so callers can reconcile.
    @State private var expiryHandled = false

    /// Copy chosen once per appearance (and refreshed on extend), not per tick.
    @State private var copyLine = ""

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let end = shieldManager.timeoutEndTime {
                countdown(until: end)
            } else {
                // Timeout over (or none started — e.g. debug verification).
                Text(TimeoutCopy.line(for: .timeoutEnd))
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
            }
        }
        .onAppear {
            copyLine = TimeoutCopy.line(for: .timeoutStart)
        }
        .onReceive(ticker) { _ in
            guard let end = shieldManager.timeoutEndTime, !expiryHandled else { return }
            if Date() >= end {
                expiryHandled = true
                // Layer 2 in-place: completes the timeout and clears shields.
                shieldManager.reconcileState()
            }
        }
    }

    private func countdown(until end: Date) -> some View {
        VStack(spacing: 12) {
            Text(copyLine)
                .font(.headline)
                .multilineTextAlignment(.center)

            // System-driven per-second countdown — no timer needed for display.
            Text(timerInterval: Date()...end, countsDown: true)
                .font(.system(size: 56, weight: .black).monospacedDigit())
                .multilineTextAlignment(.center)

            Text("Free at \(end.formatted(date: .omitted, time: .shortened))")
                .font(.subheadline)
                .foregroundColor(.secondary)

            // R6: extending is always the safe direction — no confirmation.
            HStack(spacing: 8) {
                extendButton("+15m", 15 * 60)
                extendButton("+30m", 30 * 60)
                extendButton("+1h",  3600)
                extendButton("+2h",  2 * 3600)
            }
            .padding(.top, 4)

            // RESERVED: Emergency Break entry point (separate spec). The slot is
            // deliberately low-prominence and inert for now.
            Text("Emergency break")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.4))
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity)
    }

    private func extendButton(_ label: String, _ delta: TimeInterval) -> some View {
        Button(label) {
            shieldManager.extendTimeout(by: delta)
            copyLine = TimeoutCopy.line(for: .extended)
        }
        .buttonStyle(.bordered)
        .font(.callout.bold())
    }
}

//
//  ContentView.swift
//  Getupp
//
//  Home screen — title, streak, and current block status only.
//  Everything else (wake window, timeout, apps to block, debug tools)
//  lives behind the Settings button. See SettingsView.swift.
//

import SwiftUI

struct ContentView: View {

    @EnvironmentObject var shieldManager: ShieldManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var showStreakDialog = false
    @State private var showWelcomeBack  = false
    @State private var welcomeBackLine  = ""

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    if shieldManager.appEnabled {
                        streakCard
                    }
                    mainStateSection
                    settingsButton
                }
                .padding()
            }
            .navigationTitle("GETUPP")
            .onAppear {
                shieldManager.reconcileState()
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    shieldManager.reconcileState()
                }
            }
            .sheet(isPresented: $showStreakDialog) {
                StreakDialog(
                    streakCount: shieldManager.streak.count,
                    totalTimeoutMinutes: shieldManager.totalTimeoutMinutes
                )
            }
            // Escape Hatch confirmation flow — attached at root so both entry
            // doors (the hub, and the reserved TimeoutCountdownView slot) can
            // open it from anywhere by setting shieldManager.activeEscape.
            .fullScreenCover(item: $shieldManager.activeEscape) { action in
                EscapeConfirmationView(action: action)
                    .environmentObject(shieldManager)
            }
        }
    }

    // MARK: - Streak card

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

    // MARK: - Main state section

    @ViewBuilder
    private var mainStateSection: some View {
        if !shieldManager.appEnabled {
            disabledView
        } else if shieldManager.timeoutEndTime != nil {
            timeoutView
        } else if shieldManager.isVerifiedToday {
            verifiedTodayView
        } else if shieldManager.isShielded {
            needsVerificationView
        } else {
            idleView
        }
    }

    // MARK: - Pull the Plug disabled state

    /// When appEnabled == false, this replaces the whole main state section —
    /// nothing else competes with the one re-enable button.
    private var disabledView: some View {
        GroupBox {
            VStack(spacing: 16) {
                Text(EscapeHatchCopy.homeDisabledStatement)
                    .font(.headline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Button(EscapeHatchCopy.homeDisabledButton) {
                    shieldManager.turnBackOn()
                    welcomeBackLine = EscapeHatchCopy.line(for: .welcomeBack)
                    showWelcomeBack = true
                }
                .buttonStyle(.acidYellow)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .overlay {
            if showWelcomeBack {
                WelcomeBackOverlay(line: welcomeBackLine) {
                    showWelcomeBack = false
                }
            }
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
                Text("Set your wake window in Settings to arm the shield.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                // Active Days P1: only renders on unscheduled days, so a quiet
                // morning reads as "day off," not "GETUPP broke."
                if let hint = nextArmHint {
                    Text(hint)
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    /// "Next: Monday" — non-nil only when a schedule exists and today is NOT a
    /// scheduled day.
    private var nextArmHint: String? {
        guard let schedule = shieldManager.wakeSchedule, schedule.isEnabled,
              !ActiveDays.isScheduledToday() else { return nil }
        guard let next = schedule.nextWindowStart(after: Date(), activeDays: shieldManager.activeDays) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return "Next: \(formatter.string(from: next))"
    }

    // MARK: - Settings entry point

    private var settingsButton: some View {
        // isActive-bound so Escape Hatch (pushed underneath Settings) can pop
        // the WHOLE stack back to Home in one shot by flipping this false —
        // see ShieldManager.settingsPresented and EscapeConfirmationView.
        NavigationLink(destination: SettingsView(), isActive: $shieldManager.settingsPresented) {
            Label("Settings", systemImage: "gearshape.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - Welcome-back celebration (P1: simple burst is fine, don't block ship)

/// Minimal celebration for re-enabling: one emoji burst + a welcome-back line,
/// auto-dismisses. Animation polish is P1 — if this reads as janky on-device,
/// keep the copy line alone per the PRD's fallback.
private struct WelcomeBackOverlay: View {
    let line: String
    let onFinished: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("🎉")
                .font(.system(size: 56))
            Text(line)
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundColor(.primary)
        }
        .padding(24)
        .background(.thinMaterial)
        .cornerRadius(16)
        .transition(.scale.combined(with: .opacity))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                onFinished()
            }
        }
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

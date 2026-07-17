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

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    streakCard
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
                Text("Set your wake window in Settings to arm the shield.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Settings entry point

    private var settingsButton: some View {
        NavigationLink(destination: SettingsView()) {
            Label("Settings", systemImage: "gearshape.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
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

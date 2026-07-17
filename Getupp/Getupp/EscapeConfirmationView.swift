//
//  EscapeConfirmationView.swift
//  Getupp
//
//  The shared confirmation flow for both Escape Hatch actions — one screen,
//  parameterized by EscapeAction. Presented as a .fullScreenCover: no
//  swipe-to-dismiss, no system-alert cop-out. The friction is the feature.
//
//  Getupp target only.
//

import Combine
import SwiftUI

/// Identifies which Escape Hatch action is being confirmed. Both the
/// EscapeHatchView hub and the reserved TimeoutCountdownView slot set
/// ShieldManager.activeEscape to open this same flow — one flow, two doors.
enum EscapeAction: String, Identifiable {
    case emergencyBreak
    case pullThePlug

    var id: String { rawValue }
}

struct EscapeConfirmationView: View {

    @EnvironmentObject var shieldManager: ShieldManager
    @Environment(\.scenePhase) private var scenePhase

    let action: EscapeAction

    /// 5s on-button countdown. Restarts from 5 every appearance — backgrounding
    /// and returning does NOT preserve progress (cheap anti-impulse insurance).
    @State private var countdown = 5
    @State private var roastLine = ""

    /// Once true, the same cover shows the static "walk of shame" state
    /// instead of dismissing — post-confirmation is required, not optional.
    @State private var confirmed = false
    @State private var postRoastLine = ""

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if confirmed {
                postConfirmationView
            } else {
                confirmationView
            }
        }
        .onAppear {
            roastLine = EscapeHatchCopy.line(for: roastPool)
        }
        .onChange(of: scenePhase) { phase in
            // Countdown resets on every appearance — backgrounding mid-countdown
            // and returning must not preserve progress.
            if phase == .active && !confirmed {
                countdown = 5
            }
        }
        .onReceive(ticker) { _ in
            guard !confirmed, countdown > 0 else { return }
            countdown -= 1
        }
    }

    // MARK: - Confirmation screen

    private var confirmationView: some View {
        VStack(spacing: 24) {
            Spacer()

            Text(title)
                .font(BrandFont.escapeTitle)
                .multilineTextAlignment(.center)

            Text(implications)
                .font(BrandFont.implications)
                .multilineTextAlignment(.center)
                .foregroundColor(.primary)
                .padding(.horizontal)

            Text(roastLine)
                .font(BrandFont.roast)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            // The escape route from the escape route gets the visual priority —
            // inverted dark pattern, on purpose.
            Button(cancelLabel) {
                dismissToHome()
            }
            .buttonStyle(.acidYellow)

            Button(confirmLabel) {
                confirm()
            }
            .buttonStyle(.mutedConfirm(isEnabled: countdown == 0))
            .disabled(countdown > 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    // MARK: - Post-confirmation "walk of shame"

    private var postConfirmationView: some View {
        VStack(spacing: 24) {
            Spacer()

            Text(postFixed)
                .font(BrandFont.implications)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text(postRoastLine)
                .font(BrandFont.roast)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            Button(postCTA) {
                dismissToHome()
            }
            .buttonStyle(.acidYellow)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    // MARK: - Actions

    private func confirm() {
        switch action {
        case .emergencyBreak: shieldManager.emergencyBreak()
        case .pullThePlug:    shieldManager.pullThePlug()
        }
        postRoastLine = EscapeHatchCopy.line(for: postPool)
        confirmed = true
    }

    /// Cancel and the post-confirmation CTA both must land on Home — not just
    /// dismiss this cover, which (when entered via Settings → Escape Hatch)
    /// would leave EscapeHatchView/Settings still pushed underneath. Clearing
    /// settingsPresented unwinds that whole pushed stack in one shot.
    private func dismissToHome() {
        shieldManager.activeEscape = nil
        shieldManager.settingsPresented = false
    }

    // MARK: - Copy plumbing (per-action)

    private var title: String {
        switch action {
        case .emergencyBreak: return EscapeHatchCopy.emergencyTitle
        case .pullThePlug:    return EscapeHatchCopy.pullTitle
        }
    }

    private var implications: String {
        let streak = shieldManager.streak.count
        switch action {
        case .emergencyBreak: return EscapeHatchCopy.emergencyImplications(streak: streak)
        case .pullThePlug:    return EscapeHatchCopy.pullImplications(streak: streak)
        }
    }

    private var roastPool: EscapeHatchCopy.Pool {
        switch action {
        case .emergencyBreak: return .emergencyRoast
        case .pullThePlug:    return .pullRoast
        }
    }

    private var postPool: EscapeHatchCopy.Pool {
        switch action {
        case .emergencyBreak: return .emergencyPost
        case .pullThePlug:    return .pullPost
        }
    }

    private var cancelLabel: String {
        switch action {
        case .emergencyBreak: return EscapeHatchCopy.emergencyCancelLabel
        case .pullThePlug:    return EscapeHatchCopy.pullCancelLabel
        }
    }

    private var confirmLabel: String {
        let base: String
        switch action {
        case .emergencyBreak: base = EscapeHatchCopy.emergencyConfirmLabel
        case .pullThePlug:    base = EscapeHatchCopy.pullConfirmLabel
        }
        return countdown > 0 ? "\(base) (\(countdown))" : base
    }

    private var postFixed: String {
        switch action {
        case .emergencyBreak: return EscapeHatchCopy.emergencyPostFixed
        case .pullThePlug:    return EscapeHatchCopy.pullPostFixed
        }
    }

    private var postCTA: String {
        switch action {
        case .emergencyBreak: return EscapeHatchCopy.emergencyPostCTA
        case .pullThePlug:    return EscapeHatchCopy.pullPostCTA
        }
    }
}

#Preview {
    EscapeConfirmationView(action: .emergencyBreak)
        .environmentObject(ShieldManager())
}

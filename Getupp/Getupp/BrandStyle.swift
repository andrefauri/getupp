//
//  BrandStyle.swift
//  Getupp
//
//  Escape Hatch visual tokens (PRD: "the anti-Calm" — direct, funny-rude,
//  cornerman not bully). The PRD specs Anton / Space Mono / Caveat + an
//  acid-yellow brand button; none of those font files exist in the app yet.
//
//  POC decision: ship this feature with SF system-font equivalents now so
//  nothing blocks on sourcing/registering .ttf files in Xcode. Swapping in the
//  real brand fonts later is a one-file change — only the `Font` statics below
//  need to move from `.system(...)` to `Font.custom("Anton-Regular", ...)` etc.
//  Getupp target only.
//

import SwiftUI

extension Color {
    /// The brand's acid-yellow. Reserved for the Cancel CTA and "TURN IT BACK
    /// ON" — never used for a Confirm/destructive button (PRD: NEVER acid
    /// yellow on the way out; only on the way back, or the escape-from-the-
    /// escape route).
    static let acidYellow = Color(red: 0.83, green: 1.0, blue: 0.0) // ~#D4FF00
}

enum BrandFont {
    /// Fixed screen title (e.g. "BREAKING OUT?"). PRD spec: Anton, all caps, static.
    static let escapeTitle = Font.system(size: 34, weight: .black)

    /// The honest-cornerman implications block. PRD spec: Space Mono, factual.
    static let implications = Font.system(.body, design: .monospaced)

    /// The roast line. PRD spec: Caveat or brand-appropriate accent styling.
    static let roast = Font.system(.title3, design: .default).italic()
}

/// The BIG, prominent acid-yellow button — Cancel on a confirmation screen,
/// or "TURN IT BACK ON" on the disabled Home state. Always the visual
/// priority; on the way out this is a deliberately inverted dark pattern
/// (the escape route from the escape route gets top billing).
struct AcidYellowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 20, weight: .black))
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Color.acidYellow)
            .cornerRadius(14)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

/// The small, muted Confirm button on a confirmation screen. Deliberately the
/// visual opposite of Cancel — smaller, destructive-tinted, never yellow.
struct MutedConfirmButtonStyle: ButtonStyle {
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.callout, design: .monospaced).bold())
            .foregroundColor(isEnabled ? .white : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isEnabled ? Color.red.opacity(0.7) : Color.secondary.opacity(0.2))
            .cornerRadius(10)
    }
}

extension ButtonStyle where Self == AcidYellowButtonStyle {
    static var acidYellow: AcidYellowButtonStyle { AcidYellowButtonStyle() }
}

extension ButtonStyle where Self == MutedConfirmButtonStyle {
    static func mutedConfirm(isEnabled: Bool) -> MutedConfirmButtonStyle {
        MutedConfirmButtonStyle(isEnabled: isEnabled)
    }
}

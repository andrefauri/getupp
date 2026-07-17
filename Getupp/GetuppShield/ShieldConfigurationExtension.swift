//
//  ShieldConfigurationExtension.swift
//  GetuppShield
//
//  Returns the custom shield screen shown when a user opens a blocked app.
//  Two variants, derived from the same App Group state everything else uses:
//    morning — window running, unverified ("go take the photo")
//    timeout — verified, apps serving their timeout ("blocked until h:mm")
//  An identical shield after verification would read as "verification failed",
//  so the timeout shield must look and sound different (R8).
//
//  The primary button can ONLY close the blocked app (iOS restriction).
//  It cannot deep-link back to GETUPP.
//
//  Kept minimal: one UserDefaults read, no networking. Shows the ABSOLUTE end
//  time, never "X min left" — iOS may cache this config, and a stale absolute
//  time is still true while a stale countdown would be a lie.
//

import Foundation
import ManagedSettings
import ManagedSettingsUI
import UIKit

// ──────────────────────────────────────────────────────────────
// COPY — morning shield copy lives here; timeout shield copy comes
// from the shared pools in TimeoutCopy.swift (R7).
// Everything else in this file is layout plumbing.
// ──────────────────────────────────────────────────────────────
private let shieldTitle      = "GET UP."
private let shieldSubtitle   = "This app opens when you're out of bed. Take the photo in GETUPP."
private let shieldButtonText = "FINE."

private let timeoutButtonText = "OK, OK."

class ShieldConfigurationExtension: ShieldConfigurationDataSource {

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        makeConfig()
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        makeConfig()
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        makeConfig()
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        makeConfig()
    }

    // MARK: - Shared config builder

    /// Single source of truth for the shield appearance. Derives morning vs
    /// timeout from timeoutEndTime — the same key every clearing layer checks.
    private func makeConfig() -> ShieldConfiguration {
        if let end = Timeout.loadTimeoutEnd(), Date() < end {
            return timeoutConfig(until: end)
        }
        return morningConfig()
    }

    private func morningConfig() -> ShieldConfiguration {
        ShieldConfiguration(
            backgroundBlurStyle: .dark,
            backgroundColor:     .black,
            icon:                nil,
            title:               ShieldConfiguration.Label(
                                     text: shieldTitle,
                                     color: .white
                                 ),
            subtitle:            ShieldConfiguration.Label(
                                     text: shieldSubtitle,
                                     color: .init(white: 0.75, alpha: 1.0)
                                 ),
            primaryButtonLabel:  ShieldConfiguration.Label(
                                     text: shieldButtonText,
                                     color: .black
                                 ),
            primaryButtonBackgroundColor: .white
        )
    }

    private func timeoutConfig(until end: Date) -> ShieldConfiguration {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none

        return ShieldConfiguration(
            backgroundBlurStyle: .dark,
            backgroundColor:     .systemIndigo,
            icon:                nil,
            title:               ShieldConfiguration.Label(
                                     text: TimeoutCopy.line(for: .countdownShield),
                                     color: .white
                                 ),
            subtitle:            ShieldConfiguration.Label(
                                     text: "You're up — this app isn't. Blocked until \(formatter.string(from: end)).",
                                     color: .init(white: 0.85, alpha: 1.0)
                                 ),
            primaryButtonLabel:  ShieldConfiguration.Label(
                                     text: timeoutButtonText,
                                     color: .black
                                 ),
            primaryButtonBackgroundColor: .white
        )
    }
}

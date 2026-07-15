//
//  ShieldConfigurationExtension.swift
//  GetuppShield
//
//  Returns the custom shield screen shown when a user opens a blocked app.
//  This extension is minimal on purpose: no App Group reads, no networking,
//  no logic — just returns a static configuration.
//
//  The primary button can ONLY close the blocked app (iOS restriction).
//  It cannot deep-link back to GETUPP.
//

import ManagedSettings
import ManagedSettingsUI
import UIKit

// ──────────────────────────────────────────────────────────────
// COPY — edit these constants to iterate on wording.
// Everything else in this file is layout plumbing.
// ──────────────────────────────────────────────────────────────
private let shieldTitle      = "GET UP."
private let shieldSubtitle   = "This app opens when you're out of bed. Take the photo in GETUPP."
private let shieldButtonText = "FINE."

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

    /// Single source of truth for the shield appearance.
    private func makeConfig() -> ShieldConfiguration {
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
}

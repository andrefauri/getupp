//
//  EscapeHatchCopy.swift
//  Getupp
//
//  ALL Escape Hatch copy lives here — one data file, following the
//  TimeoutCopy.swift pattern exactly. Prompts-are-data rule: no copy is
//  hardcoded inside EscapeHatchView / EscapeConfirmationView.
//
//  Getupp target only — Escape Hatch has no shield-extension surface.
//
//  Voice: the cornerman, not the bully. Roast the behavior, never the
//  person's worth. Funny-rude, never mean.
//
//  Selection is random with no-immediate-repeat, same mechanism as
//  TimeoutCopy: the last-shown index per pool lives in the App Group.
//

import Foundation

enum EscapeHatchCopy {

    // MARK: - Pools

    enum Pool: String, CaseIterable {
        case emergencyRoast
        case emergencyPost
        case pullRoast
        case pullPost
        case welcomeBack
    }

    // MARK: - The copy

    private static let lines: [Pool: [String]] = [

        .emergencyRoast: [
            "Real emergencies rarely involve TikTok.",
            "This is the adult version of faking a fever.",
            "We'll tell your apps you had an 'emergency.'",
            "Define 'emergency.' Take your time. You clearly have some.",
            "The bed always negotiates. The bed never wins. Except today, apparently.",
        ],

        .emergencyPost: [
            "Enjoy the scroll. The shield remembers.",
            "Today didn't count. Tomorrow does.",
            "We're not mad. We're just recalibrating our expectations.",
        ],

        .pullRoast: [
            "Turning off the smoke alarm because you like the smoke.",
            "The blanket wins. Noted.",
            "We'll be here when bed-rotting stops being fun.",
            "Bold move: uninstalling the consequences instead of the apps.",
            "Your future 7am self would like a word. We'll pass along the message.",
        ],

        .pullPost: [
            "The apps are free. So is the bed. Good luck out there.",
            "We'd say 'you got this' but the evidence is mixed.",
            "Door's unlocked whenever you want your mornings back.",
        ],

        .welcomeBack: [
            "THERE you are. The shield missed you. Sort of.",
            "Back in the game. First round: tomorrow morning.",
            "Good call. The bed never deserved you anyway.",
            "Reactivated. Streak starts fresh tomorrow — make it count.",
        ],
    ]

    // MARK: - Selection (random, no immediate repeat)

    private static let lastIndexKeyPrefix = "escapeCopyLastIndex."

    /// A random line from the pool, never the same one twice in a row.
    static func line(for pool: Pool) -> String {
        guard let poolLines = lines[pool], !poolLines.isEmpty else { return "" }
        guard poolLines.count > 1 else { return poolLines[0] }

        let defaults  = GetuppShared.defaults
        let key       = lastIndexKeyPrefix + pool.rawValue
        let lastIndex = defaults?.object(forKey: key) as? Int

        var index = Int.random(in: 0..<poolLines.count)
        while index == lastIndex {
            index = Int.random(in: 0..<poolLines.count)
        }

        defaults?.set(index, forKey: key)
        return poolLines[index]
    }

    // MARK: - Fixed strings (never pooled — titles, implications, CTAs)

    static let emergencyTitle = "BREAKING OUT?"
    static let pullTitle      = "PULLING THE PLUG?"

    static func emergencyImplications(streak: Int) -> String {
        streak > 0
            ? "This unblocks your apps for today. Your \(streak)-morning streak dies right here. Tomorrow morning, the shield comes back like nothing happened."
            : "This unblocks your apps for today. No streak to lose — which is its own kind of statement. Tomorrow, the shield comes back."
    }

    static func pullImplications(streak: Int) -> String {
        streak > 0
            ? "This shuts GETUPP down completely. No morning blocks, no photos, no rules. Your \(streak)-morning streak dies here. Your settings stay saved for whenever you come back."
            : "This shuts GETUPP down completely. No morning blocks, no photos, no rules. Your settings stay saved for whenever you come back."
    }

    static let emergencyConfirmLabel = "UNBLOCK MY APPS"
    static let emergencyCancelLabel  = "NEVER MIND — I'M UP"
    static let emergencyPostFixed    = "Done. Apps unblocked for today. Streak: 0. See you tomorrow morning."
    static let emergencyPostCTA      = "BACK TO HOME"

    static let pullConfirmLabel = "SHUT IT DOWN"
    static let pullCancelLabel  = "KEEP ME HONEST"
    static let pullPostFixed    = "GETUPP is off. No blocks, no streak, no judgment. (Some judgment.) Everything's saved for when you're ready."
    static let pullPostCTA      = "BACK TO HOME"

    static let homeDisabledStatement = "GETUPP IS OFF. Your mornings are unsupervised. How's that going?"
    static let homeDisabledButton    = "TURN IT BACK ON"

    static let hubEmergencyTitle    = "Emergency Break"
    static let hubEmergencySubtitle = "Unblocks today's apps. Your streak pays the price."
    static let hubEmergencyDisabledSubtitle = "Nothing to escape from right now. Impressive foresight though."

    static let hubPullTitle    = "Pull the Plug"
    static let hubPullSubtitle = "Turns GETUPP off completely. No blocks, no streak, nothing."
}

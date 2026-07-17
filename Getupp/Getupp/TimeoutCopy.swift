//
//  TimeoutCopy.swift
//  Getupp
//
//  ALL Timeout copy lives here — one data file, organized by moment (R7).
//  Prompts-are-data rule: never hardcode a Timeout string in view logic.
//
//  Shared between the main app and the Shield extension (the countdownShield
//  pool is read by the GetuppShield process). IMPORTANT: add to BOTH targets
//  in Xcode's File Inspector: Getupp + GetuppShield.
//
//  Voice: the cornerman. Funny-rude, never mean. The APPS are in timeout —
//  the user is not. Instagram is the one being punished.
//
//  Selection is random with no-immediate-repeat: the last-shown index per pool
//  is stored in the App Group (multiple processes read these pools, so one
//  uniform mechanism beats per-process memory).
//

import Foundation

enum TimeoutCopy {

    // MARK: - Pools

    enum Pool: String, CaseIterable {
        case presetPick15
        case presetPick30
        case presetPick1h
        case presetPick2h
        case presetPick5h
        case customPick
        case timeoutStart
        case countdownShield
        case extended        // "extend" reads like a verb on an enum — avoid keyword-ish name
        case timeoutEnd
        case downgradeBlocked
    }

    // MARK: - The copy

    private static let lines: [Pool: [String]] = [

        .presetPick15: [
            "15 minutes. Baby steps. The apps can hold their breath that long.",
            "A warm-up lap. Even Instagram isn't scared yet.",
            "Starting small. The blanket didn't win — that's what counts.",
        ],

        .presetPick30: [
            "Half an hour. Enough time for coffee, not enough to relapse. Perfect.",
            "30 minutes of apps sitting in the corner. Respectable.",
            "The classic. Long enough to hurt them, short enough to keep you honest.",
        ],

        .presetPick1h: [
            "A full hour. The apps are going to write you letters.",
            "60 minutes. Somewhere, a feed refreshes without you. Beautiful.",
            "One hour before the algorithm gets you back. Strong.",
        ],

        .presetPick2h: [
            "Two hours?? The group chat will assume you died. Let them.",
            "120 minutes. That's a whole morning routine. Who ARE you?",
            "Two hours in timeout. The apps are unionizing.",
        ],

        .presetPick5h: [
            "FIVE hours. The apps will need therapy. Magnificent.",
            "5 hours. At this point just delete them. (Don't — we've grown attached.)",
            "Five hours?! Easy, champ. Save some discipline for the rest of us.",
        ],

        .customPick: [
            "Custom, huh. A connoisseur of app punishment.",
            "Bespoke timeout. Fancy.",
            "Your rules. The apps lose either way.",
        ],

        .timeoutStart: [
            "You're up. The apps aren't. They're in timeout.",
            "Photo checks out. Instagram's still grounded.",
            "You did your part. The apps sit and think about what they did.",
            "Verified. Now watch the apps do time.",
        ],

        // Shield TITLES — keep short and loud, they render in caps on the shield.
        .countdownShield: [
            "STILL IN TIMEOUT.",
            "NOT YET.",
            "IT CAN WAIT.",
            "THE FEED SURVIVES WITHOUT YOU.",
        ],

        .extended: [
            "More? The apps begged for parole and you said no. Ice cold.",
            "Extension granted. To you, not them.",
            "Piling it on. The cornerman approves.",
        ],

        .timeoutEnd: [
            "Time served. The apps are free — you don't have to visit, though.",
            "Timeout's over. Try to act like you don't miss them.",
            "Doors open. Walk in like you own the place — you do.",
        ],

        .downgradeBlocked: [
            "Nice try. Today's deal stands — the shorter timeout starts tomorrow.",
            "Shrinking your commitment mid-day? Cute. Tomorrow.",
            "You made a promise this morning. The downgrade lands tomorrow.",
        ],
    ]

    // MARK: - Selection (random, no immediate repeat)

    private static let lastIndexKeyPrefix = "timeoutCopyLastIndex."

    /// A random line from the pool, never the same one twice in a row.
    static func line(for pool: Pool) -> String {
        guard let poolLines = lines[pool], !poolLines.isEmpty else { return "" }
        guard poolLines.count > 1 else { return poolLines[0] }

        let defaults  = UserDefaults(suiteName: Timeout.appGroupID)
        let key       = lastIndexKeyPrefix + pool.rawValue
        let lastIndex = defaults?.object(forKey: key) as? Int

        var index = Int.random(in: 0..<poolLines.count)
        while index == lastIndex {
            index = Int.random(in: 0..<poolLines.count)
        }

        defaults?.set(index, forKey: key)
        return poolLines[index]
    }

    /// The pool that matches a preset duration (falls back to customPick).
    static func pool(forPresetDuration duration: TimeInterval) -> Pool {
        switch duration {
        case 15 * 60:  return .presetPick15
        case 30 * 60:  return .presetPick30
        case 3600:     return .presetPick1h
        case 2 * 3600: return .presetPick2h
        case 5 * 3600: return .presetPick5h
        default:       return .customPick
        }
    }
}

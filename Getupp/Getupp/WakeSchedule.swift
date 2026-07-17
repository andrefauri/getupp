//
//  WakeSchedule.swift
//  Getupp
//
//  Persisted schedule model — shared between the main app and the Monitor extension.
//  IMPORTANT: Add to BOTH targets in Xcode's File Inspector (main app + GetuppMonitor).
//

import Foundation

// Phase A ships .everyday only. The enum and customDays field are here from day one
// so the UserDefaults encoding never needs a migration.
enum DayMode: String, Codable, CaseIterable {
    case everyday = "everyday"
    case weekdays = "weekdays"
    case weekends = "weekends"
    case custom   = "custom"

    var displayName: String {
        switch self {
        case .everyday: return "Every day"
        case .weekdays: return "Weekdays"
        case .weekends: return "Weekends"
        case .custom:   return "Custom"
        }
    }
}

struct WakeSchedule: Codable {
    var startHour:   Int
    var startMinute: Int
    var endHour:     Int
    var endMinute:   Int
    var dayMode:     DayMode
    var customDays:  Set<Int>   // Calendar weekday numbers — 1 = Sunday … 7 = Saturday
    var isEnabled:   Bool

    /// Sensible first-run default: 07:00–12:00, every day.
    static let `default` = WakeSchedule(
        startHour: 7,  startMinute: 0,
        endHour:   12, endMinute:   0,
        dayMode:   .everyday,
        customDays: [],
        isEnabled: true
    )

    // MARK: - Display helpers

    var startDisplayString: String { String(format: "%02d:%02d", startHour, startMinute) }
    var endDisplayString:   String { String(format: "%02d:%02d", endHour, endMinute) }

    var summaryLine: String { "\(startDisplayString) – \(endDisplayString) · \(dayMode.displayName)" }

    var durationMinutes: Int {
        (endHour * 60 + endMinute) - (startHour * 60 + startMinute)
    }

    /// Validation: end must come after start and window must meet Apple's 15-minute minimum.
    var isValid: Bool { durationMinutes >= 15 }

    // MARK: - Time logic (used by app and Monitor extension — no UIKit dependency)

    /// True if `now` falls inside the configured time window on any day.
    /// Same-day windows only; midnight crossing is out of scope.
    func isCurrentlyActive(calendar: Calendar = .current, now: Date = Date()) -> Bool {
        guard isEnabled else { return false }

        let comps = calendar.dateComponents([.hour, .minute], from: now)
        guard let h = comps.hour, let m = comps.minute else { return false }

        let current = h * 60 + m
        let start   = startHour * 60 + startMinute
        let end     = endHour   * 60 + endMinute

        return current >= start && current < end
    }

    /// True if `now` falls on one of the schedule's active weekdays.
    /// Phase A: .everyday is always true; other modes reserved for Phase B.
    func isActiveDay(calendar: Calendar = .current, now: Date = Date()) -> Bool {
        guard isEnabled else { return false }

        switch dayMode {
        case .everyday:
            return true
        case .weekdays:
            let wd = calendar.component(.weekday, from: now)
            return (2...6).contains(wd)   // Mon–Fri
        case .weekends:
            let wd = calendar.component(.weekday, from: now)
            return wd == 1 || wd == 7     // Sun or Sat
        case .custom:
            let wd = calendar.component(.weekday, from: now)
            return customDays.contains(wd)
        }
    }

    /// True if `now` is both inside the time window AND on an active day.
    func isWindowActive(calendar: Calendar = .current, now: Date = Date()) -> Bool {
        isCurrentlyActive(calendar: calendar, now: now) && isActiveDay(calendar: calendar, now: now)
    }

    /// The next wall-clock instant a window will start after `now` — today's
    /// start time if it's still ahead, else the next active day's. Used to clamp
    /// timeoutEndTime so a Timeout can never collide with tomorrow's window.
    /// Walks at most 8 days (covers every dayMode); nil if disabled or no active day.
    func nextWindowStart(after now: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard isEnabled else { return nil }

        for dayOffset in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            var comps    = calendar.dateComponents([.year, .month, .day], from: day)
            comps.hour   = startHour
            comps.minute = startMinute
            comps.second = 0
            guard let candidate = calendar.date(from: comps) else { continue }

            if candidate > now && isActiveDay(calendar: calendar, now: candidate) {
                return candidate
            }
        }
        return nil
    }
}

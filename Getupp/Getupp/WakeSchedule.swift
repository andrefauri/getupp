//
//  WakeSchedule.swift
//  Getupp
//
//  Persisted schedule model — shared between the main app and the Monitor extension.
//  IMPORTANT: Add to BOTH targets in Xcode's File Inspector (main app + GetuppMonitor).
//
//  Owns the TIME window only. WHICH days it arms lives in ActiveDays.swift
//  (activeDays: Set<Int> in the App Group) — no day mode is ever stored here.
//  Day-aware functions take the set as a parameter so this struct stays a pure
//  value type. (Older persisted blobs contained dayMode/customDays fields;
//  JSONDecoder ignores unknown keys, so they decode cleanly and are dropped on
//  the next save.)
//

import Foundation

struct WakeSchedule: Codable {
    var startHour:   Int
    var startMinute: Int
    var endHour:     Int
    var endMinute:   Int
    var isEnabled:   Bool

    /// Sensible first-run default: 07:00–12:00.
    static let `default` = WakeSchedule(
        startHour: 7,  startMinute: 0,
        endHour:   12, endMinute:   0,
        isEnabled: true
    )

    // MARK: - Display helpers

    var startDisplayString: String { String(format: "%02d:%02d", startHour, startMinute) }
    var endDisplayString:   String { String(format: "%02d:%02d", endHour, endMinute) }

    /// Time only — the Days row in Settings explains which days.
    var summaryLine: String { "\(startDisplayString) – \(endDisplayString)" }

    var durationMinutes: Int {
        (endHour * 60 + endMinute) - (startHour * 60 + startMinute)
    }

    /// Validation: end must come after start and window must meet Apple's 15-minute minimum.
    /// End-after-start also enforces the no-cross-midnight constraint (R6) — a window
    /// spanning midnight would make "which day is this session?" ambiguous.
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

    /// True if `now` is both inside the time window AND on a scheduled day.
    func isWindowActive(activeDays: Set<Int>, calendar: Calendar = .current, now: Date = Date()) -> Bool {
        isCurrentlyActive(calendar: calendar, now: now)
            && ActiveDays.isScheduled(on: now, days: activeDays, calendar: calendar)
    }

    /// The next wall-clock instant a window will start after `now` — today's
    /// start time if it's still ahead, else the next scheduled day's. Used to
    /// clamp timeoutEndTime so a Timeout can never collide with the next window
    /// (with a one-day-a-week schedule that bound can be up to 6 days out —
    /// harmless, since min() means a far bound simply never wins).
    ///
    /// Bounded search: walks at most 8 days. An empty set is defensively treated
    /// as all 7 (the never-empty invariant, see ActiveDays.load), so with the
    /// schedule enabled this ALWAYS finds a candidate — nil only when disabled.
    func nextWindowStart(after now: Date = Date(), activeDays: Set<Int>, calendar: Calendar = .current) -> Date? {
        guard isEnabled else { return nil }
        let days = activeDays.isEmpty ? ActiveDays.allSeven : activeDays

        for dayOffset in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            var comps    = calendar.dateComponents([.year, .month, .day], from: day)
            comps.hour   = startHour
            comps.minute = startMinute
            comps.second = 0
            guard let candidate = calendar.date(from: comps) else { continue }

            if candidate > now && ActiveDays.isScheduled(on: candidate, days: days, calendar: calendar) {
                return candidate
            }
        }
        return nil
    }
}

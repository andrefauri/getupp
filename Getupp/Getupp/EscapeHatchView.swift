//
//  EscapeHatchView.swift
//  Getupp
//
//  The Escape Hatch hub — exactly 2 controls, nothing else. Reached from
//  Settings → "Escape Hatch". Each row opens the shared EscapeConfirmationView
//  flow via ShieldManager.activeEscape.
//
//  Getupp target only.
//

import SwiftUI

struct EscapeHatchView: View {

    @EnvironmentObject var shieldManager: ShieldManager

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                emergencyBreakRow
                pullThePlugRow
            }
            .padding()
        }
        .navigationTitle("Escape Hatch")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Rows

    /// Disabled (dimmed, non-tappable, swapped subtitle) when there's nothing
    /// to escape from — phase derived the same way Timeout.swift does, never
    /// a stored flag.
    private var emergencyBreakRow: some View {
        let phase = shieldManager.currentPhase
        let isDisabled = phase == .free || phase == .preWindow

        return Button {
            shieldManager.activeEscape = .emergencyBreak
        } label: {
            row(
                title: EscapeHatchCopy.hubEmergencyTitle,
                subtitle: isDisabled
                    ? EscapeHatchCopy.hubEmergencyDisabledSubtitle
                    : EscapeHatchCopy.hubEmergencySubtitle
            )
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1.0)
    }

    private var pullThePlugRow: some View {
        Button {
            shieldManager.activeEscape = .pullThePlug
        } label: {
            row(title: EscapeHatchCopy.hubPullTitle, subtitle: EscapeHatchCopy.hubPullSubtitle)
        }
    }

    private func row(title: String, subtitle: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

#Preview {
    NavigationView {
        EscapeHatchView()
            .environmentObject(ShieldManager())
    }
}

// MARK: - Self-tests (DEBUG only)

#if DEBUG
/// Fixture-based self-tests for the Escape Hatch's deriveStreak invariants —
/// same PASS/FAIL format as runStreakSelfTests()/runTimeoutSelfTests(). Run
/// on-device via Internal Tools (no XCTest target exists for this POC).
func runEscapeHatchSelfTests() -> [String] {
    var results: [String] = []
    let calendar = Calendar.current
    let now = Date()

    func daysAgoString(_ n: Int, from date: Date = now) -> String {
        let d = calendar.date(byAdding: .day, value: -n, to: date) ?? date
        return dayFormatter.string(from: d)
    }

    func successRecord(daysAgo: Int) -> DayRecord {
        var r = DayRecord.fresh(date: daysAgoString(daysAgo), wasScheduled: true)
        r.sessionRan = true
        return r
    }

    func brokenRecord(daysAgo: Int) -> DayRecord {
        var r = DayRecord.fresh(date: daysAgoString(daysAgo), wasScheduled: true)
        r.emergencyUsed = true
        r.emergencyAt = calendar.date(byAdding: .day, value: -daysAgo, to: now)
        return r
    }

    func check(
        _ name: String,
        records: [DayRecord],
        windowEnd: Date,
        appEnabled: Bool = true,
        expectedCount: Int,
        expectedState: DayState
    ) {
        let result = deriveStreak(
            records: records,
            today: dayFormatter.string(from: now),
            now: now,
            windowEnd: windowEnd,
            timeoutDuration: 0,
            appEnabled: appEnabled
        )
        let pass = result.count == expectedCount && result.todayState == expectedState
        results.append(
            pass
                ? "PASS \(name)"
                : "FAIL \(name) — expected \(expectedCount)/\(expectedState), got \(result.count)/\(result.todayState)"
        )
    }

    let windowClosed = now.addingTimeInterval(-3600)

    // 1. Emergency Break today breaks the streak (today's DayRecord gets
    //    emergencyUsed = true via markEmergencyUsedToday).
    check("Emergency Break today -> streak 0",
          records: [brokenRecord(daysAgo: 0), successRecord(daysAgo: 1), successRecord(daysAgo: 2)],
          windowEnd: windowClosed,
          expectedCount: 0, expectedState: .broken)

    // 2. Pull the Plug does not backdate: a broken "yesterday" (when Pull the
    //    Plug was confirmed) followed by a fresh success today walks back only
    //    as far as the broken wall — old pre-pull successes don't resurrect.
    check("Pull the Plug wall stops backdating",
          records: [successRecord(daysAgo: 0), brokenRecord(daysAgo: 1), successRecord(daysAgo: 2), successRecord(daysAgo: 3)],
          windowEnd: windowClosed,
          expectedCount: 1, expectedState: .success)

    // 3. Disabled app (mid Pull-the-Plug) always derives to 0, regardless of
    //    the day log underneath.
    check("appEnabled false -> streak 0",
          records: (0...4).map { successRecord(daysAgo: $0) },
          windowEnd: windowClosed, appEnabled: false,
          expectedCount: 0, expectedState: .success)

    // 4. Live streak number renders in the implications copy (not hardcoded,
    //    not stale — pulled from the number passed in).
    let implications = EscapeHatchCopy.emergencyImplications(streak: 12)
    results.append(
        implications.contains("12")
            ? "PASS live streak number renders in implications copy"
            : "FAIL live streak number renders in implications copy — got: \(implications)"
    )

    // 5. Zero-streak variant swaps copy entirely (no "0-morning streak" line).
    let zeroImplications = EscapeHatchCopy.emergencyImplications(streak: 0)
    results.append(
        !zeroImplications.contains("-morning streak")
            ? "PASS zero-streak variant swaps copy"
            : "FAIL zero-streak variant swaps copy — got: \(zeroImplications)"
    )

    return results
}
#endif

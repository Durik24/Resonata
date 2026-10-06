import SwiftUI

/// A small ring in the open panel's top bar: how much of Claude's 5-hour
/// session limit is used. Hover for the reset time and the weekly limit.
/// Hidden when there's nothing current to show — see `ClaudeLimits`.
struct ClaudeLimitsBadge: View {
    /// Claude's coral, so the ring reads as "Claude" at a glance.
    private static let coral = Color(red: 0.85, green: 0.47, blue: 0.34)

    var body: some View {
        // Re-read every 15 s while the panel is open. Closed, the view
        // doesn't exist and the file isn't touched.
        TimelineView(.periodic(from: .now, by: 15)) { context in
            if let limits = ClaudeLimits.read(now: context.date),
               let window = limits.fiveHour ?? limits.sevenDay {
                let used = min(max(window.usedPercentage, 0), 100)
                HStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.18), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: used / 100)
                            .stroke(tint(for: used),
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 11, height: 11)
                    Text("\(Int(used.rounded())) %")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                }
                .contentShape(Rectangle())
                .help(tooltip(limits))
            }
        }
    }

    private func tint(for used: Double) -> Color {
        used >= 90 ? .red : Self.coral
    }

    private func tooltip(_ limits: ClaudeLimits) -> String {
        var lines: [String] = []
        if let five = limits.fiveHour {
            lines.append("Claude – 5h limit: \(Int(five.usedPercentage.rounded())) %, obnoví se \(time(five.resetsAt))")
        }
        if let week = limits.sevenDay {
            lines.append("Týdenní limit: \(Int(week.usedPercentage.rounded())) %, obnoví se \(time(week.resetsAt))")
        }
        return lines.joined(separator: "\n")
    }

    private func time(_ date: Date) -> String {
        let czech = Locale(identifier: "cs_CZ")
        if Calendar.current.isDateInToday(date) {
            return "v " + date.formatted(.dateTime.hour().minute().locale(czech))
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(czech))
    }
}

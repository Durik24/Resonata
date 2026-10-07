import SwiftUI

/// A small ring in the open panel's top bar: how much of Claude's 5-hour
/// session limit is used. Hover for the reset time and the weekly limit.
/// "–" when that window has run out and no newer one has been reported.
struct ClaudeLimitsBadge: View {
    /// Claude's coral, so the ring reads as "Claude" at a glance.
    private static let coral = Color(red: 0.85, green: 0.47, blue: 0.34)

    var body: some View {
        // Re-read every 15 s while the panel is open. Closed, the view
        // doesn't exist and the file isn't touched.
        TimelineView(.periodic(from: .now, by: 15)) { context in
            // Only once Claude Code has ever reported limits: before that
            // there's nothing to show at all.
            if FileManager.default.fileExists(atPath: ClaudeLimits.fileURL.path) {
                let limits = ClaudeLimits.read(now: context.date)
                // The session (5-hour) limit only — never the weekly one in
                // its place. Once that window has run out, the ring shows
                // "–" until Claude Code reports the next one.
                let used = limits?.fiveHour.map { min(max($0.usedPercentage, 0), 100) }
                HStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.18), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: (used ?? 0) / 100)
                            .stroke(tint(for: used ?? 0),
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 11, height: 11)
                    Text(used.map { "\(Int($0.rounded())) %" } ?? "–")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(used == nil ? 0.45 : 0.85))
                }
                .contentShape(Rectangle())
                .help(tooltip(limits))
            }
        }
    }

    private func tint(for used: Double) -> Color {
        used >= 90 ? .red : Self.coral
    }

    private func tooltip(_ limits: ClaudeLimits?) -> String {
        var lines: [String] = []
        if let five = limits?.fiveHour {
            lines.append("Claude – limit relace (5 h): \(Int(five.usedPercentage.rounded())) %, obnoví se \(time(five.resetsAt))")
        } else {
            lines.append("Claude – limit relace: zatím žádná nová data (přijdou po další odpovědi Clauda v terminálu)")
        }
        if let week = limits?.sevenDay {
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

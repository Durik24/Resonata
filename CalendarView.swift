import SwiftUI

/// The open panel's right-hand column: five days around today, today in the
/// album's colour, and the events of whichever day is picked.
struct CalendarColumn: View {
    @ObservedObject var store: CalendarStore
    /// The album accent, already made readable on black.
    var accent: Color

    @State private var selected = Calendar.current.startOfDay(for: Date())

    private static let czech = Locale(identifier: "cs_CZ")

    var body: some View {
        let days = CalendarStore.days(around: Date())
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(format(selected, "LLL"))
                        .font(.system(size: 15, weight: .bold))
                    Text(format(selected, "y"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(width: 40, alignment: .leading)
                ForEach(days, id: \.self) { day($0) }
            }
            events
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            // The panel can stay open across midnight, but each open starts
            // from today again.
            selected = Calendar.current.startOfDay(for: Date())
            store.reload()
        }
    }

    private func day(_ date: Date) -> some View {
        let isToday = Calendar.current.isDateInToday(date)
        let isSelected = date == selected
        let busy = !store.events(on: date).isEmpty
        return Button { selected = date } label: {
            VStack(spacing: 3) {
                Text(format(date, "EEEEEE"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(isToday ? 0.9 : 0.4))
                // The bare number: Czech formatting writes "6." with a dot.
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isToday ? .black : .white.opacity(0.85))
                    .frame(width: 24, height: 24)
                    .background {
                        Circle().fill(isToday ? accent
                                      : .white.opacity(isSelected ? 0.14 : 0))
                    }
                // A dot for days with something on, so the strip says where
                // to look before you click.
                Circle()
                    .fill(.white.opacity(busy ? 0.5 : 0))
                    .frame(width: 3, height: 3)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(TransportButtonStyle())
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }

    @ViewBuilder
    private var events: some View {
        switch store.access {
        case .notAsked:
            hint("Uvidíš tu své události.",
                 button: "Připojit kalendář") { store.requestAccess() }
        case .denied:
            hint("Resonata nemá přístup ke kalendáři.",
                 button: "Otevřít Nastavení") { store.openPrivacySettings() }
        case .granted:
            let list = store.events(on: selected)
            if list.isEmpty {
                Text("Žádné události")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.leading, 2)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(list.prefix(2)) { row($0) }
                    if list.count > 2 {
                        Text("+ \(list.count - 2) další")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.leading, 11)
                    }
                }
            }
        }
    }

    private func row(_ event: CalendarStore.Event) -> some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(accent)
                .frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(time(of: event))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)
            .truncationMode(.tail)
        }
    }

    private func hint(_ text: String, button: String,
                      action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
            Button(action: action) {
                Text(button)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.white.opacity(0.12)))
                    .contentShape(Capsule())
            }
            .buttonStyle(TransportButtonStyle())
        }
        .padding(.leading, 2)
    }

    private func time(of event: CalendarStore.Event) -> String {
        if event.isAllDay { return "Celý den" }
        let start = event.start.formatted(.dateTime.hour().minute().locale(Self.czech))
        let end = event.end.formatted(.dateTime.hour().minute().locale(Self.czech))
        return "\(start) – \(end)"
    }

    private func format(_ date: Date, _ template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Self.czech
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

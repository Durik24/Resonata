import SwiftUI

/// The open panel's "Časovač" page: the time left in a ring on the left,
/// the lengths to start on the right, with pause and cancel under them.
struct TimerView: View {
    @ObservedObject var timer: CountdownTimer
    var accent: Color

    // Read here so the Pomodoro button shows the lengths as soon as they
    // change in the settings.
    @AppStorage(Preferences.Key.pomodoroWork) private var pomodoroWork = 25
    @AppStorage(Preferences.Key.pomodoroRest) private var pomodoroRest = 5

    private let columns = Array(repeating: GridItem(.fixed(58), spacing: 8), count: 3)

    /// Orange for work and a plain timer, green for a Pomodoro break.
    private var tint: Color { timer.phase == .rest ? ActivityLook.green : accent }

    var body: some View {
        HStack(spacing: 28) {
            ring
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(CountdownTimer.presets, id: \.self) { minutes in
                        Button { timer.start(minutes: minutes) } label: {
                            Text("\(minutes) min")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                                .frame(width: 58, height: 26)
                                .background(Capsule().fill(.white.opacity(isCurrent(minutes) ? 0.2 : 0.08)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(TransportButtonStyle())
                    }
                }
                HStack(spacing: 8) {
                    if timer.isActive {
                        control(timer.isPaused ? "play.fill" : "pause.fill",
                                timer.isPaused ? "Pokračovat" : "Pozastavit") {
                            timer.isPaused ? timer.resume() : timer.pause()
                        }
                        control("xmark", "Zrušit") { timer.cancel() }
                    } else {
                        control("play.fill", "Spustit \(timer.chosenMinutes) min") {
                            timer.start(minutes: timer.chosenMinutes)
                        }
                        let plan = Preferences.pomodoroPlan
                        control("repeat", "Pomodoro \(pomodoroWork) + \(pomodoroRest)") { timer.startPomodoro() }
                            .help("\(plan.work) min práce a \(plan.rest) min pauza pořád dokola, každá \(plan.rounds). pauza \(plan.longRest) min. Délky nastavíš v Nastavení → Pomodoro.")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var ring: some View {
        // Once a second while it runs; paused or stopped, nothing ticks.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = timer.end == nil ? Date() : context.date
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.12), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: 1 - timer.progress(at: now))
                    .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(timer.isActive ? 1 : 0)
                VStack(spacing: 2) {
                    Text(CountdownTimer.format(timer.remaining(at: now)))
                        .font(.system(size: 24, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(timer.isPaused ? 0.5 : 1))
                    Text(caption)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .frame(width: 112, height: 112)
        }
    }

    private var caption: String {
        if timer.isPaused { return "pozastaveno" }
        switch timer.phase {
        case .work: return "práce · \(timer.round). kolo"
        case .rest: return "pauza"
        case nil: return timer.isActive ? "zbývá" : "časovač"
        }
    }

    private func isCurrent(_ minutes: Int) -> Bool {
        timer.isActive && timer.phase == nil && Int((timer.total / 60).rounded()) == minutes
    }

    private func control(_ symbol: String, _ title: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(.white.opacity(0.14)))
                .contentShape(Capsule())
        }
        .buttonStyle(TransportButtonStyle())
    }
}

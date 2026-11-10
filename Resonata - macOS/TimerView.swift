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

    /// What's in the ring's minutes field while it's typed in.
    @State private var typed = ""


    /// Orange for work and a plain timer, green for a Pomodoro break.
    private var tint: Color { timer.phase == .rest ? ActivityLook.green : accent }

    var body: some View {
        HStack(spacing: 28) {
            ring
            VStack(alignment: .leading, spacing: 12) {
                EagerGrid(items: CountdownTimer.presets, columns: 3, spacing: 8, rowSpacing: 8) { minutes in
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
                HStack(spacing: 8) {
                    if timer.isActive {
                        control(timer.isPaused ? "play.fill" : "pause.fill",
                                timer.isPaused ? L.t("Resume", "Pokračovat") : L.t("Pause", "Pozastavit")) {
                            timer.isPaused ? timer.resume() : timer.pause()
                        }
                        control("xmark", L.t("Cancel", "Zrušit")) { timer.cancel() }
                    } else {
                        control("play.fill", L.t("Start \(timer.chosenMinutes) min", "Spustit \(timer.chosenMinutes) min")) {
                            timer.start(minutes: timer.chosenMinutes)
                        }
                        let plan = Preferences.pomodoroPlan
                        control("repeat", "Pomodoro \(pomodoroWork) + \(pomodoroRest)") { timer.startPomodoro() }
                            .help(L.t("\(plan.work) min of work and \(plan.rest) min of break, over and over; every \(plan.rounds)th break is \(plan.longRest) min. Set the lengths in Settings → Pomodoro.",
                                      "\(plan.work) min práce a \(plan.rest) min pauza pořád dokola, každá \(plan.rounds). pauza \(plan.longRest) min. Délky nastavíš v Nastavení → Pomodoro."))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.12), lineWidth: 6)
            if timer.isActive {
                // Once a second while it runs; paused, nothing ticks.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let now = timer.end == nil ? Date() : context.date
                    ZStack {
                        Circle()
                            .trim(from: 0, to: 1 - timer.progress(at: now))
                            .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 2) {
                            Text(CountdownTimer.format(timer.remaining(at: now)))
                                .font(.system(size: 24, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white.opacity(timer.isPaused ? 0.5 : 1))
                            Text(caption)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
            } else {
                dial
            }
        }
        .frame(width: 112, height: 112)
    }

    /// Stopped, the ring is where the length is set — any length, not just
    /// the buttons': − and + a minute at a time (hold to keep going), or
    /// click the number and type it.
    private var dial: some View {
        VStack(spacing: 4) {
            // Text, read as it's typed, rather than a number field: that
            // only takes the value on Return, so typing 37 and clicking
            // "Spustit" started the old length.
            TextField(L.t("Minutes", "Minuty"), text: $typed)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 26, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 70)
                .help(L.t("Click and type the minutes", "Klikni a napiš počet minut"))
                .onAppear { typed = "\(timer.chosenMinutes)" }
                .onChange(of: typed) { _, text in
                    let digits = String(text.filter(\.isWholeNumber).prefix(3))
                    if digits != text { typed = digits; return }
                    if let value = Int(digits), value > 0 { timer.choose(minutes: value) }
                }
                // − and +, and a typed 999 kept to 240, show here at once.
                .onChange(of: timer.chosenMinutes) { _, value in
                    if Int(typed) != value { typed = "\(value)" }
                }
                // Left empty or at 0, it goes back to the length that counts.
                .onSubmit { typed = "\(timer.chosenMinutes)" }
            HStack(spacing: 10) {
                step("minus", by: -1)
                Text("min")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                step("plus", by: 1)
            }
        }
    }


    private func step(_ symbol: String, by delta: Int) -> some View {
        Button { timer.choose(minutes: timer.chosenMinutes + delta) } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(TransportButtonStyle())
        .buttonRepeatBehavior(.enabled)
        .help(delta > 0 ? L.t("A minute more", "O minutu víc") : L.t("A minute less", "O minutu míň"))
        .accessibilityLabel(delta > 0 ? L.t("A minute more", "O minutu víc") : L.t("A minute less", "O minutu míň"))
    }

    private var caption: String {
        if timer.isPaused { return L.t("paused", "pozastaveno") }
        switch timer.phase {
        case .work: return L.t("work · round \(timer.round)", "práce · \(timer.round). kolo")
        case .rest: return L.t("break", "pauza")
        case nil: return timer.isActive ? L.t("left", "zbývá") : L.t("timer", "časovač")
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

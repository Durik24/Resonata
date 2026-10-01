import Foundation

/// How the bars and the wave move.
///
/// Made up, not heard. Resonata deliberately doesn't listen to the computer's
/// sound — no audio capture and no recording permission — so the motion can't
/// follow the music's frequencies. What it can be is calm and organic rather
/// than mechanical: each point is a sum of three slow sines at unrelated
/// speeds and phases, so neighbouring points move differently and the whole
/// never visibly repeats. It runs only while something is playing, and the
/// glow on each new lyric line (`LyricPulse`) supplies the timing the music
/// actually has.
enum Motion {

    /// Height of point `index` at time `time`, 0...1, centred on 0.5.
    static func level(_ index: Int, at time: TimeInterval) -> Double {
        let i = Double(index)
        let slow = 0.24 * sin(time * 1.3 + i * 0.71)
        let middle = 0.15 * sin(time * 2.9 + i * 1.87 + 1.0)
        let quick = 0.09 * sin(time * 5.3 + i * 3.13 + 2.0)
        return min(max(0.5 + slow + middle + quick, 0), 1)
    }
}

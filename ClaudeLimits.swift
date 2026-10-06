import Foundation

/// Claude's subscription usage limits — the 5-hour session window and the
/// weekly one — for the little gauge in the open panel's top bar.
///
/// Read from a file, never fetched. Claude Code hands its status line a JSON
/// description of the session, `rate_limits` included; the status-line
/// script below keeps only that part and writes it next to Resonata's other
/// files. No login, no token, nothing over the network: the numbers are as
/// fresh as the last time Claude Code drew its status line.
struct ClaudeLimits: Equatable {
    struct Window: Equatable {
        /// 0–100, the share of the window's limit already used.
        var usedPercentage: Double
        var resetsAt: Date
    }

    var fiveHour: Window?
    var sevenDay: Window?

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Resonata", isDirectory: true)
    }
    static var fileURL: URL { folder.appendingPathComponent("claude-limits.json") }
    static var scriptURL: URL { folder.appendingPathComponent("claude-statusline.sh") }

    static func read(now: Date = Date()) -> ClaudeLimits? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return parse(data, now: now)
    }

    /// Windows that have already reset are dropped: their percentage
    /// describes a window that's over, and the new one starts at zero.
    static func parse(_ data: Data, now: Date = Date()) -> ClaudeLimits? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        func window(_ key: String) -> Window? {
            guard let w = json[key] as? [String: Any],
                  let used = (w["used_percentage"] as? NSNumber)?.doubleValue,
                  let resets = (w["resets_at"] as? NSNumber)?.doubleValue else { return nil }
            let date = Date(timeIntervalSince1970: resets)
            return date > now ? Window(usedPercentage: used, resetsAt: date) : nil
        }
        let limits = ClaudeLimits(fiveHour: window("five_hour"), sevenDay: window("seven_day"))
        return limits.fiveHour == nil && limits.sevenDay == nil ? nil : limits
    }

    /// The status-line script Claude Code runs. Prints the model and the
    /// session limit for Claude Code's own status line, and writes the
    /// `rate_limits` part — and only that part — for Resonata.
    static let script = """
    #!/bin/sh
    # Claude Code status line, installed by Resonata.
    # Claude Code pipes the session's status in as JSON. This keeps only the
    # subscription usage limits, for the notch, and prints a short line.
    dir="$HOME/Library/Application Support/Resonata"
    input=$(cat)
    limits=$(printf '%s' "$input" | /usr/bin/plutil -extract rate_limits json -o - - 2>/dev/null)
    if [ -n "$limits" ]; then
      mkdir -p "$dir"
      printf '%s' "$limits" > "$dir/claude-limits.json.tmp" && mv -f "$dir/claude-limits.json.tmp" "$dir/claude-limits.json"
      five=$(printf '%s' "$limits" | /usr/bin/plutil -extract five_hour.used_percentage raw -o - - 2>/dev/null)
    fi
    model=$(printf '%s' "$input" | /usr/bin/plutil -extract model.display_name raw -o - - 2>/dev/null)
    if [ -n "$five" ]; then
      printf '%s · %.0f %% z 5h limitu' "$model" "$five"
    else
      printf '%s' "$model"
    fi

    """

    /// Puts the script in place, or brings an older copy up to date. Cheap
    /// and idempotent, so it runs on every launch.
    static func installScript() {
        let fm = FileManager.default
        if let current = try? String(contentsOf: scriptURL, encoding: .utf8), current == script { return }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            NSLog("Resonata: could not install the Claude status-line script: \(error)")
        }
    }
}

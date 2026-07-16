import SwiftUI

extension AppModel {
    func loadPlaybackFile(url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            playbackStatus = String(localized: "Could not read file.")
            return
        }
        do {
            playbackRows = try Self.parsePlaybackCSV(text)
            playbackStatus = String(localized: "Loaded \(String(playbackRows.count)) rows.")
        } catch {
            playbackRows = []
            playbackStatus = String(localized: "Failed to parse CSV: \(error.localizedDescription)")
        }
    }

    /// Spreadsheet exports from European-locale apps commonly use ";" as
    /// the field separator (since "," is their decimal separator) rather
    /// than ",". Detected from whichever appears more often in the header
    /// line, then used consistently for every row.
    private static func detectDelimiter(_ headerLine: String) -> Character {
        let commaCount = headerLine.filter { $0 == "," }.count
        let semicolonCount = headerLine.filter { $0 == ";" }.count
        return semicolonCount > commaCount ? ";" : ","
    }

    static func parsePlaybackCSV(_ text: String) throws -> [PlaybackRow] {
        // whereSeparator: \.isNewline (not separator: "\n") because CRLF
        // line endings collapse to a single "\r\n" Character in Swift -
        // one grapheme cluster that never equals "\n", so splitting on the
        // "\n" Character silently produced one giant unsplit line for any
        // Windows-style export.
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard lines.count >= 2 else { return [] }
        let delimiter = detectDelimiter(lines[0])
        let header = lines[0].split(separator: delimiter).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let iCh = header.firstIndex(of: "channel"),
              let iT = header.firstIndex(of: "time_s"),
              let iV = header.firstIndex(of: "voltage_v"),
              let iI = header.firstIndex(of: "current_a") else {
            throw DeviceError.decodeFailed
        }
        let iOn = header.firstIndex(of: "output_on")

        var rows: [PlaybackRow] = []
        for line in lines.dropFirst() where !line.isEmpty {
            let cols = line.split(separator: delimiter, omittingEmptySubsequences: false).map { String($0) }
            guard cols.count > max(iCh, iT, iV, iI) else { continue }
            var on: Bool? = nil
            if let iOn = iOn, cols.count > iOn {
                let raw = cols[iOn].trimmingCharacters(in: .whitespaces).lowercased()
                on = raw == "true" || raw == "1"
            }
            rows.append(PlaybackRow(
                channel: cols[iCh].trimmingCharacters(in: .whitespaces),
                t: Double(cols[iT]) ?? 0,
                voltage: Double(cols[iV]) ?? 0,
                current: Double(cols[iI]) ?? 0,
                outputOn: on
            ))
        }
        return rows.sorted { $0.t < $1.t }
    }

    func startPlayback() {
        guard !playbackRows.isEmpty else { return }
        playing = true
        let t0 = playbackRows[0].t

        for row in playbackRows {
            let delay = row.t - t0
            let task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await self.applyPlaybackRow(row)
            }
            playbackTasks.append(task)
        }

        let total = (playbackRows.last?.t ?? t0) - t0
        let finishTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, total) * 1_000_000_000) + 200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.stopPlayback(finished: true)
        }
        playbackTasks.append(finishTask)
    }

    private func applyPlaybackRow(_ row: PlaybackRow) async {
        do {
            try await device.setSetpoint(ch: row.channel, voltage: row.voltage, current: row.current)
            if let on = row.outputOn {
                try await device.setOutput(ch: row.channel, state: on ? "ON" : "OFF")
            }
            playbackStatus = String(localized: "Applied \(row.channel) @ t=\(String(format: "%.1f", row.t))s")
        } catch {
            playbackStatus = String(localized: "Playback error: \(error.localizedDescription)")
        }
    }

    func stopPlayback(finished: Bool = false) {
        playing = false
        playbackTasks.forEach { $0.cancel() }
        playbackTasks = []
        playbackStatus = finished ? String(localized: "Playback finished.") : String(localized: "Playback stopped.")
    }
}

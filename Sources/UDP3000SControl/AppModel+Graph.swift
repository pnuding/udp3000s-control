import SwiftUI
import AppKit

extension AppModel {
    func recordSample(chKey: String, voltage: Double, current: Double, outputOn: Bool) {
        guard graphing else { return }
        guard channels.contains(where: { $0.id == chKey }) else { return }
        if graphSeries[chKey] == nil {
            let color = channels.first(where: { $0.id == chKey })?.config.color ?? .gray
            graphSeries[chKey] = GraphSeries(color: color)
        }
        let t = Date().timeIntervalSince(graphStartTime)
        let series = graphSeries[chKey]!
        series.voltage.append(GraphPoint(t: t, y: voltage))
        series.current.append(GraphPoint(t: t, y: current))
        series.outputOn.append(outputOn)
        // Publishing per sample meant 12 app-wide invalidations a second
        // (3 channels x 4Hz), each re-rendering every view observing
        // AppModel and rebuilding the whole chart. The data itself is
        // still recorded at full rate - only the UI notification is
        // coalesced to ~1Hz.
        let now = Date()
        if now.timeIntervalSince(lastGraphPublish) >= 1.0 {
            lastGraphPublish = now
            objectWillChange.send()
        }
    }

    func startGraph() {
        graphSeries = [:]
        hiddenSeries = []
        for ch in channels {
            graphSeries[ch.id] = GraphSeries(color: ch.config.color)
        }
        graphStartTime = Date()
        lastGraphPublish = .distantPast
        graphing = true
    }

    func stopGraph() {
        graphing = false
    }

    func clearGraph() {
        graphSeries = [:]
        hiddenSeries = []
    }

    func toggleSeriesVisibility(_ key: String) {
        if hiddenSeries.contains(key) {
            hiddenSeries.remove(key)
        } else {
            hiddenSeries.insert(key)
        }
    }

    func exportCSV() {
        var dataRows: [[String]] = []
        for (key, series) in graphSeries {
            var lastKept: (v: Double, i: Double, on: Bool)? = nil
            for idx in 0..<series.voltage.count {
                let v = series.voltage[idx].y
                let i = series.current[idx].y
                let on = series.outputOn[idx]
                if let last = lastKept, last.v == v, last.i == i, last.on == on { continue }
                let t = series.voltage[idx].t
                // Model-aware decimals, same as the readouts: a bare
                // UDP3305S reports one more digit of resolution than the
                // -E/-U variants, and hardcoding 2/3 here silently threw
                // that extra digit away in exports.
                dataRows.append([
                    key,
                    String(format: "%.3f", t),
                    String(format: "%.\(voltageDecimals)f", v),
                    String(format: "%.\(currentDecimals)f", i),
                    on ? "true" : "false",
                ])
                lastKept = (v, i, on)
            }
        }
        guard !dataRows.isEmpty else { return }
        dataRows.sort { a, b in
            let ta = Double(a[1]) ?? 0, tb = Double(b[1]) ?? 0
            return ta != tb ? ta < tb : a[0] < b[0]
        }
        var rows = [["channel", "time_s", "voltage_v", "current_a", "output_on"]]
        rows.append(contentsOf: dataRows)
        let csv = rows.map { $0.joined(separator: ",") }.joined(separator: "\n")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "udp3305s-log-\(stamp).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        // begin(), not runModal(): the modal variant parks the main run
        // loop while the dialog is open, stalling the poll loop (and any
        // in-progress graph recording) the whole time the user browses
        // for a save location.
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // AppKit calls this on the main thread; assumeIsolated makes
            // that visible to the compiler so the alert (MainActor-bound
            // API) can be shown from here.
            MainActor.assumeIsolated {
                do {
                    try csv.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    // Silently swallowing a failed write (the old try?)
                    // left the user thinking the export succeeded.
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = String(localized: "Could not save CSV")
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }
}

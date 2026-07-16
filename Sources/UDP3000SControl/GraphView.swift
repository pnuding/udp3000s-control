import SwiftUI
import Charts

struct GraphView: View {
    @EnvironmentObject var model: AppModel

    private var sortedSeries: [(key: String, value: GraphSeries)] {
        model.graphSeries.sorted { $0.key < $1.key }
    }

    private var colorScale: (domain: [String], range: [Color]) {
        (sortedSeries.map(\.key), sortedSeries.map { $0.value.color })
    }

    private var maxT: Double {
        let points = sortedSeries.flatMap { key, series -> [GraphPoint] in
            var pts: [GraphPoint] = []
            if !model.hiddenSeries.contains("\(key):v") { pts += series.voltage }
            if !model.hiddenSeries.contains("\(key):i") { pts += series.current }
            return pts
        }
        return max(1, points.map(\.t).max() ?? 1)
    }

    private var maxVoltage: Double {
        let points = sortedSeries.flatMap { key, series in model.hiddenSeries.contains("\(key):v") ? [] : series.voltage }
        return max(0.1, (points.map(\.y).max() ?? 0) * 1.1)
    }

    private var maxCurrent: Double {
        let points = sortedSeries.flatMap { key, series in model.hiddenSeries.contains("\(key):i") ? [] : series.current }
        return max(0.1, (points.map(\.y).max() ?? 0) * 1.1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(model.graphing ? "Stop" : "Start") {
                    model.graphing ? model.stopGraph() : model.startGraph()
                }
                .buttonStyle(.borderedProminent)
                .help(model.graphing ? "Stop recording readings" : "Start recording readings")
                Button("Clear") { model.clearGraph() }
                    .help("Clear all recorded data")
                Spacer()
                Button("Export CSV…") { model.exportCSV() }
                    .help("Save recorded data as a CSV file")
            }

            legend

            Text("Voltage (V)").font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(sortedSeries, id: \.key) { key, series in
                    if !model.hiddenSeries.contains("\(key):v") {
                        ForEach(downsampled(series.voltage), id: \.t) { point in
                            LineMark(x: .value("t", point.t), y: .value("V", point.y))
                                .foregroundStyle(by: .value("Channel", key))
                        }
                    }
                }
            }
            .chartForegroundStyleScale(domain: colorScale.domain, range: colorScale.range)
            .chartLegend(.hidden)
            .chartXScale(domain: 0...maxT)
            .chartYScale(domain: 0...maxVoltage)
            .chartXAxisLabel("Time (s)")
            // min, not fixed: a fixed 140 made resizing the window pile
            // dead space below the charts instead of stretching them -
            // the whole point of resizing a graph window.
            .frame(minHeight: 140, maxHeight: .infinity)

            Text("Current (A)").font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(sortedSeries, id: \.key) { key, series in
                    if !model.hiddenSeries.contains("\(key):i") {
                        ForEach(downsampled(series.current), id: \.t) { point in
                            LineMark(x: .value("t", point.t), y: .value("A", point.y))
                                .foregroundStyle(by: .value("Channel", key))
                        }
                    }
                }
            }
            .chartForegroundStyleScale(domain: colorScale.domain, range: colorScale.range)
            .chartLegend(.hidden)
            .chartXScale(domain: 0...maxT)
            .chartYScale(domain: 0...maxCurrent)
            .chartXAxisLabel("Time (s)")
            .frame(minHeight: 140, maxHeight: .infinity)
        }
    }

    // Display-only decimation: the chart rebuilds a LineMark per point on
    // every update, so an hours-long recording (tens of thousands of
    // samples) would get very sluggish. Strided sampling caps rendering
    // at ~500 marks per series regardless of recording length; the
    // full-resolution data is untouched (CSV export still sees every
    // sample). On very long recordings a brief spike between kept samples
    // can be skipped in the display - the tradeoff for a chart that stays
    // responsive.
    private func downsampled(_ points: [GraphPoint]) -> [GraphPoint] {
        let maxPoints = 500
        guard points.count > maxPoints else { return points }
        let step = (points.count + maxPoints - 1) / maxPoints
        var out = [GraphPoint]()
        out.reserveCapacity(maxPoints + 1)
        var i = 0
        while i < points.count {
            out.append(points[i])
            i += step
        }
        // Always keep the newest sample so the line's leading edge tracks
        // live rather than lagging up to `step` samples behind.
        if let last = points.last, out.last!.t != last.t {
            out.append(last)
        }
        return out
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(sortedSeries, id: \.key) { key, series in
                legendButton(seriesKey: "\(key):v", label: "\(key) V", color: series.color)
                legendButton(seriesKey: "\(key):i", label: "\(key) A", color: series.color)
            }
            Spacer()
        }
    }

    private func legendButton(seriesKey: String, label: String, color: Color) -> some View {
        let hidden = model.hiddenSeries.contains(seriesKey)
        return Button {
            model.toggleSeriesVisibility(seriesKey)
        } label: {
            HStack(spacing: 4) {
                Rectangle().fill(color).frame(width: 12, height: 3)
                Text(label).font(.caption2)
            }
            .opacity(hidden ? 0.35 : 1.0)
        }
        .buttonStyle(.plain)
        .help(hidden ? "Show \(label) on the chart" : "Hide \(label) from the chart")
    }
}

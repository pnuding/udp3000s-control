import SwiftUI
import Foundation

struct ChannelConfig: Identifiable, Equatable {
    let id: String // the SCPI channel token: CH1 / CH2 / CH3 / SER / PARA
    let label: String
    let vmax: Double
    let imax: Double
    let color: Color
}

// What the wattage readout currently shows - tapping it cycles through
// these. Wh/mAh are per-on-cycle accumulators the device itself resets to
// 0 the instant output turns off, not lifetime totals.
enum WattDisplayMode: Int, CaseIterable {
    case watts, wattHours, milliampHours
}

@MainActor
final class ChannelState: ObservableObject, Identifiable {
    let config: ChannelConfig
    nonisolated var id: String { config.id }

    @Published var voltage: Double = 0
    @Published var current: Double = 0
    @Published var power: Double = 0
    @Published var energyWh: Double = 0
    @Published var capacityAh: Double = 0
    @Published var wattDisplayMode: WattDisplayMode = .watts
    @Published var outputOn: Bool = false
    // Direct from :OUTPut:CVCC? - whether this channel is presently
    // current-limited (CC) rather than voltage-regulated (CV). Replaces an
    // earlier heuristic that compared readings against setpoints; the
    // device already knows this and just tells us.
    @Published var constantCurrent: Bool = false

    @Published var setVoltage: Double = 0
    @Published var setCurrent: Double = 0
    @Published var setVoltageDirty = false
    @Published var setCurrentDirty = false

    @Published var ovpValue: Double = 0
    @Published var ovpEnabled: Bool = false
    @Published var ocpValue: Double = 0
    @Published var ocpEnabled: Bool = false
    @Published var ovpValueDirty = false
    @Published var ocpValueDirty = false
    @Published var protectionDirty = false

    // ovpEnabled/ocpEnabled above are what the toggle is bound to, so they
    // flip the instant you tap it - before Apply. These track what's
    // actually confirmed active on the device, updated only by a real
    // device sync or a successful apply, so the fuse indicator reflects
    // reality rather than an unsent pending edit.
    @Published var appliedOvpEnabled: Bool = false
    @Published var appliedOcpEnabled: Bool = false

    // Set once the device reports a trip via the latched per-channel
    // status register (see DeviceClient.protectionTripped) - stays set
    // across poll cycles until the user turns the output back on or
    // applies a setpoint/protection change, not just until the next poll.
    @Published var ovpTripped: Bool = false
    @Published var ocpTripped: Bool = false
    // Set once, at the moment ovpTripped/ocpTripped first flips true - not
    // touched again on later poll cycles while it's still latched, so the
    // tooltip keeps showing when the trip actually happened rather than
    // the last time this was polled.
    @Published var ovpTrippedAt: Date?
    @Published var ocpTrippedAt: Date?

    @Published var statusMessage: String = ""
    @Published var statusIsError = false

    // When this stops advancing (connection lost), the readings shown are
    // whatever was last measured - stale, potentially misleading. Views
    // compare against this to decide when to show placeholder dashes
    // instead of a frozen-looking number.
    @Published var lastGoodUpdate = Date()

    init(config: ChannelConfig) {
        self.config = config
    }

    func setStatus(_ message: String, isError: Bool = false) {
        statusMessage = message
        statusIsError = isError
    }
}

// Not Identifiable-via-UUID: that allocated a fresh UUID per recorded
// sample (4Hz x channels x hours) purely to satisfy ForEach, and defeated
// cheap diffing. Within one series `t` is strictly increasing, so views
// use ForEach(id: \.t) instead.
struct GraphPoint {
    let t: Double
    let y: Double
}

final class GraphSeries {
    let color: Color
    var voltage: [GraphPoint] = []
    var current: [GraphPoint] = []
    var outputOn: [Bool] = []

    init(color: Color) {
        self.color = color
    }
}

struct PlaybackRow {
    let channel: String
    let t: Double
    let voltage: Double
    let current: Double
    let outputOn: Bool?
}

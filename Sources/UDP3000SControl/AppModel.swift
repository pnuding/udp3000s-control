import SwiftUI
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let device = DeviceClient()

    @Published var host: String
    @Published var connected = false
    @Published var connectionError: String? = nil

    private static let hostDefaultsKey = "deviceHost"

    @Published var mode: String = "" // "" = not yet known, forces the first checkMode() to load setpoints
    @Published var channels: [ChannelState]

    // Populated from *IDN? right after connecting. Distinct UDP3000S-series
    // models behave slightly differently (see extraDecimal/
    // supportsEnergyCapacity below), so this drives those rather than
    // hardcoding assumptions about a single model.
    @Published var deviceModel: String = ""
    @Published var firmwareVersion: String = ""
    @Published var windowTitle: String = "UDP3000S Control"

    // The bare UDP3305S has one more decimal of resolution on both voltage
    // and current than the -E/-U variants this app was originally built
    // against. Defaults to -E/-U precision until a model is identified.
    var extraDecimal: Bool {
        let upper = deviceModel.uppercased()
        guard !upper.isEmpty else { return false }
        return !upper.hasSuffix("-E") && !upper.hasSuffix("-U")
    }
    var voltageDecimals: Int { extraDecimal ? 3 : 2 }
    var currentDecimals: Int { extraDecimal ? 4 : 3 }

    // The undocumented MEASure:ENERgy?/MEASure:CAPacity? queries only
    // exist from firmware 1.17 onward - older units just time out instead
    // of erroring, so this is gated on the reported version rather than
    // discovered the slow way on every poll cycle.
    var supportsEnergyCapacity: Bool {
        guard !firmwareVersion.isEmpty else { return false }
        return Self.compareVersions(firmwareVersion, "1.17") >= 0
    }

    private static func compareVersions(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    // Mirrors the device's own physical "all on/off" button: on if any
    // channel is on, off only once every channel is. Kept as its own
    // @Published property (rather than a computed `channels.contains
    // { $0.outputOn }`) because ChannelState is a separate ObservableObject
    // - a per-channel outputOn flip publishes *that* object's own change,
    // not AppModel's, so a toolbar view observing only AppModel would
    // never see a computed property update. This is refreshed explicitly
    // wherever outputOn can change.
    @Published var anyOutputOn = false

    @Published var graphing = false
    @Published var graphSeries: [String: GraphSeries] = [:]
    @Published var hiddenSeries: Set<String> = []
    var graphStartTime = Date()
    // Data is recorded at full poll rate, but the UI notification for it
    // is coalesced (see recordSample) - this tracks the last time one
    // actually went out.
    var lastGraphPublish = Date.distantPast

    @Published var playbackRows: [PlaybackRow] = []
    @Published var playing = false
    @Published var playbackStatus: String = ""
    var playbackTasks: [Task<Void, Never>] = []

    private var pollTask: Task<Void, Never>?
    private var setpointPollTask: Task<Void, Never>?

    static let blue = Color(red: 0x1f / 255, green: 0x6f / 255, blue: 0xe0 / 255)
    static let yellow = Color(red: 0xe0 / 255, green: 0xb4 / 255, blue: 0x00 / 255)
    static let magenta = Color(red: 0xd8 / 255, green: 0x1b / 255, blue: 0x93 / 255)

    // String(localized:) here, not a plain literal: these labels flow into
    // several places downstream (Text(channel.config.label), and several
    // interpolated .help()/accessibilityLabel strings elsewhere) that
    // display or interpolate an already-built String rather than a fresh
    // LocalizedStringKey literal - localizing at the source is what makes
    // all of those come out translated instead of just the first one.
    static let normalConfigs = [
        ChannelConfig(id: "CH1", label: String(localized: "Channel 1"), vmax: 33, imax: 5.2, color: blue),
        ChannelConfig(id: "CH2", label: String(localized: "Channel 2"), vmax: 33, imax: 5.2, color: yellow),
        ChannelConfig(id: "CH3", label: String(localized: "Channel 3"), vmax: 6.2, imax: 3.2, color: magenta),
    ]
    static let serConfigs = [
        ChannelConfig(id: "SER", label: String(localized: "Series (Ch1+Ch2)"), vmax: 66, imax: 5.2, color: blue),
        normalConfigs[2],
    ]
    static let paraConfigs = [
        ChannelConfig(id: "PARA", label: String(localized: "Parallel (Ch1+Ch2)"), vmax: 33, imax: 10.4, color: blue),
        normalConfigs[2],
    ]

    init() {
        host = UserDefaults.standard.string(forKey: Self.hostDefaultsKey) ?? ""
        channels = Self.normalConfigs.map { ChannelState(config: $0) }
    }

    // ---------- connection ----------

    func connect() async {
        // Trim rather than reject: a pasted trailing space or newline is
        // the realistic bad input here and would otherwise fail with an
        // opaque network error. Persisting happens here, on apply, rather
        // than in a didSet - binding the text field straight to `host`
        // was writing UserDefaults on every keystroke.
        host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        UserDefaults.standard.set(host, forKey: Self.hostDefaultsKey)
        await device.setHost(host)
        do {
            try await device.connect()
            connected = true
            connectionError = nil
            if let idn = try? await device.identify() {
                deviceModel = idn.model
                firmwareVersion = idn.firmware
                // Test-only override so model-specific layout (the bare
                // UDP3305S's extra decimal) can be previewed without
                // actually owning one: `FORCE_MODEL=UDP3305S` env var.
                if let forced = ProcessInfo.processInfo.environment["FORCE_MODEL"], !forced.isEmpty {
                    deviceModel = forced
                }
                windowTitle = deviceModel.isEmpty
                    ? String(localized: "UDP3000S Control")
                    : String(localized: "\(deviceModel) Control")
                // A fresh connection could be to a different, older unit
                // than whatever this session last talked to - don't leave
                // a channel stuck showing Wh/mAh if the newly-identified
                // device doesn't actually support it.
                if !supportsEnergyCapacity {
                    for ch in channels { ch.wattDisplayMode = .watts }
                }
            }
            startPolling()
        } catch {
            connected = false
            connectionError = error.localizedDescription
            stopPolling()
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refreshAll()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        // Setpoint/protection values only ever got loaded once (on mode
        // detection) and then never refreshed again, so a change made
        // directly on the device's own front panel would never show up
        // here. This re-syncs them once a second - slower than the live
        // readings since they change far less often - but skips any field
        // the user has a pending, not-yet-applied edit in, so it never
        // clobbers work in progress.
        setpointPollTask?.cancel()
        setpointPollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                if self.connected {
                    for ch in self.channels {
                        await self.refreshSetpointAndProtectionIfClean(ch)
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        setpointPollTask?.cancel()
        setpointPollTask = nil
    }

    // ---------- polling / mode ----------

    private func refreshAll() async {
        await checkMode()
        // Once the device drops off, every per-channel call below would
        // just fail too and paper the cards with their own "Read error"
        // messages while the toolbar still claimed "Connected" - checkMode
        // already re-tries the device every cycle, so it's the single
        // source of truth for connectivity; nothing else needs to run
        // (or show its own error) while it's down.
        guard connected else { return }
        for ch in channels {
            await refreshChannel(ch)
        }
        syncAnyOutputOn()
    }

    private func syncAnyOutputOn() {
        anyOutputOn = channels.contains { $0.outputOn }
    }

    private func checkMode() async {
        let newMode: String
        do {
            newMode = try await device.getMode()
        } catch {
            connected = false
            connectionError = error.localizedDescription
            return
        }
        if !connected {
            connected = true
            connectionError = nil
            for ch in channels where ch.statusIsError { ch.setStatus("") }
        }
        guard newMode != mode else { return }
        mode = newMode
        let configs: [ChannelConfig]
        switch newMode {
        case "SER": configs = Self.serConfigs
        case "PARA": configs = Self.paraConfigs
        default: configs = Self.normalConfigs
        }
        channels = configs.map { ChannelState(config: $0) }
        for ch in channels {
            await loadSetpointAndProtection(ch)
        }
    }

    private func loadSetpointAndProtection(_ ch: ChannelState) async {
        if let sp = try? await device.getSetpoint(ch: ch.id) {
            ch.setVoltage = sp.voltage
            ch.setCurrent = sp.current
            ch.setVoltageDirty = false
            ch.setCurrentDirty = false
        }
        if let prot = try? await device.getProtection(ch: ch.id) {
            let ovpOn = prot.ovpState.trimmingCharacters(in: .whitespaces).uppercased() == "ON"
            let ocpOn = prot.ocpState.trimmingCharacters(in: .whitespaces).uppercased() == "ON"
            ch.ovpValue = prot.ovpValue
            ch.ovpEnabled = ovpOn
            ch.appliedOvpEnabled = ovpOn
            ch.ocpValue = prot.ocpValue
            ch.ocpEnabled = ocpOn
            ch.appliedOcpEnabled = ocpOn
            ch.ovpValueDirty = false
            ch.ocpValueDirty = false
            ch.protectionDirty = false
        }
    }

    /// Same sync as loadSetpointAndProtection, but never overwrites a
    /// field the user has an unapplied edit sitting in (its dirty flag is
    /// still set) - used for the ongoing once-a-second background refresh,
    /// as opposed to the unconditional load right after mode detection.
    private func refreshSetpointAndProtectionIfClean(_ ch: ChannelState) async {
        if let sp = try? await device.getSetpoint(ch: ch.id) {
            if !ch.setVoltageDirty { ch.setVoltage = sp.voltage }
            if !ch.setCurrentDirty { ch.setCurrent = sp.current }
        }
        if let prot = try? await device.getProtection(ch: ch.id) {
            // Applied state always reflects the device, dirty or not - a
            // pending, unsent toggle flip shouldn't make the fuse look
            // like the change already took effect.
            let ovpOn = prot.ovpState.trimmingCharacters(in: .whitespaces).uppercased() == "ON"
            let ocpOn = prot.ocpState.trimmingCharacters(in: .whitespaces).uppercased() == "ON"
            ch.appliedOvpEnabled = ovpOn
            ch.appliedOcpEnabled = ocpOn
            if !ch.ovpValueDirty { ch.ovpValue = prot.ovpValue }
            if !ch.ocpValueDirty { ch.ocpValue = prot.ocpValue }
            if !ch.protectionDirty {
                ch.ovpEnabled = ovpOn
                ch.ocpEnabled = ocpOn
            }
        }
    }

    private func refreshChannel(_ ch: ChannelState) async {
        // Output state first: recordSample and the CC/energy gating below
        // want this cycle's value - when this query ran last, the graph
        // export's output_on column lagged one poll tick (250ms) behind
        // every real switch.
        if let state = try? await device.outputState(ch: ch.id) {
            ch.outputOn = state.trimmingCharacters(in: .whitespaces).uppercased() == "ON"
        }

        // Checked every cycle regardless of on/off - the trip already
        // happened by the time outputOn reads false, and the latched
        // event register is what actually holds the flag long enough for
        // this poll rate to catch it (see protectionTripped). Once set,
        // only clearProtectionTrip (on output-on / setpoint / protection
        // apply) resets it - never overwritten back to false just because
        // this cycle's read came back clean.
        if let trip = try? await device.protectionTripped(ch: ch.id) {
            if trip.ovp {
                if !ch.ovpTripped { ch.ovpTrippedAt = Date() }
                ch.ovpTripped = true
            }
            if trip.ocp {
                if !ch.ocpTripped { ch.ocpTrippedAt = Date() }
                ch.ocpTripped = true
            }
        }

        do {
            let meas = try await device.measure(ch: ch.id)
            ch.voltage = meas.voltage
            ch.current = meas.current
            ch.power = meas.power
            ch.lastGoodUpdate = Date()
            // Only clear a stale read-error, never a just-shown confirmation
            // like "Setpoint applied." - otherwise it vanishes ~300ms later
            // and the card's height flickers as the status line collapses.
            if ch.statusIsError { ch.setStatus("") }
            recordSample(chKey: ch.id, voltage: meas.voltage, current: meas.current, outputOn: ch.outputOn)
        } catch {
            ch.setStatus(String(localized: "Read error: \(error.localizedDescription)"), isError: true)
        }

        // With the output off there's nothing worth asking: CV/CC is
        // meaningless, and the device has already reset both accumulators
        // to 0 (they're per-on-cycle counters) - so mirror that locally
        // and skip up to 3 queries per off channel, roughly a third of
        // idle polling traffic.
        if ch.outputOn {
            if let cvcc = try? await device.cvcc(ch: ch.id) { ch.constantCurrent = cvcc.hasPrefix("CC") }
            if supportsEnergyCapacity {
                if let wh = try? await device.measureEnergyWh(ch: ch.id) { ch.energyWh = wh }
                if let ah = try? await device.measureCapacityAh(ch: ch.id) { ch.capacityAh = ah }
            }
        } else {
            ch.constantCurrent = false
            ch.energyWh = 0
            ch.capacityAh = 0
        }
    }

    // ---------- channel actions ----------

    func toggleOutput(_ ch: ChannelState) async {
        let newState = ch.outputOn ? "OFF" : "ON"
        do {
            try await device.setOutput(ch: ch.id, state: newState)
            ch.outputOn.toggle()
            if newState == "ON" {
                ch.ovpTripped = false
                ch.ocpTripped = false
                ch.ovpTrippedAt = nil
                ch.ocpTrippedAt = nil
            }
        } catch {
            ch.setStatus(String(localized: "Toggle failed: \(error.localizedDescription)"), isError: true)
        }
        syncAnyOutputOn()
    }

    // Same on/off-together logic as the device's own front-panel button:
    // if anything is on, this turns everything off; only once everything
    // is off does it turn everything on. The programming manual documents
    // an ALL channel token for OUTPut:STATe, so this is a single command
    // rather than the per-channel loop it used to be - every channel
    // switches in the same instant, with one network round trip.
    func toggleAllOutputs() async {
        let turnOn = !anyOutputOn
        do {
            try await device.setOutput(ch: "ALL", state: turnOn ? "ON" : "OFF")
            for ch in channels {
                ch.outputOn = turnOn
                if turnOn {
                    ch.ovpTripped = false
                    ch.ocpTripped = false
                    ch.ovpTrippedAt = nil
                    ch.ocpTrippedAt = nil
                }
            }
        } catch {
            for ch in channels {
                ch.setStatus(String(localized: "Toggle failed: \(error.localizedDescription)"), isError: true)
            }
        }
        syncAnyOutputOn()
    }

    @discardableResult
    func applySetpoint(_ ch: ChannelState) async -> Bool {
        let voltage = round(ch.setVoltage, voltageDecimals)
        let current = round(ch.setCurrent, currentDecimals)
        do {
            try await device.setSetpoint(ch: ch.id, voltage: voltage, current: current)
            ch.setVoltageDirty = false
            ch.setCurrentDirty = false
            ch.ovpTripped = false
            ch.ocpTripped = false
            ch.ovpTrippedAt = nil
            ch.ocpTrippedAt = nil
            return true
        } catch {
            ch.setStatus(String(localized: "Setpoint failed: \(error.localizedDescription)"), isError: true)
            return false
        }
    }

    @discardableResult
    func applyProtection(_ ch: ChannelState) async -> Bool {
        let ovpValue = round(ch.ovpValue, voltageDecimals)
        let ocpValue = round(ch.ocpValue, currentDecimals)
        let ovpState = ch.ovpEnabled ? "ON" : "OFF"
        let ocpState = ch.ocpEnabled ? "ON" : "OFF"
        do {
            try await device.setProtection(ch: ch.id, ovpValue: ovpValue, ovpState: ovpState, ocpValue: ocpValue, ocpState: ocpState)
            ch.ovpValueDirty = false
            ch.ocpValueDirty = false
            ch.protectionDirty = false
            ch.appliedOvpEnabled = ch.ovpEnabled
            ch.appliedOcpEnabled = ch.ocpEnabled
            ch.ovpTripped = false
            ch.ocpTripped = false
            ch.ovpTrippedAt = nil
            ch.ocpTrippedAt = nil
            return true
        } catch {
            ch.setStatus(String(localized: "Protection failed: \(error.localizedDescription)"), isError: true)
            return false
        }
    }

    private func round(_ value: Double, _ places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (value * factor).rounded() / factor
    }
}

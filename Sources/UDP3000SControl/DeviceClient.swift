// Swift port of the same raw-SCPI-socket backend used by device.js
// (Electron) and main.rs (Tauri): connect to port 5025, one synchronous
// reply per query.
//
// This being an actor does NOT by itself serialize scpi() calls the way
// the Python/Node/Rust backends' explicit locks do: actors only guarantee
// exclusivity *between* await points, and scpi() suspends twice (once
// sending, once waiting for the reply). With two independent poll loops
// both calling in here, a second call's send+receive could interleave
// with the first's, and readLine() would then hand back whichever call's
// query happened to check the buffer first - not necessarily the one that
// actually asked. That's what caused "ghost values": a card's own reading
// query intermittently returning another query's reply instead of its
// own. The explicit lock below closes that window the same way the other
// backends' locks do.

import Foundation
import Network

/// NWConnection's stateUpdateHandler can fire from multiple states in
/// quick succession; this guards a continuation against being resumed
/// more than once, safely across whatever queue the handler runs on.
final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func markIfFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

enum DeviceError: LocalizedError {
    case notConnected
    case noReply
    case connectionClosed
    case decodeFailed
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConnected: return String(localized: "not connected")
        case .noReply: return String(localized: "no reply")
        case .connectionClosed: return String(localized: "connection closed by device")
        case .decodeFailed: return String(localized: "could not decode reply")
        case .timeout: return String(localized: "timed out waiting for device")
        }
    }
}

struct Measurement { let voltage: Double; let current: Double; let power: Double }
struct Protection { let ovpValue: Double; let ovpState: String; let ocpValue: Double; let ocpState: String }
struct ProtectionTrip { let ovp: Bool; let ocp: Bool }
struct DeviceIdentity { let manufacturer: String; let model: String; let serial: String; let firmware: String }

actor DeviceClient {
    private var connection: NWConnection?
    // No default - always set via setHost() before connect(); a connect
    // attempt against "" fails immediately rather than probing some
    // baked-in address.
    private var host: String = ""
    private let port: NWEndpoint.Port = 5025
    private var buffer = Data()

    // A minimal async mutex: acquireLock()/releaseLock() are only ever
    // called from within this actor's own isolated methods, and neither
    // does anything awaitable while touching lockBusy/lockWaiters, so
    // there's no reentrancy window inside the lock itself - only the
    // critical section it guards is allowed to suspend.
    private var lockBusy = false
    private var lockWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireLock() async {
        if !lockBusy {
            lockBusy = true
            return
        }
        await withCheckedContinuation { cont in
            lockWaiters.append(cont)
        }
    }

    private func releaseLock() {
        if let next = lockWaiters.first {
            lockWaiters.removeFirst()
            next.resume()
        } else {
            lockBusy = false
        }
    }

    // NWConnection has no built-in operation timeout: if the device goes
    // dark mid-call (unplugged, cable pulled) with no more traffic to
    // provoke a TCP-level failure, a receive()/send() completion handler
    // can simply never fire, leaving the caller suspended forever - still
    // holding the lock above - and blocking every future call including a
    // user-initiated reconnect. A `withThrowingTaskGroup` timeout was
    // tried here first and made things worse: cancelling the group does
    // NOT stop a suspended CheckedContinuation, so the "abandoned" attempt
    // kept running in the background and could complete much later,
    // silently overwriting `connection` with a socket that had since gone
    // stale - exactly the "Socket is not connected" that never recovered.
    // This version instead races the real completion against a GCD
    // deadline for exactly one winner (via ResumeGuard), and the loser is
    // deterministically cancelled rather than left to run unsupervised.
    private func withDeadline<T>(_ seconds: Double, _ start: @escaping (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        let resumeGuard = ResumeGuard()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            start { result in
                if resumeGuard.markIfFirst() { cont.resume(with: result) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if resumeGuard.markIfFirst() { cont.resume(throwing: DeviceError.timeout) }
            }
        }
    }

    func setHost(_ h: String) {
        host = h
    }

    func connect() async throws {
        await acquireLock()
        defer { releaseLock() }
        try await connectLocked()
    }

    // scpi() already holds the lock when it auto-reconnects on a dropped
    // connection, so it calls this directly - going through connect()
    // there would deadlock trying to acquire a lock it's already holding.
    private func connectLocked() async throws {
        connection?.cancel()
        connection = nil
        buffer.removeAll()

        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let resumeGuard = ResumeGuard()
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if resumeGuard.markIfFirst() { cont.resume() }
                    case .failed(let err):
                        if resumeGuard.markIfFirst() { cont.resume(throwing: err) }
                    case .cancelled:
                        if resumeGuard.markIfFirst() { cont.resume(throwing: DeviceError.connectionClosed) }
                    default:
                        break
                    }
                }
                conn.start(queue: .global(qos: .userInitiated))
                // A dead/blackholed route can leave the socket neither
                // ready nor failed for a very long time. If our deadline
                // wins the race, explicitly cancel this attempt so a late
                // ".ready" can never sneak in afterwards and get assigned
                // below once we've already moved on.
                DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                    if resumeGuard.markIfFirst() {
                        conn.cancel()
                        cont.resume(throwing: DeviceError.timeout)
                    }
                }
            }
        } catch {
            conn.cancel()
            throw error
        }
        connection = conn
    }

    private func receiveChunk() async throws -> Data {
        guard let conn = connection else { throw DeviceError.notConnected }
        return try await withDeadline(3) { complete in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if let error = error {
                    complete(.failure(error))
                } else if let data = data, !data.isEmpty {
                    complete(.success(data))
                } else if isComplete {
                    complete(.failure(DeviceError.connectionClosed))
                } else {
                    complete(.success(Data()))
                }
            }
        }
    }

    private func readLine() async throws -> String {
        while true {
            if let idx = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<idx]
                buffer.removeSubrange(...idx)
                guard let s = String(data: lineData, encoding: .utf8) else { throw DeviceError.decodeFailed }
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let chunk = try await receiveChunk()
            buffer.append(chunk)
        }
    }

    /// Sends one SCPI line. Returns the reply for a query ("?" in cmd), or
    /// nil for a plain write command, which gets no reply from the device.
    @discardableResult
    func scpi(_ cmd: String) async throws -> String? {
        await acquireLock()
        defer { releaseLock() }

        do {
            if connection == nil { try await connectLocked() }
            guard let conn = connection else { throw DeviceError.notConnected }
            let isQuery = cmd.contains("?")
            let line = (cmd + "\n").data(using: .utf8)!

            try await withDeadline(3) { complete in
                conn.send(content: line, completion: .contentProcessed { error in
                    complete(error.map { .failure($0) } ?? .success(()))
                })
            }

            guard isQuery else { return nil }
            return try await readLine()
        } catch {
            // A dead socket (device unplugged, network drop, etc.) never
            // fixes itself: without this, every future call kept reusing
            // the same broken `connection` object forever instead of
            // retrying connectLocked() above, so the app could never
            // recover once the device went away.
            connection?.cancel()
            connection = nil
            buffer.removeAll()
            throw error
        }
    }

    func measure(ch: String) async throws -> Measurement {
        guard let line = try await scpi("MEASURE:ALL? \(ch)") else { throw DeviceError.noReply }
        let parts = line.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        return Measurement(
            voltage: parts.count > 0 ? parts[0] : 0,
            current: parts.count > 1 ? parts[1] : 0,
            power: parts.count > 2 ? parts[2] : 0
        )
    }

    func outputState(ch: String) async throws -> String {
        guard let s = try await scpi("OUTPUT:STATE? \(ch)") else { throw DeviceError.noReply }
        return s
    }

    /// Returns "CV" or "CC" - whether the channel is presently voltage- or
    /// current-limited. Direct device query, so no need to infer this from
    /// comparing readings against setpoints.
    func cvcc(ch: String) async throws -> String {
        guard let s = try await scpi("OUTPUT:CVCC? \(ch)") else { throw DeviceError.noReply }
        return s.trimmingCharacters(in: .whitespaces).uppercased()
    }

    /// manufacturer, model (e.g. "UDP3305S-E"), serial, firmware version.
    func identify() async throws -> DeviceIdentity {
        guard let line = try await scpi("*IDN?") else { throw DeviceError.noReply }
        let parts = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        return DeviceIdentity(
            manufacturer: parts.count > 0 ? parts[0] : "",
            model: parts.count > 1 ? parts[1] : "",
            serial: parts.count > 2 ? parts[2] : "",
            firmware: parts.count > 3 ? parts[3] : ""
        )
    }

    // Undocumented in UNI-T's published v1.3 programming manual (which
    // matches firmware 1.10) but accepted cleanly by this unit on firmware
    // 1.17, alongside the documented MEASURE:ALL/VOLTage/CURRent/POWEr
    // family - confirmed live against the real device: values track
    // power/current draw over time as expected, and both reset to 0 the
    // instant the output turns off (a per-on-cycle counter, not a lifetime
    // total). Units are watt-hours and amp-hours directly, not milli-.
    func measureEnergyWh(ch: String) async throws -> Double {
        guard let line = try await scpi("MEASURE:ENERGY? \(ch)") else { throw DeviceError.noReply }
        return Double(line.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    func measureCapacityAh(ch: String) async throws -> Double {
        guard let line = try await scpi("MEASURE:CAPACITY? \(ch)") else { throw DeviceError.noReply }
        return Double(line.trimmingCharacters(in: .whitespaces)) ?? 0
    }

    func setOutput(ch: String, state: String) async throws {
        try await scpi("OUTPUT:STATE \(ch),\(state)")
    }

    func getSetpoint(ch: String) async throws -> (voltage: Double, current: Double) {
        guard let vline = try await scpi("APPLY? \(ch),VOLT") else { throw DeviceError.noReply }
        guard let iline = try await scpi("APPLY? \(ch),CURRENT") else { throw DeviceError.noReply }
        let v = Double(vline.split(separator: ",").last?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
        let i = Double(iline.split(separator: ",").last?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
        return (v, i)
    }

    func setSetpoint(ch: String, voltage: Double?, current: Double?) async throws {
        if let v = voltage, !v.isNaN { try await scpi("APPLY \(ch),\(v)V") }
        if let c = current, !c.isNaN { try await scpi("APPLY \(ch),\(c)A") }
    }

    func getProtection(ch: String) async throws -> Protection {
        guard let ovpV = try await scpi("OUTPUT:OVP:VALUE? \(ch)") else { throw DeviceError.noReply }
        guard let ovpS = try await scpi("OUTPUT:OVP:STATE? \(ch)") else { throw DeviceError.noReply }
        guard let ocpV = try await scpi("OUTPUT:OCP:VALUE? \(ch)") else { throw DeviceError.noReply }
        guard let ocpS = try await scpi("OUTPUT:OCP:STATE? \(ch)") else { throw DeviceError.noReply }
        return Protection(
            ovpValue: Double(ovpV.trimmingCharacters(in: .whitespaces)) ?? 0,
            ovpState: ovpS,
            ocpValue: Double(ocpV.trimmingCharacters(in: .whitespaces)) ?? 0,
            ocpState: ocpS
        )
    }

    // Undocumented like MEASURE:ENERGY/CAPACITY above, but confirmed live
    // against the real device: the *main* STATus:QUEStionable?/:CONDition?
    // registers never reflect a trip on this firmware (always read 0, even
    // immediately after one), and the live per-channel :CONDition? clears
    // again within ~150ms of the output settling off - too fast for this
    // app's ~250ms poll cycle to reliably catch. The latched per-channel
    // :EVENt? register is the one that actually works: it holds bit 2 (OVP)
    // or bit 3 (OCP) until read, confirmed by tripping each protection and
    // reading this a full second later. SER/PARA have no confirmed mapping
    // of their own (untested on real hardware in that mode) - they fall
    // back to channel 1's summary, since CH1 is the "master" side of a
    // combined SER/PARA output.
    func protectionTripped(ch: String) async throws -> ProtectionTrip {
        let n = ch.hasPrefix("CH") ? (Int(ch.dropFirst(2)) ?? 1) : 1
        guard let line = try await scpi("STATus:QUEStionable:INSTrument:ISUMmary\(n):EVENt?") else { throw DeviceError.noReply }
        let bits = Int(line.trimmingCharacters(in: .whitespaces)) ?? 0
        return ProtectionTrip(ovp: bits & 4 != 0, ocp: bits & 8 != 0)
    }

    func setProtection(ch: String, ovpValue: Double?, ovpState: String?, ocpValue: Double?, ocpState: String?) async throws {
        if let v = ovpValue, !v.isNaN { try await scpi("OUTPUT:OVP:VALUE \(ch),\(v)") }
        if let s = ovpState { try await scpi("OUTPUT:OVP:STATE \(ch),\(s)") }
        if let v = ocpValue, !v.isNaN { try await scpi("OUTPUT:OCP:VALUE \(ch),\(v)") }
        if let s = ocpState { try await scpi("OUTPUT:OCP:STATE \(ch),\(s)") }
    }

    func getMode() async throws -> String {
        guard let raw = try await scpi("SOURCE:MODE?") else { throw DeviceError.noReply }
        let upper = raw.trimmingCharacters(in: .whitespaces).uppercased()
        if upper.hasPrefix("SER") { return "SER" }
        if upper.hasPrefix("PARA") { return "PARA" }
        return "NORMAL"
    }
}

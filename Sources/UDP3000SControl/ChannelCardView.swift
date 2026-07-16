import SwiftUI
import AppKit

// System time formatting, not a translated string - follows the user's
// Region setting (12h/24h, separators) independently of whatever language
// the app's own UI text is showing, same as every other Mac app.
private func formattedTripTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .medium
    return formatter.string(from: date)
}

struct ChannelCardView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var channel: ChannelState
    var channelIndex: Int
    var focusedField: FocusState<Int?>.Binding
    @State private var showProtection = false

    // Deliberately natural (unconstrained) sizing everywhere below rather
    // than right-aligning within a shared width - that was tried and
    // caused two separate problems: it made the dirty-state border draw
    // around the wider invisible alignment box instead of the visible
    // field, and it pushed the visible digits away from the leading edge
    // that "Protection" (and everything else) aligns to. The one thing
    // this trades away is pixel-perfect alignment of the unit label
    // between the reading row and the setpoint row below it - a much
    // smaller cosmetic cost than either of those bugs.
    // +4pt (half a digit at the field's default 13pt system font, measured
    // via NSAttributedString) over the original 48 - felt a hair tight.
    private let fieldControlWidth: CGFloat = 52
    // Reserve room for the *entire* reading row (value + unit together) so
    // a channel showing fewer digits right now doesn't shift once it shows
    // more. Re-measured via NSAttributedString (not guessed) for the
    // larger .title readout font used below - .title2's numbers from the
    // original layout were too small once the font grew:
    //   value "33.00"/"66.00" ~86.5 + gap 2 + "V" ~7    = 96
    //   value "5.200"/"10.400" ~103.9 + gap 2 + "A" ~7  = 113
    //   value "171.60"/"343.20" ~103.9 + gap 2 + "W" ~7 = 113
    // Bare UDP3305S units show one extra decimal digit on voltage/current
    // (see AppModel.extraDecimal) - ~17pt/digit at this font size, so that
    // extra digit gets its own bit of headroom rather than a re-measurement.
    private var voltageMinWidth: CGFloat { 96 + (model.extraDecimal ? 17 : 0) }
    private var currentMinWidth: CGFloat { 114 + (model.extraDecimal ? 17 : 0) }
    private let powerMinWidth: CGFloat = 114

    var body: some View {
        // Ticks once a second purely to re-check "has it been too long
        // since the last successful read" - readings themselves are still
        // driven by the 150ms poll loop; this is only what decides when
        // to swap them for placeholder dashes if that poll loop hasn't
        // actually gotten anything back in a while.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let stale = !model.connected || context.date.timeIntervalSince(channel.lastGoodUpdate) > 5
            VStack(alignment: .leading, spacing: 10) {
                header
                readingsAndControls(stale: stale)
                // Reserved height regardless of content, so an error
                // appearing or clearing never resizes (and reflows the
                // whole grid).
                Text(channel.statusMessage.isEmpty ? " " : channel.statusMessage)
                    .font(.caption)
                    .foregroundStyle(channel.statusIsError ? .red : .secondary)
                    .frame(height: 14, alignment: .leading)
            }
            .padding(10)
            // Grid sizes its own two columns tightly on its own, but
            // nothing else here stops the *header's* Spacer (which pushes
            // the on/off toggle to the card's right edge) from expanding
            // to fill however much width is on offer. A guessed maxWidth
            // cap was tried here first, but that only helps once the
            // window is already sized - when SwiftUI probes "how big
            // could this content get" to size a *brand new* window with
            // no saved frame, it proposes a generous width, and a maxWidth
            // cap just becomes the size the card reports back (all 3
            // cards hitting their cap, badly oversizing a first launch).
            // .fixedSize forces this view to always compute its true
            // ideal width - where the header's Spacer reports its small
            // natural size, not "as much as offered" - regardless of how
            // generous a proposal it's given.
            .fixedSize(horizontal: true, vertical: false)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(channel.config.color.opacity(0.6), lineWidth: 2)
            )
        }
    }

    private var header: some View {
        HStack {
            Circle().fill(channel.config.color).frame(width: 10, height: 10)
            Text(channel.config.label).font(.headline)
            Spacer()
            Toggle("", isOn: Binding(
                get: { channel.outputOn },
                set: { _ in Task { await model.toggleOutput(channel) } }
            ))
            .labelsHidden()
            .toggleStyle(ColoredSwitchToggleStyle(tint: channel.config.color))
            .disabled(!model.connected)
            .help(channel.outputOn ? "Turn \(channel.config.label) output off" : "Turn \(channel.config.label) output on")
        }
    }

    // Readouts stacked in the left column, the matching operable control
    // for each one directly to its right in the second column - Grid (not
    // a manually-paired HStack) so both columns line up across rows
    // automatically. Protection has no readout of its own, so its row
    // just leaves the first column empty rather than spanning both.
    private func readingsAndControls(stale: Bool) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                reading(stale ? "--" : String(format: "%.\(model.voltageDecimals)f", channel.voltage), "V", minWidth: voltageMinWidth)
                SetpointField(
                    value: Binding(
                        get: { channel.setVoltage },
                        set: { channel.setVoltage = $0 }
                    ),
                    decimals: model.voltageDecimals,
                    range: 0...channel.config.vmax,
                    width: fieldControlWidth,
                    accessibilityLabel: "\(channel.config.label) voltage setpoint",
                    dirty: channel.setVoltageDirty,
                    helpText: "Setpoint range: 0–\(String(format: "%g", channel.config.vmax))V",
                    focusIndex: channelIndex * 2,
                    focusedField: focusedField,
                    onDirty: { channel.setVoltageDirty = true },
                    onCommit: { Task { await model.applySetpoint(channel) } },
                    onTabAdvance: { reverse in advanceFocus(reverse: reverse) }
                )
                .equatable()
            }
            GridRow {
                reading(
                    stale ? "--" : String(format: "%.\(model.currentDecimals)f", channel.current), "A",
                    minWidth: currentMinWidth,
                    valueColor: (!stale && channel.constantCurrent) ? .red : .primary
                )
                SetpointField(
                    value: Binding(
                        get: { channel.setCurrent },
                        set: { channel.setCurrent = $0 }
                    ),
                    decimals: model.currentDecimals,
                    range: 0...channel.config.imax,
                    width: fieldControlWidth,
                    accessibilityLabel: "\(channel.config.label) current setpoint",
                    dirty: channel.setCurrentDirty,
                    helpText: "Setpoint range: 0–\(String(format: "%g", channel.config.imax))A",
                    focusIndex: channelIndex * 2 + 1,
                    focusedField: focusedField,
                    onDirty: { channel.setCurrentDirty = true },
                    onCommit: { Task { await model.applySetpoint(channel) } },
                    onTabAdvance: { reverse in advanceFocus(reverse: reverse) }
                )
                .equatable()
            }
            GridRow {
                wattReading(stale: stale)
                // Icon rather than "Apply" text: several of the 13
                // localizations run longer than English (e.g. Dutch
                // "Toepassen", Swedish "Verkställ" at 9 characters), which
                // would have blown out the card's carefully measured
                // column-2 width. A checkmark needs no translation at all.
                let dirty = channel.setVoltageDirty || channel.setCurrentDirty
                Button {
                    Task { await model.applySetpoint(channel) }
                } label: {
                    Image(systemName: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .frame(width: fieldControlWidth)
                .buttonStyle(.borderedProminent)
                // .disabled() alone barely dims a borderedProminent button -
                // it stayed looking clickable even when it wasn't. Muting
                // the tint to gray when there's nothing to apply makes the
                // "inactive" state actually read as inactive, while still
                // getting the full accent-color prominence the moment a
                // field becomes dirty.
                .tint(dirty ? Color.accentColor : Color.secondary)
                .controlSize(.small)
                .disabled(!dirty)
                .help("Apply setpoint changes")
            }
            GridRow {
                // A bare Spacer() here (tried first) doesn't know it's
                // sitting in a Grid cell - its default vertical growth
                // demand stretched this whole row (and the protection
                // button with it) down to fill the card's leftover
                // height. Color.clear has no such demand.
                Color.clear.frame(width: 1, height: 1)
                protectionButton
            }
        }
    }

    private func reading(_ value: String, _ unit: String, minWidth: CGFloat = 0, valueColor: Color = .primary) -> some View {
        // .lastTextBaseline, not .bottom: with two different font sizes,
        // .bottom lines up the *frames'* bottom edges, which sits the
        // smaller unit label's actual glyph baseline visibly lower than
        // the value's - this aligns their real text baselines instead.
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            Text(value)
                .font(.system(.title, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundStyle(valueColor)
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
        // On the whole row, not just the value: reserving only the value's
        // width left the unit label unprotected and it got squeezed to
        // nothing under pressure. .leading (not .trailing) so a longer
        // reading never needs truncating, without shifting shorter ones
        // away from Protection's own left edge below.
        .frame(minWidth: minWidth, alignment: .leading)
    }

    // Tapping cycles W -> Wh -> mAh, same tap-to-toggle style as the
    // protection button below (no Button chrome). Wh/mAh are the device's
    // own per-on-cycle accumulators - it resets them to 0 itself the
    // instant output turns off, so this never needs its own reset control.
    private func wattReading(stale: Bool) -> some View {
        let (value, unit): (String, String) = {
            switch channel.wattDisplayMode {
            case .watts: return (stale ? "--" : String(format: "%.2f", channel.power), "W")
            case .wattHours: return (stale ? "--" : Self.adaptive(channel.energyWh, maxDecimals: 4), "Wh")
            case .milliampHours: return (stale ? "--" : Self.adaptive(channel.capacityAh * 1000, maxDecimals: 1), "mAh")
            }
        }()
        return reading(value, unit, minWidth: powerMinWidth)
            .contentShape(Rectangle())
            .onTapGesture {
                guard model.supportsEnergyCapacity else { return }
                let all = WattDisplayMode.allCases
                let next = (channel.wattDisplayMode.rawValue + 1) % all.count
                channel.wattDisplayMode = all[next]
            }
            .help(model.supportsEnergyCapacity ? "Tap to cycle W / Wh / mAh" : "")
    }

    // Wh/mAh accumulate without bound over a long run - fixed decimals
    // would keep widening the readout column (and with it the whole
    // locked window) as the integer part grows. Shedding decimals as the
    // value grows keeps the number to ~6 characters total, which is what
    // powerMinWidth reserves space for.
    private static func adaptive(_ value: Double, maxDecimals: Int) -> String {
        let intDigits = value < 1 ? 1 : Int(log10(value)) + 1
        let decimals = max(0, min(maxDecimals, 6 - intDigits))
        return String(format: "%.\(decimals)f", value)
    }

    private var protectionButton: some View {
        HStack(spacing: 4) {
            if tripped {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            FuseSymbol()
                .stroke(tripped ? Color.red : (protectionActive ? Color.primary : Color.secondary.opacity(0.35)), lineWidth: 1.5)
                .frame(width: 22, height: 8)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { showProtection.toggle() }
        .popover(isPresented: $showProtection) {
            ProtectionPopoverContent(
                channelLabel: channel.config.label,
                vmax: channel.config.vmax,
                imax: channel.config.imax,
                voltageDecimals: model.voltageDecimals,
                currentDecimals: model.currentDecimals,
                ovpEnabled: Binding(
                    get: { channel.ovpEnabled },
                    set: { channel.ovpEnabled = $0; channel.protectionDirty = true }
                ),
                ovpValue: $channel.ovpValue,
                ovpValueDirty: $channel.ovpValueDirty,
                ovpTripped: channel.ovpTripped,
                ovpTrippedAt: channel.ovpTrippedAt,
                ocpEnabled: Binding(
                    get: { channel.ocpEnabled },
                    set: { channel.ocpEnabled = $0; channel.protectionDirty = true }
                ),
                ocpValue: $channel.ocpValue,
                ocpValueDirty: $channel.ocpValueDirty,
                ocpTripped: channel.ocpTripped,
                ocpTrippedAt: channel.ocpTrippedAt,
                protectionDirty: $channel.protectionDirty,
                onCommit: { Task { await model.applyProtection(channel) } }
            )
            .equatable()
            .padding()
        }
        .help(protectionTooltip)
        // 2pt of trailing padding pulls the chevron in from the true
        // trailing edge - flush right made it stand out against the
        // Apply button/fields above, which have their own inherent
        // bezel/border inset.
        .padding(.trailing, 2)
        // A fixed width matching column 2's own established width
        // (fieldControlWidth), not maxWidth: .infinity - .infinity is
        // harmless once the window is already sized (it just fills
        // whatever width the other rows already established), but when
        // SwiftUI probes "how big could this content get" to size a
        // brand new window with no saved frame, anything with an
        // unbounded maxWidth actually expands to fill that generous
        // proposal, dragging every card out to its maxWidth cap - which
        // is exactly what caused new installs to open oversized.
        .frame(width: fieldControlWidth, alignment: .trailing)
    }

    private var protectionActive: Bool {
        channel.appliedOvpEnabled || channel.appliedOcpEnabled
    }

    private var tripped: Bool {
        channel.ovpTripped || channel.ocpTripped
    }

    // OVP takes priority if somehow both are latched at once (unobserved
    // in testing - the two protections tripped independently every time)
    // since the fuse only has room for one warning icon anyway.
    private var protectionTooltip: LocalizedStringKey {
        if channel.ovpTripped, let at = channel.ovpTrippedAt {
            return "OVP tripped at \(formattedTripTime(at))"
        }
        if channel.ocpTripped, let at = channel.ocpTrippedAt {
            return "OCP tripped at \(formattedTripTime(at))"
        }
        return "Protection settings"
    }

    private func dirtyOverlay(_ dirty: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.orange, lineWidth: dirty ? 2 : 0)
    }

    // Field index = channelIndex*2 (volts) or channelIndex*2+1 (amps);
    // wraps around both ends so Tab from the last field goes back to CH1's
    // volts field rather than leaving the window.
    private func advanceFocus(reverse: Bool) {
        let total = model.channels.count * 2
        guard total > 0 else { return }
        let current = focusedField.wrappedValue ?? (channelIndex * 2)
        focusedField.wrappedValue = reverse ? (current - 1 + total) % total : (current + 1) % total
    }
}

// Same rationale and pattern as ProtectionPopoverContent below: `channel`'s
// voltage/current/power readings update ~4x/sec, which invalidates
// ChannelCardView's entire body - including this field, even though a
// reading tick never touches setVoltage/setCurrent. That's harmless when
// the field is idle, but a field that's mid-interaction (focused, with an
// active text selection) sitting through thousands of redundant re-diffs
// over a long idle-but-selected period is suspected of being what left
// AppKit's own text-layout bookkeeping (TextKit 2's
// NSTextContentStorage/NSTextLayoutManager) in a state that then hung for
// tens of seconds on the next real click - see the 2026-07 investigation.
// Taking only plain values (not a live reference to `channel`) and
// wrapping the call site in `.equatable()` lets SwiftUI skip touching the
// underlying NSTextField entirely on ticks where nothing here changed.
private struct SetpointField: View, Equatable {
    @Binding var value: Double
    let decimals: Int
    let range: ClosedRange<Double>
    let width: CGFloat
    let accessibilityLabel: LocalizedStringKey
    let dirty: Bool
    let helpText: LocalizedStringKey
    let focusIndex: Int
    var focusedField: FocusState<Int?>.Binding
    let onDirty: () -> Void
    let onCommit: () -> Void
    let onTabAdvance: (Bool) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value == rhs.value
            && lhs.decimals == rhs.decimals
            && lhs.range == rhs.range
            && lhs.width == rhs.width
            && lhs.accessibilityLabel == rhs.accessibilityLabel
            && lhs.dirty == rhs.dirty
            && lhs.helpText == rhs.helpText
            && lhs.focusIndex == rhs.focusIndex
    }

    var body: some View {
        DecimalField(
            value: $value,
            decimals: decimals,
            range: range,
            width: width,
            accessibilityLabel: accessibilityLabel,
            onDirty: onDirty,
            onCommit: onCommit,
            onTabAdvance: onTabAdvance
        )
        .focused(focusedField, equals: focusIndex)
        .help(helpText)
        .overlay(dirtyOverlay(dirty))
    }

    private func dirtyOverlay(_ dirty: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.orange, lineWidth: dirty ? 2 : 0)
    }
}

// A standalone Equatable view, not a computed property of ChannelCardView:
// `channel` is an @ObservedObject whose voltage/current/power readings
// update ~4x/sec from the poll loop, and ANY change to it re-evaluates
// ChannelCardView's entire body - including this popover's content, even
// though nothing here actually depends on those readings. That was
// tearing down and recreating the popover's real NSView-backed controls
// while it sat open, and if that happened to land right as the mouse
// entered one of them, its tracking area never got the "entered" event
// needed to arm a tooltip - which then seemed to jam something in
// AppKit's tooltip bookkeeping app-wide until an activate/deactivate
// cycle reset it. Taking only the specific protection-related values as
// plain parameters (not a reference to the live channel) and wrapping
// the call site in `.equatable()` lets SwiftUI skip re-rendering this
// entirely unless one of those specific values actually changed.
private struct ProtectionPopoverContent: View, Equatable {
    let channelLabel: String
    let vmax: Double
    let imax: Double
    let voltageDecimals: Int
    let currentDecimals: Int
    @Binding var ovpEnabled: Bool
    @Binding var ovpValue: Double
    @Binding var ovpValueDirty: Bool
    let ovpTripped: Bool
    let ovpTrippedAt: Date?
    @Binding var ocpEnabled: Bool
    @Binding var ocpValue: Double
    @Binding var ocpValueDirty: Bool
    let ocpTripped: Bool
    let ocpTrippedAt: Date?
    @Binding var protectionDirty: Bool
    let onCommit: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.channelLabel == rhs.channelLabel
            && lhs.vmax == rhs.vmax
            && lhs.imax == rhs.imax
            && lhs.voltageDecimals == rhs.voltageDecimals
            && lhs.currentDecimals == rhs.currentDecimals
            && lhs.ovpEnabled == rhs.ovpEnabled
            && lhs.ovpValue == rhs.ovpValue
            && lhs.ovpValueDirty == rhs.ovpValueDirty
            && lhs.ovpTripped == rhs.ovpTripped
            && lhs.ovpTrippedAt == rhs.ovpTrippedAt
            && lhs.ocpEnabled == rhs.ocpEnabled
            && lhs.ocpValue == rhs.ocpValue
            && lhs.ocpValueDirty == rhs.ocpValueDirty
            && lhs.ocpTripped == rhs.ocpTripped
            && lhs.ocpTrippedAt == rhs.ocpTrippedAt
            && lhs.protectionDirty == rhs.protectionDirty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Protection - \(channelLabel)").font(.headline)
            HStack(spacing: 10) {
                Toggle(isOn: Binding(
                    get: { ovpEnabled },
                    set: { ovpEnabled = $0; protectionDirty = true }
                )) {
                    HStack(spacing: 4) {
                        Text("OVP").foregroundStyle(ovpTripped ? .red : .primary)
                        if ovpTripped {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        }
                    }
                }
                .help(ovpTooltip)
                DecimalField(
                    value: $ovpValue,
                    decimals: voltageDecimals,
                    range: 0...vmax,
                    width: 60,
                    accessibilityLabel: "\(channelLabel) over-voltage protection threshold",
                    onDirty: { ovpValueDirty = true },
                    onCommit: onCommit
                )
                .help("Output turns off if voltage exceeds this threshold (0–\(String(format: "%g", vmax))V)")
                .overlay(dirtyOverlay(ovpValueDirty))
                Text("V").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Toggle(isOn: Binding(
                    get: { ocpEnabled },
                    set: { ocpEnabled = $0; protectionDirty = true }
                )) {
                    HStack(spacing: 4) {
                        Text("OCP").foregroundStyle(ocpTripped ? .red : .primary)
                        if ocpTripped {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        }
                    }
                }
                .help(ocpTooltip)
                DecimalField(
                    value: $ocpValue,
                    decimals: currentDecimals,
                    range: 0...imax,
                    width: 60,
                    accessibilityLabel: "\(channelLabel) over-current protection threshold",
                    onDirty: { ocpValueDirty = true },
                    onCommit: onCommit
                )
                .help("Output turns off if current exceeds this threshold (0–\(String(format: "%g", imax))A)")
                .overlay(dirtyOverlay(ocpValueDirty))
                Text("A").font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                let dirty = ovpValueDirty || ocpValueDirty || protectionDirty
                Button {
                    onCommit()
                } label: {
                    Image(systemName: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .frame(width: 60)
                .buttonStyle(.borderedProminent)
                .tint(dirty ? Color.accentColor : Color.secondary)
                .disabled(!dirty)
                .help("Apply protection changes")
            }
        }
        // AppKit auto-focuses the OVP field the instant this popover
        // appears, same as it does for the very first field in a new
        // window - resign it immediately rather than leaving it selected
        // for a field nobody actually clicked into.
        .onAppear {
            DispatchQueue.main.async {
                NSApp.keyWindow?.resignFirstResponderIfEditingText()
            }
        }
    }

    private func dirtyOverlay(_ dirty: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.orange, lineWidth: dirty ? 2 : 0)
    }

    private var ovpTooltip: LocalizedStringKey {
        if ovpTripped, let at = ovpTrippedAt { return "OVP tripped at \(formattedTripTime(at))" }
        return "Enable over-voltage protection"
    }

    private var ocpTooltip: LocalizedStringKey {
        if ocpTripped, let at = ocpTrippedAt { return "OCP tripped at \(formattedTripTime(at))" }
        return "Enable over-current protection"
    }
}

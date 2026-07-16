import SwiftUI

/// A numeric field that doesn't fight the user while typing.
///
/// TextField(value:formatter:) round-trips through the formatter on every
/// keystroke, so typing "8,23" gets reformatted to "8,00" the instant the
/// partial input parses as "8" - there's no way to finish typing decimals.
/// This keeps its own local text state and only reformats on blur/submit,
/// so partial input is never clobbered mid-edit. Accepts either "," or "."
/// as the decimal separator regardless of locale.
struct DecimalField: View {
    @Binding var value: Double
    var decimals: Int
    var range: ClosedRange<Double> = 0...Double.greatestFiniteMagnitude
    var width: CGFloat = 56
    // LocalizedStringKey, not String: call sites build this via string
    // interpolation (e.g. "\(channel.config.label) voltage setpoint") - as
    // a plain String parameter that interpolation would just be verbatim
    // Swift string concatenation, bypassing Localizable.strings lookup
    // entirely. Typed as LocalizedStringKey, the same interpolation is
    // instead built into a lookup pattern ("%@ voltage setpoint") the way
    // Text/.help() already do.
    var accessibilityLabel: LocalizedStringKey
    var onDirty: () -> Void = {}
    var onCommit: () -> Void = {}
    // When set, Tab/Shift+Tab are intercepted instead of falling through to
    // AppKit's automatic key-view loop, which orders purely by screen
    // geometry (row-by-row, then left-to-right) - fine for a single field
    // per row, but wrong once two fields share a column stacked vertically
    // per card: it tabs "CH1 volts, CH2 volts, CH3 volts, CH1 amps, ..."
    // instead of through one card at a time. The bool argument is true for
    // Shift+Tab (reverse).
    var onTabAdvance: ((Bool) -> Void)? = nil

    @State private var text: String = ""
    // Dirty is decided by comparing against this, not by focus state.
    // Focus-gating is tempting but fragile: AppKit sometimes auto-focuses
    // the first text field in a freshly-opened window, and if that happens
    // to land on this field, its own onAppear sync would then look
    // indistinguishable from a real keystroke and wrongly mark it dirty.
    @State private var lastSyncedValue: Double = 0
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .frame(width: width)
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(accessibilityLabel)
            .focused($focused)
            .onAppear { syncFromValue() }
            .onChange(of: text) { _, newValue in
                if let parsed = Self.parse(newValue) {
                    value = parsed
                    if parsed != lastSyncedValue {
                        onDirty()
                    }
                }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { syncFromValue() }
            }
            .onChange(of: value) { _, newValue in
                if !focused {
                    lastSyncedValue = newValue
                    text = Self.format(newValue, decimals: decimals)
                }
            }
            .onSubmit {
                syncFromValue()
                onCommit()
            }
            .onKeyPress(keys: [.tab]) { press in
                guard let onTabAdvance else { return .ignored }
                onTabAdvance(press.modifiers.contains(.shift))
                return .handled
            }
    }

    private func syncFromValue() {
        value = min(max(value, range.lowerBound), range.upperBound)
        lastSyncedValue = value
        text = Self.format(value, decimals: decimals)
    }

    static func format(_ v: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", v)
    }

    static func parse(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: "."))
    }
}

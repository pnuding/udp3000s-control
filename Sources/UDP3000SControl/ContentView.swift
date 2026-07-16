import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var showConnection = false
    @State private var showPlayback = false
    // Captured once, in onAppear below, so the willClose handler can tell
    // this actual window apart from the Graph window, popovers, and panels
    // by identity - a title-string check ("!= Graph") would be too loose
    // here, since quitting the whole app is a much bigger consequence than
    // the other places in this file that use that same looser heuristic.
    @State private var mainWindow: NSWindow?
    // Shared across every card so Tab can be driven explicitly in
    // CH1-volts -> CH1-amps -> CH2-volts -> ... order (index = channel
    // position * 2, +1 for the amps field) instead of AppKit's automatic
    // geometric key-view loop, which orders by screen row/column position.
    @FocusState private var focusedField: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.mode.isEmpty && model.mode != "NORMAL" {
                Label(
                    model.mode == "SER"
                        ? "Channel 1+2 are combined in SERIES mode."
                        : "Channel 1+2 are combined in PARALLEL mode.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }

            // Plain HStack, not a grid - we always want exactly one column
            // per channel in a single row (2 or 3, never wrapping), so
            // there's no need for LazyVGrid's flexible-column machinery at
            // all. Each card sizes itself to its own natural content
            // instead of being forced to a guessed constant width, which
            // is what kept being either too wide (dead space inside the
            // card) or too narrow (content clipped past the card border).
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(model.channels.enumerated()), id: \.element.id) { index, ch in
                    ChannelCardView(channel: ch, channelIndex: index, focusedField: $focusedField)
                }
            }
        }
        .padding(20)
        // Starts as the generic series name ("UDP3000S Control") and gets
        // replaced with the specific detected model (e.g. "UDP3305S-E
        // Control") once *IDN? comes back after connecting.
        .navigationTitle(model.windowTitle)
        .contentShape(Rectangle())
        .onTapGesture {
            // Clicking a text field is easy; clicking *away* from one to
            // release focus isn't, since clicking empty background
            // doesn't naturally resign first responder the way clicking
            // another control does. This makes the whole background
            // clickable for exactly that. Buttons/toggles/fields still get
            // first claim on taps landing directly on them.
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .onAppear {
            // AppKit auto-focuses the first text field in the window
            // unless told otherwise, which reads as "a setpoint field is
            // always selected" even though nobody clicked it.
            DispatchQueue.main.async {
                mainWindow = NSApp.keyWindow
                NSApp.keyWindow?.resignFirstResponderIfEditingText()
                lockWindowToIdealSize(NSApp.keyWindow)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            // This app has no menu bar / Dock-icon-only presence worth
            // keeping alive with no windows - closing the main window (by
            // the red button, Cmd-W, or any other route) should quit
            // outright, same as if you'd chosen Quit, rather than leaving
            // the process running invisibly (or just the Graph window
            // floating with no way back to the toolbar that opened it).
            guard let window = note.object as? NSWindow, window === mainWindow else { return }
            NSApp.terminate(nil)
        }
        .task {
            if model.host.isEmpty {
                showConnection = true
            } else {
                await model.connect()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            // Same auto-focus behavior can re-trigger any time this window
            // becomes key again (e.g. after clicking back from the Graph
            // window), not just on first launch - so this needs to run
            // every time, not only once in onAppear. Scoped to just this
            // window so it doesn't interfere with the Graph window. Can't
            // match on an exact title string anymore since the window's
            // title now changes once the device model is identified -
            // excluding "Graph" (the one other window, always fixed) is
            // simpler than tracking the current expected title.
            guard let window = note.object as? NSWindow, window.title != "Graph" else { return }
            // This notification also fires every time a popover closes
            // (closing one hands key status back to this window) - calling
            // makeFirstResponder(nil) unconditionally in that moment was
            // the likely cause of tooltips silently going dead afterwards
            // (macOS tooltips are tracking-area-based and tied to the
            // responder chain; forcing a responder change while a popover
            // is mid-teardown seems to leave that bookkeeping stale until
            // something else, like opening another popover, rebuilds it).
            // Only actually needed when a text field auto-grabbed focus,
            // so only act when that's really what's focused.
            DispatchQueue.main.async {
                window.resignFirstResponderIfEditingText()
                lockWindowToIdealSize(window)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                statusIndicator
                Button {
                    Task { await model.toggleAllOutputs() }
                } label: {
                    Image(systemName: model.anyOutputOn ? "power.circle.fill" : "power.circle")
                        .foregroundStyle(model.anyOutputOn ? .green : .secondary)
                }
                .disabled(!model.connected)
                .help(model.anyOutputOn ? "Turn all outputs off" : "Turn all outputs on")
                .accessibilityLabel(model.anyOutputOn ? "Turn all outputs off" : "Turn all outputs on")

                Button {
                    openWindow(id: "graph")
                } label: {
                    Image(systemName: "chart.xyaxis.line")
                }
                .help("Open graph window")
                .accessibilityLabel("Open graph window")

                Button {
                    showPlayback.toggle()
                } label: {
                    Image(systemName: "play.circle")
                }
                .popover(isPresented: $showPlayback) {
                    PlaybackView()
                        .frame(width: 320)
                        .padding()
                }
                .help("Playback")
                .accessibilityLabel("Playback")
            }
        }
    }

    // .windowResizability(.contentSize) on the Scene sizes the window to
    // match its content on a fresh, persisted-frame-free launch - but
    // that's a separate, async pass from ours, and stripping .resizable
    // immediately (the only way found to actually stop drag-resizing; see
    // below) can lock in whatever transient size the window had *before*
    // that pass finished. On a machine that already had a saved window
    // frame from an earlier run - back when the window was still
    // resizable and had already settled at the right size - locking that
    // in was harmless. On a brand new install with no saved frame at all,
    // it locked in the wrong one instead, which is what took the card
    // layout out of alignment on a first launch elsewhere. Forcing the
    // window to its content's own fitting size before locking removes the
    // dependency on which pass happens to run first.
    // window.contentView?.fittingSize turned out to be unreliable here -
    // it read back as zero on every attempt during testing (an
    // NSHostingView quirk, seemingly), so trying to recompute the ideal
    // size ourselves via that API was never actually engaging at all; the
    // wrong width was coming straight from SwiftUI's own
    // .windowResizability(.contentSize) pass, uncorrected. Rather than
    // fight that mechanism, this just waits for the *window's own frame*
    // (as SwiftUI itself keeps adjusting it during that pass) to stop
    // changing between successive checks, then locks it - trusting
    // SwiftUI's sizing entirely instead of trying to recompute it.
    private func lockWindowToIdealSize(_ window: NSWindow?, previousFrame: NSRect? = nil, attempt: Int = 0) {
        guard let window else { return }
        let current = window.frame
        let stable = previousFrame.map { abs($0.width - current.width) < 0.5 && abs($0.height - current.height) < 0.5 } ?? false
        if !stable, attempt < 40 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
                lockWindowToIdealSize(window, previousFrame: current, attempt: attempt + 1)
            }
            return
        }
        // .windowResizability(.contentSize) alone only sets a *minimum*
        // equal to the content's ideal size - it doesn't stop the user
        // from dragging the window wider, which just adds dead space
        // since nothing in this layout grows to fill it. The card layout
        // is only correct at its natural size, so remove the resizable
        // trait outright instead of just bounding it.
        window.styleMask.remove(.resizable)
    }

    // An inline text label here ("Connected"/"Not connected"/"Disconnected")
    // would need a fixed-width cap to keep the toolbar from growing with
    // translation length across 14 languages - instead this is icon+color
    // only (three visually distinct states, not just a same-shape dot in
    // two colors like before), with the full description moved to the
    // tooltip/accessibility label, which has no width constraint at all.
    // It doubles as the way into connection settings - the separate gear
    // button it replaced was redundant with it, and the auto-shown
    // popover on a first launch with no saved host anchors here too.
    private var statusIndicator: some View {
        let (icon, color, label): (String, Color, LocalizedStringKey) = {
            if model.connected { return ("wifi", .green, "Connected") }
            if model.host.isEmpty { return ("wifi.slash", .secondary, "Not connected") }
            return ("wifi.exclamationmark", .orange, "Disconnected")
        }()
        return Button {
            showConnection.toggle()
        } label: {
            Image(systemName: icon)
                .foregroundStyle(color)
        }
        .popover(isPresented: $showConnection) {
            ConnectionSettingsView()
                .frame(width: 280)
                .padding()
        }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityHint(Text("Connection settings"))
    }
}

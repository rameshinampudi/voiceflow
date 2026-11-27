import AppKit
import SwiftUI

/// What the resting bar says about Airflow.
enum IdleStatus: Equatable {
    case ready
    case needsPermission(String)
    case preparing(String)
}

enum PillState: Equatable {
    case hidden
    /// Always-on resting indicator: a small breathing dot.
    case idle(IdleStatus)
    case listening(command: Bool, handsFree: Bool)
    case processing(command: Bool)
    case message(String, isError: Bool)
}

@MainActor
final class PillModel: ObservableObject {
    @Published var state: PillState = .hidden
    /// Smoothed microphone level, 0…1 (fast attack, slow release, like a VU meter).
    @Published var level: CGFloat = 0

    func push(level raw: Float) {
        let target = CGFloat(raw)
        level = target > level ? level + (target - level) * 0.65 : level * 0.82 + target * 0.18
    }

    func resetLevel() { level = 0 }
}

/// The floating bar at the bottom of the screen (Wispr's "Flow bar").
/// At rest it's a small breathing dot so you can see Airflow is running; while you talk it
/// grows into a live voice meter.
@MainActor
final class FlowPillController {
    let model = PillModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var restingState: PillState = .hidden

    /// Shows activity (listening / processing / message).
    func show(_ state: PillState) {
        hideWork?.cancel()
        if case .listening = state {
            if case .listening = model.state {} else { model.resetLevel() }
        }
        present(state)
    }

    /// Back to the resting dot (or nothing, if the idle bar is turned off).
    func rest() {
        hideWork?.cancel()
        present(restingState)
    }

    func flash(_ text: String, isError: Bool, seconds: Double = 2.6) {
        show(.message(text, isError: isError))
        let work = DispatchWorkItem { [weak self] in self?.rest() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Updates the resting indicator; applied immediately if nothing else is showing.
    func setIdle(_ status: IdleStatus, visible: Bool) {
        let resting: PillState = visible ? .idle(status) : .hidden
        guard resting != restingState else { return }
        restingState = resting
        switch model.state {
        case .hidden, .idle: present(resting)
        default: break
        }
    }

    private func present(_ state: PillState) {
        model.state = state
        if state == .hidden {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 64),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: PillView(model: model))
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 8))
    }
}

// MARK: - Views

private let airflowCyan = Color(red: 0.45, green: 0.80, blue: 1.0)
private let airflowViolet = Color(red: 0.62, green: 0.55, blue: 1.0)

struct PillView: View {
    @ObservedObject var model: PillModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            bar
        }
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: model.state)
    }

    @ViewBuilder private var bar: some View {
        switch model.state {
        case .hidden:
            EmptyView()
        case let .idle(status):
            IdleBar(status: status)
                .transition(.scale(scale: 0.7).combined(with: .opacity))
        default:
            HStack(spacing: 10) { activeContent }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color(white: 0.07).opacity(0.93)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                .foregroundStyle(.white)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }

    @ViewBuilder private var activeContent: some View {
        switch model.state {
        case let .listening(command, handsFree):
            let tint = command ? airflowViolet : airflowCyan
            ZStack {
                Circle()
                    .fill(tint.opacity(0.28))
                    .frame(width: 22, height: 22)
                    .scaleEffect(1 + model.level * 0.7)
                Image(systemName: command ? "wand.and.stars" : "mic.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 26, height: 26)
            VoiceBars(level: model.level, tint: tint)
            if handsFree {
                Text("⌥ to finish · esc to cancel")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        case let .processing(command):
            ProcessingDots(tint: command ? airflowViolet : airflowCyan)
        case let .message(text, isError):
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.orange : Color.green)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .frame(maxWidth: 380)
        case .hidden, .idle:
            EmptyView()
        }
    }
}

/// The resting indicator: a softly breathing dot, plus a note when something needs attention.
struct IdleBar: View {
    let status: IdleStatus

    private var color: Color {
        switch status {
        case .ready: return airflowCyan
        case .needsPermission: return .orange
        case .preparing: return airflowViolet
        }
    }

    private var label: String? {
        switch status {
        case .ready: return nil
        case let .needsPermission(text), let .preparing(text): return text
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            TimelineView(.animation(minimumInterval: 1.0 / 15)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let breath = CGFloat(0.5 + 0.5 * sin(t * 2.0))
                ZStack {
                    Circle()
                        .fill(color.opacity(0.18 + 0.22 * breath))
                        .frame(width: 11 + 7 * breath, height: 11 + 7 * breath)
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                }
                .frame(width: 20, height: 20)
            }
            if let label {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color(white: 0.07).opacity(0.72)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }
}

/// Bars that bounce with your voice. Each bar wobbles at its own rate; the loudness scales them,
/// so silence leaves a gentle shimmer and speech makes them jump.
struct VoiceBars: View {
    let level: CGFloat
    let tint: Color
    private static let envelope: [CGFloat] = [0.32, 0.45, 0.62, 0.78, 0.92, 1.0, 0.92, 0.78, 0.62, 0.45, 0.32]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 40)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<Self.envelope.count, id: \.self) { i in
                    let speed = 7.0 + Double(i % 4) * 2.1
                    let wobble = CGFloat(0.55 + 0.45 * sin(t * speed + Double(i) * 1.9))
                    let shimmer = CGFloat(1.2 + 1.2 * sin(t * 3 + Double(i)))
                    let height = 3 + shimmer + min(1, level * 1.25) * Self.envelope[i] * wobble * 20
                    Capsule()
                        .fill(tint)
                        .frame(width: 3, height: height)
                }
            }
            .frame(height: 26)
        }
    }
}

struct ProcessingDots: View {
    var tint: Color

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(tint)
                        .frame(width: 6, height: 6)
                        .opacity(0.3 + 0.7 * max(0, sin(t * 6 - Double(i) * 0.8)))
                }
            }
        }
        .frame(height: 26)
    }
}

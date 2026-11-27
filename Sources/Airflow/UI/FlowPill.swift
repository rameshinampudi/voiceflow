import AppKit
import SwiftUI

enum PillState: Equatable {
    case hidden
    case listening(command: Bool, handsFree: Bool)
    case processing(command: Bool)
    case message(String, isError: Bool)
}

@MainActor
final class PillModel: ObservableObject {
    static let barCount = 16
    @Published var state: PillState = .hidden
    @Published var levels: [CGFloat] = Array(repeating: 0, count: PillModel.barCount)

    func push(level: Float) {
        var next = levels
        next.removeFirst()
        next.append(CGFloat(level))
        levels = next
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

/// The small floating capsule at the bottom of the screen (Wispr's "Flow bar").
@MainActor
final class FlowPillController {
    let model = PillModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(_ state: PillState) {
        hideWork?.cancel()
        if case .listening = state {
            if case .listening = model.state {} else { model.resetLevels() }
        }
        model.state = state
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        hideWork?.cancel()
        model.state = .hidden
        panel?.orderOut(nil)
    }

    func flash(_ text: String, isError: Bool, seconds: Double = 2.6) {
        show(.message(text, isError: isError))
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
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
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 12))
    }
}

struct PillView: View {
    @ObservedObject var model: PillModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if model.state != .hidden {
                HStack(spacing: 10) { content }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color(white: 0.08).opacity(0.92)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: model.state)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case let .listening(command, handsFree):
            Image(systemName: command ? "wand.and.stars" : "mic.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(command ? Color.purple : Color.white)
            WaveformView(levels: model.levels, tint: command ? .purple : .white)
            if handsFree {
                Text("⌥ to finish · esc to cancel")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        case let .processing(command):
            ProcessingDots(tint: command ? .purple : .white)
        case let .message(text, isError):
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.orange : Color.green)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .frame(maxWidth: 380)
        case .hidden:
            EmptyView()
        }
    }
}

struct WaveformView: View {
    let levels: [CGFloat]
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(tint.opacity(0.9))
                    .frame(width: 3, height: 3 + min(1, levels[index]) * 19)
            }
        }
        .frame(height: 22)
        .animation(.easeOut(duration: 0.08), value: levels)
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
        .frame(height: 22)
    }
}

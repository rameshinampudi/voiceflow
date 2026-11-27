import AirflowCore
import AppKit
import CoreGraphics

/// A session-wide CGEventTap that turns raw key/mouse events into `HotkeyEvent`s.
/// Needs Accessibility permission (an active tap can swallow Esc while dictating).
@MainActor
final class HotkeyMonitor {
    var side: HotkeySide = .either
    /// Returns true to swallow the event.
    var onEvent: ((HotkeyEvent) -> Bool)?
    var onPasteLast: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    // Device-dependent modifier bits (IOKit NX_DEVICE*KEYMASK).
    private static let leftOptionMask: UInt64 = 0x0000_0020
    private static let rightOptionMask: UInt64 = 0x0000_0040
    private static let leftControlMask: UInt64 = 0x0000_0001
    private static let rightControlMask: UInt64 = 0x0000_2000

    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags.rawValue
            let userData = event.getIntegerValueField(.eventSourceUserData)
            let typeRaw = type.rawValue
            let swallow = MainActor.assumeIsolated {
                Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    .process(typeRaw: typeRaw, keyCode: keyCode, flags: flags, userData: userData)
            }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func process(typeRaw: UInt32, keyCode: Int64, flags rawFlags: UInt64, userData: Int64) -> Bool {
        guard let type = CGEventType(rawValue: typeRaw) else { return false }
        let flags = CGEventFlags(rawValue: rawFlags)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .flagsChanged:
            return handleFlagsChanged(keyCode: Int(keyCode), flags: flags)
        case .keyDown:
            if userData == TextInserter.syntheticEventMarker { return false }
            return handleKeyDown(keyCode: Int(keyCode), flags: flags)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            _ = send(.otherKeyDown)  // ⌥-click / ⌥-drag is not dictation
            return false
        default:
            return false
        }
    }

    private func handleFlagsChanged(keyCode: Int, flags: CGEventFlags) -> Bool {
        let raw = flags.rawValue
        switch keyCode {
        case 58, 61:  // left / right Option
            let isLeft = keyCode == 58
            let isDown = raw & (isLeft ? Self.leftOptionMask : Self.rightOptionMask) != 0
            let isTrigger = side == .either || (side == .left && isLeft) || (side == .right && !isLeft)
            guard isTrigger else { return isDown ? send(.otherModifierDown) : false }
            if isDown {
                let others = !flags.intersection([.maskCommand, .maskShift, .maskSecondaryFn]).isEmpty
                return send(.triggerDown(
                    time: ProcessInfo.processInfo.systemUptime,
                    controlHeld: flags.contains(.maskControl), otherModifiersHeld: others))
            }
            return send(.triggerUp(time: ProcessInfo.processInfo.systemUptime))
        case 59, 62:  // left / right Control
            let down = raw & (keyCode == 59 ? Self.leftControlMask : Self.rightControlMask) != 0
            return down ? send(.controlDown) : false
        case 54, 55:  // Command
            return flags.contains(.maskCommand) ? send(.otherModifierDown) : false
        case 56, 60:  // Shift
            return flags.contains(.maskShift) ? send(.otherModifierDown) : false
        case 63:  // fn
            return flags.contains(.maskSecondaryFn) ? send(.otherModifierDown) : false
        default:
            return false
        }
    }

    private func handleKeyDown(keyCode: Int, flags: CGEventFlags) -> Bool {
        if keyCode == 53 { return send(.escapeDown) }
        // ⌃⌘V — paste the last transcript.
        if keyCode == 9, flags.contains(.maskCommand), flags.contains(.maskControl),
           !flags.contains(.maskAlternate), !flags.contains(.maskShift) {
            onPasteLast?()
            return true
        }
        return send(.otherKeyDown)
    }

    private func send(_ event: HotkeyEvent) -> Bool {
        onEvent?(event) ?? false
    }
}

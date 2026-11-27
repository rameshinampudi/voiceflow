import VoiceFlowCore

private func down(_ time: Double, control: Bool = false, others: Bool = false) -> HotkeyEvent {
    .triggerDown(time: time, controlHeld: control, otherModifiersHeld: others)
}

func hotkeyChecks(_ t: Checks) {
    t.run("hold then release dictates") {
        var m = HotkeyStateMachine()
        t.equal(m.handle(down(0)).actions, [.startCapture(.dictation), .scheduleTick(after: 0.18)])
        t.equal(m.handle(.tick(time: 0.18)).actions, [.activate(.dictation, handsFree: false)])
        t.equal(m.handle(.triggerUp(time: 2)).actions, [.finish])
        t.equal(m.state, .idle)
    }

    t.run("quick tap is discarded silently") {
        var m = HotkeyStateMachine()
        _ = m.handle(down(0))
        t.equal(m.handle(.triggerUp(time: 0.08)).actions, [.cancel(silent: true)])
        t.equal(m.handle(.tick(time: 0.18)).actions, [])  // late tick from that press
        t.equal(m.state, .idle)
    }

    t.run("option used in a shortcut is ignored") {
        var m = HotkeyStateMachine()
        _ = m.handle(down(0))
        t.equal(m.handle(.otherKeyDown).actions, [.cancel(silent: true)])
        t.equal(m.handle(.triggerUp(time: 0.3)).actions, [])
    }

    t.run("option with command already held never starts") {
        var m = HotkeyStateMachine()
        t.equal(m.handle(down(0, others: true)).actions, [])
        t.equal(m.state, .idle)
    }

    t.run("modifier after activation cancels visibly") {
        var m = HotkeyStateMachine()
        _ = m.handle(down(0))
        _ = m.handle(.tick(time: 0.2))
        t.equal(m.handle(.otherModifierDown).actions, [.cancel(silent: false)])
    }

    t.run("escape while holding cancels and is swallowed") {
        var m = HotkeyStateMachine()
        _ = m.handle(down(0))
        _ = m.handle(.tick(time: 0.2))
        let result = m.handle(.escapeDown)
        t.equal(result.actions, [.cancel(silent: false)])
        t.expect(result.swallow)
    }

    t.run("double tap enters hands-free until the next press") {
        var m = HotkeyStateMachine()
        _ = m.handle(down(0))
        _ = m.handle(.triggerUp(time: 0.1))
        t.equal(m.handle(down(0.3)).actions, [.startCapture(.dictation), .activate(.dictation, handsFree: true)])
        t.equal(m.handle(.triggerUp(time: 0.35)).actions, [])
        t.expect(m.isHandsFree)
        t.equal(m.handle(.otherKeyDown).actions, [])  // typing doesn't stop hands-free
        t.equal(m.handle(down(5)).actions, [])        // finish on release, not press
        t.equal(m.handle(.triggerUp(time: 5.1)).actions, [.finish])
        t.equal(m.state, .idle)
    }

    t.run("slow second tap is not a double tap") {
        var m = HotkeyStateMachine()
        _ = m.handle(down(0))
        _ = m.handle(.triggerUp(time: 0.1))
        t.equal(m.handle(down(1.0)).actions, [.startCapture(.dictation), .scheduleTick(after: 0.18)])
    }

    t.run("escape cancels hands-free") {
        var m = HotkeyStateMachine()
        _ = m.handle(.toggleHandsFree)
        let result = m.handle(.escapeDown)
        t.equal(result.actions, [.cancel(silent: false)])
        t.expect(result.swallow)
    }

    t.run("menu toggle starts and finishes hands-free") {
        var m = HotkeyStateMachine()
        t.equal(m.handle(.toggleHandsFree).actions, [.startCapture(.dictation), .activate(.dictation, handsFree: true)])
        t.equal(m.handle(.toggleHandsFree).actions, [.finish])
    }

    t.run("control switches to command mode") {
        var m = HotkeyStateMachine()
        _ = m.handle(down(0))
        t.equal(m.handle(.controlDown).actions, [.modeChanged(.command)])
        t.equal(m.handle(.tick(time: 0.2)).actions, [.activate(.command, handsFree: false)])
        t.equal(m.handle(.triggerUp(time: 1)).actions, [.finish])
    }

    t.run("control held first starts command mode") {
        var m = HotkeyStateMachine()
        t.equal(m.handle(down(0, control: true)).actions.first, .startCapture(.command))
    }
}

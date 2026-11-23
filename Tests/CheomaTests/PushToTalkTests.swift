import AppKit
import os
import XCTest
@testable import Cheoma

/// 단축키 상태 기계에 실제 이벤트와 같은 키 코드 · 수식키 비트를 넣어 본다 (키를 실제로 보내지 않는다)
final class PushToTalkStateMachineTests: XCTestCase {
    private typealias Bits = PushToTalkStateMachine.Modifiers
    private let hold = PushToTalkStateMachine.holdThreshold
    private let window = PushToTalkStateMachine.doubleTapWindow

    /// 키를 누르고 떼는 순서를 적기 쉽게 한다. 실제 flagsChanged처럼 눌려 있는 다른 수식키 비트를 같이 싣는다
    private struct Keyboard {
        var machine: PushToTalkStateMachine
        /// 단축키 말고 눌려 있는 수식키 비트
        var held: UInt = 0
        var hotKeyDown = false

        init(_ hotKey: DictationHotKey = .rightOption, handsFree: Bool = true) {
            machine = PushToTalkStateMachine(hotKey: hotKey, allowsHandsFree: handsFree)
        }

        /// 실제 이벤트에 늘 붙어 오는 NX_NONCOALSESCEDMASK
        private static let noise: UInt = 0x100

        private var hotKeyBits: UInt {
            let bits = Bits.bits(for: machine.hotKey)
            return bits.family | bits.own
        }

        private var flags: UInt { held | (hotKeyDown ? hotKeyBits : 0) | Self.noise }

        mutating func press(at time: TimeInterval) -> [PushToTalkEvent] {
            hotKeyDown = true
            return machine.flagsChanged(keyCode: machine.hotKey.keyCode, flags: flags, at: time)
        }

        mutating func release(at time: TimeInterval) -> [PushToTalkEvent] {
            hotKeyDown = false
            return machine.flagsChanged(keyCode: machine.hotKey.keyCode, flags: flags, at: time)
        }

        /// 짧게 톡 친다 (0.05초)
        mutating func tap(at time: TimeInterval) -> [PushToTalkEvent] {
            press(at: time) + release(at: time + 0.05)
        }

        mutating func key(_ keyCode: UInt16, at time: TimeInterval) -> [PushToTalkEvent] {
            machine.keyDown(keyCode: keyCode, at: time)
        }

        /// 다른 수식키를 누르거나 뗀다 (bits는 그 키의 묶음 비트 + 장치 비트)
        mutating func modifier(_ keyCode: UInt16, _ bits: UInt, down: Bool, at time: TimeInterval) -> [PushToTalkEvent] {
            if down { held |= bits } else { held &= ~bits }
            return machine.flagsChanged(keyCode: keyCode, flags: flags, at: time)
        }

        mutating func tick(at time: TimeInterval) -> [PushToTalkEvent] {
            machine.tick(at: time)
        }

        /// 두 번 빠르게 눌러 손을 떼도 듣는 상태로 만든다. 마지막으로 키를 뗀 시각을 돌려준다
        mutating func startHandsFree(at time: TimeInterval) -> TimeInterval {
            _ = tap(at: time)
            _ = press(at: time + 0.2)
            _ = release(at: time + 0.25)
            return time + 0.25
        }
    }

    private let leftShift: (code: UInt16, bits: UInt) = (56, Bits.shift | Bits.leftShift)
    private let leftOption: (code: UInt16, bits: UInt) = (58, Bits.option | Bits.leftOption)
    private let leftCommand: (code: UInt16, bits: UInt) = (55, Bits.command | Bits.leftCommand)
    private let capsLock: (code: UInt16, bits: UInt) = (57, 1 << 16)
    private let leftArrow: UInt16 = 123
    private let letterA: UInt16 = 0
    private let escape = PushToTalkStateMachine.escapeKeyCode

    // MARK: 누르고 있기

    func testHoldBeginsAfterThresholdAndEndsOnRelease() {
        var keys = Keyboard()
        XCTAssertEqual(keys.press(at: 10), [.armed])
        XCTAssertEqual(keys.machine.nextDeadline, 10 + hold)
        XCTAssertEqual(keys.tick(at: 10.1), [])
        XCTAssertEqual(keys.tick(at: 10 + hold), [.began(handsFree: false)])
        XCTAssertEqual(keys.tick(at: 10.5), [])
        XCTAssertNil(keys.machine.nextDeadline)
        XCTAssertEqual(keys.release(at: 12), [.ended])
        XCTAssertEqual(keys.machine.phase, .idle)
        XCTAssertFalse(keys.machine.isActive)
    }

    /// 타이머가 늦어도 뗀 시각이 기준 시간을 넘었으면 누르고 있던 것이다
    func testLateReleaseWithoutTickStillCountsAsHold() {
        var keys = Keyboard()
        XCTAssertEqual(keys.press(at: 10), [.armed])
        XCTAssertEqual(keys.release(at: 10.6), [.began(handsFree: false), .ended])
    }

    func testThresholdEdge() {
        var exact = Keyboard()
        _ = exact.press(at: 10)
        XCTAssertEqual(exact.release(at: 10 + hold), [.began(handsFree: false), .ended])

        var early = Keyboard()
        _ = early.press(at: 10)
        XCTAssertEqual(early.release(at: 10 + hold - 0.001), [.cancelled])
    }

    // MARK: 톡 치기 · 두 번 치기

    func testTapCancels() {
        var keys = Keyboard()
        XCTAssertEqual(keys.press(at: 10), [.armed])
        XCTAssertEqual(keys.release(at: 10.08), [.cancelled])
        XCTAssertEqual(keys.machine.phase, .tapped(releasedAt: 10.08))
        XCTAssertEqual(keys.machine.nextDeadline, 10.08 + window)
        XCTAssertEqual(keys.tick(at: 10.08 + window + 0.01), [])
        XCTAssertEqual(keys.machine.phase, .idle)
    }

    func testDoubleTapStartsHandsFreeAndNextPressEndsOnKeyUp() {
        var keys = Keyboard()
        XCTAssertEqual(keys.tap(at: 10), [.armed, .cancelled])
        XCTAssertEqual(keys.press(at: 10.2), [.armed, .began(handsFree: true)])
        // 손을 떼도 계속 듣는다
        XCTAssertEqual(keys.release(at: 10.25), [])
        XCTAssertEqual(keys.machine.phase, .handsFree(.listening))
        XCTAssertTrue(keys.machine.isActive)
        XCTAssertNil(keys.machine.nextDeadline)
        XCTAssertEqual(keys.tick(at: 30), [])
        // 다시 누를 때가 아니라 뗄 때 끝낸다 (수식키를 뗀 뒤에 붙여 넣도록)
        XCTAssertEqual(keys.press(at: 31), [])
        XCTAssertEqual(keys.tick(at: 32), [])
        XCTAssertEqual(keys.release(at: 32), [.ended])
        XCTAssertEqual(keys.machine.phase, .idle)
    }

    func testSecondTapAtWindowEdge() {
        var inside = Keyboard()
        _ = inside.press(at: 10)
        _ = inside.release(at: 10.05)
        XCTAssertEqual(inside.press(at: 10.05 + window), [.armed, .began(handsFree: true)])

        var outside = Keyboard()
        _ = outside.press(at: 10)
        _ = outside.release(at: 10.05)
        XCTAssertEqual(outside.press(at: 10.05 + window + 0.001), [.armed])
        XCTAssertEqual(outside.tick(at: 10.05 + window + 0.001 + hold), [.began(handsFree: false)])
    }

    func testHandsFreeDisabledTreatsSecondTapAsNewPress() {
        var keys = Keyboard(handsFree: false)
        XCTAssertEqual(keys.tap(at: 10), [.armed, .cancelled])
        XCTAssertEqual(keys.machine.phase, .idle)
        XCTAssertNil(keys.machine.nextDeadline)
        XCTAssertEqual(keys.press(at: 10.2), [.armed])
        XCTAssertEqual(keys.release(at: 10.25), [.cancelled])
        XCTAssertEqual(keys.press(at: 11), [.armed])
        XCTAssertEqual(keys.release(at: 12), [.began(handsFree: false), .ended])
    }

    func testOtherKeyBetweenTapsBreaksDoubleTap() {
        var keys = Keyboard()
        _ = keys.tap(at: 10)
        XCTAssertEqual(keys.key(letterA, at: 10.1), [])
        XCTAssertEqual(keys.press(at: 10.2), [.armed])
    }

    func testOtherModifierBetweenTapsBreaksDoubleTap() {
        var keys = Keyboard()
        _ = keys.tap(at: 10)
        XCTAssertEqual(keys.modifier(leftShift.code, leftShift.bits, down: true, at: 10.1), [])
        XCTAssertEqual(keys.modifier(leftShift.code, leftShift.bits, down: false, at: 10.15), [])
        XCTAssertEqual(keys.press(at: 10.2), [.armed])
    }

    // MARK: 다른 키와 같이 누름

    func testOtherKeyWhileArmedCancels() {
        var keys = Keyboard()
        XCTAssertEqual(keys.press(at: 10), [.armed])
        XCTAssertEqual(keys.key(leftArrow, at: 10.05), [.cancelled])
        // 같이 누른 것이었으니 떼도, 기다려도 아무 일 없다
        XCTAssertEqual(keys.tick(at: 11), [])
        XCTAssertEqual(keys.release(at: 11), [])
        // ⌥← 뒤에 바로 다시 눌러도 두 번 누르기가 아니다
        XCTAssertEqual(keys.press(at: 11.1), [.armed])
    }

    func testOtherKeyWhileHoldingCancels() {
        var keys = Keyboard()
        _ = keys.press(at: 10)
        XCTAssertEqual(keys.tick(at: 10.2), [.began(handsFree: false)])
        XCTAssertEqual(keys.key(letterA, at: 11), [.cancelled])
        XCTAssertEqual(keys.release(at: 12), [])
        XCTAssertEqual(keys.machine.phase, .idle)
    }

    func testOtherModifierWhileArmedOrHoldingCancels() {
        var armed = Keyboard()
        _ = armed.press(at: 10)
        XCTAssertEqual(armed.modifier(leftShift.code, leftShift.bits, down: true, at: 10.05), [.cancelled])
        XCTAssertEqual(armed.modifier(leftShift.code, leftShift.bits, down: false, at: 10.3), [])
        XCTAssertEqual(armed.release(at: 10.4), [])

        var holding = Keyboard()
        _ = holding.press(at: 10)
        _ = holding.tick(at: 10.2)
        XCTAssertEqual(holding.modifier(leftCommand.code, leftCommand.bits, down: true, at: 10.5), [.cancelled])
        XCTAssertEqual(holding.release(at: 10.6), [])
    }

    /// 오른쪽 ⌥을 누른 채 왼쪽 ⌥을 누르면 묶음 비트는 그대로지만 장치 비트로 알아챈다
    func testOppositeSideOfSameModifierCancels() {
        var keys = Keyboard()
        _ = keys.press(at: 10)
        XCTAssertEqual(keys.modifier(leftOption.code, leftOption.bits, down: true, at: 10.05), [.cancelled])
    }

    func testCapsLockDoesNotCancel() {
        var keys = Keyboard()
        _ = keys.press(at: 10)
        XCTAssertEqual(keys.modifier(capsLock.code, capsLock.bits, down: true, at: 10.05), [])
        XCTAssertEqual(keys.release(at: 11), [.began(handsFree: false), .ended])
    }

    func testOtherKeyDuringSecondTapCancels() {
        var keys = Keyboard()
        _ = keys.tap(at: 10)
        XCTAssertEqual(keys.press(at: 10.2), [.armed, .began(handsFree: true)])
        XCTAssertEqual(keys.key(leftArrow, at: 10.3), [.cancelled])
        XCTAssertEqual(keys.release(at: 10.4), [])
        XCTAssertEqual(keys.machine.phase, .idle)
    }

    func testHandsFreeListeningIgnoresOtherKeys() {
        var keys = Keyboard()
        let start = keys.startHandsFree(at: 10)
        XCTAssertEqual(keys.key(letterA, at: start + 1), [])
        XCTAssertEqual(keys.modifier(leftShift.code, leftShift.bits, down: true, at: start + 2), [])
        XCTAssertEqual(keys.modifier(leftShift.code, leftShift.bits, down: false, at: start + 2.1), [])
        XCTAssertEqual(keys.machine.phase, .handsFree(.listening))
    }

    /// 손을 떼고 듣는 중에 ⌥←를 쳐도 끝내지 않는다
    func testChordWhileHandsFreeKeepsListening() {
        var keys = Keyboard()
        let start = keys.startHandsFree(at: 10)
        XCTAssertEqual(keys.press(at: start + 1), [])
        XCTAssertEqual(keys.key(leftArrow, at: start + 1.1), [])
        XCTAssertEqual(keys.release(at: start + 1.2), [])
        XCTAssertEqual(keys.machine.phase, .handsFree(.listening))
        XCTAssertEqual(keys.press(at: start + 2), [])
        XCTAssertEqual(keys.release(at: start + 2.05), [.ended])
    }

    // MARK: 다른 수식키를 누른 채 누름

    func testHotKeyPressedWithModifierHeldIsIgnored() {
        var keys = Keyboard()
        XCTAssertEqual(keys.modifier(leftShift.code, leftShift.bits, down: true, at: 10), [])
        XCTAssertEqual(keys.press(at: 10.1), [])
        XCTAssertEqual(keys.machine.phase, .ignoring)
        XCTAssertNil(keys.machine.nextDeadline)
        XCTAssertEqual(keys.tick(at: 11), [])
        // ⇧을 먼저 떼고 계속 누르고 있어도 듣지 않는다
        XCTAssertEqual(keys.modifier(leftShift.code, leftShift.bits, down: false, at: 11), [])
        XCTAssertEqual(keys.tick(at: 12), [])
        XCTAssertEqual(keys.release(at: 12), [])
        XCTAssertEqual(keys.machine.phase, .idle)
        // 그 다음 누름은 평소대로
        XCTAssertEqual(keys.press(at: 13), [.armed])
    }

    func testHotKeyPressedWithOppositeSideHeldIsIgnored() {
        var keys = Keyboard()
        _ = keys.modifier(leftOption.code, leftOption.bits, down: true, at: 10)
        XCTAssertEqual(keys.press(at: 10.1), [])
        XCTAssertEqual(keys.release(at: 11), [])
    }

    func testModifierHeldOnSecondTapIsIgnored() {
        var keys = Keyboard()
        _ = keys.tap(at: 10)
        _ = keys.modifier(leftCommand.code, leftCommand.bits, down: true, at: 10.1)
        XCTAssertEqual(keys.press(at: 10.2), [])
        XCTAssertEqual(keys.release(at: 10.25), [])
        XCTAssertEqual(keys.machine.phase, .idle)
    }

    func testModifierHeldWhilePressingDuringHandsFreeIsIgnored() {
        var keys = Keyboard()
        let start = keys.startHandsFree(at: 10)
        _ = keys.modifier(leftShift.code, leftShift.bits, down: true, at: start + 1)
        XCTAssertEqual(keys.press(at: start + 1.1), [])
        XCTAssertEqual(keys.release(at: start + 1.2), [])
        XCTAssertEqual(keys.machine.phase, .handsFree(.listening))
        _ = keys.modifier(leftShift.code, leftShift.bits, down: false, at: start + 1.3)
        _ = keys.press(at: start + 2)
        XCTAssertEqual(keys.release(at: start + 2.05), [.ended])
    }

    // MARK: Esc

    func testEscapeCancelsWhileArmed() {
        var keys = Keyboard()
        _ = keys.press(at: 10)
        XCTAssertEqual(keys.key(escape, at: 10.05), [.cancelled])
        XCTAssertEqual(keys.tick(at: 11), [])
        XCTAssertEqual(keys.release(at: 11), [])
    }

    func testEscapeCancelsWhileHolding() {
        var keys = Keyboard()
        _ = keys.press(at: 10)
        _ = keys.tick(at: 10.2)
        XCTAssertEqual(keys.key(escape, at: 11), [.cancelled])
        XCTAssertEqual(keys.release(at: 11.5), [])
        // 취소한 뒤 뗀 것은 톡 친 것으로 치지 않는다
        XCTAssertEqual(keys.press(at: 11.6), [.armed])
    }

    func testEscapeCancelsWhileHandsFreeStarting() {
        var keys = Keyboard()
        _ = keys.tap(at: 10)
        _ = keys.press(at: 10.2)
        XCTAssertEqual(keys.key(escape, at: 10.22), [.cancelled])
        XCTAssertEqual(keys.release(at: 10.3), [])
        XCTAssertEqual(keys.machine.phase, .idle)
    }

    func testEscapeCancelsWhileHandsFreeListening() {
        var keys = Keyboard()
        let start = keys.startHandsFree(at: 10)
        XCTAssertEqual(keys.key(escape, at: start + 3), [.cancelled])
        XCTAssertEqual(keys.machine.phase, .idle)
        XCTAssertEqual(keys.press(at: start + 4), [.armed])
    }

    func testEscapeCancelsWhileHandsFreeStopping() {
        var keys = Keyboard()
        let start = keys.startHandsFree(at: 10)
        _ = keys.press(at: start + 1)
        XCTAssertEqual(keys.key(escape, at: start + 1.05), [.cancelled])
        XCTAssertEqual(keys.release(at: start + 1.1), [])
        XCTAssertEqual(keys.machine.phase, .idle)
    }

    func testEscapeWhenNotListeningDoesNothing() {
        var keys = Keyboard()
        XCTAssertEqual(keys.key(escape, at: 10), [])
        _ = keys.tap(at: 11)
        XCTAssertEqual(keys.key(escape, at: 11.1), [])
        // 톡 친 뒤 Esc를 누르면 두 번 누르기도 없던 일이 된다
        XCTAssertEqual(keys.press(at: 11.2), [.armed])
    }

    // MARK: 다른 단축키

    func testRightCommand() {
        var keys = Keyboard(.rightCommand)
        XCTAssertEqual(keys.press(at: 10), [.armed])
        XCTAssertEqual(keys.release(at: 10.5), [.began(handsFree: false), .ended])
        // 왼쪽 ⌘은 단축키가 아니다
        XCTAssertEqual(keys.modifier(leftCommand.code, leftCommand.bits, down: true, at: 11), [])
        XCTAssertEqual(keys.modifier(leftCommand.code, leftCommand.bits, down: false, at: 11.5), [])
        XCTAssertEqual(keys.machine.phase, .idle)
        // 오른쪽 ⌘을 누른 채 왼쪽 ⌘을 누르면 같이 누른 것
        _ = keys.press(at: 12)
        XCTAssertEqual(keys.modifier(leftCommand.code, leftCommand.bits, down: true, at: 12.05), [.cancelled])
    }

    func testFunctionKey() {
        var keys = Keyboard(.fn)
        XCTAssertEqual(keys.press(at: 10), [.armed])
        XCTAssertEqual(keys.tick(at: 10.2), [.began(handsFree: false)])
        XCTAssertEqual(keys.key(leftArrow, at: 10.3), [.cancelled])

        var tap = Keyboard(.fn)
        XCTAssertEqual(tap.tap(at: 10), [.armed, .cancelled])
        XCTAssertEqual(tap.press(at: 10.2), [.armed, .began(handsFree: true)])
    }

    func testLeftOptionAloneDoesNothing() {
        var keys = Keyboard()
        XCTAssertEqual(keys.modifier(leftOption.code, leftOption.bits, down: true, at: 10), [])
        XCTAssertEqual(keys.tick(at: 11), [])
        XCTAssertEqual(keys.modifier(leftOption.code, leftOption.bits, down: false, at: 11), [])
        XCTAssertEqual(keys.machine.phase, .idle)
    }

    // MARK: 이벤트가 이상할 때

    /// 장치 비트 없이 묶음 비트만 오는 이벤트 (원격 제어 앱 등)
    func testFamilyBitWithoutDeviceBitsCountsAsHotKey() {
        var machine = PushToTalkStateMachine(hotKey: .rightOption, allowsHandsFree: true)
        XCTAssertEqual(machine.flagsChanged(keyCode: 61, flags: Bits.option, at: 10), [.armed])
        XCTAssertEqual(machine.flagsChanged(keyCode: 61, flags: 0, at: 10.5), [.began(handsFree: false), .ended])
    }

    func testRepeatedDownEventIsIgnored() {
        var keys = Keyboard()
        XCTAssertEqual(keys.press(at: 10), [.armed])
        XCTAssertEqual(keys.press(at: 10.05), [])
        XCTAssertEqual(keys.release(at: 10.5), [.began(handsFree: false), .ended])
    }

    /// 단축키를 뗀 이벤트를 놓쳤으면 다음 수식키 이벤트로 바로잡는다
    func testMissedReleaseIsRecoveredFromAnotherModifierEvent() {
        var machine = PushToTalkStateMachine(hotKey: .rightOption, allowsHandsFree: true)
        _ = machine.flagsChanged(keyCode: 61, flags: Bits.option | Bits.rightOption, at: 10)
        _ = machine.tick(at: 10.2)
        XCTAssertEqual(machine.flagsChanged(keyCode: 56, flags: Bits.shift | Bits.leftShift, at: 11), [.ended])
        XCTAssertFalse(machine.isHotKeyDown)
        XCTAssertEqual(machine.phase, .idle)
    }

    func testReleaseWithoutPressDoesNothing() {
        var machine = PushToTalkStateMachine(hotKey: .rightOption, allowsHandsFree: true)
        XCTAssertEqual(machine.flagsChanged(keyCode: 61, flags: 0x100, at: 10), [])
        XCTAssertEqual(machine.phase, .idle)
    }

    // MARK: 멈춤 · 설정 바꾸기

    func testPointerWhilePressedOrHoldingIsAChord() {
        var keyboard = Keyboard()
        XCTAssertEqual(keyboard.press(at: 0), [.armed])
        XCTAssertEqual(keyboard.machine.pointerPressed(at: 0.05), [.cancelled])
        XCTAssertEqual(keyboard.release(at: 0.3), [])
        XCTAssertEqual(keyboard.machine.phase, .idle)

        XCTAssertEqual(keyboard.press(at: 1), [.armed])
        XCTAssertEqual(keyboard.machine.pointerPressed(at: 1.5), [.began(handsFree: false), .cancelled])

        // 손을 떼고 듣는 중에는 클릭해도 (글 칸을 고르는 등) 계속 듣는다
        var handsFree = Keyboard()
        let released = handsFree.startHandsFree(at: 10)
        XCTAssertEqual(handsFree.machine.pointerPressed(at: released + 1), [])
        XCTAssertEqual(handsFree.machine.phase, .handsFree(.listening))
    }

    func testResetCancelsOnlyWhileListening() {
        var armed = Keyboard()
        _ = armed.press(at: 10)
        XCTAssertEqual(armed.machine.reset(), [.cancelled])
        XCTAssertEqual(armed.machine.phase, .idle)

        var handsFree = Keyboard()
        _ = handsFree.startHandsFree(at: 10)
        XCTAssertEqual(handsFree.machine.reset(), [.cancelled])

        var tapped = Keyboard()
        _ = tapped.tap(at: 10)
        XCTAssertEqual(tapped.machine.reset(), [])

        var idle = Keyboard()
        XCTAssertEqual(idle.machine.reset(), [])
    }

    func testResetWhileKeyIsDownIgnoresItsRelease() {
        var keys = Keyboard()
        _ = keys.press(at: 10)
        _ = keys.machine.reset()
        XCTAssertEqual(keys.release(at: 10.05), [])
        XCTAssertEqual(keys.press(at: 10.1), [.armed])
    }

    func testChangingHotKeyCancelsAndSwitchesKeys() {
        var keys = Keyboard()
        _ = keys.press(at: 10)
        XCTAssertEqual(keys.machine.update(hotKey: .rightCommand, allowsHandsFree: true), [.cancelled])
        XCTAssertEqual(keys.machine.flagsChanged(keyCode: 61, flags: 0x100, at: 10.1), [])
        XCTAssertEqual(keys.machine.flagsChanged(keyCode: 61, flags: Bits.option | Bits.rightOption, at: 11), [])
        XCTAssertEqual(keys.machine.flagsChanged(keyCode: 61, flags: 0, at: 11.5), [])
        XCTAssertEqual(keys.machine.flagsChanged(keyCode: 54, flags: Bits.command | Bits.rightCommand, at: 12), [.armed])
    }

    func testSameHotKeyUpdateKeepsListening() {
        var keys = Keyboard()
        _ = keys.press(at: 10)
        _ = keys.tick(at: 10.2)
        XCTAssertEqual(keys.machine.update(hotKey: .rightOption, allowsHandsFree: false), [])
        XCTAssertEqual(keys.release(at: 11), [.ended])
    }

    func testDisablingHandsFreeDropsPendingTap() {
        var keys = Keyboard()
        _ = keys.tap(at: 10)
        XCTAssertEqual(keys.machine.update(hotKey: .rightOption, allowsHandsFree: false), [])
        XCTAssertEqual(keys.machine.phase, .idle)
        XCTAssertEqual(keys.press(at: 10.2), [.armed])
    }
}

/// NSEvent를 만들어(보내지 않고) 감시기에 바로 넣어 본다
@MainActor
final class PushToTalkMonitorTests: XCTestCase {
    private final class Clock {
        var now: TimeInterval = 100
    }

    private func flagsEvent(keyCode: UInt16, flags: UInt, timestamp: TimeInterval = 0) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
            timestamp: timestamp, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: keyCode))
    }

    private func keyEvent(keyCode: UInt16, characters: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    private let rightOptionDown = PushToTalkStateMachine.Modifiers.option | PushToTalkStateMachine.Modifiers.rightOption | 0x100

    func testHoldThroughMonitor() throws {
        let clock = Clock()
        let monitor = PushToTalkMonitor(hotKey: .rightOption, allowsHandsFree: true, clock: { clock.now },
                                        isHotKeyPhysicallyDown: { _ in true })
        var events: [PushToTalkEvent] = []
        monitor.onEvent = { events.append($0) }

        let down = try flagsEvent(keyCode: 61, flags: rightOptionDown)
        // 오른쪽 장치 비트가 NSEvent에 그대로 남는다
        XCTAssertEqual(down.modifierFlags.rawValue & PushToTalkStateMachine.Modifiers.rightOption,
                       PushToTalkStateMachine.Modifiers.rightOption)
        monitor.handle(down)
        XCTAssertEqual(events, [.armed])
        clock.now += 0.2
        monitor.tick()
        XCTAssertEqual(events, [.armed, .began(handsFree: false)])
        XCTAssertTrue(monitor.isActive)
        clock.now += 1
        monitor.handle(try flagsEvent(keyCode: 61, flags: 0x100))
        XCTAssertEqual(events, [.armed, .began(handsFree: false), .ended])
        XCTAssertFalse(monitor.isActive)
    }

    func testEscapeThroughMonitor() throws {
        let clock = Clock()
        let monitor = PushToTalkMonitor(hotKey: .rightOption, allowsHandsFree: true, clock: { clock.now })
        var events: [PushToTalkEvent] = []
        monitor.onEvent = { events.append($0) }

        monitor.handle(try flagsEvent(keyCode: 61, flags: rightOptionDown))
        monitor.handle(try keyEvent(keyCode: 53, characters: "\u{1b}"))
        XCTAssertEqual(events, [.armed, .cancelled])
    }

    func testStopCancelsOnceWhileListening() throws {
        let clock = Clock()
        let monitor = PushToTalkMonitor(hotKey: .rightOption, allowsHandsFree: true, clock: { clock.now })
        var events: [PushToTalkEvent] = []
        monitor.onEvent = { events.append($0) }

        monitor.handle(try flagsEvent(keyCode: 61, flags: rightOptionDown))
        monitor.stop()
        monitor.stop()
        XCTAssertEqual(events, [.armed, .cancelled])
        XCTAssertFalse(monitor.isRunning)
    }

    /// 메인 스레드가 밀려 늦게 처리해도 이벤트가 일어난 시각으로 가린다: 0.08초 만에 뗀 것은 톡 친 것이다
    func testLateHandledReleaseUsesEventTime() throws {
        let clock = Clock()
        let monitor = PushToTalkMonitor(hotKey: .rightOption, allowsHandsFree: true, clock: { clock.now },
                                        isHotKeyPhysicallyDown: { _ in false })
        var events: [PushToTalkEvent] = []
        monitor.onEvent = { events.append($0) }
        monitor.handle(try flagsEvent(keyCode: 61, flags: rightOptionDown, timestamp: 100))
        XCTAssertEqual(events, [.armed])
        clock.now = 100.5
        monitor.handle(try flagsEvent(keyCode: 61, flags: 0x100, timestamp: 100.08))
        XCTAssertEqual(events, [.armed, .cancelled])
        XCTAssertTrue(monitor.isWaitingForSecondTap)
    }

    /// 기준 시간이 됐는데 키가 이미 올라가 있으면 밀려 있는 키 떼기를 기다린다 (톡 친 것을 듣기로 만들지 않게)
    func testDeadlineWaitsForPendingRelease() throws {
        let clock = Clock()
        var keyIsDown = false
        let monitor = PushToTalkMonitor(hotKey: .rightOption, allowsHandsFree: true, clock: { clock.now },
                                        isHotKeyPhysicallyDown: { _ in keyIsDown })
        var events: [PushToTalkEvent] = []
        monitor.onEvent = { events.append($0) }
        monitor.handle(try flagsEvent(keyCode: 61, flags: rightOptionDown))
        clock.now += 0.3
        monitor.tick()
        XCTAssertEqual(events, [.armed])
        monitor.handle(try flagsEvent(keyCode: 61, flags: 0x100, timestamp: 100.08))
        XCTAssertEqual(events, [.armed, .cancelled])

        // 정말 누르고 있으면 기준 시간에 듣기 시작한다
        keyIsDown = true
        clock.now = 102
        monitor.handle(try flagsEvent(keyCode: 61, flags: rightOptionDown))
        clock.now += 0.2
        monitor.tick()
        XCTAssertEqual(events, [.armed, .cancelled, .armed, .began(handsFree: false)])
        monitor.stop()
    }

    /// 단축키를 누른 채 클릭하면 ⌥-클릭 같은 단축키다
    func testClickWhilePressedCancels() throws {
        let clock = Clock()
        let monitor = PushToTalkMonitor(hotKey: .rightOption, allowsHandsFree: true, clock: { clock.now },
                                        isHotKeyPhysicallyDown: { _ in true })
        var events: [PushToTalkEvent] = []
        monitor.onEvent = { events.append($0) }
        monitor.handle(try flagsEvent(keyCode: 61, flags: rightOptionDown))
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        monitor.handle(click)
        XCTAssertEqual(events, [.armed, .cancelled])
        monitor.handle(try flagsEvent(keyCode: 61, flags: 0x100))
        XCTAssertEqual(events, [.armed, .cancelled])
        XCTAssertFalse(monitor.isWaitingForSecondTap)
    }

    /// 이벤트 탭이 본 Esc: 듣는 중이면 버리고 앞 앱에 넘기지 않는다. 그 Esc의 키 떼기도 삼킨다
    func testInterceptsEscapeOnlyWhileListening() throws {
        let clock = Clock()
        let monitor = PushToTalkMonitor(hotKey: .rightOption, allowsHandsFree: true, clock: { clock.now },
                                        isHotKeyPhysicallyDown: { _ in true })
        var events: [PushToTalkEvent] = []
        monitor.onEvent = { events.append($0) }
        XCTAssertFalse(monitor.interceptKey(down: true, keyCode: 53, at: 0), "듣지 않을 때는 그대로 넘긴다")
        XCTAssertFalse(monitor.interceptKey(down: false, keyCode: 53, at: 0))
        monitor.handle(try flagsEvent(keyCode: 61, flags: rightOptionDown))
        XCTAssertFalse(monitor.interceptKey(down: true, keyCode: 0, at: 0), "다른 키는 넘긴다")
        XCTAssertTrue(monitor.interceptKey(down: true, keyCode: 53, at: 0))
        XCTAssertEqual(events, [.armed, .cancelled])
        XCTAssertTrue(monitor.interceptKey(down: true, keyCode: 53, at: 0), "누르고 있어 반복된 Esc")
        XCTAssertTrue(monitor.interceptKey(down: false, keyCode: 53, at: 0))
        XCTAssertFalse(monitor.interceptKey(down: false, keyCode: 53, at: 0))
        XCTAssertEqual(events, [.armed, .cancelled])
        monitor.stop()
    }

    func testUpdateSwitchesHotKey() throws {
        let clock = Clock()
        let monitor = PushToTalkMonitor(hotKey: .rightOption, allowsHandsFree: true, clock: { clock.now })
        var events: [PushToTalkEvent] = []
        monitor.onEvent = { events.append($0) }

        monitor.update(hotKey: .fn, allowsHandsFree: false)
        XCTAssertEqual(monitor.hotKey, .fn)
        XCTAssertFalse(monitor.allowsHandsFree)
        monitor.handle(try flagsEvent(keyCode: 61, flags: rightOptionDown))
        XCTAssertEqual(events, [])
        monitor.handle(try flagsEvent(keyCode: 61, flags: 0x100))
        monitor.handle(try flagsEvent(keyCode: 63, flags: PushToTalkStateMachine.Modifiers.function | 0x100))
        XCTAssertEqual(events, [.armed])
        monitor.stop()
    }

    // MARK: 듣는 동안만 다는 것 (가짜 감시 · 탭)

    private func hookedMonitor(_ fake: FakeSystemHooks, clock: Clock, keyIsDown: @escaping () -> Bool = { true })
        -> PushToTalkMonitor {
        PushToTalkMonitor(hotKey: .rightOption, allowsHandsFree: true, interceptsEscape: true, clock: { clock.now },
                          isHotKeyPhysicallyDown: { _ in keyIsDown() }, hooks: fake.hooks)
    }

    /// 마우스 감시 · Esc 탭은 누른 때부터 끝날 때까지만. armed를 알리기 전에 단다 (마이크를 여는 동안 누른 Esc도 삼키게)
    func testSessionHooksComeOffOnEveryEnd() throws {
        let fake = FakeSystemHooks()
        let clock = Clock()
        let monitor = hookedMonitor(fake, clock: clock)
        var events: [PushToTalkEvent] = []
        var tapAtArmed = false
        monitor.onEvent = { [unowned monitor] event in
            events.append(event)
            if event == .armed { tapAtArmed = monitor.hasEscapeTap }
        }
        monitor.start()
        XCTAssertTrue(monitor.isRunning)
        XCTAssertEqual(fake.count(.key), 2)
        XCTAssertFalse(monitor.hasEscapeTap)
        XCTAssertFalse(monitor.watchesPointer)

        // 누르고 있다가 떼기
        monitor.handle(try flagsEvent(keyCode: 61, flags: rightOptionDown))
        XCTAssertTrue(tapAtArmed)
        XCTAssertEqual(fake.count(.tap), 1)
        XCTAssertEqual(fake.count(.pointer), 2)
        clock.now += 0.2
        monitor.tick()
        clock.now += 1
        monitor.handle(try flagsEvent(keyCode: 61, flags: 0x100))
        XCTAssertEqual(events, [.armed, .began(handsFree: false), .ended])
        XCTAssertEqual(fake.count(.tap), 0)
        XCTAssertEqual(fake.count(.pointer), 0)

        // 톡 친 것
        clock.now += 1
        monitor.handle(try flagsEvent(keyCode: 61, flags: rightOptionDown))
        XCTAssertTrue(monitor.hasEscapeTap)
        monitor.handle(try flagsEvent(keyCode: 61, flags: 0x100))
        XCTAssertFalse(monitor.hasEscapeTap)
        XCTAssertFalse(monitor.watchesPointer)

        // 밖에서 끝냄
        clock.now += 1
        monitor.handle(try flagsEvent(keyCode: 61, flags: rightOptionDown))
        monitor.abandon()
        XCTAssertFalse(monitor.hasEscapeTap)
        XCTAssertFalse(monitor.watchesPointer)
        monitor.handle(try flagsEvent(keyCode: 61, flags: 0x100))

        // 감시를 멈춤
        clock.now += 1
        monitor.handle(try flagsEvent(keyCode: 61, flags: rightOptionDown))
        monitor.stop()
        XCTAssertEqual(fake.installedCount, 0)
        XCTAssertEqual(fake.tapInstalls, 4)
    }

    /// 손을 떼고 듣는 중 Esc: 듣기를 버리고, 탭은 그 Esc를 뗄 때까지 달아 둔다 (키 떼기도 앞 앱에 넘기지 않게)
    func testHandsFreeEscapeKeepsTapUntilKeyUp() throws {
        let fake = FakeSystemHooks()
        let clock = Clock()
        var keyIsDown = false
        let monitor = hookedMonitor(fake, clock: clock) { keyIsDown }
        var events: [PushToTalkEvent] = []
        monitor.onEvent = { events.append($0) }
        monitor.start()
        keyIsDown = true
        monitor.handle(try flagsEvent(keyCode: 61, flags: rightOptionDown))
        clock.now += 0.05
        keyIsDown = false
        monitor.handle(try flagsEvent(keyCode: 61, flags: 0x100))
        clock.now += 0.15
        keyIsDown = true
        monitor.handle(try flagsEvent(keyCode: 61, flags: rightOptionDown))
        clock.now += 0.05
        keyIsDown = false
        monitor.handle(try flagsEvent(keyCode: 61, flags: 0x100))
        XCTAssertEqual(events, [.armed, .cancelled, .armed, .began(handsFree: true)])
        XCTAssertTrue(monitor.isActive)
        XCTAssertTrue(monitor.hasEscapeTap)

        XCTAssertTrue(monitor.interceptKey(down: true, keyCode: 53, at: 0))
        XCTAssertEqual(events.last, .cancelled)
        XCTAssertFalse(monitor.isActive)
        XCTAssertTrue(monitor.hasEscapeTap, "Esc를 뗄 때까지")
        XCTAssertFalse(monitor.watchesPointer)
        XCTAssertTrue(monitor.interceptKey(down: false, keyCode: 53, at: 0))
        XCTAssertFalse(monitor.hasEscapeTap)
        monitor.stop()
    }

    /// 탭을 달기 전에(마이크를 여는 동안 등) 눌려 탭이 넘긴 Esc도 NSEvent로 와서 듣기를 버린다. Cheoma 창에서는 삼킨다
    func testEscapeThatThePassedTapStillCancels() throws {
        let fake = FakeSystemHooks()
        let clock = Clock()
        let monitor = hookedMonitor(fake, clock: clock)
        var events: [PushToTalkEvent] = []
        monitor.onEvent = { events.append($0) }
        monitor.start()
        monitor.handle(try flagsEvent(keyCode: 61, flags: rightOptionDown))
        XCTAssertTrue(monitor.hasEscapeTap)
        monitor.handle(try keyEvent(keyCode: 53, characters: "\u{1b}"))
        XCTAssertEqual(events, [.armed, .cancelled])
        monitor.handle(try flagsEvent(keyCode: 61, flags: 0x100))

        clock.now += 1
        monitor.handle(try flagsEvent(keyCode: 61, flags: rightOptionDown))
        let local = try XCTUnwrap(fake.localHandler)
        XCTAssertTrue(local(try keyEvent(keyCode: 53, characters: "\u{1b}")), "듣기를 버린 Esc는 Cheoma 창에 넘기지 않는다")
        XCTAssertEqual(events, [.armed, .cancelled, .armed, .cancelled])
        XCTAssertFalse(local(try keyEvent(keyCode: 53, characters: "\u{1b}")), "듣지 않을 때는 넘긴다")
        monitor.stop()
    }

    /// 탭을 만들지 못해도 (권한 없음) 보기만 하는 감시는 그대로 돈다
    func testWorksWithoutEscapeTap() throws {
        let fake = FakeSystemHooks()
        fake.tapFails = true
        let clock = Clock()
        let monitor = hookedMonitor(fake, clock: clock)
        var events: [PushToTalkEvent] = []
        monitor.onEvent = { events.append($0) }
        monitor.start()
        monitor.handle(try flagsEvent(keyCode: 61, flags: rightOptionDown))
        XCTAssertFalse(monitor.hasEscapeTap)
        XCTAssertTrue(monitor.watchesPointer)
        monitor.handle(try keyEvent(keyCode: 53, characters: "\u{1b}"))
        XCTAssertEqual(events, [.armed, .cancelled])
        monitor.stop()
    }

    /// 사용자가 친 키만 알린다 (받아쓰기가 보낸 ⌘V · 수식키는 빼고)
    func testReportsTypedKeysButNotOwnPaste() throws {
        let clock = Clock()
        let monitor = PushToTalkMonitor(hotKey: .rightOption, allowsHandsFree: true, clock: { clock.now },
                                        isHotKeyPhysicallyDown: { _ in false })
        var typed = 0
        monitor.onKeyTyped = { typed += 1 }
        monitor.handle(try keyEvent(keyCode: 36, characters: "\r"))
        XCTAssertEqual(typed, 1)
        monitor.handle(try flagsEvent(keyCode: 61, flags: rightOptionDown))
        monitor.handle(try flagsEvent(keyCode: 61, flags: 0x100))
        XCTAssertEqual(typed, 1)
        // 만들기만 하고 보내지 않는다
        let paste = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true))
        paste.flags = .maskCommand
        paste.setIntegerValueField(.eventSourceUserData, value: DictationPasteKey.eventMarker)
        monitor.handle(try XCTUnwrap(NSEvent(cgEvent: paste)))
        XCTAssertEqual(typed, 1)
        monitor.stop()
    }
}

/// 탭 스레드에서 정하는 것: 듣는 중의 Esc만 삼키고, 그 Esc의 반복 · 키 떼기도 삼킨다
final class EscapeTapGateTests: XCTestCase {
    func testDecisions() {
        let gate = EscapeTapGate()
        XCTAssertEqual(gate.decide(keyCode: 53, down: true), .pass)
        XCTAssertEqual(gate.decide(keyCode: 53, down: false), .pass)
        gate.setIntercepts(true)
        XCTAssertEqual(gate.decide(keyCode: 0, down: true), .pass)
        XCTAssertEqual(gate.decide(keyCode: 53, down: true), .swallowAndCancel)
        XCTAssertTrue(gate.holdsSwallowedEscape)
        XCTAssertEqual(gate.decide(keyCode: 53, down: true), .swallow)
        XCTAssertEqual(gate.decide(keyCode: 0, down: false), .pass)
        XCTAssertEqual(gate.decide(keyCode: 53, down: false), .swallowRelease)
        XCTAssertFalse(gate.holdsSwallowedEscape)
        // 한 번 버린 뒤에는 메인 스레드가 다시 켤 때까지 넘긴다
        XCTAssertEqual(gate.decide(keyCode: 53, down: true), .pass)
        gate.setIntercepts(true)
        XCTAssertEqual(gate.decide(keyCode: 53, down: true), .swallowAndCancel)
        gate.forgetSwallowedEscape()
        XCTAssertEqual(gate.decide(keyCode: 53, down: false), .pass)
    }

    /// 여러 스레드에서 같이 써도 Esc 한 번은 한 번만 버린다
    func testConcurrentDecisionsCancelOnce() {
        let gate = EscapeTapGate()
        gate.setIntercepts(true)
        let cancels = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if gate.decide(keyCode: 53, down: true) == .swallowAndCancel { cancels.withLock { $0 += 1 } }
        }
        XCTAssertEqual(cancels.withLock { $0 }, 1)
    }

    // MARK: 탭 스레드 (이벤트 탭이 아닌 보통 포트로 스레드만 본다)

    private func plainPort() throws -> (CFMachPort, CFRunLoopSource) {
        var context = CFMachPortContext()
        let port = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, { _, _, _, _ in }, &context, nil))
        let source = try XCTUnwrap(CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0))
        return (port, source)
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            guard Date() < deadline else { return XCTFail("기다리다 끝남: \(what)") }
            usleep(2_000)
        }
    }

    /// 스레드는 자기 런루프에서 탭을 켜고, stop하면 그 스레드에서 끄고 포트를 무효로 한 뒤 끝난다
    func testTapThreadStartsAndStopsCleanly() throws {
        let (port, source) = try plainPort()
        let enabled = OSAllocatedUnfairLock(initialState: [Bool]())
        let tap = EscapeTapThread(gate: EscapeTapGate(), report: { _, _ in })
        tap.launch(port: port, source: source) { value in enabled.withLock { $0.append(value) } }
        waitUntil("런루프를 돎") { tap.isRunning }
        XCTAssertTrue(CFMachPortIsValid(port))
        tap.stop()
        waitUntil("스레드가 끝남") { tap.isFinished }
        XCTAssertFalse(CFMachPortIsValid(port))
        XCTAssertEqual(enabled.withLock { $0 }, [true, false])
        tap.stop()
    }

    /// 스레드가 돌기 전에 떼어도 스레드가 스스로 정리하고 끝난다
    func testTapThreadStoppedBeforeRunning() throws {
        for _ in 0..<20 {
            let (port, source) = try plainPort()
            let tap = EscapeTapThread(gate: EscapeTapGate(), report: { _, _ in })
            tap.launch(port: port, source: source) { _ in }
            tap.stop()
            waitUntil("스레드가 끝남") { tap.isFinished }
            XCTAssertFalse(CFMachPortIsValid(port))
        }
    }
}

/// 진짜 감시 · 탭 대신 표만 돌려주는 가짜. 단 것을 센다
@MainActor
final class FakeSystemHooks {
    enum Kind { case key, pointer, tap }

    private final class Token {
        let kind: Kind
        init(_ kind: Kind) { self.kind = kind }
    }

    private var installed: [Token] = []
    private(set) var tapInstalls = 0
    /// 탭을 만들지 못하는 것처럼 (권한 없음)
    var tapFails = false
    /// 앱 안 감시 (Cheoma 창으로 온 키처럼 넣어 본다. true면 삼킨다)
    private(set) var localHandler: ((NSEvent) -> Bool)?

    func count(_ kind: Kind) -> Int { installed.filter { $0.kind == kind }.count }
    var installedCount: Int { installed.count }

    var hooks: PushToTalkMonitor.SystemHooks {
        PushToTalkMonitor.SystemHooks(
            addKeyMonitors: { [unowned self] _, local in
                localHandler = local
                return [add(.key), add(.key)]
            },
            addPointerMonitors: { [unowned self] _ in [add(.pointer), add(.pointer)] },
            removeMonitor: { [unowned self] token in remove(token) },
            installEscapeTap: { [unowned self] _, _ in
                tapInstalls += 1
                return tapFails ? nil : add(.tap)
            },
            removeEscapeTap: { [unowned self] token in remove(token) })
    }

    private func add(_ kind: Kind) -> Token {
        let token = Token(kind)
        installed.append(token)
        return token
    }

    private func remove(_ token: Any) {
        guard let token = token as? Token else { return XCTFail("모르는 표") }
        guard let index = installed.firstIndex(where: { $0 === token }) else { return XCTFail("두 번 뗌") }
        installed.remove(at: index)
    }
}

// DeviceComebackTests.swift
// Waiting for a device that went away, and how often it may come back.

import XCTest
import IOKit
@testable import USBIPDCore

/// A device that is never used, only handed over.
private final class IdleDeviceIO: USBDeviceIO {
    func endpoint(_ address: UInt8) -> USBEndpointInfo? { nil }
    var currentConfiguration: UInt8? { 1 }
    func makeBuffer(length: Int) -> NSMutableData { NSMutableData(length: length) ?? NSMutableData() }
    func enqueueControl(_ setup: USBSetupPacket, data: NSMutableData?,
                        completion: @escaping @Sendable (IOReturn, Int) -> Void) throws {}
    func sendControl(_ setup: USBSetupPacket, data: NSMutableData?) throws -> Int { 0 }
    func enqueueTransfer(endpoint: UInt8, data: NSMutableData?,
                         completion: @escaping @Sendable (IOReturn, Int) -> Void) throws {}
    func enqueueIsochronous(endpoint: UInt8, data: NSMutableData, transactions: [USBIsochronousTransaction],
                            completion: @escaping @Sendable (IOReturn, [USBIsochronousTransaction]) -> Void) throws {}
    func abortControl() {}
    func abort(endpoint: UInt8) {}
    func clearHalt(endpoint: UInt8) throws {}
    func setConfiguration(_ value: UInt8) throws {}
    func setAlternateSetting(interface: UInt8, alternate: UInt8) throws {}
    func close() {}
}

final class DeviceComebackTests: XCTestCase {

    private let comeback = DeviceComeback(window: 0.3, interval: 0.01)

    /// Looked for until it is back, then handed over as it was opened.
    func testADeviceThatComesBackIsHandedOver() {
        let device = IdleDeviceIO()
        var looks = 0
        let outcome = comeback.wait(reopen: {
            looks += 1
            return looks < 3 ? nil : device
        }, stillWanted: { true })

        guard case .back(let io) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(io === device)
        XCTAssertEqual(looks, 3)
    }

    /// Something else at the port, or a device that would not open, ends the wait.
    func testADeviceThatCannotBeTakenAgainIsRefused() {
        var looks = 0
        let outcome = comeback.wait(reopen: {
            looks += 1
            throw USBDeviceOpenError.differentDevice(busid: "1-2")
        }, stillWanted: { true })

        guard case .refused(let error) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(error as? USBDeviceOpenError, .differentDevice(busid: "1-2"))
        XCTAssertEqual(looks, 1)
    }

    /// A device that stays away is given up on once the window has passed.
    func testADeviceThatStaysAwayIsGivenUpOn() {
        let started = Date()
        let outcome = comeback.wait(reopen: { nil }, stillWanted: { true })

        guard case .timedOut = outcome else { return XCTFail("\(outcome)") }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.3)
    }

    /// Once its client has gone, the device is no longer looked for.
    func testNothingIsLookedForOnceTheClientHasGone() {
        var looks = 0
        var wanted = true
        let outcome = comeback.wait(reopen: {
            looks += 1
            wanted = false
            return nil
        }, stillWanted: { wanted })

        guard case .abandoned = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(looks, 1)
    }

    /// A device may come back a few times within the period, and again once it has passed.
    func testComebacksAreLimitedWithinThePeriod() {
        var budget = ComebackBudget(limit: 3, period: 60)
        let start = Date()
        XCTAssertTrue(budget.allows(at: start))
        XCTAssertTrue(budget.allows(at: start.addingTimeInterval(20)))
        XCTAssertTrue(budget.allows(at: start.addingTimeInterval(40)))
        XCTAssertFalse(budget.allows(at: start.addingTimeInterval(50)))
        // The first has left the period; the refusal was not counted.
        XCTAssertTrue(budget.allows(at: start.addingTimeInterval(61)))
        XCTAssertFalse(budget.allows(at: start.addingTimeInterval(62)))
    }

    /// A drive that resets each time it goes to standby, with half a minute of idling
    /// between, always comes back.
    func testADriveResettingAtEachStandbyKeepsComingBack() {
        var budget = ComebackBudget(limit: 3, period: 60)
        let start = Date()
        for index in 0..<10 {
            XCTAssertTrue(budget.allows(at: start.addingTimeInterval(Double(index) * 33)), "comeback \(index)")
        }
    }
}

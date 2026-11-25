// BulkOnlyMediumLockTests.swift
// Unlocking the medium of a captured storage device, against scripted bulk pipes.

import XCTest
@testable import USBIPDCore

/// A storage interface's bulk pipes that answer each read from a script.
private final class ScriptedPipes: BulkOnlyPipes {
    enum Reply {
        case data(Data)
        case stall
    }

    var replies: [Reply] = []
    private(set) var written: [Data] = []
    private(set) var clearedHalts: [Bool] = []
    private(set) var resets = 0

    func write(_ data: Data, timeout: TimeInterval) throws {
        written.append(data)
    }

    func read(length: Int, timeout: TimeInterval) throws -> Data {
        guard !replies.isEmpty else { throw USBDeviceIOError(USBIOReturn.timeout, "Reading") }
        switch replies.removeFirst() {
        case .data(let data):
            return data
        case .stall:
            throw USBDeviceIOError(USBIOReturn.hostPipeStalled, "Reading")
        }
    }

    func clearHalt(inbound: Bool) throws {
        clearedHalts.append(inbound)
    }

    func resetRecovery() throws {
        resets += 1
    }
}

final class BulkOnlyMediumLockTests: XCTestCase {

    private let tag: UInt32 = 0x6C6B_0001

    private func status(_ tag: UInt32, _ status: UInt8) -> ScriptedPipes.Reply {
        var data = Data([0x55, 0x53, 0x42, 0x53])
        withUnsafeBytes(of: tag.littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: [0, 0, 0, 0, status])
        return .data(data)
    }

    private func sense(key: UInt8, asc: UInt8, ascq: UInt8) -> ScriptedPipes.Reply {
        var bytes = [UInt8](repeating: 0, count: 18)
        bytes[0] = 0x70
        bytes[2] = key
        bytes[7] = 10
        bytes[12] = asc
        bytes[13] = ascq
        return .data(Data(bytes))
    }

    /// The command block is PREVENT ALLOW MEDIUM REMOVAL with Prevent 0, no data, for the
    /// logical unit asked for.
    func testSendsAllowMediumRemovalToTheUnit() {
        let pipes = ScriptedPipes()
        pipes.replies = [status(tag, 0)]
        XCTAssertEqual(BulkOnlyMediumLock.release(lun: 1, over: pipes), .released)

        XCTAssertEqual(pipes.written.count, 1)
        let block = [UInt8](pipes.written[0])
        XCTAssertEqual(block.count, 31)
        XCTAssertEqual(Array(block[0..<4]), [0x55, 0x53, 0x42, 0x43], "USBC")
        XCTAssertEqual(Array(block[4..<8]), [0x01, 0x00, 0x6B, 0x6C], "the tag, little-endian")
        XCTAssertEqual(Array(block[8..<12]), [0, 0, 0, 0], "no data")
        XCTAssertEqual(block[12], 0x00)
        XCTAssertEqual(block[13], 1, "LUN")
        XCTAssertEqual(block[14], 6, "a 6-byte command")
        XCTAssertEqual(Array(block[15..<31]), [0x1E] + [UInt8](repeating: 0, count: 15))
        XCTAssertEqual(pipes.resets, 0)
    }

    /// The first command after a media change gets a unit attention. Reading it ends it,
    /// and the unlock goes through on the second try.
    func testTriesAgainAfterAUnitAttention() {
        let pipes = ScriptedPipes()
        pipes.replies = [status(tag, 1), sense(key: 6, asc: 0x28, ascq: 0), status(tag + 1, 0), status(tag + 2, 0)]
        XCTAssertEqual(BulkOnlyMediumLock.release(lun: 0, over: pipes), .released)

        XCTAssertEqual(pipes.written.map { $0[15] }, [0x1E, 0x03, 0x1E])
        XCTAssertEqual(pipes.written[1][12], 0x80, "REQUEST SENSE reads its data")
        XCTAssertEqual(pipes.written[1][8], 18)
        XCTAssertEqual(pipes.resets, 0)
    }

    /// Any other refusal is reported with the device's sense data, and not retried.
    func testReportsARefusalWithItsSense() {
        let pipes = ScriptedPipes()
        pipes.replies = [status(tag, 1), sense(key: 5, asc: 0x20, ascq: 0), status(tag + 1, 0)]
        XCTAssertEqual(BulkOnlyMediumLock.release(lun: 0, over: pipes), .refused("sense key 5, ASC 20, ASCQ 00"))
        XCTAssertEqual(pipes.written.map { $0[15] }, [0x1E, 0x03])
    }

    /// A unit attention that comes back on the second try is reported rather than
    /// retried without end.
    func testGivesUpAfterTwoTries() {
        let pipes = ScriptedPipes()
        pipes.replies = [status(tag, 1), sense(key: 6, asc: 0x29, ascq: 0), status(tag + 1, 0),
                         status(tag + 2, 1), sense(key: 6, asc: 0x29, ascq: 0), status(tag + 3, 0)]
        XCTAssertEqual(BulkOnlyMediumLock.release(lun: 0, over: pipes), .refused("sense key 6, ASC 29, ASCQ 00"))
        XCTAssertEqual(pipes.written.map { $0[15] }, [0x1E, 0x03, 0x1E, 0x03])
    }

    /// A status read that stalls is read again once the halt is cleared, as the
    /// transport prescribes.
    func testReadsTheStatusAgainAfterAStall() {
        let pipes = ScriptedPipes()
        pipes.replies = [.stall, status(tag, 0)]
        XCTAssertEqual(BulkOnlyMediumLock.release(lun: 0, over: pipes), .released)
        XCTAssertEqual(pipes.clearedHalts, [true])
        XCTAssertEqual(pipes.resets, 0)
    }

    /// A data phase that stalls is cleared and its status read after it.
    func testAStalledDataPhaseStillReadsTheStatus() {
        let pipes = ScriptedPipes()
        pipes.replies = [status(tag, 1), .stall, status(tag + 1, 1)]
        XCTAssertEqual(BulkOnlyMediumLock.release(lun: 0, over: pipes), .refused("sense data "))
        XCTAssertEqual(pipes.clearedHalts, [true])
    }

    /// A phase error resets the transport, so the client starts from a clean state.
    func testPhaseErrorResetsTheTransport() {
        let pipes = ScriptedPipes()
        pipes.replies = [status(tag, 2)]
        XCTAssertEqual(BulkOnlyMediumLock.release(lun: 0, over: pipes), .failed("phase error"))
        XCTAssertEqual(pipes.resets, 1)
    }

    /// A status answering some other command is no status for this one.
    func testStatusForAnotherTagResetsTheTransport() {
        let pipes = ScriptedPipes()
        pipes.replies = [status(tag + 7, 0)]
        guard case .failed = BulkOnlyMediumLock.release(lun: 0, over: pipes) else {
            return XCTFail("a status with another tag was accepted")
        }
        XCTAssertEqual(pipes.resets, 1)
    }

    /// A device that never answers resets the transport too.
    func testNoStatusResetsTheTransport() {
        let pipes = ScriptedPipes()
        guard case .failed = BulkOnlyMediumLock.release(lun: 0, over: pipes) else {
            return XCTFail("a missing status was taken for an answer")
        }
        XCTAssertEqual(pipes.resets, 1)
    }
}

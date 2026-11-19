// USBIPAttachmentTests.swift
// The attached-session logic, against a device that records what it is asked to do.

import XCTest
import IOKit
@testable import USBIPDCore
@testable import Common

/// A device that queues requests until the test completes them.
private final class RecordingDeviceIO: USBDeviceIO, @unchecked Sendable {
    struct Pending {
        let endpoint: UInt8
        let data: NSMutableData?
        let setup: USBSetupPacket?
        let transactions: [USBIsochronousTransaction]
        let complete: (@Sendable (IOReturn, Int) -> Void)?
        let completeIsochronous: (@Sendable (IOReturn, [USBIsochronousTransaction]) -> Void)?
    }

    private let lock = NSLock()
    var endpoints: [UInt8: USBEndpointInfo] = [:]
    var configuration: UInt8? = 1
    private(set) var pending: [Pending] = []
    private(set) var sentControl: [USBSetupPacket] = []
    private(set) var clearedHalts: [UInt8] = []
    private(set) var aborted: [UInt8] = []
    private(set) var controlAborts = 0
    private(set) var configurations: [UInt8] = []
    private(set) var alternateSettings: [[UInt8]] = []
    private(set) var closed = false
    var controlResult: IOReturn = kIOReturnSuccess

    func endpoint(_ address: UInt8) -> USBEndpointInfo? { endpoints[address] }
    var currentConfiguration: UInt8? { configuration }
    func makeBuffer(length: Int) -> NSMutableData { NSMutableData(length: length)! }

    func enqueueControl(_ setup: USBSetupPacket, data: NSMutableData?,
                        completion: @escaping @Sendable (IOReturn, Int) -> Void) throws {
        record(Pending(endpoint: 0, data: data, setup: setup, transactions: [], complete: completion,
                       completeIsochronous: nil))
    }

    func sendControl(_ setup: USBSetupPacket, data: NSMutableData?) throws -> Int {
        lock.lock(); sentControl.append(setup); lock.unlock()
        if controlResult != kIOReturnSuccess { throw USBDeviceIOError(controlResult, "control") }
        return 0
    }

    func enqueueTransfer(endpoint: UInt8, data: NSMutableData?,
                         completion: @escaping @Sendable (IOReturn, Int) -> Void) throws {
        record(Pending(endpoint: endpoint, data: data, setup: nil, transactions: [], complete: completion,
                       completeIsochronous: nil))
    }

    func enqueueIsochronous(endpoint: UInt8, data: NSMutableData, transactions: [USBIsochronousTransaction],
                            completion: @escaping @Sendable (IOReturn, [USBIsochronousTransaction]) -> Void) throws {
        record(Pending(endpoint: endpoint, data: data, setup: nil, transactions: transactions, complete: nil,
                       completeIsochronous: completion))
    }

    func abortControl() { lock.lock(); controlAborts += 1; lock.unlock() }
    func abort(endpoint: UInt8) { lock.lock(); aborted.append(endpoint); lock.unlock() }
    func clearHalt(endpoint: UInt8) throws { lock.lock(); clearedHalts.append(endpoint); lock.unlock() }
    func setConfiguration(_ value: UInt8) throws { lock.lock(); configurations.append(value); lock.unlock() }
    func setAlternateSetting(interface: UInt8, alternate: UInt8) throws {
        lock.lock(); alternateSettings.append([interface, alternate]); lock.unlock()
    }
    func close() { lock.lock(); closed = true; lock.unlock() }

    private func record(_ entry: Pending) {
        lock.lock(); pending.append(entry); lock.unlock()
    }
}

/// Replies the attachment sent, decoded.
private final class ReplyLog: @unchecked Sendable {
    private let lock = NSLock()
    private var raw: [Data] = []

    func append(_ data: Data) { lock.lock(); raw.append(data); lock.unlock() }

    var all: [Data] { lock.lock(); defer { lock.unlock() }; return raw }

    var submits: [USBIPSubmitResponse] {
        all.filter { $0[3] == 0x03 }.compactMap { try? USBIPSubmitResponse.decode(from: $0) }
    }

    var unlinks: [USBIPUnlinkResponse] {
        all.filter { $0[3] == 0x04 }.compactMap { try? USBIPUnlinkResponse.decode(from: $0) }
    }
}

final class USBIPAttachmentTests: XCTestCase {

    private var device: RecordingDeviceIO!
    private var replies: ReplyLog!
    private var attachment: USBIPAttachment!

    override func setUp() {
        super.setUp()
        device = RecordingDeviceIO()
        device.endpoints = [
            0x81: USBEndpointInfo(address: 0x81, transferType: .bulk, maxPacketSize: 512, interfaceNumber: 0),
            0x02: USBEndpointInfo(address: 0x02, transferType: .bulk, maxPacketSize: 512, interfaceNumber: 0),
            0x83: USBEndpointInfo(address: 0x83, transferType: .isochronous, maxPacketSize: 192, interfaceNumber: 1),
            0x03: USBEndpointInfo(address: 0x03, transferType: .isochronous, maxPacketSize: 192, interfaceNumber: 1)
        ]
        replies = ReplyLog()
        let log = replies!
        attachment = USBIPAttachment(busid: "1-1", io: device, maxTransferSize: 1 << 20) { log.append($0) }
    }

    // MARK: - Helpers

    private func setup(_ bytes: [UInt8]) -> Data { Data(bytes) }

    private func submit(_ seqnum: UInt32, ep: UInt32, direction: UInt32, length: UInt32, flags: UInt32 = 0,
                        setup: Data = Data(count: 8), payload: Data? = nil,
                        packets: [USBIPIsoPacketDescriptor] = []) {
        let request = USBIPSubmitRequest(
            seqnum: seqnum, devid: 0x0001_0001, direction: direction, ep: ep, transferFlags: flags,
            transferBufferLength: length, numberOfPackets: UInt32(packets.count), setup: setup,
            transferBuffer: payload, isoPackets: packets)
        attachment.handle(try! request.encode())
        attachment.waitUntilProcessed()
    }

    private func unlink(_ seqnum: UInt32, target: UInt32) {
        let request = USBIPUnlinkRequest(seqnum: seqnum, unlinkSeqnum: target, devid: 0x0001_0001, direction: 0, ep: 0)
        attachment.handle(try! request.encode())
        attachment.waitUntilProcessed()
    }

    // MARK: - Control endpoint

    func testControlReadIsQueuedAndAnswered() {
        submit(1, ep: 0, direction: 1, length: 18, setup: setup([0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00]))
        XCTAssertEqual(device.pending.count, 1)
        let request = device.pending[0]
        XCTAssertEqual(request.setup?.wLength, 18)

        request.data!.replaceBytes(in: NSRange(location: 0, length: 2), withBytes: [0x12, 0x01])
        request.complete!(kIOReturnSuccess, 18)

        XCTAssertEqual(replies.submits.count, 1)
        XCTAssertEqual(replies.submits[0].status, 0)
        XCTAssertEqual(replies.submits[0].actualLength, 18)
        XCTAssertEqual(replies.submits[0].transferBuffer?.prefix(2), Data([0x12, 0x01]))
    }

    /// The host has to select a configuration itself; a raw SET_CONFIGURATION would
    /// change the device behind its back.
    func testSetConfigurationIsCarriedOutNotForwarded() {
        submit(1, ep: 0, direction: 0, length: 0, setup: setup([0x00, 0x09, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00]))
        XCTAssertEqual(device.configurations, [2])
        XCTAssertTrue(device.pending.isEmpty)
        XCTAssertEqual(replies.submits.map(\.status), [0])
    }

    func testSetInterfaceSelectsTheAlternateSetting() {
        submit(1, ep: 0, direction: 0, length: 0, setup: setup([0x01, 0x0B, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00]))
        XCTAssertEqual(device.alternateSettings, [[1, 1]])
        XCTAssertEqual(replies.submits.map(\.status), [0])
    }

    /// Both sides of the endpoint: the device with the request, the host with a reset of
    /// its own state. Forwarding the request alone left the host's endpoint halted.
    func testClearHaltClearsBothSides() {
        submit(1, ep: 0, direction: 0, length: 0, setup: setup([0x02, 0x01, 0x00, 0x00, 0x81, 0x00, 0x00, 0x00]))
        XCTAssertEqual(device.sentControl.map(\.wIndex), [0x81])
        XCTAssertEqual(device.clearedHalts, [0x81])
        XCTAssertEqual(replies.submits.map(\.status), [0])
    }

    func testClearHaltRefusedByTheDeviceIsReported() {
        device.controlResult = USBIOReturn.pipeStalled
        submit(1, ep: 0, direction: 0, length: 0, setup: setup([0x02, 0x01, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00]))
        XCTAssertTrue(device.clearedHalts.isEmpty)
        XCTAssertEqual(replies.submits.map(\.status), [-32])
    }

    func testSetAddressIsAnsweredWithoutAction() {
        submit(1, ep: 0, direction: 0, length: 0, setup: setup([0x00, 0x05, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00]))
        XCTAssertTrue(device.pending.isEmpty)
        XCTAssertTrue(device.sentControl.isEmpty)
        XCTAssertEqual(replies.submits.map(\.status), [0])
    }

    // MARK: - Bulk

    func testStallIsReportedAsEPIPE() {
        submit(1, ep: 1, direction: 1, length: 512)
        device.pending[0].complete!(USBIOReturn.pipeStalled, 0)
        XCTAssertEqual(replies.submits.map(\.status), [-32])
        // A stall is the client's to clear.
        XCTAssertTrue(device.clearedHalts.isEmpty)
    }

    /// Transaction errors halt IOUSBHost's endpoint, and a Linux client expects its host
    /// controller to have reset that already.
    func testTransactionErrorResetsTheHostSide() {
        submit(1, ep: 1, direction: 1, length: 512)
        device.pending[0].complete!(USBIOReturn.crcError, 0)
        attachment.waitUntilProcessed()
        XCTAssertEqual(replies.submits.map(\.status), [-84])
        XCTAssertEqual(device.clearedHalts, [0x81])
    }

    func testShortReadWithShortNotOKIsEREMOTEIO() {
        submit(1, ep: 1, direction: 1, length: 512, flags: URBTransferFlags.shortNotOK)
        device.pending[0].complete!(kIOReturnSuccess, 13)
        XCTAssertEqual(replies.submits.map(\.status), [-121])
        XCTAssertEqual(replies.submits.first?.actualLength, 13)
    }

    func testShortReadIsOtherwiseSuccess() {
        submit(1, ep: 1, direction: 1, length: 512)
        device.pending[0].complete!(kIOReturnSuccess, 13)
        XCTAssertEqual(replies.submits.map(\.status), [0])
        XCTAssertEqual(replies.submits.first?.transferBuffer?.count, 13)
    }

    /// URB_ZERO_PACKET on a write that fills its last packet: the zero-length packet is
    /// queued straight after it, and the URB completes when both have.
    func testZeroPacketFollowsAFullWrite() {
        submit(1, ep: 2, direction: 0, length: 512, flags: URBTransferFlags.zeroPacket,
               payload: Data(repeating: 0x5A, count: 512))
        XCTAssertEqual(device.pending.count, 2)
        XCTAssertEqual(device.pending[0].data?.length, 512)
        XCTAssertNil(device.pending[1].data)

        device.pending[0].complete!(kIOReturnSuccess, 512)
        XCTAssertTrue(replies.submits.isEmpty)
        device.pending[1].complete!(kIOReturnSuccess, 0)
        XCTAssertEqual(replies.submits.map(\.status), [0])
        XCTAssertEqual(replies.submits.first?.actualLength, 512)
    }

    func testUnknownEndpointIsENOENT() {
        submit(1, ep: 5, direction: 1, length: 64)
        XCTAssertTrue(device.pending.isEmpty)
        XCTAssertEqual(replies.submits.map(\.status), [-2])
    }

    func testOversizedTransferIsRefused() {
        submit(1, ep: 1, direction: 1, length: 2 << 20)
        XCTAssertTrue(device.pending.isEmpty)
        XCTAssertEqual(replies.submits.map(\.status), [-22])
    }

    // MARK: - Unlink

    /// A withdrawn request is answered by RET_UNLINK alone, once the abort has taken.
    func testUnlinkAbortsAndAnswersWithUnlinkOnly() {
        submit(1, ep: 1, direction: 1, length: 512)
        unlink(2, target: 1)
        XCTAssertEqual(device.aborted, [0x81])
        XCTAssertTrue(replies.all.isEmpty, "nothing is said until the abort completes")

        device.pending[0].complete!(USBIOReturn.aborted, 0)
        XCTAssertTrue(replies.submits.isEmpty)
        XCTAssertEqual(replies.unlinks.map(\.seqnum), [2])
        XCTAssertEqual(replies.unlinks.map(\.status), [-104])
    }

    func testUnlinkOfAnAnsweredRequestSaysZero() {
        submit(1, ep: 1, direction: 1, length: 512)
        device.pending[0].complete!(kIOReturnSuccess, 512)
        unlink(2, target: 1)
        XCTAssertTrue(device.aborted.isEmpty)
        XCTAssertEqual(replies.unlinks.map(\.status), [0])
    }

    /// IOUSBHost aborts the whole endpoint. A request that was not withdrawn still gets
    /// its RET_SUBMIT, with the status Linux uses for an unlink.
    func testOtherRequestsCaughtInAnAbortAreECONNRESET() {
        submit(1, ep: 1, direction: 1, length: 512)
        submit(2, ep: 1, direction: 1, length: 512)
        unlink(3, target: 1)
        device.pending[0].complete!(USBIOReturn.aborted, 0)
        device.pending[1].complete!(USBIOReturn.aborted, 0)

        XCTAssertEqual(replies.unlinks.map(\.seqnum), [3])
        XCTAssertEqual(replies.submits.map(\.seqnum), [2])
        XCTAssertEqual(replies.submits.map(\.status), [-104])
    }

    func testControlUnlinkAbortsControlRequests() {
        submit(1, ep: 0, direction: 1, length: 4, setup: setup([0xC0, 0x01, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00]))
        unlink(2, target: 1)
        XCTAssertEqual(device.controlAborts, 1)
    }

    // MARK: - Isochronous

    /// The reply carries the received bytes back to back and a descriptor per packet,
    /// each with its own status.
    func testIsochronousReadIsCompactedInTheReply() {
        let packets = [USBIPIsoPacketDescriptor(offset: 0, length: 4),
                       USBIPIsoPacketDescriptor(offset: 4, length: 4),
                       USBIPIsoPacketDescriptor(offset: 8, length: 4)]
        submit(1, ep: 3, direction: 1, length: 12, flags: 0x2, packets: packets)
        let request = device.pending[0]
        XCTAssertEqual(request.transactions.map(\.offset), [0, 4, 8])
        XCTAssertEqual(request.transactions.map(\.requestCount), [4, 4, 4])

        request.data!.replaceBytes(in: NSRange(location: 0, length: 12),
                                   withBytes: [1, 2, 0, 0, 9, 9, 9, 9, 5, 6, 7, 8])
        var done = request.transactions
        done[0].completeCount = 2
        done[1].status = USBIOReturn.notSent1Error
        done[2].completeCount = 4
        request.completeIsochronous!(kIOReturnSuccess, done)

        guard let reply = replies.submits.first else { return XCTFail("no reply") }
        XCTAssertEqual(reply.status, 0)
        XCTAssertEqual(reply.actualLength, 6)
        XCTAssertEqual(reply.errorCount, 1)
        XCTAssertEqual(reply.transferBuffer, Data([1, 2, 5, 6, 7, 8]))
        XCTAssertEqual(reply.isoPackets.map(\.actualLength), [2, 0, 4])
        XCTAssertEqual(reply.isoPackets.map(\.status), [0, -18, 0])
        XCTAssertEqual(reply.isoPackets.map(\.offset), [0, 4, 8])
    }

    /// OUT packets are gathered from wherever the client put them.
    func testIsochronousWriteIsGatheredFromTheClientsOffsets() {
        let payload = Data([1, 2, 0xEE, 0xEE, 3, 4])
        let packets = [USBIPIsoPacketDescriptor(offset: 0, length: 2),
                       USBIPIsoPacketDescriptor(offset: 4, length: 2)]
        submit(1, ep: 3, direction: 0, length: 6, payload: payload, packets: packets)
        let request = device.pending[0]
        XCTAssertEqual(request.transactions.map(\.offset), [0, 2])
        XCTAssertEqual(Data(bytes: request.data!.bytes, count: request.data!.length), Data([1, 2, 3, 4]))
    }

    // MARK: - Lifetime

    func testCloseGivesTheDeviceBackAndSilencesLateCompletions() {
        submit(1, ep: 1, direction: 1, length: 512)
        attachment.close()
        attachment.waitUntilProcessed()
        XCTAssertTrue(device.closed)

        device.pending[0].complete!(USBIOReturn.aborted, 0)
        XCTAssertTrue(replies.all.isEmpty)
    }
}

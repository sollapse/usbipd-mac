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

/// Replies the attachment sent, decoded, in the order they were sent.
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

    /// Commands in order: 3 for RET_SUBMIT, 4 for RET_UNLINK, with the seqnum.
    var sequence: [String] {
        all.map { "\($0[3] == 0x03 ? "submit" : "unlink") \(UInt32($0[4]) << 24 | UInt32($0[5]) << 16 | UInt32($0[6]) << 8 | UInt32($0[7]))" }
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

    private func submit(_ seqnum: UInt32, ep: UInt32, direction: UInt32, length: UInt32, flags: UInt32 = 0,
                        setup: [UInt8] = [UInt8](repeating: 0, count: 8), payload: Data? = nil,
                        packets: [USBIPIsoPacketDescriptor] = []) {
        let request = USBIPSubmitRequest(
            seqnum: seqnum, devid: 0x0001_0001, direction: direction, ep: ep, transferFlags: flags,
            transferBufferLength: length, numberOfPackets: UInt32(packets.count), setup: Data(setup),
            transferBuffer: payload, isoPackets: packets)
        attachment.handle(try! request.encode())
        attachment.waitUntilProcessed()
    }

    private func unlink(_ seqnum: UInt32, target: UInt32) {
        let request = USBIPUnlinkRequest(seqnum: seqnum, unlinkSeqnum: target, devid: 0x0001_0001, direction: 0, ep: 0)
        attachment.handle(try! request.encode())
        attachment.waitUntilProcessed()
    }

    /// Complete a queued transfer the way IOUSBHost would, and let the attachment act.
    private func complete(_ index: Int, _ result: IOReturn, _ transferred: Int) {
        device.pending[index].complete!(result, transferred)
        attachment.waitUntilProcessed()
    }

    private func fill(_ data: NSMutableData?, _ bytes: [UInt8]) {
        data!.replaceBytes(in: NSRange(location: 0, length: bytes.count), withBytes: bytes)
    }

    // MARK: - Control endpoint

    func testControlReadIsQueuedAndAnswered() {
        submit(1, ep: 0, direction: 1, length: 18, setup: [0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00])
        XCTAssertEqual(device.pending.count, 1)
        XCTAssertEqual(device.pending[0].setup?.wLength, 18)

        fill(device.pending[0].data, [0x12, 0x01])
        complete(0, kIOReturnSuccess, 18)

        XCTAssertEqual(replies.submits.count, 1)
        XCTAssertEqual(replies.submits[0].status, 0)
        XCTAssertEqual(replies.submits[0].actualLength, 18)
        XCTAssertEqual(replies.submits[0].transferBuffer?.prefix(2), Data([0x12, 0x01]))
    }

    /// The host has to select a configuration itself; a raw SET_CONFIGURATION would
    /// change the device behind its back.
    func testSetConfigurationIsCarriedOutNotForwarded() {
        submit(1, ep: 0, direction: 0, length: 0, setup: [0x00, 0x09, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(device.configurations, [2])
        XCTAssertTrue(device.pending.isEmpty)
        XCTAssertEqual(replies.submits.map(\.status), [0])
    }

    func testSetInterfaceSelectsTheAlternateSetting() {
        submit(1, ep: 0, direction: 0, length: 0, setup: [0x01, 0x0B, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00])
        XCTAssertEqual(device.alternateSettings, [[1, 1]])
        XCTAssertEqual(replies.submits.map(\.status), [0])
    }

    /// Both sides of the endpoint: the device with the request, the host with a reset of
    /// its own state. Forwarding the request alone left the host's endpoint halted.
    func testClearHaltClearsBothSides() {
        submit(1, ep: 0, direction: 0, length: 0, setup: [0x02, 0x01, 0x00, 0x00, 0x81, 0x00, 0x00, 0x00])
        XCTAssertEqual(device.sentControl.map(\.wIndex), [0x81])
        XCTAssertEqual(device.clearedHalts, [0x81])
        XCTAssertEqual(replies.submits.map(\.status), [0])
    }

    func testClearHaltRefusedByTheDeviceIsReported() {
        device.controlResult = USBIOReturn.pipeStalled
        submit(1, ep: 0, direction: 0, length: 0, setup: [0x02, 0x01, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00])
        XCTAssertTrue(device.clearedHalts.isEmpty)
        XCTAssertEqual(replies.submits.map(\.status), [-32])
    }

    func testSetAddressIsAnsweredWithoutAction() {
        submit(1, ep: 0, direction: 0, length: 0, setup: [0x00, 0x05, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertTrue(device.pending.isEmpty)
        XCTAssertTrue(device.sentControl.isEmpty)
        XCTAssertEqual(replies.submits.map(\.status), [0])
    }

    // MARK: - Bulk

    func testStallIsReportedAsEPIPE() {
        submit(1, ep: 1, direction: 1, length: 512)
        complete(0, USBIOReturn.pipeStalled, 0)
        XCTAssertEqual(replies.submits.map(\.status), [-32])
        // A stall is the client's to clear.
        XCTAssertTrue(device.clearedHalts.isEmpty)
    }

    /// Transaction errors halt IOUSBHost's endpoint, and a Linux client expects its host
    /// controller to have reset that already. Requests queued behind the failed one are
    /// aborted by the reset and queued again.
    func testTransactionErrorResetsTheHostSideAndKeepsTheRest() {
        submit(1, ep: 1, direction: 1, length: 512)
        submit(2, ep: 1, direction: 1, length: 512)
        complete(0, USBIOReturn.crcError, 0)
        XCTAssertEqual(replies.submits.map(\.status), [-84])
        XCTAssertEqual(device.clearedHalts, [0x81])

        // The reset aborted the second request; it goes back to the device rather than
        // being reported as unlinked.
        complete(1, USBIOReturn.aborted, 0)
        XCTAssertEqual(device.pending.count, 3)
        XCTAssertEqual(replies.submits.count, 1)

        complete(2, kIOReturnSuccess, 512)
        XCTAssertEqual(replies.submits.map(\.seqnum), [1, 2])
        XCTAssertEqual(replies.submits.last?.status, 0)
    }

    /// A refusal by the software never reached the bus, so nothing is reset for it.
    func testSoftwareRefusalDoesNotResetTheEndpoint() {
        submit(1, ep: 1, direction: 1, length: 512)
        complete(0, USBIOReturn.badArgument, 0)
        XCTAssertTrue(device.clearedHalts.isEmpty)
    }

    func testShortReadWithShortNotOKIsEREMOTEIO() {
        submit(1, ep: 1, direction: 1, length: 512, flags: URBTransferFlags.shortNotOK)
        complete(0, kIOReturnSuccess, 13)
        XCTAssertEqual(replies.submits.map(\.status), [-121])
        XCTAssertEqual(replies.submits.first?.actualLength, 13)
    }

    func testShortReadIsOtherwiseSuccess() {
        submit(1, ep: 1, direction: 1, length: 512)
        complete(0, kIOReturnSuccess, 13)
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

        complete(0, kIOReturnSuccess, 512)
        XCTAssertTrue(replies.submits.isEmpty)
        complete(1, kIOReturnSuccess, 0)
        XCTAssertEqual(replies.submits.map(\.status), [0])
        XCTAssertEqual(replies.submits.first?.actualLength, 512)
    }

    /// If the data part fails, the packet behind it sits on a halted endpoint; the
    /// client hears about the failure at once rather than when it gives up.
    func testZeroPacketWriteFailingIsAnsweredAtOnce() {
        submit(1, ep: 2, direction: 0, length: 512, flags: URBTransferFlags.zeroPacket,
               payload: Data(repeating: 0x5A, count: 512))
        complete(0, USBIOReturn.pipeStalled, 0)
        XCTAssertEqual(replies.submits.map(\.status), [-32])

        // The packet's own completion, when the halt is cleared, says nothing more.
        complete(1, USBIOReturn.aborted, 0)
        XCTAssertEqual(replies.all.count, 1)
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

        complete(0, USBIOReturn.aborted, 0)
        XCTAssertTrue(replies.submits.isEmpty)
        XCTAssertEqual(replies.unlinks.map(\.seqnum), [2])
        XCTAssertEqual(replies.unlinks.map(\.status), [-104])
    }

    /// A request answered before its unlink arrives: its RET_SUBMIT goes out first, then
    /// RET_UNLINK with status 0. The other order makes Linux's vhci drop the device.
    func testUnlinkOfAnAnsweredRequestFollowsItsReply() {
        submit(1, ep: 1, direction: 1, length: 512)
        device.pending[0].complete!(kIOReturnSuccess, 512)
        unlink(2, target: 1)
        XCTAssertTrue(device.aborted.isEmpty)
        XCTAssertEqual(replies.sequence, ["submit 1", "unlink 2"])
        XCTAssertEqual(replies.unlinks.map(\.status), [0])
    }

    /// IOUSBHost aborts the whole endpoint. A request caught up in it that the client
    /// did not withdraw goes back to the device, ahead of anything submitted meanwhile.
    func testRequestsCaughtInAnAbortAreQueuedAgainInOrder() {
        submit(1, ep: 1, direction: 1, length: 512)
        submit(2, ep: 1, direction: 1, length: 512)
        unlink(3, target: 1)
        // Arrives while the endpoint drains: held back.
        submit(4, ep: 1, direction: 1, length: 512)
        XCTAssertEqual(device.pending.count, 2)

        complete(0, USBIOReturn.aborted, 0)
        complete(1, USBIOReturn.aborted, 0)

        XCTAssertEqual(replies.sequence, ["unlink 3"])
        XCTAssertEqual(device.pending.count, 4, "2 queued again, then 4")
        complete(2, kIOReturnSuccess, 512)
        complete(3, kIOReturnSuccess, 512)
        XCTAssertEqual(replies.sequence, ["unlink 3", "submit 2", "submit 4"])
    }

    /// The client stopping a stream withdraws every request; nothing is queued again.
    func testWithdrawingEveryRequestQueuesNothingAgain() {
        submit(1, ep: 1, direction: 1, length: 512)
        submit(2, ep: 1, direction: 1, length: 512)
        unlink(3, target: 1)
        unlink(4, target: 2)
        complete(0, USBIOReturn.aborted, 0)
        complete(1, USBIOReturn.aborted, 0)
        XCTAssertEqual(device.pending.count, 2)
        XCTAssertEqual(Set(replies.unlinks.map(\.seqnum)), [3, 4])
        XCTAssertTrue(replies.submits.isEmpty)
    }

    /// A request held back during a drain never reached the device; withdrawing it is
    /// answered straight away.
    func testUnlinkOfAHeldRequestIsAnsweredAtOnce() {
        submit(1, ep: 1, direction: 1, length: 512)
        unlink(2, target: 1)
        submit(3, ep: 1, direction: 1, length: 512)
        unlink(4, target: 3)
        XCTAssertEqual(replies.unlinks.map(\.seqnum), [4])

        complete(0, USBIOReturn.aborted, 0)
        XCTAssertEqual(device.pending.count, 1, "the withdrawn request is not queued")
    }

    /// A completion left over from an attempt that was aborted and queued again is not
    /// taken for the new attempt's.
    func testLateCompletionOfAnEarlierAttemptIsIgnored() {
        submit(1, ep: 2, direction: 0, length: 512, flags: URBTransferFlags.zeroPacket,
               payload: Data(repeating: 1, count: 512))
        submit(2, ep: 2, direction: 0, length: 4, payload: Data([1, 2, 3, 4]))
        unlink(3, target: 2)
        // The abort takes the data part of 1 first; 1 is set aside to go again.
        complete(0, USBIOReturn.aborted, 0)
        // 2's abort ends the drain, and 1 is queued again (pending 3 and 4).
        complete(2, USBIOReturn.aborted, 0)
        XCTAssertEqual(device.pending.count, 5)

        // Now the first attempt's zero-length packet reports in, late.
        complete(1, USBIOReturn.aborted, 0)
        XCTAssertEqual(replies.sequence, ["unlink 3"])

        complete(3, kIOReturnSuccess, 512)
        complete(4, kIOReturnSuccess, 0)
        XCTAssertEqual(replies.sequence, ["unlink 3", "submit 1"])
    }

    func testControlUnlinkAbortsControlRequests() {
        submit(1, ep: 0, direction: 1, length: 4, setup: [0xC0, 0x01, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00])
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

        fill(request.data, [1, 2, 0, 0, 9, 9, 9, 9, 5, 6, 7, 8])
        var done = request.transactions
        done[0].completeCount = 2
        done[1].status = USBIOReturn.notSent1Error
        done[2].completeCount = 4
        request.completeIsochronous!(kIOReturnSuccess, done)
        attachment.waitUntilProcessed()

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

    /// Packet lengths whose sum overflows 32 bits are refused, not trapped on.
    func testIsochronousLengthsThatOverflowAreRefused() {
        let packets = (0..<3).map { _ in USBIPIsoPacketDescriptor(offset: 0, length: 0xFFFF_FFFF) }
        submit(1, ep: 3, direction: 1, length: 0, packets: packets)
        XCTAssertTrue(device.pending.isEmpty)
        XCTAssertEqual(replies.submits.map(\.status), [-22])
    }

    // MARK: - Lifetime

    /// Closing gives the device back before it returns, and silences late completions.
    func testCloseGivesTheDeviceBackAndSilencesLateCompletions() {
        submit(1, ep: 1, direction: 1, length: 512)
        attachment.close()
        XCTAssertTrue(device.closed)

        complete(0, USBIOReturn.aborted, 0)
        XCTAssertTrue(replies.all.isEmpty)
    }
}

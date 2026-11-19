// USBIPStreamFramerTests.swift
// TCP delivers bytes; the server has to find the messages in them.

import XCTest
@testable import USBIPDCore
@testable import Common

final class USBIPStreamFramerTests: XCTestCase {

    // MARK: - Builders

    private func submit(seqnum: UInt32, direction: UInt32, ep: UInt32 = 1, length: UInt32,
                        packets: UInt32 = 0, payload: Data? = nil) throws -> Data {
        return try USBIPSubmitRequest(
            seqnum: seqnum, devid: 0x0001_0002, direction: direction, ep: ep,
            transferFlags: 0, transferBufferLength: length, numberOfPackets: packets,
            transferBuffer: payload
        ).encode()
    }

    private func unlink(seqnum: UInt32, target: UInt32) throws -> Data {
        return try USBIPUnlinkRequest(seqnum: seqnum, unlinkSeqnum: target, devid: 0x0001_0002,
                                      direction: 0, ep: 0).encode()
    }

    private func drain(_ framer: inout USBIPStreamFramer, attached: Bool) throws -> [Data] {
        var messages: [Data] = []
        while let message = try framer.nextMessage(attached: attached) {
            messages.append(message)
        }
        return messages
    }

    // MARK: - Handshake

    func testDeviceListRequestIsTheHeaderAlone() throws {
        var framer = USBIPStreamFramer()
        framer.append(try DeviceListRequest().encode())
        let messages = try drain(&framer, attached: false)
        XCTAssertEqual(messages.map(\.count), [8])
        XCTAssertEqual(framer.bufferedByteCount, 0)
    }

    func testImportRequestCarriesItsBusid() throws {
        var framer = USBIPStreamFramer()
        let request = try DeviceImportRequest(busID: "1-1").encode()
        framer.append(request.prefix(20))
        XCTAssertNil(try framer.nextMessage(attached: false), "half an import is not a message")
        framer.append(request.suffix(from: 20))
        XCTAssertEqual(try framer.nextMessage(attached: false), request)
    }

    func testUnknownHandshakeCodeIsRejected() {
        var framer = USBIPStreamFramer()
        framer.append(Data([0x01, 0x11, 0x12, 0x34, 0, 0, 0, 0]))
        XCTAssertThrowsError(try framer.nextMessage(attached: false)) { error in
            XCTAssertEqual(error as? USBIPStreamFramer.FramingError, .unknownHandshakeCode(0x1234))
        }
    }

    // MARK: - URB traffic

    /// A read that carries several messages must yield all of them. The connection used
    /// to treat each read as one message and lost every one after the first.
    func testSeveralMessagesInOneRead() throws {
        let first = try submit(seqnum: 1, direction: 1, length: 512)
        let second = try submit(seqnum: 2, direction: 0, length: 4, payload: Data([1, 2, 3, 4]))
        let third = try unlink(seqnum: 3, target: 1)

        var framer = USBIPStreamFramer()
        framer.append(first + second + third)
        let messages = try drain(&framer, attached: true)
        XCTAssertEqual(messages, [first, second, third])
    }

    /// A bulk OUT larger than one read arrives in pieces and must be reassembled.
    func testOutPayloadSplitAcrossReads() throws {
        let payload = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0) })
        let message = try submit(seqnum: 7, direction: 0, length: UInt32(payload.count), payload: payload)

        var framer = USBIPStreamFramer()
        var received: [Data] = []
        var offset = 0
        while offset < message.count {
            let end = min(offset + 65_536, message.count)
            framer.append(message.subdata(in: offset..<end))
            received += try drain(&framer, attached: true)
            offset = end
        }
        XCTAssertEqual(received, [message])
    }

    /// An IN request carries no data, whatever its transfer_buffer_length says.
    func testInRequestHasNoPayload() throws {
        let message = try submit(seqnum: 1, direction: 1, length: 4096)
        var framer = USBIPStreamFramer()
        framer.append(message)
        XCTAssertEqual(try framer.nextMessage(attached: true)?.count, 48)
    }

    /// Isochronous requests end with 16 bytes per packet descriptor: after the data
    /// for OUT, directly after the header for IN.
    func testIsochronousDescriptorsAreCounted() throws {
        var framer = USBIPStreamFramer()

        var inRequest = try submit(seqnum: 1, direction: 1, ep: 2, length: 3 * 192, packets: 3)
        inRequest.append(Data(count: 3 * 16))
        framer.append(inRequest)
        XCTAssertEqual(try framer.nextMessage(attached: true), inRequest)

        var outRequest = try submit(seqnum: 2, direction: 0, ep: 2, length: 8, packets: 2,
                                    payload: Data(repeating: 0xAB, count: 8))
        outRequest.append(Data(count: 2 * 16))
        framer.append(outRequest)
        XCTAssertEqual(try framer.nextMessage(attached: true), outRequest)
    }

    /// number_of_packets of 0xffffffff marks a transfer that is not isochronous.
    func testAllOnesPacketCountMeansNoDescriptors() throws {
        let message = try submit(seqnum: 1, direction: 1, length: 64, packets: 0xFFFF_FFFF)
        var framer = USBIPStreamFramer()
        framer.append(message + message)
        XCTAssertEqual(try drain(&framer, attached: true).count, 2)
    }

    func testUnknownCommandIsRejected() {
        var framer = USBIPStreamFramer()
        var bogus = Data(count: 48)
        bogus[3] = 0x09
        framer.append(bogus)
        XCTAssertThrowsError(try framer.nextMessage(attached: true)) { error in
            XCTAssertEqual(error as? USBIPStreamFramer.FramingError, .unknownCommand(9))
        }
    }

    func testOversizedMessageIsRejected() throws {
        var framer = USBIPStreamFramer(maxMessageSize: 1024)
        framer.append(try submit(seqnum: 1, direction: 0, length: 4096).prefix(48))
        XCTAssertThrowsError(try framer.nextMessage(attached: true)) { error in
            XCTAssertEqual(error as? USBIPStreamFramer.FramingError, .messageTooLarge(48 + 4096))
        }
    }

    func testTooManyIsoPacketsIsRejected() throws {
        var framer = USBIPStreamFramer()
        framer.append(try submit(seqnum: 1, direction: 1, length: 0, packets: 1025))
        XCTAssertThrowsError(try framer.nextMessage(attached: true)) { error in
            XCTAssertEqual(error as? USBIPStreamFramer.FramingError, .tooManyIsoPackets(1025))
        }
    }

    /// Consumed bytes are dropped as the stream goes on, so a long-lived connection does
    /// not keep everything it ever received.
    func testBufferDoesNotGrowWithTraffic() throws {
        let message = try submit(seqnum: 1, direction: 0, length: 1000, payload: Data(count: 1000))
        var framer = USBIPStreamFramer()
        for _ in 0..<500 {
            framer.append(message)
            _ = try drain(&framer, attached: true)
        }
        XCTAssertEqual(framer.bufferedByteCount, 0)
    }
}

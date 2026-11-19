// USBIPIsoPacketTests.swift
// Isochronous SUBMIT messages end with one 16-byte descriptor per packet.

import XCTest
@testable import USBIPDCore
@testable import Common

final class USBIPIsoPacketTests: XCTestCase {

    func testDescriptorWireLayout() throws {
        let packet = USBIPIsoPacketDescriptor(offset: 0x0102_0304, length: 192, actualLength: 188, status: -18)
        let encoded = packet.encode()
        XCTAssertEqual(encoded.count, 16)
        XCTAssertEqual(Array(encoded.prefix(4)), [0x01, 0x02, 0x03, 0x04])
        XCTAssertEqual(try USBIPIsoPacketDescriptor.decode(from: encoded, at: 0), packet)
    }

    /// An isochronous IN request carries no data: its descriptors follow the header
    /// directly. They used to be read as the transfer buffer.
    func testInRequestDescriptorsFollowTheHeader() throws {
        let packets = (0..<3).map { USBIPIsoPacketDescriptor(offset: UInt32($0 * 192), length: 192) }
        let request = USBIPSubmitRequest(
            seqnum: 9, devid: 1, direction: 1, ep: 3, transferFlags: 0x2,
            transferBufferLength: 576, numberOfPackets: 3, isoPackets: packets
        )
        let encoded = try request.encode()
        XCTAssertEqual(encoded.count, 48 + 3 * 16)

        let decoded = try USBIPSubmitRequest.decode(from: encoded)
        XCTAssertNil(decoded.transferBuffer)
        XCTAssertEqual(decoded.isoPackets, packets)
    }

    func testOutRequestDescriptorsFollowTheData() throws {
        let payload = Data((0..<8).map { UInt8($0) })
        let packets = [USBIPIsoPacketDescriptor(offset: 0, length: 4),
                       USBIPIsoPacketDescriptor(offset: 4, length: 4)]
        let request = USBIPSubmitRequest(
            seqnum: 10, devid: 1, direction: 0, ep: 3, transferFlags: 0,
            transferBufferLength: 8, numberOfPackets: 2, transferBuffer: payload, isoPackets: packets
        )
        let decoded = try USBIPSubmitRequest.decode(from: try request.encode())
        XCTAssertEqual(decoded.transferBuffer, payload)
        XCTAssertEqual(decoded.isoPackets, packets)
    }

    /// The reply carries the IN packets back to back, then the descriptors saying where
    /// each belongs and how much of it arrived.
    func testResponseCarriesCompactedDataThenDescriptors() throws {
        let packets = [USBIPIsoPacketDescriptor(offset: 0, length: 192, actualLength: 2, status: 0),
                       USBIPIsoPacketDescriptor(offset: 192, length: 192, actualLength: 1, status: 0)]
        let response = USBIPSubmitResponse(
            seqnum: 9, devid: 1, direction: 1, ep: 3, status: 0, actualLength: 3,
            numberOfPackets: 2, errorCount: 0, transferBuffer: Data([0xA, 0xB, 0xC]), isoPackets: packets
        )
        let encoded = try response.encode()
        XCTAssertEqual(encoded.count, 48 + 3 + 2 * 16)

        let decoded = try USBIPSubmitResponse.decode(from: encoded)
        XCTAssertEqual(decoded.transferBuffer, Data([0xA, 0xB, 0xC]))
        XCTAssertEqual(decoded.isoPackets, packets)
    }

    /// A request that names packets but was cut short decodes without them, so its
    /// header can still be read.
    func testMissingDescriptorsDecodeAsNone() throws {
        let request = USBIPSubmitRequest(seqnum: 1, devid: 1, direction: 1, ep: 3, transferFlags: 0,
                                         transferBufferLength: 1024, numberOfPackets: 10)
        let decoded = try USBIPSubmitRequest.decode(from: try request.encode())
        XCTAssertEqual(decoded.numberOfPackets, 10)
        XCTAssertTrue(decoded.isoPackets.isEmpty)
    }
}

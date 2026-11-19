// USBIPDeviceListInterfaceTests.swift
// A device list follows each device with its interfaces' class triples.

import XCTest
@testable import USBIPDCore
@testable import Common

final class USBIPDeviceListInterfaceTests: XCTestCase {

    private func device(interfaceCount: UInt8, interfaces: [USBIPExportedInterface]) -> USBIPExportedDevice {
        return USBIPExportedDevice(
            path: "/sys/devices/1-1", busID: "1-1", busnum: 1, devnum: 1, speed: 3,
            vendorID: 0x18A5, productID: 0x0428, bcdDevice: 0x01CD,
            deviceClass: 0, deviceSubClass: 0, deviceProtocol: 0,
            configurationCount: 1, configurationValue: 1, interfaceCount: interfaceCount,
            interfaces: interfaces)
    }

    func testInterfacesFollowTheDeviceRecord() throws {
        let interfaces = [USBIPExportedInterface(interfaceClass: 0x08, interfaceSubClass: 0x06, interfaceProtocol: 0x50),
                          USBIPExportedInterface(interfaceClass: 0xFF, interfaceSubClass: 0x00, interfaceProtocol: 0x00)]
        let response = DeviceListResponse(devices: [device(interfaceCount: 2, interfaces: interfaces)])
        let encoded = try response.encode()

        // op_common, ndev, one device record, two interface records.
        XCTAssertEqual(encoded.count, 8 + 4 + 312 + 2 * 4)
        XCTAssertEqual(Array(encoded[(8 + 4 + 312)...]), [0x08, 0x06, 0x50, 0x00, 0xFF, 0x00, 0x00, 0x00])

        let decoded = try DeviceListResponse.decode(from: encoded)
        XCTAssertEqual(decoded.devices.first?.interfaces, interfaces)
        XCTAssertEqual(decoded.devices.first?.bcdDevice, 0x01CD)
    }

    /// Without interface details the records are still written, as zeros, so the
    /// stream keeps its shape.
    func testUnknownInterfacesAreWrittenAsZeros() throws {
        let response = DeviceListResponse(devices: [device(interfaceCount: 1, interfaces: [])])
        let encoded = try response.encode()
        XCTAssertEqual(encoded.count, 8 + 4 + 312 + 4)
        XCTAssertEqual(Array(encoded.suffix(4)), [0, 0, 0, 0])
    }
}

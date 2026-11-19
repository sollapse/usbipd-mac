// USBSpeedWireValueTests.swift
// The speed USB/IP carries is Linux's enum usb_device_speed, not this project's enum.

import XCTest
@testable import USBIPDCore
@testable import Common

final class USBSpeedWireValueTests: XCTestCase {

    /// USB_SPEED_WIRELESS is 4 in Linux, so SuperSpeed is 5 and SuperSpeed+ is 6.
    /// Sending 4 for SuperSpeed made a Linux client attach the device as Wireless USB
    /// on vhci's high-speed hub.
    func testWireValuesFollowLinux() {
        XCTAssertEqual(USBSpeed.unknown.usbipSpeed, 0)
        XCTAssertEqual(USBSpeed.low.usbipSpeed, 1)
        XCTAssertEqual(USBSpeed.full.usbipSpeed, 2)
        XCTAssertEqual(USBSpeed.high.usbipSpeed, 3)
        XCTAssertEqual(USBSpeed.superSpeed.usbipSpeed, 5)
        XCTAssertEqual(USBSpeed.superSpeedPlus.usbipSpeed, 6)
    }

    /// IOKit's "Device Speed" runs kUSBDeviceSpeedLow (0) to kUSBDeviceSpeedSuperPlusBy2
    /// (5). The two SuperSpeed+ values used to read as unknown.
    func testIOKitDeviceSpeedValues() {
        XCTAssertEqual(USBSpeed(ioKitDeviceSpeed: 0), .low)
        XCTAssertEqual(USBSpeed(ioKitDeviceSpeed: 1), .full)
        XCTAssertEqual(USBSpeed(ioKitDeviceSpeed: 2), .high)
        XCTAssertEqual(USBSpeed(ioKitDeviceSpeed: 3), .superSpeed)
        XCTAssertEqual(USBSpeed(ioKitDeviceSpeed: 4), .superSpeedPlus)
        XCTAssertEqual(USBSpeed(ioKitDeviceSpeed: 5), .superSpeedPlus)
        XCTAssertEqual(USBSpeed(ioKitDeviceSpeed: 9), .unknown)
    }

    /// The device list and the import reply both advertise the wire value.
    func testExportedDeviceCarriesWireSpeed() throws {
        let exported = USBIPExportedDevice(
            path: "/sys/devices/1-1",
            busID: "1-1",
            busnum: 1,
            devnum: 1,
            speed: USBSpeed.superSpeed.usbipSpeed,
            vendorID: 0x1234,
            productID: 0x5678,
            deviceClass: 0,
            deviceSubClass: 0,
            deviceProtocol: 0,
            configurationCount: 1,
            configurationValue: 1,
            interfaceCount: 1
        )
        let encoded = try exported.encode()
        XCTAssertEqual(try EndiannessConverter.readUInt32FromData(encoded, at: 296), 5)
    }
}

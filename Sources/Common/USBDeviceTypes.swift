// USBDeviceTypes.swift
// Common USB device types shared across modules

import Foundation

/// USB device speed enumeration
///
/// The raw values are this project's own numbering. They are not what USB/IP puts on
/// the wire: use `usbipSpeed` for that.
public enum USBSpeed: UInt8, Sendable {
    case unknown = 0
    case low = 1
    case full = 2
    case high = 3
    case superSpeed = 4
    /// SuperSpeed+ at 10 or 20 Gbps (USB 3.1 Gen 2 and USB 3.2 Gen 2x2).
    case superSpeedPlus = 5

    /// The speed as USB/IP carries it: Linux's `enum usb_device_speed`.
    ///
    /// That enumeration has USB_SPEED_WIRELESS at 4, so SuperSpeed is 5 and
    /// SuperSpeed+ is 6. Sending the raw value told every client that a SuperSpeed
    /// device was a Wireless USB one, and a Linux client attached it to vhci's
    /// high-speed hub instead of its SuperSpeed hub.
    public var usbipSpeed: UInt32 {
        switch self {
        case .unknown: return 0
        case .low: return 1
        case .full: return 2
        case .high: return 3
        case .superSpeed: return 5
        case .superSpeedPlus: return 6
        }
    }

    /// The speed IOKit reports in a device's "Device Speed" property
    /// (kUSBDeviceSpeedLow ... kUSBDeviceSpeedSuperPlusBy2).
    public init(ioKitDeviceSpeed value: UInt32) {
        switch value {
        case 0: self = .low
        case 1: self = .full
        case 2: self = .high
        case 3: self = .superSpeed
        case 4, 5: self = .superSpeedPlus
        default: self = .unknown
        }
    }
}

/// Protocol defining USB device information
public protocol USBDeviceInfo {
    var busID: String { get }
    var deviceID: String { get }
    var vendorID: UInt16 { get }
    var productID: UInt16 { get }
    var deviceClass: UInt8 { get }
    var deviceSubClass: UInt8 { get }
    var deviceProtocol: UInt8 { get }
    var speed: USBSpeed { get }
    var manufacturerString: String? { get }
    var productString: String? { get }
    var serialNumberString: String? { get }
}

/// Represents a USB device
public struct USBDevice: USBDeviceInfo, Sendable {
    public let busID: String
    public let deviceID: String
    public let vendorID: UInt16
    public let productID: UInt16
    public let deviceClass: UInt8
    public let deviceSubClass: UInt8
    public let deviceProtocol: UInt8
    public let speed: USBSpeed
    public let manufacturerString: String?
    public let productString: String?
    public let serialNumberString: String?
    
    public init(
        busID: String,
        deviceID: String,
        vendorID: UInt16,
        productID: UInt16,
        deviceClass: UInt8,
        deviceSubClass: UInt8,
        deviceProtocol: UInt8,
        speed: USBSpeed,
        manufacturerString: String?,
        productString: String?,
        serialNumberString: String?
    ) {
        self.busID = busID
        self.deviceID = deviceID
        self.vendorID = vendorID
        self.productID = productID
        self.deviceClass = deviceClass
        self.deviceSubClass = deviceSubClass
        self.deviceProtocol = deviceProtocol
        self.speed = speed
        self.manufacturerString = manufacturerString
        self.productString = productString
        self.serialNumberString = serialNumberString
    }
}
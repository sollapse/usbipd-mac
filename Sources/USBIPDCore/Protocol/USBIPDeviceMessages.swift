// USBIPDeviceMessages.swift
// USB/IP device list and import messages

import Foundation
import Common

/// Device list request message
public struct DeviceListRequest: USBIPMessageCodable {
    public let header: USBIPHeader
    
    public init(header: USBIPHeader = USBIPHeader(command: .requestDeviceList)) {
        self.header = header
    }
    
    public func encode() throws -> Data {
        return try header.encode()
    }
    
    public static func decode(from data: Data) throws -> DeviceListRequest {
        let header = try USBIPHeader.decode(from: data)
        
        guard header.command == .requestDeviceList else {
            throw USBIPProtocolError.invalidMessageFormat
        }
        
        return DeviceListRequest(header: header)
    }
}

/// One `struct usbip_usb_interface`: an interface's class triple, as a device list
/// describes it.
public struct USBIPExportedInterface: Equatable, Sendable {
    public let interfaceClass: UInt8
    public let interfaceSubClass: UInt8
    public let interfaceProtocol: UInt8

    public init(interfaceClass: UInt8, interfaceSubClass: UInt8, interfaceProtocol: UInt8) {
        self.interfaceClass = interfaceClass
        self.interfaceSubClass = interfaceSubClass
        self.interfaceProtocol = interfaceProtocol
    }

    /// Class, subclass, protocol and a padding byte.
    public func encode() -> Data {
        return Data([interfaceClass, interfaceSubClass, interfaceProtocol, 0])
    }
}

/// What the device layer knows about a device beyond what discovery reports: its
/// configuration and its interfaces.
public struct USBIPDeviceDescription: Equatable, Sendable {
    public let bcdDevice: UInt16
    public let configurationCount: UInt8
    public let configurationValue: UInt8
    public let interfaces: [USBIPExportedInterface]

    public init(bcdDevice: UInt16, configurationCount: UInt8, configurationValue: UInt8,
                interfaces: [USBIPExportedInterface]) {
        self.bcdDevice = bcdDevice
        self.configurationCount = configurationCount
        self.configurationValue = configurationValue
        self.interfaces = interfaces
    }
}

/// Exported device information for device list response
public struct USBIPExportedDevice: USBIPMessageCodable {
    public let path: String
    public let busID: String
    public let busnum: UInt32
    public let devnum: UInt32
    public let speed: UInt32
    public let vendorID: UInt16
    public let productID: UInt16
    /// bcdDevice — the device release number. Absent from this struct until 2026-08,
    /// which shifted every byte after idProduct two positions early on the wire.
    public let bcdDevice: UInt16
    public let deviceClass: UInt8
    public let deviceSubClass: UInt8
    public let deviceProtocol: UInt8
    public let configurationCount: UInt8
    public let configurationValue: UInt8
    public let interfaceCount: UInt8
    /// The interfaces a device list follows this record with. When empty, or not
    /// `interfaceCount` long, zeroed records are written in their place.
    public let interfaces: [USBIPExportedInterface]

    public init(
        path: String,
        busID: String,
        busnum: UInt32,
        devnum: UInt32,
        speed: UInt32,
        vendorID: UInt16,
        productID: UInt16,
        bcdDevice: UInt16 = 0,
        deviceClass: UInt8,
        deviceSubClass: UInt8,
        deviceProtocol: UInt8,
        configurationCount: UInt8,
        configurationValue: UInt8,
        interfaceCount: UInt8,
        interfaces: [USBIPExportedInterface] = []
    ) {
        self.interfaces = interfaces
        self.path = path
        self.busID = busID
        self.busnum = busnum
        self.devnum = devnum
        self.speed = speed
        self.vendorID = vendorID
        self.productID = productID
        self.bcdDevice = bcdDevice
        self.deviceClass = deviceClass
        self.deviceSubClass = deviceSubClass
        self.deviceProtocol = deviceProtocol
        self.configurationCount = configurationCount
        self.configurationValue = configurationValue
        self.interfaceCount = interfaceCount
    }
    
    public func encode() throws -> Data {
        var data = Data()
        
        // Path: 256 bytes, null-terminated, padded with zeros
        data.append(try StringEncodingUtilities.encodeFixedLengthString(path, length: 256))
        
        // BusID: 32 bytes, null-terminated, padded with zeros
        data.append(try StringEncodingUtilities.encodeFixedLengthString(busID, length: 32))
        
        // Numeric fields in network byte order (big endian)
        data.append(EndiannessConverter.writeUInt32ToData(busnum))
        data.append(EndiannessConverter.writeUInt32ToData(devnum))
        data.append(EndiannessConverter.writeUInt32ToData(speed))
        data.append(EndiannessConverter.writeUInt16ToData(vendorID))
        data.append(EndiannessConverter.writeUInt16ToData(productID))
        data.append(EndiannessConverter.writeUInt16ToData(bcdDevice))
        data.append(deviceClass)
        data.append(deviceSubClass)
        data.append(deviceProtocol)
        // Order matters and is not alphabetical: bConfigurationValue precedes
        // bNumConfigurations in struct usbip_usb_device.
        data.append(configurationValue)
        data.append(configurationCount)
        data.append(interfaceCount)
        
        return data
    }
    
    public static func decode(from data: Data) throws -> USBIPExportedDevice {
        guard data.count >= 312 else { // 256 + 32 + 24
            throw USBIPProtocolError.invalidDataLength
        }
        
        // Extract path (256 bytes)
        let path = try StringEncodingUtilities.decodeFixedLengthString(from: data, at: 0, length: 256)
        
        // Extract busID (32 bytes)
        let busID = try StringEncodingUtilities.decodeFixedLengthString(from: data, at: 256, length: 32)
        
        // Extract numeric fields
        let busnum = try EndiannessConverter.readUInt32FromData(data, at: 288)
        let devnum = try EndiannessConverter.readUInt32FromData(data, at: 292)
        let speed = try EndiannessConverter.readUInt32FromData(data, at: 296)
        let vendorID = try EndiannessConverter.readUInt16FromData(data, at: 300)
        let productID = try EndiannessConverter.readUInt16FromData(data, at: 302)
        let bcdDevice = try EndiannessConverter.readUInt16FromData(data, at: 304)
        let deviceClass = data[306]
        let deviceSubClass = data[307]
        let deviceProtocol = data[308]
        let configurationValue = data[309]
        let configurationCount = data[310]
        let interfaceCount = data[311]
        
        return USBIPExportedDevice(
            path: path,
            busID: busID,
            busnum: busnum,
            devnum: devnum,
            speed: speed,
            vendorID: vendorID,
            productID: productID,
            bcdDevice: bcdDevice,
            deviceClass: deviceClass,
            deviceSubClass: deviceSubClass,
            deviceProtocol: deviceProtocol,
            configurationCount: configurationCount,
            configurationValue: configurationValue,
            interfaceCount: interfaceCount
        )
    }
}

/// Device list response message
public struct DeviceListResponse: USBIPMessageCodable {
    public let header: USBIPHeader
    public let deviceCount: UInt32
    public let devices: [USBIPExportedDevice]
    
    public init(header: USBIPHeader = USBIPHeader(command: .replyDeviceList), devices: [USBIPExportedDevice]) {
        self.header = header
        self.deviceCount = UInt32(devices.count)
        self.devices = devices
    }
    
    public func encode() throws -> Data {
        var data = try header.encode()
        data.append(EndiannessConverter.writeUInt32ToData(deviceCount))

        // struct op_devlist_reply is just `uint32_t ndev` followed by the device
        // records — there is no padding after the count. Four reserved bytes used to
        // be written here, which pushed the first device record four bytes late and
        // made a real usbip client misparse it.

        for device in devices {
            data.append(try device.encode())

            // Each device record is followed by bNumInterfaces × struct
            // usbip_usb_interface, four bytes each. These were not written at all,
            // so a client that consumed them read into the *next* device's path —
            // visible as interface classes like 2f/73/79, which is ASCII "/sy".
            //
            // When the interfaces are not known they are written as zeros, which a
            // client renders as "(Defined at Interface level)".
            if device.interfaces.count == Int(device.interfaceCount) {
                for interface in device.interfaces {
                    data.append(interface.encode())
                }
            } else {
                for _ in 0..<Int(device.interfaceCount) {
                    data.append(contentsOf: [0 as UInt8, 0, 0, 0])
                }
            }
        }

        return data
    }
    
    public static func decode(from data: Data) throws -> DeviceListResponse {
        guard data.count >= 12 else {
            throw USBIPProtocolError.invalidDataLength
        }
        
        let header = try USBIPHeader.decode(from: data.subdata(in: 0..<8))
        
        guard header.command == .replyDeviceList else {
            throw USBIPProtocolError.invalidMessageFormat
        }
        
        let deviceCount = try EndiannessConverter.readUInt32FromData(data, at: 8)

        var devices: [USBIPExportedDevice] = []
        // Device records begin immediately after ndev — op_devlist_reply has no
        // padding.
        var offset = 12

        for _ in 0..<deviceCount {
            guard data.count >= offset + 312 else {
                throw USBIPProtocolError.invalidDataLength
            }

            let deviceData = data.subdata(in: offset..<(offset + 312))
            let record = try USBIPExportedDevice.decode(from: deviceData)
            offset += 312

            // Then bNumInterfaces × struct usbip_usb_interface, four bytes each.
            let interfaceBytes = Int(record.interfaceCount) * 4
            guard data.count >= offset + interfaceBytes else {
                throw USBIPProtocolError.invalidDataLength
            }
            let interfaces = (0..<Int(record.interfaceCount)).map { index -> USBIPExportedInterface in
                let base = data.startIndex + offset + index * 4
                return USBIPExportedInterface(interfaceClass: data[base], interfaceSubClass: data[base + 1],
                                              interfaceProtocol: data[base + 2])
            }
            offset += interfaceBytes

            devices.append(USBIPExportedDevice(
                path: record.path, busID: record.busID, busnum: record.busnum, devnum: record.devnum,
                speed: record.speed, vendorID: record.vendorID, productID: record.productID,
                bcdDevice: record.bcdDevice, deviceClass: record.deviceClass,
                deviceSubClass: record.deviceSubClass, deviceProtocol: record.deviceProtocol,
                configurationCount: record.configurationCount, configurationValue: record.configurationValue,
                interfaceCount: record.interfaceCount, interfaces: interfaces))
        }
        
        return DeviceListResponse(header: header, devices: devices)
    }
}

/// Device import request message
public struct DeviceImportRequest: USBIPMessageCodable {
    public let header: USBIPHeader
    public let busID: String
    
    public init(header: USBIPHeader = USBIPHeader(command: .requestDeviceImport), busID: String) {
        self.header = header
        self.busID = busID
    }
    
    public func encode() throws -> Data {
        var data = try header.encode()
        
        // BusID: 32 bytes, null-terminated, padded with zeros
        data.append(try StringEncodingUtilities.encodeFixedLengthString(busID, length: 32))
        
        return data
    }
    
    public static func decode(from data: Data) throws -> DeviceImportRequest {
        guard data.count >= 40 else { // 8 + 32
            throw USBIPProtocolError.invalidDataLength
        }
        
        let header = try USBIPHeader.decode(from: data.subdata(in: 0..<8))
        
        guard header.command == .requestDeviceImport else {
            throw USBIPProtocolError.invalidMessageFormat
        }
        
        // Extract busID (32 bytes)
        let busID = try StringEncodingUtilities.decodeFixedLengthString(from: data, at: 8, length: 32)
        
        return DeviceImportRequest(header: header, busID: busID)
    }
}

/// Device import response message (OP_REP_IMPORT)
///
/// `struct op_import_reply` is exactly one `struct usbip_usb_device`, so a successful
/// reply is op_common(8) + 312 bytes. This previously encoded op_common plus a 4-byte
/// returnCode and nothing else — 12 bytes total. A real client reads op_common, sees
/// status OK, then blocks forever waiting for the 312 bytes of device that never
/// arrive. `usbip attach` hung indefinitely against this server.
///
/// The old `returnCode` was also redundant: status already lives in op_common.
public struct DeviceImportResponse: USBIPMessageCodable {
    public let header: USBIPHeader

    /// The imported device. Required when status is 0; omitted on failure, where the
    /// reply is op_common alone.
    public let device: USBIPExportedDevice?

    public init(header: USBIPHeader = USBIPHeader(command: .replyDeviceImport),
                device: USBIPExportedDevice? = nil) {
        self.header = header
        self.device = device
    }

    public func encode() throws -> Data {
        var data = try header.encode()
        // On failure the reply is the header alone — there is no device to describe.
        if header.status == 0, let device = device {
            data.append(try device.encode())
        }
        return data
    }

    public static func decode(from data: Data) throws -> DeviceImportResponse {
        guard data.count >= 8 else {
            throw USBIPProtocolError.invalidDataLength
        }

        let header = try USBIPHeader.decode(from: data.subdata(in: 0..<8))

        guard header.command == .replyDeviceImport else {
            throw USBIPProtocolError.invalidMessageFormat
        }

        guard header.status == 0 else {
            return DeviceImportResponse(header: header, device: nil)
        }

        guard data.count >= 8 + 312 else {
            throw USBIPProtocolError.invalidDataLength
        }
        let device = try USBIPExportedDevice.decode(from: data.subdata(in: 8..<(8 + 312)))
        return DeviceImportResponse(header: header, device: device)
    }
}

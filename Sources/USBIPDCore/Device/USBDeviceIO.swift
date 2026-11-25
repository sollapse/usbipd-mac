// USBDeviceIO.swift
// What an attached USB/IP session needs from a device, and how its results map to USB/IP.

import Foundation
import IOKit

/// An endpoint of the device's current configuration and alternate settings.
public struct USBEndpointInfo: Equatable, Sendable {
    /// bEndpointAddress, direction in bit 7.
    public let address: UInt8
    public let transferType: USBTransferType
    /// Bytes per packet, including the extra transactions of a high-bandwidth endpoint.
    public let maxPacketSize: Int
    /// The interface the endpoint belongs to.
    public let interfaceNumber: UInt8

    public init(address: UInt8, transferType: USBTransferType, maxPacketSize: Int, interfaceNumber: UInt8) {
        self.address = address
        self.transferType = transferType
        self.maxPacketSize = maxPacketSize
        self.interfaceNumber = interfaceNumber
    }
}

/// The eight bytes of a control request's SETUP stage.
public struct USBSetupPacket: Equatable, Sendable {
    public let bmRequestType: UInt8
    public let bRequest: UInt8
    public let wValue: UInt16
    public let wIndex: UInt16
    public let wLength: UInt16

    public init(bmRequestType: UInt8, bRequest: UInt8, wValue: UInt16, wIndex: UInt16, wLength: UInt16) {
        self.bmRequestType = bmRequestType
        self.bRequest = bRequest
        self.wValue = wValue
        self.wIndex = wIndex
        self.wLength = wLength
    }

    /// Parse the setup field of a CMD_SUBMIT. USB puts its fields in little-endian order.
    public init?(_ bytes: Data) {
        guard bytes.count >= 8 else { return nil }
        let b = [UInt8](bytes.prefix(8))
        self.init(
            bmRequestType: b[0],
            bRequest: b[1],
            wValue: UInt16(b[2]) | UInt16(b[3]) << 8,
            wIndex: UInt16(b[4]) | UInt16(b[5]) << 8,
            wLength: UInt16(b[6]) | UInt16(b[7]) << 8
        )
    }

    /// Whether the data stage, if any, runs device to host.
    public var isDeviceToHost: Bool { bmRequestType & 0x80 != 0 }
}

/// One packet of an isochronous transfer, as the device layer schedules it.
public struct USBIsochronousTransaction: Equatable, Sendable {
    /// Bytes requested.
    public var requestCount: UInt32
    /// Where the packet sits in the transfer's buffer.
    public var offset: UInt32
    /// Bytes transferred, filled in on completion.
    public var completeCount: UInt32
    /// The packet's own result, filled in on completion.
    public var status: IOReturn

    public init(requestCount: UInt32, offset: UInt32, completeCount: UInt32 = 0, status: IOReturn = kIOReturnSuccess) {
        self.requestCount = requestCount
        self.offset = offset
        self.completeCount = completeCount
        self.status = status
    }
}

/// What a USB/IP attachment needs from the device it serves.
///
/// IOUSBHostDeviceIO is the real one. The protocol exists so the attachment's
/// handling of USB/IP — which requests it carries out itself, how it tracks and
/// cancels URBs, what it reports — can be tested without hardware.
///
/// Asynchronous requests complete on a queue of the implementation's choosing; the
/// synchronous calls are made from the attachment's own queue.
public protocol USBDeviceIO: AnyObject {
    /// The endpoint with this address in the current configuration and alternate
    /// settings, or nil if there is none.
    func endpoint(_ address: UInt8) -> USBEndpointInfo?

    /// bConfigurationValue of the current configuration, or nil when unconfigured.
    var currentConfiguration: UInt8? { get }

    /// A buffer for a transfer of this many bytes.
    func makeBuffer(length: Int) -> NSMutableData

    /// Hand back a buffer from `makeBuffer` once the transfer that used it has completed
    /// and nothing reads it any more, so it can serve another transfer.
    func recycle(_ buffer: NSMutableData)

    /// Queue a request on the default control endpoint.
    func enqueueControl(_ setup: USBSetupPacket, data: NSMutableData?,
                        completion: @escaping @Sendable (IOReturn, Int) -> Void) throws

    /// Send a request on the default control endpoint and wait for it.
    func sendControl(_ setup: USBSetupPacket, data: NSMutableData?) throws -> Int

    /// Queue a bulk or interrupt transfer. nil data is a zero-length packet.
    func enqueueTransfer(endpoint: UInt8, data: NSMutableData?,
                         completion: @escaping @Sendable (IOReturn, Int) -> Void) throws

    /// Queue an isochronous transfer, starting as soon as the endpoint allows.
    func enqueueIsochronous(endpoint: UInt8, data: NSMutableData, transactions: [USBIsochronousTransaction],
                            completion: @escaping @Sendable (IOReturn, [USBIsochronousTransaction]) -> Void) throws

    /// Abort every request pending on the default control endpoint.
    func abortControl()

    /// Abort every request pending on an endpoint.
    func abort(endpoint: UInt8)

    /// Clear the host's side of a halted endpoint and reset its data toggle. The device's
    /// side is cleared by the CLEAR_FEATURE request itself.
    func clearHalt(endpoint: UInt8) throws

    /// Select a configuration. Every pending request is aborted.
    func setConfiguration(_ value: UInt8) throws

    /// Select an interface's alternate setting. Requests pending on its endpoints are
    /// aborted, and its endpoints are replaced by the new setting's.
    func setAlternateSetting(interface: UInt8, alternate: UInt8) throws

    /// Abort everything and give the device back to macOS.
    func close()
}

public extension USBDeviceIO {
    /// Devices that do not pool buffers let them go.
    func recycle(_ buffer: NSMutableData) {}
}

/// How the device layer refuses an operation, as an IOReturn.
public struct USBDeviceIOError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public var errorDescription: String? { description }

    public let result: IOReturn
    public let operation: String

    public init(_ result: IOReturn, _ operation: String) {
        self.result = result
        self.operation = operation
    }

    public var description: String {
        return "\(operation) failed: \(USBIOReturn.describe(result))"
    }
}

/// IOReturn values the transfer path has to tell apart. The USB-specific ones are
/// defined with function-like macros, which Swift does not import.
public enum USBIOReturn {
    public static let success = kIOReturnSuccess
    public static let aborted = IOReturn(bitPattern: 0xE000_02EB)
    public static let timeout = IOReturn(bitPattern: 0xE000_02D6)
    public static let noDevice = IOReturn(bitPattern: 0xE000_02C0)
    public static let notResponding = IOReturn(bitPattern: 0xE000_02ED)
    public static let exclusiveAccess = IOReturn(bitPattern: 0xE000_02C5)
    public static let notOpen = IOReturn(bitPattern: 0xE000_02CD)
    public static let internalError = IOReturn(bitPattern: 0xE000_02C9)
    public static let notPermitted = IOReturn(bitPattern: 0xE000_02E2)
    public static let badArgument = IOReturn(bitPattern: 0xE000_02C2)
    public static let unsupported = IOReturn(bitPattern: 0xE000_02C7)
    public static let underrun = IOReturn(bitPattern: 0xE000_02E7)
    public static let overrun = IOReturn(bitPattern: 0xE000_02E8)
    public static let isoTooOld = IOReturn(bitPattern: 0xE000_02F0)
    public static let isoTooNew = IOReturn(bitPattern: 0xE000_02F1)
    public static let pipeStalled = IOReturn(bitPattern: 0xE000_404F)
    /// kUSBHostReturnPipeStalled: how IOUSBHost reports a STALL. The IOUSBLib code above
    /// is never what an IOUSBHostPipe returns.
    public static let hostPipeStalled = IOReturn(bitPattern: 0xE000_5000)
    /// kUSBHostReturnNoPower: no configuration fits the power available.
    public static let hostNoPower = IOReturn(bitPattern: 0xE000_5001)
    /// kUSBHostReturnRedundant: the setting asked for is already in effect.
    public static let hostRedundant = IOReturn(bitPattern: 0xE000_5002)
    public static let transactionTimeout = IOReturn(bitPattern: 0xE000_4051)
    public static let crcError = IOReturn(bitPattern: 0xE000_4001)
    public static let bitstuffError = IOReturn(bitPattern: 0xE000_4002)
    public static let dataToggleError = IOReturn(bitPattern: 0xE000_4003)
    public static let bufferOverrunError = IOReturn(bitPattern: 0xE000_400C)
    public static let bufferUnderrunError = IOReturn(bitPattern: 0xE000_400D)
    public static let notSent1Error = IOReturn(bitPattern: 0xE000_400E)
    public static let notSent2Error = IOReturn(bitPattern: 0xE000_400F)
    public static let linkError = IOReturn(bitPattern: 0xE000_4010)

    public static func describe(_ result: IOReturn) -> String {
        return String(format: "0x%08x", UInt32(bitPattern: result))
    }
}

/// Linux errno values, which is what USB/IP's status fields carry.
public enum LinuxErrno {
    public static let enoent: Int32 = 2
    public static let enomem: Int32 = 12
    public static let exdev: Int32 = 18
    public static let enodev: Int32 = 19
    public static let einval: Int32 = 22
    public static let epipe: Int32 = 32
    public static let enosr: Int32 = 63
    public static let ecomm: Int32 = 70
    public static let eproto: Int32 = 71
    public static let eoverflow: Int32 = 75
    public static let eilseq: Int32 = 84
    public static let eopnotsupp: Int32 = 95
    public static let econnreset: Int32 = 104
    public static let eshutdown: Int32 = 108
    public static let etimedout: Int32 = 110
    public static let eremoteio: Int32 = 121
}

/// Status codes for RET_SUBMIT, following what Linux's USB stack reports for the same
/// outcome (Documentation/driver-api/usb/error-codes.rst).
public enum USBIPTransferStatus {
    /// The status of a whole URB.
    public static func urbStatus(for result: IOReturn) -> Int32 {
        switch result {
        case USBIOReturn.success, USBIOReturn.underrun:
            // A short read is a successful one; URB_SHORT_NOT_OK is applied separately.
            return 0
        case USBIOReturn.pipeStalled, USBIOReturn.hostPipeStalled:
            // A storage device stalls its bulk-in endpoint in the ordinary course of
            // things. Reported as anything but EPIPE, the client never clears the halt,
            // never reads the status, and every command after it times out.
            return -LinuxErrno.epipe
        case USBIOReturn.hostNoPower:
            return -LinuxErrno.eshutdown
        case USBIOReturn.aborted:
            return -LinuxErrno.econnreset
        case USBIOReturn.timeout, USBIOReturn.transactionTimeout:
            return -LinuxErrno.etimedout
        case USBIOReturn.overrun:
            return -LinuxErrno.eoverflow
        case USBIOReturn.noDevice:
            return -LinuxErrno.eshutdown
        case USBIOReturn.crcError:
            return -LinuxErrno.eilseq
        case USBIOReturn.bufferOverrunError:
            return -LinuxErrno.ecomm
        case USBIOReturn.bufferUnderrunError:
            return -LinuxErrno.enosr
        case USBIOReturn.badArgument:
            return -LinuxErrno.einval
        case USBIOReturn.unsupported:
            return -LinuxErrno.eopnotsupp
        default:
            // Bitstuffing, data toggle, no response, link errors and the rest: Linux
            // reports transaction-level failures as EPROTO.
            return -LinuxErrno.eproto
        }
    }

    /// The status of one isochronous packet.
    public static func packetStatus(for result: IOReturn) -> Int32 {
        switch result {
        case USBIOReturn.success, USBIOReturn.underrun:
            return 0
        case USBIOReturn.notSent1Error, USBIOReturn.notSent2Error,
             USBIOReturn.isoTooOld, USBIOReturn.isoTooNew, USBIOReturn.aborted:
            // The packet was not transferred at all.
            return -LinuxErrno.exdev
        default:
            return urbStatus(for: result)
        }
    }

    /// Whether the host's software refused a request without it reaching the bus.
    public static func isHostRefusal(_ result: IOReturn) -> Bool {
        switch result {
        case USBIOReturn.badArgument, USBIOReturn.notPermitted, USBIOReturn.unsupported,
             USBIOReturn.exclusiveAccess, USBIOReturn.notOpen, USBIOReturn.hostRedundant:
            return true
        default:
            return false
        }
    }

    /// Whether a failed bulk or interrupt transfer left the host's side of the endpoint
    /// halted with nothing on the client's side to clear it.
    ///
    /// IOUSBHost halts an endpoint on any error other than a timeout, and every later
    /// request fails until it is cleared. A STALL is the device's doing, so the client
    /// sees EPIPE and clears it with CLEAR_FEATURE, as on Linux. For transaction errors
    /// Linux's host controller drivers reset the endpoint themselves and clients send
    /// nothing, so the server has to.
    public static func needsHostSideReset(after result: IOReturn) -> Bool {
        switch result {
        case USBIOReturn.success, USBIOReturn.underrun, USBIOReturn.pipeStalled, USBIOReturn.hostPipeStalled,
             USBIOReturn.aborted, USBIOReturn.timeout, USBIOReturn.transactionTimeout,
             USBIOReturn.noDevice, USBIOReturn.hostNoPower, USBIOReturn.hostRedundant,
             // Refusals by the software, which never reached the bus.
             USBIOReturn.badArgument, USBIOReturn.notPermitted, USBIOReturn.unsupported,
             USBIOReturn.exclusiveAccess, USBIOReturn.notOpen:
            return false
        default:
            return true
        }
    }
}

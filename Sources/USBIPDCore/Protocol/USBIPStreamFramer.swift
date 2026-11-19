// USBIPStreamFramer.swift
// Splits a USB/IP byte stream into whole messages.

import Foundation

/// Splits a USB/IP connection's byte stream into whole messages.
///
/// TCP delivers bytes, not messages. A read can end in the middle of a message — a
/// 64 KiB bulk OUT arrives in pieces — or carry several: a client that keeps more than
/// one URB in flight writes them back to back. Treating each read as exactly one
/// message, as the connection used to, cut the first kind short and dropped all but
/// the first of the second, after which the two sides no longer agreed on where a
/// message began.
///
/// The length of a message is known from its header:
///
/// - Before import, messages are framed with `op_common`. OP_REQ_DEVLIST is the
///   8-byte header alone; OP_REQ_IMPORT adds a 32-byte busid.
/// - After import, messages are framed with `usbip_header_basic`. CMD_UNLINK is
///   48 bytes. CMD_SUBMIT is 48 bytes, followed by `transfer_buffer_length` bytes of
///   data when the direction is OUT, followed by `number_of_packets` isochronous
///   packet descriptors of 16 bytes each when the transfer is isochronous.
public struct USBIPStreamFramer {
    public enum FramingError: Error, Equatable {
        /// An op_common code no client sends before import.
        case unknownHandshakeCode(UInt16)
        /// A usbip_header_basic command no client sends after import.
        case unknownCommand(UInt32)
        /// A message longer than the framer is willing to buffer.
        case messageTooLarge(Int)
        /// More isochronous packets than USB/IP allows in one request.
        case tooManyIsoPackets(Int)
    }

    /// Size of one `usbip_iso_packet_descriptor`.
    public static let isoPacketDescriptorSize = 16

    /// USBIP_MAX_ISO_PACKETS in Linux.
    public static let maxIsoPackets = 1024

    /// The default limit is far above any transfer a client sends (Linux caps a URB well
    /// below it), and low enough that a corrupt length cannot make the server try to
    /// buffer gigabytes.
    public static let defaultMaxMessageSize = 64 << 20

    public let maxMessageSize: Int

    private var buffer = Data()
    private var start = 0

    public init(maxMessageSize: Int = USBIPStreamFramer.defaultMaxMessageSize) {
        self.maxMessageSize = maxMessageSize
    }

    /// Bytes received and not yet returned as a message.
    public var bufferedByteCount: Int { buffer.count - start }

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// The next complete message, or nil if more bytes are needed.
    ///
    /// - Parameter attached: whether the connection has imported a device, which decides
    ///   how the bytes are framed. See USBIPConnectionState.
    /// - Throws: FramingError when the bytes cannot be the start of a valid message. The
    ///   connection cannot recover from that and should be closed.
    public mutating func nextMessage(attached: Bool) throws -> Data? {
        let pending = buffer.count - start
        guard let length = try Self.messageLength(
            of: buffer, from: start, available: pending, attached: attached, maxMessageSize: maxMessageSize
        ), pending >= length else {
            return nil
        }

        let message = buffer.subdata(in: start..<(start + length))
        start += length

        // Drop consumed bytes once they make up most of the buffer, so it does not grow
        // without bound on a long-lived connection, without copying on every message.
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        } else if start > 1 << 16 && start > buffer.count / 2 {
            buffer = buffer.subdata(in: start..<buffer.count)
            start = 0
        }
        return message
    }

    /// Length of the message whose first byte is at `start`, or nil if too little of its
    /// header has arrived to tell.
    static func messageLength(
        of bytes: Data,
        from start: Int,
        available: Int,
        attached: Bool,
        maxMessageSize: Int
    ) throws -> Int? {
        if !attached {
            // op_common: version(2) code(2) status(4)
            guard available >= 8 else { return nil }
            let code = UInt16(readUInt16(bytes, start + 2))
            switch code {
            case USBIPProtocol.Command.requestDeviceList.rawValue:
                return 8
            case USBIPProtocol.Command.requestDeviceImport.rawValue:
                return 8 + 32
            default:
                throw FramingError.unknownHandshakeCode(code)
            }
        }

        // usbip_header_basic: command(4) seqnum(4) devid(4) direction(4) ep(4), then a
        // 28-byte command block.
        guard available >= USBIPProtocol.commandMessagePrefixSize else { return nil }
        let command = readUInt32(bytes, start)
        switch command {
        case USBIPProtocol.BasicCommand.unlink.rawValue:
            return USBIPProtocol.commandMessagePrefixSize

        case USBIPProtocol.BasicCommand.submit.rawValue:
            let direction = readUInt32(bytes, start + 12)
            let transferBufferLength = Int(readUInt32(bytes, start + 24))
            // number_of_packets is 0 (Linux) or 0xffffffff (the protocol document) for a
            // transfer that is not isochronous; either way no descriptors follow.
            let packets = Int(Int32(bitPattern: readUInt32(bytes, start + 32)))
            guard packets <= maxIsoPackets else {
                throw FramingError.tooManyIsoPackets(packets)
            }

            var length = USBIPProtocol.commandMessagePrefixSize
            if direction == USBIPProtocol.directionOut {
                length += transferBufferLength
            }
            if packets > 0 {
                length += packets * isoPacketDescriptorSize
            }
            guard length <= maxMessageSize else {
                throw FramingError.messageTooLarge(length)
            }
            return length

        default:
            throw FramingError.unknownCommand(command)
        }
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) << 8 | UInt16(data[base + 1])
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16 |
            UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
    }
}

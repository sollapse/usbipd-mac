// BulkOnlyMediumLock.swift
// Unlocking the medium of a storage device captured from macOS.

import Foundation
import IOKit

/// The bulk pipes of a bulk-only storage interface, for the few commands the daemon
/// sends such a device itself, before any client has it.
protocol BulkOnlyPipes {
    /// Send on the bulk OUT endpoint. A stall throws an error carrying it.
    func write(_ data: Data, timeout: TimeInterval) throws
    /// Read up to `length` bytes from the bulk IN endpoint.
    func read(length: Int, timeout: TimeInterval) throws -> Data
    /// Clear a halt on the bulk IN endpoint, or on the bulk OUT one.
    func clearHalt(inbound: Bool) throws
    /// Bulk-Only Mass Storage Reset, then clear both endpoints' halts: the recovery the
    /// transport prescribes after a status it cannot use.
    func resetRecovery() throws
}

/// Releasing the medium-removal lock macOS leaves on a storage device it is captured from.
///
/// macOS locks a drive's tray with PREVENT ALLOW MEDIUM REMOVAL while it has a disc. A
/// capture terminates its storage drivers without them unlocking it, so the lock stays.
/// The client never set it and does not know to clear it, so its eject is refused with
/// "medium removal prevented". That was measured with a USB BD-RE drive on Windows: the
/// eject was refused until the device had been reset. Unlocking it once it is captured
/// hands the client the device as it would find one just plugged in.
enum BulkOnlyMediumLock {
    enum Outcome: Equatable {
        case released
        /// The device refused, with its sense data.
        case refused(String)
        /// The exchange went wrong; the transport has been reset.
        case failed(String)
    }

    enum TransportError: Error, CustomStringConvertible {
        case unusableStatus(Data)
        case phaseError

        var description: String {
            switch self {
            case .unusableStatus(let data):
                return "no usable command status (\(data.map { String(format: "%02x", $0) }.joined()))"
            case .phaseError:
                return "phase error"
            }
        }
    }

    struct Completed {
        let status: UInt8
        let data: Data
    }

    private static let allow: [UInt8] = [0x1E, 0, 0, 0, 0, 0]
    private static let requestSense: [UInt8] = [0x03, 0, 0, 0, 18, 0]

    /// Send PREVENT ALLOW MEDIUM REMOVAL, allowing removal, to one logical unit. The first
    /// command after a media change or a reset gets a unit attention instead; that is
    /// read, which ends it, and the command is sent once more.
    static func release(lun: UInt8, over pipes: BulkOnlyPipes, firstTag: UInt32 = 0x6C6B_0001) -> Outcome {
        var tag = firstTag
        func nextTag() -> UInt32 {
            defer { tag &+= 1 }
            return tag
        }
        do {
            for attempt in 0..<2 {
                if try run(allow, lun: lun, dataIn: 0, tag: nextTag(), over: pipes).status == 0 {
                    return .released
                }
                let sense = try run(requestSense, lun: lun, dataIn: 18, tag: nextTag(), over: pipes)
                let unitAttention = sense.data.count > 2 && sense.data[sense.data.startIndex + 2] & 0x0F == 0x06
                if attempt == 1 || !unitAttention {
                    return .refused(describeSense(sense.data))
                }
            }
        } catch {
            try? pipes.resetRecovery()
            return .failed("\(error)")
        }
        return .refused("no sense data")
    }

    /// One command through the bulk-only transport: command block, data, status.
    static func run(_ cdb: [UInt8], lun: UInt8, dataIn length: Int, tag: UInt32,
                    over pipes: BulkOnlyPipes) throws -> Completed {
        try pipes.write(commandBlockWrapper(tag: tag, lun: lun, cdb: cdb, dataInLength: length), timeout: 5)

        var data = Data()
        if length > 0 {
            do {
                data = try pipes.read(length: length, timeout: 10)
            } catch let error where isStall(error) {
                // A failed data phase ends in a stall, and the status follows it.
                try pipes.clearHalt(inbound: true)
            }
        }

        let wrapper: Data
        do {
            wrapper = try pipes.read(length: 13, timeout: 10)
        } catch let error where isStall(error) {
            // The status may be stalled once: clear the halt and read it again.
            try pipes.clearHalt(inbound: true)
            wrapper = try pipes.read(length: 13, timeout: 10)
        }
        guard let status = status(of: wrapper, tag: tag) else {
            throw TransportError.unusableStatus(wrapper)
        }
        guard status != 2 else {
            throw TransportError.phaseError
        }
        return Completed(status: status, data: data)
    }

    /// A 31-byte command block wrapper: "USBC", the tag, the data length and direction,
    /// the LUN, and the command padded to 16 bytes.
    static func commandBlockWrapper(tag: UInt32, lun: UInt8, cdb: [UInt8], dataInLength: Int) -> Data {
        var data = Data([0x55, 0x53, 0x42, 0x43])
        withUnsafeBytes(of: tag.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(dataInLength).littleEndian) { data.append(contentsOf: $0) }
        data.append(dataInLength > 0 ? 0x80 : 0x00)
        data.append(lun & 0x0F)
        data.append(UInt8(cdb.count))
        data.append(contentsOf: cdb)
        data.append(contentsOf: [UInt8](repeating: 0, count: 16 - cdb.count))
        return data
    }

    /// The status byte of a 13-byte command status wrapper, if it is one and answers `tag`.
    static func status(of wrapper: Data, tag: UInt32) -> UInt8? {
        let bytes = [UInt8](wrapper)
        guard bytes.count == 13, Array(bytes[0..<4]) == [0x55, 0x53, 0x42, 0x53] else { return nil }
        let answered = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
        return answered == tag ? bytes[12] : nil
    }

    static func describeSense(_ data: Data) -> String {
        let bytes = [UInt8](data)
        guard bytes.count >= 14 else {
            return "sense data \(bytes.map { String(format: "%02x", $0) }.joined())"
        }
        return String(format: "sense key %X, ASC %02X, ASCQ %02X", bytes[2] & 0x0F, bytes[12], bytes[13])
    }

    static func isStall(_ error: Error) -> Bool {
        let result = ioReturn(from: error)
        return result == USBIOReturn.pipeStalled || result == USBIOReturn.hostPipeStalled
    }
}

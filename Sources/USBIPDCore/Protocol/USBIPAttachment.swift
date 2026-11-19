// USBIPAttachment.swift
// Serves the URB traffic of one imported device.

import Foundation
import IOKit
import Common

/// Why an import was refused before the device was opened.
public enum AttachmentError: Error, CustomStringConvertible, Equatable {
    /// Another client has the device. A second capture would take it from that client.
    case alreadyAttached(String)

    public var description: String {
        switch self {
        case .alreadyAttached(let busid):
            return "\(busid) is already attached by another client"
        }
    }
}

/// URB transfer_flags a server has to act on (linux/usb.h).
public enum URBTransferFlags {
    /// A short IN transfer is an error (EREMOTEIO) rather than a success.
    public static let shortNotOK: UInt32 = 0x0001
    /// An OUT transfer whose length is a multiple of the packet size ends with a
    /// zero-length packet.
    public static let zeroPacket: UInt32 = 0x0040
}

/// Serves the URB traffic of one imported device.
///
/// Every CMD_SUBMIT is queued with the device as soon as it arrives, in arrival order,
/// and answered from its completion. Nothing waits on a transfer: a client can keep
/// several in flight on one endpoint (isochronous streams depend on it) and a read that
/// may never complete holds up nothing behind it. The device queues each endpoint's
/// requests in the order they were given, which is the order USB requires.
///
/// Requests that change the host's own state are carried out here rather than passed to
/// the device as raw requests, because the host has to know about them:
///
/// - SET_CONFIGURATION selects the configuration through the host, and is a no-op for
///   the configuration already selected (clients send one while attaching).
/// - SET_INTERFACE selects an alternate setting, which replaces the interface's
///   endpoints. Isochronous endpoints usually exist only in a non-zero setting.
/// - CLEAR_FEATURE(ENDPOINT_HALT) clears the halt on the device and on the host. A raw
///   request would clear only the device's side and leave the host's endpoint halted,
///   failing every later transfer.
/// - SET_ADDRESS and a hub port reset are answered without action, as Linux's server
///   does: the client's view of addresses and ports is its own.
///
/// A withdrawn request (CMD_UNLINK) is aborted at the device and answered by RET_UNLINK
/// alone once it has completed, as Linux's server does. IOUSBHost aborts every request
/// pending on the endpoint, so others caught up in it complete with ECONNRESET.
public final class USBIPAttachment: @unchecked Sendable {
    public let busid: String

    private let io: USBDeviceIO
    private let maxTransferSize: Int
    private let send: @Sendable (Data) -> Void
    private let queue: DispatchQueue
    private let logger = Logger(subsystem: "com.usbipd.mac", category: "attachment")

    /// Guards `inFlight` and `isClosed`. Completions arrive on the device's queue.
    private let lock = NSLock()
    private var inFlight: [UInt32: InFlightURB] = [:]
    private var isClosed = false

    private struct InFlightURB {
        let request: USBIPSubmitRequest
        /// Endpoint address with the direction bit; 0 for the control endpoint.
        let endpoint: UInt8
        let isControl: Bool
        /// The CMD_UNLINK that withdrew this request, answered when it completes.
        var unlinkSeqnum: UInt32?
    }

    /// - Parameters:
    ///   - maxTransferSize: the largest transfer a client may request.
    ///   - send: delivers a reply to the client. Called from several queues.
    public init(busid: String, io: USBDeviceIO, maxTransferSize: Int, send: @escaping @Sendable (Data) -> Void) {
        self.busid = busid
        self.io = io
        self.maxTransferSize = maxTransferSize
        self.send = send
        self.queue = DispatchQueue(label: "com.usbipd.mac.attachment.\(busid)")
    }

    /// Handle one framed CMD_SUBMIT or CMD_UNLINK. Messages must be passed in the order
    /// they arrived.
    public func handle(_ message: Data) {
        queue.async { self.process(message) }
    }

    /// Stop serving: abort what is in flight and give the device back to macOS.
    public func close() {
        lock.lock()
        let wasClosed = isClosed
        isClosed = true
        inFlight.removeAll()
        lock.unlock()
        guard !wasClosed else { return }

        queue.async {
            self.io.close()
        }
    }

    /// Wait until every message handed to `handle` so far has been processed. Requests
    /// queued with the device may still be in flight.
    func waitUntilProcessed() {
        queue.sync {}
    }

    var inFlightCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlight.count
    }

    // MARK: - Dispatch

    private func process(_ message: Data) {
        lock.lock()
        let closed = isClosed
        lock.unlock()
        guard !closed else { return }

        guard let header = try? USBIPBasicHeader.decode(from: message) else {
            logger.warning("Ignoring a message with an unreadable header")
            return
        }

        switch header.command {
        case .submit:
            submit(message, header: header)
        case .unlink:
            unlink(message)
        case .retSubmit, .retUnlink:
            logger.warning("Ignoring a reply sent by the client")
        }
    }

    private func submit(_ message: Data, header: USBIPBasicHeader) {
        let request: USBIPSubmitRequest
        do {
            request = try USBIPSubmitRequest.decode(from: message)
        } catch {
            reply(seqnum: header.seqnum, devid: header.devid, direction: header.direction, ep: header.ep,
                  status: -LinuxErrno.einval)
            return
        }

        guard Int(request.transferBufferLength) <= maxTransferSize else {
            logger.warning("Refusing a \(request.transferBufferLength)-byte transfer, above the limit of \(maxTransferSize)")
            reply(to: request, status: -LinuxErrno.einval)
            return
        }

        let number = UInt8(truncatingIfNeeded: request.ep & 0x0F)
        if number == 0 {
            submitControl(request)
        } else {
            let inbound = request.direction == USBIPProtocol.directionIn
            submitEndpoint(request, address: inbound ? number | 0x80 : number)
        }
    }

    // MARK: - Control endpoint

    private func submitControl(_ request: USBIPSubmitRequest) {
        guard let setup = USBSetupPacket(request.setup) else {
            reply(to: request, status: -LinuxErrno.einval)
            return
        }

        if let status = carryOut(setup) {
            reply(to: request, status: status)
            return
        }

        let inbound = setup.isDeviceToHost
        let buffer: NSMutableData?
        if inbound {
            buffer = setup.wLength > 0 ? io.makeBuffer(length: Int(setup.wLength)) : nil
        } else if let payload = request.transferBuffer, !payload.isEmpty {
            buffer = NSMutableData(data: payload)
        } else {
            buffer = nil
        }

        track(request, endpoint: 0, isControl: true)
        let replyBuffer = ReplyBuffer(inbound ? buffer : nil)
        do {
            try io.enqueueControl(setup, data: buffer) { [weak self] result, transferred in
                self?.complete(request.seqnum, result: result, transferred: transferred, buffer: replyBuffer.data)
            }
        } catch {
            untrack(request.seqnum)
            reply(to: request, status: USBIPTransferStatus.urbStatus(for: ioReturn(from: error)))
        }
    }

    /// Carry out a request that changes the host's state, returning its status, or nil if
    /// the request should go to the device as it is.
    private func carryOut(_ setup: USBSetupPacket) -> Int32? {
        switch (setup.bmRequestType, setup.bRequest) {
        case (0x00, 0x05):
            // SET_ADDRESS. The device already has its address; the client's view of it
            // is the client's business.
            return 0

        case (0x00, 0x09):
            // SET_CONFIGURATION
            let value = UInt8(truncatingIfNeeded: setup.wValue)
            return status { try io.setConfiguration(value) }

        case (0x01, 0x0B):
            // SET_INTERFACE
            let interface = UInt8(truncatingIfNeeded: setup.wIndex)
            let alternate = UInt8(truncatingIfNeeded: setup.wValue)
            return status { try io.setAlternateSetting(interface: interface, alternate: alternate) }

        case (0x02, 0x01) where setup.wValue == 0 && setup.wIndex & 0x0F != 0:
            // CLEAR_FEATURE(ENDPOINT_HALT). The device's side with the request itself,
            // then the host's, in the order Linux's usb_clear_halt uses.
            let endpoint = UInt8(truncatingIfNeeded: setup.wIndex)
            if let failure = status({ _ = try io.sendControl(setup, data: nil) }), failure != 0 {
                return failure
            }
            do {
                try io.clearHalt(endpoint: endpoint)
            } catch {
                logger.debug("Host side of \(String(format: "0x%02x", endpoint)) not cleared: \(error)")
            }
            return 0

        case (0x23, 0x03) where setup.wValue == 4:
            // SET_FEATURE(PORT_RESET) addressed to the client's own root hub port.
            return 0

        default:
            return nil
        }
    }

    private func status(_ operation: () throws -> Void) -> Int32? {
        do {
            try operation()
            return 0
        } catch {
            logger.info("\(busid): \(error)")
            return USBIPTransferStatus.urbStatus(for: ioReturn(from: error))
        }
    }

    // MARK: - Other endpoints

    private func submitEndpoint(_ request: USBIPSubmitRequest, address: UInt8) {
        guard let endpoint = io.endpoint(address) else {
            // Not in the current configuration and alternate settings. ENOENT is what
            // Linux's usb_submit_urb returns for that.
            reply(to: request, status: -LinuxErrno.enoent)
            return
        }

        switch endpoint.transferType {
        case .bulk, .interrupt:
            submitTransfer(request, endpoint: endpoint)
        case .isochronous:
            submitIsochronous(request, endpoint: endpoint)
        case .control:
            reply(to: request, status: -LinuxErrno.einval)
        }
    }

    private func submitTransfer(_ request: USBIPSubmitRequest, endpoint: USBEndpointInfo) {
        let address = endpoint.address
        let inbound = address & 0x80 != 0
        let length = Int(request.transferBufferLength)

        let buffer: NSMutableData?
        if inbound {
            buffer = length > 0 ? io.makeBuffer(length: length) : nil
        } else if let payload = request.transferBuffer, !payload.isEmpty {
            buffer = outBuffer(payload)
        } else {
            buffer = nil
        }

        let zeroPacket = !inbound && request.transferFlags & URBTransferFlags.zeroPacket != 0
            && length > 0 && endpoint.maxPacketSize > 0 && length % endpoint.maxPacketSize == 0

        track(request, endpoint: address, isControl: false)
        do {
            if zeroPacket {
                // Both are queued now so nothing queued later can come between them.
                let first = TransferResultBox()
                try io.enqueueTransfer(endpoint: address, data: buffer) { result, transferred in
                    first.store(result, transferred)
                }
                try io.enqueueTransfer(endpoint: address, data: nil) { [weak self] result, _ in
                    let (firstResult, transferred) = first.load()
                    self?.complete(request.seqnum, result: firstResult == kIOReturnSuccess ? result : firstResult,
                                   transferred: transferred, buffer: nil)
                }
            } else {
                let replyBuffer = ReplyBuffer(inbound ? buffer : nil)
                try io.enqueueTransfer(endpoint: address, data: buffer) { [weak self] result, transferred in
                    self?.complete(request.seqnum, result: result, transferred: transferred, buffer: replyBuffer.data)
                }
            }
        } catch {
            untrack(request.seqnum)
            reply(to: request, status: USBIPTransferStatus.urbStatus(for: ioReturn(from: error)))
        }
    }

    private func submitIsochronous(_ request: USBIPSubmitRequest, endpoint: USBEndpointInfo) {
        let packets = request.isoPackets
        guard !packets.isEmpty else {
            reply(to: request, status: -LinuxErrno.einval)
            return
        }
        let inbound = endpoint.address & 0x80 != 0

        // The packets go back to back in the device's buffer. The client's offsets can
        // leave gaps, and the reply's data is back to back anyway.
        var transactions: [USBIsochronousTransaction] = []
        var total = 0
        for packet in packets {
            transactions.append(USBIsochronousTransaction(requestCount: packet.length, offset: UInt32(total)))
            total += Int(packet.length)
        }
        guard total <= maxTransferSize else {
            reply(to: request, status: -LinuxErrno.einval)
            return
        }

        let buffer = io.makeBuffer(length: total)
        if !inbound {
            let payload = request.transferBuffer ?? Data()
            for (packet, transaction) in zip(packets, transactions) where packet.length > 0 {
                let start = Int(packet.offset)
                let end = start + Int(packet.length)
                guard end <= payload.count else {
                    reply(to: request, status: -LinuxErrno.einval)
                    return
                }
                payload.withUnsafeBytes { source in
                    let destination = buffer.mutableBytes.advanced(by: Int(transaction.offset))
                    destination.copyMemory(from: source.baseAddress!.advanced(by: start), byteCount: end - start)
                }
            }
        }

        track(request, endpoint: endpoint.address, isControl: false)
        let replyBuffer = ReplyBuffer(inbound ? buffer : nil)
        do {
            try io.enqueueIsochronous(endpoint: endpoint.address, data: buffer, transactions: transactions) {
                [weak self] result, completed in
                self?.completeIsochronous(request.seqnum, result: result, completed: completed,
                                          buffer: replyBuffer.data)
            }
        } catch {
            untrack(request.seqnum)
            reply(to: request, status: USBIPTransferStatus.urbStatus(for: ioReturn(from: error)))
        }
    }

    private func outBuffer(_ payload: Data) -> NSMutableData {
        let buffer = io.makeBuffer(length: payload.count)
        payload.withUnsafeBytes { source in
            buffer.mutableBytes.copyMemory(from: source.baseAddress!, byteCount: min(payload.count, buffer.length))
        }
        return buffer
    }

    // MARK: - Withdrawing requests

    private func unlink(_ message: Data) {
        guard let request = try? USBIPUnlinkRequest.decode(from: message) else { return }

        lock.lock()
        guard var entry = inFlight[request.unlinkSeqnum], entry.unlinkSeqnum == nil else {
            lock.unlock()
            // Already answered. Linux's server says so with status 0, and the client
            // has its RET_SUBMIT.
            sendUnlinkReply(seqnum: request.seqnum, devid: request.devid, status: 0)
            return
        }
        entry.unlinkSeqnum = request.seqnum
        inFlight[request.unlinkSeqnum] = entry
        lock.unlock()

        // The reply goes out when the aborted request completes.
        if entry.isControl {
            io.abortControl()
        } else {
            io.abort(endpoint: entry.endpoint)
        }
    }

    // MARK: - Completion

    private func track(_ request: USBIPSubmitRequest, endpoint: UInt8, isControl: Bool) {
        lock.lock()
        inFlight[request.seqnum] = InFlightURB(request: request, endpoint: endpoint, isControl: isControl)
        lock.unlock()
    }

    private func untrack(_ seqnum: UInt32) {
        lock.lock()
        inFlight[seqnum] = nil
        lock.unlock()
    }

    /// Take a completed request out of the table. Returns nil when the attachment is
    /// closed or the request was withdrawn (whose RET_UNLINK this sends).
    private func finish(_ seqnum: UInt32) -> InFlightURB? {
        lock.lock()
        let entry = inFlight.removeValue(forKey: seqnum)
        let closed = isClosed
        lock.unlock()

        guard let entry = entry, !closed else { return nil }
        if let unlinkSeqnum = entry.unlinkSeqnum {
            sendUnlinkReply(seqnum: unlinkSeqnum, devid: entry.request.devid, status: -LinuxErrno.econnreset)
            return nil
        }
        return entry
    }

    private func complete(_ seqnum: UInt32, result: IOReturn, transferred: Int, buffer: NSMutableData?) {
        guard let entry = finish(seqnum) else { return }
        let request = entry.request

        var status = USBIPTransferStatus.urbStatus(for: result)
        let inbound = request.direction == USBIPProtocol.directionIn
        if status == 0, inbound, request.transferFlags & URBTransferFlags.shortNotOK != 0,
           transferred < Int(request.transferBufferLength) {
            status = -LinuxErrno.eremoteio
        }

        if !entry.isControl && USBIPTransferStatus.needsHostSideReset(after: result) {
            // Cleared from the attachment's queue: clearing aborts what is pending on
            // the endpoint, and doing that from inside a completion could wait on this
            // very queue.
            let endpoint = entry.endpoint
            queue.async { [io] in try? io.clearHalt(endpoint: endpoint) }
        }

        var data: Data?
        if let buffer = buffer, transferred > 0 {
            data = Data(bytes: buffer.bytes, count: min(transferred, buffer.length))
        }
        reply(to: request, status: status, actualLength: UInt32(transferred), data: data)
    }

    private func completeIsochronous(_ seqnum: UInt32, result: IOReturn, completed: [USBIsochronousTransaction],
                                     buffer: NSMutableData?) {
        guard let entry = finish(seqnum) else { return }
        let request = entry.request

        var descriptors: [USBIPIsoPacketDescriptor] = []
        var data = Data()
        var actual: UInt32 = 0
        var errors: UInt32 = 0
        for (index, packet) in request.isoPackets.enumerated() {
            let transaction = index < completed.count ? completed[index] : USBIsochronousTransaction(
                requestCount: packet.length, offset: 0, completeCount: 0, status: result)
            let status = USBIPTransferStatus.packetStatus(for: transaction.status)
            let count = min(transaction.completeCount, transaction.requestCount)
            if status != 0 {
                errors += 1
            }
            if let buffer = buffer, count > 0, Int(transaction.offset) + Int(count) <= buffer.length {
                data.append(buffer.bytes.advanced(by: Int(transaction.offset)).assumingMemoryBound(to: UInt8.self),
                            count: Int(count))
            }
            actual += count
            descriptors.append(USBIPIsoPacketDescriptor(offset: packet.offset, length: packet.length,
                                                        actualLength: count, status: status))
        }

        // An isochronous URB succeeds as a whole even when packets fail; their own
        // statuses and the error count say which. Only a request that did not run at all
        // fails as a whole.
        let ranAtAll = result == kIOReturnSuccess || result == USBIOReturn.underrun
            || Int(errors) < request.isoPackets.count
        let status = ranAtAll ? 0 : USBIPTransferStatus.urbStatus(for: result)

        let response = USBIPSubmitResponse(
            seqnum: request.seqnum, devid: request.devid, direction: request.direction, ep: request.ep,
            status: status, actualLength: actual, startFrame: request.startFrame,
            numberOfPackets: UInt32(request.isoPackets.count), errorCount: errors,
            transferBuffer: buffer == nil || data.isEmpty ? nil : data, isoPackets: descriptors)
        deliver(response)
    }

    // MARK: - Replies

    private func reply(to request: USBIPSubmitRequest, status: Int32, actualLength: UInt32 = 0, data: Data? = nil) {
        let response = USBIPSubmitResponse(
            seqnum: request.seqnum, devid: request.devid, direction: request.direction, ep: request.ep,
            status: status, actualLength: actualLength, startFrame: request.startFrame,
            numberOfPackets: request.isoPackets.isEmpty ? 0 : UInt32(request.isoPackets.count),
            errorCount: 0, transferBuffer: data,
            isoPackets: request.isoPackets.map {
                USBIPIsoPacketDescriptor(offset: $0.offset, length: $0.length, actualLength: 0, status: status)
            })
        deliver(response)
    }

    private func reply(seqnum: UInt32, devid: UInt32, direction: UInt32, ep: UInt32, status: Int32) {
        deliver(USBIPSubmitResponse(seqnum: seqnum, devid: devid, direction: direction, ep: ep,
                                    status: status, actualLength: 0))
    }

    private func sendUnlinkReply(seqnum: UInt32, devid: UInt32, status: Int32) {
        let response = USBIPUnlinkResponse(seqnum: seqnum, devid: devid, direction: 0, ep: 0, status: status)
        if let data = try? response.encode() {
            send(data)
        }
    }

    private func deliver(_ response: USBIPSubmitResponse) {
        do {
            send(try response.encode())
        } catch {
            logger.error("Could not encode a reply for seqnum \(response.seqnum): \(error)")
        }
    }
}

/// Hands an IN transfer's buffer to its completion, which IOUSBHost calls on another
/// queue. Nothing touches the buffer between the two.
private final class ReplyBuffer: @unchecked Sendable {
    let data: NSMutableData?

    init(_ data: NSMutableData?) {
        self.data = data
    }
}

/// Carries the first transfer's result to the zero-length packet queued after it.
private final class TransferResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: IOReturn = kIOReturnSuccess
    private var transferred = 0

    func store(_ result: IOReturn, _ transferred: Int) {
        lock.lock()
        self.result = result
        self.transferred = transferred
        lock.unlock()
    }

    func load() -> (IOReturn, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (result, transferred)
    }
}

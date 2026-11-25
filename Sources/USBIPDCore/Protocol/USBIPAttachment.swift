// USBIPAttachment.swift
// Serves the URB traffic of one imported device.

import Foundation
import IOKit
import Common

/// Why an import was refused before the device was opened.
public enum AttachmentError: Error, CustomStringConvertible, LocalizedError, Equatable {
    /// Another client has the device. A second capture would take it from that client.
    case alreadyAttached(String)
    /// The session ended while its device was away.
    case ended(String)

    public var description: String {
        switch self {
        case .alreadyAttached(let busid):
            return "\(busid) is already attached by another client"
        case .ended(let busid):
            return "The session serving \(busid) has ended"
        }
    }

    public var errorDescription: String? { description }
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
/// - SET_ADDRESS is answered without action: the device has its address, and the
///   client's view of addresses is its own.
/// - A hub port reset is answered without action too. Linux's server resets the device
///   for it; here a reset would end the capture and hand the device back to macOS.
///
/// A device can go away and come straight back, as a drive that resets itself does (see
/// `DeviceComeback`). From `deviceWentAway()` to `resume(with:)`, what the client sends is
/// held, and what the device had is answered once it is back, with EPROTO: a transaction
/// error, which a client recovers from with the device it then has. The client's
/// configuration and alternate settings are selected again first.
///
/// A withdrawn request (CMD_UNLINK) is aborted at the device and answered by RET_UNLINK
/// alone once it has completed, as Linux's server does. IOUSBHost can only abort a whole
/// endpoint, and resetting an endpoint aborts what is queued on it too, so an endpoint
/// being aborted is drained: requests caught up in it that had transferred nothing are
/// queued again, in order, together with any submitted meanwhile. On Linux those
/// requests simply carry on, and drivers that see them fail with ECONNRESET take it
/// as their own unlink and stop resubmitting.
///
/// Everything here runs on one serial queue: messages from the client, and completions,
/// which IOUSBHost delivers elsewhere and which are moved onto it. So a reply can never
/// overtake another reply it must follow — a RET_UNLINK saying "already completed" is
/// only ever sent after that request's RET_SUBMIT.
public final class USBIPAttachment: @unchecked Sendable {
    public let busid: String

    private let maxTransferSize: Int
    private let send: @Sendable (Data) -> Void
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()
    private let logger = Logger(subsystem: "com.usbipd.mac", category: "attachment")

    // Confined to `queue`.
    /// The device, replaced when it comes back after going away.
    private var io: USBDeviceIO
    private var inFlight: [UInt32: InFlightURB] = [:]
    private var draining: [UInt8: Set<UInt32>] = [:]
    private var isClosed = false
    private var lastGeneration: UInt64 = 0
    /// From the device going away until it is back or the session ends.
    private var deviceAway = false
    /// CMD_SUBMITs that arrived while the device was away, in order.
    private var heldWhileAway: [(seqnum: UInt32, message: Data)] = []
    /// What the client selected, to be selected again on a device that comes back.
    private var clientConfiguration: UInt8?
    private var clientAlternates: [UInt8: UInt8] = [:]

    private enum Stage {
        /// Queued with the device.
        case queued
        /// Aborted with an endpoint having transferred nothing; queued again when the
        /// endpoint has drained.
        case awaitingResubmit
        /// Arrived while its endpoint was draining; queued when it has.
        case held
        /// Went with a device that went away; answered when it is back.
        case lost
    }

    private struct InFlightURB {
        let request: USBIPSubmitRequest
        /// Endpoint address with the direction bit; 0 for the control endpoint.
        let endpoint: UInt8
        let transferType: USBTransferType
        var stage: Stage
        /// Which time this request was queued. A request queued again after an abort
        /// must not take a late completion from its earlier attempt as its own.
        var generation: UInt64 = 0
        /// The CMD_UNLINK that withdrew this request, answered when it completes.
        var withdrawnBy: UInt32?
        /// The buffer an IN reply's data is read from.
        var buffer: NSMutableData?
        /// The buffer an OUT transfer's data went out from.
        var outBuffer: NSMutableData?
        /// An OUT followed by a zero-length packet whose data part has not completed.
        var awaitingDataPart = false
        /// The data part's byte count, once it has completed.
        var dataPartTransferred: Int?
    }

    /// - Parameters:
    ///   - maxTransferSize: the largest transfer a client may request.
    ///   - send: delivers a reply to the client.
    public init(busid: String, io: USBDeviceIO, maxTransferSize: Int, send: @escaping @Sendable (Data) -> Void) {
        self.busid = busid
        self.io = io
        self.maxTransferSize = maxTransferSize
        self.send = send
        self.queue = DispatchQueue(label: "com.usbipd.mac.attachment.\(busid)")
        queue.setSpecific(key: queueKey, value: true)
    }

    /// Handle one framed CMD_SUBMIT or CMD_UNLINK. Messages must be passed in the order
    /// they arrived.
    public func handle(_ message: Data) {
        queue.async { self.process(message) }
    }

    /// Stop serving: abort what is in flight and give the device back to macOS. Returns
    /// once the device has been given back.
    public func close() {
        onQueue {
            guard !self.isClosed else { return }
            self.isClosed = true
            // The device first: its aborts complete what is in flight before the
            // buffers those transfers use are let go.
            self.io.close()
            self.inFlight.removeAll()
            self.draining.removeAll()
            self.heldWhileAway.removeAll()
        }
    }

    /// The device went away. Let go of it, and hold what the client sends until
    /// `resume(with:)` brings it back or the session ends.
    public func deviceWentAway() {
        queue.async {
            guard !self.isClosed, !self.deviceAway else { return }
            self.deviceAway = true
            self.trace("the device went away; holding what the client sends until it is back")
            // What it had completes as it is aborted, and is set aside as lost. Their
            // buffers are not read again: they were mapped for this device.
            self.io.close()
        }
    }

    /// The device is back, opened as `newIO`. Select the client's configuration and
    /// alternate settings on it again, answer what went with the old device, and queue
    /// what the client sent meanwhile, in order.
    ///
    /// Throws if the session ended meanwhile, or the client's settings cannot be selected
    /// again. The caller then ends the session, and closes `newIO`, which closing twice
    /// does no harm.
    public func resume(with newIO: USBDeviceIO) throws {
        try onQueue {
            guard !self.isClosed else { throw AttachmentError.ended(self.busid) }
            self.io = newIO
            if let value = self.clientConfiguration, value != newIO.currentConfiguration {
                try newIO.setConfiguration(value)
            }
            for (number, alternate) in self.clientAlternates.sorted(by: { $0.key < $1.key }) where alternate != 0 {
                try newIO.setAlternateSetting(interface: number, alternate: alternate)
            }

            for seqnum in self.inFlight.keys.sorted() {
                guard let entry = self.inFlight[seqnum] else { continue }
                if let unlinkSeqnum = entry.withdrawnBy {
                    self.sendUnlinkReply(seqnum: unlinkSeqnum, devid: entry.request.devid,
                                         status: -LinuxErrno.econnreset)
                } else {
                    self.trace("seq \(seqnum) went with the device")
                    self.reply(to: entry.request, status: -LinuxErrno.eproto)
                }
            }
            self.inFlight.removeAll()
            self.draining.removeAll()
            self.deviceAway = false

            let held = self.heldWhileAway
            self.heldWhileAway.removeAll()
            self.trace("the device is back, with \(held.count) held \(held.count == 1 ? "request" : "requests") to queue")
            held.forEach { self.process($0.message) }
        }
    }

    /// Run on the queue, from it or from elsewhere.
    private func onQueue<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            return try work()
        }
        return try queue.sync(execute: work)
    }

    /// Wait until every message and completion handed over so far has been processed.
    func waitUntilProcessed() {
        queue.sync {}
    }

    var inFlightCount: Int {
        return queue.sync { inFlight.count }
    }

    // MARK: - Dispatch

    private func process(_ message: Data) {
        guard !isClosed else { return }

        guard let header = try? USBIPBasicHeader.decode(from: message) else {
            logger.warning("Ignoring a message with an unreadable header")
            return
        }

        switch header.command {
        case .submit where deviceAway:
            trace("CMD_SUBMIT seq \(header.seqnum) held until the device is back")
            heldWhileAway.append((seqnum: header.seqnum, message: message))
        case .submit:
            submit(message, header: header)
        case .unlink where deviceAway:
            unlinkWhileAway(message)
        case .unlink:
            unlink(message)
        case .retSubmit, .retUnlink:
            logger.warning("Ignoring a reply sent by the client")
        }
    }

    /// With the device away there is nothing to abort, so a withdrawal is answered at once.
    private func unlinkWhileAway(_ message: Data) {
        guard let request = try? USBIPUnlinkRequest.decode(from: message) else { return }
        trace("CMD_UNLINK seq \(request.seqnum) for seq \(request.unlinkSeqnum), with the device away")

        if let index = heldWhileAway.firstIndex(where: { $0.seqnum == request.unlinkSeqnum }) {
            heldWhileAway.remove(at: index)
            sendUnlinkReply(seqnum: request.seqnum, devid: request.devid, status: -LinuxErrno.econnreset)
        } else if let entry = inFlight[request.unlinkSeqnum], entry.withdrawnBy == nil {
            // It went with the device, or will once its abort completes.
            inFlight[request.unlinkSeqnum] = nil
            sendUnlinkReply(seqnum: request.seqnum, devid: request.devid, status: -LinuxErrno.econnreset)
        } else {
            sendUnlinkReply(seqnum: request.seqnum, devid: request.devid, status: 0)
        }
    }

    private func submit(_ message: Data, header: USBIPBasicHeader) {
        let request: USBIPSubmitRequest
        do {
            request = try USBIPSubmitRequest.decode(from: message)
        } catch {
            deliver(USBIPSubmitResponse(seqnum: header.seqnum, devid: header.devid, direction: header.direction,
                                        ep: header.ep, status: -LinuxErrno.einval, actualLength: 0))
            return
        }

        trace("CMD_SUBMIT seq \(request.seqnum) ep \(request.ep) \(request.direction == 1 ? "in" : "out") "
              + "length \(request.transferBufferLength) flags \(String(format: "0x%x", request.transferFlags))"
              + (request.ep & 0x0F == 0 ? " setup \(request.setup.map { String(format: "%02x", $0) }.joined())" : "")
              + (request.isoPackets.isEmpty ? "" : " packets \(request.isoPackets.count)")
              // What goes out matters as much as what comes back: a storage command
              // block is 31 bytes, and its operation code is what says what the client
              // asked the device to do.
              + (request.transferBuffer.map { " data \($0.prefix(32).map { String(format: "%02x", $0) }.joined())" } ?? ""))

        guard Int(request.transferBufferLength) <= maxTransferSize else {
            logger.warning("Refusing a \(request.transferBufferLength)-byte transfer, above the limit of \(maxTransferSize)")
            reply(to: request, status: -LinuxErrno.einval)
            return
        }

        let number = UInt8(truncatingIfNeeded: request.ep & 0x0F)
        guard number != 0 else {
            submitControl(request)
            return
        }

        let inbound = request.direction == USBIPProtocol.directionIn
        let address = inbound ? number | 0x80 : number
        guard let endpoint = io.endpoint(address) else {
            // Not in the current configuration and alternate settings. ENOENT is what
            // Linux's usb_submit_urb returns for that.
            reply(to: request, status: -LinuxErrno.enoent)
            return
        }

        switch endpoint.transferType {
        case .control:
            reply(to: request, status: -LinuxErrno.einval)
        case .isochronous:
            // The packets are checked now, so a request that cannot be laid out is
            // refused before anything is queued.
            guard isochronousLength(of: request) != nil else {
                reply(to: request, status: -LinuxErrno.einval)
                return
            }
            admit(request, endpoint: address, transferType: .isochronous)
        case .bulk, .interrupt:
            admit(request, endpoint: address, transferType: endpoint.transferType)
        }
    }

    /// Track a request and queue it, or hold it while its endpoint drains.
    private func admit(_ request: USBIPSubmitRequest, endpoint: UInt8, transferType: USBTransferType) {
        let draining = self.draining[endpoint] != nil
        inFlight[request.seqnum] = InFlightURB(request: request, endpoint: endpoint, transferType: transferType,
                                               stage: draining ? .held : .queued)
        if !draining {
            start(request.seqnum)
        }
    }

    // MARK: - Control endpoint

    private func submitControl(_ request: USBIPSubmitRequest) {
        guard let setup = USBSetupPacket(request.setup) else {
            reply(to: request, status: -LinuxErrno.einval)
            return
        }

        if let status = carryOut(setup) {
            trace("seq \(request.seqnum) carried out here: status \(status)")
            reply(to: request, status: status)
            return
        }
        admit(request, endpoint: 0, transferType: .control)
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
            let result = status { try io.setConfiguration(value) }
            if result == 0 {
                clientConfiguration = value
                clientAlternates = [:]
            }
            return result

        case (0x01, 0x0B):
            // SET_INTERFACE
            let interface = UInt8(truncatingIfNeeded: setup.wIndex)
            let alternate = UInt8(truncatingIfNeeded: setup.wValue)
            let result = status { try io.setAlternateSetting(interface: interface, alternate: alternate) }
            if result == 0 {
                clientAlternates[interface] = alternate
            }
            return result

        case (0x02, 0x01) where setup.wValue == 0 && setup.wIndex & 0x0F != 0:
            // CLEAR_FEATURE(ENDPOINT_HALT). The device's side with the request itself,
            // then the host's, in the order Linux's usb_clear_halt uses.
            let endpoint = UInt8(truncatingIfNeeded: setup.wIndex)
            do {
                _ = try io.sendControl(setup, data: nil)
            } catch {
                // The device answering is the device's business, and is passed on. A
                // refusal by the host stack itself is not: clearing the host's side
                // below is what IOUSBHost wants instead, so it goes ahead.
                let result = ioReturn(from: error)
                if !USBIPTransferStatus.isHostRefusal(result) {
                    logger.info("\(busid): clearing the halt on \(String(format: "0x%02x", endpoint)): \(error)")
                    return USBIPTransferStatus.urbStatus(for: result)
                }
                trace("the host refused CLEAR_FEATURE as a request (\(USBIOReturn.describe(result))); clearing the halt through the pipe instead")
            }
            resetHostSide(of: endpoint)
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

    // MARK: - Queueing with the device

    /// Queue a tracked request with the device. Buffers are made here rather than on
    /// arrival, so a request queued again after an abort starts from its original data.
    private func start(_ seqnum: UInt32) {
        guard var entry = inFlight[seqnum] else { return }
        if deviceAway {
            // Due again after an abort, with the device gone: it is answered with the rest
            // of what went with it.
            entry.stage = .lost
            inFlight[seqnum] = entry
            return
        }
        let request = entry.request
        lastGeneration += 1
        entry.generation = lastGeneration
        let generation = lastGeneration
        // Buffers are made for each attempt; an earlier attempt's went back to the pool.
        entry.buffer = nil
        entry.outBuffer = nil

        do {
            switch entry.transferType {
            case .control:
                guard let setup = USBSetupPacket(request.setup) else { throw USBDeviceIOError(USBIOReturn.badArgument, "Setup") }
                let buffer: NSMutableData?
                if setup.isDeviceToHost {
                    buffer = setup.wLength > 0 ? io.makeBuffer(length: Int(setup.wLength)) : nil
                    entry.buffer = buffer
                } else if let payload = request.transferBuffer, !payload.isEmpty {
                    buffer = NSMutableData(data: payload)
                } else {
                    buffer = nil
                }
                inFlight[seqnum] = entry
                try io.enqueueControl(setup, data: buffer) { [weak self] result, transferred in
                    self?.queue.async {
                        self?.completed(seqnum, generation: generation, result: result, transferred: transferred)
                    }
                }

            case .bulk, .interrupt:
                try startTransfer(seqnum, generation: generation, entry: &entry)

            case .isochronous:
                try startIsochronous(seqnum, generation: generation, entry: &entry)
            }
        } catch {
            inFlight[seqnum] = nil
            reply(to: request, status: USBIPTransferStatus.urbStatus(for: ioReturn(from: error)))
        }
    }

    private func startTransfer(_ seqnum: UInt32, generation: UInt64, entry: inout InFlightURB) throws {
        let request = entry.request
        let address = entry.endpoint
        let inbound = address & 0x80 != 0
        let length = Int(request.transferBufferLength)

        let buffer: NSMutableData?
        if inbound {
            buffer = length > 0 ? io.makeBuffer(length: length) : nil
            entry.buffer = buffer
        } else if let payload = request.transferBuffer, !payload.isEmpty {
            buffer = outBuffer(payload)
            entry.outBuffer = buffer
        } else {
            buffer = nil
        }

        let packetSize = io.endpoint(address)?.maxPacketSize ?? 0
        let zeroPacket = !inbound && request.transferFlags & URBTransferFlags.zeroPacket != 0
            && length > 0 && packetSize > 0 && length % packetSize == 0
        entry.awaitingDataPart = zeroPacket
        inFlight[seqnum] = entry

        try io.enqueueTransfer(endpoint: address, data: buffer) { [weak self] result, transferred in
            self?.queue.async {
                self?.completed(seqnum, generation: generation, result: result, transferred: transferred)
            }
        }
        if zeroPacket {
            // Queued straight after the data, so nothing queued later can come between.
            try io.enqueueTransfer(endpoint: address, data: nil) { [weak self] result, transferred in
                self?.queue.async {
                    self?.completed(seqnum, generation: generation, result: result, transferred: transferred)
                }
            }
        }
    }

    private func startIsochronous(_ seqnum: UInt32, generation: UInt64, entry: inout InFlightURB) throws {
        let request = entry.request
        let inbound = entry.endpoint & 0x80 != 0
        guard let total = isochronousLength(of: request) else {
            throw USBDeviceIOError(USBIOReturn.badArgument, "Isochronous packets")
        }

        // The packets go back to back in the device's buffer. The client's offsets can
        // leave gaps, and the reply's data is back to back anyway.
        var transactions: [USBIsochronousTransaction] = []
        var offset = 0
        for packet in request.isoPackets {
            transactions.append(USBIsochronousTransaction(requestCount: packet.length, offset: UInt32(offset)))
            offset += Int(packet.length)
        }

        let buffer = io.makeBuffer(length: total)
        if inbound {
            entry.buffer = buffer
        } else {
            entry.outBuffer = buffer
            let payload = request.transferBuffer ?? Data()
            for (packet, transaction) in zip(request.isoPackets, transactions) where packet.length > 0 {
                let start = Int(packet.offset)
                let end = start + Int(packet.length)
                guard end <= payload.count else {
                    throw USBDeviceIOError(USBIOReturn.badArgument, "Isochronous packet outside the data")
                }
                payload.withUnsafeBytes { source in
                    let destination = buffer.mutableBytes.advanced(by: Int(transaction.offset))
                    destination.copyMemory(from: source.baseAddress!.advanced(by: start), byteCount: end - start)
                }
            }
        }
        inFlight[seqnum] = entry

        try io.enqueueIsochronous(endpoint: entry.endpoint, data: buffer, transactions: transactions) {
            [weak self] result, completed in
            self?.queue.async {
                self?.completedIsochronous(seqnum, generation: generation, result: result, completed: completed)
            }
        }
    }

    /// Total bytes of an isochronous request's packets, or nil if there are none or they
    /// exceed what a transfer may be. Summed without overflow: three packets of
    /// 0xffffffff bytes must be refused, not trap.
    private func isochronousLength(of request: USBIPSubmitRequest) -> Int? {
        guard !request.isoPackets.isEmpty else { return nil }
        var total = 0
        for packet in request.isoPackets {
            total += Int(packet.length)
            if total > maxTransferSize {
                return nil
            }
        }
        return total
    }

    private func outBuffer(_ payload: Data) -> NSMutableData {
        let buffer = io.makeBuffer(length: payload.count)
        payload.withUnsafeBytes { source in
            buffer.mutableBytes.copyMemory(from: source.baseAddress!, byteCount: min(payload.count, buffer.length))
        }
        return buffer
    }

    // MARK: - Withdrawing requests and draining endpoints

    private func unlink(_ message: Data) {
        guard let request = try? USBIPUnlinkRequest.decode(from: message) else { return }
        trace("CMD_UNLINK seq \(request.seqnum) for seq \(request.unlinkSeqnum)")

        guard var entry = inFlight[request.unlinkSeqnum], entry.withdrawnBy == nil else {
            // Already answered. Linux's server says so with status 0; the RET_SUBMIT
            // went out before this, from this same queue.
            sendUnlinkReply(seqnum: request.seqnum, devid: request.devid, status: 0)
            return
        }

        switch entry.stage {
        case .held, .awaitingResubmit, .lost:
            // Not with the device: nothing to abort.
            inFlight[request.unlinkSeqnum] = nil
            sendUnlinkReply(seqnum: request.seqnum, devid: request.devid, status: -LinuxErrno.econnreset)

        case .queued:
            entry.withdrawnBy = request.seqnum
            inFlight[request.unlinkSeqnum] = entry
            // The reply goes out when the aborted request completes.
            if beginDraining(entry.endpoint) {
                if entry.endpoint == 0 {
                    io.abortControl()
                } else {
                    io.abort(endpoint: entry.endpoint)
                }
            }
        }
    }

    /// Start draining an endpoint about to be aborted or reset. Returns false when it is
    /// already draining, in which case the abort that started it covers this request too.
    private func beginDraining(_ endpoint: UInt8) -> Bool {
        guard draining[endpoint] == nil else { return false }
        let outstanding = inFlight.filter { $0.value.endpoint == endpoint && $0.value.stage == .queued }.keys
        draining[endpoint] = Set(outstanding)
        if outstanding.isEmpty {
            finishDraining(endpoint)
        }
        return true
    }

    /// Clear the host's side of an endpoint, which aborts what is queued on it.
    private func resetHostSide(of endpoint: UInt8) {
        let started = beginDraining(endpoint)
        do {
            try io.clearHalt(endpoint: endpoint)
        } catch {
            logger.debug("Host side of \(String(format: "0x%02x", endpoint)) not cleared: \(error)")
        }
        if started {
            finishDraining(endpoint)
        }
    }

    /// Once nothing aborted is left outstanding on an endpoint, queue again what the abort
    /// caught and what arrived meanwhile, in the order the client sent it.
    private func finishDraining(_ endpoint: UInt8) {
        guard let outstanding = draining[endpoint], outstanding.isEmpty else { return }
        draining[endpoint] = nil

        let waiting = inFlight.filter {
            $0.value.endpoint == endpoint && ($0.value.stage == .awaitingResubmit || $0.value.stage == .held)
        }.keys.sorted()
        for seqnum in waiting {
            guard var entry = inFlight[seqnum] else { continue }
            entry.stage = .queued
            entry.awaitingDataPart = false
            entry.dataPartTransferred = nil
            inFlight[seqnum] = entry
            start(seqnum)
        }
    }

    // MARK: - Completion

    private func completed(_ seqnum: UInt32, generation: UInt64, result: IOReturn, transferred: Int) {
        trace("seq \(seqnum) completed: \(USBIOReturn.describe(result)), \(transferred) bytes")
        // A completion from an earlier attempt, or from the zero-length packet of one
        // already set aside to be queued again, belongs to nothing current.
        guard !isClosed, var entry = inFlight[seqnum], entry.generation == generation,
              entry.stage == .queued else { return }
        if deviceAway {
            setAsideWithDevice(seqnum, entry)
            return
        }

        // An OUT with a zero-length packet completes twice. A data part that succeeds
        // waits for the packet; one that fails is answered at once, since the packet
        // behind it will sit on a halted endpoint until the client clears it.
        if entry.awaitingDataPart {
            entry.awaitingDataPart = false
            if result == kIOReturnSuccess {
                entry.dataPartTransferred = transferred
                inFlight[seqnum] = entry
                return
            }
        }
        let wasDraining = leaveDrain(seqnum, endpoint: entry.endpoint)
        inFlight[seqnum] = nil

        if let unlinkSeqnum = entry.withdrawnBy {
            sendUnlinkReply(seqnum: unlinkSeqnum, devid: entry.request.devid, status: -LinuxErrno.econnreset)
            recycleBuffers(of: &entry)
        } else if result == USBIOReturn.aborted && wasDraining && transferred == 0 && entry.dataPartTransferred == nil {
            // Caught up in another request's abort, with nothing transferred: queued
            // again once the endpoint has drained.
            recycleBuffers(of: &entry)
            entry.stage = .awaitingResubmit
            inFlight[seqnum] = entry
        } else {
            // A zero-length packet aborted after its data went out completes as a success.
            let dataDone = entry.dataPartTransferred
            let finalResult = dataDone != nil && result == USBIOReturn.aborted ? kIOReturnSuccess : result
            reply(to: entry, result: finalResult, transferred: dataDone ?? transferred)
            recycleBuffers(of: &entry)

            if entry.transferType != .control && USBIPTransferStatus.needsHostSideReset(after: result) {
                resetHostSide(of: entry.endpoint)
            }
        }
        finishDraining(entry.endpoint)
    }

    /// A request that completed after its device went away and was let go of. Its buffers
    /// may no longer be readable, so it is answered once the device is back, as lost; a
    /// withdrawn one is answered now.
    private func setAsideWithDevice(_ seqnum: UInt32, _ entry: InFlightURB) {
        var entry = entry
        if let unlinkSeqnum = entry.withdrawnBy {
            inFlight[seqnum] = nil
            sendUnlinkReply(seqnum: unlinkSeqnum, devid: entry.request.devid, status: -LinuxErrno.econnreset)
        } else {
            entry.stage = .lost
            inFlight[seqnum] = entry
        }
    }

    /// Give a finished attempt's buffers back for other transfers. Only once IOKit has
    /// completed the request and the reply has been built from them.
    private func recycleBuffers(of entry: inout InFlightURB) {
        if let buffer = entry.buffer {
            io.recycle(buffer)
        }
        if let buffer = entry.outBuffer {
            io.recycle(buffer)
        }
        entry.buffer = nil
        entry.outBuffer = nil
    }

    private func completedIsochronous(_ seqnum: UInt32, generation: UInt64, result: IOReturn,
                                      completed: [USBIsochronousTransaction]) {
        guard !isClosed, var entry = inFlight[seqnum], entry.generation == generation,
              entry.stage == .queued else { return }
        if deviceAway {
            setAsideWithDevice(seqnum, entry)
            return
        }
        let wasDraining = leaveDrain(seqnum, endpoint: entry.endpoint)
        inFlight[seqnum] = nil

        let transferredAny = completed.contains { $0.completeCount > 0 }
        if let unlinkSeqnum = entry.withdrawnBy {
            sendUnlinkReply(seqnum: unlinkSeqnum, devid: entry.request.devid, status: -LinuxErrno.econnreset)
            recycleBuffers(of: &entry)
        } else if result == USBIOReturn.aborted && wasDraining && !transferredAny {
            recycleBuffers(of: &entry)
            entry.stage = .awaitingResubmit
            inFlight[seqnum] = entry
        } else {
            replyIsochronous(to: entry, result: result, completed: completed)
            recycleBuffers(of: &entry)
        }
        finishDraining(entry.endpoint)
    }

    /// Take a completed request off its endpoint's drain. Returns whether it was on one.
    private func leaveDrain(_ seqnum: UInt32, endpoint: UInt8) -> Bool {
        guard var outstanding = draining[endpoint], outstanding.contains(seqnum) else { return false }
        outstanding.remove(seqnum)
        draining[endpoint] = outstanding
        return true
    }

    // MARK: - Replies

    private func reply(to entry: InFlightURB, result: IOReturn, transferred: Int) {
        let request = entry.request
        var status = USBIPTransferStatus.urbStatus(for: result)
        let inbound = request.direction == USBIPProtocol.directionIn
        if status == 0, inbound, request.transferFlags & URBTransferFlags.shortNotOK != 0,
           transferred < Int(request.transferBufferLength) {
            status = -LinuxErrno.eremoteio
        }

        var data: Data?
        if let buffer = entry.buffer, transferred > 0 {
            data = Data(bytes: buffer.bytes, count: min(transferred, buffer.length))
        }
        reply(to: request, status: status, actualLength: UInt32(clamping: transferred), data: data)
    }

    private func replyIsochronous(to entry: InFlightURB, result: IOReturn, completed: [USBIsochronousTransaction]) {
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
            if let buffer = entry.buffer, count > 0, Int(transaction.offset) + Int(count) <= buffer.length {
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

        deliver(USBIPSubmitResponse(
            seqnum: request.seqnum, devid: request.devid, direction: request.direction, ep: request.ep,
            status: status, actualLength: actual, startFrame: request.startFrame,
            numberOfPackets: UInt32(request.isoPackets.count), errorCount: errors,
            transferBuffer: entry.buffer == nil || data.isEmpty ? nil : data, isoPackets: descriptors))
    }

    private func reply(to request: USBIPSubmitRequest, status: Int32, actualLength: UInt32 = 0, data: Data? = nil) {
        deliver(USBIPSubmitResponse(
            seqnum: request.seqnum, devid: request.devid, direction: request.direction, ep: request.ep,
            status: status, actualLength: actualLength, startFrame: request.startFrame,
            numberOfPackets: request.isoPackets.isEmpty ? 0 : UInt32(request.isoPackets.count),
            errorCount: 0, transferBuffer: data,
            isoPackets: request.isoPackets.map {
                USBIPIsoPacketDescriptor(offset: $0.offset, length: $0.length, actualLength: 0, status: status)
            }))
    }

    private func sendUnlinkReply(seqnum: UInt32, devid: UInt32, status: Int32) {
        trace("RET_UNLINK seq \(seqnum) status \(status)")
        let response = USBIPUnlinkResponse(seqnum: seqnum, devid: devid, direction: 0, ep: 0, status: status)
        if let data = try? response.encode() {
            send(data)
        }
    }

    private func deliver(_ response: USBIPSubmitResponse) {
        trace("RET_SUBMIT seq \(response.seqnum) status \(response.status) length \(response.actualLength)"
              + (response.transferBuffer.map { " data \($0.prefix(16).map { String(format: "%02x", $0) }.joined())" } ?? ""))
        do {
            send(try response.encode())
        } catch {
            logger.error("Could not encode a reply for seqnum \(response.seqnum): \(error)")
        }
    }

    /// Whether every URB is logged: set USBIPD_TRACE in the daemon's environment to see
    /// what a device's client asks for and what comes back.
    private static let tracing = ProcessInfo.processInfo.environment["USBIPD_TRACE"] != nil

    private func trace(_ message: @autoclosure () -> String) {
        if Self.tracing {
            logger.info("\(busid): \(message())")
        }
    }
}

// IOUSBHostDeviceIO.swift
// Serves one USB device to a USB/IP client through IOUSBHost.

import Foundation
import IOKit
import IOKit.usb
import IOUSBHost
import Common

/// kIOMessageServiceIsTerminated, defined with a macro Swift does not import.
private let kIOMessageServiceIsTerminatedValue: UInt32 = 0xE000_0010

/// Why a device could not be opened for serving.
public enum USBDeviceOpenError: Error, CustomStringConvertible, LocalizedError, Equatable {
    public var errorDescription: String? { description }

    case notFound(busid: String)
    /// macOS drivers hold the device, and only root may take it from them.
    case captureNeedsRoot(busid: String, holders: [String])
    /// The device carries mounted volumes. Taking it would cut them off unflushed.
    case volumesMounted(busid: String, mountPoints: [String])
    /// Interfaces stayed held after the device was captured.
    case interfacesStillHeld(busid: String, interfaces: [UInt8], holders: [String])
    /// The capture freed a storage interface, but macOS lets only a process with Full
    /// Disk Access open it. `launchedFrom` is the chain of processes this one was
    /// started from, the app among them being the one macOS asks about.
    case storageNeedsFullDiskAccess(busid: String, interface: UInt8, launchedFrom: [String])
    case openFailed(busid: String, operation: String, result: IOReturn)

    public var description: String {
        switch self {
        case .notFound(let busid):
            return "No USB device \(busid) is attached"
        case .captureNeedsRoot(let busid, let holders):
            return "macOS drivers hold \(busid) (\(holders.joined(separator: ", "))); "
                + "taking the device from them needs the daemon to run as root"
        case .volumesMounted(let busid, let mountPoints):
            return "\(busid) has mounted volumes (\(mountPoints.joined(separator: ", "))); "
                + "eject them first, or they would be cut off without being flushed"
        case .interfacesStillHeld(let busid, let interfaces, let holders):
            let list = interfaces.map(String.init).joined(separator: ", ")
            return "macOS would not release interface \(list) of \(busid) "
                + "(\(holders.joined(separator: ", "))). If that is a storage interface, "
                + "`usbipd kext \(busid)` writes a codeless kext that keeps its driver off "
                + "this device"
        case .storageNeedsFullDiskAccess(let busid, let interface, let launchedFrom):
            let refusal = "macOS let go of \(busid), but opening its storage interface \(interface) "
                + "needs Full Disk Access, and this process does not have it (started from: "
                + "\(launchedFrom.joined(separator: " < ")))."
            if let app = launchedFrom.first(where: { $0.hasSuffix(".app") }) {
                return refusal + " Grant it to \(app), which this usbipd was started from, in "
                    + "System Settings > Privacy & Security > Full Disk Access, restart that app, "
                    + "and try again"
            }
            // Over SSH there is no app in the chain, and the check refused a daemon there
            // although the session itself could read files Full Disk Access protects.
            return refusal + " It was not started from an app. Start the daemon from a terminal "
                + "app that has Full Disk Access; one started over SSH is refused. A daemon "
                + "started at boot would need the grant on the usbipd binary itself, which has "
                + "not been tested"
        case .openFailed(let busid, let operation, let result):
            return "\(operation) failed for \(busid): \(USBIOReturn.describe(result))"
        }
    }
}

/// One USB device opened through IOUSBHost, with every interface of its current
/// configuration open and every endpoint of their current alternate settings ready.
///
/// IOUSBHost rather than the COM-style IOUSBLib the rest of the project uses, for what
/// it can do that IOUSBLib cannot from userspace: capture a device from the drivers
/// macOS bound to it (as root), select a configuration without handing the new
/// interfaces to those drivers, and queue isochronous transfers as lists of
/// per-interval transactions, which is exactly how USB/IP describes them.
///
/// A device macOS does not hold is opened as is. One it does is captured: IOUSBHost
/// terminates the drivers and clients on it, and gives it back — reset, drivers
/// rematched — when this object is closed.
public final class IOUSBHostDeviceIO: USBDeviceIO, @unchecked Sendable {
    public let busid: String

    /// Whether the device was taken from macOS's drivers.
    public let captured: Bool

    private let device: IOUSBHostDevice
    private let queue: DispatchQueue
    private let logger = Logger(subsystem: "com.usbipd.mac", category: "device-io")

    /// Guards everything below. Transfers complete on `queue` while the attachment
    /// submits from its own.
    private let lock = NSLock()
    private var interfaces: [UInt8: IOUSBHostInterface] = [:]
    private var alternates: [UInt8: UInt8] = [:]
    private var pipes: [UInt8: IOUSBHostPipe] = [:]
    private var endpoints: [UInt8: USBEndpointInfo] = [:]
    private var bufferPool: [Int: [NSMutableData]] = [:]
    private var isClosed = false

    /// Receives a line for each step of opening the device, for `usbipd probe`.
    private let trace: ((String) -> Void)?

    private init(busid: String, device: IOUSBHostDevice, queue: DispatchQueue, captured: Bool,
                 trace: ((String) -> Void)? = nil) {
        self.busid = busid
        self.device = device
        self.queue = queue
        self.captured = captured
        self.trace = trace
    }

    deinit {
        close()
    }

    // MARK: - Opening

    /// Open the device at `busid` for serving, taking it from macOS's drivers if they
    /// hold any of its interfaces.
    ///
    /// - Parameters:
    ///   - trace: receives a line for each step, which `usbipd probe` prints.
    ///   - onTerminated: called when the device goes away, from IOUSBHost's queue.
    public static func open(busid: String, trace: ((String) -> Void)? = nil,
                            onTerminated: @escaping @Sendable () -> Void) throws -> IOUSBHostDeviceIO {
        guard let service = findService(busid: busid) else {
            throw USBDeviceOpenError.notFound(busid: busid)
        }
        defer { IOObjectRelease(service) }

        let queue = DispatchQueue(label: "com.usbipd.mac.device.\(busid)")
        let handler: IOUSBHostInterestHandler = { _, messageType, _ in
            if messageType == kIOMessageServiceIsTerminatedValue {
                onTerminated()
            }
        }

        // Try it as it is first. A device nothing has claimed opens without capture,
        // and capture resets the device when it is given back, which is not worth
        // doing to one that never needed it.
        trace?("Opening \(busid) as it is. Its interfaces:")
        interfaceReport(under: service).forEach { trace?("  \($0)") }
        var heldInterfaces: [UInt8] = []
        let plain: IOUSBHostDevice?
        do {
            plain = try IOUSBHostDevice(__ioService: service, options: [], queue: queue, interestHandler: handler)
        } catch {
            trace?("The device itself would not open (\(USBIOReturn.describe(ioReturn(from: error))))")
            plain = nil
        }
        if let plain = plain {
            let io = IOUSBHostDeviceIO(busid: busid, device: plain, queue: queue, captured: false, trace: trace)
            do {
                try io.openInterfaces(of: service)
                trace?("Opened without capture")
                return io
            } catch HeldInterfaces.held(let numbers) {
                heldInterfaces = numbers
                io.close()
            }
        }

        // Something holds it. Capturing it terminates whatever that is, which IOUSBHost
        // allows root without an entitlement.
        let holders = driverNames(under: service, interfaces: heldInterfaces)
        guard geteuid() == 0 else {
            throw USBDeviceOpenError.captureNeedsRoot(busid: busid, holders: holders)
        }

        // A capture terminates the storage stack with no unmount. Refuse while a
        // volume on the device is mounted rather than risk what is on it.
        let mounted = mountedVolumes(under: service)
        guard mounted.isEmpty else {
            throw USBDeviceOpenError.volumesMounted(busid: busid, mountPoints: mounted)
        }

        trace?("Capturing \(busid) from \(holders.joined(separator: ", "))")
        let capturedDevice: IOUSBHostDevice
        do {
            capturedDevice = try IOUSBHostDevice(__ioService: service, options: [.deviceCapture],
                                                 queue: queue, interestHandler: handler)
        } catch {
            throw USBDeviceOpenError.openFailed(busid: busid, operation: "Capturing the device",
                                                result: ioReturn(from: error))
        }
        trace?("Captured")

        // The capture terminates the drivers, but the interfaces they were on can stay
        // behind with them. Selecting the configuration again, unmatched, gives fresh
        // interfaces nothing has claimed.
        let io = IOUSBHostDeviceIO(busid: busid, device: capturedDevice, queue: queue, captured: true, trace: trace)
        do {
            try io.openInterfaces(of: service, reselectingConfiguration: true)
        } catch HeldInterfaces.held(let numbers) {
            let stillHeld = driverNames(under: service, interfaces: numbers)
            io.close()
            throw USBDeviceOpenError.interfacesStillHeld(busid: busid, interfaces: numbers,
                                                         holders: stillHeld.isEmpty ? holders : stillHeld)
        }
        if io.releaseMediumLocks() {
            // The unlock moved the bulk endpoints' data toggles off DATA0, where a client
            // that has just configured the device expects them; its SET_CONFIGURATION is
            // a no-op here, since the configuration is already selected. With a BD-RE
            // drive, the client's first command block afterwards was acknowledged and
            // never acted on, as a device does with a packet whose toggle marks it a
            // repeat, most likely because the client's SET_INTERFACE reset the device's
            // toggles but not the host's. Its first command hung for 20 seconds.
            // Selecting the configuration again resets both sides, and leaves the device
            // as one just configured.
            do {
                try io.reselectConfiguration(of: service)
            } catch HeldInterfaces.held(let numbers) {
                let stillHeld = driverNames(under: service, interfaces: numbers)
                io.close()
                throw USBDeviceOpenError.interfacesStillHeld(busid: busid, interfaces: numbers,
                                                             holders: stillHeld.isEmpty ? holders : stillHeld)
            }
        }
        io.logger.info("Captured \(busid) from macOS's drivers (\(holders.joined(separator: ", ")))")
        return io
    }

    private enum HeldInterfaces: Error {
        case held([UInt8])
    }

    /// How one round of opening a configuration's interfaces came out.
    private enum OpenOutcome {
        case opened([UInt8: IOUSBHostInterface])
        /// Interfaces a driver still holds.
        case held([UInt8])
        /// A storage interface no driver holds, refused by the Full Disk Access check.
        case needsFullDiskAccess(UInt8)
    }

    /// Close the open interfaces, then select the configuration again, unmatched, and
    /// open them anew.
    private func reselectConfiguration(of service: io_service_t) throws {
        lock.lock()
        let old = Array(interfaces.values)
        interfaces = [:]
        alternates = [:]
        pipes = [:]
        endpoints = [:]
        lock.unlock()
        old.forEach { $0.destroy() }
        try openInterfaces(of: service, reselectingConfiguration: true, heading: "Before selecting it again:")
    }

    /// Open every interface of the current configuration, configuring the device first
    /// if nothing has, and selecting the configuration again first if asked to.
    private func openInterfaces(of service: io_service_t, reselectingConfiguration: Bool = false,
                                heading: String = "After the capture:") throws {
        if device.configurationDescriptor == nil {
            let first: UnsafePointer<IOUSBConfigurationDescriptor>
            do {
                first = try device.configurationDescriptor(with: 0)
                try device.__configure(withValue: Int(first.pointee.bConfigurationValue), matchInterfaces: false)
                trace?("Configured with configuration \(first.pointee.bConfigurationValue), unmatched")
            } catch {
                throw USBDeviceOpenError.openFailed(busid: busid, operation: "Configuring the device",
                                                    result: ioReturn(from: error))
            }
        }

        guard let configuration = device.configurationDescriptor else {
            trace?("The device has no configuration")
            return
        }
        let expected = Int(configuration.pointee.bNumInterfaces)
        let value = configuration.pointee.bConfigurationValue

        // A capture terminates every client of the device, and may leave the interfaces
        // behind with drivers that are going or come back. A fresh selection of the
        // configuration, unmatched, makes interfaces nothing holds.
        if captured && reselectingConfiguration {
            Self.waitQuiet(service)
            trace?(heading)
            Self.interfaceReport(under: service).forEach { trace?("  \($0)") }
            do {
                try device.__configure(withValue: 0, matchInterfaces: false)
                trace?("Selected configuration 0")
            } catch {
                trace?("Selecting configuration 0 failed: \(USBIOReturn.describe(ioReturn(from: error)))")
            }
            Self.waitQuiet(service)
            do {
                try device.__configure(withValue: Int(value), matchInterfaces: false)
                trace?("Selected configuration \(value) again, unmatched")
            } catch {
                throw USBDeviceOpenError.openFailed(busid: busid, operation: "Reconfiguring the device",
                                                    result: ioReturn(from: error))
            }
            Self.waitQuiet(service)
            trace?("After selecting it again:")
            Self.interfaceReport(under: service).forEach { trace?("  \($0)") }
        }

        // A driver a capture terminated can take a moment to finish going, so on a
        // captured device a held interface is tried again for a few seconds before it
        // counts as held.
        let attempts = captured ? 8 : 1
        var last = OpenOutcome.held([])
        for attempt in 1...attempts {
            let services = waitForInterfaces(of: service, expected: expected)
            last = try openAll(services)
            services.forEach { IOObjectRelease($0) }

            if case .opened(let opened) = last {
                install(opened)
                return
            }
            if attempt < attempts {
                Thread.sleep(forTimeInterval: 0.5)
                Self.waitQuiet(service)
            }
        }

        switch last {
        case .needsFullDiskAccess(let number):
            throw USBDeviceOpenError.storageNeedsFullDiskAccess(busid: busid, interface: number,
                                                                launchedFrom: ProcessLineage.chain())
        case .held(let numbers):
            throw HeldInterfaces.held(numbers)
        case .opened:
            return
        }
    }

    /// One attempt at opening every interface. Anything opened is let go again unless
    /// all of them open.
    private func openAll(_ services: [io_service_t]) throws -> OpenOutcome {
        var opened: [UInt8: IOUSBHostInterface] = [:]
        var held: [UInt8] = []
        var fullDiskAccess: UInt8?
        for interfaceService in services {
            let number = Self.uint8Property(interfaceService, "bInterfaceNumber") ?? UInt8(opened.count + held.count)
            do {
                opened[number] = try IOUSBHostInterface(__ioService: interfaceService, options: [],
                                                        queue: queue, interestHandler: nil)
            } catch {
                // An interface a driver holds does not always fail with
                // kIOReturnExclusiveAccess: macOS 27 reports kIOReturnInternalError for
                // one its mass storage driver has. Any failure on an interface with a
                // driver attached is taken as that driver's doing.
                //
                // With no driver left, kIOReturnInternalError on a storage interface is
                // macOS's Full Disk Access check: a process without it is refused
                // whatever its privileges, and one with it opens the interface at once.
                let result = ioReturn(from: error)
                let drivers = Self.driverNames(of: interfaceService)
                trace?("Interface \(number) would not open (\(USBIOReturn.describe(result))); "
                       + (drivers.isEmpty ? "no driver on it" : "on it: \(drivers.joined(separator: ", "))"))
                if drivers.isEmpty && result == USBIOReturn.internalError
                    && Self.uint8Property(interfaceService, "bInterfaceClass") == 0x08 {
                    fullDiskAccess = number
                } else if result == USBIOReturn.exclusiveAccess || result == USBIOReturn.notPermitted
                            || !drivers.isEmpty {
                    held.append(number)
                } else {
                    opened.values.forEach { $0.destroy() }
                    throw USBDeviceOpenError.openFailed(busid: busid, operation: "Opening interface \(number)",
                                                        result: result)
                }
            }
        }

        if let number = fullDiskAccess {
            opened.values.forEach { $0.destroy() }
            return .needsFullDiskAccess(number)
        }
        guard held.isEmpty else {
            opened.values.forEach { $0.destroy() }
            return .held(held.sorted())
        }
        return .opened(opened)
    }

    /// Take over a set of open interfaces and their endpoints.
    private func install(_ opened: [UInt8: IOUSBHostInterface]) {
        lock.lock()
        defer { lock.unlock() }
        interfaces = opened
        alternates = [:]
        pipes = [:]
        endpoints = [:]
        for (number, interface) in opened {
            let alternate = interface.interfaceDescriptor.pointee.bAlternateSetting
            alternates[number] = alternate
            addEndpointsLocked(of: interface, number: number, alternate: alternate)
        }
    }

    /// Wait for IOKit to finish matching and terminating below a service.
    private static func waitQuiet(_ service: io_service_t, seconds: UInt32 = 2) {
        var wait = mach_timespec_t(tv_sec: seconds, tv_nsec: 0)
        _ = IOServiceWaitQuiet(service, &wait)
    }

    /// One line per interface below a device: number, alternate setting, class, registry
    /// entry, and whatever is attached to it.
    static func interfaceReport(under service: io_service_t) -> [String] {
        let services = interfaceServices(under: service)
        defer { services.forEach { IOObjectRelease($0) } }
        guard !services.isEmpty else { return ["no interfaces"] }

        return services.map { interfaceService in
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(interfaceService, &entryID)
            let number = uint8Property(interfaceService, "bInterfaceNumber").map(String.init) ?? "?"
            let alternate = uint8Property(interfaceService, "bAlternateSetting").map(String.init) ?? "?"
            let interfaceClass = uint8Property(interfaceService, "bInterfaceClass").map { String(format: "%02x", $0) } ?? "?"
            let drivers = driverNames(of: interfaceService)
            return "interface \(number) alternate \(alternate) class \(interfaceClass) "
                + "(entry \(String(format: "0x%llx", entryID))): "
                + (drivers.isEmpty ? "no driver" : drivers.joined(separator: ", "))
        }
    }

    /// The device's interface services once `expected` of them exist, or whatever exists
    /// after two seconds. The caller releases them.
    private func waitForInterfaces(of service: io_service_t, expected: Int) -> [io_service_t] {
        var services = Self.interfaceServices(under: service)
        var waited = 0
        while services.count < expected && waited < 20 {
            services.forEach { IOObjectRelease($0) }
            Thread.sleep(forTimeInterval: 0.1)
            waited += 1
            services = Self.interfaceServices(under: service)
        }
        return services
    }

    /// Make the pipes of one interface's alternate setting available. Called with the
    /// lock held.
    private func addEndpointsLocked(of interface: IOUSBHostInterface, number: UInt8, alternate: UInt8) {
        let configuration = interface.configurationDescriptor
        guard let descriptor = Self.interfaceDescriptor(in: configuration, number: number, alternate: alternate) else {
            logger.warning("Interface \(number) has no alternate setting \(alternate)")
            return
        }

        var current = IOUSBGetNextEndpointDescriptor(configuration, descriptor, nil)
        while let endpoint = current {
            let address = endpoint.pointee.bEndpointAddress
            let type: USBTransferType
            switch endpoint.pointee.bmAttributes & 0x03 {
            case 1: type = .isochronous
            case 2: type = .bulk
            case 3: type = .interrupt
            default: type = .control
            }
            let maxPacket = Int(UInt16(littleEndian: endpoint.pointee.wMaxPacketSize) & 0x07FF)

            do {
                pipes[address] = try interface.copyPipe(withAddress: Int(address))
                endpoints[address] = USBEndpointInfo(address: address, transferType: type,
                                                     maxPacketSize: maxPacket, interfaceNumber: number)
            } catch {
                logger.warning("No pipe for endpoint \(String(format: "0x%02x", address)): \(ioReturn(from: error))")
            }

            current = IOUSBGetNextEndpointDescriptor(
                configuration, descriptor, UnsafePointer<IOUSBDescriptorHeader>(OpaquePointer(endpoint)))
        }
    }

    /// The open interfaces, each with its current alternate setting and endpoints.
    public var interfaceSummary: [(number: UInt8, alternate: UInt8, endpoints: [USBEndpointInfo])] {
        lock.lock()
        defer { lock.unlock() }
        return interfaces.keys.sorted().map { number in
            let own = endpoints.values.filter { $0.interfaceNumber == number }.sorted { $0.address < $1.address }
            return (number: number, alternate: alternates[number] ?? 0, endpoints: own)
        }
    }

    // MARK: - USBDeviceIO

    public func endpoint(_ address: UInt8) -> USBEndpointInfo? {
        lock.lock()
        defer { lock.unlock() }
        return endpoints[address]
    }

    public var currentConfiguration: UInt8? {
        return device.configurationDescriptor?.pointee.bConfigurationValue
    }

    public func makeBuffer(length: Int) -> NSMutableData {
        guard length > 0 else { return NSMutableData() }

        // A storage client asks for the same few sizes over and over (a 31-byte command,
        // a 64 KiB read, a 13-byte status), and making one costs a call into the kernel
        // and a mapping. Buffers come back through recycle and are handed out again.
        lock.lock()
        if var free = bufferPool[length], let buffer = free.popLast() {
            bufferPool[length] = free
            lock.unlock()
            return buffer
        }
        lock.unlock()

        // Memory IOUSBHost maps for the controller saves a copy on every transfer. It
        // cannot be resized, which is fine for a buffer made to the request's size.
        if let data = try? device.ioData(withCapacity: length) {
            return data
        }
        return NSMutableData(length: length) ?? NSMutableData()
    }

    public func recycle(_ buffer: NSMutableData) {
        let length = buffer.length
        guard length > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        var free = bufferPool[length] ?? []
        if free.count < Self.buffersKeptPerSize {
            free.append(buffer)
            bufferPool[length] = free
        }
    }

    /// Enough for a stream with several transfers of one size in flight.
    private static let buffersKeptPerSize = 16

    public func enqueueControl(_ setup: USBSetupPacket, data: NSMutableData?,
                               completion: @escaping @Sendable (IOReturn, Int) -> Void) throws {
        do {
            // No timeout: a client that gives up on a request cancels it with UNLINK.
            try owner(of: setup).__enqueue(Self.request(setup), data: data, completionTimeout: 0) {
                status, transferred in
                completion(status, transferred)
            }
        } catch {
            throw USBDeviceIOError(ioReturn(from: error), "Control request")
        }
    }

    public func sendControl(_ setup: USBSetupPacket, data: NSMutableData?) throws -> Int {
        var transferred = 0
        do {
            try owner(of: setup).__send(Self.request(setup), data: data, bytesTransferred: &transferred,
                                        completionTimeout: 5)
        } catch {
            throw USBDeviceIOError(ioReturn(from: error), "Control request")
        }
        return transferred
    }

    /// The object to send a control request through: the interface it is addressed to,
    /// or the interface owning the endpoint it is addressed to, as a driver would send
    /// it; otherwise the device.
    private func owner(of setup: USBSetupPacket) -> IOUSBHostObject {
        let target = UInt8(truncatingIfNeeded: setup.wIndex)
        lock.lock()
        defer { lock.unlock() }
        switch setup.bmRequestType & 0x1F {
        case 0x01:
            return interfaces[target] ?? device
        case 0x02:
            if let number = endpoints[target]?.interfaceNumber, let interface = interfaces[number] {
                return interface
            }
            return device
        default:
            return device
        }
    }

    public func enqueueTransfer(endpoint: UInt8, data: NSMutableData?,
                                completion: @escaping @Sendable (IOReturn, Int) -> Void) throws {
        let pipe = try self.pipe(endpoint)
        do {
            // No timeout, as for control requests. IOUSBHost requires 0 for interrupt
            // endpoints in any case.
            try pipe.enqueueIORequest(with: data, completionTimeout: 0) { status, transferred in
                completion(status, transferred)
            }
        } catch {
            throw USBDeviceIOError(ioReturn(from: error), "Transfer on \(String(format: "0x%02x", endpoint))")
        }
    }

    public func enqueueIsochronous(endpoint: UInt8, data: NSMutableData, transactions: [USBIsochronousTransaction],
                                   completion: @escaping @Sendable (IOReturn, [USBIsochronousTransaction]) -> Void) throws {
        guard #available(macOS 12.0, *) else {
            throw USBDeviceIOError(USBIOReturn.unsupported, "Isochronous transfers need macOS 12")
        }
        let pipe = try self.pipe(endpoint)

        // The list has to outlive the call: IOUSBHost fills it in on completion.
        let count = transactions.count
        let list = UnsafeMutablePointer<IOUSBHostIsochronousTransaction>.allocate(capacity: max(count, 1))
        for (index, transaction) in transactions.enumerated() {
            list[index] = IOUSBHostIsochronousTransaction(
                status: kIOReturnSuccess, requestCount: transaction.requestCount, offset: transaction.offset,
                completeCount: 0, timeStamp: 0, options: [])
        }
        let addressList = UInt(bitPattern: list)

        do {
            // Frame 0 starts the transfer on the next frame the endpoint can use,
            // straight after whatever is already queued on it (XHCI only, which is every
            // controller macOS 12 runs on).
            try pipe.enqueueIORequest(with: data, transactionList: list, transactionListCount: count,
                                      firstFrameNumber: 0, options: []) { status, completed in
                let results = (0..<count).map { index -> USBIsochronousTransaction in
                    let entry = completed[index]
                    return USBIsochronousTransaction(requestCount: entry.requestCount, offset: entry.offset,
                                                     completeCount: entry.completeCount, status: entry.status)
                }
                UnsafeMutablePointer<IOUSBHostIsochronousTransaction>(bitPattern: addressList)?.deallocate()
                completion(status, results)
            }
        } catch {
            list.deallocate()
            throw USBDeviceIOError(ioReturn(from: error), "Isochronous transfer on \(String(format: "0x%02x", endpoint))")
        }
    }

    public func abortControl() {
        // Requests to an interface went through that interface's object.
        lock.lock()
        let owners: [IOUSBHostObject] = [device] + Array(interfaces.values)
        lock.unlock()
        for owner in owners {
            do {
                try owner.__abortDeviceRequests(with: .asynchronous)
            } catch {
                logger.debug("Aborting control requests: \(ioReturn(from: error))")
            }
        }
    }

    public func abort(endpoint: UInt8) {
        guard let pipe = try? pipe(endpoint) else { return }
        do {
            try pipe.__abort(with: .asynchronous)
        } catch {
            logger.debug("Aborting \(String(format: "0x%02x", endpoint)): \(ioReturn(from: error))")
        }
    }

    public func clearHalt(endpoint: UInt8) throws {
        let pipe = try self.pipe(endpoint)
        do {
            try pipe.clearStall()
        } catch {
            throw USBDeviceIOError(ioReturn(from: error), "Clearing the halt on \(String(format: "0x%02x", endpoint))")
        }
    }

    public func setConfiguration(_ value: UInt8) throws {
        guard value != currentConfiguration else { return }

        let service = device.ioService
        lock.lock()
        let old = Array(interfaces.values)
        interfaces = [:]
        alternates = [:]
        pipes = [:]
        endpoints = [:]
        lock.unlock()
        old.forEach { $0.destroy() }

        do {
            // Not matched: the drivers this device was taken from would otherwise claim
            // the new configuration's interfaces straight away.
            try device.__configure(withValue: Int(value), matchInterfaces: false)
        } catch {
            throw USBDeviceIOError(ioReturn(from: error), "Selecting configuration \(value)")
        }

        // Configuration 0 is the unconfigured state: no interfaces to open, and opening
        // them would configure the device again behind the client's back.
        guard value != 0 else { return }

        do {
            try openInterfaces(of: service)
        } catch HeldInterfaces.held(let numbers) {
            throw USBDeviceIOError(USBIOReturn.exclusiveAccess,
                                   "Opening interface \(numbers.map(String.init).joined(separator: ", "))")
        }
    }

    public func setAlternateSetting(interface number: UInt8, alternate: UInt8) throws {
        lock.lock()
        let interface = interfaces[number]
        lock.unlock()
        guard let interface = interface else {
            throw USBDeviceIOError(USBIOReturn.badArgument, "Interface \(number) is not open")
        }

        do {
            try interface.selectAlternateSetting(Int(alternate))
        } catch {
            let result = ioReturn(from: error)
            // The setting already in effect: nothing changed, and nothing to rebuild.
            if result == USBIOReturn.hostRedundant {
                return
            }
            throw USBDeviceIOError(result, "Selecting alternate setting \(alternate) of interface \(number)")
        }

        // Selecting a setting closes the interface's pipes, so the old ones are gone
        // whatever happens next.
        lock.lock()
        defer { lock.unlock() }
        for (address, info) in endpoints where info.interfaceNumber == number {
            endpoints[address] = nil
            pipes[address] = nil
        }
        alternates[number] = alternate
        addEndpointsLocked(of: interface, number: number, alternate: alternate)
    }

    public func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        let openPipes = Array(pipes.values)
        let openInterfaces = Array(interfaces.values)
        pipes = [:]
        endpoints = [:]
        interfaces = [:]
        // Pooled buffers are mapped through the device's connection; let them go first.
        bufferPool = [:]
        lock.unlock()

        openPipes.forEach { try? $0.__abort(with: .synchronous) }
        try? device.__abortDeviceRequests(with: .synchronous)
        openInterfaces.forEach { $0.destroy() }

        // For a captured device this resets it and lets macOS's drivers match it again,
        // which is how it is given back.
        device.destroy()
        if captured {
            logger.info("Gave \(busid) back to macOS")
        }
    }

    // MARK: - What macOS's storage drivers leave behind

    /// Unlock the medium of every logical unit behind each bulk-only storage interface,
    /// which macOS's drivers may have locked and the capture left locked. See
    /// `BulkOnlyMediumLock`. Called once a captured device's interfaces are open, before
    /// any client has it. Returns whether anything was sent to the device.
    fileprivate func releaseMediumLocks() -> Bool {
        lock.lock()
        let storage = interfaces.compactMap { number, interface -> (number: UInt8, inbound: UInt8, outbound: UInt8)? in
            let descriptor = interface.interfaceDescriptor.pointee
            guard descriptor.bInterfaceClass == 0x08, descriptor.bInterfaceProtocol == 0x50 else { return nil }
            let bulk = endpoints.values.filter { $0.interfaceNumber == number && $0.transferType == .bulk }
            guard let inbound = bulk.first(where: { $0.address & 0x80 != 0 })?.address,
                  let outbound = bulk.first(where: { $0.address & 0x80 == 0 })?.address else { return nil }
            return (number: number, inbound: inbound, outbound: outbound)
        }
        lock.unlock()

        for interface in storage.sorted(by: { $0.number < $1.number }) {
            let pipes = CapturedBulkPipes(io: self, interface: interface.number,
                                          inbound: interface.inbound, outbound: interface.outbound)
            for lun in 0...maxLUN(of: interface.number) {
                let line: String
                switch BulkOnlyMediumLock.release(lun: lun, over: pipes) {
                case .released:
                    line = "Interface \(interface.number), LUN \(lun): medium removal allowed"
                case .refused(let sense):
                    line = "Interface \(interface.number), LUN \(lun): medium removal not allowed (\(sense))"
                case .failed(let reason):
                    line = "Interface \(interface.number), LUN \(lun): allowing medium removal failed (\(reason)); "
                        + "the transport was reset"
                }
                trace?(line)
            }
        }
        return !storage.isEmpty
    }

    /// GET MAX LUN: the highest logical unit number of a bulk-only interface. A device
    /// with one unit may stall the request.
    private func maxLUN(of interface: UInt8) -> UInt8 {
        let setup = USBSetupPacket(bmRequestType: 0xA1, bRequest: 0xFE, wValue: 0,
                                   wIndex: UInt16(interface), wLength: 1)
        guard let data = NSMutableData(length: 1),
              let count = try? sendControl(setup, data: data), count == 1 else { return 0 }
        return min(data.bytes.load(as: UInt8.self), 15)
    }

    /// One bulk transfer, waited for, with a timeout. Only for what the daemon sends a
    /// device itself; a client's transfers are queued and never time out.
    fileprivate func transferSync(endpoint: UInt8, data: NSMutableData, timeout: TimeInterval) throws -> Int {
        let pipe = try self.pipe(endpoint)
        let done = DispatchSemaphore(value: 0)
        let outcome = TransferOutcome()
        let name = "Transfer on \(String(format: "0x%02x", endpoint))"
        do {
            try pipe.enqueueIORequest(with: data, completionTimeout: timeout) { status, transferred in
                outcome.set(status, transferred)
                done.signal()
            }
        } catch {
            throw USBDeviceIOError(ioReturn(from: error), name)
        }
        if done.wait(timeout: .now() + timeout + 2) == .timedOut {
            try? pipe.__abort(with: .synchronous)
            throw USBDeviceIOError(USBIOReturn.timeout, name)
        }
        let (status, transferred) = outcome.value
        guard status == kIOReturnSuccess else {
            throw USBDeviceIOError(status, name)
        }
        return transferred
    }

    // MARK: - Helpers

    private func pipe(_ endpoint: UInt8) throws -> IOUSBHostPipe {
        lock.lock()
        defer { lock.unlock() }
        guard let pipe = pipes[endpoint] else {
            throw USBDeviceIOError(USBIOReturn.badArgument, "No endpoint \(String(format: "0x%02x", endpoint))")
        }
        return pipe
    }

    private static func request(_ setup: USBSetupPacket) -> IOUSBDeviceRequest {
        var request = IOUSBDeviceRequest()
        request.bmRequestType = setup.bmRequestType
        request.bRequest = setup.bRequest
        request.wValue = setup.wValue
        request.wIndex = setup.wIndex
        request.wLength = setup.wLength
        return request
    }

    /// The interface descriptor for one alternate setting of one interface.
    private static func interfaceDescriptor(in configuration: UnsafePointer<IOUSBConfigurationDescriptor>,
                                            number: UInt8, alternate: UInt8) -> UnsafePointer<IOUSBInterfaceDescriptor>? {
        var current = IOUSBGetNextInterfaceDescriptor(configuration, nil)
        while let descriptor = current {
            if descriptor.pointee.bInterfaceNumber == number && descriptor.pointee.bAlternateSetting == alternate {
                return descriptor
            }
            current = IOUSBGetNextInterfaceDescriptor(
                configuration, UnsafePointer<IOUSBDescriptorHeader>(OpaquePointer(descriptor)))
        }
        return nil
    }

    /// The IOUSBHostDevice service whose locationID gives this busid. The caller
    /// releases it.
    static func findService(busid: String) -> io_service_t? {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return nil }
        var iterator: io_iterator_t = 0
        // MACH_PORT_NULL is the default main port, spelled without kIOMainPortDefault
        // (macOS 12) or the deprecated kIOMasterPortDefault.
        guard IOServiceGetMatchingServices(mach_port_t(MACH_PORT_NULL), matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { return nil }
            if let locationID = uint32Property(service, "locationID") {
                let identity = USBIPDeviceIdentity.busID(forLocationID: locationID)
                if "\(identity.busID)-\(identity.deviceID)" == busid {
                    return service
                }
            }
            IOObjectRelease(service)
        }
    }

    /// The device's interface services, in the service plane below it. The caller
    /// releases them.
    private static func interfaceServices(under service: io_service_t) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var found: [io_service_t] = []
        while true {
            let child = IOIteratorNext(iterator)
            guard child != 0 else { break }
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0 {
                found.append(child)
            } else {
                IOObjectRelease(child)
            }
        }
        return found
    }

    /// Class names of the drivers attached to the given interfaces (all of them when the
    /// list is empty), for messages.
    private static func driverNames(under service: io_service_t, interfaces: [UInt8]) -> [String] {
        var names: Set<String> = []
        let services = interfaceServices(under: service)
        defer { services.forEach { IOObjectRelease($0) } }

        for interfaceService in services {
            if !interfaces.isEmpty,
               let number = uint8Property(interfaceService, "bInterfaceNumber"),
               !interfaces.contains(number) {
                continue
            }
            names.formUnion(driverNames(of: interfaceService))
        }
        return names.sorted()
    }

    /// Class names of what is attached to one interface, leaving out the nodes every
    /// interface has.
    private static func driverNames(of interfaceService: io_service_t) -> [String] {
        let structural: Set<String> = ["IOUSBHostInterface", "IOUSBInterface", "AppleUSBHostCompositeDevice",
                                       "AppleUSBHostDeviceUserClient", "IOUSBHostDeviceUserClient",
                                       "AppleUSBHostInterfaceUserClient", "IOUSBHostInterfaceUserClient",
                                       "AppleUSBHostFrameworkInterfaceClient"]
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(interfaceService, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var names: [String] = []
        while true {
            let child = IOIteratorNext(iterator)
            guard child != 0 else { break }
            if let className = IOObjectCopyClass(child)?.takeRetainedValue() {
                let name = className as String
                if !structural.contains(name) {
                    names.append(name)
                }
            }
            IOObjectRelease(child)
        }
        return names
    }

    /// The configuration and interfaces of the device at `busid`, read from the
    /// IORegistry, for device lists.
    public static func describe(busid: String) -> USBIPDeviceDescription? {
        guard let service = findService(busid: busid) else { return nil }
        defer { IOObjectRelease(service) }

        let services = interfaceServices(under: service)
        defer { services.forEach { IOObjectRelease($0) } }

        var configurationValue: UInt8 = 0
        var interfaces: [(number: UInt8, info: USBIPExportedInterface)] = []
        for interfaceService in services {
            configurationValue = uint8Property(interfaceService, "bConfigurationValue") ?? configurationValue
            let info = USBIPExportedInterface(
                interfaceClass: uint8Property(interfaceService, "bInterfaceClass") ?? 0,
                interfaceSubClass: uint8Property(interfaceService, "bInterfaceSubClass") ?? 0,
                interfaceProtocol: uint8Property(interfaceService, "bInterfaceProtocol") ?? 0)
            interfaces.append((number: uint8Property(interfaceService, "bInterfaceNumber") ?? 0, info: info))
        }

        return USBIPDeviceDescription(
            bcdDevice: UInt16(truncatingIfNeeded: uint32Property(service, "bcdDevice") ?? 0),
            configurationCount: uint8Property(service, "bNumConfigurations") ?? 1,
            configurationValue: configurationValue,
            interfaces: interfaces.sorted { $0.number < $1.number }.map(\.info))
    }

    /// Mount points of volumes on media below this service.
    static func mountedVolumes(under service: io_service_t) -> [String] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(service, kIOServicePlane,
                                            IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var bsdNames: Set<String> = []
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            if IOObjectConformsTo(entry, "IOMedia") != 0,
               let name = IORegistryEntryCreateCFProperty(entry, "BSD Name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String {
                bsdNames.insert(name)
            }
            IOObjectRelease(entry)
        }
        guard !bsdNames.isEmpty else { return [] }

        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let table = mounts else { return [] }

        var mountPoints: [String] = []
        for index in 0..<Int(count) {
            var entry = table[index]
            let from = withUnsafeBytes(of: &entry.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let on = withUnsafeBytes(of: &entry.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            if from.hasPrefix("/dev/"), bsdNames.contains(String(from.dropFirst(5))) {
                mountPoints.append(on)
            }
        }
        return mountPoints
    }

    private static func uint32Property(_ entry: io_registry_entry_t, _ key: String) -> UInt32? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else {
            return nil
        }
        return value.uint32Value
    }

    private static func uint8Property(_ entry: io_registry_entry_t, _ key: String) -> UInt8? {
        return uint32Property(entry, key).map { UInt8(truncatingIfNeeded: $0) }
    }
}

/// The IOReturn behind an error thrown by IOUSBHost, whose NSErrors carry it as the code.
/// A captured storage interface's bulk pipes, for `BulkOnlyMediumLock`.
private struct CapturedBulkPipes: BulkOnlyPipes {
    let io: IOUSBHostDeviceIO
    let interface: UInt8
    let inbound: UInt8
    let outbound: UInt8

    func write(_ data: Data, timeout: TimeInterval) throws {
        _ = try io.transferSync(endpoint: outbound, data: NSMutableData(data: data), timeout: timeout)
    }

    func read(length: Int, timeout: TimeInterval) throws -> Data {
        guard let buffer = NSMutableData(length: length) else {
            throw USBDeviceIOError(USBIOReturn.badArgument, "Reading \(length) bytes")
        }
        let count = try io.transferSync(endpoint: inbound, data: buffer, timeout: timeout)
        return Data(bytes: buffer.bytes, count: min(count, length))
    }

    func clearHalt(inbound isInbound: Bool) throws {
        try io.clearHalt(endpoint: isInbound ? inbound : outbound)
    }

    func resetRecovery() throws {
        let reset = USBSetupPacket(bmRequestType: 0x21, bRequest: 0xFF, wValue: 0,
                                   wIndex: UInt16(interface), wLength: 0)
        _ = try io.sendControl(reset, data: nil)
        try io.clearHalt(endpoint: inbound)
        try io.clearHalt(endpoint: outbound)
    }
}

/// The result of one transfer, set from IOUSBHost's queue and read by the waiting thread.
private final class TransferOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var status: IOReturn = kIOReturnSuccess
    private var transferred = 0

    func set(_ status: IOReturn, _ transferred: Int) {
        lock.lock()
        self.status = status
        self.transferred = transferred
        lock.unlock()
    }

    var value: (IOReturn, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (status, transferred)
    }
}

func ioReturn(from error: Error) -> IOReturn {
    if let ioError = error as? USBDeviceIOError {
        return ioError.result
    }
    return IOReturn(truncatingIfNeeded: (error as NSError).code)
}

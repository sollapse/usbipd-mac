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
    /// Interfaces stayed held after the device was captured. macOS keeps its mass
    /// storage drivers on their interfaces even then.
    case interfacesStillHeld(busid: String, interfaces: [UInt8], holders: [String])
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
                + "(\(holders.joined(separator: ", "))). Mass storage drivers keep their "
                + "interfaces even when the device is captured; `usbipd kext \(busid)` "
                + "writes a codeless kext that keeps them off this device"
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
    private var isClosed = false

    private init(busid: String, device: IOUSBHostDevice, queue: DispatchQueue, captured: Bool) {
        self.busid = busid
        self.device = device
        self.queue = queue
        self.captured = captured
    }

    deinit {
        close()
    }

    // MARK: - Opening

    /// Open the device at `busid` for serving, taking it from macOS's drivers if they
    /// hold any of its interfaces.
    ///
    /// - Parameter onTerminated: called when the device goes away, from IOUSBHost's queue.
    public static func open(busid: String, onTerminated: @escaping @Sendable () -> Void) throws -> IOUSBHostDeviceIO {
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
        var heldInterfaces: [UInt8] = []
        if let plain = try? IOUSBHostDevice(__ioService: service, options: [], queue: queue, interestHandler: handler) {
            let io = IOUSBHostDeviceIO(busid: busid, device: plain, queue: queue, captured: false)
            do {
                try io.openInterfaces(of: service)
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

        let capturedDevice: IOUSBHostDevice
        do {
            capturedDevice = try IOUSBHostDevice(__ioService: service, options: [.deviceCapture],
                                                 queue: queue, interestHandler: handler)
        } catch {
            throw USBDeviceOpenError.openFailed(busid: busid, operation: "Capturing the device",
                                                result: ioReturn(from: error))
        }

        let io = IOUSBHostDeviceIO(busid: busid, device: capturedDevice, queue: queue, captured: true)
        do {
            try io.openInterfaces(of: service)
        } catch HeldInterfaces.held(let numbers) {
            let stillHeld = driverNames(under: service, interfaces: numbers)
            io.close()
            throw USBDeviceOpenError.interfacesStillHeld(busid: busid, interfaces: numbers,
                                                         holders: stillHeld.isEmpty ? holders : stillHeld)
        }
        io.logger.info("Captured \(busid) from macOS's drivers (\(holders.joined(separator: ", ")))")
        return io
    }

    private enum HeldInterfaces: Error {
        case held([UInt8])
    }

    /// Open every interface of the current configuration, configuring the device first
    /// if nothing has.
    private func openInterfaces(of service: io_service_t) throws {
        if device.configurationDescriptor == nil {
            let first: UnsafePointer<IOUSBConfigurationDescriptor>
            do {
                first = try device.configurationDescriptor(with: 0)
                try device.__configure(withValue: Int(first.pointee.bConfigurationValue), matchInterfaces: false)
            } catch {
                throw USBDeviceOpenError.openFailed(busid: busid, operation: "Configuring the device",
                                                    result: ioReturn(from: error))
            }
        }

        guard let configuration = device.configurationDescriptor else { return }
        let expected = Int(configuration.pointee.bNumInterfaces)
        let value = configuration.pointee.bConfigurationValue

        // Interfaces appear as the configuration is applied, so give them a moment.
        var services = waitForInterfaces(of: service, expected: expected)

        // A capture terminates every client of the device. If that took the interfaces
        // with it, select the configuration again to have them made anew, unmatched.
        if services.count < expected && captured {
            services.forEach { IOObjectRelease($0) }
            logger.info("\(busid) lost its interfaces to the capture; selecting configuration \(value) again")
            try? device.__configure(withValue: 0, matchInterfaces: false)
            do {
                try device.__configure(withValue: Int(value), matchInterfaces: false)
            } catch {
                throw USBDeviceOpenError.openFailed(busid: busid, operation: "Reconfiguring the device",
                                                    result: ioReturn(from: error))
            }
            services = waitForInterfaces(of: service, expected: expected)
        }
        defer { services.forEach { IOObjectRelease($0) } }

        var opened: [UInt8: IOUSBHostInterface] = [:]
        var held: [UInt8] = []
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
                let result = ioReturn(from: error)
                if result == USBIOReturn.exclusiveAccess || result == USBIOReturn.notPermitted
                    || !Self.driverNames(of: interfaceService).isEmpty {
                    held.append(number)
                } else {
                    opened.values.forEach { $0.destroy() }
                    throw USBDeviceOpenError.openFailed(busid: busid, operation: "Opening interface \(number)",
                                                        result: result)
                }
            }
        }

        guard held.isEmpty else {
            opened.values.forEach { $0.destroy() }
            throw HeldInterfaces.held(held.sorted())
        }

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
        // Memory IOUSBHost maps for the controller saves a copy on every transfer. It
        // cannot be resized, which is fine for a buffer made to the request's size.
        if length > 0, let data = try? device.ioData(withCapacity: length) {
            return data
        }
        return NSMutableData(length: length) ?? NSMutableData()
    }

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
            throw USBDeviceIOError(ioReturn(from: error), "Selecting alternate setting \(alternate) of interface \(number)")
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
func ioReturn(from error: Error) -> IOReturn {
    if let ioError = error as? USBDeviceIOError {
        return ioError.result
    }
    return IOReturn(truncatingIfNeeded: (error as NSError).code)
}

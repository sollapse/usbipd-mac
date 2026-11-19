// ServerCoordinator.swift
// Core server coordinator for USB/IP server

import Foundation
import Common

/// Active request tracking for concurrent USB request processing
private class ActiveRequestTracker {
    private var requestCounts: [UUID: Int] = [:]
    private let queue = DispatchQueue(label: "com.usbipd.active-requests", attributes: .concurrent)
    
    /// Get current active request count for a client connection
    func getActiveRequestCount(for connectionId: UUID) -> Int {
        return queue.sync {
            return requestCounts[connectionId] ?? 0
        }
    }
    
    /// Increment active request count for a client connection
    func incrementActiveRequests(for connectionId: UUID) {
        queue.async(flags: .barrier) {
            self.requestCounts[connectionId] = (self.requestCounts[connectionId] ?? 0) + 1
        }
    }
    
    /// Decrement active request count for a client connection
    func decrementActiveRequests(for connectionId: UUID) {
        queue.async(flags: .barrier) {
            if let currentCount = self.requestCounts[connectionId], currentCount > 0 {
                self.requestCounts[connectionId] = currentCount - 1
                if self.requestCounts[connectionId] == 0 {
                    self.requestCounts.removeValue(forKey: connectionId)
                }
            }
        }
    }
    
    /// Remove all active requests for a client connection (on disconnect)
    func removeAllRequests(for connectionId: UUID) {
        queue.async(flags: .barrier) {
            self.requestCounts.removeValue(forKey: connectionId)
        }
    }
    
    /// Get total active request count across all connections
    var totalActiveRequests: Int {
        return queue.sync {
            return requestCounts.values.reduce(0, +)
        }
    }
}

/// Statistics tracker for USB operations and server performance
private class USBOperationStatsTracker {
    private var stats = USBOperationStatistics()
    private let queue = DispatchQueue(label: "com.usbipd.usb-stats", attributes: .concurrent)
    private let startTime = Date()
    
    /// Get current statistics snapshot
    func getStatistics() -> USBOperationStatistics {
        return queue.sync {
            return USBOperationStatistics(
                activeRequestCount: stats.activeRequestCount,
                currentLoadPercentage: stats.currentLoadPercentage,
                activeControlRequests: stats.activeControlRequests,
                activeBulkRequests: stats.activeBulkRequests,
                activeInterruptRequests: stats.activeInterruptRequests,
                activeIsochronousRequests: stats.activeIsochronousRequests,
                successfulTransfers: stats.successfulTransfers,
                failedTransfers: stats.failedTransfers,
                totalTransfers: stats.totalTransfers,
                controlTransferCount: stats.controlTransferCount,
                successfulControlTransfers: stats.successfulControlTransfers,
                failedControlTransfers: stats.failedControlTransfers,
                bulkTransferCount: stats.bulkTransferCount,
                successfulBulkTransfers: stats.successfulBulkTransfers,
                failedBulkTransfers: stats.failedBulkTransfers,
                interruptTransferCount: stats.interruptTransferCount,
                successfulInterruptTransfers: stats.successfulInterruptTransfers,
                failedInterruptTransfers: stats.failedInterruptTransfers,
                isochronousTransferCount: stats.isochronousTransferCount,
                successfulIsochronousTransfers: stats.successfulIsochronousTransfers,
                failedIsochronousTransfers: stats.failedIsochronousTransfers,
                averageTransferLatency: stats.averageTransferLatency,
                averageThroughput: stats.averageThroughput,
                peakThroughput: stats.peakThroughput,
                totalBytesTransferred: stats.totalBytesTransferred,
                timeoutErrors: stats.timeoutErrors,
                deviceNotAvailableErrors: stats.deviceNotAvailableErrors,
                invalidParameterErrors: stats.invalidParameterErrors,
                endpointStallErrors: stats.endpointStallErrors,
                otherErrors: stats.otherErrors,
                maxConcurrentRequests: stats.maxConcurrentRequests,
                transferBufferMemoryUsage: stats.transferBufferMemoryUsage,
                activeURBCount: stats.activeURBCount,
                lastUpdateTime: Date()
            )
        }
    }
    
    /// Update active request count and load percentage
    func updateActiveRequests(_ count: Int, maxConcurrent: Int) {
        queue.async(flags: .barrier) {
            self.stats = USBOperationStatistics(
                activeRequestCount: count,
                currentLoadPercentage: maxConcurrent > 0 ? (Double(count) / Double(maxConcurrent)) * 100.0 : 0.0,
                activeControlRequests: self.stats.activeControlRequests,
                activeBulkRequests: self.stats.activeBulkRequests,
                activeInterruptRequests: self.stats.activeInterruptRequests,
                activeIsochronousRequests: self.stats.activeIsochronousRequests,
                successfulTransfers: self.stats.successfulTransfers,
                failedTransfers: self.stats.failedTransfers,
                totalTransfers: self.stats.totalTransfers,
                controlTransferCount: self.stats.controlTransferCount,
                successfulControlTransfers: self.stats.successfulControlTransfers,
                failedControlTransfers: self.stats.failedControlTransfers,
                bulkTransferCount: self.stats.bulkTransferCount,
                successfulBulkTransfers: self.stats.successfulBulkTransfers,
                failedBulkTransfers: self.stats.failedBulkTransfers,
                interruptTransferCount: self.stats.interruptTransferCount,
                successfulInterruptTransfers: self.stats.successfulInterruptTransfers,
                failedInterruptTransfers: self.stats.failedInterruptTransfers,
                isochronousTransferCount: self.stats.isochronousTransferCount,
                successfulIsochronousTransfers: self.stats.successfulIsochronousTransfers,
                failedIsochronousTransfers: self.stats.failedIsochronousTransfers,
                averageTransferLatency: self.stats.averageTransferLatency,
                averageThroughput: self.stats.averageThroughput,
                peakThroughput: self.stats.peakThroughput,
                totalBytesTransferred: self.stats.totalBytesTransferred,
                timeoutErrors: self.stats.timeoutErrors,
                deviceNotAvailableErrors: self.stats.deviceNotAvailableErrors,
                invalidParameterErrors: self.stats.invalidParameterErrors,
                endpointStallErrors: self.stats.endpointStallErrors,
                otherErrors: self.stats.otherErrors,
                maxConcurrentRequests: max(self.stats.maxConcurrentRequests, maxConcurrent),
                transferBufferMemoryUsage: self.stats.transferBufferMemoryUsage,
                activeURBCount: self.stats.activeURBCount,
                lastUpdateTime: Date()
            )
        }
    }
}

/// Extension for DateFormatter to provide consistent log formatting
extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}

/// USB operation statistics for monitoring transfer performance
public struct USBOperationStatistics {
    public let activeRequestCount: Int
    public let currentLoadPercentage: Double
    public let activeControlRequests: Int
    public let activeBulkRequests: Int
    public let activeInterruptRequests: Int
    public let activeIsochronousRequests: Int
    public let successfulTransfers: Int
    public let failedTransfers: Int
    public let totalTransfers: Int
    public let controlTransferCount: Int
    public let successfulControlTransfers: Int
    public let failedControlTransfers: Int
    public let bulkTransferCount: Int
    public let successfulBulkTransfers: Int
    public let failedBulkTransfers: Int
    public let interruptTransferCount: Int
    public let successfulInterruptTransfers: Int
    public let failedInterruptTransfers: Int
    public let isochronousTransferCount: Int
    public let successfulIsochronousTransfers: Int
    public let failedIsochronousTransfers: Int
    public let averageTransferLatency: Double
    public let averageThroughput: Double
    public let peakThroughput: Double
    public let totalBytesTransferred: UInt64
    public let timeoutErrors: Int
    public let deviceNotAvailableErrors: Int
    public let invalidParameterErrors: Int
    public let endpointStallErrors: Int
    public let otherErrors: Int
    public let maxConcurrentRequests: Int
    public let transferBufferMemoryUsage: UInt64
    public let activeURBCount: Int
    public let lastUpdateTime: Date?
    
    public init(
        activeRequestCount: Int = 0,
        currentLoadPercentage: Double = 0.0,
        activeControlRequests: Int = 0,
        activeBulkRequests: Int = 0,
        activeInterruptRequests: Int = 0,
        activeIsochronousRequests: Int = 0,
        successfulTransfers: Int = 0,
        failedTransfers: Int = 0,
        totalTransfers: Int = 0,
        controlTransferCount: Int = 0,
        successfulControlTransfers: Int = 0,
        failedControlTransfers: Int = 0,
        bulkTransferCount: Int = 0,
        successfulBulkTransfers: Int = 0,
        failedBulkTransfers: Int = 0,
        interruptTransferCount: Int = 0,
        successfulInterruptTransfers: Int = 0,
        failedInterruptTransfers: Int = 0,
        isochronousTransferCount: Int = 0,
        successfulIsochronousTransfers: Int = 0,
        failedIsochronousTransfers: Int = 0,
        averageTransferLatency: Double = 0.0,
        averageThroughput: Double = 0.0,
        peakThroughput: Double = 0.0,
        totalBytesTransferred: UInt64 = 0,
        timeoutErrors: Int = 0,
        deviceNotAvailableErrors: Int = 0,
        invalidParameterErrors: Int = 0,
        endpointStallErrors: Int = 0,
        otherErrors: Int = 0,
        maxConcurrentRequests: Int = 0,
        transferBufferMemoryUsage: UInt64 = 0,
        activeURBCount: Int = 0,
        lastUpdateTime: Date? = nil
    ) {
        self.activeRequestCount = activeRequestCount
        self.currentLoadPercentage = currentLoadPercentage
        self.activeControlRequests = activeControlRequests
        self.activeBulkRequests = activeBulkRequests
        self.activeInterruptRequests = activeInterruptRequests
        self.activeIsochronousRequests = activeIsochronousRequests
        self.successfulTransfers = successfulTransfers
        self.failedTransfers = failedTransfers
        self.totalTransfers = totalTransfers
        self.controlTransferCount = controlTransferCount
        self.successfulControlTransfers = successfulControlTransfers
        self.failedControlTransfers = failedControlTransfers
        self.bulkTransferCount = bulkTransferCount
        self.successfulBulkTransfers = successfulBulkTransfers
        self.failedBulkTransfers = failedBulkTransfers
        self.interruptTransferCount = interruptTransferCount
        self.successfulInterruptTransfers = successfulInterruptTransfers
        self.failedInterruptTransfers = failedInterruptTransfers
        self.isochronousTransferCount = isochronousTransferCount
        self.successfulIsochronousTransfers = successfulIsochronousTransfers
        self.failedIsochronousTransfers = failedIsochronousTransfers
        self.averageTransferLatency = averageTransferLatency
        self.averageThroughput = averageThroughput
        self.peakThroughput = peakThroughput
        self.totalBytesTransferred = totalBytesTransferred
        self.timeoutErrors = timeoutErrors
        self.deviceNotAvailableErrors = deviceNotAvailableErrors
        self.invalidParameterErrors = invalidParameterErrors
        self.endpointStallErrors = endpointStallErrors
        self.otherErrors = otherErrors
        self.maxConcurrentRequests = maxConcurrentRequests
        self.transferBufferMemoryUsage = transferBufferMemoryUsage
        self.activeURBCount = activeURBCount
        self.lastUpdateTime = lastUpdateTime
    }
}

/// Server coordinator that implements the USBIPServer protocol
public class ServerCoordinator: USBIPServer {
    /// Network service for handling client connections
    private var networkService: NetworkService
    
    /// Device discovery for USB device enumeration
    private var deviceDiscovery: DeviceDiscovery
    
    /// Request processor for handling USB/IP protocol requests
    private let requestProcessor: RequestProcessor
    
    /// Device claim manager for device claiming
    private let deviceClaimManager: DeviceClaimManager
    
    /// Server configuration
    private let config: ServerConfig
    
    /// Logger instance for server events
    private let logger: Logger
    
    /// Flag indicating if the server is running
    private var isServerRunning = false
    
    /// Concurrent request processing queue
    private let requestProcessingQueue: DispatchQueue
    
    /// Active request tracking for concurrent processing
    private let activeRequests = ActiveRequestTracker()
    
    /// USB operation statistics tracker
    private let usbStatsTracker = USBOperationStatsTracker()
    
    /// Maximum concurrent requests per client connection
    private let maxConcurrentRequestsPerClient: Int

    /// Opens a device for a client that imports it. The IOUSBHost device layer, unless a
    /// test supplies another.
    public var openDeviceIO: (_ busid: String, _ onTerminated: @escaping @Sendable () -> Void) throws -> USBDeviceIO = {
        busid, onTerminated in
        try IOUSBHostDeviceIO.open(busid: busid, onTerminated: onTerminated)
    }

    /// Guards the two tables below.
    private let connectionsLock = NSLock()

    /// Devices a client has attached. Importing one twice would capture it from under
    /// the first client.
    private var attachedBusids: Set<String> = []

    /// Per-connection state, so a disconnect can give the connection's device back.
    private var connectionStates: [UUID: USBIPConnectionState] = [:]

    /// Callback for error events
    public var onError: ((Error) -> Void)?
    
    /// Initialize with network service, device discovery, and optional device claim manager
    public init(networkService: NetworkService, 
               deviceDiscovery: DeviceDiscovery, 
               deviceClaimManager: DeviceClaimManager? = nil, 
               config: ServerConfig = ServerConfig(),
               boundDevices: BoundDeviceStore = BoundDeviceStore()) {
        self.networkService = networkService
        self.deviceDiscovery = deviceDiscovery
        self.config = config
        
        // Initialize concurrent processing infrastructure
        self.requestProcessingQueue = DispatchQueue(
            label: "com.usbipd.request-processing", 
            qos: DispatchQoS(qosClass: config.usbRequestQoS, relativePriority: 0), 
            attributes: .concurrent
        )
        self.maxConcurrentRequestsPerClient = config.maxConcurrentRequests
        
        // Initialize logger with appropriate configuration
        let loggerConfig = LoggerConfig(
            level: config.logLevel,
            includeTimestamp: true,
            includeContext: config.debugMode
        )
        self.logger = Logger(config: loggerConfig, subsystem: "com.usbipd.mac", category: "server")
        
        // Use provided device claim manager or create a mock one
        self.deviceClaimManager = deviceClaimManager ?? UserspaceDeviceClaimManager()
        
        // Create request processor with device claim manager and configurable logging
        self.requestProcessor = RequestProcessor(
            deviceDiscovery: deviceDiscovery, 
            deviceClaimManager: self.deviceClaimManager,
            boundDevices: boundDevices
        ) { [weak config] message, processorLevel in
            guard let config = config else { return }
            
            // Convert RequestProcessor.LogLevel to ServerConfig.LogLevel
            let configLevel: LogLevel
            switch processorLevel {
            case .debug: configLevel = .debug
            case .info: configLevel = .info
            case .warning: configLevel = .warning
            case .error: configLevel = .error
            }
            
            // Check if we should log this message based on configured log level
            guard config.shouldLog(level: configLevel) else { return }
            
            let timestamp = DateFormatter.logFormatter.string(from: Date())
            let prefix: String
            switch processorLevel {
            case .debug: prefix = "[DEBUG]"
            case .info: prefix = "[INFO]"
            case .warning: prefix = "[WARNING]"
            case .error: prefix = "[ERROR]"
            }
            
            let logMessage = "\(timestamp) \(prefix) \(message)"
            
            // Log to file if configured
            if let logFilePath = config.logFilePath {
                do {
                    let fileHandle: FileHandle
                    if FileManager.default.fileExists(atPath: logFilePath) {
                        fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: logFilePath))
                        fileHandle.seekToEndOfFile()
                    } else {
                        FileManager.default.createFile(atPath: logFilePath, contents: nil)
                        fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: logFilePath))
                    }
                    
                    if let data = (logMessage + "\n").data(using: .utf8) {
                        fileHandle.write(data)
                    }
                    fileHandle.closeFile()
                } catch {
                    print("Error writing to log file: \(error.localizedDescription)")
                }
            }
            
            // Always print to console
            print(logMessage)
            
            // Include protocol-level details in debug mode
            if config.debugMode && processorLevel == .debug {
                // Additional debug information could be added here
            }
        }
        
        // Wire the USB request handler. Without it RequestProcessor has no way to
        // service SUBMIT or UNLINK: every URB fell into a `guard let handler` and threw
        // invalidMessageFormat, which reads like a protocol error and is really "no
        // handler configured". setUSBRequestHandler existed, USBRequestHandler existed,
        // and nothing ever connected the two — so the transfer path was unreachable no
        // matter how correct the framing was.
        self.requestProcessor.setUSBRequestHandler(
            USBRequestHandler(
                deviceDiscovery: deviceDiscovery,
                deviceClaimManager: self.deviceClaimManager,
                config: config
            )
        )

        // Imported devices are served by an attachment, opened before the import is
        // answered. See USBIPAttachment.
        self.requestProcessor.attachmentOpener = { [weak self] device, state in
            guard let self = self else { throw ServerError.notRunning }
            return try self.openAttachment(for: device, state: state)
        }

        // Device lists describe each device's real interfaces.
        self.requestProcessor.deviceDescriber = { device in
            IOUSBHostDeviceIO.describe(busid: "\(device.busID)-\(device.deviceID)")
        }

        setupCallbacks()
    }

    /// Open a device for the client on this connection.
    private func openAttachment(for device: USBDevice, state: USBIPConnectionState) throws -> USBIPAttachment {
        let busid = "\(device.busID)-\(device.deviceID)"

        connectionsLock.lock()
        let alreadyAttached = attachedBusids.contains(busid)
        if !alreadyAttached {
            attachedBusids.insert(busid)
        }
        connectionsLock.unlock()
        guard !alreadyAttached else {
            throw AttachmentError.alreadyAttached(busid)
        }

        do {
            let io = try openDeviceIO(busid) { [weak state] in
                // The device went away. Closing the connection tells the client, as
                // Linux's server does, and the disconnect hands the device back.
                state?.closeConnection?()
            }
            let attachment = USBIPAttachment(busid: busid, io: io, maxTransferSize: Int(config.maxUSBBufferSize)) {
                [weak state] data in
                state?.send?(data)
            }
            logger.info("Serving \(busid) to a client", context: ["busid": busid])
            return attachment
        } catch {
            connectionsLock.lock()
            attachedBusids.remove(busid)
            connectionsLock.unlock()
            throw error
        }
    }

    /// Stop serving a connection's device, if it has one, and give it back to macOS.
    private func closeAttachment(of state: USBIPConnectionState) {
        guard let attachment = state.attachment else { return }
        state.attachment = nil
        attachment.close()

        connectionsLock.lock()
        attachedBusids.remove(attachment.busid)
        connectionsLock.unlock()
        logger.info("Stopped serving \(attachment.busid)", context: ["busid": attachment.busid])
    }
    
    /// Set up callbacks for network and device events
    private func setupCallbacks() {
        // Handle client connections
        networkService.onClientConnected = { [weak self] clientConnection in
            guard let self = self else { return }
            
            self.logger.info("Client connected", context: ["connectionId": clientConnection.id.uuidString])
            
            // Create a local mutable variable for the connection
            var connection = clientConnection

            // Framing state belongs to the connection, not the processor: after a
            // successful import this socket switches from op_common to
            // usbip_header_basic, and nothing in the bytes says so.
            let connectionState = USBIPConnectionState()
            let replyConnection = clientConnection
            connectionState.send = { data in
                // A reply for a client that has gone has nowhere to go.
                try? replyConnection.send(data: data)
            }
            connectionState.closeConnection = {
                try? replyConnection.close()
            }
            self.connectionsLock.lock()
            self.connectionStates[clientConnection.id] = connectionState
            self.connectionsLock.unlock()

            // TCP delivers bytes, not messages: one read can hold part of a message or
            // several of them. See USBIPStreamFramer.
            var framer = USBIPStreamFramer()

            // Reads are delivered one at a time on the connection's own queue, so the
            // framer is only ever touched from one thread.
            connection.onDataReceived = { [weak self] data in
                guard let self = self else { return }

                self.logger.debug("Received data from client", context: [
                    "connectionId": connection.id.uuidString,
                    "dataSize": data.count
                ])

                framer.append(data)
                while true {
                    let message: Data?
                    do {
                        message = try framer.nextMessage(attached: connectionState.isAttached)
                    } catch {
                        // The stream cannot be resynchronised once a header is
                        // nonsense: everything after it would be read at the wrong
                        // offsets.
                        self.logger.warning("Closing connection on an unframeable message", context: [
                            "connectionId": connection.id.uuidString,
                            "error": String(describing: error)
                        ])
                        self.onError?(error)
                        try? connection.close()
                        return
                    }
                    guard let message = message else { break }
                    if let attachment = connectionState.attachment {
                        // Queued with the device in arrival order; replies are sent as
                        // the transfers complete.
                        attachment.handle(message)
                    } else {
                        self.dispatch(message, from: connection, state: connectionState)
                    }
                }
            }
            
            // Set up error handler for the connection
            connection.onError = { [weak self] error in
                guard let self = self else { return }
                
                self.logger.error("Client connection error", context: [
                    "connectionId": connection.id.uuidString,
                    "error": error.localizedDescription
                ])
                
                // Forward error to server error handler
                self.onError?(error)
            }
        }
        
        // Handle client disconnections
        networkService.onClientDisconnected = { [weak self] clientConnection in
            guard let self = self else { return }
            
            self.logger.info("Client disconnected", context: [
                "connectionId": clientConnection.id.uuidString,
                "activeRequests": self.activeRequests.getActiveRequestCount(for: clientConnection.id)
            ])
            
            // Clean up active request tracking for this client
            self.activeRequests.removeAllRequests(for: clientConnection.id)

            // Give the client's device back, and break the reply closures' hold on the
            // connection.
            self.connectionsLock.lock()
            let state = self.connectionStates.removeValue(forKey: clientConnection.id)
            self.connectionsLock.unlock()
            if let state = state {
                self.closeAttachment(of: state)
                state.send = nil
                state.closeConnection = nil
            }
        }
        
        // Handle device connections
        deviceDiscovery.onDeviceConnected = { [weak self] device in
            guard let self = self else { return }
            
            self.logger.info("USB device connected", context: [
                "busID": device.busID,
                "deviceID": device.deviceID,
                "vendorID": String(format: "0x%04x", device.vendorID),
                "productID": String(format: "0x%04x", device.productID),
                "product": device.productString ?? "Unknown"
            ])
        }
        
        // Handle device disconnections
        deviceDiscovery.onDeviceDisconnected = { [weak self] device in
            guard let self = self else { return }
            
            self.logger.info("USB device disconnected", context: [
                "busID": device.busID,
                "deviceID": device.deviceID,
                "vendorID": String(format: "0x%04x", device.vendorID),
                "productID": String(format: "0x%04x", device.productID)
            ])
        }
    }
    
    /// Handle one framed message.
    ///
    /// Handshake messages are processed before the next message is framed, because an
    /// import changes how every byte after it is read. URB traffic goes to the
    /// concurrent processing queue, so a read that blocks does not hold up the requests
    /// behind it.
    private func dispatch(_ message: Data, from connection: ClientConnection, state: USBIPConnectionState) {
        guard state.isAttached else {
            process(message, from: connection, state: state)
            return
        }

        activeRequests.incrementActiveRequests(for: connection.id)
        let activeCount = activeRequests.getActiveRequestCount(for: connection.id)
        if activeCount > maxConcurrentRequestsPerClient {
            // Reported, not enforced. Dropping the request, as this used to, left the
            // client waiting for a reply that would never come.
            logger.warning("Client connection is over its concurrent request limit", context: [
                "connectionId": connection.id.uuidString,
                "activeRequests": activeCount,
                "limit": maxConcurrentRequestsPerClient
            ])
        }

        requestProcessingQueue.async {
            defer { self.activeRequests.decrementActiveRequests(for: connection.id) }
            self.process(message, from: connection, state: state)
        }
    }

    /// Run one message through the request processor and send its reply.
    private func process(_ message: Data, from connection: ClientConnection, state: USBIPConnectionState) {
        do {
            let responseData = try requestProcessor.processRequest(message, connectionState: state)

            // An empty response means the processor deliberately has nothing to say — a
            // request the client withdrew, which is answered by its RET_UNLINK and must
            // not also draw a RET_SUBMIT.
            if !responseData.isEmpty {
                try connection.send(data: responseData)
            }

            // Once the socket carries an attached device it may go quiet indefinitely,
            // so exempt it from the idle reaper.
            if state.isAttached, let tcpConnection = connection as? TCPClientConnection {
                tcpConnection.keepAlive = true
            }

            logger.debug("Sent response to client", context: [
                "connectionId": connection.id.uuidString,
                "responseSize": responseData.count
            ])
        } catch {
            logger.error("Failed to process request", context: [
                "connectionId": connection.id.uuidString,
                "error": error.localizedDescription
            ])
            onError?(error)

            if case USBIPProtocolError.invalidHeader = error {
                logger.warning("Closing connection due to invalid header", context: [
                    "connectionId": connection.id.uuidString
                ])
                try? connection.close()
            }
        }
    }

    /// Start the USB/IP server
    public func start() throws {
        guard !isServerRunning else {
            throw ServerError.alreadyRunning
        }
        
        do {
            // Validate configuration before starting
            try config.validate()
            
            // Log server startup
            let timestamp = DateFormatter.logFormatter.string(from: Date())
            print("\(timestamp) [INFO] Starting USB/IP server on port \(config.port)")
            
            // Device claim manager is already initialized and ready
            
            // Start device discovery notifications
            try deviceDiscovery.startNotifications()
            
            // Start network service
            try networkService.start(port: config.port)
            
            isServerRunning = true
            
            // Log successful startup
            print("\(timestamp) [INFO] USB/IP server started successfully")
        } catch let configError as ServerError {
            // Forward configuration error
            throw configError
        } catch {
            // Clean up if any component fails to start
            deviceDiscovery.stopNotifications() // This method doesn't throw
            do {
                try networkService.stop()
            } catch {
                // Ignore errors during cleanup
            }
            
            // Forward error
            throw ServerError.initializationFailed("Failed to start server: \(error.localizedDescription)")
        }
    }
    
    /// Stop the USB/IP server
    public func stop() throws {
        guard isServerRunning else {
            throw ServerError.notRunning
        }
        
        // Stop device discovery notifications
        deviceDiscovery.stopNotifications()

        // Give every attached device back to macOS before the connections go.
        connectionsLock.lock()
        let states = Array(connectionStates.values)
        connectionsLock.unlock()
        states.forEach { closeAttachment(of: $0) }

        // Stop network service
        try networkService.stop()
        
        // Device claim manager cleanup (if needed) would happen in its own deinit
        
        isServerRunning = false
    }
    
    /// Check if the server is running
    public func isRunning() -> Bool {
        return isServerRunning
    }
    
    // Get System Extension status information
    // Get automatic installation status and history (disabled in current implementation)
    // - Returns: Current installation state and attempt history, or nil if System Extension not enabled
    // public func getAutomaticInstallationStatus() -> (state: AutomaticInstallationManager.InstallationState, history: [AutomaticInstallationManager.InstallationAttemptResult])? {
    //     guard let installationManager = automaticInstallationManager else {
    //         return nil
    //     }
    //     return installationManager.getInstallationStatus()
    // }
    
    /// Get USB operation statistics for monitoring and diagnostics
    public func getUSBOperationStatistics() -> USBOperationStatistics {
        // Update active request count before returning statistics
        let currentActiveRequests = activeRequests.totalActiveRequests
        usbStatsTracker.updateActiveRequests(currentActiveRequests, maxConcurrent: maxConcurrentRequestsPerClient)
        
        return usbStatsTracker.getStatistics()
    }
}


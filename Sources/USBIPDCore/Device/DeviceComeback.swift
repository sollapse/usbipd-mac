// DeviceComeback.swift
// Waiting for a device that went away from an attached client to come back.

import Foundation

/// Waits for a device that went away from an attached client to come back at its port.
///
/// A device can drop off the bus and come straight back. A bus-powered BD-RE drive did so
/// as it went to standby after fast reads, about 32 seconds after the last one, and was
/// back 0.6 seconds later, whichever host it was serving. macOS recovers on its own, and
/// nothing seems amiss. A USB/IP client whose connection is closed sees the device
/// unplugged instead, and Windows, caught reading from it, can be left holding a
/// half-gone volume until it restarts. So the client's session is kept for a while, and
/// a device that comes back is given to it.
public struct DeviceComeback: Sendable {
    public enum Outcome {
        /// Back, and opened.
        case back(USBDeviceIO)
        /// Back, but not the same device, or it could not be opened again.
        case refused(Error)
        /// Not back in time.
        case timedOut
        /// No longer wanted: the client went meanwhile.
        case abandoned
    }

    /// How long the device has to come back.
    public let window: TimeInterval
    /// How long to wait between looks.
    public let interval: TimeInterval

    public init(window: TimeInterval, interval: TimeInterval) {
        self.window = window
        self.interval = interval
    }

    /// Look for the device until it is back, is refused, is no longer wanted or the window
    /// has passed. `reopen` returns nil while the device is not back.
    public func wait(reopen: () throws -> USBDeviceIO?, stillWanted: () -> Bool) -> Outcome {
        let deadline = Date().addingTimeInterval(window)
        while true {
            guard stillWanted() else { return .abandoned }
            do {
                if let io = try reopen() {
                    return .back(io)
                }
            } catch {
                return .refused(error)
            }
            guard Date() < deadline else { return .timedOut }
            Thread.sleep(forTimeInterval: interval)
        }
    }
}

/// How many times a device may come back within a period. A device that keeps going away
/// soon after coming back is failing, and its client is better told that it has gone.
/// A drive that resets as it goes to standby needs more than half a minute of idling
/// between two resets.
public struct ComebackBudget: Sendable {
    public let limit: Int
    public let period: TimeInterval
    private var times: [Date] = []

    public init(limit: Int, period: TimeInterval) {
        self.limit = limit
        self.period = period
    }

    /// Whether the device may come back once more, at `now`. Counts it if so.
    public mutating func allows(at now: Date = Date()) -> Bool {
        times.removeAll { now.timeIntervalSince($0) >= period }
        guard times.count < limit else { return false }
        times.append(now)
        return true
    }
}

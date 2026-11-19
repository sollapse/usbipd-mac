// CodelessClaimKext.swift
// A kext with no code that keeps macOS's drivers off chosen devices.

import Foundation
import IOKit

/// One interface for the claim kext to keep macOS's drivers off.
public struct ClaimedInterface: Equatable, Sendable {
    public let busid: String
    public let vendorID: UInt16
    public let productID: UInt16
    public let configurationValue: UInt8
    public let interfaceNumber: UInt8

    public init(busid: String, vendorID: UInt16, productID: UInt16, configurationValue: UInt8, interfaceNumber: UInt8) {
        self.busid = busid
        self.vendorID = vendorID
        self.productID = productID
        self.configurationValue = configurationValue
        self.interfaceNumber = interfaceNumber
    }
}

/// A codeless kext: an Info.plist of IOKit personalities and nothing else.
///
/// Capturing a device frees it from every macOS driver except one: Apple documents its
/// mass storage drivers as kept on their interfaces even then (USB.h, for
/// kUSBReEnumerateCaptureDeviceBit). This keeps them from ever attaching. Each
/// personality matches one interface by vendor, product, configuration and interface
/// number, which USB matching ranks above the class match those drivers use, and puts a
/// bare IOService there instead. An IOService never opens its provider, so the
/// interface stays free for the daemon to open.
///
/// Loading one takes System Integrity Protection off on Apple silicon: a kext signed
/// with anything but a KEXT-enabled Developer ID, which Apple does not grant for
/// personal use, loads only under Permissive Security.
public enum CodelessClaimKext {
    public static let bundleIdentifier = "com.usbipd.mac.claim"
    public static let bundleName = "usbipd-claim.kext"

    /// The bundle's Info.plist.
    public static func infoPlist(for interfaces: [ClaimedInterface]) -> [String: Any] {
        var personalities: [String: Any] = [:]
        for interface in interfaces {
            let name = String(format: "%@ %04x:%04x interface %d", interface.busid,
                              interface.vendorID, interface.productID, interface.interfaceNumber)
            personalities[name] = [
                // IOService is the kernel's own class; no driver code is loaded for it.
                "CFBundleIdentifier": "com.apple.kpi.iokit",
                "IOClass": "IOService",
                "IOProviderClass": "IOUSBHostInterface",
                "idVendor": Int(interface.vendorID),
                "idProduct": Int(interface.productID),
                "bConfigurationValue": Int(interface.configurationValue),
                "bInterfaceNumber": Int(interface.interfaceNumber),
                // In the default match category on purpose: a category of its own would let
                // macOS's driver attach alongside it instead of losing to it.
                "IOProbeScore": 100_000
            ] as [String: Any]
        }

        return [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "usbipd-claim",
            "CFBundlePackageType": "KEXT",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "IOKitPersonalities": personalities,
            "OSBundleLibraries": ["com.apple.kpi.iokit": "20.0"]
        ]
    }

    /// Write the bundle, replacing one already at `bundleURL`.
    public static func write(_ interfaces: [ClaimedInterface], to bundleURL: URL) throws {
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: bundleURL.path) {
            try fileManager.removeItem(at: bundleURL)
        }
        try fileManager.createDirectory(at: contents, withIntermediateDirectories: true)

        let data = try PropertyListSerialization.data(fromPropertyList: infoPlist(for: interfaces),
                                                      format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    /// The interfaces of the device at `busid`, read from the IORegistry. The device has to
    /// be attached and configured.
    public static func interfaces(ofDeviceAt busid: String) -> [ClaimedInterface] {
        guard let service = IOUSBHostDeviceIO.findService(busid: busid) else { return [] }
        defer { IOObjectRelease(service) }

        guard let vendorID = number(service, "idVendor"), let productID = number(service, "idProduct") else {
            return []
        }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var found: [ClaimedInterface] = []
        while true {
            let child = IOIteratorNext(iterator)
            guard child != 0 else { break }
            defer { IOObjectRelease(child) }
            guard IOObjectConformsTo(child, "IOUSBHostInterface") != 0,
                  let interfaceNumber = number(child, "bInterfaceNumber"),
                  let configurationValue = number(child, "bConfigurationValue") else {
                continue
            }
            found.append(ClaimedInterface(busid: busid, vendorID: UInt16(truncatingIfNeeded: vendorID),
                                          productID: UInt16(truncatingIfNeeded: productID),
                                          configurationValue: UInt8(truncatingIfNeeded: configurationValue),
                                          interfaceNumber: UInt8(truncatingIfNeeded: interfaceNumber)))
        }
        return found.sorted { $0.interfaceNumber < $1.interfaceNumber }
    }

    private static func number(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? NSNumber)?.intValue
    }
}

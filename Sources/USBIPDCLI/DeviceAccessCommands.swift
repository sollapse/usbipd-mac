// DeviceAccessCommands.swift
// Commands for getting at devices macOS holds: probe and kext.

import Foundation
import USBIPDCore
import Common

private let logger = Logger(config: LoggerConfig(level: .info), subsystem: "com.usbipd.mac", category: "cli-commands")

private let busidPattern = #"^\d+-\d+(\.\d+)*$"#

/// Opens a device exactly as an attaching client would have it opened, reports what
/// that took from macOS and what it found, and gives the device back.
///
/// The question this answers cannot be settled from documentation: which drivers macOS
/// lets go of when a device is captured. Apple documents mass storage as an exception
/// for one API and not for another; this finds out for a given device and macOS release
/// without needing a USB/IP client.
public class ProbeCommand: Command {
    public let name = "probe"
    // Completion scripts quote this naively and their tests reject the names of removed
    // commands, so it carries neither an apostrophe nor the word for a client's import.
    public let description = "Open a device as an import would, report it, and give it back"

    public init() {}

    public func execute(with arguments: [String]) throws {
        if arguments.contains("-h") || arguments.contains("--help") {
            printHelp()
            return
        }
        guard let busid = arguments.first else {
            throw CommandLineError.missingArguments("Device busid required")
        }
        guard busid.range(of: busidPattern, options: .regularExpression) != nil else {
            throw CommandLineError.invalidArguments("Invalid busid format: \(busid)")
        }

        let io: IOUSBHostDeviceIO
        do {
            // Each step is printed: what macOS does with a captured device is the whole
            // question this command answers.
            io = try IOUSBHostDeviceIO.open(busid: busid, trace: { print("  - \($0)") }) {}
        } catch let error as USBDeviceOpenError {
            print("Cannot serve \(busid): \(error)")
            throw CommandHandlerError.deviceAttachmentFailed(error.description)
        }
        defer { io.close() }

        if io.captured {
            print("Captured \(busid) from macOS's drivers.")
        } else {
            print("Opened \(busid). Nothing had to be taken from macOS.")
        }
        print("Configuration: \(io.currentConfiguration.map(String.init) ?? "none")")
        for interface in io.interfaceSummary {
            let endpoints = interface.endpoints.map { endpoint in
                "\(String(format: "0x%02x", endpoint.address)) \(endpoint.transferType)"
            }
            let list = endpoints.isEmpty ? "no endpoints" : endpoints.joined(separator: ", ")
            print("  Interface \(interface.number), alternate setting \(interface.alternate): \(list)")
        }
        if io.captured {
            print("Giving it back to macOS.")
        }
        logger.info("Probed device", context: ["busid": busid, "captured": String(io.captured)])
    }

    private func printHelp() {
        print("Usage: usbipd probe <busid>")
        print("")
        print("Open a device the way the daemon does when a client attaches it: as it is if")
        print("nothing holds it, otherwise captured from macOS's drivers. Report what was")
        print("taken and which interfaces and endpoints opened, then give the device back.")
        print("")
        print("Capturing needs root: sudo usbipd probe <busid>. Eject a storage device's")
        print("volumes first; the probe refuses while one is mounted.")
    }
}

/// Writes a codeless kext that keeps macOS's drivers off chosen devices, for the
/// drivers a capture does not release.
public class KextCommand: Command {
    public let name = "kext"
    public let description = "Write a codeless kext that keeps the macOS drivers off devices"

    public init() {}

    public func execute(with arguments: [String]) throws {
        if arguments.contains("-h") || arguments.contains("--help") {
            printHelp()
            return
        }

        var busids: [String] = []
        var outputDirectory = FileManager.default.currentDirectoryPath
        var sign = true
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-o", "--output":
                index += 1
                guard index < arguments.count else {
                    throw CommandLineError.missingArguments("\(argument) needs a directory")
                }
                outputDirectory = arguments[index]
            case "--no-sign":
                sign = false
            default:
                guard argument.range(of: busidPattern, options: .regularExpression) != nil else {
                    throw CommandLineError.invalidArguments("Invalid busid format: \(argument)")
                }
                busids.append(argument)
            }
            index += 1
        }
        guard !busids.isEmpty else {
            throw CommandLineError.missingArguments("At least one device busid is required")
        }

        var interfaces: [ClaimedInterface] = []
        for busid in busids {
            let found = CodelessClaimKext.interfaces(ofDeviceAt: busid)
            guard !found.isEmpty else {
                throw CommandHandlerError.deviceNotFound("\(busid) is not attached, or macOS has not configured it")
            }
            interfaces += found
        }

        let bundle = URL(fileURLWithPath: outputDirectory).appendingPathComponent(CodelessClaimKext.bundleName)
        try CodelessClaimKext.write(interfaces, to: bundle)
        print("Wrote \(bundle.path), keeping macOS's drivers off:")
        for interface in interfaces {
            print("  \(interface.busid) (\(String(format: "%04x:%04x", interface.vendorID, interface.productID))) "
                  + "configuration \(interface.configurationValue), interface \(interface.interfaceNumber)")
        }

        if sign {
            signAdHoc(bundle)
        }

        print("""

            The kext matches these devices by vendor and product ID: every device of the
            same model is kept from macOS, wherever it is plugged in.

            Installing it on Apple silicon, at the Mac:
              1. A kext without a KEXT-enabled Developer ID loads only with System
                 Integrity Protection off. Shut down, hold the power button until the
                 startup options appear, open Options, then Utilities > Terminal, run
                 `csrutil disable` (this sets Permissive Security), and restart.
              2. sudo cp -R \(bundle.path) /Library/Extensions/
                 sudo chown -R root:wheel /Library/Extensions/\(CodelessClaimKext.bundleName)
                 sudo kmutil load -p /Library/Extensions/\(CodelessClaimKext.bundleName)
              3. Allow it in System Settings > Privacy & Security, and restart when asked.
              4. Unplug the device and plug it in again. `usbipd bind` then reports it free.

            Removing it:
              sudo rm -rf /Library/Extensions/\(CodelessClaimKext.bundleName)
              sudo kmutil rebuild
            then restart, and re-enable SIP from recoveryOS with `csrutil enable` if
            nothing else needs it off.
            """)
    }

    /// Sign the bundle ad hoc. Under Permissive Security the signature is not enforced,
    /// but kmutil still reads one.
    private func signAdHoc(_ bundle: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", bundle.path]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                print("Signed it ad hoc.")
            } else {
                print("codesign exited with \(process.terminationStatus); the kext is unsigned.")
            }
        } catch {
            print("Could not run codesign (\(error.localizedDescription)); the kext is unsigned.")
        }
    }

    private func printHelp() {
        print("Usage: usbipd kext <busid>... [--output <directory>] [--no-sign]")
        print("")
        print("Write usbipd-claim.kext, a kext with no code that keeps macOS's drivers off")
        print("every interface of the given devices, so the daemon can open them without")
        print("capturing anything. It is for what a capture does not release: macOS keeps")
        print("its mass storage drivers on their interfaces even when a device is captured.")
        print("")
        print("Try `sudo usbipd probe <busid>` first: if the probe opens the device, no kext")
        print("is needed. Loading the kext needs System Integrity Protection off.")
        print("")
        print("Options:")
        print("  -o, --output <dir>  Where to write the bundle (default: current directory)")
        print("  --no-sign           Leave the bundle unsigned")
    }
}

// CodelessClaimKextTests.swift
// The claim kext has to out-match macOS's class drivers and never hold its interface.

import XCTest
@testable import USBIPDCore

final class CodelessClaimKextTests: XCTestCase {

    private let drive = ClaimedInterface(busid: "1-1", vendorID: 0x18A5, productID: 0x0428,
                                         configurationValue: 1, interfaceNumber: 0)

    private func personalities(_ interfaces: [ClaimedInterface]) -> [[String: Any]] {
        let plist = CodelessClaimKext.infoPlist(for: interfaces)
        let table = plist["IOKitPersonalities"] as? [String: Any] ?? [:]
        return table.values.compactMap { $0 as? [String: Any] }
    }

    func testOnePersonalityPerInterface() {
        let second = ClaimedInterface(busid: "1-1", vendorID: 0x18A5, productID: 0x0428,
                                      configurationValue: 1, interfaceNumber: 1)
        XCTAssertEqual(personalities([drive, second]).count, 2)
    }

    /// Vendor, product, configuration and interface number is the most specific match
    /// USB defines, so it beats the class match macOS's storage drivers use.
    func testMatchesTheInterfaceSpecifically() throws {
        let personality = try XCTUnwrap(personalities([drive]).first)
        XCTAssertEqual(personality["IOProviderClass"] as? String, "IOUSBHostInterface")
        XCTAssertEqual(personality["idVendor"] as? Int, 0x18A5)
        XCTAssertEqual(personality["idProduct"] as? Int, 0x0428)
        XCTAssertEqual(personality["bConfigurationValue"] as? Int, 1)
        XCTAssertEqual(personality["bInterfaceNumber"] as? Int, 0)
    }

    /// A bare IOService never opens its provider, and sharing the default match category
    /// is what makes macOS's driver lose to it rather than attach beside it.
    func testPlaceholderHoldsNothing() throws {
        let personality = try XCTUnwrap(personalities([drive]).first)
        XCTAssertEqual(personality["IOClass"] as? String, "IOService")
        XCTAssertNil(personality["IOMatchCategory"])
    }

    func testBundleIsACodelessKext() throws {
        let plist = CodelessClaimKext.infoPlist(for: [drive])
        XCTAssertEqual(plist["CFBundlePackageType"] as? String, "KEXT")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, CodelessClaimKext.bundleIdentifier)
        XCTAssertNil(plist["CFBundleExecutable"], "a codeless kext has no executable")
    }

    func testWrittenBundleReadsBack() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claim-kext-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent(CodelessClaimKext.bundleName)

        try CodelessClaimKext.write([drive], to: bundle)
        // Written twice: the second replaces the first.
        try CodelessClaimKext.write([drive], to: bundle)

        let data = try Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual((plist["IOKitPersonalities"] as? [String: Any])?.count, 1)
    }
}

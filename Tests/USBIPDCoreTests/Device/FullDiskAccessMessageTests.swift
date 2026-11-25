// FullDiskAccessMessageTests.swift
// What the Full Disk Access refusal tells the user to do.

import XCTest
@testable import USBIPDCore

final class FullDiskAccessMessageTests: XCTestCase {

    /// Started from Terminal: the grant goes to Terminal, which is what lets the daemon
    /// open a storage interface.
    func testNamesTheAppTheDaemonWasStartedFrom() {
        let error = USBDeviceOpenError.storageNeedsFullDiskAccess(
            busid: "1-1", interface: 0, launchedFrom: ["usbipd", "sudo", "zsh", "login", "Terminal.app"])
        let text = error.description
        XCTAssertTrue(text.contains("started from: usbipd < sudo < zsh < login < Terminal.app"), text)
        XCTAssertTrue(text.contains("Grant it to Terminal.app"), text)
    }

    /// Started over SSH: no app is in the chain, and the session's own access was not
    /// enough, so the message says to start the daemon from a terminal app instead of
    /// naming something to grant it to.
    func testWithoutAnAppSaysToStartFromATerminalApp() {
        let error = USBDeviceOpenError.storageNeedsFullDiskAccess(
            busid: "1-1", interface: 0, launchedFrom: ["usbipd", "sudo", "zsh", "sshd-session"])
        let text = error.description
        XCTAssertTrue(text.contains("Start the daemon from a terminal app that has Full Disk Access"), text)
        XCTAssertTrue(text.contains("over SSH is refused"), text)
        XCTAssertFalse(text.contains("Grant it to"), text)
    }
}

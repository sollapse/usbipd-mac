> [!IMPORTANT]
> **Which devices work:** those whose USB interface can actually be claimed. Debug
> probes (J-Link, ST-Link, CMSIS-DAP), boards in DFU or bootloader mode, Android
> devices in ADB mode, vendor-specific interfaces generally, and **USB-serial adapters
> (FTDI, CP210x)** — the last of these despite macOS having a driver attached, which
> earlier versions of this file wrongly said made them impossible. These need no entitlement and no
> System Extension — a J-Link has been driven end to end from a Linux client with
> probe-rs, and a Pixel answers ADB protocol messages over the wire.
>
> **One caveat even for devices that work:** a client whose protocol keys off USB
> connection or reset events may still not function. `adb` is the known example — it
> waits for the phone's once-per-connection announcement, which macOS already received.
> Request/response devices are unaffected. See
> [Documentation/development/android-adb-validation.md](Documentation/development/android-adb-validation.md).
>
> **Devices macOS holds** — HID, audio, cameras, CDC-ACM, mass storage — are taken from
> macOS when a client attaches them, and given back when it detaches. IOUSBHost lets
> root *capture* a device: the drivers and clients on it are terminated, and on release
> the device is reset and they match it again. That needs no entitlement, only the
> daemon running as root (`sudo brew services start usbip`). The DriverKit USB transport
> entitlements this project asked Apple for were denied on 25 February 2026, and are
> not needed for this. `bind` says what attaching will take from macOS; `sudo usbipd
> probe <busid>` opens a device exactly as an attach would and reports the outcome.
>
> **Mass storage needs Full Disk Access.** Capturing a storage device terminates its
> driver; the daemon then selects the configuration again so the interface comes back
> unclaimed, and macOS lets only a process with Full Disk Access open it. macOS goes by
> the app the daemon was started from: grant it, in System Settings > Privacy &
> Security > Full Disk Access, to the terminal app you start the daemon from, and start
> it there. A daemon started over SSH is refused, even when the SSH session can read
> protected files. A daemon started at boot (`brew services`) would need the grant on
> the `usbipd` binary itself, which has not been tested. Measured on macOS 27.0.1 with a
> USB BD-RE drive, served to Windows 11 through usbip-win2. A device whose volumes are
> mounted is refused rather than captured, since capturing it would cut them off
> unflushed: eject them first. If some macOS release keeps a storage interface anyway,
> `usbipd kext <busid>` writes a codeless kext that keeps the driver off that device
> model; loading it needs System Integrity Protection off, and the command prints the
> steps.
>
> The capture path has been validated against hardware with that drive: capture, bulk
> and control transfers, stalls and their clearing, and handing the device back.
> Isochronous and interrupt transfers, capturing HID, audio, camera and CDC-ACM devices,
> and the kext have not been yet. Seizing the interface (`USBInterfaceOpenSeize`) was
> measured and does not release a driver, and neither unmounting nor ejecting releases
> it; capture is a different operation. Note this is also *not* the App Sandbox entitlement
> `com.apple.security.device.usb`, which is freely usable and grants nothing here — see
> [Documentation/development/entitlement-validation.md](Documentation/development/entitlement-validation.md).

# usbipd-mac

A macOS implementation of the USB/IP protocol that allows sharing USB devices over IP networks.

## Overview

usbipd-mac is a macOS implementation of the USB/IP protocol that allows sharing USB devices over IP networks. This server implementation enables macOS users to share USB devices with any compatible USB/IP client, with a focus on compatibility with the Linux Kernel virtual HCI driver (vhci-hcd.ko). Docker support on macOS is also a goal.

## Features

- USB device sharing from macOS to other systems over network
- Compatible with the standard Linux `usbip` client — verified with a real client
  performing enumeration, control transfers and bulk transfers
- Works with [usbip-win2](https://github.com/vadimgrn/usbip-win2) on Windows — verified
  with a USB BD-RE drive, a disc read end to end
- Every interface of a device is served: control, bulk, interrupt and isochronous
  transfers (isochronous needs macOS 12), alternate settings and configurations,
  SuperSpeed and SuperSpeed+ speeds
- Devices macOS holds are captured from its drivers when a client attaches, as root,
  and handed back when it detaches; mass storage too, with Full Disk Access
- `USBIPD_TRACE` logs every request and reply, to see what a client and a device said
- No System Extension or entitlement required

## Requirements

- **macOS 11.0+**
- **Xcode 13+**: needed to build, and to run the test suite (`swift test` requires
  XCTest, which the Command Line Tools alone do not provide)
- **Code Signing**: optional for development, required for distribution

## Installation

### Homebrew Installation (Recommended)

The easiest way to install usbipd-mac is through Homebrew. The formula installs the
latest release, which does not have the changes listed under Unreleased in
[CHANGELOG.md](CHANGELOG.md) — capturing held devices, mass storage, usbip-win2 support
among them. To use those, build from source (see
[Building the Project](#building-the-project)).

```bash
# Add the usbip tap
brew tap beriberikix/usbipd-mac

# Trust the tap. Homebrew 6 refuses to load formulae from untrusted third-party taps,
# and there is nothing a tap author can do about it — trust is a per-user decision, and
# only official Homebrew taps are trusted automatically.
brew trust beriberikix/usbipd-mac

# Install usbip
brew install usbip
```

Without the trust step: `Refusing to load formula beriberikix/usbipd-mac/usbip from
untrusted tap`. Trusting a single formula rather than the whole tap also works:
`brew trust --formula beriberikix/usbipd-mac/usbip`.

#### Service Management

After installation, you can manage the usbipd daemon using Homebrew services:

```bash
# Start the service (sudo is needed for USB device access)
sudo brew services start usbip

# Stop the service
sudo brew services stop usbip

# Restart the service
sudo brew services restart usbip

# Check service status
brew services info usbip
```

#### There is no System Extension

usbipd serves devices from userspace through IOKit. It needs no System Extension, no
DriverKit extension and no entitlement to do it.

The subsystem that once claimed otherwise was removed in 0.7.0 — some 24,000 lines that
no shipping path could reach. It could not have worked: `OSSystemExtensionRequest`
resolves extensions inside the *calling process's own* bundle and requires that bundle
to live in `/Applications`, which a Homebrew-installed binary is not. Its device-claiming
strategy was also measured not to unbind anything.

Devices macOS has not bound a driver to are served as they are. Devices whose
interfaces it holds are no longer refused: the daemon captures them from their drivers
when a client attaches, which IOUSBHost lets root do without any entitlement (see the
note at the top). See
[Documentation/development/driver-free-release.md](Documentation/development/driver-free-release.md)
for the history.


#### Troubleshooting Homebrew Installation

Common installation issues and solutions:

- **Permission Errors**: run service commands with `sudo`; the daemon needs privileged USB access
- **Service Won't Start**: Verify the binary installed correctly with `which usbipd` and check logs with `brew services list`
- **Version Issues**: Update with `brew upgrade usbip` or reinstall with `brew reinstall usbip`

#### What `bind` says about a device macOS holds

`bind` no longer refuses a device that a macOS driver or another process holds. It
offers it, and says what attaching it will take from macOS. For a USB BD-RE drive:

```
$ usbipd bind 1-1
Note: macOS has bound drivers to 1-1 (IOUSBMassStorageInterfaceNub).
When a client attaches, the daemon takes the device from them and gives it
back when the client detaches. Taking it needs the daemon to run as root
(sudo brew services start usbip).

It is a storage device:
- Eject its volumes before attaching. Taking it would cut them off
  unflushed, so the daemon refuses while one is mounted.
- macOS opens a storage interface only to a process with Full Disk
  Access, and goes by the app the daemon was started from. Grant it in
  System Settings > Privacy & Security > Full Disk Access to the
  terminal app you start the daemon from. A daemon started over SSH
  is refused. Started at boot, as brew services does, the daemon
  would need the grant itself, which has not been tested.
`sudo usbipd probe 1-1` checks both without a client.
✓ Device 1-1 added to server configuration
Bound device 1-1: 18a5:0428 (Verbatim 4K BD RW)
Registered for USB/IP sharing. macOS keeps the device until a client attaches.
```

A device another process has open is offered the same way; the capture terminates that
process's hold on it too. `sudo usbipd probe <busid>` opens a device exactly as an
attach would, prints what that took from macOS and which interfaces and endpoints
opened, and gives the device back, so you can find out without a client.

To check hardware before buying or debugging, `./Scripts/validate-usb-entitlements.sh`
reports which of your attached devices are claimable and which are owned.

### Manual Installation (Development)

For development or manual installation, see the [Building the Project](#building-the-project) section below.

## Usage

Once installed, you can use usbip to share USB devices over the network:

### Basic Commands

```bash
# List available USB devices
usbipd list

# Share a USB device (device ID from list command)
usbipd bind <busid>

# Check daemon status and shared devices
usbipd status

# Stop sharing a device
usbipd unbind <busid>

# Run the daemon in the foreground, as root (for storage devices, from a terminal app
# that has Full Disk Access)
sudo usbipd daemon -f

# Open a device as an attach would, report what that took, and give it back
sudo usbipd probe <busid>

# Write a codeless kext that keeps macOS's drivers off a device (a fallback; needs SIP off)
usbipd kext <busid>
```


### Client Connection

From a USB/IP client (typically Linux):

```bash
# Install USB/IP tools (Ubuntu/Debian)
sudo apt install linux-tools-generic

# Connect to shared device
sudo usbip attach -r <macos-ip-address> -b <device-id>

# List attached devices
usbip port

# Detach device
sudo usbip detach -p <port-number>
```

From Windows, with [usbip-win2](https://github.com/vadimgrn/usbip-win2) (its `usbip.exe`
is in `C:\Program Files\USBip`; its GUI, wusbip, does the same):

```powershell
# Connect to a shared device
usbip.exe attach -r <macos-ip-address> -b <busid>

# List attached devices
usbip.exe port

# Detach a device
usbip.exe detach -p <port-number>
```

### Storage devices over a network

A storage client sends one SCSI command at a time, and each takes three USB/IP round
trips — the command block, the data and the status — each waiting for the one before.
So the network's round-trip time, not the device or the daemon, usually sets the pace.
Measured with a USB BD-RE drive attached to Windows over Wi-Fi: the drive answered each
transfer in about a millisecond, the daemon added nothing measurable, and the round
trips took a median of 9 ms each. A link with shorter round trips, such as a wired one,
should help more than anything on the Mac can.

On Windows, an Explorer window open on an optical drive makes Explorer ask the drive
for its features about 34 times a second. Locally that goes unnoticed; over the network
it took most of the link. Closing the window made reads several times faster.

Give a bus-powered optical drive enough power: its own USB 3 cable, or a powered hub. A
drive running at USB 2 once dropped off the bus while spinning up a disc (macOS's kernel
log says "hardware connection lost").

The same BD-RE drive at USB 3 at times dropped off the bus as it went to standby, about
32 seconds after a fast read, and was back 0.6 seconds later. It did so with macOS alone
too, which recovers without a word. The daemon holds an attached client's requests while
its device comes back, for up to 10 seconds, and the client keeps the device if the same
one comes back at the same port. One that stays away ends the session, as an unplugged
device does. Windows, caught mid-mount by a drive going away like that, would then not
start its CD-ROM driver for the drive again (problem code 38) until it restarted;
restarting Explorer did not clear it.

### Seeing what a client and a device said

Set `USBIPD_TRACE` in the daemon's environment to log every request, every request the
daemon carried out itself, every completion with its IOReturn, and every reply. Requests
show the first 32 bytes of what they send, so a storage device's commands can be read
from their command blocks, and replies the first 16 bytes of what comes back. Writing
the log to a file keeps a terminal's scrollback out of the daemon's way, and appending
to it keeps what came before a restart:

```bash
sudo USBIPD_TRACE=1 usbipd daemon -f >> /tmp/usbipd-trace.log 2>&1
```

It writes several lines for every transfer, so leave it off when you are not looking.

### Docker Integration

For Docker Desktop users:

```bash
# Ensure the service is running
sudo brew services start usbip

# USB devices will be available to Docker containers
# through the USB/IP protocol integration
```

## Project Status

This project is currently in early development. The core server functionality is being implemented as an MVP.

## Building the Project

### Quick Start

```bash
# Build the project
swift build

# Build with Xcode (recommended for development)
xcodebuild -scheme usbipd-mac build

# Build a release binary and run the daemon from it
swift build -c release
sudo .build/release/usbipd daemon -f
```


## Running Tests

```bash
# Run all tests
swift test

# Run specific test environments (see Documentation for details)
swift test --parallel                 # Run the test suite
```

If `xcode-select` points at the Command Line Tools, which have no XCTest, run the suite
against Xcode: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.

## Documentation

For detailed information about development, architecture, and troubleshooting, see the comprehensive documentation in the [`Documentation/`](Documentation/) folder:

### Development Documentation
- [**Architecture**](Documentation/development/architecture.md) - System design and component overview
- [**CI/CD Pipeline**](Documentation/development/ci-cd.md) - Continuous integration and branch protection
- [**Testing Strategy**](Documentation/development/testing-strategy.md) - Test environments and validation approaches

### API and Protocol Documentation
- [**USB Implementation**](Documentation/api/usb-implementation.md) - USB/IP protocol implementation details
- [**Protocol Reference**](Documentation/protocol-reference.md) - USB/IP protocol specification
- [**QEMU Test Tool**](Documentation/qemu-test-tool.md) - QEMU validation server usage

### Troubleshooting Guides
- [**Build Troubleshooting**](Documentation/troubleshooting/build-troubleshooting.md) - Common build and setup issues
- [**QEMU Troubleshooting**](Documentation/troubleshooting/qemu-troubleshooting.md) - QEMU test server issues

## Release Automation

usbipd-mac uses automated GitHub Actions workflows for consistent and reliable releases.

### For Maintainers

#### Release Process

1. **Create and Edit Changelog**:
   ```bash
   # Manually edit CHANGELOG.md to document changes for the release
   # Add entries under the [Unreleased] section
   # Follow Keep a Changelog format
   ```

2. **Commit Changelog**:
   ```bash
   # Commit the changelog updates
   git add CHANGELOG.md
   git commit -m "docs: update changelog for v1.2.3 release"
   ```

3. **Prepare Release Locally**:
   ```bash
   # Prepare specific version (will prompt to review auto-generated changelog)
   ./Scripts/prepare-release.sh --version v1.2.3
   
   # The script will:
   # - Update CHANGELOG.md with version entry
   # - Pause for you to manually edit the changelog
   # - Run validation, tests, and create the Git tag
   ```
   
   Available options:
   - `--version VERSION`: Specific version (e.g., v1.2.3 or 1.2.3)
   - `--dry-run`: Preview actions without making changes
   - `--skip-tests`: Skip test execution (not recommended)
   - `--skip-lint`: Skip code quality checks (not recommended)
   - `--force`: Override safety checks and skip manual changelog review

4. **Push Release Tag**:
   ```bash
   # Push the created tag to trigger automated workflows
   git push origin v1.2.3
   ```

5. **Automated Pipeline**: Once a version tag is pushed, GitHub Actions automatically:
   - Validates the release candidate
   - Builds production artifacts with code signing
   - Runs comprehensive test validation
   - **Updates Homebrew formula automatically**
   - Creates GitHub release with artifacts and checksums
   - Pushes formula changes back to the repository

6. **Emergency Releases**: For critical fixes, use `--force` to skip manual changelog review and validation.

#### Homebrew Formula Management

**External Tap Architecture**: The Homebrew formula is managed in a separate tap repository and is updated automatically via homebrew-releaser GitHub Action during the release workflow.

**Automated Formula Update Process**:

The release workflow uses homebrew-releaser for direct formula updates:
- Homebrew-releaser action automatically updates formula in the external tap repository: [`homebrew-usbipd-mac`](https://github.com/beriberikix/homebrew-usbipd-mac)
- Formula is committed directly to tap repository with proper version and SHA256
- No metadata files or manual intervention required

**Immediate Availability** - users can install and update through Homebrew immediately after a release is published.

**Formula Testing and Validation**:
```bash
# Test installation from tap
brew uninstall usbip || true
brew untap beriberikix/usbipd-mac || true
brew tap beriberikix/usbipd-mac
brew trust beriberikix/usbipd-mac
brew install usbip
```

**Formula Repository**: The formula and automation workflows are maintained in the separate [`homebrew-usbipd-mac`](https://github.com/beriberikix/homebrew-usbipd-mac) repository.

#### Versioning Strategy

- **Semantic Versioning**: Follow semver (MAJOR.MINOR.PATCH) for all releases
- **Release Schedule**: Monthly minor releases with patch releases as needed
- **Pre-releases**: Use `-alpha`, `-beta`, `-rc` suffixes for testing releases
- **Changelog**: Automatically generated from conventional commits

#### Required Setup

For release automation to work properly:

1. **Code Signing**: Configure Apple Developer certificates in GitHub repository secrets
2. **Permissions**: Ensure maintainer access to repository settings and secrets
3. **Environment**: Validate local environment with release preparation script

Validation commands:
```bash
# Check release preparation environment
./Scripts/prepare-release.sh --help

# Formula tooling lives in the tap repository, not here:
#   https://github.com/beriberikix/homebrew-usbipd-mac
```

See [Release Automation Documentation](Documentation/Release-Automation.md) for complete setup instructions and troubleshooting.

### For Contributors

Release automation is handled by maintainers. Contributors should:
- Follow conventional commit format for automatic changelog generation
- Ensure all PRs pass CI validation before merge
- Report issues with release automation to repository maintainers

## License

[MIT License](LICENSE)

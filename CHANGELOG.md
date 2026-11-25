# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added — devices macOS holds are served, mass storage included

`bind` refused any device a macOS driver or another process held — HID, mass storage,
audio, cameras, CDC-ACM — because nothing could release one. IOUSBHost lets root
*capture* a device, without the DriverKit entitlement Apple refused this project: the
drivers and clients on it are terminated, and when the client detaches the device is
reset and handed back to them. `bind` now offers such a device and says what attaching
it will take from macOS, and the daemon captures it when a client attaches. That needs
the daemon to run as root.

Mass storage took two more steps, measured with a USB BD-RE drive (18a5:0428) on
macOS 27.0.1:

- A capture terminates the storage driver, but the interface node it was on can stay
  behind with the driver found back on it. The daemon selects configuration 0 and then
  the current one again, unmatched, which gives a fresh interface nothing has claimed.
- macOS opens a storage interface only to a process with Full Disk Access, and fails
  the open with `kIOReturnInternalError` otherwise. It goes by the app the daemon was
  started from: a daemon started with `sudo` from Terminal opened the drive, and one
  started with `sudo` over SSH was refused, although the SSH session could read files
  Full Disk Access protects. The error names the processes the daemon was started
  from and what to do.

A device whose volumes are mounted is refused rather than captured, since a capture
would cut them off unflushed. With this the drive was attached to Windows 11 through
usbip-win2 0.9.8.1, and a disc in it read.

### Added — `usbipd probe` and `usbipd kext`

`sudo usbipd probe <busid>` opens a device the way an attach does — as it is if nothing
holds it, captured otherwise — and prints each step: what was attached to each interface
before and after the capture, each configuration selection, and each failed open. Then
it gives the device back. It tells you what attaching will do to a given device on a
given macOS release, without a USB/IP client.

`usbipd kext <busid>...` writes `usbipd-claim.kext`, a kext with no code whose
personalities out-match macOS's class drivers on the given devices' interfaces. It is a
fallback for an interface a capture does not release; the BD-RE drive did not need it.
Loading it needs System Integrity Protection off, and it has not been loaded.

### Fixed — a TCP read was taken as one whole message

The connection handed each TCP read to the request processor as exactly one message. A
bulk OUT larger than one read arrived in pieces, each decoded as a message of its own,
and URBs a client wrote back to back were lost after the first. Small request/response
traffic happened to arrive one message per read, which is why the probes validated
before worked; a mass storage device would not have survived its first write. Messages
are now framed from their headers, payloads and isochronous descriptors included, and a
header that cannot start a valid message closes the connection.

### Fixed — an attached device was served through one interface, one transfer at a time

The transfer path opened the first interface IOKit listed and sent every transfer there.
It found the device by vendor and product ID, so two identical devices could not be told
apart, and ran each transfer as a blocking call. It passed SET_CONFIGURATION,
SET_INTERFACE and CLEAR_FEATURE(ENDPOINT_HALT) to the device as raw bytes, which left
the host's own state behind: after clearing a halt that way, the host's endpoint stayed
halted and every later transfer failed.

An imported device is now served through IOUSBHost and found by its busid: every
interface of the current configuration, every endpoint of the selected alternate
settings, any number of URBs in flight, and each endpoint in order. The requests that
change the host's state are carried out by the host. A CMD_UNLINK is answered once its
abort completes. Other requests caught up in the same endpoint abort are queued again
instead of being answered with ECONNRESET, which Linux drivers take as their own
unlink. Every reply goes out from one queue, so a RET_UNLINK can no longer overtake its
RET_SUBMIT, the order that makes Linux's vhci detach the device. A device that cannot be
served is refused at import, with the reason in the daemon's log, and when the client
disconnects the device goes back to macOS.

### Fixed — a STALL was reported as a protocol error

IOUSBHost reports a stalled endpoint as `kUSBHostReturnPipeStalled` (0xe0005000), not
IOUSBLib's `kIOUSBPipeStalled`, so a stall went out as EPROTO. Storage devices stall as a
matter of course: with no disc in it, the BD-RE drive stalled the data phase of the
storage driver's third command. Windows, never told it was a stall, did not clear it or
read the status, every later command timed out, and USBSTOR gave up with code 10. A
stall is now EPIPE, and the host's side is left for the client to clear, as Linux's
server leaves it.

### Fixed — a captured drive's tray stayed locked

macOS locks a drive's tray with PREVENT ALLOW MEDIUM REMOVAL while it has a disc, and a
capture terminates its storage drivers without them unlocking it. The client never set
that lock and does not know to clear it, so its eject was refused. With the BD-RE drive
attached to Windows, Explorer said "An error occurred while ejecting", and the drive's
sense data was ILLEGAL REQUEST, 53/02, medium removal prevented. It happened when macOS
had held the drive with a disc in long enough to lock it before an attach, so it came
and went. Once it has captured a storage device, the daemon now sends each logical unit
of its bulk-only interfaces PREVENT ALLOW MEDIUM REMOVAL allowing removal, before the
client has the device. A unit attention that comes first is read and the command sent
again; an exchange that goes wrong ends with the transport's reset recovery, so the
client still starts clean. Then the daemon selects the configuration again. The
exchange moves the bulk endpoints' data toggles off DATA0, where a client that has just
configured the device expects them. Without the re-selection, the drive acknowledged
Windows' first command block and never acted on it, and that first command hung for
20 seconds.

### Fixed — isochronous transfers

Isochronous calls passed no completion callback and freed their buffers while the
transfer was still pending. Neither SUBMIT message knew about the per-packet descriptors
that follow an isochronous request, so an IN request's descriptors were read as data.
Isochronous transfers are now IOUSBHost transaction lists, one transaction per packet
(macOS 12 and later), with each packet's length and status in the reply. The
descriptors are decoded at any alignment; they follow the data, so they can start at an
odd offset. A request whose packet lengths add up past the transfer limit is refused;
three packets of 0xffffffff bytes used to trap a daemon running as root. None of this
has been validated on hardware yet.

### Fixed — SuperSpeed devices were advertised as Wireless USB

USB/IP carries Linux's `enum usb_device_speed`, where 4 is Wireless USB, 5 SuperSpeed
and 6 SuperSpeed+. This project's own enum values went out instead, so a Linux client
attached a SuperSpeed device to vhci's high-speed hub, and SuperSpeed+ went out as 0.
They now go out as 5 and 6.

### Fixed — every device was described as one interface of unknown class

Device lists and import replies gave every device one configuration and one interface
of unknown class, so `usbip list -r` showed "(Defined at Interface level)" for all of
them. They now carry each device's current configuration and each interface's class.

### Changed — replies go out without waiting

The listener sets TCP_NODELAY, as Linux's usbip tools do. With Nagle's algorithm, the
short last segment of a large reply, such as a 64 KiB read, waited for the client to
acknowledge the segments before it. A connection now reads up to 1 MiB at a time instead
of 64 KiB, and IOUSBHost's transfer buffers are reused instead of being mapped for every
transfer.

### Added — `USBIPD_TRACE`

Setting `USBIPD_TRACE` in the daemon's environment logs every CMD_SUBMIT and
CMD_UNLINK, every request carried out on the host, every completion with its IOReturn
and every reply. An import logs how the device was opened, step by step, as
`usbipd probe` prints it.

### Measured — a storage device over a network

Every SCSI command a storage client sends takes three USB/IP round trips — the command
block, the data and the status — and each waits for the one before. With the BD-RE drive
attached to Windows over Wi-Fi, the drive answered each transfer in about a millisecond
and the daemon added nothing measurable. The round trips, at a median of 9 ms each, set
the pace. An Explorer window open on the drive made Explorer ask the drive for its
features about 34 times a second, which took most of the link: closing the window made
reads several times faster.

### Known limitations

- Isochronous and interrupt transfers, the claim kext, and capturing HID, audio, camera
  and CDC-ACM devices have not been validated on hardware.
- A Full Disk Access grant to the `usbipd` binary itself, which a daemon started at boot
  would need, has not been tested. A locally built binary is ad hoc signed, so macOS
  would tie such a grant to that one build.

### Removed — the System Extension subsystem

Some 24,000 lines that no shipping path could reach, and a release artifact no
installed component could locate.

Activation was never attempted: both `OSSystemExtensionManager.submitRequest` call
sites were unreachable, gated on a configuration value nothing ever set. The whole of
`Sources/SystemExtension/` was unreachable even from its own executable, its types
shadowed by same-named stubs. `usbipd status` had 600 lines of reporting behind a guard
that always took the early return.

None of it could have worked. `OSSystemExtensionRequest` resolves extensions inside the
calling process's own bundle and requires that bundle to live in `/Applications`; a
Homebrew-installed binary is neither. The claiming strategy underneath — setting
`IOMatchCategory` and `IOProbeScore` from userspace — was measured not to unbind
anything, and is not how a DriverKit extension matches in any case.

Nothing that worked has changed. Devices macOS has not bound a driver to are served
exactly as before; devices whose interfaces it holds are refused by `bind`, which names
the owner. Those decisions were always made by `DeviceOwnershipInspector` and by IOKit
refusing `USBInterfaceOpen`, not by the extension.

**User-visible changes:**

- `USBIPDSystemExtension.systemextension.tar.gz` is no longer published. It was signed,
  notarized and stapled every release, and was not a System Extension bundle by
  structure — no `NSExtension` dict, no `IOKitPersonalities`, and an empty
  `embedded.provisionprofile`.
- `systemextension_url` and `systemextension_sha256` are gone from the Homebrew
  metadata. Nothing consumed them.
- `usbipd status` reports how devices are accessed and which are shared, and no longer
  claims to report on an extension. `--health` is still accepted and says plainly that
  there is nothing further to check.
- `bind` and `unbind` no longer print "Checking System Extension status..." or branch
  their success message on whether a manager existed.
- `~/Library/Application Support/usbipd-mac/cli-claimed-devices.json` is no longer read
  or written. It recorded claims that were never taken; any existing file is inert and
  can be deleted.
- `usbipd.entitlements` is gone. The binary carried
  `com.apple.developer.system-extension.install`, a restricted entitlement AMFI kills
  without an authorising profile, so release signing had to withhold it — which it
  always did. With nothing to install, signing has one path.

`Sources/SystemExtension/Info.plist`, its entitlements and the README explaining the
failure are preserved under `Documentation/development/system-extension-archive/`. They
record the identifier and entitlement decisions a future DriverKit extension needs.

Also corrected: `CLAUDE.md` claimed `Tests/SharedUtilities/` was compiled by both test
targets. SwiftPM ignores `sources:` paths outside the target directory, so it never was.

## [v0.6.0] - 2026-08-09

This release makes usbipd usable on a machine with a USB hub, which in practice means
most machines. It also makes CMSIS-DAP debug probes work end to end, and stops two
attached devices from interfering with each other. Every fix below was measured against
hardware: a SEGGER J-Link, a Raspberry Pi Debug Probe, an FTDI Quad RS232-HS, a Silicon
Labs CP2102N, and a Pixel 10a.

### Fixed — every device behind a hub was unreachable

A busid became a hub port path when locationID decoding was corrected, so a device two
tiers down is `32-2.2`. The wire protocol has no room for that: USB/IP identifies a
device by a devid the client composes from the bus and device numbers in the import
reply. The encoder kept only the final port, so `32-2.2` and `32-2` both went out as
device number 2, and the server resolved the devid to whichever matched first.

That was the hub. Importing a CP2102N at `32-2.2` handed back an identifier naming the
USB2.0 hub above it, and the first transfer died in `USBDeviceOpen` with
`kIOReturnExclusiveAccess`, because macOS owns hubs. On a docked machine this was nearly
every device.

The port path is now packed one nibble per tier, mirroring how macOS builds locationID,
and a devid is resolved by matching it against the devices actually attached rather than
by unpacking it — so a stale or unrepresentable identifier resolves to nothing and the
client is told ENODEV instead of being pointed at the wrong device. Four tiers of up to
fifteen ports each are representable; deeper chains are refused rather than approximated.

### Fixed — transfers on one device blocked each other

Every transfer on an interface went through a single serial queue, and IOKit's
`ReadPipeTO` and `WritePipeTO` block the calling thread until they complete or time out.
A pending IN transfer therefore held the queue for its entire timeout, and no other
transfer could start — including the OUT transfer carrying the command that would have
made the device answer the read. Any protocol that reads and writes at once deadlocked
until the timeout, then failed.

A Raspberry Pi Debug Probe showed it exactly: probe-rs posted a read, then fifteen
writes that sat untouched for sixty seconds and all completed within sixteen
milliseconds of the read finally timing out.

Each endpoint now has its own queue. Transfers on one endpoint stay ordered, as USB
requires of a pipe, while unrelated endpoints proceed in parallel — which USB/IP has
always assumed, since the protocol carries a sequence number precisely so replies may
return out of order.

### Fixed — a cancelled transfer was carried out anyway, and answered later

A client that withdrew a request got it performed regardless. The sequence number was
claimed only after an IOKit enumeration, so an UNLINK arriving a millisecond later found
nothing and was told the request had already completed; the abort was aimed at the
endpoint in the UNLINK message, which is always zero, so it hit the control pipe; and
`AbortPipe` was called with an endpoint number rather than an IOKit pipe reference. The
transfer ran on, collected the answer to a later command, and delivered it under a
sequence number the client had retired.

This is why `probe-rs info` failed against a CMSIS-DAP probe with "Error in the USB
access": probe-rs drains the IN endpoint with a short timeout before its first command,
and that abandoned read consumed every response it wanted. It matters well beyond debug
probes, because libusb cancels any read it has timed out.

A cancelled request is now aborted at the correct pipe and answered by its RET_UNLINK
alone, carrying `-ECONNRESET` as the URB status — which libusb reads as cancelled, and
for a timed-out read as a timeout. `probe-rs info` against a Debug Probe now completes
946 transfers, 929 of them on the CMSIS-DAP bulk endpoints, and stops only at chip
detection — the identical error the probe gives plugged straight into the Mac, because
no target is wired to its SWD pins.

### Fixed — two attached devices interfered with each other

USB/IP numbers requests per connection and the Linux client opens one connection per
attached device, so every client starts again at 1. Request tracking used one
process-wide table keyed on the bare sequence number, so a second client's first request
looked like a duplicate of the first client's and was refused — and refused silently,
because the rejection was thrown past the code that turns a refusal into a reply, leaving
the client waiting for an answer that never came.

Attaching two devices from a single machine was enough to trigger it. Measured with an
FTDI and a CP2102N driven at once: five of ten concurrent transfers failed before the
change, none after.

### Fixed — `bind` and `unbind` needed a daemon restart

They are separate processes that write a file the daemon read only at startup. A device
bound while the daemon was running stayed unimportable — `usbip attach` answered
"Request Failed" — and nothing said a restart was needed. The daemon now notices the
file has changed and re-reads it.

### Fixed — `bind` rewrote unrelated configuration

The bound-device list lived in the configuration file beside the port, the log level and
the transfer tuning, so `bind` rewrote the whole file to append one busid. Because the
CLI falls back to a default configuration when that file will not parse, a single
malformed character turned the next `bind` into a silent reset of the port and log
level.

The list now lives in `~/.usbipd/bound-devices.json` and is the only thing bind and
unbind touch; `~/.usbipd/usbipd-config.json` is read and never written. An
`allowedDevices` key left in an old configuration is migrated once and then ignored.
Updates are serialised with a lock, so two `bind` commands can no longer lose each
other's device.

### Fixed — `bind` accepted devices it could not serve

A device that exposes no USB interfaces was reported as free, then failed every transfer
with "Interface 0 not found". This happens when macOS has not configured the device,
usually because another process is driving it directly — a browser tab using WebUSB, for
instance. It is now refused with an explanation.

### Fixed — USB-serial adapters were refused, and they work

`bind` decided ownership from which driver was attached to an interface. That inference
holds for HID and mass storage, and is wrong for serial: `IOUserSerial` sits on every
FTDI and CP210x interface without taking exclusive access. Measured against an FTDI
Quad RS232-HS and a Silicon Labs CP2102N, both return their real descriptor over USB/IP
and the FTDI returns real bulk data — `status=0 actual=2 data=0260`, its modem-status
bytes.

So the most-requested category was being refused with a message claiming it needed a
DriverKit entitlement from Apple. It does not.

Ownership is now decided by attempting to open the interface and closing it again,
which is what the entitlement harness always did. The refinement "dexts do not block,
kernel drivers do" is also wrong — `AppleUserHIDDevice` is a dext and does block — so
nothing short of attempting the open is reliable. HID, mass storage and audio are still
correctly refused.

**Caveat:** macOS keeps its serial driver attached and still publishes `/dev/cu.*`.
Nothing prevents a local program opening that while a remote client drives the same
UART.

### Known limitations

Interrupt endpoints remain untested — no unbound interrupt device has been available.
Isochronous is structurally incomplete: alternate settings are never selected and pipes
are discovered once at open, so a UVC device's isochronous endpoints would never appear.
Hub port paths deeper than four tiers cannot be represented in a devid and are refused.
A device that disappears mid-session may keep failing until the daemon is restarted.

## [v0.5.4] - 2026-08-08

### Fixed — v0.5.3 could not serve any device

v0.5.3 stopped starting the System Extension manager at launch, which was correct: it
cannot be activated from a shipping install and it was scanning the filesystem on every
command. But three separate code paths still required a successful claim from it, so
with the manager unstarted they all failed:

- `bind` refused every device with "System Extension failed to claim device"
- the import handler refused every attach with "Failed to claim exclusive access"
- every transfer failed with "Device not claimed for USB operations"

None of those claims did anything real. Devices are served through IOKit from userspace,
and what actually gates access is the bind allow-list and IOKit's own exclusive-access
rules. All three now proceed when no claim is recorded.

This was shipped, and would have been caught before tagging by running
`Scripts/verify-hardware.sh` — which could not run, because no device was attached.

### Fixed — composite debug probes were refused

Ownership was decided for the device as a whole, so any interface held by a driver
refused the entire device. A Raspberry Pi Debug Probe pairs a free CMSIS-DAP interface
with a CDC serial port that macOS claims, and was rejected despite the debug interface
being usable — as are most composite probes, including ST-Link with VCP.

Ownership is now per interface. A device with at least one free interface can be bound,
and `bind` says which interfaces are served and which macOS holds.

### Known limitation — CMSIS-DAP probes enumerate but do not fully drive

`probe-rs list` finds a Raspberry Pi Debug Probe over USB/IP and reads its serial, and
control transfers return its real descriptor. `probe-rs info` fails: the CMSIS-DAP
exchange on endpoints 0x04/0x05 writes successfully but some reads return EPROTO or time
out. Not yet diagnosed.

## [v0.5.3] - 2026-08-08

### Fixed — the CLI was unusable to read

A plain `usbipd list` printed roughly forty lines of debug logging around three lines
of output. Every component constructs its own `Logger` with a hardcoded level — 27 at
`.info`, 3 at `.debug` — so `ServerConfig.logLevel` governed nothing. `Logger` now has a
process-wide floor defaulting to `.warning`, which wins where it is stricter. The daemon
raises it to `.info`, since its output goes to a log file, and `USBIPD_LOG_LEVEL`
overrides both.

### Fixed — `usbipd -v` reported the wrong build

A Homebrew-installed release binary printed `Build: Development`, because `main.swift`
emitted that literal. A correct implementation existed in `CommandLineParser` but was
never reached, since `main.swift` intercepts `-v` first. Both now read one value.

### Fixed — the CLI hunted for a System Extension on every command

The bundle detector walked the filesystem on every invocation, including the
developer's own `.build` directory: an installed binary was scanning a source tree it
found there and adopting a debug bundle from it. The manager was also started each
time, restoring claim state for a subsystem that cannot be activated from a Homebrew
prefix. Neither now happens, and `usbipd status` no longer instructs users to install a
System Extension they cannot install.

### Fixed — `usbipd completion` wrote files when given no verb

The action defaulted to `generate`, whose output directory defaults to the working
directory, so a bare `usbipd completion` silently wrote three completion scripts
wherever the user was standing. It now prints usage.

## [v0.5.2] - 2026-08-07

### Added — Intel Macs are supported again

Releases through v0.5.1 shipped an arm64-only binary, because the release workflow ran
a plain `swift build` on an Apple silicon runner. Installing on an Intel Mac succeeded
and then failed with `Bad CPU type in executable` (#32).

The build now produces both architectures and splits them with `lipo`, publishing
`usbipd-<version>-macos-arm64` and `usbipd-<version>-macos-x86_64`. The formula selects
with `on_arm`/`on_intel`, so each user downloads one artifact of about 5.4 MB — slightly
smaller than the arm64-only build, rather than the 10.8 MB a universal binary would
cost everyone. Each slice is signed separately, since `lipo -thin` strips the signature.

## [v0.5.1] - 2026-08-07

### Fixed — control transfers were broken in release builds only

`performControlTransfer` returned a pointer out of `setupPacket.withUnsafeBytes`,
which only guarantees it inside the closure. Every subsequent read was of freed
memory. Debug builds happened to leave the bytes intact, so all prior validation
passed; optimised builds did not, so `bmRequestType`, `bRequest`, `wValue`, `wIndex`
and `wLength` became garbage, the device received a malformed request, and the pipe
stalled — `kIOUSBPipeStalled`, reaching clients as EPROTO.

This affected **v0.5.0 as shipped**: control transfers are how a client enumerates a
device, so attaching from Linux would fail against the released binary even though bulk
transfers worked. Found by testing the Homebrew-installed artifact rather than a local
debug build.

## [v0.5.0] - 2026-08-06

First release in which the software does what it claims. Every prior release shipped a
transfer path that had never moved data, and a `bind` that recorded devices without
serving them. Those releases have been deleted rather than left to mislead.

The version number also means something now: it was hardcoded as "0.1.0" in three
separate print statements, so every previous release reported 0.1.0 regardless of its
tag.

### Fixed — USB transfers now reach real hardware

The transfer path had never moved data. Several defects sat between a client
request and the device, each hiding the next.

- `ReadPipeTO`'s size argument is in/out — buffer capacity in, bytes read out — and was
  initialised to 0 and never set. IOKit was told the buffer could hold nothing, so any
  packet the device sent overran it. **Every IN transfer on the bulk and interrupt paths
  failed this way.**
- Transfer type was guessed from the request's interval field. USB/IP carries no
  transfer type, so it now comes from the device via `GetPipeProperties`. A J-Link
  declares `bInterval 1` on both of its *bulk* pipes, so the guess routed bulk traffic
  to the interrupt path.
- IOKit addresses pipes by a 1-based index into the interface, not by endpoint number.
  Endpoint discovery is now implemented and the index looked up.
- Direction was taken from bit 7 of the endpoint address, which a conforming client
  leaves clear because it sends direction in its own field.
- `USBSubmitProcessor` fabricated a `0000:0000` device instead of resolving the devid,
  so every lookup failed with ENODEV.
- 33 escaped string interpolations in `USBDeviceCommunicatorImplementation` — the one in
  `deviceIdentifier(for:)` gave every device the same literal key, so no claim matched.

Verified with probe-rs driving a J-Link from a Linux client over USB/IP, reading the
probe's VTref exactly as it does connected directly.

### Fixed — the bind allow-list is enforced

`bind` wrote devices to `allowedDevices` and nothing ever read it back. The server
advertised **every** USB device on the machine and served transfers on any of them,
bound or not. `isDeviceAllowed` also returned true for an empty list, so a fresh
install offered everything. Both are fixed; sharing is opt-in.

### Added — `bind` refuses devices something else owns

Previously it allow-listed anything and failed later at transfer time. It now reads
ownership from the IORegistry and refuses with an explanation naming the owner,
distinguishing a kernel driver (needs a DriverKit entitlement) from a userspace holder
(quit the app).

### Added — configuration settings are honoured

`maxUSBBufferSize`, `usbOperationTimeout`, `maxTotalConcurrentRequests`,
`maxPendingURBsPerDevice`, `maxConnections` and `connectionTimeout` all persisted and
validated their own ranges while nothing read them. They now apply. `maxUSBBufferSize`
matters most: `IOKitUSBInterface` allocated `Int(bufferLength)` straight from a
wire-supplied `UInt32`. `autoBindDevices` was removed rather than implemented, being
the opposite of the opt-in model.

### Fixed — transfers reported bytes they did not have

A timed-out IN transfer answered with `actualLength` set to the buffer capacity and no
payload, because that field is primed for `ReadPipeTO`'s in/out contract and IOKit does
not reset it when nothing is read. A client reading that many bytes would
desynchronise. Zeroed on every non-success path, for bulk and interrupt.

The default transfer timeout was also raised from 5000 ms to 60000 ms. At five seconds
any merely idle IN endpoint produced ETIMEDOUT, and `adb` gave up on its first read.
Both were found by testing against an Android device.

### Fixed — miscellaneous

- Bulk transfers apply a timeout; they used `ReadPipe`/`WritePipe`, which block forever
- `kIOUSBTransactionTimeout` maps to ETIMEDOUT rather than falling through to EPROTO
- A `defer` in a registry loop released the entry the next iteration was about to read
- `CommandHandlerError` was re-wrapped in itself, doubling error prefixes
- Data races in `USBSubmitProcessor` (concurrent-queue writes without `.barrier`)

### Removed

- `attach` and `detach`, which macOS cannot implement — that is a client-side operation
- `install-system-extension`, which could not succeed from a Homebrew prefix, and
  `diagnose`, which did not complete in 300 seconds. Both were registered but absent
  from `usbipd --help`
- The `.kiro` and `.gemini` directories
- `URBTracker`, `DeviceMonitor`, the global logging functions, and five other
  mechanisms that had tests but no production callers, dropping 42 tests that covered
  code the daemon never reached
- Two message validators with no callers anywhere, one of which contained a check that
  could never fire (`endpoint & 0x0F > 15`)
- ~17,800 lines of test targets that no target compiled and that had never run

### Added — MIT LICENSE

The README had claimed MIT while no LICENSE file existed, leaving the terms of
distribution unstated.

### Measured

- Seizing an interface does **not** take it from a kernel driver:
  `USBInterfaceOpenSeize` returns the same `kIOReturnExclusiveAccess` as a plain open.
  Neither unmounting nor ejecting releases a device either. Measured against mass
  storage, HID and a webcam.
- `com.apple.security.device.usb` is an App Sandbox entitlement and grants nothing
  here; the DriverKit transport entitlements are what gate this.

### Known limitations

- **Clients whose protocol keys off connection or reset events may not work**, even on
  a device that claims cleanly. `adb` reports an otherwise-working Pixel `offline`: the
  phone announces itself once per USB connection and macOS already received that
  announcement, and attaching from a client causes no bus reset the phone can observe.
  Request/response devices are unaffected.
- **UNLINK does not abort an in-flight read.** It answers `RET_UNLINK` immediately, but
  the transfer is only reclaimed when its own timeout expires. This is why the timeout
  cannot be removed in favour of unlimited waits.
- **`bind` does not affect a running daemon**, which reads the allow-list only at
  startup.

- Interrupt endpoints are unverified against hardware
- Isochronous is structurally incomplete: alternate settings are never selected and
  pipes are discovered once at open, so a UVC device's isochronous endpoints never appear
- The System Extension subsystem is quarantined and no shipping path activates it

## [v0.1.34] - 2025-08-28

### Added
- Comprehensive shell completion system for bash, zsh, and fish
- Dynamic completion for device IDs, IP addresses, and ports
- Intelligent command-aware argument completion
- Homebrew automatic completion installation and configuration

### Improved
- Enhanced CLI usability with tab completion support
- Better development experience with shell integration


## [v0.1.26] - 2025-08-22

### Added
- **System Extension Bundle Distribution**: Release workflow now builds and distributes system extension bundles
  - Builds USBIPDSystemExtension target explicitly in release workflow
  - Creates proper system extension bundle structure with Info.plist
  - Applies code signing to system extension bundle
  - Includes system extension bundle in release artifacts as compressed tar.gz
  - Generates checksums for both CLI binary and system extension
  - Updates Homebrew metadata to include system extension download URLs and checksums
  - Enhances release notes with system extension installation instructions

### Fixed
- **Homebrew System Extension Support**: Fixed "System Extension Status: Not Available" error for Homebrew users
  - System extension bundle now properly distributed with releases
  - Homebrew formula can install complete functionality including system extensions
  - Users can now successfully run `sudo usbipd install-system-extension`

## [v0.1.19] - 2025-08-21

### Fixed
- **Test Compilation**: Fixed duplicate BundleSearchResult struct causing compilation ambiguity
  - Removed duplicate struct definition in test file
  - Now uses internal struct from main source file

## [v0.0.17] - 2025-08-21

### Fixed
- **Release Automation**: Complete resolution of GitHub Actions workflow automation issues
  - Fixed critical YAML syntax errors preventing workflow execution
  - Resolved conditional logic in job dependencies
  - Fixed GitHub Actions context variable usage in shell environments
  - Restored proper tag-triggered releases vs branch push filtering
  - Enabled manual workflow_dispatch testing with parameter validation

### Improved
- Enhanced error handling in release workflows
- Improved homebrew-releaser integration reliability
- Better validation of release triggers and conditions

## [v0.0.14] - 2025-08-21

### Added
- **Homebrew Releaser Migration**: Complete migration from webhook system to homebrew-releaser GitHub Action
  - Automated homebrew tap management with homebrew-releaser action
  - Comprehensive post-migration monitoring and validation
  - End-to-end release automation with artifact management
  - Rollback procedures and validation scripts
  - Enhanced documentation and troubleshooting guides

### Changed
- Updated release workflows to use homebrew-releaser action
- Improved homebrew tap repository management
- Enhanced release monitoring and validation

### Removed
- Legacy webhook system for homebrew tap management

## [v0.0.6] - 2025-08-18

### Added
- **Complete System Extension Installation Framework**: Comprehensive system extension lifecycle management
  - Advanced installation orchestration with automatic and manual installation modes
  - Intelligent installation verification and validation system
  - Service lifecycle management with recovery and fallback mechanisms
  - Enhanced diagnostic capabilities for troubleshooting installation issues
- **Production-Ready Installation Workflows**: End-to-end system extension deployment
  - Automated installation process for developer environments
  - Manual installation guidance with step-by-step user instructions
  - Cross-platform compatibility validation (Intel, Apple Silicon, Universal)
  - Installation status monitoring with real-time progress reporting
- **Enhanced CLI Commands and Diagnostics**: Comprehensive command-line interface
  - New `install-system-extension` command for manual installation
  - Advanced `diagnose` command with system health checks
  - Installation verification and status reporting capabilities
  - Interactive troubleshooting and guidance system

### Fixed
- **Critical USB/IP Protocol Issues**: Resolved fatal crashes and protocol errors
  - Fixed USB/IP device list request command encoding (0x05 → 0x8005)
  - Resolved "Index out of range" crashes in integration tests
  - Improved timing for asynchronous notification processing
  - Enhanced error handling for network communication failures
- **Test Infrastructure Stability**: Comprehensive test suite improvements
  - Fixed critical integration test failures affecting production validation
  - Improved mock device simulation and timing reliability
  - Enhanced test environment setup and teardown procedures
  - Resolved Swift concurrency compliance issues
- **System Extension Bundle Detection**: Enhanced bundle management
  - Improved bundle detection and validation logic
  - Fixed bundle path resolution in various installation scenarios
  - Enhanced error handling for bundle creation and management
  - Better compatibility with different macOS versions and architectures

### Changed
- **Installation Architecture**: Streamlined and consolidated installation process
  - Simplified installation workflow with fewer user interaction points
  - Improved error recovery and fallback mechanisms
  - Enhanced logging and diagnostic information collection
  - Better integration with macOS System Extension APIs
- **Test Infrastructure**: Modernized testing approach
  - Consolidated test environments (development, CI, production)
  - Improved QEMU integration testing infrastructure
  - Enhanced mock systems for reliable automated testing
  - Streamlined CI/CD pipeline for faster validation

### Security
- **Enhanced System Extension Security**: Improved security validation
  - Strengthened code signing and entitlement validation
  - Enhanced installation verification to prevent tampering
  - Improved system permission management and validation
  - Better isolation and sandboxing of system extension components

### Performance
- **Optimized Installation Process**: Faster and more reliable installation
  - Reduced installation time through parallel processing
  - Improved resource utilization during installation
  - Enhanced memory management and cleanup procedures
  - Better error recovery without requiring system restarts

## [v0.0.4] - 2025-08-18

### Added
- **Homebrew System Extension Integration**: Complete end-to-end System Extension support for Homebrew installations
  - Automatic System Extension bundle creation during `brew install` process
  - Intelligent installation automation with developer mode detection
  - Manual installation fallback with guided user instructions
  - Cross-platform compatibility validation (Intel x86_64, Apple Silicon ARM64, Universal)
  - macOS version compatibility checking (macOS 11.0+)
- **Enhanced Installation Automation**
  - Automatic System Extension installation in developer mode environments
  - Manual installation script generation for standard environments
  - User guidance and troubleshooting documentation
  - Installation status monitoring and progress reporting
- **Comprehensive Error Handling and Recovery**
  - Structured error categorization and handling framework
  - Automatic recovery strategies for common installation failures
  - Diagnostic information collection for troubleshooting
  - Environment-specific validation and setup verification
- **Advanced Testing Infrastructure**
  - Complete end-to-end Homebrew workflow testing
  - QEMU integration testing for USB/IP protocol validation
  - Multi-environment test suite (development, CI, production)
  - Comprehensive compatibility testing across architectures and macOS versions

### Fixed
- **CI/CD Pipeline Reliability**
  - Resolved GitHub Actions workflow parameter mismatches
  - Fixed SwiftLint strict mode violations (31 violations resolved)
  - Corrected test discovery and execution in CI environments
  - Improved code quality with comprehensive linting compliance
- **System Extension Bundle Creation**
  - Fixed bundle structure validation and code signing integration
  - Resolved duplicate type definitions and build conflicts
  - Corrected Info.plist generation and entitlements configuration
- **Build System Improvements**
  - Enhanced Swift Package Manager integration
  - Improved dependency resolution and caching
  - Fixed cross-compilation issues for Universal binaries

### Changed
- **Test Architecture Refactoring**
  - Reorganized test helper functions to prevent XCTest discovery conflicts
  - Improved test naming conventions (test* → validate* for helpers)
  - Enhanced test execution performance and reliability
- **Documentation and Code Quality**
  - Comprehensive spec-driven development documentation
  - Improved code commenting and inline documentation
  - Enhanced error messages and user-facing guidance

### Technical Details
- System Extension bundle creation with proper macOS bundle structure
- CFBundlePackageType correctly set to "SYSX" for System Extension identification
- Automated code signing integration for notarization-ready bundles
- Environment detection for development vs. production installation workflows
- QEMU-based protocol validation for comprehensive testing coverage

## [v0.0.3] - 2025-08-16

### Added
- Uploaded certs for code signing

## [v0.0.2] - 2025-08-16

### Added
- Improved System Extension installation process

## [v0.0.1] - 2025-08-16

### Added
- Initial release


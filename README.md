# Bud Probe

SwiftUI iOS 26 tool for Pixel Buds control and general Bluetooth exploration.
No third party packages. Swift 5 language mode.

Pixel Buds controls need Bluetooth Classic RFCOMM, which an iPhone cannot access
through CoreBluetooth. This app separates those controls onto an authenticated
Linux bridge while keeping general BLE inspection available on the phone.
The bridge service and pbpctrl are external prerequisites and are not bundled here.

- **Buds:** battery and charging state, ANC, five-band EQ, multipoint, on-head
  detection, gesture settings display, firmware, and raw JSON commands with verbatim
  responses. Controls use the authenticated Linux bridge and pbpctrl over Classic
  RFCOMM.
- **Explore:** scan with the phone's CoreBluetooth adapter, bridge BLE, or bridge
  Classic inquiry. Results from all three sources stay in one list. Inspect and
  read/write/subscribe to GATT characteristics, or view Classic SDP records.
  Classic devices have no write controls. Phone identifiers are iOS UUIDs, not
  Bluetooth MAC addresses. They cannot be correlated automatically with bridge
  results.
- **Settings:** persistent bridge URL/token, health check, bridge trust list with
  revocation, and clearing saved actions. A 403 on write prompts for trust and
  retries once after confirmation. Phone writes use the same bridge trust list.

Save a labelled hex write from a writable characteristic. Saved actions appear in
that device's detail and grouped by device in Explore. Bridge actions reconnect
automatically. Phone actions reconnect to a device from the current scan. Scan
again after relaunch. Writes with no response report submission. Acknowledgements
and local notifications appear in the phone device log. Notification polling runs
only while a bridge detail is visible, subscribed, and the app is active.

The dark header strip, large controls, and monospaced output are retained. Device
details open inline, with no nested navigation. The abandoned L2CAP experiment and
Pixel Buds BLE control replays are not part of the current application.

## Architecture

- `Bridge.swift` holds the Foundation HTTP client, errors, and Codable bridge models.
- `BridgeStore.swift` coordinates controls, trust confirmation, persisted actions,
  connection settings, and verbatim command output.
- `Probe.swift` owns the CoreBluetooth central/peripheral delegates, discovery,
  reads, writes, subscriptions, and bounded phone log buffer.
- SwiftUI views provide the Buds, Explore, and Settings tabs. `LogTextView.swift`
  adapts UIKit TextKit for incremental log rendering. `LogRelay.swift` retains an
  optional plain-text HTTP export mechanism, disabled until explicitly configured.

## Notable engineering decisions

- Bridge clients are value snapshots so editing Settings cannot redirect an
  in-flight write or its trust-confirmation retry.
- A first-write 403 is preserved, prompts for trust, and retries exactly once.
  Bridge BLE writes can address characteristics by handle to disambiguate UUIDs.
- Saved phone actions discard session-specific object identifiers and resolve the
  characteristic again after reconnection. Ambiguous UUID matches are rejected.
- Notification polling follows visibility, connection, subscription, and scene
  state rather than running continuously in the background.
- Phone log updates are batched on a timer and capped at 2,000 lines. TextKit edits
  append and trim changed text while preserving the reader's scroll position.
- Operation-specific HTTP deadlines allow slow bridge status/command calls while
  keeping health checks and notification polls shorter.

## Bridge contract and configuration

Every request sends `X-Bridge-Token`. The default URL is
`http://127.0.0.1:8180` and the token starts empty. Set your own bridge URL and token
in Settings before using bridge features. On an iPhone, loopback means the phone,
not your Linux host. Use an endpoint you control that the phone can reach.
The Buds tab attempts a health check and status read when it appears.

The URL, token, and saved actions are stored locally in UserDefaults. Errors are
shown in the UI. This is not Keychain storage. Do not use an untrusted network for
plain HTTP token or device-data traffic. Prefer HTTPS or a trusted private network.

The required bridge contract includes **POST /ble/connect** with
`{"addr":"..."}`. Revoking trust uses `POST /trust/{addr}` with
`{"trusted":false}` rather than DELETE. The client also uses `/health`,
`/buds/status`, `/buds/cmd`, `/scan/ble`, `/scan/classic`, `/trust`,
`/ble/{addr}/gatt`, `/ble/disconnect`, `/ble/read`, `/ble/write`, `/ble/notify`,
`/notifications`, and `/sdp/{addr}`. The contract fixture documents representative
payloads but is not a production bridge implementation.

Requests are asynchronous and bounded: health 12s, ordinary operations 35s,
scans 40s, SDP 50s, status 180s, commands 200s, and notification polls 10s.
The session resource deadline is 240s. Bridge status reads may be slow when buds
are unavailable. Bridge reachability is separate from subcommand errors, which
are surfaced even when HTTP returns 200.

### Optional log relay

No log destination is configured by default. `pushLogToServer()` skips the export
when `logRelayURL` is missing or invalid, without starting an outgoing request.
To opt in during development, set Xcode scheme Run arguments to
`-logRelayURL https://example.com/log`, replacing that example with your own
HTTP(S) endpoint. This supplies a UserDefaults launch argument for that run.
Removing it disables the relay unless you have separately persisted the same key.
The relay sends UTF-8 text with `Content-Type: text/plain` on an explicit call to
`pushLogToServer()`. The current views do not expose a relay button. No automatic
log upload is added. Logs can include nearby device names, identifiers, and raw
characteristic values. Review them before exporting. The relay has no built-in
authentication and should only target a receiver you control.

## Stack and validation on Linux

The app uses SwiftUI, Combine, CoreBluetooth, Foundation/URLSession, and UIKit.
XcodeGen generates the Xcode project. The existing fixture runner uses Python 3
and a Swift compiler on PATH.

```sh
swiftc -parse App/*.swift
python3 Tests/run_bridge_contract.py
```

The contract check compiles the actual Foundation HTTP client and models and
checks authentication headers, query paths, POST bodies, battery/status and GATT
decoding, 403 error preservation, notifications, and saved action serialization
against a local fixture server. It does not substitute for an Apple SDK build or
device Bluetooth tests.

## Build and signing

Use a Mac with Xcode and an iOS 26 SDK, plus XcodeGen. The spec records Xcode 27.
No generated project is committed.

```sh
xcodegen generate
open BudProbe.xcodeproj
```

For an unsigned archive with an installed compatible Apple SDK:

```sh
xcodebuild -project BudProbe.xcodeproj -scheme BudProbe \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath .build/BudProbe.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" archive
```

The safe sample bundle ID is `org.example.BudProbe`. For device installation,
configure your own bundle ID, developer team, signing identity, and provisioning
profile. `CFBundleIdentifier` follows `PRODUCT_BUNDLE_IDENTIFIER`. Bluetooth usage
keys and the Bluetooth central background mode remain in Info.plist.

The retained release workflow archives, signs, and uploads an IPA artifact on
manual dispatch or a version tag. Before using it, set repository variable
`BUNDLE_ID` to match your own provisioning profile. Set secrets `P12_BASE64`,
`P12_PASSWORD`, `PROFILE_BASE64`, `SIGN_IDENTITY`, and `DEVELOPMENT_TEAM` using your
own signing credentials. Optional variable `MACOS_RUNNER` selects a runner with
the required Xcode/SDK. Its fallback is `macos-latest`, which is not a guarantee
that the recorded Xcode version is available. No signing credentials are bundled.

Linux syntax and fixture checks do not verify SwiftUI/Apple-framework type
checking, rendering, CoreBluetooth behavior, signing, hosted runner availability,
or end-to-end writes/notifications against real devices. No Apple build, signing,
installation, or hardware test was performed for this export.

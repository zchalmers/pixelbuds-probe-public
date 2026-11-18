# Publication preparation report

## Scope and history

This is a local review candidate, not an approved public release. The export has
fresh history with one initial commit and no remote. The original GitHub
repository remains private. No publication, remote configuration, installation,
notification delivery, signing, or live device control was performed.

## Changes

- `App/BridgeStore.swift`: replaced the personal bridge address with loopback and
  removed the embedded default bridge credential. The default token is empty.
  Settings persistence, runtime token handling, and `X-Bridge-Token` request
  authentication remain unchanged.
- `App/LogRelay.swift`: removed the private destination and machine-specific
  description. The existing plain-text POST mechanism now requires an explicit
  `logRelayURL` UserDefaults value with an HTTP(S) URL. Missing or invalid
  configuration skips the request without an error or crash. Conditional
  FoundationNetworking import permits local Linux validation.
- `App/Probe.swift`: retained log export, with a disabled status when no relay is
  configured. All Bluetooth controls, log buffering, and delegate behavior remain.
- `project.yml`: replaced the personal bundle namespace and signing team with a
  generic sample bundle ID and an empty team setting.
- `.github/workflows/release.yml`: retained archive/sign/package behavior, using
  configurable bundle ID, developer team, signing identity, and runner selection.
  The archive bundle ID and Info.plist assertion use the same configured value.
- `README.md`: preserved feature and setup information, replaced private settings,
  and documented architecture, code-specific decisions, bridge prerequisites,
  opt-in logging, credential storage limitations, signing setup, and validation
  limits.

## Removed files

- `.devin/blueprint.yaml`: machine-specific automation harness configuration, not
  application source or engineering documentation. Its now-empty directory was
  also removed.

No substantive Swift source, existing tests, source assets, build specification,
or release workflow was removed. There were no compiled applications, signing
profiles, private keys, recordings, or personal datasets in the source snapshot.
No license or new dependency, test file, or CI workflow was added.

## Verification performed

- Read all source files and audited the complete UTF-8 tree, including workflow,
  fixtures, project configuration, and documentation. No binary files were present.
- Exact-value checks for the original embedded bridge credential and signing
  identifiers passed. Private network, host, filesystem, contact, device identifier,
  and credential-category inspection found no remaining private values in the
  candidate tree, including this report.
- Source snapshot content hashes were unchanged after preparation.
- Source had 19 files and 2,124 lines. All 11 Swift files were retained, with
  1,708 source Swift lines and 1,720 candidate Swift lines. The only deletion is
  the harness file listed above. The additional report and expanded README
  account for the documentation growth.
- `swiftc -parse App/*.swift` passed with Swift 6.4.1 on Linux. Parsing is syntax
  validation, not Apple-framework type checking.
- `python3 Tests/run_bridge_contract.py` passed. It compiled and ran the actual
  Foundation bridge client/models against a loopback fixture server.
- `swiftc -swift-version 5 -typecheck App/LogRelay.swift` passed on Linux.
- A temporary, untracked validation harness executed the actual relay implementation.
  Unconfigured and invalid configuration checks passed. An explicitly configured
  loopback receiver received exactly one plain-text POST and returned HTTP 204.
  No new test file was added to the repository.
- YAML and Info.plist parsing passed. Workflow shell blocks passed `bash -n`.
  Static checks confirmed coherent sample/configurable bundle IDs.

## Judgment calls

- Kept protocol UUIDs and synthetic fixture addresses because they are technical
  constants and generic test data, not personal device identifiers.
- Kept UserDefaults credential handling, HTTP bridge support, and transport
  permissions to avoid changing authentication or device behavior during scrubbing.
- Retained the relay helper even though the current UI has no export button.
  Configuration is explicit and there is no default external request.
- Retained the existing release workflow rather than adding CI. Signing requires
  the next user's own matching certificate, profile, team, and bundle ID.

## Residual risks and review gates

- No Apple SDK build, simulator run, hosted workflow execution, signing, or hardware
  test was performed. SwiftUI/CoreBluetooth behavior and release packaging still
  require a Mac and appropriate hardware. Runner fallback does not guarantee the
  required Xcode version or SDK is installed.
- The Linux Bluetooth bridge and pbpctrl are external and not included. Fixture
  checks cover representative contracts, not a complete deployed bridge.
- The bridge token is stored in UserDefaults, not Keychain. HTTP transport may
  expose tokens and device data outside a trusted network. The existing transport
  policy is retained and documented, not hardened in this scrub.
- Future runtime logs can include nearby device identifiers and raw payloads.
  Review them before invoking optional export. The relay has no built-in
  authentication and must target a receiver controlled by its user.
- An existing installation may retain its previous UserDefaults configuration.
  Scrubbing source defaults does not erase configuration already on a device.
- Pattern and exact-value review reduce privacy exposure but cannot prove that
  every possible sensitive value was detected. Owner review is still required.

# Feature regression baseline

Run `bash Scripts/test-feature-baseline.sh` before shipping. It runs the full
domain, application, infrastructure, and app-layer suite, existing strict
coverage gates, the 500-sample two-process simulation, and the acceptance-probe
tests. It also builds optimized frameworks with `ENABLE_TESTABILITY=NO` and runs
`Scripts/test-release-transfer.sh`. That probe verifies which binaries were loaded
and exercises delayed ACKs, task/transfer cancellation, disconnect, reset, and a
mixed file batch through the real coordinators, sources, stores, and QoS scheduler.
The release script runs it against the actual archive before notarization.

The app-layer target compiles the app's real view models without the app
entry point; tests use isolated preferences, trust, and clipboard adapters.
It does not launch another UniSpace or touch the user's general pasteboard.

Keep code tests and installed-app acceptance results separate. A healthy socket,
simulated injector, or enabled toggle cannot establish live feature correctness.
An unrun or incomplete check is `NOT_TESTED` or `INCONCLUSIVE`, never `PASS`.
An observed failure remains `FAIL` even when other evidence is missing.

## Feature coverage and live acceptance

| Feature | Automated baseline | Required live evidence |
| --- | --- | --- |
| Pairing, trust, workspace updates | DomainModelsTests, ApplicationTests, WorkspaceReplicaMergerTests, InfrastructureTests | Pair disposable workspace; reconnect trusted device; reject untrusted device |
| Controller selection and presence | CoordinatorStateCoverageTests, ConnectionPolicyTests, ContinuityDestinationResolverTests | Correct controller on both hosts; offline peer does not become active |
| Cursor handoff and sustained control | ControlResilienceTests, InputPipelineTests, TwoProcessSimulationTests | Physical taimb2 mouse; actual UniSpace handoff, receiver OS motion, progress ACKs, anchored controller cursor |
| Keyboard, held modifiers, buttons, drag, scroll | ApplicationTests, InputPipelineTests, SimulatedE2ETests | Type disposable text; drag and scroll; release held inputs after disconnect/emergency stop |
| Clipboard text and URLs | ClipboardProtocolTests, ClipboardApplicationTests, ClipboardInfrastructureTests | Unique text and URL in both directions; exact representations and UniSpace origin on receiver |
| Clipboard lifecycle | ClipboardFeatureBaselineTests | Copy after peer/workspace update, key rotation, reconnect, sharing off/on |
| Explicit file transfer | FileTransferCoordinatorTests, FileTransferInfrastructureTests, FileTransferPortableInteropTests, ReleaseTransferProbe | Empty, Unicode-name, and binary batch through app; receiver lengths and SHA-256 match |
| Finder file continuity | FinderFileContinuityCoordinatorTests, FinderFileContinuityTests | Receiver-local file URLs with UniSpace origin; paste in Finder; no echo or text-path fallback |
| Interrupted file transfer | FileTransferCoordinatorTests, TransferQoSInfrastructureTests, PersistentFileSourceProviderTests | Interrupt during larger transfer; resume/retry; exact final bytes; cancellation reaches terminal state |
| Control while copying/transferring | TransferQoSInfrastructureTests, TwoProcessSimulationTests | Keep real mouse session active while clipboard and bulk transfer run; same control acceptance thresholds |
| Seamless window catalog/presentation | SeamlessWindowTests, SeamlessWindowConnectionTests | Catalog refresh/closure does not end desktop control; move/pull/return a disposable window |
| Settings and navigation | UniSpaceUITests, FileTransferUITests (`Scripts/test.sh --full`) | Installed app reflects state and errors; no false connected/completed indicators |
| Sleep/wake and peer restart | ConnectionRecoveryPolicyTests, ControlResilienceTests | Resume and reconnect on both installed hosts; no stuck keys or lost continuity route |
| Macifier interoperability | Macifier portable recovery and input suites | Native Windows host acceptance; cross-build alone does not pass this row |

## Repeatable installed-app checks

Both apps must be running, paired, and configured for the intended route. Pass
the expected build explicitly; the probes reject a different build or multiple
installed-app processes. They never toggle macOS settings or claim physical
latency from heartbeat RTT.

Clipboard probe (temporarily uses both clipboards; avoid copying during the run):

```sh
python3 Scripts/verify-live-continuity.py clipboard \
  --peer fox@foxs-macbook-pro.tailda4c05.ts.net --expected-build 45
```

The probe tests text and URL delivery in both directions. Original clipboard
representations remain in private local snapshots on their own host and are
restored only if the clipboard still contains this run's disposable marker.
Restoration adds origin markers to prevent broadcasting private original data.
Newer user clipboard contents are preserved. Successful restoration removes the
snapshots; a failed restoration reports the private snapshot path for recovery.
Only generated test markers, booleans, file hashes, and app identity enter reports.
The probe refuses to overwrite an existing multi-item clipboard: a short-lived
helper cannot reliably restore that selection after exiting. Preserve such a
selection manually before running a clipboard-mutating probe.

Automated Finder file-copy continuity uses fresh fixtures and preserves both
clipboards with the same rules:

```sh
python3 Scripts/verify-live-continuity.py finder-files \
  --peer fox@foxs-macbook-pro.tailda4c05.ts.net --expected-build 45 --timeout 30
```

The native helper writes real file URLs to the sender pasteboard, exercising the
installed app's file polling and transfer path. It verifies receiver-local bytes,
hashes, and Finder publication and checks that both app PIDs remained stable.
It keeps the pasteboard writer alive until verification and restoration finish,
and requires all three source files to be readable before testing delivery.
Filename comparison uses Unicode NFC equivalence (macOS supplies decomposed
names); file count, byte count, contents, case, and accents remain strict.
This covers Finder copy continuity; use the manual steps below to verify the
explicit **Send Files** interface separately.

Prepare fresh empty, Unicode-name, and 2 MiB binary fixtures:

```sh
python3 Scripts/verify-live-continuity.py prepare-files \
  --output .build/feature-baseline/files-run1
```

Use UniSpace **Send Files** to send all three generated files as one batch.
After completion, before copying anything else on Fox:

```sh
python3 Scripts/verify-live-continuity.py verify-files \
  --peer fox@foxs-macbook-pro.tailda4c05.ts.net --expected-build 45 \
  --manifest .build/feature-baseline/files-run1/manifest.json
```

This reads the receiver pasteboard and receiver files. SSH copies only the probe
executable, never file payloads. Missing files, partial files, wrong hashes,
unexpected batches, non-receiver-local paths, or absent UniSpace origin fail.
Repeat in the reverse direction from Fox for bidirectional acceptance. Preserve
the original clipboard separately when doing the manual file test.

For actual mouse verification, follow [live-control-verification.md](live-control-verification.md).
Start the armed recorder before the physical handoff. Run it again while sending
a large file and copying disposable text to cover cross-feature interference.

Every live invocation writes `report.json` under its printed/output directory.
Exit status is nonzero for both failure and inconclusive results. Run directories
must be new to prevent stale evidence from passing. Live probes are opt-in and
are not run by CI against developers' desktops.

## Recorded baseline — 2026-10-01, build 43

| Check | Result | Evidence |
| --- | --- | --- |
| Clipboard text, taimb2 → Fox and Fox → taimb2 | FAIL | Fresh source values verified; absent receiver values/origin after 12 seconds |
| Clipboard URL, both directions | FAIL | Same failure, including URL representation |
| Explicit 11,008-byte text file, taimb2 → Fox | PASS | UI completed; receiver SHA-256 `5ae6ef95e3c3b52bef1a8a163392749072232e23824884c87f2769dbfb994929` |
| Explicit 2,097,152-byte binary, taimb2 → Fox | PASS | Receiver SHA-256 `7cc0bd838fa07cf5919ea4b66a882b21acb1fb5e0bde981355da95b360ec4448`; published receiver-local Finder URL with UniSpace origin |
| Sustained physical cursor control | INCONCLUSIVE | Both build-43 apps observed, but no new UniSpace handoff during armed recording |
| Empty/Unicode/multi-file batch, reverse files, interruption, native Windows, physical keyboard/drag/scroll, seamless presentation, sleep/wake | NOT_TESTED | Require fresh live acceptance; existing unit/simulation results do not fill these rows |

The clipboard regression test fails before the route-restoration fix for peer
updates and actual workspace-key changes. The view model retained the displayed
peer while coordinator restart cleared the route; it must reapply that route even
when the UI selection does not change. Unchanged context must not restart the
transport; sharing disabled must never dial; leaving a workspace clears the route.
Passing these tests does not change the recorded build-43 live failures.

## Build 44 follow-up

Build 44 was signed, notarized, installed on both Macs, and verified by matching
the main executable and all three framework hashes. The same live clipboard
probe passed all four directions/representations, with restoration on both hosts.

The mixed-file batch exposed a second regression: taimb2's UniSpace aborted
while waiting for a receiver acknowledgement. The symbolicated crash points to
`FileTransferSendScheduler.waitForCredit` in `QoSFileTransferTransport.swift`,
inside nested cancellation-handler/checked-continuation closures. The runtime
reported an incorrect actor executor assumption.

Debug tests and even Release XCTest with testability enabled passed. A standalone
probe loading the exact archived frameworks reproduced the abort only when it
used the real `FileTransferCoordinator` path with delayed acknowledgements.
The scheduler now registers an `AsyncStream` wake-up signal synchronously on its
actor and consumes it asynchronously, preserving cancellation without a nested
actor-capturing continuation callback. Wake-up also rechecks transfer cancellation
and peer disconnect before permitting entry completion. The production-framework
probe is a required release gate; build 44's mixed-file live result remains FAIL.

## Build 45 acceptance — 2026-10-01

Installed `/Applications/UniSpace.app` version 1.2.0, build 45, from commit
`0ca8731` on taimb2 and Fox. Both passed signature verification, stapler validation,
and Gatekeeper with `source=Notarized Developer ID`; main/framework SHA-256 hashes
match on both hosts. App notarization: `093caab3-5134-42d7-b409-a126270a0e7c`.
DMG notarization: `7f731ace-9f5b-4a17-a6e3-b502073b81d1`. Both were Accepted.

| Check | Result |
| --- | --- |
| Clean unit/app-layer suite | 291 passed, 0 failed, 1 intentional signed-native-input skip |
| Existing coverage gates and 500-sample two-process simulation | PASS; thresholds unchanged |
| Optimized production-framework probe and exact archived-framework probe | PASS; delayed ACK, task/transfer cancellation, disconnect, reset, mixed batch |
| Live text and URL clipboard delivery, both directions | PASS, all four cases; both clipboards restored |
| Live file-copy continuity, taimb2 → Fox | PASS; all three source files confirmed and all receiver bytes/hashes matched; all three receiver-local Finder URLs published |
| App process stability during successful live probes | PASS; taimb2 PID 32802 and Fox PID 51612 unchanged |
| New explicit Send Files UI check, reverse-direction files, interruption under physical control, physical keyboard/drag/scroll, native Windows | NOT_TESTED on build 45 |
| Physical cursor stability | Still unverified; previous armed recording captured no UniSpace handoff |

Successful evidence: `.build/feature-baseline/build45-clipboard/report.json` and
`.build/feature-baseline/build45-finder-final/report.json`. The live file receipt
is transfer `EC05F035-8047-4BF8-A4DC-683D6B451056`: 0-byte empty file, 29-byte Unicode
text file, and 2,097,152-byte binary. Earlier prototype file-probe runs lacked a
complete validated source clipboard and are not evidence of a product failure;
their original reports are retained. The final probe verifies source setup,
keeps the writer alive, and handles canonical Unicode filenames explicitly.

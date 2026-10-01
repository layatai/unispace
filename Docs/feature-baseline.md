# Feature regression baseline

Run `bash Scripts/test-feature-baseline.sh` before shipping. It runs the full
domain, application, infrastructure, and app-layer suite, existing strict
coverage gates, the 500-sample two-process simulation, and the acceptance-probe
tests. The app-layer target compiles the app's real view models without the app
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
| Explicit file transfer | FileTransferCoordinatorTests, FileTransferInfrastructureTests, FileTransferPortableInteropTests | Empty, Unicode-name, and binary batch through app; receiver lengths and SHA-256 match |
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
  --peer fox@foxs-macbook-pro.tailda4c05.ts.net --expected-build 43
```

The probe tests text and URL delivery in both directions. Original clipboard
representations remain in private local snapshots on their own host and are
restored only if the clipboard still contains this run's disposable marker.
Restoration adds origin markers to prevent broadcasting private original data.
Newer user clipboard contents are preserved. Successful restoration removes the
snapshots; a failed restoration reports the private snapshot path for recovery.
Only generated test markers, booleans, file hashes, and app identity enter reports.

Prepare fresh empty, Unicode-name, and 2 MiB binary fixtures:

```sh
python3 Scripts/verify-live-continuity.py prepare-files \
  --output .build/feature-baseline/files-run1
```

Use UniSpace **Send Files** to send all three generated files as one batch.
After completion, before copying anything else on Fox:

```sh
python3 Scripts/verify-live-continuity.py verify-files \
  --peer fox@foxs-macbook-pro.tailda4c05.ts.net --expected-build 43 \
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

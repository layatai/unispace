# Live desktop-control acceptance

A successful build, notarization, heartbeat, or local simulation does not establish
that a physical mouse reliably controls another Mac. Use the installed controller
and receiver, paired application logs, and passive OS cursor observation.

## Reproduced live failure (build 42)

On 2026-10-01, both Macs logged active desktop sessions ending immediately after
`Seamless window ended: connection closed`. Controller examples occurred at
10:53:41, 10:53:56, 10:54:03, and 10:55:02 UTC. Heartbeats and input progress were
still arriving. The receiver independently showed the same interruption.

The 15-second background window-catalog refresh closes a catalog-only connection.
`returnHome()` schedules capture cleanup, making `isPresenting` temporarily true
while the presentation lease is idle. `SeamlessWindowViewModel` interpreted that
busy transition as a new presentation and called `stopControlling()`.

Build 43 keeps capture cleanup busy for operation gating but exposes a separate
`requiresExclusiveInput` signal based only on an actual presentation phase. The
view model uses that signal to release desktop control. Automatic presentation
stops now have explicit diagnostic reasons instead of the generic `manual stop`.
A real two-endpoint catalog regression test failed with three false exclusivity
notifications before this correction and passes afterward.

## Repeatable live check

Keep diagnostics enabled in UniSpace on both Macs. Use the actual installed app
at `/Applications/UniSpace.app` and confirm the same intended build on both.

```sh
python3 Tools/LiveControlObserver/test_verifier.py
python3 Scripts/verify-live-control.py \
  --peer user@receiver-host \
  --expected-build 43 \
  --duration 90 \
  --output .build/live-verification/build43
```

The verifier compiles a passive cursor observer and copies it to the receiving
Mac's `.unispace-live-verification/build` directory. It never posts, warps, clicks,
or types an event. It reads the app's sandboxed diagnostic log and samples the
actual OS cursor position on both hosts at approximately 50 Hz. Host identity,
installed build, running PID, and logging status are recorded before the test.

Wait for both `READY` messages. Move the physical controller mouse across the
configured edge, then make small continuous movements within the receiver display
for about one minute. Avoid buttons, typing, and display edges during this baseline.
Afterward, return normally across the configured edge. Background window-catalog
refresh must remain enabled so the original failure path is exercised.

The automated stability gate requires:

- The intended app build running and diagnostic logging enabled on both hosts.
- At least 45 seconds of uninterrupted control of the nominated receiver.
- At least 100 real receiver cursor-position changes during that session.
- At least 100 application input-progress acknowledgments.
- At least two catalog connection closures during active control.
- No unexpected desktop-session stop and heartbeat RTT p95 at most 250 ms.

The report separates `PASS`, `FAIL`, and `INCONCLUSIVE`. Idle runs, heartbeats alone,
stationary receiver cursors, wrong builds, and an unexercised catalog path cannot
produce a passing stability result. Raw events, stderr, interim progress, and the
final report are kept under the chosen output directory.

## Evidence limits and further cases

Heartbeat RTT is not cursor latency. OS cursor observation establishes actual
cursor state changes, but physical end-to-end latency needs correlated capture
and receiver-observation timing or high-speed video. Do not subtract independent
host monotonic clocks. Record the user's smoothness/stall assessment alongside the
stability report; a passing stability gate does not override a report of lag.

After the baseline passes, test idle/resume, normal boundary return, drag and
button ordering, and bounded interruption recovery separately. Keep test input
inside a disposable target window for any button or keyboard tests. Record expected
interruptions explicitly so they cannot hide an unintended disconnect.

The live logs are at:

`~/Library/Containers/com.layatai.unispace/Data/Library/Application Support/UniSpace/Logs/diagnostics.log`

The non-container Application Support directory is not the installed sandboxed
app's log location.

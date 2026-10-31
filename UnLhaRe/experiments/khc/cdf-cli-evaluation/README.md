# CDF chooser CLI evaluation harness

This is development-only work under the preregistration in
`../cdf-chooser-evaluation-20261027.md`. It does not establish general
performance or superiority. `evaluation.py` contains the fixed Canterbury11
manifest and binary identities, exact CLI arguments, two correctness roundtrips,
one warmup per binary, ten AB/BA pairs, byte-level comparisons, and the original
decision thresholds. Measured records retain bounded stdout/stderr, raw closure
and host observation data via the injected adapter.

`execute_trial` and `evaluate_injected` describe the adapter interface and allow
pure tests; their adapter callbacks are **not independently authenticated**.
`assess` checks the supplied record structure and thresholds; it does not prove
the records came from actual processes. The public `run_native` entry always
raises `IntegrationUnavailable`. No direct CLI subprocess, remote registration,
or OS cleanup occurs through this package.

`process_adapter.py` now provides a Darwin wait4 helper primitive, bounded
separate stdout/stderr wire encoding, and `FrozenBackendBridge` for the existing
finite supervisor and continuous observer APIs. It validates the raw group
closure and each observer-covered event, then requires the completed observer
report to cover all 48 children before scoring. The helper is not exposed as a
native entry point and `create_native_adapter` always refuses. A caller-supplied
helper identity callback is not an authorization or a verified helper executable.
The existing 64-capture/42-event reference contract is not the 48-event contract
for this campaign. A reviewed capture count, overall deadline and storage budget
are still needed. The helper's wait4 result alone does not prove process-group
closure; the actual outer supervisor must retain its own raw evidence.

`observer_protocol.py` supplies a **proposed, not yet approved or wired**
48-event contract using the frozen observer: 240 captures at 1.25-second
cadence, an observer start within 8 seconds of native start, completion by
317 seconds, group closure by 330 seconds, native finalization by 350 seconds,
and the existing Windows 360-second envelope. The final capture is scheduled
at 298.75 seconds after observer start. It preserves the existing CPU, AC,
thermal, sample-timing and RSS eligibility limits. Children that do not fit
the short window are invalid; their per-child maximums do not extend the window.
The proposed observer capture stream, final report and event bindings have a
1 MiB/one-entry cap each, in addition to the campaign's other storage charges.
The completed-observer wait uses chunks no longer than ten seconds and retains
the absolute monotonic deadline at native start plus 317 seconds; observer
start is checked against the same native start. On expiry or finalization
failure, the bridge requests lifecycle abort with the native-start-plus-330
seconds closure deadline and records an unconfirmed or late abort as unknown.
The native lifecycle must supply an authenticated start value, independently
bounded abort and evidence verification; those capabilities are not yet wired,
so the bridge must not be enabled for a real run. These source-level bounds and
the observer's overhead still require review and native measurement.
Before each child, the bridge requires an authenticated native monotonic start,
limits the outer supervisor timeout to the remaining observer window after
reserving 13 seconds for group closure, 4 seconds for event coverage and one
second for pre-spawn admission, and checks that budget again at `popen`. The
helper's preregistered 60/20-second limits remain upper bounds. The clock
authentication and abort callbacks are not yet implemented by a real lifecycle;
blocking OS calls can also overrun a software deadline. The bridge therefore
remains unavailable for native process entry.

`validate_complete_evidence` recomputes observer eligibility and checks all
48 fixed commands against frozen FS closure records. Its expected process IDs,
event bindings and timing inputs are supplied by the caller; the result does
not independently authenticate live process identity, the Windows Job or
storage lifecycle. A registered runtime must bind those values before using
the result. `create_native_observer` remains unavailable.

`wait4_helper.py --verify-request-base64` validates a fixed, canonical helper
request. `FixedHelperCommand` binds a bridge invocation to one of the two
preflight, two warmup and twenty preregistered trials, its exact binary/argv,
cwd and timeout, plus fixed helper/driver/adapter hashes. `--run-request-base64`
currently refuses: a Mac process cannot authenticate the Windows private
registration or prove the pending-run gate merely from an argv or parent PID.
It must not be enabled until a reviewed lifecycle capability and authenticated
helper delivery are provided. The helper wire test starts a local Python
verifier process only; it is not a Darwin wait4 or candidate execution test.

Before any real invocation, a separate reviewed integration must bind all of:

- The existing registered storage lifecycle, unresolved-run guard and shared
  Cargo lease; all existing targets and outstanding reservations must be charged.
- Immutable independent chooser-boundary witness, source/build proof, and real
  malformed/legacy/overwrite/memory safety evidence. A truthy test fixture or
  callback alone is not such proof.
- A finite process-group supervisor that validates raw closure, enforces the
  60-second encode and 20-second decode limits, captures bounded output, and
  preserves failure artifacts without retry. An independently verified
  continuous CPU/thermal/AC observer and native wait4 RSS measurement must be
  bound to every child, not inferred from reported booleans.
- A reviewed fixed total campaign deadline, per-run output/entry reservation,
  journal accounting, and a bounded preflight/finalization reserve. The prior
  reference's 160 MiB/512 entries are context, not an approved budget for this
  campaign. The fixed parent deadline must accommodate two correctness pairs,
  two warmups and twenty measured executions or fail before starting.
- Preserve unexpected exceptions and complete group termination, durable
  failure recording, and post-fsync deadline handling in that integration;
  the injected driver does not implement these process lifecycle guarantees.
- Parent-chain nofollow/ownership enforcement and CreateNew/no-replace output
  creation, plus a real observer/supervisor end-to-end and source identity
  validation. The proposed RUN path in source is not a registration or a grant
  to create it.

Use `py -3 -B test_evaluation.py` on Windows for the pure tests. These tests use
the locally retained Canterbury manifest; they do not launch either CLI.

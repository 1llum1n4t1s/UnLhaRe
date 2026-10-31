# Single-pass hybrid follow-up — 2026-09-29

This follows the size-only splice screen in [HYBRID_SPLICE_SCREEN_20260928.md](HYBRID_SPLICE_SCREEN_20260928.md). The trace splice remains an offline size oracle; a separate parser was added to test actual state-sharing execution.

- Input: `build/khc-current-source-native-solid-20260923-group/all.group`, 2,811,006 bytes, SHA-256 `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76`.
- Reproduction from `UnLhaRe/`: run `cargo +1.98.1 build --locked --offline --release --example khc_lab`, then `build/cargo/release/examples/khc_lab.exe --beam-model blended --beam-width 2 --beam-block 8192 --beam-matches bt5 --dictionary-mib 64 --entropy-backend range hybrid-splice-screen build/khc-current-source-native-solid-20260923-group/all.group`.
- Settings: Range, Blended Beam width 2, block 8192, BT5, 64 MiB dictionary. The fixed 7-Zip size gate is 483,599 bytes.
- Baseline Beam: 483,130 bytes.
- Exact trace oracle: six selected intervals combine to 483,574 bytes (+444 bytes vs Beam; 25 bytes under the 7-Zip size gate). It requires both complete parser traces, so it has no valid speed claim.
- The actual single-pass parser shares the Range model and Rep history and catches the BT matcher up over skipped regions. All 64 subsets of six oracle-selected intervals were encoded and decoded. Four nonempty combinations met the 483,599-byte size gate.
- All four size-passing schedules received nine paired Release measurements. Candidate order rotated between rounds and Beam/hybrid order alternated; frame assembly is timed, while decoding and the full-trace/64-mask selection work are excluded.

| Mask | Selected ranges | Frame bytes | Beam median (ms) | Hybrid median (ms) | Hybrid slower (ms) | Beam/hybrid |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 16 | `ptt5` partition 0 | 483,178 | 892.865 | 900.059 | 7.194 | 0.9920× |
| 32 | `ptt5` partition 15 | 483,168 | 907.184 | 937.437 | 30.253 | 0.9677× |
| 40 | `kennedy.xls` partition 10 + `ptt5` partition 15 | 483,568 | 899.806 | 927.341 | 27.536 | 0.9703× |
| 48 | `ptt5` partitions 0 and 15 | 483,144 | 902.683 | 922.221 | 19.538 | 0.9788× |

- None of the size-passing schedules beat the Beam control on median encode time. Mask 48 remains the smallest frame (+14 bytes vs Beam; 455 under the size gate); mask 16 was the fastest hybrid, but was still 7.194 ms slower than its paired Beam median. This single-pass region-switching branch is therefore no-go for the joint size/speed objective.
- This screen did not rerun 7-Zip timing. The gate is the fixed 483,599-byte 7-Zip frame size; all comparisons here are paired against Beam from the same Release example. The regions are corpus-specific and were selected with full traces, so the screen is neither a production policy nor a held-out result.
- The first E2E run exposed a clipped length-1 Match incorrectly becoming a length-1 Rep and underflowing length coding. Classification and replay validation were corrected; the final 64-subset run completed with every round-trip verified.
- Disposition: all four size-passing schedules were already timed in this screen. No cheap single-pass decision rule or held-out validation was established; this branch remains no-go, and the earlier “time the other three subsets” placeholder is stale. Overall 7-Zip superiority remains unproven.

The exact all-subset and all-schedule output is in `build/khc-single-pass-hybrid-20260929/all-size-passing-timings.json` (SHA-256 `AF922DE8EAEC6A6FF36A273BAD09D7C7C0820BBC7C9F7150693A5CBCEF80C605`). It includes all 64 subset sizes, round-trip status, and the nine samples for every timed schedule.


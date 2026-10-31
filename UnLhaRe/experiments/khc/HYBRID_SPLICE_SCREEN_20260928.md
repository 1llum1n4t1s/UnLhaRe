# Exact method-2 hybrid splice screen — 2026-09-28

- Input: `build/khc-current-source-native-solid-20260923-group/all.group` (2,811,006 bytes; SHA-256 `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76`).
- Reproduction: build `khc_lab` in Release, then run the command recorded in `report.json`.
- Conditions: Range coder; Blended Beam width 2, block 8192, BT5; 64 MiB dictionary. The size gate is the fixed 7-Zip frame size of 483,599 bytes.
- The method-2 Beam baseline is 483,130 bytes. All 64 equally spaced intervals across `kennedy.xls`, `plrabn12.txt`, `lcet10.txt`, and `ptt5` were spliced individually, fully re-encoded, and decoded successfully.
- Exact greedy combination: 6 intervals covering 321,588 bytes (11.44%) produced 483,574 bytes: 25 bytes smaller than the 7-Zip size gate, and 444 bytes larger than Beam.
- Replacing all target-file ranges with lazy-LZ tokens produced 525,135 bytes; full lazy-LZ was 531,353 bytes.
- No speed claim: `speed.measured=false`. Both full parsers were run to collect tokens, so this experiment does not show an encode-time win and should not be integrated as a production heuristic.
- Correctness fix made during this screen: a clipped one-byte normal match was previously classified as a length-1 Rep, underflowing the Rep-length encoder. It is now converted to ShortRep only when it uses Rep0, otherwise to a literal; replay validates minimum Rep/Match lengths before encoding.
- Follow-up: a shared-state single-pass hybrid was prototyped, then all 64 subsets of six oracle-selected intervals were round-trip checked. See [HYBRID_SINGLE_PASS_20260929.md](HYBRID_SINGLE_PASS_20260929.md); no size-and-speed joint win has been established.

Full machine-readable output is preserved in `report.json`.


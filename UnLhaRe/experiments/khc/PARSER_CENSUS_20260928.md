# KHC parser census — 2026-09-28

## Purpose and method

This is the first measurement for Grok's proposal to use a fast provisional parse and run Beam only where its token decisions disagree. `khc_lab parser-census` captures decisions from the actual Standard, lazy LZ, and current BT5 Beam encoders. It compares, at every input byte, the exact containing-token signature `(start, length, kind, resolved distance, Rep index)`.

The screen verifies each ordinary frame by decoding it, verifies that captured tokens cover the input contiguously and reproduce every copy span, and verifies that each trace encoder emits the same payload as its ordinary encoder. It caps each trace at 4,194,304 tokens (64 MiB with the current `SelectedToken` layout).

This is a parser-decision census, **not** a hybrid implementation, repair-opportunity estimate, or encode-time benchmark. Signature disagreement can overcount useful repair regions. The trace capture reserves against `Options.memory_budget`, including already-retained prior parser traces; for the solid-group run the three vectors retained 25,165,824 bytes of capacity. The 40% / 80% thresholds from Grok are therefore left unapplied as calibrated rules; raw rates are reported so the proposal can be challenged with evidence.

## Canterbury solid-group result

Input: `build/khc-current-source-native-solid-20260923-group/all.group` (2,811,006 bytes), with dictionary 64 MiB and current Beam settings Range / Blended / W2 / BT5 / B8192.

| Parser | Ordinary frame bytes | Tokens | Copy bytes | Trace equals ordinary payload | Round-trip |
| --- | ---: | ---: | ---: | --- | --- |
| Standard | 579,558 | 369,575 | 2,712,645 (96.50%) | yes | yes |
| Lazy LZ | 531,353 | 437,622 | 2,603,573 (92.62%) | yes | yes |
| Beam | 483,130 | 436,763 | 2,693,633 (95.82%) | yes | yes |

| Exact signature comparison | Agreeing input bytes | Agreement |
| --- | ---: | ---: |
| Standard vs lazy LZ | 807,026 | 28.71% |
| Standard vs Beam | 253,957 | 9.03% |
| Lazy LZ vs Beam | 430,689 | 15.32% |
| All three agree | 181,476 | 6.46% |
| At least one parser disagrees | 2,629,530 | 93.54% |

## Per-file Canterbury result

The 11 manifest-listed development files were measured independently from `build/khc-corpus/canterbury-development/`. Rates below are input-byte weighted within each file and use the same exact token signature.

| File | Input bytes | Any-parser disagreement | Lazy LZ / Beam agreement |
| --- | ---: | ---: | ---: |
| alice29.txt | 152,089 | 81.22% | 32.12% |
| asyoulik.txt | 125,179 | 82.45% | 33.95% |
| cp.html | 24,603 | 66.24% | 55.22% |
| fields.c | 11,150 | 66.59% | 49.78% |
| grammar.lsp | 3,721 | 60.68% | 57.83% |
| kennedy.xls | 1,029,744 | 99.71% | 1.49% |
| lcet10.txt | 426,754 | 84.58% | 26.33% |
| plrabn12.txt | 481,861 | 89.11% | 24.93% |
| ptt5 | 513,216 | 95.50% | 20.10% |
| sum | 38,240 | 78.08% | 56.59% |
| xargs.1 | 4,227 | 53.66% | 66.12% |

Across the 2,810,784 source bytes, 2,591,961 positions had a disagreement (92.21%). `kennedy.xls` accounts for 1,026,724 of those positions (39.61%), not over 80%. So the proposed `>40%` rejection heuristic would reject this exact-signature version of the hybrid idea; the `kennedy.xls` concentration condition does not hold. This does not prove every possible hybrid is futile, but there is no measured basis here to implement one or claim a speedup.

## Follow-up scalar-DP gate

The current-source `profile` run on the same solid group reported `expand_nodes=545.14 ms` and `find_matches=343.99 ms`, so expansion is the larger measured phase. These are inclusive phase values (`rep_length` is nested inside expansion); they are not standalone component timings or an encode-vs-7-Zip comparison. The uninstrumented time in that one profile invocation was 948.06 ms.

The existing fixed-Rep-history scalar candidate was then screened through `group-bench` with all other Beam baseline options unchanged. It produced a 525,867-byte frame, round-tripped the full group, and its five encode wall samples were 793.30, 767.34, 736.67, 722.24, and 706.52 ms. The frame is 42,268 bytes above the saved 7-Zip gate (483,599) and 42,737 bytes above the current Beam frame (483,130), so it fails the required size gate; the unpaired timings do not establish a speedup. Do not reimplement or optimize this candidate from these data.

Reproduce with:

```powershell
build/cargo/x86_64-pc-windows-msvc/release/examples/khc_lab.exe profile build/khc-current-source-native-solid-20260923-group/all.group --dictionary-mib 64 --algorithm beam --beam-width 2 --beam-block 8192 --beam-model blended --beam-matches bt5
build/cargo/x86_64-pc-windows-msvc/release/examples/khc_lab.exe group-bench build/khc-current-source-native-solid-20260923-group/all.group --algorithm beam --beam-width 2 --beam-block 8192 --beam-model blended --beam-matches bt5 --dictionary-mib 64 --beam-fixed-rep-history
```

## Reproduction

From `UnLhaRe/`:

```powershell
cargo run --locked --release --target x86_64-pc-windows-msvc --example khc_lab -- parser-census build/khc-current-source-native-solid-20260923-group/all.group --dictionary-mib 64 --beam-width 2 --beam-block 8192 --beam-model blended --beam-matches bt5
```

For each manifest-listed file, run the same command with that file path in place of `all.group`. The full manifest is `experiments/khc/CORPUS_MANIFEST.json`.

The Silesia holdout was not measured. No 7-Zip run or encode-time measurement was made in this census, so the result must not be read as evidence about the 1.3x speed gate.

Formatting check and the release example build passed. The CLI end-to-end checks passed for the solid group and all 11 individual development inputs. Clippy with `-D warnings` still exits unsuccessfully on 23 diagnostics in the existing KHC experiment implementation (for example `hybrid.rs`, `rep_frontier_dp.rs`, and older sections of `lz.rs`); none of the diagnostics point to the new census functions. Those unrelated implementation warnings were not mass-edited as part of this experiment.

## Reproduction identities

SHA-256 values for the sources and primary input used by this run:

| File | SHA-256 |
| --- | --- |
| `experiments/khc/mod.rs` | `1F7726A456612E27E038215068BB8FC9B779A2F573F4421CF65C492BC467F5AD` |
| `experiments/khc/lz.rs` | `2F161B6701976E0E9B15E38A9ADCE37B24A45CC4AC4F3B33AC684309B90090C5` |
| `examples/khc_lab.rs` | `0FC7BC717E5267DDDBA942E9F714E35119B063ECDDED65A68F640D7B6972D9AB` |
| `build/cargo/x86_64-pc-windows-msvc/release/examples/khc_lab.exe` | `D431D9BA091B0017190F4D6D3665CF477E13074BF6DC3317A843FC2B8AE80CE1` |
| `build/khc-current-source-native-solid-20260923-group/all.group` | `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76` |
| `build/khc-corpus/canterbury-development/kennedy.xls` | `9AF47239CA29DFE20E633F80BBBB9A4CC9783D0803D7B2B5626F42E4C3790420` |

# Range正規化回数 — 2026-09-28

2 byteまとめ読みは実装していない。固定Canterbury groupの現行Rangeフレーム483,130 bytesで、1 bitの正規化が2 byteだったのは5,976,004 bit中420回（0.0070%）だけだった。事前関門は20%以上。0 byteは5,493,339、1 byteは482,245。通常復号とprofile復号の出力は一致し、ラウンドトリップも一致した。Silesiaは未使用。

この回数計測のあと、同じRelease実行ファイルで`compare-solid.ps1`を5反復した。符号器の出力は既知フレームSHA `CF4F107BE32E35B603FCA9CE05AC8A5C5C3F4211A4BC0B68236A383F8029447D`のままで、2 byteシフトは入っていない。したがってこの比較は新しいcodecの勝利ではなく、現行Rangeの再測定である。

| | 総バイト | 圧縮中央値 | 展開中央値 | 圧縮 sampled private / working set | 展開 sampled private / working set |
| --- | ---: | ---: | ---: | ---: | ---: |
| KHC Range | 483,130 | 1001.5268 ms | 56.0225 ms | 36,986,880 / 35,840,000 | 4,583,424 / 8,417,280 |
| 7-Zip 26.03 | 483,599 | 574.5624 ms | 47.3884 ms | 37,052,416 / 42,577,920 | 4,661,248 / 9,973,760 |

メモリはwarm-upを除く5標本の中央値で、1 ms前後のsampled値であり、同一hard capの証明ではない。圧縮は約1.74倍、展開は約1.18倍遅い。総合優位ではない。

再現:

```powershell
./build/cargo/x86_64-pc-windows-msvc/release/examples/khc_lab.exe renorm-census ./build/khc-current-source-native-solid-20260923-group/all.group --algorithm beam --beam-width 2 --beam-block 8192 --beam-model blended --beam-matches bt5 --dictionary-mib 64
./experiments/khc/compare-solid.ps1 -LabPath ./build/cargo/x86_64-pc-windows-msvc/release/examples/khc_lab.exe -SevenZipPath ./build/khc-baseline-20260918/x64/7za.exe -GroupPath ./build/khc-current-source-native-solid-20260923-group/all.group -WorkDirectory ./build/khc-renorm-gate-solid5-20260928 -BeamMatches bt5 -BeamWidth 2 -BeamBlock 8192 -BeamModel blended -EntropyBackend range -Repeats 5
```

実行ファイルSHA-256は `35F3D4D8A88FB33E0430726F1B46E5FD6B706F6CFF145D53CB2CEFA7A92AEEE0`。7-Zipは `EDBEE35370E14030E4C785CF88200F42DC651C1EB4217C1E3963C38A12F099B0`。

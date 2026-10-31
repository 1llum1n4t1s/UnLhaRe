# Forest直接parse：互換性・局所効果を確認して採用

2026-10-05 Windows x64。親所有のpaid_model.rs/packet.rs変更を製品経路へ統合。最終Forestのdense確保/zero初期化は維持し、284個の一時Dispatch確保・初期化と872448行/6979584 Bの再コピーを除去した。root単位1024行sliceで同じparserを使い、high履歴反転・depth/CDF/duplicate・model count/trailing検査を保持する。parse_rootの検証用Dispatchは用途が別であり残す。parse_dispatch_peakは直接parseの0になり、reader/最終Forest/既存stack boundは継続計上する。wire、識別子、公開API、依存、versionは不変。

## 旧新交互9測定＋warm1

固定7fixtureをpaid/low別に完了。合計588native calls、280自己往復、28相互復号、140同frame pair、差0、全pin前後一致。旧empty EXEは保持。時間はprocess起動＋binary I/O込み、純codec時間ではない。新しいrunnerの7-Zip用plan pinはこれら完了後に追加したため、報告中runner SHAは各測定時のhistorical版を指す。

| 入力 | paid圧縮 前→後 ms | paid展開 前→後 ms | low圧縮 前→後 ms | low展開 前→後 ms |
| --- | --- | --- | --- | --- |
| repeat4KiB | 105.422→75.464 | 84.961→63.403 | 93.939→75.421 | 81.038→63.360 |
| all256×8 | 104.607→75.071 | 96.071→64.791 | 94.113→89.152 | 93.660→63.722 |
| random64KiB | 293.273→278.425 | 72.298→72.522 | 254.718→237.863 | 71.458→73.207 |
| alice29 | 232.573→217.658 | 142.204→109.610 | 203.766→187.816 | 138.542→108.459 |
| kennedy | 640.209→605.868 | 302.953→284.967 | 591.722→557.481 | 291.732→282.025 |

paidのrepeat圧縮/展開、all256展開、alice展開は新maxが旧minを下回る。lowはalice展開のみこの条件を満たす。alice展開はpaid約22.9%/low約21.7%短縮を独立したmode別runで再現した。ただし同条件の別日反復や統計検定ではない。その他は範囲が重なり、中央値改善のみで普遍的速度優位を断定しない。empty/one/stored decodeは変更を通らず、時間変動を改善と称さない。全child64MiB WS/private内、短命private peakの観測限界はrunner通り。追加heapを減らした量からOS peakが必ず下がるとは言わない。

## E2E・静的検査

変更前と変更後同コマンドのrelease既存3 E2Eは成功。ただし最初の両runはUNLHARE_KHC_FIXED_INPUTなしであり、3固定block部分は未実行だった。これをresult.jsonのfalseから確認し、変更後は同変数へ既存all.groupを明示して追加再実行した。SHA256 18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76。9境界、3固定block156483/237176/119861 B、low、oversize拒否、30故障/30回復、最大split852rootで成功。追加成果物block-normal-10692、block-adverse-32076、model-boundary-24868を保持。最大split28.4605msは単発E2E時間で、旧新9測定値ではない。

clippy --locked --offline --release --target x86_64-pc-windows-msvc --example khc_direct_probe -- -D warnings成功。rustfmt --check成功、git diff --check成功（既存改行warningのみ）。全repo/container/非Windows nativeは今回再実行していない。新unit test・unsafeなし。read-only探索1回はPowerShell brace構文でhook拒否され、削除操作は含まれていなかった。正しいPowerShell構文のread-only確認に修正した。削除/Git書込み/外部公開なし。

## 再現証拠と容量

- 新probe87D22FCD6E500BCBB26371BC4B86C19208796C36D6D596F7E89D18CFEB9C115C、1013760 B。旧empty D32F332FBAB51D919B65F5D62588BA96CBC78BE891C5BEB6A5B7BAE7833CD79E。
- paid：build/khc-cpu-measurement-v2-20261005-direct-paid/report.json、25258 B、SHA256 6B304040BB3B5346CA54C41BE016193F00829BF2521DD913D457DCB3EA730EA7。
- low：build/khc-cpu-measurement-v2-20261005-direct-low/report.json、25246 B、SHA256 0F2C00E2A973D8ED4A1B16DC967AEAD3395B8D612446D1024610BE6A8D59FAC9。
- paid_model source B965512A4DAB0D920C9BEA14DA3FFD176CE289E4EB22BDC92DF93CAC3BF32072、packet source BA0BE650557F7F7224AA6632ECDD3BCB7023CF3DC4D69F0A293ADC33192EC618。詳細source/input/configはJSON pin。
- buildは既存Rust1.98.1 exact path、rustc現在SHA CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BCを確認。compiler hashはrunner JSON pinでないため、source lockと同等のbuild時証明とはしない。
- 共有Cargo測定6123283030 B、累積baseline5906793080 Bとの差216489950 B/256MiB、残51945506 B。既存target-dir共有。2report合計50504 B、raw/frame disk0。製品E2E成果物は既存dirに小JSONのみ追加。

opop6基本観点はplanの親担当で完了。Performance/Cleaner/Normalizer採用、Hardening/Tester検査・互換確認、Modernizer追加変更不要。Async寿命維持、Startup/Intel今回非該当。これは新圧縮原理ではなく同じ形式の実装改善である。GOALはactive、7-Zip完成ゲートは未達。次の全development対7-Zip実測はSEVEN_DIRECT_PLANの固定条件で実行し、以前の時間と混ぜない。

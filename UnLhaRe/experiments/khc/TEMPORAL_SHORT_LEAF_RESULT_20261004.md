# 短leaf＋実保存費DPの結果

固定14tileの情報費用screenは529063B。元paid-root532461Bより3398B改善したが、固定483599Bを45464B超過するためno-go。正当性・資源検証は成功、製品採用はしない。全GOALはactive・未達。保存費だけの小改修を続けず、global共有モデルの分布表現を根本的に小さくする候補を独立読み取り調査へ移した。

## 費用の内訳

| 項目 | short leaf | 元paid root |
| --- | ---: | ---: |
| token ceil | 502944B | 504317B |
| 保存header | 23040B | 25065B |
| side | 3079B | 3079B |
| 総費用screen | 529063B | 532461B |
| free Qtoken449308からのtoken増分 | 53636B | 55009B |

token1373B/header2025Bの両方が改善したが、14tileの剪定損失が大きい。新selected leavesはuniform11700/pure1226/raw4048。uniformには省略default root9263も含むため、全11700がwireへ保存されたとは扱わない。explicit roots2665。DP内部費用171884bits＋11928outer flags＝header有効183812bits、padding60bits、tile u32長56B。DP lossと完成packet解析lossはどちらも4023545.9993952513bits。

leafはuniform/pure/rawの厳密CDF一致を2bit tagで区別する。CDFの量子化とHist/record/historyは原実装を保持。root defaultのDP費用0とoracle wire3bitsを区別し、raw-bit目的費用を実packet有効bitsへ直接照合した。bytepaddingまでの最適性や旧selected CDF不変は主張しない。

## 実行と検証

Windows x64固定rustc1.98.1、opt3/thin LTO/CGU1/unwind/overflow checks/debug0。compile1/native1、両exit0/stderr空、runner diagnostic-passed。compile5095.6744ms/native全診断6491.2309ms。E2E・model学習・wire保存と照合を含む実験全体時間で、CLI圧縮速度ではない。

原有限E2Eの24拒否/65536・65537境界/Front3、既存packet正常4/3489792全CDF/root拒否3/packet拒否8/weighted拒否4を維持。新pure9（全CDF9216）、内部uniform1/raw3/default3/DP費用2境界/wire拒否4と理由・回復が成功。固定実入力read1/BWT1/walk1、14tile/3976models/11928roots、Fit→root全CDF12214272比較、連結rootbits直接比較、完成packetのnode/component/tile/whole loss/countを照合。全Metaと無料Q全統計も原reportへ直接一致。

親は新model全体、packet/probe差分、先行FAILURE censusとE2Eを読み取り確認。原Hist/quantize prefix、weighted ingest、Accumulator全文は直接一致。workerは許可変換の全文照合ledgerと非書込syntax後完全停止、親がhashを固定して実行した。親readonly verifierは77組/raw1、追加compile/native0で再現成功。基礎paid-rootの同一readonly75組も開始/終了成功。新ユニットテストなし。

## 資源・証拠

model capacity23742675B<24MiB、fixed phase44700009B<48MiB、BWT式141598926B<160MiB。OS peakWS55730176/private51867648B、160MiB以内。4usize追加×14=448Bをcapacity式に含む。Dense1/packet1/node scratch1、14件scalar summary、packetはRAMだけで解放。実frame0/trace0/forest0、速度/portable/holdout/API/4native/総合7-Zip超えは未達。

新出力はEXE358400B＋report166349B＝524749B、2filesのみ（8MiB予算内）。元report/source不変、Git/version/依存/製品/x86/外部/削除0。終了時空き約36.71GiB。共有driveの他作業による変動は本実験の消費へ加算しない。

report SHA256 4124800010B921906E48EA1E185AE94B9BEF1974F1EE9B0DD0840FECCC1453DE、EXE SHA256 28D026B1751CCF5A8AFBCE079EF6178839E1C8DEB6C846E77A288BEBAABF17DE、runner SHA256 C733E7AAC8E85BCC59532AC4EDA814A4B7490C6713E117939C27020AE0A87738。`temporal-short-leaf/verify-artifacts.ps1`を固定bundled pwshで実行すれば追加native/compileなしで検証できる。新folder名/PLANは開始時の計画識別20261004を維持、実行はUTC2026-10-04/JST2026-10-05。

全完成書庫483599B、全CLI encode574.5624ms/decode47.3884ms未満、同CPU/threads/RAM、quiet≤15%/warm1+9、独立holdout/API/Windows/macOS x64/ARM64の全固定条件を維持する。

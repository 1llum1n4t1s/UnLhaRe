# 正規化prior候補と小容量診断の結果

## 判定

P256固定強度のKHNPR001候補は不採用。fixed input全frame610222byte、旧direct575791byteより34431byte（約5.98%）大きく、483599byte gateを126623byte超過。サイズgate未達のため正式性能測定を行わない。7-Zip超えgoalは未達・active、固定条件や過去のterminal測定を変更・再試行しない。

## 実行検証

モデルの独立oracle検証はopt2/3×overflow yes/noの4条件で成功。13170475件の正規化scale比較と393216イベント、424319 prefix query、455422 selection queryを確認した。root45/local21 rescaleを含み、fingerprint63d2b815cfcd6e6eで一致。
model report SHA BD8090CE5C601F2BAC4C8E297E8C84FFD5D8FAE665B720ED1043580E676EFA2D。

full E2Eは7入力×4条件でencode/decode全byte一致、21 wire比較、独立forge255/256/257境界、23不正frame拒否と空frame成功、旧format拒否、no-clobber等に成功。52回のbyte比較で13651708byteを確認し、91件の所有一時物を削除。親がreport hash、24個のsource/compiler/input識別値、12個の保持生成物識別値を再照合し、削除記録を持つ全91件の不在を確認した。ledgerは比較記録52件と削除記録91件が混在するため、deleted/transient_pathを持つ要素だけを残存検査する。
full report SHA 942C0FBF794C5A9A80479AD815A61E79F3A67EAB435FB848D40EFD18F68F944B。
full frame SHA 881A9AFE44F50A9546625333F8C976ADFDEE2A8382F4D4168289B6F629AA6082。

## cold文脈の機構診断

実行前契約PRIOR_PRECISION_DIAGNOSTIC_CONTRACT_20261002.mdに従い、実際のold/new ContextModelをalphabet256/key2で使用。key0/token0を8192更新した後、rootおよびlocal全1536 countと全1024 intervalを独立配列・通常u128除算の期待値へ比較した。opt2/overflow yesの1条件のみ。拒否update後の状態維持とCLI引数拒否も成功。

| 状態/token0 | old frequency/total | P256 frequency/total |
| --- | --- | --- |
| cold/key1 | 8193/8448 | 249/512 |
| hot/key0 | 40961/41216 | 33017/33280 |

cold時の一様支持256は全total512の50%。学習済みglobal token0の約96.98%が、約48.63%まで薄まる機構を実状態で確認した。ただし全書庫の34431byte増をこの要因だけに帰属できない。新旧のprior強度も変わっており、全入力の寄与分離は未実行。

probe report SHA 8C3A0782986D581AE7BA253CF33D107AE2BD676389FF8F1EDF0475E0BEE7D2B9、11139byte。
probe EXE SHA 2382B01B33B3307129E5352509706F4B8BF29924F1F27A014E711CBBBE89033F、151040byte。
verifier SHA 76F6FD12D0AC8427F9F37F38C97B658F72A092476EB8A01E4A4C425769D3AF67。
9 source/compiler/runtime識別値とEXEを実行前後・親再照合、差異なし。

## 容量と次の段階

full保持13file1768622byte、model保持686314byte、今回probe保持2file162179byte。全て小さな専用出力先、Cargo/PDB/raw traceなし。probe8MiB/full64MiBの事前・事後予算内。guardはprocess書込みを強制制限するものではない。今回のprobeで不要な一時物は作らなかった。

cleanup-incremental.ps1の候補表示ではtarget_count0/target_bytes0であり、新たな削除は行っていない。これは専用Cargo増分キャッシュの確認であり、作業フォルダ全体に不要物がないという意味ではない。固定corpus、旧proof、source、候補EXE、製品生成物、共有キャッシュ、x86は保護する。

次は全global/local混合を高精度32768へ正規化し、一様支持を1%未満へ抑える仮説を先に契約化する。まだ実装・サイズ改善・速度改善の証拠ではない。正式encode/decode性能、holdout/カテゴリ、4native、実allocation失敗、製品/API統合は未検証。Git/version/公開は変更しない。


# CTS内部predict診断結果（2026-10-04）

数値不変の診断が成功。今回sampleしたgather/Kernel/sealの3区間和ではKernelがencode84.1566%、decode85.0391%。次の候補はsnapshot契約の縮小ではなくKernel内のHamilton選択を優先する。payload全体の割合や速度改善、7-Zip超えを示す結果ではない。

| 同じsample集合の集約時間 | encode | decode |
| --- | ---: | ---: |
| guard/gather | 0.7728 ms | 0.7267 ms |
| Kernel | 9.6940 ms | 9.8858 ms |
| snapshot構築/seal | 1.0522 ms | 1.0125 ms |
| CTS子から3区間を引いた残差 | 2.2286 ms | 2.1502 ms |
| enclosing CTS子 | 13.7476 ms | 13.7752 ms |

observeと認証fallback頻度は未測定。保存nsはchecked・transactional、実時計試行数はnullでrollback可能とはしない。追加clock・tuple返却・配置が短区間に影響し、sealの時間は純粋なmemcpy費用ではない。prefix1の2層はsample0で時間不明。外挿・overhead補正・前回との時間差による採用判断なし。

## 実装・検証

- 新rootは7file109946B。元depth CTS全sourceと追加predictの診断除去後body一致、model観測除去後一致、codecは凍結配線のallowlist一致。Snapshotの構造・derive・DerefMut、guardとcommit順は不変。
- 独立読み取りでrootモデルaliasとJSON/runner契約の不一致を実行前に発見・修正。worker編集停止・所有権返却後に親がJSON説明と非sample文書を修正、再事前チェックと独立readback後に実行。
- compile1回3709.2171ms、直接契約CLI1回166.5492ms、E2E profile CLI1回21853.9629ms、全exit0。compile warning stderr975B、CLI stderr0。
- counter正常9群/期待拒否23、実時計0、拒否前後全保存state保持。旧/新model tuple双方14/16/1。直接CTSは双方合計受理4/拒否6、別certified tokenのvisibleを現在予測へ修復した受理、stale・derived・未使用Kernel tail拒否を全Cts Eqで確認。
- baseline encode1→profile encode1→profile decode1、入力read1。frame全478750B×1、plain全2811006B×1、Proof全14 fields×2（CDF bits）、stats全22 fieldsの3組一致。最大frame2/957500B、終了frame0、diskへのinput/frame/plainコピーなし。
- 各方向3825340枝、14942sample。8層totals `[121,415562,13461,2296628,1,71469,7502,1020596]`、samples `[0,1623,53,8971,0,279,29,3987]`。全層の内外ns分解・未完了0確認。
- 実size_of: Node24B、Kernel1168B、RawSnapshot1488B、sealed Snapshot2976B、Cts80B、Stratum112B、State904B、Scope104B。型の保存量であり機械コピー量ではない。
- graph14、215 identitiesをbefore/after/live照合、親もEXE込み216件を終了後再照合、不一致0。所有EXE process0。
- baseline encode5871.0926ms、profile encode8091.2134ms、profile decode7749.5393ms。追加処理とコード配置の異なる診断値で正式速度比較には使わない。

## 保持証拠と容量

生成root `build/khc-quaternary-cts-inner-split-20261004/` は2file481180B（約470KiB）。8MiB予算内、空き約68.60GiB。削除なし。

- report.json: 79260B、SHA256 `59C4C8B73DF3275303D52629C3862CD1F83D260AF60EC9E4D8A024AA95571562`。
- inner-split-o2.exe: 401920B、SHA256 `38C44DDBD15DB3A07A9F8C40C7D10F1526DF4503367A933878A618A3C5DC4309`。
- 入口 `quaternary-cts-inner-split/verify.ps1`、既存output再実行は拒否。timeout/output overflow実fault注入は未検証。

固定総合goalは未達、正式速度・CPU・独立holdout・カテゴリ・製品APIは未検証。exp-zero/KT equalなど過去不採用を維持。次候補の根拠は `QUATERNARY_CTS_HAMILTON_INVESTIGATION_20261004.md` に保存した。

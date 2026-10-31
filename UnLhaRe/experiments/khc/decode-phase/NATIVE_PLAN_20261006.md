# 実全書庫の復号・再現測定計画

2026-10-06 JST。前ターンはGOAL状態質問への応答だけ（no progress）。現在active、元の総合優位・真正未見・研究・形式統合ゲートを変更しない。親が全編集・計測を所有する。今回の既知Canterbury11入力は未見ではない。

## 失敗を先に定義
- 古いEXE/異なる書庫/source/入力/reportで測る：固定SHAとread-shareロック、終了時全pin再確認。
- 他作業/CPU負荷/同時コンパイルの混入：関連process0を開始条件、各child前CPU<=15%、待機60秒、suite300秒。
- 作成や復元物を重複保持：既存current.khc/native-solid.7zのみ使用。CLI khc-testと7za tはいずれも全復号+CRCで出力ファイル0。extract/write速度とは区別。
- 起動/観測/PowerShell guardの費用をcodec性能と混同：OS process start/exit差とCPU、外側起動待機wallを別記録。Guard等は停止後。9paired+別順、warm1は除外。
- quick processの0メモリ観測を0Bと主張：欠測flag。WSはOS peak、privateはsampling+PeakPagedの観測値であり全時点の厳密最大を保証しない。
- child停止/出力洪水/リソース超過：60秒、64MiB、stdout/stderr各32KiB、work8MiB/report128KiB、空き5GiB+予算。失敗は保存して同じ失敗で無制限再起動しない。
- 旧phase EXEはcompact Forest採用前の依存なので流用しない。診断sourceを現子moduleへ直接接続して再compileし、公開rlib/frame復号と全byte一致を確認してからphaseを読む。
- 計測器の6境界時間を非計測native/7Zipの勝利値へ流用しない。過去不採用CDF削減/range融合/active移動/visited省略を根拠なく再試行しない。
- buildストレージ超過：Cargo6163555929B/cap6175228536Bは固定で変えない。今回Cargo build0、standalone compileだけ8MiB専用先。
- 正常復号だけで安全性を推測：既存9公開E2E baseline/終了照合、製品source変更時は再build後同経路の悪性入力/状態/no-clobberまで検証必須。

## 比較契約
466395B KHC（entry独立block）対481490B real7z solid+/blocks1/LZMA2:3m、7za26.03/mx9/md4m要求/mfb273/mmt1。raw2810784Bを辞書property3145728Bがカバーする。前native-c完全復元/mtime記録を参照し、双方testをwarm1+9。順序khc/sevenとseven/khcの別実行を保存し、median/min/max/process CPU/観測RAMを読む。率3.135%は5%未達、速度は測定前未判定。強設定全体/真正未見/encode条件は別途未達。
前native-c report SHA18E70562A567D520B57C4CD7FDC11F5B67C502C218933E6E5B2419DFBCB83D3A、
KHC C29B63905569B44A6D4AF6F19D80AEF345D68B3572BBB0A0AA82AF08D882B7DE、
7z F26CA2BA262964FC601D544D860280BCC07A984243828F02DC6DFDC5849F8A78。

## opop観点台帳
| 観点 | 親の判断・今回の検証 |
| --- | --- |
| Modernizer | 依存/tool更新不要。既存rustc/7za/rlib固定 |
| Normalizer | 旧guardの辞書表記/mtime既定を修正済み記録へ合わせる。元report変更なし |
| Performance | native復号差を9pairedと独立逆順で確認、現Forestのstageへ絞る |
| Cleaner | 参照済みEXE/report/inputは保存。不要PDBのみ用途終了後共通moduleで清掃 |
| Hardening | SHA/reparse/時間/RAM/disk/終端/CRC/byte一致、失敗report |
| Tester | 既存9E2Eとframe公開cross-decode。新unitなし |
| Async | process/stream/lockをfinallyで解放。監視以外worker増加なし |
| Startup | process wall/CPU/外側待機と純decode phaseを区別 |
| Intel | 今回外部の未解決照会なし。Oct6公式7Zip版とproperty仕様は前記録を維持 |

新規出力: build/khc-native-decode-<Attempt>-20261006（最大8MiB、実report<=128KiB）。
後続profile: build/khc-native-profile-<Attempt>-20261006（最大8MiB、EXE/PDB/JSON）。raw/frameディスク出力0。
Git/外部書込み/新サービス/版変更/既存物削除0。実験基盤の是正はcodec改善として加算しない。


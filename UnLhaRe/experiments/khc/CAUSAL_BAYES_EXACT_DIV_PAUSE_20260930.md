# CTS exact-div 一時停止・再開点（2026-09-30）

再開追記: ユーザーの「作業再開OK」後、独立照合・最大batch E2E・別session再現・重複中間archives清掃を完了。現在の採否と成果物は[DEVELOPMENT.md](DEVELOPMENT.md)末尾「CTS exact-div」を正本とする。以下は停止時点の履歴であり、現在の未完了状態として読み替えない。

ユーザーの「キリの良いところで一時停止」に従い、比較測定の終了・exit 0を回収して停止。新しい実装、測定、独立監査は開始していない。対象rootの実行プロセスなし、既存の全サブエージェントは完了を確認した。固定評価条件・製品コード・versionは変更しない。

## 保存した結果

- failure-first契約: `CAUSAL_BAYES_EXACT_DIV_CONTRACT_20260930.md`。実装: `causal-bayes-exact-div/`。CTS ratioだけを正確なQ48 shift / quotient範囲検査後のx64 DIVへ置換し、portable fallbackを保持。
- 数値CLI E2E: 独立BigInteger oracleの23,608ケース、14 checks / 14 CLI。report status `verified`。
- 全codec CLI E2E: 36 checks / 61 CLI。report status `correctness_and_size_passed_not_timed`。全frame 483,468 bytes、従来SHAと一致。
- 比較: warmup 1＋測定9、3系列循環順。39 CLI終了、report status `success`。exact-div中央値3443.1123 ms、同session fast-BWT control中央値3618.3183 ms、native7z中央値595.2353 ms。
- paired exact-div/control比の中央値0.9387823654563998（6.1218%短縮）。9対中2対は候補が遅い。独立監査・再現測定は未実施なので、採用確定や一貫した改善とは扱わない。
- 固定サイズ条件はPASS、固定full encode `<574.5624 ms` はFAIL。7-Zip総合超過・製品採用は未達。sampled thread数はthread lifetime保証ではない。

## 保持する証拠

すべて `UnLhaRe/build/khc-bwt-causal-bayes-exact-div-20260930/` 以下。

| report | SHA-256 |
| --- | --- |
| numeric-e2e/report.json | `7F30002807B10D7D0A6423A751FCE47AECFCDA022D581C234294991F87C9BDF0` |
| full-e2e/report.json | `6038187B78024F94D0CCD62D9EDAD8FB34FEB47607CEF62A07350AD1470BE611` |
| performance/report.json | `09C86E2902BA112F8DA8867B4B5D496508E1052DB0ABDF90418EFEAA75E4AAAB` |

入力、oracle、出力、EXE/PDB、測定archivesは再開時の独立照合に必要なので保持。今回のrootは未清掃。用途を終えた重複中間archivesだけを監査後に選別し、初回・最終archivesと復元証拠は保持する。過去policy拒否対象への再試行・回避、共有cache、UnLha32Reの操作はしない。

## 再開時

1. 保存されたsource/binary/report/input SHAと全実exit・archive現物・集計を独立照合する。DIV guard/register constraints、portable同値、BigInteger oracleを確認する。
2. 2対の逆転を含む結果を評価し、必要なら同一固定条件の別sessionで再現する。確認前に研究baselineを更新しない。
3. 採否と限界をDEVELOPMENT.mdへ統合し、終了した新rootの不要中間生成物だけ安全に清掃する。
4. 評価条件を緩めず次の単一案へ進む。旧debugpairのCTS比率を新candidate自身の比率に転用しない。

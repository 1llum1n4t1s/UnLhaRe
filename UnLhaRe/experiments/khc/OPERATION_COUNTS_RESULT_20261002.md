# Q15/CTS論理回数: 完全codec同値を保ち、次の改善対象を特定

指定Windows x64/rustc1.98.1で、通常/checkedの7入力を完走し、従来と全byte同一の完全483496B frameを得た。34確認/53CLI/299identity、28組のencode/decode計数JSONが通常/checkedで一致。計数付きEXEの時間を性能採用に用いていない。goal全体は未達。

## 固定development入力で実行された回数

| stage | Bayes calls | 旧exp2枝 | heavy更新 | heavy KT大型分母 |
| --- | ---: | ---: | ---: | ---: |
| light | 7622618 | 37549 | 0 | 0 |
| live-heavy | 2788870 | 5622 | 2788870 | 21674349 |
| replay-heavy | 434286 | 4827 | 434286 | 1153194 |
| reference（通常未使用） | 0 | 0 | 0 | 0 |

- Bayes合計10845774、旧exp2枝47998。direct Q15 shortcutが99.56%に適用された。これは指数計算回数の削減であり、99.56%の速度改善ではない。
- 軽量モデルは17node×7622618=129584506件を更新。selected-depth histogramは[448,440,841,1612,3147,6219,12360,24617,49165,98031,190396,330654,476812,606517,625853,468503,4727003]、深さ16が4727003件、探索反復17442185件。選択深さを浅くするだけでは17nodeの学習処理は減らない。
- heavy更新3223156=live2788870+replay434286、node更新54793652、mixture51570496、ratio wrapper106364148=33×3223156。
- heavy KTはmethod1（対称）541688、method2（既存small table）31424421、method3（大型分母）22827543。KT内部も含むratio計算129191691回のうちshift51719923、integer refinement77471768（補正なし53380957/1up24090811）。native fallback/certificate fallbackは0。large KTはrefinementの約29.47%を占める。
- 各class/stageのBayes/events、light histogram/nodes、heavy predict/update/KT/mix/node、33 wrapper/イベント、flags合計=wrapper+KT大型分母を照合。referenceやlightへheavy計数が漏れず、encode/decode/通常/checkedの全JSONも同じ。TLS state14360B、overflow=false、scope restored=true。

## 実装/証拠の範囲

元sourceから6ファイル22明示置換でcfg限定hook/参照変更を導出し、全文対応を実行時に照合した。予測/ratio/observeを診断のために再実行せず、既存Resultや正常完了loopから加算。node17/mixture16/light探索反復は元の正常loopに基づく論理回数で、CPU命令の実測ではない。thread-localはstage/classを保存/復元し、referenceを別bucketに保持する。

元full verifierから15明示置換の全文対応も別読み取りで確認した。従来の32項目（7入力通常/checked・全文frame/stdout・復元・双方向decoder・破損拒否/no-output・no-clobber・入力不足）と二つの計数同値確認を維持。製品/source旧proof/各固定ゲートは変更なし、新ユニットテストなし。

正本build/khc-operation-counts-20261002/report.json SHA 93A456E60EE7941A5721136FF14766B221E479F7CEA2FA796DAB55747A431B70、UTC2026-10-01T17:21:15.9266377Z〜2026-10-01T17:21:47.0173033Z。verifier SHA696DEECFD2739A811E3A2BEE44A1B6D98C8FE97D81A81A283F48F9E7CD54913A、更新UTC2026-10-01T17:21:14.3178295Z。通常EXE263168B/SHA FD402F1F6BE1B556F6BEC7BD442A0C6B09EBB0C0BDA41938454A312BE4740FBE、checked264704B/SHA A671B53E818FDEE75CA50D41A226A8A0D42AC73F3E7894529E3BF5BCC2EA3324。

CWD C:\Users\IMT\dev\UnLhaRe\UnLhaRe、bundled pwsh7.6.5、Windows10.0.26300.0/Ryzen5 7640HS6C12T/rustc1.98.1。compiler絶対path/SHA/version、全CLI argv、実行前後source/EXE/input/outputの長さとSHAはreportに保持。入口operation-counts/verify.ps1は既存rootを拒否し、自動再試行/上書きしない。

## 容量/清掃

新root32MiB予算を前後で通過。既存入力/元frame/EXEを再利用し、全event列/生数値/ETL/Cargo targetを生成していない。完了した計数JSONだけをbounded stdout/reportで保持する。

今回生成した未追跡/証拠未参照PDB二つを、絶対範囲・全ancestor no-reparse・使用中process0・排他open・SHA/長さ・299identity未参照で確認して削除。cleanup-pdb.ps1で同一PowerShell内の明示LiteralPath二つだけに適用。2744320B（約2.62MiB）を削除し、全299identityとreport SHAが不変、PDB残存0。直接削除だが保持source/compilerから再生成可能。plan/result ledgerをoperation-countsに保持し、backupは作っていない。

最終root14870035B（約14.18MiB）/47files、tmp/reparse0、関連process0、PowerShell parser異常0、git diff --check成功。source/docs/ledgerは別の小さい成果物。新性能試行の追加はattempt1407Bだけ。旧正式比較rootや元proof/EXE/入力は保存した。

## 次のアルゴリズム候補と未達

Bayes未最適化という問いは計数上ほぼ解消された。残る7747万余りの変動分母refinement、とくに正常heavy updateの16個の独立posteriorをbatch処理するのが次の一つの候補。KT大型分母の約2283万回はrefinement総数に含まれ、両者を二重計上しない。演算頻度は選択の証拠で、時間/cacheの原因確定ではない。

既存corrected/signed/split scalar推定商を読み取り、scalarを再発明せず4lane SIMDへまとめる。返却商は q*d<=n と n-q*d<d の整数certificateで確定し、不一致はnative商。依頼文中の誤った短縮不等式 q*d<=n<n+d は採用しない。unsigned変換、signed32出力域、推定が2^32へ丸められる境界、inactive/tail lane、feature判定、Tree updateの依存/拒否状態を新しい実装前契約で扱う。

単純scalar実装より速いことは未証明。新候補の正確さ確認を先行し、速度は新source/binary/proofを固定した静穏一回の正式比較で判断する。今回のformal preflight CPU16%失敗は再開しない。holdout/カテゴリ/同境界decode/四native決定性/製品API安全性/7-Zip総合超えは未達、goal active。


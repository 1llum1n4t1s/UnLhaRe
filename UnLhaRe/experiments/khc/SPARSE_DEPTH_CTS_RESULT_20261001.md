# 幾何深度CTSはサイズ不合格

一構成depth0/1/2/4/8/16は、有限CLI E2Eに成功しても固定size gateを超過したためNO-GO。完全frame484950Bは固定上限483599Bより1351B大きく、凍結old483469Bより1481B、通常causal scheduler483496Bより1454B増える。速度測定/holdout/深度集合やconfidenceの設定sweepは行わない。default、製品API、version、x86を変更していない。

最初のverifierはmapping診断後にIdentityのproperty誤りで停止した。旧verifierと失敗reportは凍結し、property1件・新root・旧verifier pin追加だけの3置換cloneで再検証した。圧縮アルゴリズムは変更しない。[修正境界](SPARSE_DEPTH_CTS_HARNESS_REPAIR_20261001.md)と各source全文対応を保持している。

成功E2E（sizeのみNO-GO）のterminal reportは `C:\Users\IMT\dev\UnLhaRe\UnLhaRe\build\khc-sparse-depth-cts-20261001-harness-repair\report.json`、SHA256 `04F3D1A7605E0BB1ACC62AB363BECA07047DB2641AF46A46D6362AFC37ECC788`。2026-10-01T14:36:54.3603943Z〜14:37:27.2725588Z、exit0、status `correctness_passed_size_no_go_not_timed`。57checks/69CLI/93identities、check/timeout/exit失敗0、source/input/出力の保存後と現在の長さ/hash差0。通常native237568B SHA `EA0291F26FAC0C6ED4B3036EDE7E49362EAF090E19A0F925E750EF0729C2C8F6`。固定frame SHA `76CEE8C2EBFD7A4A06514CDC9F891618C563B5844C39C7D21528552E576AFA7E`。

| 検証 | 実行した範囲 |
| --- | --- |
| suffix mapping | 全65536個の16bit history×6depth、393216recordを元1bit-step tree indexと照合。invalid level2件拒否、Node16B/Prediction192B/65815nodesを確認 |
| 圧縮・復号 | 空/単byte/全byte/反復/周期/seeded random/固定group、native/forcedportable/連続heavy参照cfgのframe全byte・復元hash・schedule一致 |
| 因果的replay | active2788870件のheavy/Bayes Q15が連続参照と一致。小journal64recordsではforced catch-upと多数切替を往復で確認 |
| 失敗時公開 | 代表5破損、old/通常scheduler/小journalとのmagic交差拒否、既存出力保持、入力欠落、mapping CreateNew/引数拒否 |

16bit suffixのkeyは新context_index（reverse_bits）と、旧treeを根から1bitずつ辿る別計算で照合した。records4718592B SHA `236B901D4F05081841814CDE9D05130BAF4AD83553566F6CCD0A27FAA42E26A5`を保持する。これはmapping全有限historyの証拠であり、全Model内部状態の独立BigInteger oracleではない。四nativeのf64決定性・normal input cap超過fixture・全misuse/poison分岐・製品path/publicationの証明ではない。

fixed scheduleは通常causal schedulerと全field一致し、heavy processed3223156（replay434286込み）。sourceの1event構成は17→6KT、16→5posterior/mixtureなので各種35354716呼び出しを減らす構成になったが、これを時間短縮率とはみなさない。通常Prediction192B、heavy Node arrays7371280B＋表524296B。light/Bayes/journal/BWT/allocatorを含むOS peakやhard capではない。圧縮率損失1454Bは、段数削減を採用するには今回の固定gateの残余103Bに対して大きすぎる。

再現入口は `pwsh -NoProfile -File experiments/khc/sparse-depth-cts/verify-harness-repair.ps1`、既存rootを拒否して証拠を上書きしない。初回入口とのcorrespondence、独立context CLI、compiler/source pins、入力/frame/restore/raw stdout/stderrを保持する。必要な証拠は28535716B、owned tmp/reparse0、関連processなし。

## 用途終了の重複rawだけを清掃

初回失敗rootの `C:\Users\IMT\dev\UnLhaRe\UnLhaRe\build\khc-sparse-depth-cts-20261001\context-records.bin` は、修正後rootの同名recordsと4718592B/上記SHAが一致し、二重保持は不要になった。正確な絶対path、owner、全ancestor非reparse、process不在、exclusive open、保持側identityを確認し、同一PowerShellのliteral Remove-Itemで初回の1ファイルだけ削除、不存在と保持側hashを確認した。4718592B削減、同一rawまたはcontext CLIで回復可能。初回context EXEはhashが異なるため削除していない。

初回report SHA `60C58C347A9B84451345A6BAF536CB3B2A7816EEE854B5D8080DFC11407B8807` は改変していない。初回29identitiesは実行時の歴史的記録であり、清掃後28が元pathに現在存在し、削除した1つは修正後recordsへ対応する。初回root1499230Bを保持。修正後93identitiesはすべて現在一致する。共有cache/他作業/ごみ箱/x86は削除対象にしていない。

総合7-Zip超えは未達。通常schedulerのcorrectness/size候補は保持する一方、速度はCPU quiet失敗で未判定。今回のNO-GOは深度を単純に減らして計算量と圧縮率を同時に満たす仮説を反証し、次は同じ深度集合の微調整ではなく、符号化event数やdense context学習の別構造を検討する材料になる。

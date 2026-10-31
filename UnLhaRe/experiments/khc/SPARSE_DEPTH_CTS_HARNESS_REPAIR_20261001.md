# 検証入口のproperty修正、数値構成は不変

最初の入口は全65536histories/393216mapping records、layout192B/Node16Bの診断とrecords CreateNew拒否まで実行したが、直後のハッシュ比較で失敗した。Holdが返すIdentityは `.sha256` であり、記録リストに追加する別objectの `.before_sha256` を読んでしまった実装誤り。圧縮codec起動前、4CLIの有限部分成功であり、全E2E/size成功と扱わない。

元 `verify.ps1` SHA `25E20785438C89199271534855F2FB2321A9184062098C5743EC0A3BD42F466C` と初回root/report SHA `60C58C347A9B84451345A6BAF536CB3B2A7816EEE854B5D8080DFC11407B8807` は変更せず保持する。context records4718592B SHA `236B901D4F05081841814CDE9D05130BAF4AD83553566F6CCD0A27FAA42E26A5`。

修正入口 `verify-harness-repair.ps1` は元scriptに3個だけの明示置換: 比較propertyをsha256へ訂正、新しいowned root `build/khc-sparse-depth-cts-20261001-harness-repair`、元verifierをsource pinに追加。全文対応を `harness-repair-correspondence.json` で記録する。codec/heavy/scheduler/Bayes/context audit、depth集合、confidence、journal、固定input/size/時間の閾値は変更しない。これはサイズ不合格の設定再試行でもCPU正式比較の自動再試行でもない。

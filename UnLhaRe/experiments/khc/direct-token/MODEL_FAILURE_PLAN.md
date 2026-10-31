# direct-token CDF primitive: 失敗条件と検証入口

実装前仕様は `../DIRECT_TOKEN_CONTRACT_20261002.md`。alphabet/key/token/limit/slotの境界拒否、更新前のroot/local両検査、拒否後の継続、root/localのrescale、truncate時の累積・選択、全count一致を確認する。独立oracleは生配列・逐次和・線形探索のみ。treeの計算をoracleへ複製しない。

4条件（opt2/3 × overflow checks有無）を別の小EXEで実行する。契約の生成物欄の「2個」は4条件を4個保持する実行計画と不一致のため、実数と容量を報告する。契約のハッシュは変更しない。8MiB予算は維持する。raw trace、Cargo、PDBを作らず、検証結果は小JSONのみ。

検証開始前にsource/contract/compilerをハッシュ固定し、読み取り共有でロックする。fresh output限定、再実行/上書きしない。child120秒、stdout/stderr各65536文字まで。引数拒否と正常終了を別CLIで確認する。全4条件で件数とfingerprint一致を要求する。

heap allocationの実失敗注入、他OS/CPU native、full codec/wire、速度/圧縮率、製品統合はこのprimitiveの成功からは証明しない。

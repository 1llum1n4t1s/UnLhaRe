# 等カウントKT短絡候補の失敗条件

## 実装前の条件

- 既存mixture-reuse CTS/source/EXE/正式proofを変更しない。新候補の唯一の数値変更はNode::ktのtotal checked_addとMAX_OBSERVATIONS検査の後のzero==one短絡。一般除算helper・posterior・weight・predict/update・precision・wireを変えない。
- total overflow又はcap超過の等カウントを成功させる、weightの新検査を追加する、既存のエラー内容・優先順を変える場合は失敗。
- c<=281018401のz=o=cでは分子因子と分母が2c+1、旧商は厳密Q/2。c=281018402はcap error、c=2147483648はtotal overflowを先に返す。既存下流probability(Q/2)は必ず成功。
- 独立BigInteger oracle、直接Node::ktを呼ぶCLI、実Model履歴rawの照合が成立しない場合はcodecへ進めない。任意u32 counts境界、非等カウント、最大cap、overflow/cap優先順、0/0、偏り両端、opt2/3反復を含める。
- 診断用のaudit cfgは通常codecへ入れない。追加ユニットテストではなく、入力とraw出力を保持するCLI E2Eを用いる。oracleはcandidate除算helperを共有しない。
- 旧65536helperと11267Model履歴の検証を新CTSでも再利用する場合、実source/current proofを再検証し、新unused rootの証拠にする。過去の中間rootや削除rawは正式DFSに混入させない。
- 入力/出力のreparse、既存出力の上書き、no-clobber sentinel破損、想定外exit/timeout、source-after変更、証拠又はownedtmp不整合は成功を禁止する。

## 所有と段階

直接KT CLIは `khc_balanced_kt_audit` cfgで実Node::ktを呼ぶ。入力はLE u32 zero/oneの8B record、上限65536件。出力はLE u64 probability＋u64 statusの16B record（valid0/total overflow1/cap2）。原エラー文字列は `CTS node total overflow` / `CTS node observation cap exceeded` の完全一致で分類し、対応をstdoutのerror_messagesへ記録する。未知errorは成功扱いにしない。独立oracleはu32 total overflowを先に、次にcapを判定し、有効値をBigIntegerのQ*(2z+1)/(2*(z+o+1))で求める。原helper65536件と実Model11267観測/7historiesの検証は別モードとして保持し、診断cfgを通常ビルドへ入れない。

親が契約・後段codec/build/fullverify/compare・開発記録を担当する。数値実装担当は新 `causal-bayes-q32-balanced-kt/{cts_model.rs,audit_cli.rs,verify-numeric.ps1}` だけを所有し、凍結mixture-reuse CTSをcloneして一変数を追加する。先にCLI数値仕様と失敗集合を実装し、数値証拠を完成・freezeしてから独立新contextへ確認を渡す。

実書庫の等カウント率・分岐予測・生成コード・正味速度は未測定。枝追加により非該当時が遅くなる可能性も残る。数値一致を速度の証拠としない。codecでは旧mixture-reuseと7小fixture＋固定frameの全byte一致・相互復号、旧79checksの包含、公開安全性を確認してから固定条件の性能比較へ進む。

固定条件は483599B以下、全CLI encode中央値574.5624ms未満、quiet15%、warm1＋9、同session循環・既存native設定のまま。現在のSAIS Q48研究基準、holdout/4native/製品統合を含む総合目標を縮めない。全工程でGit/外部書込み/製品/x86/CPU設定/共有cacheの変更をしない。

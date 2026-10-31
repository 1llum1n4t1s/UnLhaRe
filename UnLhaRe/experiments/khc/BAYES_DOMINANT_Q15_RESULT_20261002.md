# Bayes Q15優勢shortcut: 数値/完全codec合格、性能未判定

指定Windows x64/rustc1.98.1の有限検証で旧予測と完全frameが一致した。これは速度改善、四nativeの同値、製品導入、7-Zip超えの証明ではない。元の凍結source/proofと固定ゲートは保持した。

## 変更と検証

component boundsを先行し、両lossと差が有限の場合に限り、同componentまたはloss差32以上を直接整数CDFへ返す。primary-cts>=32はcts優勢、<=-32はprimary優勢。学習用両component、observe、gain、scheduler、wireは維持する。元Bayesへの一つのshortcut挿入とcfg監査hook追加、schedulerのmodule参照2箇所を全文対応で確認。codec本文は元整数候補とSHAも完全一致。

閾値32は最大CDF寄与32766/(1+2^32)<7.63e-6から決め、サイズ/時間へのfitやsweepはしない。この実数モデルの丸め同値と、実際のnative有限検証は別の証拠。[公式f64 exp2文書](https://doc.rust-lang.org/std/primitive.f64.html#method.exp2)は精度を全環境共通に保証していない。閲覧時の表示版1.99.0と実行compiler1.98.1を混同しない。

数値CLIはopt2/opt3、両方overflow-checks=yesで各5920979件を旧実コードと逐次比較。Prediction三値とエラー文字列を比較し、生値を保存しない。全32767 primaryとCTS端/中央/隣接/同component、32の隣接float、負finite/NaN/Inf/差overflow、不正component、seed付き100万件を含む。equal 491915、primary優勢 2151943、CTS優勢 2152672、旧経路 1124449、エラー 4361。FNV64 529ee7291004574bは実比較後の非暗号要約で、hashだけを正確さの根拠にしない。7 CLI/6確認/19 identity。

Full E2Eは7入力×通常/checked、全文frameとschedule stdout、復元、双方向旧新decoder互換、5破損拒否/no-output、encode/decode no-clobber、入力不足を確認。53 CLI/32確認/218 identity。完全固定frame483496B、SHA CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12、上限483599Bを満たす。ユニットテスト新設なし。旧verifierから15明示置換を全文照合して実行した。

## 正本の証拠

- 数値: build/khc-bayes-dominant-q15-20261002-numeric/report.json、SHA CD285519F0EB1A74A5DBA01CDD26AFD484471586A6555537E3A7051FB69A5C51。UTC2026-10-01T16:49:47.0252022Z〜16:49:49.3562352Z、verifier更新16:49:34.332058Z。
- 完全codec: build/khc-bayes-dominant-q15-20261002-codec/report.json、SHA 0776392ED95FEE12D1F47FF6CE06C409B7A6DEC6A086AAC131234335EC834360。UTC2026-10-01T16:51:12.2741845Z〜16:51:40.5719008Z、verifier更新16:50:51.2924462Z。
- 通常EXE238080B/SHA A98326FBF88608DACE22D44DF934DF5EC3062AB684E934F644013024E69B0FBE。checked239104B/SHA C24C2E9969E1308210D1A7F7C43FCF3CFDF58F1C5DE6CE63097DF16396C95CDF。
- CWD C:\\Users\\IMT\\dev\\UnLhaRe\\UnLhaRe、bundled pwsh7.6.5、Windows10.0.26300.0、Ryzen5 7640HS6C12T。compiler C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe、SHA CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC。全argv/version/絶対scriptパスは両reportに記録。
- 初回入口bayes-dominant-q15/verify-numeric.ps1とverify-codec.ps1は既存生成先を拒否し、上書き/自動再試行をしない。証拠を消して同じ試行をやり直さない。source対応はcorrespondence.json、verifier対応はverifier-correspondence.jsonで再現可能。

### 現在のsource pin

| source | SHA256 |
| --- | --- |
| audit_cli.rs | 1A4D481753AB6348D1F29BB8A3CD47ED8901D2D3616D58AAFABB26D8217E8D12 |
| bayes_model.rs | DC0852C55C5CDA8B97D445C231B92ACF446FCBC17959B6ABC58244E7D0E6797B |
| bayes_old.rs | 34E32F4F45E0D20BE0EE12595C8E2296838DDFBC50C5BDBC3D6D2E6EF80DFF3F |
| codec.rs | 0AD79D2C15CFFA96CDBED33421C20418C146BA223C872CFDCF5FD3F263ED0B64 |
| correspondence.json | 4BFF5873CB2402D69F5C2D4FA59447F08E3F2A9E5C586161ACE07C71CD0D74AC |
| scheduler.rs | C286EC6D84894A889B5BD2153E0817BDA4FD22A2A684B8E2554F47BB21475656 |
| verifier-correspondence.json | 1CD028592FACF328D674D19DAF51ADE2D357DA1D8255F96B86ABA109693595B4 |
| verify-codec.ps1 | 6D87E77A4E20135222F46118F1AEEE877B620178B359EE67E4E748A7EABAD566 |
| verify-numeric.ps1 | 4024D454234A2D318833F37C0F51C07BCFB6D1DF0055B8EBFB0E1BA00B846A58 |

## 容量と清掃

Numeric8MiB/full32MiBの事前・事後budgetを通過。固定input/旧frame/EXEを再利用し、新Cargo target/cache、生trace、全件数値は作成していない。

今回生成した未追跡/証拠未参照PDB4件だけを、絶対範囲・ancestor no-reparse・SHA/長さ・関連process0・排他open・両report参照で検査して削除した。最初の変数を使う単発削除呼出はpolicy拒否で未実行。cleanup-pdb.ps1へ同じ安全確認をまとめ、同一PowerShell内で明示LiteralPath4件だけを削除した。別シェル渡しや再帰削除はない。

削除量5341184B（約5.09MiB）。計画/完了ledgerはbayes-dominant-q15/pdb-cleanup-{plan,result}.json。直接削除したためごみ箱からの復元は不可だが、保持source/compilerから再生成できる。backupは作成していない。削除後237 identityのSHA/長さと両report SHAが不変、4 PDB残存0。

最終numeric298847B/3files、full12979149B/47files、計13277996B（約12.66MiB）。tmp/reparse0、関連process0、PowerShell parser異常0、git diff --check成功（既存DESIGN.mdのCRLF警告は別）。source/ledger容量は生成先と区別する。前回の整数formal root10477515Bは証拠として保持した。C空き約64.59GiBだが、前回清掃以外に増えた原因は未調査で、今回回収量へ加算しない。

## 未達と次の工程

前回integer候補の正式比較は旧control warmup後CPU16%で終了、計測samples0。再開/自動再試行なし。本shortcut候補は新しいアルゴリズムとして数値/E2E合格のみで、速度測定はまだ行っていない。

次は新source/EXE/二proofを固定し、旧8measurement helpers同値でformal harnessを導出する。新候補一回だけ、warmup1+9/circular/全CLI起動終了とdrain/host CPU15%/完全frame483599B/encode median<574.5624msを維持して検証する。全codecでの十分な高速化、holdout/カテゴリ/同境界decode/四native決定性/製品APIと安全性は未証明。goalはactive。


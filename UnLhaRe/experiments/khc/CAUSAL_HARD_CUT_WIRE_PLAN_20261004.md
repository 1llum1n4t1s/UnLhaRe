# hard-cut実frame：先行E2Eから接続する

前工程はcompile1/native1でscreen480782B、readonly105pin組成功。証拠CAUSAL_HARD_CUT_RESULT_20261004.md/report SHA E4CC334310A4426EB9F83E68D9D95D6421747723BCEE2A3F01C29CD346E4B9A0。これは実frame/速度成功ではない。次工程の判定は実frame.len()<=483599、全plain直接比較、encode/decodeの全Proof14 Eq、再encodeの全frame直接比較、破損拒否、資源の実測である。

readonly接続監査は原codec SHA02DCD75C450323F844029E6098C041779551BB2E8E10DCF918E8D44751F94B91 の数値処理を変えず接続可能と確認。新private magicはKHQCHC01（8bytes）。codecのmodel pathを原modelへの明示path、e2e pathを新先行fixtureへ各1、magicをdoc/const/statsの3箇所、計5置換。原file/旧wireは変更しない。原float_scopeの返却型を維持し新codecを参照。new adapterは凍結causal-hard-cut/engineを直接path再export＋Node=NodeState aliasだけ。root旧CTS primitives/prices/Model/pool/math/BWT/range/packed alphabetを凍結参照する。

frame_audit/primary_auditはOFF、wire_auditはON。原Modelの旧Clone/weight seed helperをコンパイルしない。TLS集計/追加KT loss log2もOFF。旧e2eのframe_audit必須selfcheckは呼ばず、同正常・破損frame技法を新fixtureへ先行移す。先生旧frame長/CRC/digest/loss一致を新アルゴリズムへ要求しない。Proof14のbase digestだけで新primary全node一致を主張しない（原primaryの全state有限oracleは前工程で成功）。固定validate_fixed(5)はgrammar/CRC/finite共通条件として照合、depth8数値条件へは到達しない。

第一段階は新causal-hard-cut-wire/FAILURE_PLAN.md,e2e.rsだけ。原e2e SHA81BD12AC0C240E3FB51EA0E6A7F20FA22BB5278067F709FA53BB8560FDA734E5 を基点にcfg(frame_audit)→cfg(wire_audit)、旧Model.rejection_checks 26件を除去、関連count/reportをframe E2Eだけへ修正。既存14正常/33破損/4短depthheaderを維持。旧float magic KHQCFP01を明示拒否するケースを1追加して破損34件。新magic受理は全14正常で確認。正常各encode2/decode1、全plain/Proof14/全再frameを直接比較。初回実装前にエラー一覧を保存し、動的未検証のREADYまで。codec/runner/probe/adapter実装は禁止。

第二段階は親が先行2filesを全文確認・停止返却後に許可。nativeはselfcheck CLI1＋fixed CLI1の計2、compile1。selfcheck後finite入力/frame/復元Vecをdrop。fixedはinput一read/encode1/decode1、型付きProof14 Eq/全2811006plain直接比較/実サイズ/全stats相互整合。frame/plain/inputのdisk保存0、EXE/reportのみ。statsを先生値へ固定せず、grammar countsとCRCだけ既知共通値を使用する。E2E stdoutとfixed stdoutは別child記録にしてJSON投影の混在を避ける。

rustc1.98.1 edition2024 opt3/thin/CGU1/unwind/overflowyes/debug0/DEBUG:NONE、compile60s/native各120s。source300KiB/EXE1MiB/report256KiB/output8MiB/free5GiB、newunused build/khc-causal-hard-cut-wire-20261004。入力/source/tool/旧成功証拠/先行fixtureのbefore-after-live pin。価格cfg(test)探索限定stripは前成功runnerの同SHA限定allowlistを直接再利用しcfg(test)OFFの原コンパイルsourceを維持。Model/source容量見積と実WS/private<=160MiBを区別して両方確認、デコード途中/encode出力のpeakも全native process終了時WinAPI計測。型付きProof14 Eqはencode/decodeで全field、screen exactlossは参考で新getter追加しない。

速度の診断時間は採用根拠にしない。実サイズ通過後だけquiet<=15%/warm1+9/fullCLI574.5624ms/47.3884ms/same memory/thread正式比較へ。holdout/category、完成書庫metadata/API、4native/総合7-Zip超えは未達。製品dirty/version/x86/Git/共有cache/旧証拠不変、削除/公開/追加委任なし。

観点台帳：Performance＝新primaryの実wire評価、Normalizer＝数値原codec/primitive直接参照、Hardening＝CRC/破損/旧magic拒否、Tester＝先行全frame E2E、Modernizer依存変更なし、Cleaner生frameコピー/trace保存なし。Asyncはfinite Vec解放/owned child終了、Intel外部仕様不要、Startup private EXEのみで製品非該当。

# 旧Q32 stage診断: cfg依存修正試行の固定契約

## 前試行の実測結果と今回の変更

`quaternary-cts-stage-profile/` の試行はcompile1がexit1、CLI0で終了した。診断時間は未取得、encode/decode/input read/E2Eの動的完了は0または未観測であり、合格とはしない。失敗reportは56374B、SHA256 `0D2DEDC2A4937361FE77C3F5C6C6EBE7ED38597C14653458E77478F36057563F`、UTCmtime `2026-10-03T14:17:17.0430938Z`。stderr4555BにE0599が5件、既存unused import警告1件。所有EXEのprocess censusは0、出力はreport1件のみ。親が169 source identitiesのSHA/bytes/UTCticksをlive照合し、不一致0を確認した。前source4件・契約・reportを編集/削除/上書きしない。

原因は凍結 `quaternary-cts-depth/model.rs:107` のframe_audit限定rejection_checksが、同integer_cts.rs:154–157のprimitive_audit限定seedメソッドを参照すること。frame_auditだけでは通常経路から未呼出でも型検査が失敗する。前FAILURE_PLANのprimitive_auditを追加しない制約は保持したまま失敗として記録し、**この新試行だけ**compileへprimitive_auditを追加する。親のgraph10件のcfg探索で、追加cfgはdepth/q32 CTSのseedメソッド定義のみ。独立readonly担当もdepth2bodyと所有codec参照を確認した。rejection_checks/seedの呼出は追加しない。通常数値/wire/CRC/総timer/83契約case/計測方式は変えない。

## 新物・所有・実装前計画

新sourceは `quaternary-cts-stage-profile-cfg/` のFAILURE_PLAN.md、codec.rs、probe.rs、verify-stages.ps1の4件、親一人が所有する。FAILURE_PLANをコードより先に固定する。codec/probeは凍結前試行から同内容コピー、runnerだけroot/compile cfg/basis schema/174 identity接続を修正する。新outputは `build/khc-quaternary-cts-stage-profile-cfg-20261003/`。前rootを再利用しない。新候補アルゴリズム・別model/poolコピー・unit test・製品/API/version/x86/Git/外部サービスは追加しない。

固定数値テンプレはQ21のbaseline_codec.rs、graphは所有root/codecと凍結depth/model、depth CTS、q32 CTS、旧pool/Math、SAIS BWT、packed_alphabet、multi_rangeの10source/9edge。前の26観測置換allowlistを維持し、数値/wire/state/総timer全token一致を検査する。新codec/probeのbyte/SHAは凍結前codec/probeと一致させる。

## 呼出・失敗・診断条件

この修正試行はcompile1/候補CLI `profile INPUT` 1、encode2/decode1/input read1。先行失敗compile1を含め累計compile2/CLI1を予定し、過去のcompileを隠さない。追加warmup/canonical/ABBA/再測定選別なし。合計wall300秒、各child120秒。synthetic契約12loop/13group/83case=38Ok+45期待Err、stream3080/sample16/scope pairs64/top pairs4/escape7。exact生成recipe・9golden・14overflow・10lifecycle・4residualは凍結前FAILURE_PLANを参照し、一切変えない。

top全区間transform/payload、Model::new/finish_audit各1回、枝はcomponent×prefix8層・層ordinal%256==128を抽出。sample同ticket親とpredict/range_and_selection/observeの3子を計測し、同枝残差だけchecked計算。全数nのsampleはn<128なら0、他は1+(n-128)/256。escapeは成功counterのみ。空Instant pair10000組1回、補正/採用利用なし。実時計attemptsとcommit endpointsを分け、故意のMAX内部state seedをAPI到達可能としない。先行操作前のfixture/recipe/pending、Result差のfirst field、実Err、予定/完了を保持。census失敗でも別tryでbounded report保存を試す。

無計測参照は同bodyで時計/集約無効、独立oracleではない。参照/計測frame全478750B、復元plain全2811006B、Proof14×2（CDF bits）、全stats3組、旧固定値を比較。branch各方向3825340/component[2725772,1099568]/escape742、各層全数/sample数の方向一致、全bucket開始終了pair一致、top4bucket各1回を確認。candidate frame最大2枚/957500B、参照最後0、disk input/frame/plain copies0。

## 固定参照・容量・実行

basisは前失敗reportを上記SHA/bytes/UTCmtimeで別固定。169 identitiesは失敗reportのbefore tableを継承し、現在liveと一致しなければ拒否する。過去after/live未完了を成功と偽らない。新契約1+新4件を加え**174 identities**、今回before/after/liveを全件SHA/bytes/UTCticks検査する。前失敗reportが参照するQ21 reportもparent_basisとして別固定し、各phaseで照合する。DateKind String/ISOmtime/Roundtrip UTCticks、readlock/graph/aliasを維持する。

source4件≤300KiB、EXE≤1MiB、report≤256KiB、最終EXE/report2件・保持≤1.25MiB、fresh≤8MiB、各write前に空き5GiB+8MiB以上/reparse祖先拒否。stdout/stderr16KiB、formatter stdoutは300KiB stream hashとbounded preview/本文省略を区別。JSON projectionは174×1024+2048 basis+2048 parent_basis+79872その他=262144Bとし、実serialized sizeをwrite前に再検査する。新入力コピー/Cargo/PDB/asm/raw traceは作らない。前55KiB失敗証拠は保持する。

runtime PowerShell7.6.5 SHA362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139、rustc1.98.1 SHACA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC。edition2024/frame_audit/**primitive_audit**/opt2/overflow-checks=yes/panic=abort/debuginfo0/link DEBUG:NONE。親nonExecuteでparser/formatter/graph/token/174 identities/容量を確認し、独立readonly確認後に親がExecute1回。動的未実行のfailure保存/CIM失敗注入は未検証と残す。

診断専用。inclusiveを二重加算せず、推計をexact exclusiveとしない。周期/cold/rescale/時計分解能/観測負荷の限界を明記。正式median574.5624ms/CPU15%/holdout/categories/4native/製品APIの固定条件は変更しない。7-Zip総合超え、製品完成、goal complete/pausedにはしない。

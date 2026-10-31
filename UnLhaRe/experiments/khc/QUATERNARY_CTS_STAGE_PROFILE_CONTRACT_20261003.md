# 旧Q32 depth5: 小容量stage診断の固定契約

## 目的と境界

Q21候補まで4案は正しさ合格でも事前の両方向短縮条件へ達していない。Q21結果は `QUATERNARY_CTS_MIXED_Q21_ABBA_RESULT_20261003.md` に固定し、採用基点は旧Q32 depth5のまま。次は**新アルゴリズムを試す前の限定診断**として、BWT・payload・残差、およびpayload内のbranch予測/符号化/更新の寄与を観測する。計測入りbinaryの時間を改善率・採用gate・正式benchmarkへ流用しない。停止ではなくactive goalの次の工程である。

製品/API/version、x86、公開・配信・Git変更、外部サービス、共有cacheは対象外。凍結されたsource/契約/結果/EXE/reportを編集・削除しない。今回の新物だけを `quaternary-cts-stage-profile/` と `build/khc-quaternary-cts-stage-profile-20261003/` に分離する。

## 所有ファイルと実装順

新sourceは4ファイルのみ: `FAILURE_PLAN.md`、`codec.rs`、`probe.rs`、`verify-stages.ps1`。最初のturnではFAILURE_PLANだけを保存し、問い・失敗分類・exact loop/counter・想定graph/bytesを親へ返して編集停止する。親が計画を全文確認してから、指定worker一人へ残り3ファイルを委任する。親も所有中のworkerファイルを同時編集しない。コード後unit testは追加せず、standalone診断CLI内の契約E2Eを用いる。

codecテンプレはQ21ディレクトリの**baseline_codec.rs（旧Q32 scope）**。新Q21 candidate childとE2E参照だけを除去し、modelは凍結depth/model、pool/Math/CTS/BWT/packed alphabet/rangeも旧sourceへ結線する。新Q21数値body、QCANCEL/Math-U64/Alpha bodyを接続しない。所有codecの数値statement・型・状態・順序・wire・CRC・既存総timer境界は維持し、その間に診断用の時計/カウンタだけを追加する。別model/pool copyを作らず、まず最小のstage計測に絞る。更に内側のCTS/Math詳細は結果を見て別の契約で判断する。

rootの想定配線は所有codec、旧baseline_cts=depth CTS、reference_cts=q32 CTS、旧integer_pool、旧fixed_math、BWT、packed_alphabet、multi_range。root integer_cts aliasはreference_ctsで旧poolを支える。codec内integer_cts aliasはbaseline_cts、model参照は凍結depth/model。閉包はrootを含む10 unique source/9 path edgesを想定し、実装担当が計画の時点で全pathを確定する。所有数値コピーはcodec一つのみ。

## 計測方式

topは全区間: encode BWT、decode inverse BWTを共通bucket `transform`、各encode/decode payloadを `payload`。既存総timerのelapsedとその二つの差を `top_residual` とする。残差にはheader/CRC/packed/frame・非計測処理・時計/counterの影響も入るため「CRCだけ」や純粋な演算時間と呼ばない。payload内のModel::newとfinish_auditも各1回のinclusive bucketを保存する。親子を合計して二重加算しない。

branchはcomponent×prefix（2×4=8層）別のsystematic 1/256抽出。層ごとの1-based ordinalが `ordinal % 256 == 128` の場合のみ、同じ枝の `branch_after_prefix` 親scope、および `predict`、`range_and_selection`、`observe` の3直下scopeを計時する。prefix確定と抽出カウンタの処理は親scopeの前なので含まれない。rangeはknown_child/interval/Encoderまたはslot/select/interval/consumeを含み、tree edgeなどの残りは親−3childの残差へ入る。uniform escape byteは時間sample対象外、別の成功counterだけ記録する。

prefix各層の全数nに対する予定sample数は `n<128 ? 0 : 1+(n-128)/256`。固定境界goldenはn=0,1,127,128,129,383,384,385,u64MAXの9件で、期待0,0,0,1,1,1,2,2,72057594037927936。guard・counter overflow・未完了scope等の負例とexact件数は実装前FAILURE_PLANで固定する。無効引数の検査前にcounter/時計を進めない。

方向ごとに全branch開始/完了数、component/prefix全数/sample数、全bucket開始/終了/pair数・elapsed ns、escape数を集約する。sampleされた同じ枝のparent−child合計のみexact residualとして計算し、逆転を0へ丸めず失敗にする。payload全体からsampleの推計を引いた「exact exclusive」は作らない。層ごとのsample平均・全数を掛けた推計を出すなら必ずestimateと明記し、測定値と区別する。小さい順位差は判断不能とする。

codec外で固定10000組の空Instant pairを1回だけ観測し、counter/loopも含むoverheadの目安として保存する。codec時間から機械的に差し引かず、補正値を採用gateに使わない。periodic workloadとの同期、初期/cold/rescaleの偏り、時計の分解能、計測分岐/カウンタの影響は残る。

## 呼出数と正しさ

候補CLIは `profile INPUT` 1回、compile1回。fixed inputは既存all.groupを1read、2811006B/SHA `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76`。runnerの凍結identity検査/readlockで入力も保護する。

無計測modeの旧数値codec encode1回でRAM参照frameを作る→計測mode encode1回→計測mode decode1回、計**encode2/decode1**。無計測modeは同じ所有bodyで時計/集約が無効な経路であり、独立した別実装oracleではない。数値statement差分検証と旧固定statsがこの点を補う。追加canonical再encode、warmup、ABBA、再測定選別はしない。

参照frameと計測frameの全478750byteを直接比較、計測decodeの全plain2811006byteを入力と直接比較、参照encode/計測encode/計測decode全Proof14（CDF bits）と全statsを比較する。旧magicKHQCID01/header285/payload478465/plainCRC433441561/payloadCRC3616798779/headerCRC621578488/base0caac94407124a37/CDF表示3820763.985142052等は旧固定値を保持。grammar/runs/classesも固定値を検査する。最大candidate frame2枚/957500B、最後reference0。全frame/input/plainをdiskへ保存しない。

各計測方向のbranch成功数はcomponent別[2725772,1099568]、総数3825340、escape742。encode/decodeのcomponent×prefix全数とsample数は一致する。全bucketの開始/終了数、同sampleのparent/child pair数、transform/payload/Model::new/finish_audit各1回を確認し、不足・余分・overflow・未完了をpassedにしない。失敗時は最初のfield/indexと予定/完了数、生成recipe、bounded evidenceを保存する。heap/write/sync fault injection、一般入力、holdout検証は含めない。

## 参照固定・容量・実行

Q21 reportの163 source identitiesをbefore/after/liveで照合し、Q21 RESULT1+新4を追加した168 identitiesを想定する。この契約自体も固定sourceへ加えるため、最終identity countは**169**。Q21 reportのidentityはbasisとして別にも保存し、byte/SHA/UTCmtimeを照合する。identity schemaはpath/sha256/bytes/mtime_utc、DateKind Stringで読んでRoundtrip DateTime→UTC ticks比較。各読込元のmetadata/graph/alias/数値/timer diffを親と独立readonly担当が確認する。

新4source≤300KiB。EXE≤1MiB、report≤256KiB、最終出力2件、fresh root≤8MiB、保持見積り≤1.25MiB。各write前に予算と空き5GiB+8MiBを確認し、出力root/祖先のreparseを拒否、timeout120秒で所有childだけ回収する。Cargo target/PDB/asm/raw trace/新表/入力frame復元copiesを作らない。再現source・小さいEXE・bounded reportを保持し、一時物があるなら用途終了後その物だけを清掃する。

PowerShell7.6.5 SHA `362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139`、rustc1.98.1 SHA `CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC`。edition2024/frame_audit/opt2/overflow-checks=yes/panic=abort/debuginfo0/link DEBUG:NONE。nonExecuteはparser/formatter stdout/graph/identities/容量だけで出力を作らない。編集停止と独立確認を回収してから親がExecuteを1回だけ行う。

正式median574.5624ms/CPU15%/独立holdout/categories/4native/製品API条件は変更しない。この診断が成功しても性能改善・製品完成・7-Zip総合超えとしない。goalをcomplete/pausedへ変更しない。

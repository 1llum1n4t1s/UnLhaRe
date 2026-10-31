# all-class-static 単一ブロック完成frameの失敗先行計画

本試作はStage Aとは別のstandalone入口であり、製品/API/CLIや既存pinを変更しない。
入力上限1MiB、構成は既存SA-IS BWT・run grammar・全class有料static model・整数rangeの一つに固定する。
model選択に既存の浮動小数DPを使うが、wire CDFとpayload符号化・復号は整数のみである。

## コードを書く前の失敗一覧と有限E2E

- magic/version/mode/reserved、加算overflow、宣言長と実長、出力上限：固定40B headerの全fieldを検査し、短いheader、過大長、切断、末尾追加、予約値、未知modeを拒否する。制限超過はmodel確保前に拒否する。
- model/CDF：既存packet readerの全root数・padding・木深さ・frequency正値/合計/tail検査を再利用する。固定codebook identityも検査する。壊れたmodel header・bit数・padding、および不正CDFを有限fixtureで拒否する。
- range：5B prefix、切断、末尾、丸め隙間、不正interval、canonical finishを検査する。終端byteとprefixの破損を拒否し、同じprocessで正常frameを再復号する。
- history/prefix：grammarの6class履歴をk=1も含め各branch後に更新し、元walkとencode/decodeの全Metaを照合する。全prefixとclass、implicit branchの出現を集計する。tokenは動的limit未満に制限する。
- run/escape：初期next-use順を257種類以下の重複しないu16列として明示課金する。headを消費し、rank=0なら退役、rank>0なら残りqueueのrank位置へ再挿入する。隣接同symbol、空queue、残り長超過、非最短/過長escape、未退役symbolを拒否する。escapeはlength-256の最短LEB128をrangeの一様byteで符号化する。
- sentinel/primary/inverse BWT：last長=plain長+1、sentinel一個、primaryのsentinel、alphabet一致、LF全行一周を検査する。既存reference inverseを使用し、範囲外primary、重複/範囲外alphabet、異常run、短周期LFを有限fixtureで拒否する。
- CRC：元byteのCRC32(IEEE)をheaderへ保存し、公開する戻り値の前に照合する。stored/range両方でCRC破損を拒否する。
- deterministic/stored：空、1B、全256byte、反復、固定seed random、escape境界、既存の固定source一個(1MiB以下、引数SHA必須)をRAMで逐次実行する。元全byteとSHA-256、frame再encode一致を照合する。小入力のstored、大反復のrange、完全frame同長でstoredになる比較境界をassertする。
- recovery：各malformed拒否直後に正常frameを復号し、byte/SHAを照合する。有限検査でありOS障害・一般的な破損完全検出は主張しない。

## 固定wire形式と資源

LE header 40B: magic[8]=`ACSF 15 10 26 00`、version:u8=1、mode:u8(0 stored/1 range)、reserved:u16=0、total:u32、plain:u32、CRC32:u32、primary:u32、alphabet_count:u16、reserved:u16=0、model_bytes:u32、payload_bytes:u32。
range bodyは初期next-use順u16列、既存Packet、canonical range streamの順。storedはplainのみでprimary/alphabet/modelを0とする。
rangeがstoredの40+plain bytesより厳密に小さいときだけrangeを選ぶ。候補range自体も全caseで復号してから選択を検証する。
modelとpayloadはstoredに勝てない時点のbounded失敗をstored成功と混同せず、候補上限8MiB以内で完成させる。
header+順序+model+実payloadを合算し、Stage Aのborrowed 3079B・ideal token量を転用しない。

Denseを解放後にForest一個を作る。nodeごとのlow/high Hist/Fitを逐次解放し、逆CDFの巨大表は作らない。
保持する入力・frameは一個のcase内だけ、入力は最大1MiB。model32MiB、phase64MiB、scratch64KiBの既存枠へ実capacityを照合する。
standalone出力8MiB、source追加26KiB、candidate source64KiB、source closure350KiBの検査・実行は親の登録済みstorage入口が担当する。
実装担当はcompile/nativeを実行しない。親側のnative検証は登録済みstorage入口から実行し、結果を以下へ記録する。速度・7-Zip優位性は測らない。

## 実行結果（2026-10-16 JST）

- 登録済みrun `21a721bd5d064dd99f3902efb3aa7504` はexit 0で完了。入力はCanterbury `ptt5` 513,216 bytes、SHA-256 `0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650`。
- Rust 1.98.1 MSVC native compile後、9ケース、28件のmalformed拒否、各拒否直後の同一process復旧28件を通過。全caseでbyte/SHA、frame再encode、全Metaを照合した。全体source closure 112,324 bytes、candidate source 63,777 bytes。
- `ptt5` はrange modeを選択。40B header・next-use順序・model・終端込みpayloadのcandidate合計50,592 bytesで、stored合計513,256 bytesより小さい。単一候補のformat screenであり、7-Zip比較・速度・メモリ優位性は示さない。
- recovery ZIP 603,374 bytes、SHA-256 `6437f802614a3da38b1a91a9a6224e7d9a7f8f41a29907c8f94369c130ddfc27`。内包`report.json` SHA-256 `08cd6ff44624d0ababced4ef22734ffe699dbf5c9b9fcc30dbe0585b3130c85b`。Prunlet清掃完了、Temp作業先なし。

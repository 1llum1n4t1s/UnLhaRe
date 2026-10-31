# all-class-frame failure-first

PLAN二件・static RESULT・nested AGENTS全文を確認。新5filesだけを所有し、全frozen sourceを直接参照する。stst正常finite／異常adversarialのRAM E2Eをコードより先に固定する。追加研究・設定探索・ユニット追加を行わない。

| 分類 | 失敗条件と直接検査 |
| --- | --- |
| happy/boundary | empty/1byte/all256/repeat/skew/seeded random、1MiB直前/一致/超過。元byte直接一致。storedとcompressed両経路をassert |
| type/boundary | 新magic/rev/method/flags/reserved/長/primary/alphabet/table/model/range終端/CRC不正を拒否。超過raw宣言はallocation前拒否、加算checked |
| state | 各異常後の同process正常復帰。外部model/state/dictionary/IOなし |
| semantic | alphabetは最初の出現順のu16LE、sentinel1回、active先頭symbol→rank/run→remove/insertを一致。k1含む全history更新、branch上限、最短varint、remaining、oneLFcycle |
| resource | MAX_INPUT=1MiB、正常finite累計4MiB以内（phaseA32KiB制約は適用しない）、逐次解放。異常32以内。codec64MiB/scratch64KiB/OS各160MiB、全capacityと同時寿命を記録 |
| fallback | 実alphabet+model+payloadがstored以上ならstored。range出力上限だけは非利益fallback、一般error/panicを握り潰さない。method1 body>=rawは非正準拒否 |

headerはKHC1BLK NUL/40B/rev1。CRC32は認証ではない。tree選択floatはencoderのみ、decoderはwire整数CDF。既存paid/tree/codebook/packet/packed23/multi_rangeを直接参照。teacher/未native leaf/poolを実行しない。新codec/probe/finite/adversarialは新規記述でstructural frozen copyは行わない（既存API利用のみ）。payload/frame/input/trace disk保存0。

worker compile/native/Git/外部/削除/download/依存/version/追加委任0。native分類(test defect/environment/product defect reproduced)は親の初回実行まで未検証。固定rustfmt非書込と5SHA/mtime/bytesでREADY編集STOP。親がrunner/verifier/spec/product接続を所有する。

## capacity上界の由来と有限計数

SA-ISは各level nの主配列text4n/types n/SA4n/LMS2n/names2n/reduced2n/ordered2nと桶3配列、縮小n/2の幾何和を保守的40*(raw+1)+8MiBとする。Front形成時last2n+run容量（実capacity*12）もこの上界以下。モデルphaseは実Front/Dense/Hist pair/Fit pair/最大作業packet/Forest/parse transient/range上限/最終frameを保守的に合算し4MiB余裕を加える。Treeの2組は各nodes容量256以下・各edge4以下でheap上界64KiB以内、この余裕に含む。codec局所stack/recursion上界32KiB、probeのretained report capacityをscratchへ追加し64KiB以内とする。caller入力chunk容量もcodec外寿命として追加する。decoderはframe+Forest+reader/Dispatch+last u16+packed words u32+出力byteを実capacity課金し1MiB余裕を加算。

finite入力9正常+1超過は累計3170561B（4MiB以内）。異常30は独立uniform packet/payloadの新規構築、BWT/Fit実行0。正常witness→各異常理由→同process正常元byte復帰を検査し計61decode call。CRC resealはCRC欠陥自体の例を除いて意味拒否を観測する。payloadの最終bit不正はrange finish、非最短varintは正準性、sentinel-first lastはLF self-cycleに到達する。stored canonical fieldsとmethod1 body>=rawも直接拒否する。現sourceはすべて新規記述（既存の構造体全文コピーなし）、従って旧sourceへの逆ledgerは不要。凍結依存はpath参照のみで同一wire fee/grammarを維持する。

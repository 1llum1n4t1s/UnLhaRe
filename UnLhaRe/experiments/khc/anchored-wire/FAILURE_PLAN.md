# CRC付きanchor wire：コード前有限契約

親PLAN SHA175E11A041EB85B415A02194F32AD695E8174663A647706D4CB8D68203F0AE81読了。原Model/CTS/math/pool/payload/grammar/CRC算術を維持。旧codecから可逆allowlistだけで新KHQCHA01へ接続。旧inverse本体を削除し凍結anchored::inverseへ置換、原旧decoderの実体は新codecに残さない。新SA BWTを直接参照、entropyLUT/exp-scaleなし。以下全未実行、compile1/native3は親だけ。

## normal / 元malformed / 境界

元正常14で全plain/各typedProof14/全再encode frame/entropybits直接一致、元short-depth-header4維持。元malformed34の名前・原因・strict reasonを維持。ただし lf_cycle の旧 `LF cycle inconsistent` は新packed24-fallbackの `LF early primary cycle` へ変化する（n2 last[0,1],primary0は1歩でprimary再訪、変更されたinverseによる同じ拒否）。depth5のみ、旧原34に新namedを混ぜて数を膨らませない。

新正常境界2はinput6/7B（transform n7/8）、empty/32B metadata・header_lenとCRC保護を検査し、全plain/Proof14/再frame一致。全原normalのdeclared nからanchor0/32を決め、正準packed alphabetと全metadata parseを確認。

## 新named拒否10＋相互magic1

各namedの予定guardまで届く正準frame、validCRCが必要なら両CRC修復後にstrict reason比較。各10拒否直後にsame-process正常tiny復元1、合計10recovery。

| Name | strict reason |
| --- | --- |
| old_hardcut_magic | bad frame magic/header |
| anchor_crc_bitflip | header CRC mismatch |
| anchor_row_range | anchor row range |
| anchor0_mismatch | anchor0 primary |
| anchor_duplicate | duplicate anchor |
| anchor_endpoint | anchor segment endpoint |
| anchor_cycle72 | LF early primary cycle |
| anchor_metadata_missing | packed header length outside bounds |
| anchor_metadata_extra | packed header length outside bounds |
| fallback_metadata_extra | packed alphabet rank byte width not canonical |

row/anchor0/duplicateは正常n16のmetadataを変更しheaderCRC修復。endpointは正常n16 all-zeroのanchor1/2を交換してunique/range/anchor0合法のまま末尾不一致まで到達。n72 last=[1×7,0,1×64],primary7,anchor=[7,0,1,2,3,4,5,6]はpayloadを正常modelでencodeし正準alphabet/validheaderCRC/payloadCRCでinverseへ渡す。早期primary拒否の最初のinterleave stepは固定しない。missingはn16から全32B削除、extraはfull257alphabetの最大header317に1B加算、fallbackextraはn1へ32Bを挿入。旧frame→新decoder拒否はnamedのold_hardcut_magic。別に新frame→旧decoderもstrict bad-magic拒否1。

元forgeのn>=8はprimary＋残り7unique合法row placeholderを追加し、parseの別guardでescape/range等が予定外に拒否される偽coverageを防ぐ。metadata意味検査はpayload前parse＋inverse前early-primary/全segmentendpoint。CRCだけで意味正常と主張しない。新self censusは元normal14/malformed34/short4、anchorboundary2/named10/recovery10/reverse-magic1。

## fixed・寿命・費用

固定input一read、旧/新encode各1/restore各1、fixed再encode0/validate_fixed4。旧478856と新478888、payload478571/header旧285新317、共通fields/packedalphabet/全payload直接一致。両fullplain2811006、各typedProof14 Eq、型間全Debug14一致、statsはmagic/frame/header/headerCRC/追加anchorfieldsだけ差を許し全残り直接一致。旧plainを新restore前drop、最大frame2/plain1。metadata32BはheaderCRC `[0..32]+[36..header_len]` に含む。

旧frameを保持したnewBWT source phase141598926+1048861+4096=142651883B。model/encoder/inverse/dataはactual capacity＋保守source式を別表示。各native WinAPI WS/private各160MiB、非null正値/errorなし。全source+PLAN+failure300KiB/EXE1MiB/report256KiB/output8MiB/free5GiB、compile60/native各120s。新unusedbuild khc-anchored-wire-20261004、EXE/report2filesだけ、生input/frame/plain/trace/ASM/PDB/newCargo0。

元normal149/SA59の全before-after-live/EXE/source/tools/input/PLANをpin、parserを緩和せず原prices cfgtest探索suffixだけ固定SHAで除外。3files保存後件数/allowlistを親へ中間返却、6filesREADYで編集停止/所有返却。正式速度・holdout/4native/完成公開wire/API/製品採用/7zip達成なし。Git/製品/旧証拠/他者dirty/version/x86/外部/delete/追加委任0。

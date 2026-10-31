# SA直接採取：追加LF構築・全歩行を除去

前goal turnは8-anchor逆変換の実装・実測・結果保存を完了したprogress。本turnは先行PLAN/追補、失敗契約、実装、単回compile/native、親readonlyまで完了したprogress。総合GOALはactive、固定ゲート未達、停止なし。

原SA-ISとBWT処理を保ち、既存SA→lastループで8個の対象suffixを採取する。旧LF生成と全く同じ32B metadataを返すが、追加LFtable・依存歩行・独立SA全走査を行わない。n<8はmetadata空。原serialize/parseと逆変換は凍結参照を直接再利用する。

## 実装・契約

- suffix SA位置 `(n−i*(n/8))%n` から対応rowを採取。欠損・重複・範囲外を拒否し、q0除算なし。stackは8 Option<usize>と8usize、metadata以外の新heap割当なし。
- 原SA-ISprefixは全文一致。signature、stack初期化、loop内採取、metadata返却の4置換と固定helper末尾除去で原BWT全sourceへ復元できる。親readonlyでも独立に全文復元確認。
- tiny92：旧/新BWT各92、last全文・primary・metadata全byte一致、独立suffix sort92・SA対応512、原reference/packed24/anchored全plain入力一致。fallback28/全余り8。
- selector q0-safe28、target採取152/照合152/roundtrip19（最大n8388609を含む人工selector）、非対象1、拒否8/stack不変5、原/新oversized拒否2、同process正常復帰1。巨大forward BWTやOSOOMは未実行。旧decoder1793列挙等を今回再実行したとは呼ばず、旧成果物/pinsを保持。

## 内部計時：生成費用を無料にしない

固定input2811006B一read、old=BWT＋LFmetadata生成、new=BWT＋SAmetadata採取。each warm1後9round AB/BA、18calls全保存。各pairでlast・primary・32Bmetadata全要素直接比較、最後の全plain2811006Bも入力へ一致。

| pipeline | old | new |
| --- | ---: | ---: |
| 全9回中央値 | 167.2463ms | 133.6980ms |
| AB 5回中央値 | 167.2463ms | 133.6980ms |
| BA 4回中央値 | 171.6117ms | 134.0673ms |

全中央値約20.06%短縮。今回の旧BWT中央値126.2160ms、旧LF生成42.7331ms。前候補の旧LF単回70.6117msを今回の同条件値として合算しない。新BWTの採取負荷はtotalへ含まれ、独立した生成timerを0と偽らない。旧total−旧BWT−LFは各rawで300..900nsのtimer bookkeepingとして保存。

alphabet準備は一回0.5518msを別記録・pipeline計時外。prepared全要素をwarmupの旧lastから求めたalphabetと直接比較、最終復元用scanも別fieldで記録。alphabetを既に持つcodec境界の局所比較であり、準備が無料とも完成codec速度とも主張しない。比較・caller解放は計時外、関数内SA/text/scratch解放は計時内。CPU quiet未確認なので正式性能・安定改善・7-Zip超え・採用の証拠ではない。

## リソース・再現

- 実peak WS60968960B/private57290752B、両160MiB以内。old/new相手last保持中のBWTphase147225100B、LFphase29497526B、restorephase26682390Bはcapacity込みsource推定（quota保証ではない）。
- compile1/native1、全3children exit0。Rust9source/8edges/44128B、PLAN+追補+failure込み54101B、49unique pins。
- 出力EXE277504B＋report55959B=333463B（約326KiB）、2filesだけ。新Cargo/ASM/PDB/input/plain/frame/rawtraceコピーなし。readonly時free40571011072B（約37.8GiB）、8MiB予算・5GiB最小残量を確認。削除なし。
- report SHA `A4C1128B0092FC89D20D419AF87059ADCF607F76E989262396E41B5F0AD8DAAE`
- EXE SHA `27050B585AD48BE4CB53B4AB7B6504172091EE8A28FE9D973AD5D6B201D88657`
- runner SHA `CE793167F5894284F3F8D6B058CF5D30D1A070343CAC0402B44C58E6E9A0E3D8`
- 親readonly SHA `058B434F360E88FC0DE8107C21B78C24AE0BC229ADE1C9E5B74F272BF4311EC7`：単回exit0、59before/after/live組、raw native1、18計時の全中央値/順序別値再計算、有限契約/全plain/capacity式/両peak/原BWT全文復元/output形状確認。追加compile/native0。

opopの全観点は原PLANの限定範囲で親が担当。Performanceは旧LF追加仕事の除去と内部差、Hardening/Testerは上記有限拒否/復帰/E2E成功、Normalizerは原serializer/parser参照、Cleaner/Modernizerは旧証拠・依存・原SAを維持、Asyncは明示解放・pin finallyを確認。Intel/Startupは非該当。実装は既存workerを再利用し5file所有を限定、親はPLAN/追補/readonly/RESULT/台帳のみ。要求構成と今回toolに未表示の実効モデル設定を同一視しない。

## 次の判断

8-anchor方式は生成面の負荷を減らせたが、実CRC付きframeへ未接続、現状の約2秒payload処理は解決していない。CRC保護/新magic/全payload直接一致/破損metadata拒否を満たすprivate wire接続と、payload予測の構造的な仕事削減は別工程。小さな数値同値micro改善だけを全goalへ代用しない。正式CLI size/encode/decode、quiet/holdout、API、4nativeの全ゲートは未達。製品dirty20files・Git・version・依存・x86・外部変更なし。

# minor頻度診断の独立監査と採否条件

読み取り専用担当 temporal_paid_model_audit は root-history-order の model.rs、bundle.rs、e2e.rs、RESULT_20261005.md、保存reportの5資料だけを調査。編集・compile・native・Git・外部・削除0。親は計画の費用式へ統合した。実装担当とは別担当。実際のエンコード、復号、teacher状態、全CLI速度はこの監査では検証していない。

## 確定費用と最も強い反証

旧実費screen484612Bは483599Bへ1013B不足。token478603Bとside3079Bは変更せず、metadata1917B以下が必要。保存葉uniform62、pure76、compact993について mode compact0 / pure10 / uniform11 の固定prefixは993bitだけ削減する。元payload23405bitから22412bitへ短縮するが、raw minor形式はflag1B＋長4B＋ceil(22412/8)=2807Bで届かない。

minor hist h、総数N、Huffman長lを計測した場合に限り、候補費用は `1+4+128+ceil((22412-8*N+sum(h*l))/8)` B。128Bは256長nibble、flag・長・paddingを全課金する。1917B以下には minor削減8140bit以上が必要。Nの既存構造による範囲2084..2217は実測ではなく、histは不明。一様256binなら平均長8bitなので table分だけ悪化する。generic byte圧縮で1013B削減できるという根拠もない。

## 固定一候補

通常Huffmanを(weight,minsymbol,id)で決定的に構築。最大511node、最大長15、空はraw、singleton長1、長15超はraw fallback。新DP選択・木変更・近似変更・precision sweepはしない。費用は有効候補とrawの最小値だけを推定し、実codecであるとは表示しない。費用条件を満たした場合だけ次段で実typed metadata coder、原typed fields逐次一致、全854016CDFの復元比較へ進む。

## メモリと失敗時契約

既存RAM packetを一回parseし、u32 hist256=1024B、長256、小scalarだけ保持。生minor列・packetコピー・入力複製は保存しない。Huffman一時域16KiB以下をreport前に破棄。旧scratch64940Bに無条件で追加しない。node JSON容量35000から32000へ縮小し、retained structの実sizeofを算入、scratch65536・model32MiB・phase64MiB・OS各160MiBを別々に確認。

先行failure planはempty/singleton/一様/偏り/長15超/weight上限/overflow、元packetの全mode・k2/3/4・order・depth・index・trunc・padding・余剰・回復を含む。未実装Huffman decoderの拒否検証済みとは主張しない。将来の実decoderではflag、oversubscribed/incomplete表、未登録symbol、trunc、正確bit長、padding、trailingを別に検証する。

## 観点台帳

| 観点 | 担当・結論 |
| --- | --- |
| Performance | 独立担当＋親：256bin実測を採用、サイズ改善そのものは証拠不足 |
| Hardening | 独立担当＋親：checked数値・strict parser・有界RAMを診断契約へ |
| Tester | 独立担当＋親：failure-first有限E2E、旧全CDF/Meta証明を維持 |
| Normalizer | 親：既存packet grammarを直接参照、費用表現を一式へ統一 |
| Cleaner | 親：raw trace・複製・無制限sweepを追加しない、既存証拠は保持 |
| Modernizer | 親：runtime/依存更新不要、公開API変更なし |
| Async | 親：一時Huffman作業域とreport保持の非重複を検証対象へ |
| Intel / Startup | 非該当：現在の外部仕様・製品起動/配布変更なし |

全GOALはactive。サイズscreen診断を実frame・速度・holdout・API・4環境native達成へ置換しない。

# ファイル境界を跨ぐ1MiB packing：2構成とも不採用

2026-10-06 JST。現public rlib SHA94A19BFD6C0AFD23D7C0453760C51B596D9BFA2C7CBE983BBFA15F6111572AC4、全11 Canterbury development本文2810784B、現codec/モデル/1MiB上限を固定。Mdl/BinaryAdaptive各blockで全byte復元、両実行で空/1B/all256の6正常往復も成功。入力・ソース・コンパイラ・依存・EXE全pinの終了一致。これはサイズと機能の有限診断で、性能測定でも実native solid書庫でもない。高CPU下の時間は速度優位に使わない。

## 実frameサイズ

| 構成 | blocks | Mdl B | BinaryAdaptive B | 仮想container下限B / 別予約込みB |
| --- | ---: | ---: | ---: | ---: |
| manifest順に全11本文を詰める | 3 | 513252 | 577698 | 412 / 668 |
| 既存90%ASCII規則でtext8/binary3へ安定分割し群末尾flush | 4 | 506649 | 476676 | 416 / 672 |

現entry独立frame465951B/native466395Bに対しどちらも増加。2群構成のAdaptive+予約費477348Bは、native7z481490Bに対する5%上限457415Bを19933B上回る。実nativeサイズは未実装なので、477348Bはあくまで費用見積り。最低費を使っても失格で、費用予約の調整で合格へ変えない。

| 2群block | raw B | Mdl B | Adaptive B |
| --- | ---: | ---: | ---: |
| text1 | 1048576 | 301254 | 301254 |
| text2 | 181008 | 59565 | 59565 |
| binary1 | 1048576 | 80870 | 47679 |
| binary2 | 532624 | 64960 | 68178 |

text合計360819Bは現8MDL350458Bから10361B増加。binaryでblockごとの小さい実frameを後知恵で選んでも112639B、全体473458Bになり現465951Bを7507B上回る。この後知恵の最小和は、選択器の速度・実統合の証拠ではないが、この2群packingに既存2strategyの選択だけを足してもサイズ条件が満たせない反証にはなる。分類の閾値/順序/ブロック長をsweepせず、当該構成は打ち切る。BWT/context modelの異種混合を単純solid化で改善できるという仮説は、この入力・構成では成立しなかった。

## 資源・再現

| build配下 | report SHA256 | EXE SHA256 |
| --- | --- | --- |
| khc-solid-size-a-20261006 | D8B805197395B7550F8168670F379CC38C7C574D856D04EC3279D8A5BAA518BE | CD47B61905BCD956168D9F8FD0CC379B2606120F8292A2B22E8D9ED2EAB16DBE |
| khc-solid-class-size-a-20261006 | 84A6F77D5E820678B54E56EA83E5B15311E89610E31D5EF691C846515ADCD49F | 1B28FBD7088C4F8536BFB478503D934B933327AB7C2E1B8D79C864DC4B59E5D8 |

EXE1051136/1053696B、report13236/13411B。compiler観測max private217997312B/WS267198464B（初回）、初回child観測private28839936B/WS30507008B、2群child28180480B/31469568B。各child60秒・RAM/出力guard内、timeout0/stderr0、raw/encoded/plain data disk0。debug0+/DEBUG:NONEでPDBなし。再実行はsolid_size.ps1 / solid_class_size.ps1 -Attempt <未使用名>、保持物への上書き不可。ライブラリ現buildを利用し、製品Cargo/full build/4nativeは再実行していない。各sourceのfmt checkとPS Parser、scope diff --check成功。

今回rANSとsolid診断の8 build root保持合計3551780B（約3.39MiB）、ソースは結果追記前228205B。Cargo6163555929Bで増加0、固定cap6175228536B/残11672607B維持、最後の空き54245556224B。今ターンのPDB清掃1282048Bの元/$R/$I不在・既存bin不変はRESULTと共通ledgerに保存。候補source/EXE/report/input/共有cache/x86削除0、関連子process0。

## 次工程

現lz.rs:163は最長一致を選び、:172以降でflag/rep/距離/長さを符号化する。符号長は選択基準に入っていない。したがって、同じ候補探索上限を保ちつつ短いrecent-distance一致と長いnew-distance一致の実bit費用を比較する余地は、独立したローカル仮説として残る。旧lazyは別既試行なので再演せず、次は有限lookaheadの費用感応parseが現greedyより有望かを、旧試作・同点/モデル更新・decoderの全契約と突き合わせる。まだ実装・圧縮率改善・独自性は証明していない。MDLのtoken/run支配が消えたとも言わない。

全archive/真正未見/7-Zip公平総合優位・Zstd・最新研究/量子区分・独自性・実統合・4nativeの元GOALは未達。GOAL active、率5%/速度10%等のゲートは変更しない。

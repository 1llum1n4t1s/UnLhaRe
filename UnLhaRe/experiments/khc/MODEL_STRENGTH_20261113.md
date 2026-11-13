# LHCのモデル強化調査（2026-11-13）

[見直したゲート](GOAL_GATE_20261113.md)で、未見のCalgaryではLHCのサイズが7-Zip solidより0.64%大きかった。合格（7-Zipの0.95倍、808,010B以下）には約48KBの削減が要る。どのfileでどの種類のモデルが不足しているかを、7-Zipの各設定とのfile単位比較で調べた。測定は `D:\tmp\lhc-perf` の作業用ハーネス（`refs.ts` / `ppmd.ts` / `ppmdspeed.ts`）による方向決めの測定で、正式比較ではない。

## file単位の比較（LHC portfolioのframe合計と、7-Zip各設定の単独書庫）

| 合計 | Calgary 18file | Canterbury 11file |
| --- | ---: | ---: |
| LHC portfolio | 855,374 | 449,865 |
| 7-Zip LZMA2 mx9 | 884,474 | 493,169 |
| 7-Zip PPMd o32/256MB | 810,179 | 575,290 |
| 7-Zip BCJ+LZMA2 | 885,347 | 494,117 |
| file別に7-Zip最良 | 787,484 | 432,811 |
| file別にLHCと7-Zipの最良 | 787,325 | 429,174 |

- **テキストはPPM系が強い**。両集合の全テキストでPPMdがLHCより4〜15%小さい（book1 213,162対230,214、alice29 38,972対43,267、progl 13,488対15,800）。現行のBWT系MDLは、文脈を直接持つPPM系より弱い。
- **小さいfileとバイナリはLZMAが強い**。obj2 61,447対76,384、sum 9,513対11,868、geo 53,458対57,642。MDLはモデル表の最小約241Bの固定費があり、小さいfileで不利。BCJはCalgaryの実行コード（VAX・68000）に効かない。
- **LHCが勝つのは空間・記録モデルの得意なfile**（kennedy.xls、ptt5／pic）。

## PPMの次数・メモリとサイズ（Calgaryテキスト13file、7-Zip PPMd、file単位合計）

| 設定 | 合計 | LHC比 | 展開時間の合計（起動13回込み） |
| --- | ---: | ---: | ---: |
| LHC portfolio | 653,501 | — | — |
| o4 / 16MB | 610,607 | −42.9KB | 471ms |
| o6 / 16MB | 586,677 | −66.8KB | 561ms |
| o8 / 32MB | 584,765 | −68.7KB | 586ms |
| o16 / 64MB | 595,027 | −58.5KB | 638ms |
| o32 / 256MB | 606,695 | −46.8KB | 654ms |

order 6〜8・16〜32MBが最良で、64MiB codec gate内に収まる。この候補をportfolioへ加えるだけで、Calgary全体は約786.7KB（808,010B以下）に届く見込み。過去の「全byte PPM」（2026-09-26、653,422B、文脈上限131,072の簡易実装）は、PPMII（SEE・情報継承・メモリ再構築）を持つPPMdとは別物で、今回の結果と矛盾しない。

## 復号速度の見積もり（Windows x64、7-Zip、1スレッド、起動費を差し引き）

book1（768,771B）の展開は、PPMd o8が約79ms（約10MB/s）、LZMA2が約7ms。現行LHC MDLの復号は同規模で約28ms（`lhc_block_bench`の実測から推定）。PPM系はテキストの復号を約3倍遅くする。4worker並列なら最長blockが律速で、Calgaryの復号予算（7-Zipの2倍、約107ms）にほぼ収まる見込みだが、余裕は小さい。

## 推奨する次の作業

1. **PPMII系テキスト候補（新revision）**：PPMd var.H（PPMII）相当をRustで独自に実装し、order 6〜8・メモリ16〜32MBでportfolioの候補へ加える。参照実装はLZMA SDKのPpmd7（public domain）。単一blockで完結し、既存の1MiB block・並列処理・CRC・no-replace公開をそのまま使う。利得の見込みはCalgaryで約−69KB、Canterburyのテキストで約−17KB。
2. **LZMA級のLZ候補（その次）**：最適パースとrep matchを持つLZで、小さいfile・バイナリを補う。見込みはCalgaryで約−21KB（obj2、geo、trans、obj1）。
3. 復号時間が予算を超える場合は、サイズ差が小さいときにPPMを選ばない費用込みの選択や、大きいテキストblockの分割を検討する。

## 実装結果（2026-11-13）

推奨1をrevision 11（`portfolio-ppm-trial`、frame `LPM1BLK`）として実装した。Calgaryのframe合計は855,374Bから775,746B（order 6）、Canterburyは449,865Bから415,210Bへ減り、見込み（約786.7KB）を上回った。PPMはテキストだけでなくobj2（76,384→68,064B）やgeoでも既存候補に勝った。復号速度と判定は[ゲート](GOAL_GATE_20261113.md#2026-11-13-ppmii系テキスト候補revision-11portfolio-ppm-trial)を参照。


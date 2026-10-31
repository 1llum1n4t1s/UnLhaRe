# 第二段階：コストの高い短いmatchと先読みを比較

2026-10-05。第一段階の全11file screenでkennedy約41%削減、全体oracle459301 B（7.17%削減）となり事前継続条件を満たした。ただしLZ3全体573773 Bは現KHC494786 Bより悪く、選択費用を払った実経路や製品統合・7-Zipゲートはまだ未達。

別example/EXE/outputで第一段階を凍結保持する。新試作は同一token表現のまま探索128候補、最低match4、1byte lazy（次位置の最長matchが現在より2以上長ければliteral）へ変更する。先読み時に現位置をhash chainへ一度だけ登録し、後の登録をat+1から行う。comparison総上限64*raw、raw1MiB/length4096/整数model/全CRC/range検査/stored fallbackは同じ。符号化方針の比較であり、新圧縮原理ではない。experimental magicはKHLZQ1\0\0で第一段階と明確に分ける。

失敗候補：重複登録でchain自己循環、未確定未来を参照、literalへ戻った後のchain更新欠落、budget消費二重/超過、境界tailでlookahead範囲越え、短match抑制で大きい率悪化、先読みCPU増幅、既存自己復元/破損/相互状態回復の失敗。候補ポインタは常に現在より過去、全comparisonを共有counterで課金。

新56vector/2context有限E2E、同じ11file全体screenと56vector腐敗拒否を実施（新unitなし）。継続は第一段階に対し単独LZ総サイズ3%以上削減かつkennedyの最良サイズ悪化1%以内、RAM/完全復元成功。未達ならこの修正候補は採用しない。GOAL_GATE/初段基準を変更しない。両段oracleと実試行費用を別に記録。

追加使用量：第一段階build後Cargo6125807058 B、baseline差219013978 B/256MiB、残49421478 B。新exampleとclippyに16MiB以内、専用output8MiB/JSON256KiB、raw/frame disk0、free5GiB以上。旧source/EXE/reportを変更せず、新target-dir/依存/download/削除/Git/外部公開なし。親が全編集所有。

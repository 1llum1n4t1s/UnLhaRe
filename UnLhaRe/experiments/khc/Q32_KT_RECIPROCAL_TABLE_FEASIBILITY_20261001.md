# KT小分母の厳密商テーブル：実装前条件

KT register形状の専用化は既にcompilerが行っていたため打ち切った。次の仮説はdivl自体を小分母だけhigh-multiplyへ置換すること。近似モデル・wire変更ではなく、元floor商を厳密に復元する候補である。まだ実装・採用しない。

## 数学

Q=2^32、B=2^64、検査済み非等カウントKTのd=total+1>=2、n=Q*zero+Q/2<B。d<=65536の場合だけR=ceil(B/d)を一つのu64表へ保存できる（d=1のRはu64外なので対象外）。

B/d<=R<B/d+1より、n/d<=nR/B<n/d+1（n<B）。qhat=floor(nR/B)はfloor(n/d)かそれ+1。qhat*d>nならqhatを1減らし、そうでなければ保持する。これでfloor(n/d)と完全一致する。KTではfloor(n/d)<Q、qhat<=Q、d<=65536なのでqhat*d<=2^48で補正積もu64内。high productはRust u128積の上位64bitから取り、f64推定・逆数近似へ変えない。

65537個のu64表は524296B。Model所有としglobal/cache共有やNode layout増加を避ける。表の構築時間・割当・lookup・追加分岐・cache汚染は全CLI比較に含める。大分母は既存native32/forcedportable経路へfallbackする。CAP/checked counts/equal shortcut/error順は元仕様を保持する。

## 先に必要な反証

- 実固定groupで、実際に商計算するKTのd分布をdiagnostic cfgで数える。固定binsはd<=63、<=255、<=4095、<=65536、それより大きい。equal-count shortcutをhitへ含めない。size/frame/復号/通常source対応/件数決定性をE2Eへ含める。人工numeric dataset割合を実書庫hit率として使わない。
- 分布がlookup適用の仮説を支持しても速度とは呼ばない。表構築と高位積+補正が現CPUのdivlより速いかは独立に必要。
- 実装する場合は2..65536の全分母・zero境界/中間・補正境界、旧KT65536/Model11267の独立BigInteger expected、通常/forcedportable opt2/3をCLI全byte照合する。商の数学証明をerror/publication/layout/codec検証の代わりにしない。
- codecの全frame・復号・代表破損・no-clobber成功後に、同session quiet/fullCLI/fixed gateで判定。追加div等で悪化・gate未達なら不採用。現在CPU41%失敗試行のwarmup値は比較に使わない。

本案はKTのみ。posterior/Bayes/BWT/primary/文法/深さを同時に変更せず、速度/メモリ/holdout/4native/製品統合/総合7-Zip超えの未達を維持する。

# 履歴の十分条件によるmemo census（2026-10-07、実装前）

full10bit×3 keyのcensus-aは全token1109008、possible hit213637=19.2638%、hit_paid217542/2021264=10.7627%。原案そのままの1.5MiB cacheをcodecへ入れない。cache容量/hash係数のsweepはせず、CDFに影響しないhistoryを区別していた可能性だけを厳密に調べる。
paid_model parserは4-way history tree、split深さdの判定bits=3<<(2d)、root high flagなら2bitpair順を反転する。default/leaf-onlyはmask0。既存1024行の恒定CDF判定ならdescriptor maskも0にできる。privateコピーのparser中にk別syntax依存maskを捕捉し、追加のdense CDF全行比較はしない。maskは最小ではなく安全な上界。
componentとtoken support Nごとに、lo<Nの到達可能nodeとそのprefix k>=2のmaskをgrammar classへORする。class0はrootだけで1訪問、class1はlo4/lo32の最大2訪問、class2はdepth8以内。開始maskはclass0そのまま、class1はm|m>>2、class2はm|m>>2|m>>4|m>>6|m>>8。k1もhistory更新するが確率依存はない。右閉包なしのkeyは不正なので使わない。
同じmasked-start/key・leafのhitで、old historyの終了値をそのまま代入しない。各classの訪問数vとzero開始childsuffix（10bit）をu16×3へ保存し、実startからv>=5ならsuffix、それ以外は((start<<(2v))|suffix)&1023へ変換して終了historyと照合する。枠は元24B cellを維持する。forest/N別mask tableは3096B、private decoderのroot masks1704B、管理scratchを含め64MiB予約へ追加課金する。
失敗先行：depth5超split/高順反転/既存default/constant/mixedCDF、mask未知bit・N/c上限、token内同class再訪、k1脱落、shift16 panic、hidden bitsのposthistory欠落、masked keyの誤hit/別CDF衝突、別forest共有、source/wire/raw/CRCの差異、alloc上限/OOM/timeout。新unit testなし。driver有限契約＋全11saved frame/public/source全byteを維持し、private decode中はskipしない。syntactic global perN masksによるpossible hit率は実速度ではない。
旧census-a/source/reportを変更しない。新private paid_model/packet/block/memoコピーを用い、native未変更。copyは新ファイルなのでuser sourceを上書きしない。新専用output8MiB/report64KiB（compiler一時物込み）、compiler512MiB/60s、child64MiB/60s、suite300s、CPU15%/quiet60s、free5GiB+8MiB、Cargo増分0/dependencydownload0/raw/frame/trace0。同じ65536cell×24Bだけを使用。率の結果から最終採用を宣言しない。語義上の改善が観察できなければcache案を打切り、別方式を選ぶ。


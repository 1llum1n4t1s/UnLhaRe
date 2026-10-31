# 次の構造問い：学習済みbranch-historyの小さい静的モデル

## この問いを選ぶ根拠と限界

convex-envelopeの新診断は未来tokenを知る最大expert選択でも理想token506840B。固定flat四expertの凸重み調整だけは主経路にしない。独立analystと親のコード照合では、実float CTSとの三差はnode別条件付け/重み、class別直近5childの深さ混合、log-linear積混合。どれが必要な情報量を供給するかの単独寄与はまだ未測定。

新たに検討するのは、branch grammarとclass別child履歴を残し、前処理でtrained分布を小さいcontext treeへMDL剪定して保存する方式。decode時にCTS posteriorやpool log/exp/gradientを再計算しない構造であり、static-direct-mdlのflat token/symbol/recent/joint集計や、online prior強度変更とは別。成功を予測した案ではなく、必要size＋headerを一設定で反証する候補。過去の局所CTS/inverse/単一suffix/flat prior調整は再開しない。

## 未実装の候補仕様

既存quaternary Treeのcomponent/class/childと合法prefixをそのまま観測し、class6×prefix2..4×直近child履歴（最大5個、4分岐）の各深さ0..5で四child histogramを構築する。prefix1は符号量0だがchild0の履歴更新は省かない。branchごとにclass履歴を更新する順序を既存CTSと照合する。

各context nodeの固定Q32768 leaf CDFはinteger Hamilton＋合法child最小2、zero childも支持する。nodeをleafにするloss＋1bit tag＋(prefix-1)*15bitのCDF保存費用と、splitにする1bit tag＋4children費用を比較し、depth5まで一意なtie policyで剪定する。CDF leaf/split treeを実際にbit serialize/parseし費用を全byteへ照合してからsizeを判定する。空prefix群/未観測historyの意味とfallbackはコード前に確定する。

decoderは保存treeをclass/prefix/history→leaf CDF lookupへ展開できる。固定6×3×1024dispatchのRAMと、CDF/slot/branch updateの仕事量を別に予算化する。表保存費用を無料にせず、tree枝を辿るgrammarも省かない。二pass training/encodeと一pass decode、BWT/inverse/coderを含む全速度は依然必要で、MDL size成功だけで574.5624/47.3884msへ届くとは言わない。

## 次の実装前に必要な確認

- 既往に同じbranch/class/prefix/history-trained MDLモデルがないか指定記録/実コードで確認する。
- 全branchの独立walkを作り、既存class totals[889227,620240,1216305,889227,64372,145969]とbranches[2725772,1099568]、grammar/escape/runを照合する。初期historyとnode classの意味を固定する。
- prefix別CDF、tag/15bit字段、MAX depth/未観測分岐、overflow/拒否/roundtripを先行failure planで定義する。metadata最悪値、working phase/出力8MiB/RAM160MiBを算術確認する。
- source/outputを新rootへ限定し、旧root/製品/wire/依存/版/Git/x86を変更しない。必要loss＋実model bytes＋framing/escape/reserveが483599Bを超えたらcoder/速度/深さ・精度sweepへ進まない。

まだ実装・圧縮率/速度改善の証拠はなく、保存済みの次の問いに留まる。総合goalは完成書庫/API/独立holdout/category/同資源/4nativeまで未達/active。

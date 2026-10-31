# 因果hard-cut：固定入力の一次評価通過

親の単一実行はWindows x64でexit0、compile1/native1。原Model/pool/math/pricesの数値式は変更せず、private primaryを全6階層soft mixtureから過去のcached cutで選ぶ1階層KTへ交換した別アルゴリズム。原モデルとの数値同値は要求しない。

正常160events・全1318590node直接比較・価格16384件・確率640件成功。拒否15件で全state不変、depth拒否3件、CAPexact正常1件。固定入力2811006B、一read/BWT一回/Front一walk、3825340枝、14305969合法intervalと28611938端点selectを検査。actual CDF lossの独立集計とModel auditのu64 bitsは4705461279319865477で一致。

実pool loss3821620.7048102045 bits、ceil token477703B＋side3079B＝screen480782B。固定483599B基準との差2817B。これは必要条件のloss-only screenであり、実frame長・復元・速度の成功ではない。旧float teacher loss3820764.1727890265に対して856.532020 bits増だが、教師との差を採用gateへ追加していない。終端best Q8・実選択price Q8・選択KT loss・pool lossは別fieldで保存、regret保証なし。

実NodeState40B/8190node、primary capacity327664B。model構造見積21496336B/fixedphase42453670B、private base Vec容量は未測定。WinAPI実peakWS55455744B/private51589120B、各160MiB以内。TLS集計は単一固定Model限定で診断overheadあり、性能には流用しない。

生成物はEXE383488Bとreport81487Bだけ、計464975B。終了時owned process0。readonly verifier一回exit0で105 before/after/live identity組、EXE、raw stdout projection、全Meta/count/loss/サイズ/両peakを再照合。追加compile/native0、最終free62302994432B。削除0/共有cache不変、製品20dirty/version/x86/Git不変。

- report SHA E4CC334310A4426EB9F83E68D9D95D6421747723BCEE2A3F01C29CD346E4B9A0
- EXE SHA 59E3EB93CDCA68A7DAB61D774FF6C068D1742CAC8897195B96A2900CE3F36035
- runner SHA AD0A4CEDF48E61447200AFE0D6563BDFAD32ADA441D456756239A2644F6F5DE9
- readonly verifier SHA 5566BBAD26A2485280343086A79F3C3BCE66A0FE7406A97EC26BB84A3B3AA7CA
- Rust closure19sources/18edges/85361B。原prices cfg(test)末尾1064Bはgraph探索からだけ除外し、コンパイルは原source全bytesのままcfg(test)OFF。Source helper全文allowlist残差0。

再照合：bundled pwshで `-NoProfile -File UnLhaRe/experiments/khc/causal-hard-cut/verify-readonly.ps1`。run-native.ps1はunused rootを必要とする単回生成入口であり、保存済みrootへ再実行しない。

次は新private magicを持つ実frame encode→decode→全plain直接比較→Proof14全field一致。既存codecの数値処理を変更しない接続可能性は確認済みだが、new Node aliasと新magic/pathだけのallowlistが必要。実装前に正常・破損frame E2Eを固定する。全CLI速度574.5624/47.3884ms、warm1+9/quiet/same resource、holdout/category、完成書庫/API/4nativeは未達、総合GOAL active。既存の停止記録を再適用しない。

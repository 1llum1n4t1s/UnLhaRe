# 遅延エラー候補：通常private wire確認

前工程は計測付きbinaryで両方向68853924calls/1147565400B要求減、全frame478856B直接一致、全plain/typed Proof14/各有限E2E成功。非計測binaryの速度は未測定。証拠HARD_CUT_LAZY_ERRORS_RESULT_20261004.md/report SHA52B58473E868E882886E8A89E46CE910CD72FDACFBDFD5DBED0E96EA302DF953。

## 実装前の失敗契約

- 新hard-cut-lazy-wire/のadapterだけが凍結lazy_engine SHA B4A89308243C32A46D90EF768A431E2E97FF20AF62E4D9766F787A422E54623Eを参照し再export＋Node aliasする。原wire adapterとの差分はengine path1箇所だけ。
- 原wire probe（SHA176AB4074A9B0C1C18A7E56400083FE908C4F37F7D4A2A9A2E83747AEA418DBC）は全文維持。scopeは原wire scopeからcodec path1箇所を原wire codecへの直接参照へ変更。原codec/Model/pool/math/coder/BWT/e2eを編集しない。
- Source graphは新probe/adapter/scope、原wire codec/e2e、lazy_engineと元依存だけ。custom global_allocator/compare/TLS primary collectorを含まないことをclosure全文から確認。cfg wire_auditのみ、frame/primary/primitive/test OFF。
- 旧fixture正常14/破損34/短header4をそのままselfcheck1で実行し、全E2E JSON/厳密reasonを凍結wire成功と一致させる。新post-code unit testは作らない。
- fixed一read/encode1/decode1、全2811006B plain直接比較、typed Proof14全Eq、両stats一致/旧成功statsとProof全値一致、実frame478856B/size483599以下。固定再encode0であり、今回通常binaryで旧と全frame直接比較したとは主張しない（計測付き前工程で直接比較済み）。
- peak WS/privateはself/fixedの双方でpositive/非null/errornull/160MiB以内を必要とする。unknownは成功扱いしない。
- 通常native elapsedは単回診断でありquiet/warm1+9/全CLI/独立holdout/4native/総合超過証拠ではない。旧単回値3775.1837/3864.9464msは参考のみ。実測結果で次の正式比較か追加演算削減を判断する。

## 所有と容量

新4files adapter.rs,float_scope.rs,probe.rs,run-native.ps1だけをworkerへ委任。fixtureと元sourceは全て凍結。runnerは元wire SHA A829A0046668998F487D9B5CE6FBD372E72DAE007E486EF9F7CB8F70DA925B95のhelper/guard/child/identity/pin/limitsを維持して、出力root、direct source pathとallowlist、前診断pin/判定を必要分だけ適応する。source allowlistでextra残差0を保存。

新unused build/khc-hard-cut-lazy-wire-20261004、compile1/self1/fixed1、compile60s/native各120s、source300KiB/EXE1MiB/report256KiB/output8MiB/free5GiB。生input/frame/plain/trace/Cargo/PDB追加0。必要RAM boundは元wireのencoder44674633/inverse46903800/model21561264/BWT141598926Bを維持。before/after/liveの原成功wireと今回allocation成功report/EXE/source/tool/input/PLANをpin。最終READY/全編集停止を親が回収・全文レビューするまでcompile/native禁止。製品/Git/version/x86/外部/削除変更なし。

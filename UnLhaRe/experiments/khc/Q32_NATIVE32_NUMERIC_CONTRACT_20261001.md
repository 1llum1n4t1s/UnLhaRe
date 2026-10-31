# guarded64/32商の数値E2E条件

[実装前の成立条件と失敗境界](Q32_NATIVE32_QUOTIENT_FEASIBILITY_20261001.md) SHA268AF44903743E447B4A0D9569436DADFDF88C8A1D7DD5253B96FA54D88F7BC2を維持する。今回は数値専用3filesだけ、CTS/codec/製品への組込みや性能採用はしない。

## 先に固定する失敗条件

- 原helperのzero denominator→checked product→Q shift→d>Q fallback→float/整数証明の順又は旧portable分岐の処理を変更する。asmの除数0/商overflow、入力出力register宣言、flags保存仮定の誤り。
- 商・残余・helperエラー優先が独立BigIntegerと不一致。forced portableと通常cfgの値/errorが異なる。旧56191件の商又はportable flagsが保持されない。
- high=d-1/d/d+1、d=0/1/Q-1/Q/Q+1/u64max、商Q-1/Q/Q+1、余り0/d-1、積overflowとd0の優先、signed境界の未検査。
- CLIが入力/出力の祖先reparseを追跡、65536record cap超過・不完全recordを受理、既存出力を上書き、所有tmpを残す、source/proof/EXEを変更、120秒子期限超過。
- 新数値dataset成功・実divl命令から高速化率/全入力証明/他native/製品完成を主張する。

## 編集所有と実験プロトコル

worker一人が新 native32-quotient/{exact_div.rs,audit_cli.rs,verify.ps1}だけ所有する。exact_div.rsは原split helper D969F4CDD89A41BA70BD1BD4C3EC4F4D99004455C9B6C66B53DE4DCC470C0966をcloneし、x86_64かつnot(khc_force_portable)のguarded経路を追加する。ordinary ratio APIの商とerrorは保持、診断NATIVE32=32 flagsは別仕様で旧flags同一とは主張しない。private64/32 primitiveは商と実EDX残余を返し、numeric-only audit cfgは同primitiveの実結果を検査する。guardを共有し、audit入力によって無条件asmを呼ぶ入口を作らない。非x86_64/強制portable/high>=dは旧処理のまま。

CLI inputは24B LE u64 a,b,d、outputは32B LE u64 quotient,remainder,error_code,flags。error_codeは0正常/1除数0/2積overflow、error recordのq/r/flagsは0。input内のhelper errorを記録するaudit専用protocolであり、ordinary ratioのResult契約は変えない。format/path/capのCLI拒否はexit1・stdout0・未公開、正常auditはexit0・1行Stats。出力は全record評価後にCreateNew所有tmp/hard_link no-replaceで公開し、所有tmpだけ必ず清掃する。

未使用root build/khc-native32-quotient-numeric-20261001を非追跡で確認して新規確保する。ownership/source/本契約/成立条件/原helper/compiler/旧数値proof・直接input/outputのcurrent長さSHA/readlockを保持する。rustc1.98.1 x64 native SHA CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC、edition2024/panicabort/opt2・opt3の通常auditと強制portable auditをcompileする。

独立C# BigInteger oracle（candidate f64補正やasm処理を転用しない）で境界と決定的生成の65536records（helperエラーを含む）を生成し、通常/portable×opt2/3×2反復の値/error/実残余を照合する。通常NATIVE32は正しいguardに限り、forced portableにNATIVE32は0、SHIFT/FALLBACK既存条件も区別する。旧proof03C8C60C2DC435AD57BD96F5E19DC2E3EB2B275E775BB246E1292F55274C5C29/input56191も再利用し、新値を原oracleへ、forcedportable flagsを旧rawへ照合する。旧proofの全履歴を再DFSして再証明する必要はないが、使用した全rawはcurrent pin/readlockへ含める。

空input/最大cap/不完全record/cap+1/input不存在・directory、既存output、ownedjunctionとancestor reparse拒否、sentinel保持・未公開/tmp0をCLI E2Eで確認する。junction Targetを作成後と非recursive削除直前にresolved owned rootへ照合する。symlink特権やCPU設定を変更しない。sourceafter/current raw/inventory/reportを保持する。失敗はfailedreportと原因を保存し、同条件の自動retryをしない。

実行前source freeze/Parser/fmt/source対応を親へ通知し、契約内の一度E2Eを担当が実行してよい。終了時編集停止。親は実raw/source/実EXE命令を追加確認し、次段codec条件はその後に保存する。新unitなし、Gitstage/commit/push/外部write/秘密/製品/x86互換版は対象外。

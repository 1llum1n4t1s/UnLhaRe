# 実装前の失敗一覧

正本は ../LOOKUP_FLOAT_CTS_PLAN_20261004.md。private KHQCFP01、depth5一構成。旧形式・製品は変更しない。

1. 数値domain: 0/負/NaN/Inf、prefix0/5、child>=prefix、weight範囲、raw/class cap、serial overflow。拒否後は全モデルstateを直接比較し、floatはto_bitsで比較する。
2. canonical Math生成失敗、ln/expの補間端点・cutoff・非finite。非対称syntheticでstd式の独立数値計算に対しln/exp各2e-7、pool probability1e-6。KT/CTS、gradient、Hamilton total/tail/minimumも検査する。
   KTはlevelごとにdenominatorの逆数を一回計算してchildへ乗算する。qとCDFのp正規化もsum逆数一回から乗算する。独立oracleはchildごとの直接除算。Hamilton後freq>=2を検査し、下限補正はしない。
3. RAM codecで空・1byte・反復・周期・全byte・random、復元plain全byte、repeat frame全byte、全ProofとCDF entropy bits。旧E2Eのtruncation/header/payload/metadata/range/grammar拒否を新形式へ適応する。新unit testは作らない。
4. 固定group2811006B/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76。新frame<=483599Bのscreenを先に実施。不合格ならABBAを走らせない。合格時だけold/new/new/old一周warmup0、全plain/repeat-frame/Proof14比較。
5. source閉包identityを実行前後固定。source300KiB/EXE1MiB/report256KiB/fresh8MiB。compiler60秒/CLI120秒/stdout64KiB/stderr16KiB、既存生成root拒否。生成物はEXE+reportだけ、input/frame/plainはRAM。
6. 4環境native互換性、最適化間float軌跡、正式速度、holdout/category、製品契約、7-Zip総合勝利はこのscreenからは証明しない。拒否の件数を旧モデルへ偽装しない。容量・数値仕様・設定を自動緩和しない。

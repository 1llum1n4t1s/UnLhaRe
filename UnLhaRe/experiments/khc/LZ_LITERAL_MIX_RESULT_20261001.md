# 逐次LZ literal混合の結果: 固定サイズ条件に未達

固定一構成を実装し、CLIで往復・決定性・代表異常系を検証した。通常Lazy LZの531353Bから523081Bへ8272B縮小したが、上限483599Bを39482B超過したため不採用。速度測定、holdout、context/weight/parserの後付け調整には進まない。製品の既定・ABI・versionは変更しない。

## 実行証拠と範囲

`build/khc-lz-literal-mix-20261001-dependency-repair/report.json` SHA `DE62570E41D9383B43F76ABC28048AB26E17D97033700A6BFDCA895A0B8F4E3C`、status `correctness_passed_size_no_go_not_timed`。45checks/65CLI/89identities、実行中のbefore/after変化・timeout・owned tmp/reparseは0。固定group2811006B SHA `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76`。

- control frame531353B SHA `D2B7A7326D38844F707F4F12B2ECCC9EC22AD3CAFD61CDEF31CE72904DA9AE9C`。現在のRelease `khc_lab.exe`による元Lazy LZ出力とも全byte一致した。
- mixed frame523081B SHA `90F6FCB233C04D30321C4DE86DE0E9EB421587C9AE152416401E003CAF7B6143`。両variantの反復出力と復号全byteを照合した。
- 空・短入力・全byte・反復・周期・seeded random、固定group、別magicの相互拒否、代表破損、取消、入力不存在/ディレクトリ、no-clobber、上限超過、入力/出力祖先junctionを確認した。これは有限のWindows x64 CLI検証であり、全破損の網羅や製品の親handle-based安全性の証明ではない。

新literal予測は既存expertとorder-2 expertの因果的な混合で、追加配列storageは524288B。これは実測peak memoryではない。Beam/RANS/deferred adaptationは今回の対応範囲外であり、新magicは研究用別形式。汎用互換性、速度、4環境native、総合7-Zip超えは未証明。

元reportの`limitations`先頭3文は別verifierから継承された誤った説明である。この実行ではBigInteger oracle、Model history protocol、forced-portable buildを使用していない。それらを成功証拠として扱わない。reportと凍結verifierは履歴保全のため書き換えず、本記録で実際の範囲を訂正する。新しい独立作者監査もない。

初回compileは共有diagnostics moduleのserde_json extern不足で失敗した。別rootの失敗reportを保持し、既存rlibの参照だけを修正して新rootで検証した。変更境界は[build修正記録](LZ_LITERAL_MIX_BUILD_REPAIR_20261001.md)。依存更新や盲目的な性能再試行ではない。basis `cargo +1.98.1 check --locked --offline --example khc_lab`は変更前exit0/10.3888秒、変更後exit0/0.4691秒。Release exampleのビルドも成功した。

## 用途終了fixtureの清掃

今回所有の `C:\Users\IMT\dev\UnLhaRe\UnLhaRe\build\khc-lz-literal-mix-20261001-dependency-repair\over-cap.input` だけを削除した。67108905B、SHA `934D5A499F36334863850A8711DD559E1CAE2A4139E1AB3C4C58276B3D29E559`。owner、terminal report、length/hash、祖先非reparse、関連処理停止を確認し、単一PowerShellの`Remove-Item -LiteralPath`で削除、残存なしを観測した。ごみ箱ではなく直接削除だが、CreateNewでゼロ-filled fileを作りSetLength(67108905)とするverifierの手順で再生成できる。

reportの89identitiesは実行時の履歴であり、削除後は88現存identityの長さ/hash一致を改めて確認した。2026-10-01 21:55のCPU確認後の再開時に、root保持量22033405B、owned tmp/reparse0を再確認。source・report・EXE・rawframe・復号結果は保持し、共有Cargo cacheや他作業は削除していない。

`opop`の観点調査により既実装のcache/遅延生成と既存no-go案の再試行を避けた。新modelは許可済みアルゴリズム研究であり、既定挙動を維持する保守改善として採用したものではない。全体goalはactive、7-Zip超えは未達。

# Dense17段Q16 CTS: 1B超過でもNO-GO

Q16/17段/min alpha1の一構成は、数値と有限codec E2Eに成功したが、完全frame483600Bで固定上限483599Bを1B超過した。NO-GOとして閉じ、precision/alpha/depth変更やheader削減でこの試行を通過扱いにしない。速度/holdout/設定sweepは行わない。通常Q32 scheduler483496Bから104B、凍結balanced Q32 frame483469Bから131B増える。7-Zip超え・速度改善は未証明。

[事前契約](Q16_DENSE_CTS_CONTRACT_20261001.md)と研究sourceは10月1日に開始し、実行は10月2日JSTに完了した。根拠は `C:\Users\IMT\dev\UnLhaRe\UnLhaRe\build\khc-q16-dense-cts-20261001\report.json` SHA256 `3BEAB8DF55122861ADA76E5D0F0BCADD63DD4B2DC1F2AFAFD5498EBCFAF58DD1`。2026-10-01T15:08:23.7784023Z〜15:09:02.1560223Z、exit0、status `correctness_passed_size_no_go_not_timed`。59checks/71CLI/95identities、失敗check/timeout/想定外exit0、終了直後のcurrent長さ/hash差0。

通常native237056B SHA `AEE3847124B55CF9B1A23CEC22B692E57C3E68906610BB789EB3CE9BB663BD70`。固定frame SHA `F76B409E0498A59D3E1E5A1D121F3C49D9BA84AAFC84E0BFB775C81CEF0CC343`。verifier SHA `DF22587DE926D7C981C3C1F7966CAA6F0B064E83278ACF9A007B20643987ADCF`、変更時刻2026-10-02T00:07:17.5070499+09:00、CWD `C:\Users\IMT\dev\UnLhaRe\UnLhaRe`。元通常scheduler verifierへの12置換の全文対応、heavy16置換、scheduler参照1行、wrapper/Bayes getter対応、source/compiler/input pinsを実行入口で照合した。

| 数値記録 | 件数と支持範囲 |
| --- | --- |
| ratio | 720904。全d1..65536の境界/中間10n、等号、範囲外、u64MAX、固定seed65536標本、d0/product overflow順序 |
| KT | 196633。小観測total全0..65535の3分布、large counts、equal、clamp、cap、u32 overflow |
| model helpers | 1170。有限weights/probabilities、mixture floor/remainder、観測側ceiling、posterior、after1/2/65535/65536/capのalpha/next weight |

総918707recordsをu128直接積/除算のoracleへ照合した。oracleは逆数表・legacy quotientを共有しない。native/forcedportable各18B×918707=16536726Bのrecordsが全byte一致。Table524296B/Node16B/Prediction544Bも確認した。等号分岐は、n==Q*dだと48bit reciprocal積が2^64以上になるため乗算前にQを返す。正常Q16 posteriorはtable domain内だが、private任意引数にはその仮定を強制せず範囲外を凍結native32 helperへfallbackする。

codecは空/単byte/全byte/反復/周期/seeded random/固定groupでnative/portable/連続Q16 heavy参照のframe全byte・復元hash・schedule一致を確認した。固定反復、旧Q32/通常scheduler/小journalmagic交差拒否、代表5破損、既存出力保持、入力欠落、小journal64recordsのforced catch-upも通過。固定group heavy processed3223156（replay434286込み）、active2788870とjournal件数は通常Q32 schedulerと一致。activeのheavy/Bayes Q15は連続Q16参照と一致するが、旧Q32や全内部stateへの同値は主張しない。

## 追加の読み取り確認と限界

既存 `balanced_kt_codec_audit` 担当が、48bit reciprocalの数学domain/equality/overflowと、実source3ファイルを静的に追跡した。guard/fallback、KT検査/clamp、alpha min1/retained/next bounds、Q15変換、oracle独立計算との不整合は見つからなかった。これは既存担当の追加確認であり、新独立作者監査や実速度確認ではない。

ratioは全u64網羅ではなく各dの10点と標本。helperのcached ceilingはweight==snapshot枝だけで、非一致/捏造snapshot/全private error優先の網羅ではない。helper numeric audit単独ではTreeの連続履歴・Predict.zero・実更新でのmin alpha移行を実行しない。別codec E2Eで長い履歴/実更新/復元を有限確認したが、独立した全Tree state oracleではない。normal input cap超過fixture、全poison分岐、四nativeのf64 primary/Bayes決定性、製品parent-handle公開安全性、hard memory/OS peak、同境界decode・holdout/category・製品統合は未証明。

## 重複rawの清掃と再現

再現入口は `pwsh -NoProfile -File experiments/khc/q16-dense-cts/verify.ps1`。CreateNew/既存root拒否で保存済みreportを書き換えない。未採用のsource/EXE/frame/restore/numeric native raw/CLIログは今後の再現と精度変更の反証材料として保持する。

用途を終えたportable raw `C:\Users\IMT\dev\UnLhaRe\UnLhaRe\build\khc-q16-dense-cts-20261001\numeric-portable.records` だけを削除した。16536726B SHA `161A59B5BCA12128D28C47E66270D1F87E25E56BB4A5A9F046BFCFB8D6DE07A2`、native同名rawと全byte一致の保持物がある。絶対path/root/owner、ancestor非reparse、owner process不在、exclusive open、保持側identityを検査後、単一PowerShellのliteral Remove-Itemで削除し、不存在と保持raw SHAを確認した。約16.5MB削減、同一rawまたはpinned portable CLIで再生成可能。

terminal reportの95identitiesは実行時の歴史的記録として改変しない。清掃後94が元pathで現在一致し、削除した1つは `numeric-native.records` の同一bytes/hashへ対応する。numeric_evidence.portableの歴史的pathもこの同一raw対応を使う。現在root41853767B、owned tmp/reparse0、関連processなし。共有cache/他作業/x86/ごみ箱は対象にしていない。

総合goalはactive/未達。次はこのQ16構成を調整せず、Q32の予測を変えずに可変posterior分母を整数reciprocalのseed/refinement/残余検証で処理できるかを別の未実装仮説として調べる。旧float estimate/corrected/split/native32の既試行との差を先に確認する。正確さ・速度・一般化は未証明で、固定gateや元の総合要件を省略しない。

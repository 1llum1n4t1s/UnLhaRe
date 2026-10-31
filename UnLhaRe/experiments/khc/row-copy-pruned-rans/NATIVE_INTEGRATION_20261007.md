# Native KRS1 統合：実装前の条件（2026-10-07）

採用する範囲：Rust KHCの明示opt-in RecordTrial／CLI record-trialだけ。既定Mdl/revision1とHybrid/BinaryAdaptive revision2、LHA、公開C/.NET ABI、version1.0.4は変更しない。archive revision3でKRS1BLKを必須とし、既存readerが未知revisionを拒否できるようにする。私的試作とのframe全byte一致をE2Eで確認する。
KRS header layout/整数CDF/scale15 scalarANS/因果幅/完全copy文法/下界は試作のまま。内部配置だけsrc/khc/record*.rsへ移す。既存blockをbaseline aliasとして使い、旧blockは編集しない。
KHC archive metadata/entry CRC/安全な親handle/CRC後no-replace公開/選択/取消は共通経路を使う。KRS extentは確保前raw+80で制限、revision1/2はraw+40を維持。listは復元せずheader/extent/wireCRC/保存CDF/内包legacy headerを検査する。verify/extractはplain CRCも検査。
失敗先行：空・1byte・全256symbol・copy長0/127/128/16383/16384付近・1MiB・複数block・ディレクトリ・各method；旧revision1/2fixtureと互換；新strategyframeがprivate試作と一致；unknownarchive/frameversion、混合magic、reserved、truncation、trailing、raw/model/payload過大、壊れたCDF/freq0/total、非最小ULEB/overflow/copy超過、innerlegacy不正、wire/raw/fileCRC；上限entry/total/memory、選択、取消前後、既存archive/既存extract出力保持。
新unit testは追加しない。専用E2E runnerで実際の公開APIcreate/list/verify/extractを通し、小さいJSONに結果とhashを保持する。試験fixtureは専用rootに最小限、共有corpusを複製しない。全filesは作成台帳に記録し、終了時清掃は共通Windows手順が使える場合だけ行う。
予算：Cargo増分0・既存cache cap6175228536B、依存download0、standalone native rlib＋E2E EXE／compiler一時物を専用root合計16MiB、source backup<=128KiB、fixture<=4MiB、free>=5GiB+20MiB。compiler512MiB/60s、E2E64MiB/60s、suite300s、CPU quiet15%/60s。同じtarget release depsを既存Cargo fingerprintで一意特定し、hashを固定する。native CLI buildはE2E成功後に別予算で検証し、未実行を明記する。
性能は統合後の実archive総byte/正逆native全I/O再計測で再判定。現private gateの成功をnative/Zstd/未見/7Zip全体へ外挿しない。条件不足ならnativeを既定にせずGOAL activeで改善を続ける。


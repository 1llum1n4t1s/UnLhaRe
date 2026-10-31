# direct-token完全frame: 正確性成功、サイズ不採用

PROGRESS。新研究形式 `KHNTOK01` を実装し、完全frameのencode/decode E2Eは成功した。ただし固定サイズgateに失敗したため、この候補は不採用。正式性能測定は実行していない。7-Zip総合超えは未達でgoal activeを維持する。

## 実測した範囲

| 確認 | 結果 |
| --- | --- |
| empty/single/all-byte/zero-repeat/alternating/seeded random/fixed all.group | 7入力×opt2/3×overflow yes/noの28 encode/decode全byte一致 |
| 条件間wire | 21 frameの実byte比較成功 |
| 独立literal frameのlength255/256/257 | codec encoderを使わず生成、3つとも全byte復元一致 |
| forged frame | valid empty1件、意図したstderr拒否23件。CRCの前段だけの拒否をgrammar到達へ数えない |
| no-clobber/不正operation/args/missing/旧形式相互拒否 | 成功、拒否後の出力不在または既存保持 |
| 証拠再照合 | source/compiler/runtime/input/旧成果物20件、現存EXE/frame12件に差異なし |

全52比較、13546747byte。source読み取りlockとbefore/after識別を記録した。`crc_repaired=false` のliteral grammar frameはfresh construction時に正しいCRCを付けたもの。「false」はCRCが壊れているという意味ではなく、後から修復するmutationをしなかったという分類。該当decoder stderrはheader/payload CRC成功後のgrammar分岐から出る。unique active listのhead除去/非zero rank挿入により、non-maximal adjacent branchは通常grammarでは到達不能であることを静的確認したが、このbranchを実行したとは主張しない。

## 固定入力の結果

- input2811006byte、SHA `18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76`。
- 完全frame **575791byte**（payload575510/header281）、SHA `7CA980DEA45770A96E40FAADC43964E597CAF529CBD84EC6BAA6CCE3E621A647`。
- 固定上限483599byteより92192byte、約19.064%大きい。`size_gate=false`。上限、単一thread/CPU15%/574.5624ms未満/warmup1+9の正式境界を変更しない。
- runs889227、rank/length各889227 interval、escape742byte、合計1779196 range interval。Run12byte×889227=10670724byteはencoderのrun table計算値であり、全process peak memoryやdecoderの実割当量ではない。interval件数が減ってもサイズ/速度勝利とは扱わない。
- E2E `elapsed_ms_diagnostic` は正式中央値、7-Zip比較、改善率の証拠ではない。holdout/カテゴリ、同境界decode性能、4native、allocation失敗注入、製品/API統合は未検証。

## source・証拠・容量

codec `direct-token/codec.rs` SHA `52AE4721BE40197A40F97DF9377F300986063649DCB8121B5A5516F376906512`。旧binary schedulerは通常経路から除去したが、旧実験/source/proofは保持した。原codecのfilled/CRC/read/publish/inverse BWTの6関数blockは文字列照合で一致（境界の空行だけ除外）。BWT/packed alphabet/range primitive/CDF primitiveは凍結sourceを再利用した。独立explorerの静的調査でも文脈更新順、rank範囲、varint、boundsの具体的欠陥は見つからなかったが、実行証明とは区別する。

初回入口はBWT pin path typoによってcompile/codec0・root未作成でterminalとなった。原因と元SHAを `DIRECT_TOKEN_FULL_PREFLIGHT_FIX_20261002.md` へ残し、新契約・fresh rootで訂正した。元の測定候補を再評価したものではない。修正後verifier SHA `86A207CD0AABD9DF56B08D44E90326491EE5E9F2759C078924DCDD7CCC2BF12C`、forge `0892F905002D6776FD494D0587B8DDDB379BE13C97DED224F9382B753AA4204A`、plan `82F660D7906712DFEC3C13F5DA16DE02D875C9A21F8CC90FE015E6A3D8DBD55A`。

`build/khc-direct-token-full-20261002-bwt-pin-fix/report.json` 172972byte、SHA `B2CBF04F6CAFA79DA72EB082A0C957DE468C9AC4945186D8DDABC1EB8AA91C4F`。124 CLI record、正式benchmark0。独立計算・全byte比較をしてからexact owned transient91件を削除し、親も全91件の不在を確認した。削除物はgenerated小input、condition frame、restore、forge/boundary、existing-output fixture。内容は凍結source/固定inputから再生成できる。ユーザーデータや旧証拠は削除していない。

残存は4codec EXE+forge EXE+7reference frame+reportの13file、合計 **1724161byte（約1.644MiB）**。64MiB事前・事後予算内。PDB/Cargo/cache/raw traceなし。`git diff --check` 成功（既存DESIGN.mdの改行警告のみ）。sourceは未ステージ、製品API/level0/4/5/6/7/version/Git/publication/x86は変更しない。

次は文脈ごとの確率推定を改良する。現在のfrequency=root+4localは、root正規化分布に対してrootTotal/4件の事前観測を置くのと同じ式で、globalの観測量によって局所文脈への事前重みが強くなる。これがサイズ差の実原因とはまだ断定しない。固定強度に正規化したglobal CDFを使い、同じ固定入力・gateで反証する。整数wireと容量上限を維持する。

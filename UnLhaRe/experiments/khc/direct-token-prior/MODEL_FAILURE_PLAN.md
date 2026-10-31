# 正規化prior数値・状態CLI検証の失敗計画

実行前契約: `../DIRECT_TOKEN_PRIOR_CONTRACT_20261002.md`。候補のprior_math/cdf_model固定SHA通知が届くまでcompile/runしない。旧モデル/旧range/旧full proofは読み取り専用で固定する。

失敗条件と検証:
- D=0,16384,u32::MAXまたはprefix>Dを受理、D=1のreciprocalが2^32でない、補正を忘れる/2回必要、通常u32/u128除算と異なる値: D=1..16383の終点、全257出力境界ceil(qD/256)と両隣、32seeded prefixを逐次比較。800万件以上、補正1の実測証人を要求する。
- node個別丸め、freq/prefixの丸め不一致、truncated CDF/searchのずれ、freq=0またはtotal>66045: 生配列+通常整数除算+linear selectの独立oracleと照合する。候補scale/Fenwickをoracleへ流用しない。
- root/local更新順序、rescale後scale更新漏れ、count/state汚染: alphabet16/256/257、13key、各131072eventの偏り/交互/seeded入力、variable truncationでinterval/selectを逐次比較。全countsを1024event毎と全rescale直後と終了時に比較する。
- 無効factory/key/token/limit/slot/audit keyを受理または状態変化: 全counts/rescale snapshot、拒否後oracle照合、その後の通常eventで継続を確認する。
- opt2/3×overflow yes/noで結果が違う: 4条件のstdout全体（counterとfingerprintを含む）を一致確認する。CLI引数拒否も全条件で確認する。
- ソース/契約/guard/旧primitive proof/compiler/runtime/import不一致、実行中変更、EXE改変: read-lockと前後SHA、import先の実在/固定対象を実行前確認。候補ソースの固定SHAは親通知値を必須引数として受ける。
- 時間/容量/出力逸脱: child120秒、stdout/stderr各65536文字、report512KiB、fresh専用root8MiB。4小EXE+JSONは1MiB未満の見積り。各EXE最大1MiB、compile前に1MiB+残りreport512KiBをreserve、超過停止。guardを前後/条件間に実行する。生vector/traceは保存しない。oracle一時massは257u32以下、countは14×257以下（factory上限の一時modelのみ4097×257）。

生成先は `UnLhaRe/build/khc-direct-token-prior-model-20261002`。存在時は上書き/自動再試行しない。失敗はbounded reportと最小assert位置/条件を残し親へ返す。旧proof/dirty file/Git/version/外部/x86/cacheを変更しない。

数値・状態成功はfull size/speed、allocation failure injection、four native、grammar/container、製品/API統合の成功を意味しない。

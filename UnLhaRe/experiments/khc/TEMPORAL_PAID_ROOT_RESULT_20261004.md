# 固定14tile・モデル保存費込みの結果

情報診断は正当性・資源条件を満たすが、費用screen532461Bで固定483599Bを48862B超えるため、この方式はno-go。製品・実frame・速度の採用なし。全GOALはactive、未達。次の候補はleaf保存費を短くする設計を独立読み取り調査中。

## 観測値

| 項目 | 値 |
| --- | ---: |
| 元の無料Qtoken / side込み | 449308 / 452387B |
| paid token ceil | 504317B |
| paid token増分 | +55009B |
| 実際にRAMへ保存・読み戻したmodel header | 25065B |
| side | 3079B |
| paid screen | 532461B |
| token増分＋header / 許容 | 80074 / 31212B |
| DP loss / packetからのrow loss | 4034528.037735755 / 4034528.0377357546 bits |
| default / explicit roots | 9263 / 2665 |
| header有効bits / padding | 200031 / 41 |
| 局所rootとの連結bit直接比較 | 188103 bits |

元の分布計算とgrammarは変えていない。無料Qは全tile/node/component/whole統計と原reportへ直接一致。paid側は既存depth5四分木MDLを再利用し、root default tagとtile単位length/paddingだけを新設した。保存費25065Bそのものは残り31212Bより小さいが、木の剪定による55009Bのtoken増分が大きい。無料モデル推定の452387Bを、完成書庫の圧縮サイズとは扱わない。

## 実行・E2E・親検証

固定rustc1.98.1、Windows x64、opt3/thin LTO/CGU1/unwind/overflow checks/debug0、単体compile1/native1。compile約6002.9644ms、native全診断約6384.2747ms。これはE2E・構築・保存・照合を含む実験時間でありCLI圧縮速度の測定ではない。native exit0/stderr空。

既存有限E2Eは65536/65537境界、24拒否と回復、実Front3例を直接維持。追加packet正常4例、完成packet全CDF3489792比較、root拒否3、packet拒否8、weighted拒否4と回復が成功。固定実入力はread1/BWT1/walk1、3976node models/11928roots、Fit→root解析全CDF12214272比較、完成packetのnode/component/tile/whole count・loss照合。packetはRAMのみで逐次解放。原model全文prefix、Accumulator4接続点逆復元、weighted ingestのnamespace逆置換を親でも照合。

親runner初回はnative成功後、nested E2Eのfull_event_trace_savedを旧階層で参照したためerror=Traceで失敗した。元reportは書き換えていない。runnerの同一行にある2参照をfrozen_temporal階層へ修正し、保存済みrawを読み取り検証した。再compile/native0。runner元全文SHAへの1行逆復元、sources/identities before-after-live、全Meta、無料Q、paid費用・E2E・OS資源の検証が75組/raw1で成功。EXE after fieldはwrapper終了前に未記録なので、EXE before/live一致を検証し、before-afterと偽っていない。

実行経路のnativeは元から成功。訂正したvalidatorを同じ保存rawへ通し全検証成功。訂正runner自体の新規native実行は行っていない。未来の新規実験は別の未使用出力先を用いる必要がある。

## 容量と資源

model capacity式23742227B <24MiB、fixed phase44699561B <48MiB、BWT式141598926B <160MiB。OS peakWS55652352/private51843072B、各160MiB以内。Dense1/packet1/node scratchのみ、14件scalar paid summary。node oracle4544Bは4MiB reserve内。

新生成物はEXE330240B＋report159942B＝490182B、2ファイルのみ。予算8MiB以内、raw入力・frame・plain・packet・CDF trace・Cargo/PDB/ASM生成0。最終読み取り時空き41323343872B（約38.49GiB）。削除0、他作業の容量変動を本実験の消費と混同しない。

## 再現と識別

`temporal-paid-root/verify-artifacts.ps1`を固定bundled pwshで実行すると、追加compile/nativeなしで上記保存結果を再検証する。元report status=failed/Traceは保持され、readonly-passedを別結果として返す。

- report SHA256: 1D87164EF4869B24BB5267914DE80ACC44E358D4C3D5D39E3CE42D278269C4B1
- EXE SHA256: 1C8FE42F9DB14CBA6B5713BF122A170109B5C810C7732D1E3D0C68B9C3D053FD
- 修正runner SHA256: 7EC90BDF1F909B08C05CBCD6C57294A0C2739A48958DA124BB752D92A8B6926F
- readonly verifier SHA256: 297D5C6A1211A45735D6668501F6C91FA13C1E1698556DFC611D6AC36DEB17CE
- PLAN SHA256: 1FA09B573D7E2DA132CA5DEBF7FCCB0911D16AA05F2C77270E1D1BE7FAEB3C6D

製品dirty、全旧証拠、Git/version/依存/x86/外部/削除を変更していない。完全書庫483599B、全CLI encode574.5624ms/decode47.3884ms未満、同CPU/threads/RAM、quiet≤15%・warm1+9、holdout/API/Windows/macOS x64/ARM64の全固定条件を維持する。圧縮計算速度・実復号・portable wire・総合7-Zip超えは未達。

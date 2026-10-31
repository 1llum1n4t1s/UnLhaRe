# all-class-static failure-first

ALL_CLASS_STATIC_PLAN_20261005.md全文とRESEARCH_SELECTION_20261005.mdの現状／候補1／契約／段階を確認。新4filesだけを所有し、未検証leaf sourceは参照しない。

| 失敗条件 | 先行有限RAM E2E／固定入力の検査 |
| --- | --- |
| class/node/prefix省略 | 2×142=284models／852root、全k×1024=872448CDF、全6classカウントと全Meta直接一致 |
| k1の履歴更新忘れ | grammar callbackで全branchの独立history更新を検査、k1も実counter。元grammarをそのまま使用 |
| 有料wire不一致 | paid Fit/Selected/parse直接使用、table134B/852flag/内部bit/zero pad、実rootbit→packet bit直接比較、全packet解析CDF→再Fit |
| loss／旧2,5対照混同 | 新全class DP=parsed rowloss=replay、旧2/5 loss1540684.988783758/内部20422/flag834/payload21256/2791Bを同入力から直接照合 |
| packet拒否／回復欠落 | flag/table/長/切断/余剰/root数/depth/pure dominant/compact residual/pad/trailing拒否と同process正常復帰。CDF tail／総量はwire構造で生成され直接書けないため支持検査と意味不正残余で検査 |
| 資源／計数隠し | 32KiB以内の空・1B・全byte・反復・skew・全class小入力、逐次処理。finiteとfixedのread/BWT/walk/Fit/CDF計数分離。Dense1/Forest1/fit pair node単位、全capacity／寿命課金 |

model32MiB/phase64MiB/scratch64KiB/OS各160MiB、新4files64KiB／closure350KiB。side3079Bは旧固定値借用の試算、complete frame0/teacher0。rawpacket/input/frame/trace disk copy0。新sourceは新規記述、packetの凍結bundle由来差分には厳密逆ledgerを残す。worker compile/native/Git/version/依存/外部/削除/download/追加委任0。型／nativeは親だけ、最終非書込rustfmtと4SHA/mtime/bytes後READY編集完全停止。

## 親による所有権拡張と分類（実装分離前）

更新PLANに従いadversarial.rsを加えた5filesを所有する。合計64KiB、型/native禁止とその他境界は維持。ststを確認し、正常finite.rsと異常adversarial.rsを分離する。故障モデルは受信metadataの非正規化・切断・追加・table/深さ/残余の意味不正。異常は正常packetの複製をRAMで改変して厳密理由と同process復帰を検査する。これはOS chaos、巨大負荷、AI攻撃全体の検証ではない。初回source/native成功は親のみ。最終識別値は5filesへ更新する。

## packet厳密逆ledger（RAM照合）

packet.rsのみvalidated paid-code-tree/bundle.rsから派生。凍結元SHA256 8CF5754DCFA37AECD584D0DB199D5E9B23AA31FFDFFA4246FD4248FD2A9F4B08。以下の現packetゼロ起点line spliceを下から順に逆適用すると元全文へbyte-for-byte一致することをRAMで確認した。元sourceへの書込／disk copyなし。probe.rs / finite.rs / adversarial.rsは新規記述。

- 現packet line offset=4, remove=2; old挿入2lines。

```text
pub const MODELS:usize=278;
pub const ROOTS:usize=834;
```

- 現packet line offset=55, remove=1; old挿入1lines。

```text
pub struct Forest{frequencies:Vec<[u16;4]>,selected:[[bool;142];2]}
```

- 現packet line offset=59, remove=1; old挿入1lines。

```text
        let mut selected=[[false;142];2];let mut models=0;
```

- 現packet line offset=61, remove=1; old挿入1lines。

```text
            for node in 0..142{if tree.class(node)?==2{selected[c][node]=true;models+=1;let parsed=reader.next()?;
```

- 現packet line offset=63, remove=1; old挿入1lines。

```text
            }}
```

- 現packet line offset=65, remove=1; old挿入1lines。

```text
        if models!=MODELS{return Err("Forest selected node count".into());}reader.finish()?;Ok(Self{frequencies,selected})
```

- 現packet line offset=68, remove=1; old挿入1lines。

```text
        if c>=2 || node>=142 || !(2..=4).contains(&k) || !self.selected[c][node]{return Err("Forest component/node/prefix/mask".into());}
```

- 現packet line offset=75, remove=1; old挿入0lines。

```text
(empty)
```

元はCRLF、新packetはLF。上記old各行をCRLFへ戻す（元末尾もCRLF）、未変更行もCRLFへ戻す。検査時は各old行のCRLFを保持した実文字列で逆spliceし一致を確認した。

## 実装段階の検査契約

有限8入力の合計26049B／最大16384Bを直接assertし、BWT8／walk16／case Fit9088と順序fixture Fit4をfixed1136Fitと分ける。正常parse9、異常19／復帰19／正常witness1のparse39は別field。正常finite_E2Eの既存拒否／復帰scalarはadversarial実counterのsummary alias。Forest Reader decoderと全3root Dispatchの実capacityを追加保存し、個別rootと同extentでも別transientとして保守的加算する。contract/memoryのResult接続は凍結contract+referenceをpath参照する。全wire、CDF、grammar replay段階までを担当し、payload／逆BWT／完成frameを追加しない。型／native分類は親実行まで未検証。故障が出たらtest defect/environment/product defect reproducedを親の台帳に分類する。

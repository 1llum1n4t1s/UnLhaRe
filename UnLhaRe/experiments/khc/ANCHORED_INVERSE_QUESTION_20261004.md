# 次の構造候補：有料anchorでLF依存loadを分割する

permutation-inverse/packed.rsは各symbol区間をrank0..count-1で埋めLFが置換であることを使う。primaryの早期再訪を拒否し、n行後のprimary復帰を要求する。旧単回近似/内部中央値を全CLI目標の下界や達成証拠にはしない。

候補は8本の独立row stateを同一threadでinterleaveし、依存loadの待ちを重ねられるかを測るもの。実CPU利益は未証明、現時点は正当性の問い。n>=8、q=floor(n/8)、開始offsetをi*q、最初7segmentはq、最後はq+(n%8)。anchor_i=LF^(i*q)(primary)を32bit×8で実保存する。anchor0=primary、全row範囲、各segment終了rowが次anchor（最後primary）、global offset>0でprimary早期再訪なしを検証する。

各segmentが連結して全長nのprimary起点LF walkになること、LFが置換かつ早期primary再訪がないことから、全row訪問を示せるか独立確認する。この証明が成立しないならvisitedを省かない。各global step>0のbyteをplain[n-1-global_step]へ書く。sentinelはglobal step0だけ省略。n<8は元packed24にfallback、形式ではanchor無しをcanonicalとする。

encoder側のanchor作成を無料にしない。先行独立診断はLF walkでanchorを求める時間を別途実測、metadataをserialize/parseして32Bを実計上する。将来BWTが保持するsuffix arrayからanchorを得るなら、suffix rowのSA値が `(n-global_step)%n` であることをtiny independent oracleで確認し、追加scanとメモリを測る。元BWT/source/形式を今は変えない。

必要な先行失敗契約：anchor数/範囲/anchor0/重複/ずれ/segment終端不一致、約数LF cycle、symbol/sentinel/alphabet、n=1..8とn%8全余り、24bit/最大transform長、capacity/overflow/CRC/panic/timeout。旧referenceとpacked24と候補の全plain直接比較、拒否→正常同process復帰を固定する。生成metadata/容量とencoder追加コストも記録する。従来のtiny/巨大fixtureを無実行で完了扱いしない。

既存単thread/max length維持。原root/製品/公開API/version/Git/x86/外部変更なし。新8MiB専用出力/source300KiB/EXE1MiB/report256KiB/free5GiB/実peak160MiB。anchor方式は新metadataが必要で旧wire互換ではない。仮にinverse改善が成立しても、現在の約2sのpayload復号・完成書庫・全正式gateは別の未解決事項であり、総合7-Zip超えとしない。

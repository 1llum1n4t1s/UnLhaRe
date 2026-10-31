# 高精度混合のprimitive APIと所有権（実装前追記）

親はdirect-token-dirichlet/cdf_model.rs、mixture_math.rsだけを実装する。独立workerは同ディレクトリのmodel_audit.rs、verify-model.ps1、MODEL_FAILURE_PLAN.mdだけを所有する。旧source/reportは変更しない。

ContextModel::new(alphabet,keys)、update(key,token)、cfg(model_audit) audit_counts(Option<usize>)、audit_rescales()は旧版と同じ。prepare(key,limit)->Result<Distribution<'_>, &'static str>を追加する。Distributionは読み取り借用のみ、total()->u32、interval(token)->Result<(u32,u32,u32),...>、select(slot)->Result<(usize,u32,u32,u32),...>。検証用interval(key,token,limit)、select(key,slot,limit) wrapperはcfg(model_audit)だけに置き、製品候補通常経路はprepared APIを使う。

MixtureScale::new(D:u32,T:u32)、floor(R:u32,L:u32)->Result<u32,...>。audit_parameters()->(D:u32,T:u32,den:u64,reciprocal:u64)、audit_floor_mass(mass:u64)->Result<u32,...>はcfg(model_audit)。mass=64R+DL、通常floorでも検証massでも同じprivate演算を使う。mass<=denを検査してQ*massを計算する。境界oracleは通常u128除算を独立使用する。

実行は親の最終source hash通知後のみ。fresh root/8MiB/4小EXE/512KiB report、子120s・stdout/stderr各65536、readlock/import/SHA前後照合。全実行後sourceは凍結する。数学/API/実行前planの矛盾は親へ戻して実行を止める。同条件の自動再試行をしない。

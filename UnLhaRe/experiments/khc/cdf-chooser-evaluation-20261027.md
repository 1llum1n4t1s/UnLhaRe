# CDF chooser ablation: preregistered Mac evaluation

Recorded 2026-10-27 before any candidate build or timing. This is a local decoder
optimization experiment, not a new compression principle or a 7-Zip superiority
claim. The controlled baseline is the existing frozen source ZIP SHA-256
`030eaef48e23004e7902bfe81c0ba28eca15b505252ee59b5d0caa1e43926c3f` and its Mac
release CLI SHA-256 `5338389a94ecad6296fab1686398ef7d01efaf1783fb3fa90e54fa61d0fa9629`.
The candidate changes only `src/khc/block/packet.rs::Cdf::choose` in an independently
identified source snapshot. Exact candidate source and binary SHA, build recipe,
toolchain and release flags must be pinned before any evaluation; use the same
Rust 1.99.1, target and effective build settings as the baseline. If these cannot
be established, comparison is invalid and no candidate is adopted.

Dataset is the already-tuned 11-file Canterbury input manifest SHA-256
`458a2048459bbcae07a771c072d5e387af910c9916545919e42cbb3bcfbb87af`.
It is development data, not holdout. Whole-archive create/extract uses the same
single-worker `portfolio-trial` recipe, metadata and sync behavior as the prior
Mac reference. The baseline and candidate archives and all 11 restored files must
be byte-identical. Run the candidate-independent baseline and candidate binaries
without diagnostic timing instrumentation. Check every output, error status and
restored file SHA and reject extra paths, links and unintended overwrite.

Before timing, compare the old and new chooser using an independent finite witness
covering valid k=2,3,4, each interval boundary minus one/equal/plus one when in
range, final endpoint and above, and unused tail; compare child, cumulative,
frequency and error. Also preserve existing k=0,1 and k>4 behavior if reachable by
internal tests. Reject invalid CDF/extent/truncation/corruption/unknown format via
the real archive/decoder paths. Candidate source proof must show exactly one
changed file and all other baseline files byte-identical. Safety or byte mismatch
means rejection, not a timing success.

After correctness, run one fixed warmup per binary and exactly ten paired rounds,
with the execution order AB, BA, BA, AB, AB, BA, BA, AB, AB, BA (A=baseline,
B=candidate). Record individual encode/decode wall times and maximum RSS, exact
order, raw exits, CPU/thermal/AC observations, tool identities and complete
archive sizes. The primary statistic is each pair's whole-archive decode wall-time
ratio B/A. Adopt for further integration only if overall median and both AB and BA
subgroup medians are each <=0.95, and the second-largest of all ten ratios is <1.00.
This last fixed sign-based rule is a conservative noise screen, not proof of
independent samples. Also require candidate median encode time <=1.05 times the
baseline, and 11-file equality in every run. For each of encode and decode, every
measured peak RSS must be <=134,217,728 bytes and the candidate's maximum over its
ten measured runs must be <= the greater of (baseline maximum * 1.05) and
(baseline maximum + 2,097,152 bytes). This fixed allowance handles measurement
granularity; do not adjust it after seeing the results. Format or safety regression
rejects the candidate.
Any failure of these thresholds rejects the candidate; no extra sample or changed
threshold rescues that run. Ineligible CPU/thermal/AC observation, incomplete
capture, unknown child closure or timeout makes the comparison invalid, not a
finding that either binary is slower. No automatic retry follows an invalid run.

Keep the approved Mac ordinary 1.5 GiB, all Cargo 1 GiB and total 2.5 GiB limits,
and the overall previously authorized ceiling 3 GiB. Pre-run inventory includes
all existing targets, including the 167,939,777-byte diagnostic target; no new
root or target may exclude their contributions. Before reserving at most 512 MiB
for a candidate target, remeasure actual Cargo usage and all outstanding
reservations; no additional 512 MiB baseline target is assumed. Bound each child,
the complete run and all raw output storage before execution using the existing
finite supervisor and continuously monitored admission conditions. A concrete
execution protocol with these bounds and fixed commands must be reviewed before
launch. Preserve failed attempts and stopped Windows S1/S2/S3 records. This
ablation does not establish performance against 7-Zip, representative workloads,
unseen data, or the full goal.

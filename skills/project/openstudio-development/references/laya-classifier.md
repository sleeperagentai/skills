# Laya (embedding-prototype classifier): calibration and limits

Read before changing `services/ai-gateway/laya/registry.go` phrases, the softmax temperature, the `ReadVerdict` threshold, or before asking Laya to score something new. SKILL.md carries the always-on Laya rules (degraded fallback produces hash noise, check `VendorID`, `EmbedderReady()` not `ModelAvailable()`).

Laya scores cosine similarity between the input embedding (all-MiniLM-L6-v2) and label *description phrases*. Getting that to discriminate needs these rules.

## Calibration rules

1. **Max-over-phrases, never centroid.** Give each label several phrases and score by the best match. Averaging diverse "unsafe" phrasings into one vector produces a centroid near none of them — benign immunology scored unsafe while explicit racial dehumanisation scored safe.
2. **MiniLM cosines occupy ~0.0–0.4, so softmax at τ=1 is almost flat.** Use a temperature (τ=0.07, found by sweep). Temperature changes separation only, never argmax — assert that in the test so a future tweak cannot silently reorder labels.
3. **Negations do not exist in embedding space, and incidental tokens leak.** A phrase like "slang used casually *without sexual intent*" still carries "sexual" and pulls explicit content toward itself; "performed without consent" drags consent *education* into unsafe; "chemical or biological weapon" flags immunology. Describe the register positively, and name the artefact rather than the field.
4. **Cover innocent homonyms or you get the Scunthorpe problem.** Literature (Moby Dick), garden birds (great tits), farm animals and public figures blocked until the safe set gained anchors for them. Crude anatomical words also name birds, plants, animals and novels.

## Thresholds, not argmax

Never act on argmax from a 3-label prefilter — it measured a 16% false-unsafe rate on ordinary science-history questions. Threshold the probability mass: `laya.ReadVerdict()` gates at `P(unsafe) >= 0.70`, the lowest value with zero false blocks on the labelled set while catching ~96% of unsafe input. Expose one reader like that so callers cannot take argmax themselves. A **degraded** verdict must neither block nor clear: failing closed blocks all traffic on a misconfigured box, failing open publishes unmoderated content — force escalation instead.

## Fixtures in waves; report the blind number

Tune on set 1; write set 2 *after* tuning; write set 3 and run it exactly once. Each wave catches what the previous missed (a tuning "fix" that adds education anchors to the safe set can open a hole that only the holdout shows). The tuned fixture's accuracy is overfit by construction — never quote it alone. Fixtures: `calibration.jsonl` (tuned), `holdout.jsonl`, `blind.jsonl`, `crude.jsonl` (real vulgar vocabulary + homonyms). Re-run all four after any prototype or model change.

## What Laya cannot be asked to do

- **It is text-only.** It cannot score audio fidelity or video quality. For audio, score the ASR transcript (label it `transcript_quality`, not `audio_quality`) plus technical QC from ffprobe (duration, silence, clipping); for video use measurable technical QC (resolution, codec, duration drift) rather than inventing an aesthetic score.
- **Cosine distance to the string "hateful violent sexual or self-harm content" is not a hate-speech classifier.** Laya is a cheap local prefilter: it may ESCALATE to the authoritative `aigw.Moderation` provider and may block cheaply on *input* before spending LLM credits, but a clean Laya score must never substitute for real moderation on user-facing output.

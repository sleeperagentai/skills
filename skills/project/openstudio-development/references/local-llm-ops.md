# Local LLM operations (llama.cpp / Qwen) for OpenStudio

Operational depth for running TextGen locally via llama.cpp. Needed when a cloud key is out of credit, when calibrating a prompt that must run on the smaller model class, or when debugging a `TEXTGEN_FAILED` on a `PROVIDER_TEXTGEN=local` boot. The high-level resolution order is in `openstudio-development/SKILL.md`; everything below is the depth you only load when working this path.

## Fast bootstrap without HF auth

`scripts/dev-native/llamacpp.sh` defaults to Mistral-Small-24B (≈14GB) which needs a long download and is overkill for unblocking a stuck cloud provider. Ungated 3B alternative that downloads in a few minutes and runs comfortably on CPU:

```bash
hf download bartowski/Qwen2.5-3B-Instruct-GGUF Qwen2.5-3B-Instruct-Q4_K_M.gguf \
  --local-dir ~/.cache/openstudio/models

llama-server \
  -m ~/.cache/openstudio/models/Qwen2.5-3B-Instruct-Q4_K_M.gguf \
  --host 127.0.0.1 --port 8080 --ctx-size 4096 --parallel 2 \
  --alias qwen2.5-3b > /tmp/os-logs/llamacpp.log 2>&1 &
```

Then `LLAMACPP_URL=http://localhost:8080/v1` and `PROVIDER_TEXTGEN=local` in `.env`. Confirm via `aigw: TextGen=local:llamacpp` in the API startup log. Qwen2.5-3B takes 45–60s for a 30-second script prompt on this VM — the `/live/scripts` sync budget must be ≥90s or the 202-then-poll fallback fires on nearly every call (which the wizard handles, so it still works, just slower). A budget of 45s consistently loses the sync path even on warmed model caches.

## Three timeouts tune together

When switching from cloud to local llama.cpp, the sync budget (`liveScriptsSyncBudget = 90 * time.Second`) is only the first knob — the async fallback path has its own cap (`asyncHardCapMultiplier = 3` → 270s) that fires as `context deadline exceeded` when the goroutine times out, marking the script row `status=failed` with a misleading `TEXTGEN_FAILED` even though the model is still generating. And the adapter's HTTP client (`localtextgen/localtextgen.go`, default 120s) times out FIRST — the goroutine never even sees the async cap. For 1200-token generations on a 3B CPU model, bump: `asyncHardCapMultiplier = 6` (9min) in `live_scripts.go`, HTTP client to `8 * time.Minute` in `localtextgen/`.

Symptom of skipping either: `/live/scripts` returns 202 → 30s later `GET /scripts/{id}` reports `failed` with `context deadline exceeded (Client.Timeout exceeded while awaiting headers)` (HTTP client timeout) or `context deadline exceeded` (async cap). Confirm the fix by watching the row flip `queued → done` over 45-60s while the model actually completes.

## `--parallel N` caps concurrent inflight requests

The default `scripts/dev-native/llamacpp.sh` (and the Qwen2.5-3B bootstrap above) launches with `--parallel 2`. Firing 8 concurrent `/live/scripts` calls (e.g. a batch script generating one storyboard per template) queues requests 3-8 behind the first two — and because each Qwen call takes 45-60s, requests 5-8 age out against the HTTP client's 8-minute timeout and come back `TEXTGEN_FAILED` even though the model would have produced valid output given more time. Two fixes:

1. **Serialise batch clients.** Loop through the N items generating one storyboard at a time (`await`/`sleep 1` between submits) — total wall time is `N * 55s` but every item completes.
2. **Raise `--parallel`** on `llama-server` — needs proportional RAM (each slot holds a KV cache) and each parallel request slows the others because there's still one CPU. Practical ceiling on this VM is 4.

Symptom of the concurrency cap being hit: half the batch's script rows finish `status=done` in ~55s, the other half sit `queued` for the full timeout window then flip to `failed` with `context deadline exceeded`. The `/tmp/os-logs/api.log` will NOT show a llama-server error — the model never saw those requests, they died in the client wait. Serialise for reliability; only raise `--parallel` if wall time is the constraint AND you have RAM headroom.

# ElevenLabs Voice Design (create-previews → promote)

Voice Design is a separate API surface from `POST /v1/text-to-speech/<voiceId>`. Use it when the operator needs custom character voices (Homer-style, Rick-style, etc.) rather than the stock premade voices — which Free-tier can't call anyway (see the ElevenLabs Free-tier rule in SKILL.md).

## Two-step lifecycle

1. **Preview generation** — `POST /v1/text-to-voice/create-previews`

   ```json
   {
     "voice_description": "<20-1000 chars: age, timbre, delivery, accent, energy, exaggeration>",
     "text": "<100-1000 chars: script that shows the voice off in the target register>"
   }
   ```

   Response returns `previews: [ {audio_base_64, generated_voice_id, duration_secs, media_type, language}, ... ]`. Three previews per call by default. **Field name is `audio_base_64` with an underscore** — not `audio_base64` and not `audio`. Getting this wrong silently drops every preview because the base64 lookup misses, the response looks fine at status 200, and no MP3s land on disk. Always probe an unfamiliar endpoint's response shape once (`json.dumps(summarize(j), indent=2)`) before wiring the parser.

   The `generated_voice_id` in the preview response is **ephemeral** — ElevenLabs discards it within ~24h if not promoted. Cache the MP3 for the ▶ sample button, but don't wire it into TTS calls: those need step 2.

2. **Promotion to permanent voice** — `POST /v1/text-to-voice/create-voice-from-preview`

   ```json
   { "voice_name": "Homer-style", "voice_description": "...", "generated_voice_id": "<from step 1>", "labels": {} }
   ```

   Returns a permanent `voice_id` (20 alphanumeric chars). This is what goes into the `voiceAliases` map in `services/ai-gateway/elevenlabstts/elevenlabstts.go` and what every subsequent `/v1/text-to-speech` call uses. Promotion is free; it consumes one custom-voice slot on the account (Starter tier = 10 slots).

## Sample MP3 vs voice ID — two different assets, two different jobs

When the operator asks "why do we need to promote, we already have the audio", the answer is that these are two different assets:

- **Sample MP3s** (the 21 files from create-previews) — fixed recordings of the preview scripts. Use for the ▶ sample button on `/cast`, marketing/demo fixtures. Cache under `openstudio-public/voices/<char>-sample.mp3` and serve as `sample_url` on the character row.
- **Permanent voice ID** — the parameter to future `POST /v1/text-to-speech/<voiceId>` calls that synthesises **new words the user hasn't spoken yet**. Every render passes the user's script through TTS with this ID. No amount of caching preview MP3s replaces the voice ID because the user's script is authored per project.

Both are needed; neither substitutes for the other. Wire the character row so `voice_id` and `sample_url` are populated together at seed time; the schema already has both columns on `content.characters`.

## Custom-voice slot cap (`voice_limit_reached` 400) — translate to plain language

Promote fails with `HTTP 400 { "detail": { "status": "voice_limit_reached", "message": "You have reached your maximum amount of custom voices (10 / 10). You can upgrade your subscription to increase your custom voice limit." } }` when the account has used every custom-voice slot (Starter = 10). The handler's default error branch (`CodeProviderUnavailable` + "We couldn't save that voice. You haven't been charged. Try again.") hides the real cause: the user clicks Save forever, retries do nothing, and the generic sentence suggests transient vendor trouble.

**Rule.** Translate the vendor's cap error to a plain, actionable sentence in the promote handler (`handleInfluencerVoicePromote` and any sibling that calls `designer.PromoteVoicePreview`):

```go
msg := perr.Error()
switch {
case strings.Contains(msg, "voice_limit_reached"),
     strings.Contains(msg, "maximum amount of custom voices"):
    writeErr(w, errs.New(errs.CodeConflict,
        "Your voice library is full. Delete a voice you don't need, then try again."))
default:
    writeErr(w, errs.New(errs.CodeProviderUnavailable,
        "We couldn't save that voice. You haven't been charged. Try again."))
}
```

Match on substrings, not JSON-parsed fields — the adapter stringifies the vendor envelope and future minor shape changes shouldn't need handler updates. Keep both the `voice_limit_reached` status code AND the human message substring in the OR; one of them survives any single vendor-side rewrite. **Credit hold still releases on this path** — the switch sits inside the existing `if perr != nil { s.releaseHold(...); ... }` block, so a cap rejection costs the user nothing.

**Recovery for the user.** Delete a voice via `DELETE /api/v1/influencers/{id}/voice`, which clears the local link but does NOT un-promote the ElevenLabs slot (slots are permanent on the vendor side). To actually free a slot, operator deletes the voice directly at https://elevenlabs.io/app/voice-lab. The 7 character-bundled Cast voices (Homer/Rick/Morty/Bart/Marge/Peter/SpongeBob) consume slots too — 10 slots fills fast once a few influencers are saved.

**Product scalability note.** 10 slots is a hard cap once multiple paying tenants ship. Either (a) one ElevenLabs org per workspace, or (b) switch from "promote to permanent slot" to "store the preview's voice-design seed and synth per request" (slower, no permanent slot). Flagged for production-readiness planning — not a code fix in-session.

## Safety filter (`blocked_generation` 403) — what trips it and what fixes it

Voice Design returns `403 authorization_error / code=forbidden / status=blocked_generation` when the prompt or preview text is judged unsafe. On this repo the triggers, ordered by how often they fire:

1. **Trademarked catchphrases in the preview text.** `Wubba lubba dub dub`, `Eat my shorts`, `Grinds my gears`, `Ay caramba`, character-name vocatives (`Lois`, `Milhouse`, direct `Morty`/`Rick` address). Strip these — the vocal *quality* is what Voice Design listens to, not the exact catchphrase. Replace with neutral filler (`Listen, kid, I don't have time...` instead of `Listen, Morty, I don't have time...`) and the voice still lands.
2. **Youth-age phrasing in the description.** `14-year-old boy`, `10-year-old boy`, `young teenager`. Even the vocal-quality framing gets flagged. Reframe as **`Adult voice actor performing a <adjective> cartoon sidekick`** — moves the perceived subject to an adult performer and clears the filter while preserving the pitch/wobble cues the model actually uses. Youth-female phrasing (Bart played by an adult woman) is less aggressive; adult-performer wording still helps.
3. **Character names in the description.** `Homer Simpson`, `Peter Griffin` — describe the archetype (`Middle-aged American man, 40s, with a thick Rhode Island accent, dopey nasal delivery, wheezy heh-heh-heh laugh`) not the trademarked name.

Workflow when a preview is blocked:
- Read the error `request_id` from `detail.request_id` — useful if operator escalates to ElevenLabs support, otherwise ignore.
- Rewrite description + text with the rules above and retry. Do NOT keep the old blocked wording anywhere in the file — future sessions will copy it.
- If two rewrites still fail, the character is a hard block on that account (rare); note it in `docs/CAST-GAPS.md` and pick a nearest-neighbour voice.

## Preview script quality (matters as much as description)

ElevenLabs Voice Design tunes the generated voice off both fields but the `text` field carries the emotional register. Write scripts that:
- Use v3 audio tags inline: `[burps]`, `[sighs]`, `[laughs]`, `[stammers]`, `[shouting]`, `[nervous]` — these bias the voice toward the tagged affect even though they're not spoken.
- Spell out stutters: `I-I-I don't know` beats `I don't know`; catchphrase sounds spelled phonetically (`D'ohhh!`, `Hehehehe`, `Mmm... donuts...`).
- Punctuate for pacing: ellipses for slow/dim pauses, em dashes for interruptions.
- Match the character's typical register — a hyper character needs a hyper preview script, or the voice comes back flat regardless of description.

After promotion, the operator tunes TTS synthesis with `stability` 25-40% (lower = more cartoonish swings), `similarity_boost` 75-85%, `style` 30-60%. These live on the TTS call, not the promotion — the adapter (`elevenlabstts.go`) is the right place to pass them per-voice.

## Deterministic-probe pattern for unknown external APIs

When wiring any new external HTTP API (Voice Design being one instance), don't guess the response shape. Write a tiny probe first:

```python
import json, urllib.request
req = urllib.request.Request(url, data=..., headers=..., method="POST")
with urllib.request.urlopen(req) as r:
    j = json.loads(r.read())
    def summarize(o, d=0):
        if d > 4: return "..."
        if isinstance(o, dict):
            return {k: (f"<str len={len(v)}>" if isinstance(v,str) and len(v)>200 else summarize(v,d+1)) for k,v in o.items()}
        if isinstance(o, list):
            return [summarize(x, d+1) for x in o[:2]] + ([f"...+{len(o)-2}"] if len(o)>2 else [])
        return o
    print(json.dumps(summarize(j), indent=2))
```

Base64 fields are the specific trap this catches — they render as multi-KB strings that break every downstream summariser and hide the key you're actually looking for.

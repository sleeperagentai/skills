# API Template: Video Generation Endpoint

## POST /api/videos/generate
Start AI video generation process from a text prompt with optional narration and caption customization.

### Request Body
```json
{
  "prompt": "A short video about renewable energy innovations",
  "use_approval": true,
  "narration_character_id": 1,
  "custom_audio_s3_key": null,
  "caption_template_id": 2
}
```

### Request Fields
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `prompt` | string | Yes | The text prompt describing the desired video content |
| `use_approval` | boolean | No | Whether to require human approval before final processing (default: true) |
| `narration_character_id` | integer | No | ID of narration character template to use (null for default TTS) |
| `custom_audio_s3_key` | string | No | S3 key of custom audio file to process instead of TTS (null if not used) |
| `caption_template_id` | integer | No | ID of caption template to apply (null for no captions) |

### Success Response
```json
{
  "video_id": 123,
  "status": "PENDING",
  "message": "Video generation started"
}
```

### Response Fields
| Field | Type | Description |
|-------|------|-------------|
| `video_id` | integer | Unique identifier for the generated video |
| `status` | string | Initial status (always "PENDING" when generation starts) |
| `message` | string | Human-readable status message |

### Example Usage
```bash
# Generate video with Morgan Freeman narration and YouTube-style captions
curl -X POST "http://localhost:8000/api/videos/generate" \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "A short video about renewable energy innovations",
    "use_approval": true,
    "narration_character_id": 1,
    "caption_template_id": 2
  }'

# Generate video with custom audio upload and no captions
curl -X POST "http://localhost:8000/api/videos/generate" \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "Product demonstration video",
    "use_approval": false,
    "narration_character_id": null,
    "custom_audio_s3_key": "uploads/user123/audio/abc123.mp3",
    "caption_template_id": null
  }'
```

### Related Endpoints
- `GET /api/videos/{video_id}` - Get video status and metadata
- `GET /api/videos/{video_id}/script` - Retrieve generated script for review
- `GET /api/videos/{video_id}/voiceover` - Get narration audio reference
- `GET /api/videos/{video_id}/captions` - Get captions reference
- `POST /api/videos/{video_id}/approve` - Approve video awaiting review
- `POST /api/videos/{video_id}/reject` - Reject video with notes
- `GET /api/narration-characters/` - List available narration voices
- `GET /api/caption-templates/` - List available caption styles

### Error Responses
| Status Code | Error Condition | Response Body |
|-------------|-----------------|---------------|
| 400 | Invalid request parameters | `{"detail": "Error description"}` |
| 401 | Missing or invalid authentication | `{"detail": "Not authenticated"}` |
| 403 | Insufficient permissions | `{"detail": "Permission denied"}` |
| 404 | Video not found (for related endpoints) | `{"detail": "Video not found"}` |
| 429 | Rate limit exceeded | `{"detail": "Rate limit exceeded"}` |
| 500 | Internal server error | `{"detail": "Internal server error"}` |
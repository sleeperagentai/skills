---
name: ai-agentic-media-workflow
description: Orchestrating multi-step AI generation pipelines for media creation (video, audio, images) with human approval checkpoints and template-based systems
category: mlops
---
# AI Agentic Media Workflow Orchestration

Orchestrating multi-step AI generation pipelines for media creation (video, audio, images) with human approval checkpoints and template-based systems.

## When to Use This Skill

Use this skill when building systems that:
- Generate media content through multiple AI processing stages
- Require separating fast preprocessing (System 1) from generative tasks (System 2)
- Incorporate human approval checkpoints between stages
- Use template-based systems for voices, captions, or styles
- Orchestrate complex workflows with tools like Prefect 2.x or Apache Airflow
- Need to support both template options and custom uploads (audio, etc.)

## Core Patterns

### System 1 / System 2 Separation
- **System 1 (Fast)**: Lightweight models for quick understanding, classification, routing
  - Examples: Prompt enhancement, content safety checks, topic categorization
  - Models: Laya, small LLMs, classifiers
  - Goal: Rapid triage to determine processing path
- **System 2 (Generative)**: Heavier models for creative generation
  - Examples: Script writing, voiceover synthesis, image/video generation
  - Models: LLMs, TTS, diffusion models
  - Goal: High-quality creative output

### Template-Based Systems with Custom Fallback
- **Template Library**: Pre-built options with metadata (language, style, use case)
  - Examples: Narration characters (Morgan Freeman style, etc.), Caption templates (YouTube, TikTok, etc.)
  - Include samples/previews for selection
  - Mark as premium/free, track usage
- **Custom Upload Support**: Allow users to provide their own assets
  - Validation and processing pipeline for custom inputs
  - Format conversion, quality checking, metadata extraction
  - Storage and referencing alongside template options
- **Selection UI**: Clear presentation of template vs. custom options
  - Preview capabilities for informed selection
  - Default to high-quality free templates when unspecified

### Workflow Orchestration with Approval Checkpoints
- **Stage Definition**: Break process into discrete, retryable steps
  - Example: Prompt → Enhancement → Script → Narration → Captions → Visuals → Assembly
- **State Management**: Track progress and artifacts between stages
  - Database records with status fields (PENDING, SYSTEM1_PROCESSING, SCRIPT_GENERATING, etc.)
  - Object storage references for intermediate/final outputs
  - Clear failure modes and retry logic per stage
- **Human-in-the-Loop**: Configurable approval checkpoints
  - After script generation: Review/modify/regenerate script
  - After narration: Listen to voiceover, request changes
  - Before final assembly: Review all components
  - Status transitions: PENDING → AWAITING_APPROVAL → APPROVED/REJECTED → PROCESSING → COMPLETED/FAILED
- **Orchestration Tool Usage** (Prefect 2.x example):
  - `@task` for each discrete processing step
  - `@flow` with `SequentialTaskRunner` for ordered execution
  - Conditional logic for approval paths
  - Error handling and failure state transitions

## Implementation Considerations

### Database Schema
- **Media Item Table**: Core entity with foreign keys to templates/custom assets
  - `prompt`, `enhanced_prompt` (System 1 output)
  - `script`, `voiceover_s3_key`, `captions_s3_key`, `video_s3_key`, `thumbnail_s3_key`
  - `narration_character_id` (FK to template), `custom_audio_s3_key` (nullable)
  - `caption_template_id` (FK to template)
  - `status` (enum: PENDING, SYSTEM1_PROCESSING, SCRIPT_GENERATING, NARRATION_GENERATING, CAPTION_GENERATING, VISUALS_GENERATING, ASSEMBLING, AWAITING_APPROVAL, APPROVED, PROCESSING, COMPLETED, FAILED)
  - `is_approved`, `approval_notes`, `completed_at`
  - `duration`, `width`, `height`, `file_size`

- **Template Tables**: 
  - `narration_characters`: name, description, voice_sample, model_path, language, gender, age_range, accent, is_premium, is_active
  - `caption_templates`: name, description, font_family, font_size, font_color, background_*, position, outline_*, shadow_effect, is_premium, is_active, language

### Storage Organization
- `/voiceovers/{user_id}/{video_id}.{format}` - Narration audio
- `/captions/{user_id}/{video_id}.{format}` - Caption files (JSON/WebVTT/SRT)
- `/video_elements/{user_id}/{video_id}/` - AI-generated backgrounds/objects
- `/videos/{user_id}/{video_id}.mp4` - Final video
- `/thumbnails/{user_id}/{video_id}.jpg` - Thumbnail preview
- `/voice-samples/` - Narration character samples
- Custom uploads stored with UUIDs to avoid conflicts

### API Design Patterns
- **Generation Start**: `POST /media/generate` with options (template_ids, custom_uploads, use_approval)
  - Returns media item ID immediately
  - Triggers background workflow
- **Status Checking**: `GET /media/{id}` returns current status and progress
- **Stage-Specific Retrieval**: 
  - `GET /media/{id}/script`, `/voiceover`, `/captions` for review
  - `POST /media/{id}/approve-script`, `/regenerate-voiceover` for corrections
- **Approval Endpoints**: 
  - `POST /media/{id}/approve`, `POST /media/{id}/reject` with notes
  - Automatic progression to next stage or failure

### Frontend Integration
- **Generation Form**: Prompt input + template selectors + custom upload toggles + approval checkbox
- **Status Dashboard**: Visual progress indicator, current stage display
- **Review Interfaces**: 
  - Script editor with approve/regenerate buttons
  - Audio player with waveform and re-record option
  - Caption preview with styling controls
- **Video Player**: 
  - Toggle captions on/off
  - Select caption language if multiple available
  - Playback speed and quality controls
- **Template Management** (optional admin UI): 
  - Browse/search templates
  - Preview samples
  - Mark as premium/free
  - Upload new templates

## Common Pitfalls and Solutions

### Pitfall: Tight Coupling Between Stages
- **Problem**: Hard dependencies make it difficult to swap models or insert new stages
- **Solution**: Define clear interfaces between stages (input/output schemas)
  - Use message queues or database records as handoff points
  - Allow stages to be developed and deployed independently
  - Version interfaces to support rolling updates

### Pitfall: Ignoring System 1 Value
- **Problem**: Using heavy models for tasks that lightweight models can handle fast/cheaply
- **Solution**: Always start with System 1 for triage
  - Route simple requests to lightweight paths
  - Reserve System 2 for complex generative tasks
  - Track cost/quality metrics to continually optimize routing

### Pitfall: Poor Template Discovery
- **Problem**: Users unaware of available options or overwhelmed by choices
- **Solution**: 
  - Categorize templates by use case (educational, entertainment, marketing, etc.)
  - Provide preview/samples for audio/visual templates
  - Implement smart defaults based on prompt analysis (System 1)
  - Allow favoriting/frequently-used templates

### Pitfall: Approval Bottlenecks
- **Problem**: Human checkpoints slowing down throughput excessively
- **Solution**:
  - Make approval optional (user-configurable per generation)
  - Provide clear "good enough" defaults for skipping approval
  - Implement batch approval interfaces for power users
  - Use predictive quality scoring to auto-approve high-confidence outputs

### Pitfall: Storage Proliferation
- **Problem**: Intermediate assets consuming excessive storage
- **Solution**:
  - Implement retention policies (delete intermediates after successful completion)
  - Use tiered storage (hot/warm/cold) based on access patterns
  - Compress intermediate assets when appropriate
  - Generate derivatives on-demand rather than storing all variants

## Verification Checklist

When implementing an AI agentic media workflow, verify:
- [ ] System 1 processing completes quickly (<2s) for prompt understanding
- [ ] All stages have clear input/output contracts
- [ ] Template systems include preview/samples for informed selection
- [ ] Custom upload paths validate and process user-provided assets
- [ ] Workflow correctly handles approval transitions (both paths)
- [ ] Failure states are properly tracked and retryable
- [ ] Intermediate assets are cleaned up appropriately
- [ ] Status API accurately reflects current processing stage
- [ ] Review interfaces allow meaningful modifications at each checkpoint
- [ ] Final output correctly incorporates all approved components
- [ ] System handles concurrent workflows without resource exhaustion

## Related Resources
- See `references/prefect_workflow_structure.md` for detailed Prefect 2.x workflow implementation patterns
- See `references/api_video_generation_template.md` for API request/response templates
- See `scripts/test_workflow_components.sh` for a verification script to test workflow components
- [ ] Final output correctly incorporates all approved components
- [ ] System handles concurrent workflows without resource exhaustion
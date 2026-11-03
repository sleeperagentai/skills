---
name: ai-agentic-multimedia-workflow
description: Use this skill when building AI-powered multimedia generation platforms that require orchestration of multiple AI models (text, audio, image, video) with optional human approval checkpoints. This approach properly distinguishes between System 1 (fast, intuitive) and System 2 (reasoning, creative) AI processing to optimize for both speed and quality.
---
# AI Agentic Multimedia Workflow

## Description
Use this skill when building AI-powered multimedia generation platforms that require orchestration of multiple AI models (text, audio, image, video) with optional human approval checkpoints. This approach properly distinguishes between System 1 (fast, intuitive) and System 2 (reasoning, creative) AI processing to optimize for both speed and quality.

## When to Use
- Building AI-generated video, audio, or multimedia platforms
- Implementing workflows that require multiple specialized AI models
- When you need to balance processing speed (System 1) with output quality (System 2)
- When human review/approval is desired before final generation
- When deploying with orchestration tools like Prefect or Apache Airflow

## Workflow Architecture

### 1. System 1 Processing (Fast Preprocessing)
**Purpose**: Quick triage, classification, and routing using lightweight/fast models
**Models**: Laya or similar fast inference models
**Tasks**:
- Content safety check (is prompt appropriate?)
- Topic/category detection
- Style/tone classification
- Complexity assessment (simple vs. complex multimedia)
**Output**: Metadata to route to appropriate generative models

### 2. System 2 Processing (Creative Generation)
**Purpose**: High-quality creative generation using best-suited models
**Models**: Best/cheapest/free models appropriate for each modality
**Tasks**:
- **Script Generation**: LLM for structured screenplays with scenes/dialogue
  - Options: Llama 3 8B (free via HuggingFace), Mistral, Phi-3
  - Process: Prompt → Structured screenplay
- **Voiceover Generation**: TTS for natural-sounding audio
  - Options: Coqui TTS, Bark, Tortoise-TTS
  - Process: Script → Audio
- **Visual Generation**: AI image/video models for scenes
  - Options: Stable Diffusion XL, ANIMATE_DIFF, SVD
  - Process: Scene descriptions → Keyframes → Video sequence
- **Caption Generation**: Speech-to-text + templating
  - Options: Whisper, Whisper.cpp
  - Process: Audio → Timed text → Apply caption templates

### 3. Assembly & Post-processing
**Purpose**: Combine all generated elements into final output
**Tools**: 
- Remotion for video assembly (when building video platforms)
- FFmpeg or similar for audio/video processing
- Custom compositors for other media types
**Tasks**:
- Synchronize narration with visual elements
- Apply caption styling and positioning
- Render final multimedia output
- Generate thumbnails/previews

### 4. Optional Human Approval Checkpoint
**Purpose**: Allow human review before final generation
**Implementation**:
- Pause workflow after System 2 generation but before assembly
- Present generated script, voice samples, visual concepts for review
- Accept/Modify/Regenerate options for each component
- Resume workflow based on user decisions

## Key Principles

### System 1 vs System 2 Distinction
- **System 1**: Fast, intuitive, low-cost processing (use for preprocessing)
  - *Never* use for creative tasks like script or scene generation
  - *Always* use for triage and routing decisions
- **System 2**: Slower, reasoning-capable, higher-quality processing (use for generation)
  - Use for all creative output generation
  - Select models based on quality/cost/speed requirements for each task

### Model Selection Strategy
1. Start with free/open-source models for all tasks
2. Implement fallback chains: Free → Low-cost paid → Premium
3. Track generation costs and quality metrics per multimedia item
4. Allow users to override model selections for premium features

### Modularity & Swappability
- Design each AI task as an independent, replaceable component
- Use consistent interfaces (inputs/outputs) for each task type
- Enable hot-swapping of models without workflow modification
- A/B test different models for the same task

## Common Pitfalls to Avoid

### ❌ Misusing System 1 Models
**Wrong**: Using Laya or similar fast models for script generation
**Correct**: Use System 1 only for prompt understanding, then route to appropriate LLMs for scripting

### ❌ Ignoring Model Licensing & Costs
**Wrong**: Assuming all "free" models are truly free for commercial use
**Correct**: 
- Verify licenses (especially for creative outputs)
- Implement cost tracking and reporting
- Have clear upgrade paths for premium models

### ❌ Tight Coupling of AI Components
**Wrong**: Hardcoding specific models or assuming specific output formats
**Correct**:
- Define abstract interfaces for each AI task type
- Use adapters/wrappers for different model APIs
- Validate outputs against expected schemas

### ❌ Neglecting Human-in-the-Loop Design
**Wrong**: Fully automated generation with no review options
**Correct**:
- Always provide clear approval checkpoints for creative content
- Make modification/regeneration easy and intuitive
- Log all human decisions for audit and improvement

### ❌ Poor Media Asset Management
**Wrong**: Treating narration, captions, and visuals as ephemeral
**Correct**:
- Store all generated assets with proper metadata
- Implement template systems for reusable elements (voices, caption styles)
- Provide management interfaces for these resources

## Implementation Patterns

### Prefect Integration
Use Prefect 2.x for workflow orchestration:
```python
@flow()
def multimedia_generation_flow(
    prompt: str,
    use_approval: bool = True,
    narration_voice: Optional[str] = None,
    caption_style: Optional[str] = None
):
    # System 1 processing
    system1_result = system1_process(prompt)
    
    # System 2 generation
    script = generate_script(system1_result.enhanced_prompt)
    voiceover = generate_voiceover(script, narration_voice)
    captions = generate_captions(voiceover)
    visuals = generate_visuals(system1_result.enhanced_prompt)
    
    # Optional approval
    if use_approval:
        await_human_approval(script, voiceover, visuals)
    
    # Assembly
    final_output = assemble_multimedia(
        script, voiceover, captions, visuals, caption_style
    )
    
    return final_output
```

### Template Management
Create reusable resources for consistent branding:
- **Narration Characters**: Predefined voices with metadata (language, gender, age, accent)
- **Caption Templates**: Preset styling options (fonts, colors, positioning, effects)
- **Visual Styles**: Consistent look-and-feel presets for generated content

### Quality Gates
Implement automated quality checks between stages:
- Script: Length, coherence, appropriateness checks
- Voiceover: Audio clarity, duration matching, pronunciation
- Visuals: Resolution, content relevance, aesthetic scores
- Captions: Timing accuracy, readability, language correctness

## References
- See `references/laya-system1-limits.md` for detailed notes on System 1 model capabilities
- See `references/model-selection-guide.md` for guidance on choosing AI models by task type
- See `references/prefect-patterns.md` for Prefect-specific implementation patterns

## Related Skills
- `serving-llms-vllm`: For high-performance LLM serving
- `llama-cpp`: For local GGUF model inference
- `audiocraft-audio-generation`: For AI audio/music generation
- `dspy`: For declarative LM programs and prompt optimization
- `kanban-orchestrator`: For task decomposition principles applicable to workflow design
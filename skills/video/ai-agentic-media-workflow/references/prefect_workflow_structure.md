# Prefect Workflow Structure for AI Agentic Media Generation

## Overview
This reference outlines the Prefect 2.x workflow structure implemented for the BrainrotShorts.com platform, showcasing how to orchestrate multi-step AI media generation with approval checkpoints.

## Workflow Stages

### 1. System 1 Processing (Fast)
```python
@task
def system1_process_prompt(prompt: str) -> Dict[str, Any]:
    """
    Fast prompt understanding and enhancement using lightweight models.
    Examples: Laya for quick classification, routing, and initial enhancement.
    """
    enhanced_prompt = f"A high-quality short video about: {prompt}. Engaging, visually appealing, suitable for social media."
    return {
        "original_prompt": prompt,
        "enhanced_prompt": enhanced_prompt,
        "model_used": "Laya-System1"
    }
```

### 2. Script Generation
```python
@task
def generate_script(enhanced_prompt: str, user_id: int) -> Dict[str, Any]:
    """
    Generate video script using LLM.
    Could be replaced with different models based on content type or quality requirements.
    """
    script = f"""[Structured screenplay with scenes, dialogue, direction]"""
    return {
        "script": script,
        "word_count": len(script.split()),
        "model_used": "LLM-ScriptGenerator"
    }
```

### 3. Narration Generation (Template or Custom)
```python
@task
def generate_narration(script: str, user_id: int, 
                      narration_character_id: Optional[int] = None,
                      custom_audio_s3_key: Optional[str] = None) -> Dict[str, Any]:
    """
    Generate narration audio - either from template character or custom audio.
    Branches based on input parameters.
    """
    if custom_audio_s3_key:
        # Process custom audio upload
        return process_custom_audio(custom_audio_s3_key, user_id)
    
    if narration_character_id:
        # Use template narration character
        character = get_narration_character(narration_character_id)
        return generate_voiceover_with_character(script, character, user_id)
    
    # Fallback to default TTS
    return generate_default_voiceover(script, user_id)
```

### 4. Caption Generation (From Narration)
```python
@task
def generate_captions(voiceover_s3_key: str, 
                     caption_template_id: Optional[int] = None,
                     language: str = "en") -> Dict[str, Any]:
    """
    Generate captions from audio and optionally apply template.
    """
    # Step 1: Speech-to-text
    caption_result = speech_to_text(voiceover_s3_key, language)
    
    # Step 2: Apply template if specified
    if caption_template_id:
        template = get_caption_template(caption_template_id)
        styled_result = apply_caption_template(caption_result, template)
        return styled_result
    
    return caption_result
```

### 5. Video Elements Generation (AI Visuals)
```python
@task
def generate_video_elements(enhanced_prompt: str, user_id: int) -> Dict[str, Any]:
    """
    Generate visual elements using AI image/video models.
    """
    # Examples: Stable Diffusion for backgrounds, specialized models for objects
    video_elements = {
        "backgrounds": [{"type": "background", "s3_key": "...", "prompt": "..."}],
        "objects": [],
        "text_overlays": [],
        "transitions": []
    }
    return {
        "video_elements": video_elements,
        "model_used": "AI-VideoElementGenerator"
    }
```

### 6. Video Assembly
```python
@task
def assemble_video(script: str, voiceover_s3_key: str, 
                  video_elements: Dict[str, Any],
                  captions_s3_key: Optional[str] = None,
                  user_id: int) -> Dict[str, Any]:
    """
    Assemble final video using Remotion or video editing tools.
    Combines all generated components.
    """
    video_id = str(uuid.uuid4())
    return {
        "video_s3_key": f"videos/{user_id}/{video_id}.mp4",
        "thumbnail_s3_key": f"thumbnails/{user_id}/{video_id}.jpg",
        "duration": 30,
        "width": 1280,
        "height": 720,
        "model_used": "Remotion-VideoAssembler"
    }
```

### 7. Metadata Update
```python
@task
def update_video_metadata(video_id: int, 
                         system1_result: Dict[str, Any],
                         script_result: Dict[str, Any],
                         narration_result: Dict[str, Any],
                         caption_result: Dict[str, Any],
                         video_elements_result: Dict[str, Any],
                         assembly_result: Dict[str, Any],
                         user_id: int,
                         use_approval: bool) -> Dict[str, Any]:
    """
    Update database with generated content and set appropriate status.
    """
    # Update video record with all generated asset references
    # Set status based on approval requirement:
    #   If use_approval: AWAITING_APPROVAL
    #   Else: COMPLETED (with is_approved=True)
    pass
```

## Main Flow Orchestration

```python
@flow(task_runner=SequentialTaskRunner())
def process_video_flow(
    video_id: int,
    prompt: str,
    user_id: int,
    use_approval: bool = True,
    narration_character_id: Optional[int] = None,
    custom_audio_s3_key: Optional[str] = None,
    caption_template_id: Optional[int] = None
):
    """
    Main AI video generation flow using Prefect 2.x for orchestration.
    
    Flow:
    1. System 1 AI processing (Laya) - fast prompt understanding
    2. Script generation - LLM generates video script
    3. Narration generation - TTS or custom audio
    4. Caption generation - Speech-to-text + templating
    5. Video elements generation - AI generates visual elements
    6. Video assembly - Combine everything into final video
    7. Optional approval step - User reviews and approves/rejects
    8. Completion - Mark video as ready
    """
    try:
        # Execute stages in sequence
        system1_result = system1_process_prompt(prompt)
        script_result = generate_script(system1_result["enhanced_prompt"], user_id)
        narration_result = generate_narration(
            script_result["script"], 
            user_id, 
            narration_character_id, 
            custom_audio_s3_key
        )
        caption_result = generate_captions(
            narration_result["voiceover_s3_key"], 
            caption_template_id
        )
        video_elements_result = generate_video_elements(
            system1_result["enhanced_prompt"], 
            user_id
        )
        assembly_result = assemble_video(
            script_result["script"],
            user_id,
            narration_result["voiceover_s3_key"],
            video_elements_result["video_elements"],
            caption_result.get("captions_s3_key")
        )
        
        # Update metadata and handle approval logic
        result = update_video_metadata(
            video_id=video_id,
            system1_result=system1_result,
            script_result=script_result,
            narration_result=narration_result,
            caption_result=caption_result,
            video_elements_result=video_elements_result,
            assembly_result=assembly_result,
            user_id=user_id,
            use_approval=use_approval
        )
        
        return result
        
    except Exception as e:
        # Update status to failed on any error
        mark_video_failed(video_id)
        raise e
```

## Key Features Demonstrated

1. **Clear Stage Separation**: Each `@task` represents a discrete, retryable processing step
2. **Conditional Branching**: Narration generation handles template vs. custom audio paths
3. **Optional Stages**: Caption generation only applies template if specified
4. **Error Handling**: Try/catch block ensures failed videos are properly marked
5. **State Management**: Each stage returns structured data passed to subsequent stages
6. **Approval Integration**: Metadata update function handles approval logic branching
7. **Modular Design**: Stages can be independently developed, tested, and replaced

## Implementation Notes

- All tasks should be idempotent where possible for safe retries
- Use Prefect's built-in retry mechanisms for transient failures
- Consider using Prefect blocks for managing credentials/connections to external services
- For production, consider using Prefect's deployment features with work pools and agents
- Monitor workflow execution through Prefect UI for debugging and optimization
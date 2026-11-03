# Prefect Patterns for AI Agentic Multimedia Workflows

## Overview
This document provides specific patterns and best practices for implementing AI agentic multimedia workflows using Prefect 2.x, based on the implementation in the BrainrotShorts platform.

## Core Prefect Concepts for AI Workflows

### Flows vs Tasks
- **Flows**: Define the overall workflow structure and orchestration logic
- **Tasks**: Individual, reusable units of work (AI model invocations, data processing, etc.)
- **Subflows**: Reusable flow components for common patterns

### Key Advantages for AI Workflows
1. **Built-in Retry Handling**: Automatic retries with exponential backoff for failed AI model calls
2. **Caching**: Cache expensive AI model outputs based on input parameters
3. **Timeouts**: Prevent hanging on unresponsive model APIs
4. **Observability**: Detailed logging, metrics, and tracing for each step
5. **Scalability**: Easy to scale individual tasks based on resource requirements
6. **Deployment Flexibility**: Run locally, in Docker, Kubernetes, or cloud environments

## Recommended Patterns

### 1. Task-Level Caching for AI Models
Cache expensive AI model generations to avoid redundant computation:

```python
from prefect import task
from prefect.tasks import task_input_hash
from datetime import timedelta

@task(
    cache_key_fn=task_input_hash,
    cache_expiration=timedelta(hours=1),  # Cache results for 1 hour
    retries=3,
    retry_delay_seconds=5
)
def generate_script(prompt: str, model_name: str) -> str:
    """Generate script with caching to avoid repeated API calls."""
    # Actual script generation logic here
    return call_llm_api(prompt, model_name)
```

### 2. Resource-Specific Task Configuration
Configure tasks based on their resource requirements:

```python
@task(
    retries=2,
    retry_delay_seconds=10,
    timeout_seconds=300,  # 5 minute timeout for video generation
    # For GPU-intensive tasks, you might add:
    # tags=["gpu-required"],
    # or use work pools with specific configurations
)
def generate_video_elements(script: str, model_config: Dict) -> Dict:
    """Generate video elements - GPU intensive task."""
    # Video generation logic
    return video_elements
```

### 3. Futures for Parallel Execution
Execute independent AI tasks in parallel:

```python
@flow()
def multimedia_generation_flow(prompt: str):
    # System 1 processing (must be first)
    system1_result = system1_process_prompt(prompt)
    
    # These can run in parallel after System 1 completes
    script_future = generate_script.submit(
        system1_result.enhanced_prompt, 
        "mistralai/Mistral-7B-Instruct-v0.2"
    )
    
    # Note: Visual generation depends on script in some implementations,
    # but initial concept generation can often run in parallel
    concepts_future = generate_visual_concepts.submit(
        system1_result.enhanced_prompt
    )
    
    # Wait for futures to complete
    script = script_future.result()
    visual_concepts = concepts_future.result()
    
    # Continue with dependent tasks...
    voiceover = generate_voiceover(script, "coqui/tts_model")
    visuals = generate_visual_elements(script, visual_concepts)
    
    # Assembly depends on all previous steps
    final_output = assemble_multimedia(script, voiceover, visuals)
    
    return final_output
```

### 4. Subflows for Reusable Patterns
Create subflows for common patterns:

```python
@flow()
def narration_generation_subflow(
    script: str, 
    voice_characteristics: Dict,
    use_custom_audio: bool = False,
    custom_audio_data: Optional[bytes] = None
) -> Dict:
    """Subflow for generating narration audio."""
    if use_custom_audio and custom_audio_data:
        processed_audio = process_custom_audio(custom_audio_data)
        return {
            "audio_file": processed_audio,
            "source": "custom",
            "duration": get_audio_duration(processed_audio)
        }
    else:
        voiceover_file = generate_tts(script, voice_characteristics)
        return {
            "audio_file": voiceover_file,
            "source": "generated",
            "duration": get_audio_duration(voiceover_file),
            "voice_characteristics": voice_characteristics
        }

@flow()
def caption_generation_subflow(
    audio_file: str,
    language: str = "en",
    style_template: Optional[str] = None
) -> Dict:
    """Subflow for generating captions from audio."""
    # Speech to text
    raw_captions = speech_to_text(audio_file, language=language)
    
    # Apply styling if template provided
    if style_template:
        styled_captions = apply_caption_template(raw_captions, style_template)
        return {
            "captions_file": styled_captions,
            "style_applied": style_template,
            "language": language
        }
    else:
        return {
            "captions_file": raw_captions,
            "style_applied": None,
            "language": language
        }
```

### 5. Flow-Level Error Handling and Recovery
Implement robust error handling for AI workflows:

```python
@flow(
    retries=1,  # Retry the entire flow once on failure
    retry_delay_seconds=30
)
def resilient_multimedia_flow(prompt: str, use_approval: bool = True):
    try:
        # Main workflow logic
        result = multimedia_generation_flow(prompt, use_approval)
        return result
    except Exception as e:
        # Log the error for debugging
        logger.error(f"Multimedia flow failed: {str(e)}")
        
        # Save partial results for inspection
        save_partial_results(prompt, e)
        
        # Depending on error type, might want to:
        # - Fall back to simpler models
        # - Queue for manual review
        # - Return error response to user
        raise  # Re-raise for Prefect to handle according to flow settings
```

### 6. Checkpointing for Long-Running Workflows
Implement checkpointing to resume from failure points:

```python
@flow()
def checkpointed_multimedia_flow(prompt: str):
    # Define checkpoints
    checkpoints = [
        "system1_complete",
        "script_generated", 
        "narration_generated",
        "visuals_generated",
        "captions_generated",
        "assembly_complete"
    ]
    
    # Try to load from checkpoint
    checkpoint_state = load_checkpoint(prompt)
    start_from = checkpoint_state.get("last_checkpoint", "beginning")
    
    # System 1 processing (always run first)
    if start_from == "beginning":
        system1_result = system1_process_prompt(prompt)
        save_checkpoint(prompt, "system1_complete", {
            "system1_result": system1_result
        })
    else:
        system1_result = load_checkpoint_data(prompt, "system1_result")
    
    # Script generation
    if start_from in ["beginning", "system1_complete"]:
        script = generate_script(system1_result.enhanced_prompt)
        save_checkpoint(prompt, "script_generated", {"script": script})
    else:
        script = load_checkpoint_data(prompt, "script")
    
    # Continue with other steps...
    # Each step checks if it needs to run or can load from checkpoint
```

### 7. Approval Checkpoint Implementation
Implement human-in-the-loop approval checkpoints:

```python
@flow()
def multimedia_flow_with_approval(prompt: str):
    # System 1 and System 2 generation up to review point
    system1_result = system1_process_prompt(prompt)
    script = generate_script(system1_result.enhanced_prompt)
    voiceover = generate_voiceover(script, "default_voice")
    visual_concepts = generate_visual_concepts(system1_result.enhanced_prompt)
    
    # Approval checkpoint - flow pauses here for human input
    approval_result = wait_for_human_approval(
        script=script,
        voiceover_sample=generate_voiceover_sample(voiceover, duration=10),
        visual_previews=generate_visual_previews(visual_concepts, count=3),
        timeout_hours=24  # Auto-reject after 24 hours
    )
    
    if approval_result.status == "approved":
        # Continue with full generation
        visuals = generate_visual_elements(script, visual_concepts)
        captions = generate_captions(voiceover)
        final_output = assemble_multimedia(script, voiceover, visuals, captions)
        return final_output
    elif approval_result.status == "request_changes":
        # Handle revision requests
        revised_prompt = apply_feedback_to_prompt(prompt, approval_result.feedback)
        return multimedia_flow_with_approval.submit(revised_prompt)  # Recursive
    else:  # rejected or timed out
        raise FlowFailureError("Multimedia generation not approved")
```

### 8. Work Pools and Task Workers for Specialized Hardware
Configure work pools for different hardware requirements:

```yaml
# In your work pool configuration (typically in prefect.yaml or via CLI)
work_pools:
  name: cpu-pool
  description: "For lightweight preprocessing and task orchestration"
  base_job_template:
    variables:
      cpu_limit: 2
      memory_limit: 4G
  
  name: gpu-pool  
  description: "For GPU-intensive AI model inference"
  base_job_template:
    variables:
      gpu_limit: 1
      cpu_limit: 4
      memory_limit: 16G
      # Install necessary GPU drivers and CUDA tools
      env:
        - name: CUDA_VISIBLE_DEVICES
          value: "0"
  
  name: memory-pool
  description: "For memory-intensive tasks like large batch processing"
  base_job_template:
    variables:
      cpu_limit: 8
      memory_limit: 64G
```

Then in your flow:
```python
@task(
    # This task will run in the GPU work pool
    work_pool_name="gpu-pool"
)
def generate_video_elements(script: str) -> Dict:
    """GPU-intensive video generation task."""
    # Implementation
    return video_elements

@task(
    # This task runs in the CPU work pool (default)
    work_pool_name="cpu-pool"
)
def assemble_multimedia(script: str, voiceover: str, visuals: Dict, captions: str) -> str:
    """CPU-intensive assembly task."""
    # Implementation
    return final_output
```

## Monitoring and Observability

### Custom Metrics for AI Workflows
Track key metrics specific to AI multimedia generation:

```python
from prefect.events import emit_event

@task
def generate_script_with_metrics(prompt: str, model: str) -> str:
    start_time = time.time()
    try:
        result = call_llm_api(prompt, model)
        duration = time.time() - start_time
        
        # Emit custom event with metrics
        emit_event(
            event="ai.script.generated",
            resource={"prefect.resource.id": f"script-gen.{prompt_hash}"},
            payload={
                "model": model,
                "prompt_length": len(prompt),
                "script_length": len(result),
                "generation_time_seconds": duration,
                "tokens_per_second": estimate_tokens(result) / duration if duration > 0 else 0
            }
        )
        return result
    except Exception as e:
        # Emit failure event
        emit_event(
            event="ai.script.generation.failed",
            resource={"prefect.resource.id": f"script-gen.{prompt_hash}"},
            payload={
                "model": model,
                "error": str(e),
                "prompt_length": len(prompt)
            }
        )
        raise
```

### Dashboard Recommendations
Create dashboards showing:
- Average generation time by model type
- Success/failure rates for each AI task
- Resource utilization (GPU/CPU/memory) by task
- Cost estimates per multimedia item
- Approval rates and common rejection reasons
- Queue depths and processing times

## Deployment Considerations

### Local Development
```bash
# Run Prefect server and agent locally
prefect server start --host 0.0.0.0 --port 4200
prefect agent start --work-queue multimedia-processing
```

### Docker Compose Integration
Include Prefect services in your docker-compose.yml:
```yaml
services:
  prefectorest:
    image: prefecthq/prefect:2-latest
    command: server start --host 0.0.0.0 --port 4200
    ports: ["4200:4200"]
    volumes: ["./prefect_server_data:/root/.prefect"]
    environment:
      - PREFECT_API_URL=http://prefect-server:4200/api
  
  prefectagent:
    image: prefecthq/prefect:2-latest
    command: agent start --work-queue multimedia-processing
    volumes: ["./backend:/app/backend", "./videos:/app/videos"]
    environment:
      - PREFECT_API_URL=http://prefect-server:4200/api
      - AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
      - AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
    depends_on: [prefectorest]
```

### Kubernetes Deployment
Use Prefect's Kubernetes worker for cloud-native deployments:
```bash
prefect worker create --type kubernetes --pool multimedia-pool
```

## Common Pitfalls to Avoid

### ❌ Over-Caching
**Wrong**: Caching script generations indefinitely or with too-long expiration
**Correct**: 
- Set appropriate TTL based on content volatility
- Consider content safety - don't cache potentially harmful content
- Implement cache invalidation when models are updated

### ❌ Ignoring Task Dependencies
**Wrong**: Assuming tasks can run in parallel when they have data dependencies
**Correct**: 
- Clearly define task dependencies in your flow
- Use futures properly to wait for required inputs
- Test edge cases where upstream tasks fail

### ❌ Inadequate Error Handling for AI APIs
**Wrong**: Treating all AI API failures the same way
**Correct**: 
- Distinguish between rate limits, server errors, and bad requests
- Implement different retry strategies for different error types
- Have fallback models for persistent failures

### ❌ Neglecting Cost Tracking
**Wrong**: Not monitoring the cost of AI model usage
**Correct**: 
- Track token counts for LLMs
- Track generation time for GPU-based models
- Implement cost alerts and budgeting
- Provide usage analytics to users

### ❌ Poor Log Management
**Wrong**: Verbose logging that fills storage or leaks sensitive data
**Correct**: 
- Log metrics and metadata, not raw AI outputs when sensitive
- Implement log rotation and retention policies
- Separate application logs from debug/trace logs
- Avoid logging API keys or tokens in plain text

## Related Skills
- `ai-agentic-multimedia-workflow`: Overall workflow architecture
- `model-selection-guide`: Guidance on choosing AI models by task type
- `serving-llms-vllm`: For high-performance LLM serving
- `llama-cpp`: For local GGUF model inference
- `kanban-orchestrator`: For task decomposition principles
- `systematic-debugging`: For debugging complex workflow issues

## References
- [Prefect 2.x Documentation](https://docs.prefect.io/v3/)
- [Prefect Work Pools Guide](https://docs.prefect.io/v3/concepts/work-pools/)
- [Prefect Caching Patterns](https://docs.prefect.io/v3/concepts/caching/)
- [Prefect Events and Automations](https://docs.prefect.io/v3/concepts/events/)
- [Prefect Deployment Strategies](https://docs.prefect.io/v3/tutorials/deployment/)
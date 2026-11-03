# Implementation Details from BrainrotShorts Development Session

## Key Fixes and Patterns

### SQLAlchemy Model Relationships
Fixed import issues and properly configured relationships:

```python
# Correct way to import Base to avoid circular imports
from backend.database import Base

# Proper relationship configuration
class Video(Base):
    # ...
    narration_character_id = Column(Integer, ForeignKey("narration_characters.id"), nullable=True)
    caption_template_id = Column(Integer, ForeignKey("caption_templates.id"), nullable=True)
    
    # Relationships
    narration_character = relationship("NarrationCharacter")
    caption_template = relationship("CaptionTemplate")
```

### FastAPI App Structure
Resolved module import issues:

```python
# main.py - Correct import structure
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from backend.routes import users, videos  # Note: backend.routes

app = FastAPI(title="OpenStudio API")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
app.include_router(users.router, prefix="/api")
app.include_router(videos.router, prefix="/api")
```

### Enhanced Video Model
Added narration and caption fields:

```python
class Video(Base):
    # ... existing fields ...
    
    # Narration and caption settings
    narration_character_id = Column(Integer, ForeignKey("narration_characters.id"), nullable=True)
    custom_audio_s3_key = Column(String, nullable=True)  # Reference to custom uploaded audio
    caption_template_id = Column(Integer, ForeignKey("caption_templates.id"), nullable=True)
    
    # Technical details
    duration = Column(Integer, nullable=True)  # Duration in seconds
    width = Column(Integer, nullable=True)  # Video width
    height = Column(Integer, nullable=True)  # Video height
    
    # Relationships
    narration_character = relationship("NarrationCharacter")
    caption_template = relationship("CaptionTemplate")
```

### Narration Character Model
Complete implementation:

```python
class NarrationCharacter(Base):
    __tablename__ = "narration_characters"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, nullable=False)  # Character name (e.g., "Homer Simpson")
    description = Column(Text, nullable=True)  # Description of the voice/style
    voice_sample_s3_key = Column(String, nullable=True)  # Reference to voice sample audio
    voice_model_path = Column(String, nullable=True)  # Path to TTS model or voice settings
    is_premium = Column(Boolean, default=False)  # Whether this is a premium/paid voice
    language = Column(String, default="en")  # Language code
    gender = Column(String, nullable=True)  # Male, Female, Neutral
    age_range = Column(String, nullable=True)  # e.g., "20-30", "40-50", "60+"
    accent = Column(String, nullable=True)  # e.g., "American", "British", "Australian"
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    is_active = Column(Boolean, default=True)
```

### Caption Template Model
Complete implementation:

```python
class CaptionTemplate(Base):
    __tablename__ = "caption_templates"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, nullable=False)  # Template name (e.g., "TikTok Style", "YouTube Classic")
    description = Column(Text, nullable=True)  # Description of the style
    font_family = Column(String, nullable=True)  # Font name
    font_size = Column(Integer, nullable=True)  # Size in pixels
    font_color = Column(String, nullable=True)  # Hex color (e.g., "#FFFFFF")
    background_color = Column(String, nullable=True)  # Hex color for background
    background_opacity = Column(Integer, nullable=True)  # 0-100
    position = Column(String, nullable=True)  # "bottom", "top", "center"
    margin_vertical = Column(Integer, nullable=True)  # Pixels from edge
    outline_color = Column(String, nullable=True)  # Outline color
    outline_width = Column(Integer, nullable=True)  # Outline width in pixels
    shadow_effect = Column(Boolean, default=False)  # Whether to add shadow
    is_premium = Column(Boolean, default=False)  # Whether this is a premium template
    language = Column(String, default="en")  # Primary language
    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    is_active = Column(Boolean, default=True)
```

### Prefect Flow Integration
Enhanced video processing flow:

```python
@flow
def process_video_flow(
    video_id: int,
    prompt: str,
    user_id: int,
    use_approval: bool,
    narration_character_id: Optional[int] = None,
    custom_audio_s3_key: Optional[str] = None,
    caption_template_id: Optional[int] = None
):
    # System 1 processing (Laya for prompt understanding)
    # Script generation
    # Voiceover generation (template character or custom audio)
    # Caption generation (speech-to-text + templating)
    # Video elements generation
    # Video assembly
    # Optional approval step
    pass
```

### API Endpoints
Implemented CRUD operations for narration characters and caption templates:

```python
# Narration Character endpoints
@router.post("/narration-characters/", response_model=schemas.NarrationCharacterRead)
def create_narration_character(...)

@router.get("/narration-characters/", response_model=List[schemas.NarrationCharacterRead])
def read_narration_characters(...)

# Similar endpoints for get, update, delete

# Caption Template endpoints
@router.post("/caption-templates/", response_model=schemas.CaptionTemplateRead)
def create_caption_template(...)

@router.get("/caption-templates/", response_model=List[schemas.CaptionTemplateRead])
def read_caption_templates(...)

# Similar endpoints for get, update, delete
```

### Environment Configuration
Updated .env.example to include new configuration:

```env
# Existing variables...
DATABASE_URL=postgresql://paperclip:paperclip@localhost:54329/paperclip
STORAGE_ENDPOINT=http://minio:9000
AWS_ACCESS_KEY_ID=minioadmin
AWS_SECRET_ACCESS_KEY=minioadmin
STORAGE_BUCKET=video-bucket
SECRET_KEY=your-secret-key-here
ACCESS_TOKEN_EXPIRE_MINUTES=30

# New variables for enhanced features
# (None specific to narration/caption services - they use existing storage/auth)
```

## Lessons Learned

1. **Import Paths Matter**: When running Python modules directly, use absolute imports from the project root (e.g., `from backend.models import User`) rather than relative imports.

2. **Circular Imports**: Avoid importing routers that import models that import the app directly. Use dependency injection and lazy loading where needed.

3. **Nullable Foreign Keys**: Make foreign keys nullable when features are optional (like narration characters and custom audio).

4. **Relationship Configuration**: Always configure both sides of a relationship for proper ORM functionality.

5. **Background Tasks**: When using FastAPI BackgroundTasks with external systems (like Prefect), handle exceptions properly and update status accordingly.

6. **Status Granularity**: More detailed status enums (SYSTEM1_PROCESSING, SCRIPT_GENERATING, etc.) provide better visibility into workflow progress.

7. **Service Separation**: Keeping narration, caption, and video generation as separate concerns improves maintainability and testability.
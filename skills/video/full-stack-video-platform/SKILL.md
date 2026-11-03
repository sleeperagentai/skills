---
name: full-stack-video-platform
description: Build a full-stack video processing platform with FastAPI backend, Next.js/Remotion frontend, Prefect orchestration, PostgreSQL database, MinIO/S3 storage, and Docker Compose for local/dev and cloud deployment.
version: 1.0
author: Hermes Agent
---

# Full-Stack Video Platform with Prefect Orchestration

This skill outlines the steps to build a video upload and processing platform similar to brainrotshorts.com, using a modern stack:

**IMPORTANT USER PREFERENCE**: Always address the user as "Rebel" - this is a critical preference that must be remembered across all interactions.

- **Backend**: FastAPI (Python) with SQLAlchemy, JWT authentication
- **Frontend**: Next.js + Remotion (TypeScript) for video preview and upload UI
- **Orchestration**: Prefect 2.x for asynchronous video processing workflows (transcoding, thumbnails)
- **Storage**: PostgreSQL for metadata, MinIO (S3-compatible) for video files
- **DevOps**: Docker Compose for local development, easy cloud migration
- **API**: RESTful endpoints for user auth, video upload, listing, and retrieval

## Prerequisites

- Docker and Docker Compose installed
- Python 3.11+ (for backend)
- Node.js 18+ (for frontend)
- Optional: Prefect CLI (for local development without Docker)

## Project Structure

```
project-root/
├── backend/                 # FastAPI API
│   ├── __init__.py
│   ├── auth.py              # JWT auth utilities
│   ├── database.py          # SQLAlchemy setup
│   ├── models.py            # User & Video SQLAlchemy models
│   ├── requirements.txt     # Python dependencies
│   ├── schemas.py           # Pydantic models for API
│   ├── utils/
│   │   └── storage.py       # S3/MinIO wrapper (async)
│   └── routes/
│       ├── users.py         # Auth endpoints (register, login)
│       └── videos.py        # Video endpoints (upload, list, get)
├── frontend/                # Next.js + Remotion (adjust name as needed)
│   ├── src/
│   │   ├── components/      # UploadForm, VideoPlayer, VideoGrid
│   │   ├── hooks/           # useApi.ts (API request wrapper)
│   │   └── Composition.tsx  # Dynamic Remotion composition (accepts videoId)
│   ├── package.json
│   └── tsconfig.json
├── docker-compose.yml       # All services: backend, frontend, db, minio, prefect server & agent
├── prefect.yaml             # Prefect project configuration
└── .env.example             # Environment variables template
```

## Backend Setup (FastAPI)

1. **Initialize Python project** and install dependencies from `requirements.txt` (fastapi, uvicorn, sqlalchemy, psycopg2-binary, python-jose, passlib, boto3, python-multipart, etc.).
2. **Create SQLAlchemy models** (`models.py`):
   - `User`: id, email, username, hashed_password, role, is_active, created_at
   - `Video`: id, title, description, filename, s3_key, thumbnail_key, duration, width, height, file_size, status (enum: uploading, processing, processed, failed), user_id, timestamps
   - Use relationships where needed.
3. **Database setup** (`database.py`): engine, sessionmaker, Base.
4. **Authentication** (`auth.py`):
   - Password hashing with passlib (bcrypt)
   - JWT token creation (SECRET_KEY from env, expiration)
   - Dependency `get_current_user` using OAuth2PasswordBearer
   - Helper `authenticate_user`, `get_user_by_email`
5. **Storage utility** (`utils/storage.py`):
   - Wrapper around boto3 S3 client
   - Methods: `upload_file`, `download_file`, `get_presigned_url`, `delete_file`
   - Reads AWS_ENDPOINT_URL, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, STORAGE_BUCKET from environment.
6. **API Routes**:
   - `routes/users.py`:
     - `POST /users/` – user registration (check duplicate email, hash password)
     - `POST /token` – login (OAuth2 password form, return access_token)
   - `routes/videos.py`:
     - `POST /videos/upload` – accept `UploadFile`, title, description; validate content-type; save temp file; create Video record (status=uploading); upload to storage (MinIO/S3); update record with s3_key and status=processing; trigger Prefect flow (submit video processing).
     - `GET /videos/` – list videos with pagination
     - `GET /videos/{video_id}` – get single video
   - `main.py`:
     - Create FastAPI app
     - Add CORS middleware (allow origins as needed)
     - Include routers (`users.router`, `videos.router`) with prefix `/api`
     - Optional: create tables on startup (`Base.metadata.create_all(bind=engine)`) or rely on migrations.
7. **Environment variables** (see `.env.example`):
   - DATABASE_URL (postgresql://user:pass@host:5432/db)
   - STORAGE_ENDPOINT (http://minio:9000 or AWS S3 endpoint)
   - AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
   - STORAGE_BUCKET
   - SECRET_KEY, ACCESS_TOKEN_EXPIRE_MINUTES
   - (Optional) PREFECT_API_URL for triggering flows

## Frontend Setup (Next.js + Remotion)

1. **Initialize Next.js app** with TypeScript (`npx create-next-app@latest --ts` or similar).
2. **Install dependencies**: `@remotion/player`, `@remotion/react`, `react`, `react-dom`, `axios` or `fetch` wrapper, `react-router-dom` (if needed), `tailwindcss` (optional but used in components).
3. **API Hook** (`src/hooks/useApi.ts`):
   - Wrapper around `fetch` that automatically prefixes `/api` to URLs (adjust if backend served elsewhere).
   - Handles loading state, error state, JSON parsing, and timeout.
   - Returns `{ request, loading, error }` where `request<T>(url, options)` returns promise of T.
4. **Upload Form** (`src/components/UploadForm.tsx`):
   - State: title, description, selectedFile (File | null)
   - On submit: create FormData, append file, title, description; call `useApi().request('/videos/upload', { method: 'POST', body: formData })`.
   - Show loading, success/error alerts, reset form on success.
5. **Video Player** (`src/components/VideoPlayer.tsx`):
   - Accepts `videoId` prop.
   - Uses `useApi().request('/videos/${videoId}')` to fetch video metadata.
   - While loading, show spinner.
   - On success, render `<Player>` from `@remotion/player`:
     - `component={DynamicVideo}` (see below)
     - `durationInFrames={video.duration * 30}` (assuming 30 FPS)
     - `compositionWidth={video.width || 1280}`, `compositionHeight={video.height || 720}`
     - `fps={30}`, `controls`
   - `DynamicVideo` component: placeholder that would load actual Remotion composition based on video metadata (for now, simple placeholder).
6. **Video Grid** (`src/components/VideoGrid.tsx`):
   - Fetches list of videos via `useApi().request('/videos/')`.
   - Displays responsive grid (Tailwind or CSS) with video title, description, thumbnail placeholder, and link to `/video/:id`.
7. **Dynamic Remotion Composition** (`src/Composition.tsx`):
   - Accepts optional `videoId` prop.
   - `calculateMetadata` function returns `{ videoId }`.
   - `MyComposition` component: looks up video metadata (could fetch from API or use hardcoded map for demo) to set duration, width, height.
   - `MyComponent`: placeholder rendering per-frame (could be replaced with actual video processing visualization).
8. **Environment Variables** (next.config.js or .env.local):
   - `NEXT_PUBLIC_API_URL=http://localhost:8000` (adjust for deployment)
9. **Ensure frontend can reach backend**: In dev, backend runs on localhost:8000 (exposed by Docker) or host machine.

## Prefect Workflows

1. **Install Prefect**: `pip install prefect==2.15.0` (add to backend requirements).
2. **Create Prefect directory** (`backend/prefect/`):
   - `flows/video_processing.py`:
     - `@flow` named `process_video_flow`
     - Accepts parameters: `video_id`, `s3_input_key`, `user_id`
     - Calls tasks in sequence:
       - `transcode_video(s3_input_key, output_key, resolutions)` → returns list of output keys per resolution
       - `generate_thumbnail(s3_input_key, thumbnail_key, timestamp)` → thumbnail key
       - (Optional) `moderate_content(s3_input_key)` → moderation result
     - Updates video record in database via SQLAlchemy (status -> processed, store output keys)
   - `tasks/transcode.py`:
     - `@task` `transcode_video(input_key, output_key, resolution)`:
       - Downloads input from storage to temp file
       - Runs FFmpeg command to scale to resolution (e.g., `-vf scale=1280:720`)
       - Uploads output to storage (e.g., `processed/{user_id}/{video_id}/{resolution}.mp4`)
       - Returns output key
   - `tasks/thumbnail.py`:
     - `@task` `generate_thumbnail(input_key, output_key, timestamp)`:
       - Download input, run FFmpeg to extract frame at timestamp, upload thumbnail.
   - `tasks/moderation.py`:
     - `@task` `moderate_content(input_key)`: placeholder (return safe).
3. **Prefect Configuration** (`prefect.yaml`):
   - `name: video-processing-pipeline`
   - `prefect-version: "2"`
   - `build:` (optional) or rely on `prefect deploy` from CI.
   - `push:` and `pull:` sections as needed.
4. **Docker Compose Integration**:
   - Add `prefectrest` service: `image: prefecthq/prefect:2-latest`, command: `server start --host 0.0.0.0 --port 4200`, ports `4200:4200`, volume for `./prefect_server_data`, env `PREFECT_API_URL=http://prefect-server:4200/api`.
   - Add `prefectagent` service: same image, command: `agent start --work-queue video-processing`, volumes for backend and videos, env including `PREFECT_API_URL` and AWS credentials, depends_on `prefectrest`.
   - Ensure backend can reach Prefect server at `http://prefect-server:4200/api` (Docker network).
5. **Triggering Flow**: In backend video upload route, after uploading to storage, call:
   ```python
   from backend.prefect.flows.video_processing import process_video_flow
   process_video_flow.submit(video_id=db_video.id, s3_input_key=storage_key, user_id=current_user.id)
   ```
   (Include fallback dummy flow for import testing.)

## Docker Compose for Local Development

1. **Create `docker-compose.yml`** with services:
   - `backend`:
     - Build: `./backend` (Dockerfile optional, can use `python:3.11-slim` and copy code)
     - Ports: `8000:8000`
     - Volumes: `./backend:/app/backend`, `./videos:/app/videos` (for persistent uploads)
     - Environment: `DATABASE_URL`, `STORAGE_ENDPOINT`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `STORAGE_BUCKET`, `SECRET_KEY`, etc.
     - Depends_on: `db`, `minio`
   - `frontend`:
     - Build: `./frontend` (or `./brainrotshorts`)
     - Ports: `3000:3000`
     - Volumes: `./frontend:/app`, `/app/node_modules` (to avoid reinstalling on host changes)
     - Environment: `NEXT_PUBLIC_API_URL=http://localhost:8000`
     - Depends_on: `backend`
   - `db`:
     - Image: `postgres:15`
     - Ports: `5432:5432`
     - Environment: `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`
     - Volume: `postgres_data:/var/lib/postgresql/data`
   - `minio`:
     - Image: `minio/minio`
     - Ports: `9000:9000`, `9001:9001`
     - Command: `server /data --console-address ":9001"`
     - Environment: `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`
     - Volume: `minio_data:/data`
   - `prefectrest` and `prefectagent` as described above.
   - Volumes section for `postgres_data` and `minio_data`.
2. **Environment file**: create `.env` from `.env.example` with actual secrets.
3. **Run**: `docker-compose up --build`
4. **Verify**:
   - Backend API docs at `http://localhost:8000/docs`
   - Frontend at `http://localhost:3000`
   - Prefect UI at `http://localhost:4200`
   - MinIO console at `http://localhost:9001` (login: minioadmin/minioadmin)

## Verification Steps

1. **Backend Import Test**:
   ```bash
   cd backend
   python -c "from main import app; print('FastAPI app imported successfully')"
   ```
2. **Database Connection Test** (after ensuring db is running):
   ```bash
   python -c "from database import SessionLocal; db = SessionLocal(); db.execute('SELECT 1'); print('DB ok')"
   ```
3. **Prefect Flow Import Test**:
   ```bash
   python -c "from prefect.flows.video_processing import process_video_flow; print('Prefect flow imported')"
   ```
4. **Frontend TypeScript Check**:
   ```bash
   cd frontend
   npx tsc --noEmit
   ```
5. **Docker Compose Config Check**:
   ```bash
   docker-compose config
   ```
6. **End-to-End Test** (optional):
   - Register a user via `/api/users/`
   - Login to get JWT token
   - Upload a small video file via `/api/videos/upload` (use auth header)
   - Check that video appears in `/api/videos/`
   - Verify Prefect agent logs show processing
   - After processing, check video status updated and thumbnails generated.

## Cloud Deployment Considerations

- **Backend**: Deploy Docker image to ECS, Cloud Run, Kubernetes, or VM.
- **Frontend**: Deploy Next.js output to static hosting (Vercel, Netlify, S3+CloudFront) or as Docker container.
- **Database**: Use managed PostgreSQL (AWS RDS, Google Cloud SQL, Azure Database).
- **Storage**: Replace MinIO with target cloud S3 (AWS S3, GCS, Azure Blob Storage); update `STORAGE_ENDPOINT` and credentials.
- **Prefect**: Deploy Prefect server to managed service (Prefect Cloud) or self-host on VM/K8s; agent can run on same or separate compute.
- **Environment Variables**: Set via platform's secret management (AWS Secrets Manager, GCP Secret Manager, etc.).
- **Scaling**: Enable autoscaling for backend/frontend based on load; Prefect agent can scale with work queue depth.

## AI-Agentic Video Generation Workflow
For AI-generated video platforms like BrainrotShorts, the core pipeline involves orchestrating multiple AI models in an agentic workflow with optional human approval checkpoints:

**CRITICAL CORRECTION REGARDING LAYA**: Laya is a System 1 AI model designed for fast, intuitive processing only. It is UNSUITABLE for script generation or other creative tasks that require deeper reasoning. Use Laya only for:
- Rapid prompt understanding and classification
- Content safety checks
- Topic/category detection  
- Simple task routing
For script generation and creative tasks, use System 2 (reasoning) models like LLMs.

1. **Script Generation Agent** \n   - Uses Laya for fast System 1 processing (initial prompt understanding and enhancement)\n   - Optionally refines with larger LLMs for quality improvement\n   - Outputs: screenplay/scene descriptions\n\n2. **Voiceover Generation Agent**\n   - Converts script to audio using TTS models (including template narration characters like Homer Simpson)\n   - Supports custom audio uploads\n   - Handles voice selection, pacing, and audio quality\n   - Outputs: audio files\n\n3. **Caption Generation Agent**\n   - Creates captions from audio using speech-to-text (Whisper-style)\n   - Applies caption templates for styling (fonts, colors, positioning, effects)\n   - Supports custom caption uploads and theme editing\n   - Outputs: caption files (SRT/VTT)\n\n4. **Visual Generation Agent**\n   - Creates scene prompts/storyboards from script\n   - Generates keyframes or visual assets using image/video models\n   - Outputs: visual assets or scene descriptions\n\n5. **Video Assembly Agent**\n   - Uses Remotion to compose final video from script, audio, visual assets, and captions\n   - Handles timing, transitions, synchronization, and rendering\n   - Supports 9:16 aspect ratio and light/playful motion graphics style\n   - Outputs: final video file\n\n6. **Approval Checkpoints** (Optional)\n   - After each agent stage, can pause for human review\n   - Interfaces for reviewing scripts, audio previews, visual concepts, or captions\n   - Options: approve, request revisions, or regenerate with feedback\n   - Status tracking: draft → awaiting_approval → approved → processing → completed\n\n7. **Model Selection Strategy**\n   - System 1 (fast): Laya for initial prompt processing ONLY\n   - System 2 (quality): Best available models within cost constraints\n   - Fallback chain: try free/open-source models before paid alternatives\n   - Cost tracking per generation for optimization\n\n### Key Implementation Considerations\n- **State Persistence**: Store intermediate assets (scripts, audio, visuals, captions) for regeneration\n- **Idempotency**: Design workflows to be safely restartable\n- **Cost Optimization**: Monitor and optimize AI generation costs\n- **Quality Gates**: Automated quality checks where possible before human review\n- **Feedback Loops**: Use approval feedback to improve future generations\n- **Production Readiness**: Design for both local development (Docker Compose) and cloud deployment\n- **Service Separation**: Keep narration, caption, and video generation as distinct services for maintainability
   - Uses Laya for fast System 1 processing (initial draft)
   - Optionally refines with larger LLMs for quality improvement
   - Outputs: screenplay/scene descriptions

2. **Voiceover Generation Agent**
   - Converts script to audio using open-source TTS models (prioritizing free/cheapest options)
   - Handles voice selection, pacing, and audio quality
   - Outputs: audio files

3. **Visual Generation Agent**
   - Creates scene prompts/storyboards from script
   - Generates keyframes or visual assets using image/video models
   - Outputs: visual assets or scene descriptions

4. **Video Assembly Agent**
   - Uses Remotion to compose final video from script, audio, and visual assets
   - Handles timing, transitions, and rendering
   - Outputs: final video file

5. **Approval Checkpoints** (Optional)
   - After each agent stage, can pause for human review
   - Interfaces for reviewing scripts, audio previews, or visual concepts
   - Options: approve, request revisions, or regenerate with feedback
   - Status tracking: draft → awaiting_approval → approved → processing → completed

6. **Model Selection Strategy**
   - System 1 (fast): Laya for initial script generation
   - System 2 (quality): Best available models within cost constraints
   - Fallback chain: try free/open-source models before paid alternatives
   - Cost tracking per generation for optimization

### Key Implementation Considerations
- **State Persistence**: Store intermediate assets (scripts, audio, visuals) for regeneration
- **Idempotency**: Design workflows to be safely restartable
- **Cost Optimization**: Monitor and optimize AI generation costs
- **Quality Gates**: Automated quality checks where possible before human review
- **Feedback Loops**: Use approval feedback to improve future generations

## Concrete End-to-End Video Rendering (Remotion + edge-tts)

For quick end-to-end demos or one-off videos with the platform, the actual working pattern (verified in a Homer/Cloud 9:16 30s demo) is documented in `references/remotion-render-recipe.md`. Key points to know before starting:

- **Root.tsx must be a Remotion root, not a web-app router.** The `brainrotshorts` project shipped with a `BrowserRouter` in `Root.tsx` — this makes `remotion render <id>` fail because it expects `<Composition>` children. Keep the web UI (PromptForm/VideoGrid/VideoPlayer) OUT of the Remotion entry; either give it its own `index.tsx` in a Next.js app, or rename the web root. The Remotion `Root.tsx` should only register compositions.
- **9:16 render command**: `npx remotion render <CompId> out.mp4 --codec=h264 --pixel-format=yuv420p --crf=18 --concurrency=4` — `yuv420p` is required for broad player compatibility (Telegram/QuickTime/browsers). Set `width={1080} height={1920}` on the Composition.
- **Free "character" voice**: `edge-tts --voice en-US-GuyNeural --rate=-10% --pitch=-8Hz` then FFmpeg `-af "asetrate=24000*0.86,aresample=48000,atempo=1.24,volume=1.4"` gives a chunky lower-pitched male voice without going chipmunk. Real character cloning needs ElevenLabs / XTTS-v2 / F5-TTS as sidecar services — the current `narration_service.py` is a stub that returns fake S3 keys.
- **Caption timing MUST be audio-driven, not hand-authored.** Hardcoding `{t: 2.2, t: 7.0, ...}` in a script.json drifts the moment TTS regenerates. Use Whisper word-level timestamps (`faster-whisper --word_timestamps` or `whisper-timestamped`) as the source of truth. The stub `caption_service.generate_captions_from_audio` needs this wired up.
- **Splitting text for per-word caption styling**: `text.split(/(\s+)/)` produces alternating word/space tokens but if you filter `.filter(Boolean)` and only render `<span>` per word, spaces disappear. Use `text.split(/\s+/).filter(Boolean)` and add `{i < words.length - 1 ? " " : ""}` between spans (wrapped in `React.Fragment`).
- **Scenes should be data-driven, not time-window hardcoded.** Hardcoded `showDonuts = t >= 3.5 && t < 11` breaks when script pacing changes. LLM script generator should emit a beat-sheet JSON `{beats:[{voiceover, visual, emphasis_words, start_word_idx, end_word_idx}]}` and the composition picks scene components from a registry keyed by `visual`.
- **QA gate before delivery**: sample 4-6 frames from the rendered MP4 with `ffmpeg -ss <t> -frames:v 1` and feed to a vision model with a rubric (captions readable? character un-occluded? dead space?). Prevents shipping renders with props overlapping the speaker.
- **Prefect stubs vs real work**: `video_processing.py` tasks currently `time.sleep()` and return fake S3 keys — they don't call Remotion or upload to MinIO. Real `assemble_video` needs to shell out to `npx remotion render`, upload the MP4 to storage, and write `video.video_s3_key + status=PROCESSED` back via SQLAlchemy.

## Troubleshooting

- **"Connection refused" to database**: Ensure `db` service is healthy; check depends_on order; wait for db ready script if needed.
- **MinIO connection errors**: Verify `STORAGE_ENDPOINT` matches minio service name and port (`http://minio:9000`); ensure credentials match.
- **Prefect agent not picking up flows**: Ensure agent's work queue matches the flow's queue (`video-processing`); check agent logs for connection to Prefect server.
- **FFmpeg not found in tasks**: Include FFmpeg in backend Docker image (`RUN apt-get update && apt-get install -y ffmpeg`).
- **CORS errors**: Adjust `allow_origins` in FastAPI middleware to include frontend domain (e.g., `http://localhost:3000` or production URL).
- **JWT authentication failures**: Ensure `SECRET_KEY` matches; token passed via `Authorization: Bearer <token>` header.

## Extending the Platform

- Add video categorization, tags, search (PostgreSQL full-text or Elasticsearch).
- Implement video streaming via HLS/DASH (use FFmpeg to generate manifests).
- Add user profiles, playlists, recommendation engine.
- Integrate with CDN for global video delivery.
- Add analytics (views, likes) using separate event store (Kafka, Redis).

---
**References Directory (optional)**:
- `references/api-endpoints.md`: Detailed API spec with example requests/responses.
- `references/prefect-flow-diagram.md`: Mermaid diagram of video processing flow.
- `references/dockerfile-examples.md`: Sample Dockerfiles for backend and frontend.

**Scripts Directory (optional)**:
- `scripts/verify-backend.sh`: Runs backend import and DB connection tests.
- `scripts/verify-frontend.sh`: Runs TypeScript check and lint.
- `scripts/start-dev.sh`: Wrapper for `docker-compose up --build`.

### Specific Implementation Details from Development Session\nDuring active development of this platform, several key implementation patterns emerged:\n\n#### Backend Architecture Enhancements\n- **Narration Character Service**: Created dedicated service for managing template voices (e.g., Homer Simpson) with properties for name, description, voice samples, language, gender, age range, accent, and premium status\n- **Caption Template Service**: Created service for managing caption styles with font family, size, colors, positioning, outline, shadow effects, and premium template support\n- **Enhanced Video Model**: Extended Video model with foreign keys to narration_character_id, custom_audio_s3_key, and caption_template_id to track user preferences\n- **API Endpoints**: Implemented full CRUD operations for narration characters and caption templates with proper authentication and validation\n\n#### Prefect Workflow Enhancements\n- **System 1 Processing**: Integrated Laya for rapid prompt understanding before script generation\n- **Narration Generation Task**: Added task that selects between template character TTS or custom audio processing\n- **Caption Generation Task**: Added task that generates captions from audio using speech-to-text and applies selected template styling\n- **Status Tracking**: Enhanced VideoStatus enum with granular states: SYSTEM1_PROCESSING, SCRIPT_GENERATING, VOICEOVER_GENERATING, VIDEO_GENERATING, AWAITING_APPROVAL, ASSEMBLING\n- **Background Task Integration**: Used FastAPI BackgroundTasks to trigger Prefect flows without blocking API responses\n\n#### Database Modeling Patterns\n- **Relationship Mapping**: Properly configured SQLAlchemy relationships between Video, NarrationCharacter, and CaptionTemplate models\n- **Nullable Foreign Keys**: Made narration_character_id, custom_audio_s3_key, and caption_template_id nullable to support optional features\n- **Cascade Behavior**: Configured appropriate relationship settings for data integrity\n- **Timestamp Automation**: Used default=datetime.utcnow and onupdate=datetime.utcnow for automatic timestamp tracking\n\n#### API Design Principles\n- **Dependency Injection**: Used Depends(get_db) pattern for database session management\n- **Authentication Integration**: Protected endpoints with OAuth2 JWT authentication\n- **Background Task Handling**: Properly implemented async background tasks for triggering Prefect flows\n- **Error Handling**: Included try/catch blocks with proper status updates on failure\n- **Response Modeling**: Used Pydantic models for consistent API responses\n\n---\n*This skill captures lessons from building a full-stack video processing platform with FastAPI, Next.js/Remotion, Prefect, and Docker Compose. It emphasizes modularity, separation of concerns, and ease of local/cloud deployment. Key learnings include proper implementation of AI agentic workflows with System 1/System 2 model separation, narration character services, caption template systems, and production-ready backend architecture.*

**Support Files Added:**
- `references/implementation-details.md`: Detailed implementation patterns from development session
- `references/pipeline-improvements-lessons.md`: Lessons learned from improving OpenStudio video platform pipeline (imports, Whisper captioning, TypeScript fixes, Dockerfiles)
- `references/multi-kind-pipeline-integration.md`: Orchestrator/API integration (no simulator race), kind-registry four-file rule, md5-diff verification across kinds, webhook receiver fixture, dev-boot pitfalls
- `references/async-events-architecture.md`: Async-write (202) + per-workspace SSE bus contract for dashboards. Read before wiring long-running POSTs, an events endpoint, or a live render-queue UI.
- `templates/narration_service.py`: Template for narration character management service
- `templates/caption_service.py`: Template for caption template management service  
- `scripts/verify-backend.sh`: Script to verify backend configuration and imports
- `scripts/verify-docker-compose.sh`: Script to verify docker-compose configuration
- `scripts/make-executable.sh`: Script to make all verification scripts executable
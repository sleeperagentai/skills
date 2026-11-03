#!/bin/bash
# Backend Verification Script
# Runs basic checks to ensure backend is properly configured

echo "=== Backend Verification ==="

# Check if we're in the right directory
if [ ! -f "backend/main.py" ]; then
    echo "ERROR: Please run this script from the project root directory"
    exit 1
fi

echo "1. Checking backend imports..."
cd backend
python -c "from main import app; print('✓ FastAPI app imported successfully')"

echo "2. Checking database connection..."
python -c "
from database import SessionLocal
try:
    db = SessionLocal()
    db.execute('SELECT 1')
    print('✓ Database connection successful')
except Exception as e:
    print(f'✗ Database connection failed: {e}')
"

echo "3. Checking model imports..."
python -c "
from models import User, Video, NarrationCharacter, CaptionTemplate
print('✓ All models imported successfully')
"

echo "4. Checking API route imports..."
python -c "
from routes import users, videos
print('✓ API routes imported successfully')
"

echo "5. Checking Prefect flow import..."
python -c "
from prefect.flows.video_processing import process_video_flow
print('✓ Prefect flow imported successfully')
"

echo "6. Checking Pydantic schemas..."
python -c "
from schemas import (
    UserCreate, UserRead, Token,
    VideoProcessRequest, VideoProcessResponse,
    NarrationCharacterCreate, NarrationCharacterRead,
    CaptionTemplateCreate, CaptionTemplateRead
)
print('✓ All schemas imported successfully')
"

echo "7. Checking service imports..."
python -c "
from services.narration_service import get_narration_characters
from services.caption_service import get_caption_templates
print('✓ All services imported successfully')
"

echo "=== Verification Complete ==="
echo "If all checks show ✓, the backend is properly configured."
echo "To run the backend: PYTHONPATH=/path/to/project/backend uvicorn backend.main:app --reload"
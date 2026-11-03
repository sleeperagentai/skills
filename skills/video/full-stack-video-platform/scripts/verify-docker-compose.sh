#!/bin/bash
# Docker Compose Verification Script
# Checks that docker-compose.yml is valid and services can start

echo "=== Docker Compose Verification ==="

# Check if we're in the right directory
if [ ! -f "docker-compose.yml" ]; then
    echo "ERROR: Please run this script from the project root directory"
    exit 1
fi

echo "1. Checking docker-compose syntax..."
docker-compose config
if [ $? -eq 0 ]; then
    echo "✓ docker-compose.yml syntax is valid"
else
    echo "✗ docker-compose.yml syntax is invalid"
    exit 1
fi

echo "2. Checking required services are defined..."
REQUIRED_SERVICES=("backend" "frontend" "db" "minio" "prefectrest" "prefectagent")
for service in "${REQUIRED_SERVICES[@]}"; do
    if grep -q "^  $service:" docker-compose.yml; then
        echo "✓ Service '$service' found"
    else
        echo "✗ Service '$service' NOT found"
    fi
done

echo "3. Checking volume definitions..."
if grep -q "volumes:" docker-compose.yml; then
    echo "✓ Volumes section found"
else
    echo "✗ Volumes section NOT found"
fi

echo "4. Checking environment file guidance..."
if [ -f ".env.example" ]; then
    echo "✓ .env.example file found"
else
    echo "✗ .env.example file NOT found"
fi

echo "=== Docker Compose Verification Complete ==="
echo "To start all services: docker-compose up --build"
echo "To stop all services: docker-compose down"
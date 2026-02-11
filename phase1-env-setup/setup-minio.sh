#!/usr/bin/env bash
set -euo pipefail

MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-minioadmin}"
MINIO_BUCKET="${MINIO_BUCKET:-k10-exports}"

echo "=== Deploying MinIO ==="

# Stop and remove existing MinIO container if present
docker rm -f minio 2>/dev/null || true

# Start MinIO server
docker run -d --name minio \
  -p 9000:9000 -p 9001:9001 \
  -e MINIO_ROOT_USER="${MINIO_ROOT_USER}" \
  -e MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD}" \
  minio/minio server /data --console-address ":9001"

echo "Waiting for MinIO to be ready..."
sleep 5

# Create the export bucket
docker run --rm --net=host --entrypoint sh minio/mc -c \
  "mc alias set local http://localhost:9000 ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD} && \
   mc mb local/${MINIO_BUCKET} --ignore-existing"

echo "=== MinIO deployed ==="
echo "  API:     http://localhost:9000"
echo "  Console: http://localhost:9001"
echo "  Bucket:  ${MINIO_BUCKET}"
echo ""
echo "IMPORTANT: Note your host IP for cluster access:"
echo "  hostname -I | awk '{print \$1}'"

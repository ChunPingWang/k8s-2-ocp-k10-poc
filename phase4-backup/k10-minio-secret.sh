#!/usr/bin/env bash
set -euo pipefail

MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-minioadmin}"
MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-minioadmin}"

echo "=== Creating K10 MinIO credential secret ==="

kubectl create secret generic k10-minio-secret \
  --namespace kasten-io \
  --type secrets.kanister.io/aws \
  --from-literal=aws_access_key_id="${MINIO_ACCESS_KEY}" \
  --from-literal=aws_secret_access_key="${MINIO_SECRET_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret k10-minio-secret created/updated in kasten-io namespace"

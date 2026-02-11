#!/usr/bin/env bash
set -euo pipefail

echo "=== Installing Kasten K10 on Kind (Source Cluster) ==="

# Ensure we're on the Kind context
kubectl config use-context kind-source-cluster

# Add Kasten Helm repo
helm repo add kasten https://charts.kasten.io/
helm repo update

# Run pre-flight check
echo ""
echo "=== Running K10 pre-flight check ==="
curl -s https://docs.kasten.io/tools/k10_primer.sh | bash
echo ""

# Create namespace
kubectl create namespace kasten-io --dry-run=client -o yaml | kubectl apply -f -

# Install K10
helm install k10 kasten/k10 \
  --namespace kasten-io \
  --set auth.tokenAuth.enabled=true \
  --set injectKanisterSidecar.enabled=true \
  --set persistence.storageClass="" \
  --wait --timeout 15m

echo ""
echo "=== K10 installed on Kind ==="
echo ""
echo "To access the dashboard:"
echo "  kubectl -n kasten-io port-forward svc/gateway 8080:8000"
echo "  Open: http://localhost:8080/k10/"
echo ""
echo "To get auth token:"
echo "  kubectl -n kasten-io create token k10-k10 --duration=24h"

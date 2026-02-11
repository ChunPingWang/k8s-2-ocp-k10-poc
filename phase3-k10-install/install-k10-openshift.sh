#!/usr/bin/env bash
set -euo pipefail

echo "=== Installing Kasten K10 on OpenShift Local (Target Cluster) ==="

# Login to OpenShift
oc login -u kubeadmin https://api.crc.testing:6443

# Add Kasten Helm repo
helm repo add kasten https://charts.kasten.io/
helm repo update

# Run pre-flight check
echo ""
echo "=== Running K10 pre-flight check ==="
curl -s https://docs.kasten.io/tools/k10_primer.sh | bash
echo ""

# Create namespace
oc create namespace kasten-io --dry-run=client -o yaml | oc apply -f -

# Grant SCCs for K10 service accounts
echo "=== Granting OpenShift SCCs ==="
oc adm policy add-scc-to-user privileged -z k10-k10 -n kasten-io
oc adm policy add-scc-to-user anyuid -z k10-k10 -n kasten-io
oc adm policy add-scc-to-user privileged -z metering-svc -n kasten-io

# Install K10 with OpenShift-specific settings
helm install k10 kasten/k10 \
  --namespace kasten-io \
  --set auth.tokenAuth.enabled=true \
  --set injectKanisterSidecar.enabled=true \
  --set scc.create=true \
  --set route.enabled=true \
  --set route.path="/k10" \
  --set persistence.storageClass="" \
  --wait --timeout 15m

echo ""
echo "=== K10 installed on OpenShift ==="
echo ""
echo "To access the dashboard:"
echo "  oc get route -n kasten-io"
echo ""
echo "To get auth token:"
echo "  oc -n kasten-io create token k10-k10 --duration=24h"

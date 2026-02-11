#!/usr/bin/env bash
set -euo pipefail

echo "=== Post-Restore: OpenShift SCC Fixups ==="

# Ensure we're on the OpenShift context
oc whoami || { echo "ERROR: Not logged into OpenShift. Run: oc login -u kubeadmin https://api.crc.testing:6443"; exit 1; }

# Clean target namespace if it exists (optional — skip if restore creates it)
# oc delete namespace demo-app --ignore-not-found

# Grant necessary SCCs for the restored workloads
echo "Granting anyuid SCC to default SA in demo-app..."
oc adm policy add-scc-to-user anyuid -z default -n demo-app

# Restart pods to pick up SCC changes
echo "Restarting deployments..."
oc rollout restart deployment/postgres -n demo-app
oc rollout restart deployment/frontend -n demo-app

# Wait for rollout
echo "Waiting for postgres rollout..."
oc rollout status deployment/postgres -n demo-app --timeout=120s

echo "Waiting for frontend rollout..."
oc rollout status deployment/frontend -n demo-app --timeout=120s

echo ""
echo "=== Post-restore fixups complete ==="
echo "Run validation: bash phase6-validation/validate-restore.sh"

#!/usr/bin/env bash
set -euo pipefail

PASS=0
FAIL=0

check() {
  local desc="$1"
  shift
  if "$@" > /dev/null 2>&1; then
    echo "[PASS] $desc"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] $desc"
    FAIL=$((FAIL + 1))
  fi
}

echo "========================================"
echo "  K10 Restore Validation Checklist"
echo "========================================"
echo ""

# 1. Namespace exists
check "Namespace demo-app exists" \
  oc get ns demo-app

# 2. PostgreSQL deployment running
check "Deployment postgres is available" \
  oc wait --for=condition=available deployment/postgres -n demo-app --timeout=10s

# 3. Frontend deployment running
check "Deployment frontend is available" \
  oc wait --for=condition=available deployment/frontend -n demo-app --timeout=10s

# 4. Services restored
check "Service postgres-svc exists" \
  oc get svc postgres-svc -n demo-app

check "Service frontend-svc exists" \
  oc get svc frontend-svc -n demo-app

# 5. ConfigMap intact
check "ConfigMap app-config exists" \
  oc get cm app-config -n demo-app

echo ""
echo "--- ConfigMap data ---"
oc get cm app-config -n demo-app -o jsonpath='{.data}' 2>/dev/null || echo "(unable to read)"
echo ""

# 6. Secret intact
check "Secret app-secret exists" \
  oc get secret app-secret -n demo-app

# 7. PVC or emptyDir volume check
# NOTE: PoC uses emptyDir instead of PVC due to K10 CSI driver limitations on Kind.
# Data is not persisted across backup/restore — only K8s resource manifests are restored.
if oc get pvc postgres-data -n demo-app &>/dev/null; then
  check "PVC postgres-data is Bound" \
    bash -c 'oc get pvc postgres-data -n demo-app -o jsonpath="{.status.phase}" | grep -q Bound'
else
  echo "[INFO] No PVC found (PoC uses emptyDir) — skipping PVC check"
fi

# 8. Database connectivity (data may be empty since emptyDir is not persisted)
echo ""
echo "--- Database connectivity check ---"
DB_OUTPUT=$(oc exec -n demo-app deploy/postgres -- psql -U postgres -c "SELECT 1 AS connectivity_test;" 2>&1) || true
echo "$DB_OUTPUT"

if echo "$DB_OUTPUT" | grep -q "1"; then
  echo "[PASS] PostgreSQL is reachable and responsive"
  PASS=$((PASS + 1))
else
  echo "[FAIL] PostgreSQL connectivity check failed"
  FAIL=$((FAIL + 1))
fi

# 9. Frontend accessible
check "Frontend responds on port 80" \
  oc exec -n demo-app deploy/frontend -- curl -s -o /dev/null -w '%{http_code}' http://localhost:80

# 10. Save restored state for diff
echo ""
echo "--- Saving restored state ---"
oc get all,pvc,configmap,secret -n demo-app -o wide > /tmp/restored-state.txt 2>/dev/null || true
echo "Saved to /tmp/restored-state.txt"

if [ -f /tmp/baseline-state.txt ]; then
  echo ""
  echo "--- Diff: baseline vs restored ---"
  diff /tmp/baseline-state.txt /tmp/restored-state.txt || true
fi

echo ""
echo "========================================"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

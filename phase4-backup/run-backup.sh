#!/usr/bin/env bash
set -euo pipefail

echo "=== Triggering K10 backup policy for demo-app ==="

cat <<EOF | kubectl apply -f -
apiVersion: actions.kio.kasten.io/v1alpha1
kind: RunAction
metadata:
  generateName: run-demo-app-backup-
  namespace: kasten-io
spec:
  subject:
    kind: Policy
    name: demo-app-backup
    namespace: kasten-io
EOF

echo ""
echo "Backup triggered. Monitor progress with:"
echo "  kubectl get actions.actions.kio.kasten.io -n kasten-io -w"
echo ""
echo "Or use the K10 Dashboard -> Actions page."

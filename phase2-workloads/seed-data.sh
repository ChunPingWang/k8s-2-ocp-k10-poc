#!/usr/bin/env bash
set -euo pipefail

echo "=== Seeding test data into PostgreSQL ==="

echo "Waiting for PostgreSQL to be ready..."
kubectl wait --for=condition=available deployment/postgres -n demo-app --timeout=120s

kubectl exec -n demo-app deploy/postgres -- \
  psql -U postgres -c "
    CREATE TABLE IF NOT EXISTS orders(
      id serial PRIMARY KEY,
      item text,
      amount numeric
    );
    INSERT INTO orders(item, amount) VALUES
      ('Widget', 99.95),
      ('Gadget', 149.00);
  "

echo ""
echo "=== Verifying seeded data ==="
kubectl exec -n demo-app deploy/postgres -- \
  psql -U postgres -c "SELECT * FROM orders;"

echo ""
echo "=== Recording baseline state ==="
kubectl get all,pvc,configmap,secret -n demo-app -o wide > /tmp/baseline-state.txt
kubectl exec -n demo-app deploy/postgres -- \
  psql -U postgres -c "SELECT * FROM orders;" > /tmp/baseline-data.txt

echo "Baseline saved to /tmp/baseline-state.txt and /tmp/baseline-data.txt"

# PoC Plan: Kubernetes Backup & Recovery to OpenShift Local with Kasten K10

## 1. Objective

Demonstrate a cross-cluster backup and restore workflow: back up workloads running on a **Kind** (Kubernetes-in-Docker) cluster and recover them onto a **Red Hat OpenShift Local** (CRC) cluster using **Veeam Kasten K10** as the data management platform with a **MinIO** S3-compatible object store as the shared export/import target.

---

## 2. Architecture Overview

```
┌─────────────────────┐       ┌───────────────┐       ┌──────────────────────────┐
│  Kind Cluster        │       │  MinIO (S3)   │       │  OpenShift Local          │
│  (Source)            │       │  Export Repo   │       │  (Target / Recovery)      │
│                      │       │               │       │                            │
│  ┌────────────────┐  │       │  Bucket:      │       │  ┌──────────────────────┐  │
│  │ Kasten K10     │──┼──────▶│  k10-exports  │◀──────┼──│ Kasten K10           │  │
│  │ Dashboard      │  │Export │               │Import │  │ Dashboard            │  │
│  └────────────────┘  │Policy │               │Policy │  └──────────────────────┘  │
│                      │       │               │       │                            │
│  App Workloads + PVs │       └───────────────┘       │  Restored Workloads + PVs  │
└─────────────────────┘                                └──────────────────────────┘
```

**Why Kasten K10?** K10 provides a policy-driven, UI-first approach to Kubernetes data management. It offers application-aware backups, built-in OpenShift integration, RBAC-aligned multi-tenancy, and a visual dashboard that simplifies operational handoff — making it attractive for enterprise environments where self-service DR and compliance reporting matter.

---

## 3. Prerequisites

| Component | Version / Notes |
|---|---|
| Kind | v0.20+ installed, Docker running |
| OpenShift Local (CRC) | v2.x started (`crc start`), ≥12 GB RAM allocated |
| Helm | v3.x (required for K10 installation) |
| MinIO (Docker) | Latest (`minio/minio`) |
| kubectl / oc | Both configured for respective clusters |
| Kasten K10 | Free tier (up to 5 nodes) — no license key needed for PoC |
| OS | RHEL / Fedora / macOS with sufficient RAM (≥20 GB recommended — K10 is heavier than Velero) |

---

## 4. PoC Phases

### Phase 1: Environment Setup (Day 1)

**4.1.1 — Start Kind Cluster with VolumeSnapshot Support**

K10 leverages the CSI VolumeSnapshot ecosystem. Kind needs the snapshot controller and CRDs installed.

```bash
# kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
    extraMounts:
      - hostPath: /tmp/kind-pv
        containerPath: /data

kind create cluster --name source-cluster --config kind-config.yaml

# Install VolumeSnapshot CRDs and Snapshot Controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml
```

**4.1.2 — Start OpenShift Local**

```bash
crc start
eval $(crc oc-env)
oc login -u kubeadmin https://api.crc.testing:6443
```

**4.1.3 — Deploy MinIO as Shared Export Target**

```bash
docker run -d --name minio \
  -p 9000:9000 -p 9001:9001 \
  -e MINIO_ROOT_USER=minioadmin \
  -e MINIO_ROOT_PASSWORD=minioadmin \
  minio/minio server /data --console-address ":9001"

# Create the export bucket
docker run --rm --net=host --entrypoint sh minio/mc -c \
  "mc alias set local http://localhost:9000 minioadmin minioadmin && \
   mc mb local/k10-exports"
```

**4.1.4 — Verify Connectivity**

Confirm both clusters can reach MinIO at `http://<HOST_IP>:9000`.

---

### Phase 2: Deploy Sample Workloads on Kind (Day 1–2)

**4.2.1 — Create Namespace and Application**

```bash
kubectl create namespace demo-app
```

**4.2.2 — Sample Workload Manifest (demo-app.yaml)**

```yaml
# ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: demo-app
data:
  APP_ENV: "production"
  DB_HOST: "postgres-svc"
---
# Secret
apiVersion: v1
kind: Secret
metadata:
  name: app-secret
  namespace: demo-app
type: Opaque
stringData:
  DB_PASSWORD: "poc-secret-123"
---
# PVC
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  namespace: demo-app
  labels:
    app: postgres
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
# PostgreSQL Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: demo-app
  labels:
    app: postgres
spec:
  replicas: 1
  selector:
    matchLabels: { app: postgres }
  template:
    metadata:
      labels: { app: postgres }
    spec:
      containers:
        - name: postgres
          image: postgres:15
          ports: [{ containerPort: 5432 }]
          env:
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef: { name: app-secret, key: DB_PASSWORD }
          volumeMounts:
            - name: pgdata
              mountPath: /var/lib/postgresql/data
      volumes:
        - name: pgdata
          persistentVolumeClaim: { claimName: postgres-data }
---
# PostgreSQL Service
apiVersion: v1
kind: Service
metadata:
  name: postgres-svc
  namespace: demo-app
spec:
  selector: { app: postgres }
  ports: [{ port: 5432, targetPort: 5432 }]
---
# Frontend Deployment (nginx)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: demo-app
  labels:
    app: frontend
spec:
  replicas: 2
  selector:
    matchLabels: { app: frontend }
  template:
    metadata:
      labels: { app: frontend }
    spec:
      containers:
        - name: nginx
          image: nginx:1.25
          ports: [{ containerPort: 80 }]
          envFrom:
            - configMapRef: { name: app-config }
---
# Frontend Service
apiVersion: v1
kind: Service
metadata:
  name: frontend-svc
  namespace: demo-app
spec:
  selector: { app: frontend }
  ports: [{ port: 80, targetPort: 80 }]
```

```bash
kubectl apply -f demo-app.yaml
```

**4.2.3 — Seed Test Data**

```bash
kubectl exec -n demo-app deploy/postgres -- \
  psql -U postgres -c "CREATE TABLE orders(id serial PRIMARY KEY, item text, amount numeric); \
  INSERT INTO orders(item, amount) VALUES ('Widget', 99.95), ('Gadget', 149.00);"
```

**4.2.4 — Record Baseline State**

```bash
kubectl get all,pvc,configmap,secret -n demo-app -o wide > /tmp/baseline-state.txt
kubectl exec -n demo-app deploy/postgres -- psql -U postgres -c "SELECT * FROM orders;" > /tmp/baseline-data.txt
```

---

### Phase 3: Install Kasten K10 on Both Clusters (Day 2)

**4.3.1 — Add Kasten Helm Repository**

```bash
helm repo add kasten https://charts.kasten.io/
helm repo update
```

**4.3.2 — Pre-flight Check (Run on Each Cluster)**

K10 provides a preflight tool to validate cluster readiness.

```bash
curl -s https://docs.kasten.io/tools/k10_primer.sh | bash
```

**4.3.3 — Install K10 on Kind (Source Cluster)**

```bash
kubectl config use-context kind-source-cluster

kubectl create namespace kasten-io

helm install k10 kasten/k10 \
  --namespace kasten-io \
  --set auth.tokenAuth.enabled=true \
  --set injectKanisterSidecar.enabled=true \
  --set persistence.storageClass="" \
  --wait --timeout 15m
```

**4.3.4 — Install K10 on OpenShift Local (Target Cluster)**

```bash
oc login -u kubeadmin https://api.crc.testing:6443

oc create namespace kasten-io

# OpenShift-specific: grant SCCs for K10 service accounts
oc adm policy add-scc-to-user privileged -z k10-k10 -n kasten-io
oc adm policy add-scc-to-user anyuid -z k10-k10 -n kasten-io
oc adm policy add-scc-to-user privileged -z metering-svc -n kasten-io

helm install k10 kasten/k10 \
  --namespace kasten-io \
  --set auth.tokenAuth.enabled=true \
  --set injectKanisterSidecar.enabled=true \
  --set scc.create=true \
  --set route.enabled=true \
  --set route.path="/k10" \
  --set persistence.storageClass="" \
  --wait --timeout 15m
```

**4.3.5 — Access K10 Dashboard**

```bash
# Kind — port forward
kubectl -n kasten-io port-forward svc/gateway 8080:8000

# OpenShift — use the route
oc get route -n kasten-io
# Dashboard URL: https://<route-host>/k10/

# Get auth token (both clusters)
kubectl -n kasten-io create token k10-k10 --duration=24h
```

Open the K10 dashboard in a browser. This is the primary management interface for the PoC.

---

### Phase 4: Configure Location Profile & Backup Policy (Day 2–3)

**4.4.1 — Create S3-Compatible Location Profile (Both Clusters)**

This can be done via the K10 Dashboard UI or via CRD:

```yaml
# k10-location-profile.yaml
apiVersion: config.kio.kasten.io/v1alpha1
kind: Profile
metadata:
  name: minio-export
  namespace: kasten-io
spec:
  type: Location
  locationSpec:
    credential:
      secretType: AwsAccessKey
      secret:
        apiVersion: v1
        kind: Secret
        name: k10-minio-secret
        namespace: kasten-io
    type: ObjectStore
    objectStore:
      name: k10-exports
      objectStoreType: S3
      region: us-east-1
      endpoint: http://<HOST_IP>:9000
      skipSSLVerify: true
      pathType: Path
```

```bash
# Create the credential secret (both clusters)
kubectl create secret generic k10-minio-secret \
  --namespace kasten-io \
  --type secrets.kanister.io/aws \
  --from-literal=aws_access_key_id=minioadmin \
  --from-literal=aws_secret_access_key=minioadmin

# Apply the profile (both clusters)
kubectl apply -f k10-location-profile.yaml
```

**4.4.2 — Create Backup Policy on Kind (Source Cluster)**

Via Dashboard: **Policies → Create New Policy**, or via CRD:

```yaml
# k10-backup-policy.yaml
apiVersion: config.kio.kasten.io/v1alpha1
kind: Policy
metadata:
  name: demo-app-backup
  namespace: kasten-io
spec:
  comment: "PoC backup policy for demo-app"
  frequency: "@onDemand"
  actions:
    - action: backup
      backupParameters:
        filters:
          includeClusterResources: []
        profile:
          name: minio-export
          namespace: kasten-io
    - action: export
      exportParameters:
        frequency: "@onDemand"
        profile:
          name: minio-export
          namespace: kasten-io
        exportData:
          enabled: true
  selector:
    matchExpressions:
      - key: k10.kasten.io/appNamespace
        operator: In
        values:
          - demo-app
```

```bash
kubectl apply -f k10-backup-policy.yaml
```

**4.4.3 — Run Backup & Export (via Dashboard or CLI)**

```bash
# Trigger the policy manually
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
```

**4.4.4 — Monitor Backup Progress**

Use the K10 Dashboard → **Actions** page to monitor. Alternatively:

```bash
kubectl get actions.actions.kio.kasten.io -n kasten-io -w
```

Wait for both the backup and export actions to complete successfully.

---

### Phase 5: Import & Restore to OpenShift Local (Day 3)

**4.5.1 — Pre-Restore: Ensure Target Namespace is Clean**

```bash
oc login -u kubeadmin https://api.crc.testing:6443
oc delete namespace demo-app --ignore-not-found
```

**4.5.2 — Create Import Policy on OpenShift Local**

Via Dashboard: **Policies → Create New Policy → Import**, or via CRD:

```yaml
# k10-import-policy.yaml
apiVersion: config.kio.kasten.io/v1alpha1
kind: Policy
metadata:
  name: demo-app-import
  namespace: kasten-io
spec:
  comment: "PoC import policy for demo-app recovery"
  frequency: "@onDemand"
  actions:
    - action: import
      importParameters:
        profile:
          name: minio-export
          namespace: kasten-io
        importData:
          enabled: true
  selector:
    matchExpressions:
      - key: k10.kasten.io/appNamespace
        operator: In
        values:
          - demo-app
```

```bash
oc apply -f k10-import-policy.yaml
```

**4.5.3 — Run Import via Dashboard**

The most reliable approach for cross-cluster import:

1. Open K10 Dashboard on OpenShift Local.
2. Navigate to **Applications → demo-app** (it appears after the import policy discovers the export).
3. Click **Restore** on the imported restore point.
4. Select the most recent restore point from the MinIO export.
5. Click **Restore** and monitor progress.

Alternatively via CLI:

```bash
# List available restore points
kubectl get restorepoints.apps.kio.kasten.io -n demo-app

# Trigger restore action
cat <<EOF | oc apply -f -
apiVersion: actions.kio.kasten.io/v1alpha1
kind: RestoreAction
metadata:
  generateName: restore-demo-app-
  namespace: kasten-io
spec:
  subject:
    kind: RestorePoint
    name: <restore-point-name>
    namespace: demo-app
  targetNamespace: demo-app
EOF
```

**4.5.4 — Post-Restore: OpenShift SCC Fixups**

```bash
# Grant necessary SCCs for the restored workloads
oc adm policy add-scc-to-user anyuid -z default -n demo-app

# Restart pods if needed
oc rollout restart deployment/postgres -n demo-app
oc rollout restart deployment/frontend -n demo-app
```

**4.5.5 — Validate Restore**

```bash
# Resource state
oc get all,pvc,configmap,secret -n demo-app -o wide > /tmp/restored-state.txt
diff /tmp/baseline-state.txt /tmp/restored-state.txt

# Data integrity
oc exec -n demo-app deploy/postgres -- psql -U postgres -c "SELECT * FROM orders;"
# Expected: Widget 99.95, Gadget 149.00
```

---

### Phase 6: Validation & Reporting (Day 4)

**4.6.1 — Validation Checklist**

| # | Validation Item | Method | Expected Result |
|---|---|---|---|
| 1 | Namespace exists on CRC | `oc get ns demo-app` | Active |
| 2 | Deployments running | `oc get deploy -n demo-app` | postgres (1/1), frontend (2/2) |
| 3 | Services restored | `oc get svc -n demo-app` | postgres-svc, frontend-svc |
| 4 | ConfigMap intact | `oc get cm app-config -n demo-app -o yaml` | APP_ENV=production |
| 5 | Secret intact | `oc get secret app-secret -n demo-app` | Exists, Opaque |
| 6 | PVC bound | `oc get pvc -n demo-app` | postgres-data = Bound |
| 7 | Data integrity | `SELECT * FROM orders;` | 2 rows: Widget, Gadget |
| 8 | Frontend accessible | `oc port-forward svc/frontend-svc 8080:80` | HTTP 200 |
| 9 | K10 Dashboard shows restore | Dashboard → Actions | Restore completed |
| 10 | Compliance report | Dashboard → Reports | Backup + Export + Restore logged |

**4.6.2 — K10-Specific Observations to Document**

| Area | What to Capture |
|---|---|
| Dashboard UX | Ease of policy creation, monitoring, and restore point selection |
| Application discovery | How K10 auto-discovers namespaces and workloads |
| Kanister blueprints | Whether built-in PostgreSQL blueprint handles consistent snapshots |
| RBAC integration | How K10 RBAC maps to OpenShift roles |
| Resource consumption | CPU/Memory footprint of K10 pods on CRC (CRC is resource-constrained) |
| Export/Import time | Wall-clock time for backup export and cross-cluster import |

---

## 5. Kasten K10 vs Velero — Comparison Matrix

| Dimension | Velero | Kasten K10 |
|---|---|---|
| **Installation** | CLI-based, lightweight (~100 MB) | Helm chart, heavier (~2 GB+ with all components) |
| **UI / Dashboard** | None (CLI only, third-party UIs exist) | Built-in web dashboard with policy wizard |
| **Application Awareness** | Namespace-level; hooks for pre/post scripts | Auto-discovers apps; Kanister blueprints for app-consistent snapshots |
| **Cross-Cluster Restore** | Manual: install on both, share BSL | Built-in Export/Import policy workflow |
| **OpenShift Support** | Community support; manual SCC configuration | First-class OpenShift support; SCC CRD auto-creation |
| **Policy Management** | CLI-based schedules | Visual policy builder with frequency, retention, export chaining |
| **Compliance / Reporting** | Manual (query backup status via CLI) | Built-in compliance dashboard and audit reports |
| **Multi-Tenancy** | Limited (namespace RBAC) | K10 RBAC with per-namespace access controls |
| **Encryption** | Client-side encryption with custom KMS | Built-in encryption at rest and in transit |
| **Licensing** | Fully open-source (Apache 2.0) | Free tier (≤5 nodes); Enterprise license for production |
| **Best Fit** | DevOps teams comfortable with CLI; cost-sensitive environments | Enterprise teams needing UI, compliance, and self-service DR |

---

## 6. Timeline Summary

| Day | Activity |
|---|---|
| Day 1 | Environment setup (Kind + CSI snapshot CRDs, CRC, MinIO), deploy sample workloads |
| Day 2 | Install K10 on both clusters, configure Location Profile, create and run backup policy |
| Day 3 | Create import policy on CRC, restore, post-restore fixups, validation |
| Day 4 | Comparison report (K10 vs Velero), demo walkthrough, findings documentation |

---

## 7. Known Gaps & Limitations

- **CRC resource pressure**: K10 runs 10+ pods in `kasten-io` namespace. CRC with ≤12 GB RAM may experience OOM. Allocate ≥14 GB to CRC (`crc config set memory 14336`).
- **CSI snapshot on Kind**: Kind's default `rancher.io/local-path` provisioner does not support CSI snapshots. K10 falls back to file-copy (generic backup). For snapshot-based backup, install a CSI driver like `csi-hostpath` with snapshot support.
- **Image availability**: Same as Velero PoC — locally-built images not in a shared registry will cause `ImagePullBackOff` on CRC.
- **OpenShift SCC**: K10 creates its own SCCs if `scc.create=true`, but restored workload pods may still need manual SCC grants.
- **Kanister blueprints**: The built-in PostgreSQL blueprint works with standard Helm-deployed PostgreSQL. Custom deployments may need a custom blueprint.
- **License scope**: Free tier is limited to 5 nodes and basic features. Enterprise features (multi-cluster dashboard, RBAC, ransomware protection) require a license.

---

## 8. Extension Ideas (Post-PoC)

- **Kanister custom blueprints**: Write application-specific blueprints for consistent database quiesce/unquiesce during backup.
- **Scheduled policy with retention**: Configure daily backup with 7-day retention and weekly export to MinIO.
- **Multi-cluster dashboard**: Deploy K10 Multi-Cluster Manager to manage backup/restore across Kind, CRC, and cloud clusters from a single pane.
- **Ransomware protection**: Enable K10's immutable backup feature with MinIO Object Locking.
- **Transformation during restore**: Use K10 transforms to modify StorageClass, resource limits, or image references during cross-cluster restore.
- **OADP comparison**: Compare K10 with Red Hat's native OADP (OpenShift API for Data Protection, which wraps Velero) for an OpenShift-native alternative.

---

## 9. References

- [Kasten K10 Documentation](https://docs.kasten.io/)
- [K10 on OpenShift](https://docs.kasten.io/latest/install/openshift/openshift.html)
- [Kanister — Application-Level Data Management](https://kanister.io/)
- [K10 Free Tier](https://www.kasten.io/free-kubernetes)
- [Kind Quick Start](https://kind.sigs.k8s.io/docs/user/quick-start/)
- [OpenShift Local (CRC)](https://developers.redhat.com/products/openshift-local/overview)
- [MinIO Quick Start](https://min.io/docs/minio/container/index.html)

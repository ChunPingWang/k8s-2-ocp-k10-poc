# Kubernetes 備份與還原至 OpenShift — Kasten K10 PoC

## 專案簡介

本專案示範如何使用 **Veeam Kasten K10** 作為資料管理平台，將運行於 **Kind**（Kubernetes-in-Docker）叢集上的工作負載備份，並還原至 **Red Hat OpenShift Local**（CRC）叢集。透過 **MinIO** S3 相容物件儲存作為跨叢集的匯出/匯入目標。

## Kubernetes 備份與還原核心概念

### 為什麼 Kubernetes 需要備份？

傳統虛擬機器備份僅需對磁碟做快照，但 Kubernetes 的工作負載由多種相互關聯的資源組成，備份挑戰截然不同：

| 層級 | 資源範例 | 說明 |
|---|---|---|
| **叢集層級** | Node、ClusterRole、StorageClass、CRD | 定義叢集基礎架構與全域策略 |
| **命名空間層級** | Deployment、Service、ConfigMap、Secret | 應用程式的宣告式配置（「期望狀態」） |
| **資料層級** | PersistentVolume (PV)、PersistentVolumeClaim (PVC) | 實際的持久化資料（資料庫檔案、上傳檔案等） |

僅備份 YAML 清單不夠（資料會遺失）；僅備份磁碟也不夠（無法重建 Pod 網路與服務發現）。**完整的 Kubernetes 備份必須同時涵蓋資源定義與持久化資料。**

### Kubernetes 備份的關鍵元件

```
┌─────────────────────────────────────────────────────────┐
│                    Kubernetes 叢集                        │
│                                                          │
│  ┌──────────────┐   ┌──────────────┐   ┌─────────────┐  │
│  │  etcd         │   │  API Server   │   │  kubelet    │  │
│  │  (叢集狀態)   │   │  (資源 CRUD)  │   │  (Pod 管理) │  │
│  └──────┬───────┘   └──────┬───────┘   └──────┬──────┘  │
│         │                  │                   │         │
│         ▼                  ▼                   ▼         │
│  ┌─────────────────────────────────────────────────────┐ │
│  │  Namespace: demo-app                                │ │
│  │  ┌───────────┐ ┌─────────┐ ┌────────┐ ┌─────────┐  │ │
│  │  │Deployment │ │ Service │ │ConfigMap│ │ Secret  │  │ │
│  │  └─────┬─────┘ └─────────┘ └────────┘ └─────────┘  │ │
│  │        │                                            │ │
│  │        ▼                                            │ │
│  │  ┌───────────┐      ┌──────────────────┐            │ │
│  │  │   Pod     │─────▶│ PVC ──▶ PV (資料) │            │ │
│  │  └───────────┘      └──────────────────┘            │ │
│  └─────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

- **etcd**：Kubernetes 的分散式鍵值儲存，保存所有叢集狀態。直接備份 etcd 可實現叢集級災難復原，但粒度太粗、難以做應用程式級還原
- **API Server**：所有備份工具都透過 Kubernetes API 讀取資源清單（Deployment、Service 等）
- **CSI（Container Storage Interface）**：標準化的儲存介面，讓備份工具能建立 **VolumeSnapshot**（磁碟快照），實現一致性資料備份
- **PV / PVC**：PersistentVolume 是實際儲存；PersistentVolumeClaim 是 Pod 對儲存的請求。備份時需對 PV 做快照以保留資料

### VolumeSnapshot 機制

CSI VolumeSnapshot 是 Kubernetes 原生的磁碟快照 API，是現代備份工具的基礎：

```
Pod 寫入資料 ──▶ PVC ──▶ PV (CSI Driver)
                              │
                    VolumeSnapshot API
                              │
                              ▼
                      VolumeSnapshotContent
                       (磁碟快照副本)
```

三個關鍵 CRD：
- **VolumeSnapshotClass**：定義快照的驅動程式與參數（類似 StorageClass）
- **VolumeSnapshot**：使用者請求建立快照
- **VolumeSnapshotContent**：實際的快照資料（由 CSI 驅動程式管理）

### 跨叢集遷移的挑戰

將工作負載從叢集 A 還原至叢集 B 面臨以下挑戰：

1. **儲存差異**：來源叢集用 AWS EBS，目標叢集用 Ceph RBD — StorageClass 名稱與驅動程式不同
2. **網路差異**：ClusterIP、NodePort 範圍可能不同，Ingress 配置需調整
3. **安全性差異**：OpenShift 的 SCC 比標準 K8s 的 PodSecurityPolicy/Standards 更嚴格
4. **映像檔可用性**：私有 Registry 中的映像檔在目標叢集可能無法拉取
5. **CRD 相容性**：自訂資源定義在目標叢集上必須先安裝

## Kasten K10 深入介紹

### K10 架構

K10 以 Helm Chart 部署於 `kasten-io` 命名空間，包含以下核心元件：

```
┌─────────────────────────────────────────────────┐
│  kasten-io 命名空間                               │
│                                                  │
│  ┌────────────┐  ┌──────────────┐  ┌──────────┐ │
│  │ Gateway    │  │ Dashboard/   │  │ Auth     │ │
│  │ (入口)     │  │ Frontend     │  │ Service  │ │
│  └──────┬─────┘  └──────────────┘  └──────────┘ │
│         │                                        │
│  ┌──────▼─────┐  ┌──────────────┐  ┌──────────┐ │
│  │ Controller │  │ Catalog      │  │ Crypto   │ │
│  │ Manager    │  │ Service      │  │ Service  │ │
│  │ (策略引擎) │  │ (還原點目錄) │  │ (加密)   │ │
│  └──────┬─────┘  └──────────────┘  └──────────┘ │
│         │                                        │
│  ┌──────▼─────┐  ┌──────────────┐  ┌──────────┐ │
│  │ Executor   │  │ Kanister     │  │ State    │ │
│  │ (執行備份/ │  │ Service      │  │ Service  │ │
│  │  還原動作) │  │ (應用感知)   │  │ (狀態DB) │ │
│  └────────────┘  └──────────────┘  └──────────┘ │
└─────────────────────────────────────────────────┘
```

### K10 核心概念

#### Profile（位置設定檔）

Profile 定義備份資料的儲存目標，支援多種後端：

- **S3 相容儲存**：AWS S3、MinIO、Ceph Object Gateway
- **Azure Blob Storage**
- **Google Cloud Storage**
- **NFS**

```yaml
# 範例：MinIO S3 Profile
apiVersion: config.kio.kasten.io/v1alpha1
kind: Profile
spec:
  type: Location
  locationSpec:
    type: ObjectStore
    objectStore:
      objectStoreType: S3
      endpoint: http://minio:9000   # S3 端點
      name: k10-exports             # Bucket 名稱
```

#### Policy（策略）

Policy 定義「何時」與「如何」執行備份，是 K10 的核心抽象：

- **backup**：備份 Kubernetes 資源清單 + PV 快照
- **export**：將備份資料匯出至外部儲存（跨叢集遷移必須）
- **import**：從外部儲存匯入備份（目標叢集側）

```
Policy 工作流：
  backup ──▶ 本地還原點（RestorePoint）
               │
           export ──▶ 外部儲存（S3 Bucket）
                           │
                       import ──▶ RestorePointContent（目標叢集）
                                       │
                                   restore ──▶ 還原工作負載
```

#### RestorePoint（還原點）

K10 的還原點包含：
- **資源清單**：所有 Kubernetes 資源的 JSON/YAML 序列化
- **PV 快照參考**：指向 CSI VolumeSnapshotContent 的參照
- **元資料**：時間戳、來源叢集資訊、備份策略

跨叢集匯入時，K10 先建立 **RestorePointContent**（叢集層級），再綁定至 **RestorePoint**（命名空間層級），最後透過 **RestoreAction** 執行還原。

#### Kanister（應用程式感知框架）

Kanister 是 K10 的應用程式感知引擎，透過 **Blueprint** 定義資料庫的一致性備份流程：

| 資料庫 | Blueprint 操作 |
|---|---|
| PostgreSQL | `pg_dump` / `pg_restore` |
| MySQL | `mysqldump` / `mysql` |
| MongoDB | `mongodump` / `mongorestore` |
| Elasticsearch | Snapshot API |

K10 自動注入 **kanister-sidecar** 容器至被備份的 Pod，用於在 Pod 內執行資料一致性操作。

### K10 備份與還原流程

#### 來源叢集（備份 + 匯出）

```
1. 建立 Policy（指定備份目標命名空間）
2. Policy 觸發 BackupAction
   ├── 掃描命名空間中的所有資源（Deployment、Service、ConfigMap...）
   ├── 序列化資源至 Kopia 儲存庫
   └── 建立 PV 的 VolumeSnapshot（如有 PVC）
3. Policy 觸發 ExportAction
   ├── 將本地備份資料上傳至 S3
   └── 產生 receiveString（加密的匯入金鑰）
```

#### 目標叢集（匯入 + 還原）

```
1. 建立 Profile（指向相同的 S3 儲存）
2. 建立 Import Policy（使用來源叢集的 receiveString）
3. 觸發 ImportAction
   ├── 從 S3 讀取匯出資料
   └── 建立 RestorePointContent
4. 建立 RestorePoint 綁定至 RestorePointContent
5. 觸發 RestoreAction
   ├── 反序列化 Kubernetes 資源
   ├── 建立 Deployment、Service、ConfigMap、Secret 等
   └── 還原 PV 資料（如有）
```

### K10 與 OpenShift 整合

OpenShift 在標準 Kubernetes 之上增加了企業級安全機制，K10 原生支援：

| OpenShift 特性 | K10 整合方式 |
|---|---|
| **SCC（Security Context Constraints）** | `scc.create=true` Helm 參數自動建立 SCC |
| **Route** | K10 可自動建立 OpenShift Route 暴露儀表板 |
| **ImageStream** | 備份時自動包含 ImageStream 資源 |
| **DeploymentConfig**（已棄用） | 支援備份，但建議遷移至 Deployment |
| **OperatorHub** | K10 提供 Operator 版本，可透過 OLM 安裝 |

## 架構概覽

```
┌─────────────────────┐       ┌───────────────┐       ┌──────────────────────────┐
│  Kind Cluster        │       │  MinIO (S3)   │       │  OpenShift Local          │
│  (來源叢集)          │       │  匯出儲存庫   │       │  (目標 / 還原叢集)        │
│                      │       │               │       │                            │
│  ┌────────────────┐  │       │  Bucket:      │       │  ┌──────────────────────┐  │
│  │ Kasten K10     │──┼──────▶│  k10-exports  │◀──────┼──│ Kasten K10           │  │
│  │ 儀表板         │  │匯出   │               │匯入   │  │ 儀表板               │  │
│  └────────────────┘  │策略   │               │策略   │  └──────────────────────┘  │
│                      │       │               │       │                            │
│  應用程式 + PV       │       └───────────────┘       │  還原後的工作負載 + PV     │
└─────────────────────┘                                └──────────────────────────┘
```

## 為什麼選擇 Kasten K10？

K10 提供以策略驅動、UI 優先的 Kubernetes 資料管理方案，具備以下特色：

- **應用程式感知備份**：自動發現命名空間與工作負載，支援 Kanister 藍圖實現應用程式一致性快照
- **內建 OpenShift 整合**：原生支援 SCC（Security Context Constraints）自動建立
- **視覺化儀表板**：透過 Web UI 即可建立策略、監控進度、選擇還原點
- **合規性報告**：內建稽核報告與合規性儀表板
- **企業級多租戶**：RBAC 對齊的命名空間層級存取控制

## 前置需求

| 元件 | 版本 / 備註 |
|---|---|
| Kind | v0.20+ 已安裝，Docker 執行中 |
| OpenShift Local (CRC) | v2.x 已啟動（`crc start`），至少 12 GB RAM |
| Helm | v3.x（K10 安裝必要） |
| MinIO (Docker) | 最新版（`minio/minio`） |
| kubectl / oc | 分別配置至對應叢集 |
| Kasten K10 | 免費版（最多 5 節點）— PoC 無需授權金鑰 |
| 作業系統 | RHEL / Fedora / macOS，建議至少 20 GB RAM |

## 專案結構

```
.
├── README.md                              # 本文件（zh-TW）
├── poc-k8s-backup-to-openshift-recovery-k10.md  # 完整 PoC 計畫（英文）
├── phase1-env-setup/                      # 階段 1：環境建置
│   ├── kind-config.yaml                   # Kind 叢集配置
│   ├── setup-minio.sh                     # MinIO 部署腳本
│   └── install-snapshot-crds.sh           # CSI VolumeSnapshot CRD 安裝
├── phase2-workloads/                      # 階段 2：範例工作負載
│   ├── demo-app.yaml                      # 完整應用程式清單
│   └── seed-data.sh                       # 測試資料填充腳本
├── phase3-k10-install/                    # 階段 3：K10 安裝
│   ├── install-k10-kind.sh               # Kind 叢集 K10 安裝
│   └── install-k10-openshift.sh          # OpenShift 叢集 K10 安裝
├── phase4-backup/                         # 階段 4：備份配置
│   ├── k10-location-profile.yaml         # S3 位置設定檔
│   ├── k10-minio-secret.sh               # MinIO 憑證建立
│   └── k10-backup-policy.yaml            # 備份策略
├── phase5-restore/                        # 階段 5：匯入與還原
│   ├── k10-import-policy.yaml            # 匯入策略
│   └── post-restore-fixup.sh             # 還原後 SCC 修正
└── phase6-validation/                     # 階段 6：驗證
    └── validate-restore.sh               # 還原驗證腳本
```

## PoC 執行步驟

### 階段 1：環境建置（第 1 天）

1. 建立 Kind 叢集並安裝 VolumeSnapshot CRD
2. 啟動 OpenShift Local（CRC）
3. 部署 MinIO 作為共享匯出目標
4. 驗證兩個叢集均可連線至 MinIO

```bash
# 建立 Kind 叢集
kind create cluster --name source-cluster --config phase1-env-setup/kind-config.yaml

# 安裝 Snapshot CRD
bash phase1-env-setup/install-snapshot-crds.sh

# 部署 MinIO
bash phase1-env-setup/setup-minio.sh
```

### 階段 2：部署範例工作負載（第 1-2 天）

部署包含 PostgreSQL 資料庫與 Nginx 前端的範例應用程式。

```bash
# 建立命名空間並部署應用程式
kubectl create namespace demo-app
kubectl apply -f phase2-workloads/demo-app.yaml

# 填充測試資料
bash phase2-workloads/seed-data.sh
```

### 階段 3：安裝 Kasten K10（第 2 天）

在來源與目標叢集上安裝 K10。

```bash
# Kind 叢集
bash phase3-k10-install/install-k10-kind.sh

# OpenShift 叢集
bash phase3-k10-install/install-k10-openshift.sh
```

### 階段 4：配置備份策略（第 2-3 天）

建立 S3 位置設定檔與備份策略。

```bash
# 建立 MinIO 憑證（兩個叢集皆需執行）
bash phase4-backup/k10-minio-secret.sh

# 套用位置設定檔與備份策略
kubectl apply -f phase4-backup/k10-location-profile.yaml
kubectl apply -f phase4-backup/k10-backup-policy.yaml
```

### 階段 5：匯入與還原至 OpenShift（第 3 天）

```bash
# 在 OpenShift 叢集上建立 MinIO 憑證
bash phase4-backup/k10-minio-secret.sh

# 建立位置設定檔（endpoint 需改為 OpenShift 可達的 MinIO 位址）
oc apply -f phase4-backup/k10-location-profile.yaml

# 從來源叢集取得 receiveString
kubectl --context kind-source-cluster get policies.config.kio.kasten.io \
  demo-app-backup -n kasten-io \
  -o jsonpath='{.spec.actions[1].exportParameters.receiveString}'

# 將 receiveString 填入匯入策略後套用
oc apply -f phase5-restore/k10-import-policy.yaml

# 觸發匯入
cat <<EOF | oc create -f -
apiVersion: actions.kio.kasten.io/v1alpha1
kind: RunAction
metadata:
  generateName: run-demo-app-import-
  namespace: kasten-io
spec:
  subject:
    kind: Policy
    name: demo-app-import
    namespace: kasten-io
EOF

# 建立 RestorePoint 並觸發還原
# （詳見 poc-k8s-backup-to-openshift-recovery-k10.md）

# 還原後修正
bash phase5-restore/post-restore-fixup.sh
```

### 階段 6：驗證（第 4 天）

```bash
bash phase6-validation/validate-restore.sh
```

## Kasten K10 與 Velero 比較

| 面向 | Velero | Kasten K10 |
|---|---|---|
| **安裝方式** | CLI 安裝，輕量（約 100 MB） | Helm Chart 安裝，較重（約 2 GB+） |
| **使用者介面** | 無（僅 CLI） | 內建 Web 儀表板，附策略精靈 |
| **應用程式感知** | 命名空間層級；支援 hook 腳本 | 自動發現應用程式；Kanister 藍圖 |
| **跨叢集還原** | 手動：兩端安裝，共享 BSL | 內建匯出/匯入策略工作流 |
| **OpenShift 支援** | 社群支援；需手動配置 SCC | 原生 OpenShift 支援；SCC 自動建立 |
| **策略管理** | CLI 排程 | 視覺化策略建構器 |
| **合規性報告** | 手動（透過 CLI 查詢） | 內建合規性儀表板與稽核報告 |
| **授權方式** | 完全開源（Apache 2.0） | 免費版（≤5 節點）；企業版需授權 |
| **適用場景** | 熟悉 CLI 的 DevOps 團隊 | 需要 UI、合規性與自助式 DR 的企業團隊 |

## 已知限制

- **CRC 資源壓力**：K10 在 `kasten-io` 命名空間執行 16 Pod，CRC 建議分配 ≥14 GB RAM 與 ≥50 GB 磁碟
- **Kind CSI 快照**：Kind 的 `hostpath.csi.k8s.io` 驅動程式未被 K10 識別為支援的 CSI 驅動程式。通用儲存備份（GSB）自 K10 v6.5.0 起需要付費啟用金鑰（[詳情](https://docs.kasten.io/latest/install/gvs_restricted/)）。PoC 使用 emptyDir 替代 PVC 來展示 K10 資源備份工作流。生產環境請使用 K10 支援的 CSI 驅動程式（AWS EBS、Ceph RBD 等）
- **CRC 網路隔離**：CRC VM 無法直接存取主機 Docker 容器。解決方案：在 CRC 內部署 MinIO，透過 `oc port-forward` + `mc mirror` 同步匯出資料
- **匯入需要 receiveString**：K10 匯入策略需要來源叢集匯出策略的 `receiveString`，此字串在首次備份匯出後自動生成
- **映像檔可用性**：本機建置的映像檔若未推送至共享 Registry，在 CRC 上會出現 `ImagePullBackOff`
- **OpenShift SCC**：還原的工作負載 Pod 可能仍需手動授予 SCC（`oc adm policy add-scc-to-user anyuid`）
- **免費版限制**：免費版限制 5 節點，企業功能（多叢集儀表板、RBAC、勒索軟體防護）需付費授權

## 參考資料

- [Kasten K10 官方文件](https://docs.kasten.io/)
- [K10 on OpenShift](https://docs.kasten.io/latest/install/openshift/openshift.html)
- [Kanister — 應用程式層級資料管理](https://kanister.io/)
- [K10 免費版](https://www.kasten.io/free-kubernetes)
- [Kind 快速入門](https://kind.sigs.k8s.io/docs/user/quick-start/)
- [OpenShift Local (CRC)](https://developers.redhat.com/products/openshift-local/overview)
- [MinIO 快速入門](https://min.io/docs/minio/container/index.html)

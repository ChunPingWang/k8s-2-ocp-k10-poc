# Kubernetes 備份與還原至 OpenShift — Kasten K10 PoC

## 專案簡介

本專案示範如何使用 **Veeam Kasten K10** 作為資料管理平台，將運行於 **Kind**（Kubernetes-in-Docker）叢集上的工作負載備份，並還原至 **Red Hat OpenShift Local**（CRC）叢集。透過 **MinIO** S3 相容物件儲存作為跨叢集的匯出/匯入目標。

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
# 套用匯入策略
oc apply -f phase5-restore/k10-import-policy.yaml

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

- **CRC 資源壓力**：K10 在 `kasten-io` 命名空間執行 10+ Pod，CRC 建議分配 ≥14 GB RAM
- **Kind CSI 快照**：Kind 預設 provisioner 不支援 CSI 快照，K10 會回退至檔案複製（通用備份）
- **映像檔可用性**：本機建置的映像檔若未推送至共享 Registry，在 CRC 上會出現 `ImagePullBackOff`
- **OpenShift SCC**：還原的工作負載 Pod 可能仍需手動授予 SCC
- **免費版限制**：免費版限制 5 節點，企業功能（多叢集儀表板、RBAC、勒索軟體防護）需付費授權

## 參考資料

- [Kasten K10 官方文件](https://docs.kasten.io/)
- [K10 on OpenShift](https://docs.kasten.io/latest/install/openshift/openshift.html)
- [Kanister — 應用程式層級資料管理](https://kanister.io/)
- [K10 免費版](https://www.kasten.io/free-kubernetes)
- [Kind 快速入門](https://kind.sigs.k8s.io/docs/user/quick-start/)
- [OpenShift Local (CRC)](https://developers.redhat.com/products/openshift-local/overview)
- [MinIO 快速入門](https://min.io/docs/minio/container/index.html)

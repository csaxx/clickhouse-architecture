# Operator — Kubernetes Deployment Configuration

Kubernetes manifests and Helm values for the StarRocks production deployment
using the **kube-starrocks** Helm chart.

The `kube-starrocks/kube-starrocks` chart is an umbrella chart that installs
the operator **and** deploys the StarRocksCluster in a single Helm release via
`values.yaml`. Raw `StarRocksCluster` CRD manifests are not used.

## Architecture Reference

- Full design rationale and decisions: [`starrocks-architecture.md`](../starrocks-architecture.md)
- DDL statements (run after deployment): [`starrocks/sql/`](../../sql/)

## File Layout

| File | Type | Purpose |
|---|---|---|
| `values.yaml` | Helm values | Operator + cluster configuration (single Helm release) |
| `00-namespace.yaml` | kubectl | `starrocks` namespace |
| `01-configmaps.yaml` | kubectl | `fe.conf` and `cn.conf` ConfigMaps (must exist before `helm install`) |
| `02-init-job.yaml` | kubectl | One-shot Job: creates S3 storage volume after cluster is healthy |
| `03-services.yaml` | kubectl | External client-facing Services (LoadBalancer + HTTP ClusterIP) |
| `04-networkpolicy.yaml` | kubectl | All NetworkPolicy rules |
| `vault/serviceaccount.yaml` | kubectl | ServiceAccount + RBAC for Vault auth |
| `vault/vault-policy.hcl` | vault CLI | Vault policy for S3 credential read access |

## Topology

| Component | Configuration | Pods | Notes |
|---|---|---|---|
| FE nodes | `values.yaml` → `starRocksFeSpec` | 3 | 1 leader + 2 followers; Raft via BDB-JE |
| CN nodes | `values.yaml` → `starRocksComputeNodeSpec` | 7 | Shared-data; NVMe is data cache only |
| Init Job | `02-init-job.yaml` | 1 | One-shot; creates S3 storage volume |
| **Total pods** | | **10** | vs. 19–21 for equivalent ClickHouse |

## Prerequisites

Before running `helm install`:

1. **Vault Agent Injector** (HashiCorp Vault 1.3.0+ with injector webhook) running and configured with Kubernetes auth.
2. **Kubernetes Secret `starrocks-s3-credentials`** exists in the `starrocks` namespace (see §4 below).
3. **StorageClasses** available:
   - `standard` — fast SSD (FE metadata PVC, 20 GiB)
   - `nvme-storageclass` — NVMe/SSD-backed PVs (CN data cache PVC, 575 GiB)
   Replace these names in `values.yaml` to match your environment.
4. **Node labels and taints** applied (see §3 below):
   - FE nodes (≥3): `starrocks/role=fe` + taint `starrocks/fe=true:NoSchedule`
   - CN nodes (≥7): `starrocks/role=cn` + taint `starrocks/cn=true:NoSchedule`
5. **All blocking Open Decisions resolved** — see §9 below.

---

## §1 — Install the kube-starrocks Helm Chart

The `kube-starrocks/kube-starrocks` umbrella chart installs the operator and
deploys the StarRocksCluster from `values.yaml` in a single release.

```bash
helm repo add kube-starrocks https://starrocks.github.io/starrocks-kubernetes-operator
helm repo update

# Show available versions — pin before production
helm search repo kube-starrocks/kube-starrocks --versions | head -10
```

```bash
# Install operator + cluster from values.yaml
helm install starrocks kube-starrocks/kube-starrocks \
  --namespace starrocks \
  --create-namespace \
  --version <pin-to-latest-stable> \
  -f values.yaml
```

To upgrade (e.g., after changing `values.yaml` or bumping `image` tags):

```bash
helm upgrade starrocks kube-starrocks/kube-starrocks \
  --namespace starrocks \
  --version <new-version> \
  -f values.yaml
```

To inspect the rendered templates before applying:

```bash
helm template starrocks kube-starrocks/kube-starrocks \
  --namespace starrocks \
  --version <version> \
  -f values.yaml
```

---

## §2 — Apply Pre-Helm Resources

These resources must exist before `helm install`:

```bash
# 1. Namespace (helm --create-namespace also creates it, but explicit is safer)
kubectl apply -f 00-namespace.yaml

# 2. ServiceAccount and RBAC (Vault Agent needs it before pods start)
kubectl apply -f vault/serviceaccount.yaml

# 3. ConfigMaps (referenced by name in values.yaml; must exist before operator
#    tries to mount them into FE/CN pods)
kubectl apply -f 01-configmaps.yaml

# 4. S3 credentials Secret (see §4 below)
# kubectl -n starrocks create secret generic starrocks-s3-credentials ...
```

---

## §3 — Prepare Node Labels and Taints

```bash
# ─── FE nodes (minimum 3) ─────────────────────────────────────────────────────
kubectl label node <fe-node-1> <fe-node-2> <fe-node-3> starrocks/role=fe
kubectl taint node <fe-node-1> <fe-node-2> <fe-node-3> starrocks/fe=true:NoSchedule

# ─── CN nodes (minimum 7, one per node) ───────────────────────────────────────
kubectl label node <cn-node-1> <cn-node-2> <cn-node-3> \
  <cn-node-4> <cn-node-5> <cn-node-6> <cn-node-7> starrocks/role=cn
kubectl taint node <cn-node-1> <cn-node-2> <cn-node-3> \
  <cn-node-4> <cn-node-5> <cn-node-6> <cn-node-7> starrocks/cn=true:NoSchedule
```

---

## §4 — Configure Vault Auth

```bash
# 1. Enable Kubernetes auth method (if not already enabled)
vault auth enable kubernetes

# 2. Configure the Kubernetes auth method
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc" \
  token_reviewer_jwt="$(kubectl -n starrocks create token starrocks)" \
  kubernetes_ca_cert=@/path/to/ca.crt

# 3. Write the StarRocks Vault policy
vault policy write starrocks vault/vault-policy.hcl

# 4. Bind the policy to the ServiceAccount
vault write auth/kubernetes/role/starrocks \
  bound_service_account_names=starrocks \
  bound_service_account_namespaces=starrocks \
  policies=starrocks \
  ttl=1h

# 5. Store S3 credentials in Vault (KV v2)
vault kv put secret/starrocks/s3/credentials \
  access_key_id=<YOUR_S3_ACCESS_KEY> \
  secret_access_key=<YOUR_S3_SECRET_KEY>
```

**Create the Kubernetes Secret** (required by `02-init-job.yaml`):

```bash
# Option A — Manual
kubectl -n starrocks create secret generic starrocks-s3-credentials \
  --from-literal=access_key_id=<ACCESS_KEY> \
  --from-literal=secret_access_key=<SECRET_KEY>

# Option B — From Vault (scripted)
kubectl -n starrocks create secret generic starrocks-s3-credentials \
  --from-literal=access_key_id="$(vault kv get -field=access_key_id secret/starrocks/s3/credentials)" \
  --from-literal=secret_access_key="$(vault kv get -field=secret_access_key secret/starrocks/s3/credentials)"

# Option C — Vault Secrets Operator (automated rotation, recommended for production)
# Deploy a VaultStaticSecret CR to continuously sync the Vault secret to the
# Kubernetes Secret "starrocks-s3-credentials".
# See: https://developer.hashicorp.com/vault/docs/platform/k8s/vso
```

---

## §5 — Deployment Order

```bash
# 1. Pre-helm resources (namespace, RBAC, ConfigMaps, Secret)
kubectl apply -f 00-namespace.yaml
kubectl apply -f vault/serviceaccount.yaml
kubectl apply -f 01-configmaps.yaml
# kubectl -n starrocks create secret generic starrocks-s3-credentials ...

# 2. Install operator + cluster via Helm
helm install starrocks kube-starrocks/kube-starrocks \
  --namespace starrocks \
  --version <pin-version> \
  -f values.yaml

# 3. Wait for FE pods to be Running and Ready
kubectl -n starrocks rollout status statefulset -l app.kubernetes.io/component=fe

# 4. Verify FE HA — all 3 FE pods healthy
kubectl -n starrocks exec -it <fe-pod-0> -- \
  mysql -h 127.0.0.1 -P 9030 -u root -e "SHOW FRONTENDS\G"
# Expected: 3 rows; IsMaster=true on exactly 1 FE

# 5. Wait for CN pods
kubectl -n starrocks rollout status statefulset -l app.kubernetes.io/component=cn

# 6. Verify CN registration
kubectl -n starrocks exec -it <fe-pod-0> -- \
  mysql -h 127.0.0.1 -P 9030 -u root -e "SHOW COMPUTE NODES\G"
# Expected: 7 rows; all Alive=true

# 7. Edit 02-init-job.yaml — replace <S3_ENDPOINT_URL> and <S3_BUCKET> — then apply
kubectl apply -f 02-init-job.yaml
kubectl -n starrocks wait --for=condition=complete job/starrocks-init --timeout=600s
kubectl -n starrocks logs job/starrocks-init

# 8. Client-facing Services
kubectl apply -f 03-services.yaml

# 9. NetworkPolicy (apply LAST — under default-deny, premature application blocks init traffic)
kubectl apply -f 04-networkpolicy.yaml
```

---

## §6 — Verify Cluster Health

```bash
# ─── Storage volume ───────────────────────────────────────────────────────────
kubectl -n starrocks exec -it <fe-pod-0> -- \
  mysql -h 127.0.0.1 -P 9030 -u root -e "SHOW STORAGE VOLUMES\G"
# Expected: s3_volume; IsDefault=true; Enabled=true

# ─── CN data cache ────────────────────────────────────────────────────────────
kubectl -n starrocks exec -it <fe-pod-0> -- \
  mysql -h 127.0.0.1 -P 9030 -u root \
  -e "SELECT * FROM information_schema.datacache_stats\G"
# Expected: non-zero disk_quota on each CN

# ─── FE HTTP health ───────────────────────────────────────────────────────────
FE_SVC=$(kubectl -n starrocks get svc starrocks-production-fe-service \
  -o jsonpath='{.spec.clusterIP}')
curl -sf "http://${FE_SVC}:8030/api/health" && echo "FE healthy"

# ─── Helm release status ──────────────────────────────────────────────────────
helm status starrocks -n starrocks
```

---

## §7 — Vault Agent Credential Injection (Advanced)

The `values.yaml` annotations trigger the Vault Agent Injector to write
`/vault/secrets/s3-creds.conf` (S3 credentials as conf properties) to each
FE/CN pod.

**Primary credential path**: the init Job (`02-init-job.yaml`) creates the S3
storage volume via DDL using credentials from the `starrocks-s3-credentials`
Kubernetes Secret. CN nodes retrieve credentials from FE metadata for all S3
operations — credentials do not need to be in `cn.conf`.

**If direct conf injection is required** (e.g., to pass credentials through
`fe.conf`/`cn.conf` for operations that bypass the named storage volume),
add an `initContainers` block under `starRocksFeSpec` or `starRocksComputeNodeSpec`
in `values.yaml`:

```yaml
# Append to starRocksFeSpec: (or starRocksComputeNodeSpec:) in values.yaml
# Requires kube-starrocks >= 1.8 and agent-init-first: "true" in annotations
# (Vault Agent runs as init-0; this runs after it as init-1)
initContainers:
  - name: inject-s3-credentials
    image: alpine:3.19
    command:
      - sh
      - -c
      - cat /vault/secrets/s3-creds.conf >> /opt/starrocks/fe/conf/fe.conf
```

**Credential rotation** procedure:
```bash
# 1. Update secret in Vault and the Kubernetes Secret
# 2. Rolling restart to pick up new Vault Agent renderings
kubectl -n starrocks rollout restart statefulset -l app.kubernetes.io/component=fe
kubectl -n starrocks rollout restart statefulset -l app.kubernetes.io/component=cn
# 3. If rotating the storage volume credentials, update via SQL:
#    ALTER STORAGE VOLUME s3_volume SET PROPERTIES (
#      "aws.s3.access_key" = "new-key",
#      "aws.s3.secret_key" = "new-secret"
#    );
```

---

## §8 — Post-Deployment: Run SQL DDL

After all pods are Running/Ready and the storage volume is confirmed:

```bash
EXTERNAL_IP=$(kubectl -n starrocks get svc starrocks-fe-mysql-lb \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
mysql -h "${EXTERNAL_IP}" -P 9030 -u root
```

Run DDL from `starrocks/sql/` in order:

| File | Purpose | Notes |
|---|---|---|
| `01_storage_volume.sql` | Verify/document storage volume | Already created by init Job |
| `02_database.sql` | Create database | Run first |
| `03_events_table.sql` | Primary Key events table | Includes `persistent_index_type = CLOUD_NATIVE` |
| `04_routine_load.sql` | Kafka → StarRocks Routine Load | Requires Redpanda running |
| `05_routine_load_dlq.sql` | DLQ table for failed messages | Optional; recommended |
| `06_pipe_s3.sql` | S3 file ingest via Pipe | StarRocks 3.2+ |
| `07_compliance.sql` | Compliance DELETE/UPDATE examples | Reference DDL |

---

## §9 — PoC Validation Checklist

**Phase 1 — FE cluster**
- [ ] `SHOW FRONTENDS` shows 3 FEs; exactly 1 IsMaster; all Alive
- [ ] FE leader failover: kill leader pod → follower election within 30 s; Routine Load resumes
- [ ] Vault Agent: `/vault/secrets/s3-creds.conf` exists in each FE pod
- [ ] `helm status starrocks -n starrocks` shows DEPLOYED

**Phase 2 — CN PoC (start with 1 CN)**
- [ ] `SHOW COMPUTE NODES` shows CN with Alive=true
- [ ] `SELECT * FROM information_schema.datacache_stats` shows non-zero disk_quota
- [ ] Manual INSERT → verify S3 write completes without error
- [ ] `DELETE FROM events WHERE user_id = X` → immediate logical inaccessibility

**Phase 3 — Routine Load**
- [ ] Routine Load job RUNNING (`SHOW ROUTINE LOAD`)
- [ ] Full ingest rate (~57,870 rows/sec) sustained ≥ 2 hours; CN CPU/memory stable
- [ ] Rowset count per partition remains bounded (no small-file accumulation)

**Phase 4 — Pipe**
- [ ] Pipe loads test file; no double-load on retry
- [ ] FE leader failover mid-load; Pipe resumes cleanly

**Phase 5 — Scale to 7 CNs**
- [ ] `helm upgrade` with `replicas: 7` → all 7 CNs Alive; tablet redistribution completes
- [ ] No data loss or query errors during redistribution

**Phase 6 — Compliance and rotation**
- [ ] `ALTER TABLE events COMPACT PARTITION <p>` duration on ~714M-row partition
- [ ] Partition TTL: S3 objects deleted after `partition_ttl` expires
- [ ] Credential rotation: `helm upgrade` with new image → rolling restart → Vault sidecar rewrites `/vault/secrets/s3-creds.conf`

---

## §10 — Open Decisions — Blocking Placeholders

| Decision | File | Placeholder | Blocks |
|---|---|---|---|
| Q1 — S3 backend | `02-init-job.yaml` | `<S3_ENDPOINT_URL>`, `<S3_BUCKET>` | Storage volume creation |
| Q1 — S3 CIDR | `04-networkpolicy.yaml` | `0.0.0.0/0` in starrocks-to-s3 | NetworkPolicy security |
| Q3 — FE count | `values.yaml` → `starRocksFeSpec.replicas` | `3` | FE fault tolerance |
| Q7 — NVMe cache size | `values.yaml` → `storageSize`, `01-configmaps.yaml` → `datacache_disk_size` | `575Gi`, `500000000000` | PVC and cache sizing |
| Q12 — Cache populate mode | `01-configmaps.yaml` → `datacache_populate_mode` | `auto` | Cache warmth validation |
| Vault path / role | `values.yaml` annotations | `secret/data/starrocks/s3/credentials`, `starrocks` | Vault injection |
| StorageClass names | `values.yaml` → `storageClassName` | `standard`, `nvme-storageclass` | PVC provisioning |
| Node labels / taints | `values.yaml` → `nodeSelector`, `tolerations` | `starrocks/role=fe`, `starrocks/role=cn` | Pod scheduling |
| CPU / memory | `values.yaml` → `resourceRequirements` | Resource requests/limits | Capacity planning |
| Pod label keys | `values.yaml` affinities, `04-networkpolicy.yaml` | `app.kubernetes.io/name`, `component` | Anti-affinity, NetworkPolicy |
| Kafka namespace / labels | `04-networkpolicy.yaml` | `redpanda` namespace, `app: redpanda` | Routine Load connectivity |

See [`starrocks-architecture.md §9`](../starrocks-architecture.md#9-open-decisions) for the full
list of 12 open decisions with blocking status and context.

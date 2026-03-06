# ClickHouse Production Architecture on Kubernetes

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
   - 1.1 [Throughput and Capacity Baseline](#11-throughput-and-capacity-baseline)
2. [Component Descriptions](#2-component-descriptions)
3. [Data Flow Diagrams](#3-data-flow-diagrams)
   - 3.1 [Kafka Ingest Path](#31-kafka-ingest-path)
   - 3.2 [S3Queue Ingest Path](#32-s3queue-ingest-path)
   - 3.3 [Query Path](#33-query-path)
   - 3.4 [Query Routing Options: K8s Service vs chproxy](#34-query-routing-options-k8s-service-vs-chproxy)
4. [Storage Policy Design](#4-storage-policy-design)
5. [Replication and HA Design](#5-replication-and-ha-design)
6. [Cross-Cluster Write Architecture](#6-cross-cluster-write-architecture)
   - 6.4 [Credential Management via HashiCorp Vault](#64-credential-management-via-hashicorp-vault)
7. [Critical Limitations and Risks](#7-critical-limitations-and-risks)
   - 7.3 [Compliance Mutations with Zero-Copy](#73-compliance-mutations-with-zero-copy)
8. [Open Questions](#8-open-questions)
9. [Recommended Versions](#9-recommended-versions)
10. [Implementation Order](#10-implementation-order)

---

## 1. Architecture Overview

This design implements a production-grade ClickHouse setup on Kubernetes using the Altinity ClickHouse Operator. The architecture separates compute from storage (S3 backend), uses ClickHouse Keeper in place of ZooKeeper, and implements two interconnected clusters:

- **Ingest cluster**: stateless compute tier that consumes from Kafka and S3 source buckets
- **Cache cluster**: persistent storage and query tier backed by S3 with local NVMe/SSD cache

```
                     ┌─────────────────────────────────────────────────┐
                     │              Kubernetes Cluster                  │
                     │                                                  │
 ┌──────────┐        │  ┌─────────────────────────────────────────┐    │
 │  Apache  │        │  │        Ingest Cluster (2 pods)           │    │
 │  Kafka   │────────┼──│  ┌──────────────┐  ┌──────────────┐    │    │
 └──────────┘        │  │  │  Ingest-0    │  │  Ingest-1    │    │    │
                     │  │  │  (shard 1)   │  │  (shard 2)   │    │    │
 ┌──────────┐        │  │  │  KafkaEngine │  │  KafkaEngine │    │    │
 │  S3 Src  │────────┼──│  │  S3Queue     │  │  S3Queue     │    │    │
 │  Bucket  │        │  │  │  Mat. Views  │  │  Mat. Views  │    │    │
 └──────────┘        │  │  └──────┬───────┘  └──────┬───────┘    │    │
                     │  │         └────────┬──────────┘           │    │
                     │  └─────────────────┼───────────────────────┘    │
                     │     Distributed INSERT (cross-cluster)           │
                     │                    ▼                             │
                     │  ┌──────────────────────────────────────────┐   │
                     │  │        Cache Cluster (14 pods)            │   │
                     │  │  Sh1       Sh2    ...   Sh7               │   │
                     │  │  R0 R1    R0 R1         R0 R1             │   │
                     │  └──────────────────────────────────────────┘   │
                     │          │  NVMe/SSD cache layer │               │
                     │  ┌──────────────────────────────────────────┐   │
                     │  │       ClickHouse Keeper (3-5 pods)        │   │
                     │  └──────────────────────────────────────────┘   │
                     └─────────────────────────────────────────────────┘
                                          │
                               ┌──────────┘
                               ▼
                     ┌──────────────────┐
                     │  S3 Backend      │
                     │  (MinIO / NetApp)│
                     └──────────────────┘
```

### Pod Count Summary

| Component          | Pods     | Notes                             |
|--------------------|----------|-----------------------------------|
| ClickHouse Keeper  | 3–5      | 3 minimum; 5 recommended for prod |
| Ingest cluster     | 2        | 2 shards × 1 replica              |
| Cache cluster      | 14       | 7 shards × 2 replicas             |
| **Total CH pods**  | **19–21** |                                   |

### 1.1 Throughput and Capacity Baseline

**Daily ingest volume**: ~5 billion rows/day arriving continuously (no batch window).

| Metric | Value |
|---|---|
| Sustained ingest rate | ~57,870 rows/sec |
| Per ingest shard (2 shards) | ~28,935 rows/sec |
| Per cache shard (7 shards) | ~714M rows/shard/day |
| Expected duplicate rate | 10–20% (→ ~4–4.5B unique rows/day after deduplication) |

#### Part Accumulation Risk

At sustained ingest rates, controlling the number of data parts per partition is critical. ClickHouse slows INSERTs when a partition exceeds ~300 parts and blocks INSERTs entirely at ~3,000 parts ("too many parts" error).

KafkaEngine fires a Materialized View on every poll batch. Small batch sizes produce small, frequent parts — a direct path to part accumulation failure.

**Mitigation — tune `kafka_max_block_size`**: Set `kafka_max_block_size = 1048576` (1 million rows). With ~29,000 rows/sec per ingest shard, a 1M-row batch completes in ~35 seconds. This produces large parts at a manageable frequency and keeps part counts well below the limit.

**Additional merge pressure**: `ReplicatedReplacingMergeTree` (see [Section 2.3](#23-cache-cluster-14-pods)) must deduplicate 10–20% duplicates via background merges. At 500M–1B duplicate rows/day, background merge activity is significant. Tune `background_pool_size` accordingly and monitor merge queue depth via `system.merges`.

#### S3 Write Amplification

Write-through at 5B rows/day means every INSERT writes to S3 immediately. Background merges (including deduplication merges) add S3 rewrites on top of that. Plan S3 PUT bandwidth and cost budgets accordingly — row size is TBD (see [Open Question #8](#8-open-questions)).

---

## 2. Component Descriptions

### 2.1 ClickHouse Keeper

ClickHouse Keeper is the distributed coordination service for this deployment. It replaces ZooKeeper entirely and is used by:

- `ReplicatedMergeTree` for replication metadata (part tracking, merge coordination)
- S3Queue for file claim coordination (ensures each file is processed by exactly one ingest node)
- Zero-copy replication GC (tracks which S3 parts are safe to delete after merges)

**Deployment**: Either the `ClickHouseKeeperInstallation` CRD (operator version dependent — see [Open Question #3](#8-open-questions)) or a standalone StatefulSet.

**Criticality**: A Keeper quorum loss **simultaneously halts** cache replication, S3Queue processing, and zero-copy GC. This makes Keeper the highest-criticality component in the deployment.

**Placement**: Keeper pods must run on dedicated Kubernetes nodes with reserved CPU/memory. Pod anti-affinity must be enforced to spread Keeper across distinct nodes and, where possible, distinct availability zones.

**Quorum sizing**:
- 3 nodes: tolerates 1 node failure
- 5 nodes: tolerates 2 node failures (recommended for production)

### 2.2 Ingest Cluster (2 pods)

The ingest cluster is a **stateless compute tier**. It holds no persistent data and requires no S3 backend or cache disk.

**Topology**: 2 shards × 1 replica. Each shard is a single pod. There is no intra-cluster replication on ingest nodes; redundancy comes from the cache cluster downstream.

**Tables on each ingest node**:
- `KafkaEngine` table — reads from Kafka
- `S3Queue` table — reads from the S3 source bucket
- Materialized Views — transform and forward data from KafkaEngine and S3Queue
- `Distributed` table pointing to the cache cluster (used by MVs as the write target)

**Kafka partition assignment**: Each ingest shard reads a distinct partition group using a separate Kafka consumer group name per shard. Sharing a consumer group across both ingest nodes for the same topic is not supported by KafkaEngine and will cause data loss.

**S3Queue coordination**: Both ingest nodes read from the same source bucket. Keeper coordinates file claims so each file is processed by exactly one ingest node without duplication.

Both ingest nodes are defined in a **single `ClickHouseInstallation` (CHI)** alongside the cache cluster.

### 2.3 Cache Cluster (14 pods)

The cache cluster is the **primary persistent storage and query tier**.

**Topology**: 7 shards × 2 replicas = 14 pods.

**Table engine**: `ReplicatedReplacingMergeTree(ver)` with `allow_remote_fs_zero_copy_replication = 1`.

**Deduplication**: `ReplicatedReplacingMergeTree` deduplicates rows with the same primary key, keeping the row with the highest value of the `ver` column (typically an event timestamp in milliseconds as `UInt64`, or an incrementing sequence number). The specific column to use as `ver` is TBD — see [Open Question #6](#8-open-questions).

> **Note**: deduplication happens at **merge time**, not at INSERT time. Duplicate rows are transiently visible between insert and the next background merge. Transient duplicates are acceptable — `SELECT ... FINAL` is not required and should be avoided (it forces a merge-on-read and is typically 2–3× slower).

**Partition key**: `PARTITION BY toYYYYMMDD(event_date)` (daily partitions) is confirmed.

**Storage**: Local NVMe/SSD write-through cache backed by S3 (see [Section 4](#4-storage-policy-design)).

**Query interface**: A `Distributed` table (`cache_distributed`) spans all 7 shards. Clients may query any cache node; the node fans out to the appropriate shards and aggregates results.

**Replica placement**: The 2 replicas of each shard must land on different Kubernetes nodes (pod anti-affinity required). Spreading across availability zones is recommended where the infrastructure supports it.

### 2.4 S3 Storage Backend

All persistent data is stored in S3-compatible storage. Two candidates are under evaluation: **MinIO** and **NetApp**. The team must select one before YAML authoring begins (see [Open Question #1](#8-open-questions)).

**Bucket layout**: Single bucket with per-shard prefix:
```
s3://bucket/clickhouse/cache/shard-1/
s3://bucket/clickhouse/cache/shard-2/
...
s3://bucket/clickhouse/cache/shard-7/
```

Both replicas of a shard intentionally write to the same shard prefix. This is required for zero-copy replication: Replica B does not copy data from Replica A — it reads the S3 parts that A already wrote and registers them as its own, coordinating ownership via Keeper.

**Consistency requirement**: Strong read-after-write consistency is required. Both options below satisfy this requirement at the versions specified.

#### MinIO vs NetApp Comparison

| Dimension | MinIO | NetApp |
|---|---|---|
| **Consistency model** | Strong read-after-write consistency from 2021-09-23 release onward | Depends on product (ONTAP S3, StorageGRID); verify per-product docs — strong consistency is generally available but must be confirmed |
| **HA / erasure coding** | Distributed erasure-coded mode across ≥4 nodes with configurable EC (e.g., EC:4 or EC:2); single-node MinIO is not production-acceptable | Hardware-native redundancy (RAID, HA controllers); erasure coding varies by product line — confirm settings with storage team |
| **Credential management** | Access key + secret key pairs; supports MinIO service accounts; integrates with HashiCorp Vault via KV secrets engine | Standard S3-compatible access key + secret; credential lifecycle managed by NetApp tooling or Vault |
| **Vault integration path** | Vault KV or dynamic credentials via MinIO admin API; Vault Agent Sidecar injects creds into CH config at pod start | Vault KV for static access-key storage; no native dynamic-credential provider; same Vault Agent Sidecar injection pattern applies |
| **Operational complexity** | Operator-managed (Kubernetes MinIO Operator available); team owns the full storage layer | Storage team manages the appliance/cluster; ClickHouse team only manages S3 credentials and bucket configuration |
| **Cost model** | Infrastructure cost only (runs on commodity nodes) | Licensing + hardware; potentially pre-existing sunk cost if NetApp is already deployed |
| **ClickHouse PoC risk** | Widely used with ClickHouse zero-copy; well-documented combination | Less community documentation for CH + NetApp; requires explicit PoC validation |

**Recommendation**: If NetApp is already operational in the environment, prefer it to avoid managing an additional storage layer. If no existing S3 infrastructure exists, MinIO distributed mode is the proven path for ClickHouse zero-copy replication.

---

## 3. Data Flow Diagrams

### 3.1 Kafka Ingest Path

```
Kafka Topic (N partitions)
  │
  ├─► Ingest-0  (partitions 0 .. N/2-1)
  │     KafkaEngine (consumer_group = ingest_shard_1)
  │       └─► Materialized View
  │             └─► Distributed table → cache cluster shards 1-7
  │
  └─► Ingest-1  (partitions N/2 .. N-1)
        KafkaEngine (consumer_group = ingest_shard_2)
          └─► Materialized View
                └─► Distributed table → cache cluster shards 1-7
```

Each cache shard receives rows from both ingest nodes. Rows are distributed by `xxHash64(sharding_column)` — deterministic hashing is confirmed as the mechanism. The specific column(s) to use as the sharding key are TBD (see [Open Question #7](#8-open-questions)).

**Kafka partition count**: At ~28,935 rows/sec per ingest shard, the Kafka topic must have enough partitions to sustain this throughput. Partition count must be a multiple of 2 (so each ingest shard gets an equal partition group). The exact count depends on message size and broker throughput — finalize during PoC (see [Open Question #5](#8-open-questions)).

### 3.2 S3Queue Ingest Path

```
S3 Source Bucket
  │
  ├─► Ingest-0  (claims files via Keeper lock)
  │     S3Queue
  │       └─► Materialized View
  │             └─► Distributed table → cache cluster shards 1-7
  │
  └─► Ingest-1  (claims files via Keeper lock)
        S3Queue
          └─► Materialized View
                └─► Distributed table → cache cluster shards 1-7
```

Keeper prevents both nodes from processing the same file. File processing state is persisted in Keeper so that if an ingest node restarts mid-file, the file is retried cleanly.

### 3.3 Query Path

**Chosen mechanism**: Kubernetes Service load balancing (see [Section 3.4](#34-query-routing-options-k8s-service-vs-chproxy) for the comparison that led to this decision).

```
Client
  └─► K8s Service (ClusterIP or LoadBalancer, port 9000/8123)
        └─► Any cache node (round-robin or random pod selection)
              └─► cache_distributed (Distributed table, cluster = cache)
                    ├─► Shard 1 (queries one replica)
                    ├─► Shard 2 (queries one replica)
                    │   ...
                    └─► Shard 7 (queries one replica)
                          └─► Aggregate results → Client
```

Hot data is served from the local NVMe cache. On a cache miss, the S3 parts are read from S3 and the result is populated into the local NVMe cache for subsequent reads.

The K8s Service targets all cache pods via label selector. Native Kubernetes health checking removes failed pods from the endpoint slice without additional tooling.

### 3.4 Query Routing Options: K8s Service vs chproxy

**Decision**: K8s Service LB selected. This section documents the trade-off evaluation for the record.

| Dimension | K8s Service (chosen) | chproxy |
|---|---|---|
| **Operational complexity** | None — native Kubernetes primitive, no extra component to deploy or upgrade | Additional StatefulSet or Deployment; requires HA deployment of chproxy itself |
| **Health checking** | Kubernetes readiness/liveness probes remove unhealthy pods from endpoints automatically | chproxy has its own health check logic; must be configured separately |
| **Connection pooling** | None — each client connection goes directly to a CH pod | chproxy pools connections, reducing CH connection overhead under high client concurrency |
| **Per-user / per-query routing** | Not available — all queries hit any pod | Supports per-user cluster routing, read-only enforcement, and query-level routing rules |
| **Queue limiting / overflow** | Not available | chproxy can queue or reject queries that exceed concurrency limits |
| **Protocol support** | TCP (port 9000) and HTTP (port 8123) | HTTP only (proxies ClickHouse HTTP interface) |
| **TLS termination** | Handled by K8s Ingress or external LB | chproxy can terminate TLS before CH |
| **When to reconsider** | If client concurrency causes CH connection exhaustion, or if per-user query isolation becomes a requirement | — |

chproxy is widely used in production ClickHouse deployments and remains the recommended path if the simpler K8s Service approach hits connection-count or routing limitations.

---

## 4. Storage Policy Design

### 4.1 Disk Hierarchy (Cache Cluster Only)

Each cache pod has a three-layer disk hierarchy:

```
cache disk  (type: cache)
  ├── local path: /var/lib/clickhouse/s3_cache/  [NVMe PVC]
  └── wraps: s3 disk  (type: s3)
                └──► s3://bucket/clickhouse/cache/shard-{N}/
```

The `cache` disk type is a ClickHouse-native write-through cache layer. On INSERT, data is written simultaneously to the local NVMe path and the S3 backend. On read, the local NVMe copy is used if present; otherwise the S3 part is fetched and cached locally.

### 4.2 Key Storage Settings

| Setting | Value | Notes |
|---|---|---|
| `cache_on_write_operations` | `1` | Write-through: INSERTs populate the NVMe cache |
| `max_size` | TBD | Size of the NVMe PVC — see [Open Question #8](#8-open-questions) |
| `allow_remote_fs_zero_copy_replication` | `1` | Set in MergeTree settings block; enables zero-copy between replicas |
| `kafka_max_block_size` | `1048576` | Rows per KafkaEngine MV fire. At ~29k rows/sec per shard, a 1M-row batch completes in ~35 sec — large parts, manageable frequency; prevents "too many parts". Set on the KafkaEngine table. |
| `background_pool_size` | TBD (≥8 recommended) | Background merge threads per server. Increase to handle deduplication merge pressure at 5B rows/day + 10–20% duplicate rate. |

#### Cache Eviction Strategy

ClickHouse cache disk uses **LRU (Least Recently Used) eviction** by default. The interplay with `cache_on_write_operations = 1` produces the following recency profile:

- **Newest data is always resident**: every INSERT writes through to NVMe immediately. The most recently ingested partitions are always cache-warm.
- **Actively queried older data stays warm**: LRU retains parts that are being read regularly. Repeated queries on recent-but-not-newest data keep those parts in NVMe.
- **Eviction triggers only at `max_size`**: when the NVMe PVC approaches its configured limit, the least-recently-used parts are evicted. Evicted data is still readable — ClickHouse transparently fetches from S3 on a cache miss, then re-populates the local cache.

**Sizing guidance**: Target the NVMe cache at the *active working set* — the data expected to be queried regularly. A starting point of 20–30% of total dataset size is reasonable; tune upward based on observed cache hit rate.

**Key monitoring metric**:
```sql
SELECT
    cache_name,
    formatReadableSize(size)        AS cache_size,
    formatReadableSize(used_size)   AS used,
    hits,
    misses,
    round(hits / (hits + misses) * 100, 1) AS hit_rate_pct
FROM system.filesystem_cache_log
-- or for current state:
-- FROM system.filesystem_cache
```

A hit rate below ~90% on hot queries indicates the NVMe cache is undersized for the active working set. Increase `max_size` or reduce the working set by tuning TTL/partition pruning.

### 4.3 S3 Disk Type

Use the standard `s3` disk type. Do **not** use `s3_plain`.

`s3_plain` produces an immutable flat-path layout that is incompatible with `ReplicatedMergeTree`: merges write new parts at new S3 paths, which `s3_plain` cannot manage. See [Section 7.2](#72-s3_plain-incompatibility) for details.

### 4.4 Ingest Cluster Storage

The ingest cluster uses the **default storage policy** (local disk only). No S3 disk and no cache disk are configured on ingest nodes. All ingest data is immediately forwarded to the cache cluster; nothing is retained locally.

---

## 5. Replication and HA Design

### 5.1 Cache Cluster Replication

Replication is handled by `ReplicatedMergeTree` coordinated through ClickHouse Keeper.

**Normal write path** (zero-copy):
1. Ingest node sends rows to cache Shard N, Replica 0.
2. Replica 0 writes the data part to the local NVMe cache and the S3 prefix for shard N.
3. Replica 0 registers the new part in Keeper.
4. Replica 1 sees the new part in Keeper, records the same S3 path as its own (zero-copy: no data is transferred between replicas over the network).
5. Both replicas now have the part on S3; their local NVMe caches populate lazily or on access.

**Failure modes and recovery**:

| Failed Component | Impact | Recovery |
|---|---|---|
| 1 cache replica (any shard) | Reads and writes continue via the other replica; no data loss | Pod restart; replica re-syncs via Keeper |
| Both replicas of 1 shard | That shard is unavailable; `cache_distributed` queries fail | Restore from S3 (data preserved); restart pods |
| Keeper quorum loss | All replication halts; S3Queue halts; GC halts; new INSERTs fail | Restore Keeper quorum; ClickHouse resumes automatically |
| S3 unavailable | INSERTs fail (write-through); reads from NVMe cache still work | Restore S3; buffered writes must be replayed |
| Ingest node failure | Kafka: offsets hold; messages reprocessed on restart. S3Queue: Keeper releases unclaimed files. | Pod restart |

### 5.2 Keeper HA

- Minimum 3 nodes for any cluster (quorum = 2).
- Recommended 5 nodes for production (quorum = 3; tolerates 2 failures).
- Must run on dedicated Kubernetes nodes to avoid resource contention with ClickHouse workloads.
- Pod anti-affinity must prevent any two Keeper pods from sharing a node.

### 5.3 S3 HA

S3 availability directly governs INSERT availability (write-through). S3 HA must be designed and validated before this architecture can claim full HA. Requirements differ by backend:

**MinIO** (if selected):
- Must run in distributed erasure-coded mode across a minimum of 4 nodes (MinIO requirement for erasure coding).
- Recommended configuration: ≥4 nodes with EC:2 or EC:4 depending on drive count and desired fault tolerance.
- Single-node or single-drive MinIO is not acceptable for production.
- MinIO itself must have a quorum of nodes available for writes; losing >50% of nodes halts writes.
- Deploy behind a stable DNS name or K8s Service; ClickHouse connects to MinIO via the configured endpoint in the storage policy XML.
- See [Open Question #2](#8-open-questions) for MinIO node/drive count decision.

**NetApp** (if selected):
- Verify that the specific product (ONTAP S3, StorageGRID, etc.) is configured with hardware-level redundancy (RAID, HA controller pairs).
- Confirm erasure-coding settings with the storage team before PoC.
- Confirm that the product version provides strong read-after-write consistency on the S3 API path used by ClickHouse.
- NetApp HA is largely managed by the storage team; the ClickHouse team's responsibility is limited to endpoint stability and credential availability.

**Common requirement for both**: The S3 endpoint must be reachable from all 14 cache pods and both ingest pods on the ports configured in the storage policy (typically 443 for HTTPS or 9000 for MinIO HTTP). Validate K8s NetworkPolicy allows this traffic.

---

## 6. Cross-Cluster Write Architecture

### 6.1 Single CHI — Auto-Generated Remote Servers

Both the ingest cluster and the cache cluster are defined in **one `ClickHouseInstallation` (CHI)**. The Altinity ClickHouse Operator automatically generates the `remote_servers` configuration for all clusters defined within a CHI and distributes it to every pod in that CHI.

This means ingest nodes automatically know the full shard/replica topology of the cache cluster — **no manual `remote_servers` XML is needed**. This is the recommended and correct approach.

> **Verify**: Confirm that the target Altinity operator version generates cross-cluster `remote_servers` for a multi-cluster CHI before beginning YAML authoring. See [Open Question #12](#8-open-questions).

### 6.2 Write Path: Kafka to Cache

```
Kafka partition group
  └─► KafkaEngine on Ingest-0
        └─► Materialized View fires on each batch
              └─► Distributed table (cluster = "cache", sharding_key = xxHash64(sharding_column))
                    ├─► INSERT → Cache Shard 1, Replica 0  (writes NVMe + S3)
                    ├─► INSERT → Cache Shard 3, Replica 0
                    └─► ...
```

The `Distributed` table references the cluster name `cache` as declared in the CHI YAML. The operator populates the connection details. No manual host lists or port configurations are required on ingest nodes.

### 6.3 Authentication and Network Policy

The Altinity operator sets `interserver_secret` automatically for all pods within the same CHI. Cross-cluster INSERTs from ingest pods to cache pods are authenticated without manual credential management.

**Required Kubernetes NetworkPolicy**: ingest pods must be permitted to reach cache pods on:
- Port **9000** (native TCP, used by Distributed table inserts)
- Port **9009** (interserver HTTP, used for replication)

Keeper pods must be reachable from all cache and ingest pods on:
- Port **2181** (Keeper client port)
- Port **2888** / **3888** (Keeper internal cluster ports)

### 6.4 Credential Management via HashiCorp Vault

**Decision**: All secrets are sourced from HashiCorp Vault using the Kubernetes auth method. Kubernetes Secrets are not the primary credential store for this deployment.

#### Credentials Managed by Vault

| Credential | Used by | Vault path (example) |
|---|---|---|
| S3 access key + secret | Cache pods (storage policy XML), ingest pods (S3Queue) | `secret/clickhouse/s3/credentials` |
| ClickHouse user passwords | Client authentication | `secret/clickhouse/users/{username}` |
| Interserver secret | All CH pods (if not auto-managed by operator) | `secret/clickhouse/interserver` |

For S3 credentials specifically: ClickHouse reads S3 access key and secret key from the storage policy XML at startup (and on SIGHUP). These must be present in the XML config before `clickhouse-server` starts.

#### Vault Injection Patterns

**Option A — Vault Agent Sidecar (recommended for ClickHouse)**

Vault Agent runs as an init container and writes rendered secret templates into a shared volume before the `clickhouse-server` container starts. The rendered output is a ClickHouse XML config drop-in file placed in `/etc/clickhouse-server/config.d/`.

```
Pod startup sequence:
  1. vault-agent (init container) authenticates to Vault via K8s ServiceAccount token
  2. vault-agent renders s3-credentials.xml from Vault KV → /etc/clickhouse-server/config.d/s3-credentials.xml
  3. clickhouse-server starts, reads config.d/ — S3 creds are already present
```

Advantage: credentials never exist as a Kubernetes Secret object. Vault Agent handles token renewal. `clickhouse-server` sees static files at startup — no ClickHouse-side Vault awareness needed.

**Option B — Vault Secrets Operator**

The Vault Secrets Operator materializes Vault secrets as Kubernetes Secret objects, which are then mounted into pods as files or environment variables.

Advantage: simpler pod manifest (no sidecar); standard K8s Secret mount pattern.

Disadvantage: credentials exist briefly as Kubernetes Secret objects in etcd. Requires RBAC controls on Secret access. Less appropriate for high-sensitivity credentials.

#### Recommended Pattern

Use **Vault Agent Sidecar** as an init container. Configure it to:
1. Authenticate using the pod's Kubernetes ServiceAccount via the Vault Kubernetes auth backend.
2. Render a ClickHouse XML config drop-in file containing S3 access/secret keys.
3. Write the rendered file to a shared `emptyDir` volume mounted at `/etc/clickhouse-server/config.d/`.
4. Exit — `clickhouse-server` starts after the init container completes.

#### Secret Rotation Procedure

ClickHouse does not hot-reload S3 credentials automatically when the underlying file changes. To rotate S3 credentials without downtime:

1. Update the secret in Vault.
2. Vault Agent (if running as a sidecar, not init-only) re-renders the config file on the next renewal cycle.
3. Send SIGHUP to the `clickhouse-server` process: `kill -HUP $(pidof clickhouse-server)`. ClickHouse reloads XML config files on SIGHUP without restarting.
4. Verify: query `SELECT * FROM system.disks` and confirm no S3 errors appear in `system.text_log`.

Plan a rotation procedure and test it in staging before the first production credential rotation.

---

## 7. Critical Limitations and Risks

### 7.1 SharedMergeTree Is NOT Available in Open-Source ClickHouse

`SharedMergeTree` is available **only in ClickHouse Cloud**. Any documentation, blog post, or tooling suggesting `SharedMergeTree` for a self-hosted deployment is incorrect. Attempting to use it on an open-source ClickHouse binary produces:

```
Code: 60. DB::Exception: Unknown table engine 'SharedMergeTree'
```

The correct engine for this architecture is `ReplicatedMergeTree` with `allow_remote_fs_zero_copy_replication = 1`.

**Action required**: The implementation team must explicitly review and acknowledge this warning before YAML authoring begins.

### 7.2 s3_plain Incompatibility

`s3_plain` uses an immutable flat path layout. `ReplicatedMergeTree` merges write new data parts to new S3 paths. `s3_plain` cannot handle path mutations required by merges. **Always use the standard `s3` disk type**.

### 7.3 Compliance Mutations with Zero-Copy

Nightly compliance DELETE and UPDATE operations are a confirmed hard requirement. This section documents how both lightweight mutation mechanisms interact with zero-copy replication, the physical deletion timing risk, and the recommended compliance path.

#### General Zero-Copy Caveats

| Risk | Detail | Mitigation |
|---|---|---|
| Version requirement | Zero-copy had correctness bugs before 23.x | This deployment targets ClickHouse 26.x LTS (see [Section 9](#9-recommended-versions)); 26.x is well past the stability threshold |
| GC accumulation | Pre-merge S3 parts are GC'd only after all replicas acknowledge the merged part in Keeper. Extended replica downtime causes S3 storage growth | Monitor S3 object count and size; set replica downtime SLA |
| S3 write amplification from merges | Frequent small merges generate many S3 PUT operations | Tune `min_bytes_for_wide_part`, `merge_max_block_size`, and merge selector settings |

#### Lightweight UPDATE (Patch Parts, CH 24.3+)

Patch parts write a small overlay S3 object that stores the updated column values for affected rows. The original data part on S3 is unchanged; the patch is applied at read time.

- **Zero-copy interaction**: the patch overlay is a new small S3 object. It is replicated to both replicas via Keeper coordination (same mechanism as new data parts). The original part is not rewritten.
- **S3 write amplification**: low — only the changed columns are written, not the full part.
- **Production track record**: patch parts alongside zero-copy replication are relatively new (CH 24.3+). **Must be validated in the PoC before relying on them for nightly compliance updates.**

#### Lightweight DELETE (CH 23.3+)

Lightweight DELETE writes a deletion bitmap alongside the data part. Deleted rows are filtered at query execution time and are logically invisible immediately after the DELETE completes.

**Critical gap**: the physical S3 bytes for deleted rows are NOT removed until the data part participates in a merge. Until then, a client with direct S3 access can still read the raw part files.

#### TTL-Based Expiration (`eviction_date`)

A time-based TTL on the `eviction_date` column is a confirmed compliance requirement. The recommended DDL pattern is:

```sql
TTL eviction_date DELETE
SETTINGS TTL_only_drop_parts = 1
```

**How `TTL_only_drop_parts = 1` works**: when every row in a data part has an expired TTL, ClickHouse drops the entire part without performing a merge rewrite. This is equivalent to `DROP PARTITION` behavior — **instant physical deletion** of S3 objects for that part.

**24-hour SLA satisfaction**: `PARTITION BY toYYYYMMDD(event_date)` (daily partitions) is confirmed and `TTL_only_drop_parts = 1` is set. Parts whose entire content has expired are dropped within the TTL check interval (default: every 60 seconds), trivially satisfying the 24-hour SLA. No manual intervention required.

**User-ID compliance deletes — sole compliance delete path (confirmed required, high risk at scale)**

User-ID compliance deletes (`DELETE FROM cache_table WHERE user_id = X`) are a confirmed requirement. A given user's rows are distributed across all time partitions — this is non-partition-aligned and row-level delete is unavoidable.

```sql
-- Step 1: logical deletion (immediate, but not physical)
DELETE FROM cache_table WHERE user_id = 12345;

-- Step 2: force physical removal by triggering a merge on every affected partition
OPTIMIZE TABLE cache_table PARTITION '2024-01' FINAL;
OPTIMIZE TABLE cache_table PARTITION '2024-02' FINAL;
-- ... repeat for every partition that contained matching rows
```

`OPTIMIZE TABLE PARTITION FINAL` rewrites all data parts in a partition into a single merged part, physically removing the deleted rows from S3 in the process.

**Severity at 5B rows/day scale**: This is a critical risk that must be explicitly planned for.

- At ~714M rows/shard/day, each daily partition on each shard holds hundreds of millions of rows. `OPTIMIZE TABLE PARTITION FINAL` reads all S3 parts for that partition, rewrites them into one merged part, and writes the result back — a multi-GB+ S3 I/O operation per partition.
- A single user's data across 12 months with daily partitions = 365 `OPTIMIZE TABLE FINAL` calls per shard = **2,555 total** across the cluster. At production data volumes, this sweep could take many hours and compete directly with normal ingest merge activity.
- Even with monthly partitions, 12 months × 7 shards = 84 `OPTIMIZE TABLE FINAL` calls — each operating on a partition containing ~22B rows. This is likely infeasible within 24 hours under any concurrent workload.
- Zero-copy compatibility: `OPTIMIZE TABLE FINAL` is compatible with zero-copy, but creates new merged parts on S3; Keeper coordinates GC of old parts. Allow additional time (typically minutes) for GC to physically remove S3 objects. This lag counts against the 24-hour SLA.

**The 24-hour physical deletion SLA for user-ID row-level deletes may be infeasible at production volumes.** See [Open Question #17](#8-open-questions) for the legal determination that must be obtained before finalizing this path.

---

#### Hard Architectural Recommendation

**`PARTITION BY toYYYYMMDD(event_date)` (daily) is confirmed.** Daily partitions are the primary mitigation lever for user-ID compliance deletes: each `OPTIMIZE TABLE PARTITION FINAL` call operates on a single day's data per shard, limiting the rows-per-partition that must be rewritten. At ~714M rows/shard/day this is still a heavy operation — but it is the best achievable bound given the non-partition-aligned delete pattern. The PoC must measure the actual elapsed time and S3 I/O per partition to determine whether the 24-hour SLA is feasible (see [Open Question #17](#8-open-questions)).

#### PoC Validation Requirement

The nightly mutation path must be validated in the PoC before production deployment:
1. Execute a representative nightly DELETE on a partition sized to production data volumes.
2. Measure the time from DELETE issuance to physical S3 object removal (OPTIMIZE TABLE FINAL + GC).
3. Confirm the 24-hour SLA is achievable under production load conditions.

### 7.4 KafkaEngine At-Least-Once Delivery Risk

KafkaEngine commits the Kafka offset after the Materialized View fires, but the downstream `Distributed` INSERT to the cache cluster can still fail after the offset is committed. This creates a window for data loss (offset advanced, INSERT not persisted).

**Resolution**: `ReplicatedReplacingMergeTree` is confirmed as the cache cluster engine (Q6 resolved). This makes duplicate delivery idempotent: if KafkaEngine re-delivers a message after a failed INSERT (offset not yet committed), the duplicate row is deduplicated at the next background merge. Transient duplicates until merge are acceptable.

**Remaining options for additional safety**:
- Set `kafka_commit_every_batch = 0` to further reduce the loss window
- Configure a dead-letter Kafka topic to capture failed INSERTs for alerting

### 7.5 Keeper as a Multi-Subsystem Single Point of Failure

Keeper quorum loss simultaneously halts:
1. Cache replication (no new parts acknowledged)
2. S3Queue file processing (no new file claims)
3. Zero-copy GC (old S3 parts accumulate)
4. New INSERTs to ReplicatedMergeTree tables (blocked until quorum restored)

**Mitigation**: Run 5 Keeper nodes for production. Dedicate Kubernetes nodes exclusively to Keeper. Do not co-locate Keeper with ClickHouse server pods.

### 7.6 S3 Availability = INSERT Availability

Write-through caching means S3 is in the critical write path. If S3 becomes unreachable:
- INSERTs fail immediately
- Reads from the local NVMe cache continue for data already cached
- No write buffering at the ClickHouse layer

**Mitigation**: S3 HA (MinIO erasure coding or NetApp redundancy) must be operational before this architecture can claim production HA. Design and validate S3 HA independently before deploying ClickHouse.

---

## 8. Open Questions

The following decisions must be resolved before YAML authoring begins. Each unresolved question blocks one or more YAML files.

**Legend**: ✅ Resolved | ⬜ Open

| # | Status | Question | Blocks |
|---|---|---|---|
| 1 | ✅ | **S3 implementation**: Both MinIO and NetApp are under evaluation. See comparison in [Section 2.4](#24-s3-storage-backend) and [Section 5.3](#53-s3-ha). Decision required before storage policy YAML. | Storage policy YAML, S3 credentials |
| 2 | ⬜ | **MinIO HA** (if MinIO selected): distributed/erasure-coded mode? How many MinIO nodes and drives? | S3 HA validation |
| 3 | ⬜ | **Keeper deployment method**: `ClickHouseKeeperInstallation` CRD or standalone StatefulSet? Confirm target Altinity operator version and its CRD support. | Keeper YAML |
| 4 | ⬜ | **Keeper node count**: 3 (tolerates 1 failure) or 5 (tolerates 2 failures)? | Keeper YAML, node reservation |
| 5 | ⬜ | **Kafka partition strategy**: How many partitions per topic? How are they split between the 2 ingest shards? | KafkaEngine DDL |
| 6 | ✅ | **Deduplication engine**: `ReplicatedReplacingMergeTree(ver)` confirmed for the cache cluster. Expected duplicate rate: 10–20% (~500M–1B rows/day). Deduplication occurs at merge time; transient duplicates are acceptable — `SELECT ... FINAL` not required. **Sub-question open**: which column to use as `ver` (event timestamp in ms as `UInt64` recommended; specific column TBD). | Cache cluster DDL — engine resolved; `ver` column requires input |
| 7 | ✅ | **Sharding key mechanism**: `xxHash64(sharding_column)` confirmed as the distribution mechanism. **Specific column(s) TBD** — which column(s) should be used for the hash? | Distributed table DDL |
| 8 | ⬜ | **Cache disk sizing**: Target data volume per shard? What percentage of hot data must fit in the NVMe cache? | PVC sizing, storage class selection |
| 9 | ⬜ | **S3 bucket and prefix naming**: Finalize the bucket name and prefix scheme before any deployment. Renaming after data exists requires a full data migration. | Storage policy YAML |
| 10 | ⬜ | **CHI namespace strategy**: One `ClickHouseInstallation` per environment (dev/staging/prod), or one CHI across all environments? | CHI YAML structure |
| 11 | ✅ | **Query routing**: Kubernetes Service load balancing selected. Trade-offs vs chproxy documented in [Section 3.4](#34-query-routing-options-k8s-service-vs-chproxy). | Service/Ingress YAML — can proceed |
| 12 | ✅ | **Altinity operator version**: Confirmed **0.26.0+**. The cross-cluster `remote_servers` auto-generation behavior must still be validated in the PoC against this version before YAML authoring. | CHI YAML, cross-cluster write path — PoC validation required |
| 13 | ✅ | **S3 credentials management**: HashiCorp Vault with Kubernetes integration. Vault Agent Sidecar pattern selected. Details in [Section 6.4](#64-credential-management-via-hashicorp-vault). | Storage policy YAML, RBAC — design complete; implementation follows deployment |
| 14 | ✅ | **Mutation policy**: Nightly compliance DELETE and UPDATE confirmed as hard requirement. Compliance mechanism: lightweight `DELETE WHERE user_id = X` followed by `OPTIMIZE TABLE PARTITION FINAL` per affected partition (sole confirmed path). Patch parts (lightweight UPDATE) for field-level updates. Full design in [Section 7.3](#73-compliance-mutations-with-zero-copy). 24-hour physical deletion SLA feasibility TBD — see Q17. | DDL design — PARTITION BY confirmed daily; SLA validation pending Q17 |
| 15 | ✅ | **Cache eviction behavior**: LRU eviction is acceptable. Newer data prioritized via write-through (`cache_on_write_operations = 1`). Eviction sizing guidance and monitoring in [Section 4.2](#42-key-storage-settings). | PVC sizing — resolved; start with 20–30% of dataset, tune from hit rate |
| 16 | ✅ | **Compliance DELETE paths — resolved**: (1) **TTL path** (`eviction_date` column): `TTL_only_drop_parts = 1` with `PARTITION BY toYYYYMMDD(event_date)` (daily) → instant physical deletion; 24h SLA satisfied. (2) **User-ID path** (`DELETE WHERE user_id = X`): non-partition-aligned; lightweight DELETE + `OPTIMIZE TABLE PARTITION FINAL` per partition is the sole path. `PARTITION BY toYYYYMMDD(event_date)` **daily is now confirmed**. Physical SLA at production volumes remains high-risk — see Q17 and [Section 7.3](#73-compliance-mutations-with-zero-copy). | `PARTITION BY` DDL confirmed daily; SLA feasibility pending Q17 |
| 17 | ⬜ | **User-ID compliance SLA: physical vs logical deletion**. For `DELETE WHERE user_id = X` row-level compliance deletes: does the 24-hour SLA require **physical S3 byte removal** within 24 hours, or is **logical inaccessibility** (deletion bitmap applied; rows invisible to all queries) sufficient? Physical removal at 5B rows/day scale requires `OPTIMIZE TABLE FINAL` across all affected partitions — potentially hundreds or thousands of operations per delete request, taking many hours and competing with ingest. If physical deletion within 24 hours is strictly required, the current table design cannot satisfy it without a dedicated architecture change (e.g., separate per-user TTL partitioning). **This is a legal/compliance determination, not a technical one. The compliance team must provide a formal written answer before DDL is finalized.** | Cache cluster DDL, `PARTITION BY` design, compliance SLA validation |

---

## 9. Recommended Versions

| Component | Recommended | Minimum | Notes |
|---|---|---|---|
| ClickHouse Server | **26.x LTS** | 24.8 | Deployment targets 26.x LTS. Zero-copy replication is stable from 23.8; 26.x is well past all known correctness issues. Always use an LTS release for production. |
| Altinity Operator | **0.26.0+** | — | Confirmed version. Validate compatibility with ClickHouse 26.x and `ClickHouseKeeperInstallation` CRD support; validate cross-cluster `remote_servers` auto-generation in PoC. |
| ClickHouse Keeper | Same as CH Server | — | Keeper is bundled with ClickHouse. Keeper and CH server versions must match exactly. |
| MinIO (if selected) | **Latest available release** | 2021-09-23 | Strong read-after-write consistency was introduced in the 2021-09-23 release. Earlier versions are incompatible with zero-copy replication. |

---

## 10. Implementation Order

YAML authoring begins only after all [Open Questions](#8-open-questions) are resolved and the following conditions are met:

- The SharedMergeTree warning (Section 7.1) has been explicitly reviewed and acknowledged by the implementation team.
- The cross-cluster write mechanism (single CHI + auto-generated `remote_servers`) has been validated against the target Altinity operator version's documented behavior.
- A proof-of-concept test has verified that zero-copy replication functions correctly between 2 replicas on the target ClickHouse version and S3 backend before scaling to 14 pods.

### Implementation Phases

**Phase 1 — Keeper**
Deploy ClickHouse Keeper (StatefulSet or CRD). Validate quorum health before proceeding. All subsequent components depend on Keeper.

**Phase 2 — Cache cluster PoC (1 shard × 2 replicas)**
Deploy a single cache shard with zero-copy replication enabled. Validate:
- Data written to Replica 0 appears on Replica 1 without data transfer between pods
- S3 parts appear under the correct shard prefix
- NVMe cache is populated on write (`cache_on_write_operations = 1`)
- Cache miss triggers S3 read and local cache population
- **Throughput validation** (required at 5B rows/day scale):
  - Drive sustained ingest at ~29,000 rows/sec per shard; confirm no "too many parts" errors occur with `kafka_max_block_size = 1048576`
  - Monitor `system.merges` for merge queue depth under sustained load; tune `background_pool_size` as needed
- **Mutation and compliance validation** (required before production):
  - **TTL path**: create a table with `TTL eviction_date DELETE SETTINGS TTL_only_drop_parts = 1`; populate with data where all rows in a part have expired TTL; confirm the part is dropped within the TTL check interval (≤60 sec) and S3 objects are physically removed; verify no rewrite merge is triggered
  - **Compliance delete load test**: execute lightweight DELETE (`DELETE FROM t WHERE user_id = X`) on a partition sized to representative production volumes; run `OPTIMIZE TABLE PARTITION FINAL`; measure elapsed time and S3 I/O; measure time from DELETE issuance to confirmed physical S3 part removal; document against the 24-hour SLA — this is the primary input for Q17 resolution
  - If patch parts (lightweight UPDATE) are required for nightly compliance updates: validate `ALTER TABLE t UPDATE` using patch parts with zero-copy enabled; confirm both replicas reflect the update correctly
  - Document all measured timings for inclusion in the compliance evidence package

**Phase 3 — Scale cache cluster to full topology (7 shards × 2 replicas)**
Roll out the remaining 6 shards. Validate `cache_distributed` fan-out queries.

**Phase 4 — Ingest cluster + cross-cluster Distributed table**
Deploy both ingest nodes in the same CHI as the cache cluster. Validate that ingest nodes can resolve cache shard addresses from the operator-generated `remote_servers`.

**Phase 5 — KafkaEngine + S3Queue + Materialized Views**
Create ingest tables and views. Validate end-to-end: messages from Kafka and files from the S3 source bucket appear in the cache cluster.

**Phase 6 — Distributed query table + client connectivity**
Expose `cache_distributed` to clients via the chosen routing mechanism (Service, chproxy, etc.). Run query validation.

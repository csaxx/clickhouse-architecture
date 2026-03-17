# ClickHouse Production Architecture on Kubernetes

## Table of Contents

1. [Requirements and Assumptions](#1-requirements-and-assumptions)
   - 1.1 [Use Case and System Context](#11-use-case-and-system-context)
   - 1.2 [Ingest Requirements](#12-ingest-requirements)
   - 1.3 [Query Requirements](#13-query-requirements)
   - 1.4 [Compliance Requirements](#14-compliance-requirements)
   - 1.5 [Infrastructure Constraints](#15-infrastructure-constraints)
   - 1.6 [Design Assumptions](#16-design-assumptions)
2. [Architecture Overview](#2-architecture-overview)
   - 2.1 [Cluster Topology](#21-cluster-topology)
   - 2.2 [Pod Count Summary](#22-pod-count-summary)
3. [Component Descriptions](#3-component-descriptions)
   - 3.1 [ClickHouse Keeper](#31-clickhouse-keeper)
   - 3.2 [Ingest Cluster (2 pods)](#32-ingest-cluster-2-pods)
   - 3.3 [Cache Cluster (14 pods)](#33-cache-cluster-14-pods)
   - 3.4 [S3 Storage Backend](#34-s3-storage-backend)
4. [Data Flow](#4-data-flow)
   - 4.1 [Kafka Ingest Path](#41-kafka-ingest-path)
   - 4.2 [S3Queue Ingest Path](#42-s3queue-ingest-path)
   - 4.3 [Query Path](#43-query-path)
   - 4.4 [Query Routing: K8s Service vs chproxy](#44-query-routing-k8s-service-vs-chproxy)
   - 4.5 [Dedicated Query Cluster: Evaluated, Deferred](#45-dedicated-query-cluster-evaluated-deferred)
5. [Storage Design](#5-storage-design)
   - 5.1 [Disk Hierarchy (Cache Cluster)](#51-disk-hierarchy-cache-cluster)
   - 5.2 [Key Storage Settings](#52-key-storage-settings)
   - 5.3 [Cache Eviction Strategy](#53-cache-eviction-strategy)
   - 5.4 [S3 Disk Type Selection](#54-s3-disk-type-selection)
   - 5.5 [Ingest Cluster Storage](#55-ingest-cluster-storage)
6. [Replication and High Availability](#6-replication-and-high-availability)
   - 6.1 [Cache Cluster Replication](#61-cache-cluster-replication)
   - 6.2 [Keeper HA](#62-keeper-ha)
   - 6.3 [S3 HA](#63-s3-ha)
7. [Cross-Cluster Write Architecture](#7-cross-cluster-write-architecture)
   - 7.1 [Single CHI and Auto-Generated Remote Servers](#71-single-chi-and-auto-generated-remote-servers)
   - 7.2 [Write Path: Kafka to Cache](#72-write-path-kafka-to-cache)
   - 7.3 [Authentication and Network Policy](#73-authentication-and-network-policy)
   - 7.4 [Credential Management via HashiCorp Vault](#74-credential-management-via-hashicorp-vault)
8. [Risks and Limitations](#8-risks-and-limitations)
   - 8.1 [SharedMergeTree Not Available in Open-Source ClickHouse](#81-sharedmergetree-not-available-in-open-source-clickhouse)
   - 8.2 [s3_plain Incompatibility](#82-s3_plain-incompatibility)
   - 8.3 [Compliance Mutations with Zero-Copy Replication](#83-compliance-mutations-with-zero-copy-replication)
   - 8.4 [KafkaEngine At-Least-Once Delivery](#84-kafkaengine-at-least-once-delivery)
   - 8.5 [Keeper as a Multi-Subsystem Dependency](#85-keeper-as-a-multi-subsystem-dependency)
   - 8.6 [S3 Availability Equals INSERT Availability](#86-s3-availability-equals-insert-availability)
   - 8.7 [Zero-Copy Replication Production Stability](#87-zero-copy-replication-production-stability)
9. [Open Decisions](#9-open-decisions)
10. [Recommended Versions](#10-recommended-versions)
11. [Implementation Roadmap](#11-implementation-roadmap)
12. [Scalability Considerations](#12-scalability-considerations)
    - 12.1 [Ingest Tier](#121-ingest-tier)
    - 12.2 [Cache Cluster](#122-cache-cluster)
    - 12.3 [ClickHouse Keeper](#123-clickhouse-keeper)
    - 12.4 [S3 Storage](#124-s3-storage)
    - 12.5 [Query Concurrency](#125-query-concurrency)
    - 12.6 [Compliance Delete Scalability](#126-compliance-delete-scalability)
    - 12.7 [Operational Scalability](#127-operational-scalability)
    - 12.8 [Scalability Summary](#128-scalability-summary)
13. [Configuration Reference](#13-configuration-reference)

---

## 1. Requirements and Assumptions

This chapter collects the confirmed requirements and design assumptions that motivate the architectural decisions made throughout this document. Decisions reference these requirements where relevant.

### 1.1 Use Case and System Context

The system is a production-grade event data pipeline on Kubernetes. Data arrives continuously from two source systems and is made available for analytical queries:

- **Source A — Apache Kafka**: streaming events from application producers
- **Source B — S3 file uploads**: batch file deposits from external systems or ETL processes

Data flows through a stateless ingest tier and is persisted in a replicated, S3-backed query tier. Clients run analytical (read-heavy, ad-hoc) queries against the current dataset.

### 1.2 Ingest Requirements

| Metric | Value |
|---|---|
| Daily ingest volume | ~5 billion rows/day |
| Sustained ingest rate | ~57,870 rows/sec |
| Arrival pattern | Continuous — no batch window |
| Expected duplicate rate | 10–20% (~500M–1B duplicates/day) |
| Unique rows after deduplication | ~4–4.5B rows/day |
| Per ingest shard (2 shards) | ~28,935 rows/sec |
| Per cache shard (7 shards) | ~714M rows/shard/day |

Ingest must be continuous and uninterrupted; no maintenance window is available for batch loading.

**Part accumulation constraint**: KafkaEngine fires a Materialized View on every poll batch. Small batches produce many small parts per partition. ClickHouse slows INSERTs at ~300 parts/partition and blocks entirely at ~3,000 parts ("too many parts"). `kafka_max_block_size` must be tuned to limit part accumulation at this ingest rate (see [Section 5.2](#52-key-storage-settings)).

**Merge pressure**: `ReplicatedReplacingMergeTree` must deduplicate 500M–1B duplicate rows/day through background merges. Background merge pool sizing must account for this load (see [Section 5.2](#52-key-storage-settings)).

**S3 write amplification**: write-through at 5B rows/day means every INSERT writes to S3 immediately. Background deduplication merges add further S3 rewrites on top. S3 PUT bandwidth and cost must be budgeted accordingly — row size is TBD (see [Open Decision #8](#9-open-decisions)).

### 1.3 Query Requirements

- Analytical (read-heavy, ad-hoc) query workload
- Hot data (recently ingested) expected to be queried most frequently
- NVMe/SSD cache serves hot data; S3 fallback acceptable for cold data (cache miss)
- `SELECT ... FINAL` is not required and must be avoided: transient duplicates (pre-merge) are acceptable; `FINAL` forces a merge-on-read and is typically 2–3× slower
- No per-user query isolation or connection pooling required at initial deployment

### 1.4 Compliance Requirements

Two distinct compliance delete mechanisms are required as hard requirements:

**Time-based expiry (TTL path)**:
- An `eviction_date` column marks the expiry date of each row
- Physical S3 deletion must complete within 24 hours of the expiry date
- This SLA is satisfied by `TTL_only_drop_parts = 1` with daily partitions — see [Section 8.3](#83-compliance-mutations-with-zero-copy-replication)

**User-ID row-level delete**:
- Nightly compliance deletes of all rows for a given `user_id` (`DELETE FROM ... WHERE user_id = X`)
- 24-hour SLA applies — but whether "24 hours" means **physical S3 byte removal** or **logical inaccessibility** (rows invisible to all queries) is a pending legal determination (see [Open Decision #11](#9-open-decisions))
- This distinction has significant architectural impact: physical removal at 5B rows/day scale requires `OPTIMIZE TABLE PARTITION FINAL` across all affected partitions and may not be feasible within 24 hours — see [Section 8.3](#83-compliance-mutations-with-zero-copy-replication)

**Nightly compliance updates**: field-level UPDATE operations are also a confirmed nightly requirement (lightweight patch parts, CH 24.3+). Must be validated in the PoC.

### 1.5 Infrastructure Constraints

| Component | Constraint |
|---|---|
| Platform | Kubernetes |
| Operator | Altinity ClickHouse Operator 0.26.0+ |
| Secrets management | HashiCorp Vault with Kubernetes auth method |
| Coordination | ClickHouse Keeper (ZooKeeper not used) |
| Local storage | NVMe/SSD PersistentVolumes on cache nodes |
| Object storage | S3-compatible backend (MinIO or NetApp — decision pending, see [Open Decision #1](#9-open-decisions)) |

### 1.6 Design Assumptions

The following assumptions are made in the absence of confirmed values. They must be validated during the PoC and corrected before production sizing.

| Assumption | Value | Status |
|---|---|---|
| Duplicate handling | Merge-time deduplication acceptable; transient duplicates tolerated | Confirmed |
| Query isolation | K8s Service LB sufficient; per-user routing not required initially | Confirmed |
| Partition key | Daily (`PARTITION BY toYYYYMMDD(event_date)`) | Confirmed |
| Cache eviction | LRU acceptable; start at 20–30% of dataset for NVMe sizing | Confirmed |
| `ver` column for deduplication | Event timestamp in ms (`UInt64`) recommended; specific column TBD | Open — see [Decision #6](#9-open-decisions) |
| Sharding key column | `xxHash64(sharding_column)` confirmed as mechanism; column TBD | Open — see [Decision #7](#9-open-decisions) |
| Row size | TBD | Open — see [Decision #8](#9-open-decisions) |

---

## 2. Architecture Overview

The architecture separates compute from storage (S3 backend), uses ClickHouse Keeper for distributed coordination, and implements two interconnected clusters within a single Altinity `ClickHouseInstallation`:

- **Ingest cluster**: stateless compute tier that consumes from Kafka and S3 source buckets
- **Cache cluster**: persistent storage and query tier backed by S3 with local NVMe/SSD cache

### 2.1 Cluster Topology

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
                     │  │       ClickHouse Keeper (3–5 pods)        │   │
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

### 2.2 Pod Count Summary

| Component          | Pods      | Notes                               |
|--------------------|-----------|-------------------------------------|
| ClickHouse Keeper  | 3–5       | 3 minimum; 5 recommended for prod   |
| Ingest cluster     | 2         | 2 shards × 1 replica                |
| Cache cluster      | 14        | 7 shards × 2 replicas               |
| **Total CH pods**  | **19–21** |                                     |

---

## 3. Component Descriptions

### 3.1 ClickHouse Keeper

ClickHouse Keeper is the distributed coordination service for this deployment. It replaces ZooKeeper entirely and is used by:

- `ReplicatedMergeTree` for replication metadata (part tracking, merge coordination)
- S3Queue for file claim coordination (ensures each file is processed by exactly one ingest node)
- Zero-copy replication GC (tracks which S3 parts are safe to delete after merges)

**Deployment**: Either the `ClickHouseKeeperInstallation` CRD or a standalone StatefulSet — see [Open Decision #3](#9-open-decisions).

**Criticality**: A Keeper quorum loss **simultaneously halts** cache replication, S3Queue processing, and zero-copy GC. This makes Keeper the highest-criticality component in the deployment. See [Section 8.5](#85-keeper-as-a-multi-subsystem-dependency).

**Placement**: Keeper pods must run on dedicated Kubernetes nodes with reserved CPU/memory. Pod anti-affinity must be enforced to spread Keeper across distinct nodes and, where possible, distinct availability zones.

**Quorum sizing** (see [Open Decision #4](#9-open-decisions)):
- 3 nodes: tolerates 1 node failure
- 5 nodes: tolerates 2 node failures (recommended for production)

### 3.2 Ingest Cluster (2 pods)

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

### 3.3 Cache Cluster (14 pods)

The cache cluster is the **primary persistent storage and query tier**.

**Topology**: 7 shards × 2 replicas = 14 pods.

**Table engine**: `ReplicatedReplacingMergeTree(ver)` with `allow_remote_fs_zero_copy_replication = 1`.

**Deduplication**: `ReplicatedReplacingMergeTree` deduplicates rows with the same primary key, keeping the row with the highest value of the `ver` column. The specific column to use as `ver` is TBD — see [Open Decision #6](#9-open-decisions).

> **Note**: deduplication happens at **merge time**, not at INSERT time. Duplicate rows are transiently visible between insert and the next background merge. Transient duplicates are acceptable per [Section 1.6](#16-design-assumptions) — `SELECT ... FINAL` is not required and should be avoided.

**Partition key**: `PARTITION BY toYYYYMMDD(event_date)` (daily partitions). Daily partitions are also the primary lever for compliance delete performance — see [Section 8.3](#83-compliance-mutations-with-zero-copy-replication).

**Storage**: Local NVMe/SSD write-through cache backed by S3 — see [Section 5](#5-storage-design).

**Query interface**: A `Distributed` table (`cache_distributed`) spans all 7 shards. Clients may query any cache node; the node fans out to the appropriate shards and aggregates results.

**Replica placement**: The 2 replicas of each shard must land on different Kubernetes nodes (pod anti-affinity required). Spreading across availability zones is recommended.

### 3.4 S3 Storage Backend

All persistent data is stored in S3-compatible storage. Two candidates are under evaluation: **MinIO** and **NetApp**. The team must select one before YAML authoring begins (see [Open Decision #1](#9-open-decisions)).

**Bucket layout**: Single bucket with per-shard prefix:
```
s3://bucket/clickhouse/cache/shard-1/
s3://bucket/clickhouse/cache/shard-2/
...
s3://bucket/clickhouse/cache/shard-7/
```

Both replicas of a shard intentionally write to the same shard prefix. This is required for zero-copy replication: Replica B does not copy data from Replica A — it reads the S3 parts that A already wrote and registers them as its own, coordinating ownership via Keeper.

**Consistency requirement**: Strong read-after-write consistency is required. Both options below satisfy this requirement at the versions specified in [Section 10](#10-recommended-versions).

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

## 4. Data Flow

### 4.1 Kafka Ingest Path

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

Each cache shard receives rows from both ingest nodes. Rows are distributed by `xxHash64(sharding_column)` — deterministic hashing is confirmed as the mechanism. The specific column(s) to use as the sharding key are TBD (see [Open Decision #7](#9-open-decisions)).

**Kafka partition count**: At ~28,935 rows/sec per ingest shard, the Kafka topic must have enough partitions to sustain this throughput. Partition count must be a multiple of 2 so each ingest shard gets an equal partition group. Finalize during PoC (see [Open Decision #10](#9-open-decisions)).

### 4.2 S3Queue Ingest Path

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

### 4.3 Query Path

**Chosen mechanism**: Kubernetes Service load balancing (see [Section 4.4](#44-query-routing-k8s-service-vs-chproxy) for the comparison that led to this decision).

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

### 4.4 Query Routing: K8s Service vs chproxy

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

chproxy is widely used in production ClickHouse deployments and remains the recommended escalation path if the K8s Service approach hits connection-count or routing limitations.

### 4.5 Dedicated Query Cluster: Evaluated, Deferred

**Decision**: Not adopted at this time. Deferred pending PoC evidence. This section documents the evaluation for the record.

#### What the option is

A third cluster — "query" — consisting of 3 compute-only nodes with no replicas. Each node runs only a `Distributed` table targeting the cache cluster. Clients query these nodes instead of cache nodes directly. The query nodes have no local data; they act as dedicated fan-out coordinators and aggregation engines.

#### What it actually does

A query node receives a client query, fans it out to all 7 cache shards via the Distributed table, collects partial results from each shard over the network, and merges them locally. Cache nodes still perform all data scanning and S3/NVMe I/O. The query node handles only coordination and final aggregation.

#### Advantages

**Compute isolation (most significant benefit)**: Cache nodes carry concurrent background load:
- S3 write-through on every INSERT at ~57,870 rows/sec (see [Section 1.2](#12-ingest-requirements))
- Background deduplication merges on 500M–1B duplicate rows/day
- Zero-copy replication coordination with Keeper
- NVMe cache management

Complex queries requiring large in-memory aggregations compete with merge thread pools for CPU and RAM on cache nodes. Dedicated query nodes remove this contention entirely.

**Independent horizontal scaling**: Query capacity (concurrency, aggregation RAM) scales independently from storage capacity (shard count, NVMe sizing). A 4th query node can be added without touching the cache cluster.

**Hardware specialization**: Query nodes can be provisioned as memory/CPU-heavy without NVMe. Cache nodes can optimize for I/O.

**Cleaner connection management**: Clients connect to 3 nodes instead of any of 14.

#### Disadvantages

**No local data — all 7 shards require network hops**: When a client hits a cache node that also holds shard N data, shard N is scanned locally with no inter-pod network cost (1/7 of data). A query node sends all 7 partial queries over the network, adding inter-pod round-trips for every query.

**Added complexity (most significant cost)**: A third cluster in the CHI means additional Kubernetes manifests, more upgrade surface, extended PoC validation scope, and additional monitoring surfaces.

**Weaker HA for query coordination**: Three nodes, no replicas. Any single failure reduces query capacity by 33%. Compare with the current approach where any of 14 cache pods can act as coordinator — losing one has negligible impact.

**Aggregation bottleneck risk**: Under high concurrency, each query node simultaneously aggregates 7 partial result streams per query. If the workload involves many concurrent queries with large intermediate result sets, query nodes become the CPU/RAM bottleneck while cache nodes remain underutilized on the compute side.

**Premature optimization risk**: ClickHouse's scheduler separates background merge threads (`background_pool_size`) from foreground query threads. Without PoC evidence of actual contention, the query cluster adds complexity to solve a problem that may not exist at this workload profile.

#### Option comparison

| Dimension | Current (query via cache nodes) | With query cluster |
|---|---|---|
| Local data advantage | 1/7 of data local to coordinator | None — all network |
| Merge/query isolation | Shared CPU/RAM on cache nodes | Fully isolated |
| Hardware flexibility | One node profile for all | Specialized per role |
| Horizontal query scaling | Implicit (more cache nodes) | Explicit (query nodes) |
| Operator/YAML complexity | Two clusters in CHI | Three clusters in CHI |
| Pod count | 19–21 | +3 = 22–24 |
| HA for query coordination | 14 possible coordinators | 3 nodes, no replicas |

#### Decision rationale

The Phase 2 PoC (see [Section 11](#11-implementation-roadmap)) must measure sustained throughput at ~29k rows/sec with concurrent merge load. **Extend that PoC run with query-side resource profiling**: measure CPU and memory headroom on cache nodes during representative concurrent queries while the background merge pool is active. If the PoC demonstrates measurable contention — growing merge queue depth, query latency spikes, or cache node memory saturation — the query cluster is the correct architectural response.

If the PoC shows cache nodes handle both workloads within acceptable resource margins, the query cluster adds complexity with no measured gain. Introduce it when evidence of a real bottleneck exists, not before.

---

## 5. Storage Design

### 5.1 Disk Hierarchy (Cache Cluster)

Each cache pod has a three-layer disk hierarchy:

```
cache disk  (type: cache)
  ├── local path: /var/lib/clickhouse/s3_cache/  [NVMe PVC]
  └── wraps: s3 disk  (type: s3)
                └──► s3://bucket/clickhouse/cache/shard-{N}/
```

The `cache` disk type is a ClickHouse-native write-through cache layer. On INSERT, data is written simultaneously to the local NVMe path and the S3 backend. On read, the local NVMe copy is used if present; otherwise the S3 part is fetched and cached locally.

### 5.2 Key Storage Settings

| Setting | Value | Notes |
|---|---|---|
| `cache_on_write_operations` | `1` | Write-through: INSERTs populate the NVMe cache |
| `max_size` | TBD | Size of the NVMe PVC — see [Open Decision #8](#9-open-decisions) |
| `allow_remote_fs_zero_copy_replication` | `1` | Set in MergeTree settings block; enables zero-copy between replicas |
| `kafka_max_block_size` | `1048576` | Rows per KafkaEngine MV fire. At ~29k rows/sec per shard, a 1M-row batch completes in ~35 sec — large parts, manageable frequency; prevents "too many parts" |
| `background_pool_size` | TBD (≥8 recommended) | Background merge threads per server. Must handle deduplication merge pressure at 5B rows/day + 10–20% duplicate rate |

### 5.3 Cache Eviction Strategy

ClickHouse cache disk uses **LRU (Least Recently Used) eviction** by default. Combined with `cache_on_write_operations = 1`, this produces the following recency profile:

- **Newest data is always resident**: every INSERT writes through to NVMe immediately. The most recently ingested partitions are always cache-warm.
- **Actively queried older data stays warm**: LRU retains parts that are being read regularly.
- **Eviction triggers only at `max_size`**: when the NVMe PVC approaches its configured limit, the least-recently-used parts are evicted. Evicted data is still readable — ClickHouse transparently fetches from S3 on a cache miss, then re-populates the local cache.

**Sizing guidance**: Target the NVMe cache at the active working set. A starting point of 20–30% of total dataset size is reasonable; tune upward based on observed cache hit rate. See [Open Decision #8](#9-open-decisions) for the sizing inputs required.

**Key monitoring query**:
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

A hit rate below ~90% on hot queries indicates the NVMe cache is undersized for the active working set.

### 5.4 S3 Disk Type Selection

Use the standard `s3` disk type. Do **not** use `s3_plain`.

`s3_plain` produces an immutable flat-path layout that is incompatible with `ReplicatedMergeTree`: merges write new parts at new S3 paths, which `s3_plain` cannot manage. See [Section 8.2](#82-s3_plain-incompatibility) for details.

### 5.5 Ingest Cluster Storage

The ingest cluster uses the **default storage policy** (local disk only). No S3 disk and no cache disk are configured on ingest nodes. All ingest data is immediately forwarded to the cache cluster; nothing is retained locally.

---

## 6. Replication and High Availability

### 6.1 Cache Cluster Replication

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
| Ingest node failure | Kafka: offsets hold; messages reprocessed on restart. S3Queue: Keeper releases unclaimed files | Pod restart |

### 6.2 Keeper HA

- Minimum 3 nodes for any cluster (quorum = 2).
- Recommended 5 nodes for production (quorum = 3; tolerates 2 failures) — see [Open Decision #4](#9-open-decisions).
- Must run on dedicated Kubernetes nodes to avoid resource contention with ClickHouse workloads.
- Pod anti-affinity must prevent any two Keeper pods from sharing a node.

### 6.3 S3 HA

S3 availability directly governs INSERT availability (write-through per [Section 1.3](#13-query-requirements)). S3 HA must be designed and validated before this architecture can claim full HA. Requirements differ by backend:

**MinIO** (if selected):
- Must run in distributed erasure-coded mode across a minimum of 4 nodes.
- Recommended configuration: ≥4 nodes with EC:2 or EC:4 depending on drive count and desired fault tolerance.
- Single-node or single-drive MinIO is not acceptable for production.
- See [Open Decision #2](#9-open-decisions) for MinIO node/drive count.

**NetApp** (if selected):
- Verify that the specific product (ONTAP S3, StorageGRID, etc.) is configured with hardware-level redundancy (RAID, HA controller pairs).
- Confirm erasure-coding settings with the storage team before PoC.
- Confirm that the product version provides strong read-after-write consistency on the S3 API path used by ClickHouse.

**Common requirement for both**: The S3 endpoint must be reachable from all 14 cache pods and both ingest pods on the ports configured in the storage policy. Validate K8s NetworkPolicy allows this traffic.

---

## 7. Cross-Cluster Write Architecture

### 7.1 Single CHI and Auto-Generated Remote Servers

Both the ingest cluster and the cache cluster are defined in **one `ClickHouseInstallation` (CHI)**. The Altinity ClickHouse Operator automatically generates the `remote_servers` configuration for all clusters defined within a CHI and distributes it to every pod in that CHI.

This means ingest nodes automatically know the full shard/replica topology of the cache cluster — **no manual `remote_servers` XML is needed**. This is the recommended and correct approach.

> **Verify in PoC**: Confirm that the target Altinity operator version (0.26.0+) generates cross-cluster `remote_servers` for a multi-cluster CHI before beginning YAML authoring.

### 7.2 Write Path: Kafka to Cache

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

### 7.3 Authentication and Network Policy

The Altinity operator sets `interserver_secret` automatically for all pods within the same CHI. Cross-cluster INSERTs from ingest pods to cache pods are authenticated without manual credential management.

**Required Kubernetes NetworkPolicy**: ingest pods must be permitted to reach cache pods on:
- Port **9000** (native TCP, used by Distributed table inserts)
- Port **9009** (interserver HTTP, used for replication)

Keeper pods must be reachable from all cache and ingest pods on:
- Port **2181** (Keeper client port)
- Port **2888** / **3888** (Keeper internal cluster ports)

### 7.4 Credential Management via HashiCorp Vault

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

Advantage: simpler pod manifest; standard K8s Secret mount pattern.

Disadvantage: credentials exist briefly as Kubernetes Secret objects in etcd. Requires RBAC controls on Secret access.

#### Secret Rotation Procedure

ClickHouse does not hot-reload S3 credentials automatically when the underlying file changes. To rotate S3 credentials without downtime:

1. Update the secret in Vault.
2. Vault Agent (if running as a sidecar, not init-only) re-renders the config file on the next renewal cycle.
3. Send SIGHUP to the `clickhouse-server` process: `kill -HUP $(pidof clickhouse-server)`. ClickHouse reloads XML config files on SIGHUP without restarting.
4. Verify: query `SELECT * FROM system.disks` and confirm no S3 errors appear in `system.text_log`.

Plan a rotation procedure and test it in staging before the first production credential rotation.

---

## 8. Risks and Limitations

### 8.1 SharedMergeTree Not Available in Open-Source ClickHouse

`SharedMergeTree` is available **only in ClickHouse Cloud**. Any documentation, blog post, or tooling suggesting `SharedMergeTree` for a self-hosted deployment is incorrect. Attempting to use it on an open-source ClickHouse binary produces:

```
Code: 60. DB::Exception: Unknown table engine 'SharedMergeTree'
```

The correct engine for this architecture is `ReplicatedMergeTree` with `allow_remote_fs_zero_copy_replication = 1`.

> **Action required**: The implementation team must explicitly review and acknowledge this warning before YAML authoring begins.

> **Critical**: `allow_remote_fs_zero_copy_replication = 1` has a documented history of data loss bugs in production. Read [Section 8.7](#87-zero-copy-replication-production-stability) before proceeding. The decision to use zero-copy replication vs. full replication (doubled S3 cost, no GC race risk) must be made explicitly — see [Open Decision #12](#9-open-decisions).

### 8.2 s3_plain Incompatibility

`s3_plain` uses an immutable flat path layout. `ReplicatedMergeTree` merges write new data parts to new S3 paths. `s3_plain` cannot handle path mutations required by merges. **Always use the standard `s3` disk type** (see [Section 5.4](#54-s3-disk-type-selection)).

### 8.3 Compliance Mutations with Zero-Copy Replication

Nightly compliance DELETE and UPDATE operations are a confirmed hard requirement (see [Section 1.4](#14-compliance-requirements)). This section documents how both lightweight mutation mechanisms interact with zero-copy replication, the physical deletion timing risk, and the recommended compliance path.

#### General Zero-Copy Caveats

| Risk | Detail | Mitigation |
|---|---|---|
| Version requirement | Zero-copy had correctness bugs before 23.x | Deployment targets ClickHouse 26.x LTS (see [Section 10](#10-recommended-versions)); 26.x is well past the stability threshold |
| GC accumulation | Pre-merge S3 parts are GC'd only after all replicas acknowledge the merged part in Keeper. Extended replica downtime causes S3 storage growth | Monitor S3 object count and size; set replica downtime SLA |
| S3 write amplification from merges | Frequent small merges generate many S3 PUT operations | Tune `min_bytes_for_wide_part`, `merge_max_block_size`, and merge selector settings |

#### Lightweight UPDATE (Patch Parts, CH 24.3+)

Patch parts write a small overlay S3 object that stores the updated column values for affected rows. The original data part on S3 is unchanged; the patch is applied at read time.

- **Zero-copy interaction**: the patch overlay is a new small S3 object, replicated to both replicas via Keeper coordination. The original part is not rewritten.
- **S3 write amplification**: low — only the changed columns are written, not the full part.
- **Production track record**: patch parts alongside zero-copy replication are relatively new (CH 24.3+). **Must be validated in the PoC before relying on them for nightly compliance updates.**

#### Lightweight DELETE (CH 23.3+)

Lightweight DELETE writes a deletion bitmap alongside the data part. Deleted rows are filtered at query execution time and are logically invisible immediately after the DELETE completes.

**Critical gap**: the physical S3 bytes for deleted rows are NOT removed until the data part participates in a merge. Until then, a client with direct S3 access can still read the raw part files.

#### TTL-Based Expiration (`eviction_date`)

The recommended DDL pattern for time-based expiry:

```sql
TTL eviction_date DELETE
SETTINGS TTL_only_drop_parts = 1
```

**How `TTL_only_drop_parts = 1` works**: when every row in a data part has an expired TTL, ClickHouse drops the entire part without performing a merge rewrite. This is equivalent to `DROP PARTITION` behavior — **instant physical deletion** of S3 objects for that part.

**24-hour SLA satisfaction**: `PARTITION BY toYYYYMMDD(event_date)` with `TTL_only_drop_parts = 1` drops fully-expired parts within the TTL check interval (default: every 60 seconds). The 24-hour SLA for time-based expiry is trivially satisfied with daily partitions. No manual intervention required.

#### User-ID Compliance Deletes (Confirmed Required, High Risk at Scale)

User-ID compliance deletes (`DELETE FROM cache_table WHERE user_id = X`) are a confirmed requirement. A given user's rows are distributed across all time partitions — this is non-partition-aligned and row-level delete is unavoidable.

```sql
-- Step 1: logical deletion (immediate, but not physical)
DELETE FROM cache_table WHERE user_id = 12345;

-- Step 2: force physical removal by triggering a merge on every affected partition
OPTIMIZE TABLE cache_table PARTITION '2024-01-01' FINAL;
OPTIMIZE TABLE cache_table PARTITION '2024-01-02' FINAL;
-- ... repeat for every partition that contained matching rows
```

`OPTIMIZE TABLE PARTITION FINAL` rewrites all data parts in a partition into a single merged part, physically removing the deleted rows from S3 in the process.

**Severity at 5B rows/day scale**: This is a high-risk operation requiring explicit planning. Risk level is conditional on nightly batch volume (see below).

- At ~714M rows/shard/day, each daily partition on each shard holds hundreds of millions of rows. `OPTIMIZE TABLE PARTITION FINAL` reads all S3 parts for that partition, rewrites them into one merged part, and writes the result back — a multi-GB+ S3 I/O operation per partition.
- In practice, a user's activity is typically weighted toward recent partitions. A realistic assumption is **~30 affected partitions per user delete** (compared to the theoretical maximum of 365 for a full year of retention). At 30 partitions × 7 shards = **210 `OPTIMIZE TABLE PARTITION FINAL` calls per user** — a 92% reduction from the worst-case 2,555. The 365-partition / 2,555-call figure remains valid as the theoretical maximum (full 12-month retention with data in every daily partition) but is not the expected operational case.
- Zero-copy compatibility: `OPTIMIZE TABLE FINAL` creates new merged parts on S3; Keeper coordinates GC of old parts. Allow additional time (typically minutes) for GC to physically remove S3 objects. This lag counts against the 24-hour SLA.

**Recency bias analysis — benefits and complications**:

*Benefits*:
1. **NVMe cache warmth for reads**: write-through (`cache_on_write_operations = 1`) guarantees recent partitions are always NVMe-resident. The read phase of `OPTIMIZE TABLE FINAL` on recent partitions reads from local NVMe (~1–3 GB/s) rather than S3 (~100–500 MB/s) — 3–30× faster reads.
2. **Old partitions are already heavily merged**: background merges have had more time to consolidate older partitions, resulting in fewer parts per partition and less merge work per `OPTIMIZE FINAL` call on older partitions.

*Complications*:
1. **Recent partitions have more un-merged small parts**: KafkaEngine fires at `kafka_max_block_size = 1M` rows. At ~29k rows/sec per ingest shard, a 1M-row batch arrives every ~35 sec. Recent partitions accumulate many small parts before background merges consolidate them — `OPTIMIZE FINAL` on a recent partition involves more individual merge steps and more S3 PUT operations.
2. **NVMe cache eviction pressure**: `OPTIMIZE FINAL` on warm recent partitions writes the large new merged part back through the NVMe cache (write-through). The merged part can occupy significant NVMe space, potentially evicting other recently-cached parts under LRU pressure and causing temporary cache miss spikes for concurrent queries.
3. **S3 writes are always on the critical path**: NVMe warmth accelerates only the read phase. The output write is always write-through (NVMe + S3), and S3 write throughput remains the bottleneck regardless of cache state.

**Per-shard wall-clock estimate** (30 partitions per shard, executed sequentially):

| Partition state | Read source | Estimated per call | 30-call total |
|---|---|---|---|
| NVMe-warm (recent, ~20/30 partitions) | Local NVMe at 1–3 GB/s | 1–6 min | — |
| Cold (older, ~10/30 partitions) | S3 at 100–500 MB/s | 2–10 min | — |
| **Combined per-shard total** | | | **~30 min – 8 hours** |

All 7 shards execute in parallel → wall-clock equals per-shard time (assuming adequate `background_pool_size`).

**Multi-user nightly batch — the binding risk variable**:

`OPTIMIZE TABLE PARTITION FINAL` calls for different users operating on the same partition must be serialized (same `background_pool_size`; same partition is rewritten). Per-user wall-clock does not parallelize across users sharing the same partitions.

| Users per nightly batch | Estimated wall-clock (midrange, per shard) | 24-hour SLA |
|---|---|---|
| 1 | ~2–3 hours | Comfortably feasible |
| 3–5 | ~6–15 hours | Feasible with scheduling |
| 10 | ~20–30 hours | Borderline / infeasible |
| 20+ | >24 hours | Infeasible without optimization |

**Feasibility assessment**: The 24-hour SLA is feasible for small nightly batches (1–5 users). It becomes infeasible if the nightly batch consistently exceeds ~10 users without scheduling or optimization. The **number of users per nightly batch** is the primary new risk variable and must be quantified before this path can be fully validated. See [Open Decision #11](#9-open-decisions).

**Hard architectural note**: `PARTITION BY toYYYYMMDD(event_date)` (daily) is the primary mitigation lever: each `OPTIMIZE TABLE PARTITION FINAL` call operates on a single day's data per shard, limiting the rows per partition that must be rewritten. The PoC must measure actual elapsed time and S3 I/O per partition — and must test representative multi-user batch runs — to determine whether the 24-hour SLA is achievable (primary input for [Open Decision #11](#9-open-decisions)).

#### PoC Validation Requirements

1. Execute a representative nightly DELETE on a partition sized to production data volumes.
2. Measure the time from DELETE issuance to physical S3 object removal (OPTIMIZE TABLE FINAL + GC).
3. Test with 30 representative partitions (weighted toward recent, ~20 warm / ~10 cold); measure per-user wall-clock.
4. Also run 3-user and 10-user batch scenarios to characterize multi-user serialization scaling.
5. Confirm the 24-hour SLA is achievable under production load conditions.

### 8.4 KafkaEngine At-Least-Once Delivery

KafkaEngine commits the Kafka offset after the Materialized View fires, but the downstream `Distributed` INSERT to the cache cluster can still fail after the offset is committed. This creates a window for data loss (offset advanced, INSERT not persisted).

**Resolution**: `ReplicatedReplacingMergeTree` makes duplicate delivery idempotent — if KafkaEngine re-delivers a message after a failed INSERT, the duplicate row is deduplicated at the next background merge. Transient duplicates until merge are acceptable per [Section 1.6](#16-design-assumptions).

**Additional safety options**:
- Set `kafka_commit_every_batch = 0` to further reduce the loss window
- Configure a dead-letter Kafka topic to capture failed INSERTs for alerting

### 8.5 Keeper as a Multi-Subsystem Dependency

Keeper quorum loss simultaneously halts:
1. Cache replication (no new parts acknowledged)
2. S3Queue file processing (no new file claims)
3. Zero-copy GC (old S3 parts accumulate)
4. New INSERTs to ReplicatedMergeTree tables (blocked until quorum restored)

**Mitigation**: Run 5 Keeper nodes for production. Dedicate Kubernetes nodes exclusively to Keeper. Do not co-locate Keeper with ClickHouse server pods.

### 8.6 S3 Availability Equals INSERT Availability

Write-through caching means S3 is in the critical write path. If S3 becomes unreachable:
- INSERTs fail immediately
- Reads from the local NVMe cache continue for data already cached
- No write buffering at the ClickHouse layer

**Mitigation**: S3 HA (MinIO erasure coding or NetApp redundancy) must be operational before this architecture can claim production HA. Design and validate S3 HA independently before deploying ClickHouse.

### 8.7 Zero-Copy Replication Production Stability

**Rating: Critical**

`allow_remote_fs_zero_copy_replication = 1` has a documented history of data loss bugs in production deployments. This is the single highest-risk configuration choice in this architecture and must be explicitly treated as such before any YAML authoring begins. See [Open Decision #12](#9-open-decisions).

#### The Core Problem: GC Race Conditions

Zero-copy replication eliminates inter-replica S3 data transfer by having both replicas reference the same S3 objects. When a merge completes:

1. The merging replica writes the new merged part to S3 and registers it in Keeper.
2. The other replica acknowledges the new part via Keeper and updates its local metadata.
3. The original S3 parts are now candidates for garbage collection.
4. Keeper-coordinated lock checks determine whether it is safe to delete the old S3 objects.

**The race**: the lock check and S3 DELETE are not atomic. Under production load — concurrent merges, high Keeper write pressure, or Keeper leader elections — the sequence can interleave incorrectly:

- A lock check returns "safe to delete" before the other replica has finished acquiring its read lock on the old parts.
- The old S3 objects are deleted.
- The other replica attempts to read the now-missing S3 objects → the part is broken → **data is permanently lost**.

This failure mode requires no misconfiguration. It is a timing-sensitive race in the GC coordination protocol that is triggered by normal production workload conditions.

#### ClickHouse Inc.'s Own Signal

ClickHouse Cloud does not use zero-copy replication. ClickHouse Inc. built **SharedMergeTree** specifically to replace it — a fundamentally different design where S3 object metadata is managed by a dedicated metadata service, removing GC coordination from the ClickHouse server entirely. ClickHouse Inc. would not have invested in an entirely new storage engine if zero-copy replication were reliable at production scale.

> Open-source ClickHouse does not include SharedMergeTree (see [Section 8.1](#81-sharedmergetree-not-available-in-open-source-clickhouse)) — this architecture cannot use it. But the signal is unambiguous: the team that maintains ClickHouse does not trust zero-copy replication for their own production product.

#### Keeper znode Accumulation

Zero-copy replication creates a Keeper znode for every S3 part reference — both live parts and GC candidates. At the ingest rates in this architecture (`kafka_max_block_size = 1M` rows at ~57,870 rows/sec → multiple new parts per second across the cluster before background merges consolidate them), the Keeper znode tree for zero-copy locks grows rapidly. Interrupted merges, Keeper leader elections, and partial GC runs all leave stale znodes behind.

These accumulate over time, increasing Keeper memory usage and degrading znode traversal latency for all Keeper clients (replication, S3Queue, GC). ClickHouse provides no automated cleanup for stale zero-copy lock znodes. Periodic manual cleanup is required in production, and there is no safe, zero-downtime procedure for running it under live load.

This compounds [Section 8.5](#85-keeper-as-a-multi-subsystem-dependency): Keeper is already a single point of failure for replication, S3Queue, and GC. Zero-copy replication adds unbounded znode growth as a fourth failure mode against the same ensemble.

#### Interaction with Compliance Deletes

`OPTIMIZE TABLE PARTITION FINAL` — the mechanism this architecture relies on for physical user-ID deletion — is the highest-exposure operation under zero-copy replication. It:

1. Reads all parts in a partition → writes one new merged part to S3.
2. Registers the new merged part via Keeper.
3. Initiates GC of **all** original parts simultaneously.

Step 3 is maximum-exposure for GC races: every part in the partition is simultaneously a GC candidate. At production partition sizes (~143 GB compressed / shard / day), a race here results in loss of an entire partition's worth of data, not a single small part. This is the same operation executed 210 times per user during a nightly compliance delete (see [Section 8.3](#83-compliance-mutations-with-zero-copy-replication)).

#### NVMe Cache Masking

The NVMe write-through cache (`cache_on_write_operations = 1`) introduces a secondary failure mode: if S3 objects are erroneously GC'd while valid NVMe cache entries for those objects still exist, queries will continue to return results from the NVMe cache — **masking the data loss**. The data appears intact until the NVMe cache entry is evicted, at which point the S3 fetch fails. This can delay detection by hours and complicates any post-incident recovery.

#### The Alternative: Full Replication

Disabling zero-copy (`allow_remote_fs_zero_copy_replication = 0`) restores standard ClickHouse replication: each replica independently writes and owns its S3 data. There are no GC race conditions. Replication lag recovery is handled by ClickHouse's established fetcher mechanism, which is battle-tested across a large number of production deployments.

| | Zero-copy (`= 1`) | Full replication (`= 0`) |
|---|---|---|
| S3 storage per shard | 1× (shared between replicas) | 2× (one copy per replica) |
| Inter-replica network transfer on lag | None | Fetcher copies missing parts |
| GC race condition risk | Present; documented data loss incidents | None |
| Data loss surface area | Merges, mutations, OPTIMIZE FINAL, GC | None beyond standard CH replication bugs |
| Production track record | Multiple known incidents; ClickHouse Inc. abandoned it | Well-understood; widely deployed at scale |
| Keeper znode growth | Unbounded; requires manual cleanup | No additional znode overhead |

**Cost implication**: Full replication doubles S3 storage for the cache cluster. At 7 shards, the shared zero-copy prefix becomes 7 independent per-replica prefixes with 2× the data. This is the primary trade-off and must be budgeted before a decision is made.

#### Conditions for Retaining Zero-Copy

If storage cost makes full replication infeasible, zero-copy may be retained only under all of the following conditions:

1. **Extended PoC validation**: run a ≥72-hour merge-heavy workload with `allow_remote_fs_zero_copy_replication = 1`, including repeated `OPTIMIZE TABLE PARTITION FINAL` operations. Continuously monitor S3 object counts against Keeper-registered part counts for divergence (missing objects = data loss). Any divergence fails the PoC.
2. **Keeper znode monitoring**: instrument an alert on the zero-copy lock znode count under `clickhouse/zero_copy_locks/` in Keeper. Alert before Keeper memory saturation.
3. **GC health check**: a scheduled script must cross-reference S3 objects against `system.parts` on all replicas, flagging orphaned S3 objects and missing-but-registered parts. Must run at least daily.
4. **Migration runbook**: document the procedure for switching from zero-copy to full replication under live traffic (config change → allow replicas to fetch missing parts → verify parity) before going to production.

---

## 9. Open Decisions

The following decisions must be resolved before YAML authoring begins. Each blocks one or more manifests or DDL files.

### Infrastructure Decisions

| # | Decision | Blocks |
|---|---|---|
| 1 | **S3 backend selection**: MinIO or NetApp. See comparison in [Section 3.4](#34-s3-storage-backend) and [Section 6.3](#63-s3-ha). | Storage policy YAML, S3 credentials |
| 2 | **MinIO HA configuration** *(if MinIO selected)*: distributed/erasure-coded mode — how many MinIO nodes and drives? EC:2 or EC:4? | S3 HA validation |
| 3 | **Keeper deployment method**: `ClickHouseKeeperInstallation` CRD or standalone StatefulSet? Confirm supported method for the target Altinity operator version. | Keeper YAML |
| 4 | **Keeper node count**: 3 (tolerates 1 failure) or 5 (tolerates 2 failures, recommended for production)? | Keeper YAML, node reservation |
| 5 | **Kubernetes namespace strategy**: one `ClickHouseInstallation` per environment (dev/staging/prod), or one CHI across all environments? | CHI YAML structure |
| 12 | **Zero-copy vs full replication**: use `allow_remote_fs_zero_copy_replication = 1` (1× S3 storage per shard; documented data loss risk; requires ≥72h PoC validation — see [Section 8.7](#87-zero-copy-replication-production-stability)) or `= 0` (2× S3 storage per shard; no GC race risk; standard replication semantics)? **This is an architectural decision, not a configuration detail — it must be made explicitly and before YAML authoring begins.** | Storage policy YAML, cache cluster DDL, S3 cost budget |

### Table and Schema Decisions

| # | Decision | Blocks |
|---|---|---|
| 6 | **`ver` column** for `ReplicatedReplacingMergeTree(ver)`: which column serves as the deduplication version key? Event timestamp in ms (`UInt64`) is recommended; specific column TBD. | Cache cluster DDL |
| 7 | **Sharding key column** for `xxHash64(sharding_column)`: which column(s) determine shard assignment? | Distributed table DDL |

### Capacity and Sizing Decisions

| # | Decision | Blocks |
|---|---|---|
| 8 | **Cache disk sizing**: target data volume per shard; required hot-data percentage; row size. All three inputs are needed to size NVMe PVCs. Starting point: 20–30% of dataset (see [Section 5.3](#53-cache-eviction-strategy)). | PVC sizing, storage class selection |
| 9 | **S3 bucket and prefix naming**: finalize bucket name and prefix scheme before any deployment. Renaming after data exists requires a full data migration. | Storage policy YAML |

### Kafka Integration

| # | Decision | Blocks |
|---|---|---|
| 10 | **Kafka topic partition count and assignment**: how many partitions per topic? Partition count must be a multiple of 2 for equal shard assignment. Finalize based on broker throughput and message size — validate in PoC. | KafkaEngine DDL |

### Compliance

| # | Decision | Blocks |
|---|---|---|
| 11 | **User-ID compliance SLA — physical vs logical deletion**: for `DELETE WHERE user_id = X`, does the 24-hour SLA require **physical S3 byte removal** or is **logical inaccessibility** (deletion bitmap applied; rows invisible to all queries) sufficient? Under the revised ~30-partition-per-user assumption, physical removal requires **210 `OPTIMIZE TABLE FINAL` calls per user** (down from the 365-partition worst-case of 2,555). The 24-hour SLA is **feasible for small nightly batches (1–5 users)** but becomes infeasible if the batch consistently exceeds ~10 users (see [Section 8.3](#83-compliance-mutations-with-zero-copy-replication)). **Two required inputs**: (1) physical vs logical SLA — legal/compliance determination required; (2) typical number of users per nightly deletion batch — product/ops team must provide. **Both answers are required before DDL is finalized.** | Cache cluster DDL, `PARTITION BY` design, compliance SLA validation |

---

## 10. Recommended Versions

| Component | Recommended | Minimum | Notes |
|---|---|---|---|
| ClickHouse Server | **26.x LTS** | 24.8 | Deployment targets 26.x LTS. Zero-copy replication is stable from 23.8; 26.x is well past all known correctness issues. Always use an LTS release for production. |
| Altinity Operator | **0.26.0+** | — | Validate compatibility with ClickHouse 26.x and `ClickHouseKeeperInstallation` CRD support; validate cross-cluster `remote_servers` auto-generation in PoC. |
| ClickHouse Keeper | Same as CH Server | — | Keeper is bundled with ClickHouse. Keeper and CH server versions must match exactly. |
| MinIO (if selected) | **Latest available release** | 2021-09-23 | Strong read-after-write consistency was introduced in the 2021-09-23 release. Earlier versions are incompatible with zero-copy replication. |

---

## 11. Implementation Roadmap

YAML authoring begins only after all [Open Decisions](#9-open-decisions) are resolved and the following prerequisites are confirmed:

- The SharedMergeTree warning ([Section 8.1](#81-sharedmergetree-not-available-in-open-source-clickhouse)) has been explicitly reviewed and acknowledged by the implementation team.
- Cross-cluster `remote_servers` auto-generation has been validated against the target Altinity operator version (0.26.0+) in the PoC.
- Zero-copy replication has been verified correct on the target ClickHouse version and S3 backend before scaling to 14 pods.

### Phase 1 — Keeper

Deploy ClickHouse Keeper (StatefulSet or CRD). Validate quorum health before proceeding. All subsequent components depend on Keeper.

### Phase 2 — Cache Cluster PoC (1 shard × 2 replicas)

Deploy a single cache shard with zero-copy replication enabled. Validate:
- Data written to Replica 0 appears on Replica 1 without data transfer between pods
- S3 parts appear under the correct shard prefix
- NVMe cache is populated on write (`cache_on_write_operations = 1`)
- Cache miss triggers S3 read and local cache population

**Throughput validation**:
- Drive sustained ingest at ~29,000 rows/sec per shard; confirm no "too many parts" errors with `kafka_max_block_size = 1048576`
- Monitor `system.merges` for merge queue depth under sustained load; tune `background_pool_size` as needed

**Mutation and compliance validation**:
- **TTL path**: create a table with `TTL eviction_date DELETE SETTINGS TTL_only_drop_parts = 1`; populate with data where all rows in a part have expired TTL; confirm the part is dropped within the TTL check interval (≤60 sec) and S3 objects are physically removed; verify no rewrite merge is triggered
- **Compliance delete load test**: execute lightweight DELETE (`DELETE FROM t WHERE user_id = X`) on 30 representative partitions (weighted toward recent, ~20 warm / ~10 cold); run `OPTIMIZE TABLE PARTITION FINAL` sequentially per shard; measure per-user elapsed time and S3 I/O; also run 3-user and 10-user batch scenarios to characterize multi-user serialization; measure time from DELETE issuance to confirmed physical S3 part removal; document all results against the 24-hour SLA — this is the primary input for resolving [Open Decision #11](#9-open-decisions)
- **Patch parts validation** (if nightly compliance updates required): validate `ALTER TABLE t UPDATE` using patch parts with zero-copy enabled; confirm both replicas reflect the update correctly
- Document all measured timings for inclusion in the compliance evidence package

**Query-side profiling** (to evaluate dedicated query cluster per [Section 4.5](#45-dedicated-query-cluster-evaluated-deferred)):
- Run representative concurrent queries while the background merge pool is active
- Measure CPU and memory headroom on cache nodes; record merge queue depth
- Use results to decide whether a dedicated query cluster is warranted before Phase 3

### Phase 3 — Scale Cache Cluster (7 shards × 2 replicas)

Roll out the remaining 6 shards. Validate `cache_distributed` fan-out queries.

### Phase 4 — Ingest Cluster + Cross-Cluster Distributed Table

Deploy both ingest nodes in the same CHI as the cache cluster. Validate that ingest nodes can resolve cache shard addresses from the operator-generated `remote_servers`.

### Phase 5 — KafkaEngine + S3Queue + Materialized Views

Create ingest tables and views. Validate end-to-end: messages from Kafka and files from the S3 source bucket appear in the cache cluster.

### Phase 6 — Distributed Query Table + Client Connectivity

Expose `cache_distributed` to clients via the chosen routing mechanism (K8s Service or chproxy). Run query validation.

---

## 12. Scalability Considerations

This section evaluates the scalability characteristics of each architectural tier against the confirmed workload: ~5B rows/day at ~57,870 rows/sec sustained, 10–20% duplicate rate, 7-shard × 2-replica cache cluster, and 2-shard ingest tier.

### 12.1 Ingest Tier

**Rating: Moderate**

The 2-shard ingest tier is stateless and handles ~28,935 rows/sec per shard comfortably at current load. Scaling to 4 shards requires Kafka topic repartitioning — partition count must remain a multiple of the ingest shard count. This is a coordinated, non-zero-downtime operation: consumer offset assignments are disrupted during repartitioning.

S3Queue scales more smoothly than Kafka: Keeper coordinates file claims per-file, so additional ingest nodes participate in claim coordination without Kafka partition topology constraints.

**Scale-out path**: 2-shard → 4-shard is the logical next step. Plan Kafka repartitioning in advance; validate zero-data-loss handoff in staging before production.

### 12.2 Cache Cluster

**Rating: Strong (vertical) / High Risk (horizontal)**

**Vertical scaling** is the low-risk path: larger NVMe PVCs, more CPU, more RAM per pod. S3 absorbs data growth without pod-level disk pressure. Adding replicas per shard is zero-copy — no data is transferred between CH pods; only Keeper coordination is required.

**Horizontal scaling (resharding) is the critical constraint.** ClickHouse has no automated resharding. Adding an 8th cache shard requires:

1. Deploying the new shard in the CHI.
2. Migrating data from existing shards via `INSERT INTO new_shard SELECT ... FROM old_shard` — a multi-hour, multi-TB S3 read/write operation.
3. Rewriting the Distributed table DDL with the updated topology.
4. Running this concurrently with live ingest at ~57,870 rows/sec.

The 7-shard count must be validated against a capacity projection. At 200 B/row average, 5B rows/day ≈ 1 TB/day raw; per-shard ≈ 143 GB/day. At 90-day retention, each shard holds ~12.9 TB of raw data before compression. NVMe PVC sizing must be derived from these numbers using the sizing formula in [Section 13](#13-configuration-reference).

> **Recommendation**: Establish a resharding runbook before go-live. The absence of a tested procedure when capacity is reached is a higher risk than the resharding operation itself.

### 12.3 ClickHouse Keeper

**Rating: Moderate**

Keeper uses Raft consensus — adding nodes improves fault tolerance but **does not increase write throughput**. Write capacity is fixed by the Raft leader. At 7 shards × 2 replicas, Keeper receives part registration writes from 14 replica paths. With `kafka_max_block_size = 1M` at ~57,870 rows/sec, approximately 1–2 new parts are registered per shard per second. Merge completions and zero-copy GC events add further writes on top.

This is manageable at current scale, but Keeper write pressure must be profiled in PoC Phase 2 before scaling the shard count further.

A deeper structural concern: a single Keeper ensemble serves replication metadata, S3Queue file coordination, and zero-copy GC simultaneously. Each additional subsystem relying on Keeper **increases the blast radius of a quorum loss**. Separate Keeper ensembles per subsystem would limit blast radius, but this is not supported by the current single-CHI design and should be treated as a future architectural option if Keeper becomes a bottleneck.

### 12.4 S3 Storage

**Rating: Strong**

S3 scales horizontally and independently of ClickHouse. Per-shard prefix isolation bounds partition-level operations (TTL drops, `OPTIMIZE PARTITION FINAL`) to a single shard's data. MinIO distributed erasure-coded mode scales by adding drive nodes; NetApp scales per hardware configuration.

**Write amplification** compounds with scale and must be budgeted. Sources:
- Write-through: every INSERT writes to S3 immediately at ~57,870 rows/sec.
- Deduplication merges: 500M–1B duplicate rows/day are rewritten during background merges.
- Compliance `OPTIMIZE TABLE PARTITION FINAL` (see [Section 12.6](#126-compliance-delete-scalability)) adds further S3 rewrites.

Row size (Open Decision #8) is the blocking input for quantifying this amplification. Resolve it before S3 bandwidth and cost budgeting.

**Zero-copy GC lag**: pre-merge S3 parts are not deleted until all replicas acknowledge the merged result in Keeper. Extended replica downtime causes unbounded S3 object accumulation. Monitor S3 object count per shard prefix and enforce a replica downtime SLA.

### 12.5 Query Concurrency

**Rating: Moderate**

Parallel fan-out to 7 shards scales query execution throughput linearly with shard count. With 14 cache pods as potential coordinators, the loss of any single pod has negligible routing impact.

Two concurrency risks exist at higher client load:

**Connection exhaustion**: K8s Service LB has no connection pooling. Each client connection maps directly to a ClickHouse thread plus memory allocation. At high client concurrency (>50 simultaneous connections is a practical threshold to watch), connection overhead accumulates on cache pods. chproxy, which pools connections before forwarding to CH, is the recommended mitigation — see [Section 4.4](#44-query-routing-k8s-service-vs-chproxy).

**Merge/query thread contention**: cache nodes carry concurrent background load — write-through INSERTs at ~57,870 rows/sec and deduplication merges on 500M–1B rows/day. ClickHouse separates background merge threads (`background_pool_size`) from query threads, but they share the same CPU and memory envelope. Under high concurrent analytical query load, contention for RAM is the likely bottleneck. PoC Phase 2 must measure this before scaling to production concurrency levels — see [Section 4.5](#45-dedicated-query-cluster-evaluated-deferred).

**Scale-out path**: (1) Add chproxy when client concurrency approaches connection exhaustion. (2) Add a dedicated query cluster (Section 4.5) when PoC demonstrates measurable merge/query contention. (3) Add cache replicas (zero-copy) to distribute read load.

### 12.6 Compliance Delete Scalability

**Rating: High** (conditional — Critical if nightly batch exceeds ~10 users; see below)

User-ID compliance deletes (`DELETE FROM ... WHERE user_id = X`) are the most significant scalability constraint in the architecture. This is a non-partition-aligned row-level operation, making physical deletion inherently expensive at scale.

**Scale of the problem — revised under recency assumption**:

A user's activity is typically weighted toward recent partitions. The realistic per-user case assumes ~30 affected daily partitions, not 365 for a full year. The 365-partition figure remains the theoretical maximum for a user with data in every daily partition across 12 months.

| Scenario | Partitions | OPTIMIZE calls (× 7 shards) | Uncompressed S3 I/O (read + write) | Compressed (~5× LZ4/ZSTD) |
|---|---|---|---|---|
| Typical (30 partitions) | 30 | **210** | ~60 TB | ~12 TB |
| Worst case (365 partitions, full year) | 365 | **2,555** | ~730 TB | ~146 TB |

**Recency bias — warm/cold timing breakdown**:

Per-call time varies by partition warmth. At 30 partitions per shard (~20 NVMe-warm recent, ~10 cold):

| Partition state | Read source | Estimated per call |
|---|---|---|
| NVMe-warm (~20/30) | Local NVMe at 1–3 GB/s | 1–6 min |
| Cold (~10/30) | S3 at 100–500 MB/s | 2–10 min |

30 sequential calls per shard → **~30 min (optimistic) to ~8 hours (pessimistic)**. All 7 shards run in parallel; wall-clock equals per-shard time. See [Section 8.3](#83-compliance-mutations-with-zero-copy-replication) for the full recency bias analysis (including NVMe eviction pressure and small-part accumulation on recent partitions).

**Multi-user nightly batch — the binding risk variable**:

`OPTIMIZE TABLE PARTITION FINAL` calls for different users on the same partition are serialized. Per-user wall-clock does not parallelize across users sharing the same partitions.

| Users per nightly batch | Estimated wall-clock (midrange, per shard) | 24-hour SLA |
|---|---|---|
| 1 | ~2–3 hours | Comfortably feasible |
| 3–5 | ~6–15 hours | Feasible with scheduling |
| 10 | ~20–30 hours | Borderline / infeasible |
| 20+ | >24 hours | Infeasible without optimization |

The **number of users per nightly batch** is the primary new risk variable and must be quantified — see [Open Decision #11](#9-open-decisions).

**Available mitigations** (in order of preference):

| Mitigation | Effect | Cost |
|---|---|---|
| Accept logical inaccessibility (deletion bitmap) as SLA compliance | Eliminates `OPTIMIZE TABLE FINAL` requirement entirely | Requires legal/compliance approval — Open Decision #11 |
| Quantify and cap users per nightly batch | Keeps wall-clock within 24h | Requires product/ops constraint; queue management |
| Schedule to minimize concurrent user overlap on same partitions | Reduces serialization | Requires deletion job ordering logic |
| Rate-limit OPTIMIZE calls to off-peak windows | Reduces ingest contention | Requires deletion queue management; does not reduce total S3 I/O |
| Partition by `(event_date, user_id_bucket)` | Reduces rows-per-partition | Dramatically increases partition count; complicates TTL and query routing |

If the compliance team requires physical S3 byte removal within 24 hours, the nightly batch volume must be quantified and mitigations designed before production go-live.

### 12.7 Operational Scalability

**Rating: Moderate**

The single CHI containing both the ingest and cache clusters simplifies operator configuration but creates a wide blast radius for CHI-level operations. A CHI update triggers a rolling restart across all 19–21 pods. Separate CHIs for ingest and cache would allow independent upgrade cycles at the cost of manual `remote_servers` management.

Secret rotation (see [Section 7.4](#74-credential-management-via-hashicorp-vault)) requires sending `SIGHUP` to each ClickHouse pod after Vault Agent re-renders the credential file. At 19–21 pods, this is manageable manually. If pod count grows significantly, a rotation automation script or operator hook becomes necessary.

Monitoring scales linearly with pod count: each of the 21 pods emits independent `system.merges`, `system.filesystem_cache`, and `system.text_log` streams. Aggregate dashboards (merge queue depth, cache hit rate, part count per shard) are required before production — per-pod inspection does not scale.

### 12.8 Scalability Summary

| Dimension | Rating | Primary Bottleneck | Scale-out Path |
|---|---|---|---|
| Zero-copy replication | Critical | GC race conditions can cause permanent data loss; Keeper znode accumulation degrades over time | Resolve Open Decision #12 (zero-copy vs full replication) before YAML authoring; see Section 8.7 |
| Ingest tier | Moderate | Kafka repartitioning to add shards | Add shards (2→4); repartition Kafka |
| Cache cluster — vertical | Strong | NVMe sizing requires row size input (Decision #8) | Larger PVCs; S3 absorbs growth |
| Cache cluster — horizontal | High risk | No automated resharding; multi-hour manual migration | Establish resharding runbook before capacity ceiling |
| ClickHouse Keeper | Moderate | Raft write ceiling; multi-subsystem blast radius | Profile Keeper write pressure at 7 shards in PoC |
| S3 storage | Strong | Write amplification cost (row size TBD) | S3 scales independently |
| Query concurrency | Moderate | No connection pooling; merge/query RAM contention | chproxy; dedicated query cluster (Section 4.5) |
| Compliance deletes | High | 210 calls per user (30 typical partitions); multi-user batch volume is the binding constraint | Quantify users/batch; resolve Open Decision #11; prefer logical inaccessibility |
| Operational | Moderate | Single CHI blast radius; manual SIGHUP rotation | Automate rotation; split CHI if pod count grows |

---

## 13. Configuration Reference

Annotated DDL templates and server configuration baselines for all table types are in the companion document:

**[docs/configuration-reference.md](configuration-reference.md)**

| Section | Contents |
|---|---|
| [§1 — Database Engine: `Replicated` vs Default](configuration-reference.md#1-database-engine-replicated-vs-default) | Comparison of `Replicated` vs `Atomic` + `ON CLUSTER`; recommendation per cluster |
| [§2 — Cache Cluster Tables](configuration-reference.md#2-cache-cluster-tables) | `ReplicatedReplacingMergeTree` DDL; `Distributed` query table DDL |
| [§3 — Ingest Cluster Tables](configuration-reference.md#3-ingest-cluster-tables) | `KafkaEngine`, `S3Queue`, Materialized Views, write `Distributed` table DDL |
| [§4 — Global Server Settings](configuration-reference.md#4-global-server-settings) | Cache node and ingest node XML config baselines |
| [§5 — Cache Disk Sizing](configuration-reference.md#5-cache-disk-sizing) | Sizing formula, worked examples (50–200 B/row × 30–90 day retention), storage XML |

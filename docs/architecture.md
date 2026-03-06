# ClickHouse Production Architecture on Kubernetes

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Component Descriptions](#2-component-descriptions)
3. [Data Flow Diagrams](#3-data-flow-diagrams)
4. [Storage Policy Design](#4-storage-policy-design)
5. [Replication and HA Design](#5-replication-and-ha-design)
6. [Cross-Cluster Write Architecture](#6-cross-cluster-write-architecture)
7. [Critical Limitations and Risks](#7-critical-limitations-and-risks)
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

**Table engine**: `ReplicatedMergeTree` with `allow_remote_fs_zero_copy_replication = 1`.

**Storage**: Local NVMe/SSD write-through cache backed by S3 (see [Section 4](#4-storage-policy-design)).

**Query interface**: A `Distributed` table (`cache_distributed`) spans all 7 shards. Clients may query any cache node; the node fans out to the appropriate shards and aggregates results.

**Replica placement**: The 2 replicas of each shard must land on different Kubernetes nodes (pod anti-affinity required). Spreading across availability zones is recommended where the infrastructure supports it.

### 2.4 S3 Storage Backend

All persistent data is stored in S3 (MinIO or NetApp S3-compatible storage).

**Bucket layout**: Single bucket with per-shard prefix:
```
s3://bucket/clickhouse/cache/shard-1/
s3://bucket/clickhouse/cache/shard-2/
...
s3://bucket/clickhouse/cache/shard-7/
```

Both replicas of a shard intentionally write to the same shard prefix. This is required for zero-copy replication: Replica B does not copy data from Replica A — it reads the S3 parts that A already wrote and registers them as its own, coordinating ownership via Keeper.

**Consistency requirement**: Strong read-after-write consistency is required. Both MinIO (post-2021-09-23) and AWS S3 provide this. Verify any other S3-compatible storage provider before deployment.

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

Each cache shard receives rows from both ingest nodes. Rows are distributed by `xxHash64(sharding_key)` so that each row lands on exactly one shard (see [Open Question #7](#8-open-questions)).

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

```
Client
  └─► Any cache node (via K8s Service or proxy)
        └─► cache_distributed (Distributed table, cluster = cache)
              ├─► Shard 1 (queries one replica)
              ├─► Shard 2 (queries one replica)
              │   ...
              └─► Shard 7 (queries one replica)
                    └─► Aggregate results → Client
```

Hot data is served from the local NVMe cache. On a cache miss, the S3 parts are read from S3 and the result is populated into the local NVMe cache for subsequent reads.

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

S3 availability directly governs INSERT availability (write-through). S3 HA must be designed before this architecture can claim full HA:

- **MinIO**: requires distributed/erasure-coded mode across multiple nodes and drives. Single-node MinIO is not acceptable for production.
- **NetApp**: verify erasure-coding and redundancy settings with the storage team.

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
              └─► Distributed table (cluster = "cache", sharding_key = xxHash64(key))
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

### 7.3 Zero-Copy Replication Caveats

| Risk | Detail | Mitigation |
|---|---|---|
| Version requirement | Zero-copy had correctness bugs before 23.x | Mandate ClickHouse 24.x+ for production |
| Mutations (`UPDATE`/`DELETE`) | `ALTER TABLE UPDATE/DELETE` with zero-copy can produce inconsistency across replicas | Design for INSERT-only workflows; use lightweight deletes (23.3+) cautiously; see [Open Question #14](#8-open-questions) |
| GC accumulation | Pre-merge S3 parts are GC'd only after all replicas acknowledge the merged part in Keeper. Extended replica downtime causes S3 storage growth | Monitor S3 object count and size; set replica downtime SLA |
| S3 write amplification from merges | Frequent small merges generate many S3 PUT operations | Tune `min_bytes_for_wide_part`, `merge_max_block_size`, and merge selector settings |

### 7.4 KafkaEngine At-Least-Once Delivery Risk

KafkaEngine commits the Kafka offset after the Materialized View fires, but the downstream `Distributed` INSERT to the cache cluster can still fail after the offset is committed. This creates a window for data loss (offset advanced, INSERT not persisted).

**Options**:
- Set `kafka_commit_every_batch = 0`: reduces data loss risk but increases duplicate delivery on retry
- Use `ReplacingMergeTree` on the cache cluster for idempotent deduplication (recommended — see [Open Question #6](#8-open-questions))
- Configure a dead-letter Kafka topic to capture failed inserts

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

| # | Question | Blocks |
|---|---|---|
| 1 | **S3 implementation**: MinIO or NetApp S3? | Storage policy YAML, S3 credentials |
| 2 | **MinIO HA** (if MinIO selected): distributed/erasure-coded mode? How many MinIO nodes and drives? | S3 HA validation |
| 3 | **Keeper deployment method**: `ClickHouseKeeperInstallation` CRD or standalone StatefulSet? Confirm target Altinity operator version and its CRD support. | Keeper YAML |
| 4 | **Keeper node count**: 3 (tolerates 1 failure) or 5 (tolerates 2 failures)? | Keeper YAML, node reservation |
| 5 | **Kafka partition strategy**: How many partitions per topic? How are they split between the 2 ingest shards? | KafkaEngine DDL |
| 6 | **Exactly-once semantics**: Use `ReplacingMergeTree` on the cache cluster for deduplication, or accept at-least-once delivery? | Cache cluster DDL |
| 7 | **Sharding key**: Which column(s) to use for `xxHash64()` in the Distributed table, or use `rand()`? | Distributed table DDL |
| 8 | **Cache disk sizing**: Target data volume per shard? What percentage of hot data must fit in the NVMe cache? | PVC sizing, storage class selection |
| 9 | **S3 bucket and prefix naming**: Finalize the bucket name and prefix scheme before any deployment. Renaming after data exists requires a full data migration. | Storage policy YAML |
| 10 | **CHI namespace strategy**: One `ClickHouseInstallation` per environment (dev/staging/prod), or one CHI across all environments? | CHI YAML structure |
| 11 | **Query routing**: Direct pod connection, Kubernetes Service load balancing, or a query proxy (e.g., chproxy)? | Service/Ingress YAML |
| 12 | **Altinity operator version**: Confirm the exact version available in the target cluster. The cross-cluster `remote_servers` auto-generation behavior must be validated against this version. | CHI YAML, cross-cluster write path |
| 13 | **S3 credentials management**: Kubernetes Secrets, IAM instance roles/IRSA, or MinIO service accounts? | Storage policy YAML, RBAC |
| 14 | **Mutation policy**: Are any `ALTER TABLE UPDATE` or `DELETE` operations expected? If yes, zero-copy + mutation interaction must be evaluated and tested before production use. | DDL design |
| 15 | **Cache eviction behavior**: Is cache-miss fallback to S3-only reads acceptable for evicted data, or must the NVMe cache be sized large enough to prevent eviction of hot data entirely? | PVC sizing |

---

## 9. Recommended Versions

| Component | Recommended | Minimum | Notes |
|---|---|---|---|
| ClickHouse Server | **24.8 LTS** | 23.8 | Zero-copy replication is stable from 23.8; 24.x has additional correctness fixes. Always use an LTS release for production. |
| Altinity Operator | **0.23.x+** | — | Confirm `ClickHouseKeeperInstallation` CRD support for the exact version available. |
| ClickHouse Keeper | Same as CH Server | — | Keeper is bundled with ClickHouse. Keeper and CH server versions must match exactly. |
| MinIO (if selected) | **2023+ release** | 2021-09-23 | Strong read-after-write consistency was introduced in the 2021-09-23 release. Earlier versions are incompatible with zero-copy replication. |

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

**Phase 3 — Scale cache cluster to full topology (7 shards × 2 replicas)**
Roll out the remaining 6 shards. Validate `cache_distributed` fan-out queries.

**Phase 4 — Ingest cluster + cross-cluster Distributed table**
Deploy both ingest nodes in the same CHI as the cache cluster. Validate that ingest nodes can resolve cache shard addresses from the operator-generated `remote_servers`.

**Phase 5 — KafkaEngine + S3Queue + Materialized Views**
Create ingest tables and views. Validate end-to-end: messages from Kafka and files from the S3 source bucket appear in the cache cluster.

**Phase 6 — Distributed query table + client connectivity**
Expose `cache_distributed` to clients via the chosen routing mechanism (Service, chproxy, etc.). Run query validation.

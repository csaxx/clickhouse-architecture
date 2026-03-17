# StarRocks Production Architecture on Kubernetes

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
   - 2.3 [Architecture Mode: Shared-Data](#23-architecture-mode-shared-data)
3. [Component Descriptions](#3-component-descriptions)
   - 3.1 [FE Nodes (Frontend)](#31-fe-nodes-frontend)
   - 3.2 [CN Nodes (Compute Node)](#32-cn-nodes-compute-node)
   - 3.3 [S3 Storage Backend](#33-s3-storage-backend)
4. [Data Flow](#4-data-flow)
   - 4.1 [Kafka Ingest Path (Routine Load)](#41-kafka-ingest-path-routine-load)
   - 4.2 [S3 File Ingest Path (Pipe)](#42-s3-file-ingest-path-pipe)
   - 4.3 [Query Path](#43-query-path)
   - 4.4 [Query Routing: K8s Service vs chproxy](#44-query-routing-k8s-service-vs-chproxy)
   - 4.5 [Dedicated Query Tier: Not Applicable](#45-dedicated-query-tier-not-applicable)
5. [Storage Design](#5-storage-design)
   - 5.1 [Shared-Data Storage Model](#51-shared-data-storage-model)
   - 5.2 [Key Storage Settings](#52-key-storage-settings)
   - 5.3 [Cache Eviction Strategy](#53-cache-eviction-strategy)
   - 5.4 [Write-Path Cache Population](#54-write-path-cache-population)
6. [Replication and High Availability](#6-replication-and-high-availability)
   - 6.1 [Data Durability (Shared-Data Mode)](#61-data-durability-shared-data-mode)
   - 6.2 [FE High Availability](#62-fe-high-availability)
   - 6.3 [CN Failure and Recovery](#63-cn-failure-and-recovery)
   - 6.4 [S3 HA](#64-s3-ha)
7. [Write Architecture](#7-write-architecture)
   - 7.1 [Routine Load Write Path](#71-routine-load-write-path)
   - 7.2 [Authentication and Network Policy](#72-authentication-and-network-policy)
   - 7.3 [Credential Management via HashiCorp Vault](#73-credential-management-via-hashicorp-vault)
8. [Risks and Limitations](#8-risks-and-limitations)
   - 8.1 [Shared-Data Mode Maturity](#81-shared-data-mode-maturity)
   - 8.2 [Primary Key Merge-on-Write at Ingest Scale](#82-primary-key-merge-on-write-at-ingest-scale)
   - 8.3 [Routine Load Small File Accumulation](#83-routine-load-small-file-accumulation)
   - 8.4 [StarRocks Pipe Maturity](#84-starrocks-pipe-maturity)
   - 8.5 [FE as Multi-Role Single Point of Failure](#85-fe-as-multi-role-single-point-of-failure)
   - 8.6 [kube-starrocks Operator Maturity](#86-kube-starrocks-operator-maturity)
   - 8.7 [S3 Availability Equals Write Availability](#87-s3-availability-equals-write-availability)
   - 8.8 [Compaction for Physical Compliance Delete](#88-compaction-for-physical-compliance-delete)
9. [Open Decisions](#9-open-decisions)
10. [Recommended Versions](#10-recommended-versions)
11. [Implementation Roadmap](#11-implementation-roadmap)
12. [Scalability Considerations](#12-scalability-considerations)
    - 12.1 [Ingest Tier](#121-ingest-tier)
    - 12.2 [CN Horizontal Scaling](#122-cn-horizontal-scaling)
    - 12.3 [FE Concurrency](#123-fe-concurrency)
    - 12.4 [S3 Storage](#124-s3-storage)
    - 12.5 [Query Concurrency](#125-query-concurrency)
    - 12.6 [Compliance Delete Scalability](#126-compliance-delete-scalability)
    - 12.7 [Operational Scalability](#127-operational-scalability)
    - 12.8 [Scalability Summary](#128-scalability-summary)
13. [Configuration Reference](#13-configuration-reference)

---

## 1. Requirements and Assumptions

This chapter collects the confirmed requirements and design assumptions that motivate the architectural decisions throughout this document. Requirements are identical to those driving the parallel ClickHouse architecture; the StarRocks solutions differ.

### 1.1 Use Case and System Context

The system is a production-grade event data pipeline on Kubernetes. Data arrives continuously from two source systems and is made available for analytical queries:

- **Source A — Apache Kafka**: streaming events from application producers
- **Source B — S3 file uploads**: batch file deposits from external systems or ETL processes

Data is ingested directly into a unified compute+storage tier and is available for analytical queries immediately after ingest. Clients run read-heavy, ad-hoc analytical queries against the current dataset.

### 1.2 Ingest Requirements

| Metric | Value |
|---|---|
| Daily ingest volume | ~5 billion rows/day |
| Sustained ingest rate | ~57,870 rows/sec |
| Arrival pattern | Continuous — no batch window |
| Expected duplicate rate | 10–20% (~500M–1B duplicates/day) |
| Unique rows after deduplication | ~4–4.5B rows/day |
| Per CN node (7 CNs) | ~8,267 rows/sec average (load distributed by FE) |
| Per partition per day (7 partitions) | ~714M rows/day (pre-dedup) |

Ingest must be continuous and uninterrupted; no maintenance window is available for batch loading.

**Rowset accumulation constraint**: Routine Load fires sub-tasks on a configurable interval. If `max_batch_rows` is set too low relative to ingest rate, CN nodes accumulate many small rowsets per partition, degrading merge and query performance. This is the StarRocks equivalent of ClickHouse's "too many parts" problem. `max_batch_rows` and `desired_concurrent_number` must be tuned to produce rowsets large enough to avoid accumulation (see [Section 4.1](#41-kafka-ingest-path-routine-load) and [Section 8.3](#83-routine-load-small-file-accumulation)).

**Write-path deduplication**: The Primary Key table model deduplicates on INSERT (merge-on-write). Each duplicate row triggers a lookup on the Primary Key index and replaces the stored row. At 57,870 rows/sec with 10–20% duplicate rate (~5,787–11,574 row replacements/sec), write-path overhead must be validated in PoC (see [Section 8.2](#82-primary-key-merge-on-write-at-ingest-scale)).

> **Improvement over ClickHouse**: `ReplicatedReplacingMergeTree` deduplicates at merge time — duplicate rows are transiently visible between INSERT and the background merge. StarRocks Primary Key model deduplicates on INSERT — **no transient duplicates exist at any point**. This removes the need for `SELECT ... FINAL` and eliminates the associated 2–3× query overhead.

### 1.3 Query Requirements

- Analytical (read-heavy, ad-hoc) query workload
- Hot data (recently ingested) expected to be queried most frequently
- NVMe/SSD data cache serves hot data; S3 fallback acceptable for cold data (cache miss)
- No transient duplicates — Primary Key model guarantees deduplicated reads immediately after INSERT
- No per-user query isolation or connection pooling required at initial deployment

### 1.4 Compliance Requirements

Two distinct compliance delete mechanisms are required as hard requirements:

**Time-based expiry (TTL path)**:
- An `eviction_date` column marks the expiry date of each row
- Physical S3 deletion must complete within 24 hours of the expiry date
- This SLA is satisfied by partition-level TTL with daily partitions — StarRocks drops entire expired partitions, which triggers S3 object deletion. No in-partition rewrite is needed (see [Section 7.1](#71-routine-load-write-path))

**User-ID row-level delete**:
- Nightly compliance deletes of all rows for a given `user_id` (`DELETE FROM ... WHERE user_id = X`)
- 24-hour SLA applies — whether "24 hours" means **physical S3 byte removal** or **logical inaccessibility** is a pending legal determination (see [Open Decision #11](#9-open-decisions))
- **Improvement over ClickHouse**: On the Primary Key model, `DELETE FROM t WHERE user_id = X` achieves **immediate logical inaccessibility** — deleted rows are invisible to all queries immediately, with no `OPTIMIZE TABLE PARTITION FINAL` equivalent required for logical deletion. Physical byte removal from S3 still requires compaction (see [Section 8.8](#88-compaction-for-physical-compliance-delete))
- If the compliance SLA requires only logical inaccessibility, StarRocks satisfies it immediately on `DELETE`. If physical byte removal is required, `ALTER TABLE t COMPACT` forces compaction and is the equivalent of ClickHouse's `OPTIMIZE TABLE PARTITION FINAL`

**Nightly compliance updates**: field-level `UPDATE` operations are a confirmed nightly requirement. StarRocks Primary Key model supports `UPDATE table SET col = val WHERE condition` natively and efficiently (see [Section 13](#13-configuration-reference)).

### 1.5 Infrastructure Constraints

| Component | Constraint |
|---|---|
| Platform | Kubernetes |
| Operator | kube-starrocks operator (validate version against target StarRocks version — see [Section 10](#10-recommended-versions)) |
| Secrets management | HashiCorp Vault with Kubernetes auth method |
| Coordination | FE nodes (internal BDB-JE; no external ZooKeeper/Keeper needed) |
| Local storage | NVMe/SSD PersistentVolumes on CN nodes (data cache only — not primary storage) |
| Object storage | S3-compatible backend (MinIO or NetApp — decision pending, see [Open Decision #1](#9-open-decisions)) |

### 1.6 Design Assumptions

| Assumption | Value | Status |
|---|---|---|
| Deduplication model | Merge-on-write (Primary Key table) — no transient duplicates | Confirmed |
| Query isolation | K8s Service LB sufficient; per-user routing not required initially | Confirmed |
| Partition key | Daily (`PARTITION BY date_trunc('DAY', event_date)`) | Confirmed |
| Cache eviction | LRU acceptable; start at 20–30% of dataset for NVMe sizing | Confirmed |
| Distribution key column | `DISTRIBUTED BY HASH(col)` — column TBD | Open — see [Decision #5](#9-open-decisions) |
| Row size | TBD | Open — see [Decision #7](#9-open-decisions) |
| Bucket count per partition | 21 (3× CN count = 3 × 7) — starting point | Open — see [Decision #8](#9-open-decisions) |

---

## 2. Architecture Overview

The architecture uses StarRocks shared-data mode: FE nodes provide metadata coordination and query routing; CN nodes provide compute and local NVMe data caching; S3 is the source of truth for all persistent data.

> **Improvement over ClickHouse**: The ClickHouse architecture requires three separate concerns — ClickHouse Keeper (3–5 pods), an ingest cluster (2 pods), and a cache cluster (14 pods) — totaling 19–21 pods. StarRocks unifies these into FE nodes (3 pods) + CN nodes (7 pods) = **10 pods total**. FE handles metadata coordination and Routine Load scheduling natively. Shared-data mode eliminates per-shard replication by using S3 as the source of truth.

### 2.1 Cluster Topology

```
                     ┌─────────────────────────────────────────────────┐
                     │              Kubernetes Cluster                  │
                     │                                                  │
 ┌──────────┐        │  ┌─────────────────────────────────────────┐    │
 │  Apache  │        │  │         FE Nodes (3 pods)                │    │
 │  Kafka   │────────┼──│  ┌──────────┐ ┌──────────┐ ┌─────────┐ │    │
 └──────────┘        │  │  │ FE-0     │ │ FE-1     │ │ FE-2    │ │    │
                     │  │  │ (leader) │ │(follower)│ │(follower│ │    │
 ┌──────────┐        │  │  └────┬─────┘ └──────────┘ └─────────┘ │    │
 │  S3 Src  │────────┼──│       │  Routine Load scheduling        │    │
 │  Bucket  │        │  │       │  Pipe monitoring                │    │
 └──────────┘        │  │       │  Query coordination             │    │
                     │  └───────┼─────────────────────────────────┘    │
                     │          │  dispatch fragments                   │
                     │          ▼                                       │
                     │  ┌──────────────────────────────────────────┐   │
                     │  │         CN Nodes (7 pods)                 │   │
                     │  │  CN-0  CN-1  CN-2  CN-3  CN-4  CN-5  CN-6│   │
                     │  │  [NVMe data cache on each CN]             │   │
                     │  └──────────────────────────────────────────┘   │
                     └─────────────────────────────────────────────────┘
                                          │  writes / reads
                               ┌──────────┘
                               ▼
                     ┌──────────────────┐
                     │  S3 Backend      │
                     │  (MinIO / NetApp)│
                     │  (source of truth│
                     │   for all data)  │
                     └──────────────────┘
```

### 2.2 Pod Count Summary

| Component | Pods | Notes |
|---|---|---|
| FE nodes | 3 | 1 leader + 2 followers; handles metadata, query routing, Routine Load |
| CN nodes | 7 | Shared-data mode; NVMe is data cache only; S3 is primary storage |
| **Total pods** | **10** | vs. 19–21 for equivalent ClickHouse deployment |

### 2.3 Architecture Mode: Shared-Data

**Architecture mode chosen: Shared-data (StarRocks 3.x).**

This is the correct mode for this architecture for the following reasons:

- **Data is stored in S3 (primary storage)** with local NVMe SSD as a data cache — directly analogous to ClickHouse's `cache` disk type wrapping an `s3` disk.
- **No per-CN replication is required** for data durability. S3 (with MinIO erasure coding or NetApp hardware redundancy) provides durability. If a CN fails, other CNs read from S3 directly; no data is lost.
- **Shared-nothing mode** stores data locally on BEs with no S3 backend — this does not match the desired architecture and is explicitly not selected.

The shared-data model eliminates the zero-copy replication risk that is a critical open decision in the ClickHouse architecture (ClickHouse Open Decision #12: GC race conditions causing documented data loss incidents). In StarRocks shared-data mode, S3 is the single source of truth — there is no replication coordination that can race with GC.

> **Improvement over ClickHouse**: ClickHouse's `allow_remote_fs_zero_copy_replication = 1` is a critical open risk with documented GC data loss incidents in production. StarRocks shared-data mode **eliminates this risk entirely** — there is no replica-to-replica coordination on S3 data, and no GC race condition is possible.

---

## 3. Component Descriptions

### 3.1 FE Nodes (Frontend)

FE nodes are the **control plane and query coordination layer** for the StarRocks cluster. A 3-node FE deployment provides one elected leader and two followers. Leader election uses Raft consensus over BDB-JE (Berkeley DB Java Edition) — no external coordination service (ZooKeeper, ClickHouse Keeper) is required.

**FE responsibilities**:
- Metadata storage and coordination (table schemas, partition metadata, CN topology, tablet assignments)
- Query parsing, planning, and fragment dispatch to CNs
- Routine Load job management: FE creates, monitors, and restarts Routine Load jobs; sub-tasks are dispatched to CNs for execution
- Pipe monitoring: FE tracks which S3 files have been loaded and triggers new loads when files arrive
- DDL execution (CREATE TABLE, ALTER TABLE, etc.)
- User authentication

**FE replaces** (in ClickHouse terms):
- ClickHouse Keeper — metadata coordination and leader election
- The ingest cluster — Routine Load scheduling is internal to FE; no separate ingest nodes are needed
- The Distributed table DDL — FE routes queries to CNs automatically; clients need no special table name

**Criticality**: FE quorum loss simultaneously halts all DDL, all DML, all Routine Load scheduling, all Pipe monitoring, and all query routing. This is equivalent blast radius to ClickHouse Keeper quorum loss, and must be treated with the same criticality.

**Placement**: FE pods must run on dedicated Kubernetes nodes with reserved CPU and memory. Pod anti-affinity must be enforced to spread FE across distinct nodes and, where possible, distinct availability zones.

**Quorum sizing** (see [Open Decision #3](#9-open-decisions)):
- 3 nodes: tolerates 1 node failure (standard production configuration)
- 5 nodes: tolerates 2 node failures (extra fault tolerance at higher cost)

### 3.2 CN Nodes (Compute Node)

CN nodes are the **compute and data cache layer**. In shared-data mode, CNs do not own data permanently — S3 is the source of truth. The local NVMe SSD on each CN is a transparent data cache that accelerates reads for hot data.

**CN responsibilities**:
- Execute Routine Load sub-tasks (consume Kafka partitions, write rowsets to S3)
- Execute Pipe load tasks (read S3 files, write rowsets to S3)
- Execute query fragments dispatched by FE (scan tablets, aggregate, filter)
- Maintain local NVMe data cache (hot tablet pages, populated on read or write)
- Perform background compaction (merging small rowsets into larger ones; deduplicating Primary Key model rows)

**Tablet distribution**: In shared-data mode, tablets are stored in S3. Each tablet is assigned to a CN for compute purposes; FE reassigns tablets from failed CNs to healthy CNs automatically. There is no replication factor — each tablet has one S3 location, not N replicas.

**Horizontal scaling**: Adding a CN pod causes FE to redistribute tablets across all CNs automatically. No manual shard migration is required. This is a major operational improvement over ClickHouse, which requires manual resharding during scale-out (see [Section 12.2](#122-cn-horizontal-scaling)).

> **kube-starrocks operator note**: When authoring YAML manifests, shared-data CN nodes are declared under `starRocksComputeNodeSpec` in the `StarRocksCluster` CR — **not** `starRocksBeSpec` (which is for shared-nothing BE nodes). Using the wrong spec will deploy shared-nothing Backend nodes, which do not connect to S3 and will not function as intended.

### 3.3 S3 Storage Backend

All persistent data is stored in S3-compatible storage. Two candidates are under evaluation: **MinIO** and **NetApp**. The team must select one before YAML authoring begins (see [Open Decision #1](#9-open-decisions)).

The S3 backend evaluation and trade-offs are identical to the ClickHouse architecture. The MinIO vs. NetApp comparison below applies equally to both systems.

**Bucket layout**: Single bucket with per-table/partition prefix managed by StarRocks internally:
```
s3://bucket/starrocks/
  └── {db_id}/{table_id}/{partition_id}/{tablet_id}/
```

StarRocks shared-data manages S3 path layout internally. Unlike ClickHouse, no per-shard bucket prefix configuration is required at the operator level.

**Consistency requirement**: Strong read-after-write consistency is required. Both MinIO and NetApp satisfy this at the versions specified in [Section 10](#10-recommended-versions).

#### MinIO vs NetApp Comparison

| Dimension | MinIO | NetApp |
|---|---|---|
| **Consistency model** | Strong read-after-write consistency from 2021-09-23 release onward | Depends on product (ONTAP S3, StorageGRID); verify per-product docs — strong consistency generally available but must be confirmed |
| **HA / erasure coding** | Distributed erasure-coded mode across ≥4 nodes with configurable EC (e.g., EC:4 or EC:2) | Hardware-native redundancy (RAID, HA controllers); erasure coding varies by product line |
| **Vault integration path** | Vault KV or dynamic credentials via MinIO admin API; Vault Agent Sidecar injects creds into CN/FE config at pod start | Vault KV for static access-key storage; Vault Agent Sidecar injection pattern applies |
| **Operational complexity** | Operator-managed (Kubernetes MinIO Operator available); team owns the full storage layer | Storage team manages the appliance/cluster; StarRocks team only manages credentials and bucket configuration |
| **Cost model** | Infrastructure cost only (runs on commodity nodes) | Licensing + hardware; potentially pre-existing sunk cost if NetApp is already deployed |
| **StarRocks PoC risk** | Well-documented with shared-data mode S3 backends | Less community documentation for StarRocks + NetApp; requires explicit PoC validation |

**Recommendation**: If NetApp is already operational in the environment, prefer it to avoid managing an additional storage layer. If no existing S3 infrastructure exists, MinIO distributed mode is the proven path for StarRocks shared-data.

---

## 4. Data Flow

### 4.1 Kafka Ingest Path (Routine Load)

Routine Load is the StarRocks mechanism for continuous Kafka consumption. The FE creates and manages the job; CNs execute sub-tasks.

```
Kafka Topic (N partitions)
  │
  ├─► FE (Routine Load job manager)
  │     ├─► Sub-task 0 → CN-x  (partitions 0..N/K-1)
  │     │     └─► rowsets written to S3 → Primary Key table
  │     ├─► Sub-task 1 → CN-y  (partitions N/K..2N/K-1)
  │     │     └─► rowsets written to S3 → Primary Key table
  │     └─► ... (K sub-tasks total)
  │
  └─► FE tracks offsets internally (no external offset store needed)
```

Each sub-task is assigned to a CN by FE. The CN consumes the assigned Kafka partition range for one batch interval, writes rowsets to S3, and reports completion to FE. FE commits Kafka offsets internally on success.

**Key tuning parameters**:
- `desired_concurrent_number`: number of parallel sub-tasks (equivalent concept to Kafka consumer parallelism on ClickHouse's ingest cluster)
- `max_batch_rows`: max rows per sub-task flush (equivalent to `kafka_max_block_size` in ClickHouse — see [Open Decision #9](#9-open-decisions))
- `max_batch_interval`: max seconds between flushes

**Kafka partition count**: Partition count determines the maximum effective parallelism for Routine Load. `desired_concurrent_number` cannot exceed the number of Kafka partitions. Must be a value that allows even distribution across sub-tasks (see [Open Decision #10](#9-open-decisions)).

**Improvement over ClickHouse**: ClickHouse requires a `KafkaEngine` table + Materialized View chain + `Distributed` table on ingest nodes, plus a cross-cluster INSERT to the cache cluster. StarRocks Routine Load is a single DDL statement — FE manages the entire lifecycle. No Materialized Views, no Distributed table, no separate ingest cluster required.

### 4.2 S3 File Ingest Path (Pipe)

StarRocks Pipe (3.2+) is the equivalent of ClickHouse's S3Queue. The FE monitors a configured S3 path and dispatches load tasks to CNs as new files appear.

```
S3 Source Bucket
  │
  ├─► FE (Pipe job monitor)
  │     ├─► Detects new file → dispatches load task → CN-x
  │     │     └─► CN reads file from S3, writes rowsets → Primary Key table
  │     ├─► Marks file as loaded in FE metadata
  │     └─► Retries failed files automatically
  │
  └─► Primary Key table deduplicates overlapping rows on INSERT
```

**Pipe vs S3Queue comparison**:

| Dimension | StarRocks Pipe | ClickHouse S3Queue |
|---|---|---|
| **File tracking state** | FE metadata (BDB-JE) | ClickHouse Keeper znode tree |
| **Deduplication** | Marks files processed after successful load; Primary Key model deduplicates row-level overlaps | Keeper coordinates file claims; each file processed by exactly one ingest node |
| **Failure/retry** | Pipe retries failed files automatically; FE persists retry state | Keeper releases claimed files after ingest node failure; files re-queued |
| **Semantics** | At-least-once file processing; row-level dedup by Primary Key | At-least-once (retry on failure); row-level dedup by ReplacingMergeTree at merge time |
| **Maturity** | StarRocks 3.2+ — newer, requires explicit PoC validation (see [Section 8.4](#84-starrocks-pipe-maturity)) | Production-mature in ClickHouse |

### 4.3 Query Path

**Chosen mechanism**: Kubernetes Service load balancing to FE nodes (see [Section 4.4](#44-query-routing-k8s-service-vs-chproxy) for the trade-off evaluation).

```
Client
  └─► K8s Service (ClusterIP or LoadBalancer, port 9030/8030)
        └─► Any FE node (round-robin or random pod selection)
              └─► FE parses query, generates execution plan
                    └─► FE dispatches fragments to CNs
                          ├─► CN-0 scans assigned tablets → partial result
                          ├─► CN-1 scans assigned tablets → partial result
                          │   ...
                          └─► CN-6 scans assigned tablets → partial result
                                └─► FE collects and merges → Client
```

Hot data is served from the local NVMe data cache on each CN. On a cache miss, the tablet pages are read from S3 and populated into the NVMe cache for subsequent reads.

The K8s Service targets all FE pods via label selector. Kubernetes health checking removes failed FE pods from the endpoint slice automatically.

**Improvement over ClickHouse**: ClickHouse requires a `Distributed` table on the receiving node to fan out to shards, plus a potential dedicated query cluster for compute isolation. In StarRocks, FE natively separates query coordination from data storage — every FE node is a full query coordinator. No `Distributed` table DDL is needed, and no dedicated query cluster is required to achieve the same compute isolation benefit.

### 4.4 Query Routing: K8s Service vs chproxy

**Decision**: K8s Service LB selected. This section documents the trade-off evaluation for the record.

| Dimension | K8s Service (chosen) | chproxy |
|---|---|---|
| **Operational complexity** | None — native Kubernetes primitive | Additional Deployment; requires HA deployment of chproxy itself |
| **Health checking** | Kubernetes readiness/liveness probes remove unhealthy FE pods automatically | chproxy has its own health check logic; must be configured separately |
| **Connection pooling** | None — each client connection goes directly to an FE pod | chproxy pools connections, reducing FE connection overhead under high client concurrency |
| **Per-user / per-query routing** | Not available | Supports per-user routing, read-only enforcement, query-level routing rules |
| **Queue limiting / overflow** | Not available | chproxy can queue or reject queries that exceed concurrency limits |
| **Protocol support** | MySQL wire protocol (port 9030) and HTTP (port 8030) | HTTP only |
| **When to reconsider** | If client concurrency causes FE connection exhaustion | — |

chproxy is a valid escalation path if FE connection counts become a bottleneck at high client concurrency.

### 4.5 Dedicated Query Tier: Not Applicable

ClickHouse Section 4.5 evaluates a dedicated query cluster as a mechanism to isolate query compute from ingest and merge workloads on cache nodes. This concern does not apply to StarRocks in the same way:

- FE nodes are already dedicated query coordinators — they hold no data and perform no ingest work
- CN compute isolation between ingest (Routine Load execution) and query (fragment execution) is managed by StarRocks's internal resource groups and pipeline execution engine
- If CN compute contention between ingest and query becomes measurable, StarRocks Resource Groups (`CREATE RESOURCE GROUP`) provide workload isolation without adding a separate cluster tier

The PoC should measure CPU and memory headroom on CNs during concurrent query workloads while Routine Load sub-tasks are active. If contention is observed, configure Resource Groups before considering infrastructure changes.

---

## 5. Storage Design

### 5.1 Shared-Data Storage Model

In shared-data mode, each CN node has a two-layer storage model:

```
S3 Backend  (primary — source of truth for all data)
  └──► s3://bucket/starrocks/  [MinIO or NetApp]
        └── All tablet data (rowsets) written here on INSERT

NVMe/SSD Data Cache  (per-CN — transparent acceleration layer)
  └──► /path/to/datacache/  [NVMe PVC on CN pod]
        └── Hot tablet pages cached here (LRU eviction when full)
```

This is directly analogous to ClickHouse's `cache` disk type wrapping an `s3` disk. The operational semantics are equivalent: all writes go to S3; hot data is cached locally on NVMe; cache misses transparently read from S3 and populate the cache.

The key difference from ClickHouse is that StarRocks shared-data does **not** write to local NVMe on INSERT by default — data goes to S3, and the cache is populated on read (or optionally on write via `datacache_populate_mode`). This is discussed in [Section 5.4](#54-write-path-cache-population).

### 5.2 Key Storage Settings

CN node configuration (`cn.conf`):

| Setting | Value | Notes |
|---|---|---|
| `datacache_enable` | `true` | Enables local NVMe data cache |
| `datacache_disk_path` | `/path/to/datacache` | NVMe PVC mount path |
| `datacache_disk_size` | TBD | NVMe PVC size — see [Open Decision #7](#9-open-decisions) |
| `datacache_populate_mode` | `auto` (recommended) | Controls when cache is populated — see [Section 5.4](#54-write-path-cache-population) |

S3 backend configuration (set in FE + CN via `aws_s3_*` properties or config):

| Setting | Value | Notes |
|---|---|---|
| `aws_s3_endpoint` | S3 endpoint URL | MinIO or NetApp endpoint |
| `aws_s3_access_key` | Injected by Vault Agent | See [Section 7.3](#73-credential-management-via-hashicorp-vault) |
| `aws_s3_secret_key` | Injected by Vault Agent | |
| `aws_s3_region` | Region identifier | MinIO: use `us-east-1` or configured region |
| `aws_s3_path` | `s3://bucket/starrocks` | Root path for all StarRocks data |

Routine Load tuning parameters (set in `CREATE ROUTINE LOAD` DDL):

| Setting | Value | Notes |
|---|---|---|
| `desired_concurrent_number` | TBD | Parallel sub-tasks; see [Open Decision #9](#9-open-decisions) |
| `max_batch_rows` | TBD | Rows per sub-task flush; tune to avoid small rowset accumulation |
| `max_batch_interval` | `10` (seconds, starting point) | Max wait between flushes |

### 5.3 Cache Eviction Strategy

StarRocks data cache uses **LRU (Least Recently Used) eviction** when the NVMe cache reaches `datacache_disk_size`. This produces the following recency profile:

- **Actively queried data stays warm**: LRU retains tablet pages that are being read regularly
- **Cold data is evicted**: Least-recently-used pages are evicted when cache is full; evicted data is still readable — CN transparently fetches from S3 on cache miss
- **Cache miss transparency**: A cache miss adds S3 read latency for that query but does not fail the query

**Sizing guidance**: Target the NVMe cache at the active working set. A starting point of 20–30% of total dataset size is reasonable; tune based on observed cache hit ratio. See [Open Decision #7](#9-open-decisions) for the sizing inputs required.

**Key monitoring**:
```sql
-- Data cache utilization and hit metrics per CN (StarRocks 3.x)
SELECT * FROM information_schema.datacache_stats;
```

A cache hit ratio below ~90% on hot queries indicates the NVMe cache is undersized for the active working set.

### 5.4 Write-Path Cache Population

**ClickHouse** (with `cache_on_write_operations = 1`): data is written to both NVMe and S3 on INSERT simultaneously — the NVMe cache is always warm for the most recently ingested data.

**StarRocks shared-data** (default behavior): data is written to S3 on INSERT; the NVMe cache is populated on the first read of that data (read-through). This means newly ingested data is not immediately cache-warm — the first query touching a new tablet page incurs an S3 read latency.

**Mitigation**: Set `datacache_populate_mode = auto`. With `auto` mode, StarRocks opportunistically pre-populates the cache during read I/O paths and may also populate on write in some configurations. Exact behavior varies by version.

> **Open Decision #12** (see [Section 9](#9-open-decisions)): The PoC must validate whether `datacache_populate_mode = auto` provides sufficient cache warmth for newly ingested data to match the ClickHouse `cache_on_write_operations = 1` behavior. If hot-data query latency on freshly ingested partitions is unacceptable, additional investigation is required.

---

## 6. Replication and High Availability

### 6.1 Data Durability (Shared-Data Mode)

In shared-data mode, **data durability is provided entirely by S3**. There is no per-CN data replication, no replica log, and no replication coordination. The HA model for data is:

- MinIO: erasure-coded distributed mode across ≥4 nodes (e.g., EC:2 or EC:4)
- NetApp: hardware-native redundancy (RAID, HA controller pairs)

This eliminates the zero-copy replication concern that is a critical open risk in the ClickHouse architecture. There is no GC race condition because there is only one copy of each data file in S3, owned and managed by StarRocks directly.

### 6.2 FE High Availability

FE HA uses Raft-based leader election over BDB-JE. No external coordination service is required.

| FE Configuration | Fault Tolerance |
|---|---|
| 3 FE nodes (standard) | Tolerates 1 FE failure; 2-node quorum remains |
| 5 FE nodes (extra) | Tolerates 2 FE failures; 3-node quorum remains |

**FE leader election**: When the leader FE fails, the followers elect a new leader automatically (typically within seconds). During leader election:
- New DDL statements are queued or fail
- New DML (INSERT/UPDATE/DELETE) is queued or fails
- Routine Load new sub-task scheduling pauses
- Existing query fragments already dispatched to CNs continue executing
- In-flight Routine Load sub-tasks on CNs continue executing; they report to FE on completion

**FE follower reads**: StarRocks 3.x supports follower FE nodes handling read queries (SELECT) to distribute query coordination load. This is the StarRocks equivalent of ClickHouse's dedicated query cluster benefit — achieved through FE configuration, not a separate cluster.

See [Open Decision #3](#9-open-decisions) for the 3 vs. 5 FE node decision.

### 6.3 CN Failure and Recovery

| Failed Component | Impact | Recovery |
|---|---|---|
| 1 CN node | FE reassigns affected tablets to remaining CNs; those CNs read affected tablet data from S3 (cold cache for those tablets); no data loss | Pod restart → FE marks CN active → CN begins warming NVMe cache from S3 reads |
| Multiple CN nodes | Affected tablets' compute reassigned; cold reads from S3 for those tablets | Same — each restarted CN warms its cache independently |
| All CN nodes | All queries fail (no compute available) | Restore CNs; data is safe in S3; full cache warmup required on restart |
| FE quorum loss | All DDL, DML, Routine Load, Pipe, and query routing halt | Restore FE quorum; StarRocks resumes automatically |
| S3 unavailable | INSERTs fail (data written to S3 on INSERT); reads from NVMe cache may partially work | Restore S3; in-flight Routine Load sub-tasks must be retried |

### 6.4 S3 HA

S3 availability directly governs INSERT availability (all writes go to S3 in shared-data mode). S3 HA must be designed and validated before this architecture can claim full HA.

**MinIO** (if selected):
- Must run in distributed erasure-coded mode across a minimum of 4 nodes
- Recommended: ≥4 nodes with EC:2 or EC:4 depending on drive count and desired fault tolerance
- Single-node or single-drive MinIO is not acceptable for production
- See [Open Decision #2](#9-open-decisions) for MinIO node/drive count

**NetApp** (if selected):
- Verify the specific product (ONTAP S3, StorageGRID) is configured with hardware-level redundancy
- Confirm strong read-after-write consistency on the S3 API path used by StarRocks
- Confirm settings with the storage team before PoC

**Common requirement**: The S3 endpoint must be reachable from all 7 CN pods and all 3 FE pods on the configured port. Validate Kubernetes NetworkPolicy allows this traffic.

---

## 7. Write Architecture

### 7.1 Routine Load Write Path

```
Kafka partition range
  └─► Routine Load sub-task on CN-x (assigned by FE)
        └─► CN consumes rows from Kafka
              └─► Primary Key dedup (merge-on-write: new row replaces existing row with same key)
                    └─► Rowset written to S3
                          └─► FE commits offset on success
```

The write path is simpler than ClickHouse's cross-cluster architecture:
- No ingest cluster → cache cluster network hop
- No Distributed table fanout on INSERT
- No Materialized View chain
- No Keeper coordination on the write path

**Time-based expiry (partition TTL)**:

Configure on the table with dynamic partition management:
```sql
PROPERTIES (
    "partition_ttl" = "90 DAY",
    "dynamic_partition.enable" = "true",
    "dynamic_partition.time_unit" = "DAY",
    "dynamic_partition.ttl" = "90"
);
```

When a partition's TTL expires, StarRocks drops the entire partition and deletes the associated S3 objects. This is equivalent to ClickHouse's `TTL_only_drop_parts = 1` with daily partitions — no in-partition row-level rewrite is performed, making the 24-hour TTL SLA achievable.

**User-ID row-level DELETE**:
```sql
-- Logical deletion — immediately effective, rows invisible to all subsequent queries
DELETE FROM events WHERE user_id = 12345;

-- Physical byte removal — requires compaction (equivalent to OPTIMIZE TABLE PARTITION FINAL)
ALTER TABLE events COMPACT PARTITION p20240101;  -- specific partition
-- or
ALTER TABLE events COMPACT;  -- all partitions (resource-intensive)
```

> **Improvement over ClickHouse**: In ClickHouse, `DELETE FROM t WHERE user_id = X` alone is a lightweight delete marker — rows remain visible to queries until `OPTIMIZE TABLE PARTITION FINAL` is run. In StarRocks Primary Key model, deleted rows are **immediately invisible** to all queries after the `DELETE` statement completes. Physical S3 byte removal still requires compaction (see [Section 8.8](#88-compaction-for-physical-compliance-delete)), but the logical inaccessibility requirement is satisfied immediately.

**Nightly field-level UPDATE**:
```sql
-- Efficiently supported on Primary Key model
UPDATE events
SET field_a = new_value
WHERE condition;
```

### 7.2 Authentication and Network Policy

**Required Kubernetes NetworkPolicy — FE to CN**:
- FE pods must reach CN pods on:
  - Port **9060** (CN thrift port — heartbeat, tablet info)
  - Port **8040** (CN HTTP port — result fetching)
  - Port **9050** (CN heartbeat service port)

**Required Kubernetes NetworkPolicy — Client to FE**:
- Clients must reach FE pods on:
  - Port **9030** (MySQL wire protocol)
  - Port **8030** (HTTP API)
  - Port **9020** (RPC port, internal)

**Required Kubernetes NetworkPolicy — All pods to S3**:
- All FE and CN pods must reach the S3 endpoint on the configured port (typically 443 or 9000 for MinIO)

### 7.3 Credential Management via HashiCorp Vault

**Decision**: All secrets are sourced from HashiCorp Vault using the Kubernetes auth method. Kubernetes Secrets are not the primary credential store for this deployment.

The same Vault Agent Sidecar pattern from the ClickHouse architecture applies:

#### Credentials Managed by Vault

| Credential | Used by | Vault path (example) |
|---|---|---|
| S3 access key + secret | FE and CN pods (shared-data S3 access) | `secret/starrocks/s3/credentials` |
| StarRocks user passwords | Client authentication | `secret/starrocks/users/{username}` |

#### Vault Injection Pattern

**Vault Agent Sidecar (init container)**

Vault Agent runs as an init container and writes rendered secret templates into a shared volume before the FE or CN container starts. The rendered output is a configuration drop-in file.

For FE (`fe.conf` drop-in):
```
# Rendered by Vault Agent
aws_s3_access_key = <rendered from Vault>
aws_s3_secret_key = <rendered from Vault>
```

For CN (`cn.conf` drop-in):
```
# Rendered by Vault Agent
aws_s3_access_key = <rendered from Vault>
aws_s3_secret_key = <rendered from Vault>
```

**Secret rotation**: StarRocks does not universally support hot-reload of S3 credentials on SIGHUP in all versions. The safe rotation procedure is a rolling pod restart. The PoC must validate the rotation procedure to confirm:
1. Whether `kill -HUP` on FE/CN triggers credential re-read
2. If not, whether a rolling restart procedure can be executed without query/ingest interruption

---

## 8. Risks and Limitations

### 8.1 Shared-Data Mode Maturity

**Risk**: StarRocks 3.x shared-data has been production-available since ~2023. It is less battle-tested than ClickHouse's S3-backed storage at scale, and the community body of production incident reports is smaller.

**Mitigation**:
- Run a PoC with production-representative data volumes (full 5B rows/day ingest rate, representative query mix)
- Validate S3 object lifecycle (S3 PUT/GET/DELETE patterns, object count growth over time)
- Validate partition drop + S3 cleanup under TTL

**Contrast with ClickHouse**: ClickHouse's S3-backed ReplicatedMergeTree has a larger production community but carries the zero-copy replication GC risk (ClickHouse Risk 8.7), which shared-data mode eliminates entirely. The immaturity risk of shared-data is lower severity than the data-loss risk of zero-copy replication.

### 8.2 Primary Key Merge-on-Write at Ingest Scale

**Risk**: The Primary Key table model deduplicates on INSERT (merge-on-write). Each incoming row with a duplicate primary key triggers a lookup in the Primary Key index and a row replacement. At 57,870 rows/sec with 10–20% duplicate rate (~5,787–11,574 row replacements/sec sustained), write-path CPU and memory overhead can degrade ingest throughput or increase write latency under heavy load.

**Mitigation**:
- PoC must sustain full 57,870 rows/sec ingest rate for ≥2 hours and measure CN CPU, memory, and write latency
- If write-path overhead is measurable, evaluate the Duplicate Key model as a fallback (no merge-on-write, but reintroduces transient duplicates — equivalent to ClickHouse's `ReplacingMergeTree`)
- Tune Routine Load `max_batch_rows` to reduce per-sub-task write amplification; increase `max_compaction_threads` in `cn.conf` if compaction falls behind under heavy ingest

**Contrast with ClickHouse**: ClickHouse `ReplacingMergeTree` has no write-path overhead — duplicates are accepted on INSERT and resolved at merge time. The trade-off is transient duplicates visible to queries. StarRocks eliminates transient duplicates at the cost of higher write-path overhead.

### 8.3 Routine Load Small File Accumulation

**Risk**: Routine Load fires sub-tasks on `max_batch_interval` seconds. If `max_batch_rows` is too small relative to ingest rate, each sub-task flush writes small rowsets to S3. CN nodes accumulate many small rowsets per partition, degrading query performance and increasing compaction pressure.

At ~57,870 rows/sec with `desired_concurrent_number = K` sub-tasks and `max_batch_interval = 10s`, each sub-task sees approximately `57,870 / K × 10` rows per flush. With K=6 sub-tasks, that is ~96,450 rows per flush — a reasonable rowset size. With K=20, that drops to ~28,935 rows per flush — potentially problematic at high partition counts.

**Mitigation**:
- Tune `desired_concurrent_number` to match Kafka partition count and CN availability
- Set `max_batch_rows` high enough that each sub-task produces rowsets of ≥100K rows
- Monitor rowset count per partition: `SELECT * FROM information_schema.be_tablets WHERE rowset_count > threshold`
- Background compaction handles rowset merging; adjust compaction thread pool if rowset accumulation is observed

**Contrast with ClickHouse**: ClickHouse's equivalent is `kafka_max_block_size` tuning to prevent "too many parts". The recommended ClickHouse value is 1,048,576 rows per block. The same principle applies to StarRocks Routine Load.

### 8.4 StarRocks Pipe Maturity

**Risk**: The Pipe feature was introduced in StarRocks 3.2 and is newer than ClickHouse's S3Queue. Retry behavior, exactly-once semantics (vs. at-least-once + Primary Key dedup), and behavior under FE leader failover mid-load must be validated in PoC.

**Mitigation**:
- PoC must validate: successful file loads, failure + retry behavior, FE leader failover mid-load, and file deduplication (no double-load of successfully loaded files)
- Run with production-representative file sizes and arrival rates
- Validate that Primary Key dedup covers any at-least-once re-delivery edge cases

**Contrast with ClickHouse**: ClickHouse S3Queue is production-mature. If Pipe behavior is found to be unsatisfactory, evaluate `INSERT INTO ... SELECT * FROM FILES(...)` with manual file tracking as an alternative.

### 8.5 FE as Multi-Role Single Point of Failure

**Risk**: FE quorum loss simultaneously halts all DDL, all DML (INSERT/UPDATE/DELETE), all Routine Load sub-task scheduling, all Pipe monitoring, and all query routing. This is the same blast radius as ClickHouse Keeper quorum loss.

**Mitigation**:
- Run FE pods on dedicated Kubernetes nodes with pod anti-affinity
- Spread FE pods across distinct availability zones
- Monitor FE leader health; alert on leader absence within ≤30 seconds
- Consider 5-node FE for extra fault tolerance (see [Open Decision #3](#9-open-decisions))

**Contrast with ClickHouse**: ClickHouse Keeper quorum loss halts replication, S3Queue, and zero-copy GC simultaneously. FE quorum loss has equivalent scope. Neither system avoids this class of single point of failure at the coordination layer — they differ in the underlying technology (BDB-JE vs. Keeper/Raft) but not in the operational criticality.

### 8.6 kube-starrocks Operator Maturity

**Risk**: The kube-starrocks operator is less mature than the Altinity ClickHouse Operator. Operator behavior for rolling upgrades, FE leader failover during upgrades, secret injection, and multi-AZ pod scheduling must be explicitly validated.

**Mitigation**:
- Pin to a specific operator version; validate against the target StarRocks version in the PoC
- Validate: FE rolling upgrade (no quorum loss), CN rolling upgrade (no data unavailability), secret injection from Vault Agent Sidecar, pod anti-affinity enforcement
- Subscribe to operator release notes; test upgrades in staging before production

**Contrast with ClickHouse**: The Altinity ClickHouse Operator 0.26.0+ is a more mature product with a larger production community. Operator risk is higher on the StarRocks side at present.

### 8.7 S3 Availability Equals Write Availability

**Risk**: In shared-data mode, all writes go to S3 on INSERT. S3 unavailability means INSERT unavailability. NVMe data cache is not written on INSERT (see [Section 5.4](#54-write-path-cache-population)), so there is no local write buffer that can absorb S3 outages.

**Mitigation**: Same as ClickHouse — S3 HA must be in place before claiming write HA. See [Section 6.4](#64-s3-ha).

**Contrast with ClickHouse**: Same risk with the same severity. Both architectures require S3 HA before claiming full production HA.

### 8.8 Compaction for Physical Compliance Delete

**Risk**: Physical S3 byte removal for user-ID deletes requires compaction. `ALTER TABLE t COMPACT` forces compaction but is I/O intensive and contends with query and ingest workloads on the same CN nodes.

The 24-hour physical deletion SLA (if required — see [Open Decision #11](#9-open-decisions)) requires compaction of all partitions containing rows for the deleted `user_id` to complete within 24 hours. At production data volumes (~714M rows per partition), compaction time per partition must be measured in PoC.

**Mitigation**:
- PoC must measure `ALTER TABLE t COMPACT PARTITION p_YYYYMMDD` duration for a partition containing ~714M rows
- If compaction is too slow, schedule compaction at off-peak hours or use Resource Groups to limit compaction I/O impact on query workloads
- For time-based expiry: partition drop (`DROP PARTITION`) immediately removes all S3 objects — no compaction needed; the 24-hour TTL SLA is straightforwardly achievable with daily partitions

**Improvement over ClickHouse**: StarRocks compaction operates at the **tablet level** (finer granularity than ClickHouse's partition-level rewrite). Tablets within a partition can compact concurrently across multiple CN nodes. This makes compaction generally faster and more parallelizable than ClickHouse's `OPTIMIZE TABLE PARTITION FINAL`, which rewrites each partition serially on a single replica. However, PoC measurement at production partition sizes is required before this advantage can be quantified.

**Contrast with ClickHouse**: ClickHouse requires `OPTIMIZE TABLE PARTITION FINAL` for both logical inaccessibility and physical byte removal after a `DELETE`. StarRocks satisfies logical inaccessibility immediately on `DELETE`; only physical byte removal requires compaction. The compliance SLA gap (if any) is smaller and the feasibility window is wider.

---

## 9. Open Decisions

The following decisions must be resolved before YAML authoring and PoC validation begins. Numbering is aligned with the ClickHouse architecture open decisions where equivalent.

| # | Decision | Blocks | ClickHouse Equivalent |
|---|---|---|---|
| 1 | S3 backend: MinIO or NetApp | Storage config, CN YAML | Decision #1 (identical) |
| 2 | MinIO HA configuration: node count, EC setting | S3 HA validation | Decision #2 (identical) |
| 3 | FE node count: 3 (standard) or 5 (extra fault tolerance)? 3 tolerates 1 failure; 5 tolerates 2 failures | FE YAML | Decision #4 (Keeper node count) |
| 4 | Kubernetes namespace strategy: shared namespace or dedicated StarRocks namespace? | Operator YAML, NetworkPolicy | Decision #3 (K8s namespace) |
| 5 | Distribution key column: which column for `DISTRIBUTED BY HASH(col)`? | Table DDL | Decision #7 (sharding key column) |
| 6 | Partition expression: daily by `event_date` confirmed — validate `date_trunc('DAY', event_date)` expression | Table DDL | Decision #5 (partition key — confirmed in CH) |
| 7 | NVMe data cache sizing: `datacache_disk_size` per CN | CN pod sizing | Decision #8 (row size → cache sizing) |
| 8 | Bucket count per table partition: `BUCKETS N` in CREATE TABLE. Rule of thumb: 3× CN count = 21 for 7 CNs. Tune based on partition data size | Table DDL | No direct equivalent (CH uses shards) |
| 9 | Routine Load parallelism: `desired_concurrent_number` — how many concurrent sub-tasks? Must balance Kafka partition count and CN resource availability | Routine Load DDL | Decision #10 (Kafka partition count drives this) |
| 10 | Kafka topic partition count: must be ≥ `desired_concurrent_number`; multiple of sub-task count for even distribution | Routine Load DDL | Decision #10 (identical) |
| 11 | User-ID compliance SLA: physical byte removal (requires compaction within 24h) or logical inaccessibility (immediately satisfied by DELETE)? | Compliance SLA validation | Decision #11 (same legal question; logical inaccessibility is *immediately* satisfied in StarRocks, unlike ClickHouse) |
| 12 | Write-path cache population: does `datacache_populate_mode = auto` ensure sufficient cache warmth for newly ingested data? If not, what is the hot-data guarantee? | Storage design | Decision #12 (zero-copy vs full replication — eliminated in StarRocks; replaced by this cache warmth question) |

---

## 10. Recommended Versions

| Component | Recommended Version | Notes |
|---|---|---|
| StarRocks Server | **3.3.x** (latest 3.3 patch) | Minimum: 3.2 (Pipe feature required). 3.3 includes shared-data stability improvements. Validate LTS status before production |
| kube-starrocks operator | **latest stable** compatible with target StarRocks version | Validate operator ↔ StarRocks version matrix in operator release notes; test in PoC |
| MinIO | Latest available (min: 2021-09-23 for strong consistency) | If MinIO is selected — same requirement as ClickHouse architecture |
| HashiCorp Vault | As per existing organizational standard | No version constraint specific to StarRocks |
| Kubernetes | ≥1.24 | Operator requires standard PVC, StatefulSet, and Service features |

---

## 11. Implementation Roadmap

The implementation sequence mirrors the ClickHouse roadmap but reflects the simplified topology (no separate ingest cluster, no Keeper):

### Phase 1 — FE Cluster (Prerequisite)
- Deploy 3 FE pods via kube-starrocks operator
- Validate FE HA: kill leader → confirm follower election and recovery
- Validate Vault Agent Sidecar secret injection (S3 credentials in `fe.conf`)
- Validate kube-starrocks operator rolling upgrade behavior (no quorum loss)

### Phase 2 — CN PoC (1 CN, Shared-Data)
- Deploy 1 CN pod; configure `datacache_enable = true` and `datacache_disk_path`
- Create Primary Key table (1 bucket, daily partition)
- Run manual INSERT at low volume; validate S3 write path and data cache population
- Validate `DELETE WHERE user_id = X` immediate logical inaccessibility
- Validate `ALTER TABLE COMPACT` and observe compaction duration

### Phase 3 — Routine Load Validation
- Connect Routine Load to Kafka topic
- Run at full ingest rate (57,870 rows/sec) for ≥2 hours
- Measure: ingest latency, rowset accumulation rate, Primary Key merge-on-write overhead
- Tune `desired_concurrent_number` and `max_batch_rows`
- Validate at-least-once + Primary Key dedup (simulate consumer re-delivery)

### Phase 4 — Pipe Validation
- Create Pipe pointing at S3 source bucket
- Validate file tracking (no double-load on retry), failure/retry behavior
- Simulate FE leader failover mid-load; confirm Pipe resumes cleanly

### Phase 5 — Scale CN to 7 Nodes
- Add remaining 6 CN pods; observe FE tablet redistribution
- Validate no data loss or query errors during scale-out
- Run full ingest + query workload; measure resource utilization across all CNs

### Phase 6 — Compliance and Credential Rotation
- Validate nightly `DELETE WHERE user_id = X` timing at production partition sizes
- Measure `ALTER TABLE COMPACT PARTITION` duration per partition (~714M rows)
- Validate nightly `UPDATE` operation timing
- Validate Vault credential rotation procedure (SIGHUP or rolling restart)
- Validate partition TTL drop + S3 object cleanup within 24 hours

---

## 12. Scalability Considerations

### 12.1 Ingest Tier

**Current capacity**: 7 CNs × Routine Load throughput = ~57,870 rows/sec target. Routine Load parallelism is bounded by Kafka partition count and `desired_concurrent_number`.

**Scale-out path**: Add CNs (see [Section 12.2](#122-cn-horizontal-scaling)) to increase Routine Load sub-task execution capacity. Increase `desired_concurrent_number` if Kafka partition count allows. Kafka partition count is the ceiling for Routine Load parallelism.

**Bottleneck signals**: Routine Load sub-task queue depth increasing; sub-task execution time growing; Kafka consumer lag increasing despite active sub-tasks.

### 12.2 CN Horizontal Scaling

> **Improvement over ClickHouse**: ClickHouse scale-out requires adding new shard(s) and manually migrating data from existing shards — a multi-hour operation that may require downtime or careful coordination. StarRocks shared-data mode scales out by adding CN pods; FE automatically redistributes tablets to the new CNs. No manual data migration is required.

**Scale-out procedure**:
1. Add a new CN pod via kube-starrocks operator (update CN replicas in StarRocksCluster CR)
2. FE detects new CN and begins reassigning tablets to it
3. Tablet redistribution is transparent to queries and ingest — the system continues operating during rebalance
4. New CN begins warming its NVMe data cache as tablets are accessed

**Scale limit**: Shared-data mode scales to tens of CN nodes. The practical upper limit is governed by FE metadata capacity (tablet count per partition × partition count × table count) and S3 throughput.

### 12.3 FE Concurrency

**Current capacity**: 3 FE nodes handle query planning, Routine Load management, and Pipe monitoring. Under high query concurrency, FE CPU and memory (for intermediate result aggregation) become the bottleneck.

**Scale-out path**: Add FE follower nodes. FE followers can serve SELECT queries (read queries). This distributes query coordination load without affecting the 3-node quorum for DDL/DML.

**Bottleneck signals**: FE CPU sustained >70%; FE memory approaching JVM heap limit; query planning latency increasing; connection queue depth increasing at FE.

### 12.4 S3 Storage

S3 storage scales automatically with the backend. For MinIO, add nodes and drives. For NetApp, provision additional capacity per storage team procedures. No StarRocks-side changes are needed.

**S3 throughput** scales with MinIO node count (distributed erasure-coded mode provides proportional throughput). At 5B rows/day, S3 write bandwidth is the primary throughput concern; budget accordingly based on measured row size (see [Open Decision #7](#9-open-decisions)).

### 12.5 Query Concurrency

FE handles concurrent query planning. CN handles concurrent fragment execution. Resource Groups can limit the resources allocated to Routine Load vs query workloads to prevent starvation:

```sql
CREATE RESOURCE GROUP ingest_rg
PROPERTIES (
    "cpu_core_limit" = "4",
    "mem_limit" = "8589934592"  -- 8 GB
);

CREATE RESOURCE GROUP query_rg
PROPERTIES (
    "cpu_core_limit" = "12",
    "mem_limit" = "25769803776"  -- 24 GB
);
```

Use `CLASSIFY ... TO GROUP` to route Routine Load sub-tasks to `ingest_rg` and user queries to `query_rg`.

### 12.6 Compliance Delete Scalability

**Time-based expiry (partition drop)**:
- Partition drop is O(1) relative to partition data size — FE drops the partition metadata and S3 objects are deleted. No data rewrite occurs.
- Scales linearly with partition count, not with data volume
- 24-hour physical deletion SLA is straightforwardly achievable with daily partitions

**User-ID row-level deletes**:

The compliance window depends on how many users are in the nightly batch and how long compaction takes per affected partition.

| Users per night | Affected partitions (typical) | Compaction tasks | 24h feasibility |
|---|---|---|---|
| ≤5 | ≤5 × retention_days | Parallelizable across CNs | Feasible if per-partition compaction ≤ 24h / partition_count |
| ~10 | ~10 × retention_days | Higher parallelism needed | Likely feasible with full compaction thread pool |
| >10 | Grows with retention | May contend with query workload | Requires PoC measurement; Resource Group isolation recommended |

> **Improvement over ClickHouse**: ClickHouse `OPTIMIZE TABLE PARTITION FINAL` rewrites each partition serially on each replica. StarRocks compaction is distributed across CN tablets and parallelizable at finer granularity. The compliance delete feasibility window is wider, but the same fundamental challenge (compaction time scales with data volume) applies.

The same open question from ClickHouse Decision #11 applies: the legal/compliance team must confirm whether the 24-hour SLA requires physical byte removal (compaction) or logical inaccessibility (immediately satisfied by `DELETE`). If logical inaccessibility is sufficient, StarRocks satisfies this requirement trivially with no time constraint concern.

### 12.7 Operational Scalability

**Monitoring**: StarRocks exposes Prometheus metrics from both FE (port 8030/metrics) and CN (port 8040/metrics). Standard Kubernetes monitoring stacks (Prometheus + Grafana) apply directly.

**Log management**: FE and CN write structured logs. Route to the organizational log aggregation platform via standard Kubernetes log forwarding.

**Upgrade path**: kube-starrocks operator rolling upgrades. Validate in staging before production. FE upgrades first (leader → followers), then CN rolling upgrade.

### 12.8 Scalability Summary

| Dimension | Current capacity | Scale-out path | ClickHouse equivalent |
|---|---|---|---|
| Ingest rate | ~57,870 rows/sec (7 CNs) | Add CNs; increase Routine Load parallelism | Add ingest shard pods |
| Storage capacity | Unlimited (S3-backed) | S3 backend scales independently | S3-backed; same |
| Query concurrency | FE-bound at high concurrency | Add FE follower nodes | Add cache nodes (heavier) |
| CN compute | 7 CNs | Add CNs; automatic tablet redistribution | Add shards (manual migration required) |
| Compliance delete | Compaction per partition | Parallelize across CNs; Resource Groups | `OPTIMIZE PARTITION FINAL` per replica |

---

## 13. Configuration Reference

### Table DDL (Primary Key Model)

```sql
CREATE TABLE events (
    event_id        BIGINT          NOT NULL,
    user_id         BIGINT          NOT NULL,
    event_date      DATE            NOT NULL,
    eviction_date   DATE            NOT NULL,
    event_ts        DATETIME        NOT NULL,
    -- ... other columns ...
    PRIMARY KEY (event_id)
)
ENGINE = OLAP
PRIMARY KEY (event_id)
COMMENT "Event analytics table"
PARTITION BY RANGE(event_date) (
    -- dynamic partitions auto-created
)
DISTRIBUTED BY HASH(event_id) BUCKETS 21   -- 3 × 7 CNs; see Open Decision #8
ORDER BY (event_id)
PROPERTIES (
    "replication_num" = "1",               -- shared-data: no replica replication needed
    "storage_volume" = "s3_volume",        -- refers to configured S3 storage volume
    "enable_persistent_index" = "true",
    "persistent_index_type"   = "CLOUD_NATIVE",  -- stores Primary Key index in S3 (required for CN/shared-data mode)
    "datacache_enable" = "true",
    "datacache_partition_duration" = "7 DAY",  -- keep last 7 days hot in NVMe cache
    "dynamic_partition.enable" = "true",
    "dynamic_partition.time_unit" = "DAY",
    "dynamic_partition.start" = "-90",
    "dynamic_partition.end" = "3",
    "dynamic_partition.prefix" = "p",
    "dynamic_partition.buckets" = "21",
    "partition_ttl" = "90 DAY"             -- auto-drop partitions older than 90 days
);
```

### S3 Storage Volume DDL

```sql
-- Run once during cluster setup
CREATE STORAGE VOLUME s3_volume
TYPE = S3
LOCATIONS = ("s3://bucket/starrocks")
PROPERTIES (
    "enabled" = "true",
    "aws.s3.region" = "us-east-1",
    "aws.s3.endpoint" = "http://minio-service:9000",
    "aws.s3.access_key" = "${AWS_ACCESS_KEY}",     -- injected by Vault Agent
    "aws.s3.secret_key" = "${AWS_SECRET_KEY}"       -- injected by Vault Agent
);

SET DEFAULT STORAGE VOLUME s3_volume;
```

### Routine Load DDL

```sql
CREATE ROUTINE LOAD db_name.events_kafka_load ON events
COLUMNS TERMINATED BY ",",
ROWS TERMINATED BY "\n"
PROPERTIES (
    "desired_concurrent_number" = "6",      -- see Open Decision #9
    "max_batch_rows" = "500000",            -- tune to avoid small rowset accumulation
    "max_batch_interval" = "10",            -- seconds
    "max_error_number" = "1000"
)
FROM KAFKA (
    "kafka_broker_list" = "kafka-broker:9092",
    "kafka_topic" = "events_topic",
    "kafka_partitions" = "0,1,2,3,4,5",
    "kafka_offsets" = "OFFSET_BEGINNING"
);
```

### Pipe DDL (S3 File Ingest)

```sql
CREATE PIPE events_s3_pipe
PROPERTIES (
    "auto_ingest" = "true",
    "poll_interval" = "60"          -- seconds between S3 path checks
)
AS INSERT INTO events
SELECT *
FROM FILES(
    "path" = "s3://source-bucket/events/",
    "format" = "parquet",           -- or csv, json
    "aws.s3.endpoint" = "http://minio-service:9000",
    "aws.s3.access_key" = "${AWS_ACCESS_KEY}",
    "aws.s3.secret_key" = "${AWS_SECRET_KEY}"
);
```

### Compliance Operations

```sql
-- Time-based expiry: handled automatically by partition_ttl in table PROPERTIES
-- No manual action required; StarRocks drops expired partitions and their S3 objects

-- User-ID logical deletion (immediate effect)
DELETE FROM events WHERE user_id = 12345;

-- Physical byte removal (compaction — equivalent to OPTIMIZE TABLE PARTITION FINAL)
-- Run after logical deletion if physical removal SLA is required
ALTER TABLE events COMPACT PARTITION p20240101;

-- Nightly field-level UPDATE
UPDATE events
SET consent_status = 'withdrawn'
WHERE user_id IN (SELECT user_id FROM nightly_update_batch);
```

### CN Configuration (`cn.conf` key settings)

```properties
# Data cache (NVMe SSD)
datacache_enable = true
datacache_disk_path = /path/to/nvme/datacache
datacache_disk_size = <TBD GB>          # see Open Decision #7
datacache_populate_mode = auto          # see Open Decision #12

# S3 credentials (injected by Vault Agent Sidecar)
aws_s3_access_key = <rendered by Vault>
aws_s3_secret_key = <rendered by Vault>
aws_s3_endpoint = http://minio-service:9000
aws_s3_region = us-east-1
```

### FE Configuration (`fe.conf` key settings)

```properties
# S3 credentials (injected by Vault Agent Sidecar)
aws_s3_access_key = <rendered by Vault>
aws_s3_secret_key = <rendered by Vault>
aws_s3_endpoint = http://minio-service:9000
aws_s3_region = us-east-1

# JVM heap (tune based on concurrent query count and result set sizes)
JAVA_OPTS = "-Xmx16g -Xms16g"
```

### Cache Hit Monitoring

```sql
-- Data cache stats per CN
SELECT * FROM information_schema.datacache_stats;

-- Routine Load job status
SHOW ROUTINE LOAD FOR events_kafka_load;

-- Pipe status
SHOW PIPES;

-- Compaction status
SHOW PROC '/compactions';
```

---

*Document status: Architecture design — open decisions pending (see Section 9). YAML authoring begins after all open decisions are resolved and PoC phases 1–6 are validated.*

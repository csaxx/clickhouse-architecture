# StarRocks for ClickHouse Practitioners

A technical guide for engineers with production ClickHouse experience who need to understand StarRocks deeply — not just at the architecture level, but as a mental model shift.

This guide maps every ClickHouse concept to its StarRocks equivalent, shows side-by-side DDL for all key objects drawn from this repository's actual SQL files, and gives an honest assessment of where StarRocks improves on ClickHouse and where it falls short. For deployment details (pod counts, resource specs, operator config), see `starrocks-architecture.md`. This document teaches the concepts.

---

## Table of Contents

1. [TL;DR Comparison Table](#1-tldr-comparison-table)
2. [Architecture Mental Model](#2-architecture-mental-model)
3. [Table Models (Engines)](#3-table-models-engines)
4. [Data Organization: Parts vs Tablets](#4-data-organization-parts-vs-tablets)
5. [Storage Architecture](#5-storage-architecture)
6. [Kafka Ingest: KafkaEngine vs Routine Load](#6-kafka-ingest-kafkaengine-vs-routine-load)
7. [S3 File Ingest: S3Queue vs Pipe](#7-s3-file-ingest-s3queue-vs-pipe)
8. [Materialized Views: A Fundamental Difference](#8-materialized-views-a-fundamental-difference)
9. [Query Execution Model](#9-query-execution-model)
10. [DML: INSERT, UPDATE, DELETE, UPSERT](#10-dml-insert-update-delete-upsert)
11. [Operations and Administration](#11-operations-and-administration)
12. [Advantages of StarRocks over ClickHouse](#12-advantages-of-starrocks-over-clickhouse)
13. [Disadvantages / Trade-offs vs ClickHouse](#13-disadvantages--trade-offs-vs-clickhouse)
14. [Decision Framework](#14-decision-framework)

---

## 1. TL;DR Comparison Table

Scan this table first to locate the dimensions most relevant to you, then go to the detailed section.

| Dimension | ClickHouse (this architecture) | StarRocks (this architecture) |
|---|---|---|
| **Topology** | 3 concerns: ingest cluster + cache cluster + Keeper | 2 tiers: FE (control) + CN (compute+cache) |
| **Pod count** | 19–21 pods | 10 pods |
| **Coordination service** | ClickHouse Keeper (3–5 pods, replaces ZooKeeper) | FE internal (BDB-JE); no separate coordination cluster |
| **Storage engine / model** | ReplicatedReplacingMergeTree(ver) | PRIMARY KEY table (merge-on-write) |
| **Deduplication timing** | Merge-time; transient duplicates visible until next background merge | Insert-time; no transient duplicates at any point |
| **`SELECT ... FINAL`** | Available workaround to force merge-on-read dedup; 2–3× slower; **should be avoided** | Not needed; queries always see deduplicated data |
| **Kafka ingest** | 3 objects: KafkaEngine table + Materialized View + Distributed table | 1 object: `CREATE ROUTINE LOAD` |
| **S3 file ingest** | 2 objects: S3Queue table + Materialized View | 1 object: `CREATE PIPE` |
| **Materialized View approach** | Trigger-based (fires on INSERT); used as ingest pipeline glue | Async refresh jobs; transparent query rewrite (3.x) |
| **Query coordination** | Distributed table fans out to shards; each shard returns partial results | FE generates MPP query plan; CNs exchange intermediate results |
| **Horizontal scaling** | Cache resharding: multi-hour manual operation at 5B rows/day | CN addition triggers automatic tablet redistribution |
| **Compliance DELETE** | Lightweight delete (logical); rows visible until `OPTIMIZE PARTITION FINAL` | Immediate logical inaccessibility; physical via `ALTER TABLE COMPACT` |
| **Native UPDATE/UPSERT** | No (workarounds: patch parts, ALTER TABLE UPDATE) | Yes (Primary Key model — first-class operations) |
| **Zero-copy replication** | `allow_remote_fs_zero_copy_replication = 1`; documented GC data loss risk | Not applicable; shared-data mode has no replica-level replication |
| **Write-path NVMe cache** | `cache_on_write_operations = 1` → write-through always | Default read-through; `datacache_populate_mode = auto` closes gap partially |
| **SQL protocol** | Custom ClickHouse SQL; HTTP + native TCP; custom drivers required | MySQL-compatible (port 9030); standard SQL tooling works |
| **JOIN performance** | Designed for single-table wide-format scans; multi-table JOINs are weak | MPP optimizer handles multi-table JOINs well; colocate joins supported |
| **Operator** | Altinity Operator 0.26.0+ (mature, battle-tested) | kube-starrocks (less mature; PoC validation required) |
| **Ingest cluster** | Required (separate 2-pod cluster + Distributed write tables) | Not needed; Routine Load sub-tasks run directly on CN nodes |
| **Function library** | Very large (HLL, bitmap, specialized time-series codecs, string ops) | Smaller but growing; MySQL-standard functions available |
| **Column compression** | Custom codecs (Delta, DoubleDelta, Gorilla) tuned for time-series | LZ4, Zstd, Snappy; no custom time-series codecs |

---

## 2. Architecture Mental Model

### ClickHouse: Three Separate Concerns

The ClickHouse architecture in this repository separates three distinct concerns into separate components:

```
┌─────────────────────────────────────────────────────────────────┐
│  INGEST CLUSTER (2 pods: 2 shards × 1 replica)                 │
│  KafkaEngine / S3Queue → MV transforms → Distributed INSERT     │
│  Concern: message consumption, transformation, routing          │
└──────────────────────────────┬──────────────────────────────────┘
                               │ cross-cluster INSERT via cache_writer
┌──────────────────────────────▼──────────────────────────────────┐
│  CACHE CLUSTER (14 pods: 7 shards × 2 replicas)                │
│  ReplicatedReplacingMergeTree + S3 backend + NVMe cache         │
│  Concern: durable storage, deduplication, query execution        │
└──────────────────────────────┬──────────────────────────────────┘
                               │ distributed coordination (Keeper paths,
                               │ replica metadata, S3Queue file state)
┌──────────────────────────────▼──────────────────────────────────┐
│  CLICKHOUSE KEEPER (3–5 pods)                                   │
│  Concern: distributed consensus, replica sync, table metadata   │
└─────────────────────────────────────────────────────────────────┘
```

Every `ON CLUSTER 'cache'` or `ON CLUSTER 'ingest'` DDL statement is a reminder that you are explicitly routing DDL to a named cluster. Cross-cluster writes require a `Distributed` table on the ingest side pointing to the cache cluster. Query fanout requires a `Distributed` query table on the cache cluster.

### StarRocks: Two Tiers

StarRocks collapses these three concerns into two tiers:

```
┌─────────────────────────────────────────────────────────────────┐
│  FE NODES (3 pods, quorum: 1 leader + 2 followers)             │
│  - DDL execution and metadata storage (BDB-JE, replicated)      │
│  - Query parsing, planning, and coordination                    │
│  - Routine Load job management (replaces ingest cluster)        │
│  - Pipe job management (replaces S3Queue + MV)                  │
│  - Kafka offset tracking (replaces consumer group manual setup) │
│  Replaces: ingest cluster logic + Keeper coordination           │
└──────────────────────────────┬──────────────────────────────────┘
                               │ tablet assignments, load tasks,
                               │ query plan fragments
┌──────────────────────────────▼──────────────────────────────────┐
│  CN NODES (7 pods)                                              │
│  - Tablet storage on S3 (shared-data mode)                      │
│  - Local NVMe data cache (transparent LRU)                      │
│  - Routine Load sub-task execution (ingest)                     │
│  - Query plan fragment execution                                │
│  Replaces: cache cluster storage + ingest cluster consumers     │
└─────────────────────────────────────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────┐
│  S3 BACKEND (MinIO or NetApp)                                   │
│  Primary source of truth for all tablet data                    │
└─────────────────────────────────────────────────────────────────┘
```

### The "Distributed Table" Mental Model Shift

In ClickHouse, you write a `Distributed` table because ClickHouse nodes are independent — they do not know about each other unless you explicitly configure cluster topology and create Distributed tables over it. The `Distributed` engine is the mechanism by which ClickHouse achieves fan-out writes and fan-in query results.

StarRocks has no `Distributed` table concept because the FE is a unified control plane that maintains a global metadata view of all tablets across all CNs. When you write `INSERT INTO events`, the FE already knows which tablets exist, which CNs host them, and routes the write accordingly. When you run a `SELECT`, the FE generates an MPP plan that addresses specific tablets on specific CNs. The routing is transparent and automatic.

This means:
- No `ON CLUSTER 'cache'` suffix on DDL — FE applies DDL globally.
- No `cache_distributed` table for query fan-out.
- No `cache_writer` table for cross-cluster INSERT.
- No `kafka_group_name = 'clickhouse_ingest_{shard}'` macro to prevent consumer group collision.

### Pod Count Arithmetic

| Component | ClickHouse | StarRocks |
|---|---|---|
| Coordination | 3–5 Keeper pods | 0 (FE internal BDB-JE) |
| Ingest layer | 2 ingest pods (2 shards × 1 replica) | 0 (Routine Load on CNs) |
| Storage/compute | 14 cache pods (7 shards × 2 replicas) | 7 CN pods |
| Control plane | 0 (no dedicated FE) | 3 FE pods |
| **Total** | **19–21 pods** | **10 pods** |

The 2× storage pod count in ClickHouse exists because of replica replication. In StarRocks shared-data mode, S3 provides durability; `replication_num = 1` means each tablet is assigned to one CN for compute. There is no CN-to-CN replication.

---

## 3. Table Models (Engines)

### ClickHouse: Engine Zoo

ClickHouse has many storage engines. The ones relevant to this architecture:

| Engine | Role | Notes |
|---|---|---|
| `MergeTree` | Base append-only engine | No dedup; background merge combines parts |
| `ReplicatedReplacingMergeTree(ver)` | Dedup at merge time; `ver` column picks winner | Transient duplicates between INSERT and merge |
| `AggregatingMergeTree` | Pre-aggregate at merge time | Stores `AggregateFunction` states |
| `Kafka` (KafkaEngine) | Streaming connector, not storage | Must pair with MV to consume |
| `S3Queue` | S3 file connector, not storage | Must pair with MV to process |
| `Distributed` | Routing table (not storage) | Fan-out writes and query merging across shards |

### StarRocks: Four Table Models

StarRocks has four table models that cover all of the above:

| Model | Dedup | Writes | Equivalent |
|---|---|---|---|
| **Duplicate Key** | None | Fast append | `MergeTree` |
| **Aggregate Key** | Pre-aggregates on flush | Moderate | `AggregatingMergeTree` |
| **Unique Key** | Merge-on-write or merge-on-read | Slower than Duplicate | `ReplacingMergeTree` (roughly) |
| **Primary Key** | Merge-on-write; full DML (UPDATE/DELETE) | Lookup overhead | No direct CH equivalent |

This architecture uses **Primary Key** for all storage. There is no separate ingest connector engine — Routine Load and Pipe are job-level constructs, not engine-level objects.

### PRIMARY KEY vs ReplicatedReplacingMergeTree: Deep Comparison

This is the most important engine-level difference to understand.

**ClickHouse ReplicatedReplacingMergeTree(ver)**:
- Deduplication key = `ORDER BY` columns (the sort key is the dedup key).
- The `ver` column determines which row wins when duplicates are collapsed — highest `ver` survives.
- Deduplication happens **at merge time** (background process). From INSERT until the next merge that covers both parts, both rows are present and queryable.
- `SELECT ... FINAL` forces merge-on-read to suppress transient duplicates, but costs 2–3× query time.
- This architecture explicitly documents: **FINAL must NOT be used** in production queries.

```sql
-- ClickHouse: dedup key = ORDER BY; ver column picks winner; dedup at merge time
ENGINE = ReplicatedReplacingMergeTree(
    '/clickhouse/tables/{cluster}/{shard}/cache_db/cache_table',
    '{replica}',
    _ver          -- row with highest _ver is kept when duplicates collapse at merge
)
ORDER BY (user_id, event_ts)  -- this IS the dedup key
```

**StarRocks PRIMARY KEY**:
- Deduplication key = `PRIMARY KEY` columns (separate declaration, not the sort key).
- Newest row **always wins** unconditionally — there is no `ver` column. The incoming row replaces the stored row on INSERT.
- Deduplication happens **on INSERT** (merge-on-write). The lookup cost is paid at write time, not read time.
- No transient duplicates at any point. No `FINAL` equivalent needed.
- `ORDER BY` is an independent sort key within a tablet (affects scan performance but is not the dedup key).

```sql
-- StarRocks: dedup key = PRIMARY KEY; newest row wins; dedup on INSERT
ENGINE = OLAP
PRIMARY KEY (event_id)           -- this IS the dedup key (separate from ORDER BY)
ORDER BY (event_id)              -- sort key within a tablet (query performance)
```

**Trade-off summary**:

| Aspect | ClickHouse ReplacingMergeTree | StarRocks Primary Key |
|---|---|---|
| Dedup timing | Background merge (lazy) | INSERT time (eager) |
| Transient duplicates | Yes — visible between INSERT and merge | No |
| Write-path overhead | Zero (dedup deferred) | Lookup cost per duplicate row at INSERT |
| Read-path overhead | `FINAL` = 2–3× slower; avoid without FINAL | Zero (data always deduplicated) |
| Version column | Required (`ver`) | Not needed (newest wins unconditionally) |
| `FINAL` equivalent | Required for guaranteed dedup | Not needed |

At 57,870 rows/sec with 10–20% duplicate rate (~5,787–11,574 duplicate rows/sec), the Primary Key write-path lookup overhead must be validated in PoC. The ClickHouse write path has zero dedup overhead at this rate; StarRocks pays a lookup cost on every duplicate.

---

## 4. Data Organization: Parts vs Tablets

### ClickHouse: Part / Merge Model

When you INSERT into a MergeTree table, ClickHouse writes an immutable **part** — a directory of column files in S3. Background **merge threads** (`background_pool_size`) periodically merge smaller parts into larger ones. `PARTITION BY` creates logical containers; parts within a partition are what get merged together.

```
Partition p20240115 (PARTITION BY toYYYYMMDD(event_date))
  ├── part_001/    ← written on first INSERT batch
  ├── part_002/    ← written on second INSERT batch
  ├── part_003/    ← background merge of part_001 + part_002
  └── ...
```

Key concepts:
- **Part accumulation ("too many parts")**: if INSERTs create parts faster than merges can combine them, ClickHouse throws `Too many parts` errors and blocks writes. At Kafka ingest rates, `kafka_max_block_size = 1048576` (1M rows per batch) prevents this by creating fewer, larger parts.
- **`ORDER BY`** = primary key / sort key within a part. Column data within a part is sorted by this key. Determines range scan efficiency.
- **Background pool**: merge threads compete with queries for I/O; `background_pool_size` must be tuned alongside query concurrency.
- **Parts in S3**: in this architecture, each part is a set of S3 objects. Merges read from S3, write merged output to S3, and then delete the constituent parts.

### StarRocks: Tablet / Rowset / Compaction Model

StarRocks uses different terminology for equivalent concepts:

| ClickHouse concept | StarRocks equivalent |
|---|---|
| Part | Rowset |
| Partition (`PARTITION BY`) | Partition (`PARTITION BY RANGE`) |
| Background merge | Compaction (cumulative + base) |
| Merge pool / `background_pool_size` | CN compaction threads |
| "Too many parts" problem | "Small file / rowset accumulation" |
| Part directory in S3 | Tablet segment objects in S3 |

**Tablet** is the key concept that has no direct ClickHouse equivalent. A tablet is the unit of data distribution and compaction within a partition. Each partition has `BUCKETS N` tablets. Tablets from the same partition can reside on different CNs.

```
Partition p20240115 (PARTITION BY RANGE(event_date))
  ├── tablet_0/   ← rows where hash(event_id) % 21 == 0  → assigned to CN-3
  ├── tablet_1/   ← rows where hash(event_id) % 21 == 1  → assigned to CN-5
  ├── ...
  └── tablet_20/  ← rows where hash(event_id) % 21 == 20 → assigned to CN-1
```

Each tablet contains one or more **rowsets** — immutable objects written on INSERT (equivalent to ClickHouse parts). **Compaction** merges rowsets within a tablet into larger rowsets, equivalent to ClickHouse background merges. There are two compaction types:
- **Cumulative compaction**: merges small rowsets into medium rowsets (analogous to frequent small merges).
- **Base compaction**: merges medium rowsets into the large base rowset (analogous to major merges).

### Key Conceptual Difference: Shard-Level vs Tablet-Level Distribution

ClickHouse distributes data at the **shard level** — each shard (node or node pair) is responsible for a partition of the keyspace. The sharding function (`xxHash64(sharding_column) % shard_count`) is defined at the Distributed table level and determines which node receives each row.

StarRocks distributes at the **tablet level** — within each partition, rows are hashed to tablets by `DISTRIBUTED BY HASH(col)`. Multiple tablets from the same partition live on different CNs. This is a finer-grained distribution model.

Consequences:
- In ClickHouse, adding a shard requires re-sharding existing data (multi-hour migration at 5B rows/day scale).
- In StarRocks, adding a CN triggers automatic tablet reassignment — the cluster rebalances without manual data migration.

### Bucket Count Guidance

`DISTRIBUTED BY HASH(event_id) BUCKETS 21` in this architecture uses the rule of thumb: **3 × CN count** (3 × 7 = 21).

- Too few buckets: a partition's data is concentrated on fewer CNs; parallelism bottleneck during scans and compaction.
- Too many buckets: metadata overhead increases; very small tablets reduce scan efficiency.
- The bucket count is set once at table creation and cannot be changed without a table rebuild — finalize it based on expected partition size and CN count.

### Rowset Accumulation ("Small File" Problem)

The StarRocks equivalent of ClickHouse's "too many parts" problem is rowset accumulation:

| | ClickHouse | StarRocks |
|---|---|---|
| Symptom | `Too many parts in partition` error | Compaction lag; slow queries on affected tablets |
| Root cause | Too many small INSERTs creating many parts before merge | Too many small rowsets per tablet before compaction |
| Primary lever | `kafka_max_block_size = 1048576` (1M rows per Kafka batch) | `max_batch_rows = 500000` in Routine Load |
| Secondary lever | `background_pool_size` | CN compaction thread count |
| Monitoring | `SELECT count() FROM system.parts WHERE active` | `SHOW PROC '/compactions'` |

---

## 5. Storage Architecture

### ClickHouse Storage Stack

ClickHouse's storage hierarchy in this architecture uses a two-level disk abstraction:

```
cache disk (type: cache, write-through, LRU eviction)
  Name: nvme_cache
  max_size: NVMe capacity × cache_fraction
  cache_on_write_operations: 1  ← populate NVMe on INSERT (write-through)
    │
    └── wraps: s3 disk (type: s3)
                Name: s3_main
                endpoint: http://minio:9000/bucket/clickhouse/cache/shard-{N}/
```

Storage policy `cache_policy` routes all writes through this hierarchy. When a part is written:
1. Data is written to S3 (durable source of truth).
2. `cache_on_write_operations = 1` simultaneously copies the data to local NVMe.
3. On read, the cache disk serves data from NVMe if present; on miss, falls back to S3 and populates NVMe (read-through).

This write-through behavior ensures newly ingested data is always NVMe-hot, avoiding cold reads from S3 immediately after ingest.

### StarRocks Shared-Data Storage Stack

```
S3 backend (primary source of truth)
  s3://bucket/starrocks/{db}/{table}/{partition}/{tablet}/

NVMe data cache (per-CN, transparent LRU layer)
  datacache_disk_path: /data/datacache
  datacache_disk_size: NVMe capacity × cache_fraction
```

Key differences from ClickHouse's model:

**1. S3 is the primary store, not a fallback.**
In ClickHouse, the `s3` disk is the "real" storage and the `cache` disk wraps it. In StarRocks shared-data, S3 is always the write target. The NVMe cache is a transparent acceleration layer, not a primary tier.

**2. No write-through by default.**
StarRocks' default data cache behavior is read-through — NVMe is populated on first read, not on write. Newly ingested data starts cold. The setting `datacache_populate_mode = auto` attempts to populate the cache on writes that are likely to be queried soon, but this is not a strict write-through guarantee and must be validated in PoC.

```sql
-- StarRocks table-level settings for shared-data / CN mode (in 03_events_table.sql)
"datacache_enable" = "true",
"datacache_partition_duration" = "7 DAY",  -- keep last 7 days' partitions NVMe-hot
"enable_persistent_index" = "true",
"persistent_index_type"   = "CLOUD_NATIVE" -- store Primary Key index in S3, not local disk
```

**4. Primary Key index must be stored in S3 (`CLOUD_NATIVE`).**
For `PRIMARY KEY` tables in shared-data mode, `persistent_index_type = CLOUD_NATIVE` stores the Primary Key lookup index in S3 rather than on the CN's local disk. This is required for CN (stateless compute) nodes, which may not have persistent local storage between restarts. Without this property, StarRocks falls back to `LOCAL` index storage — which defeats the purpose of CN nodes and will either fail or produce incorrect behavior on pods without durable local storage. This has no ClickHouse equivalent because ClickHouse's primary index is always embedded in each part's local files.

**3. No replica-level replication.**
`replication_num = 1` in this architecture means each tablet is assigned to one CN for compute. Durability comes from S3's erasure coding (MinIO) or RAID (NetApp), not from CN-to-CN replication. There is no "zero-copy" concept because there are no replicas.

### Shared-Nothing vs Shared-Data

StarRocks supports two storage modes:
- **Shared-nothing**: BEs have local SSD/NVMe as primary storage; `replication_num = 3` means 3 BE replicas per tablet; no S3 dependency.
- **Shared-data**: S3 is primary; NVMe is a cache layer; `replication_num = 1`; horizontal scaling without data migration.

This architecture uses **shared-data** exclusively. The reason: shared-data enables adding CNs without re-distributing existing data (tablets are reassigned lazily from S3). Shared-nothing would require manual tablet rebalancing similar to ClickHouse resharding.

### Zero-Copy Replication: Why It Matters and Why It Disappears

**ClickHouse context**: with S3-backed MergeTree and 2 replicas per shard, you have a choice:
- `allow_remote_fs_zero_copy_replication = 0`: both replicas write complete copies of each part to S3 (2× S3 storage cost; no GC race).
- `allow_remote_fs_zero_copy_replication = 1`: both replicas reference the same S3 objects; Keeper znodes track shared part ownership; no redundant S3 writes.

The zero-copy option is attractive for cost (1× S3 storage) but carries documented risk: the Keeper-coordinated GC that cleans up S3 objects for zero-copy parts has a race condition that can result in a replica permanently losing parts — this means data loss, not just performance degradation. ClickHouse Inc. built SharedMergeTree (ClickHouse Cloud only) specifically to replace this mechanism. The risk is significant enough that this architecture marks it as a critical open decision (#12) that must be resolved before YAML authoring.

**StarRocks**: this class of problem does not exist in shared-data mode. There are no replicas. S3 is the single source of truth. There is no GC race because there is no Keeper-coordinated object sharing. Adding or removing CNs does not involve S3 GC coordination — tablet files in S3 are simply re-referenced by the new CN assignment. The zero-copy risk is architecturally eliminated, not mitigated.

---

## 6. Kafka Ingest: KafkaEngine vs Routine Load

### ClickHouse Path: Three Objects

The ClickHouse Kafka ingest pipeline requires three DDL objects deployed together as a unit:

**Object 1: KafkaEngine table** (`06_ingest_kafka_table.sql`) — the Kafka connector. Not a storage table. Reading from it consumes messages; it stores no rows.

```sql
-- ClickHouse: KafkaEngine connector (not storage)
CREATE TABLE IF NOT EXISTS default.kafka_ingest
ON CLUSTER 'ingest'
(
    event_ts      UInt64,
    user_id       UInt64,
    eviction_date Date
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list          = 'kafka-broker-0:9092,kafka-broker-1:9092',
    kafka_topic_list           = 'events',
    kafka_group_name           = 'clickhouse_ingest_{shard}',  -- {shard} macro: CRITICAL for multi-node
    kafka_format               = 'JSONEachRow',
    kafka_max_block_size       = 1048576,    -- prevent "too many parts"
    kafka_num_consumers        = 1,
    kafka_flush_interval_ms    = 7500,
    kafka_handle_error_mode    = 'stream',   -- expose _error/_raw_message virtual columns
    kafka_skip_broken_messages = 0;
```

**Object 2: Materialized View** (`07_ingest_kafka_mvs.sql`) — the trigger that fires on each batch consumed from the KafkaEngine table, transforms columns, and writes to the cache cluster. The MV is the ingest pipeline's transformation layer.

```sql
-- ClickHouse: MV trigger (fires on each Kafka batch consumed by kafka_ingest)
CREATE MATERIALIZED VIEW IF NOT EXISTS default.mv_kafka_to_cache
ON CLUSTER 'ingest'
TO default.cache_writer          -- writes to Distributed table on ingest cluster
AS SELECT
    toDate(toDateTime64(event_ts / 1000, 3))  AS event_date,
    event_ts,
    user_id,
    eviction_date,
    event_ts                                   AS _ver
FROM default.kafka_ingest
WHERE length(_error) = 0;        -- filter parse errors via virtual column

-- DLQ path (second MV, same source table)
CREATE MATERIALIZED VIEW IF NOT EXISTS default.mv_kafka_dlq
ON CLUSTER 'ingest'
TO default.kafka_dead_letters
AS SELECT
    _raw_message AS raw_message,
    _error       AS error,
    now()        AS captured_at
FROM default.kafka_ingest
WHERE length(_error) > 0;
```

**Object 3: Distributed write table** (`04_ingest_cache_writer.sql`) — a `Distributed` engine table on the ingest cluster that routes INSERT to the correct shard on the cache cluster. This is the cross-cluster bridge.

### StarRocks Path: One Object

```sql
-- StarRocks: Routine Load replaces all three ClickHouse objects
CREATE ROUTINE LOAD events_db.events_kafka_load ON events_db.events

COLUMNS
(
    event_id,
    user_id,
    event_ts,
    eviction_date,
    event_date = str_to_date(from_unixtime(event_ts / 1000), '%Y-%m-%d')
    -- ClickHouse equivalent: toDate(toDateTime64(event_ts / 1000, 3)) AS event_date
)

PROPERTIES
(
    "desired_concurrent_number" = "6",    -- parallel sub-tasks (≤ Kafka partition count)
    "max_batch_rows"            = "500000",  -- equivalent to kafka_max_block_size
    "max_batch_interval"        = "10",
    "max_error_number"          = "1000",
    "max_filter_ratio"          = "0.01",
    "strict_mode"               = "true",
    "timezone"                  = "UTC",
    "consumer_group"            = "starrocks_events_kafka_load"  -- FE manages this automatically
)

FROM KAFKA
(
    "kafka_broker_list" = "kafka-broker-0:9092,kafka-broker-1:9092",
    "kafka_topic"       = "events",
    "kafka_partitions"  = "0,1,2,3,4,5",
    "kafka_offsets"     = "OFFSET_END,OFFSET_END,OFFSET_END,OFFSET_END,OFFSET_END,OFFSET_END",
    "format"            = "json"
);
```

### Operational Comparison

| Dimension | ClickHouse | StarRocks |
|---|---|---|
| Objects required | 3 (KafkaEngine + MV + Distributed) | 1 (Routine Load job) |
| Offset management | External (Kafka consumer group, ClickHouse commits offsets) | Internal (FE metadata; FE commits offsets on batch success) |
| Consumer group collision avoidance | Manual: `kafka_group_name = 'clickhouse_ingest_{shard}'` (`{shard}` macro required) | Automatic: job name used as group name basis |
| DLQ routing | Automatic: second MV reads `_error` virtual column | Manual: monitoring process polls CN error log files (`ErrorLogUrls` in `SHOW ROUTINE LOAD TASK`) |
| Parallelism tuning | Kafka partition count + `kafka_num_consumers` per node | `desired_concurrent_number` (≤ Kafka partition count) |
| Batch size tuning | `kafka_max_block_size` (rows per MV batch) | `max_batch_rows` (rows per sub-task flush) |
| "Too many parts" equivalent | `Too many parts` exception | Rowset accumulation; monitor `SHOW PROC '/compactions'` |
| Cross-cluster write | Required: `default.cache_writer` Distributed INSERT | Not needed: Routine Load writes directly to target table |
| Column transforms | In MV SELECT clause | In `COLUMNS` clause of Routine Load DDL |
| Job management | `DETACH/ATTACH TABLE` to pause/resume KafkaEngine | `PAUSE/RESUME ROUTINE LOAD FOR job_name` |
| Ingest cluster | Required (separate pods) | Not required (sub-tasks run on CNs) |

### Function Translation for Column Transforms

| Operation | ClickHouse (in MV SELECT) | StarRocks (in COLUMNS clause) |
|---|---|---|
| ms epoch → Date | `toDate(toDateTime64(event_ts / 1000, 3))` | `str_to_date(from_unixtime(event_ts / 1000), '%Y-%m-%d')` |
| ms epoch → DateTime | `toDateTime64(event_ts / 1000, 3)` | `from_unixtime(event_ts / 1000)` |
| Conditional | `if(cond, a, b)` | `if(cond, a, b)` (same) |
| Current timestamp | `now()` | `now()` (same) |

---

## 7. S3 File Ingest: S3Queue vs Pipe

### ClickHouse S3Queue Path: Two Objects

**Object 1: S3Queue table** (`08_ingest_s3queue_table.sql`) — monitors an S3 path for new files and delivers them to attached MVs. Like KafkaEngine, it is a connector, not storage.

```sql
-- ClickHouse: S3Queue connector (not storage)
CREATE TABLE IF NOT EXISTS default.s3queue_ingest
ON CLUSTER 'ingest'
(
    event_ts      UInt64,
    user_id       UInt64,
    eviction_date Date
)
ENGINE = S3Queue(
    's3://source-bucket/path/**',
    'JSONEachRow'
)
SETTINGS
    mode                                      = 'ordered',   -- process in S3 listing order
    s3queue_processing_threads_num            = 4,
    s3queue_max_processed_files_before_commit = 100,
    s3queue_enable_logging_to_s3queue_log     = 1,
    s3queue_tracked_files_limit               = 1000000,     -- max Keeper znodes for file state
    s3queue_tracked_file_ttl_sec              = 604800;      -- 7 days
```

**Object 2: Materialized View** (`09_ingest_s3queue_mv.sql`) — identical transformation pattern to the Kafka MV.

```sql
-- ClickHouse: S3Queue MV (fires as files are delivered by S3Queue)
CREATE MATERIALIZED VIEW IF NOT EXISTS default.mv_s3queue_to_cache
ON CLUSTER 'ingest'
TO default.cache_writer
AS SELECT
    toDate(toDateTime64(event_ts / 1000, 3))  AS event_date,
    event_ts,
    user_id,
    eviction_date,
    event_ts                                   AS _ver
FROM default.s3queue_ingest;
```

Note: S3Queue does not expose `_error` virtual columns the way KafkaEngine does. Schema validation failures cause the file to be retried; errors are visible only in `system.s3queue_log`.

### StarRocks Pipe Path: One Object

```sql
-- StarRocks: Pipe replaces S3Queue + MV with a single object
CREATE PIPE IF NOT EXISTS events_db.events_s3_pipe
PROPERTIES
(
    "auto_ingest"         = "true",
    "poll_interval"       = "60",        -- seconds between S3 path polls
    "max_concurrent_tasks" = "4"         -- equivalent to s3queue_processing_threads_num
)
AS
INSERT INTO events_db.events
(
    event_id, user_id, event_ts, eviction_date, event_date
)
SELECT
    event_id,
    user_id,
    event_ts,
    eviction_date,
    str_to_date(from_unixtime(event_ts / 1000), '%Y-%m-%d') AS event_date
    -- ClickHouse equivalent: toDate(toDateTime64(event_ts / 1000, 3)) AS event_date
FROM FILES
(
    "path"              = "s3://source-bucket/events/",
    "format"            = "parquet",
    "aws.s3.endpoint"   = "http://minio-service:9000",
    "aws.s3.region"     = "us-east-1",
    "aws.s3.access_key" = "${SOURCE_S3_ACCESS_KEY}",
    "aws.s3.secret_key" = "${SOURCE_S3_SECRET_KEY}"
);
```

### State Store Comparison

| Dimension | ClickHouse S3Queue | StarRocks Pipe |
|---|---|---|
| File state location | Keeper znode tree | FE metadata (BDB-JE) |
| Processed file tracking | Znode per file (up to `s3queue_tracked_files_limit`) | FE metadata row per file |
| Expiry of processed state | `s3queue_tracked_file_ttl_sec` (7 days default) | Permanent until pipe is dropped |
| Duplicate prevention | Keeper claim lock; processed file znode | FE metadata: files marked processed after successful load; not re-queued |
| Leader failover behavior | New Keeper leader recovers znode state; brief processing pause | FE leader failover (BDB-JE replicated to FE followers); Pipe must be validated in PoC |
| File retry | Re-queued after `tracked_file_ttl_sec` expires | Explicit: `ALTER PIPE ... RETRY FILE 's3://...'` |
| Semantics | At-least-once (per file) + dedup via ReplacingMergeTree | At-least-once (per file) + dedup via Primary Key |
| State fragility | Keeper znode bloat at high file counts; mitigated by `s3queue_tracked_files_limit` | FE metadata; less fragile under leader failover |

**Important**: Pipe (introduced in StarRocks 3.2) is newer than S3Queue. FE leader failover behavior during active Pipe load tasks must be validated in PoC before production deployment.

---

## 8. Materialized Views: A Fundamental Difference

### ClickHouse Materialized Views

ClickHouse MVs are **trigger-based**:
- Each MV is a `SELECT` statement bound to a source table.
- On every INSERT to the source table, the MV's SELECT runs against the new rows and its result is written to the target table.
- The target table can be any engine (including Distributed, for cross-cluster writes).
- **No query rewrite**: the MV result lives in a separate table. Queries must explicitly target either the source table or the MV target table. The optimizer does not automatically use the MV.

In this architecture, MVs serve as the **ingest pipeline glue**: the KafkaEngine table is the source, the MV transforms rows (derives `event_date`, sets `_ver`), and the Distributed write table (`cache_writer`) is the target. The MV is not an analytics optimization — it is the ingest mechanism.

### StarRocks Materialized Views: Two Distinct Types

#### Type 1: Synchronous (Rollup) MVs — Legacy, Skip

These are an older mechanism. Ignore them for new designs.

#### Type 2: Asynchronous MVs — For Pre-Aggregation

Async MVs are maintained by scheduled or triggered refresh jobs. They are not used for ingest in this architecture (Routine Load handles ingest natively). They are relevant for pre-aggregating results for dashboard queries.

```sql
-- StarRocks: async MV for pre-aggregation (analytics use case, not ingest)
CREATE MATERIALIZED VIEW daily_event_counts
REFRESH ASYNC EVERY(INTERVAL 1 DAY)
AS SELECT
    event_date,
    count(*) AS event_count,
    count(DISTINCT user_id) AS unique_users
FROM events_db.events
GROUP BY event_date;
```

#### Type 3: Transparent Query Rewrite (StarRocks 3.x) — No ClickHouse Equivalent

StarRocks 3.x introduces **transparent query rewrite**: the query optimizer automatically detects when a query can be satisfied by an existing MV and rewrites the query plan to use the MV result instead of scanning the base table.

This has no ClickHouse equivalent. In ClickHouse, if you build an `AggregatingMergeTree` MV for pre-aggregated counts, queries must explicitly `SELECT ... FROM the_mv_table`. The application knows about the MV. In StarRocks, the application queries the base table; the optimizer silently routes the query to the MV.

Example:
```sql
-- Application sends this query to StarRocks:
SELECT event_date, count(*) FROM events_db.events GROUP BY event_date;

-- StarRocks optimizer detects daily_event_counts covers this query.
-- Actual execution plan uses daily_event_counts — no application change needed.
```

When to use transparent rewrite: when dashboard queries are expensive and you want query acceleration without changing application SQL. The MV refresh lag means the rewrite result may be slightly stale; verify that staleness is acceptable for the query workload.

### MVs in This Architecture

Routine Load handles ingest natively — there is no ingest MV needed in StarRocks. The ClickHouse pattern (KafkaEngine + MV + Distributed table) collapses to a single Routine Load DDL. MVs in StarRocks are purely an analytics optimization tool for this architecture, not an ingest mechanism.

---

## 9. Query Execution Model

### ClickHouse: Push-Based Within Node, Distributed Fan-Out Across Nodes

ClickHouse uses a **vectorized push-based pipeline** within a single node: operators push batches of rows through a processing pipeline using SIMD instructions. This is extremely fast for single-node column scans.

For distributed queries, the `Distributed` table fans out the query to individual shards, each shard executes the full query locally, and partial results are sent back to the coordinator node for final merging. Each shard is largely independent; complex distributed operations (like distributed GROUP BY with high cardinality) require network transfer of intermediate results.

`SELECT ... FINAL` modifies this: it forces ClickHouse to merge all parts for the queried partitions before executing the query — reads every part, deduplicates, then applies the query. Cost: 2–3× query time. This is why the architecture explicitly prohibits FINAL in production.

`PREWHERE` is a ClickHouse-specific optimization: a preliminary WHERE applied before reading column data for rows that fail PREWHERE, allowing early elimination of rows before full column reads. It's a manual optimization hint for queries with high-selectivity filters.

### StarRocks: MPP Volcano Model

StarRocks uses a **Massively Parallel Processing (MPP) Volcano model**. The FE generates a query plan and splits it into **fragments** — independently executable pipeline stages. Fragments are dispatched to CNs for execution; CNs exchange intermediate results via network. The FE coordinates fragment execution and assembles the final result.

Key differences from ClickHouse's model:

| Aspect | ClickHouse | StarRocks |
|---|---|---|
| Within-node execution | Push-based vectorized pipeline | Volcano model + pipeline engine (3.x) |
| Cross-node execution | Distributed table fan-out; each shard independent | MPP fragments with inter-CN exchange |
| Coordinator role | Distributed table host node | FE (dedicated coordinator) |
| Dedup at query time | `SELECT ... FINAL` (expensive) | Not needed (Primary Key data always deduplicated) |
| Multi-table JOINs | Poor; requires denormalized wide tables | Well-supported; MPP optimizer handles shuffle joins efficiently |
| Early filter optimization | `PREWHERE` (manual hint) | Cost-based optimizer with predicate pushdown (automatic) |

### Colocate Joins

StarRocks supports **colocated joins**: if two tables use the same distribution key and bucket count, their corresponding tablets are co-located on the same CNs. A join on the distribution key can then be executed without shuffling data across CNs — each CN joins its local tablets independently.

This has no direct ClickHouse equivalent. ClickHouse's co-located join (`GLOBAL JOIN` / `LOCAL IN`) is limited; general JOIN performance is a known weakness.

To create co-located tables:
```sql
-- Both tables use same distribution key (user_id) and bucket count (21)
-- StarRocks co-locates matching tablets on the same CNs
CREATE TABLE events_db.events        DISTRIBUTED BY HASH(user_id) BUCKETS 21 ...;
CREATE TABLE events_db.user_profiles DISTRIBUTED BY HASH(user_id) BUCKETS 21 ...;

-- This join has no network shuffle (CNs join local tablets)
SELECT e.event_id, p.display_name
FROM events_db.events e
JOIN events_db.user_profiles p ON e.user_id = p.user_id;
```

### SQL Dialect Differences

| ClickHouse | StarRocks | Notes |
|---|---|---|
| `toDate(x)` | `date(x)` or `str_to_date(x, fmt)` | |
| `toDateTime64(x, 3)` | `from_unixtime(x)` | |
| `toYYYYMMDD(x)` | `date_format(x, '%Y%m%d')` | |
| `formatReadableSize(x)` | No direct equivalent | Use `round(x / 1073741824, 2)` for GB |
| `length(str)` | `length(str)` | Same |
| `if(cond, a, b)` | `if(cond, a, b)` | Same |
| `system.parts` | `information_schema.PARTITIONS` | Different schema; different columns |
| `system.query_log` | `information_schema.loads` + `EXPLAIN` | |
| `system.replicas` | N/A | No replicas in shared-data mode |
| `system.zookeeper` | N/A | No Keeper |
| `system.merges` | `information_schema.be_compactions` | |
| `SHOW PROCESSLIST` | `SHOW PROCESSLIST` | Same (MySQL compat) |
| HTTP + native TCP (9000/8123) | MySQL protocol (9030) + HTTP (8080) | MySQL clients (mysql CLI, JDBC) work directly |
| ClickHouse-specific drivers | Standard MySQL JDBC/ODBC drivers | |

---

## 10. DML: INSERT, UPDATE, DELETE, UPSERT

### ClickHouse DML Limitations

ClickHouse's `MergeTree` family was designed for append-only high-throughput ingest. Mutations (UPDATE, DELETE) were retrofitted and have significant limitations:

| Operation | ClickHouse Mechanism | Cost | Notes |
|---|---|---|---|
| INSERT | Append new part | Low | Dedup at merge time (ReplacingMergeTree) |
| UPSERT | Not native | — | Emulated via ReplacingMergeTree + merge-time dedup |
| Lightweight DELETE (23.3+) | Deletion bitmap on part | Low (logical) | Rows logically hidden; physically present until OPTIMIZE |
| ALTER TABLE UPDATE | Rewrite entire column data across all affected parts | High | Full part rewrite; heavy I/O |
| Patch parts (24.3+) | Write overlay object for column updates | Medium | More efficient than full rewrite; limited column types |
| `OPTIMIZE TABLE PARTITION FINAL` | Force partition rewrite; physically removes deleted rows | Very high | Required for physical deletion; serialized per partition |

The compliance delete path in this architecture requires: `DELETE FROM events WHERE user_id = X` (lightweight delete, logical) followed by `OPTIMIZE TABLE t PARTITION 'pYYYYMMDD' FINAL` for each affected partition. With daily partitions over a 90-day retention window, a single user deletion may require up to ~210 OPTIMIZE calls. These cannot be parallelized (each OPTIMIZE holds a partition write lock), making the 24h SLA infeasible beyond ~10 users per nightly batch.

### StarRocks Primary Key DML

The Primary Key model treats UPDATE and DELETE as first-class operations with merge-on-write semantics:

| Operation | StarRocks Mechanism | Cost | Notes |
|---|---|---|---|
| INSERT | Merge-on-write; lookup and replace on PK collision | Lookup overhead per duplicate | No transient duplicates |
| UPSERT | Native behavior of INSERT on Primary Key | Same as INSERT | New row always replaces stored row |
| UPDATE | Efficient in-place update via Primary Key lookup | Low per row | No full part rewrite |
| DELETE | Immediate logical inaccessibility | Low | Rows invisible immediately after DELETE completes |
| `ALTER TABLE COMPACT` | Distributed compaction across tablets on all CNs | Medium (distributed) | Physical byte removal; parallelizable across tablets |

### Side-by-Side: Compliance Delete

**ClickHouse**:
```sql
-- Step 1: logical deletion (rows still visible until OPTIMIZE)
DELETE FROM cache_db.cache_table
ON CLUSTER 'cache'
WHERE user_id = 12345;

-- Step 2: physical removal — must run per affected partition (serialized)
-- With 90-day retention: up to 90 × 2 replicas = 180–210 OPTIMIZE calls
OPTIMIZE TABLE cache_db.cache_table
ON CLUSTER 'cache'
PARTITION '20240115' FINAL;

OPTIMIZE TABLE cache_db.cache_table
ON CLUSTER 'cache'
PARTITION '20240116' FINAL;
-- ... repeat for every partition containing user_id = 12345 rows
```

**StarRocks**:
```sql
-- Step 1: immediate logical deletion (rows invisible NOW)
DELETE FROM events_db.events
WHERE user_id = 12345;
-- No OPTIMIZE equivalent needed for logical inaccessibility.
-- Rows are invisible to all queries as soon as this statement completes.

-- Step 2: physical removal (only if SLA requires physical S3 byte removal)
-- Distributed across tablets on all CNs simultaneously
ALTER TABLE events_db.events COMPACT PARTITION p20240115;
-- Optionally compact a range instead of per-partition calls:
ALTER TABLE events_db.events COMPACT PARTITION START ("p20240101") END ("p20241231");
```

The key improvement: in ClickHouse, the compliance gap between `DELETE` and physical removal may span hours (OPTIMIZE duration at scale). In StarRocks, logical inaccessibility is immediate — if the compliance SLA is interpreted as "rows must not be queryable," the SLA is satisfied at the moment `DELETE` completes, independent of compaction timing.

Both systems face the same challenge for **physical byte removal** at scale with many partitions: the number of partitions to compact is proportional to the retention window. StarRocks compaction is distributed across tablets on all CNs simultaneously (potentially faster than ClickHouse's serialized per-partition OPTIMIZE), but both require PoC validation at production partition sizes.

### UPDATE Example (StarRocks only)

```sql
-- Native UPDATE on Primary Key model (no ClickHouse equivalent without ALTER TABLE UPDATE overhead)
UPDATE events_db.events
SET eviction_date = current_date()
WHERE user_id = 12345;

-- Batch UPDATE from staging table (compliance field pseudonymization)
UPDATE events_db.events e
    JOIN events_db.compliance_batch b ON e.user_id = b.user_id
SET e.eviction_date = b.new_eviction_date
WHERE b.batch_date = current_date()
  AND b.operation = 'UPDATE';
```

In ClickHouse, the equivalent would be `ALTER TABLE cache_table ON CLUSTER 'cache' UPDATE eviction_date = today() WHERE user_id = 12345` — a heavy mutation that rewrites all column data for affected parts.

---

## 11. Operations and Administration

### Schema Changes

| Operation | ClickHouse | StarRocks |
|---|---|---|
| `ADD COLUMN` | Lightweight (wide format parts; column added as metadata; existing parts not rewritten) | Lightweight (FE metadata + background tablet updates) |
| `DROP COLUMN` | Lightweight (column marked dropped; parts not rewritten) | Lightweight |
| `MODIFY COLUMN` (type change) | Heavy: rewrites all data for that column across all parts; avoid in production during peak | Light-to-medium depending on type change; check StarRocks docs for specific conversions |
| `RENAME COLUMN` | Requires RENAME COLUMN (24.x+) or full table DDL in older versions | Supported in recent StarRocks versions |
| `ON CLUSTER` required | Yes, on every DDL statement | No (FE applies globally) |
| Propagation | Operator applies DDL to all nodes; replication ensures consistency | FE applies DDL; propagates to CNs via FE metadata |

### Rolling Upgrades

**ClickHouse** (Altinity Operator):
- Operator performs a rolling restart of nodes one at a time.
- Keeper must stay quorate during the upgrade (3-node Keeper tolerates 1-node failure; upgrade one Keeper node at a time with quorum maintained).
- Ingest pauses during individual node restarts (KafkaEngine consumer stops; MV trigger does not fire).
- Altinity 0.26.0+ is a mature operator; rolling upgrade behavior is well-documented.

**StarRocks** (kube-starrocks):
- Operator performs rolling restart of CN nodes.
- During CN restart: tablets on the restarting CN are temporarily unavailable; FE reroutes queries to remaining CNs (tablet replicas if `replication_num > 1`; in shared-data mode with `replication_num = 1`, queries to tablets on the restarting CN may fail briefly).
- FE leader failover during upgrade: if the FE leader pod is restarted, one of the follower FEs becomes the new leader. FE leadership election via BDB-JE; brief pause during leader election.
- kube-starrocks operator upgrade behavior, FE leader failover timing, and Routine Load behavior during FE restarts must all be validated in PoC.

### Credential Rotation

**ClickHouse**:
- Vault Agent Sidecar writes S3 credentials as XML config drop-in files.
- Send `kill -HUP` to ClickHouse process to reload config without pod restart.
- Well-supported mechanism.

**StarRocks**:
- Vault Agent Sidecar writes credentials to FE/CN environment or config files.
- `kill -HUP` behavior for reloading S3 credentials is **not guaranteed** across all StarRocks versions.
- Rolling pod restart may be required to rotate S3 credentials.
- **PoC must validate credential rotation without full pod restart.**

### Observability: Key Monitoring Queries

| What to monitor | ClickHouse | StarRocks |
|---|---|---|
| **Cache hit rate** | `SELECT * FROM system.filesystem_cache_log` | `SELECT * FROM information_schema.datacache_stats` |
| **Part / rowset accumulation** | `SELECT partition, count() FROM system.parts WHERE active GROUP BY partition` | `SHOW PROC '/compactions'` |
| **Ingest lag (Kafka)** | Query Kafka consumer group lag externally; CH doesn't expose this natively | `SHOW ROUTINE LOAD FOR events_db.events_kafka_load\G` (shows Lag field) |
| **Merge / compaction progress** | `SELECT * FROM system.merges` | `SELECT * FROM information_schema.be_compactions` |
| **Query profiling** | `SELECT * FROM system.query_log WHERE type = 'QueryFinish'` | `EXPLAIN <query>` + `information_schema.loads` |
| **Replication lag** | `SELECT * FROM system.replicas WHERE behind_count > 0` | N/A (shared-data; no replica lag) |
| **Keeper health** | `SELECT * FROM system.zookeeper WHERE path = '/clickhouse'` | N/A (FE internal; `SHOW PROC '/frontends'`) |
| **Prometheus scrape** | `/metrics` endpoint on each CH node (port 9363) | FE `/metrics` (port 8080) + CN `/metrics` (port 8040) |
| **Active queries** | `SELECT * FROM system.processes` | `SHOW PROCESSLIST` |
| **S3 ingest file state** | `SELECT * FROM system.s3queue_log` | `SELECT * FROM information_schema.pipe_files WHERE pipe_name = 'events_s3_pipe'` |
| **Partition list** | `SELECT * FROM system.parts WHERE table = 'cache_table' AND active GROUP BY partition` | `SHOW PARTITIONS FROM events_db.events ORDER BY PartitionName` |

**Notable absence in StarRocks**: there is no equivalent to `system.replicas` (no replicas in shared-data mode) and no equivalent to `system.zookeeper` (no external Keeper). Monitoring is simpler because there are fewer distributed state concerns.

---

## 12. Advantages of StarRocks over ClickHouse

These are substantive architectural improvements, not marketing claims. Each has a concrete impact on the production system.

### 1. Zero-Copy Replication Eliminated

This is the single most important safety improvement in this architecture comparison.

ClickHouse's `allow_remote_fs_zero_copy_replication = 1` allows multiple replicas to share S3 objects, reducing storage costs. However, the mechanism relies on Keeper-coordinated GC to determine when shared objects are safe to delete. This GC has a documented race condition that can result in one replica permanently losing parts — data loss that cannot be recovered from within the cluster. ClickHouse Inc. built SharedMergeTree (Cloud only) specifically to replace this mechanism. The risk is severe enough that this architecture flags it as Open Decision #12 (critical blocker before YAML authoring) and requires an explicit decision between 1× S3 cost (zero-copy, GC race risk) vs 2× S3 cost (full replication, no risk).

In StarRocks shared-data mode, this class of problem does not exist. There are no replicas. S3 is the single source of truth. There is no GC coordination for shared objects because no objects are shared across replicas. The zero-copy risk is architecturally eliminated, not mitigated.

### 2. No Transient Duplicates

ClickHouse's `ReplicatedReplacingMergeTree` deduplicates at merge time. Between INSERT and the next background merge, both the old and new row are present and queryable. Applications that require consistent deduplication must use `SELECT ... FINAL` (expensive) or accept that queries may return duplicates.

StarRocks Primary Key deduplicates on INSERT. From the moment an INSERT completes, the stored row reflects the most recent version. No FINAL equivalent is needed. No application-side workaround is required. Analytical queries always see deduplicated data.

This improves both correctness (no accidental double-counting in aggregations) and performance (no FINAL overhead).

### 3. Simpler Topology

Three separate concerns in ClickHouse (ingest cluster + cache cluster + external Keeper) become two tiers in StarRocks (FE + CN). Pod count drops from 19–21 to 10. This reduces:
- Operational surface area (fewer components to monitor, upgrade, and troubleshoot).
- Failure modes (Keeper quorum loss is a significant incident type in ClickHouse; FE BDB-JE replication is simpler and less operationally demanding).
- DDL complexity (no `ON CLUSTER` routing; no cross-cluster Distributed tables).

### 4. Horizontal Scaling Without Migration

Adding capacity to the ClickHouse cache cluster requires resharding: adding a new shard and either migrating existing data (multi-hour operation at 5B rows/day) or accepting permanent imbalanced data distribution. This is a planned, disruptive operation.

Adding a CN to StarRocks triggers automatic tablet redistribution. The FE reassigns tablets from existing CNs to the new CN. Existing CNs transfer tablet data (or the new CN reads from S3 directly in shared-data mode). No manual data migration, no table rebuild, no write pause.

### 5. Native UPDATE and DELETE

ClickHouse was designed for append-only workloads. UPDATE and DELETE are available but expensive: `ALTER TABLE UPDATE` rewrites all column data for affected parts; lightweight DELETE leaves rows physically present until OPTIMIZE. Neither is a first-class, efficient operation.

StarRocks Primary Key makes UPDATE and DELETE first-class. UPDATE on a single row is efficient (Primary Key lookup + delta write). DELETE makes rows immediately logically inaccessible. These are not retrofits — the Primary Key model is architecturally designed for them.

### 6. FE as Unified Control Plane

The FE eliminates the need for a separate coordination cluster. ClickHouse Keeper manages replica metadata, table schemas, S3Queue file state, and INSERT-level dedup windows — a separate 3-5 pod cluster that must be operated, backed up, and kept quorate. If Keeper loses quorum, replicated tables become read-only.

The FE handles all of these concerns internally via BDB-JE (a replicated embedded database within the FE pods). There is no separate coordination cluster to manage. FE follower nodes provide HA for the metadata store.

### 7. Immediate Logical Delete for Compliance

When a compliance deletion request arrives, ClickHouse's lightweight delete marks rows as deleted but they remain visible to queries until `OPTIMIZE TABLE PARTITION FINAL` completes. The gap between the delete command and actual query invisibility can span hours at scale.

StarRocks DELETE on a Primary Key table makes rows immediately invisible to all queries upon statement completion. If the compliance SLA is defined as "rows must not be queryable" (logical inaccessibility), StarRocks satisfies it at DELETE time, independent of compaction scheduling.

### 8. MySQL Protocol Compatibility

ClickHouse uses a custom SQL dialect and requires custom drivers (ClickHouse JDBC/ODBC, `clickhouse-client`, HTTP API). Standard database tools (mysql CLI, MySQL Workbench, standard JDBC connections) do not work without adaptation.

StarRocks exposes a MySQL-compatible protocol on port 9030. Standard MySQL tools work without modification. Any tool that speaks MySQL protocol (BI tools, monitoring dashboards, ORM frameworks) connects without custom drivers.

### 9. Better JOIN Support

ClickHouse is optimized for single-table scans on wide denormalized tables. Multi-table JOINs involve significant data movement and are not well-optimized relative to purpose-built OLAP databases with MPP architectures.

StarRocks' MPP optimizer is designed for multi-table JOINs. It supports hash joins, broadcast joins, bucket shuffle joins, and colocate joins. For workloads with normalized schemas or multiple lookup tables, StarRocks will generally outperform ClickHouse.

### 10. Colocate Joins

When two tables are distributed by the same key and same bucket count, StarRocks co-locates their tablets on the same CNs. Joins on the co-location key require no network data transfer — each CN joins its local tablet data independently. This significantly reduces join cost for frequently joined table pairs.

---

## 13. Disadvantages / Trade-offs vs ClickHouse

An honest assessment of where StarRocks is weaker. These are not disqualifying concerns, but they require PoC validation and operational awareness.

### 1. Write-Path Overhead (Primary Key Merge-on-Write)

The Primary Key model's deduplication-on-INSERT requires a lookup in the current tablet data for every incoming row that might be a duplicate. At 57,870 rows/sec with a 10–20% duplicate rate, approximately 5,787–11,574 lookup operations per second are required at the CN level.

ClickHouse's `ReplicatedReplacingMergeTree` has **zero write-path dedup overhead** — deduplication is entirely deferred to background merge, which runs asynchronously on background threads. High-throughput ingest is not affected by dedup at write time.

The actual overhead of the Primary Key lookup at this ingest rate depends on tablet data size, NVMe cache hit rate, and CN hardware. It must be measured under sustained load in PoC before concluding the Primary Key model handles 57,870 rows/sec within resource budgets.

### 2. Write-Path NVMe Cache Population

ClickHouse's `cache_on_write_operations = 1` guarantees that every INSERT populates the NVMe cache immediately (write-through). Queries on recently ingested data never go to S3 cold.

StarRocks' default data cache behavior is read-through: the NVMe cache is populated on first read, not on write. After a batch ingest, the data is in S3 but not yet in the NVMe cache. If a query targets recently ingested data before it has been accessed, it reads from S3 (higher latency).

`datacache_populate_mode = auto` attempts to populate the cache on writes that are likely to be queried soon, but this is a heuristic, not a strict write-through guarantee. The actual cache warmth of freshly ingested data must be measured in PoC, particularly for dashboard queries that execute within minutes of ingest completion.

### 3. kube-starrocks Operator Maturity

The Altinity Operator for ClickHouse (version 0.26.0+) is a mature, production-hardened tool with extensive documentation, community adoption, and known behavior in upgrade and failure scenarios.

kube-starrocks is a younger operator. The following behaviors must be validated in PoC before production deployment:
- Rolling upgrade behavior for FE and CN nodes separately.
- FE leader failover timing during pod restart.
- Routine Load continuity during FE leader failover (do in-flight batches complete or are they dropped?).
- Vault Agent Sidecar integration for secret injection into FE/CN config.
- CN scale-out (add CN pod → automatic tablet rebalancing trigger).

### 4. Pipe Maturity

StarRocks Pipe was introduced in 3.2 (2023). S3Queue in ClickHouse is also relatively recent but has more community production case studies. Specific gaps:
- FE leader failover during an active Pipe load task: is the task retried automatically or lost?
- Behavior when the source S3 bucket has millions of processed files in FE metadata.
- Error visibility: S3Queue writes error details to `system.s3queue_log`; Pipe requires querying `information_schema.pipe_files` for file-level status.

### 5. DLQ Routing

ClickHouse's `kafka_handle_error_mode = 'stream'` + `_error` virtual column makes DLQ routing **automatic and built-in**. The DLQ MV (`mv_kafka_dlq`) fires on the same Kafka batch that produces errors; malformed rows are written to the DLQ table in the same transaction as the main ingest. No external process required.

StarRocks Routine Load writes error row details to CN-local error log files. To populate a DLQ table, an external monitoring process must:
1. Poll `SHOW ROUTINE LOAD TASK FOR job_name` for error log file URLs.
2. Fetch the error log files from each CN that reported errors.
3. Parse the log files and insert error rows into the DLQ table.

This is operationally more complex and introduces a time lag between the error occurrence and DLQ availability.

### 6. Ecosystem and Community Size

ClickHouse has a larger open-source community, more third-party integrations, more Stack Overflow answers, and a larger body of published production incident reports. A larger community means faster debugging of unusual problems and more shared tooling.

StarRocks' community is smaller and growing. The consequence is less publicly available troubleshooting guidance for edge cases. This is a practical operational concern for teams without in-house StarRocks expertise.

### 7. Shared-Data Mode Maturity

StarRocks shared-data mode has been production-available since approximately 2023. It has fewer public production case studies at the scale of 5B rows/day with S3-backed primary storage than ClickHouse's S3-backed MergeTree. Specifically:
- Long-term compaction behavior at scale (tablet fragmentation after 90+ days of daily partitions).
- FE metadata growth rate with `partition_ttl` and dynamic partition management at high partition count.
- S3 API rate limits under sustained Pipe + Routine Load + query workloads.

These are not known problems — they are areas where ClickHouse has more public evidence of behavior at scale.

### 8. ClickHouse Function Library Richness

ClickHouse has one of the largest built-in function libraries of any OLAP database, with particular strength in:
- **HyperLogLog**: `uniq`, `uniqCombined`, `uniqExact` — approximate and exact cardinality at different cost/accuracy trade-offs.
- **Bitmap**: `bitmapAnd`, `bitmapOr`, `bitmapCardinality` — efficient set operations on integer sets.
- **Time series**: `runningAccumulate`, `runningDifference`, `timeSlots`, `toStartOfInterval` — window/aggregation functions tuned for time series.
- **String**: extensive regular expression, similarity, and encoding functions.

StarRocks' function library is smaller, though most common analytical functions are present. Workloads that rely heavily on ClickHouse-specific HLL functions, bitmap operations, or specialized time-series aggregates will require adaptation.

### 9. Column Compression

ClickHouse offers custom codecs specifically tuned for time-series data:
- **Delta**: for slowly incrementing integers (timestamps, counters).
- **DoubleDelta**: for second-order differences (monotonic sequences).
- **Gorilla**: for floating-point sequences with similar consecutive values.
- These can be combined with LZ4 or ZSTD for additional compression.

StarRocks uses standard columnar compression: LZ4, Zstd, Snappy. For datasets where custom codecs provide significant compression gains (typical: timestamp columns, counter sequences), ClickHouse may achieve meaningfully better storage efficiency. For general mixed-type payloads the difference is less significant.

---

## 14. Decision Framework

Use this framework when evaluating StarRocks vs ClickHouse for new projects or migration decisions. This is not exhaustive — always run a PoC against your actual data and query patterns.

### Choose StarRocks if:

- **You need native UPDATE/DELETE/UPSERT without workarounds.** The Primary Key model makes these first-class operations. In ClickHouse, they require workarounds (`patch parts`, `ALTER TABLE UPDATE`, `OPTIMIZE PARTITION FINAL`) that are expensive and operationally complex.

- **Compliance deletes must be logically inaccessible immediately.** StarRocks DELETE makes rows invisible upon statement completion. ClickHouse lightweight delete requires `OPTIMIZE PARTITION FINAL` to achieve the same — potentially hours later at scale.

- **Horizontal scaling (adding compute) without data migration is required.** Adding a CN triggers automatic tablet redistribution. ClickHouse cache cluster resharding is a multi-hour planned operation.

- **MySQL-compatible SQL and standard tooling are important.** Any MySQL-speaking tool works with StarRocks. ClickHouse requires custom drivers or the HTTP API.

- **Zero-copy replication risk is unacceptable and ClickHouse Cloud (SharedMergeTree) is not an option.** Open-source ClickHouse's zero-copy mechanism has documented GC race conditions. StarRocks shared-data mode eliminates this class of problem architecturally.

- **Multi-table JOINs are a significant part of the query workload.** StarRocks' MPP optimizer and colocate join support handle multi-table queries well. ClickHouse is designed for single-table wide-format scans.

- **Topology simplicity is valued.** StarRocks collapses 19–21 pods across three separate concerns into 10 pods across two tiers. Fewer components to operate, monitor, and upgrade.

- **Transient duplicates in queries are not acceptable.** If your application cannot tolerate duplicate rows between INSERT and background merge, StarRocks Primary Key eliminates the problem entirely.

### Choose ClickHouse if:

- **Ingest rate is extremely high and zero write-path dedup overhead is required.** `ReplicatedReplacingMergeTree` defers all dedup overhead to background merge threads. INSERT throughput is not impacted by dedup lookups. At multi-hundred-thousand rows/sec, this is a meaningful advantage.

- **You need ClickHouse's rich function library.** If your workload relies heavily on HLL cardinality estimation, bitmap set operations, Gorilla/Delta codecs for time-series compression, or ClickHouse-specific aggregation functions, there is no equivalent in StarRocks.

- **Team has existing ClickHouse expertise and established tooling.** Operational knowledge, monitoring dashboards, runbooks, and incident response procedures built for ClickHouse are not transferable to StarRocks. The learning curve is real, and the risk of production incidents increases during the expertise ramp-up period.

- **Single-table wide-format analytical queries dominate the workload.** ClickHouse's push-based columnar engine and extensive compression options are highly optimized for this pattern. If your query workload is primarily wide-table scans with minimal JOINs, ClickHouse's per-query performance may be higher.

- **Extremely aggressive columnar compression with custom codecs is required.** If your dataset is time-series in nature and you need maximum storage efficiency, ClickHouse's Delta/DoubleDelta/Gorilla codecs may provide compression ratios that StarRocks' standard codecs cannot match.

- **ClickHouse Cloud is an option.** If you can use ClickHouse Cloud, SharedMergeTree replaces the zero-copy mechanism with a safe, production-hardened alternative. This eliminates ClickHouse's primary architectural risk and makes it a stronger contender.

### Choose Neither Without PoC Validation if:

- **>10 compliance user-ID deletes per night.** Both systems face the serialization and scaling challenge of physical byte removal across many partitions. The 24h SLA for physical removal must be measured at production partition sizes and realistic nightly batch volumes. StarRocks has an advantage (immediate logical inaccessibility; parallelized compaction), but physical removal timing still requires measurement.

- **>57,870 rows/sec sustained Kafka ingest.** This architecture is designed for ~57,870 rows/sec across 7 CNs (~8,267 rows/sec per CN). Higher rates require validation of both Routine Load sub-task throughput and Primary Key lookup latency under load.

- **S3-backed primary storage with NVMe cache, requiring consistent query latency on freshly ingested data.** Both systems require PoC validation of cache warmth after ingest. ClickHouse `cache_on_write_operations = 1` provides a stronger guarantee; StarRocks `datacache_populate_mode = auto` must be measured against your actual query latency SLA.

---

*For deployment details, pod resource specs, operator configuration, and YAML manifests, see `starrocks-architecture.md`. For ClickHouse production architecture, see `architecture.md`.*

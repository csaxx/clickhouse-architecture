# ClickHouse Configuration Reference

Companion document to [architecture.md](architecture.md). Contains annotated DDL templates and server configuration baselines for all table types in this architecture. Placeholders marked **TBD** depend on open questions (see [architecture.md — Open Questions](architecture.md#8-open-questions)) and must be confirmed before YAML authoring begins.

## Table of Contents

1. [Database Engine: `Replicated` vs Default (`Atomic` + `ON CLUSTER`)](#1-database-engine-replicated-vs-default)
2. [Cache Cluster Tables](#2-cache-cluster-tables)
3. [Ingest Cluster Tables](#3-ingest-cluster-tables)
4. [Global Server Settings](#4-global-server-settings)
5. [Cache Disk Sizing](#5-cache-disk-sizing)

---

## 1. Database Engine: `Replicated` vs Default (`Atomic` + `ON CLUSTER`)

ClickHouse databases default to the `Atomic` engine. DDL statements (`CREATE TABLE`, `ALTER TABLE`, `DROP TABLE`) apply only to the local node — to propagate DDL across a cluster, every statement must carry `ON CLUSTER <cluster_name>`.

The **`Replicated` database engine** (`ENGINE = Replicated(...)`, ClickHouse 22+) changes this: DDL operations are committed to Keeper and replayed automatically on every node registered to the database's replication group, including nodes that were offline when the DDL was issued.

### Comparison

| Dimension | `Atomic` + `ON CLUSTER` | `Replicated` database engine |
|---|---|---|
| **DDL propagation** | Explicit `ON CLUSTER` required on every `CREATE`, `ALTER`, `DROP` statement | Automatic within the replication group |
| **Node rejoining late** | Node misses DDL while down; must be replayed manually or via `system.distributed_ddl_queue` retry | Node replays all missed DDL from Keeper on startup — zero manual intervention |
| **Cross-shard coverage** | `ON CLUSTER <name>` reaches all nodes in the cluster (all shards + replicas) | Replicated DB syncs within its replication group (one group per shard's replica pair); `ON CLUSTER` is still required for cross-shard DDL |
| **Keeper load** | DDL creates entries in the distributed DDL log (`/clickhouse/task_queue/ddl/`) | Additional Keeper znodes per database instance per replica; higher base Keeper write rate for large clusters |
| **Operator compatibility** | Default; fully supported by Altinity operator | Supported in ClickHouse 22+; **validate** that Altinity 0.26.0+ correctly manages `Replicated` database lifecycle in PoC |
| **Troubleshooting** | `system.distributed_ddl_queue` | `system.distributed_ddl_queue` + database-level Keeper znodes; more complex |

### Recommendation

**Cache cluster (7×2)**: Use `Replicated` database. The 2 replicas of each cache shard must stay in schema sync. With a `Replicated` database, schema changes propagate automatically to the second replica — including replicas that were restarting when the DDL was issued. This eliminates the most common source of replica schema divergence during rolling upgrades.

`ON CLUSTER 'cache'` is still required on all DDL statements to distribute across all 7 shards. Within each shard, the replica pair self-synchronizes via the `Replicated` database and Keeper.

**Ingest cluster (2×1)**: Use the default `Atomic` engine. Ingest nodes are single-replica per shard; there is no intra-shard replica to synchronize. All DDL uses `ON CLUSTER 'ingest'`.

```sql
-- One-time setup: create the Replicated database on all cache nodes
CREATE DATABASE IF NOT EXISTS cache_db
ON CLUSTER 'cache'
ENGINE = Replicated(
    '/clickhouse/databases/cache_db',  -- Keeper path; unique per database instance
    '{shard}',                         -- shard macro populated by Altinity operator
    '{replica}'                        -- replica macro populated by Altinity operator
);
```

> **PoC validation required**: Confirm that Altinity operator 0.26.0+ correctly handles a `Replicated` database — creation on initial deploy, DDL propagation after pod restart, and compatibility with operator-managed `macros` and `remote_servers`. See [Open Question #12](architecture.md#8-open-questions).

---

## 2. Cache Cluster Tables

### Cache Data Table — `ReplicatedReplacingMergeTree`

```sql
CREATE TABLE cache_db.cache_table
ON CLUSTER 'cache'
(
    -- Schema TBD. Structural columns required by this architecture are listed below.
    -- Remaining payload columns to be determined by the application team.
    event_date     Date,         -- partition key source column
    event_ts       UInt64,       -- event timestamp in milliseconds; candidate ver column (Q6)
    user_id        UInt64,       -- compliance DELETE target; candidate sharding key column (Q7)
    eviction_date  Date,         -- TTL source: row expires when eviction_date < today
    _ver           UInt64        -- ReplacingMergeTree ver column; TBD (Q6)
                                 -- recommended: same as event_ts, or a dedicated monotonic sequence number
    -- ... additional payload columns TBD
)
ENGINE = ReplicatedReplacingMergeTree(
    '/clickhouse/tables/{cluster}/{shard}/cache_db/cache_table',  -- Keeper path; {cluster}/{shard} macros from operator
    '{replica}',   -- replica macro from operator
    _ver           -- row with highest _ver is kept on dedup at merge time; TBD (Q6)
)
PARTITION BY toYYYYMMDD(event_date)    -- daily partitions; confirmed
ORDER BY (user_id, event_ts)           -- primary key / sort key; TBD — align with dominant query WHERE / GROUP BY patterns
TTL eviction_date DELETE               -- time-based physical expiry
SETTINGS
    -- Zero-copy: both replicas reference the same S3 parts; no replica-to-replica byte transfer
    allow_remote_fs_zero_copy_replication   = 1,
    -- Drop entire S3 parts when all rows in the part have expired TTL.
    -- Avoids a full merge-rewrite; provides instant physical deletion.
    -- Required to satisfy the 24-hour TTL SLA with daily partitions.
    TTL_only_drop_parts                     = 1,
    -- Parts >= 10 MB use columnar (wide) format: better compression and column pruning at query time.
    -- At 1M-row Kafka batches, parts will typically exceed this threshold immediately.
    min_bytes_for_wide_part                 = 10485760,
    min_rows_for_wide_part                  = 0,          -- size-based threshold only
    -- INSERT-level dedup window: track the last 1000 INSERT block checksums.
    -- Rejects re-delivered Kafka batches with the same block checksum (same data retried after failure).
    replicated_deduplication_window         = 1000,
    replicated_deduplication_window_seconds = 604800;     -- 7-day INSERT dedup window
```

**`ORDER BY` design note**: The sort key determines both query performance and dedup correctness. `ReplacingMergeTree` collapses all rows sharing the same `ORDER BY` key at merge time, retaining the row with the highest `_ver`. Put the most-selective query filter columns first. If compliance queries and application queries both filter primarily by `user_id`, placing `user_id` first in the sort key is correct. Finalize the ORDER BY alongside the query pattern analysis — this choice is hard to change after data is written.

### Cache Distributed Query Table — `Distributed`

Resides on every cache node. Clients query this table; ClickHouse fans out to all 7 shards automatically.

```sql
CREATE TABLE cache_db.cache_distributed
ON CLUSTER 'cache'
    AS cache_db.cache_table              -- inherits schema; no column list needed
ENGINE = Distributed(
    'cache',                             -- cluster name; auto-populated in remote_servers by Altinity operator
    'cache_db',
    'cache_table',
    xxHash64(sharding_column)            -- sharding key; TBD (Q7) — must match the ingest-side write Distributed table
);
```

---

## 3. Ingest Cluster Tables

### Distributed Write Table (ingest → cache)

Create this before KafkaEngine and S3Queue tables. Materialized Views use it as the INSERT target.

```sql
CREATE TABLE default.cache_writer
ON CLUSTER 'ingest'
(
    -- Schema must match cache_db.cache_table exactly
    event_date     Date,
    event_ts       UInt64,
    user_id        UInt64,
    eviction_date  Date,
    _ver           UInt64
    -- ... additional payload columns TBD
)
ENGINE = Distributed(
    'cache',                      -- target cluster; auto-populated by operator in remote_servers
    'cache_db',
    'cache_table',
    xxHash64(sharding_column)     -- sharding key; TBD (Q7) — must match cache query Distributed table
);
```

**Async vs synchronous inserts**: By default, Distributed INSERTs are buffered locally and sent asynchronously. To make MV→cache INSERTs synchronous — waiting for the cache shard to confirm before the KafkaEngine offset is committed — set the user-level setting `insert_distributed_sync = 1` in the ClickHouse user profile used by the ingest tables. Synchronous inserts eliminate the data-loss window described in [architecture.md §7.4](architecture.md#74-kafkaengine-at-least-once-delivery-risk) but add one network RTT per batch. Measure the throughput impact against the ~29k rows/sec target during PoC before committing to either mode.

### KafkaEngine Table

One table per ingest shard. **The `kafka_group_name` must be unique per shard** — two consumers in the same group for the same topic receive only a subset of partitions each, effectively losing messages.

```sql
CREATE TABLE default.kafka_ingest
ON CLUSTER 'ingest'
(
    -- Source message schema TBD; columns must match or be transformable to cache_table schema
    event_ts       UInt64,
    user_id        UInt64,
    eviction_date  Date
    -- ... additional source columns TBD
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list         = 'kafka-broker-0:9092,kafka-broker-1:9092',  -- TBD (Q5)
    kafka_topic_list          = 'events',                                    -- TBD (Q5)
    -- Consumer group MUST be unique per ingest shard.
    -- The {shard} macro is populated per-pod by the Altinity operator.
    kafka_group_name          = 'clickhouse_ingest_{shard}',
    kafka_format              = 'JSONEachRow',              -- TBD: JSONEachRow / AvroConfluent / Protobuf
    -- Rows per MV batch. At ~29k rows/sec per ingest shard, a 1M-row batch completes in ~35 sec.
    -- Critical for controlling part creation frequency — see architecture.md §1.1.
    kafka_max_block_size      = 1048576,
    -- Consumer threads per table. Start with 1; increase only if a single thread
    -- cannot sustain ~29k rows/sec. Monitor consumer lag to assess.
    kafka_num_consumers       = 1,
    -- Max time to wait for a full kafka_max_block_size batch before firing a partial batch.
    -- 7500 ms is the default. Reduce to ~1000 ms if low-latency delivery is required.
    kafka_flush_interval_ms   = 7500,
    -- 'stream' exposes _error and _raw_message virtual columns in the MV,
    -- enabling dead-letter queue routing for malformed messages without halting the consumer.
    kafka_handle_error_mode   = 'stream',
    -- Do not silently skip broken messages (default 0).
    -- Requires explicit DLQ handling via a second Materialized View (see below).
    kafka_skip_broken_messages = 0,
    -- Max Kafka messages fetched per poll call (default 65536).
    kafka_poll_max_batch_size = 65536;
```

### Kafka Materialized View

```sql
CREATE MATERIALIZED VIEW default.mv_kafka_to_cache
ON CLUSTER 'ingest'
TO default.cache_writer         -- Distributed table routing rows to the cache cluster
AS SELECT
    toDate(toDateTime64(event_ts / 1000, 3))  AS event_date,  -- derive Date from ms timestamp
    event_ts,
    user_id,
    eviction_date,
    event_ts                                   AS _ver         -- ver column; TBD (Q6)
    -- ... additional column transforms TBD
FROM default.kafka_ingest
WHERE length(_error) = 0;       -- filter out parse errors; requires kafka_handle_error_mode = 'stream'
```

**Dead-letter queue MV** — add alongside the main MV when `kafka_handle_error_mode = 'stream'`:

```sql
CREATE MATERIALIZED VIEW default.mv_kafka_dlq
ON CLUSTER 'ingest'
TO default.kafka_dead_letters   -- a Log or MergeTree table for error inspection / alerting
AS SELECT
    _raw_message,
    _error,
    now() AS captured_at
FROM default.kafka_ingest
WHERE length(_error) > 0;
```

### S3Queue Table

```sql
CREATE TABLE default.s3queue_ingest
ON CLUSTER 'ingest'
(
    -- Source file schema TBD; must match or be transformable to cache_table schema
    event_ts       UInt64,
    user_id        UInt64,
    eviction_date  Date
    -- ... additional source columns TBD
)
ENGINE = S3Queue(
    's3://source-bucket/path/**',  -- TBD: glob pattern for source files
    'JSONEachRow'                  -- TBD: file format (JSONEachRow / Parquet / CSV / etc.)
    -- Credentials: do NOT embed inline. Inject via named collection or XML config drop-in
    -- written by Vault Agent Sidecar — see architecture.md §6.4.
)
SETTINGS
    -- 'ordered': process files in S3 listing order; file state tracked in Keeper.
    -- Use 'unordered' if files can arrive out-of-order or be re-uploaded at any time.
    mode                                      = 'ordered',
    -- Parallel file download/parse threads per ingest node.
    -- Tune to available vCPU and S3 bandwidth; 4 is a reasonable starting point.
    s3queue_processing_threads_num            = 4,
    -- Files processed before Keeper state commit.
    -- Higher = less Keeper I/O; lower = less re-processing on unexpected restart.
    s3queue_max_processed_files_before_commit = 100,
    -- Log processing events to system.s3queue_log for observability and debugging.
    s3queue_enable_logging_to_s3queue_log     = 1,
    -- Max Keeper entries for processed-file state. Prevents Keeper znode bloat at high file counts.
    s3queue_tracked_files_limit               = 1000000,
    -- How long to retain "processed" file entries in Keeper.
    -- Files that re-appear in S3 after this TTL will be re-processed.
    s3queue_tracked_file_ttl_sec              = 604800,   -- 7 days
    s3queue_polling_min_timeout_ms            = 1000,
    s3queue_polling_max_timeout_ms            = 10000;
```

### S3Queue Materialized View

```sql
CREATE MATERIALIZED VIEW default.mv_s3queue_to_cache
ON CLUSTER 'ingest'
TO default.cache_writer
AS SELECT
    toDate(toDateTime64(event_ts / 1000, 3))  AS event_date,
    event_ts,
    user_id,
    eviction_date,
    event_ts                                   AS _ver
    -- ... additional column transforms TBD
FROM default.s3queue_ingest;
```

---

## 4. Global Server Settings

Delivered as XML drop-in files placed in `/etc/clickhouse-server/config.d/` and `/etc/clickhouse-server/users.d/`. In the Altinity operator CHI YAML these map to the `configuration.files` section. Values below are starting-point recommendations; tune based on observed system metrics.

### Cache Node — Server Settings (`config.d/server-settings.xml`)

```xml
<clickhouse>
    <!-- ───── Background thread pools ───── -->

    <!--
        Merge and mutation threads per server.
        At ~714M rows/shard/day + 10–20% dedup pressure from ReplacingMergeTree, plus nightly
        compliance DELETE mutations, 16 threads sustains concurrent merge activity without queue backlog.
        Increase to 32 if system.merges shows persistent queue depth above ~100.
    -->
    <background_pool_size>16</background_pool_size>

    <!--
        Replication fetch threads. With zero-copy replication, replicas reference the same S3 parts
        rather than copying bytes. These threads are used only during initial replica catch-up
        (e.g., after pod restart). 8 is sufficient for a 2-replica-per-shard topology.
    -->
    <background_fetches_pool_size>8</background_fetches_pool_size>

    <!--
        Scheduled background tasks: TTL expiry checks, replica health checks, part moves.
        16 provides headroom for concurrent nightly TTL drops alongside normal merge activity.
    -->
    <background_schedule_pool_size>16</background_schedule_pool_size>

    <!-- Part movement between storage volumes. Minimal relevance for a single write-through policy. -->
    <background_move_pool_size>4</background_move_pool_size>

    <!-- ───── Memory ───── -->

    <!--
        Server-level memory cap at 85% of available RAM.
        Leaves headroom for OS page cache (critical for NVMe cache hit performance).
        Do not exceed 90%; above that, OS memory pressure degrades cache hit rates.
    -->
    <max_server_memory_usage_to_ram_ratio>0.85</max_server_memory_usage_to_ram_ratio>

    <!-- ───── Connections and concurrency ───── -->

    <max_connections>4096</max_connections>

    <!-- Total concurrent queries including reads and inserts. -->
    <max_concurrent_queries>200</max_concurrent_queries>

    <!-- INSERT concurrency budget, separate from the read concurrency budget. -->
    <max_concurrent_insert_queries>50</max_concurrent_insert_queries>

    <!-- ───── MergeTree settings ───── -->

    <merge_tree>
        <!--
            Parts-before-INSERT-slowdown per partition (default 300).
            With kafka_max_block_size = 1048576, each Kafka batch produces ~1 part per ~35 sec.
            Under normal load this limit is never approached; it exists as a safety backstop.
        -->
        <parts_to_delay_insert>300</parts_to_delay_insert>

        <!--
            Parts-before-INSERT-rejection (default 3000). Lowered to 1000 as an early warning.
            At 1000 parts, the merge system is severely behind; catching it here allows
            investigation before the hard limit is reached.
        -->
        <parts_to_throw_insert>1000</parts_to_throw_insert>

        <!-- Hard upper bound on total parts across all partitions on this server. -->
        <max_parts_in_total>200000</max_parts_in_total>

        <!--
            Minimum interval between TTL-triggered merges per partition, in seconds.
            Default is 14400 (4 hours). Set to 60 so expired parts are dropped promptly,
            providing substantial margin against the 24-hour TTL SLA.
            Increase to 3600 if TTL merges compete with ingest merge pressure under sustained load.
        -->
        <merge_with_ttl_timeout>60</merge_with_ttl_timeout>

        <!--
            Wide-part format threshold. Parts >= 10 MB use columnar (wide) format,
            which is required for good compression ratios and column pruning at query time.
            At 1M-row Kafka batches, parts will typically exceed 10 MB immediately.
        -->
        <min_bytes_for_wide_part>10485760</min_bytes_for_wide_part>
    </merge_tree>
</clickhouse>
```

### Cache Node — User/Query Settings (`users.d/query-settings.xml`)

```xml
<clickhouse>
    <profiles>
        <default>
            <!-- Per-query memory limit. 10 GB is a conservative starting point; tune per workload. -->
            <max_memory_usage>10737418240</max_memory_usage>

            <!-- Spill to disk when per-query memory limit is approached. -->
            <max_bytes_before_external_group_by>5368709120</max_bytes_before_external_group_by>
            <max_bytes_before_external_sort>5368709120</max_bytes_before_external_sort>

            <!--
                INSERT-level deduplication for ReplicatedMergeTree tables (default 1 = enabled).
                Tracks recent INSERT block checksums and rejects re-delivered blocks with the same hash.
                This is the primary guard against KafkaEngine at-least-once re-delivery producing
                duplicate data parts at the storage layer.
                Do not disable.
            -->
            <insert_deduplicate>1</insert_deduplicate>
        </default>
    </profiles>
</clickhouse>
```

### Ingest Node — Server Settings (`config.d/server-settings.xml`)

```xml
<clickhouse>
    <!--
        KafkaEngine and S3Queue polling scheduler threads.
        Each KafkaEngine table with kafka_num_consumers = 1 consumes 1 thread.
        Each S3Queue table uses s3queue_processing_threads_num threads.
        16 provides headroom for 2 Kafka tables + 2 S3Queue tables per node, with room for growth.
    -->
    <background_message_broker_schedule_pool_size>16</background_message_broker_schedule_pool_size>

    <!--
        Distributed table async send threads.
        If using synchronous Distributed inserts (insert_distributed_sync = 1 in user profile),
        this pool is not exercised. If using async mode, size to sustain peak INSERT throughput.
    -->
    <background_distributed_schedule_pool_size>8</background_distributed_schedule_pool_size>

    <!--
        Merge threads. Ingest nodes hold no persistent user data; merges are minimal.
        4 is sufficient for the transient local parts created before MV fires.
    -->
    <background_pool_size>4</background_pool_size>

    <max_server_memory_usage_to_ram_ratio>0.80</max_server_memory_usage_to_ram_ratio>
    <max_connections>1024</max_connections>
    <max_concurrent_queries>100</max_concurrent_queries>
</clickhouse>
```

---

## 5. Cache Disk Sizing

The NVMe cache `max_size` is TBD pending resolution of [Open Question #8](architecture.md#8-open-questions) (per-shard data volume and compressed row size). The formula and worked examples below allow sizing once the row size is measured in the PoC.

### Sizing Formula

```
rows_per_shard_per_day  = 5,000,000,000 × (1 − duplicate_rate) ÷ 7
                        ≈ 643,000,000 rows/shard/day   (at 15% duplicate rate)

total_shard_rows        = rows_per_shard_per_day × retention_days

compressed_shard_size   = total_shard_rows × compressed_bytes_per_row

nvme_cache_target       = compressed_shard_size × working_set_fraction
                          (recommended starting point: 0.25 = 25% of total shard data)

nvme_pvc_size           = nvme_cache_target × 1.15
                          (15% headroom above max_size to prevent the underlying filesystem from filling)
```

Typical ClickHouse columnar compression for production event schemas: **20–200 compressed bytes/row**. The actual value depends heavily on schema width, string cardinality, and codec choices. Measure compressed row size during PoC using `SELECT sum(data_compressed_bytes) / sum(rows) FROM system.parts WHERE table = 'cache_table'`.

### Worked Examples

| Compressed bytes/row | Retention | Total per shard | 25% cache (`max_size`) | PVC (+15% headroom) |
|---|---|---|---|---|
| 50 B/row | 30 days | ~965 GB | ~241 GB | **~278 GB** |
| 50 B/row | 90 days | ~2.9 TB | ~725 GB | **~833 GB** |
| 100 B/row | 30 days | ~1.93 TB | ~482 GB | **~554 GB** |
| 100 B/row | 90 days | ~5.8 TB | ~1.44 TB | **~1.66 TB** |
| 200 B/row | 30 days | ~3.85 TB | ~963 GB | **~1.11 TB** |
| 200 B/row | 90 days | ~11.6 TB | ~2.9 TB | **~3.33 TB** |

> **Retention period** is also TBD. Resolve as part of Open Question #8 alongside row size. Both inputs are required to select Kubernetes storage classes and node instance types.

### Storage Configuration Reference

```xml
<!-- config.d/storage.xml on each cache node (one file per node, shard endpoint differs per shard) -->
<clickhouse>
    <storage_configuration>
        <disks>
            <s3_main>
                <type>s3</type>
                <!-- Shard-specific prefix; {shard} macro populated by operator -->
                <endpoint>https://minio-endpoint/bucket/clickhouse/cache/shard-{shard}/</endpoint>
                <!-- Credentials injected by Vault Agent Sidecar into a separate config.d file; see architecture.md §6.4 -->
                <use_environment_credentials>false</use_environment_credentials>
            </s3_main>
            <nvme_cache>
                <type>cache</type>
                <disk>s3_main</disk>
                <path>/var/lib/clickhouse/s3_cache/</path>
                <!-- Replace with the computed nvme_cache_target value from the formula above -->
                <max_size>274877906944</max_size>          <!-- example: 256 GiB; update before deployment -->
                <!-- Write-through: INSERTs populate the NVMe cache immediately on write -->
                <cache_on_write_operations>1</cache_on_write_operations>
                <!-- 100 MB cache segment files; balance between I/O granularity and file-count overhead -->
                <max_file_segment_size>104857600</max_file_segment_size>
                <!-- Cache on first access (threshold 0); increase to 1 or 2 to avoid caching rarely-read parts -->
                <cache_hits_threshold>0</cache_hits_threshold>
            </nvme_cache>
        </disks>
        <policies>
            <cache_policy>
                <volumes>
                    <main>
                        <disk>nvme_cache</disk>
                    </main>
                </volumes>
            </cache_policy>
        </policies>
    </storage_configuration>
</clickhouse>
```

**`max_size` vs PVC size**: Set `max_size` to the computed `nvme_cache_target`. ClickHouse LRU-evicts parts when used space reaches `max_size`. Size the Kubernetes PVC to `max_size × 1.15` to ensure the underlying filesystem never runs full — ClickHouse does not pre-allocate `max_size` at startup.

**Cache hit rate monitoring**:

```sql
SELECT
    cache_name,
    formatReadableSize(size)        AS max_cache_size,
    formatReadableSize(used_size)   AS used,
    hits,
    misses,
    round(hits / (hits + misses) * 100, 1) AS hit_rate_pct
FROM system.filesystem_cache;
```

A sustained hit rate below ~90% on production queries indicates the NVMe cache is undersized for the active working set. Increase `max_size` (and resize the PVC accordingly) before S3 read latency begins affecting query SLAs.

-- =============================================================================
-- 03_events_table.sql
-- Primary Key events table — the single persistent storage and query table.
--
-- Run after: 02_database.sql
-- Target: any FE node via MySQL client (port 9030)
--
-- Engine: PRIMARY KEY (merge-on-write deduplication)
--   Rows sharing the same PRIMARY KEY are deduplicated on INSERT: the incoming
--   row replaces the stored row immediately. No transient duplicates are visible
--   at any point. This is a strict improvement over ClickHouse's
--   ReplicatedReplacingMergeTree, which deduplicates at merge time and exposes
--   transient duplicates between INSERT and the next background merge.
--
-- Storage: shared-data mode with local NVMe data cache.
--   All writes go to S3 (source of truth). Hot tablet pages are cached on the
--   local NVMe SSD of each CN (datacache_enable = true). This is directly
--   analogous to ClickHouse's 'cache' disk type wrapping an 's3' disk.
--
-- Partitioning: daily by event_date.
--   Daily partitions satisfy the 24-hour TTL SLA for time-based expiry.
--   StarRocks drops the entire partition and its S3 objects when the TTL fires.
--   No in-partition row-level rewrite is needed — equivalent to ClickHouse's
--   TTL_only_drop_parts = 1.
--
-- This table replaces ALL of the following ClickHouse objects:
--   cache_db.cache_table  (ReplicatedReplacingMergeTree, 7 shards × 2 replicas)
--   cache_db.cache_distributed  (Distributed query table)
--   default.cache_writer  (Distributed write table on ingest nodes)
-- All three are unified into this single table because FE routes both ingest
-- writes (from Routine Load sub-tasks) and query reads (to CNs) automatically.
--
-- TBD values (resolve before production deploy):
--   - Full payload column list              (application team)
--   - PRIMARY KEY columns                   (confirm deduplication key — may be composite)
--   - DISTRIBUTED BY HASH(col)              (Open Decision #5)
--   - BUCKETS count                         (Open Decision #8; default: 21 = 3 × 7 CNs)
--   - ORDER BY sort key                     (align with dominant query WHERE / GROUP BY)
--   - partition_ttl retention period        (compliance/legal team)
--   - dynamic_partition.start retention     (align with partition_ttl)
--   - datacache_partition_duration          (how many recent days to keep NVMe-hot)
-- =============================================================================

CREATE TABLE IF NOT EXISTS events_db.events
(
    -- -------------------------------------------------------------------------
    -- Structural columns required by this architecture.
    -- Additional payload columns to be defined by the application team.
    -- -------------------------------------------------------------------------

    -- Primary key column: used for merge-on-write deduplication.
    -- Incoming rows with the same event_id replace the stored row on INSERT.
    -- TBD: confirm whether the natural dedup key is a single column or composite
    --   (e.g., (event_id) or (user_id, event_ts)). A wider primary key increases
    --   write-path lookup overhead — keep it as narrow as the dedup requirement allows.
    event_id        BIGINT          NOT NULL  COMMENT "Deduplication primary key",

    -- Compliance DELETE target. Nightly batch deletes all rows for a given user_id.
    -- Logical inaccessibility is immediate on DELETE (no OPTIMIZE PARTITION equivalent needed).
    user_id         BIGINT          NOT NULL  COMMENT "User identifier; compliance DELETE target",

    -- Partition key. Must be DATE or DATETIME type.
    -- Derived from event_ts at ingest time (see 04_routine_load.sql COLUMNS expression).
    event_date      DATE            NOT NULL  COMMENT "Event date; daily partition key",

    -- TTL compliance column. Time-based expiry fires when the partition containing
    -- these rows is older than partition_ttl. All rows in the partition are deleted
    -- together with the partition's S3 objects — no per-row TTL evaluation needed.
    -- Set eviction_date = the date by which physical removal must be complete.
    eviction_date   DATE            NOT NULL  COMMENT "Compliance TTL source: row expires at partition drop",

    -- Event timestamp in milliseconds. Used for time-ordering within a partition
    -- and for deriving event_date at ingest time.
    event_ts        BIGINT          NOT NULL  COMMENT "Event timestamp in milliseconds"

    -- Additional payload columns TBD (application team).
    -- Example: event_type VARCHAR(64), payload JSON, session_id BIGINT
)
ENGINE = OLAP

-- PRIMARY KEY defines the deduplication key (merge-on-write).
-- Must list column(s) that appear at the start of the column definition order.
-- TBD: confirm primary key column(s) — see note on event_id above.
PRIMARY KEY (event_id)

-- ORDER BY defines the sort order within each tablet.
-- Determines both query scan performance and compaction efficiency.
-- Must be a prefix of PRIMARY KEY in StarRocks 3.x PRIMARY KEY tables, OR
-- you may specify additional sort columns beyond the primary key columns.
-- Align with the dominant query filter patterns (e.g., if queries filter by
-- user_id first, include it: ORDER BY (event_id, user_id)).
-- This choice is hard to change after data is written — finalize alongside
-- query pattern analysis (analogous to ClickHouse ORDER BY finalization).
-- TBD: finalize sort key.
ORDER BY (event_id)

-- Daily partitions. Initial partition list is empty; dynamic partition management
-- auto-creates future partitions and drops expired ones per the PROPERTIES below.
PARTITION BY RANGE(event_date) ()

-- DISTRIBUTED BY HASH routes rows to tablets by hash of the named column.
-- This determines both Routine Load write distribution across CNs and query
-- parallelism within a partition.
-- TBD: confirm distribution column (Open Decision #5).
--   Candidate: user_id (aligns with compliance DELETE and likely query filters)
--   Candidate: event_id (uniform distribution if UUIDs or monotonic IDs)
-- BUCKETS 21 = 3 × CN count (7 CNs). Rule of thumb: 3× CN count.
-- Adjust if partitions are consistently very large (more buckets) or very small
-- (fewer buckets). See Open Decision #8.
DISTRIBUTED BY HASH(event_id) BUCKETS 21  -- TBD: replace event_id with confirmed distribution column (Open Decision #5)

PROPERTIES (
    -- Shared-data mode: replication_num = 1 means each tablet is assigned to
    -- one CN for compute. Data durability comes from S3 (erasure-coded MinIO or
    -- NetApp), not from CN-level replicas.
    "replication_num" = "1",

    -- Reference the storage volume created in 01_storage_volume.sql.
    -- All tablet data for this table is written to that S3 volume.
    "storage_volume" = "s3_volume",

    -- Persistent Primary Key index stored in S3 (CLOUD_NATIVE), not local disk.
    -- Required for shared-data / CN mode. Without this, StarRocks falls back to
    -- LOCAL storage for the index, which defeats the purpose of CN nodes and will
    -- fail or degrade on pods without persistent local storage.
    "enable_persistent_index" = "true",
    "persistent_index_type"   = "CLOUD_NATIVE",

    -- Enable local NVMe data cache on CN nodes for this table.
    -- Hot tablet pages are cached in the NVMe SSD configured in cn.conf
    -- (datacache_disk_path / datacache_disk_size).
    "datacache_enable" = "true",

    -- Keep the most recent N days of partitions pre-warmed in NVMe cache.
    -- Partitions older than this window are still readable (S3 fallback) but
    -- are not actively cached. Starting point: 7 days.
    -- Tune based on query access pattern analysis in PoC (Open Decision #12).
    "datacache_partition_duration" = "7 DAY",

    -- Dynamic partition management: auto-creates new daily partitions in advance
    -- and drops partitions beyond the retention window.
    "dynamic_partition.enable" = "true",
    "dynamic_partition.time_unit" = "DAY",

    -- Retain partitions for the last 90 days.
    -- TBD: align with compliance retention period and partition_ttl below.
    -- Must satisfy eviction_date requirements: rows must not be evicted before
    -- their eviction_date is reached.
    "dynamic_partition.start" = "-90",

    -- Pre-create partitions 3 days into the future to avoid Routine Load
    -- failures when events with a future event_date arrive.
    "dynamic_partition.end" = "3",

    "dynamic_partition.prefix" = "p",

    -- Bucket count for auto-created partitions. Must match BUCKETS clause above.
    "dynamic_partition.buckets" = "21",

    -- partition_ttl: automatically drop partitions whose date range is older
    -- than this interval. When a partition is dropped, all its S3 objects are
    -- deleted immediately — no in-partition row rewrite is needed.
    -- This satisfies the 24-hour TTL SLA for time-based expiry with daily partitions
    -- (equivalent to ClickHouse's TTL_only_drop_parts = 1).
    -- TBD: confirm with compliance/legal team. Must be >= |dynamic_partition.start|
    -- to prevent TTL from firing before the dynamic partition window.
    "partition_ttl" = "90 DAY"
);

-- Verify table structure:
-- DESCRIBE events_db.events;
-- SHOW CREATE TABLE events_db.events;
-- SHOW PARTITIONS FROM events_db.events ORDER BY PartitionName;

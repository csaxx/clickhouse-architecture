-- =============================================================================
-- 02_cache_table.sql
-- Local replicated data table on each cache shard replica.
--
-- Run after: 01_cache_database.sql
-- Target: cache cluster (ON CLUSTER 'cache' distributes to all 14 pods)
--
-- Engine: ReplicatedReplacingMergeTree
--   Merge-time deduplication: rows sharing the same ORDER BY key are collapsed
--   to the row with the highest _ver value at merge time. Transient duplicates
--   (pre-merge) are acceptable; SELECT ... FINAL must NOT be used.
--
-- Storage: cache_policy routes writes through the NVMe/SSD write-through cache
--   disk (nvme_cache) which wraps the s3_main disk. INSERTs populate the NVMe
--   cache immediately (cache_on_write_operations = 1). Cold data falls back to
--   S3. Zero-copy replication (allow_remote_fs_zero_copy_replication = 1) means
--   both replicas of a shard reference the same S3 parts — no replica-to-replica
--   byte transfer.
--
-- TTL: eviction_date controls time-based physical expiry. TTL_only_drop_parts=1
--   drops entire S3 parts when all rows have expired, avoiding a full rewrite.
--   With daily partitions this satisfies the 24-hour TTL SLA.
--
-- TBD columns / settings (resolve before production deploy):
--   - Additional payload columns (application team)
--   - ORDER BY final sort key — align with dominant query WHERE / GROUP BY
--   - _ver column source (event_ts recommended; or dedicated sequence number)
--   - sharding_column (used in 03_cache_distributed.sql and 04_ingest_cache_writer.sql)
-- =============================================================================

CREATE TABLE IF NOT EXISTS cache_db.cache_table
ON CLUSTER 'cache'
(
    -- Structural columns required by this architecture.
    -- Additional payload columns to be added by the application team.
    event_date    Date,    -- partition key source; derived from event_ts in ingest MVs
    event_ts      UInt64,  -- event timestamp in milliseconds; used as _ver column (TBD: Q6)
    user_id       UInt64,  -- compliance DELETE target; candidate sharding key column (TBD: Q7)
    eviction_date Date,    -- TTL source: row expires when eviction_date < today

    -- ReplacingMergeTree version column.
    -- Row with the highest _ver is retained when duplicates are collapsed at merge time.
    -- Recommendation: set equal to event_ts, or use a dedicated monotonic sequence.
    -- TBD: confirm ver column source (Open Decision #6).
    _ver          UInt64

    -- Additional payload columns TBD (application team)
)
ENGINE = ReplicatedReplacingMergeTree(
    '/clickhouse/tables/{cluster}/{shard}/cache_db/cache_table',  -- Keeper path; {cluster} and {shard} macros from operator
    '{replica}',  -- replica macro from operator
    _ver          -- row with highest _ver is kept on dedup at merge time
)
PARTITION BY toYYYYMMDD(event_date)  -- daily partitions; confirmed
-- Primary key / sort key. TBD: finalize alongside query pattern analysis.
-- user_id first if compliance and application queries both filter primarily by user_id.
-- This choice is hard to change after data is written.
ORDER BY (user_id, event_ts)
TTL eviction_date + INTERVAL 0 DAY DELETE  -- physical row expiry when eviction_date is reached
SETTINGS
    -- Route all parts through the NVMe write-through cache → S3 storage hierarchy.
    -- storage_policy must match the policy name defined in config.d/storage.xml.
    storage_policy                          = 'cache_policy',

    -- Zero-copy replication: both replicas reference the same S3 parts.
    -- No replica-to-replica byte transfer. Requires allow_remote_fs_zero_copy_replication
    -- to also be set in the server-level merge_tree config.
    allow_remote_fs_zero_copy_replication   = 1,

    -- Drop entire S3 parts when all rows in the part have exceeded their TTL.
    -- Avoids a full merge-rewrite and provides near-instant physical deletion.
    -- Required to satisfy the 24-hour TTL SLA with daily partitions.
    TTL_only_drop_parts                     = 1,

    -- Parts >= 10 MB use columnar (wide) format: better compression and column
    -- pruning at query time. At 1M-row Kafka batches, parts typically exceed
    -- this threshold immediately after INSERT.
    min_bytes_for_wide_part                 = 10485760,
    min_rows_for_wide_part                  = 0,  -- size-based threshold only

    -- INSERT-level dedup window: track the last 1000 INSERT block checksums.
    -- Rejects re-delivered Kafka batches with the same block checksum.
    replicated_deduplication_window         = 1000,
    replicated_deduplication_window_seconds = 604800;  -- 7-day INSERT dedup window

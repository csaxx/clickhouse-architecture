-- =============================================================================
-- 04_ingest_cache_writer.sql
-- Distributed write table on the ingest cluster — target for all ingest MVs.
--
-- Run after: 02_cache_table.sql (cache_table must exist before writes land)
-- Target: ingest cluster (ON CLUSTER 'ingest' — created on both ingest pods)
--
-- This table routes INSERT batches from the ingest nodes to the correct cache
-- shard. All Materialized Views on the ingest cluster write TO this table.
-- Create this table BEFORE creating any KafkaEngine or S3Queue Materialized
-- Views; the MVs reference it as their TO target.
--
-- Schema: must exactly match cache_db.cache_table. Any column added to
--   cache_table must also be added here.
--
-- Sharding key: xxHash64(sharding_column) — TBD (Open Decision #7).
--   MUST match the sharding key in 03_cache_distributed.sql.
--
-- Async vs synchronous inserts:
--   Default: Distributed INSERTs are buffered locally and sent asynchronously.
--   For synchronous mode (waits for cache shard ACK before Kafka offset commit),
--   set insert_distributed_sync = 1 in the ingest user profile. Synchronous
--   inserts eliminate the data-loss window from KafkaEngine at-least-once
--   delivery but add one network RTT per batch. Measure throughput impact
--   against the ~29k rows/sec target during PoC before choosing a mode.
-- =============================================================================

CREATE TABLE IF NOT EXISTS default.cache_writer
ON CLUSTER 'ingest'
(
    -- Schema must exactly match cache_db.cache_table
    event_date    Date,
    event_ts      UInt64,
    user_id       UInt64,
    eviction_date Date,
    _ver          UInt64
    -- Additional payload columns TBD (must mirror cache_db.cache_table)
)
ENGINE = Distributed(
    'cache',                      -- target cluster; auto-populated by operator in remote_servers
    'cache_db',
    'cache_table',
    xxHash64(user_id)             -- sharding key TBD (Open Decision #7); replace user_id with confirmed column
);

-- =============================================================================
-- 03_cache_distributed.sql
-- Distributed query table on the cache cluster — client query entry point.
--
-- Run after: 02_cache_table.sql
-- Target: cache cluster (ON CLUSTER 'cache' — created on all 14 pods)
--
-- Clients query cache_db.cache_distributed. ClickHouse fans the query out to
-- all 7 shards automatically and merges results. Do not query cache_table
-- directly for cross-shard reads.
--
-- Sharding key: xxHash64(sharding_column) — TBD (Open Decision #7).
--   The sharding key here MUST match the sharding key used in the ingest-side
--   cache_writer table (04_ingest_cache_writer.sql). A mismatch causes rows to
--   land on the wrong shard for reads.
-- =============================================================================

CREATE TABLE IF NOT EXISTS cache_db.cache_distributed
ON CLUSTER 'cache'
    AS cache_db.cache_table              -- inherits schema; no column list needed
ENGINE = Distributed(
    'cache',                             -- target cluster; auto-populated in remote_servers by Altinity operator
    'cache_db',
    'cache_table',
    xxHash64(user_id)                    -- sharding key TBD (Open Decision #7); replace user_id with confirmed column
);

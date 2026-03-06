-- =============================================================================
-- 01_cache_database.sql
-- Create the Replicated database on all cache nodes.
--
-- Run once during initial cluster setup (idempotent via IF NOT EXISTS).
-- Target: cache cluster (all 7 shards × 2 replicas = 14 pods)
--
-- Why Replicated engine:
--   Each shard has 2 replicas. The Replicated database engine commits DDL to
--   Keeper and replays it automatically on both replicas — including replicas
--   that were offline when the DDL was issued. This eliminates schema
--   divergence during rolling upgrades.
--
--   ON CLUSTER 'cache' is still required to distribute across all 7 shards.
--   Within each shard the replica pair self-synchronizes via Keeper.
--
-- PoC validation required: confirm that Altinity operator 0.26.0+ correctly
-- handles the Replicated database lifecycle (creation, DDL propagation after
-- pod restart, compatibility with operator-managed macros and remote_servers).
-- =============================================================================

CREATE DATABASE IF NOT EXISTS cache_db
ON CLUSTER 'cache'
ENGINE = Replicated(
    '/clickhouse/databases/cache_db',  -- Keeper znode path; must be unique per database instance
    '{shard}',                         -- populated per-pod by the Altinity operator
    '{replica}'                        -- populated per-pod by the Altinity operator
);

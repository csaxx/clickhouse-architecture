-- =============================================================================
-- 08_ingest_s3queue_table.sql
-- S3Queue source table on the ingest cluster.
--
-- Run after: 04_ingest_cache_writer.sql
-- Target: ingest cluster (ON CLUSTER 'ingest')
--
-- This table is NOT a storage table — it is a file-queue connector. It monitors
-- an S3 bucket path and delivers new files to attached Materialized Views.
-- Do not query it directly.
--
-- Mode 'ordered': files are processed in S3 listing order; processed-file state
--   is tracked in Keeper. Use 'unordered' if files can arrive out of order or be
--   re-uploaded at any time.
--
-- Credentials: do NOT embed S3 credentials inline. Inject via a named collection
--   or an XML config drop-in written by Vault Agent Sidecar (see architecture.md §6.4).
--
-- Keeper state:
--   s3queue_tracked_files_limit caps Keeper znodes for processed-file state.
--   s3queue_tracked_file_ttl_sec controls how long "processed" entries are
--   retained; files that re-appear in S3 after this TTL will be re-processed.
--
-- TBD values (resolve before deploy):
--   - S3 source bucket URL and glob pattern  (Open Decision #5)
--   - File format (JSONEachRow / Parquet / CSV — Open Decision #5)
--   - Source file schema / column list
-- =============================================================================

CREATE TABLE IF NOT EXISTS default.s3queue_ingest
ON CLUSTER 'ingest'
(
    -- Source file schema TBD (Open Decision #5).
    -- Columns must match or be transformable to cache_db.cache_table schema.
    event_ts      UInt64,
    user_id       UInt64,
    eviction_date Date
    -- Additional source columns TBD
)
ENGINE = S3Queue(
    's3://source-bucket/path/**',  -- TBD: glob pattern for source files (Open Decision #5)
    'JSONEachRow'                  -- TBD: file format — JSONEachRow / Parquet / CSV (Open Decision #5)
    -- Credentials: do NOT embed here. Inject via named collection or Vault-written XML config drop-in.
)
SETTINGS
    -- 'ordered': process files in S3 listing order; state tracked in Keeper.
    -- Switch to 'unordered' if files can arrive out of order or be re-uploaded.
    mode                                      = 'ordered',

    -- Parallel file download/parse threads per ingest node.
    -- Tune to available vCPU and S3 bandwidth; 4 is a reasonable starting point.
    s3queue_processing_threads_num            = 4,

    -- Files processed per Keeper state commit.
    -- Higher = less Keeper I/O; lower = less re-processing on unexpected restart.
    s3queue_max_processed_files_before_commit = 100,

    -- Log processing events to system.s3queue_log for observability and debugging.
    s3queue_enable_logging_to_s3queue_log     = 1,

    -- Max Keeper entries for processed-file state. Prevents Keeper znode bloat
    -- at high file counts.
    s3queue_tracked_files_limit               = 1000000,

    -- How long to retain "processed" file entries in Keeper (seconds).
    -- Files that re-appear in S3 after this TTL will be re-processed.
    s3queue_tracked_file_ttl_sec              = 604800,    -- 7 days

    s3queue_polling_min_timeout_ms            = 1000,
    s3queue_polling_max_timeout_ms            = 10000;

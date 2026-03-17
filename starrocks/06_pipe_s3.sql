-- =============================================================================
-- 06_pipe_s3.sql
-- Pipe job: continuous S3 source bucket monitoring → events table ingest.
--
-- Run after: 03_events_table.sql
-- Target: any FE node via MySQL client (port 9030)
--
-- ClickHouse equivalent:
--   default.s3queue_ingest    (08_ingest_s3queue_table.sql)
--   default.mv_s3queue_to_cache (09_ingest_s3queue_mv.sql)
--
-- Pipe replaces both the S3Queue table and its Materialized View with a single
-- DDL statement. FE monitors the configured S3 path for new files, dispatches
-- load tasks to CNs, and tracks loaded files in FE metadata (BDB-JE) to prevent
-- double-loading.
--
-- File tracking comparison:
--   ClickHouse S3Queue: file state stored in ClickHouse Keeper znode tree.
--     Both ingest nodes can claim the same S3 bucket; Keeper coordinates
--     exclusive file claims.
--   StarRocks Pipe: file state stored in FE metadata (BDB-JE). Simpler and
--     less fragile under leader failover. No "claim lock" race possible.
--
-- Semantics: at-least-once per file.
--   If a load task fails mid-file, the file is retried.
--   Row-level deduplication (duplicate rows from retried files) is handled by
--   the Primary Key table on INSERT — no extra dedup configuration needed.
--   Files that have been successfully loaded are permanently tracked and will
--   not be re-loaded even if they remain in the S3 source bucket.
--
-- TBD values (resolve before deploy):
--   - S3 source bucket path           (equivalent to CH Open Decision #5)
--   - format                          (parquet / orc / json / csv)
--   - COLUMNS mapping                 (if source schema differs from events table)
--   - Source S3 credentials           (if different from the StarRocks data volume)
--   - poll_interval                   (tune to file arrival frequency)
--   - max_concurrent_tasks            (tune to CN resource availability)
-- =============================================================================

CREATE PIPE IF NOT EXISTS events_db.events_s3_pipe
PROPERTIES
(
    -- Enable automatic file monitoring.
    -- FE polls the S3 path on each poll_interval for new files.
    -- Set to "false" to create the Pipe in paused state for validation before
    -- enabling in production.
    "auto_ingest" = "true",

    -- Seconds between S3 path polls.
    -- Lower = lower latency for new file detection; higher = lower S3 LIST API cost.
    -- Tune to match the expected file arrival frequency.
    -- Starting point: 60 seconds.
    "poll_interval" = "60",

    -- Number of concurrent file load tasks dispatched to CNs.
    -- Equivalent to S3Queue's s3queue_processing_threads_num.
    -- TBD: tune based on CN resource availability and file arrival rate.
    -- Starting point: 4 concurrent tasks.
    "max_concurrent_tasks" = "4"
)
AS
INSERT INTO events_db.events
(
    event_id,
    user_id,
    event_ts,
    eviction_date,
    event_date
    -- Add additional columns here as the payload schema is finalized (application team)
)
SELECT
    event_id,
    user_id,
    event_ts,
    eviction_date,

    -- Derive event_date from millisecond epoch timestamp.
    -- Mirrors the column transform in ClickHouse's mv_s3queue_to_cache MV:
    --   ClickHouse: toDate(toDateTime64(event_ts / 1000, 3)) AS event_date
    --   StarRocks:  str_to_date(from_unixtime(event_ts / 1000), '%Y-%m-%d')
    -- If the source file already contains event_date as a DATE column,
    -- simplify this to: event_date
    str_to_date(from_unixtime(event_ts / 1000), '%Y-%m-%d') AS event_date

    -- Additional column transforms TBD (application team)

FROM FILES
(
    -- TBD: replace with actual S3 source bucket and path prefix.
    -- Supports wildcards: "s3://bucket/prefix/*.parquet" or "s3://bucket/prefix/"
    -- Equivalent to ClickHouse S3Queue 's3://source-bucket/path/**'.
    "path" = "s3://source-bucket/events/",  -- TBD (equivalent to CH Open Decision #5)

    -- File format. TBD: confirm with the source system team.
    -- Options: "parquet", "orc", "json", "csv"
    -- Equivalent to ClickHouse S3Queue format parameter.
    "format" = "parquet",

    -- S3 endpoint for the SOURCE bucket.
    -- This may differ from the StarRocks data volume endpoint if the source
    -- files are in a different MinIO instance or on NetApp.
    -- TBD: replace with the actual source bucket endpoint.
    "aws.s3.endpoint" = "http://minio-service:9000",

    -- Source bucket region.
    "aws.s3.region" = "us-east-1",

    -- Source bucket credentials.
    -- Inject from Vault Agent Sidecar into FE environment or config at startup.
    -- Do NOT embed plaintext credentials here.
    -- If the source bucket is accessible via the same credentials as the StarRocks
    -- data volume, these may be omitted (FE uses the volume credentials by default).
    "aws.s3.access_key" = "${SOURCE_S3_ACCESS_KEY}",  -- inject via Vault Agent
    "aws.s3.secret_key" = "${SOURCE_S3_SECRET_KEY}"   -- inject via Vault Agent

    -- CSV-specific settings (relevant when format = "csv"):
    -- "csv.column_separator" = ",",
    -- "csv.row_delimiter" = "\n",
    -- "csv.skip_header" = "1"

    -- JSON-specific settings (relevant when format = "json"):
    -- "strip_outer_array" = "false",
    -- "json_root" = ""
);

-- =============================================================================
-- Pipe lifecycle commands (for reference)
-- =============================================================================

-- Check Pipe status:
-- SHOW PIPES FROM events_db;
-- SELECT * FROM information_schema.pipes
-- WHERE pipe_database = 'events_db' AND pipe_name = 'events_s3_pipe';

-- Pause auto-ingest (FE stops polling; in-flight tasks complete):
-- ALTER PIPE events_db.events_s3_pipe SET ("auto_ingest" = "false");

-- Resume:
-- ALTER PIPE events_db.events_s3_pipe SET ("auto_ingest" = "true");

-- Retry a specific file that previously failed:
-- ALTER PIPE events_db.events_s3_pipe RETRY FILE 's3://source-bucket/events/failed_file.parquet';

-- Drop the Pipe (non-recoverable: all file tracking state is lost; files will
-- be re-processed if a new Pipe is created pointing to the same path):
-- DROP PIPE events_db.events_s3_pipe;

-- =============================================================================
-- Monitoring queries
-- =============================================================================

-- Overall Pipe status:
-- SHOW PIPES FROM events_db\G

-- Files currently being loaded:
-- SELECT * FROM information_schema.pipe_files
-- WHERE pipe_database = 'events_db' AND pipe_name = 'events_s3_pipe'
-- AND file_state = 'LOADING';

-- Files that failed and are pending retry:
-- SELECT * FROM information_schema.pipe_files
-- WHERE pipe_database = 'events_db' AND pipe_name = 'events_s3_pipe'
-- AND file_state = 'ERROR'
-- ORDER BY last_modified DESC LIMIT 50;

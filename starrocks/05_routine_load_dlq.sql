-- =============================================================================
-- 05_routine_load_dlq.sql
-- Dead-letter queue table for Routine Load parse and type-conversion errors.
--
-- Run after: 03_events_table.sql
-- Target: any FE node via MySQL client (port 9030)
--
-- ClickHouse equivalent: default.kafka_dead_letters (05_ingest_kafka_dlq_table.sql)
--   ClickHouse routes error rows automatically via a DLQ Materialized View that
--   reads _error and _raw_message virtual columns on the KafkaEngine table.
--
-- StarRocks Routine Load difference:
--   Routine Load does NOT expose error rows as virtual columns for MV routing.
--   Instead, rows that fail parsing or type conversion are:
--     1. Counted against max_error_number (job pauses if threshold exceeded).
--     2. Written to a BE-local error log file as tab-separated raw content.
--     3. The error file URL is exposed in SHOW ROUTINE LOAD TASK (ErrorLogUrls).
--
--   This table provides persistent storage for error rows extracted from those
--   BE log files. It is NOT populated automatically — a monitoring process must
--   poll SHOW ROUTINE LOAD TASK, fetch error files from the BE HTTP API, and
--   INSERT parsed errors into this table.
--
-- Error file retrieval (for the monitoring process):
--   1. SHOW ROUTINE LOAD TASK FOR events_db.events_kafka_load;
--      → Inspect the ErrorLogUrls column for each sub-task.
--      → URLs have the form: http://<be-host>:8040/api/_load_error_log?file=<path>
--   2. Fetch: curl "http://<be-host>:8040/api/_load_error_log?file=<path>"
--   3. Parse the tab-separated output and INSERT into this table.
--
-- Retention: 30 days of error history. Adjust via dynamic_partition.start and
--   partition_ttl if a longer or shorter window is needed.
-- =============================================================================

CREATE TABLE IF NOT EXISTS events_db.routine_load_errors
(
    -- Partition key: time the error was captured by the monitoring process.
    -- Not the Kafka message timestamp — use kafka_offset for correlation.
    captured_at     DATETIME        NOT NULL  COMMENT "Time error was extracted from BE error log",

    -- Routing metadata: which job and sub-task produced the error.
    job_name        VARCHAR(256)    NOT NULL  COMMENT "Routine Load job name",
    task_id         VARCHAR(256)              COMMENT "Sub-task ID from SHOW ROUTINE LOAD TASK",

    -- Kafka coordinates: identify the exact message that failed.
    -- Use these to replay the message or investigate the source system.
    kafka_partition INT                       COMMENT "Kafka partition of the error row",
    kafka_offset    BIGINT                    COMMENT "Kafka offset of the error row",

    -- Error content: raw message bytes and parse error description.
    -- raw_message is capped at 65,533 bytes (VARCHAR limit).
    -- For messages larger than this, store a truncated prefix and log the overflow.
    raw_message     VARCHAR(65533)            COMMENT "Raw Kafka message (truncated to 65KB if larger)",
    error_message   VARCHAR(4096)             COMMENT "Error description from Routine Load error log"
)
ENGINE = OLAP

-- DUPLICATE KEY: this table stores error records without deduplication.
-- Multiple errors for the same kafka_offset are possible (e.g., retried sub-task).
DUPLICATE KEY (captured_at, job_name)

PARTITION BY RANGE(captured_at) ()

-- 4 buckets: error volume is low; no need for high parallelism here.
DISTRIBUTED BY HASH(job_name) BUCKETS 4

PROPERTIES (
    "replication_num" = "1",
    "storage_volume" = "s3_volume",

    -- DLQ table is not hot-queried; disable NVMe data cache to conserve cache
    -- capacity for the main events table.
    "datacache_enable" = "false",

    "dynamic_partition.enable" = "true",
    "dynamic_partition.time_unit" = "DAY",
    "dynamic_partition.start" = "-30",  -- retain 30 days of error history
    "dynamic_partition.end" = "1",
    "dynamic_partition.prefix" = "p",
    "dynamic_partition.buckets" = "4",
    "partition_ttl" = "30 DAY"
);

-- =============================================================================
-- Alerting guidance
-- =============================================================================

-- Monitor Routine Load error counts. Alert when error_rows is non-zero or growing:
--
--   SHOW ROUTINE LOAD FOR events_db.events_kafka_load\G
--
--   Key fields to monitor:
--     State            — RUNNING | PAUSED | STOPPED
--     ErrorRows        — cumulative error rows since job start
--     CurrentTaskNum   — active sub-task count (should equal desired_concurrent_number)
--     Lag              — Kafka consumer lag per partition (track for growing lag)
--
-- Alert thresholds (starting points — tune based on observed data quality):
--   Page on-call if:  State = PAUSED (job hit max_error_number threshold)
--   Warn if:          ErrorRows increments across two consecutive checks
--   Info if:          CurrentTaskNum < desired_concurrent_number (some sub-tasks idle)

-- =============================================================================
-- Monitoring query: current job health
-- =============================================================================

-- SHOW ROUTINE LOAD FOR events_db.events_kafka_load\G

-- SELECT
--     JOB_NAME,
--     STATE,
--     CURRENT_TASK_NUM,
--     LAG,
--     ERROR_ROWS,
--     TOTAL_ROWS,
--     UNSELECTED_ROWS,
--     LOADED_ROWS
-- FROM information_schema.routine_load_jobs
-- WHERE job_name = 'events_kafka_load';

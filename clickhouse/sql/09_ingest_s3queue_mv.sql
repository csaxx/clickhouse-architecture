-- =============================================================================
-- 09_ingest_s3queue_mv.sql
-- Materialized View: S3Queue → cache cluster.
--
-- Run after: 04_ingest_cache_writer.sql, 08_ingest_s3queue_table.sql
-- Target: ingest cluster (ON CLUSTER 'ingest')
--
-- Routes rows from S3 source files to the cache cluster via the Distributed
-- write table default.cache_writer.
--
-- Column transforms mirror those in 07_ingest_kafka_mvs.sql:
--   event_date is derived from the ms-epoch event_ts column.
--   _ver is set to event_ts. TBD: confirm ver column source (Open Decision #6).
--
-- S3Queue does not expose error virtual columns the way KafkaEngine does, so
-- there is no separate DLQ MV for this path. Schema validation failures cause
-- the file to be retried; monitor system.s3queue_log for parse errors.
-- =============================================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS default.mv_s3queue_to_cache
ON CLUSTER 'ingest'
TO default.cache_writer
AS SELECT
    toDate(toDateTime64(event_ts / 1000, 3))  AS event_date,   -- derive Date partition key from ms timestamp
    event_ts,
    user_id,
    eviction_date,
    event_ts                                   AS _ver          -- ver column TBD (Open Decision #6)
    -- Additional column transforms TBD
FROM default.s3queue_ingest;

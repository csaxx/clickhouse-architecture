-- =============================================================================
-- 07_ingest_kafka_mvs.sql
-- Materialized Views: KafkaEngine → cache cluster (main path + DLQ path).
--
-- Run after: 04_ingest_cache_writer.sql, 05_ingest_kafka_dlq_table.sql,
--            06_ingest_kafka_table.sql
-- Target: ingest cluster (ON CLUSTER 'ingest')
--
-- Two MVs are created together because both read from default.kafka_ingest and
-- must be deployed as a pair when kafka_handle_error_mode = 'stream':
--
--   mv_kafka_to_cache  — routes well-formed rows to the cache cluster via
--                        default.cache_writer (Distributed table).
--   mv_kafka_dlq       — routes parse-error rows to default.kafka_dead_letters
--                        for inspection and alerting.
--
-- Column transforms:
--   event_date is derived from event_ts (ms timestamp) using toDate(toDateTime64(...)).
--   _ver is set to event_ts. TBD: confirm ver column source (Open Decision #6).
--
-- Error filter:
--   length(_error) = 0  selects only successfully parsed rows.
--   length(_error) > 0  selects only rows that failed to parse.
--   Both conditions rely on kafka_handle_error_mode = 'stream' (set in 06).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Main path: well-formed rows → cache cluster
-- -----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW IF NOT EXISTS default.mv_kafka_to_cache
ON CLUSTER 'ingest'
TO default.cache_writer
AS SELECT
    toDate(toDateTime64(event_ts / 1000, 3))  AS event_date,   -- derive Date partition key from ms timestamp
    event_ts,
    user_id,
    eviction_date,
    event_ts                                   AS _ver          -- ver column TBD (Open Decision #6)
    -- Additional column transforms TBD
FROM default.kafka_ingest
WHERE length(_error) = 0;  -- only successfully parsed rows; requires kafka_handle_error_mode = 'stream'

-- -----------------------------------------------------------------------------
-- Dead-letter queue path: parse-error rows → DLQ table
-- -----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW IF NOT EXISTS default.mv_kafka_dlq
ON CLUSTER 'ingest'
TO default.kafka_dead_letters
AS SELECT
    _raw_message AS raw_message,
    _error       AS error,
    now()        AS captured_at
FROM default.kafka_ingest
WHERE length(_error) > 0;  -- only rows that failed to parse

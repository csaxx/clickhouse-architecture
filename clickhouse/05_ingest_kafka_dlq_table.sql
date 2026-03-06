-- =============================================================================
-- 05_ingest_kafka_dlq_table.sql
-- Dead-letter queue table for malformed Kafka messages.
--
-- Run after: 04_ingest_cache_writer.sql
-- Target: ingest cluster (ON CLUSTER 'ingest')
--
-- When kafka_handle_error_mode = 'stream', parse errors are exposed as
-- _error / _raw_message virtual columns on the KafkaEngine table rather than
-- halting the consumer. The DLQ MV (07_ingest_kafka_mvs.sql) routes failed
-- rows here for inspection and alerting.
--
-- Retention: no TTL is set by default. Add a TTL on captured_at once a
-- suitable retention period is agreed (e.g., TTL captured_at + INTERVAL 30 DAY DELETE).
-- This table does not need replication; a single copy per shard is sufficient
-- for error inspection. Use MergeTree (not ReplicatedMergeTree) because ingest
-- nodes are single-replica per shard.
-- =============================================================================

CREATE TABLE IF NOT EXISTS default.kafka_dead_letters
ON CLUSTER 'ingest'
(
    raw_message String,    -- original unparseable Kafka message bytes
    error       String,    -- parse error description from ClickHouse
    captured_at DateTime DEFAULT now()
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(captured_at)
ORDER BY captured_at;

-- =============================================================================
-- 06_ingest_kafka_table.sql
-- KafkaEngine source table on the ingest cluster.
--
-- Run after: 04_ingest_cache_writer.sql, 05_ingest_kafka_dlq_table.sql
-- Target: ingest cluster (ON CLUSTER 'ingest')
--
-- This table is NOT a storage table — it is a streaming connector. Reading
-- from it consumes messages from the Kafka topic. Do not query it directly.
-- Attach a Materialized View (07_ingest_kafka_mvs.sql) to consume from it.
--
-- Consumer group uniqueness:
--   kafka_group_name uses the {shard} macro so each ingest shard gets its own
--   consumer group. Two nodes sharing a consumer group split partitions between
--   them, which would cause message loss. The {shard} macro is populated per-pod
--   by the Altinity operator.
--
-- Throughput tuning:
--   kafka_max_block_size = 1048576 (1M rows) limits part accumulation.
--   At ~29k rows/sec per shard a full batch completes in ~35 sec.
--   kafka_num_consumers = 1: increase only if a single thread cannot sustain
--   ~29k rows/sec (monitor consumer lag).
--
-- Error handling:
--   kafka_handle_error_mode = 'stream' exposes _error and _raw_message virtual
--   columns in the MV SELECT, enabling DLQ routing without halting the consumer.
--   kafka_skip_broken_messages = 0 forces explicit DLQ handling.
--
-- TBD values (resolve before deploy):
--   - kafka_broker_list  (Open Decision #5)
--   - kafka_topic_list   (Open Decision #5)
--   - kafka_format       (JSONEachRow / AvroConfluent / Protobuf — Open Decision #5)
--   - Source message schema / column list
-- =============================================================================

CREATE TABLE IF NOT EXISTS default.kafka_ingest
ON CLUSTER 'ingest'
(
    -- Source message schema TBD (Open Decision #5).
    -- Columns must match or be transformable to cache_db.cache_table schema.
    event_ts      UInt64,
    user_id       UInt64,
    eviction_date Date
    -- Additional source columns TBD
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list          = 'kafka-broker-0:9092,kafka-broker-1:9092',  -- TBD (Open Decision #5)
    kafka_topic_list           = 'events',                                    -- TBD (Open Decision #5)

    -- Consumer group MUST be unique per ingest shard.
    -- {shard} macro is populated per-pod by the Altinity operator.
    kafka_group_name           = 'clickhouse_ingest_{shard}',

    kafka_format               = 'JSONEachRow',    -- TBD: JSONEachRow / AvroConfluent / Protobuf (Open Decision #5)

    -- Rows per MV batch. At ~29k rows/sec per shard, a 1M-row batch completes in ~35 sec.
    -- Controls part creation frequency — keep large to avoid "too many parts".
    kafka_max_block_size       = 1048576,

    -- Consumer threads per table. Start with 1; increase only if a single
    -- thread cannot sustain ~29k rows/sec. Monitor consumer lag to assess.
    kafka_num_consumers        = 1,

    -- Max wait for a full batch before firing a partial batch.
    -- 7500 ms is the default. Reduce to ~1000 ms if low-latency delivery is required.
    kafka_flush_interval_ms    = 7500,

    -- 'stream' exposes _error and _raw_message virtual columns in the MV,
    -- enabling dead-letter queue routing for malformed messages without halting
    -- the consumer.
    kafka_handle_error_mode    = 'stream',

    -- Do not silently skip broken messages.
    -- Requires explicit DLQ handling via the DLQ MV (07_ingest_kafka_mvs.sql).
    kafka_skip_broken_messages = 0,

    -- Max Kafka messages fetched per poll call.
    kafka_poll_max_batch_size  = 65536;

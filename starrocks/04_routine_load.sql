-- =============================================================================
-- 04_routine_load.sql
-- Routine Load job: continuous Kafka → events table ingest.
--
-- Run after: 03_events_table.sql
-- Target: any FE node via MySQL client (port 9030)
--
-- Routine Load replaces the entire ClickHouse ingest pipeline:
--   ClickHouse: KafkaEngine table  (06_ingest_kafka_table.sql)
--             + Materialized Views (07_ingest_kafka_mvs.sql)
--             + Distributed write table (04_ingest_cache_writer.sql)
--             + cross-cluster INSERT from ingest cluster → cache cluster
--   StarRocks:  a single CREATE ROUTINE LOAD statement
--
-- Architecture:
--   FE creates desired_concurrent_number sub-tasks, each assigned to a BE.
--   Each sub-task owns a range of Kafka partitions for one batch interval.
--   The BE consumes rows, applies column transforms, writes rowsets to S3 via
--   the Primary Key table (merge-on-write dedup happens here), then reports
--   completion to FE. FE commits the Kafka offsets on success.
--
-- Deduplication:
--   The Primary Key table deduplicates on INSERT. If a Kafka partition is
--   replayed after a sub-task failure, re-delivered rows with the same primary
--   key replace the stored rows — no duplicate rows result. This is equivalent
--   to (and strictly better than) ClickHouse's replicated_deduplication_window
--   combined with ReplacingMergeTree, because there are no transient duplicates
--   at any point.
--
-- Error handling:
--   Rows that fail parsing or type conversion are counted against max_error_number.
--   If the threshold is exceeded the job pauses automatically.
--   Error row details are written to BE-local error log files; paths are visible
--   in SHOW ROUTINE LOAD TASK (ErrorLogUrls column).
--   See 05_routine_load_dlq.sql for the companion DLQ table.
--
-- TBD values (resolve before deploy):
--   - kafka_broker_list           (Open Decision #10)
--   - kafka_topic                 (Open Decision #10)
--   - kafka_partitions            (Open Decision #10 — must match actual partition count)
--   - format                      (json / csv / avro — match source message format)
--   - COLUMNS mapping             (adjust to actual source message schema)
--   - desired_concurrent_number   (Open Decision #9 — must not exceed partition count)
--   - max_batch_rows              (tune during PoC to avoid small rowset accumulation)
-- =============================================================================

CREATE ROUTINE LOAD events_db.events_kafka_load ON events_db.events

-- Column mapping: describes how to derive each table column from the Kafka message.
-- The expressions here mirror the column transforms in ClickHouse's MV SELECT:
--   ClickHouse: toDate(toDateTime64(event_ts / 1000, 3)) AS event_date
--   StarRocks:  str_to_date(from_unixtime(event_ts / 1000), '%Y-%m-%d') AS event_date
--
-- If the Kafka message field names match the table column names exactly AND
-- event_date is present in the source message as a DATE string, the COLUMNS
-- clause can be simplified or omitted.
--
-- TBD: adjust column list and expressions to match the actual Kafka message schema.
COLUMNS
(
    event_id,
    user_id,
    event_ts,
    eviction_date,
    -- Derive event_date from the millisecond epoch timestamp.
    -- from_unixtime converts seconds to a datetime string; event_ts / 1000 converts ms → s.
    -- str_to_date parses the result to DATE type for the partition column.
    event_date = str_to_date(from_unixtime(event_ts / 1000), '%Y-%m-%d')
    -- Additional column mappings TBD (application team)
)

-- Optional: filter rows at ingest time. Uncomment and adjust if needed.
-- WHERE user_id > 0

PROPERTIES
(
    -- -------------------------------------------------------------------------
    -- Parallelism
    -- -------------------------------------------------------------------------

    -- Number of concurrent sub-tasks. Each sub-task is assigned to one BE and
    -- owns a non-overlapping range of Kafka partitions.
    -- Cannot exceed the Kafka topic's partition count.
    -- At 57,870 rows/sec total with 6 sub-tasks: each sub-task handles ~9,645 rows/sec.
    -- TBD: set to match Kafka partition count or a divisor of it (Open Decision #9).
    "desired_concurrent_number" = "6",

    -- -------------------------------------------------------------------------
    -- Batch sizing (equivalent to kafka_max_block_size in ClickHouse)
    -- -------------------------------------------------------------------------

    -- Max rows per sub-task batch before flushing to S3.
    -- Too small → many small rowsets accumulate per partition (StarRocks "small
    --   file" problem, equivalent to ClickHouse "too many parts").
    -- Too large → high BE memory usage during batch accumulation.
    --
    -- Sizing estimate:
    --   6 sub-tasks, 10s interval, ~57,870 rows/sec total
    --   → ~9,645 rows/sec per sub-task × 10s → ~96,450 rows per flush
    --   max_batch_rows = 500,000 → each flush completes well within 10s;
    --   produces rowsets of ~96K rows — reasonable size, not too small.
    --
    -- Tune upward if rowset accumulation is observed in PoC (SHOW PROC '/compactions').
    "max_batch_rows" = "500000",

    -- Max seconds between sub-task flushes regardless of max_batch_rows.
    -- Lower = lower ingest latency; higher = larger rowsets per flush.
    -- 10 seconds is a reasonable starting point. Align with Kafka consumer lag SLA.
    "max_batch_interval" = "10",

    -- -------------------------------------------------------------------------
    -- Error tolerance
    -- -------------------------------------------------------------------------

    -- Max number of malformed rows tolerated per sub-task batch before the job
    -- pauses. When the job pauses it must be manually resumed after investigation.
    "max_error_number" = "1000",

    -- Max fraction of filtered/errored rows allowed per batch.
    -- 0.01 = pause if more than 1% of rows in a batch are filtered or errored.
    -- Stricter than max_error_number alone — catches high-volume error spikes.
    "max_filter_ratio" = "0.01",

    -- Strict mode: type-conversion failures (not parse errors) cause the row to
    -- be filtered rather than substituting NULL. Recommended for production to
    -- surface schema mismatches early. Set false during initial development if
    -- the source schema is not yet stable.
    "strict_mode" = "true",

    -- -------------------------------------------------------------------------
    -- Time and format
    -- -------------------------------------------------------------------------

    -- Timezone for datetime conversion expressions in the COLUMNS clause.
    -- Match the timezone of the source event timestamps.
    "timezone" = "UTC",

    -- Kafka consumer group name. FE manages this; it is set automatically using
    -- the Routine Load job name. No manual group name configuration needed
    -- (unlike ClickHouse where kafka_group_name = 'clickhouse_ingest_{shard}'
    -- must use the {shard} macro to prevent cross-shard consumer group collision).
    "consumer_group" = "starrocks_events_kafka_load"
)

FROM KAFKA
(
    -- TBD: replace with actual Kafka broker addresses (Open Decision #10).
    "kafka_broker_list" = "kafka-broker-0:9092,kafka-broker-1:9092",

    -- TBD: replace with actual Kafka topic name (Open Decision #10).
    "kafka_topic" = "events",

    -- TBD: list all partition IDs for the topic.
    -- Must be a complete, comma-separated list of partition IDs.
    -- desired_concurrent_number sub-tasks are distributed across these partitions.
    -- Partition count should be a multiple of desired_concurrent_number for
    -- even distribution.
    "kafka_partitions" = "0,1,2,3,4,5",  -- TBD: adjust to actual partition count

    -- Initial Kafka offset policy per partition.
    -- OFFSET_END: start from the current end of the topic (no historical replay).
    -- OFFSET_BEGINNING: replay from the earliest available message.
    -- For production first deployment, use OFFSET_END unless historical replay is required.
    -- One offset value required per partition listed in kafka_partitions.
    "kafka_offsets" = "OFFSET_END,OFFSET_END,OFFSET_END,OFFSET_END,OFFSET_END,OFFSET_END",

    -- Message format. TBD: match source message format (equivalent to kafka_format in ClickHouse).
    -- Options: "json", "csv", "avro"
    -- For Avro: add "confluent_schema_registry_url" property for schema resolution.
    "format" = "json",

    -- JSON-specific settings (relevant when format = "json"):

    -- Strip outer array if messages are delivered as JSON arrays of objects.
    -- false: each message is a single JSON object (most common).
    -- true: each message is a JSON array, e.g. [{...}, {...}].
    "strip_outer_array" = "false",

    -- JSON path prefix for nested message structures.
    -- Leave empty if the message is a flat JSON object.
    -- Example: "$" or "$.data" if the fields are nested under a key.
    "json_root" = ""

    -- Kafka broker security settings (if required):
    -- "property.security.protocol" = "SASL_SSL",
    -- "property.sasl.mechanism" = "PLAIN",
    -- "property.sasl.username" = "<username>",
    -- "property.sasl.password" = "<password>"
);

-- =============================================================================
-- Job lifecycle commands (for reference)
-- =============================================================================

-- Check job status (shows state, consumed rows, error rows, lag):
-- SHOW ROUTINE LOAD FOR events_db.events_kafka_load\G

-- Check sub-task details (shows per-task Kafka partition assignments and error log URLs):
-- SHOW ROUTINE LOAD TASK FOR events_db.events_kafka_load\G

-- Pause job if issues are found (job stops consuming; offsets are held):
-- PAUSE ROUTINE LOAD FOR events_db.events_kafka_load;

-- Resume after investigation and correction:
-- RESUME ROUTINE LOAD FOR events_db.events_kafka_load;

-- Alter batch interval dynamically without recreating the job:
-- ALTER ROUTINE LOAD FOR events_db.events_kafka_load
-- PROPERTIES ("max_batch_interval" = "5");

-- Stop job permanently (non-recoverable; Kafka offsets committed up to this point;
-- recreating the job with OFFSET_END will miss messages consumed since stop):
-- STOP ROUTINE LOAD FOR events_db.events_kafka_load;

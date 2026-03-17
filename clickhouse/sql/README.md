# ClickHouse DDL

SQL files for all database and table creation statements. Files are numbered in dependency order; run them in sequence.

## Prerequisites

All open decisions that affect schema must be resolved before running in production. The TBD items are called out in each file. Key blockers:

| Decision | Affects |
|---|---|
| Q5 — Kafka broker list, topic, format | `06_ingest_kafka_table.sql` |
| Q5 — S3 source bucket URL and format | `08_ingest_s3queue_table.sql` |
| Q6 — `_ver` column source | `02_cache_table.sql`, `07_ingest_kafka_mvs.sql`, `09_ingest_s3queue_mv.sql` |
| Q7 — Sharding key column | `03_cache_distributed.sql`, `04_ingest_cache_writer.sql` |

Server-level configuration (storage policy, background thread pools, Keeper connection) must be deployed before running these DDL statements — see `docs/configuration-reference.md`.

## Execution Order

### Cache cluster

| File | Object | Notes |
|---|---|---|
| `01_cache_database.sql` | `cache_db` (Replicated DB) | Run once; idempotent |
| `02_cache_table.sql` | `cache_db.cache_table` (ReplicatedReplacingMergeTree) | Requires `cache_policy` storage policy defined in server config |
| `03_cache_distributed.sql` | `cache_db.cache_distributed` (Distributed) | Client query entry point |

### Ingest cluster

| File | Object | Notes |
|---|---|---|
| `04_ingest_cache_writer.sql` | `default.cache_writer` (Distributed → cache) | Must exist before MVs are created |
| `05_ingest_kafka_dlq_table.sql` | `default.kafka_dead_letters` (MergeTree) | Must exist before DLQ MV is created |
| `06_ingest_kafka_table.sql` | `default.kafka_ingest` (KafkaEngine) | Starts consuming on creation; deploy MVs immediately after |
| `07_ingest_kafka_mvs.sql` | `default.mv_kafka_to_cache`, `default.mv_kafka_dlq` | Both MVs deployed together |
| `08_ingest_s3queue_table.sql` | `default.s3queue_ingest` (S3Queue) | Starts polling on creation; deploy MV immediately after |
| `09_ingest_s3queue_mv.sql` | `default.mv_s3queue_to_cache` | |

## Key Design Constraints

**Sharding key must match across all three tables**: `03_cache_distributed.sql` (query) and `04_ingest_cache_writer.sql` (write) must use the same `xxHash64(sharding_column)` expression. A mismatch causes rows to land on the wrong shard at read time.

**Create `cache_writer` before KafkaEngine / S3Queue MVs**: the MVs reference `default.cache_writer` as their `TO` target. If it does not exist when the MV fires, INSERTs are silently dropped.

**Deploy MVs immediately after their source tables**: KafkaEngine begins consuming as soon as the table is created. Any delay between creating `kafka_ingest` and its MVs will result in messages being consumed but discarded.

**`insert_distributed_sync`**: default is async (Distributed INSERTs buffered locally). For synchronous mode set `insert_distributed_sync = 1` in the ingest user profile — see `docs/configuration-reference.md §3` for trade-offs.

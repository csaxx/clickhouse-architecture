# StarRocks DDL

SQL files for all database, table, and job creation statements. Files are numbered in dependency order; run them in sequence.

## Prerequisites

All open decisions that affect schema must be resolved before running in production. Key blockers:

| Decision | Affects |
|---|---|
| Open Decision #1 — S3 backend (MinIO or NetApp) | `01_storage_volume.sql` |
| Open Decision #5 — distribution key column | `03_events_table.sql` |
| Open Decision #8 — bucket count per partition | `03_events_table.sql` |
| Open Decision #9 — Routine Load `desired_concurrent_number` | `04_routine_load.sql` |
| Open Decision #10 — Kafka broker list, topic, partition count | `04_routine_load.sql` |
| Open Decision #11 — physical vs logical compliance SLA | `07_compliance.sql` |
| Open Decision #12 — write-path cache population validation | `03_events_table.sql` (`datacache_partition_duration`) |
| Source message schema and format | `04_routine_load.sql`, `06_pipe_s3.sql` |

The S3 storage volume (`01_storage_volume.sql`) must exist before any table DDL is run.
S3 credentials must be injected by Vault Agent Sidecar into FE/BE config before StarRocks starts — see `starrocks-architecture.md` Section 7.3.

## Execution Order

| File | Object | Notes |
|---|---|---|
| `01_storage_volume.sql` | `s3_volume` (Storage Volume) | Run once; idempotent. Must succeed before any table DDL. |
| `02_database.sql` | `events_db` (Database) | Run once; idempotent. |
| `03_events_table.sql` | `events_db.events` (PRIMARY KEY table) | Main persistent table. Replaces ClickHouse `cache_table`, `cache_distributed`, and `cache_writer`. Must exist before Routine Load or Pipe is created. |
| `04_routine_load.sql` | `events_db.events_kafka_load` (Routine Load job) | Kafka → events ingest. Replaces ClickHouse `kafka_ingest` table + `mv_kafka_to_cache` MV + `cache_writer`. |
| `05_routine_load_dlq.sql` | `events_db.routine_load_errors` (DLQ table) | Error row storage. Equivalent to ClickHouse `kafka_dead_letters`. Populated by external monitoring process — see file comments. |
| `06_pipe_s3.sql` | `events_db.events_s3_pipe` (Pipe job) | S3 file → events ingest. Replaces ClickHouse `s3queue_ingest` table + `mv_s3queue_to_cache` MV. |
| `07_compliance.sql` | Templates only — no persistent objects except staging tables | Compliance DELETE, compaction, UPDATE, and TTL monitoring queries. |

## ClickHouse → StarRocks Object Mapping

| ClickHouse Object | File | StarRocks Equivalent | File |
|---|---|---|---|
| `cache_db` (Replicated database) | `01_cache_database.sql` | `events_db` (standard database) | `02_database.sql` |
| `cache_db.cache_table` (ReplicatedReplacingMergeTree, 7×2) | `02_cache_table.sql` | `events_db.events` (PRIMARY KEY table) | `03_events_table.sql` |
| `cache_db.cache_distributed` (Distributed query table) | `03_cache_distributed.sql` | *not needed* — FE routes queries automatically | — |
| `default.cache_writer` (Distributed write table, ingest cluster) | `04_ingest_cache_writer.sql` | *not needed* — Routine Load writes directly | — |
| `default.kafka_dead_letters` (MergeTree DLQ) | `05_ingest_kafka_dlq_table.sql` | `events_db.routine_load_errors` | `05_routine_load_dlq.sql` |
| `default.kafka_ingest` (KafkaEngine) | `06_ingest_kafka_table.sql` | `events_db.events_kafka_load` (Routine Load) | `04_routine_load.sql` |
| `default.mv_kafka_to_cache` + `mv_kafka_dlq` (MVs) | `07_ingest_kafka_mvs.sql` | *included in Routine Load DDL* | `04_routine_load.sql` |
| `default.s3queue_ingest` (S3Queue) | `08_ingest_s3queue_table.sql` | `events_db.events_s3_pipe` (Pipe) | `06_pipe_s3.sql` |
| `default.mv_s3queue_to_cache` (MV) | `09_ingest_s3queue_mv.sql` | *included in Pipe DDL* | `06_pipe_s3.sql` |

**Objects eliminated** (no StarRocks equivalent needed):
- `cache_distributed` — FE routes all queries natively; no Distributed table DDL required
- `cache_writer` on the ingest cluster — Routine Load writes directly to the PRIMARY KEY table; no cross-cluster Distributed INSERT needed
- Ingest cluster itself — Routine Load sub-tasks run on BE nodes; no separate ingest cluster or pods

## Key Design Constraints

**Distribution key must be chosen before first INSERT**: `DISTRIBUTED BY HASH(col)` in `03_events_table.sql` routes rows to tablets. This determines both Routine Load write distribution and query scan parallelism. Changing it after data is written requires a table rebuild.

**Routine Load partition count must match `kafka_partitions`**: The `desired_concurrent_number` in `04_routine_load.sql` cannot exceed the number of Kafka partitions listed in `kafka_partitions`. A mismatch causes some sub-tasks to have no partitions assigned and silently under-consume.

**Start Routine Load with `OFFSET_END` in production**: unless historical replay is required, use `OFFSET_END` to avoid replaying messages that predate the first deployment. If `OFFSET_BEGINNING` is used accidentally, the Primary Key dedup will suppress duplicates of any rows already loaded, but the replay volume can be large.

**Create the events table before creating the Routine Load job or Pipe**: both `04_routine_load.sql` and `06_pipe_s3.sql` reference `events_db.events` as their target. If the table does not exist when these statements run, they will fail.

**Compaction (07_compliance.sql) is I/O intensive**: schedule `ALTER TABLE COMPACT` during off-peak hours or use Resource Groups to cap its CPU/memory footprint on BE nodes during business hours.

## Differences from ClickHouse DDL

| Dimension | ClickHouse | StarRocks |
|---|---|---|
| Deduplication timing | Merge-time (transient duplicates visible pre-merge) | Insert-time (no transient duplicates) |
| Cluster targeting | `ON CLUSTER 'cache'` / `ON CLUSTER 'ingest'` on every DDL | No cluster suffix needed — FE applies DDL globally |
| Ingest pipeline | 3 objects: KafkaEngine + MV + Distributed table | 1 object: `CREATE ROUTINE LOAD` |
| S3 file pipeline | 2 objects: S3Queue + MV | 1 object: `CREATE PIPE` |
| Query fanout table | Distributed table (`cache_distributed`) required | Not required — FE routes automatically |
| DLQ routing | Automatic via MV reading `_error` virtual column | Manual — monitoring process fetches BE error log files |
| Compliance logical delete | Rows visible until `OPTIMIZE PARTITION FINAL` | Immediate on `DELETE` |
| Physical removal | `OPTIMIZE TABLE PARTITION FINAL` (serial, per partition) | `ALTER TABLE COMPACT` (distributed across tablets, parallelizable) |

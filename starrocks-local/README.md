# StarRocks Local Testing Environment

A minimal single-machine Docker Compose environment for evaluating StarRocks shared-data mode features described in `starrocks-architecture.md`. This is **not production-ready** — it is sized and configured for feature evaluation on a low-powered workstation.

## What This Deploys

| Container | Image | Purpose |
|---|---|---|
| `minio` | `minio/minio` | S3 backend (source of truth for StarRocks data) |
| `minio-init` | `minio/mc` | One-shot bucket creation |
| `starrocks-fe` | `starrocks/fe-ubuntu:latest` | Frontend: metadata, query coordination, Routine Load scheduling |
| `starrocks-cn` | `starrocks/cn-ubuntu:latest` | Compute Node: stateless compute + local NVMe data cache (no tablet storage) |
| `starrocks-init` | `mariadb:latest` | One-shot SQL init: registers CN, creates storage volume, enables profiler |
| `redpanda` | `redpandadata/redpanda` | Kafka-compatible broker for Routine Load testing |
| `redpanda-console` | `redpandadata/console` | Redpanda web UI: topics, consumer groups, messages |
| `cloudbeaver-init` | `alpine` | One-shot: write pre-configured StarRocks connection into CloudBeaver workspace |
| `cloudbeaver` | `dbeaver/cloudbeaver` | Web SQL IDE; connects to StarRocks via MySQL protocol |

**Approximate memory budget**: 7–9 GB RAM total. Reduce JVM heap and CN memory limit further if needed (see Tuning section).

### Web UIs

| URL | Service | Credentials                 |
|---|---|-----------------------------|
| http://localhost:9001 | MinIO Console | `minioadmin` / `minioadmin` |
| http://localhost:8080 | Redpanda Console | none                        |
| http://localhost:8030 | StarRocks FE web UI + query profiler | 'root' / ''   |
| http://localhost:8978 | CloudBeaver SQL IDE | `cbadmin` / `cbadmin`       |

---

## Prerequisites

- Docker Desktop ≥ 4.x (or Docker Engine + Compose plugin on Linux)
- `docker compose` available (v2 syntax)
- `mysql` CLI client — to connect to StarRocks after setup. Install via:
  - macOS: `brew install mysql-client`
  - Ubuntu/Debian: `sudo apt install mysql-client-core-8.0`
  - Windows: MySQL Shell or any MySQL-compatible client

---

## Directory Layout

```
starrocks-local/
├── docker-compose.yml   — full stack definition
├── quickstart.sh        — downloads datasets and loads them via Redpanda
├── README.md            — this file
└── data/                — created by quickstart.sh; git-ignored
```

---

## Step 1 — Start the Environment

```bash
docker compose up -d

# Watch the one-shot init container to confirm successful setup
docker compose logs -f starrocks-init
```

The `starrocks-init` container exits with code 0 on success. Look for:

```
=== StarRocks init complete ===
```

Full startup takes **2–4 minutes** on first run (image pulls + FE/BE JVM startup).

---

## Step 2 — Verify the Cluster

Connect to StarRocks using the MySQL client (no password):

```bash
mysql -h 127.0.0.1 -P 9030 -u root
```

### Check CN is registered and alive

```sql
SHOW COMPUTE NODES\G
```

Expected: one row with `Alive: true` and `SystemDecommissioned: false`. If `Alive` is `false`, wait another 30 seconds and retry — CN heartbeat registration can take up to a minute after `ADD COMPUTE NODE`.

### Check storage volume

```sql
SHOW STORAGE VOLUMES;
-- Should show minio_vol as the default volume
```

### Check cluster health

```sql
SHOW FRONTENDS\G
SHOW PROC '/statistic'\G
```

### Connect CloudBeaver to StarRocks

Open **http://localhost:8978** in a browser. Log in with `cbadmin` / `cbadmin`.

The **StarRocks (Local)** connection is pre-configured — it appears in the left panel under **Connections**. Click it to connect. No manual setup required.

> **Note**: the connection uses the MySQL 8+ driver. Do not switch it to Generic JDBC or PostgreSQL — those send PostgreSQL-style `$$` dollar-quoting in introspection queries, which StarRocks rejects.

**Useful first queries in CloudBeaver**:

```sql
SHOW COMPUTE NODES\G
SHOW STORAGE VOLUMES\G
SHOW DATABASES;
```

### Query Profiler

Query profiling is enabled globally by the init container (`enable_profile = true`). After running any query:

1. Open **http://localhost:8030** — the StarRocks FE web UI.
2. Navigate to **Query → Profile** (or **System → Queries**).
3. Click any completed query to see the full pipeline execution profile.

To enable profiling for a single session only (overrides the global default):

```sql
SET enable_profile = true;
SET pipeline_profile_level = 2;  -- 2 = per-operator detail; 1 = summary only
```

---

## Step 3 — Create a Test Table (Primary Key Model)

This mirrors the architecture: Primary Key model with daily partitioning and S3-backed shared-data storage.

```sql
-- Connect: mysql -h 127.0.0.1 -P 9030 -u root

CREATE DATABASE IF NOT EXISTS test;
USE test;

CREATE TABLE IF NOT EXISTS events (
    event_id      BIGINT   NOT NULL,
    user_id       BIGINT   NOT NULL,
    event_date    DATE     NOT NULL,
    eviction_date DATE     NOT NULL,
    event_ts      DATETIME NOT NULL,
    payload       VARCHAR(1024)
)
ENGINE = OLAP
PRIMARY KEY (event_id)
PARTITION BY RANGE(event_date) (
    -- partitions created dynamically
)
DISTRIBUTED BY HASH(event_id) BUCKETS 3   -- 3× BE count; 1 BE here → 3 buckets
ORDER BY (event_id)
PROPERTIES (
    "replication_num"              = "1",
    "storage_volume"               = "minio_vol",
    "datacache_enable"             = "true",
    "datacache_partition_duration" = "7 DAY",
    "dynamic_partition.enable"     = "true",
    "dynamic_partition.time_unit"  = "DAY",
    "dynamic_partition.start"      = "-30",
    "dynamic_partition.end"        = "3",
    "dynamic_partition.prefix"     = "p",
    "dynamic_partition.buckets"    = "3",
    "partition_ttl"                = "90 DAY"
);
```

### Verify data goes to MinIO

```sql
-- Insert a test row
INSERT INTO events VALUES (1, 100, CURDATE(), DATE_ADD(CURDATE(), INTERVAL 90 DAY),
                           NOW(), 'test payload');

-- Confirm it's readable
SELECT * FROM events;
```

Open the MinIO console at **http://localhost:9001** (user: `minioadmin`, password: `minioadmin`) and browse the `starrocks` bucket — you should see objects under a path like `starrocks/{db_id}/{table_id}/...`.

---

## Step 4 — Test Routine Load (Kafka Ingest)

### Create a Redpanda topic

```bash
# Create the test topic via rpk inside the Redpanda container
docker exec redpanda rpk topic create events-topic --partitions 3 --replicas 1
```

### Create the Routine Load job

```sql
-- Connect: mysql -h 127.0.0.1 -P 9030 -u root
USE test;

CREATE ROUTINE LOAD test.events_load ON events
COLUMNS TERMINATED BY ",",
COLUMNS (event_id, user_id, event_date, eviction_date, event_ts, payload)
PROPERTIES (
    "desired_concurrent_number" = "1",
    "max_batch_rows"            = "100000",
    "max_batch_interval"        = "10",
    "max_error_number"          = "100",
    "format"                    = "CSV"
)
FROM KAFKA (
    -- Use the internal Docker network listener (redpanda:29092)
    "kafka_broker_list" = "redpanda:29092",
    "kafka_topic"       = "events-topic",
    "kafka_partitions"  = "0,1,2",
    "kafka_offsets"     = "OFFSET_BEGINNING"
);

-- Check job status
SHOW ROUTINE LOAD FOR events_load\G
```

### Produce test messages

```bash
# Produce CSV rows via rpk: event_id,user_id,event_date,eviction_date,event_ts,payload
docker exec -i redpanda rpk topic produce events-topic << 'EOF'
2,200,2025-01-15,2025-04-15,2025-01-15 10:00:00,hello from redpanda
3,201,2025-01-15,2025-04-15,2025-01-15 10:01:00,another event
4,200,2025-01-15,2025-04-15,2025-01-15 10:02:00,duplicate user_id
5,202,2025-01-15,2025-04-15,2025-01-15 10:03:00,fourth event
EOF
```

Wait ~15 seconds (one `max_batch_interval` cycle), then:

```sql
SELECT COUNT(*), user_id FROM events GROUP BY user_id;
```

### Test Primary Key deduplication

```bash
# Produce a duplicate event_id — should replace the existing row, not insert a second one
docker exec -i redpanda rpk topic produce events-topic << 'EOF'
2,200,2025-01-15,2025-04-15,2025-01-15 10:00:00,UPDATED payload
EOF
```

```sql
-- After the next batch interval, count should still be 4 rows (not 5)
SELECT COUNT(*) FROM events;
-- Row 2's payload should now be 'UPDATED payload'
SELECT * FROM events WHERE event_id = 2;
```

---

## Step 5 — Test Compliance Operations

### Logical delete (immediate inaccessibility)

```sql
-- Delete all rows for a user — immediately invisible after this statement
DELETE FROM events WHERE user_id = 200;

-- Confirm deletion — should return 0 rows for user_id 200
SELECT * FROM events WHERE user_id = 200;
```

### Physical compaction (for physical byte removal SLA testing)

```sql
-- Force compaction on a specific partition (replace date with an actual partition)
-- This validates Section 8.8 of the architecture doc
SHOW PARTITIONS FROM events\G

-- Run compaction on a partition (use actual partition name from SHOW PARTITIONS)
ALTER TABLE events COMPACT PARTITION p20250115;

-- Monitor compaction progress
SHOW PROC '/compactions'\G
```

### Field-level UPDATE

```sql
-- Insert a test row first
INSERT INTO events VALUES (10, 300, CURDATE(), DATE_ADD(CURDATE(), INTERVAL 90 DAY),
                           NOW(), 'original value');

-- Update a field
UPDATE events SET payload = 'updated value' WHERE user_id = 300;

-- Verify
SELECT * FROM events WHERE user_id = 300;
```

---

## Step 6 — Test S3 Pipe (File Ingest)

Upload a test Parquet or CSV file to MinIO, then create a Pipe job to load it.

```bash
# Create a source bucket in MinIO for file uploads
docker exec minio-init \
  /bin/sh -c "mc alias set local http://minio:9000 minioadmin minioadmin && \
              mc mb --ignore-existing local/source-events"

# Upload a test CSV file (create locally first)
cat > /tmp/test_events.csv << 'EOF'
20,400,2025-01-16,2025-04-16,2025-01-16 09:00:00,pipe ingest row 1
21,401,2025-01-16,2025-04-16,2025-01-16 09:01:00,pipe ingest row 2
22,400,2025-01-16,2025-04-16,2025-01-16 09:02:00,pipe ingest row 3
EOF

docker cp /tmp/test_events.csv minio:/tmp/test_events.csv
docker exec minio \
  /bin/sh -c "mc alias set local http://localhost:9000 minioadmin minioadmin && \
              mc cp /tmp/test_events.csv local/source-events/test_events.csv"
```

```sql
-- Create the Pipe job pointing at the source bucket
USE test;

CREATE PIPE events_pipe
PROPERTIES (
    "auto_ingest" = "true",
    "poll_interval" = "30"
)
AS INSERT INTO events
SELECT *
FROM FILES(
    "path"                            = "s3://source-events/",
    "format"                          = "csv",
    "csv.column_separator"            = ",",
    "aws.s3.endpoint"                 = "http://minio:9000",
    "aws.s3.region"                   = "us-east-1",
    "aws.s3.access_key"               = "minioadmin",
    "aws.s3.secret_key"               = "minioadmin",
    "aws.s3.enable_ssl"               = "false",
    "aws.s3.enable_path_style_access" = "true"
);

-- Monitor pipe status
SHOW PIPES\G
```

After ~30 seconds, the pipe loads the file. The file is tracked in FE metadata and will not be re-loaded on retry — validating Section 8.4 of the architecture.

---

## Step 7 — Monitor Cache Hit Ratio

```sql
-- Data cache statistics per CN — validates Open Decision #12 (cache warmth)
SELECT * FROM information_schema.datacache_stats\G

-- CN-level config verification
SHOW COMPUTE NODES\G
```

---

## Step 8 — NYC Crash & Weather Data Quickstart (via Redpanda)

This step reproduces the [StarRocks shared-data quickstart](https://docs.starrocks.io/docs/quick_start/shared-data/) using two real-world public datasets, but routes all data through Redpanda instead of loading files directly. The flow is:

```
CSV file ──tail──▶ rpk topic produce ──▶ Redpanda topic ──▶ Routine Load ──▶ StarRocks ──▶ MinIO
```

This exercises the full ingest path: Kafka broker → StarRocks FE scheduling → CN compute → S3-backed shared-data storage.

### Datasets

| Dataset | Source | Rows | File size |
|---|---|---|---|
| NYC crash data (NYPD) | NYC OpenData via StarRocks demo repo | ~423k | ~96 MB |
| NOAA weather data | NOAA Local Climatological Data | ~8k | ~6 MB |

### Run the quickstart script

`quickstart.sh` (in this directory) handles everything end-to-end:

1. Downloads CSV files into `data/` (skipped if already present)
2. Starts the stack with `docker compose up -d`
3. Waits for `starrocks-init` to complete
4. Waits for StarRocks FE and Redpanda to be reachable
5. Creates Redpanda topics `crashdata-topic` and `weatherdata-topic`
6. Creates the `quickstart` database and tables in StarRocks
7. Creates Routine Load jobs (one per topic)
8. Streams CSV rows (header stripped) into Redpanda via `rpk topic produce`
9. Waits 60 s for the first Routine Load batch to commit, then prints row counts

```bash
chmod +x quickstart.sh
./quickstart.sh
```

Expected output at the end:

```
=== Verifying row counts ===
+--------------+--------+
| table_name   | rows   |
+--------------+--------+
| crashdata    | 423725 |
| weatherdata  |   8784 |
+--------------+--------+
```

> **Note**: row counts appear after the 60 s wait. If they show 0, the Routine Load
> batches are still committing — wait another 30 s and re-run the SELECT manually.

### Table schemas

**`quickstart.crashdata`** — DUPLICATE KEY model, distributed by `COLLISION_ID`:

```sql
CREATE TABLE IF NOT EXISTS crashdata (
    CRASH_DATE                    DATETIME,   -- combined from CSV CRASH DATE + CRASH TIME
    BOROUGH                       STRING,
    ZIP_CODE                      STRING,
    LATITUDE                      INT,        -- truncated; raw data is decimal
    LONGITUDE                     INT,        -- truncated; raw data is decimal
    LOCATION                      STRING,
    ON_STREET_NAME                STRING,
    CROSS_STREET_NAME             STRING,
    OFF_STREET_NAME               STRING,
    CONTRIBUTING_FACTOR_VEHICLE_1 STRING,
    CONTRIBUTING_FACTOR_VEHICLE_2 STRING,
    COLLISION_ID                  INT,
    VEHICLE_TYPE_CODE_1           STRING,
    VEHICLE_TYPE_CODE_2           STRING
)
ENGINE = OLAP
DUPLICATE KEY(CRASH_DATE)
DISTRIBUTED BY HASH(COLLISION_ID) BUCKETS 3
PROPERTIES ("replication_num" = "1", "storage_volume" = "minio_vol");
```

**`quickstart.weatherdata`** — DUPLICATE KEY model, distributed by `WEATHER_DATE`.
Column renamed from `DATE` → `WEATHER_DATE` to avoid SQL reserved-word conflicts
in the Routine Load `COLUMNS` clause:

```sql
CREATE TABLE IF NOT EXISTS weatherdata (
    WEATHER_DATE              DATETIME,
    NAME                      STRING,
    HourlyDewPointTemperature STRING,
    HourlyDryBulbTemperature  STRING,
    HourlyPrecipitation       STRING,
    HourlyPresentWeatherType  STRING,
    HourlyPressureChange      STRING,
    HourlyPressureTendency    STRING,
    HourlyRelativeHumidity    STRING,
    HourlySkyConditions       STRING,
    HourlyVisibility          STRING,
    HourlyWetBulbTemperature  STRING,
    HourlyWindDirection       STRING,
    HourlyWindGustSpeed       STRING,
    HourlyWindSpeed           STRING
)
ENGINE = OLAP
DUPLICATE KEY(WEATHER_DATE)
DISTRIBUTED BY HASH(WEATHER_DATE) BUCKETS 3
PROPERTIES ("replication_num" = "1", "storage_volume" = "minio_vol");
```

### Monitor Routine Load

```sql
-- Connect: mysql -h 127.0.0.1 -P 9030 -u root quickstart
SHOW ROUTINE LOAD FOR crash_load\G
SHOW ROUTINE LOAD FOR weather_load\G
```

Key fields to watch: `State` (should be `RUNNING`), `LoadedRows`, `ErrorRows`.
If `State` is `PAUSED`, check `ReasonOfStateChanged` for the error message and
resume with `RESUME ROUTINE LOAD FOR crash_load;`.

### Sample queries

After data loads, connect with `mysql -h 127.0.0.1 -P 9030 -u root quickstart`:

**Crashes per hour (time-series)**

```sql
SELECT COUNT(*) AS crashes,
       date_trunc('hour', CRASH_DATE) AS hour
FROM crashdata
GROUP BY hour
ORDER BY hour
LIMIT 48;
```

**Average dry-bulb temperature by hour**

```sql
SELECT avg(HourlyDryBulbTemperature) AS avg_temp_f,
       date_trunc('hour', WEATHER_DATE) AS hour
FROM weatherdata
GROUP BY hour
ORDER BY hour
LIMIT 48;
```

**Crashes during low visibility (JOIN crash + weather)**

```sql
SELECT COUNT(DISTINCT c.COLLISION_ID) AS crashes,
       truncate(avg(w.HourlyDryBulbTemperature), 1)  AS avg_temp_f,
       truncate(avg(w.HourlyVisibility), 2)           AS avg_visibility,
       max(w.HourlyPrecipitation)                     AS max_precip,
       date_format(date_trunc('hour', c.CRASH_DATE), '%d %b %Y %H:%i') AS hour
FROM crashdata c
LEFT JOIN weatherdata w
       ON date_trunc('hour', c.CRASH_DATE) = date_trunc('hour', w.WEATHER_DATE)
WHERE w.HourlyVisibility BETWEEN 0.0 AND 1.0
GROUP BY hour
ORDER BY crashes DESC
LIMIT 20;
```

**Crashes in near-freezing conditions**

```sql
SELECT COUNT(DISTINCT c.COLLISION_ID) AS crashes,
       truncate(avg(w.HourlyDryBulbTemperature), 1)  AS avg_temp_f,
       truncate(avg(w.HourlyVisibility), 2)           AS avg_visibility,
       max(w.HourlyPrecipitation)                     AS max_precip,
       date_format(date_trunc('hour', c.CRASH_DATE), '%d %b %Y %H:%i') AS hour
FROM crashdata c
LEFT JOIN weatherdata w
       ON date_trunc('hour', c.CRASH_DATE) = date_trunc('hour', w.WEATHER_DATE)
WHERE w.HourlyDryBulbTemperature BETWEEN 0.0 AND 40.5
GROUP BY hour
ORDER BY crashes DESC
LIMIT 20;
```

### Verify data is on MinIO

Open **http://localhost:9001** and browse `starrocks` → you should see new object
paths for the `quickstart` database alongside the `test` database from earlier steps.

---

## Useful Commands

### Restart cleanly (preserving data)

```bash
docker compose restart
```

### Full teardown including all data

```bash
docker compose down -v
```

### Connect to StarRocks

```bash
mysql -h 127.0.0.1 -P 9030 -u root
```

### Routine Load status

```sql
SHOW ROUTINE LOAD\G
-- Pause/resume
PAUSE ROUTINE LOAD FOR events_load;
RESUME ROUTINE LOAD FOR events_load;
```

### View Redpanda topics and consumer lag

```bash
# List topics
docker exec redpanda rpk topic list

# Describe consumer group (StarRocks creates one per Routine Load job)
docker exec redpanda rpk group list
docker exec redpanda rpk group describe <group_name>
```

### Browse MinIO data

Open **http://localhost:9001** in a browser. Bucket `starrocks` contains all StarRocks table data organized by `{db_id}/{table_id}/{partition_id}/{tablet_id}/`.

---

## Tuning for Very Low-Resource Machines

If the machine has less than 8 GB RAM available for Docker, edit the `entrypoint:` printf strings in `docker-compose.yml`:

**FE** — reduce JVM heap (in the `starrocks-fe` entrypoint):
```
JAVA_OPTS=\"-Xmx1024m -Xms1024m -XX:+UseG1GC\"
```

**CN** — reduce memory and cache (in the `starrocks-cn` entrypoint):
```
mem_limit = 2147483648
datacache_disk_size = 5368709120
```

**Redpanda** — reduce allocation (in the `redpanda` command list):
```yaml
  - --memory=256M
```

---

## Architecture Validation Map

Each step above maps directly to an architecture concern in `starrocks-architecture.md`:

| Test | Architecture Section |
|---|---|
| S3 write path (INSERT → MinIO) | §5.1 Shared-Data Storage Model |
| Primary Key dedup on Routine Load | §1.2, §8.2 |
| Routine Load small rowset tuning | §8.3 |
| Cache hit ratio monitoring | §5.3, Open Decision #12 |
| `DELETE` immediate logical inaccessibility | §1.4, §7.1 |
| `ALTER TABLE COMPACT` duration | §8.8 |
| Field-level `UPDATE` | §1.4, §13 |
| Pipe file tracking / no double-load | §4.2, §8.4 |
| S3 object layout in MinIO browser | §3.3 |
| CN auto-recovery (stop/start cn container) | §6.3 |

---

## Known Limitations of This Local Setup

- **1 FE, 1 CN**: FE quorum (Section 6.2) and CN redistribution (Section 12.2) cannot be tested. Use a 3-FE, 3-CN setup on a larger machine for those.
- **MinIO single-node**: not erasure-coded; data loss if the container is deleted without a volume backup. This is expected for a test environment.
- **No TLS/auth**: StarRocks root has no password, MinIO uses default credentials, Redpanda runs in dev mode with no SASL. Do not expose these ports outside the local machine.
- **No resource groups**: StarRocks Resource Groups (Section 12.5) require more than one CN to be meaningful.
- **datacache_populate_mode**: Behavior of `auto` varies by version. Check the StarRocks release notes for the version pulled for the precise semantics when evaluating Open Decision #12.

---

*All images use `:latest` tags — pull versions will vary over time. Docker Compose v2 required.*

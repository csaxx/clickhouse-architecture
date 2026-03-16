# StarRocks Local Testing Environment

A minimal single-machine Docker Compose environment for evaluating StarRocks shared-data mode features described in `starrocks-architecture.md`. This is **not production-ready** — it is sized and configured for feature evaluation on a low-powered workstation.

## What This Deploys

| Container          | Image | Purpose |
|--------------------|---|---|
| `minio`            | `minio/minio` | S3 backend (source of truth for StarRocks data) |
| `minio-init`       | `minio/mc` | One-shot bucket creation |
| `starrocks-fe1`    | `starrocks/fe-ubuntu:latest` | FE1 (FOLLOWER/leader): metadata, query coordination, Routine Load scheduling |
| `starrocks-fe2`    | `starrocks/fe-ubuntu:latest` | FE2 (OBSERVER): metadata replica, additional query routing; not a Raft voter |
| `starrocks-cn1`    | `starrocks/cn-ubuntu:latest` | CN1: stateless compute + local NVMe data cache (shared-data mode) |
| `starrocks-cn2`    | `starrocks/cn-ubuntu:latest` | CN2: second compute node; same config as CN1 |
| `starrocks-init`   | `mariadb:latest` | One-shot SQL init: registers FE2 observer + both CNs, creates storage volume, enables profiler |
| `redpanda`         | `redpandadata/redpanda` | Kafka-compatible broker for Routine Load testing |
| `redpanda-console` | `redpandadata/console` | Redpanda web UI: topics, consumer groups, messages |
| `cloudbeaver-init` | `alpine` | One-shot: write pre-configured StarRocks connection into CloudBeaver workspace |
| `cloudbeaver`      | `dbeaver/cloudbeaver` | Web SQL IDE; connects to StarRocks via MySQL protocol |

**Approximate memory budget**: 10–13 GB RAM total. Reduce CN `mem_limit` and `datacache_disk_size` in `docker-compose.yml` if the machine is constrained (see Tuning section).

### Web UIs

| URL | Service | Credentials |
|---|---|---|
| http://localhost:9001 | MinIO Console | `minioadmin` / `minioadmin` |
| http://localhost:8080 | Redpanda Console | none |
| http://localhost:8030 | StarRocks FE1 web UI + query profiler | `root` / `` |
| http://localhost:8031 | StarRocks FE2 web UI | `root` / `` |
| http://localhost:8978 | CloudBeaver SQL IDE | `cbadmin` / `cbadmin` |

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
├── docker-compose.yml              — full stack definition
├── docker-compose-up.sh            — start stack + wait for full readiness
├── docker-compose-down.sh          — tear down stack and remove all volumes
├── load-quickstart-redpanda.sh     — download datasets, create topics, produce to Redpanda
├── load-quickstart-starrocks.sh    — create DB/tables/Routine Load jobs, verify counts
├── README.md                       — this file
└── data/                           — created by load-quickstart-redpanda.sh; git-ignored
```

---

## Step 1 — Start the Environment

Use the provided script, which starts the stack and polls each service until fully ready:

```bash
chmod +x docker-compose-up.sh
./docker-compose-up.sh
```

The script confirms:
1. `starrocks-init` exits with code 0 (FE2 observer + both CNs registered, storage volume created)
2. StarRocks FE1 MySQL port reachable from host
3. Both CNs heartbeating (`Alive: true`) and tablet scheduler accepting new tables
4. Redpanda cluster healthy

Alternatively, start manually and tail the init container:

```bash
docker compose up -d
docker compose logs -f starrocks-init
```

Look for `=== StarRocks init complete ===`. Full startup takes **3–5 minutes** on first run (image pulls + FE/CN JVM startup).

---

## Step 2 — Verify the Cluster

Connect to StarRocks using the MySQL client (no password):

```bash
mysql -h 127.0.0.1 -P 9030 -u root
```

### Check FE topology

```sql
SHOW FRONTENDS\G
```

Expected: two rows — FE1 with `IsMaster: true`, FE2 with `Role: OBSERVER`.

### Check both CNs are registered and alive

```sql
SHOW COMPUTE NODES\G
```

Expected: **two rows**, both with `Alive: true` and `SystemDecommissioned: false`. If either shows `Alive: false`, wait 30 seconds and retry — CN heartbeat registration can lag up to a minute after `ADD COMPUTE NODE`.

### Check storage volume

```sql
SHOW STORAGE VOLUMES;
-- Should show minio_vol as the default volume
```

### Check cluster health

```sql
SHOW PROC '/statistic'\G
```

### Connect CloudBeaver to StarRocks

Open **http://localhost:8978** in a browser. Log in with `cbadmin` / `cbadmin`.

The **StarRocks (Local)** connection is pre-configured — it appears in the left panel under **Connections**. Click it to connect. No manual setup required.

> **Note**: the connection uses the MySQL 8+ driver. Do not switch it to Generic JDBC or PostgreSQL — those send PostgreSQL-style `$$` dollar-quoting in introspection queries, which StarRocks rejects.

**Useful first queries in CloudBeaver**:

```sql
SHOW FRONTENDS\G
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
DISTRIBUTED BY HASH(event_id) BUCKETS 6   -- 3 buckets × 2 CNs
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
    "dynamic_partition.buckets"    = "6",
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
    "desired_concurrent_number" = "2",
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
    "kafka_offsets"     = "OFFSET_BEGINNING,OFFSET_BEGINNING,OFFSET_BEGINNING"
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

### Run the quickstart scripts

Two scripts handle the load end-to-end. Run them in order after `docker-compose-up.sh`:

**1. Populate Redpanda** (download CSVs + produce to topics):

```bash
chmod +x load-quickstart-redpanda.sh
./load-quickstart-redpanda.sh
```

This downloads the CSV files into `data/` (skipped if already present), creates the Redpanda topics, and streams both datasets into them.

**2. Load into StarRocks** (create tables + Routine Load jobs + verify):

```bash
chmod +x load-quickstart-starrocks.sh
./load-quickstart-starrocks.sh
```

This creates the `quickstart` database and tables, creates two Routine Load jobs, waits 60 s for the first batch to commit, then prints row counts.

Expected output at the end of the second script:

```
=== Step 4: Verifying row counts ===
+--------------+-----------+
| table_name   | row_count |
+--------------+-----------+
| crashdata    |    423725 |
| weatherdata  |      8784 |
+--------------+-----------+
```

> **Note**: if counts show 0, the Routine Load batches are still committing — wait another 30 s and re-run the SELECT manually.

### Table schemas

**`quickstart.crashdata`** — DUPLICATE KEY model, distributed by `COLLISION_ID`:

```sql
CREATE TABLE IF NOT EXISTS crashdata (
    COLLISION_ID                  INT,        -- PRIMARY KEY; must be first column
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
    VEHICLE_TYPE_CODE_1           STRING,
    VEHICLE_TYPE_CODE_2           STRING
)
ENGINE = OLAP
PRIMARY KEY(COLLISION_ID)
DISTRIBUTED BY HASH(COLLISION_ID) BUCKETS 3
PROPERTIES (
    "replication_num"         = "1",
    "storage_volume"          = "minio_vol",
    "enable_persistent_index" = "true",
    "persistent_index_type"   = "CLOUD_NATIVE"
);
```

**`quickstart.weatherdata`** — DUPLICATE KEY model, distributed by `WEATHER_DATE`.
Column renamed from `DATE` → `WEATHER_DATE` to avoid SQL reserved-word conflicts
in the Routine Load `COLUMNS` clause:

```sql
CREATE TABLE IF NOT EXISTS weatherdata (
    WEATHER_DATE              DATETIME,   -- PRIMARY KEY col 1 (already first)
    NAME                      STRING,     -- PRIMARY KEY col 2 (station name)
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
PRIMARY KEY(WEATHER_DATE, NAME)
DISTRIBUTED BY HASH(WEATHER_DATE) BUCKETS 3
PROPERTIES (
    "replication_num"         = "1",
    "storage_volume"          = "minio_vol",
    "enable_persistent_index" = "true",
    "persistent_index_type"   = "CLOUD_NATIVE"
);
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

### Start / stop

```bash
# Start stack and wait for full readiness
./docker-compose-up.sh

# Full teardown — removes all volumes and data
./docker-compose-down.sh

# Restart without losing data
docker compose restart
```

### Connect to StarRocks

```bash
# FE1
mysql -h 127.0.0.1 -P 9030 -u root

# FE2 (observer — same data, different entry point)
mysql -h 127.0.0.1 -P 9031 -u root
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

## Tuning for Low-Resource Machines

If the machine has less than 10 GB RAM available for Docker, reduce per-component limits in `docker-compose.yml`:

**CN1 and CN2** — reduce `mem_limit` and `datacache_disk_size` in both `starrocks-cn1` and `starrocks-cn2` entrypoints:

```
mem_limit = 1073741824        # 1 GB (down from 2 GB)
datacache_disk_size = 2684354560  # 2.5 GB (down from 5 GB)
```

**FE1 and FE2** — add a `JAVA_OPTS` line to each FE's `fe.conf` via the `printf` in the entrypoint:

```
JAVA_OPTS=-Xmx1024m -Xms512m -XX:+UseG1GC
```

**Redpanda** — reduce allocation in the `redpanda` command list:

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
| CN auto-recovery (stop/start one CN container) | §6.3 |
| FE observer metadata sync (check FE2 after restart) | §6.2 |
| Query routing via FE2 (connect to port 9031) | §3.4 |

---

## Known Limitations of This Local Setup

- **1 FOLLOWER FE + 1 OBSERVER FE**: Raft quorum requires 3 FOLLOWER nodes (§6.2). FE1 is the permanent leader; FE2 is a non-voting OBSERVER. Leader failover cannot be tested without a 3-FOLLOWER setup on a larger machine.
- **2 CNs, no CN redistribution**: CN scale-out behavior (§12.2) requires adding/removing CNs from a live cluster. This can be tested manually by stopping one CN container and observing recovery.
- **MinIO single-node**: not erasure-coded; data loss if the container is deleted without a volume backup. Expected for a test environment.
- **No TLS/auth**: StarRocks root has no password, MinIO uses default credentials, Redpanda runs in dev mode with no SASL. Do not expose these ports outside the local machine.
- **No resource groups**: StarRocks Resource Groups (§12.5) require more than one CN to be meaningful — now partially testable with 2 CNs.
- **datacache_populate_mode**: Behavior of `auto` varies by version. Check the StarRocks release notes for the version pulled for the precise semantics when evaluating Open Decision #12.

---

*All images use `:latest` tags — pull versions will vary over time. Docker Compose v2 required.*

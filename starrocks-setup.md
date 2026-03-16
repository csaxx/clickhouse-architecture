# StarRocks Local Testing Environment — Docker Setup Guide

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

Only `docker-compose.yml` is required. Configuration is injected into the containers at startup to avoid Windows CRLF line-ending issues.

```
starrocks-local/
└── docker-compose.yml
```

```bash
mkdir -p starrocks-local
cd starrocks-local
```

---

## Step 1 — `docker-compose.yml`

```yaml
version: "3.8"

networks:
  sr-net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/24

volumes:
  minio-data:
  fe-meta:
  cn-cache:
  redpanda-data:
  cloudbeaver-data:

services:

  # ---------------------------------------------------------------------------
  # MinIO — S3 backend (source of truth for all StarRocks data)
  # ---------------------------------------------------------------------------
  minio:
    image: minio/minio:latest
    container_name: minio
    networks: [sr-net]
    ports:
      - "9000:9000"   # S3 API
      - "9001:9001"   # MinIO console (browser UI)
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: minioadmin
    volumes:
      - minio-data:/data
    command: server /data --console-address ":9001"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 10s

  # One-shot: create the StarRocks bucket in MinIO
  minio-init:
    image: minio/mc:latest
    container_name: minio-init
    networks: [sr-net]
    depends_on:
      minio:
        condition: service_healthy
    entrypoint: >
      /bin/sh -c "
        mc alias set local http://minio:9000 minioadmin minioadmin &&
        mc mb --ignore-existing local/starrocks &&
        echo 'MinIO bucket ready.'
      "

  # ---------------------------------------------------------------------------
  # StarRocks FE — metadata, query coordination, Routine Load scheduling
  # Config is appended to the image default via entrypoint to avoid CRLF issues
  # on Windows (mounted config files with \r\n break shell-level fe.conf parsing).
  # ---------------------------------------------------------------------------
  starrocks-fe:
    image: starrocks/fe-ubuntu:latest
    container_name: starrocks-fe
    networks: [sr-net]
    ports:
      - "8030:8030"   # HTTP API
      - "9020:9020"   # internal RPC
      - "9030:9030"   # MySQL wire protocol (client connection point)
    volumes:
      - fe-meta:/opt/starrocks/fe/meta
    entrypoint: >
      /bin/bash -c "
        printf '\nrun_mode = shared_data\ncloud_native_storage_type = S3\npriority_networks = 172.20.0.0/24\nJAVA_OPTS=\"-Xmx2048m -Xms2048m -XX:+UseG1GC -XX:MaxGCPauseMillis=200\"\n'
        exec /opt/starrocks/fe/bin/start_fe.sh
      "
    depends_on:
      minio-init:
        condition: service_completed_successfully
    healthcheck:
      # Check both HTTP (fast) and MySQL port (slower — confirms full readiness)
      test: ["CMD-SHELL", "curl -sf http://localhost:8030/api/health && bash -c 'cat /dev/null > /dev/tcp/127.0.0.1/9030' 2>/dev/null"]
      interval: 15s
      timeout: 10s
      retries: 40
      start_period: 90s

  # ---------------------------------------------------------------------------
  # StarRocks CN — stateless compute node + local data cache (shared-data mode)
  # ---------------------------------------------------------------------------
  starrocks-cn:
    image: starrocks/cn-ubuntu:latest
    container_name: starrocks-cn
    networks: [sr-net]
    ports:
      - "8040:8040"   # CN HTTP API
      - "9050:9050"   # CN heartbeat
      - "9060:9060"   # CN thrift
    volumes:
      - cn-cache:/opt/starrocks/cn/datacache
    entrypoint: >
      /bin/bash -c "
        printf '\ndatacache_enable = true\ndatacache_disk_path = /opt/starrocks/cn/datacache\ndatacache_disk_size = 10737418240\ndatacache_populate_mode = auto\nmem_limit = 4294967296\n'
          >> /opt/starrocks/cn/conf/cn.conf &&
        exec /opt/starrocks/cn/bin/start_cn.sh
      "
    depends_on:
      starrocks-fe:
        condition: service_healthy

  # One-shot: register CN with FE, create storage volume, set as default
  # mariadb instead of mysql:latest — MySQL 9.x defaults to caching_sha2_password
  # which StarRocks does not support; MariaDB client uses mysql_native_password.
  starrocks-init:
    image: mariadb:latest
    container_name: starrocks-init
    networks: [sr-net]
    depends_on:
      starrocks-cn:
        condition: service_started
    entrypoint: >
      /bin/bash -c "
        echo 'Waiting for FE MySQL port to accept connections...' &&
        until mariadb -h starrocks-fe -P 9030 -u root --connect-timeout=5 -e 'SELECT 1' > /dev/null 2>&1; do
          echo '  FE not ready yet, retrying in 5s...'; sleep 5
        done &&

        echo 'FE ready. Giving CN 15s to start...' && sleep 15 &&

        echo 'Registering CN with FE...' &&
        mariadb -h starrocks-fe -P 9030 -u root -e \"ALTER SYSTEM ADD COMPUTE NODE 'starrocks-cn:9050';\" &&

        echo 'Waiting 20s for CN registration to complete...' && sleep 20 &&

        echo 'Creating S3 storage volume (MinIO)...' &&
        mariadb -h starrocks-fe -P 9030 -u root -e \"CREATE STORAGE VOLUME IF NOT EXISTS minio_vol TYPE = S3 LOCATIONS = ('s3://starrocks/') PROPERTIES ('enabled' = 'true', 'aws.s3.region' = 'us-east-1', 'aws.s3.endpoint' = 'http://minio:9000', 'aws.s3.access_key' = 'minioadmin', 'aws.s3.secret_key' = 'minioadmin', 'aws.s3.enable_ssl' = 'false', 'aws.s3.enable_path_style_access' = 'true');\" &&

        echo 'Setting minio_vol as default storage volume...' &&
        mariadb -h starrocks-fe -P 9030 -u root -e \"SET minio_vol AS DEFAULT STORAGE VOLUME;\" &&

        echo 'Enabling query profiler (global)...' &&
        mariadb -h starrocks-fe -P 9030 -u root -e \"SET GLOBAL enable_profile = true; SET GLOBAL pipeline_profile_level = 1;\" &&

        echo '=== StarRocks init complete ==='
      "

  # ---------------------------------------------------------------------------
  # Redpanda — Kafka-compatible broker for Routine Load testing
  # ---------------------------------------------------------------------------
  redpanda:
    image: docker.redpanda.com/redpandadata/redpanda:latest
    container_name: redpanda
    networks: [sr-net]
    ports:
      - "9092:9092"    # Kafka API (host access)
      - "29092:29092"  # Kafka API (inter-container; used by StarRocks Routine Load)
      - "8082:8082"    # Pandaproxy REST API
      - "9644:9644"    # Redpanda Admin API
    volumes:
      - redpanda-data:/var/lib/redpanda/data
    command:
      - redpanda
      - start
      - --smp=1
      - --memory=512M
      - --overprovisioned
      - --kafka-addr=PLAINTEXT://0.0.0.0:29092,OUTSIDE://0.0.0.0:9092
      - --advertise-kafka-addr=PLAINTEXT://redpanda:29092,OUTSIDE://localhost:9092
      - --pandaproxy-addr=0.0.0.0:8082
      - --advertise-pandaproxy-addr=localhost:8082
      - --schema-registry-addr=0.0.0.0:8081
      - --mode=dev-container
    healthcheck:
      test: ["CMD-SHELL", "rpk cluster health | grep -E 'Healthy.*true'"]
      interval: 15s
      timeout: 10s
      retries: 10
      start_period: 30s

  # ---------------------------------------------------------------------------
  # Redpanda Console — web UI for Kafka topics, consumer groups, messages
  # ---------------------------------------------------------------------------
  redpanda-console:
    image: docker.redpanda.com/redpandadata/console:latest
    container_name: redpanda-console
    networks: [sr-net]
    ports:
      - "8080:8080"   # Redpanda Console UI
    environment:
      KAFKA_BROKERS: redpanda:29092
      KAFKA_SCHEMAREGISTRY_ENABLED: "true"
      KAFKA_SCHEMAREGISTRY_URLS: "http://redpanda:8081"
    depends_on:
      redpanda:
        condition: service_healthy

  # One-shot: write GlobalConfiguration/data-sources.json into the CloudBeaver
  # workspace volume so the StarRocks connection is pre-configured on first run.
  cloudbeaver-init:
    image: alpine:latest
    container_name: cloudbeaver-init
    networks: [sr-net]
    volumes:
      - cloudbeaver-data:/workspace
    entrypoint: >
      /bin/sh -c "
        mkdir -p /workspace/GlobalConfiguration/.dbeaver &&
        printf '{\"folders\":{},\"connections\":{\"mysql-starrocks\":{\"provider\":\"mysql\",\"driver\":\"mysql8\",\"name\":\"StarRocks (Local)\",\"save-password\":true,\"configuration\":{\"host\":\"starrocks-fe\",\"port\":\"9030\",\"database\":\"\",\"user\":\"root\",\"password\":\"\",\"url\":\"jdbc:mysql://starrocks-fe:9030/\",\"configurationType\":\"MANUAL\",\"type\":\"dev\",\"closeIdleConnection\":true,\"properties\":{\"useSSL\":\"false\",\"allowPublicKeyRetrieval\":\"true\"}}}}}' > /workspace/GlobalConfiguration/.dbeaver/data-sources.json &&
        echo 'CloudBeaver data sources pre-configured.'
      "

  # ---------------------------------------------------------------------------
  # CloudBeaver — web-based SQL query UI; connects to StarRocks via MySQL protocol
  # CB_ADMIN_NAME/CB_ADMIN_PASSWORD skip the first-run setup wizard.
  # The StarRocks connection is pre-loaded by cloudbeaver-init via GlobalConfiguration.
  # ---------------------------------------------------------------------------
  cloudbeaver:
    image: dbeaver/cloudbeaver:latest
    container_name: cloudbeaver
    networks: [sr-net]
    ports:
      - "8978:8978"   # CloudBeaver web UI
    environment:
      CB_ADMIN_NAME: cbadmin
      CB_ADMIN_PASSWORD: cbadmin
    volumes:
      - cloudbeaver-data:/opt/cloudbeaver/workspace
    depends_on:
      cloudbeaver-init:
        condition: service_completed_successfully
      starrocks-fe:
        condition: service_healthy
```

---

## Step 2 — Start the Environment

```bash
# From the starrocks-local/ directory:
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

## Step 3 — Verify the Cluster

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

## Step 4 — Create a Test Table (Primary Key Model)

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

## Step 5 — Test Routine Load (Kafka Ingest)

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

## Step 6 — Test Compliance Operations

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

## Step 7 — Test S3 Pipe (File Ingest)

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

## Step 8 — Monitor Cache Hit Ratio

```sql
-- Data cache statistics per CN — validates Open Decision #12 (cache warmth)
SELECT * FROM information_schema.datacache_stats\G

-- CN-level config verification
SHOW COMPUTE NODES\G
```

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

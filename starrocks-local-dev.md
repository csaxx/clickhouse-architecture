# StarRocks Local Prototype Setup Guide

A step-by-step guide to running the StarRocks shared-data architecture from `starrocks-architecture.md` locally using Docker and Portainer. Scaled down to run on a single VM or a small cluster with limited resources.

---

## Table of Contents

1. [What This Guide Covers](#1-what-this-guide-covers)
2. [Prerequisites and Resource Requirements](#2-prerequisites-and-resource-requirements)
3. [File Structure](#3-file-structure)
4. [Configuration Files](#4-configuration-files)
5. [Docker Compose Stack](#5-docker-compose-stack)
6. [Deploying in Portainer](#6-deploying-in-portainer)
7. [Post-Start Initialization](#7-post-start-initialization)
8. [Smoke Test: Table, Insert, Query](#8-smoke-test-table-insert-query)
9. [Optional: Kafka Ingest (Routine Load)](#9-optional-kafka-ingest-routine-load)
10. [Optional: S3 File Ingest (Pipe)](#10-optional-s3-file-ingest-pipe)
11. [Compliance Operations](#11-compliance-operations)
12. [Monitoring Queries](#12-monitoring-queries)
13. [Add a Second BE](#13-add-a-second-be)
14. [Troubleshooting](#14-troubleshooting)
15. [What This Prototype Validates](#15-what-this-prototype-validates)

---

## 1. What This Guide Covers

**Production architecture** (from `starrocks-architecture.md`):
- 3 FE nodes + 7 BE nodes + MinIO/NetApp = 10 pods on Kubernetes

**This prototype**:
- 1 FE + 1 BE + MinIO (single node) = 3 containers on Docker
- Optional: +1 Kafka broker for Routine Load testing
- Optional: second BE to test tablet redistribution

**What you can validate here:**
- Shared-data mode: S3 (MinIO) as primary storage, NVMe cache layer
- PRIMARY KEY table: merge-on-write dedup (no transient duplicates)
- `CREATE ROUTINE LOAD` vs ClickHouse KafkaEngine + MV pattern
- `CREATE PIPE` vs S3Queue + MV pattern
- Compliance: immediate logical delete, `ALTER TABLE COMPACT`
- Dynamic partition management, TTL
- MySQL-compatible client (any mysql CLI works)
- FE as unified control plane (no Distributed table needed)
- Tablet redistribution when adding a second BE

**What you cannot validate here:**
- FE HA / leader failover (needs 3 FEs for quorum)
- Sustained 57,870 rows/sec throughput (hardware limited)
- NVMe cache sizing for production working set
- kube-starrocks operator behavior
- Vault credential injection

---

## 2. Prerequisites and Resource Requirements

### Software

- Docker Engine 24+ or Docker Desktop
- Portainer CE (for GUI deployment, optional — `docker compose up` also works)
- `mysql` CLI client (for running SQL — any MySQL 5.7+ compatible client works)
- `mc` (MinIO client) — only needed for manual bucket operations; included as a container

### Minimum Resource Requirements

| Component | RAM | CPU | Disk |
|---|---|---|---|
| StarRocks FE | 2 GB | 1 core | 2 GB (metadata) |
| StarRocks BE | 2 GB | 2 cores | 5 GB (storage + cache) |
| MinIO | 512 MB | 0.5 core | 10 GB (data) |
| Kafka (optional) | 1 GB | 1 core | 2 GB |
| **Total (no Kafka)** | **~4.5 GB** | **3.5 cores** | **~17 GB** |
| **Total (with Kafka)** | **~5.5 GB** | **4.5 cores** | **~19 GB** |

> FE and BE both have large default JVM heap sizes. The configuration in this guide caps FE at 1 GB and BE at 2 GB heap, which is sufficient for prototype workloads. In production these are 8 GB and 16+ GB respectively.

### Network

All containers must be on the same Docker network. The compose file handles this. If you are running containers on multiple VMs with Docker Swarm, see the note in [Section 5](#5-docker-compose-stack).

---

## 3. File Structure

Create this directory structure before deploying. Everything lives under a single directory (e.g., `starrocks-local/`):

```
starrocks-local/
├── docker-compose.yml          ← main stack (FE + BE + MinIO)
├── docker-compose.kafka.yml    ← optional Kafka add-on stack
├── config/
│   ├── fe.conf                 ← FE configuration
│   └── be.conf                 ← BE configuration
└── init/
    ├── 01_storage_volume.sql   ← create MinIO storage volume
    ├── 02_database.sql         ← create database
    └── 03_events_table.sql     ← create events table
```

Create the directories:
```bash
mkdir -p starrocks-local/config starrocks-local/init
cd starrocks-local
```

---

## 4. Configuration Files

### `config/fe.conf`

```conf
# StarRocks FE configuration — prototype / local dev
# Production values are significantly larger; this file is scaled for limited resources.

# -----------------------------------------------------------------------
# Shared-data mode — this is the key setting that enables S3-backed storage
# -----------------------------------------------------------------------
run_mode = shared_data

# -----------------------------------------------------------------------
# Ports (defaults — change only if there are conflicts on your host)
# -----------------------------------------------------------------------
http_port = 8030          # HTTP API and web UI
rpc_port = 9020           # internal FE-to-BE RPC
query_port = 9030         # MySQL protocol (connect with mysql client here)
edit_log_port = 9010      # BDB-JE Raft log port

# -----------------------------------------------------------------------
# Metadata storage
# -----------------------------------------------------------------------
meta_dir = /opt/starrocks/fe/meta

# -----------------------------------------------------------------------
# JVM heap — capped for prototype (production: 8g+)
# -----------------------------------------------------------------------
JAVA_OPTS = -Xmx1g -XX:+UseG1GC -XX:MaxGCPauseMillis=200

# -----------------------------------------------------------------------
# Logging — reduce verbosity for local use
# -----------------------------------------------------------------------
sys_log_level = INFO

# -----------------------------------------------------------------------
# Priority network — use the container's default interface.
# Set this to the container IP prefix if FE and BE are on different hosts.
# For single-host Docker Compose, leave this commented out.
# -----------------------------------------------------------------------
# priority_networks = 172.20.0.0/16
```

### `config/be.conf`

```conf
# StarRocks BE configuration — prototype / local dev

# -----------------------------------------------------------------------
# Local working directory (NOT the primary data store — S3 is primary)
# Used for intermediate state, rowset staging, and compaction scratch space.
# -----------------------------------------------------------------------
storage_root_path = /opt/starrocks/be/storage

# -----------------------------------------------------------------------
# NVMe data cache — equivalent to ClickHouse's cache disk type
# datacache_disk_path: where hot tablet pages are cached locally
# datacache_disk_size: cap the cache at 2 GB for prototype
# In production: target 20-30% of expected dataset size
# -----------------------------------------------------------------------
datacache_enable = true
datacache_disk_path = /opt/starrocks/be/datacache
datacache_disk_size = 2147483648

# Controls when cache is populated.
# auto: opportunistically populate on write (reduces cold-read latency
#       on freshly ingested data — the gap vs ClickHouse's cache_on_write_operations = 1)
# read: populate only on read (default)
datacache_populate_mode = auto

# -----------------------------------------------------------------------
# Ports (defaults — change only if there are conflicts on your host)
# -----------------------------------------------------------------------
be_port = 9060            # thrift port (FE registers BE here)
be_http_port = 8040       # HTTP API
heartbeat_service_port = 9050  # FE-to-BE heartbeat
brpc_port = 8060          # BE-to-BE data exchange

# -----------------------------------------------------------------------
# JVM heap for compaction tasks — capped for prototype
# -----------------------------------------------------------------------
JAVA_OPTS = -Xmx512m

# -----------------------------------------------------------------------
# CPU and thread limits — reduce for limited-resource environments
# -----------------------------------------------------------------------
# Default compaction thread counts are high. Reduce for local use.
cumulative_compaction_num_threads_per_disk = 1
base_compaction_num_threads_per_disk = 1

# -----------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------
sys_log_level = INFO
```

---

## 5. Docker Compose Stack

### `docker-compose.yml` — Core Stack (FE + BE + MinIO)

```yaml
version: '3.8'

# ---------------------------------------------------------------------------
# StarRocks Prototype Stack
# Architecture: 1 FE + 1 BE + MinIO (S3 backend)
# Scaled for local dev with limited resources.
# ---------------------------------------------------------------------------

services:

  # -------------------------------------------------------------------------
  # MinIO — S3-compatible object storage
  # Replaces production MinIO (distributed, erasure-coded) or NetApp.
  # Single-node mode is NOT suitable for production; fine for prototype.
  # -------------------------------------------------------------------------
  minio:
    image: minio/minio:RELEASE.2024-01-01T00-00-00Z
    container_name: sr-minio
    hostname: minio
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: minioadmin123
    ports:
      - "9000:9000"   # S3 API
      - "9001:9001"   # MinIO Console (web UI)
    volumes:
      - minio_data:/data
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 10s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          memory: 512M

  # -------------------------------------------------------------------------
  # MinIO init — creates the bucket before StarRocks starts
  # Runs once and exits. Uses minio/mc (MinIO client).
  # -------------------------------------------------------------------------
  minio-init:
    image: minio/mc:latest
    container_name: sr-minio-init
    depends_on:
      minio:
        condition: service_healthy
    entrypoint: >
      /bin/sh -c "
      echo 'Waiting for MinIO...';
      mc alias set local http://minio:9000 minioadmin minioadmin123;
      mc mb local/starrocks-bucket --ignore-existing;
      echo 'Bucket ready.';
      "
    deploy:
      resources:
        limits:
          memory: 64M

  # -------------------------------------------------------------------------
  # StarRocks FE — Frontend (metadata + query coordination)
  # Equivalent to: ClickHouse Keeper + ingest cluster coordination + Distributed table routing
  # Production: 3 FE nodes (quorum). Here: 1 FE (no HA — acceptable for prototype).
  # -------------------------------------------------------------------------
  fe:
    image: starrocks/fe-ubuntu:3.3-latest
    container_name: sr-fe
    hostname: fe
    command: >
      /bin/bash -c "
      /opt/starrocks/fe/bin/start_fe.sh &
      FE_PID=$$!;
      echo 'FE started, PID='$$FE_PID;
      wait $$FE_PID
      "
    environment:
      - JAVA_OPTS=-Xmx1g -XX:+UseG1GC
    volumes:
      - ./config/fe.conf:/opt/starrocks/fe/conf/fe.conf:ro
      - fe_meta:/opt/starrocks/fe/meta
    ports:
      - "9030:9030"   # MySQL protocol — connect with: mysql -h 127.0.0.1 -P 9030 -u root
      - "8030:8030"   # HTTP API + StarRocks web UI (open in browser)
    depends_on:
      minio-init:
        condition: service_completed_successfully
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8030/api/health"]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 60s
    deploy:
      resources:
        limits:
          memory: 1536M   # 1 GB JVM + 512 MB overhead

  # -------------------------------------------------------------------------
  # StarRocks BE — Backend (compute + S3 data cache)
  # Equivalent to: ClickHouse cache cluster nodes (storage + query execution)
  # Production: 7 BE nodes. Here: 1 BE (no tablet distribution across nodes).
  # -------------------------------------------------------------------------
  be:
    image: starrocks/be-ubuntu:3.3-latest
    container_name: sr-be
    hostname: be
    command: /opt/starrocks/be/bin/start_be.sh
    volumes:
      - ./config/be.conf:/opt/starrocks/be/conf/be.conf:ro
      - be_storage:/opt/starrocks/be/storage
      - be_cache:/opt/starrocks/be/datacache
    ports:
      - "8040:8040"   # BE HTTP API
      - "9060:9060"   # BE thrift (used by FE to register this BE)
    depends_on:
      fe:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8040/api/health"]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 90s
    deploy:
      resources:
        limits:
          memory: 2560M   # 2 GB JVM + 512 MB overhead

  # -------------------------------------------------------------------------
  # StarRocks setup — runs once after FE and BE are healthy
  # Registers the BE with FE and creates the S3 storage volume.
  # Exits after completion; check logs to confirm success.
  # -------------------------------------------------------------------------
  setup:
    image: mysql:8
    container_name: sr-setup
    depends_on:
      fe:
        condition: service_healthy
      be:
        condition: service_healthy
    entrypoint: >
      /bin/bash -c "
      echo 'Registering BE with FE...';
      mysql -h fe -P 9030 -u root --connect-timeout=30 -e \"ALTER SYSTEM ADD BACKEND 'be:9050';\";
      echo 'Creating S3 storage volume...';
      mysql -h fe -P 9030 -u root --connect-timeout=30 << 'SQL'
      CREATE STORAGE VOLUME IF NOT EXISTS dev_s3_volume
      TYPE = S3
      LOCATIONS = ('s3://starrocks-bucket/data')
      PROPERTIES (
          \"enabled\" = \"true\",
          \"aws.s3.region\" = \"us-east-1\",
          \"aws.s3.endpoint\" = \"http://minio:9000\",
          \"aws.s3.access_key\" = \"minioadmin\",
          \"aws.s3.secret_key\" = \"minioadmin123\",
          \"aws.s3.path_style_access\" = \"true\",
          \"aws.s3.enable_ssl\" = \"false\"
      );
      SQL
      echo 'Setting default storage volume...';
      mysql -h fe -P 9030 -u root --connect-timeout=30 -e \"SET default_storage_volume = dev_s3_volume;\";
      echo 'Setup complete.';
      "
    deploy:
      resources:
        limits:
          memory: 64M

volumes:
  minio_data:
    driver: local
  fe_meta:
    driver: local
  be_storage:
    driver: local
  be_cache:
    driver: local

networks:
  default:
    name: starrocks-net
    driver: bridge
```

> **Docker Swarm note**: If you are running containers across multiple VMs in Swarm mode, replace the `bridge` network with an `overlay` network and set `driver: overlay`. The `hostname` values used for inter-container DNS resolution (`fe`, `be`, `minio`) work the same way in overlay networks. The `setup` service's BE registration command (`ALTER SYSTEM ADD BACKEND 'be:9050'`) uses the container hostname, which resolves to the correct IP in both bridge and overlay networks.

### `docker-compose.kafka.yml` — Optional Kafka Add-On

Deploy this as a separate stack after the core stack is running. Uses Kafka KRaft mode (no ZooKeeper needed).

```yaml
version: '3.8'

# ---------------------------------------------------------------------------
# Kafka Add-On Stack
# Deploys a single-broker Kafka in KRaft mode (no ZooKeeper).
# Connect to: kafka:9092 from other containers on starrocks-net
# External access (from your host): localhost:19092
# ---------------------------------------------------------------------------

services:

  kafka:
    image: confluentinc/cp-kafka:7.6.0
    container_name: sr-kafka
    hostname: kafka
    environment:
      KAFKA_NODE_ID: 1
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093,EXTERNAL://0.0.0.0:19092
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka:9092,EXTERNAL://localhost:19092
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: PLAINTEXT:PLAINTEXT,CONTROLLER:PLAINTEXT,EXTERNAL:PLAINTEXT
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@kafka:9093
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 1
      KAFKA_AUTO_CREATE_TOPICS_ENABLE: "true"
      CLUSTER_ID: "MkU3OEVBNTcwNTJENDM2Qk"  # stable cluster ID for KRaft
      # Reduce memory for limited resources
      KAFKA_HEAP_OPTS: "-Xmx512m -Xms256m"
    ports:
      - "9092:9092"    # internal (from other containers)
      - "19092:19092"  # external (from your host for testing)
    volumes:
      - kafka_data:/var/lib/kafka/data
    healthcheck:
      test: ["CMD", "kafka-topics", "--bootstrap-server", "localhost:9092", "--list"]
      interval: 15s
      timeout: 10s
      retries: 5
      start_period: 30s
    deploy:
      resources:
        limits:
          memory: 768M

  # Creates the events topic with 6 partitions on startup
  kafka-init:
    image: confluentinc/cp-kafka:7.6.0
    container_name: sr-kafka-init
    depends_on:
      kafka:
        condition: service_healthy
    entrypoint: >
      /bin/bash -c "
      kafka-topics --bootstrap-server kafka:9092 --create
        --topic events
        --partitions 6
        --replication-factor 1
        --if-not-exists;
      echo 'Topic events created (6 partitions).';
      kafka-topics --bootstrap-server kafka:9092 --describe --topic events;
      "
    deploy:
      resources:
        limits:
          memory: 64M

volumes:
  kafka_data:
    driver: local

networks:
  default:
    name: starrocks-net
    external: true   # join the existing starrocks-net network
```

---

## 6. Deploying in Portainer

### Method A: Portainer Stacks UI (recommended)

1. Open Portainer → **Stacks** → **Add stack**
2. Name the stack `starrocks`
3. Under **Build method**, choose **Web editor**
4. Paste the contents of `docker-compose.yml`
5. Click **Deploy the stack**

Portainer will pull images and start containers in dependency order. Watch the **Containers** view; the startup sequence is:

```
minio (starts) → minio-init (runs, exits) → fe (starts) → be (starts) → setup (runs, exits)
```

FE takes 30–60 seconds to fully initialize. BE takes 60–90 seconds. The `setup` container will wait for both health checks before running.

6. After deployment, check **Container logs** for:
   - `sr-fe`: look for `Waiting for connections` or `FE started`
   - `sr-be`: look for `BE started`
   - `sr-setup`: look for `Setup complete.`

7. **Optional**: Deploy the Kafka add-on as a second stack named `starrocks-kafka`, pasting `docker-compose.kafka.yml`.

### Method B: Docker Compose CLI

```bash
cd starrocks-local

# Start the core stack
docker compose up -d

# Watch logs during startup
docker compose logs -f

# Start Kafka add-on (optional, in a separate terminal after core stack is healthy)
docker compose -f docker-compose.kafka.yml up -d
```

### Verifying Startup

```bash
# Check all containers are running
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Expected output:
# sr-minio      Up 5 minutes (healthy)    0.0.0.0:9000-9001->9000-9001/tcp
# sr-fe         Up 4 minutes (healthy)    0.0.0.0:8030->8030/tcp, 0.0.0.0:9030->9030/tcp
# sr-be         Up 3 minutes (healthy)    0.0.0.0:8040->8040/tcp, 0.0.0.0:9060->9060/tcp
# sr-minio-init Exited (0)
# sr-setup      Exited (0)

# Connect with mysql client to verify FE is accepting connections
mysql -h 127.0.0.1 -P 9030 -u root --prompt="starrocks> "
```

> **Default credentials**: FE starts with user `root` and no password. Set a password in production.

---

## 7. Post-Start Initialization

The `setup` container already ran `ALTER SYSTEM ADD BACKEND` and created the storage volume. Verify and then set up the database and table.

### Verify Setup Completed

Connect to FE via MySQL client:

```bash
mysql -h 127.0.0.1 -P 9030 -u root
```

Run these checks:

```sql
-- 1. Verify BE is registered and alive
SHOW BACKENDS\G
-- Expected: 1 row, Alive = true, TabletNum = 0 (no tables yet)

-- 2. Verify storage volume exists and is enabled
SHOW STORAGE VOLUMES\G
-- Expected: dev_s3_volume, enabled = true

-- 3. Verify default storage volume is set
SHOW DEFAULT STORAGE VOLUME\G
-- Expected: dev_s3_volume

-- 4. Verify shared-data mode is active
SHOW FRONTENDS\G
-- Expected: 1 row; check that run_mode = SHARED_DATA in fe.conf took effect
-- (visible as a property of the FE or via ADMIN SHOW FRONTEND CONFIG LIKE 'run_mode')
ADMIN SHOW FRONTEND CONFIG LIKE 'run_mode';
-- Expected: run_mode = shared_data
```

### If Setup Container Failed

If the `setup` container exited with a non-zero code (check Portainer logs), run the initialization manually:

```sql
-- Connect to FE, then run:

-- Register the BE (use the container hostname 'be' + heartbeat port 9050)
ALTER SYSTEM ADD BACKEND 'be:9050';

-- Create the storage volume
CREATE STORAGE VOLUME IF NOT EXISTS dev_s3_volume
TYPE = S3
LOCATIONS = ('s3://starrocks-bucket/data')
PROPERTIES (
    "enabled" = "true",
    "aws.s3.region" = "us-east-1",
    "aws.s3.endpoint" = "http://minio:9000",
    "aws.s3.access_key" = "minioadmin",
    "aws.s3.secret_key" = "minioadmin123",
    "aws.s3.path_style_access" = "true",
    "aws.s3.enable_ssl" = "false"
);

-- Set as default for all new tables
SET default_storage_volume = dev_s3_volume;
```

> **Port note**: `ALTER SYSTEM ADD BACKEND 'be:9050'` uses port 9050 (heartbeat port). This is different from the BE thrift port 9060. The FE uses 9050 to track BE liveness.

---

## 8. Smoke Test: Table, Insert, Query

This section validates the key behaviors of the PRIMARY KEY model compared to ClickHouse's ReplicatedReplacingMergeTree.

### Create Database and Table

```sql
-- Create database
CREATE DATABASE IF NOT EXISTS events_db;
USE events_db;

-- Create PRIMARY KEY table in shared-data mode
-- This is a scaled-down version of 03_events_table.sql
CREATE TABLE IF NOT EXISTS events_db.events
(
    event_id      BIGINT  NOT NULL  COMMENT "Deduplication primary key",
    user_id       BIGINT  NOT NULL  COMMENT "User identifier; compliance DELETE target",
    event_date    DATE    NOT NULL  COMMENT "Event date; daily partition key",
    eviction_date DATE    NOT NULL  COMMENT "Compliance TTL source",
    event_ts      BIGINT  NOT NULL  COMMENT "Event timestamp in milliseconds"
)
ENGINE = OLAP
PRIMARY KEY (event_id)
ORDER BY (event_id)
PARTITION BY RANGE(event_date) ()
DISTRIBUTED BY HASH(event_id) BUCKETS 3  -- 3 buckets: 3 × 1 BE (rule of thumb: 3 × BE count)
PROPERTIES (
    "replication_num" = "1",              -- shared-data mode: S3 is the replica
    "storage_volume" = "dev_s3_volume",
    "datacache_enable" = "true",
    "datacache_partition_duration" = "7 DAY",
    "dynamic_partition.enable" = "true",
    "dynamic_partition.time_unit" = "DAY",
    "dynamic_partition.start" = "-30",
    "dynamic_partition.end" = "3",
    "dynamic_partition.prefix" = "p",
    "dynamic_partition.buckets" = "3",
    "partition_ttl" = "30 DAY"
);
```

Verify the table was created and partitions initialized:

```sql
DESCRIBE events_db.events;
SHOW PARTITIONS FROM events_db.events ORDER BY PartitionName;
-- Expected: partitions for today-30 through today+3, all auto-created by dynamic_partition
```

### Insert and Verify Dedup (Key Behavior Test)

This is the most important test: confirming no transient duplicates (unlike ClickHouse's ReplacingMergeTree).

```sql
USE events_db;

-- Insert row with event_id = 1
INSERT INTO events VALUES
(1, 100, CURDATE(), CURDATE(), UNIX_TIMESTAMP() * 1000);

-- Insert the same event_id again with different event_ts (simulates a duplicate/re-delivery)
INSERT INTO events VALUES
(1, 100, CURDATE(), CURDATE(), UNIX_TIMESTAMP() * 1000 + 9999);

-- Query immediately — no SELECT FINAL needed, no OPTIMIZE needed
-- In ClickHouse ReplacingMergeTree: both rows would be visible here until background merge
-- In StarRocks PRIMARY KEY: only 1 row visible immediately
SELECT * FROM events WHERE event_id = 1;
-- Expected: exactly 1 row (the second INSERT replaced the first on write)

-- Count — should be 1, not 2
SELECT count(*) FROM events;
-- Expected: 1
```

### Insert More Data

```sql
-- Insert a batch of events
INSERT INTO events VALUES
(2,  101, CURDATE(), CURDATE(), UNIX_TIMESTAMP() * 1000),
(3,  102, CURDATE(), CURDATE(), UNIX_TIMESTAMP() * 1000),
(4,  100, CURDATE(), CURDATE(), UNIX_TIMESTAMP() * 1000),
(5,  103, CURDATE(), CURDATE(), UNIX_TIMESTAMP() * 1000),
(2,  101, CURDATE(), CURDATE(), UNIX_TIMESTAMP() * 1000 + 1);  -- duplicate of event_id=2

SELECT count(*) FROM events;
-- Expected: 5 (event_ids 1, 2, 3, 4, 5; the duplicate event_id=2 was replaced)

-- Count distinct users
SELECT count(DISTINCT user_id) FROM events;
-- Expected: 4 (users 100, 101, 102, 103)
```

### Verify Data is in MinIO (S3)

Open the MinIO Console at **http://localhost:9001** (login: `minioadmin` / `minioadmin123`).
Browse to `starrocks-bucket/data/` — you should see a directory tree like:
```
data/
  └── 1/          ← db_id
        └── 10*/  ← table_id
              └── ...  ← partition + tablet data (rowsets)
```

This confirms the shared-data mode is working: data is in S3, not on the BE disk.

---

## 9. Optional: Kafka Ingest (Routine Load)

Deploy the Kafka stack first (see [Section 5](#5-docker-compose-stack)), then follow these steps.

### Create the Routine Load Job

This replaces the ClickHouse pattern of KafkaEngine table + Materialized View + Distributed table (3 objects → 1 object).

```sql
USE events_db;

CREATE ROUTINE LOAD events_db.events_kafka_load ON events_db.events

COLUMNS
(
    event_id,
    user_id,
    event_ts,
    eviction_date,
    event_date = str_to_date(from_unixtime(event_ts / 1000), '%Y-%m-%d')
    -- ClickHouse equivalent: toDate(toDateTime64(event_ts / 1000, 3)) AS event_date
)

PROPERTIES
(
    -- For prototype with 6 Kafka partitions and 1 BE:
    -- Use 2 sub-tasks (≤ partition count, and manageable on 1 BE)
    "desired_concurrent_number" = "2",

    -- Batch size: keep low for prototype to see data quickly
    -- Production uses 500,000 to avoid rowset accumulation
    "max_batch_rows" = "10000",
    "max_batch_interval" = "5",    -- flush every 5 seconds

    "max_error_number" = "100",
    "max_filter_ratio" = "0.1",
    "strict_mode" = "true",
    "timezone" = "UTC",
    "consumer_group" = "starrocks_dev_events_load"
)

FROM KAFKA
(
    -- 'kafka' is the container hostname, reachable within the starrocks-net Docker network
    "kafka_broker_list" = "kafka:9092",
    "kafka_topic" = "events",
    "kafka_partitions" = "0,1,2,3,4,5",
    "kafka_offsets" = "OFFSET_END,OFFSET_END,OFFSET_END,OFFSET_END,OFFSET_END,OFFSET_END",
    "format" = "json",
    "strip_outer_array" = "false"
);
```

### Check Job Status

```sql
-- View job status (shows state, consumed rows, error rows, lag)
SHOW ROUTINE LOAD FOR events_db.events_kafka_load\G

-- View sub-task details (shows which Kafka partitions each sub-task owns)
SHOW ROUTINE LOAD TASK FOR events_db.events_kafka_load\G
```

### Produce Test Messages

From your host machine, produce some JSON messages to the Kafka topic:

```bash
# Connect to Kafka container and produce test messages
docker exec -it sr-kafka /bin/bash

# Inside the container:
kafka-console-producer \
  --bootstrap-server localhost:9092 \
  --topic events \
  --property "parse.key=false"

# Type or paste these JSON messages (one per line, then Ctrl+C):
{"event_id": 1001, "user_id": 200, "event_ts": 1704067200000, "eviction_date": "2024-12-31"}
{"event_id": 1002, "user_id": 201, "event_ts": 1704067260000, "eviction_date": "2024-12-31"}
{"event_id": 1003, "user_id": 200, "event_ts": 1704067320000, "eviction_date": "2024-12-31"}
{"event_id": 1001, "user_id": 200, "event_ts": 1704067200001, "eviction_date": "2024-12-31"}
```

The last message has the same `event_id` (1001) as the first — this is a duplicate. After the Routine Load batch flushes (within `max_batch_interval` = 5 seconds), query the table:

```sql
SELECT * FROM events_db.events WHERE event_id = 1001;
-- Expected: 1 row (duplicate replaced on INSERT)

SELECT count(*) FROM events_db.events WHERE event_id >= 1001;
-- Expected: 3 (event_ids 1001, 1002, 1003)
```

### Job Lifecycle Commands

```sql
-- Pause (stops consuming; Kafka offsets held)
PAUSE ROUTINE LOAD FOR events_db.events_kafka_load;

-- Resume
RESUME ROUTINE LOAD FOR events_db.events_kafka_load;

-- Change batch interval without recreating the job
ALTER ROUTINE LOAD FOR events_db.events_kafka_load
PROPERTIES ("max_batch_interval" = "10");

-- Stop permanently (non-recoverable)
STOP ROUTINE LOAD FOR events_db.events_kafka_load;
```

---

## 10. Optional: S3 File Ingest (Pipe)

This replaces the ClickHouse pattern of S3Queue table + Materialized View (2 objects → 1 object). The Pipe monitors a MinIO path for new files.

### Create a Test Parquet File

For simplicity, use a JSON file (Parquet requires an additional tool). Upload it directly to MinIO.

```bash
# Create a test JSON file
cat > /tmp/test_events.json << 'EOF'
{"event_id": 2001, "user_id": 300, "event_ts": 1704153600000, "eviction_date": "2024-12-31"}
{"event_id": 2002, "user_id": 301, "event_ts": 1704153660000, "eviction_date": "2024-12-31"}
{"event_id": 2003, "user_id": 300, "event_ts": 1704153720000, "eviction_date": "2024-12-31"}
EOF

# Upload to MinIO using mc (from your host, if mc is installed)
mc alias set local http://localhost:9000 minioadmin minioadmin123
mc cp /tmp/test_events.json local/starrocks-bucket/source-events/

# Or upload via MinIO Console at http://localhost:9001
```

### Create the Pipe

```sql
USE events_db;

CREATE PIPE IF NOT EXISTS events_db.events_s3_pipe
PROPERTIES
(
    "auto_ingest" = "true",
    "poll_interval" = "30",        -- check for new files every 30 seconds
    "max_concurrent_tasks" = "1"   -- single BE, single concurrent task is enough
)
AS
INSERT INTO events_db.events
(
    event_id, user_id, event_ts, eviction_date, event_date
)
SELECT
    event_id,
    user_id,
    event_ts,
    eviction_date,
    str_to_date(from_unixtime(event_ts / 1000), '%Y-%m-%d') AS event_date
FROM FILES
(
    -- MinIO path: the container hostname 'minio' resolves within starrocks-net
    "path" = "s3://starrocks-bucket/source-events/",
    "format" = "json",
    "aws.s3.endpoint" = "http://minio:9000",
    "aws.s3.region" = "us-east-1",
    "aws.s3.access_key" = "minioadmin",
    "aws.s3.secret_key" = "minioadmin123",
    "aws.s3.path_style_access" = "true",
    "aws.s3.enable_ssl" = "false",
    "strip_outer_array" = "false"
);
```

### Monitor and Verify

```sql
-- Check Pipe status
SHOW PIPES FROM events_db\G

-- Check file processing state
SELECT pipe_name, file_name, file_state, last_modified
FROM information_schema.pipe_files
WHERE pipe_database = 'events_db'
ORDER BY last_modified DESC;
-- Expected: test_events.json with file_state = 'FINISHED'

-- Verify rows were loaded
SELECT * FROM events_db.events WHERE event_id >= 2001;
-- Expected: 3 rows (event_ids 2001, 2002, 2003)
```

If the file state stays `LOADING` for more than a few minutes, check:
```sql
-- Look for errors in the file processing log
SELECT * FROM information_schema.pipe_files
WHERE pipe_database = 'events_db' AND file_state = 'ERROR';
```

### Upload More Files to Test Continuous Ingestion

Drop additional JSON files into `starrocks-bucket/source-events/`. Within `poll_interval` seconds (30 seconds here), the Pipe picks them up automatically. Files already processed will not be re-loaded.

---

## 11. Compliance Operations

### Immediate Logical Delete

```sql
-- Insert a user's data
INSERT INTO events_db.events VALUES
(9001, 999, CURDATE(), CURDATE(), UNIX_TIMESTAMP() * 1000),
(9002, 999, CURDATE(), CURDATE(), UNIX_TIMESTAMP() * 1000 + 1000);

SELECT count(*) FROM events_db.events WHERE user_id = 999;
-- Expected: 2

-- Delete all rows for user_id = 999
-- In StarRocks PRIMARY KEY: rows are IMMEDIATELY invisible after this statement
-- In ClickHouse lightweight delete: rows remain visible until OPTIMIZE PARTITION FINAL
DELETE FROM events_db.events WHERE user_id = 999;

-- Verify immediately — no OPTIMIZE needed
SELECT count(*) FROM events_db.events WHERE user_id = 999;
-- Expected: 0 (immediately, not after background compaction)
```

### Force Physical Compaction

The DELETE above makes rows logically inaccessible immediately, but the bytes are still in S3 until compaction removes them. If physical removal is required by compliance:

```sql
-- Compact a specific partition (replace 'p20240101' with today's partition name)
-- First, find the partition name:
SHOW PARTITIONS FROM events_db.events ORDER BY PartitionName;

-- Then compact it:
ALTER TABLE events_db.events COMPACT PARTITION p20240101;
-- Substitute the correct partition name from the SHOW output.

-- Monitor compaction progress:
SHOW PROC '/compactions'\G

-- Verify compaction completed:
SELECT be_id, type, state, candidate_tablets, running_tablets
FROM information_schema.be_compactions;
```

### TTL Verification

```sql
-- Verify dynamic partition management is running
SHOW DYNAMIC PARTITION TABLES FROM events_db;
-- Expected: events table with dynamic partition enabled

-- Verify partitions exist for upcoming dates (pre-created by dynamic_partition.end = 3)
SELECT PARTITION_NAME, PARTITION_DESCRIPTION
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA = 'events_db' AND TABLE_NAME = 'events'
ORDER BY PARTITION_NAME;
-- Expected: partitions for last 30 days + next 3 days
```

---

## 12. Monitoring Queries

These are the StarRocks equivalents of common ClickHouse `system.*` table queries.

```sql
-- ClickHouse: SELECT * FROM system.parts WHERE table = 'cache_table' AND active
-- StarRocks: partition-level info (no direct "parts" equivalent — use information_schema)
SELECT
    PARTITION_NAME,
    round(DATA_LENGTH / 1073741824.0, 3) AS data_gb,
    TABLE_ROWS
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA = 'events_db' AND TABLE_NAME = 'events'
ORDER BY PARTITION_NAME;

-- ClickHouse: SELECT * FROM system.merges
-- StarRocks: check compaction queue
SELECT be_id, type, state, candidate_tablets, running_tablets
FROM information_schema.be_compactions;

-- ClickHouse: SELECT * FROM system.replicas WHERE behind_count > 0
-- StarRocks: N/A (no replicas in shared-data mode)

-- ClickHouse: SELECT * FROM system.zookeeper WHERE path = '/clickhouse'
-- StarRocks: N/A (no external Keeper; FE internal)

-- FE status (equivalent to ClickHouse cluster overview)
SHOW FRONTENDS\G

-- BE status (equivalent to ClickHouse system.clusters)
SHOW BACKENDS\G

-- Active queries
SHOW PROCESSLIST;

-- Cache hit statistics (equivalent to system.filesystem_cache_log)
SELECT * FROM information_schema.datacache_stats;

-- Routine Load job status
SHOW ROUTINE LOAD FOR events_db.events_kafka_load\G

-- Pipe file processing status
SELECT pipe_name, file_name, file_state
FROM information_schema.pipe_files
WHERE pipe_database = 'events_db'
ORDER BY last_modified DESC
LIMIT 20;

-- Slow query log
SELECT query_id, query, query_time_ms
FROM information_schema.loads
ORDER BY query_time_ms DESC
LIMIT 10;
```

---

## 13. Add a Second BE

This tests the key operational improvement over ClickHouse: adding compute capacity without manual data migration.

### Start a Second BE Container

Add this service to `docker-compose.yml` (or use `docker run` directly for a quick test):

```yaml
  be2:
    image: starrocks/be-ubuntu:3.3-latest
    container_name: sr-be2
    hostname: be2
    command: /opt/starrocks/be/bin/start_be.sh
    volumes:
      - ./config/be.conf:/opt/starrocks/be/conf/be.conf:ro
      - be2_storage:/opt/starrocks/be/storage
      - be2_cache:/opt/starrocks/be/datacache
    ports:
      - "8041:8040"
      - "9061:9060"
    deploy:
      resources:
        limits:
          memory: 2560M
```

Add `be2_storage` and `be2_cache` to the `volumes` section.

### Register the Second BE

After the second BE container is healthy:

```sql
-- Register be2 with FE
ALTER SYSTEM ADD BACKEND 'be2:9050';

-- Verify both BEs are alive
SHOW BACKENDS\G
-- Expected: 2 rows, both Alive = true
```

### Verify Tablet Redistribution

After registration, FE automatically begins redistributing tablets to the new BE. Monitor:

```sql
-- Check tablet distribution across BEs
-- TabletNum should become more balanced between be and be2 over time
SHOW BACKENDS\G

-- You can also force redistribution to start immediately
-- (not needed in production — FE handles this automatically)
ALTER TABLE events_db.events COMPACT;
```

Unlike ClickHouse cache cluster resharding (which requires manual data migration of ~5B rows over multiple hours), StarRocks reads tablets from S3 and assigns them to the new BE without copying data between nodes. The "redistribution" is FE updating its tablet-to-BE assignment metadata; the BE then reads tablet data from S3 on the next query.

---

## 14. Troubleshooting

### FE doesn't start / health check fails

```bash
# Check FE logs
docker logs sr-fe --tail 100

# Common issues:
# 1. Meta directory permissions
docker exec sr-fe ls -la /opt/starrocks/fe/meta

# 2. Java OOM — increase memory limit or reduce JAVA_OPTS Xmx
docker stats sr-fe

# 3. fe.conf syntax error
docker exec sr-fe cat /opt/starrocks/fe/conf/fe.conf
```

### BE doesn't start

```bash
docker logs sr-be --tail 100

# Common issue: BE tries to connect to FE before FE is fully ready
# The depends_on: service_healthy should handle this, but if not, restart be:
docker restart sr-be
```

### Setup container failed / BE not registered

```bash
# Check setup logs
docker logs sr-setup

# If it failed, run manually via mysql client:
mysql -h 127.0.0.1 -P 9030 -u root -e "ALTER SYSTEM ADD BACKEND 'be:9050';"
mysql -h 127.0.0.1 -P 9030 -u root -e "SHOW BACKENDS\G"
```

### Storage volume creation failed

```bash
# Check MinIO is reachable from within the Docker network
docker exec sr-fe curl -v http://minio:9000/minio/health/live

# If MinIO is unreachable: check that sr-minio and sr-fe are on the same network
docker inspect sr-fe | grep -A 10 Networks
docker inspect sr-minio | grep -A 10 Networks
```

### Table creation fails with "storage volume not found"

```sql
-- Verify the volume exists
SHOW STORAGE VOLUMES\G

-- Re-create if missing (copy from Section 7)
-- Then verify default is set:
SHOW DEFAULT STORAGE VOLUME\G

-- If default is not set:
SET default_storage_volume = dev_s3_volume;
```

### Routine Load job in ERROR state

```sql
-- Check error details
SHOW ROUTINE LOAD FOR events_db.events_kafka_load\G
-- Look at: State, ErrorRows, OtherMsg

-- Check sub-task error log URLs
SHOW ROUTINE LOAD TASK FOR events_db.events_kafka_load\G
-- Look at: ErrorLogUrls (these are BE-local file paths, access via docker exec)

-- Resume after fixing the issue
RESUME ROUTINE LOAD FOR events_db.events_kafka_load;
```

### Routine Load consuming but no rows in table

Common causes:
- `kafka_offsets = OFFSET_END` and no new messages were produced after job creation. Produce a test message.
- Column mapping mismatch: check the JSON field names match the COLUMNS clause.
- `strict_mode = true` with type conversion failures. Check error log.

### Pipe stuck in LOADING state

```sql
-- Check file state
SELECT * FROM information_schema.pipe_files WHERE pipe_database = 'events_db'\G

-- If ERROR, check the reason:
SELECT file_name, file_state, error_msg
FROM information_schema.pipe_files
WHERE pipe_database = 'events_db' AND file_state = 'ERROR';
```

Common cause: MinIO path_style_access. The `"aws.s3.path_style_access" = "true"` property is required for MinIO. Verify it is set in the Pipe DDL.

### Can't connect to FE with mysql client

```bash
# Verify port 9030 is accessible
telnet 127.0.0.1 9030

# If connection refused: FE is not yet ready. Wait and retry.
# Default root user has no password — don't add -p flag:
mysql -h 127.0.0.1 -P 9030 -u root
```

---

## 15. What This Prototype Validates

### Validated by this setup

| Capability | How to test |
|---|---|
| Shared-data mode (S3 as primary storage) | Create table, insert rows, verify data appears in MinIO Console |
| PRIMARY KEY merge-on-write dedup | Insert duplicate `event_id`, query immediately — 1 row, not 2 |
| No `SELECT ... FINAL` needed | All SELECT queries return deduplicated data without FINAL |
| Routine Load (Kafka → table) | Section 9: produce messages, verify rows appear |
| `CREATE PIPE` (S3 files → table) | Section 10: drop files in MinIO, verify rows appear |
| Immediate logical delete | Section 11: DELETE, query immediately — 0 rows |
| `ALTER TABLE COMPACT` | Section 11: force physical compaction, monitor SHOW PROC |
| Dynamic partition management | SHOW PARTITIONS — auto-created partitions |
| `partition_ttl` | Wait for TTL window (or set partition_ttl = '1 DAY' and watch a partition drop) |
| MySQL protocol compatibility | Any mysql CLI client works |
| FE as unified control plane | No Distributed tables needed |
| Tablet redistribution on BE add | Section 13: add BE, register, watch TabletNum rebalance |
| `datacache_populate_mode = auto` | Check `information_schema.datacache_stats` after inserts |

### Requires additional environment to validate

| Capability | What's needed |
|---|---|
| FE HA / leader failover | 3 FE nodes with Raft quorum; stop leader FE, verify follower takes over |
| kube-starrocks operator behavior | Kubernetes cluster with operator deployed |
| Sustained 57,870 rows/sec throughput | Production-scale hardware; Primary Key write-path overhead at full load |
| Vault credential injection | HashiCorp Vault running with Kubernetes auth |
| Production NVMe cache sizing | Full dataset volume; monitor cache hit ratio over days |
| FE leader failover during active Pipe load | 3 FE + active Pipe + FE kill test |
| Credential rotation without pod restart | Vault rotation integration test |
| Compaction timing at 90-day partition scale | ~90 partitions × production data volume |

---

*For production deployment architecture, see `starrocks-architecture.md`.
For concept translations from ClickHouse to StarRocks, see `starrocks-guide.md`.
For production DDL, see `starrocks/` SQL files.*

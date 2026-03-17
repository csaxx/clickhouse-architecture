# StarRocks Local — Service Endpoints & Diagnostic URLs

Quick reference for every exposed port and HTTP diagnostic endpoint in the
local Docker Compose stack.

---

## Web UIs

| Service | URL | Credentials | Purpose |
|---|---|---|---|
| StarRocks FE1 web UI | http://localhost:8030 | `root` / _(no password)_ | Query profiler, pipeline profiles, system info |
| StarRocks FE2 web UI | http://localhost:8031 | `root` / _(no password)_ | Observer node UI |
| CloudBeaver SQL IDE | http://localhost:8978 | `cbadmin` / `cbadmin` | Web SQL client; StarRocks connection pre-configured |
| Redpanda Console | http://localhost:8080 | none | Topics, consumer groups, message browser |
| MinIO Console | http://localhost:9001 | `minioadmin` / `minioadmin` | S3 bucket browser; StarRocks data under `starrocks/` |

---

## Client Connection Points

| Service | Address | Protocol | Notes |
|---|---|---|---|
| StarRocks FE1 | `127.0.0.1:9030` | MySQL wire | Primary query entry point |
| StarRocks FE2 | `127.0.0.1:9031` | MySQL wire | Observer — same data, additional query routing |
| Redpanda | `localhost:9092` | Kafka | Host-side producer/consumer access |
| Redpanda (inter-container) | `redpanda:29092` | Kafka | Used by Routine Load jobs inside Docker network |
| Redpanda Pandaproxy | `localhost:8082` | HTTP/REST | Kafka REST proxy |
| MinIO S3 API | `localhost:9000` | S3 | Endpoint for `aws s3` / `mc` CLI access |

```bash
# StarRocks MySQL client
mysql -h 127.0.0.1 -P 9030 -u root

# Redpanda CLI (via container)
docker exec redpanda rpk topic list
docker exec redpanda rpk group list

# MinIO CLI (via container)
docker exec minio mc alias set local http://localhost:9000 minioadmin minioadmin
docker exec minio mc ls local/starrocks
```

---

## StarRocks FE Diagnostic Endpoints

Both FEs expose the same paths; FE1 is on port **8030**, FE2 on **8031**.

| Endpoint | Description |
|---|---|
| `http://localhost:8030/` | FE web UI — query history, pipeline profiles, cluster overview |
| `http://localhost:8030/api/health` | Health check — returns `{"status":"OK"}` when FE is ready |
| `http://localhost:8030/metrics` | Prometheus-compatible FE metrics (query latency, load jobs, transaction counts, JVM heap) |
| `http://localhost:8030/api/show_proc?path=/` | HTTP interface to `SHOW PROC` — browse the FE proc filesystem |
| `http://localhost:8030/api/show_proc?path=/statistic` | Cluster-wide DB / table / tablet / replica counts (same as `SHOW PROC '/statistic'`) |
| `http://localhost:8030/api/show_proc?path=/frontends` | FE topology |
| `http://localhost:8030/api/show_proc?path=/backends` | CN/BE list with alive status |
| `http://localhost:8030/api/show_proc?path=/compactions` | Active compaction jobs |

---

## StarRocks CN Diagnostic Endpoints

Both CNs expose the same paths; CN1 is on port **8040**, CN2 on **8041**.

### Health & Metrics

| Endpoint | Description |
|---|---|
| `http://localhost:8040/api/health` | Health check — returns `{"status":"OK"}` when CN is alive |
| `http://localhost:8040/metrics` | Prometheus-compatible CN metrics — updated every 10 s. Useful subsets: |
| `http://localhost:8040/metrics` + `grep mem` | All memory-related metric lines |
| `http://localhost:8040/metrics` + `grep column_pool` | Column pool memory |
| `http://localhost:8040/metrics` + `grep datacache` | Cache hit / miss counters |
| `http://localhost:8040/metrics` + `grep compaction` | Compaction throughput and queue depth |

### Memory Diagnostics

| Endpoint | Description |
|---|---|
| `http://localhost:8040/mem_tracker` | Memory tracker tree — shows all memory consumers with their current and peak usage |
| `http://localhost:8040/mem_tracker?type=query_pool&upper_level=3` | Query pool memory broken down 3 levels deep — useful for identifying per-query memory pressure |
| `http://localhost:8040/memz` | tcmalloc internals — allocated bytes, freelist sizes, virtual address space; helps diagnose allocator fragmentation |

```bash
# Fetch CN1 memory overview
curl -s http://localhost:8040/mem_tracker | head -80

# Fetch CN2 query pool detail
curl -s http://localhost:8041/mem_tracker?type=query_pool\&upper_level=3

# Watch memory metrics live
watch -n5 'curl -s http://localhost:8040/metrics | grep -E "^starrocks_be_.*mem"'
```

### Data Cache Diagnostics

| Endpoint | Description |
|---|---|
| `http://localhost:8040/api/datacache/stat` | Data cache metrics: `disk_quota_bytes`, `mem_quota_bytes`, hit rate, bytes read from cache vs. remote storage |
| `http://localhost:8041/api/datacache/stat` | Same for CN2 |

```bash
# Pretty-print cache stats for both CNs
curl -s http://localhost:8040/api/datacache/stat | python3 -m json.tool
curl -s http://localhost:8041/api/datacache/stat | python3 -m json.tool
```

Key fields returned by `/api/datacache/stat`:

| Field | Meaning |
|---|---|
| `disk_quota_bytes` | Configured disk cache limit (5 GB per CN in this stack) |
| `mem_quota_bytes` | Configured memory cache limit |
| `disk_used_bytes` | Bytes currently written to the cache volume |
| `hit_count` / `miss_count` | Cache hit and miss counters since CN start |
| `hit_bytes` / `miss_bytes` | Bytes served from cache vs. fetched from MinIO |

### Tablet & Compaction Diagnostics

| Endpoint | Description |
|---|---|
| `http://localhost:8040/tablets_json` | JSON list of all tablets hosted by CN1 with state, version, and rowset info |
| `http://localhost:8041/tablets_json` | Same for CN2 |
| `http://localhost:8040/api/compaction/show?tablet_id=<id>` | Compaction history and current status for a specific tablet |

---

## Redpanda Admin API

The Redpanda Admin API is exposed on port **9644**.

| Endpoint | Description |
|---|---|
| `http://localhost:9644/v1/cluster/health_overview` | Cluster health: leader, node count, under-replicated partitions |
| `http://localhost:9644/v1/brokers` | Broker list with node IDs |
| `http://localhost:9644/v1/topics` | All topics with partition and replication metadata |
| `http://localhost:9644/v1/topics/<topic>/partitions/<id>/replicas` | Replica detail for a specific partition |

```bash
# Quick health check
curl -s http://localhost:9644/v1/cluster/health_overview | python3 -m json.tool

# List topics
curl -s http://localhost:9644/v1/topics | python3 -m json.tool
```

---

## MinIO

| Endpoint | Description |
|---|---|
| `http://localhost:9001` | MinIO Console — bucket browser, object inspector, access key management |
| `http://localhost:9000/minio/health/live` | MinIO liveness probe (returns HTTP 200 when healthy) |
| `http://localhost:9000/minio/health/ready` | MinIO readiness probe |

StarRocks stores data at `starrocks/{db_id}/{table_id}/{partition_id}/{tablet_id}/`.
Browse via the console or:

```bash
# List top-level paths in the starrocks bucket
docker exec minio mc ls local/starrocks --recursive --summarize 2>/dev/null | tail -5
```

---

## Port Summary

| Port | Container | Protocol | Purpose |
|---|---|---|---|
| **8030** | starrocks-fe1 | HTTP | FE1 web UI + diagnostic API |
| **8031** | starrocks-fe2 | HTTP | FE2 web UI + diagnostic API |
| **9020** | starrocks-fe1 | RPC | FE internal (edit log, metadata sync) |
| **9021** | starrocks-fe2 | RPC | FE2 internal |
| **9030** | starrocks-fe1 | MySQL | SQL client entry point (FE1) |
| **9031** | starrocks-fe2 | MySQL | SQL client entry point (FE2) |
| **8040** | starrocks-cn1 | HTTP | CN1 diagnostic API |
| **8041** | starrocks-cn2 | HTTP | CN2 diagnostic API |
| **9050** | starrocks-cn1 | TCP | CN1 heartbeat |
| **9051** | starrocks-cn2 | TCP | CN2 heartbeat |
| **9060** | starrocks-cn1 | Thrift | CN1 thrift RPC |
| **9061** | starrocks-cn2 | Thrift | CN2 thrift RPC |
| **8080** | redpanda-console | HTTP | Redpanda Console web UI |
| **8082** | redpanda | HTTP | Pandaproxy REST API |
| **9092** | redpanda | Kafka | Kafka API (host access) |
| **29092** | redpanda | Kafka | Kafka API (inter-container) |
| **9644** | redpanda | HTTP | Redpanda Admin API |
| **9000** | minio | S3 | MinIO S3 API |
| **9001** | minio | HTTP | MinIO Console |
| **8978** | cloudbeaver | HTTP | CloudBeaver SQL IDE |

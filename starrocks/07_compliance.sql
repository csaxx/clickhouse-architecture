-- =============================================================================
-- 07_compliance.sql
-- Compliance operation templates: user-ID DELETE, physical compaction,
-- field-level UPDATE, and TTL monitoring.
--
-- Target: any FE node via MySQL client (port 9030)
--         Run during the nightly compliance batch window.
--
-- ClickHouse equivalent:
--   Compliance delete in ClickHouse requires two steps:
--     1. DELETE FROM t WHERE user_id = X  (marks rows as deleted; they remain
--        visible to queries until the next OPTIMIZE PARTITION FINAL)
--     2. OPTIMIZE TABLE PARTITION FINAL   (rewrites affected partitions to
--        physically remove the deleted rows from S3)
--   The ClickHouse path has a significant open question (Decision #11) about
--   whether the 24-hour SLA can be met given OPTIMIZE execution time at scale.
--
--   StarRocks PRIMARY KEY model improvement:
--     Step 1 is IMMEDIATE: DELETE FROM t WHERE user_id = X makes rows
--     invisible to all queries immediately after the statement completes.
--     No OPTIMIZE equivalent is needed for LOGICAL inaccessibility.
--     Step 2 (physical S3 byte removal) still requires compaction (ALTER TABLE COMPACT),
--     but the compliance gap (rows visible to queries) is zero from the moment
--     of DELETE — regardless of when compaction completes.
--
-- Time-based expiry (partition TTL):
--   Configured in 03_events_table.sql via partition_ttl and dynamic_partition.
--   No manual action is required. StarRocks drops expired partitions and their
--   S3 objects automatically. This section provides monitoring queries only.
--
-- Open Decision #11 (same as ClickHouse):
--   Whether the 24-hour SLA requires physical byte removal (compaction) or
--   logical inaccessibility (immediately satisfied by DELETE in StarRocks).
--   If logical inaccessibility is sufficient, compaction can run asynchronously
--   at off-peak hours with no compliance deadline.
-- =============================================================================


-- =============================================================================
-- SECTION 1: Staging table for nightly compliance batch
-- =============================================================================
-- Create once. Used by both DELETE (Section 2) and UPDATE (Section 3) operations.
-- Truncate and reload before each nightly batch run.

CREATE TABLE IF NOT EXISTS events_db.compliance_batch
(
    -- Batch metadata: which run produced this entry.
    batch_date      DATE            NOT NULL  COMMENT "Date of the nightly compliance batch",
    operation       VARCHAR(16)     NOT NULL  COMMENT "Operation type: DELETE or UPDATE",

    -- Target user
    user_id         BIGINT          NOT NULL  COMMENT "User ID to be deleted or updated",

    -- For UPDATE operations: the new field values (add columns as needed).
    -- Unused for DELETE operations.
    new_eviction_date DATE                    COMMENT "Replacement eviction_date for UPDATE operations"
)
ENGINE = OLAP
DUPLICATE KEY (batch_date, operation, user_id)
DISTRIBUTED BY HASH(user_id) BUCKETS 4
PROPERTIES
(
    "replication_num" = "1",
    "storage_volume" = "s3_volume",
    "datacache_enable" = "false"     -- staging table; not queried hot
);


-- =============================================================================
-- SECTION 2: User-ID logical DELETE (immediate logical inaccessibility)
-- =============================================================================

-- Pattern A: single-user delete (for ad-hoc or low-volume compliance requests).
--   Rows are invisible to all queries immediately after this statement.
--   No OPTIMIZE PARTITION equivalent needed for logical inaccessibility.
DELETE FROM events_db.events
WHERE user_id = 12345;  -- replace 12345 with actual user_id

-- Pattern B: batch delete from the staging table (for nightly compliance runs).
--   Step 1: load the nightly batch into the staging table (via STREAM LOAD or INSERT).
--   Step 2: execute once per nightly batch.
DELETE FROM events_db.events
WHERE user_id IN
(
    SELECT user_id
    FROM events_db.compliance_batch
    WHERE batch_date = current_date()
      AND operation = 'DELETE'
);

-- Step 3: truncate staging table after confirmed successful delete.
-- TRUNCATE TABLE events_db.compliance_batch;

-- Verify: deleted rows should return no results immediately after DELETE.
-- SELECT count(*) FROM events_db.events WHERE user_id = 12345;


-- =============================================================================
-- SECTION 3: Physical byte removal via compaction
-- Required only if Open Decision #11 determines that physical S3 byte removal
-- (not just logical inaccessibility) must occur within the 24-hour SLA.
-- =============================================================================

-- Compact a specific partition (preferred — targets only affected partitions).
-- Replace 'p20240115' with the actual partition name. Partition names follow
-- the dynamic_partition.prefix + date format (e.g., 'p20240115' for 2024-01-15).
-- Run after the DELETE in Section 2 to physically remove the deleted row bytes
-- from the affected partition's S3 objects.
ALTER TABLE events_db.events COMPACT PARTITION p20240115;

-- Compact all partitions that may contain the deleted user_id rows.
-- Use when the user_id appears across many partitions (e.g., long retention window).
-- Warning: compacting all partitions is I/O-intensive and contends with query
-- and Routine Load ingest workloads on BE nodes.
-- Schedule during off-peak hours or apply Resource Group limits (see note below).
-- ALTER TABLE events_db.events COMPACT;

-- Compact a date range of partitions (more targeted than full-table compact).
-- Equivalent to running OPTIMIZE TABLE PARTITION FINAL per affected partition
-- in ClickHouse, but StarRocks compaction is distributed across tablets on
-- all BEs simultaneously — generally faster and more parallelizable.
-- ALTER TABLE events_db.events COMPACT PARTITION START ("p20240101") END ("p20240131");

-- Check compaction progress:
-- SHOW PROC '/compactions';

-- Monitor BE compaction queue:
-- SELECT be_id, type, state, candidate_tablets, running_tablets
-- FROM information_schema.be_compactions;

-- Resource Group: if compaction must run concurrently with query workloads,
-- use a Resource Group to cap compaction I/O impact.
-- CREATE RESOURCE GROUP IF NOT EXISTS compaction_rg
-- PROPERTIES ("cpu_core_limit" = "2", "mem_limit" = "4294967296");


-- =============================================================================
-- SECTION 4: Nightly field-level UPDATE
-- Efficiently supported on PRIMARY KEY model — no mutation rewrite overhead.
-- =============================================================================

-- Pattern A: single-condition UPDATE (ad-hoc or low volume).
UPDATE events_db.events
SET eviction_date = current_date()  -- mark rows for immediate TTL expiry
WHERE user_id = 12345;  -- replace with actual user_id and condition

-- Pattern B: batch UPDATE from staging table (for nightly compliance runs).
--   Step 1: load update batch into compliance_batch with operation = 'UPDATE'.
--   Step 2: execute once per nightly batch.
UPDATE events_db.events e
    JOIN events_db.compliance_batch b ON e.user_id = b.user_id
SET e.eviction_date = b.new_eviction_date
WHERE b.batch_date = current_date()
  AND b.operation = 'UPDATE'
  AND b.new_eviction_date IS NOT NULL;

-- Additional field-level update examples:
-- UPDATE events_db.events SET consent_status = 'withdrawn' WHERE user_id = 12345;
-- UPDATE events_db.events SET user_id = NULL WHERE user_id = 12345;  -- pseudonymization


-- =============================================================================
-- SECTION 5: Time-based expiry monitoring
-- Partition TTL is fully automatic (configured in 03_events_table.sql).
-- These queries verify correct TTL behavior.
-- =============================================================================

-- List all current partitions with their date ranges.
-- Expected: no partitions with PartitionName older than partition_ttl (90 days).
SHOW PARTITIONS FROM events_db.events ORDER BY PartitionName;

-- Alternatively via information_schema:
SELECT
    PARTITION_NAME,
    PARTITION_DESCRIPTION,
    round(DATA_LENGTH / 1073741824, 2)  AS data_gb,
    CREATE_TIME
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA = 'events_db'
  AND TABLE_NAME   = 'events'
ORDER BY PARTITION_NAME;

-- Verify that dynamic partitions are being created for upcoming dates.
-- Expected: partitions exist for today + dynamic_partition.end days.
SELECT
    PARTITION_NAME,
    PARTITION_DESCRIPTION
FROM information_schema.PARTITIONS
WHERE TABLE_SCHEMA = 'events_db'
  AND TABLE_NAME   = 'events'
  AND PARTITION_NAME >= concat('p', date_format(current_date(), '%Y%m%d'))
ORDER BY PARTITION_NAME;

-- Dynamic partition management configuration inspection:
SHOW DYNAMIC PARTITION TABLES FROM events_db;

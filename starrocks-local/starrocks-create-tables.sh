#!/usr/bin/env bash
# starrocks-create-tables.sh — Create databases, tables, and Routine Load jobs
# in StarRocks, then verify row counts after the initial ingest batches commit.
#
# Covers three datasets:
#   • crashdata    — NYC vehicle collision records (CSV via crashdata-topic)
#   • weatherdata  — NOAA hourly weather observations (CSV via weatherdata-topic)
#   • site_clicks  — synthetic click-stream events (JSON via site-clicks)
#
# Prerequisites:
#   1. ./docker-compose-up.sh          — stack running and healthy
#   2. ./redpanda-create-topics.sh     — topics exist
#   3. ./load-data-crash.sh            — crash CSV in crashdata-topic
#   4. ./load-data-weather.sh          — weather CSV in weatherdata-topic
#   (site_clicks data is produced separately via gen.py)
#
# Usage:
#   chmod +x starrocks-create-tables.sh
#   ./starrocks-create-tables.sh
#
# Requires: docker, mysql (or mariadb) CLI client.

set -euo pipefail

SR_HOST="127.0.0.1"
SR_PORT="9030"
SR_USER="root"

# ---------------------------------------------------------------------------
# Resolve SQL client (mysql preferred; fall back to mariadb)
# ---------------------------------------------------------------------------
if command -v mysql &>/dev/null; then
  SR_CLIENT="mysql"
elif command -v mariadb &>/dev/null; then
  SR_CLIENT="mariadb"
else
  echo "ERROR: neither 'mysql' nor 'mariadb' CLI found. Install mysql-client and retry."
  exit 1
fi

sr_sql() {
  "$SR_CLIENT" -h "$SR_HOST" -P "$SR_PORT" -u "$SR_USER" --connect-timeout=10 "$@"
}

# ---------------------------------------------------------------------------
# 1. Create databases
# ---------------------------------------------------------------------------
echo "=== Step 1: Creating databases ==="

sr_sql <<'SQL'
CREATE DATABASE IF NOT EXISTS quickstart;
SQL

echo "  databases created."

# ---------------------------------------------------------------------------
# 2. Create tables
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 2: Creating tables ==="

# ── quickstart: crashdata + weatherdata ─────────────────────────────────────
sr_sql quickstart <<'SQL'
CREATE TABLE IF NOT EXISTS crashdata (
    COLLISION_ID                  INT,
    CRASH_DATE                    DATETIME,
    BOROUGH                       STRING,
    ZIP_CODE                      STRING,
    LATITUDE                      INT,
    LONGITUDE                     INT,
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

CREATE TABLE IF NOT EXISTS weatherdata (
    WEATHER_DATE                DATETIME,
    NAME                        STRING,
    HourlyDewPointTemperature   STRING,
    HourlyDryBulbTemperature    STRING,
    HourlyPrecipitation         STRING,
    HourlyPresentWeatherType    STRING,
    HourlyPressureChange        STRING,
    HourlyPressureTendency      STRING,
    HourlyRelativeHumidity      STRING,
    HourlySkyConditions         STRING,
    HourlyVisibility            STRING,
    HourlyWetBulbTemperature    STRING,
    HourlyWindDirection         STRING,
    HourlyWindGustSpeed         STRING,
    HourlyWindSpeed             STRING
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

-- site_clicks: DUPLICATE KEY (no dedup); one bucket matches the single topic
-- partition. Routine Load uses JSON format.
CREATE TABLE IF NOT EXISTS site_clicks (
    uid   BIGINT NOT NULL COMMENT "user ID",
    site  STRING NOT NULL COMMENT "visited URL",
    vtime BIGINT NOT NULL COMMENT "visit timestamp (unix seconds)"
)
ENGINE = OLAP
DUPLICATE KEY(uid)
DISTRIBUTED BY HASH(uid) BUCKETS 1
PROPERTIES (
    "replication_num" = "1",
    "storage_volume"  = "minio_vol"
);
SQL

echo "  tables created."

# ---------------------------------------------------------------------------
# 3. Create Routine Load jobs
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 3: Creating Routine Load jobs ==="

# ── crash data (CSV, 29 positional columns → 14 stored) ─────────────────────
sr_sql quickstart <<'SQL'
CREATE ROUTINE LOAD quickstart.crash_load ON crashdata
COLUMNS TERMINATED BY ",",
COLUMNS (
    tmp_CRASH_DATE, tmp_CRASH_TIME,
    BOROUGH, ZIP_CODE, LATITUDE, LONGITUDE, LOCATION,
    ON_STREET_NAME, CROSS_STREET_NAME, OFF_STREET_NAME,
    col_persons_injured, col_persons_killed,
    col_ped_injured, col_ped_killed,
    col_cyc_injured, col_cyc_killed,
    col_mot_injured, col_mot_killed,
    CONTRIBUTING_FACTOR_VEHICLE_1, CONTRIBUTING_FACTOR_VEHICLE_2,
    col_cf3, col_cf4, col_cf5,
    COLLISION_ID,
    VEHICLE_TYPE_CODE_1, VEHICLE_TYPE_CODE_2,
    col_vt3, col_vt4, col_vt5,
    CRASH_DATE = str_to_date(concat_ws(' ', tmp_CRASH_DATE, tmp_CRASH_TIME), '%m/%d/%Y %H:%i')
)
PROPERTIES (
    "desired_concurrent_number" = "3",
    "max_batch_rows"            = "500000",
    "max_batch_interval"        = "30",
    "max_error_number"          = "500",
    "format"                    = "CSV",
    "enclose"                   = "\"",
    "strict_mode"               = "false"
)
FROM KAFKA (
    "kafka_broker_list" = "redpanda:29092",
    "kafka_topic"       = "crashdata-topic",
    "kafka_partitions"  = "0,1,2",
    "kafka_offsets"     = "OFFSET_BEGINNING,OFFSET_BEGINNING,OFFSET_BEGINNING"
);
SQL

# ── weather data (CSV, 123 positional columns → 15 stored) ──────────────────
sr_sql quickstart <<'SQL'
CREATE ROUTINE LOAD quickstart.weather_load ON weatherdata
COLUMNS TERMINATED BY ",",
COLUMNS (
    col_station, obs_date, col_latitude, col_longitude, col_elevation,
    NAME, col_report_type, col_source,
    col_alt_setting, HourlyDewPointTemperature, HourlyDryBulbTemperature,
    HourlyPrecipitation, HourlyPresentWeatherType, HourlyPressureChange,
    HourlyPressureTendency, HourlyRelativeHumidity, HourlySkyConditions,
    col_sea_level_pressure, col_station_pressure,
    HourlyVisibility, HourlyWetBulbTemperature, HourlyWindDirection,
    HourlyWindGustSpeed, HourlyWindSpeed,
    col_sunrise, col_sunset,
    col_daily_avg_dewpoint, col_daily_avg_drybulb,
    col_daily_avg_rh, col_daily_avg_sealevel,
    col_daily_avg_station, col_daily_avg_wetbulb,
    col_daily_avg_wind, col_daily_cooling,
    col_daily_depart_avg, col_daily_heating,
    col_daily_max_drybulb, col_daily_min_drybulb,
    col_daily_peak_wind_dir, col_daily_peak_wind_spd,
    col_daily_precip, col_daily_snow_depth, col_daily_snowfall,
    col_daily_sust_wind_dir, col_daily_sust_wind_spd, col_daily_weather,
    col_monthly_avg_rh, col_monthly_days_gt001,
    col_monthly_days_gt010, col_monthly_days_gt32,
    col_monthly_days_gt90, col_monthly_days_lt0, col_monthly_days_lt32,
    col_monthly_depart_avg, col_monthly_depart_cool,
    col_monthly_depart_heat, col_monthly_depart_max, col_monthly_depart_min,
    col_monthly_depart_precip, col_monthly_dewpoint,
    col_monthly_greatest_precip, col_monthly_greatest_precip_date,
    col_monthly_greatest_snow_depth, col_monthly_greatest_snow_depth_date,
    col_monthly_greatest_snowfall, col_monthly_greatest_snowfall_date,
    col_monthly_max_sealevel, col_monthly_max_sealevel_date,
    col_monthly_max_sealevel_time, col_monthly_max_drybulb,
    col_monthly_mean, col_monthly_min_sealevel,
    col_monthly_min_sealevel_date, col_monthly_min_sealevel_time,
    col_monthly_min_drybulb, col_monthly_sealevel, col_monthly_station,
    col_monthly_total_liquid, col_monthly_total_snowfall, col_monthly_wetbulb,
    col_awnd, col_cdsd, col_cldd, col_dsnw, col_hdsd, col_htdd,
    col_normals_cool, col_normals_heat,
    col_short_end_005, col_short_end_010, col_short_end_015,
    col_short_end_020, col_short_end_030, col_short_end_045,
    col_short_end_060, col_short_end_080, col_short_end_100,
    col_short_end_120, col_short_end_150, col_short_end_180,
    col_short_val_005, col_short_val_010, col_short_val_015,
    col_short_val_020, col_short_val_030, col_short_val_045,
    col_short_val_060, col_short_val_080, col_short_val_100,
    col_short_val_120, col_short_val_150, col_short_val_180,
    col_rem, col_backup_dir, col_backup_dist, col_backup_dist_unit,
    col_backup_elements, col_backup_elevation, col_backup_equipment,
    col_backup_lat, col_backup_lon, col_backup_name, col_wind_equip_change,
    WEATHER_DATE = obs_date
)
PROPERTIES (
    "desired_concurrent_number" = "3",
    "max_batch_rows"            = "200000",
    "max_batch_interval"        = "30",
    "max_error_number"          = "500",
    "format"                    = "CSV",
    "enclose"                   = "\"",
    "strict_mode"               = "false"
)
FROM KAFKA (
    "kafka_broker_list" = "redpanda:29092",
    "kafka_topic"       = "weatherdata-topic",
    "kafka_partitions"  = "0,1,2",
    "kafka_offsets"     = "OFFSET_BEGINNING,OFFSET_BEGINNING,OFFSET_BEGINNING"
);
SQL

# ── site_clicks (JSON, single partition, streaming from gen.py) ──────────────
sr_sql quickstart <<'SQL'
CREATE ROUTINE LOAD quickstart.clicks ON site_clicks
PROPERTIES (
    "format"    = "JSON",
    "jsonpaths" = "[\"$.uid\",\"$.site\",\"$.vtime\"]"
)
FROM KAFKA (
    "kafka_broker_list" = "redpanda:29092",
    "kafka_topic"       = "site-clicks",
    "kafka_partitions"  = "0",
    "kafka_offsets"     = "OFFSET_BEGINNING"
);
SQL

echo "  Routine Load jobs created."
echo "  Check status: SHOW ALL ROUTINE LOAD\\G"

# ---------------------------------------------------------------------------
# 4. Wait for crash + weather batches, then verify row counts
#    (site_clicks starts empty — populated later by gen.py)
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 4: Waiting 60s for Routine Load batches to commit ==="
sleep 60

echo ""
echo "=== Step 5: Verifying row counts ==="
sr_sql quickstart -e "
SELECT 'crashdata'   AS table_name, COUNT(*) AS row_count FROM crashdata
UNION ALL
SELECT 'weatherdata' AS table_name, COUNT(*) AS row_count FROM weatherdata
UNION ALL
SELECT 'site_clicks' AS table_name, COUNT(*) AS row_count FROM site_clicks;
"

echo ""
echo "=== StarRocks setup complete ==="
echo "  Connect:     mysql -h 127.0.0.1 -P 9030 -u root quickstart"
echo "  CloudBeaver: http://localhost:8978  (cbadmin / cbadmin)"
echo "  MinIO:       http://localhost:9001  (minioadmin / minioadmin)"
echo ""
echo "  To populate site_clicks, run gen.py against localhost:9092 topic site-clicks"

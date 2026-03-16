#!/usr/bin/env bash
# load-quickstart.sh — Download NYC crash + weather datasets and load them into
# StarRocks via Redpanda (Routine Load), persisted on MinIO.
#
# Run docker-compose-up.sh first to ensure the stack is ready.
#
# Usage:
#   chmod +x load-quickstart.sh
#   ./load-quickstart.sh
#
# Requires: docker, curl, mysql (or mariadb) CLI client.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"

CRASH_URL="https://raw.githubusercontent.com/StarRocks/demo/master/documentation-samples/quickstart/datasets/NYPD_Crash_Data.csv"
WEATHER_URL="https://raw.githubusercontent.com/StarRocks/demo/master/documentation-samples/quickstart/datasets/72505394728.csv"
CRASH_FILE="$DATA_DIR/NYPD_Crash_Data.csv"
WEATHER_FILE="$DATA_DIR/72505394728.csv"

CRASH_TOPIC="crashdata-topic"
WEATHER_TOPIC="weatherdata-topic"

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
# 1. Download data files (skip if already present)
# ---------------------------------------------------------------------------
echo "=== Step 1: Downloading datasets ==="
mkdir -p "$DATA_DIR"

if [ -f "$CRASH_FILE" ]; then
  echo "  crash data already present ($CRASH_FILE)"
else
  echo "  downloading NYC crash data (~96 MB)..."
  curl -fL --progress-bar -o "$CRASH_FILE" "$CRASH_URL"
  echo "  done."
fi

if [ -f "$WEATHER_FILE" ]; then
  echo "  weather data already present ($WEATHER_FILE)"
else
  echo "  downloading NOAA weather data..."
  curl -fL --progress-bar -o "$WEATHER_FILE" "$WEATHER_URL"
  echo "  done."
fi

# ---------------------------------------------------------------------------
# 2. Create Redpanda topics
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 2: Creating Redpanda topics ==="
docker exec redpanda rpk topic create "$CRASH_TOPIC"   --partitions 3 --replicas 1 2>&1 | grep -v "already exists" || true
docker exec redpanda rpk topic create "$WEATHER_TOPIC" --partitions 3 --replicas 1 2>&1 | grep -v "already exists" || true
echo "  topics ready: $CRASH_TOPIC, $WEATHER_TOPIC"

# ---------------------------------------------------------------------------
# 3. Create quickstart database and tables
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 3: Creating quickstart database and tables ==="

sr_sql <<'SQL'
CREATE DATABASE IF NOT EXISTS quickstart;
SQL

sr_sql quickstart <<'SQL'
CREATE TABLE IF NOT EXISTS crashdata (
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
    COLLISION_ID                  INT,
    VEHICLE_TYPE_CODE_1           STRING,
    VEHICLE_TYPE_CODE_2           STRING
)
ENGINE = OLAP
DUPLICATE KEY(CRASH_DATE)
DISTRIBUTED BY HASH(COLLISION_ID) BUCKETS 3
PROPERTIES (
    "replication_num" = "1",
    "storage_volume"  = "minio_vol"
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
DUPLICATE KEY(WEATHER_DATE)
DISTRIBUTED BY HASH(WEATHER_DATE) BUCKETS 3
PROPERTIES (
    "replication_num" = "1",
    "storage_volume"  = "minio_vol"
);
SQL

echo "  tables created."

# ---------------------------------------------------------------------------
# 4. Create Routine Load jobs
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 4: Creating Routine Load jobs ==="

# Crash data: 29 CSV columns (positional), CRASH_DATE computed from first two.
# Columns skipped (persons/cyclists/motorists injured/killed, CF 3-5, VT 3-5)
# are mapped to col_* temp vars that are discarded.
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

# Weather data: 123 CSV columns, 15 stored. All non-table columns are mapped to
# col_* temp vars. DATE is a SQL reserved word so renamed to WEATHER_DATE in the
# table; obs_date is used as the positional temp var, then assigned.
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

echo "  Routine Load jobs created."
echo "  Check status: SHOW ROUTINE LOAD\\G"

# ---------------------------------------------------------------------------
# 5. Produce CSV data → Redpanda topics (skip header row with tail -n +2)
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 5: Producing crash data → $CRASH_TOPIC ==="
echo "  (streaming ~423k rows from $CRASH_FILE — may take a minute)"
tail -n +2 "$CRASH_FILE" \
  | docker exec -i redpanda rpk topic produce "$CRASH_TOPIC" --compression snappy
echo "  crash data produced."

echo ""
echo "=== Step 6: Producing weather data → $WEATHER_TOPIC ==="
tail -n +2 "$WEATHER_FILE" \
  | docker exec -i redpanda rpk topic produce "$WEATHER_TOPIC" --compression snappy
echo "  weather data produced."

# ---------------------------------------------------------------------------
# 6. Wait for Routine Load to commit batches, then verify row counts
# ---------------------------------------------------------------------------
echo ""
echo "=== Step 7: Waiting 60s for Routine Load batches to commit ==="
sleep 60

echo ""
echo "=== Step 8: Verifying row counts ==="
sr_sql quickstart -e "
SELECT 'crashdata'   AS table_name, COUNT(*) AS rows FROM crashdata
UNION ALL
SELECT 'weatherdata' AS table_name, COUNT(*) AS rows FROM weatherdata;
"

echo ""
echo "=== Load complete ==="
echo "  Connect:     mysql -h 127.0.0.1 -P 9030 -u root quickstart"
echo "  CloudBeaver: http://localhost:8978  (cbadmin / cbadmin)"
echo "  MinIO:       http://localhost:9001  (minioadmin / minioadmin)"

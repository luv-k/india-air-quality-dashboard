/* =====================================================================
   INDIA AIR QUALITY ANALYSIS  |  MySQL 8.0+
   Source : data.gov.in (real-time AQI, snapshot of 4 Nov 2026)
   Flow   : raw table -> clean table -> checks -> analysis -> views (Power BI)
   Run the sections in order, top to bottom.
   ===================================================================== */


/* ---------------------------------------------------------------------
   SECTION 1: DATABASE AND RAW TABLE
   Everything is VARCHAR in the raw table because the file contains 'NA'
   in numeric columns. Raw data is never edited; it is the backup.
   --------------------------------------------------------------------- */
CREATE DATABASE IF NOT EXISTS air_quality;
USE air_quality;

CREATE TABLE IF NOT EXISTS aqi_raw (
    country        VARCHAR(100),   -- always 'India' in this dataset, not used later
    state          VARCHAR(100),
    city           VARCHAR(100),
    station        VARCHAR(255),
    last_update    VARCHAR(30),
    latitude       VARCHAR(20),
    longitude      VARCHAR(20),
    pollutant_id   VARCHAR(20),
    pollutant_min  VARCHAR(20),
    pollutant_max  VARCHAR(20),
    pollutant_avg  VARCHAR(20)
);

/* Load the CSV with MySQL Workbench:
   Schemas -> air_quality -> Tables -> right-click aqi_raw ->
   Table Data Import Wizard -> choose CSV -> "Use existing table".
   (If you already dropped the country column from aqi_raw, that is fine:
   the clean-table INSERT below lists columns by name, so it still works.) */

-- Check the load (expected: 3913 rows)
SELECT COUNT(*) AS raw_rows FROM aqi_raw;
SELECT * FROM aqi_raw LIMIT 5;

-- Country should only ever be India (skip if you dropped the column)
-- SELECT DISTINCT country FROM aqi_raw;


/* ---------------------------------------------------------------------
   SECTION 2: CLEAN TABLE
   Proper data types: numbers, real dates, and 'NA' turned into NULL.
   load_date tags each snapshot so daily loads can be appended later.
   is_missing flags readings that were 'NA'.
   --------------------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS aqi_clean (
    state          VARCHAR(100),
    city           VARCHAR(100),
    station        VARCHAR(255),
    last_update    DATETIME,
    latitude       DECIMAL(10,6),
    longitude      DECIMAL(10,6),
    pollutant_id   VARCHAR(20),
    pollutant_min  DECIMAL(8,2),
    pollutant_max  DECIMAL(8,2),
    pollutant_avg  DECIMAL(8,2),
    load_date      DATE,
    is_missing     TINYINT
);

TRUNCATE TABLE aqi_clean;   -- safe re-run: avoids duplicate rows

INSERT INTO aqi_clean
    (state, city, station, last_update, latitude, longitude,
     pollutant_id, pollutant_min, pollutant_max, pollutant_avg,
     load_date, is_missing)
SELECT
    TRIM(state),
    TRIM(city),
    TRIM(station),
    STR_TO_DATE(TRIM(last_update), '%d-%m-%Y %H:%i:%s'),
    CAST(NULLIF(TRIM(latitude),  'NA') AS DECIMAL(10,6)),
    CAST(NULLIF(TRIM(longitude), 'NA') AS DECIMAL(10,6)),
    TRIM(pollutant_id),
    CAST(NULLIF(TRIM(pollutant_min), 'NA') AS DECIMAL(8,2)),
    CAST(NULLIF(TRIM(pollutant_max), 'NA') AS DECIMAL(8,2)),
    CAST(NULLIF(TRIM(pollutant_avg), 'NA') AS DECIMAL(8,2)),
    '2026-11-04',                         -- snapshot date
    TRIM(pollutant_avg) = 'NA'
FROM aqi_raw;


/* ---------------------------------------------------------------------
   SECTION 3: SANITY CHECKS
   Expected: total_rows = 3913, missing_rows = 326, bad_dates = 0
   --------------------------------------------------------------------- */
SELECT COUNT(*)                  AS total_rows,
       SUM(is_missing)           AS missing_rows,
       SUM(last_update IS NULL)  AS bad_dates
FROM aqi_clean;

-- Distinct stations that have at least one NA reading (expected: 144)
SELECT COUNT(DISTINCT station) AS stations_with_na
FROM aqi_clean
WHERE is_missing = 1;

-- Stations with no valid reading at all (expected: 0)
SELECT COUNT(*) AS stations_with_no_data
FROM (
    SELECT station
    FROM aqi_clean
    GROUP BY station
    HAVING SUM(pollutant_avg IS NOT NULL) = 0
) t;

-- Coordinates inside India's bounding box (expected: all 0)
SELECT COUNT(*)                                        AS total,
       SUM(latitude IS NULL OR longitude IS NULL)      AS no_coords,
       SUM(latitude  NOT BETWEEN 6  AND 38)            AS bad_lat,
       SUM(longitude NOT BETWEEN 68 AND 98)            AS bad_long
FROM aqi_clean;


/* ---------------------------------------------------------------------
   SECTION 4: DATA QUALITY ANALYSIS (missing readings)
   --------------------------------------------------------------------- */
-- Missing readings by pollutant
SELECT pollutant_id,
       COUNT(*)        AS total_rows,
       SUM(is_missing) AS na_rows
FROM aqi_clean
GROUP BY pollutant_id
ORDER BY na_rows DESC;

-- Missing readings by state
SELECT state, COUNT(*) AS missing_count
FROM aqi_clean
WHERE is_missing = 1
GROUP BY state
ORDER BY missing_count DESC;

-- NA per column (do min, max and avg go missing together?)
SELECT SUM(pollutant_min IS NULL) AS min_na,
       SUM(pollutant_max IS NULL) AS max_na,
       SUM(pollutant_avg IS NULL) AS avg_na
FROM aqi_clean;


/* ---------------------------------------------------------------------
   SECTION 5: ANALYSIS QUERIES
   --------------------------------------------------------------------- */

-- 5.1 Most polluted cities by PM2.5 (all cities; includes 1-station cities)
SELECT city, state,
       ROUND(AVG(pollutant_avg), 1) AS avg_pm25,
       COUNT(DISTINCT station)      AS stations
FROM aqi_clean
WHERE pollutant_id = 'PM2.5'
  AND pollutant_avg IS NOT NULL
GROUP BY city, state
ORDER BY avg_pm25 DESC
LIMIT 10;

-- 5.2 Same, but only cities with 3+ stations (more reliable)
--     WHERE filters rows before grouping; HAVING filters groups after.
SELECT city, state,
       ROUND(AVG(pollutant_avg), 1) AS avg_pm25,
       COUNT(DISTINCT station)      AS stations
FROM aqi_clean
WHERE pollutant_id = 'PM2.5'
  AND pollutant_avg IS NOT NULL
GROUP BY city, state
HAVING COUNT(DISTINCT station) >= 3
ORDER BY avg_pm25 DESC
LIMIT 10;

-- 5.3 Readings per pollutant (compare within a pollutant, not across:
--     units differ, e.g. CO is usually mg/m3 and the rest ug/m3)
SELECT pollutant_id,
       COUNT(*)                     AS readings,
       ROUND(AVG(pollutant_avg), 1) AS avg_value,
       ROUND(MAX(pollutant_max), 1) AS highest_seen
FROM aqi_clean
WHERE pollutant_avg IS NOT NULL
GROUP BY pollutant_id
ORDER BY readings DESC;

-- 5.4 PM2.5 pollution categories (CASE WHEN)
--     Simplified learning bands, NOT the official CPCB AQI table.
SELECT
    CASE
        WHEN pollutant_avg <= 60  THEN '1. Within limit'
        WHEN pollutant_avg <= 120 THEN '2. Moderate'
        WHEN pollutant_avg <= 250 THEN '3. Poor'
        ELSE                           '4. Severe'
    END AS category,
    COUNT(*) AS stations
FROM aqi_clean
WHERE pollutant_id = 'PM2.5'
  AND pollutant_avg IS NOT NULL
GROUP BY category
ORDER BY category;
-- Result: 155 / 136 / 126 / 101

-- 5.5 State ranking with a window function (RANK)
SELECT state,
       ROUND(AVG(pollutant_avg), 1) AS avg_pm25,
       COUNT(DISTINCT station)      AS stations,
       RANK() OVER (ORDER BY AVG(pollutant_avg) DESC) AS state_rank
FROM aqi_clean
WHERE pollutant_id = 'PM2.5'
  AND pollutant_avg IS NOT NULL
GROUP BY state
HAVING COUNT(DISTINCT station) >= 3
ORDER BY state_rank;

-- 5.6 Delhi stations (map data)
SELECT station, latitude, longitude, pollutant_avg AS pm25
FROM aqi_clean
WHERE state = 'Delhi'
  AND pollutant_id = 'PM2.5'
  AND pollutant_avg IS NOT NULL
ORDER BY pm25 DESC;

-- 5.7 Delhi by monitoring agency (extract text from the station name)
SELECT TRIM(SUBSTRING_INDEX(station, '-', -1)) AS agency,
       COUNT(*)                                AS stations,
       ROUND(AVG(pollutant_avg), 1)            AS avg_pm25
FROM aqi_clean
WHERE state = 'Delhi'
  AND pollutant_id = 'PM2.5'
  AND pollutant_avg IS NOT NULL
GROUP BY agency
ORDER BY avg_pm25 DESC;


/* ---------------------------------------------------------------------
   SECTION 6: VIEWS FOR POWER BI
   A view is a saved query that behaves like a table.
   CREATE OR REPLACE lets you re-run this section safely.
   --------------------------------------------------------------------- */

-- Top cities (3+ stations)
CREATE OR REPLACE VIEW v_top_cities AS
SELECT city, state,
       ROUND(AVG(pollutant_avg), 1) AS avg_pm25,
       COUNT(DISTINCT station)      AS stations
FROM aqi_clean
WHERE pollutant_id = 'PM2.5' AND pollutant_avg IS NOT NULL
GROUP BY city, state
HAVING COUNT(DISTINCT station) >= 3;

-- State ranking
CREATE OR REPLACE VIEW v_state_rank AS
SELECT state,
       ROUND(AVG(pollutant_avg), 1) AS avg_pm25,
       COUNT(DISTINCT station)      AS stations,
       RANK() OVER (ORDER BY AVG(pollutant_avg) DESC) AS state_rank
FROM aqi_clean
WHERE pollutant_id = 'PM2.5' AND pollutant_avg IS NOT NULL
GROUP BY state
HAVING COUNT(DISTINCT station) >= 3;

-- Station-level PM2.5 (cards, city chart, map)
CREATE OR REPLACE VIEW v_station_map AS
SELECT state, city, station, latitude, longitude,
       pollutant_avg AS pm25
FROM aqi_clean
WHERE pollutant_id = 'PM2.5' AND pollutant_avg IS NOT NULL;

-- One row per station with its category (donut chart)
CREATE OR REPLACE VIEW v_pm25_category AS
SELECT state, city, station,
       pollutant_avg AS pm25,
       CASE
           WHEN pollutant_avg <= 60  THEN '1. Within limit'
           WHEN pollutant_avg <= 120 THEN '2. Moderate'
           WHEN pollutant_avg <= 250 THEN '3. Poor'
           ELSE                           '4. Severe'
       END AS category
FROM aqi_clean
WHERE pollutant_id = 'PM2.5' AND pollutant_avg IS NOT NULL;

-- Dimension table: one row per state, used by the slicer so one
-- filter drives every visual (Power BI: v_states -> other tables, one-to-many)
CREATE OR REPLACE VIEW v_states AS
SELECT DISTINCT state
FROM aqi_clean;

-- Optional: all pollutants, for a future pollutant slicer
CREATE OR REPLACE VIEW v_pollutants AS
SELECT state, city, station, pollutant_id,
       pollutant_avg AS value
FROM aqi_clean
WHERE pollutant_avg IS NOT NULL;

-- List all views
SHOW FULL TABLES IN air_quality WHERE Table_type = 'VIEW';


/* ---------------------------------------------------------------------
   SECTION 7 (OPTIONAL): APPENDING A NEW DAY'S SNAPSHOT
   1. Empty the raw table and import the new CSV into aqi_raw.
   2. Run the INSERT below WITHOUT truncating aqi_clean, and change
      the date to the new snapshot date.
   Note: the STR_TO_DATE format must still match the file.
   --------------------------------------------------------------------- */
-- TRUNCATE TABLE aqi_raw;
-- (import the new CSV here)
-- INSERT INTO aqi_clean
--     (state, city, station, last_update, latitude, longitude,
--      pollutant_id, pollutant_min, pollutant_max, pollutant_avg,
--      load_date, is_missing)
-- SELECT
--     TRIM(state), TRIM(city), TRIM(station),
--     STR_TO_DATE(TRIM(last_update), '%d-%m-%Y %H:%i:%s'),
--     CAST(NULLIF(TRIM(latitude),  'NA') AS DECIMAL(10,6)),
--     CAST(NULLIF(TRIM(longitude), 'NA') AS DECIMAL(10,6)),
--     TRIM(pollutant_id),
--     CAST(NULLIF(TRIM(pollutant_min), 'NA') AS DECIMAL(8,2)),
--     CAST(NULLIF(TRIM(pollutant_max), 'NA') AS DECIMAL(8,2)),
--     CAST(NULLIF(TRIM(pollutant_avg), 'NA') AS DECIMAL(8,2)),
--     '2026-11-05',                      -- NEW snapshot date
--     TRIM(pollutant_avg) = 'NA'
-- FROM aqi_raw;

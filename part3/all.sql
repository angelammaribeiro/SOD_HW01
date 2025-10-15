
-- =========================================================
-- Part 2.2 — Map-matching onto graph-based road network
-- Rebuild process preserving DriveNo and optimizing with buffers
-- Author: [Your Name]
-- =========================================================

-- ---------------------------------------------------------
-- VERSION 2: Simple but efficient buffer-assisted map-matching
-- ---------------------------------------------------------
BEGIN;

-- [Sanity checks] Uncomment if needed
-- SELECT ST_SRID(geom) FROM taxi_data_subset LIMIT 1;  -- expect 4326
-- SELECT ST_SRID(geom) FROM rome_edges LIMIT 1;        -- expect 4326

-- Step 1: Ensure both layers are spatially indexed (GiST)
-- These indexes accelerate both KNN (<->) and spatial predicates (ST_Intersects, ST_DWithin).
CREATE INDEX IF NOT EXISTS idx_taxi_geom   ON taxi_data_subset USING gist (geom);
CREATE INDEX IF NOT EXISTS idx_edges_geom  ON rome_edges        USING gist (geom);
ANALYZE taxi_data_subset;
ANALYZE rome_edges;

-- Step 2: Build a ~50 m buffer around each edge for fast pre-filtering
--   * ST_Buffer must be run in a metric CRS (EPSG:32633, UTM zone for Rome).
--   * Then transform back to EPSG:4326 for consistency with taxi_data_subset.
--   * Column is GENERATED STORED so it is maintained automatically.
ALTER TABLE rome_edges DROP COLUMN IF EXISTS edge_buf;
ALTER TABLE rome_edges
ADD COLUMN edge_buf geometry(Polygon, 4326)
GENERATED ALWAYS AS (
  ST_Transform(ST_Buffer(ST_Transform(geom, 32633), 50), 4326)
) STORED;

-- Index the new buffer column so ST_Intersects can use R-tree acceleration
CREATE INDEX IF NOT EXISTS idx_edges_edgebuf ON rome_edges USING gist (edge_buf);
ANALYZE rome_edges;

-- Step 3: Perform the actual map-matching
-- Strategy:
--   * For each taxi point:
--     - Prefer edges whose buffer contains the point (ST_Intersects).
--     - Among those, pick the closest using <-> KNN.
--     - If no buffer contains the point, fall back to the nearest edge globally.
DROP TABLE IF EXISTS taxi_matched_graph_v2;

CREATE TABLE taxi_matched_graph_v2 AS
SELECT
  t.id                              AS point_id,       -- GPS record id
  t."DriveNo"                       AS drive_no,       -- vehicle identifier
  t.date_time,                                         -- timestamp
  t.geom                            AS original_geom,  -- raw GPS point
  e.id                              AS edge_id,        -- matched road segment
  e.geom                            AS edge_geom,      -- segment geometry
  ST_ClosestPoint(e.geom, t.geom)   AS snapped_geom,   -- snapped point on road
  ST_DistanceSphere(
    t.geom, ST_ClosestPoint(e.geom, t.geom)
  )                                 AS snap_dist_m,    -- snapping distance in meters
  ST_Intersects(e.edge_buf, t.geom) AS used_buffer     -- flag: did buffer pre-filter?
FROM taxi_data_subset AS t
CROSS JOIN LATERAL (
  SELECT id, geom, edge_buf
  FROM rome_edges
  ORDER BY
    CASE WHEN ST_Intersects(edge_buf, t.geom) THEN 0 ELSE 1 END,  -- buffer hits rank first
    t.geom <-> geom                                               -- then KNN refine
  LIMIT 1
) AS e;

-- Step 4: Add supporting indexes for downstream analysis & visualization
CREATE INDEX IF NOT EXISTS idx_tmg2_snapped ON taxi_matched_graph_v2 USING gist (snapped_geom);
CREATE INDEX IF NOT EXISTS idx_tmg2_edge    ON taxi_matched_graph_v2 (edge_id);
CREATE INDEX IF NOT EXISTS idx_tmg2_time    ON taxi_matched_graph_v2 (date_time);
CREATE INDEX IF NOT EXISTS idx_tmg2_driveno ON taxi_matched_graph_v2 (drive_no);
ANALYZE taxi_matched_graph_v2;

COMMIT;


-- ---------------------------------------------------------
-- VERSION 3: Optimized two-pass implementation
-- (Splits buffer hits and fallback into separate phases for speed)
-- ---------------------------------------------------------
BEGIN;

-- A) Preconditions (re-run in case schema is fresh)
CREATE INDEX IF NOT EXISTS idx_taxi_geom  ON taxi_data_subset USING gist (geom);
CREATE INDEX IF NOT EXISTS idx_edges_geom ON rome_edges        USING gist (geom);
ANALYZE taxi_data_subset;  
ANALYZE rome_edges;

ALTER TABLE rome_edges DROP COLUMN IF EXISTS edge_buf;
ALTER TABLE rome_edges
ADD COLUMN edge_buf geometry(Polygon, 4326)
GENERATED ALWAYS AS (
  ST_Transform(ST_Buffer(ST_Transform(geom, 32633), 50), 4326)
) STORED;
CREATE INDEX IF NOT EXISTS idx_edges_edgebuf ON rome_edges USING gist (edge_buf);
ANALYZE rome_edges;

-- Performance knobs (local only during this transaction)
SET LOCAL synchronous_commit = off;  -- reduce WAL sync overhead
SET LOCAL work_mem = '256MB';        -- give joins/sorts more memory

-- 1) Fast path: buffer-based joins
-- For each point, pick the nearest edge among those whose buffer contains the point.
-- DISTINCT ON keeps only the closest match per taxi point.
DROP TABLE IF EXISTS tmg_buf_hit;
CREATE UNLOGGED TABLE tmg_buf_hit AS
SELECT DISTINCT ON (t.id)
  t.id        AS point_id,
  t."DriveNo" AS drive_no,
  t.date_time,
  t.geom      AS original_geom,
  e.id        AS edge_id,
  e.geom      AS edge_geom
FROM taxi_data_subset t
JOIN rome_edges e
  ON ST_Intersects(e.edge_buf, t.geom)      -- very cheap thanks to GiST on edge_buf
ORDER BY t.id, t.geom <-> e.geom;           -- break ties by nearest edge
CREATE INDEX idx_tmg_buf_hit_pid ON tmg_buf_hit(point_id);

-- 2) Fallback: global nearest-edge for points missed by buffer
-- Only applies to a small fraction (bridge gaps, noisy GPS).
DROP TABLE IF EXISTS tmg_fallback;
CREATE UNLOGGED TABLE tmg_fallback AS
SELECT
  t.id        AS point_id,
  t."DriveNo" AS drive_no,
  t.date_time,
  t.geom      AS original_geom,
  e.id        AS edge_id,
  e.geom      AS edge_geom
FROM taxi_data_subset t
CROSS JOIN LATERAL (
  SELECT id, geom
  FROM rome_edges
  ORDER BY t.geom <-> geom  -- pure KNN search
  LIMIT 1
) e
WHERE NOT EXISTS (SELECT 1 FROM tmg_buf_hit h WHERE h.point_id = t.id);

-- 3) Combine buffer hits + fallback and compute snapping
-- Distances are computed in UTM33 (meters) for accuracy.
DROP TABLE IF EXISTS taxi_matched_graph_v3;
CREATE TABLE taxi_matched_graph_v3 AS
WITH all_matches AS (
  SELECT *, true  AS used_buffer FROM tmg_buf_hit
  UNION ALL
  SELECT *, false AS used_buffer FROM tmg_fallback
)
SELECT
  point_id,
  drive_no,
  date_time,
  original_geom,
  edge_id,
  edge_geom,
  ST_Transform(
    ST_ClosestPoint(ST_Transform(edge_geom, 32633), ST_Transform(original_geom, 32633)),
    4326
  ) AS snapped_geom,
  ST_Distance(
    ST_Transform(original_geom, 32633),
    ST_ClosestPoint(ST_Transform(edge_geom, 32633), ST_Transform(original_geom, 32633))
  ) AS snap_dist_m,
  used_buffer
FROM all_matches;

-- Indexes after bulk load (faster than maintaining them during insert)
CREATE INDEX idx_tmg3_snapped ON taxi_matched_graph_v3 USING gist (snapped_geom);
CREATE INDEX idx_tmg3_edge    ON taxi_matched_graph_v3 (edge_id);
CREATE INDEX idx_tmg3_time    ON taxi_matched_graph_v3 (date_time);
CREATE INDEX idx_tmg3_driver  ON taxi_matched_graph_v3 (drive_no);
ANALYZE taxi_matched_graph_v3;

COMMIT;

ALTER TABLE taxi_matched_graph_v3
ALTER COLUMN date_time TYPE timestamp
USING date_time::timestamp;

-- 1) aggregate counts: distinct drivers by edge & 15-minute bin
DROP MATERIALIZED VIEW IF EXISTS segment_counts_15m CASCADE;

CREATE MATERIALIZED VIEW segment_counts_15m AS
SELECT
  edge_id,
  date_trunc('minute', date_time) 
    - make_interval(mins := EXTRACT(minute FROM date_time)::int % 15) AS ts_bin,
  COUNT(DISTINCT drive_no) AS vehicles
FROM taxi_matched_graph_v3
GROUP BY edge_id, ts_bin;

-- helpful index to filter by edge/time quickly
CREATE INDEX IF NOT EXISTS idx_seg_counts15_edge_ts 
  ON segment_counts_15m (edge_id, ts_bin);
ANALYZE segment_counts_15m;

-- 2) join with edge geometry (one geom per edge_id)
CREATE OR REPLACE VIEW v_edge_counts_15m AS
SELECT
  e.edge_id,
  c.ts_bin        AS ts,          -- time column to use in the map
  COALESCE(c.vehicles, 0) AS vehicles,
  e.edge_geom     AS geom
FROM (
  SELECT DISTINCT edge_id, edge_geom
  FROM taxi_matched_graph_v3
) e
LEFT JOIN segment_counts_15m c
  ON c.edge_id = e.edge_id;

-- (Optional) quick sanity check:
-- SELECT * FROM v_edge_counts_15m ORDER BY ts, vehicles DESC LIMIT 10;

-- do we have rows at all?
SELECT COUNT(*) FROM v_edge_counts_15m;

-- find a recent time bin with activity
SELECT ts, COUNT(*) AS n_edges, SUM(vehicles) AS total_pings
FROM v_edge_counts_15m
GROUP BY ts
ORDER BY ts DESC
LIMIT 5;

-- pick one returned ts and confirm there are features
SELECT edge_id, vehicles
FROM v_edge_counts_15m
WHERE ts = '2014-02-01 00:45:00+00'  -- replace with one from above
ORDER BY vehicles DESC
LIMIT 10;

-- First drop the view if it exists
DROP VIEW IF EXISTS v_edge_counts_15m;

-- Recreate with unique column names
CREATE OR REPLACE VIEW v_edge_counts_15m AS
SELECT
  e.id                    AS edge_id,     -- edge identifier
  e.geom                  AS geom,        -- geometry column (for GeoServer WMS/WFS)
  c.ts_bin                AS ts,          -- 15-minute time bin
  COALESCE(c.vehicles, 0) AS vehicles     -- number of distinct vehicles
FROM rome_edges e
LEFT JOIN segment_counts_15m c
  ON c.edge_id = e.id;

SELECT * FROM v_edge_counts_15m LIMIT 5;

-- if you use a MATERIALIZED VIEW for counts, refresh it first:
REFRESH MATERIALIZED VIEW segment_counts_15m;

-- sanity: how many rows overall?
SELECT COUNT(*) FROM v_edge_counts_15m;

-- is geometry valid and in EPSG:4326?
SELECT ST_SRID(geom) AS srid, GeometryType(geom) AS gtype
FROM v_edge_counts_15m LIMIT 5;

-- pick a real 15-min bin that exists:
SELECT ts, COUNT(*) 
FROM v_edge_counts_15m 
WHERE vehicles > 0
GROUP BY ts 
ORDER BY ts DESC 
LIMIT 1;

GRANT SELECT ON v_edge_counts_15m TO geoserver;
GRANT SELECT ON segment_counts_15m TO geoserver;  -- if your view joins it
GRANT SELECT ON rome_edges TO geoserver;          -- geometry source


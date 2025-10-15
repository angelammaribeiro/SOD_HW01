-- check if dataset import was done correctly
select * from taxi_data_subset

-- Add a new geometry column called "geom" to store GPS points
-- Geometry type: Point, SRID: 4326 (WGS84 latitude/longitude)
alter table taxi_data_subset
add column geom geometry(Point, 4326)

-- Rename columns for easier handling (remove spaces, standardize names)
ALTER TABLE taxi_data_subset RENAME COLUMN "Longitude" TO longitude;  -- X coordinate (East-West)
ALTER TABLE taxi_data_subset RENAME COLUMN "Latitude" TO latitude;    -- Y coordinate (North-South)
ALTER TABLE taxi_data_subset RENAME COLUMN "Date and Time" TO date_time;  -- timestamp of the GPS record

-- Convert the "longitude" column to numeric type (double precision)
-- Ensures coordinates can be used in spatial functions
ALTER TABLE taxi_data_subset
ALTER COLUMN longitude TYPE double precision
USING longitude::double precision;

-- check cordinates -> conclusion they were swapped
SELECT longitude, latitude FROM taxi_data_subset LIMIT 5;

-- Expect values near Rome: lon ≈ 12.x, lat ≈ 41.x
ALTER TABLE taxi_data_subset RENAME COLUMN longitude TO lat_raw;
ALTER TABLE taxi_data_subset RENAME COLUMN latitude TO lon_raw;

SET geom = ST_SetSRID(ST_MakePoint(lon_raw, lat_raw), 4326);

-- create small, test-sized subsets of taxi points and roads
-- drop table taxi_cropped;
CREATE TABLE taxi_cropped AS
SELECT *
FROM taxi_data_subset
WHERE ST_Within(
  geom,
  ST_MakeEnvelope(12.4852147, 41.9025643, 12.4858663, 41.9029739, 4326)
);

-- drop table roads_cropped;
CREATE TABLE roads_cropped AS
SELECT *
FROM roma_roads
WHERE ST_Intersects(
  geom,
  ST_MakeEnvelope(12.4852147, 41.9025643, 12.4858663, 41.9029739, 4326)
);

-- ------------------------------------------------------------
-- Map-matching: snap each taxi GPS point to its nearest road segment
-- Strategy: for each taxi point, find the closest road geometry
-- using a KNN (<->) search, then compute the closest point
-- on that road (snapped_geom).
-- ------------------------------------------------------------

CREATE TABLE taxi_matched AS
SELECT 
    t.id,
    t.date_time,
    t.geom AS original_geom,   -- raw GPS point
    r.osm_id,
    r.geom AS road_geom,       -- full matched road segment
    ST_ClosestPoint(r.geom, t.geom) AS snapped_geom  -- snapped point on road
FROM taxi_cropped t
JOIN LATERAL (
    SELECT r.osm_id, r.geom
    FROM roads_cropped r
    ORDER BY t.geom <-> r.geom -- KNN search
    LIMIT 1					   -- keep only the nearest road
) r ON true;

-- We first tried without indexes; it ran for a very long time and didn’t finish.
-- With GiST indexes, the same KNN query completed in milliseconds.

CREATE INDEX ON taxi_data_subset USING gist (geom);
CREATE INDEX ON roma_roads USING gist (geom);

-- Run the same process on the COMPLETE dataset (all taxi points + full road network)
-- Produces taxi_matched_complete, same structure as taxi_matched but full coverage
CREATE TABLE taxi_matched_complete AS
SELECT 
    t.id,
    t.date_time,
    t.geom AS original_geom,
    r.osm_id,
    r.geom AS road_geom,
    ST_ClosestPoint(r.geom, t.geom) AS complete_geom
FROM taxi_data_subset t
JOIN LATERAL (
    SELECT r.osm_id, r.geom
    FROM roma_roads r
    ORDER BY t.geom <-> r.geom
    LIMIT 1
) r ON true;

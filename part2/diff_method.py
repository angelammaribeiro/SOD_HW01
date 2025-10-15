# minimal_diff_method.py
import geopandas as gpd

EDGES = "rome_edges_simp.geojson"   # edges with an id column
PTS   = "mm_sample.geojson"         # sample points with point_id
OUT_CSV = "gpd_nearest.csv"
OUT_GJ  = "gpd_snapped_points.geojson"  # optional map layer

# load and ensure ids exist
edges = gpd.read_file(EDGES)
pts   = gpd.read_file(PTS)

eid = next((c for c in ["id","edge_id","fid","osmid"] if c in edges.columns), None)
if eid is None:
    edges = edges.reset_index().rename(columns={"index":"edge_id"})
    eid = "edge_id"
pid = "point_id" if "point_id" in pts.columns else "id"

# work in meters (Rome = UTM 33N, EPSG:32633)
edges_m = edges[[eid, "geometry"]].to_crs(32633)
pts_m   = pts[[pid, "geometry"]].to_crs(32633)

# nearest-edge join (adds index_right of matched edge and distance in meters)
j = gpd.sjoin_nearest(pts_m, edges_m, how="left", distance_col="dist_m")

# build snapped point: projection of point onto matched line
def snap(row):
    line = edges_m.loc[row["index_right"], "geometry"]
    return line.interpolate(line.project(row.geometry))
j["snapped_geom"] = j.apply(snap, axis=1)

# --- outputs ---
j[[pid, eid, "dist_m"]].rename(columns={pid:"point_id", eid:"edge_id_gpd"}).to_csv(OUT_CSV, index=False)

# optional: snapped points for QGIS
gpd.GeoDataFrame(
    j[[pid, eid, "dist_m"]].rename(columns={pid:"point_id", eid:"edge_id_gpd"}),
    geometry=j["snapped_geom"], crs=pts_m.crs
).to_crs(4326).to_file(OUT_GJ, driver="GeoJSON")

print("Wrote", OUT_CSV, "and", OUT_GJ)

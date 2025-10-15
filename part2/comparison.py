import pandas as pd

pg  = pd.read_csv("pg_result.csv")       # point_id, edge_id, snap_dist_m
gpd = pd.read_csv("gpd_nearest.csv")     # point_id, edge_id_gpd, dist_m

m = pg.merge(gpd, on="point_id", how="inner")

pct_diff = (m["edge_id"] != m["edge_id_gpd"]).mean()*100
print(f"% different chosen edge: {pct_diff:.2f}%")

print("\nPostGIS snap_dist_m (m):")
print(m["snap_dist_m"].describe(percentiles=[0.5,0.9]))

print("\nGeoPandas dist_m (m):")
print(m["dist_m"].describe(percentiles=[0.5,0.9]))

import osmnx as ox

# 1. Download the driving road network for Rome
G = ox.graph_from_place("Rome, Italy", network_type="drive")

# 2. Convert to GeoDataFrames (nodes = intersections, edges = road segments)
nodes, edges = ox.graph_to_gdfs(G)

# 3. Save to files so you can use them in QGIS / PostGIS
nodes.to_file("rome_nodes.geojson", driver="GeoJSON")
edges.to_file("rome_edges.geojson", driver="GeoJSON")

print("Done! Saved rome_nodes.geojson and rome_edges.geojson")


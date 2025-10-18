# Part 3 - Exercise 1 Quick Start Guide

## Overview

Exercise 1 requires developing a simple web application that displays the number of vehicles that passed through a specific road segment on a given date and time.

## What's Included

```
part3/
├── all.sql              # Database setup (from Part 2)
├── taxi-webapp/         # Web application
│   ├── app.py          # Flask backend API
│   ├── requirements.txt # Python dependencies
│   ├── README.md       # Detailed documentation
│   └── static/         # Frontend files
│       ├── index.html  # Main HTML page
│       ├── style.css   # Styling
│       └── app.js      # JavaScript logic
└── QUICKSTART.md       # This file
```

## Quick Setup (3 steps)

### Step 1: Database Setup

Make sure you have run the Part 2 SQL script. If not, run:

```bash
# Connect to your PostgreSQL database
psql -U postgres -d taxi_hw1

# Run the setup script
\i part3/all.sql

# Or from command line:
psql -U your_username -d your_database_name -f part3/all.sql
```

Verify the tables exist:
```sql
-- Check if views are created
SELECT COUNT(*) FROM v_edge_counts_15m LIMIT 5;

-- Check time range
SELECT MIN(ts_bin), MAX(ts_bin) FROM segment_counts_15m;
```

### Step 2: Configure and Install

```bash
cd part3/taxi-webapp

# Install Python dependencies
pip install -r requirements.txt

# Edit app.py to configure your database connection
# Update the DB_CONFIG dictionary with your credentials
```

In `app.py`, update:
```python
DB_CONFIG = {
    'host': 'localhost',
    'database': 'YOUR_DATABASE',  # Change this
    'user': 'YOUR_USERNAME',      # Change this
    'password': 'YOUR_PASSWORD',  # Change this
    'port': 5432
}
```

### Step 3: Run the Application

```bash
# Start the Flask server
python app.py
```

Then open your browser to: **http://localhost:5000**

## How to Use the Application

1. **Select a Date/Time**: Use the datetime picker in the control panel
2. **Load Data**: Click "Load Data" button
3. **Explore the Map**:
   - Segments are color-coded by vehicle count (red = more vehicles)
   - Hover over segments to highlight them
   - Click on segments to see details in a popup
   - Click "View Details" to see time series chart
4. **Toggle Options**: Enable "Show vehicle counts on map" to display numbers on segments

## Expected Results

- Interactive map of Rome showing road segments
- Color-coded segments based on vehicle count
- Statistics panel showing:
  - Time range of available data
  - Number of segments loaded
  - Total vehicles
  - Maximum vehicles on any segment
- Clickable segments with detailed information

## Troubleshooting

### "Database connection failed"
- Check if PostgreSQL is running: `pg_isready`
- Verify credentials in `app.py`
- Test connection: `psql -U your_username -d your_database -c "SELECT 1;"`

### "No data available for the selected time period"
- Check if materialized view has data:
  ```sql
  SELECT COUNT(*) FROM segment_counts_15m;
  SELECT DISTINCT ts_bin FROM segment_counts_15m ORDER BY ts_bin LIMIT 10;
  ```
- If empty, refresh it:
  ```sql
  REFRESH MATERIALIZED VIEW segment_counts_15m;
  ```

### Port 5000 already in use
- Change port in `app.py`:
  ```python
  app.run(debug=True, host='0.0.0.0', port=5001)  # Use 5001 instead
  ```
- Also update `API_BASE_URL` in `static/app.js`

## Testing Checklist

- [ ] Database connection successful
- [ ] Time range loads correctly
- [ ] Map displays centered on Rome
- [ ] Segments load when clicking "Load Data"
- [ ] Segments are color-coded
- [ ] Clicking segment shows popup with vehicle count
- [ ] "View Details" opens detail panel with time series chart
- [ ] Statistics update when new data is loaded
- [ ] Labels toggle works when checkbox is enabled

## Key Features Implemented

✓ Web-based interactive map using Leaflet.js
✓ REST API backend with Flask
✓ PostGIS spatial queries with optimization
✓ Time-based filtering
✓ Vehicle count visualization (choropleth)
✓ Detailed segment information
✓ Time series charts
✓ Responsive design

## Next Steps (Exercise 2)

For Exercise 2, you need to implement an advanced analysis/visualization. Some ideas:

1. **Animated Movement**: Show taxi movement over time as an animation
2. **Traffic Density Analysis**: Identify congestion hotspots and time periods
3. **Route Frequency Analysis**: Find most common taxi routes
4. **One-way Detection**: Infer road directionality from traffic patterns
5. **Optimal vs Actual Routes**: Compare taken routes with shortest paths

See the assignment PDF (page 3) for more ideas!

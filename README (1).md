# FM Research Database — Setup Guide

## What's in this folder

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Spins up a PostgreSQL 16 container |
| `schema.sql` | Creates all tables, indexes, and constraints |
| `import_csv.py` | Loads `fbmandataset.csv` into the database |

---

## Quick Start (you and your co-contributor both do this)

### 1. Prerequisites
- Docker Desktop installed and running
- Python 3.8+ with pip
- `fbmandataset.csv` placed in this folder (or note its path)

### 2. Start the database
```bash
docker compose up -d
```
This starts PostgreSQL on **localhost:5432**.  
The schema is created automatically on the very first run.

### 3. Install Python dependencies
```bash
pip install psycopg2-binary pandas
```

### 4. Import the CSV data
```bash
python import_csv.py --csv ./fbmandataset.csv
```
This loads ~159,500 players and their position ratings. Takes about 20–30 seconds.

### 5. Connect with any SQL client
| Setting | Value |
|---------|-------|
| Host | `localhost` |
| Port | `5432` |
| Database | `fm_research` |
| Username | `fm_user` |
| Password | `fm_password` |

Recommended free clients: **DBeaver**, **TablePlus**, **pgAdmin**.

---

## Sharing the database with your co-contributor

### Option A — Share via SQL dump (recommended for research snapshots)
```bash
# Export
docker exec fm_research_db pg_dump -U fm_user fm_research > fm_research_dump.sql

# Co-contributor imports it:
docker compose up -d
psql -h localhost -U fm_user -d fm_research < fm_research_dump.sql
```

### Option B — Both run from scratch
Just share this folder (without the volume). Your co-contributor runs steps 2–4 above.  
They get the same schema and same imported data.

---

## Key design decisions (why we changed the old SQLite schema)

### ❌ What was wrong before
1. **SQLite syntax** — `AUTOINCREMENT`, `PRAGMA` don't exist in PostgreSQL
2. **15 flat position columns** — `Goalkeeper INT, Striker INT …` is hard to query  
   (`WHERE position = 'GK' AND rating >= 15` is much cleaner)
3. **`age` stored as a column** — it becomes stale instantly; use `DATE_PART` instead
4. **`Born` stored as an integer** (YYYYMMDD) — PostgreSQL has a proper `DATE` type
5. **`contracts` duplicated** player name/nationality — breaks normalisation
6. **C program to run SQL files** — unnecessary; `psql` and Python handle this cleanly
7. **No indexes** — 159k rows with no indexes makes research queries slow

### ✅ What we do now
- All FM attributes use `SMALLINT` (saves ~60% memory vs `INT` for 1–20 values)
- Position ratings are in their own table: `player_position_ratings(player_id, position_code, rating)`
- `born` is a real `DATE`; age is computed on the fly
- `player_scraped_stats` is a flexible key-value table for anything you scrape from fandom
- Full-text name search powered by `pg_trgm` index

---

## Useful example queries

```sql
-- All natural strikers (rating = 20) over age 30
SELECT p.name, p.born, DATE_PART('year', AGE(p.born)) AS age
FROM players p
JOIN player_position_ratings pr ON pr.player_id = p.player_id
WHERE pr.position_code = 'ST'
  AND pr.rating = 20
  AND p.born < NOW() - INTERVAL '30 years'
ORDER BY p.finishing DESC;

-- Top 20 passers who can also play DM
SELECT p.name, p.passing, p.vision, p.decisions
FROM players p
JOIN player_position_ratings pr ON pr.player_id = p.player_id
WHERE pr.position_code = 'DM'
  AND pr.rating >= 15
ORDER BY p.passing DESC
LIMIT 20;

-- Fuzzy name search (uses pg_trgm index)
SELECT name, born, positions_desc
FROM players
WHERE name % 'Ronaldo'   -- % is the similarity operator
ORDER BY similarity(name, 'Ronaldo') DESC
LIMIT 10;

-- Insert a scraped stat from your fandom scraper
INSERT INTO player_scraped_stats (player_id, source, stat_key, stat_value)
VALUES (1000055, 'fandom_wiki', 'career_goals', '142');
```

---

## Stopping / restarting
```bash
docker compose down        # stop (data is preserved in the volume)
docker compose down -v     # stop AND wipe all data (fresh start)
docker compose up -d       # start again
```

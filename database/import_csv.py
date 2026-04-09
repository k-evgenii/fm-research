#!/usr/bin/env python3
"""
import_csv.py
============
Loads fbmandataset.csv into the FM research PostgreSQL database.

Usage:
    pip install psycopg2-binary pandas
    python import_csv.py --csv /path/to/fbmandataset.csv

Env vars (override defaults):
    DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS
"""

import argparse
import os
import sys
import pandas as pd
import psycopg2
from psycopg2.extras import execute_values

# ── Connection defaults (match docker-compose.yml) ────────────────────────────
DB = dict(
    host=os.getenv("DB_HOST", "localhost"),
    port=int(os.getenv("DB_PORT", 5432)),
    dbname=os.getenv("DB_NAME", "fm_research"),
    user=os.getenv("DB_USER", "fm_user"),
    password=os.getenv("DB_PASS", "fm_password"),
)

# ── Position column → FM abbreviation mapping ────────────────────────────────
POSITION_MAP = {
    "Goalkeeper":           "GK",
    "Sweeper":              "SW",
    "Striker":              "ST",
    "AttackingMidCentral":  "AMC",
    "AttackingMidLeft":     "AML",
    "AttackingMidRight":    "AMR",
    "DefenderCentral":      "DC",
    "DefenderLeft":         "DL",
    "DefenderRight":        "DR",
    "DefensiveMidfielder":  "DM",
    "MidfielderCentral":    "MC",
    "MidfielderLeft":       "ML",
    "MidfielderRight":      "MR",
    "WingBackLeft":         "WBL",
    "WingBackRight":        "WBR",
}

# ── CSV column → players table column mapping ────────────────────────────────
PLAYER_COL_MAP = {
    "UID":              "player_id",
    "Name":             "name",
    "NationID":         "nation_id",
    "Born":             "born",
    "Height":           "height_cm",
    "Weight":           "weight_kg",
    "PositionsDesc":    "positions_desc",
    "IntCaps":          "int_caps",
    "IntGoals":         "int_goals",
    "U21Caps":          "u21_caps",
    "U21Goals":         "u21_goals",
    # GK
    "AerialAbility":    "aerial_ability",
    "CommandOfArea":    "command_of_area",
    "Communication":    "communication",
    "Eccentricity":     "eccentricity",
    "Handling":         "handling",
    "Kicking":          "kicking",
    "OneOnOnes":        "one_on_ones",
    "Reflexes":         "reflexes",
    "RushingOut":       "rushing_out",
    "TendencyToPunch":  "tendency_to_punch",
    "Throwing":         "throwing",
    # Technical
    "Corners":          "corners",
    "Crossing":         "crossing",
    "Dribbling":        "dribbling",
    "Finishing":        "finishing",
    "FirstTouch":       "first_touch",
    "Freekicks":        "free_kicks",
    "Heading":          "heading",
    "LongShots":        "long_shots",
    "Longthrows":       "long_throws",
    "Marking":          "marking",
    "Passing":          "passing",
    "PenaltyTaking":    "penalty_taking",
    "Tackling":         "tackling",
    "Technique":        "technique",
    # Mental
    "Aggression":       "aggression",
    "Anticipation":     "anticipation",
    "Bravery":          "bravery",
    "Composure":        "composure",
    "Concentration":    "concentration",
    "Decisions":        "decisions",
    "Determination":    "determination",
    "Flair":            "flair",
    "Leadership":       "leadership",
    "OffTheBall":       "off_the_ball",
    "Positioning":      "positioning",
    "Teamwork":         "teamwork",
    "Vision":           "vision",
    "Workrate":         "work_rate",
    # Physical
    "Acceleration":     "acceleration",
    "Agility":          "agility",
    "Balance":          "balance",
    "Jumping":          "jumping",
    "NaturalFitness":   "natural_fitness",
    "Pace":             "pace",
    "Stamina":          "stamina",
    "Strength":         "strength",
    # Feet
    "LeftFoot":         "left_foot",
    "RightFoot":        "right_foot",
    # Hidden
    "Consistency":      "consistency",
    "Dirtiness":        "dirtiness",
    "ImportantMatches": "important_matches",
    "InjuryProness":    "injury_proneness",
    "Versatility":      "versatility",
    # Personality
    "Adaptability":     "adaptability",
    "Ambition":         "ambition",
    "Loyalty":          "loyalty",
    "Pressure":         "pressure",
    "Professional":     "professionalism",
    "Sportsmanship":    "sportsmanship",
    "Temperament":      "temperament",
    "Controversy":      "controversy",
}


def load_csv(path: str) -> pd.DataFrame:
    print(f"Reading CSV: {path}")
    df = pd.read_csv(path, parse_dates=False)

    # Parse Born (DD-MM-YYYY) → proper date string for PostgreSQL
    df["Born"] = pd.to_datetime(df["Born"], format="%d-%m-%Y", errors="coerce")
    df["Born"] = df["Born"].dt.strftime("%Y-%m-%d")   # None if unparseable

    print(f"  Loaded {len(df):,} rows, {len(df.columns)} columns")
    return df


def insert_nations(conn, df: pd.DataFrame):
    """Insert unique NationIDs. Names are NULL until scraped."""
    nations = df["NationID"].dropna().unique().tolist()
    rows = [(int(n),) for n in nations]
    with conn.cursor() as cur:
        execute_values(
            cur,
            "INSERT INTO nations (nation_id) VALUES %s ON CONFLICT DO NOTHING",
            rows,
        )
    conn.commit()
    print(f"  Upserted {len(rows)} nations")


def insert_players(conn, df: pd.DataFrame):
    """Bulk-insert all players."""
    player_df = df.rename(columns=PLAYER_COL_MAP)
    db_cols = list(PLAYER_COL_MAP.values())

    # Only keep columns that exist after renaming
    db_cols = [c for c in db_cols if c in player_df.columns]
    player_df = player_df[db_cols]

    # Replace NaN with None (psycopg2 maps None → NULL)
    player_df = player_df.where(player_df.notna(), None)

    rows = [tuple(r) for r in player_df.itertuples(index=False, name=None)]
    cols_sql = ", ".join(db_cols)
    sql = f"INSERT INTO players ({cols_sql}) VALUES %s ON CONFLICT (player_id) DO NOTHING"

    with conn.cursor() as cur:
        execute_values(cur, sql, rows, page_size=2000)
    conn.commit()
    print(f"  Inserted {len(rows):,} players")


def insert_position_ratings(conn, df: pd.DataFrame):
    """Normalise the 15 flat position columns into player_position_ratings."""
    rows = []
    for csv_col, code in POSITION_MAP.items():
        if csv_col not in df.columns:
            continue
        sub = df[["UID", csv_col]].dropna()
        for _, row in sub.iterrows():
            rows.append((int(row["UID"]), code, int(row[csv_col])))

    with conn.cursor() as cur:
        execute_values(
            cur,
            """INSERT INTO player_position_ratings (player_id, position_code, rating)
               VALUES %s
               ON CONFLICT (player_id, position_code) DO NOTHING""",
            rows,
            page_size=5000,
        )
    conn.commit()
    print(f"  Inserted {len(rows):,} position ratings")


def main():
    parser = argparse.ArgumentParser(description="Import FM CSV into PostgreSQL")
    parser.add_argument("--csv", required=True, help="Path to fbmandataset.csv")
    args = parser.parse_args()

    if not os.path.exists(args.csv):
        sys.exit(f"CSV file not found: {args.csv}")

    df = load_csv(args.csv)

    print("Connecting to database …")
    conn = psycopg2.connect(**DB)
    print("  Connected.")

    print("Inserting nations …")
    insert_nations(conn, df)

    print("Inserting players …")
    insert_players(conn, df)

    print("Inserting position ratings …")
    insert_position_ratings(conn, df)

    conn.close()
    print("\nDone! All data imported successfully.")


if __name__ == "__main__":
    main()

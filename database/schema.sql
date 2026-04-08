-- =============================================================
-- FM Research Database  –  PostgreSQL Schema
-- =============================================================
-- Designed for FM 2017 player data + future web-scraped stats.
-- Run once when the container first starts (Docker will call this
-- automatically from the init volume mount).
-- =============================================================

-- ---------------------------------------------------------------
-- EXTENSIONS
-- ---------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_trgm;   -- fast fuzzy name search

-- ---------------------------------------------------------------
-- NATIONS
-- nation_id matches FM's internal NationID from the CSV.
-- Names are NULL until filled by your web scraper.
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS nations (
    nation_id   INT         PRIMARY KEY,   -- FM internal ID
    name        VARCHAR(100) UNIQUE        -- populated via scraping
);

-- ---------------------------------------------------------------
-- PLAYERS  (core identity + all FM attributes)
-- One row per player. All attribute columns use SMALLINT (1-20)
-- to match FM's rating scale and save space on 159k rows.
-- age is NOT stored – derive it: DATE_PART('year', AGE(born))
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS players (
    player_id           INT          PRIMARY KEY,   -- FM UID from CSV
    name                VARCHAR(100) NOT NULL,
    nation_id           INT          REFERENCES nations(nation_id),
    born                DATE,
    height_cm           SMALLINT,
    weight_kg           SMALLINT,
    positions_desc      VARCHAR(30),   -- FM natural position string e.g. "D C", "GK", "S"
    int_caps            SMALLINT     DEFAULT 0,
    int_goals           SMALLINT     DEFAULT 0,
    u21_caps            SMALLINT     DEFAULT 0,
    u21_goals           SMALLINT     DEFAULT 0,

    -- ── GK-specific attributes ──────────────────────────────────
    aerial_ability      SMALLINT,
    command_of_area     SMALLINT,
    communication       SMALLINT,
    eccentricity        SMALLINT,
    handling            SMALLINT,
    kicking             SMALLINT,
    one_on_ones         SMALLINT,
    reflexes            SMALLINT,
    rushing_out         SMALLINT,
    tendency_to_punch   SMALLINT,
    throwing            SMALLINT,

    -- ── Technical attributes ────────────────────────────────────
    corners             SMALLINT,
    crossing            SMALLINT,
    dribbling           SMALLINT,
    finishing           SMALLINT,
    first_touch         SMALLINT,
    free_kicks          SMALLINT,
    heading             SMALLINT,
    long_shots          SMALLINT,
    long_throws         SMALLINT,
    marking             SMALLINT,
    passing             SMALLINT,
    penalty_taking      SMALLINT,
    tackling            SMALLINT,
    technique           SMALLINT,

    -- ── Mental attributes ───────────────────────────────────────
    aggression          SMALLINT,
    anticipation        SMALLINT,
    bravery             SMALLINT,
    composure           SMALLINT,
    concentration       SMALLINT,
    decisions           SMALLINT,
    determination       SMALLINT,
    flair               SMALLINT,
    leadership          SMALLINT,
    off_the_ball        SMALLINT,
    positioning         SMALLINT,
    teamwork            SMALLINT,
    vision              SMALLINT,
    work_rate           SMALLINT,

    -- ── Physical attributes ─────────────────────────────────────
    acceleration        SMALLINT,
    agility             SMALLINT,
    balance             SMALLINT,
    jumping             SMALLINT,
    natural_fitness     SMALLINT,
    pace                SMALLINT,
    stamina             SMALLINT,
    strength            SMALLINT,

    -- ── Footedness (1=weak, 20=strong) ──────────────────────────
    left_foot           SMALLINT,
    right_foot          SMALLINT,

    -- ── Hidden attributes ───────────────────────────────────────
    consistency         SMALLINT,
    dirtiness           SMALLINT,
    important_matches   SMALLINT,
    injury_proneness    SMALLINT,
    versatility         SMALLINT,

    -- ── Personality attributes ──────────────────────────────────
    adaptability        SMALLINT,
    ambition            SMALLINT,
    loyalty             SMALLINT,
    pressure            SMALLINT,
    professionalism     SMALLINT,
    sportsmanship       SMALLINT,
    temperament         SMALLINT,
    controversy         SMALLINT
);

-- ---------------------------------------------------------------
-- POSITION RATINGS  (normalised out of the flat CSV columns)
-- Each player can be rated at up to 15 positions (1–20).
-- 20 = Natural, 15 = Accomplished, 10 = Competent, 5 = Unconvincing
-- position_code uses the standard FM abbreviations.
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS player_position_ratings (
    player_id       INT         NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    position_code   VARCHAR(5)  NOT NULL,
    rating          SMALLINT    NOT NULL CHECK (rating BETWEEN 1 AND 20),
    PRIMARY KEY (player_id, position_code)
);

-- Valid position codes for reference
COMMENT ON TABLE player_position_ratings IS
    'position_code values: GK, SW, ST, AMC, AML, AMR, DC, DL, DR, DM, MC, ML, MR, WBL, WBR';

-- ---------------------------------------------------------------
-- SCRAPED STATS  (flexible key-value store for web-scraped data)
-- Designed to accept anything your fandom scraper finds without
-- needing schema changes every time you add a new stat.
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS player_scraped_stats (
    player_id       INT             NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    source          VARCHAR(100)    NOT NULL,   -- e.g. 'fandom_wiki', 'transfermarkt'
    scraped_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),
    stat_key        VARCHAR(100)    NOT NULL,   -- e.g. 'market_value', 'career_goals'
    stat_value      TEXT,
    PRIMARY KEY (player_id, source, stat_key)
);

-- ---------------------------------------------------------------
-- TEAMS  (shell table – ready for when you scrape club data)
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS teams (
    team_id             SERIAL       PRIMARY KEY,
    name                VARCHAR(100) NOT NULL,
    nation_id           INT          REFERENCES nations(nation_id),
    division            VARCHAR(60),
    stadium_capacity    INT,
    average_attendance  INT,
    ability             NUMERIC(4,1),
    potential           NUMERIC(4,1)
);

-- ---------------------------------------------------------------
-- CONTRACTS  (links players to teams – fill when you have club data)
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS contracts (
    contract_id         SERIAL       PRIMARY KEY,
    player_id           INT          NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    team_id             INT          NOT NULL REFERENCES teams(team_id)     ON DELETE CASCADE,
    wage_eur            INT,
    value_eur           INT,
    contract_signed     DATE,
    contract_expires    DATE,
    current_ability     SMALLINT,
    potential_ability   SMALLINT,
    UNIQUE (player_id, team_id, contract_signed)   -- no duplicate contracts
);

-- ---------------------------------------------------------------
-- LOANS
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS loans (
    loan_id             SERIAL  PRIMARY KEY,
    player_id           INT     NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    loaning_team_id     INT     NOT NULL REFERENCES teams(team_id)     ON DELETE CASCADE,
    receiving_team_id   INT     NOT NULL REFERENCES teams(team_id)     ON DELETE CASCADE,
    loan_expires        DATE    NOT NULL,
    UNIQUE (player_id, loaning_team_id, receiving_team_id)
);

-- ---------------------------------------------------------------
-- INDEXES  (important for 159k-row research queries)
-- ---------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_players_nation    ON players(nation_id);
CREATE INDEX IF NOT EXISTS idx_players_born      ON players(born);
CREATE INDEX IF NOT EXISTS idx_players_name_trgm ON players USING gin(name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_pos_ratings_code  ON player_position_ratings(position_code);
CREATE INDEX IF NOT EXISTS idx_scraped_source    ON player_scraped_stats(source, stat_key);
CREATE INDEX IF NOT EXISTS idx_contracts_team    ON contracts(team_id);
CREATE INDEX IF NOT EXISTS idx_contracts_player  ON contracts(player_id);

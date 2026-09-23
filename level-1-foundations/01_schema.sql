-- =============================================================================
-- 01_schema.sql  ·  Level 1 — Foundations
--
-- Schema for a melting-shop analytics database: continuous and batch furnaces
-- melting glass frit, one row per melt (= one production order), per-melt
-- averages from the furnace control system (SCADA), and lot-level quality
-- decisions from a separate QC system.
--
-- Skills shown
--   * normalised design with primary / foreign keys and lookup tables
--   * CHECK constraints (MySQL 8.0.16+) for physically impossible values
--   * a STORED generated column for a derived metric
--   * NULL used on purpose: "not measured" is not the same as "zero"
--   * indexes chosen for the queries in levels 2 and 3
--
-- Dialect: MySQL 8.0. All data in this repository is synthetic.
-- =============================================================================

DROP DATABASE IF EXISTS melt_shop;
CREATE DATABASE melt_shop CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE melt_shop;

-- ── Furnaces ─────────────────────────────────────────────────────────────────
CREATE TABLE furnaces (
  furnace_code  VARCHAR(8)  NOT NULL,
  furnace_type  ENUM('continuous','tilting','rotary') NOT NULL,
  has_scada     TINYINT(1)  NOT NULL DEFAULT 1
                COMMENT '0 = the control system does not log this furnace at all',
  commissioned  YEAR        NULL,
  PRIMARY KEY (furnace_code)
) ENGINE=InnoDB COMMENT='melting furnaces';

-- ── Products ─────────────────────────────────────────────────────────────────
CREATE TABLE products (
  product_code  VARCHAR(16) NOT NULL,
  family        ENUM('opaque','transparent','matte') NOT NULL,
  description   VARCHAR(80) NULL,
  PRIMARY KEY (product_code)
) ENGINE=InnoDB COMMENT='frit products';

-- ── Melts: the fact table ────────────────────────────────────────────────────
-- One row per production order. Everything else hangs off melt_id.
CREATE TABLE melts (
  melt_id        INT UNSIGNED  NOT NULL COMMENT 'production order number',
  furnace_code   VARCHAR(8)    NOT NULL,
  product_code   VARCHAR(16)   NOT NULL,
  start_ts       DATETIME      NOT NULL,
  end_ts         DATETIME      NOT NULL,
  hours          DECIMAL(7,2)  NOT NULL COMMENT 'furnace hours spent on the order',
  charge_kg      DECIMAL(10,1) NULL
                 COMMENT 'raw materials charged; NULL = not weighed (common before 2021)',
  output_kg      DECIMAL(10,1) NOT NULL COMMENT 'frit produced',
  gas_nm3        DECIMAL(10,1) NULL,
  oxygen_nm3     DECIMAL(10,1) NULL
                 COMMENT 'NULL = furnace fired with air. NOT the same as zero oxygen.',
  electricity_kwh        DECIMAL(10,1) NULL COMMENT 'metered only from 2024',
  material_cost_per_kg   DECIMAL(8,3)  NULL COMMENT 'ERP costing, available from 2024',
  conversion_cost_per_kg DECIMAL(8,3)  NULL COMMENT 'ERP costing, available from 2024',

  -- Loss on melting (CO2 from carbonates, water, volatiles). Derived, so it
  -- is generated rather than stored by hand: it can never disagree with the
  -- two columns it comes from. NULL when the charge was not weighed.
  loss_pct DECIMAL(6,2) GENERATED ALWAYS AS (
             CASE WHEN charge_kg > 0 THEN (1 - output_kg / charge_kg) * 100 END
           ) STORED,

  PRIMARY KEY (melt_id),
  CONSTRAINT fk_melts_furnace FOREIGN KEY (furnace_code) REFERENCES furnaces (furnace_code),
  CONSTRAINT fk_melts_product FOREIGN KEY (product_code) REFERENCES products (product_code),
  CONSTRAINT ck_melts_hours   CHECK (hours > 0),
  CONSTRAINT ck_melts_output  CHECK (output_kg > 0),
  CONSTRAINT ck_melts_period  CHECK (end_ts > start_ts),
  -- Deliberately NO check that output_kg <= charge_kg. In real data it
  -- happens: material spills over between two consecutive orders of the same
  -- product, one order looks too good and the next too bad. Rejecting those
  -- rows would hide the problem; level 3 (file 06) resolves it instead.
  KEY ix_melts_end         (end_ts),
  KEY ix_melts_furnace_end (furnace_code, end_ts),
  KEY ix_melts_product_end (product_code, end_ts)
) ENGINE=InnoDB COMMENT='one row per melt / production order';

-- ── Per-melt averages from the control system ────────────────────────────────
-- 1 : 0..1 with melts. A missing row means "no signal", which the audit in
-- level 2 separates into "furnace has no SCADA" and "logging gap".
CREATE TABLE furnace_regime (
  melt_id        INT UNSIGNED      NOT NULL,
  readings       SMALLINT UNSIGNED NOT NULL COMMENT 'samples averaged over the melt',
  t1_c           DECIMAL(6,1)      NULL COMMENT 'crown temperature',
  t3_c           DECIMAL(6,1)      NULL COMMENT 'exit temperature',
  gas_flow_nm3h  DECIMAL(7,2)      NULL COMMENT 'metered gas flow; may miss auxiliary burners',
  PRIMARY KEY (melt_id),
  CONSTRAINT fk_regime_melt FOREIGN KEY (melt_id) REFERENCES melts (melt_id)
) ENGINE=InnoDB COMMENT='SCADA averages per melt';

-- ── Quality ──────────────────────────────────────────────────────────────────
CREATE TABLE decision_codes (
  decision_code VARCHAR(10) NOT NULL,
  category      ENUM('conforming','remelt','rejected') NOT NULL,
  description   VARCHAR(80) NOT NULL,
  PRIMARY KEY (decision_code)
) ENGINE=InnoDB;

-- One row per lot (bag) inspected by QC. Loaded from a different system, so
-- there is intentionally NO foreign key to melts: the QC export can reference
-- orders the production table does not know. The audit in level 2 lists them
-- instead of letting a constraint silently refuse the load.
CREATE TABLE quality_lots (
  lot_id        INT UNSIGNED NOT NULL,
  melt_id       INT UNSIGNED NOT NULL,
  decision_code VARCHAR(10)  NOT NULL,
  qty_kg        DECIMAL(9,1) NOT NULL,
  decided_at    DATETIME     NOT NULL,
  PRIMARY KEY (lot_id),
  KEY ix_lots_melt (melt_id),
  CONSTRAINT fk_lots_code FOREIGN KEY (decision_code) REFERENCES decision_codes (decision_code),
  CONSTRAINT ck_lots_qty  CHECK (qty_kg > 0)
) ENGINE=InnoDB COMMENT='QC decision per lot';

-- ── Maintenance and tariffs ──────────────────────────────────────────────────
CREATE TABLE maintenance_events (
  event_id     INT UNSIGNED NOT NULL AUTO_INCREMENT,
  furnace_code VARCHAR(8)   NOT NULL,
  event_date   DATE         NOT NULL,
  event_type   ENUM('general overhaul','lining repair','conversion to oxygen') NOT NULL,
  PRIMARY KEY (event_id),
  KEY ix_maint_furnace_date (furnace_code, event_date),
  CONSTRAINT fk_maint_furnace FOREIGN KEY (furnace_code) REFERENCES furnaces (furnace_code)
) ENGINE=InnoDB;

CREATE TABLE energy_tariffs (
  tariff_year      YEAR         NOT NULL,
  gas_per_nm3      DECIMAL(7,3) NOT NULL,
  PRIMARY KEY (tariff_year)
) ENGINE=InnoDB COMMENT='average gas price per year, currency units';

-- ── Quick check ──────────────────────────────────────────────────────────────
SELECT table_name, table_comment
FROM information_schema.tables
WHERE table_schema = 'melt_shop'
ORDER BY table_name;

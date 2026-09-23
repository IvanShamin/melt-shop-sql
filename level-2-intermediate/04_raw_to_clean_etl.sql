-- =============================================================================
-- 04_raw_to_clean_etl.sql  ·  Level 2 — Intermediate
--
-- Loading a messy ERP export into a clean table without losing anything.
--
-- The pattern: land the file as TEXT ONLY in a staging table, then clean it
-- with one INSERT ... SELECT that can be re-run any time. A malformed value
-- can then never break the load — it shows up in a rejects report instead.
--
-- Skills shown
--   * staging table with every column VARCHAR
--   * string cleaning: TRIM, UPPER, REPLACE, LPAD, REGEXP_LIKE
--   * parsing two date formats and decimal commas safely under strict mode
--   * parsing rules kept in views, so the load and the reports share them
--   * de-duplication of re-exported rows with ROW_NUMBER()
--   * INSERT ... SELECT with an explicit column list
--   * flag, don't fix: impossible rows are kept and marked
--   * control figures, a rejects report and a warnings report
--
-- Self-contained: builds its own staging data, does not touch `melts`.
-- =============================================================================

USE melt_shop;

-- ── 1. Staging: exactly what the ERP sent, all as text ───────────────────────
DROP TABLE IF EXISTS stg_melts_raw;
CREATE TABLE stg_melts_raw (
  raw_id     INT UNSIGNED NOT NULL AUTO_INCREMENT,
  batch_id   INT UNSIGNED NOT NULL COMMENT 'one export file = one batch',
  job        VARCHAR(64) NULL,
  machine    VARCHAR(64) NULL,
  product    VARCHAR(64) NULL,
  start_dt   VARCHAR(64) NULL,
  close_dt   VARCHAR(64) NULL,
  machine_t  VARCHAR(64) NULL COMMENT 'hours',
  input_kg   VARCHAR(64) NULL,
  output_kg  VARCHAR(64) NULL,
  gas_qty    VARCHAR(64) NULL,
  PRIMARY KEY (raw_id)
) ENGINE=InnoDB;

-- A small export with the usual problems, all of which occurred in practice:
--   furnace codes written three ways, two date formats, decimal commas with a
--   thousands space, empty strings for "no value", a cancelled job, a job that
--   was exported twice (corrected in the second file), a product-code typo,
--   an unparseable number, and output larger than the charge.
INSERT INTO stg_melts_raw
  (batch_id, job, machine, product, start_dt, close_dt, machine_t, input_kg, output_kg, gas_qty)
VALUES
  (1, '30100001', 'C01',   'OPQ-105',  '2026-03-02 06:00', '2026-03-06 01:10', '91,2',  '49 310,0', '45 920,5', '10 402'),
  (1, '30100002', ' c1 ',  'OPQ-105',  '06.03.2026 2:00',  '09.03.2026 23:40', '93.6',  '51220',    '47 002,0', '10755'),
  (1, '30100003', 'C 03',  'TRN-102',  '2026-03-03 08:00', '2026-03-05 20:30', '60,5',  '38 880,0', '34 610,0', '7 390'),
  (1, '30100004', 'c03',   'TRN-102',  '2026-03-06 01:00', '2026-03-08 14:15', '61,25', '',         '33 980,0', '7 402'),
  (1, '30100005', 'C04',   'MAT-l09',  '2026-03-04 07:00', '2026-03-06 11:00', '52',    '29 900,0', '27 780,0', '5 610'),
  (1, '30100006', 'C04',   'MAT-109',  '2026-03-07 00:30', '2026-03-07 00:30', '0',     '',         '0',        ''),
  (1, '30100007', 'T1',    'MAT-104',  '2026-03-05 06:00', '2026-03-05 13:30', '7,5',   '1 380,0',  '1 318,2',  '520'),
  (1, '30100008', 'C06',   'TRN-103',  '2026-03-05 12:00', '2026-03-08 03:00', '63',    '35 200,0', '36 050,0', '7 910'),
  (1, '30100009', 'C05',   'OPQ-116',  '2026-03-06 05:00', '2026-03-08 22:45', '65.7',  '31 400,0', 'n/a',      '6 880'),
  (1, '30100010', 'C02',   'TRN-107',  '2026-13-06 05:00', '2026-03-09 10:00', '76',    '37 700,0', '34 010,0', '7 120'),
  -- second export: job 30100004 re-sent with the charge filled in
  (2, '30100004', 'C03',   'TRN-102',  '2026-03-06 01:00', '2026-03-08 14:15', '61,25', '37 950,0', '33 980,0', '7 402'),
  (2, '30100011', 'C01',   'OPQ-105',  '2026-03-10 00:30', '2026-03-13 21:00', '92,5',  '50 120,0', '46 400,0', '10 510');

-- Product-code typos seen in the ERP. A lookup table, not a CASE in the query:
-- the list grows, and it must be visible to the people who maintain it.
DROP TABLE IF EXISTS product_alias;
CREATE TABLE product_alias (
  wrong_code VARCHAR(16) NOT NULL PRIMARY KEY,
  right_code VARCHAR(16) NOT NULL
) ENGINE=InnoDB;
INSERT INTO product_alias VALUES ('MAT-l09', 'MAT-109');   -- lower-case L for 1

-- ── 2. The clean target ──────────────────────────────────────────────────────
DROP TABLE IF EXISTS melts_clean_demo;
CREATE TABLE melts_clean_demo (
  melt_id        INT UNSIGNED  NOT NULL PRIMARY KEY,
  furnace_code   VARCHAR(8)    NOT NULL,
  product_code   VARCHAR(16)   NOT NULL,
  start_ts       DATETIME      NULL,
  end_ts         DATETIME      NOT NULL,
  hours          DECIMAL(7,2)  NOT NULL,
  charge_kg      DECIMAL(10,1) NULL,
  output_kg      DECIMAL(10,1) NOT NULL,
  gas_nm3        DECIMAL(10,1) NULL,
  flag_output_gt_charge TINYINT(1) NOT NULL DEFAULT 0
    COMMENT 'kept and flagged, not deleted: someone has to look at it',
  batch_id       INT UNSIGNED  NOT NULL
) ENGINE=InnoDB;

-- ── 3. Parsing rules, written once as views ──────────────────────────────────
-- Under strict SQL mode (the MySQL 8 default) STR_TO_DATE on a bad string or
-- CAST('n/a' AS DECIMAL) inside an INSERT is an ERROR, not a warning. So every
-- value is first checked against a pattern and only then converted; anything
-- that does not match becomes NULL and is reported below.
DROP VIEW IF EXISTS v_stg_parsed;
CREATE VIEW v_stg_parsed AS
SELECT
  r.raw_id,
  r.batch_id,
  CAST(NULLIF(TRIM(r.job), '') AS UNSIGNED)                         AS melt_id,
  -- ' c1 ', 'C 03', 'c03', 'T1'  ->  'C01', 'C03', 'C03', 'T01'
  CASE WHEN REGEXP_LIKE(UPPER(REPLACE(r.machine, ' ', '')), '^[A-Z][0-9]{1,2}$')
       THEN CONCAT(LEFT(UPPER(REPLACE(r.machine, ' ', '')), 1),
                   LPAD(SUBSTRING(UPPER(REPLACE(r.machine, ' ', '')), 2), 2, '0'))
  END                                                               AS furnace_code,
  COALESCE(pa.right_code, NULLIF(TRIM(r.product), ''))              AS product_code,
  CASE
    WHEN REGEXP_LIKE(r.start_dt, '^[0-9]{4}-(0[1-9]|1[0-2])-[0-3][0-9] [0-2]?[0-9]:[0-5][0-9]$')
      THEN STR_TO_DATE(r.start_dt, '%Y-%m-%d %H:%i')
    WHEN REGEXP_LIKE(r.start_dt, '^[0-3]?[0-9]\\.(0?[1-9]|1[0-2])\\.[0-9]{4} [0-2]?[0-9]:[0-5][0-9]$')
      THEN STR_TO_DATE(r.start_dt, '%d.%m.%Y %H:%i')
  END                                                               AS start_ts,
  CASE
    WHEN REGEXP_LIKE(r.close_dt, '^[0-9]{4}-(0[1-9]|1[0-2])-[0-3][0-9] [0-2]?[0-9]:[0-5][0-9]$')
      THEN STR_TO_DATE(r.close_dt, '%Y-%m-%d %H:%i')
    WHEN REGEXP_LIKE(r.close_dt, '^[0-3]?[0-9]\\.(0?[1-9]|1[0-2])\\.[0-9]{4} [0-2]?[0-9]:[0-5][0-9]$')
      THEN STR_TO_DATE(r.close_dt, '%d.%m.%Y %H:%i')
  END                                                               AS end_ts,
  -- '49 310,0' -> '49310.0' -> 49310.0 ; 'n/a' -> NULL
  CASE WHEN REGEXP_LIKE(REPLACE(REPLACE(r.machine_t, ' ', ''), ',', '.'), '^[0-9]+(\\.[0-9]+)?$')
       THEN CAST(REPLACE(REPLACE(r.machine_t, ' ', ''), ',', '.') AS DECIMAL(10,2)) END AS hours,
  CASE WHEN REGEXP_LIKE(REPLACE(REPLACE(r.input_kg,  ' ', ''), ',', '.'), '^[0-9]+(\\.[0-9]+)?$')
       THEN CAST(REPLACE(REPLACE(r.input_kg,  ' ', ''), ',', '.') AS DECIMAL(12,1)) END AS charge_kg,
  CASE WHEN REGEXP_LIKE(REPLACE(REPLACE(r.output_kg, ' ', ''), ',', '.'), '^[0-9]+(\\.[0-9]+)?$')
       THEN CAST(REPLACE(REPLACE(r.output_kg, ' ', ''), ',', '.') AS DECIMAL(12,1)) END AS output_kg,
  CASE WHEN REGEXP_LIKE(REPLACE(REPLACE(r.gas_qty,   ' ', ''), ',', '.'), '^[0-9]+(\\.[0-9]+)?$')
       THEN CAST(REPLACE(REPLACE(r.gas_qty,   ' ', ''), ',', '.') AS DECIMAL(12,1)) END AS gas_nm3,
  -- keep the raw text next to the parsed value for the rejects report
  r.machine AS raw_machine, r.start_dt AS raw_start, r.output_kg AS raw_output
FROM stg_melts_raw r
LEFT JOIN product_alias pa ON pa.wrong_code = TRIM(r.product);

-- One row per job: when a job was exported twice, the later batch wins.
DROP VIEW IF EXISTS v_stg_latest;
CREATE VIEW v_stg_latest AS
SELECT *
FROM (
  SELECT p.*,
         ROW_NUMBER() OVER (PARTITION BY melt_id ORDER BY batch_id DESC, raw_id DESC) AS rn
  FROM v_stg_parsed p
) x
WHERE rn = 1;

-- ── 4. Load ──────────────────────────────────────────────────────────────────
-- Full rebuild, so the script can be re-run after any rule changes.
-- The column list is explicit: without it the INSERT relies on the SELECT
-- matching the table's column order, and adding one column on either side
-- would shift data into the wrong fields without an error.
TRUNCATE TABLE melts_clean_demo;

INSERT INTO melts_clean_demo
  (melt_id, furnace_code, product_code, start_ts, end_ts, hours,
   charge_kg, output_kg, gas_nm3, flag_output_gt_charge, batch_id)
SELECT
  melt_id, furnace_code, product_code, start_ts, end_ts, hours,
  charge_kg, output_kg, gas_nm3,
  COALESCE(output_kg > charge_kg, 0),
  batch_id
FROM v_stg_latest
WHERE melt_id IS NOT NULL
  AND furnace_code IS NOT NULL
  AND product_code IS NOT NULL
  AND end_ts IS NOT NULL
  AND hours > 0            -- cancelled jobs come through with zero hours
  AND output_kg > 0;       -- ... and zero output

-- ── 5. Rejects report: every staging row that did not make it, and why ──────
SELECT
  l.melt_id,
  l.batch_id,
  CASE
    WHEN l.furnace_code IS NULL                        THEN CONCAT('furnace code not recognised: ', l.raw_machine)
    WHEN l.start_ts IS NULL AND l.raw_start IS NOT NULL THEN CONCAT('start date not parseable: ', l.raw_start)
    WHEN l.output_kg IS NULL                           THEN CONCAT('output not a number: ', l.raw_output)
    WHEN l.hours = 0 OR l.output_kg = 0                THEN 'cancelled job (zero hours / output)'
    ELSE 'other'
  END AS reason
FROM v_stg_latest l
LEFT JOIN melts_clean_demo c ON c.melt_id = l.melt_id
WHERE c.melt_id IS NULL
ORDER BY l.melt_id;

-- Loaded, but someone should look: the row is usable, one field is not.
-- 30100010 has an impossible start date (month 13) and a valid end, so it is
-- kept with start_ts = NULL. 30100008 produced more than was charged.
SELECT c.melt_id, 'start date not parseable, loaded without it' AS warning
FROM melts_clean_demo c
JOIN v_stg_latest l ON l.melt_id = c.melt_id
WHERE c.start_ts IS NULL AND l.raw_start IS NOT NULL
UNION ALL
SELECT melt_id, CONCAT('output ', output_kg, ' kg > charge ', charge_kg, ' kg')
FROM melts_clean_demo
WHERE flag_output_gt_charge = 1
ORDER BY melt_id;

-- ── 6. Control figures ───────────────────────────────────────────────────────
-- Compared with the previous run before anyone looks at a dashboard.
SELECT
  (SELECT COUNT(*) FROM stg_melts_raw)                       AS raw_rows,
  (SELECT COUNT(DISTINCT job) FROM stg_melts_raw)            AS distinct_jobs,
  COUNT(*)                                                   AS clean_rows,
  SUM(flag_output_gt_charge)                                 AS flagged_output_gt_charge,
  SUM(charge_kg IS NULL)                                     AS without_charge,
  SUM(start_ts IS NULL)                                      AS without_start,
  ROUND(SUM(output_kg) / 1000, 1)                            AS tonnes
FROM melts_clean_demo;
-- Expected: raw 12 | distinct 11 | clean 9 | flagged 1 | without charge 0 |
--           without start 1 | tonnes 307.1
-- If the figures differ, find the cause. Do not edit the expected values.

SELECT melt_id, furnace_code, product_code, start_ts, end_ts, hours,
       charge_kg, output_kg, gas_nm3, flag_output_gt_charge AS flag, batch_id
FROM melts_clean_demo
ORDER BY melt_id;

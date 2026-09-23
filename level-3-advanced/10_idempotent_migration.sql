-- =============================================================================
-- 10_idempotent_migration.sql  ·  Level 3 — Advanced
--
-- Shipping a change to a production database that is updated by hand — a
-- script someone pastes into phpMyAdmin or the mysql client, possibly twice,
-- possibly half of it. Every block here is safe to run again, and a data
-- refresh either reconciles or leaves the old data untouched.
--
-- What it deploys
--   1. a new column melts.run_id (the runs from file 07, now persisted)
--   2. a derived table quality_by_code (tonnage per melt and decision code)
--   3. a procedure that refreshes it inside a transaction and refuses to
--      commit if the result does not add up
--
-- Skills shown
--   * "where am I" status query before anything changes
--   * conditional DDL via information_schema + PREPARE / EXECUTE
--   * UPDATE ... JOIN driven by a window-function CTE
--   * stored procedure with an EXIT HANDLER, SIGNAL and ROLLBACK
--   * a reconciliation check as the commit condition
--   * proving idempotency with a checksum
-- =============================================================================

USE melt_shop;

-- ── 0. Where am I? Run this first, on its own ───────────────────────────────
-- In a hand-run deployment the first question is how far the last attempt
-- got. Each flag tells which section still has to run.
SELECT
  (SELECT COUNT(*) FROM information_schema.columns
    WHERE table_schema = DATABASE() AND table_name = 'melts'
      AND column_name  = 'run_id')                               AS has_run_id_column,
  (SELECT COUNT(*) FROM information_schema.tables
    WHERE table_schema = DATABASE() AND table_name = 'quality_by_code') AS has_quality_by_code,
  (SELECT COUNT(*) FROM information_schema.routines
    WHERE routine_schema = DATABASE()
      AND routine_name   = 'refresh_quality_by_code')            AS has_refresh_procedure;


-- ── 1. Add a column only if it is missing ───────────────────────────────────
-- MySQL 8 has no ALTER TABLE ... ADD COLUMN IF NOT EXISTS (MariaDB does; the
-- difference bites when a local XAMPP runs MariaDB and the server MySQL).
-- The portable way: ask information_schema, build the statement, execute it.
-- On a second run the statement is a harmless DO 0.
SET @ddl := IF(
  (SELECT COUNT(*) FROM information_schema.columns
    WHERE table_schema = DATABASE() AND table_name = 'melts'
      AND column_name  = 'run_id') = 0,
  'ALTER TABLE melts
     ADD COLUMN run_id VARCHAR(16) NULL
         COMMENT ''consecutive run of one product on one furnace, see file 07'',
     ADD KEY ix_melts_run (run_id)',
  'DO 0');
PREPARE stmt FROM @ddl;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
-- Caveat from practice: some web clients run each statement in a separate
-- session or switch the default schema; if DATABASE() comes back NULL there,
-- the check finds nothing. The status query in section 0 catches that.


-- ── 2. Fill it: recomputed from scratch every time ──────────────────────────
-- Recomputing instead of "only new rows" is what makes this re-runnable: the
-- result depends only on the data, not on what the previous run did.
WITH ordered AS (
    SELECT melt_id, furnace_code, product_code, start_ts,
           LAG(product_code) OVER w AS prev_product,
           LAG(end_ts)       OVER w AS prev_end
    FROM melts
    WINDOW w AS (PARTITION BY furnace_code ORDER BY start_ts, melt_id)
),
numbered AS (
    SELECT melt_id, furnace_code,
           SUM(CASE WHEN prev_product = product_code
                     AND start_ts <= prev_end + INTERVAL 30 DAY THEN 0 ELSE 1 END)
             OVER (PARTITION BY furnace_code ORDER BY start_ts, melt_id
                   ROWS UNBOUNDED PRECEDING) AS run_no
    FROM ordered
)
UPDATE melts m
JOIN numbered n ON n.melt_id = m.melt_id
SET m.run_id = CONCAT(n.furnace_code, '-', LPAD(n.run_no, 4, '0'));

SELECT COUNT(*) AS melts, COUNT(run_id) AS with_run_id, COUNT(DISTINCT run_id) AS runs
FROM melts;


-- ── 3. The derived table ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS quality_by_code (
  melt_id        INT UNSIGNED  NOT NULL,
  decision_code  VARCHAR(10)   NOT NULL,
  qty_kg         DECIMAL(12,1) NOT NULL,
  lots           SMALLINT UNSIGNED NOT NULL,
  PRIMARY KEY (melt_id, decision_code),
  KEY ix_qbc_code (decision_code)
) ENGINE=InnoDB COMMENT='derived from quality_lots, rebuilt by refresh_quality_by_code()';


-- ── 4. The refresh, all or nothing ──────────────────────────────────────────
-- DELETE, not TRUNCATE: TRUNCATE is DDL in MySQL and commits implicitly, so a
-- failed check could no longer roll it back. The reconciliation runs INSIDE
-- the transaction; if the breakdown does not add up to the lots it came
-- from, SIGNAL raises an error, the handler rolls back, and the table keeps
-- yesterday's correct content instead of today's wrong one.
DROP PROCEDURE IF EXISTS refresh_quality_by_code;
DELIMITER //
CREATE PROCEDURE refresh_quality_by_code()
BEGIN
  DECLARE mismatches INT DEFAULT 0;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;          -- the caller still sees the original error
  END;

  START TRANSACTION;

  DELETE FROM quality_by_code;

  INSERT INTO quality_by_code (melt_id, decision_code, qty_kg, lots)
  SELECT l.melt_id, l.decision_code, SUM(l.qty_kg), COUNT(*)
  FROM quality_lots l
  JOIN melts m ON m.melt_id = l.melt_id        -- lots of unknown orders stay out
  GROUP BY l.melt_id, l.decision_code;

  -- Every known melt's breakdown must sum to its lots, to half a kilogram.
  SELECT COUNT(*) INTO mismatches
  FROM (SELECT melt_id, SUM(qty_kg) AS q FROM quality_by_code GROUP BY melt_id) a
  RIGHT JOIN (SELECT l.melt_id, SUM(l.qty_kg) AS q
              FROM quality_lots l JOIN melts m ON m.melt_id = l.melt_id
              GROUP BY l.melt_id) b ON b.melt_id = a.melt_id
  WHERE a.melt_id IS NULL OR ABS(a.q - b.q) > 0.5;

  IF mismatches > 0 THEN
    SIGNAL SQLSTATE '45000'
      SET MESSAGE_TEXT = 'quality_by_code does not reconcile with quality_lots - rolled back';
  END IF;

  COMMIT;
END //
DELIMITER ;


-- ── 5. Run it twice and prove nothing changed the second time ───────────────
CALL refresh_quality_by_code();
SELECT COUNT(*)                                                     AS rows_after_1st,
       ROUND(SUM(qty_kg))                                           AS kg,
       BIT_XOR(CRC32(CONCAT_WS('|', melt_id, decision_code, qty_kg, lots))) AS checksum
FROM quality_by_code;

CALL refresh_quality_by_code();
SELECT COUNT(*)                                                     AS rows_after_2nd,
       ROUND(SUM(qty_kg))                                           AS kg,
       BIT_XOR(CRC32(CONCAT_WS('|', melt_id, decision_code, qty_kg, lots))) AS checksum
FROM quality_by_code;
-- Both lines must be identical. BIT_XOR of per-row CRC32 is order-independent,
-- so it compares content, not the order rows happened to be read in.


-- ── 6. What the new table is for ────────────────────────────────────────────
-- The breakdown by code per run: with runs and codes both persisted, "which
-- runs produced re-melt material" is now a plain join.
SELECT m.run_id,
       MIN(m.product_code)                                          AS product,
       COUNT(DISTINCT m.melt_id)                                    AS melts,
       ROUND(SUM(CASE WHEN q.decision_code = 'REMELT' THEN q.qty_kg END) / 1000, 1) AS remelt_t,
       ROUND(SUM(q.qty_kg) / 1000, 1)                               AS decided_t
FROM melts m
JOIN quality_by_code q ON q.melt_id = m.melt_id
GROUP BY m.run_id
HAVING remelt_t IS NOT NULL
ORDER BY remelt_t DESC
LIMIT 10;


-- ── 7. Proving the guard: break it on purpose ───────────────────────────────
-- Commented out because the failing CALL stops a batch run. To try it, run
-- these lines by hand. A trigger adds 1 kg to every inserted row, so the
-- reconciliation must fail — and the table must keep its previous content.
--
--   CREATE TRIGGER tmp_break BEFORE INSERT ON quality_by_code
--     FOR EACH ROW SET NEW.qty_kg = NEW.qty_kg + 1;
--   CALL refresh_quality_by_code();
--     -> ERROR 1644 (45000): quality_by_code does not reconcile with
--        quality_lots - rolled back
--   SELECT COUNT(*), ROUND(SUM(qty_kg)),
--          BIT_XOR(CRC32(CONCAT_WS('|', melt_id, decision_code, qty_kg, lots)))
--   FROM quality_by_code;
--     -> the same row count, kilograms and checksum as in section 5
--   DROP TRIGGER tmp_break;

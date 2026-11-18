-- =====================================================================
--  MODULE 7 · Replay a month without disturbing the flow, then publish in one go
-- =====================================================================
--  A real case: a rule changes, a parsing bug gets fixed, and we have to
--  rebuild silver for October. Meanwhile, the daily flow keeps running
--  and the dashboards still read the old version.
--
--     bronze ──(isolated rebuild)──► silver.transaction__build
--                                         │ checks
--                                         ▼
--             REPLACE PARTITION: atomic switch to silver.transaction
-- =====================================================================


-- STEP 1 · A build table, a clone of the production table
--  CREATE TABLE … AS copies the structure (columns, engine, key), not the data.
CREATE OR REPLACE TABLE silver.transaction__build AS silver.transaction;


-- STEP 2 · The rebuild: we keep ONLY the latest version of each transaction
--  (argMax per transaction), straight from bronze. No MV fires, because we write
--  into __build and not into bronze. Production is not touched.
--  Watch out: this GROUP BY covers ~8 M keys and needs memory.
--  In Cloud, beyond half the RAM, ClickHouse spills to disk instead of
--  failing: slower, but no error.
INSERT INTO silver.transaction__build
SELECT
    card_id, channel, ts, txn_ref,
    argMax(amount_eur, version), argMax(merchant_id, version), argMax(stage, version), max(version)
FROM
(
    SELECT
        toUInt64(r.cardId) AS card_id, c.channel AS channel, parseDateTimeBestEffort(t.ts, 'UTC') AS ts,
        toUInt64(t.ref) AS txn_ref, toDecimal64(t.amount, 2) AS amount_eur, toUInt32(t.merchantId) AS merchant_id,
        r.stage AS stage, ingested_at AS version
    FROM bronze.raw_flows
    ARRAY JOIN JSONExtract(payload, 'records',
        'Array(Tuple(cardId String, stage String, channels Array(Tuple(channel String, txns Array(Tuple(ts String, amount String, merchantId String, ref String))))))') AS r
    ARRAY JOIN r.channels AS c
    ARRAY JOIN c.txns     AS t
    WHERE flow_code = 'CLEARING' AND toDecimal64OrNull(t.amount, 2) IS NOT NULL
)
WHERE toYYYYMM(ts) = 202610
GROUP BY card_id, channel, ts, txn_ref;


-- STEP 3 · Checks before publishing
--  We compare the rebuild with deduplicated production (FINAL): row count AND total amount.
--  We only publish if both match. The 3rd column shows the physical duplicates in prod.
SELECT
    (SELECT (count(), sum(amount_eur)) FROM silver.transaction FINAL WHERE toYYYYMM(ts) = 202610)  AS prod_deduplicated,
    (SELECT (count(), sum(amount_eur)) FROM silver.transaction__build)                              AS rebuild,
    (SELECT count() FROM silver.transaction WHERE toYYYYMM(ts) = 202610)                            AS prod_rows_before_merges,
    if(prod_deduplicated = rebuild, 'OK, ready to publish', 'FAIL, mismatch: do not publish')       AS verdict
SETTINGS select_sequential_consistency = 1;


-- STEP 4 · Atomic publish: the prod partition is replaced in one go
--  Readers see the old version, then the new one. Never a mix.
--  REPLACE PARTITION does not copy data: it attaches the parts of __build
--  to the production table. That is why it takes less than a second.
--  Both tables must have exactly the same structure.
ALTER TABLE silver.transaction REPLACE PARTITION 202610 FROM silver.transaction__build;

SELECT count() AS prod_rows_after_publish
FROM silver.transaction
WHERE toYYYYMM(ts) = 202610
SETTINGS select_sequential_consistency = 1;
-- What to look for: the count equals the rebuild. The table is compact, no more physical
-- duplicates, and all that without OPTIMIZE TABLE … FINAL.

DROP TABLE silver.transaction__build;


-- STEP 5 · Recompute gold: a simple refresh
--  Thanks to DEPENDS ON (module 5), the per-issuer summary follows automatically.
SYSTEM REFRESH VIEW gold.rmv_category_day_spend;
SYSTEM WAIT VIEW gold.rmv_category_day_spend;


-- STEP 6 · Swap two tables in one go: EXCHANGE TABLES
--  Example: a new version of a gold table, built alongside the old one.
--  EXCHANGE TABLES swaps the names of the two tables in a single atomic operation:
--  no reader ever sees an empty or half-filled table.
CREATE OR REPLACE TABLE gold.category_day_spend__v2 AS gold.category_day_spend;
INSERT INTO gold.category_day_spend__v2 SELECT * FROM gold.category_day_spend;
EXCHANGE TABLES gold.category_day_spend AND gold.category_day_spend__v2;
DROP TABLE gold.category_day_spend__v2;


-- STEP 7 · Pause a view during a heavy operation
--  SYSTEM STOP VIEW suspends scheduled refreshes, SYSTEM START resumes them.
--  What to look for: the status switches to Disabled, then comes back.
SYSTEM STOP VIEW gold.rmv_limit_alerts;
SELECT view, status FROM system.view_refreshes WHERE view = 'rmv_limit_alerts';
SYSTEM START VIEW gold.rmv_limit_alerts;

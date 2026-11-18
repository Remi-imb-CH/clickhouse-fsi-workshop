-- =====================================================================
--  MODULE 3 · File resends and adjustments: ReplacingMergeTree
-- =====================================================================
--  In real life: a file is sent twice, a CLEARED transaction is adjusted
--  a few days later. What does silver do?
-- =====================================================================


-- The card we will follow (sim_card_id turns a number into a card identifier)
SELECT sim_card_id(648) AS tracked_card;


-- STEP 1 · A file is resent unchanged, 3 days later
INSERT INTO bronze.raw_flows
SELECT
    replaceOne(file_name, '_488903_', '_488903_RESEND_') AS file_name,
    flow_code,
    ingested_at + INTERVAL 3 DAY                          AS ingested_at,
    payload
FROM bronze.raw_flows
WHERE flow_code = 'CLEARING'
  AND file_name LIKE 'SCHEME_CLEARING_DETAIL_100280_%';   -- batch 0 of October 15 (Lumière Banque)

--  The transactions are now duplicated on disk…
--  What to look for: twice as many rows as distinct transactions. Nothing was overwritten at INSERT.
SELECT count() AS row_count, uniqExact(txn_ref) AS distinct_transactions
FROM silver.transaction
WHERE card_id = sim_card_id(648) AND day = '2026-10-15';


-- STEP 2 · Three ways to read WITHOUT duplicates
--  a) FINAL: ClickHouse deduplicates at read time.
--     Simple and correct. It costs a bit more than a normal read, especially
--     without a filter: keep it for filtered queries, or for gold tables.
SELECT count() AS row_count
FROM silver.transaction FINAL
WHERE card_id = sim_card_id(648) AND day = '2026-10-15';

--  b) argMax(value, version): the value of the row with the highest version.
--     Same result as FINAL, written by hand.
SELECT toTimeZone(ts, 'Europe/Paris') AS local_time, txn_ref, argMax(amount_eur, version) AS amount_eur
FROM silver.transaction
WHERE card_id = sim_card_id(648) AND day = '2026-10-15'
GROUP BY local_time, txn_ref
ORDER BY local_time;

--  c) Let the merges clean up: they deduplicate in the background,
--     with no guaranteed timing. We do NOT call OPTIMIZE TABLE … FINAL: it rewrites
--     the whole partition (rule insert-optimize-avoid-final). FINAL at read time is enough.


-- STEP 3 · An adjustment: the scheme republishes the 15th as ADJUSTED
INSERT INTO bronze.raw_flows
SELECT
    replaceOne(file_name, '_488903_', '_488903_ADJUSTMENT_'),
    flow_code,
    ingested_at + INTERVAL 5 DAY,
    replaceAll(payload, '"stage":"CLEARED"', '"stage":"ADJUSTED"')
FROM bronze.raw_flows
WHERE flow_code = 'CLEARING'
  AND file_name LIKE 'SCHEME_CLEARING_DETAIL_100280_488903_2%';

SELECT stage, count() AS transactions, max(version) AS kept_version
FROM silver.transaction FINAL
WHERE card_id = sim_card_id(648) AND day = '2026-10-15'
GROUP BY stage;
-- What to look for: a single visible version, ADJUSTED replaced CLEARED, without any UPDATE.
-- This is the ClickHouse way to correct data: reinsert a more recent version
-- (rule insert-mutation-avoid-update).


-- STEP 4 · The trap to know about (we come back to it in module 5)
--  An MV sees the INSERTs, not the deduplicated state. A sum computed by an
--  MV would count the resent file twice. Idempotent aggregates
--  (max, min, uniq) are not affected. Sums are.

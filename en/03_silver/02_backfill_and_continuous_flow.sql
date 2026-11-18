-- =====================================================================
--  MODULE 3 · Backfilling the history, then the continuous flow
-- =====================================================================


-- STEP 1 · Backfill: replay bronze through the MVs, with one INSERT … SELECT
--  We run the MV query ourselves, over the whole bronze history.
--  Watch out: do this AFTER creating the MV, otherwise files arriving in
--  between would be lost. Here bronze receives nothing during the operation.
INSERT INTO silver.transaction
SELECT
    toUInt64(r.cardId), c.channel, parseDateTimeBestEffort(t.ts, 'UTC'), toUInt64(t.ref),
    toDecimal64(t.amount, 2), toUInt32(t.merchantId), r.stage, ingested_at
FROM bronze.raw_flows
ARRAY JOIN JSONExtract(payload, 'records',
    'Array(Tuple(cardId String, stage String, channels Array(Tuple(channel String, txns Array(Tuple(ts String, amount String, merchantId String, ref String))))))') AS r
ARRAY JOIN r.channels AS c
ARRAY JOIN c.txns     AS t
WHERE flow_code = 'CLEARING' AND toDecimal64OrNull(t.amount, 2) IS NOT NULL;
-- What to look for: ~8 million transactions extracted from the JSON. Check the rows/s speed
-- at the bottom of the console: all the JSON parsing happens inside the database.

INSERT INTO silver.rejects
SELECT ingested_at, file_name, flow_code, r.cardId, t.ts, t.ref, t.amount, 'non-numeric amount'
FROM bronze.raw_flows
ARRAY JOIN JSONExtract(payload, 'records', 'Array(Tuple(cardId String, channels Array(Tuple(txns Array(Tuple(ts String, amount String, ref String))))))') AS r
ARRAY JOIN r.channels AS c
ARRAY JOIN c.txns     AS t
WHERE flow_code = 'CLEARING' AND toDecimal64OrNull(t.amount, 2) IS NULL;

INSERT INTO silver.daily_settlement
SELECT toUInt64(r.cardId), c.channel, toDate(t.d), toUInt16(t.count), toDecimal64(t.amount, 2), r.stage, ingested_at
FROM bronze.raw_flows
ARRAY JOIN JSONExtract(payload, 'records', 'Array(Tuple(cardId String, stage String, channels Array(Tuple(channel String, totals Array(Tuple(d String, count String, amount String))))))') AS r
ARRAY JOIN r.channels AS c
ARRAY JOIN c.totals   AS t
WHERE flow_code = 'SETTLEMENT';

INSERT INTO silver.daily_auth
SELECT toUInt64(r.cardId), toDate(r.period.startDate), toDecimal64(r.authorized.amount, 2), parseDateTimeBestEffort(r.authorized.peakTs, 'UTC'), ingested_at
FROM bronze.raw_flows
ARRAY JOIN JSONExtract(payload, 'records', 'Array(Tuple(cardId String, period Tuple(startDate String), authorized Tuple(peakTs String, amount String)))') AS r
WHERE flow_code = 'AUTH';

SELECT
    (SELECT count() FROM silver.transaction)       AS transactions,
    (SELECT count() FROM silver.daily_settlement)  AS settlement_rows,
    (SELECT count() FROM silver.daily_auth)        AS auth_rows,
    (SELECT count() FROM silver.rejects)           AS rejects;


-- STEP 2 · The continuous flow: October 31 arrives
--  We insert ONLY into bronze. Watch silver fill up on its own.
--  The whole chain fires: bronze → MV → silver → MV (module 5) → gold.
SELECT count() AS transactions_before FROM silver.transaction WHERE day = '2026-10-31';

INSERT INTO bronze.raw_flows
SELECT * FROM simulator.clearing_files(start = 600, n = 20);

INSERT INTO bronze.raw_flows
SELECT * FROM simulator.settlement_files(start = 600, n = 20);

INSERT INTO bronze.raw_flows
SELECT * FROM simulator.auth_files(start = 600, n = 20);

SELECT count() AS transactions_after FROM silver.transaction WHERE day = '2026-10-31';
-- What to look for: the number of transactions for the 31st (a Saturday) goes from 0 to ~380,000.
-- Whatever the source of the INSERT into bronze, the materialized views propagate it.


-- STEP 3 · What compression does to the transactions
--  What to look for: bronze (JSON) weighs megabytes per file, silver a few bytes
--  per transaction. The typed columnar format is the real win.
SELECT
    table,
    formatReadableQuantity(sum(rows))                                AS row_count,
    formatReadableSize(sum(data_uncompressed_bytes))                 AS raw,
    formatReadableSize(sum(data_compressed_bytes))                   AS on_disk,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 1) AS ratio,
    round(sum(data_compressed_bytes) / sum(rows), 2)                 AS bytes_per_row
FROM system.parts
WHERE database IN ('bronze', 'silver') AND active
GROUP BY table
ORDER BY sum(data_compressed_bytes) DESC;

--  Per column (sizes are readable thanks to min_bytes_for_wide_part = 0, see module 1).
--  What to look for: channel, stage, version and card_id cost almost nothing thanks to
--  sorting and codecs; txn_ref and amount_eur, which are random by nature, weigh the most.
SELECT name, type, compression_codec,
       formatReadableSize(data_compressed_bytes) AS on_disk,
       round(data_uncompressed_bytes / data_compressed_bytes, 1) AS ratio
FROM system.columns
WHERE database = 'silver' AND table = 'transaction'
ORDER BY data_compressed_bytes DESC;


-- CHECKPOINT
--  More than 7.5 M transactions, 3,100,000 AUTH rows (100,000 cards × 31 days) and the 31st delivered by the flow.
SELECT
    if((SELECT count() FROM silver.transaction) > 7500000, 'OK', 'FAIL')        AS transactions,
    if((SELECT count() FROM silver.daily_settlement) > 3000000, 'OK', 'FAIL')   AS settlement,
    if((SELECT count() FROM silver.daily_auth) = 3100000, 'OK', 'FAIL')         AS auth,
    if((SELECT count() FROM silver.transaction WHERE day = '2026-10-31') > 250000, 'OK', 'FAIL') AS continuous_flow
SETTINGS select_sequential_consistency = 1;   -- read the latest version, whichever replica serves it

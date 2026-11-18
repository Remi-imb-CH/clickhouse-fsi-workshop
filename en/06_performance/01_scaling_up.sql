-- =====================================================================
--  MODULE 6 · Scaling up: 1 million cards, 1.5 billion transactions
-- =====================================================================
--  So far: 100,000 cards over one month. Now we move to the simulator's full
--  portfolio over a full year:
--  1,000,000 cards × 1,488 payments (about 4 a day, from November 2025
--  to October 2026) = 1,488,000,000 transactions.
--  We write straight into silver (skipping the JSON) to measure ClickHouse's
--  raw write and read speed.
--
--  The console gives up on a statement after ~60 s. So we insert in
--  8 batches of 125,000 cards (186 M transactions each), one statement per batch.
-- =====================================================================


-- STEP 1 · The table (same model as silver.transaction)
--  We declare two accelerators right away, measured in the next file:
--    · a PROJECTION: a pre-aggregated copy per hour, which ClickHouse
--      keeps up to date on every INSERT, like an index that already holds the sums;
--    · a minmax SKIP INDEX: for each granule (8,192 rows), the min and the
--      max of amount_eur. An "amount_eur > X" query skips the granules whose max
--      is below X without reading them (rule query-index-skipping-indices).
--  Declaring them BEFORE loading costs a little time on insert.
--  Adding them AFTER (ALTER … MATERIALIZE) rewrites the whole table: see 02.
CREATE OR REPLACE TABLE silver.transaction_xl
(
    card_id      UInt64,
    channel      LowCardinality(String),
    ts           DateTime('UTC') CODEC(Delta, ZSTD(1)),
    amount_eur   Decimal(12, 2)  CODEC(ZSTD(1)),
    merchant_id  UInt32          CODEC(ZSTD(1)),
    INDEX idx_amount amount_eur TYPE minmax GRANULARITY 1,
    PROJECTION p_hourly_spend (SELECT toStartOfHour(ts), sum(amount_eur), count() GROUP BY toStartOfHour(ts))
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (channel, card_id, ts);   -- lowest to highest cardinality: 2 values, then the card, then time


-- STEP 2 · The generator, stored in a parameterized view
--  Transaction no. k: card no. k / 1488, payment no. k % 1488 of that card,
--  spread evenly over the 365 days. The amount follows the day of the week
--  (more on Saturday, less on Sunday).
--  numbers_mt is the parallel version of numbers(): blocks of numbers
--  are produced and transformed on all the replica's cores at the same time.
CREATE OR REPLACE VIEW simulator.xl_txns AS
WITH
    sim_card_id(intDiv(number, 1488))                                                             AS id,
    toDate('2025-11-01') + intDiv((number % 1488) * 365, 1488)                                    AS d,
    cityHash64(id, number % 1488, 'xl')                                                           AS seed,
    dictGet('simulator.dict_card', ('segment', 'daily_limit_eur', 'ecom_share', 'first_merchant', 'n_merchants'), id) AS a,
    sim_is_ecom(seed, a.3)                                                                        AS is_ecom
SELECT
    id                                                      AS card_id,
    if(is_ecom, 'ECOM', 'POS')                              AS channel,
    sim_txn_ts(seed, a.1, is_ecom, d)                       AS ts,
    toDecimal64(toUInt64(sim_amount(seed, a.1, a.2) * [1., 1., 1., 1., 1.1, 1.3, 0.7][toDayOfWeek(d)]), 2) / 100 AS amount_eur,
    sim_merchant(seed, is_ecom, a.4, a.5)                   AS merchant_id
FROM numbers_mt({start:UInt64} * 1488, {n:UInt64} * 1488);


-- STEP 3 · 1.5 billion transactions, in 8 INSERT … SELECT
--  Large batches = few parts = few merges (rule insert-batch-size).
--  max_insert_threads = 8: 8 parallel write streams on the replica.
--  An INSERT runs on ONE replica: its speed depends on that replica's cores.
INSERT INTO silver.transaction_xl SELECT * FROM simulator.xl_txns(start = 0,      n = 125000) SETTINGS max_insert_threads = 8;
INSERT INTO silver.transaction_xl SELECT * FROM simulator.xl_txns(start = 125000, n = 125000) SETTINGS max_insert_threads = 8;
INSERT INTO silver.transaction_xl SELECT * FROM simulator.xl_txns(start = 250000, n = 125000) SETTINGS max_insert_threads = 8;
INSERT INTO silver.transaction_xl SELECT * FROM simulator.xl_txns(start = 375000, n = 125000) SETTINGS max_insert_threads = 8;
INSERT INTO silver.transaction_xl SELECT * FROM simulator.xl_txns(start = 500000, n = 125000) SETTINGS max_insert_threads = 8;
INSERT INTO silver.transaction_xl SELECT * FROM simulator.xl_txns(start = 625000, n = 125000) SETTINGS max_insert_threads = 8;
INSERT INTO silver.transaction_xl SELECT * FROM simulator.xl_txns(start = 750000, n = 125000) SETTINGS max_insert_threads = 8;
INSERT INTO silver.transaction_xl SELECT * FROM simulator.xl_txns(start = 875000, n = 125000) SETTINGS max_insert_threads = 8;
-- What to look for: at the bottom of the console, the rows/s of each batch. Every transaction is
-- computed (dictGet + a dozen hashes), sorted by the ORDER BY, compressed, then written to object storage.
-- If a batch comes close to 60 s on a smaller service, split it in two (n = 62500).


-- STEP 4 · How much it weighs
SELECT
    formatReadableQuantity(sum(rows))                                AS transactions,
    formatReadableSize(sum(data_uncompressed_bytes))                 AS raw,
    formatReadableSize(sum(data_compressed_bytes))                   AS on_disk,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 1) AS ratio,
    round(sum(data_compressed_bytes) / sum(rows), 2)                 AS bytes_per_transaction
FROM system.parts
WHERE database = 'silver' AND table = 'transaction_xl' AND active
SETTINGS select_sequential_consistency = 1;
-- What to look for: a "raw" transaction (8 + 1 + 4 + 8 + 4 bytes) weighs 25 bytes,
-- compression divides it several times over.

--  Column by column: here the parts are over 1 GB, so they are "wide"
--  (one column = one file) and system.parts_columns gives their size.
SELECT
    column,
    formatReadableSize(sum(column_data_compressed_bytes))   AS on_disk,
    round(sum(column_data_uncompressed_bytes) / sum(column_data_compressed_bytes), 1) AS ratio
FROM system.parts_columns
WHERE database = 'silver' AND table = 'transaction_xl' AND active
  AND NOT startsWith(column, '_')          -- internal technical columns
GROUP BY column
ORDER BY sum(column_data_compressed_bytes) DESC;
-- What to look for: channel (LowCardinality) costs almost nothing, and neither does card_id,
-- because rows are sorted by card. The bulk is what is random by nature: the amount,
-- the merchant, and the exact second of the payment.

--  At the scale of a large issuer (20 M cards × 365 days × 4 payments ≈ 29 billion a year):
SELECT formatReadableSize(29e9 * (
    SELECT sum(data_compressed_bytes) / sum(rows) FROM system.parts
    WHERE database = 'silver' AND table = 'transaction_xl' AND active)) AS one_year_of_transactions_estimate;
-- What to look for: a few hundred GB for a full year of transactions for 20 M cards.


-- CHECKPOINT
--  1,488,000,000 transactions expected (8 batches of 186,000,000).
SELECT
    if((SELECT count() FROM silver.transaction_xl) = 1488000000, 'OK', 'FAIL') AS xl_transactions
SETTINGS select_sequential_consistency = 1;

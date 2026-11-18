-- =====================================================================
--  MODULE 3 · Silver: typed, clean, deduplicated transactions
-- =====================================================================
--  Bronze (1 row = 1 file)  ──MV──►  Silver (1 row = 1 transaction)
--  A materialized view (MV) is an INSERT TRIGGER: every block inserted
--  into bronze is transformed and written to silver, on the fly.
--  It never recomputes existing data: it only processes the new rows,
--  at INSERT time. You pay the cost once, at write time.
-- =====================================================================


-- STEP 1 · The transaction table
--  ReplacingMergeTree: for a given key (channel, card_id, ts, txn_ref), the row with
--  the most recent version wins. Perfect for resends and adjustments.
--  The replacement happens during background merges, not at INSERT time:
--  in the meantime, both versions coexist on disk (we will see this in 03).
CREATE OR REPLACE TABLE silver.transaction
(
    card_id      UInt64,
    channel      LowCardinality(String),                        -- POS (in store) / ECOM (online)
    ts           DateTime('UTC')      CODEC(Delta, ZSTD(1)),    -- instant of the payment, in UTC. Delta stores the gap with the previous row
    txn_ref      UInt64,                                        -- the scheme's reference of the transaction
    amount_eur   Decimal(12, 2),                                -- Decimal: no rounding error on sums
    merchant_id  UInt32,
    stage        LowCardinality(String),                        -- CLEARED / ADJUSTED
    version      DateTime64(3, 'UTC') CODEC(Delta, ZSTD(1)),    -- file arrival: the most recent wins
    day          Date MATERIALIZED toDate(ts, 'Europe/Paris')   -- computed at insert: the business day, in local time
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(ts)                    -- one partition per month: few of them, bounded
ORDER BY (channel, card_id, ts, txn_ref)     -- lowest to highest cardinality: 2 values, then the card, then time
SETTINGS min_bytes_for_wide_part = 0;        -- one column = one file: we can read the compression per column


-- STEP 2 · The daily flows
--  Same principle: ReplacingMergeTree with the arrival date as the version.
CREATE OR REPLACE TABLE silver.daily_settlement
(
    card_id      UInt64,
    channel      LowCardinality(String),
    day          Date,
    txn_count    UInt16,
    amount_eur   Decimal(18, 2),
    stage        LowCardinality(String),
    version      DateTime64(3, 'UTC')
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(day)
ORDER BY (card_id, channel, day);

CREATE OR REPLACE TABLE silver.daily_auth
(
    card_id         UInt64,
    day             Date,
    authorized_eur  Decimal(18, 2),
    ts_peak         DateTime('UTC'),                              -- instant of the largest payment of the day
    version         DateTime64(3, 'UTC')
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(day)
ORDER BY (card_id, day);

--  Rejects: nothing is lost, nothing is blocked
--  An unreadable amount does not stop the load: it goes into this table,
--  with its source file, for analysis.
CREATE OR REPLACE TABLE silver.rejects
(
    ingested_at   DateTime64(3, 'UTC'),
    file_name     String,
    flow_code     LowCardinality(String),
    card_id       String,
    ts_text       String,
    txn_ref       String,
    raw_value     String,
    reason        LowCardinality(String)
)
ENGINE = MergeTree
ORDER BY (flow_code, ingested_at);


-- STEP 3 · The bronze → silver MV for transactions (CLEARING)
--  3 chained ARRAY JOINs: file → cards → channels → transactions.
--  A file of 5,000 cards thus produces ~14,000 silver rows.
--  "TO silver.transaction": the MV writes into a table we created ourselves
--  (we keep control over the engine, the key and the codecs).
CREATE OR REPLACE MATERIALIZED VIEW silver.mv_clearing TO silver.transaction AS
SELECT
    toUInt64(r.cardId)                        AS card_id,
    c.channel                                 AS channel,
    parseDateTimeBestEffort(t.ts, 'UTC')      AS ts,                -- "+02:00" (summer time) / "+01:00" (winter time) → UTC
    toUInt64(t.ref)                           AS txn_ref,
    toDecimal64(t.amount, 2)                  AS amount_eur,
    toUInt32(t.merchantId)                    AS merchant_id,
    r.stage                                   AS stage,
    ingested_at                               AS version
FROM bronze.raw_flows
ARRAY JOIN JSONExtract(payload, 'records',
    'Array(Tuple(cardId String, stage String, channels Array(Tuple(channel String, txns Array(Tuple(ts String, amount String, merchantId String, ref String))))))') AS r
ARRAY JOIN r.channels AS c
ARRAY JOIN c.txns     AS t
WHERE flow_code = 'CLEARING'
  AND toDecimal64OrNull(t.amount, 2) IS NOT NULL;   -- toDecimal64OrNull returns NULL instead of an error when the value is unreadable

--  A 2nd MV on the same source: it captures what the 1st one discards.
--  Several MVs can read the same table: each INSERT into bronze triggers all of them.
CREATE OR REPLACE MATERIALIZED VIEW silver.mv_clearing_rejects TO silver.rejects AS
SELECT
    ingested_at, file_name, flow_code,
    r.cardId AS card_id, t.ts AS ts_text, t.ref AS txn_ref, t.amount AS raw_value,
    'non-numeric amount' AS reason
FROM bronze.raw_flows
ARRAY JOIN JSONExtract(payload, 'records',
    'Array(Tuple(cardId String, channels Array(Tuple(txns Array(Tuple(ts String, amount String, ref String))))))') AS r
ARRAY JOIN r.channels AS c
ARRAY JOIN c.txns     AS t
WHERE flow_code = 'CLEARING'
  AND toDecimal64OrNull(t.amount, 2) IS NULL;


-- STEP 4 · The MVs for the daily flows (SETTLEMENT, AUTH)
CREATE OR REPLACE MATERIALIZED VIEW silver.mv_daily_settlement TO silver.daily_settlement AS
SELECT
    toUInt64(r.cardId)                        AS card_id,
    c.channel                                 AS channel,
    toDate(t.d)                               AS day,
    toUInt16(t.count)                         AS txn_count,
    toDecimal64(t.amount, 2)                  AS amount_eur,
    r.stage                                   AS stage,
    ingested_at                               AS version
FROM bronze.raw_flows
ARRAY JOIN JSONExtract(payload, 'records',
    'Array(Tuple(cardId String, stage String, channels Array(Tuple(channel String, totals Array(Tuple(d String, count String, amount String))))))') AS r
ARRAY JOIN r.channels AS c
ARRAY JOIN c.totals   AS t
WHERE flow_code = 'SETTLEMENT';

--  The AUTH file has one object per card, no nested array: a single ARRAY JOIN is enough.
CREATE OR REPLACE MATERIALIZED VIEW silver.mv_daily_auth TO silver.daily_auth AS
SELECT
    toUInt64(r.cardId)                                  AS card_id,
    toDate(r.period.startDate)                          AS day,
    toDecimal64(r.authorized.amount, 2)                 AS authorized_eur,
    parseDateTimeBestEffort(r.authorized.peakTs, 'UTC') AS ts_peak,
    ingested_at                                         AS version
FROM bronze.raw_flows
ARRAY JOIN JSONExtract(payload, 'records',
    'Array(Tuple(cardId String, period Tuple(startDate String), authorized Tuple(peakTs String, amount String)))') AS r
WHERE flow_code = 'AUTH';


-- STEP 5 · Surprise: silver is empty!
SELECT
    (SELECT count() FROM silver.transaction)       AS transactions,
    (SELECT count() FROM silver.daily_settlement)  AS settlement_rows,
    (SELECT count() FROM silver.daily_auth)        AS auth_rows;
-- What to look for: an MV only sees the INSERTs that arrive AFTER it was created.
--    Files already in bronze must be "replayed": that is the backfill.
--    This is by design: creating an MV on a 1 TB table blocks nothing.

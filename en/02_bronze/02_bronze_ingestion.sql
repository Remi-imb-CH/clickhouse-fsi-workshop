-- =====================================================================
--  MODULE 2 · Bronze: the JSON files as they arrive
-- =====================================================================
--  Golden rule of bronze: store the raw data, transform nothing.
--  One row = one received file (5,000 cards, 1 day).
--  Volume: 100,000 cards × 31 days, flows CLEARING (every transaction),
--  SETTLEMENT (daily totals), AUTH (daily authorized amount)
--  Receivers: the 6 issuing banks (12 batches for Lumière Banque, 2 for Rheingold Bank…)
--
--  Why keep the raw data? If a parsing rule changes or a bug is
--  fixed, everything can be rebuilt from bronze (module 7), without asking
--  the card scheme for the files again.
-- =====================================================================


-- STEP 1 · The bronze table
CREATE OR REPLACE TABLE bronze.raw_flows
(
    file_name    String,
    flow_code    LowCardinality(String),        -- CLEARING / SETTLEMENT / AUTH
    ingested_at  DateTime64(3, 'UTC'),          -- arrival time of the file
    payload      String CODEC(ZSTD(3))          -- the raw JSON. ZSTD(3) compresses harder than the default (LZ4): ideal for rarely re-read text
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ingested_at)              -- one partition per month: few of them, easy to purge (TTL, module 7)
ORDER BY (flow_code, ingested_at, file_name);   -- bronze is re-read by flow, then by arrival date


-- STEP 2 · A single day of CLEARING (20 files, ~270,000 transactions)
--  The generator is the parameterized view simulator.clearing_files (previous file).
--  You call it like a function. What it does, from the inside out:
--    numbers(start, n)    → n files (batches of 5,000 cards)
--    dictGet              → segment, daily limit, online share of each card
--    arrayMap             → for each card, its transactions of the day
--    CAST + toJSONString  → the final JSON file, with the field names of the source format
--  The view produces the files 2 at a time (SETTINGS max_block_size = 2 in its definition):
--  each file weighs ~2 MB of JSON, so memory stays low whatever the number of files.
INSERT INTO bronze.raw_flows
SELECT * FROM simulator.clearing_files(start = 0, n = 20);

--  What did we receive? length() gives the size of the JSON in bytes.
SELECT flow_code, count() AS files, formatReadableSize(sum(length(payload))) AS json_volume
FROM bronze.raw_flows
GROUP BY flow_code;

--  A file, exactly as it was received
SELECT file_name, ingested_at, substring(payload, 1, 600) AS json_start
FROM bronze.raw_flows
LIMIT 1;


-- STEP 3 · The rest of the month: days 2 to 30 (580 files, ~8 million transactions)
--  Same view, another range. Day 31 is kept for module 3.
--  A single INSERT of 580 files rather than 580 small INSERTs: each INSERT
--  creates a part, and a few large parts are cheaper to merge
--  (rule insert-batch-size).
INSERT INTO bronze.raw_flows
SELECT * FROM simulator.clearing_files(start = 20, n = 580);
-- What to look for: the duration covers generating AND writing ~1.3 GB of JSON.


-- STEP 4 · The daily flows: SETTLEMENT (totals) and AUTH (authorized amount)
INSERT INTO bronze.raw_flows
SELECT * FROM simulator.settlement_files(start = 0, n = 600);

INSERT INTO bronze.raw_flows
SELECT * FROM simulator.auth_files(start = 0, n = 600);


-- STEP 5 · Ingestion summary
SELECT
    flow_code,
    count()                                                        AS files,
    min(ingested_at)                                               AS first_seen,
    max(ingested_at)                                               AS last_seen,
    formatReadableSize(sum(length(payload)))                       AS raw_json
FROM bronze.raw_flows
GROUP BY flow_code
ORDER BY flow_code;

--  How much does it really weigh on disk? (ZSTD compression of the JSON)
--  What to look for: the JSON is very repetitive (same keys, same dates): it
--  compresses several times over, even though amounts and references are random.
SELECT
    formatReadableSize(sum(data_uncompressed_bytes))                 AS raw,
    formatReadableSize(sum(data_compressed_bytes))                   AS on_disk,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 1) AS ratio
FROM system.parts
WHERE database = 'bronze' AND table = 'raw_flows' AND active;

--  The parts created by our INSERTs
--  The name of a part (202610_0_5_1) gives the partition, the block range and the
--  merge level. Rerun the query in a minute: background merges
--  will have reduced their number.
SELECT partition, name, rows, formatReadableSize(bytes_on_disk) AS size, modification_time
FROM system.parts
WHERE database = 'bronze' AND table = 'raw_flows' AND active
ORDER BY modification_time;


-- CHECKPOINT MODULE 2
--  600 files per flow: 20 batches × 30 days (day 31 arrives in module 3).
SELECT
    if(countIf(flow_code = 'CLEARING') = 600, 'OK', 'FAIL')   AS clearing_600_files,
    if(countIf(flow_code = 'SETTLEMENT') = 600, 'OK', 'FAIL') AS settlement_600_files,
    if(countIf(flow_code = 'AUTH') = 600, 'OK', 'FAIL')       AS auth_600_files
FROM bronze.raw_flows
SETTINGS select_sequential_consistency = 1;   -- read the latest version, whatever the replica

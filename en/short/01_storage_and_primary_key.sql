-- =====================================================================
--  SHORT TRACK · 1/5 · How ClickHouse stores data: columns, parts, primary key
-- =====================================================================
--  Before this file, run these two files AS IS (Cmd + Enter, the whole tab):
--    · ../01_fundamentals/01_setup_and_reference_data.sql   (databases, 1 million cards)
--    · ../02_bronze/01_simulator.sql                        (the card payment simulator)
--  They create the reference data and the generator. Here we look at what was created.
--
--  How to use it: put the cursor inside a query and press Cmd + Shift + Enter.
--  At the bottom, the console shows the duration, the rows read and the volume read:
--  these are the three numbers to watch.
-- =====================================================================


-- STEP 1 · The table: 1 million cards, in a MergeTree
--  ORDER BY card_id is the primary key: it sets the order of the rows on disk
--  AND the index. It is chosen when the table is created and cannot be changed afterwards.
SHOW CREATE TABLE ref.card;

SELECT segment, product, count() AS cards, round(avg(daily_limit_eur)) AS avg_limit_eur
FROM ref.card
GROUP BY segment, product
ORDER BY cards DESC;


-- STEP 2 · Parts: what an INSERT writes
--  Each INSERT writes a "part": an immutable folder with one compressed file per column.
--  In the background, ClickHouse merges the parts together, hence the name MergeTree.
SELECT table, count() AS parts, sum(rows) AS row_count,
       formatReadableSize(sum(data_uncompressed_bytes)) AS raw,
       formatReadableSize(sum(data_compressed_bytes))   AS on_disk
FROM system.parts
WHERE database = 'ref' AND active
GROUP BY table
ORDER BY row_count DESC;


-- STEP 3 · Columns: each one is stored and compressed on its own
--  What to look for: the columns with few distinct values (issuer_id, segment, product,
--  declared LowCardinality) weigh almost nothing. The card number weighs the most.
SELECT name, type,
       formatReadableSize(data_uncompressed_bytes) AS raw,
       formatReadableSize(data_compressed_bytes)   AS on_disk,
       round(data_uncompressed_bytes / data_compressed_bytes, 1) AS ratio
FROM system.columns
WHERE database = 'ref' AND table = 'card'
ORDER BY data_compressed_bytes DESC;

--  A query only reads the columns it uses. Compare the volume read at the bottom of the console:
SELECT avg(daily_limit_eur) FROM ref.card;      -- 1 column read
SELECT * FROM ref.card FORMAT Null;             -- 8 columns read


-- STEP 4 · The sparse primary index: one entry every 8,192 rows (a "granule")
--  The index does not point to every row: it keeps the key of the first row of each granule.
--  It fits in memory even for billions of rows, and tells ClickHouse which granules to read.
SELECT * FROM ref.card WHERE card_id = 4000000000006899;     -- filter on the key
SELECT count() FROM ref.card WHERE city_code = 'FR-LYS';      -- filter off the key
-- What to look for: "rows read" at the bottom of the console. 8,192 rows for the first query
-- (one granule), 1,000,000 for the second (the whole table).

--  EXPLAIN indexes = 1 shows what the index eliminated, without running the query.
EXPLAIN indexes = 1
SELECT * FROM ref.card WHERE card_id = 4000000000006899;
-- What to look for: under "PrimaryKey", Granules: 1/123. One granule read out of 123.


-- CHECKPOINT 1/5
SELECT
    if((SELECT count() FROM ref.card) = 1000000, 'OK', 'FAIL')     AS cards,
    if((SELECT count() FROM ref.merchant) = 50000, 'OK', 'FAIL')   AS merchants,
    if((SELECT count() FROM system.functions WHERE name = 'sim_txn') = 1, 'OK', 'FAIL') AS simulator
SETTINGS select_sequential_consistency = 1;

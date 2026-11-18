-- =====================================================================
--  MODULE 2 · Exploring the raw JSON, without loading it anywhere else
-- =====================================================================


-- STEP 1 · JSON functions read the text directly
--  JSONExtract* walks through the text at read time, with no preparation at all.
--  Handy for exploring, but every query re-parses the whole JSON:
--  that is why we move to silver, with typed columns.
SELECT
    file_name,
    JSONExtractString(payload, 'header', 'flowCode')    AS source_flow_code,
    JSONExtractString(payload, 'header', 'receiverId')  AS issuer,
    JSONLength(payload, 'records')                      AS n_cards
FROM bronze.raw_flows
WHERE flow_code = 'CLEARING'
LIMIT 5;


-- STEP 2 · The native JSON type: ClickHouse discovers the structure on its own
--  payload::JSON converts the text to the JSON type: each path becomes
--  a typed subcolumn. Useful when the schema changes often (rule
--  schema-json-when-to-use). Here the source format is stable: we will prefer
--  regular columns in silver.
SELECT JSONAllPathsWithTypes(payload::JSON) AS detected_structure
FROM bronze.raw_flows
WHERE flow_code = 'AUTH'
LIMIT 1;

--  You navigate with dots, like in JavaScript.
--  .:`Array(JSON)` states the expected type for an array of objects.
SELECT
    j.header.flowCode                                     AS flow_code,
    arrayJoin(j.records.:`Array(JSON)`).cardId            AS card_id
FROM (SELECT payload::JSON AS j FROM bronze.raw_flows WHERE flow_code = 'AUTH' LIMIT 1)
LIMIT 5;


-- STEP 3 · Typed extraction: the key to moving to silver
--  We describe the expected shape, ClickHouse fills it in a single pass.
--  Then two ARRAY JOINs unfold the arrays: file → cards → channels.
--  This is exactly the query the materialized view will run in module 3.
SELECT
    r.cardId, r.stage, c.channel, length(c.txns) AS n_transactions
FROM
(
    SELECT JSONExtract(payload, 'records',
        'Array(Tuple(cardId String, stage String, channels Array(Tuple(channel String, txns Array(Tuple(ts String, amount String, merchantId String, ref String))))))') AS records
    FROM bronze.raw_flows
    WHERE flow_code = 'CLEARING'
    LIMIT 1
)
ARRAY JOIN records AS r
ARRAY JOIN r.channels AS c
LIMIT 10;


-- STEP 4 · How much do our INSERTs cost? (the query log)
--  system.query_log keeps one row per query: duration, rows, memory.
--  In Cloud, each replica has its own log: clusterAllReplicas()
--  queries all of them.
SELECT
    event_time,
    query_duration_ms / 1000                       AS seconds,
    written_rows                                   AS files_written,
    formatReadableSize(written_bytes)              AS written_size,
    formatReadableSize(memory_usage)               AS max_memory,
    substring(query, position(query, 'simulator.'), 45) AS source
FROM clusterAllReplicas('default', system.query_log)
WHERE type = 'QueryFinish'
  AND query_kind = 'Insert'
  AND has(tables, 'bronze.raw_flows')
  AND event_date = today()
ORDER BY event_time;
-- What to look for: the peak memory of each INSERT. It stays low
-- because the generator views only keep 2 files in memory at a time.

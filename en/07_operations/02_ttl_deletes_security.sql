-- =====================================================================
--  MODULE 7 · Lifecycle, targeted deletes, per-issuer security
-- =====================================================================


-- STEP 1 · TTL: old data is purged automatically
--  TTL is evaluated during merges. When a whole partition has expired,
--  it is dropped in one go: that is the point of partitioning by month
--  (rule schema-partition-lifecycle).
--  Here: the raw files are kept 5 years, the rejects 2 years. Set the durations
--  from your own retention policy.
--  Watch out: the simulated files are dated October 2026. A short TTL (90 days for example)
--  would purge them for real as soon as today's date is past it.
ALTER TABLE bronze.raw_flows MODIFY TTL toDateTime(ingested_at) + INTERVAL 5 YEAR;
ALTER TABLE silver.rejects  MODIFY TTL toDateTime(ingested_at) + INTERVAL 2 YEAR;
SHOW CREATE TABLE bronze.raw_flows;


-- STEP 2 · Targeted delete (e.g. a GDPR erasure request for one card)
--  Lightweight DELETE: the rows disappear from reads immediately.
--  They are masked first, then physically erased by the next merges.
--  To delete a lot of data at once, prefer DROP PARTITION
--  (rule insert-mutation-avoid-delete).
SELECT count() AS before FROM silver.transaction WHERE card_id = sim_card_id(999);
DELETE FROM silver.transaction WHERE card_id = sim_card_id(999);
SELECT count() AS after FROM silver.transaction WHERE card_id = sim_card_id(999);


-- STEP 3 · Fixing a value, in order of preference
--   1) reinsert a new version (ReplacingMergeTree, seen in module 3)
--   2) lightweight UPDATE (patch applied during merges)
--   3) ALTER … UPDATE (mutation: rewrites the parts, rare corrections only)
--  Here, a rare correction on a small reference table: a mutation is acceptable.
--  mutations_sync = 1 waits for the rewrite to finish before returning.
--  On the transaction table, we would rather reinsert an ADJUSTED version (module 3).
ALTER TABLE ref.card UPDATE product = 'DEBIT' WHERE product = 'PREPAID' AND daily_limit_eur >= 10000
SETTINGS mutations_sync = 1;
SELECT command, is_done, parts_to_do FROM system.mutations WHERE database = 'ref' ORDER BY create_time DESC LIMIT 1;


-- STEP 4 · Each issuing bank sees ONLY its own cards (row policies)
--  A row policy adds an invisible filter to every query of a role.
--  Security lives in the database: the front end does not have to add a WHERE,
--  and cannot forget it.
CREATE ROLE IF NOT EXISTS role_lumiere;
GRANT SELECT ON gold.* TO role_lumiere;

CREATE ROW POLICY OR REPLACE rp_lumiere_spend    ON gold.category_day_spend  USING issuer_id = '488903' TO role_lumiere;
CREATE ROW POLICY OR REPLACE rp_lumiere_curve    ON gold.issuer_curve        USING issuer_id = '488903' TO role_lumiere;
CREATE ROW POLICY OR REPLACE rp_lumiere_summary  ON gold.issuer_day_summary  USING issuer_id = '488903' TO role_lumiere;
CREATE ROW POLICY OR REPLACE rp_lumiere_alerts   ON gold.limit_alerts        USING issuer_id = '488903' TO role_lumiere;

SELECT short_name, database, table, select_filter, apply_to_list
FROM system.row_policies
WHERE database = 'gold';
-- What to look for: 4 rp_lumiere_* policies, all applied to role_lumiere, filtering
-- on Lumière Banque (issuer 488903).
--  In production: a user (or a front-end service account) is granted this role.
--    CREATE USER front_lumiere IDENTIFIED BY '…' DEFAULT ROLE role_lumiere;
--  It queries the same tables, but only sees Lumière Banque.

-- =====================================================================
--  RESET · Drops everything the workshop created (and nothing else)
-- =====================================================================
-- The row policies and the role from module 7 (they survive DROP DATABASE)
DROP ROW POLICY IF EXISTS rp_lumiere_spend   ON gold.category_day_spend;
DROP ROW POLICY IF EXISTS rp_lumiere_curve   ON gold.issuer_curve;
DROP ROW POLICY IF EXISTS rp_lumiere_summary ON gold.issuer_day_summary;
DROP ROW POLICY IF EXISTS rp_lumiere_alerts  ON gold.limit_alerts;
DROP ROLE IF EXISTS role_lumiere;
DROP DATABASE IF EXISTS gold SYNC;
DROP DATABASE IF EXISTS silver SYNC;
DROP DATABASE IF EXISTS bronze SYNC;
DROP DATABASE IF EXISTS simulator SYNC;
DROP DATABASE IF EXISTS ref SYNC;
DROP USER IF EXISTS dict_reader;
DROP FUNCTION IF EXISTS sim_issuer;
DROP FUNCTION IF EXISTS sim_card_id;
DROP FUNCTION IF EXISTS sim_random;
DROP FUNCTION IF EXISTS sim_u;
DROP FUNCTION IF EXISTS sim_z;
DROP FUNCTION IF EXISTS sim_day_count;
DROP FUNCTION IF EXISTS sim_day_seeds;
DROP FUNCTION IF EXISTS sim_is_ecom;
DROP FUNCTION IF EXISTS sim_txn_ts;
DROP FUNCTION IF EXISTS sim_amount;
DROP FUNCTION IF EXISTS sim_money;
DROP FUNCTION IF EXISTS sim_merchant;
DROP FUNCTION IF EXISTS sim_iso;
DROP FUNCTION IF EXISTS sim_txn;

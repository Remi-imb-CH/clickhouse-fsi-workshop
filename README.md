# ClickHouse from zero to advanced · Financial services workshop

A 5-hour hands-on workshop on **your own ClickHouse Cloud service**: one day of card payment clearing at an issuing bank,
from JSON files to bronze, silver and gold, then dashboards, an API and an AI agent.

Everything is **generated in SQL, inside ClickHouse**: no file to download, no bucket, no external tool.
The data is deterministic: everyone gets the same numbers, on any service.

| What | Where |
|---|---|
| The workshop, module by module | [en/README.md](en/README.md) |
| Volumes, results, and timings to measure | [en/RESULTS.md](en/RESULTS.md) |
| Dashboard, API and agent, step by step | [en/08_dashboards_agent/README.md](en/08_dashboards_agent/README.md) |

Quick start:

```bash
cd en
export CH_HOST=xxxx.eu-central-1.aws.clickhouse.cloud
export CH_PASSWORD='...'
./run_all.sh
```

## The story in one picture

```
 JSON CLEARING/SETTLEMENT/AUTH ──► bronze ──MV──► silver ──MV / refreshable views──► gold ──► dashboard
   (SQL simulator)            1 row          1 row            spend, 9am SLA, alerts,        API
                              = 1 file       = 1 transaction  reconciliation                 AI agent
```

- **1 million cards**, 50,000 merchants in 29 countries of Europe, the Middle East and Africa, 6 issuing banks
- **8.9 million transactions** received as 1,860 JSON files (2.6 GiB), then **1.5 billion transactions** written straight to silver
- The real-world problems of payment data, simulated on purpose: late files, resent files, adjustments,
  unreadable amounts, missing transactions, the 25-hour day of the clock change

The banks, merchants, cards and the "EMEA Card Switch" scheme are fictional. No real card number, no personal data.

## Credits

This workshop is the financial services edition of the
[ClickHouse energy workshop](https://github.com/Ochakri-CHDB/clickhouse-energie-workshop): same modules,
same ClickHouse features, another industry.

# Short track · ClickHouse essentials in 90 minutes

The same story as the full workshop (one day of card payment clearing at an issuing bank), cut down to the
concepts that matter most. Everything is generated in SQL inside ClickHouse: nothing to download.

| Time | Part | Concept | File | Hands-on |
|---|---|---|---|---|
| 0:00 | What is ClickHouse | column storage, the Cloud, where it is used | slides | |
| 0:10 | Setup | run two files as is | [`../01_fundamentals/01_setup_and_reference_data.sql`](../01_fundamentals/01_setup_and_reference_data.sql), then [`../02_bronze/01_simulator.sql`](../02_bronze/01_simulator.sql) | 3 min |
| 0:13 | **1** Storage | MergeTree, parts, compression, the sparse primary index | [`01_storage_and_primary_key.sql`](01_storage_and_primary_key.sql) | 12 min |
| 0:30 | **2** Ingestion | raw JSON in bronze, a materialized view, ReplacingMergeTree and FINAL | [`02_bronze_to_silver.sql`](02_bronze_to_silver.sql) | 15 min |
| 0:48 | **3** Serving | dictionaries, refreshable materialized views, a documented gold layer | [`03_dictionaries_and_gold.sql`](03_dictionaries_and_gold.sql) | 10 min |
| 1:00 | **4** Scale | 186 million transactions, primary key, parallel replicas, projection | [`04_scale_and_speed.sql`](04_scale_and_speed.sql) | 8 min |
| 1:08 | **5** Agent | create a ClickHouse agent, ask questions, have it build an app | [`05_agent.md`](05_agent.md) | 20 min |
| 1:28 | Wrap-up | best practices, where to go next | slides | |

Short on time? Part 4 can be skipped or shown by the trainer: part 5 only needs parts 1 to 3.

## How to run it

1. Create a ClickHouse Cloud service and open its SQL console (see [the main README](../README.md#before-the-session-20-min-the-day-before)).
2. **Setup**: open each of the two setup files, paste it into a new tab and run the whole tab with **Cmd + Enter**.
   They create the databases, 1 million cards, 50,000 merchants and the simulator, in a few seconds.
3. **Parts 1 to 4**: paste each file into a new tab and go query by query with **Cmd + Shift + Enter**.
   The `What to look for` comments say what to check. Each file ends with a checkpoint: a row of `OK`.

Every file is idempotent: run it again if a step was missed.

## What you get at the end

- 1.9 million transactions unfolded from 140 JSON files by a materialized view, about 20 bytes each
- a gold table of a few thousand rows that answers the dashboard in milliseconds
- 186 million transactions, where one card's statement reads a few thousand rows
- an AI agent that answers questions in plain English and builds an interactive app on your data

## Going further

The full 5-hour workshop adds the three flows and their reconciliation, the 9am SLA, limit alerts,
the clock change, replay and atomic publish, row policies, a dashboard, an API and an AI agent:
start at [`../README.md`](../README.md). The short track uses the same table names, so reset first
([`../reset.sql`](../reset.sql)) or just carry on with module 03 of the full workshop after re-running module 02.

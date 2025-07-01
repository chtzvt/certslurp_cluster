/*-----------------------------------------------------------------------
 Certificate-to-Technology Analytics Schema  –  2025-06-30
-----------------------------------------------------------------------

               CT logs → certslurp archives → ct_certificates
                                                            │
                    ┌───────────────────────────────────────┤ 1️⃣  Bloom + PSL
                    │           [mv_dns_flat]               │
                    │    (adds org_id, registrable, root)   ▼
┌─ tiny edit table  │     dict_tech_patterns  (HASHED dict)       ←── live reload
│   + versioning    └───────────────────────────────────────┐
                    │ 2️⃣  pattern match (token / regex)      │
                    ▼                                        │
        [mv_ct_tech_signals]  ──▶  tech_signals ◀─ Rails / scans / APIs
                                   ▲      ▲
                                   │ 3️⃣  │ bitmap merge
                                   │      │
                        [mv_org_tech]  (AggregatingMergeTree)
                                   │
                                   ▼
                          org_tech_facts  (read-only view)

Low-latency dictionaries
  • dict_tech_patterns 
  • dict_org_autocomplete   – distinct organisation strings
  • dict_org_roots          – org_id → root-domain list

Surrogate keys
  • org_id = UInt64  = sipHash64(norm_token_key(org_string))
    All heavy joins, group-bys and dictionaries use this hash.

________________________________________________________________________
TABLE & VIEW GLOSSARY
________________________________________________________________________

1)  ct_certificates  (MergeTree, raw ingest)
    • One row per *certificate* scraped by certslurp
    • Partition:  toYYYYMM(lts)   (append-only; lts = log timestamp)
    • ORDER BY:   (log, li)       (natural ingest order)
    • Indexes:    idx_dns_bloom  (Bloom on Array(String) dns)
                  idx_issuer     (token Bloom on issuer)
    • Codecs:     ZSTD(3) on free-text, LowCardinality(log)

2)  mv_dns_flat  (ReplacingMergeTree)
    • One row per **SAN domain**
    • Derived columns
        dn           – lower-cased SAN
        org_id       – surrogate UInt64 key
        registrable  – PSL “google.co.uk”
        root         – “google”  (first significant)
        dn_tokens    – token array of root
    • Purpose: fast domain & country filters; feeds heuristics.

3)  mv_org_cert  (MergeTree)
    • One row per (org_id , certificate)
    • Avoids `arrayJoin` at query time for exact org look-ups.

4)  mv_org_signatures  (AggregatingMergeTree)
    • SipHash64 + bitmap(cert_sn) per (norm_key, org_id)
    • Supports fuzzy “organisation similarity” searches in ≤ 0.2 s.

5)  mv_org_roots  (AggregatingMergeTree)
    • Pre-deduped list of *registrable* domains for each org_key
    • Drives dictionary `dict_org_roots` (flat in-RAM).

6)  dict_org_autocomplete  /  dict_org_roots  (FLAT dictionaries)
    • RAM hash-maps for sub-ms API endpoints (autocomplete, roots).

__ Technology matching layer ___________________________________________

A) tech_patterns/dict_tech_patterns  (TinyLog + HASHED dictionary)
   • Editable token / regex → technology + weight.
   • Columns  updated_at  &  version  for audit / rollback.

B) mv_ct_tech_signals  →  tech_signals  (MergeTree sink)
   • Every domain in `mv_dns_flat` is matched against
     `dict_tech_patterns` (token or regex).
   • Emits one *signal* row: ts, org_key, registrable, tech,
      confidence, structured evidence Array(Tuple(type,value)),
      is_negative flag for suppressing stale techs.

   External workers insert additional signals with
   `source` = 'active_scan' | 'proxycurl' etc.

C) mv_org_tech  (AggregatingMergeTree)
   • Aggregates signals into *one row per (org_key, tech)*
     keeping max(confidence) and last_seen timestamp.
   • Constant size w.r.t. signal volume.

D) org_tech_facts  (view)
   • Final, query-ready table:
       org_key | tech | confidence | last_seen

________________________________________________________________________
TYPICAL QUERY PATTERNS
________________________________________________________________________

•  What techs does Org X run?
     SELECT * FROM org_tech_facts
     WHERE org_key = norm_token_key('acme inc') AND confidence ≥ 0.5;

•  Which orgs appear to run GitLab in DE + CH?
     SELECT any(one_example) AS org_sample, confidence
     FROM org_tech_facts
     ANY INNER JOIN mv_org_signatures USING (org_key)
     WHERE tech='GitLab'
       AND org_key IN (
           SELECT norm_key FROM mv_dns_flat
           WHERE country IN ('DE','CH')
         );

•  Growth of *.bitbucket* registrable domains in JP:
     SELECT toStartOfMonth(nbf) AS month,
            uniqExact(registrable) AS n
     FROM mv_dns_flat
     WHERE country='JP' AND dn ILIKE '%bitbucket%'
     GROUP BY month ORDER BY month;

________________________________________________________________________
PERFORMANCE CONSIDERATIONS
________________________________________________________________________

✓  **Append-only ingest path** – partitions by `lts`; no in-flight duplicates.

✓  Surrogate **org_id (UInt64)** — replaces long strings in joins/dicts,
   cutting memory and index size ~30 %.

✓  **Single-part inserts** – `min_bytes_for_wide_part=128 MB`
    ensures each archive writes one “wide” part → minimal merge churn.

✓  **Bloom / tokenbf** – prunes > 95 % of rows for substring filters
    on `dn` and `iss`.

✓  **Public Suffix helpers** – `registrable`, `root` computed with
    built-in PSL, eliminating fragile `split('.')`.

✓  **AggregatingMergeTree** – keeps high-cardinality roll-ups
    (`mv_org_signatures`, `mv_org_roots`, `mv_org_tech`)
    at **O(distinct-key)** storage.

✓  **Dictionaries (FLAT / HASHED)** – sub-millisecond look-ups used:
    • write-time CT heuristics (`tech_patterns` + `dict_tech_patterns`)
    • read-time API (`dict_org_autocomplete`, `dict_org_roots`).

✓  **Signal scalability** – `tech_signals` is insert-only; background
    merges downsize parts.  Disk growth ≈ evidence volume.
    Overwrite-free design avoids write amplification.

________________________________________________________________________
EXTENSION HOOKS
________________________________________________________________________

•  Add new heuristic pattern:  `INSERT INTO tech_patterns …`
     then `SYSTEM RELOAD DICTIONARY dict_tech_patterns;`

•  Add new signal source:
     `INSERT INTO tech_signals FORMAT JSONEachRow …`

•  Adjust fuzzy match tolerance:
     change `hammingDistance()` threshold in analyst queries.

•  Suppress a false positive:

INSERT INTO tech_signals VALUES
('2025-07-01 12:00:00', 'acme co', 'acme.com',
'WordPress', 0 /*confidence*/, 'active_scan',
[('note','manual suppression')], 1 /*is_negative*/);

•  Bump or rollback a detection pattern:

UPDATE tech_patterns SET weight = 0.4, version = version+1
WHERE pattern = 'bitbucket';
SYSTEM RELOAD DICTIONARY dict_tech_patterns;

•  TTL to cold storage:

-- keep raw certs 24 months on fast disk, then move to 'blob' volume
ALTER TABLE ct_certificates
    MODIFY TTL lts + INTERVAL 24 MONTH TO VOLUME 'blob';

-- keep tech evidence 18 months hot
ALTER TABLE tech_signals
    MODIFY TTL ts  + INTERVAL 18 MONTH TO VOLUME 'blob';

________________________________________________________________________
OPERATIONAL METRICS & OBSERVABILITY
________________________________________________________________________

==== etl_ingest_metrics ====

Tracks every ETL/ingest run—useful for audit, debugging, and monitoring pipeline health.
Records when, what, and how much data was loaded, plus run time and errors.

Typical Insert (after ETL job):

INSERT INTO etl_ingest_metrics
  (job_name, table_name, rows_loaded, rows_inserted, duration_ms, partition, source, error)
VALUES
  ('certslurp', 'ct_certificates', 1048576, 1048576, 12500, '202506', 'S3', '');

Common Queries

Recent job runs and durations:
SELECT * FROM etl_ingest_metrics
ORDER BY ts DESC
LIMIT 25;

Average ingest duration for a table/job:
SELECT job_name, table_name, avg(duration_ms) AS avg_ms
FROM etl_ingest_metrics
WHERE ts > now() - INTERVAL 7 DAY
GROUP BY job_name, table_name;

Error summary:
SELECT ts, job_name, error
FROM etl_ingest_metrics
WHERE error != ''
ORDER BY ts DESC;

==== mv_partition_stats ====

Live summary of active rows and bytes for each table/partition.
Helps monitor storage usage and data growth; spot partitions that are too large, empty, or not merging/TTL-ing as expected.
Investigate large partitions or partitions not shrinking after TTL.

Example Queries

Per-table partition sizes (latest):
SELECT table, partition, rows, bytes
FROM mv_partition_stats
ORDER BY table, partition DESC;

Largest partitions:
SELECT table, partition, rows, bytes
FROM mv_partition_stats
ORDER BY bytes DESC
LIMIT 10;

==== system tables ====
Investigate merge/TTL issues or stuck parts directly from ClickHouse.

Monitor merges, mutations, TTL progress:
SELECT table, partition_id, progress, is_mutation, elapsed
FROM system.merges
WHERE active = 1;

Check ongoing TTL moves:
SELECT * FROM system.ttl_moves WHERE table = 'ct_certificates';

==== slow_queries ====
Use for long-running query analysis and troubleshooting.

SELECT *
FROM slow_queries
WHERE query_duration_ms > 10000
ORDER BY event_time DESC
LIMIT 10;

-----------------------------------------------------------------------*/

/*-----------------------------------------------------------------------
  0.  Helper UDFs
-----------------------------------------------------------------------*/
DROP FUNCTION IF EXISTS norm_token_key;
DROP FUNCTION IF EXISTS org_id;

-- 1️⃣ token-normalisation helper
CREATE FUNCTION norm_token_key AS
  (s) -> arrayStringConcat(
           arraySort(
             arrayDistinct(
               splitByRegexp('[^\\p{L}\\p{N}]+', lowerUTF8(s))
             )
           ),
           ' '
         );

-- 2️⃣ deterministic organisation-ID hash
CREATE FUNCTION org_id AS
  (s) -> sipHash64(norm_token_key(s));

/*-----------------------------------------------------------------------
  1.  Raw certificate landing table
-----------------------------------------------------------------------*/
CREATE TABLE IF NOT EXISTS ct_certificates
(
    /* core identity */
    cn  String,
    sub String,
    iss String,
    sn  FixedString(32),

    /* multi-value RDN / SAN fields */
    em   Array(String),
    ou   Array(String),
    org  Array(String),
    loc  Array(String),
    prv  Array(String),
    co   Array(String),
    st   Array(String),
    pc   Array(String),
    dns  Array(String),
    ips  Array(String),
    uris Array(String),

    /* validity window */
    nbf DateTime64(0, 'UTC'),
    naf DateTime64(0, 'UTC'),

    /* CT-log position */
    log String,
    li  UInt64,
    lts DateTime64(6, 'UTC')
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(lts)          -- append-only
ORDER BY (log, li)
SAMPLE BY li
SETTINGS
    index_granularity       = 8192,
    min_bytes_for_wide_part = 134217728;

/* codecs & LowCardinality */
ALTER TABLE ct_certificates
    -- switch to LC + LZ4HC for the log name
    MODIFY COLUMN log LowCardinality(String) CODEC(LZ4HC),

    -- core certificate strings -> ZSTD level-3
    MODIFY COLUMN cn   String         CODEC(ZSTD(3)),
    MODIFY COLUMN sub  String         CODEC(ZSTD(3)),
    MODIFY COLUMN iss  String         CODEC(ZSTD(3)),

    -- multi-value arrays -> keep existing type, add codec
    MODIFY COLUMN dns  Array(String)  CODEC(ZSTD(3)),
    MODIFY COLUMN em   Array(String)  CODEC(ZSTD(3)),
    MODIFY COLUMN org  Array(String)  CODEC(ZSTD(3)),
    MODIFY COLUMN ou   Array(String)  CODEC(ZSTD(3)),
    MODIFY COLUMN loc  Array(String)  CODEC(ZSTD(3)),
    MODIFY COLUMN prv  Array(String)  CODEC(ZSTD(3)),
    MODIFY COLUMN co   Array(String)  CODEC(ZSTD(3)),
    MODIFY COLUMN st   Array(String)  CODEC(ZSTD(3)),
    MODIFY COLUMN pc   Array(String)  CODEC(ZSTD(3)),
    MODIFY COLUMN uris Array(String)  CODEC(ZSTD(3));

/* secondary indexes */
ALTER TABLE ct_certificates
    ADD INDEX IF NOT EXISTS idx_dns_bloom  dns TYPE bloom_filter(0.02) GRANULARITY 2,
    ADD INDEX IF NOT EXISTS idx_issuer     iss TYPE tokenbf_v1(2048,3,0)      GRANULARITY 4;

/*-----------------------------------------------------------------------
  2.  Domain-flattened view  (one row per SAN)
-----------------------------------------------------------------------*/
DROP TABLE IF EXISTS dns_flat;

CREATE TABLE dns_flat
(
    ver          UInt64 MATERIALIZED sipHash64(sn),

    dn           String,
    registrable  String,
    root         String,
    dn_tokens    Array(String),

    organization String,
    ou           String,
    locality     String,
    province     String,
    country      String,
    org_id       UInt64,
    nbf          DateTime64(0, 'UTC'),
    sn           String,
    lts          DateTime,

    /* token Bloom on scalar domains */
    INDEX idx_dn_token dn TYPE tokenbf_v1(2048,3,0) GRANULARITY 4
)
ENGINE = ReplacingMergeTree(ver)
PARTITION BY toYYYYMM(lts)
ORDER BY dn;

DROP VIEW IF EXISTS mv_dns_flat;

CREATE MATERIALIZED VIEW mv_dns_flat
TO dns_flat AS
SELECT
    lower(dns)                            AS dn,
    cutToFirstSignificantSubdomain(dns)   AS registrable,
    firstSignificantSubdomain(dns)        AS root,
    splitByRegexp('[^\\p{L}\\p{N}]+', firstSignificantSubdomain(dns)) AS dn_tokens,

    organization,
    ou,
    locality,
    province,
    country,
    org_id(organization)                  AS org_id,

    nbf,
    sn,
    lts
FROM (
  SELECT
    arrayJoin(arrayDistinct(dns)) AS dns,
    arrayJoin(org) AS organization,
    arrayJoin(ou)  AS ou,
    arrayJoin(loc) AS locality,
    arrayJoin(prv) AS province,
    arrayJoin(co)  AS country,

    nbf,
    sn,
    lts

  FROM ct_certificates
) AS deduped;

INSERT INTO dns_flat
SELECT
    lower(dns),
    cutToFirstSignificantSubdomain(dns),
    firstSignificantSubdomain(dns),
    splitByRegexp('[^\\p{L}\\p{N}]+', firstSignificantSubdomain(dns)),
    arrayJoin(org),
    arrayJoin(ou),
    arrayJoin(loc),
    arrayJoin(prv),
    arrayJoin(co),
    org_id(arrayJoin(org)),
    nbf,
    sn,
    lts
FROM ct_certificates
ARRAY JOIN dns AS dns;

/*-----------------------------------------------------------------------
  3.  Org → certificate lookup view
-----------------------------------------------------------------------*/
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_org_cert
ENGINE = MergeTree
PARTITION BY toYYYYMM(nbf)
ORDER BY (organization, sn)
AS
SELECT
    arrayJoin(org) AS organization,
    org_id(organization) AS org_id,
    sn,
    nbf
FROM ct_certificates;

/*-----------------------------------------------------------------------
  4.  Organisation SipHash signatures (fuzzy backbone)
-----------------------------------------------------------------------*/
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_org_signatures
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(toStartOfMonth(min_nbf))
ORDER BY norm_key
AS
SELECT
    norm_token_key(arrayJoin(org))        AS norm_key,
    org_id(arrayJoin(org))                AS org_id,
    sipHash64(norm_key)                   AS sh64,
    anyHeavy(arrayJoin(org))              AS one_example,
    groupBitmapState(sipHash64(sn))       AS sn_bitmap,
    min(nbf)                              AS min_nbf
FROM ct_certificates
GROUP BY norm_key, org_id;

/*-----------------------------------------------------------------------
  5.  Org → registrable-domain roll-up
-----------------------------------------------------------------------*/
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_org_roots
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(toStartOfMonth(min_nbf))
ORDER BY norm_key
AS
SELECT
    norm_token_key(organization)   AS norm_key,
    groupUniqArray(registrable)    AS roots,
    countDistinct(registrable)     AS root_cnt,
    min(nbf) AS min_nbf
FROM mv_dns_flat
GROUP BY norm_key;

/*-----------------------------------------------------------------------
  6.  Low-latency dictionaries
-----------------------------------------------------------------------*/
CREATE DICTIONARY IF NOT EXISTS dict_org_autocomplete
(
    org String
)
PRIMARY KEY org
SOURCE(CLICKHOUSE(code 'SELECT DISTINCT organization FROM mv_dns_flat'))
LAYOUT(FLAT())
LIFETIME(MIN 300 MAX 3600);

CREATE DICTIONARY IF NOT EXISTS dict_org_roots
(
    norm_key String,
    roots    Array(String)
)
PRIMARY KEY norm_key
SOURCE(CLICKHOUSE(TABLE 'mv_org_roots'))
LAYOUT(FLAT())
LIFETIME(MIN 300 MAX 3600);

/*-----------------------------------------------------------------------
  7.  Technology-matching components
-----------------------------------------------------------------------*/

/* 7.1  Pattern dictionary (tiny, hand-editable) */
CREATE TABLE IF NOT EXISTS tech_patterns
(
    id       UInt32,
    pattern  String,
    is_regex UInt8  DEFAULT 0,
    tech     String,
    weight   Float32 DEFAULT 1.0,
    updated_at DateTime DEFAULT now(),
    version UInt32 DEFAULT 1
) ENGINE = TinyLog;

DROP DICTIONARY IF EXISTS dict_tech_patterns;

CREATE DICTIONARY dict_tech_patterns
(
    id       UInt32,
    pattern  String,
    is_regex UInt8,
    tech     String,
    weight   Float32
)
PRIMARY KEY id
SOURCE(CLICKHOUSE(TABLE 'tech_patterns'))
LAYOUT(HASHED())
LIFETIME(MIN 300 MAX 3600);

/* 7.2  Raw signal sink (external scanners + CT heuristics) 

Rules:  
- positive wins if confidence higher and is_negative=0;  
- suppression row (is_negative=1) sets confidence to 0 in mv_org_tech because maxState ignores it—switch to argMaxState(confidence, not is_negative) if you want negatives to overwrite.
*/

CREATE TABLE IF NOT EXISTS tech_signals
(
    ts           DateTime64(3, 'UTC'),
    org_id UInt64 DEFAULT 0,
    registrable  String,
    tech         LowCardinality(String),
    confidence   Float32,
    source LowCardinality(String), /* Conventional defaults: ct_heuristic, active_scan, proxycurl */
    state Enum8(
        'active' = 1,
        'suppressed' = 2,
        'pending_review' = 3,
        'expired' = 4
    ) DEFAULT 'active',
    evidence Array(Tuple(type String, value String)),
    is_negative UInt8 DEFAULT 0
) ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (tech, ts);

ALTER TABLE tech_signals
  ADD INDEX IF NOT EXISTS idx_org_id (org_id) TYPE set(0) GRANULARITY 1;

/* 7.3  CT-driven heuristic signals  (uses a *table* join) */
DROP VIEW IF EXISTS mv_ct_tech_signals_token;
CREATE MATERIALIZED VIEW mv_ct_tech_signals_token
TO tech_signals AS
SELECT
    now64()                       AS ts,
    org_id                        AS org_id,
    registrable                   AS registrable,
    tp.tech                       AS tech,
    tp.weight                     AS confidence,
    'ct_heuristic'                AS source,
    [ tuple('dns', dn) ]          AS evidence,
    0                             AS is_negative
FROM mv_dns_flat
ANY INNER JOIN dict_tech_patterns AS tp
     ON tp.is_regex = 0
WHERE positionCaseInsensitive(dn, tp.pattern) > 0;

-- regex matches
DROP VIEW IF EXISTS mv_ct_tech_signals_regex;
CREATE MATERIALIZED VIEW mv_ct_tech_signals_regex
TO tech_signals AS
SELECT
    now64()                  AS ts,
    org_id                   AS org_id,
    registrable              AS registrable,
    tp.tech                  AS tech,
    tp.weight                AS confidence,
    'ct_heuristic'           AS source,
    [tuple('dns', dn)]       AS evidence,
    0                        AS is_negative
FROM mv_dns_flat
ANY INNER JOIN dict_tech_patterns AS tp
  ON tp.is_regex = 1
WHERE match(dn, tp.pattern);

/* 7.4  Aggregated truth table  (org × tech) */
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_org_tech
ENGINE = AggregatingMergeTree
PARTITION BY month
ORDER BY (org_id, tech)
AS
SELECT
    org_id,
    tech,
    argMaxState(confidence, ts) AS conf_state,
    maxState(ts)          AS last_seen_state,
    toYYYYMM(ts)          AS month
FROM tech_signals
GROUP BY org_id, tech, toYYYYMM(ts);

CREATE OR REPLACE VIEW org_tech_facts AS
SELECT
    org_id,
    tech,
    finalizeAggregation(conf_state)              AS confidence,
    toDateTime64(finalizeAggregation(last_seen_state),3) AS last_seen
FROM mv_org_tech;

/*-----------------------------------------------------------------------
  8. Observability
-----------------------------------------------------------------------*/

CREATE TABLE IF NOT EXISTS etl_ingest_metrics
(
    ts          DateTime64(3, 'UTC') DEFAULT now64(),
    job_name    LowCardinality(String),   -- e.g. "certslurp", "active_scan"
    table_name  LowCardinality(String),   -- e.g. "ct_certificates"
    rows_loaded UInt64,
    rows_inserted UInt64,
    duration_ms UInt32,
    partition   String,                   -- e.g. "202506" for June 2025
    source      LowCardinality(String),   -- e.g. "S3", "API", etc
    error       String DEFAULT ''         -- error message if any, else ''
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (job_name, table_name, ts);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_partition_stats
ENGINE = SummingMergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (table, partition)
AS
SELECT
    now64() AS ts,
    table,
    partition,
    sum(rows) AS rows,
    sum(bytes_on_disk) AS bytes
FROM system.parts
WHERE active = 1
GROUP BY table, partition;

CREATE TABLE IF NOT EXISTS slow_queries
(
    event_time DateTime,
    query_duration_ms UInt32,
    query_text String,
    user String,
    database String,
    read_rows UInt64,
    read_bytes UInt64
)
ENGINE = MergeTree
ORDER BY event_time;

/*-----------------------------------------------------------------------
  9. Seeds
-----------------------------------------------------------------------*/
INSERT INTO tech_patterns (id, pattern, is_regex, tech, weight) VALUES
(1,'bitbucket',0,'Bitbucket', 1.0),
(2,'gitlab',   0,'GitLab',    1.0),
(3,'github',   0,'GitHub',    1.0),
(4,'vercel',   0,'Vercel',    1.0),
(5,'heroku',   0,'Heroku',    1.0),
(6,'splunk',   0,'Splunk',    1.0),
(7,'jenkins',  0,'Jenkins',   1.0),
(8,'jfrog',    0,'JFrog',     1.0);

SYSTEM RELOAD DICTIONARY dict_tech_patterns;
/*-----------------------------------------------------------------------
Certificate-to-Technology Analytics Schema  – 2025-07-01
-----------------------------------------------------------------------

End-to-end analytics pipeline for extracting, clustering, and analyzing certificate transparency logs to detect technology use by organization. 
Schema is designed for high-volume ingest, append-only safety, efficient surrogate keys, rapid fuzzy/org lookup, and scalable heuristics—leveraging ClickHouse 
refreshable materialized views for automatic periodic rollup, aliasing, and autocomplete.

________________________________________________________________________
DATA FLOW & ARCHITECTURE
________________________________________________________________________

CT logs → certslurp archives → ct_certificates
                        │
        ┌───────────────┴────────────────────────────────────────┐
        │   [mv_dns_flat] (per-SAN)                              │
        │   + PSL: org_id, root, etc                             │ 
dict_tech_patterns (HASHED dictionary) ←── tiny, versioned       │
        │                                                        ▼
        ▼                                           [pattern/token/regex match]
 [mv_ct_tech_signals] ─────────────────────────────────────→ tech_signals ←── external scan/API
        ▲                                                        ▲
        │                                                        │ merges & suppression
        │                                                        │
  [mv_org_tech]                                       (AggregatingMergeTree)
        │
        ▼
 org_tech_facts (read-only, deduped)


Org clustering, autocomplete & aliasing:

    mv_org_roots → org_root_sets (periodic refresh)
    │
    └─→ org_alias_map (periodic refresh)
    └─→ org_autocomplete_clustered (periodic refresh)

All organizational grouping uses org_id (UInt64; deterministic SipHash64 of normalized tokens) for speed and deduplication.

________________________________________________________________________
TABLE & VIEW GLOSSARY
________________________________________________________________________

1. ct_certificates  (MergeTree, raw ingest)
 - One row per certificate scraped by certslurp
 - Partitioned by toYYYYMM(lts) (append-only; lts = log timestamp)
 - All multi-value fields (org, dns, etc) are arrays.
 - Indexes:  Bloom on Array(String) dns; token Bloom on issuer

2. mv_dns_flat  (ReplacingMergeTree)
 - One row per SAN domain
 - Derived columns: dn (SAN), org_id, registrable (PSL), root, token arrays
 - Purpose: fast domain & country filters; feeds heuristics.

3. mv_org_cert  (MergeTree)
 - One row per (org_id, certificate)
 - Avoids arrayJoin at query time for exact org lookups.

4. mv_org_signatures  (AggregatingMergeTree)
 - SipHash64 + bitmap(cert_sn) per (norm_key, org_id)
 - Supports fuzzy org similarity/autocomplete in milliseconds.

5. mv_org_roots  (AggregatingMergeTree)
 - Pre-deduped list of registrable domains for each org_id
 - Drives org_root_sets, which feeds alias clustering.

6. org_root_sets  (periodically refreshed MergeTree)
 - Most recent root domain set per org_id (one row per org)
 - Refreshed automatically; do not manually insert.

7. org_alias_map  (periodically refreshed MergeTree)
 - All pairs of org_ids sharing ≥2 registrable roots
 - Used for alias/cluster detection and autocomplete grouping.

8. org_autocomplete_clustered  (periodically refreshed MergeTree)
 - Autocomplete table: cluster_id, aliases, display_name, cert_count
 - Used for fuzzy org lookup, UI, reporting.

9. tech_patterns/dict_tech_patterns/dict_regex_prefixes
 - Editable patterns and live-reload dictionaries for token/regex → tech mapping.

10. tech_signals  (MergeTree)
 - All technology "signals" (from heuristics + external sources)
 - Evidence, source, confidence, is_negative fields

11. mv_ct_tech_signals_token / mv_ct_tech_signals_regex
 - Insert tech_signals from token and regex matches in mv_dns_flat.

12. mv_org_tech / org_tech_facts (AggregatingMergeTree/view)
 - One row per (org_id, tech); highest-confidence, deduped
 - API and reporting table

13. etl_ingest_metrics
 - All ETL/ingest job runs (row count, duration, errors, partition, etc.)

14. mv_partition_stats, slow_queries
 - System-level metrics and performance diagnostics

________________________________________________________________________
TYPICAL QUERY PATTERNS
________________________________________________________________________

* What techs does Org X run?
SELECT * FROM org_tech_facts
WHERE org_id = org_id('acme inc') AND confidence >= 0.5;

* Which orgs appear to run GitLab in DE + CH?
SELECT
    o.display_name,
    f.confidence
FROM org_tech_facts f
JOIN org_autocomplete_clustered o ON f.org_id = o.cluster_id
WHERE f.tech = 'GitLab'
  AND f.org_id IN (
      SELECT org_id FROM dns_flat WHERE country IN ('DE','CH')
  )
ORDER BY f.confidence DESC;

* Growth of .bitbucket registrable domains in JP:
SELECT toStartOfMonth(nbf) AS month,
uniqExact(registrable) AS n
FROM dns_flat
WHERE country='JP' AND dn ILIKE '%bitbucket%'
GROUP BY month ORDER BY month;

* Recent ETL job runs and durations:
SELECT * FROM etl_ingest_metrics
ORDER BY ts DESC
LIMIT 25;

* Average ingest duration for a table/job:
SELECT job_name, table_name, avg(duration_ms) AS avg_ms
FROM etl_ingest_metrics
WHERE ts > now() - INTERVAL 7 DAY
GROUP BY job_name, table_name;

* Error summary for last 24h:
SELECT ts, job_name, error
FROM etl_ingest_metrics
WHERE error != ''
ORDER BY ts DESC;

* Per-table partition sizes (latest):
SELECT table, partition, rows, bytes
FROM mv_partition_stats
ORDER BY table, partition DESC;

* Largest partitions by bytes:
SELECT table, partition, rows, bytes
FROM mv_partition_stats
ORDER BY bytes DESC
LIMIT 10;

* Investigate active merges/mutations/TTL:
SELECT table, partition_id, progress, is_mutation, elapsed
FROM system.merges
WHERE active = 1;

* Check ongoing TTL moves:
SELECT * FROM system.ttl_moves WHERE table = 'ct_certificates';

* Show long-running queries:
SELECT * FROM slow_queries
WHERE query_duration_ms > 10000
ORDER BY event_time DESC
LIMIT 10;

* Show current org alias clusters:
SELECT * FROM org_autocomplete_clustered
WHERE length(aliases) > 1
ORDER BY cert_count DESC;


* Fuzzy search for orgs containing "acme" (case-insensitive, matches aliases or display_name)
SELECT
    display_name,
    aliases,
    cert_count
FROM org_autocomplete_clustered
WHERE display_name ILIKE '%acme%'
   OR arrayExists(x -> positionCaseInsensitive(x, 'acme') > 0, aliases)
ORDER BY cert_count DESC
LIMIT 10;

* Find orgs running "GitLab" with confidence at least 0.5, showing sample alias
SELECT
    o.display_name,
    o.aliases,
    f.confidence,
    f.last_seen
FROM org_tech_facts AS f
JOIN org_autocomplete_clustered AS o ON f.org_id = o.cluster_id
WHERE f.tech = 'GitLab' AND f.confidence >= 0.5
ORDER BY f.confidence DESC, f.last_seen DESC
LIMIT 25;

* All tech detected for orgs matching 'acme'
SELECT
    f.tech,
    f.confidence,
    f.last_seen
FROM org_tech_facts AS f
JOIN org_autocomplete_clustered AS o ON f.org_id = o.cluster_id
WHERE arrayExists(x -> positionCaseInsensitive(x, 'acme') > 0, o.aliases)
ORDER BY f.confidence DESC, f.tech

* Orgs in Germany ("DE") or Switzerland ("CH") using GitLab
SELECT
    o.display_name,
    o.aliases,
    f.confidence,
    f.last_seen
FROM org_tech_facts AS f
JOIN org_autocomplete_clustered AS o ON f.org_id = o.cluster_id
WHERE f.tech = 'GitLab'
  AND f.confidence >= 0.5
  AND f.org_id IN (
      SELECT org_id FROM dns_flat
      WHERE country IN ('DE', 'CH')
  )
ORDER BY f.last_seen DESC;

* Tech detected for a particular SAN (e.g., "example.com")
SELECT
    t.tech,
    t.confidence,
    t.last_seen
FROM org_tech_facts t
JOIN dns_flat d ON t.org_id = d.org_id
WHERE d.dn = 'example.com'
ORDER BY t.confidence DESC, t.tech

* Given a user-typed org name, get cluster and all known aliases
SELECT
    cluster_id,
    display_name,
    aliases
FROM org_autocomplete_clustered
WHERE arrayExists(x -> positionCaseInsensitive(x, 'jpmorgan') > 0, aliases)
   OR display_name ILIKE '%jpmorgan%';


* Find all facts and aliases for a known org_id
SELECT
    f.tech,
    f.confidence,
    f.last_seen,
    o.display_name,
    o.aliases
FROM org_tech_facts f
JOIN org_autocomplete_clustered o ON f.org_id = o.cluster_id
WHERE f.org_id = org_id('Acme Inc');
________________________________________________________________________
PERFORMANCE CONSIDERATIONS
________________________________________________________________________

+ Append-only ingest path – partitions by lts; no in-flight duplicates.
+ Surrogate org_id (UInt64) – all joins/group-bys via hash key.
+ Large "wide" parts – minimizes background merges and write amplification.
+ Bloom / tokenbf / ngrambf – efficient substring filters on org/dn/issuer.
+ PSL helpers – registrable, root fields use built-in PSL.
+ AggregatingMergeTree rollups – constant size w.r.t. distinct-key.
+ FLAT/HASHED dictionaries – sub-ms lookups for heuristics and API.
+ Signal scalability – tech_signals is append-only, disk grows ~=~ evidence volume.

________________________________________________________________________
EXTENSION HOOKS
________________________________________________________________________

* Add new heuristic pattern:
INSERT INTO tech_patterns …;
SYSTEM RELOAD DICTIONARY dict_tech_patterns;

* Add new signal source:
INSERT INTO tech_signals FORMAT JSONEachRow …;

* Suppress a false positive:
INSERT INTO tech_signals VALUES
('2025-07-01 12:00:00', org_id('acme co'), 'acme.com',
'WordPress', 0, 'active_scan', [('note','manual suppression')], 1);

* Bump or rollback a detection pattern:
UPDATE tech_patterns SET weight = 0.4, version = version+1
WHERE pattern = 'bitbucket';
SYSTEM RELOAD DICTIONARY dict_tech_patterns;

* TTL to cold storage:
ALTER TABLE ct_certificates
MODIFY TTL lts + INTERVAL 24 MONTH TO VOLUME 'blob';
   ALTER TABLE tech_signals
     MODIFY TTL ts + INTERVAL 18 MONTH TO VOLUME 'blob';

* Manual/forced view refresh:
SYSTEM REFRESH VIEW org_root_sets_mv;

* Check view refresh status:
SELECT * FROM system.view_refreshes WHERE view_name LIKE '%org%';

* Debug/override:
Force a refresh and inspect downstream tables after any batch.
________________________________________________________________________
OPERATIONAL METRICS & OBSERVABILITY
________________________________________________________________________

==== etl_ingest_metrics ====

Tracks every ETL/ingest run for audit, debugging, and monitoring pipeline health.
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
Monitor storage, spot partitions that are too large, empty, or not merging as expected.

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

Monitor merges, mutations, TTL progress:
system.merges, system.ttl_moves, system.view_refreshes, etc.

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

________________________________________________________________________
SCHEMA MAINTENANCE / WRITING
________________________________________________________________________

* Do NOT manually write to org_root_sets, org_alias_map, or org_autocomplete_clustered; these are maintained by periodic refreshable MVs.
* Use SYSTEM REFRESH VIEW  to trigger immediate refresh if required.
* All TTLs and refresh intervals are defined in DDL and can be tuned via ALTER TABLE.

-----------------------------------------------------------------------*/

/*-----------------------------------------------------------------------
  0.  Helper UDFs
-----------------------------------------------------------------------*/
DROP FUNCTION IF EXISTS norm_token_key;
DROP FUNCTION IF EXISTS org_id;

-- 1️⃣ token-normalisation helper

/* Stopword list can be tuned with results from:

SELECT
    token,
    count() AS n
FROM
(
    SELECT arrayDistinct(splitByChar(' ', norm_token_key(org))) AS tokens
    FROM org_strings
)
ARRAY JOIN tokens AS token
GROUP BY token
ORDER BY n DESC
LIMIT 50
*/
CREATE OR REPLACE FUNCTION norm_token_key AS
  (s) -> arrayStringConcat(
           arraySort(
             arrayFilter(
               x -> length(x) > 1 AND NOT x IN ('inc','incorporated','llc','co','company','corp','corporation','ltd','limited','sa','gmbh','the','and','&','-','of',
               'pvt','llp','bv','spa','as','oy','aps','ab','sarl','nv','ag','sl','sas','kg','kgaa','pte','plc','ltda','sl','pty','srl','at','for',
               'gesellschaft','societe','société','empresa','firma','compania','compañía','compañia','associés','vereniging'),
               arrayDistinct(
                 arrayMap(
                   t -> replaceRegexpAll(t, '[^\\p{L}\\p{N}]', ''),
                   splitByRegexp('[^\\p{L}\\p{N}]+', lowerUTF8(s))
                 )
               )
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
    sn  String,

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
    MODIFY COLUMN sn  String         CODEC(ZSTD(3)),

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
    dn_tokens_full Array(String),

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
    INDEX idx_dn_token_scalar dn TYPE tokenbf_v1(2048,3,0) GRANULARITY 4, 
    INDEX idx_dn_token_array  dn_tokens      TYPE tokenbf_v1(2048,3,0) GRANULARITY 4,
    INDEX idx_dn_tokens_full dn_tokens_full TYPE tokenbf_v1(2048,3,0) GRANULARITY 4
)
ENGINE = ReplacingMergeTree(ver)
PARTITION BY toYYYYMM(lts)
ORDER BY dn;

DROP VIEW IF EXISTS mv_dns_flat;

CREATE MATERIALIZED VIEW mv_dns_flat
TO dns_flat AS
SELECT
    lower(arrayJoin(arrayDistinct(dns)))               AS dn,
    cutToFirstSignificantSubdomain(dn)                 AS registrable,
    firstSignificantSubdomain(dn)                      AS root,
    splitByRegexp('[^\\p{L}\\p{N}]+', root)            AS dn_tokens,
    splitByRegexp('[^\\p{L}\\p{N}]+', dn)              AS dn_tokens_full,

    arrayJoin(org)                                     AS organization,
    arrayElement(ou,  1)                               AS ou,
    arrayElement(loc, 1)                               AS locality,
    arrayElement(prv, 1)                               AS province,
    arrayElement(co,  1)                               AS country,
    org_id(organization)                               AS org_id,

    nbf, sn, lts
FROM ct_certificates;

/*-----------------------------------------------------------------------
  3.  Org → certificate lookup view
-----------------------------------------------------------------------*/
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_org_cert
ENGINE = MergeTree
PARTITION BY toYYYYMM(lts)
ORDER BY (organization, sn)
AS
SELECT
    arrayJoin(org) AS organization,
    org_id(organization) AS org_id,
    sn,
    nbf,
    naf, 
    lts
FROM ct_certificates;

/*-----------------------------------------------------------------------
  4.  Org → registrable-domain roll-up
-----------------------------------------------------------------------*/
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_org_roots
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(min_lts)
ORDER BY (norm_key, org_id)
AS
SELECT
    norm_token_key(organization)   AS norm_key,
    org_id(organization)           AS org_id,
    groupUniqArray(registrable)    AS roots,
    countDistinct(registrable)     AS root_cnt,
    min(nbf) AS min_nbf,
    max(nbf) AS max_naf,
    min(lts) AS min_lts,
    max(lts) AS max_lts
FROM dns_flat
GROUP BY norm_key, org_id;

/* This table is automatically maintained by org_root_sets_mv.
   Do not manually write to this table, it will refresh on a schedule. */
CREATE OR REPLACE TABLE org_root_sets
(
    org_id    UInt64,
    roots     Array(String),
    root_cnt  UInt64
)
ENGINE = MergeTree
ORDER BY org_id;

DROP VIEW IF EXISTS org_root_sets_mv;

CREATE MATERIALIZED VIEW org_root_sets_mv
REFRESH EVERY 1 DAY OFFSET 1 HOUR RANDOMIZE FOR 1 HOUR
TO org_root_sets AS
SELECT
    org_id,
    roots,
    length(roots) AS root_cnt
FROM (
    SELECT *,
        row_number() OVER (PARTITION BY org_id ORDER BY min_nbf DESC) AS rn
    FROM mv_org_roots
)
WHERE rn = 1;

/*-----------------------------------------------------------------------
  5.  Organisation SipHash signatures + autocomplete (fuzzy backbone)
-----------------------------------------------------------------------*/
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_org_signatures
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(min_lts)
ORDER BY norm_key
AS
SELECT
    norm_token_key(arrayJoin(org))        AS norm_key,
    org_id(arrayJoin(org))                AS org_id,
    sipHash64(norm_key)                   AS sh64,
    anyHeavy(arrayJoin(org))              AS one_example,
    groupBitmapState(sipHash64(sn))       AS sn_bitmap,
    min(nbf)                              AS min_nbf,
    max(nbf)                              AS max_naf,
    min(lts) AS min_lts,
    max(lts) AS max_lts
FROM ct_certificates
GROUP BY norm_key, org_id;

CREATE TABLE org_strings
(
    org String,
    org_id UInt64 MATERIALIZED sipHash64(
                     arrayStringConcat(
                         arraySort(
                           arrayDistinct(
                             splitByRegexp('[^\\p{L}\\p{N}]+', lowerUTF8(org))
                           )), ' ')
                   ),

    INDEX idx_org_prefix (org) TYPE tokenbf_v1(2048, 3, 0) GRANULARITY 4,
    INDEX idx_org_ngram (org) TYPE ngrambf_v1(3, 2048, 3, 0) GRANULARITY 4
)
ENGINE = MergeTree
ORDER BY org 
SETTINGS index_granularity = 8192;

DROP VIEW IF EXISTS mv_org_strings;
CREATE MATERIALIZED VIEW mv_org_strings
TO org_strings
AS
SELECT DISTINCT arrayJoin(org) AS org
FROM ct_certificates;

/* This table is automatically maintained by org_alias_map_mv.
   Do not manually write to this table, it will refresh on a schedule. */
CREATE OR REPLACE TABLE org_alias_map
ENGINE = MergeTree
ORDER BY (alias_id, canonical_id) AS
SELECT
    a.org_id                                  AS alias_id,
    b.org_id                                  AS canonical_id,
    arrayIntersect(a.roots, b.roots)          AS shared,
    length(shared)                            AS inter_cnt,
    length(arrayUnion(a.roots, b.roots))      AS uni_cnt
FROM org_root_sets a
JOIN org_root_sets b ON a.org_id < b.org_id
WHERE length(arrayIntersect(a.roots, b.roots)) >= 2;

CREATE MATERIALIZED VIEW org_alias_map_mv
REFRESH EVERY 1 DAY OFFSET 3 HOUR RANDOMIZE FOR 1 HOUR
TO org_alias_map AS
SELECT
    a.org_id                                  AS alias_id,
    b.org_id                                  AS canonical_id,
    arrayIntersect(a.roots, b.roots)          AS shared,
    length(shared)                            AS inter_cnt,
    length(arrayUnion(a.roots, b.roots))      AS uni_cnt
FROM org_root_sets a
JOIN org_root_sets b ON a.org_id < b.org_id
WHERE length(shared) >= 2;

/* This table is automatically maintained by org_autocomplete_clustered_mv.
   Do not manually write to this table, it will refresh on a schedule. */
CREATE TABLE org_autocomplete_clustered
(
    cluster_id   UInt64,
    display_name String,
    cert_count   UInt64,
    aliases      Array(String),

    INDEX idx_display_name_tokenbf (display_name) TYPE tokenbf_v1(2048, 3, 0) GRANULARITY 4,
    INDEX idx_display_name_ngram   (display_name) TYPE ngrambf_v1(3, 2048, 3, 0) GRANULARITY 4,
    INDEX idx_aliases_tokenbf      (aliases)      TYPE tokenbf_v1(2048, 3, 0) GRANULARITY 4,
    INDEX idx_aliases_ngram        (aliases)      TYPE ngrambf_v1(3, 2048, 3, 0) GRANULARITY 4
)
ENGINE = MergeTree
ORDER BY (cert_count DESC, display_name)
SETTINGS index_granularity = 8192, allow_experimental_reverse_key = 1;

CREATE MATERIALIZED VIEW org_autocomplete_clustered_mv
REFRESH EVERY 1 HOUR OFFSET 50 MINUTE
TO org_autocomplete_clustered AS
SELECT
    if(m.canonical_id != 0, m.canonical_id, c.org_id) AS cluster_id,
    groupArrayDistinct(c.organization) AS aliases,
    arrayElement(
        groupArray((c.count, c.organization)),
        argMax(c.count, c.organization)
    ).2 AS display_name,
    sum(c.count) AS cert_count
FROM (
    SELECT
        org_id(arrayJoin(org)) AS org_id,
        arrayJoin(org)         AS organization,
        count()                AS count
    FROM ct_certificates
    WHERE arrayJoin(org) != ''
    GROUP BY org_id, organization
) AS c
LEFT JOIN org_alias_map m ON c.org_id = m.alias_id
GROUP BY cluster_id
ORDER BY cert_count DESC;

/*-----------------------------------------------------------------------
  6.  Low-latency dictionaries
-----------------------------------------------------------------------*/

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
CREATE TABLE tech_patterns
(
    id            UInt32,
    pattern       String,
    is_regex      UInt8  DEFAULT 0,
    regex_prefix  String DEFAULT '',
    tech          String,
    weight        Float32 DEFAULT 1.0,
    updated_at    DateTime DEFAULT now(),
    version       UInt32  DEFAULT 1
)
ENGINE = MergeTree
PRIMARY KEY id
ORDER BY id; 

DROP DICTIONARY IF EXISTS dict_tech_patterns;

CREATE DICTIONARY dict_tech_patterns
(
    id       UInt32,
    pattern  String,
    is_regex UInt8,
    regex_prefix String,
    tech     String,
    weight   Float32
)
PRIMARY KEY id
SOURCE(CLICKHOUSE(TABLE 'tech_patterns'))
LAYOUT(HASHED())
LIFETIME(MIN 300 MAX 3600);

DROP DICTIONARY IF EXISTS dict_regex_prefixes;
CREATE DICTIONARY dict_regex_prefixes
(
    regex_prefix String,
    pattern      String,
    tech         String,
    weight       Float32
)
PRIMARY KEY regex_prefix, pattern
SOURCE(
    CLICKHOUSE(
        QUERY '
            SELECT regex_prefix, pattern, tech, weight
            FROM tech_patterns
            WHERE is_regex = 1
        '
    )
)
LAYOUT(COMPLEX_KEY_HASHED())
LIFETIME(MIN 300 MAX 3600);


CREATE MATERIALIZED VIEW tech_tokens
ENGINE = TinyLog
AS
SELECT id,
       arrayJoin(
           arrayFilter(x -> x != '',
                       splitByNonAlpha(lower(pattern)))
       ) AS token
FROM tech_patterns
WHERE is_regex = 0;

/* 7.2  Raw signal sink (external scanners + CT heuristics) */

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
    df.org_id                     AS org_id,
    df.registrable                AS registrable,
    tp.tech                       AS tech,
    tp.weight                     AS confidence,
    'ct_heuristic'                AS source,
    [tuple('dns', df.dn)]         AS evidence,
    0                             AS is_negative
FROM dns_flat AS df
CROSS JOIN
(
    SELECT pattern, tech, weight
    FROM dict_tech_patterns
    WHERE is_regex = 0
) AS tp
WHERE arrayExists(
          tok -> arrayExists(
                     pat -> positionCaseInsensitive(tok, pat) > 0,
                     (SELECT groupArray(token) FROM tech_tokens)),
          df.dn_tokens_full)
  AND positionCaseInsensitive(df.dn, tp.pattern) > 0;


-- regex matches
DROP VIEW IF EXISTS mv_ct_tech_signals_regex;
CREATE MATERIALIZED VIEW mv_ct_tech_signals_regex
TO tech_signals AS
SELECT
    now64()                 AS ts,
    df.org_id               AS org_id,
    df.registrable          AS registrable,
    rp.tech                 AS tech,
    rp.weight               AS confidence,
    'ct_heuristic'          AS source,
    [tuple('dns', df.dn)]   AS evidence,
    0                       AS is_negative
FROM dns_flat AS df
CROSS JOIN
(
    SELECT regex_prefix, pattern, tech, weight
    FROM dict_regex_prefixes
) AS rp
WHERE (rp.regex_prefix = ''
       OR positionCaseInsensitive(df.dn, rp.regex_prefix) > 0)
  AND match(df.dn, rp.pattern);


/* 7.4  Aggregated truth table  (org × tech) */
DROP VIEW IF EXISTS mv_org_tech;
CREATE MATERIALIZED VIEW mv_org_tech
ENGINE = AggregatingMergeTree
PARTITION BY month
ORDER BY (org_id, tech)
AS
SELECT
    org_id,
    tech,
    maxState(confidence) AS conf_state,
    maxState(ts)         AS last_seen_state,
    anyHeavy(toYYYYMM(ts)) AS month,
    maxState(is_negative) AS suppression_state
FROM tech_signals
GROUP BY org_id, tech;

CREATE OR REPLACE VIEW org_tech_facts AS
SELECT
    org_id,
    tech,
    -- If suppression_state==1, force confidence to zero
    IF(finalizeAggregation(suppression_state)=1, 0, finalizeAggregation(conf_state)) AS confidence,
    toDateTime64(finalizeAggregation(last_seen_state), 3) AS last_seen
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
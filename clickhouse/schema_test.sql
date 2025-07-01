/* ================================================================ *
 *  Certificate-to-Technology analytics – extended validation suite *
 * ================================================================ */

USE default;

/*------------------------------------------------------------------*
 * 0️⃣  Clean start (optional)                                       *
 *------------------------------------------------------------------*/
TRUNCATE TABLE tech_patterns;
TRUNCATE TABLE tech_signals;
TRUNCATE TABLE dns_flat;
TRUNCATE TABLE mv_org_tech;
TRUNCATE TABLE ct_certificates;
TRUNCATE TABLE dns_flat;
TRUNCATE TABLE org_root_sets;
TRUNCATE TABLE org_alias_map;
TRUNCATE TABLE org_autocomplete_clustered;

/*------------------------------------------------------------------*
 * 1️⃣  Base patterns (GitLab token + Heroku regex)                  *
 *------------------------------------------------------------------*/
INSERT INTO tech_patterns (id, pattern, is_regex, regex_prefix, tech, weight) VALUES
    (9001, 'gitlab', 0, '',          'GitLab', 1.0),
    (9002, '.*\\.herokuapp\\.com$', 1, 'herokuapp', 'Heroku', 1.0);

SYSTEM RELOAD DICTIONARY dict_tech_patterns;
SYSTEM RELOAD DICTIONARY dict_regex_prefixes;

/*------------------------------------------------------------------*
 * 2️⃣  Positive-path certs (GitLab, Heroku)                         *
 *------------------------------------------------------------------*/
INSERT INTO ct_certificates
    (dns, org, ou, loc, prv, co,  sn, nbf, naf, log, li, lts)
SETTINGS async_insert = 0, wait_for_async_insert = 1
VALUES
    (['gitlab.acme.com'], ['Acme Inc'], ['IT'],  ['SF'], ['CA'], ['US'],
     'SN-GL-001', now64(), now64()+3600, 'test', 101, now64()),
    (['myapp.herokuapp.com'], ['Beta LLC'], ['ENG'], ['NY'], ['NY'], ['US'],
     'SN-HK-002', now64(), now64()+3600, 'test', 102, now64());

/*------------------------------------------------------------------*
 * 3️⃣  Negative-match sanity (example.com)                          *
 *------------------------------------------------------------------*/
INSERT INTO ct_certificates
    (dns, org, sn, nbf, naf, log, li, lts)
SETTINGS async_insert = 0, wait_for_async_insert = 1
VALUES
    (['example.com'], ['No Match Co'],
     'SN-NO-003', now64(), now64()+3600, 'test', 103, now64());

/*------------------------------------------------------------------*
 * 4️⃣  Correctness edge-cases                                       *
 *------------------------------------------------------------------*/
/* 4-a  Empty-array cert (dns only) */
INSERT INTO ct_certificates
    (dns, org, sn, nbf, naf, log, li, lts)
SETTINGS async_insert = 0, wait_for_async_insert = 1
VALUES
    (['lonely.example'], [], 'SN-EMPTY', now64(), now64()+3600, 'test', 104, now64());

/* 4-b  Multi-SAN cert (two domains) */
INSERT INTO ct_certificates
    (dns, org, ou, sn, nbf, naf, log, li, lts)
SETTINGS async_insert = 0, wait_for_async_insert = 1
VALUES
    (['a.one.com','b.one.com'], ['One Org'], ['OPS'],
     'SN-MULTI', now64(), now64()+3600, 'test', 105, now64());

/* 4-c  Case variance (GiTlAb) */
INSERT INTO ct_certificates
    (dns, org, sn, nbf, naf, log, li, lts)
SETTINGS async_insert = 0, wait_for_async_insert = 1
VALUES
    (['GiTlAb.AcMe.com'], ['Acme Inc'],
     'SN-CASE', now64(), now64()+3600, 'test', 106, now64());

/* 4-d  Bloom-filter sanity (splunk – not yet a pattern) */
INSERT INTO ct_certificates
    (dns, org, sn, nbf, naf, log, li, lts)
SETTINGS async_insert = 0, wait_for_async_insert = 1
VALUES
    (['splunk.test.io'], ['Probe Org'],
     'SN-SPLUNK1', now64(), now64()+3600, 'test', 107, now64());

/*------------------------------------------------------------------*
 * 5️⃣  Negative filter & suppression tests                          *
 *------------------------------------------------------------------*/
/* 5-a  Substring that should *not* match (parsingitlab.org) */
INSERT INTO ct_certificates
    (dns, org, sn, nbf, naf, log, li, lts)
SETTINGS async_insert = 0, wait_for_async_insert = 1
VALUES
    (['parsingitlab.org'], ['False Pos Inc'],
     'SN-FP', now64(), now64()+3600, 'test', 108, now64());

/* 5-b  Suppress GitLab for Acme Inc */
INSERT INTO tech_signals
    (ts, org_id, registrable, tech, confidence, source, evidence, is_negative)
SELECT
    now64(),                                   -- ts
    org_id('Acme Inc'),                        -- org_id
    'acme.com',                                -- registrable
    'GitLab',                                  -- tech
    0,                                         -- confidence
    'manual',                                  -- source
    [tuple('note','suppression')],             -- evidence
    1;                                         -- is_negative

/*------------------------------------------------------------------*
 * 6️⃣  Dictionary live-reload tests                                 *
 *------------------------------------------------------------------*/
/* 6-a  Add new token pattern (Splunk) */
INSERT INTO tech_patterns (id, pattern, is_regex, tech, weight)
VALUES (9100, 'splunk', 0, 'Splunk', 1);
SYSTEM RELOAD DICTIONARY dict_tech_patterns;

/* 6-b  Insert Splunk cert → should match immediately */
INSERT INTO ct_certificates
    (dns, org, sn, nbf, naf, log, li, lts)
SETTINGS async_insert = 0, wait_for_async_insert = 1
VALUES
    (['splunk.test.io'], ['Probe Org'],
     'SN-SPLUNK2', now64(), now64()+3600, 'test', 109, now64());

/* 6-c  Update regex_prefix for Heroku → match heroku.net */
ALTER TABLE tech_patterns
    UPDATE regex_prefix = 'heroku'
    WHERE id = 9002
    SETTINGS mutations_sync = 1;
SYSTEM RELOAD DICTIONARY dict_regex_prefixes;
INSERT INTO ct_certificates
    (dns, org, sn, nbf, naf, log, li, lts)
SETTINGS async_insert = 0, wait_for_async_insert = 1
VALUES
    (['foo.heroku.net'], ['Beta LLC'],
     'SN-HK-003', now64(), now64()+3600, 'test', 110, now64());

/*------------------------------------------------------------------*
 * 7️⃣  Lower GitLab weight → 0.3                                    *
 *------------------------------------------------------------------*/
ALTER TABLE tech_patterns
    UPDATE weight = 0.3
    WHERE id = 9001
    SETTINGS mutations_sync = 1;
SYSTEM RELOAD DICTIONARY dict_tech_patterns;

INSERT INTO ct_certificates
    (dns, org, sn, nbf, naf, log, li, lts)
SETTINGS async_insert = 0, wait_for_async_insert = 1
VALUES
    (['gitlab.acme.com'], ['Acme Inc'],
     'SN-GL-NEW', now64(), now64()+3600, 'test', 111, now64());

/*------------------------------------------------------------------*
 * 8️⃣  Assertions / reports                                         *
 *------------------------------------------------------------------*/

/* 8-a  dns_flat row count (7 SANs: gitlab, heroku, example, lonely, 2×one.com, splunk) */
SELECT 'dns_flat rows' AS stage, count() AS n FROM dns_flat;

/* 8-b  tech_signals: should include Splunk + new Heroku prefix, exclude example.com & parsingitlab.org */
SELECT 'tech_signals last 10' AS stage,
       registrable, tech, confidence, source
FROM tech_signals
ORDER BY ts DESC
LIMIT 10;

/* 8-c  suppression: GitLab for Acme should now be <= 0.3 */
SELECT 'Acme GitLab signals' AS stage,
       confidence,
       is_negative
FROM tech_signals
WHERE lower(registrable) = 'acme.com'        -- WHERE first
  AND tech = 'GitLab'
ORDER BY ts DESC;                            

/* 8-d  final facts (deduped) */
OPTIMIZE TABLE mv_org_tech FINAL;
SELECT 'org_tech_facts final' AS stage,
       tech, confidence, last_seen
FROM org_tech_facts
FINAL
ORDER BY last_seen DESC;

/*------------------------------------------------------------------*
 * 9️⃣  Org Clustering & Autocomplete (alias map, clustered autocomp)*
 *------------------------------------------------------------------*/

/* 9-a. Insert “JPMorgan Chase” family with overlapping domains */
INSERT INTO ct_certificates
    (dns, org, sn, nbf, naf, log, li, lts)
SETTINGS async_insert = 0, wait_for_async_insert = 1
VALUES
    (['jpmorganchase.com', 'chase.com'],               ['JPMorgan Chase & Co'],            'SN-JPM-1', now64(), now64()+3600, 'test', 201, now64()),
    (['jpmorgan.com', 'chase.com'],                    ['JPMorgan Chase and Co'],          'SN-JPM-2', now64(), now64()+3600, 'test', 202, now64()),
    (['jpmorganchase.com'],                            ['JPMorgan Chase'],                 'SN-JPM-3', now64(), now64()+3600, 'test', 203, now64()),
    (['jpmorganchase.com', 'jpmcfinancial.com'],       ['JPMorgan Chase Financial Services'],'SN-JPM-4', now64(), now64()+3600, 'test', 204, now64()),
    (['jpmorganchase.com', 'jpmcbusiness.com', 'chase.com'], ['JPMorgan Chase Business Banking'], 'SN-JPM-5', now64(), now64()+3600, 'test', 205, now64());
    
/* 9-b. Insert unrelated org for sanity */
INSERT INTO ct_certificates
    (dns, org, sn, nbf, naf, log, li, lts)
SETTINGS async_insert = 0, wait_for_async_insert = 1
VALUES
    (['usbank.com'], ['U.S. Bank'], 'SN-USB-1', now64(), now64()+3600, 'test', 204, now64());

/* 9-c. Force refresh (optional, if not waiting for scheduled MV update) */
INSERT INTO org_root_sets
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

INSERT INTO dns_flat SELECT * FROM mv_dns_flat;
SYSTEM REFRESH VIEW org_alias_map_mv;
SYSTEM REFRESH VIEW org_autocomplete_clustered_mv;

/* 9-d. Assert that clustering worked (should yield a single cluster_id for all JPMorgan orgs, with all names as aliases) */
SELECT
    'JPM cluster' AS stage,
    cluster_id,
    aliases,
    display_name,
    cert_count
FROM org_autocomplete_clustered
WHERE has(aliases, 'JPMorgan Chase & Co')
   OR has(aliases, 'JPMorgan Chase and Co')
   OR has(aliases, 'JPMorgan Chase')
   OR has(aliases, 'JPMorgan Chase Financial Services')
   OR has(aliases, 'JPMorgan Chase Business Banking')
ORDER BY cert_count DESC;

/* 9-e. Check alias map directly: verify org_ids are mapped as aliases */
SELECT
    'JPM alias map' AS stage,
    alias_id,
    canonical_id,
    shared,
    inter_cnt
FROM org_alias_map
WHERE inter_cnt >= 1
  AND (alias_id IN (
        SELECT org_id('JPMorgan Chase & Co')
        UNION ALL
        SELECT org_id('JPMorgan Chase and Co')
        UNION ALL
        SELECT org_id('JPMorgan Chase')
        UNION ALL
        SELECT org_id('JPMorgan Chase Financial Services')
        UNION ALL
        SELECT org_id('JPMorgan Chase Business Banking')
      )
   OR canonical_id IN (
        SELECT org_id('JPMorgan Chase & Co')
        UNION ALL
        SELECT org_id('JPMorgan Chase and Co')
        UNION ALL
        SELECT org_id('JPMorgan Chase')
        UNION ALL
        SELECT org_id('JPMorgan Chase Financial Services')
        UNION ALL
        SELECT org_id('JPMorgan Chase Business Banking')
      ))
ORDER BY inter_cnt DESC;

/* 9-f. Simulate autocomplete query: fuzzy search */
SELECT
    'JPM autocomplete' AS stage,
    display_name,
    cert_count,
    aliases
FROM org_autocomplete_clustered
WHERE display_name ILIKE '%jpmorgan%'
   OR arrayExists(x -> positionCaseInsensitive(x, 'jpmorgan') > 0, aliases)
ORDER BY cert_count DESC
LIMIT 5;

/* 9-g. Negative test: unrelated org should not be clustered */
SELECT
    'USB cluster' AS stage,
    display_name,
    aliases
FROM org_autocomplete_clustered
WHERE display_name ILIKE '%bank%';
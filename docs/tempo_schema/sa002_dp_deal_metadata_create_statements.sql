CREATE
OR REPLACE VIEW "dp_deal_metadata"."agreements_detailed_rights_v" AS
SELECT
   sh.agreement_id,
   ag.agreement_nm,
   sh.agreement_rights_group_id,
   arg.agreement_rights_group_nm,
   sh.right_type_id,
   NULL:: character varying AS right_type_nm,
   sh.income_type_group_id,
   itg.income_type_group_nm,
   sh.creator_share_pc,
   sh.publisher_share_pc,
   sh.our_collectable_share_pc,
   sh.create_id,
   sh.create_dt,
   sh.update_id,
   sh.update_dt
FROM
   edw.tempo_agreement_rights_group_shares sh
   JOIN edw.tempo_agreement ag ON ag.agreement_id = sh.agreement_id
   LEFT JOIN edw.tempo_agreement_rights_group arg ON arg.agreement_rights_group_id = sh.agreement_rights_group_id
   LEFT JOIN edw.tempo_income_type_group itg ON itg.income_type_group_id = sh.income_type_group_id
WHERE
   sh.prior_version_ind:: text = 'N':: text;

CREATE
OR REPLACE VIEW "dp_deal_metadata"."client_contract_song_episodic_production_v" AS
SELECT
  DISTINCT tc.client_id,
  tc.client_name,
  c.contract_id,
  c.contract_nm,
  "ts".song_id AS production_id,
  "ts".song_sequence_id AS episode_sequence_id,
  ts2.song_title_tx AS production_title_tx,
  "ts".song_title_tx AS episode_title_tx,
  tsrc.active_ind
FROM
  edw.tempo_song "ts"
  JOIN edw.tempo_song_rate_client tsrc ON "ts".song_id = tsrc.song_id
  AND "ts".song_sequence_id = tsrc.song_sequence_id
  AND "ts".prior_version_ind:: text = tsrc.prior_version_ind:: text
  JOIN edw.tempo_client tc ON tsrc.client_id = tc.client_id
  AND "ts".prior_version_ind:: text = tc.prior_version_ind:: text
  JOIN edw.tempo_contract c ON tsrc.contract_id = c.contract_id
  AND "ts".prior_version_ind:: text = c.prior_version_ind:: text
  JOIN edw.tempo_song ts2 ON "ts".song_id = ts2.song_id
  AND ts2.song_sequence_id = 0
  AND "ts".song_type_id = ts2.song_type_id
  AND "ts".prior_version_ind:: text = ts2.prior_version_ind:: text
WHERE
  "ts".song_sequence_id > 0
  AND "ts".song_type_id = 3
  AND "ts".prior_version_ind:: text = 'N':: text
UNION
SELECT
  DISTINCT tc.client_id,
  tc.client_name,
  c.contract_id,
  c.contract_nm,
  "ts".song_id AS production_id,
  "ts".song_sequence_id AS episode_sequence_id,
  ts2.song_title_tx AS production_title_tx,
  "ts".song_title_tx AS episode_title_tx,
  tsrc.active_ind
FROM
  edw.tempo_song "ts"
  JOIN edw.tempo_song_rate_client tsrc ON "ts".song_id = tsrc.song_id
  AND tsrc.song_sequence_id = 0
  AND "ts".prior_version_ind:: text = tsrc.prior_version_ind:: text
  JOIN edw.tempo_client tc ON tsrc.client_id = tc.client_id
  AND "ts".prior_version_ind:: text = tc.prior_version_ind:: text
  JOIN edw.tempo_contract c ON tsrc.contract_id = c.contract_id
  AND "ts".prior_version_ind:: text = c.prior_version_ind:: text
  JOIN edw.tempo_song ts2 ON "ts".song_id = ts2.song_id
  AND ts2.song_sequence_id = 0
  AND ts2.song_type_id = 3
  AND "ts".prior_version_ind:: text = ts2.prior_version_ind:: text
WHERE
  "ts".song_sequence_id > 0
  AND "ts".song_type_id = 3
  AND "ts".prior_version_ind:: text = 'N':: text
  AND NOT (
    EXISTS (
      SELECT
        1
      FROM
        edw.tempo_song_rate_client tsrc_inner
      WHERE
        tsrc_inner.song_id = "ts".song_id
        AND tsrc_inner.song_sequence_id = "ts".song_sequence_id
        AND tsrc_inner.prior_version_ind:: text = 'N':: text
        AND tsrc_inner.active_ind:: text = tsrc.active_ind:: text
    )
  );

CREATE
OR REPLACE VIEW "dp_deal_metadata"."client_contract_song_production_v" AS
SELECT
   DISTINCT tc.client_id,
   tc.client_name,
   tct.contract_id,
   tct.contract_nm,
   src.song_id,
   src.song_sequence_id,
   "ts".song_title_tx,
   src.active_ind
FROM
   edw.tempo_song_rate_client src
   JOIN edw.tempo_client tc ON tc.client_id = src.client_id
   AND tc.prior_version_ind:: text = src.prior_version_ind:: text
   JOIN edw.tempo_contract tct ON tct.contract_id = src.contract_id
   AND tct.prior_version_ind:: text = src.prior_version_ind:: text
   JOIN edw.tempo_song "ts" ON src.song_id = "ts".song_id
   AND "ts".song_sequence_id = src.song_sequence_id
   AND "ts".prior_version_ind:: text = src.prior_version_ind:: text
   AND "ts".song_type_id = 2
WHERE
   src.prior_version_ind:: text = 'N':: text
   AND src.song_sequence_id = 0;

CREATE
OR REPLACE VIEW "dp_deal_metadata"."client_contract_song_v" AS
SELECT
   DISTINCT tc.client_id,
   tc.client_name,
   tct.contract_id,
   tct.contract_nm,
   src.song_id,
   src.song_sequence_id,
   "ts".song_title_tx,
   src.active_ind
FROM
   edw.tempo_song_rate_client src
   JOIN edw.tempo_client tc ON tc.client_id = src.client_id
   AND tc.prior_version_ind:: text = src.prior_version_ind:: text
   JOIN edw.tempo_contract tct ON tct.contract_id = src.contract_id
   AND tct.prior_version_ind:: text = src.prior_version_ind:: text
   JOIN edw.tempo_song "ts" ON src.song_id = "ts".song_id
   AND "ts".song_sequence_id = src.song_sequence_id
   AND "ts".prior_version_ind:: text = src.prior_version_ind:: text
   AND "ts".song_type_id = 1
WHERE
   src.prior_version_ind:: text = 'N':: text
   AND src.song_sequence_id = 0;

CREATE
OR REPLACE VIEW "dp_deal_metadata"."client_contract_v" AS
SELECT
   DISTINCT c.client_id,
   c.client_nm,
   c.cross_to_client_id,
   c.cross_to_client_nm,
   c.pnl_grouping_client_id,
   c.pnl_grouping_client_nm,
   c.client_type_id,
   c.client_type_nm,
   c.agreement_id,
   c.agreement_nm,
   c.company_cd,
   c.company_nm,
   c.company_group_cd,
   c.company_group_nm,
   c.orig_office_id,
   c.orig_office_nm,
   c.signing_office_id,
   c.signing_office_nm,
   c.statement_run_group_cd,
   c.statement_run_group_nm,
   c.statement_frequency_nm,
   c.client_commencement_dt,
   c.film_tv_ind,
   c.expired_client_ind,
   c.intercompany_client_ind,
   c.migrated_client_id,
   c.third_party_client_id,
   c.client_hold_tx,
   c.signing_rep_nm,
   c.current_rep_nm,
   cv.contract_id,
   cv.contract_nm,
   cv.contract_aka_nm,
   cv.contract_type_id,
   cv.contract_type_nm,
   cv.contract_commencement_dt,
   cv.contracting_party_nm,
   cv.samp_contracting_party_nm,
   cv.migrated_contract_id,
   cv.contract_hold_tx,
   cv.first_royalty_period_dt,
   cv.contract_expiration_dt
FROM
   dp_deal_metadata.client_v c
   JOIN edw.tempo_client_contract tc ON c.client_id = tc.client_id
   AND tc.prior_version_ind:: text = 'N':: character varying:: text
   JOIN dp_deal_metadata.contract_v cv ON cv.contract_id = tc.contract_id;

CREATE
OR REPLACE VIEW "dp_deal_metadata"."client_payee_v" AS
SELECT
   tcp.client_id,
   tc.client_name,
   tcp.payee_id,
   tp.payee_name,
   tcp.hold_description_tx,
   tcp.inactive_ind,
   tcp.inactive_date
FROM
   edw.tempo_client_payee tcp
   JOIN edw.tempo_client tc ON tcp.client_id = tc.client_id
   JOIN edw.tempo_payee tp ON tcp.payee_id = tp.payee_id
WHERE
   tc.prior_version_ind:: text = 'N':: text
   AND tp.prior_version_ind:: text = 'N':: text
   AND tcp.prior_version_ind:: text = 'N':: text;

CREATE
OR REPLACE VIEW "dp_deal_metadata"."client_song_episodic_production_v" AS
SELECT
  DISTINCT tc.client_id,
  tc.client_name,
  "ts".song_id AS production_id,
  "ts".song_sequence_id AS episode_sequence_id,
  ts2.song_title_tx AS production_title_tx,
  "ts".song_title_tx AS episode_title_tx,
  tsrc.active_ind
FROM
  edw.tempo_song "ts"
  JOIN edw.tempo_song_rate_client tsrc ON "ts".song_id = tsrc.song_id
  AND "ts".song_sequence_id = tsrc.song_sequence_id
  AND tsrc.prior_version_ind:: text = 'N':: text
  JOIN edw.tempo_client tc ON tsrc.client_id = tc.client_id
  AND tc.prior_version_ind:: text = 'N':: text
  JOIN edw.tempo_song ts2 ON "ts".song_id = ts2.song_id
  AND ts2.song_sequence_id = 0
  AND ts2.song_type_id = 3
  AND ts2.prior_version_ind:: text = 'N':: text
WHERE
  "ts".song_sequence_id > 0
  AND "ts".song_type_id = 3
  AND "ts".prior_version_ind:: text = 'N':: text
UNION
SELECT
  DISTINCT tc.client_id,
  tc.client_name,
  "ts".song_id AS production_id,
  "ts".song_sequence_id AS episode_sequence_id,
  ts2.song_title_tx AS production_title_tx,
  "ts".song_title_tx AS episode_title_tx,
  tsrc.active_ind
FROM
  edw.tempo_song "ts"
  JOIN edw.tempo_song_rate_client tsrc ON "ts".song_id = tsrc.song_id
  AND tsrc.song_sequence_id = 0
  AND tsrc.prior_version_ind:: text = 'N':: text
  JOIN edw.tempo_client tc ON tsrc.client_id = tc.client_id
  AND tc.prior_version_ind:: text = 'N':: text
  JOIN edw.tempo_song ts2 ON "ts".song_id = ts2.song_id
  AND ts2.song_sequence_id = 0
  AND ts2.song_type_id = 3
  AND ts2.prior_version_ind:: text = 'N':: text
WHERE
  "ts".song_sequence_id > 0
  AND "ts".song_type_id = 3
  AND "ts".prior_version_ind:: text = 'N':: text
  AND NOT (
    EXISTS (
      SELECT
        1
      FROM
        edw.tempo_song_rate_client tsrc_inner
      WHERE
        tsrc_inner.song_id = "ts".song_id
        AND tsrc_inner.song_sequence_id = "ts".song_sequence_id
        AND tsrc_inner.prior_version_ind:: text = 'N':: text
        AND tsrc_inner.active_ind:: text = tsrc.active_ind:: text
    )
  );

CREATE
OR REPLACE VIEW "dp_deal_metadata"."client_song_production_v" AS
SELECT
   DISTINCT tc.client_id,
   tc.client_name,
   src.song_id AS production_id,
   "ts".song_sequence_id AS production_seqeunce_id,
   "ts".song_title_tx AS production_title_tx,
   src.active_ind
FROM
   edw.tempo_client tc
   JOIN edw.tempo_song_rate_client src ON tc.client_id = src.client_id
   AND src.prior_version_ind:: text = tc.prior_version_ind:: text
   AND src.song_sequence_id = 0
   JOIN edw.tempo_song "ts" ON "ts".song_id = src.song_id
   AND "ts".prior_version_ind:: text = tc.prior_version_ind:: text
   AND "ts".song_type_id = 2
   AND "ts".song_sequence_id = src.song_sequence_id
WHERE
   tc.prior_version_ind:: text = 'N':: text;

CREATE
OR REPLACE VIEW "dp_deal_metadata"."client_song_v" AS
SELECT
   DISTINCT tc.client_id,
   tc.client_name,
   src.song_id,
   src.song_sequence_id,
   "ts".song_title_tx,
   src.active_ind
FROM
   edw.tempo_client tc
   JOIN edw.tempo_song_rate_client src ON tc.client_id = src.client_id
   AND src.prior_version_ind:: text = tc.prior_version_ind:: text
   AND src.song_sequence_id = 0
   JOIN edw.tempo_song "ts" ON src.song_id = "ts".song_id
   AND src.song_sequence_id = "ts".song_sequence_id
   AND "ts".prior_version_ind:: text = tc.prior_version_ind:: text
   AND "ts".song_type_id = 1
WHERE
   tc.prior_version_ind:: text = 'N':: text;

CREATE
OR REPLACE VIEW "dp_deal_metadata"."client_v" AS
SELECT
    tc.client_id,
    tc.client_name AS client_nm,
    CASE
    WHEN tc.cross_to_client_id = NULL:: integer
    OR tc.cross_to_client_id IS NULL
    AND NULL:: "unknown" IS NULL THEN tc.client_id
    ELSE tc.cross_to_client_id END AS cross_to_client_id,
    CASE
    WHEN tc2.client_name:: text = NULL:: character varying:: text
    OR tc2.client_name IS NULL
    AND NULL:: "unknown" IS NULL THEN tc.client_name
    ELSE tc2.client_name END AS cross_to_client_nm,
    tc.pnl_grouping_client_id,
    tc.pnl_grouping_client_nm,
    tc.client_type_id,
    tct.client_type_nm,
    tc.agreement_id,
    ta.agreement_nm,
    tc.company_cd,
    tc3.company_nm,
    tc3.company_group_cd,
    tcg.company_group_nm,
    tc.orig_office_id,
    too.orig_office_nm,
    tc.signing_office_id,
    tso.signing_office_nm,
    tc.stmnt_run_group_cd AS statement_run_group_cd,
    tsrg.stmnt_run_group_nm AS statement_run_group_nm,
    tsf.stmnt_freq_nm AS statement_frequency_nm,
    tc.commencement_date AS client_commencement_dt,
    tc.client_expiration_dt AS client_termination_dt,
    tc.film_tv_ind,
    tc.expired_client_ind,
    tc.intercompany_client_ind,
    tc.migrated_client_no AS migrated_client_id,
    tc.third_party_client_id,
    chc.client_hold_tx,
    src.signing_rep_nm,
    crc.current_rep_nm,
    tci.create_dt AS tempo_create_date,
    tc.update_dt AS tempo_update_date
FROM
    edw.tempo_client tc
    LEFT JOIN edw.tempo_client_id tci ON tc.client_id = tci.client_id
    LEFT JOIN edw.tempo_client tc2 ON tc.cross_to_client_id = tc2.client_id
    AND tc2.prior_version_ind:: text = 'N':: character varying:: text
    JOIN edw.tempo_client_type tct ON tct.client_type_id = tc.client_type_id
    LEFT JOIN edw.tempo_agreement ta ON ta.agreement_id = tc.agreement_id
    AND ta.prior_version_ind:: text = 'N':: character varying:: text
    JOIN edw.tempo_company tc3 ON tc3.company_cd:: text = tc.company_cd:: text
    JOIN edw.tempo_company_group tcg ON tcg.company_group_cd:: text = tc3.company_group_cd:: text
    JOIN edw.tempo_orig_office too ON too.orig_office_id = tc.orig_office_id
    LEFT JOIN edw.tempo_signing_office tso ON tso.signing_office_id = tc.signing_office_id
    LEFT JOIN edw.tempo_statement_run_group tsrg ON tsrg.stmnt_run_group_cd:: text = tc.stmnt_run_group_cd:: text
    LEFT JOIN edw.tempo_statement_frequency tsf ON tsf.stmnt_freq_id = tsrg.stmnt_frequency_id
    LEFT JOIN (
        SELECT
            tc.client_id,
            pg_catalog.listagg(
                DISTINCT ths.hold_status_nm:: text,
                ', ':: character varying:: text
            ) WITHIN GROUP(
                ORDER BY
                    ths.hold_status_nm
            ) AS client_hold_tx
        FROM
            edw.tempo_client tc
            LEFT JOIN edw.tempo_client_payee_hold tcph ON tcph.client_id = tc.client_id
            JOIN edw.tempo_hold_status ths ON ths.hold_status_cd:: text = tcph.hold_status_cd:: text
        WHERE
            tc.prior_version_ind:: text = 'N':: character varying:: text
            AND tcph.prior_version_ind:: text = 'N':: character varying:: text
        GROUP BY
            tc.client_id
    ) chc ON chc.client_id = tc.client_id
    LEFT JOIN (
        SELECT
            tc.client_id,
            pg_catalog.listagg(
                DISTINCT tar.ar_rep_nm:: text,
                ', ':: character varying:: text
            ) WITHIN GROUP(
                ORDER BY
                    tar.ar_rep_nm
            ) AS signing_rep_nm
        FROM
            edw.tempo_client tc
            LEFT JOIN edw.tempo_client_ar_rep tcar ON tcar.client_id = tc.client_id
            LEFT JOIN edw.tempo_ar_rep tar ON tar.ar_rep_id = tcar.ar_rep_id
        WHERE
            tc.prior_version_ind:: text = 'N':: character varying:: text
            AND tcar.prior_version_ind:: text = 'N':: character varying:: text
            AND tcar.signing_ar_rep_ind:: text = 'Y':: character varying:: text
        GROUP BY
            tc.client_id
    ) src ON src.client_id = tc.client_id
    LEFT JOIN (
        SELECT
            tc.client_id,
            pg_catalog.listagg(
                DISTINCT tar.ar_rep_nm:: text,
                ', ':: character varying:: text
            ) WITHIN GROUP(
                ORDER BY
                    tar.ar_rep_nm
            ) AS current_rep_nm
        FROM
            edw.tempo_client tc
            LEFT JOIN edw.tempo_client_ar_rep tcar ON tcar.client_id = tc.client_id
            LEFT JOIN edw.tempo_ar_rep tar ON tar.ar_rep_id = tcar.ar_rep_id
        WHERE
            tc.prior_version_ind:: text = 'N':: character varying:: text
            AND tcar.prior_version_ind:: text = 'N':: character varying:: text
            AND tcar.signing_ar_rep_ind:: text = 'N':: character varying:: text
        GROUP BY
            tc.client_id
    ) crc ON crc.client_id = tc.client_id
WHERE
    tc.prior_version_ind:: text = 'N':: character varying:: text;

CREATE
OR REPLACE VIEW "dp_deal_metadata"."contract_song_episodic_production_v" AS
SELECT
  DISTINCT tco.contract_id,
  tco.contract_nm,
  "ts".song_id AS production_id,
  "ts".song_sequence_id AS episode_sequence_id,
  ts2.song_title_tx AS production_title_tx,
  "ts".song_title_tx AS episode_title_tx,
  src.active_ind
FROM
  edw.tempo_song "ts"
  JOIN edw.tempo_song_rate_client src ON "ts".song_id = src.song_id
  AND "ts".song_sequence_id = src.song_sequence_id
  AND src.prior_version_ind:: text = "ts".prior_version_ind:: text
  JOIN edw.tempo_contract tco ON tco.contract_id = src.contract_id
  AND tco.prior_version_ind:: text = src.prior_version_ind:: text
  JOIN edw.tempo_song ts2 ON "ts".song_id = ts2.song_id
  AND ts2.song_sequence_id = 0
  AND ts2.song_type_id = 3
  AND ts2.prior_version_ind:: text = "ts".prior_version_ind:: text
WHERE
  "ts".song_sequence_id > 0
  AND "ts".song_type_id = 3
  AND "ts".prior_version_ind:: text = 'N':: text
UNION
SELECT
  tco.contract_id,
  tco.contract_nm,
  "ts".song_id AS production_id,
  "ts".song_sequence_id AS episode_sequence_id,
  ts2.song_title_tx AS production_title_tx,
  "ts".song_title_tx AS episode_title_tx,
  src.active_ind
FROM
  edw.tempo_song "ts"
  JOIN edw.tempo_song_rate_client src ON "ts".song_id = src.song_id
  AND src.song_sequence_id = 0
  AND src.prior_version_ind:: text = "ts".prior_version_ind:: text
  JOIN edw.tempo_contract tco ON tco.contract_id = src.contract_id
  AND "ts".prior_version_ind:: text = tco.prior_version_ind:: text
  JOIN edw.tempo_song ts2 ON "ts".song_id = ts2.song_id
  AND ts2.song_sequence_id = 0
  AND ts2.song_type_id = 3
  AND ts2.prior_version_ind:: text = "ts".prior_version_ind:: text
WHERE
  "ts".song_sequence_id > 0
  AND "ts".song_type_id = 3
  AND "ts".prior_version_ind:: text = 'N':: text
  AND NOT (
    EXISTS (
      SELECT
        1
      FROM
        edw.tempo_song_rate_client src_inner
      WHERE
        src_inner.song_id = "ts".song_id
        AND src_inner.song_sequence_id = "ts".song_sequence_id
        AND src_inner.prior_version_ind:: text = 'N':: text
        AND src_inner.active_ind:: text = src.active_ind:: text
    )
  );

CREATE
OR REPLACE VIEW "dp_deal_metadata"."contract_song_production_v" AS
SELECT
   DISTINCT tco.contract_id,
   tco.contract_nm,
   src.song_id AS production_id,
   "ts".song_sequence_id AS production_sequence_id,
   "ts".song_title_tx AS production_title_tx,
   src.active_ind
FROM
   edw.tempo_contract tco
   JOIN edw.tempo_song_rate_client src ON tco.contract_id = src.contract_id
   AND src.prior_version_ind:: text = tco.prior_version_ind:: text
   AND src.song_sequence_id = 0
   JOIN edw.tempo_song "ts" ON "ts".song_id = src.song_id
   AND "ts".prior_version_ind:: text = src.prior_version_ind:: text
   AND "ts".song_sequence_id = src.song_sequence_id
   AND "ts".song_type_id = 2
WHERE
   tco.prior_version_ind:: text = 'N':: text;
   
CREATE
OR REPLACE VIEW "dp_deal_metadata"."contract_song_v" AS
SELECT
   DISTINCT tco.contract_id,
   tco.contract_nm,
   src.song_id,
   "ts".song_sequence_id,
   "ts".song_title_tx,
   src.active_ind
FROM
   edw.tempo_contract tco
   JOIN edw.tempo_song_rate_client src ON tco.contract_id = src.contract_id
   AND src.prior_version_ind:: text = tco.prior_version_ind:: text
   AND src.song_sequence_id = 0
   JOIN edw.tempo_song "ts" ON "ts".song_id = src.song_id
   AND "ts".prior_version_ind:: text = src.prior_version_ind:: text
   AND "ts".song_sequence_id = src.song_sequence_id
   AND "ts".song_type_id = 1
WHERE
   tco.prior_version_ind:: text = 'N':: text;

CREATE
OR REPLACE VIEW "dp_deal_metadata"."contract_v" AS
SELECT
  c.contract_id,
  c.contract_nm,
  c.contract_aka_nm,
  ct.contract_type_id,
  ct.contract_type_nm,
  o.orig_office_id,
  o.orig_office_nm,
  c.contract_commencement_dt,
  c.life_of_copyright_ind,
  c.retention_years,
  c.collection_end_months,
  c.contracting_party_nm,
  c.samp_contracting_party_nm,
  c.migrated_contract_id,
  c.third_party_deal_id,
  pg_catalog.listagg(h.hold_status_cd:: text, ', ':: text) WITHIN GROUP(
    ORDER BY
      h.hold_status_nm
  ) AS contract_hold_cd,
  pg_catalog.listagg(h.hold_status_nm:: text, ', ':: text) WITHIN GROUP(
    ORDER BY
      h.hold_status_nm
  ) AS contract_hold_tx,
  c.first_royalty_period_dt,
  c.contract_expiration_dt,
  ci.create_dt AS tempo_create_date,
  c.update_dt AS tempo_update_date,
  ts1.society_nm AS mech_society,
  ts2.society_nm AS preferred_us_mech_society,
  ts3.society_nm AS perf_society,
  ts4.society_nm AS preferred_us_perf_society,
  c.blackbox_processing_ind
FROM
  edw.tempo_contract c
  JOIN edw.tempo_contract_type ct ON c.contract_type_id = ct.contract_type_id
  JOIN edw.tempo_contract_id ci ON c.contract_id = ci.contract_id
  LEFT JOIN edw.tempo_contract_hold ch ON c.contract_id = ch.contract_id
  AND ch.prior_version_ind:: text = 'N':: text
  LEFT JOIN edw.tempo_hold_status h ON ch.hold_status_cd:: text = h.hold_status_cd:: text
  JOIN edw.tempo_orig_office o ON c.orig_office_id = o.orig_office_id
  JOIN edw.tempo_society ts1 ON c.mechanical_society_cd = ts1.society_cd
  JOIN edw.tempo_society ts2 ON c.preferred_us_mech_society_cd = ts2.society_cd
  JOIN edw.tempo_society ts3 ON c.performance_society_cd = ts3.society_cd
  JOIN edw.tempo_society ts4 ON c.preferred_us_perf_society_cd = ts4.society_cd
WHERE
  c.prior_version_ind:: text = 'N':: text
GROUP BY
  c.contract_id,
  c.contract_nm,
  c.contract_aka_nm,
  ct.contract_type_id,
  ct.contract_type_nm,
  o.orig_office_id,
  o.orig_office_nm,
  c.contract_commencement_dt,
  c.life_of_copyright_ind,
  c.retention_years,
  c.collection_end_months,
  c.contracting_party_nm,
  c.samp_contracting_party_nm,
  c.migrated_contract_id,
  c.third_party_deal_id,
  c.first_royalty_period_dt,
  c.contract_expiration_dt,
  ci.create_dt,
  c.update_dt,
  ts1.society_nm,
  ts2.society_nm,
  ts3.society_nm,
  ts4.society_nm,
  c.blackbox_processing_ind;

CREATE
OR REPLACE VIEW "dp_deal_metadata"."cross_client_song_episodic_production_v" AS
SELECT
  DISTINCT COALESCE(tc2.client_id, tc.client_id) AS cross_client_id,
  COALESCE(tc2.client_name, tc.client_name) AS cross_client_name,
  "ts".song_id,
  "ts".song_sequence_id,
  ts2.song_title_tx AS production_title_tx,
  "ts".song_title_tx AS episode_title_tx,
  tsrc.active_ind
FROM
  edw.tempo_song "ts"
  JOIN edw.tempo_song_rate_client tsrc ON "ts".song_id = tsrc.song_id
  AND "ts".song_sequence_id = tsrc.song_sequence_id
  AND tsrc.prior_version_ind:: text = 'N':: text
  JOIN edw.tempo_client tc ON tsrc.client_id = tc.client_id
  AND tc.prior_version_ind:: text = 'N':: text
  JOIN edw.tempo_song ts2 ON "ts".song_id = ts2.song_id
  AND ts2.song_sequence_id = 0
  AND ts2.song_type_id = 3
  AND ts2.prior_version_ind:: text = 'N':: text
  LEFT JOIN edw.tempo_client tc2 ON tc2.client_id = tc.cross_to_client_id
  AND tc2.prior_version_ind:: text = tc.prior_version_ind:: text
WHERE
  "ts".song_sequence_id > 0
  AND "ts".song_type_id = 3
  AND "ts".prior_version_ind:: text = 'N':: text
UNION
SELECT
  DISTINCT COALESCE(tc2.client_id, tc.client_id) AS cross_client_id,
  COALESCE(tc2.client_name, tc.client_name) AS cross_client_name,
  "ts".song_id,
  "ts".song_sequence_id,
  ts2.song_title_tx AS production_title_tx,
  "ts".song_title_tx AS episode_title_tx,
  tsrc.active_ind
FROM
  edw.tempo_song "ts"
  JOIN edw.tempo_song_rate_client tsrc ON "ts".song_id = tsrc.song_id
  AND tsrc.song_sequence_id = 0
  AND tsrc.prior_version_ind:: text = 'N':: text
  JOIN edw.tempo_client tc ON tsrc.client_id = tc.client_id
  AND tc.prior_version_ind:: text = 'N':: text
  JOIN edw.tempo_song ts2 ON "ts".song_id = ts2.song_id
  AND ts2.song_sequence_id = 0
  AND ts2.song_type_id = 3
  AND ts2.prior_version_ind:: text = 'N':: text
  LEFT JOIN edw.tempo_client tc2 ON tc2.client_id = tc.cross_to_client_id
  AND tc2.prior_version_ind:: text = tc.prior_version_ind:: text
WHERE
  "ts".song_sequence_id > 0
  AND "ts".song_type_id = 3
  AND "ts".prior_version_ind:: text = 'N':: text
  AND NOT (
    EXISTS (
      SELECT
        1
      FROM
        edw.tempo_song_rate_client tsrc_inner
      WHERE
        tsrc_inner.song_id = "ts".song_id
        AND tsrc_inner.song_sequence_id = "ts".song_sequence_id
        AND tsrc_inner.prior_version_ind:: text = 'N':: text
        AND tsrc_inner.active_ind:: text = tsrc.active_ind:: text
    )
  );

CREATE
OR REPLACE VIEW "dp_deal_metadata"."cross_client_song_production_v" AS
SELECT
   DISTINCT COALESCE(tc2.client_id, tc.client_id) AS cross_client_id,
   COALESCE(tc2.client_name, tc.client_name) AS cross_client_name,
   src.song_id AS production_id,
   "ts".song_sequence_id AS production_sequence_id,
   "ts".song_title_tx AS production_title_tx,
   src.active_ind
FROM
   edw.tempo_client tc
   JOIN edw.tempo_song_rate_client src ON tc.client_id = src.client_id
   AND src.prior_version_ind:: text = tc.prior_version_ind:: text
   AND src.song_sequence_id = 0
   JOIN edw.tempo_song "ts" ON "ts".song_id = src.song_id
   AND "ts".prior_version_ind:: text = src.prior_version_ind:: text
   AND "ts".song_sequence_id = src.song_sequence_id
   AND "ts".song_type_id = 2
   LEFT JOIN edw.tempo_client tc2 ON tc2.client_id = tc.cross_to_client_id
   AND tc2.prior_version_ind:: text = tc.prior_version_ind:: text
WHERE
   tc.prior_version_ind:: text = 'N':: text;

CREATE
OR REPLACE VIEW "dp_deal_metadata"."cross_client_song_v" AS
SELECT
   DISTINCT COALESCE(tc2.client_id, tc.client_id) AS cross_client_id,
   COALESCE(tc2.client_name, tc.client_name) AS cross_client_name,
   src.song_id,
   "ts".song_sequence_id,
   "ts".song_title_tx,
   src.active_ind
FROM
   edw.tempo_client tc
   JOIN edw.tempo_song_rate_client src ON tc.client_id = src.client_id
   AND src.prior_version_ind:: text = tc.prior_version_ind:: text
   AND src.song_sequence_id = 0
   JOIN edw.tempo_song "ts" ON "ts".song_id = src.song_id
   AND "ts".prior_version_ind:: text = src.prior_version_ind:: text
   AND "ts".song_sequence_id = src.song_sequence_id
   AND "ts".song_type_id = 1
   LEFT JOIN edw.tempo_client tc2 ON tc2.client_id = tc.cross_to_client_id
   AND tc2.prior_version_ind:: text = tc.prior_version_ind:: text
WHERE
   tc.prior_version_ind:: text = 'N':: text;

CREATE
OR REPLACE VIEW "dp_deal_metadata"."pnl_client_song_episodic_production_v" AS
SELECT
  DISTINCT tc.pnl_grouping_client_id,
  tc.pnl_grouping_client_nm AS pnl_grouping_client_name,
  "ts".song_id AS production_id,
  "ts".song_sequence_id AS episode_sequence_id,
  ts2.song_title_tx AS production_title_tx,
  "ts".song_title_tx AS episode_title_tx,
  tsrc.active_ind
FROM
  edw.tempo_song "ts"
  JOIN edw.tempo_song_rate_client tsrc ON "ts".song_id = tsrc.song_id
  AND "ts".song_sequence_id = tsrc.song_sequence_id
  AND tsrc.prior_version_ind:: text = 'N':: text
  JOIN edw.tempo_client tc ON tsrc.client_id = tc.client_id
  AND tc.prior_version_ind:: text = 'N':: text
  JOIN edw.tempo_song ts2 ON "ts".song_id = ts2.song_id
  AND ts2.song_sequence_id = 0
  AND ts2.song_type_id = 3
  AND ts2.prior_version_ind:: text = 'N':: text
WHERE
  "ts".song_sequence_id > 0
  AND "ts".song_type_id = 3
  AND "ts".prior_version_ind:: text = 'N':: text
UNION
SELECT
  DISTINCT tc.pnl_grouping_client_id,
  tc.pnl_grouping_client_nm AS pnl_grouping_client_name,
  "ts".song_id AS production_id,
  "ts".song_sequence_id AS episode_sequence_id,
  ts2.song_title_tx AS production_title_tx,
  "ts".song_title_tx AS episode_title_tx,
  tsrc.active_ind
FROM
  edw.tempo_song "ts"
  JOIN edw.tempo_song_rate_client tsrc ON "ts".song_id = tsrc.song_id
  AND tsrc.song_sequence_id = 0
  AND tsrc.prior_version_ind:: text = 'N':: text
  JOIN edw.tempo_client tc ON tsrc.client_id = tc.client_id
  AND tc.prior_version_ind:: text = 'N':: text
  JOIN edw.tempo_song ts2 ON "ts".song_id = ts2.song_id
  AND ts2.song_sequence_id = 0
  AND ts2.song_type_id = 3
  AND ts2.prior_version_ind:: text = 'N':: text
WHERE
  "ts".song_sequence_id > 0
  AND "ts".song_type_id = 3
  AND "ts".prior_version_ind:: text = 'N':: text
  AND NOT (
    EXISTS (
      SELECT
        1
      FROM
        edw.tempo_song_rate_client tsrc_inner
      WHERE
        tsrc_inner.song_id = "ts".song_id
        AND tsrc_inner.song_sequence_id = "ts".song_sequence_id
        AND tsrc_inner.prior_version_ind:: text = 'N':: text
        AND tsrc_inner.active_ind:: text = tsrc.active_ind:: text
    )
  );

CREATE
OR REPLACE VIEW "dp_deal_metadata"."pnl_client_song_production_v" AS
SELECT
   DISTINCT tc.pnl_grouping_client_id,
   tc.pnl_grouping_client_nm AS pnl_grouping_client_name,
   src.song_id AS production_id,
   "ts".song_sequence_id AS production_sequence_id,
   "ts".song_title_tx AS production_title_tx,
   src.active_ind
FROM
   edw.tempo_client tc
   JOIN edw.tempo_song_rate_client src ON tc.client_id = src.client_id
   AND src.prior_version_ind:: text = tc.prior_version_ind:: text
   AND src.song_sequence_id = 0
   JOIN edw.tempo_song "ts" ON "ts".song_id = src.song_id
   AND "ts".song_type_id = 2
   AND "ts".prior_version_ind:: text = tc.prior_version_ind:: text
   AND "ts".song_sequence_id = src.song_sequence_id
WHERE
   tc.prior_version_ind:: text = 'N':: text;

CREATE
OR REPLACE VIEW "dp_deal_metadata"."pnl_client_song_v" AS
SELECT
   DISTINCT src.song_id,
   src.song_sequence_id,
   "ts".song_title_tx,
   tc.pnl_grouping_client_id,
   tc.pnl_grouping_client_nm,
   src.active_ind
FROM
   edw.tempo_client tc
   JOIN edw.tempo_song_rate_client src ON tc.client_id = src.client_id
   AND src.prior_version_ind:: text = tc.prior_version_ind:: text
   AND src.song_sequence_id = 0
   JOIN edw.tempo_song "ts" ON src.song_id = "ts".song_id
   AND src.song_sequence_id = "ts".song_sequence_id
   AND "ts".prior_version_ind:: text = tc.prior_version_ind:: text
   AND "ts".song_type_id = 1
WHERE
   tc.prior_version_ind:: text = 'N':: text;

CREATE
OR REPLACE VIEW "dp_deal_metadata"."sub_contracts_v" AS
SELECT
    c.contract_id,
    c.contract_nm,
    sc.subcontract_id,
    sc.subcontract_nm,
    sc.rate_type_id,
    rt.rate_type_nm,
    srp.subcontract_royalty_period_dt,
    sog.subcontract_office_group_id,
    sog.subcontract_office_group_nm,
    ssg.subcontract_source_group_id,
    ssg.subcontract_source_group_nm,
    sr.income_link_id,
    CASE
    WHEN sr.income_group_type_ind:: text = 'Y':: text THEN NULL:: character varying
    ELSE it.income_type_nm END AS income_type_name,
    CASE
    WHEN sr.income_group_type_ind:: text = 'Y':: text THEN itg.income_type_group_nm
    ELSE NULL:: character varying END AS income_type_group_name,
    sr.client_rate_pc,
    sr.affiliate_remit_rate_pc,
    sr.client_collectable_pc,
    sc.hold_description_tx,
    sc.subcontract_notes_tx,
    sc.create_id,
    sc.create_dt,
    sc.update_id,
    sc.update_dt
FROM
    edw.tempo_subcontract sc
    JOIN edw.tempo_contract c ON sc.contract_id = c.contract_id
    AND sc.prior_version_ind:: text = c.prior_version_ind:: text
    LEFT JOIN edw.tempo_rate_type rt ON sc.rate_type_id = rt.rate_type_id
    LEFT JOIN edw.tempo_subcontract_royalty_period srp ON sc.contract_id = srp.contract_id
    AND sc.subcontract_id = srp.subcontract_id
    AND sc.prior_version_ind:: text = srp.prior_version_ind:: text
    LEFT JOIN edw.tempo_subcontract_office_group sog ON srp.contract_id = sog.contract_id
    AND srp.subcontract_id = sog.subcontract_id
    AND srp.subcontract_royalty_period_dt = sog.subcontract_royalty_period_dt
    AND srp.prior_version_ind:: text = sog.prior_version_ind:: text
    LEFT JOIN edw.tempo_subcontract_source_group ssg ON sog.contract_id = ssg.contract_id
    AND sog.subcontract_id = ssg.subcontract_id
    AND sog.subcontract_office_group_id = ssg.subcontract_office_group_id
    AND sog.subcontract_royalty_period_dt = ssg.subcontract_royalty_period_dt
    AND sog.prior_version_ind:: text = ssg.prior_version_ind:: text
    LEFT JOIN edw.tempo_subcontract_rate sr ON ssg.contract_id = sr.contract_id
    AND ssg.subcontract_id = sr.subcontract_id
    AND ssg.subcontract_source_group_id = sr.subcontract_source_group_id
    AND ssg.subcontract_office_group_id = sr.subcontract_office_group_id
    AND ssg.subcontract_royalty_period_dt = sr.subcontract_royalty_period_dt
    AND ssg.prior_version_ind:: text = sr.prior_version_ind:: text
    LEFT JOIN edw.tempo_income_type it ON sr.income_group_type_ind:: text = 'N':: text
    AND sr.income_link_id = it.income_type_id
    LEFT JOIN edw.tempo_income_type_group itg ON sr.income_group_type_ind:: text = 'Y':: text
    AND sr.income_link_id = itg.income_type_group_id
WHERE
    sc.prior_version_ind:: text = 'N':: text
    AND NOT (
        sr.income_group_type_ind:: text = 'Y':: text
        AND itg.income_type_group_nm IS NULL
        AND it.income_type_nm IS NULL
    );
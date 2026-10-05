CREATE
OR REPLACE VIEW "dp_song_metadata"."cwr_details_message_v" AS
SELECT
   tempo_song_cwr_details_message.song_id,
   tempo_song_cwr_details_message.song_sequence_id,
   tempo_song_cwr_details_message.song_cwr_details_id,
   tempo_song_cwr_details_message.song_ack_level_num,
   tempo_song_cwr_details_message.song_registration_cd,
   tempo_song_cwr_details_message.song_ack_message_tx,
   tempo_song_cwr_details_message.create_id AS created_by,
   tempo_song_cwr_details_message.create_dt AS created_on
FROM
   edw.tempo_song_cwr_details_message
GROUP BY
   tempo_song_cwr_details_message.song_id,
   tempo_song_cwr_details_message.song_sequence_id,
   tempo_song_cwr_details_message.song_cwr_details_id,
   tempo_song_cwr_details_message.song_ack_level_num,
   tempo_song_cwr_details_message.song_registration_cd,
   tempo_song_cwr_details_message.song_ack_message_tx,
   tempo_song_cwr_details_message.create_id,
   tempo_song_cwr_details_message.create_dt;

CREATE
OR REPLACE VIEW "dp_song_metadata"."cwr_details_v" AS
SELECT
    tscd.orig_office_id AS cwr_reg_office_id,
    oo1.orig_office_nm AS cwr_reg_office_nm,
    oo2.orig_office_nm AS song_orig_office_nm,
    tscd.song_id,
    tscd.song_sequence_id,
    "ts".song_title_tx,
    tscd.song_cwr_details_id,
    CASE
    WHEN cfp.file_status_id = 1 THEN 'Pending':: character varying
    WHEN cfp.file_status_id = 2 THEN 'Requested':: character varying
    WHEN cfp.file_status_id = 3 THEN 'Generated':: character varying
    WHEN cfp.file_status_id = 4 THEN 'Generate List':: character varying
    ELSE 'Unknown':: character varying END AS cwr_file_status,
    cfp.cwr_delivery_note_tx AS cwr_file_delivery_note,
    tscd.society_cd AS recipient_cd,
    tso.society_nm AS recipient_name,
    tso.recipient_type_id AS recipient_type,
    tscd.include_in_cwr_ind,
    tscd.update_dates_ind,
    tscd.missing_agreement_ind,
    tscd.file_name_tx,
    tscd.file_creation_dt,
    tscd.dt_first_ack_file_loaded,
    tscd.first_ack_filename_tx,
    tscd.first_ack_dt,
    tscd.first_ack_status_cd,
    tscd.first_ack_message_tx,
    tscd.dt_second_ack_file_loaded,
    tscd.second_ack_filename_tx,
    tscd.second_ack_dt,
    tscd.second_ack_status_cd,
    tscd.second_ack_message_tx,
    tscd.manual_creation_ind,
    tscd.create_id,
    tscd.create_dt,
    tscd.update_id,
    tscd.update_dt
FROM
    edw.tempo_song_cwr_details tscd
    JOIN edw.tempo_orig_office oo1 ON oo1.orig_office_id = tscd.orig_office_id
    JOIN edw.tempo_song "ts" ON "ts".song_id = tscd.song_id
    AND "ts".song_sequence_id = tscd.song_sequence_id
    AND "ts".prior_version_ind:: text = 'N':: character varying:: text
    JOIN edw.tempo_orig_office oo2 ON oo2.orig_office_id = "ts".orig_office_id
    JOIN edw.tempo_society tso ON tso.society_cd = tscd.society_cd
    LEFT JOIN edw.tempo_cwr_file_parameters cfp ON tscd.file_name_tx:: text = cfp.file_name_tx:: text;

CREATE
OR REPLACE VIEW "dp_song_metadata"."cwr_recipient_name_v" AS
SELECT
    tso1.orig_office_id,
    oo.orig_office_nm,
    tso1.society_cd AS recipient_cd,
    tso1.society_nm AS recipient_name,
    rt.recipient_type_nm,
    CASE
    WHEN tso1.cwr_type_cd = 1 THEN 'V2.0':: text
    WHEN tso1.cwr_type_cd = 2 THEN 'V2.1':: text
    WHEN tso1.cwr_type_cd = 3 THEN 'V2.2':: text
    ELSE 'Unknown':: text END AS cwr_type,
    CASE
    WHEN tso1.are_agreements_compulsory_ind:: text = 'Y':: text THEN 'Yes':: text
    WHEN tso1.are_agreements_compulsory_ind:: text = 'N':: text THEN 'No':: text
    ELSE NULL:: text END AS agreements_compulsory,
    CASE
    WHEN tso1.update_dates_ind:: text = 'Y':: text THEN 'Yes':: text
    WHEN tso1.update_dates_ind:: text = 'N':: text THEN 'No':: text
    ELSE NULL:: text END AS update_dates,
    CASE
    WHEN tso1.anglo_american_society_ind:: text = 'Y':: text THEN 'Yes':: text
    WHEN tso1.anglo_american_society_ind:: text = 'N':: text THEN 'No':: text
    ELSE NULL:: text END AS solar_repertoire_society
FROM
    edw.tempo_society tso1
    JOIN edw.tempo_orig_office oo ON oo.orig_office_id = tso1.orig_office_id
    JOIN edw.tempo_recipient_type rt ON tso1.recipient_type_id = rt.recipient_type_id;

CREATE
OR REPLACE VIEW "dp_song_metadata"."cwr_society_work_number_v" AS
SELECT
   "ts".orig_office_id,
   oo.orig_office_nm,
   sswn.song_id,
   sswn.song_sequence_id,
   "ts".song_title_tx,
   sswn.society_cd,
   tso.society_nm,
   sswn.work_number_tx,
   sswn.ack_file_name_tx,
   sswn.create_id,
   sswn.create_dt,
   sswn.update_id,
   sswn.update_dt
FROM
   edw.tempo_song_society_work_number sswn
   JOIN edw.tempo_song "ts" ON "ts".song_id = sswn.song_id
   AND "ts".song_sequence_id = sswn.song_sequence_id
   AND "ts".prior_version_ind:: text = 'N':: text
   JOIN edw.tempo_orig_office oo ON oo.orig_office_id = "ts".orig_office_id
   JOIN edw.tempo_society tso ON tso.society_cd = sswn.society_cd;

CREATE
OR REPLACE VIEW "dp_song_metadata"."identifiers_isrc_v" AS
SELECT
   ii.ident_isrc_cd AS isrc_code,
   ii.song_id AS tempo_song_id,
   "ts".song_title_tx AS tempo_song_title,
   ii.vintage_dt AS vintage_date,
   isou.ident_source_desc AS input_source,
   src.source_nm AS source_name,
   ii.src_artist_tx AS source_artist,
   ii.src_title_tx AS source_title,
   mt.match_type_desc AS match_type,
   ii.conflict_in AS conflict_indicator,
   ii.create_id AS created_by
FROM
   edw.tempo_ident_isrc ii
   JOIN edw.tempo_identifier_source isou ON isou.ident_source_id = ii.ident_source_id
   JOIN (
      SELECT
         DISTINCT tempo_song.song_id,
         tempo_song.song_title_tx
      FROM
         edw.tempo_song
      WHERE
         tempo_song.prior_version_ind:: text = 'N':: text
         AND tempo_song.song_sequence_id = 0
   ) "ts" ON "ts".song_id = ii.song_id
   LEFT JOIN edw.tempo_ident_match_type mt ON mt.match_type_id = ii.match_type_id
   LEFT JOIN edw.tempo_source src ON src.source_id = ii.source_id;

CREATE
OR REPLACE VIEW "dp_song_metadata"."identifiers_iswc_v" AS
SELECT
    tii.ident_iswc_cd,
    tii.song_id AS tempo_song_id,
    "ts".song_title_tx AS tempo_song_title,
    tii.vintage_dt,
    tis.ident_source_desc AS input_source,
    tso.source_nm AS source_name,
    CASE
    WHEN tii.preferred_in:: text = 'Y':: text THEN 'Yes':: text
    WHEN tii.preferred_in:: text = 'N':: text THEN 'No':: text
    ELSE NULL:: text END AS preferred_indicator,
    CASE
    WHEN tii.conflict_in:: text = 'Y':: text THEN 'Yes':: text
    WHEN tii.conflict_in:: text = 'N':: text THEN 'No':: text
    ELSE NULL:: text END AS conflict_indicator,
    tii.create_id AS created_by,
    tii.song_id_match_ind,
    tmt.match_type_desc AS match_type
FROM
    edw.tempo_ident_iswc tii
    JOIN edw.tempo_song "ts" ON tii.song_id = "ts".song_id
    AND "ts".prior_version_ind:: text = 'N':: text
    JOIN edw.tempo_identifier_source tis ON tii.ident_source_id = tis.ident_source_id
    LEFT JOIN edw.tempo_source tso ON tii.source_id = tso.source_id
    LEFT JOIN edw.tempo_ident_match_type tmt ON tii.match_type_id = tmt.match_type_id;

CREATE
OR REPLACE VIEW "dp_song_metadata"."identifiers_swn_v" AS
SELECT
    tit.ident_type_desc,
    CASE
    WHEN tio.ident_type_id = 3 THEN tso.source_nm
    ELSE soc.society_nm END AS society_nm,
    tio.ident_other_cd AS society_work_no,
    tio.song_id AS tempo_song_id,
    "ts".song_title_tx AS tempo_song_title,
    tio.vintage_dt,
    tis.ident_source_desc AS input_source,
    tso.source_nm AS source_name,
    mt.match_type_desc AS match_type,
    tio.conflict_in AS conflict_indicator,
    tio.create_id AS created_by
FROM
    edw.tempo_ident_other tio
    JOIN edw.tempo_song "ts" ON tio.song_id = "ts".song_id
    AND "ts".prior_version_ind:: text = 'N':: character varying:: text
    JOIN edw.tempo_identifier_type tit ON tio.ident_type_id = tit.ident_type_id
    LEFT JOIN edw.tempo_society soc ON tit.ident_society_cd = soc.society_cd
    JOIN edw.tempo_identifier_source tis ON tio.ident_source_id = tis.ident_source_id
    JOIN edw.tempo_source tso ON tio.source_id = tso.source_id
    LEFT JOIN edw.tempo_ident_match_type mt ON mt.match_type_id = tio.match_type_id;

CREATE
OR REPLACE VIEW "dp_song_metadata"."song_alerts_v" AS
SELECT
    tsa.song_id,
    tsa.song_sequence_id,
    "ts".song_title_tx,
    tsa.song_alert_id,
    tsa.song_alert_categories_id,
    tsac.song_alert_categories_nm,
    tsa.create_id,
    tsa.create_dt,
    tsa.update_id,
    tsa.update_dt,
    tsa.active_ind,
    btrim(
        regexp_replace(
            regexp_replace(
                regexp_replace(
                    regexp_replace(
                        regexp_replace(
                            regexp_replace(
                                regexp_replace(
                                    regexp_replace(
                                        regexp_replace(
                                            regexp_replace(
                                                regexp_replace(
                                                    regexp_replace(
                                                        tsa.notes_tx:: text,
                                                        '<[^>]*>':: character varying:: text,
                                                        '':: character varying:: text
                                                    ),
                                                    '[ ]+':: character varying:: text,
                                                    ' ':: character varying:: text
                                                ),
                                                'â€˜':: character varying:: text,
                                                '"':: character varying:: text
                                            ),
                                            'â€™':: character varying:: text,
                                            '"':: character varying:: text
                                        ),
                                        'â€œ':: character varying:: text,
                                        '“':: character varying:: text
                                    ),
                                    'â€':: character varying:: text,
                                    '”':: character varying:: text
                                ),
                                '\\.,':: character varying:: text,
                                ',':: character varying:: text
                            ),
                            '\\.;':: character varying:: text,
                            ';':: character varying:: text
                        ),
                        '�':: character varying:: text,
                        '':: character varying:: text
                    ),
                    '&amp;':: character varying:: text,
                    '&':: character varying:: text
                ),
                '&gt;':: character varying:: text,
                '>':: character varying:: text
            ),
            '&lt;':: character varying:: text,
            '<':: character varying:: text
        )
    ) AS notes_tx,
    CASE
    WHEN saa.song_alert_id IS NOT NULL THEN 'Yes':: character varying
    ELSE 'No':: character varying END AS attachments_ind,
    saa.filename_tx AS attachment_file_name,
    saa.description AS attachment_description
FROM
    edw.tempo_song_alert tsa
    JOIN edw.tempo_song_alert_categories tsac ON tsa.song_alert_categories_id = tsac.song_alert_categories_id
    LEFT JOIN edw.tempo_song "ts" ON "ts".song_id = tsa.song_id
    AND "ts".song_sequence_id = tsa.song_sequence_id
    AND "ts".prior_version_ind:: text = 'N':: character varying:: text
    LEFT JOIN edw.tempo_song_alert_attachment saa ON tsa.song_alert_id = saa.song_alert_id
WHERE
    tsa.prior_version_ind:: text = 'N':: text;

CREATE
OR REPLACE VIEW "dp_song_metadata"."song_alternate_titles_v" AS
SELECT
   tsat.song_id,
   tsat.song_sequence_id,
   tsat.song_alternate_title_id,
   tsat.song_alternate_title_tx,
   tsat.local_title_ind,
   tsat.create_id,
   tsat.create_dt,
   tsat.update_id,
   tsat.update_dt,
   tsat.language_cd,
   tl.language_nm,
   tsat.title_type_cd,
   ttt.title_type_nm,
   tsat.song_alt_title_non_diac_tx,
   tsat.language_script_cd,
   tls.language_script_nm,
   tsat.avi_status_ind,
   tsat.avi_status_dt,
   tsatc.country_cd
FROM
   edw.tempo_song_alternate_title tsat
   LEFT JOIN edw.tempo_language tl ON tsat.language_cd:: text = tl.language_cd:: text
   LEFT JOIN edw.tempo_title_type ttt ON tsat.title_type_cd:: text = ttt.title_type_cd:: text
   LEFT JOIN edw.tempo_language_script tls ON tsat.language_script_cd:: text = tls.language_script_cd:: text
   LEFT JOIN edw.tempo_song_alternate_title_country tsatc ON tsat.song_alternate_title_id = tsatc.song_alternate_title_id
   AND tsatc.prior_version_ind:: text = 'N':: text
WHERE
   tsat.prior_version_ind:: text = 'N':: text;

CREATE
OR REPLACE VIEW "dp_song_metadata"."song_artist_release_info_v" AS
SELECT
   tslp.song_id,
   tslp.song_sequence_id,
   "ts".song_title_tx,
   tslp.song_label_production_id,
   tslp.prior_version_ind,
   tslp.artist_id,
   ta.first_last_nm AS artist_nm,
   ta.professional_nm AS artist_professional_nm,
   tslp.product_number_tx,
   tslp.label_production_id,
   tlpc.label_production_nm,
   tlpc.song_ind,
   tlpc.production_ind,
   tlpc.label_copy_ind,
   tslp.create_id,
   tslp.create_dt:: date AS create_dt,
   tslp.update_id,
   tslp.update_dt:: date AS update_dt,
   tslp.include_in_cwr_ind,
   tslp.album_title_tx,
   tslp.first_release_dt:: date AS first_release_dt,
   tslp.ean_tx,
   tslp.isrc_tx,
   tslp.recording_format_cd,
   tslp.recording_technique_cd,
   tslp.cwr_media_type_cd,
   tslp.first_release_duration_tx,
   tslp.cut_id
FROM
   edw.tempo_song_label_production tslp
   LEFT JOIN edw.tempo_song "ts" ON tslp.song_id = "ts".song_id
   AND tslp.song_sequence_id = "ts".song_sequence_id
   AND "ts".prior_version_ind:: text = 'N':: text
   LEFT JOIN edw.tempo_artist ta ON tslp.artist_id = ta.artist_id
   LEFT JOIN edw.tempo_label_production_company tlpc ON tslp.label_production_id = tlpc.label_production_id
WHERE
   tslp.prior_version_ind:: text = 'N':: text;

CREATE
OR REPLACE VIEW "dp_song_metadata"."song_episodes_v" AS
SELECT
  s.song_id AS production_id,
  s2.song_sequence_id AS production_sequence_id,
  s2.song_title_tx AS production_title_tx,
  s.song_sequence_id AS episode_sequence_id,
  s.song_title_tx AS episode_title_tx,
  st.song_type_nm,
  sp2.release_dt AS production_release_dt,
  sp.release_dt AS episode_release_dt,
  sp.season_num,
  sp.episode_num,
  sp.episode_suffix_tx AS episode_num_suffix,
  s.orig_office_id,
  too.orig_office_nm,
  sp.create_dt AS tempo_create_date,
  sp.create_id AS created_by,
  sp.update_dt AS tempo_last_updated_date,
  sp.update_id AS updated_by,
  pg_catalog.listagg(
    hs.hold_status_nm:: text,
    ', ':: character varying:: text
  ) WITHIN GROUP(
    ORDER BY
      hs.hold_status_nm
  ) AS hold_tx
FROM
  edw.tempo_song s
  JOIN edw.tempo_song_production sp ON s.song_id = sp.song_id
  AND s.song_sequence_id = sp.song_sequence_id
  AND sp.prior_version_ind:: text = 'N':: character varying:: text
  JOIN edw.tempo_orig_office too ON s.orig_office_id = too.orig_office_id
  JOIN edw.tempo_song_production sp2 ON sp.song_id = sp2.song_id
  AND sp2.song_sequence_id = 0
  AND sp2.prior_version_ind:: text = 'N':: character varying:: text
  LEFT JOIN edw.tempo_song s2 ON sp.song_id = s2.song_id
  AND s2.song_sequence_id = 0
  AND s2.prior_version_ind:: text = 'N':: character varying:: text
  JOIN edw.tempo_song_type st ON s.song_type_id = st.song_type_id
  LEFT JOIN edw.tempo_song_hold sh ON s.song_id = sh.song_id
  AND sh.prior_version_ind:: text = 'N':: character varying:: text
  LEFT JOIN edw.tempo_hold_status hs ON sh.hold_status_cd:: text = hs.hold_status_cd:: text
WHERE
  s.prior_version_ind:: text = 'N':: character varying:: text
  AND s.song_type_id = 3
  AND s.song_sequence_id > 0
GROUP BY
  s.song_id,
  s.song_sequence_id,
  s2.song_sequence_id,
  s2.song_title_tx,
  s.song_title_tx,
  st.song_type_nm,
  sp2.release_dt,
  sp.release_dt,
  sp.season_num,
  sp.episode_num,
  sp.episode_suffix_tx,
  s.orig_office_id,
  too.orig_office_nm,
  sp.create_id,
  sp.create_dt,
  sp.update_id,
  sp.update_dt;

CREATE
OR REPLACE VIEW "dp_song_metadata"."song_production_v" AS
SELECT
   "ts".song_id AS production_id,
   "ts".song_sequence_id AS production_sequence_id,
   "ts".song_title_tx AS production_title_tx,
   tst.song_type_nm,
   tsp.release_dt AS production_release_dt,
   "ts".orig_office_id,
   too.orig_office_nm,
   tsp.production_type_cd,
   tpt.production_type_nm,
   pg_catalog.listagg(
      DISTINCT (
         (
            (
               (tlpc.label_production_nm:: text || ' (':: text) || COALESCE(tspc.product_number_tx, '':: character varying):: text
            ) || COALESCE(
               ' / ':: text || tspc.studio_production_cd:: text,
               '':: text
            )
         ) || COALESCE(
            ' / ':: text || tspc.studio_reference_cd:: text,
            '':: text
         )
      ) || ')':: text,
      ', ':: text
   ) AS production_company_nm,
   tsp.create_dt AS tempo_create_date,
   tsp.create_id AS created_by,
   tsp.update_dt AS tempo_last_updated_date,
   tsp.update_id AS updated_by,
   pg_catalog.listagg(thst.hold_status_nm:: text, ', ':: text) AS hold_tx,
   "ts".hold_description_tx AS hold_description
FROM
   edw.tempo_song "ts"
   JOIN edw.tempo_song_production tsp ON "ts".song_id = tsp.song_id
   AND "ts".song_sequence_id = tsp.song_sequence_id
   AND tsp.prior_version_ind:: text = 'N':: text
   JOIN edw.tempo_orig_office too ON "ts".orig_office_id = too.orig_office_id
   LEFT JOIN edw.tempo_production_type tpt ON tsp.production_type_cd:: text = tpt.production_type_cd:: text
   LEFT JOIN edw.tempo_song_production_company tspc ON tsp.song_id = tspc.song_id
   AND tsp.song_sequence_id = tspc.song_sequence_id
   LEFT JOIN edw.tempo_label_production_company tlpc ON tspc.production_company_id = tlpc.label_production_id
   JOIN edw.tempo_song_type tst ON "ts".song_type_id = tst.song_type_id
   LEFT JOIN edw.tempo_song_hold tsh ON "ts".song_id = tsh.song_id
   AND tsh.prior_version_ind:: text = 'N':: text
   LEFT JOIN edw.tempo_hold_status thst ON tsh.hold_status_cd:: text = thst.hold_status_cd:: text
WHERE
   "ts".prior_version_ind:: text = 'N':: text
   AND "ts".song_sequence_id = 0
   AND (
      "ts".song_type_id = 2
      OR "ts".song_type_id = 3
   )
GROUP BY
   "ts".song_id,
   "ts".song_sequence_id,
   "ts".song_title_tx,
   tst.song_type_nm,
   tsp.release_dt,
   "ts".orig_office_id,
   too.orig_office_nm,
   tsp.production_type_cd,
   tpt.production_type_nm,
   tsp.create_id,
   tsp.create_dt,
   tsp.update_id,
   tsp.update_dt,
   "ts".hold_description_tx;

CREATE MATERIALIZED VIEW dp_song_metadata.song_share_detail_mv AS WITH RECURSIVE base_songs AS (
    SELECT
        *
    FROM
        edw.tempo_song
    WHERE
        song_type_id = 1
        AND prior_version_ind = 'N'
        AND song_sequence_id = 0
),
cte_contract AS (
    SELECT
        song_id,
        contract_id,
        inclusions || ' ' || exclusions AS contract_territory_full
    FROM
        dp_song_metadata.contract_territories
),
sip_dedup AS (
    SELECT
        *
    FROM
        (
            SELECT
                sip.*,
                ROW_NUMBER() OVER (
                    PARTITION BY song_id,
                    song_sequence_id,
                    prior_version_ind,
                    country_group_id,
                    ip_writer_id,
                    ip_publisher_id,
                    publisher_id,
                    contract_id,
                    ip_chain_id
                    ORDER BY
                        update_dt DESC NULLS LAST
                ) AS rn
            FROM
                edw.tempo_song_ip_publisher sip
            WHERE
                sip.prior_version_ind = 'N'
        ) x
    WHERE
        rn = 1
),
publisher_hierarchy (
    song_id,
    song_sequence_id,
    prior_version_ind,
    country_group_id,
    root_writer_id,
    ip_chain_id,
    parent_publisher_id,
    publisher_id,
    capacity_type_cd,
    controlled_ind,
    owned_pc,
    mechanical_collectable_pc,
    performance_collectable_pc,
    sync_collectable_pc,
    contract_id,
    path,
    level
) AS (
    SELECT
        sip.song_id,
        sip.song_sequence_id,
        sip.prior_version_ind,
        sip.country_group_id,
        sip.ip_writer_id AS root_writer_id,
        sip.ip_chain_id AS ip_chain_id,
        sip.ip_publisher_id AS parent_publisher_id,
        sip.publisher_id,
        sip.capacity_type_cd,
        sip.controlled_ind,
        sip.owned_pc,
        sip.mechanical_collectable_pc,
        sip.performance_collectable_pc,
        sip.sync_collectable_pc,
        sip.contract_id,
        CAST(sip.publisher_id AS VARCHAR(1000)) AS path,
        1 AS level
    FROM
        sip_dedup sip
    WHERE
        sip.ip_writer_id <> 0
    UNION ALL
    SELECT
        sip.song_id,
        sip.song_sequence_id,
        sip.prior_version_ind,
        sip.country_group_id,
        ph.root_writer_id,
        ph.ip_chain_id,
        sip.ip_publisher_id,
        sip.publisher_id,
        sip.capacity_type_cd,
        sip.controlled_ind,
        sip.owned_pc,
        sip.mechanical_collectable_pc,
        sip.performance_collectable_pc,
        sip.sync_collectable_pc,
        sip.contract_id,
        ph.path || '>' || CAST(sip.publisher_id AS VARCHAR(50)),
        ph.level + 1
    FROM
        sip_dedup sip
        JOIN publisher_hierarchy ph ON sip.song_id = ph.song_id
        AND sip.song_sequence_id = ph.song_sequence_id
        AND sip.prior_version_ind = ph.prior_version_ind
        AND sip.country_group_id = ph.country_group_id
        AND sip.ip_publisher_id = ph.publisher_id
        AND sip.ip_writer_id = 0
        AND sip.ip_chain_id = ph.ip_chain_id
    WHERE
        POSITION(CAST(sip.publisher_id AS VARCHAR(50)) IN ph.path) = 0
        AND ph.level < 10
        AND sip.publisher_id <> ph.publisher_id
),
publisher_hierarchy_dedup AS (
    SELECT
        *
    FROM
        (
            SELECT
                ph.*,
                ROW_NUMBER() OVER (
                    PARTITION BY ph.song_id,
                    ph.song_sequence_id,
                    ph.prior_version_ind,
                    ph.country_group_id,
                    ph.root_writer_id,
                    ph.ip_chain_id,
                    ph.publisher_id,
                    ph.contract_id,
                    ph.level
                    ORDER BY
                        ph.path
                ) AS rn
            FROM
                publisher_hierarchy ph
        ) x
    WHERE
        rn = 1
)
SELECT
    ts.song_id,
    ts.song_sequence_id,
    ts.song_title_tx,
    tst.song_type_nm,
    siw.writer_id,
    tw.first_last_nm AS writer_nm,
    siw.capacity_type_cd AS writer_capacity_type_cd,
    siw.contribution_pc AS writer_contribution_pc,
    tso.society_nm AS writer_mechanical_society_nm,
    tso1.society_nm AS writer_performance_society_nm,
    tc.contract_id AS associated_contract_id,
    tc.contract_nm AS associated_contract_nm,
    ph.controlled_ind AS smp_controlled_ind,
    sicg.country_group_nm AS song_ip_territory_nm,
    ct.contract_territory_full AS song_contract_territory_nm,
    tp.publisher_nm AS publisher_name_tx,
    ph.publisher_id,
    ph.capacity_type_cd AS publisher_capacity_type_cd,
    ph.owned_pc AS publisher_control_pc,
    ph.mechanical_collectable_pc AS publisher_mechanical_pc,
    ph.performance_collectable_pc AS publisher_performance_pc,
    ph.sync_collectable_pc AS publisher_sync_pc,
    siw.mechanical_collectable_pc AS writer_mechanical_pc,
    siw.performance_collectable_pc AS writer_performance_pc,
    siw.sync_collectable_pc AS writer_sync_pc
FROM
    base_songs ts
    JOIN edw.tempo_song_type tst ON ts.song_type_id = tst.song_type_id
    JOIN edw.tempo_song_ip_writer siw ON siw.song_id = ts.song_id
    AND siw.song_sequence_id = ts.song_sequence_id
    AND siw.prior_version_ind = ts.prior_version_ind
    JOIN edw.tempo_writer tw ON siw.writer_id = tw.writer_id
    JOIN publisher_hierarchy_dedup ph ON ph.song_id = siw.song_id
    AND ph.song_sequence_id = siw.song_sequence_id
    AND ph.prior_version_ind = siw.prior_version_ind
    AND ph.country_group_id = siw.country_group_id
    AND ph.root_writer_id = siw.writer_id
    LEFT JOIN edw.tempo_publisher tp ON tp.publisher_id = ph.publisher_id
    JOIN edw.tempo_society tso ON tw.mechanical_society_cd = tso.society_cd
    JOIN edw.tempo_society tso1 ON tw.performance_society_cd = tso1.society_cd
    LEFT JOIN edw.tempo_contract tc ON tc.contract_id = siw.contract_id
    AND tc.prior_version_ind = 'N'
    LEFT JOIN cte_contract ct ON ct.contract_id = tc.contract_id
    AND ct.song_id = siw.song_id
    JOIN edw.tempo_song_ip_country_grp sicg ON siw.song_id = sicg.song_id
    AND siw.song_sequence_id = sicg.song_sequence_id
    AND siw.prior_version_ind = sicg.prior_version_ind
    AND siw.country_group_id = sicg.country_group_id
UNION
SELECT
    ts.song_id,
    ts.song_sequence_id,
    ts.song_title_tx,
    tst.song_type_nm,
    siw.writer_id,
    tw.first_last_nm AS writer_nm,
    siw.capacity_type_cd AS writer_capacity_type_cd,
    siw.contribution_pc AS writer_contribution_pc,
    tso.society_nm AS writer_mechanical_society_nm,
    tso1.society_nm AS writer_performance_society_nm,
    tc.contract_id AS associated_contract_id,
    tc.contract_nm AS associated_contract_nm,
NULL AS
    smp_controlled_ind,
    sicg.country_group_nm AS song_ip_territory_nm,
    ct.contract_territory_full AS song_contract_territory_nm,
NULL AS
    publisher_name_tx,
    CAST(
        NULL AS
            NUMERIC
    ) AS publisher_id,
NULL AS
    publisher_capacity_type_cd,
    CAST(
        NULL AS
            NUMERIC
    ) AS publisher_control_pc,
    CAST(
        NULL AS
            NUMERIC
    ) AS publisher_mechanical_pc,
    CAST(
        NULL AS
            NUMERIC
    ) AS publisher_performance_pc,
    CAST(
        NULL AS
            NUMERIC
    ) AS publisher_sync_pc,
    siw.mechanical_collectable_pc AS writer_mechanical_pc,
    siw.performance_collectable_pc AS writer_performance_pc,
    siw.sync_collectable_pc AS writer_sync_pc
FROM
    base_songs ts
    JOIN edw.tempo_song_type tst ON ts.song_type_id = tst.song_type_id
    JOIN edw.tempo_song_ip_writer siw ON ts.song_id = siw.song_id
    AND ts.song_sequence_id = siw.song_sequence_id
    AND ts.prior_version_ind = siw.prior_version_ind
    JOIN edw.tempo_writer tw ON siw.writer_id = tw.writer_id
    JOIN edw.tempo_society tso ON tw.mechanical_society_cd = tso.society_cd
    JOIN edw.tempo_society tso1 ON tw.performance_society_cd = tso1.society_cd
    LEFT JOIN edw.tempo_contract tc ON tc.contract_id = siw.contract_id
    AND tc.prior_version_ind = 'N'
    LEFT JOIN cte_contract ct ON ct.contract_id = tc.contract_id
    AND ct.song_id = siw.song_id
    JOIN edw.tempo_song_ip_country_grp sicg ON siw.song_id = sicg.song_id
    AND siw.song_sequence_id = sicg.song_sequence_id
    AND siw.prior_version_ind = sicg.prior_version_ind
    AND siw.country_group_id = sicg.country_group_id
WHERE
    ts.song_type_id = 1
    AND ts.prior_version_ind = 'N'
    AND ts.song_sequence_id = 0
    AND NOT EXISTS (
        SELECT
            1
        FROM
            sip_dedup sip_inner
        WHERE
            sip_inner.song_id = siw.song_id
            AND sip_inner.song_sequence_id = siw.song_sequence_id
            AND sip_inner.prior_version_ind = siw.prior_version_ind
            AND sip_inner.ip_writer_id = siw.writer_id
            AND sip_inner.country_group_id = siw.country_group_id
    )
UNION
SELECT
    ts.song_id,
    ts.song_sequence_id,
    ts.song_title_tx,
    tst.song_type_nm,
    CAST(
        NULL AS
            NUMERIC
    ) AS writer_id,
NULL AS
    writer_nm,
NULL AS
    writer_capacity_type_cd,
    CAST(
        NULL AS
            NUMERIC
    ) AS writer_contribution_pc,
NULL AS
    writer_mechanical_society_nm,
NULL AS
    writer_performance_society_nm,
    tc.contract_id AS associated_contract_id,
    tc.contract_nm AS associated_contract_nm,
    sip.controlled_ind AS smp_controlled_ind,
    sicg.country_group_nm AS song_ip_territory_nm,
    ct.contract_territory_full AS song_contract_territory_nm,
    tp.publisher_nm AS publisher_name_tx,
    sip.publisher_id AS publisher_id,
    sip.capacity_type_cd AS publisher_capacity_type_cd,
    sip.owned_pc AS publisher_control_pc,
    sip.mechanical_collectable_pc AS publisher_mechanical_pc,
    sip.performance_collectable_pc AS publisher_performance_pc,
    sip.sync_collectable_pc AS publisher_sync_pc,
    CAST(
        NULL AS
            NUMERIC
    ) AS writer_mechanical_pc,
    CAST(
        NULL AS
            NUMERIC
    ) AS writer_performance_pc,
    CAST(
        NULL AS
            NUMERIC
    ) AS writer_sync_pc
FROM
    base_songs ts
    JOIN edw.tempo_song_type tst ON ts.song_type_id = tst.song_type_id
    JOIN sip_dedup sip ON sip.song_id = ts.song_id
    AND sip.song_sequence_id = ts.song_sequence_id
    AND sip.prior_version_ind = ts.prior_version_ind
    JOIN edw.tempo_publisher tp ON sip.publisher_id = tp.publisher_id
    LEFT JOIN edw.tempo_contract tc ON tc.contract_id = sip.contract_id
    AND tc.prior_version_ind = 'N'
    LEFT JOIN cte_contract ct ON ct.contract_id = tc.contract_id
    AND ct.song_id = sip.song_id
    JOIN edw.tempo_song_ip_country_grp sicg ON sip.song_id = sicg.song_id
    AND sip.song_sequence_id = sicg.song_sequence_id
    AND sip.prior_version_ind = sicg.prior_version_ind
    AND sip.country_group_id = sicg.country_group_id
WHERE
    ts.song_type_id = 1
    AND ts.prior_version_ind = 'N'
    AND ts.song_sequence_id = 0
    AND sip.ip_writer_id = 0
    AND sip.ip_publisher_id = 0;

CREATE MATERIALIZED VIEW dp_song_metadata.song_share_summary_mv AS WITH RECURSIVE base_songs AS (
    SELECT
        *
    FROM
        edw.tempo_song
    WHERE
        song_type_id = 1
        AND prior_version_ind = 'N'
        AND song_sequence_id = 0
),
cte_contract AS (
    SELECT
        song_id,
        contract_id,
        LISTAGG(contract_nm, ', ') WITHIN GROUP (
            ORDER BY
                contract_nm
        ) AS contract_nm,
        inclusions || ' ' || exclusions AS contract_territory_full
    FROM
        dp_song_metadata.contract_territories
    GROUP BY
        song_id,
        contract_id,
        inclusions,
        exclusions
),
sip_dedup AS (
    SELECT
        *
    FROM
        (
            SELECT
                sip.*,
                ROW_NUMBER() OVER (
                    PARTITION BY song_id,
                    song_sequence_id,
                    prior_version_ind,
                    country_group_id,
                    ip_writer_id,
                    ip_publisher_id,
                    publisher_id,
                    contract_id,
                    ip_chain_id
                    ORDER BY
                        update_dt DESC NULLS LAST
                ) AS rn
            FROM
                edw.tempo_song_ip_publisher sip
            WHERE
                sip.prior_version_ind = 'N'
        ) x
    WHERE
        rn = 1
),
publisher_hierarchy (
    song_id,
    song_sequence_id,
    prior_version_ind,
    country_group_id,
    root_writer_id,
    ip_chain_id,
    parent_publisher_id,
    publisher_id,
    controlled_ind,
    owned_pc,
    mechanical_collectable_pc,
    performance_collectable_pc,
    sync_collectable_pc,
    contract_id,
    path,
    level
) AS (
    SELECT
        sip.song_id,
        sip.song_sequence_id,
        sip.prior_version_ind,
        sip.country_group_id,
        sip.ip_writer_id,
        sip.ip_chain_id,
        sip.ip_publisher_id,
        sip.publisher_id,
        sip.controlled_ind,
        sip.owned_pc,
        sip.mechanical_collectable_pc,
        sip.performance_collectable_pc,
        sip.sync_collectable_pc,
        sip.contract_id,
        CAST(sip.publisher_id AS VARCHAR(1000)),
        1
    FROM
        sip_dedup sip
    WHERE
        sip.ip_writer_id <> 0
    UNION ALL
    SELECT
        sip.song_id,
        sip.song_sequence_id,
        sip.prior_version_ind,
        sip.country_group_id,
        ph.root_writer_id,
        ph.ip_chain_id,
        sip.ip_publisher_id,
        sip.publisher_id,
        sip.controlled_ind,
        sip.owned_pc,
        sip.mechanical_collectable_pc,
        sip.performance_collectable_pc,
        sip.sync_collectable_pc,
        sip.contract_id,
        ph.path || '>' || CAST(sip.publisher_id AS VARCHAR(50)),
        ph.level + 1
    FROM
        sip_dedup sip
        JOIN publisher_hierarchy ph ON sip.song_id = ph.song_id
        AND sip.song_sequence_id = ph.song_sequence_id
        AND sip.prior_version_ind = ph.prior_version_ind
        AND sip.country_group_id = ph.country_group_id
        AND sip.ip_publisher_id = ph.publisher_id
        AND sip.ip_writer_id = 0
        AND sip.ip_chain_id = ph.ip_chain_id
    WHERE
        POSITION(CAST(sip.publisher_id AS VARCHAR(50)) IN ph.path) = 0
        AND ph.level < 10
        AND sip.publisher_id <> ph.publisher_id
),
publisher_hierarchy_dedup AS (
    SELECT
        song_id,
        song_sequence_id,
        prior_version_ind,
        country_group_id,
        root_writer_id,
        parent_publisher_id,
        publisher_id,
        controlled_ind,
        contract_id,
        level,
        MAX(owned_pc) AS owned_pc,
        MAX(mechanical_collectable_pc) AS mechanical_collectable_pc,
        MAX(performance_collectable_pc) AS performance_collectable_pc,
        MAX(sync_collectable_pc) AS sync_collectable_pc
    FROM
        publisher_hierarchy
    GROUP BY
        song_id,
        song_sequence_id,
        prior_version_ind,
        country_group_id,
        root_writer_id,
        parent_publisher_id,
        publisher_id,
        controlled_ind,
        contract_id,
        level
)
SELECT
    ts.song_id,
    ts.song_sequence_id,
    ts.song_title_tx,
    tst.song_type_nm,
    siw.writer_id,
    tw.first_last_nm AS writer_nm,
    siw.contribution_pc AS writer_contribution_pc,
    tso.society_nm AS writer_mechanical_society_nm,
    tso1.society_nm AS writer_performance_society_nm,
    tc.contract_id AS associated_contract_id,
    tc.contract_nm AS associated_contract_nm,
    ph.controlled_ind AS smp_controlled_ind,
    sicg.country_group_nm AS song_ip_territory_nm,
    cte_contract.contract_territory_full AS song_contract_territory_nm,
    LISTAGG(DISTINCT tp.publisher_nm, ', ') WITHIN GROUP (
        ORDER BY
            tp.publisher_nm
    ) AS publisher_name_tx,
    SUM(ph.owned_pc) AS publisher_control_pc,
    SUM(ph.mechanical_collectable_pc) AS publisher_mechanical_pc,
    SUM(ph.performance_collectable_pc) AS publisher_performance_pc,
    SUM(ph.sync_collectable_pc) AS publisher_sync_pc,
    MAX(siw.mechanical_collectable_pc) AS writer_mechanical_pc,
    MAX(siw.performance_collectable_pc) AS writer_performance_pc,
    MAX(siw.sync_collectable_pc) AS writer_sync_pc
FROM
    base_songs ts
    JOIN edw.tempo_song_type tst ON ts.song_type_id = tst.song_type_id
    JOIN edw.tempo_song_ip_writer siw ON siw.song_id = ts.song_id
    AND siw.song_sequence_id = ts.song_sequence_id
    AND siw.prior_version_ind = ts.prior_version_ind
    JOIN edw.tempo_writer tw ON siw.writer_id = tw.writer_id
    JOIN publisher_hierarchy_dedup ph ON ph.song_id = siw.song_id
    AND ph.song_sequence_id = siw.song_sequence_id
    AND ph.prior_version_ind = siw.prior_version_ind
    AND ph.country_group_id = siw.country_group_id
    AND ph.root_writer_id = siw.writer_id
    JOIN edw.tempo_publisher tp ON tp.publisher_id = ph.publisher_id
    JOIN edw.tempo_society tso ON tw.mechanical_society_cd = tso.society_cd
    JOIN edw.tempo_society tso1 ON tw.performance_society_cd = tso1.society_cd
    LEFT JOIN edw.tempo_contract tc ON tc.contract_id = siw.contract_id
    AND tc.prior_version_ind = 'N'
    LEFT JOIN cte_contract ON cte_contract.contract_id = tc.contract_id
    AND cte_contract.song_id = siw.song_id
    JOIN edw.tempo_song_ip_country_grp sicg ON siw.song_id = sicg.song_id
    AND siw.song_sequence_id = sicg.song_sequence_id
    AND siw.prior_version_ind = sicg.prior_version_ind
    AND siw.country_group_id = sicg.country_group_id
GROUP BY
    ts.song_id,
    ts.song_sequence_id,
    ts.song_title_tx,
    tst.song_type_nm,
    siw.writer_id,
    tw.first_last_nm,
    siw.contribution_pc,
    tso.society_nm,
    tso1.society_nm,
    tc.contract_id,
    tc.contract_nm,
    ph.controlled_ind,
    sicg.country_group_nm,
    cte_contract.contract_territory_full
UNION
SELECT
    ts.song_id,
    ts.song_sequence_id,
    ts.song_title_tx,
    tst.song_type_nm,
    siw.writer_id,
    tw.first_last_nm AS writer_nm,
    siw.contribution_pc AS writer_contribution_pc,
    tso.society_nm AS writer_mechanical_society_nm,
    tso1.society_nm AS writer_performance_society_nm,
    tc.contract_id AS associated_contract_id,
    tc.contract_nm AS associated_contract_nm,
NULL AS
    smp_controlled_ind,
    sicg.country_group_nm AS song_ip_territory_nm,
    cte_contract.contract_territory_full AS song_contract_territory_nm,
NULL AS
    publisher_name_tx,
    CAST(
        NULL AS
            NUMERIC
    ) AS publisher_control_pc,
    CAST(
        NULL AS
            NUMERIC
    ) AS publisher_mechanical_pc,
    CAST(
        NULL AS
            NUMERIC
    ) AS publisher_performance_pc,
    CAST(
        NULL AS
            NUMERIC
    ) AS publisher_sync_pc,
    SUM(siw.mechanical_collectable_pc) AS writer_mechanical_pc,
    SUM(siw.performance_collectable_pc) AS writer_performance_pc,
    SUM(siw.sync_collectable_pc) AS writer_sync_pc
FROM
    base_songs ts
    JOIN edw.tempo_song_type tst ON ts.song_type_id = tst.song_type_id
    JOIN edw.tempo_song_ip_writer siw ON ts.song_id = siw.song_id
    AND ts.song_sequence_id = siw.song_sequence_id
    AND ts.prior_version_ind = siw.prior_version_ind
    JOIN edw.tempo_writer tw ON siw.writer_id = tw.writer_id
    JOIN edw.tempo_society tso ON tw.mechanical_society_cd = tso.society_cd
    JOIN edw.tempo_society tso1 ON tw.performance_society_cd = tso1.society_cd
    LEFT JOIN edw.tempo_contract tc ON tc.contract_id = siw.contract_id
    AND tc.prior_version_ind = 'N'
    LEFT JOIN cte_contract ON cte_contract.contract_id = tc.contract_id
    AND cte_contract.song_id = siw.song_id
    JOIN edw.tempo_song_ip_country_grp sicg ON siw.song_id = sicg.song_id
    AND siw.song_sequence_id = sicg.song_sequence_id
    AND siw.prior_version_ind = sicg.prior_version_ind
    AND siw.country_group_id = sicg.country_group_id
WHERE
    NOT EXISTS (
        SELECT
            1
        FROM
            edw.tempo_song_ip_publisher sip_inner
        WHERE
            sip_inner.song_id = siw.song_id
            AND sip_inner.song_sequence_id = siw.song_sequence_id
            AND sip_inner.prior_version_ind = siw.prior_version_ind
            AND sip_inner.ip_writer_id = siw.writer_id
            AND sip_inner.country_group_id = siw.country_group_id
    )
GROUP BY
    ts.song_id,
    ts.song_sequence_id,
    ts.song_title_tx,
    tst.song_type_nm,
    siw.writer_id,
    tw.first_last_nm,
    siw.contribution_pc,
    tso.society_nm,
    tso1.society_nm,
    tc.contract_id,
    tc.contract_nm,
    sicg.country_group_nm,
    cte_contract.contract_territory_full
UNION
SELECT
    ts.song_id,
    ts.song_sequence_id,
    ts.song_title_tx,
    tst.song_type_nm,
    CAST(
        NULL AS
            NUMERIC
    ) AS writer_id,
NULL AS
    writer_nm,
    CAST(
        NULL AS
            NUMERIC
    ) AS writer_contribution_pc,
NULL AS
    writer_mechanical_society_nm,
NULL AS
    writer_performance_society_nm,
    tc.contract_id AS associated_contract_id,
    tc.contract_nm AS associated_contract_nm,
    sip.controlled_ind AS smp_controlled_ind,
    sicg.country_group_nm AS song_ip_territory_nm,
    cte_contract.contract_territory_full AS song_contract_territory_nm,
    pg_catalog.listagg(DISTINCT tp.publisher_nm, ', ') WITHIN GROUP (
        ORDER BY
            tp.publisher_nm
    ),
    SUM(sip.owned_pc) AS publisher_control_pc,
    SUM(sip.mechanical_collectable_pc) AS publisher_mechanical_pc,
    SUM(sip.performance_collectable_pc) AS publisher_performance_pc,
    SUM(sip.sync_collectable_pc) AS publisher_sync_pc,
    CAST(
        NULL AS
            NUMERIC
    ) AS writer_mechanical_pc,
    CAST(
        NULL AS
            NUMERIC
    ) AS writer_performance_pc,
    CAST(
        NULL AS
            NUMERIC
    ) AS writer_sync_pc
FROM
    base_songs ts
    JOIN edw.tempo_song_type tst ON ts.song_type_id = tst.song_type_id
    JOIN sip_dedup sip ON sip.song_id = ts.song_id
    AND sip.song_sequence_id = ts.song_sequence_id
    AND sip.prior_version_ind = ts.prior_version_ind
    AND sip.ip_writer_id = 0
    AND sip.ip_publisher_id = 0
    JOIN edw.tempo_publisher tp ON sip.publisher_id = tp.publisher_id
    LEFT JOIN edw.tempo_contract tc ON tc.contract_id = sip.contract_id
    AND tc.prior_version_ind = 'N'
    LEFT JOIN cte_contract ON cte_contract.contract_id = tc.contract_id
    AND cte_contract.song_id = sip.song_id
    JOIN edw.tempo_song_ip_country_grp sicg ON sip.song_id = sicg.song_id
    AND sip.song_sequence_id = sicg.song_sequence_id
    AND sip.prior_version_ind = sicg.prior_version_ind
    AND sip.country_group_id = sicg.country_group_id
WHERE
    sip.ip_writer_id = 0
    AND sip.ip_publisher_id = 0
GROUP BY
    ts.song_id,
    ts.song_sequence_id,
    ts.song_title_tx,
    tst.song_type_nm,
    tc.contract_id,
    tc.contract_nm,
    sip.controlled_ind,
    sicg.country_group_nm,
    cte_contract.contract_territory_full;

CREATE
OR REPLACE VIEW "dp_song_metadata"."song_v" AS
SELECT
  "ts".song_id,
  "ts".song_sequence_id,
  "ts".song_title_tx,
  "ts".language_cd,
  usi.utility_song_indicator_id,
  usi.utility_song_indicator_nm,
  st.song_type_nm,
  "ts".song_not_ours_dt,
  sd.copyright_year,
  sd.film_tv_ind,
  sd.production_song_id AS rolled_up_production_id,
  sd.song_sequence_id AS rolled_up_production_sequence_id,
  prod_s.song_title_tx AS rolled_up_production_title_tx,
  "ts".client_song_id,
  "ts".orig_office_id,
  too.orig_office_nm,
  sd.create_id AS created_by,
  sd.create_dt AS tempo_create_date,
  sd.update_id AS updated_by,
  sd.update_dt AS tempo_last_updated_date,
  pg_catalog.listagg(
    DISTINCT (
      (
        w.first_last_nm:: text || ' (':: character varying:: text
      ) || sipw.contribution_pc:: character varying:: text
    ) || '%)':: character varying:: text,
    ', ':: character varying:: text
  ) WITHIN GROUP(
    ORDER BY
      w.first_last_nm
  ) AS writers_tx,
  pg_catalog.listagg(
    DISTINCT CASE
    WHEN sipw.controlled_ind:: text = 'Y':: character varying:: text THEN (
      (
        (
          w.first_last_nm:: text || ' (':: character varying:: text
        ) || sipw.contribution_pc:: character varying:: text
      ) || '%)':: character varying:: text
    ):: character varying
    ELSE NULL:: character varying END:: text,
    ', ':: character varying:: text
  ) WITHIN GROUP(
    ORDER BY
      w.first_last_nm
  ) AS smp_writers_tx,
  a.artist_tx,
  al.song_alerts_tx,
  n.song_alerts_notes_tx,
  h.hold_tx
FROM
  edw.tempo_song "ts"
  JOIN edw.tempo_song_type st ON "ts".song_type_id = st.song_type_id
  JOIN edw.tempo_orig_office too ON "ts".orig_office_id = too.orig_office_id
  LEFT JOIN edw.tempo_song_detail sd ON "ts".song_id = sd.song_id
  AND sd.prior_version_ind:: text = 'N':: character varying:: text
  LEFT JOIN edw.tempo_song prod_s ON sd.production_song_id = prod_s.song_id
  AND prod_s.song_sequence_id = 0
  AND prod_s.prior_version_ind:: text = 'N':: character varying:: text
  LEFT JOIN edw.tempo_utility_song_indicator usi ON "ts".utility_song_indicator_id = usi.utility_song_indicator_id
  LEFT JOIN edw.tempo_song_ip_writer sipw ON "ts".song_id = sipw.song_id
  AND sipw.prior_version_ind:: text = 'N':: character varying:: text
  LEFT JOIN edw.tempo_writer w ON sipw.writer_id = w.writer_id
  LEFT JOIN (
    SELECT
      slp.song_id,
      pg_catalog.listagg(
        DISTINCT a.first_last_nm:: text,
        ', ':: character varying:: text
      ) WITHIN GROUP(
        ORDER BY
          a.first_last_nm
      ) AS artist_tx
    FROM
      edw.tempo_song_label_production slp
      JOIN edw.tempo_artist a ON slp.artist_id = a.artist_id
    WHERE
      slp.prior_version_ind:: text = 'N':: character varying:: text
    GROUP BY
      slp.song_id
  ) a ON "ts".song_id = a.song_id
  LEFT JOIN (
    SELECT
      sa.song_id,
      pg_catalog.listagg(
        DISTINCT sac.song_alert_categories_nm:: text,
        ', ':: character varying:: text
      ) WITHIN GROUP(
        ORDER BY
          sac.song_alert_categories_nm
      ) AS song_alerts_tx
    FROM
      edw.tempo_song_alert sa
      JOIN edw.tempo_song_alert_categories sac ON sa.song_alert_categories_id = sac.song_alert_categories_id
    WHERE
      sa.prior_version_ind:: text = 'N':: character varying:: text
      AND sa.active_ind:: text = 'Y':: character varying:: text
    GROUP BY
      sa.song_id
  ) al ON "ts".song_id = al.song_id
  LEFT JOIN (
    SELECT
      sa.song_id,
      btrim(
        regexp_replace(
          regexp_replace(
            regexp_replace(
              regexp_replace(
                regexp_replace(
                  regexp_replace(
                    regexp_replace(
                      regexp_replace(
                        regexp_replace(
                          regexp_replace(
                            regexp_replace(
                              pg_catalog.listagg(
                                DISTINCT sa.notes_tx:: text,
                                ', ':: character varying:: text
                              ) WITHIN GROUP(
                                ORDER BY
                                  sa.notes_tx
                              ):: text,
                              '<[^>]*>':: character varying:: text,
                              '':: character varying:: text
                            ),
                            '[ ]+':: character varying:: text,
                            ' ':: character varying:: text
                          ),
                          'â€˜':: character varying:: text,
                          '"':: character varying:: text
                        ),
                        'â€™':: character varying:: text,
                        '"':: character varying:: text
                      ),
                      'â€œ':: character varying:: text,
                      '“':: character varying:: text
                    ),
                    'â€':: character varying:: text,
                    '”':: character varying:: text
                  ),
                  '\\.,':: character varying:: text,
                  ',':: character varying:: text
                ),
                '\\.;':: character varying:: text,
                ';':: character varying:: text
              ),
              '�':: character varying:: text,
              '':: character varying:: text
            ),
            '&amp;':: character varying:: text,
            '&':: character varying:: text
          ),
          '&gt;':: character varying:: text,
          '>':: character varying:: text
        )
      ) AS song_alerts_notes_tx
    FROM
      edw.tempo_song_alert sa
    WHERE
      sa.prior_version_ind:: text = 'N':: character varying:: text
      AND sa.active_ind:: text = 'Y':: character varying:: text
    GROUP BY
      sa.song_id
  ) n ON "ts".song_id = n.song_id
  LEFT JOIN (
    SELECT
      sh.song_id,
      pg_catalog.listagg(
        DISTINCT hs.hold_status_nm:: text,
        ', ':: character varying:: text
      ) WITHIN GROUP(
        ORDER BY
          hs.hold_status_nm
      ) AS hold_tx
    FROM
      edw.tempo_song_hold sh
      JOIN edw.tempo_hold_status hs ON sh.hold_status_cd:: text = hs.hold_status_cd:: text
    WHERE
      sh.prior_version_ind:: text = 'N':: character varying:: text
    GROUP BY
      sh.song_id
  ) h ON "ts".song_id = h.song_id
WHERE
  "ts".song_type_id = 1
  AND "ts".prior_version_ind:: text = 'N':: character varying:: text
GROUP BY
  "ts".song_id,
  "ts".song_sequence_id,
  "ts".song_title_tx,
  "ts".language_cd,
  usi.utility_song_indicator_id,
  usi.utility_song_indicator_nm,
  st.song_type_nm,
  "ts".song_not_ours_dt,
  sd.copyright_year,
  sd.film_tv_ind,
  sd.production_song_id,
  sd.song_sequence_id,
  prod_s.song_title_tx,
  "ts".client_song_id,
  "ts".orig_office_id,
  too.orig_office_nm,
  sd.create_id,
  sd.create_dt,
  sd.update_id,
  sd.update_dt,
  a.artist_tx,
  al.song_alerts_tx,
  n.song_alerts_notes_tx,
  h.hold_tx;

CREATE
OR REPLACE VIEW "dp_song_metadata"."tempo_active_song_rate_client_v" AS
SELECT
   DISTINCT tsrc.song_id,
   tsrc.song_payment_option_id,
   po.active_ind as payment_option_active_ind,
   po.primary_ind as payment_option_primary_ind,
   po.notes_tx as payment_option_notes_tx,
   tsrog.active_ind AS active_office_group,
   tsrc.song_rate_office_group_id,
   tsrog.song_rate_office_group_nm,
   tsrc.song_rate_id,
   tsrc.primary_song_rate_id,
   tsrc.active_ind AS active_song_client,
   tsrc.client_id,
   tsrc.contract_id,
   tsrc.subcontract_id,
   tsrc.client_share_pc
FROM
   edw.tempo_song_rate_client tsrc
   JOIN edw.tempo_song_rate_office_group tsrog ON tsrc.song_rate_office_group_id = tsrog.song_rate_office_group_id
   AND tsrc.song_id = tsrog.song_id
   AND tsrc.song_sequence_id = tsrog.song_sequence_id
   AND tsrog.active_ind:: text = 'Y':: text
   AND tsrog.prior_version_ind:: text = 'N':: text
   JOIN "dwa-prod-db"."edw"."tempo_song_payment_option" po ON tsrc.song_id = po.song_id 
   AND tsrc.song_sequence_id = po.song_sequence_id
   AND tsrc.song_payment_option_id = po.song_payment_option_id
WHERE
   tsrc.prior_version_ind:: text = 'N':: text
   AND tsrc.active_ind:: text = 'Y':: text
   AND tsrc.song_payment_option_id > -1
   AND po.prior_version_ind:: text = 'N':: text
ORDER BY
   tsrc.song_id,
   tsrc.song_rate_office_group_id,
   tsrc.song_payment_option_id;

CREATE
OR REPLACE VIEW "dp_song_metadata"."tempo_song_production_reporting_gr_v" AS
SELECT
   tsprg.song_id,
   tsprg.song_sequence_id,
   tsprg.song_reporting_group_id,
   tsrg.song_reporting_group_nm,
   tsrg.notes_tx AS song_reporting_group_notes_tx,
   tsprg.create_id,
   tsprg.create_dt
FROM
   edw.tempo_song_production_reporting_grp tsprg
   JOIN edw.tempo_song_reporting_group tsrg ON tsprg.song_reporting_group_id = tsrg.song_reporting_group_id
WHERE
   tsprg.prior_version_ind:: text = 'N':: text;

CREATE OR REPLACE PROCEDURE shared.sp_get_all_contract_territories()
 LANGUAGE plpgsql
AS $$
DECLARE
 
    v_includeTx VARCHAR(32760) := '';
    v_excludeTx VARCHAR(32760) := '';
    v_reIncludeTx VARCHAR(32760) := NULL;
 
BEGIN
 
--create the base table with all tempo songs and contracts
drop table if exists terr_tmp_1;
 
select distinct
        src.song_id,
        c.contract_id,
        c.contract_nm
into terr_tmp_1
from
     edw.tempo_song_rate_client as src
join edw.tempo_song_payment_option as spo
            on spo.song_id = src.song_id
             and spo.song_sequence_id = src.song_sequence_id
             and spo.prior_version_ind = src.prior_version_ind
             and src.song_payment_option_id = spo.song_payment_option_id
join edw.tempo_contract as c
            on src.contract_id = c.contract_id
join edw.tempo_song_rate_office_group as srog
            on spo.song_id = srog.song_id
                and srog.song_sequence_id = src.song_sequence_id
                and srog.prior_version_ind = src.prior_version_ind
                and spo.song_payment_option_id = srog.song_payment_option_id
                and src.song_rate_office_group_id = srog.song_rate_office_group_id
where 1=1
    and src.song_sequence_id = 0
    and src.song_sequence_id = 0
    and src.prior_version_ind = 'N'
    and spo.active_ind = 'Y'
    and src.active_ind = 'Y'
    and srog.active_ind = 'Y'
    and src.song_payment_option_id > -1
order by c.contract_nm nulls first;
 
--count the countries to set the songExceptionInc flag
drop table if exists terr_tmp_3;
 
select
     terr_tmp_1.*,
     count(cnt.country_cd) rcount,
     case when rcount > 0 then 'Y' else 'N' end as songException
into terr_tmp_3
from
    terr_tmp_1
 left join
        (
        SELECT rto.country_cd, rto.song_id, rto.contract_id
        FROM edw.tempo_song_rate_terr_override_det AS rto join
             terr_tmp_1 on terr_tmp_1.song_id = rto.song_id
        WHERE 1=1
            AND rto.song_sequence_id = 0
            AND rto.contract_id = terr_tmp_1.contract_id
            AND rto.prior_version_ind = 'N'
            AND rto.country_cd <> 'WRD'
        EXCEPT
        SELECT rto.country_cd, rto.song_id, rto.contract_id
        FROM edw.tempo_song_rate_terr_override_det AS rto  join
             terr_tmp_1 on terr_tmp_1.song_id = rto.song_id
        WHERE 1=1
            AND rto.song_sequence_id = 0
            AND rto.contract_id = terr_tmp_1.contract_id
            AND rto.prior_version_ind = 'N'
            AND rto.include_ind = 'N'
            AND rto.country_cd <> 'WRD'
        ) cnt on terr_tmp_1.song_id = cnt.song_id
        and terr_tmp_1.contract_id = cnt.contract_id
group by
     terr_tmp_1.song_id,
     terr_tmp_1.contract_id,
     terr_tmp_1.contract_nm;
 
 
--set the first exclude column for songexception = Y
--prep the contract world indicator fro the counts
drop table if exists terr_tmp_4;
select
    terr_tmp_3.*,
    exclude1,
    case when songexception = 'N' then case when wc.contract_id is null then 'N' else 'Y' end end as contractworld,
    'World' as include
into terr_tmp_4
from
    terr_tmp_3
left join
    (SELECT
        song_id,
        contract_id,
        CASE WHEN LISTAGG(country_nm, ';') WITHIN GROUP (
        ORDER BY
            country_nm
        ) IS NOT NULL THEN LISTAGG(country_nm, ';') WITHIN GROUP (
        ORDER BY
            country_nm
        ) else ''
         END exclude1
        FROM
        (
            SELECT DISTINCT
            country_nm,
            song_id,
            contract_id
            FROM
            (
                SELECT
                co.country_nm,
                rto.include_ind,
                terr_tmp_3.song_id,
                terr_tmp_3.contract_id
                FROM
                edw.tempo_song_rate_terr_override_det rto
                LEFT JOIN edw.tempo_country co ON co.country_cd = rto.country_cd
                JOIN terr_tmp_3 on terr_tmp_3.song_id = rto.song_id and terr_tmp_3.contract_id = rto.contract_id
                WHERE
                1 = 1
                AND rto.song_sequence_id = 0
                AND rto.prior_version_ind = 'N'
                AND rto.country_cd <> 'WRD'
                AND rto.include_ind = 'N'
                AND co.gca_territory_ind = 'Y'
                UNION ALL
                SELECT
                c.country_nm,
                'N' AS include_ind,
                t3.song_id,
                t3.contract_id
                FROM
                edw.tempo_country c
                JOIN edw.tempo_territory_country tcnt ON tcnt.country_cd = c.country_cd
                join terr_tmp_3 t3 on 1=1
                WHERE
                1 = 1
                and tcnt.territory_id = 1
                AND c.country_cd <> 'WRD'
                AND c.gca_territory_ind = 'Y'
                AND NOT EXISTS (
                    SELECT
                    1
                    FROM
                    edw.tempo_song_rate_terr_override_det rto
                    WHERE
                    rto.song_id = t3.song_id
                    AND rto.song_sequence_id = 0
                    AND rto.contract_id = t3.contract_id
                    AND rto.prior_version_ind = 'N'
                    AND rto.country_cd <> 'WRD'
                    AND rto.country_cd = c.country_cd)
            )
        ORDER BY  1 NULLS FIRST
        )  terrSongCur
        group by song_id, contract_id
    ) exclusions1
                 on terr_tmp_3.song_id = exclusions1.song_id
                and terr_tmp_3.contract_id = exclusions1.contract_id
                and terr_tmp_3.songException = 'Y'
left join (SELECT distinct contract_id
            FROM edw.tempo_contract_territory ct
                where ct.include_ind = 'Y'
                AND ct.prior_version_ind = 'N'
                AND ct.territory_id = 1
                AND ct.primary_territory_id = 1
                ) wc
on wc.contract_id = terr_tmp_3.contract_id and terr_tmp_3.songexception = 'N';
 
 
--2nd exclude logic for exception = N and world = Y
drop table if exists terr_tmp_5;
select
    terr_tmp_4.*,
    ex2.ex2c as exclude2
into terr_tmp_5
from
     terr_tmp_4
left join
    (
   SELECT
    song_id,
    contract_id,
    CASE
         WHEN LISTAGG(territory_nm, ';') WITHIN GROUP (ORDER BY territory_nm)
         IS NOT NULL THEN LISTAGG(territory_nm, ';') WITHIN GROUP (ORDER BY territory_nm)
    END as ex2c
            FROM
            (
        SELECT DISTINCT
            ct.include_ind,
            tr.territory_nm,
            t4.contract_id,
            t4.song_id
        FROM edw.tempo_contract_territory AS ct,
             edw.tempo_territory AS tr,
             terr_tmp_4 t4
        WHERE 1=1
            AND ct.contract_id = t4.contract_id
            AND tr.territory_id = ct.territory_id
            AND ct.include_ind = 'N'
            AND ct.prior_version_ind = 'N'
            AND NOT EXISTS(
                SELECT *
                FROM edw.tempo_song_rate_territory_override AS rto
                WHERE 1=1
                    AND rto.song_id = t4.song_id
                    AND rto.song_sequence_id = 0
                    AND rto.prior_version_ind = 'N'
                    AND rto.contract_id = t4.contract_id
                    AND rto.territory_id <> 1
                    AND rto.include_ind = 'Y' --World
                )
         ORDER BY tr.territory_nm NULLS FIRST
            ) contract_terr_exclude_cur
    group by
    song_id,
    contract_id
    ) ex2
on ex2.song_id = terr_tmp_4.song_id and ex2.contract_id = terr_tmp_4.contract_id
and terr_tmp_4.songexception = 'N' and terr_tmp_4.contractworld = 'Y';
 
--3rd exclude logic for exception = N and world = Y. Doesn't return anything
drop table if exists terr_tmp_6;
 
select
    terr_tmp_5.*,
    ex3 as exclude3
into terr_tmp_6
from terr_tmp_5
left join
    ( SELECT song_id, contract_id, CASE
            WHEN LISTAGG(country_nm, ';') WITHIN GROUP (
                ORDER BY country_nm
            ) IS NOT NULL THEN LISTAGG(country_nm, ';') WITHIN GROUP (
                ORDER BY country_nm
            )
        END ex3
    FROM (
            SELECT DISTINCT co.country_nm, t5.song_id, t5.contract_id
            FROM edw.tempo_contract_territory_country AS ctc,
                edw.tempo_country AS co,
                terr_tmp_5 t5
            WHERE ctc.contract_id = t5.contract_id
                AND co.country_cd = ctc.country_cd
                AND ctc.include_ind = 'N'
                AND ctc.prior_version_ind = 'N'
                AND NOT EXISTS(
                    SELECT 1
                    FROM edw.tempo_song_rate_terr_override_det AS rto
                    WHERE rto.country_cd = ctc.country_cd
                        AND rto.song_id = t5.song_id
                        AND rto.song_sequence_id = 0
                        AND rto.prior_version_ind = 'N'
                        AND rto.contract_id = t5.contract_id
                        AND rto.country_cd <> 'WRD'
                        AND rto.include_ind = 'Y' --Not World
                )
                AND co.gca_territory_ind = 'Y'
            ORDER BY co.country_nm NULLS FIRST
        ) contractTerrCountryExcludeCur
group by song_id, contract_id) ex3
on ex3.song_id = terr_tmp_5.song_id and ex3.contract_id = terr_tmp_5.contract_id
and terr_tmp_5.songexception = 'N' and terr_tmp_5.contractworld = 'Y';
 
--set main include for songexception = N and world = N
drop table if exists terr_tmp_7;
select
    terr_tmp_6.*,
    inc2 as include2
into terr_tmp_7
from terr_tmp_6
left join
(SELECT song_id, contract_id,
        CASE
        WHEN LISTAGG(country_nm, ';') WITHIN GROUP(
            ORDER BY country_nm
        ) IS NOT NULL THEN LISTAGG(country_nm, ';') WITHIN GROUP (
            ORDER BY country_nm
        )
    END inc2
FROM (
        SELECT DISTINCT *
        FROM (
                SELECT DISTINCT country_nm, song_id, contract_id
                FROM (
                        SELECT rto.include_ind,
                               co.country_nm,
                               t6.song_id,
                               t6.contract_id
                        FROM
                            edw.tempo_song_rate_terr_override_det AS rto,
                            edw.tempo_country AS co,
                            terr_tmp_6 t6
                        WHERE co.country_cd = rto.country_cd
                            AND rto.song_id = t6.song_id
                            AND rto.song_sequence_id = 0
                            AND rto.prior_version_ind = 'N'
                            AND rto.contract_id = t6.contract_id
                            AND rto.country_cd <> 'WRD' --Not World
                            AND rto.include_ind = 'Y'
                            AND co.gca_territory_ind = 'Y'
                        UNION ALL
                        --included contract countries
                        SELECT ctc.include_ind,
                            co.country_nm,
                            t6.song_id,
                            t6.contract_id
                        FROM edw.tempo_contract_territory_country AS ctc,
                            edw.tempo_country AS co,
                            terr_tmp_6 t6
                        WHERE co.country_cd = ctc.country_cd
                            AND ctc.contract_id = t6.contract_id
                            AND ctc.include_ind = 'Y'
                            AND ctc.country_cd <> 'WRD'
                            AND ctc.prior_version_ind = 'N'
                            AND co.gca_territory_ind = 'Y'
                        UNION ALL
                        --included contract territories
                        SELECT ct.include_ind,
                               ct.territory_nm,
                               t6.song_id,
                               t6.contract_id
                        FROM
                            edw.tempo_contract_territory AS ct,
                            terr_tmp_6 t6
                        WHERE ct.contract_id = t6.contract_id
                            AND ct.include_ind = 'Y'
                            AND ct.prior_version_ind = 'N'
                    )
            )
        ORDER BY country_nm NULLS FIRST
    ) contractTerrSongCur
    group by song_id, contract_id
) inc
on inc.song_id = terr_tmp_6.song_id and inc.contract_id = terr_tmp_6.contract_id
    and terr_tmp_6.songexception = 'N' and terr_tmp_6.contractworld = 'N';
 
--merge the include and exclude columns
drop table if exists terr_tmp_8;
select
    t7.*,
    'Include: '||nvl(include2, include) include_final,
    --'Exclude: '||nvl(exclude1,'')||nvl(exclude2,'')||';'||nvl(exclude3,'') exclude_final,
   case
        case when exclude1 is null and exclude2 is null and exclude3 is null then ''
             when exclude1 is not null then exclude1
             when exclude2 is null then exclude3
             when exclude3 is null then exclude2
             else exclude2||';'||exclude3
        end
    when '' then ''
    else   'Exclude: '|| case when exclude1 is null and exclude2 is null and exclude3 is null then ''
             when exclude1 is not null then exclude1
             when exclude2 is null then exclude3
             when exclude3 is null then exclude2
             else exclude2||';'||exclude3
             end
    end exclude_final,
    contract_nm||' '||include_final||' '||exclude_final territory_tx
into terr_tmp_8
 from terr_tmp_7 t7;
 
drop table if exists terr_tmp_9;
--displays every country in the world that isn't in the exclude variable.
SELECT
    countryCur.contract_id, countryCur.song_id,
    CASE
        WHEN LISTAGG(country_nm, ';') WITHIN GROUP (
            ORDER BY country_nm
        ) IS NOT NULL THEN LISTAGG(country_nm, ';') WITHIN GROUP (
            ORDER BY country_nm
        )
    END as reIncludeTx
into  terr_tmp_9
FROM (
        SELECT terr_tmp_8.song_id, terr_tmp_8.contract_id,cnt.country_nm
        FROM edw.tempo_territory_country tcnt,
            edw.tempo_country cnt,
             terr_tmp_8 --deliberately no join condition
        WHERE tcnt.country_cd = cnt.country_cd
            AND tcnt.territory_id = 1
            AND cnt.country_cd <> 'WRD'
            AND cnt.gca_territory_ind = 'Y'
            AND POSITION(cnt.country_nm IN nvl(exclude_final,'')) = 0
    ) countryCur
group by countryCur.contract_id, countryCur.song_id;
 
 
--adjust the forats and make string shorest
drop table if exists terr_tmp_10;
select t8.*, t9.reIncludeTx
into terr_tmp_10
from terr_tmp_8 t8 left join terr_tmp_9 t9 on t8.song_id = t9.song_id and t8.contract_id = t9.contract_id;
 
update terr_tmp_10 set include_final = 'Include: '||reincludetx where
length(include_final||exclude_final) > length(reincludetx);
 
update terr_tmp_10 set exclude_final = null where
length(include_final||exclude_final) > length(reincludetx);
 
 
--create the final output table
--drop table if exists dp_song_metadata.contract_territories;
 
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables
               WHERE table_schema = 'dp_song_metadata'
                 AND table_name = 'contract_territories') THEN
        EXECUTE 'TRUNCATE TABLE dp_song_metadata.contract_territories';
    END IF;
END;
 
insert into dp_song_metadata.contract_territories
select song_id, contract_id, contract_nm, include_final as inclusions, exclude_final as exclusions
from terr_tmp_10;
 
drop table if exists terr_tmp_1;
drop table if exists terr_tmp_2;
drop table if exists terr_tmp_3;
drop table if exists terr_tmp_4;
drop table if exists terr_tmp_5;
drop table if exists terr_tmp_6;
drop table if exists terr_tmp_7;
drop table if exists terr_tmp_8;
drop table if exists terr_tmp_9;
drop table if exists terr_tmp_10;
END;
 
 
$$
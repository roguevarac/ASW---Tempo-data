CREATE
OR REPLACE VIEW "dp_statement_lines"."master_crj_v" AS
SELECT
   b.orig_office_id,
   b.batch_total_am,
   b.batch_total_reconciled_ind,
   b.posted_to_gl_ind,
   b.notes_tx AS batch_notes_tx,
   ba.crj_bank_account_nm,
   t.crj_type_nm,
   c.crj_batch_id,
   c.crj_line_id,
   c.crj_bank_account_id,
   c.deposit_dt,
   c.bank_batch_number_tx,
   c.crj_payor_tx,
   c.check_wire_num_tx,
   c.check_am,
   c.dr_gst_vat_receivable_am,
   c.cr_gst_vat_payable_am,
   c.dr_deduction_am,
   c.crj_am,
   c.crj_unassociated_balance_am,
   c.crj_type_id,
   c.post_to_gl_acctg_period_dt,
   c.crj_non_royalty_type_id,
   c.crj_ref_number_tx,
   c.accounting_company_group_nm,
   c.royalty_company_nm,
   c.income_type_group_id,
   c.crj_statement_header_id,
   c.crj_source_nm,
   c.local_inf_reference_tx,
   c.royalty_done_ind,
   c.royalty_done_acctg_period_dt,
   c.crj_input_source_id,
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
                                          c.notes_tx:: text,
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
   ) AS crj_notes_tx,
   c.create_id,
   c.create_dt,
   c.update_id,
   c.update_dt,
   c.royalty_and_sh_done_acctg_dt,
   c.entity_group_id,
   c.royalty_done_reason_id,
   c.license_number,
   c.invoice_number,
   cra.statement_header_id,
   cra.processing_office_id,
   cra.cash_receipt_associated_am,
   cra.crj_association_id
FROM
   edw.tempo_crj_line c
   LEFT JOIN edw.tempo_crj_batch b ON c.crj_batch_id = b.crj_batch_id
   LEFT JOIN edw.tempo_crj_bank_account ba ON c.crj_bank_account_id = ba.crj_bank_account_id
   LEFT JOIN edw.tempo_crj_type t ON c.crj_type_id = t.crj_type_id
   LEFT JOIN edw.tempo_cash_receipt_association cra ON b.orig_office_id = cra.orig_office_id
   AND c.crj_batch_id = cra.crj_batch_id
   AND c.crj_line_id = cra.crj_line_id;

CREATE
OR REPLACE VIEW "dp_statement_lines"."source_match_records_v" AS
SELECT
  ssmf.source_stmt_match_file_seq_id,
  ssmf.orig_office_id,
  oo.orig_office_nm,
  ssmf.source_id,
  src.source_nm,
  ssmf.sub_source_id,
  subsrc.source_nm AS sub_source_nm,
  ssmf.income_type_match_group_id,
  itmg.income_type_match_group_nm,
  ssmf.income_type_id,
  it.income_type_nm,
  ssmf.src_work_number_tx,
  ssmf.src_sub_work_number_tx,
  ssmf.src_iswc_cd,
  ssmf.src_song_production_title_tx,
  ssmf.src_filmtv_title_tx,
  ssmf.src_episode_num,
  ssmf.src_episode_title_tx,
  ssmf.src_writer_nm_tx,
  ssmf.src_product_number_tx,
  ssmf.song_id,
  "ts".song_title_tx,
  pg_catalog.listagg(DISTINCT tw.first_last_nm:: text, ', ':: text) WITHIN GROUP(
    ORDER BY
      tw.first_last_nm
  ) AS writers_tx,
  ssmf.song_sequence_id,
  ssmf.song_payment_option_id,
  ssmf.matched_twice_ind,
  ssmf.confirmed_match_ind,
  ssmf.migrated_match_ind,
  ssmf.statement_header_id,
  ssmf.create_id,
  ssmf.create_dt,
  ssmf.update_id,
  ssmf.update_dt,
  ssmf.orig_source_id_overridden
FROM
  edw.tempo_source_statement_match_file ssmf
  LEFT JOIN edw.tempo_orig_office oo ON ssmf.orig_office_id = oo.orig_office_id
  LEFT JOIN edw.tempo_source src ON ssmf.source_id = src.source_id
  LEFT JOIN edw.tempo_source subsrc ON ssmf.sub_source_id = subsrc.source_id
  LEFT JOIN edw.tempo_income_type_match_group itmg ON ssmf.income_type_match_group_id = itmg.income_type_match_group_id
  LEFT JOIN edw.tempo_income_type it ON ssmf.income_type_id = it.income_type_id
  LEFT JOIN edw.tempo_song "ts" ON ssmf.song_id = "ts".song_id
  AND ssmf.song_sequence_id = "ts".song_sequence_id
  AND "ts".prior_version_ind:: text = 'N':: text
  LEFT JOIN edw.tempo_song_ip_writer tsiw ON ssmf.song_id = tsiw.song_id
  AND tsiw.prior_version_ind:: text = 'N':: text
  LEFT JOIN edw.tempo_writer tw ON tsiw.writer_id = tw.writer_id
GROUP BY
  ssmf.source_stmt_match_file_seq_id,
  ssmf.orig_office_id,
  oo.orig_office_nm,
  ssmf.source_id,
  src.source_nm,
  ssmf.sub_source_id,
  subsrc.source_nm,
  ssmf.income_type_match_group_id,
  itmg.income_type_match_group_nm,
  ssmf.income_type_id,
  it.income_type_nm,
  ssmf.src_work_number_tx,
  ssmf.src_sub_work_number_tx,
  ssmf.src_iswc_cd,
  ssmf.src_song_production_title_tx,
  ssmf.src_filmtv_title_tx,
  ssmf.src_episode_num,
  ssmf.src_episode_title_tx,
  ssmf.src_writer_nm_tx,
  ssmf.src_product_number_tx,
  ssmf.song_id,
  "ts".song_title_tx,
  ssmf.song_sequence_id,
  ssmf.song_payment_option_id,
  ssmf.matched_twice_ind,
  ssmf.confirmed_match_ind,
  ssmf.migrated_match_ind,
  ssmf.statement_header_id,
  ssmf.create_id,
  ssmf.create_dt,
  ssmf.update_id,
  ssmf.update_dt,
  ssmf.orig_source_id_overridden;

CREATE
OR REPLACE VIEW "dp_statement_lines"."source_v" AS
SELECT
   tsc.country_cd AS source_country_cd,
   "ts".source_id,
   "ts".source_nm,
   "ts".used_for_stmt_header_ind,
   "ts".affiliate_ind,
   "ts".default_sales_type_id,
   st.sales_type_nm AS default_sales_type_nm,
   "ts".default_ind,
   "ts".country_rates_ind,
   "ts".priority_num,
   "ts".track_source_ind,
   "ts".active_ind,
   "ts".rate_towards_recoup_pc,
   "ts".address_id,
   "ts".valid_to_load_ind,
   "ts".update_id,
   "ts".update_dt,
   "ts".orig_office_id,
   oo.orig_office_nm,
   "ts".requires_sub_source_ind,
   "ts".sent_to_web_ind,
   "ts".match_inc_type_mtch_grp_id_ind,
   "ts".header_group_sources_ind,
   "ts".notes_tx,
   "ts".match_source_id,
   tsm.source_nm AS match_source_nm,
   "ts".deal_note_tx,
   "ts".ident_type_override_id,
   it.ident_type_desc AS ident_type_name,
   "ts".exclude_identifier_ind,
   "ts".specific_rate_ind,
   "ts".create_dt,
   "ts".digital_source_ind,
   "ts".primary_source_id,
   ts1.source_nm AS primary_source_nm,
   "ts".fractional_cent_load_dec_num,
   "ts".display_in_contract_ind
FROM
   edw.tempo_source "ts"
   JOIN edw.tempo_source_country tsc ON "ts".source_id = tsc.source_id
   AND tsc.primary_ind:: text = 'Y':: character varying:: text
   AND tsc.active_ind:: text = 'Y':: character varying:: text
   JOIN edw.tempo_orig_office oo ON oo.orig_office_id = "ts".orig_office_id
   LEFT JOIN edw.tempo_source ts1 ON "ts".primary_source_id = ts1.source_id
   LEFT JOIN edw.tempo_source tsm ON "ts".match_source_id = tsm.source_id
   LEFT JOIN edw.tempo_identifier_type it ON "ts".ident_type_override_id = it.ident_type_id
   LEFT JOIN edw.tempo_sales_type st ON "ts".default_sales_type_id = st.sales_type_id
WHERE
   "ts".active_ind:: text = 'Y':: character varying:: text;

CREATE
OR REPLACE VIEW "dp_statement_lines"."statement_headers_v" AS
SELECT
    sh.statement_header_id,
    sh.processing_office_id,
    oo.orig_office_nm AS processing_office_name,
    sh.original_statement_header_id AS orig_statement_header_id,
    sh.orig_processing_office_id,
    sh.statement_type_id,
    st.statement_type_nm AS statement_type_name,
    sh.reporting_period_start_dt AS sh_reporting_period_start,
    sh.reporting_period_end_dt AS sh_reporting_period_end,
    CASE
    WHEN sh.source_id = 0 THEN NULL:: integer
    ELSE sh.source_id END AS source_id,
    sr1.source_nm AS source_name,
    sh.sub_source_id,
    sr2.source_nm AS sub_source_name,
    sh.sub_sub_source_id,
    sr3.source_nm AS sub_sub_source_name,
    sh.company_cd AS company_code,
    co.company_nm AS company_name,
    sh.statement_header_status_id,
    shs.statement_header_status_nm AS statement_header_status_name,
    oo.currency_cd AS currency_code,
    sh.total_lc_gross_statement_am AS total_lc_gross_stmt_am,
    sh.system_lc_gross_statement_am AS system_lc_gross_stmt_am,
    sh.conversion_commission_rt,
    sh.exchange_rate_to_local_rt AS exchange_to_local_currency,
    sh.exchange_rate_to_us_rt AS exchange_to_us_currency,
    sh.withholding_tax_rt AS withholding_tax_rate,
    sh.total_converted_net_am,
    sh.total_lines_qt,
    sh.semiannual_royalty_period_dt AS semiannual_statement_period,
    sh.quarterly_royalty_period_dt AS quarterly_statement_period,
    sh.released_accounting_period_dt AS sh_released_acctg_period_dt,
    sh.check_number_tx,
    sh.sales_type_id AS sales_type,
    sh.income_type_id,
    tit.income_type_nm AS income_type_name,
    sh.load_file_id,
    sf.file_nm AS file_name,
    sf.load_dt AS load_date,
    sh.error_cd AS error_code,
    CASE
    WHEN sh.special_rate_ind:: text = 'Y':: text THEN 'Yes':: text
    WHEN sh.special_rate_ind:: text = 'N':: text THEN 'No':: text
    ELSE NULL:: text END AS special_rate,
    sh.special_rate_apprvd_by_user_id AS special_rate_approved_user_id,
    sh.special_rate_apprvd_by_dt AS special_rate_approved_by_date,
    CASE
    WHEN sh.data_punch_ind:: text = 'Y':: text THEN 'Yes':: text
    WHEN sh.data_punch_ind:: text = 'N':: text THEN 'No':: text
    ELSE NULL:: text END AS data_punch,
    CASE
    WHEN sh.hold_statement_ind:: text = 'Y':: text THEN 'Yes':: text
    WHEN sh.hold_statement_ind:: text = 'N':: text THEN 'No':: text
    ELSE NULL:: text END AS hold_statement,
    CASE
    WHEN sh.intercompany_header_ind:: text = 'Y':: text THEN 'Yes':: text
    WHEN sh.intercompany_header_ind:: text = 'N':: text THEN 'No':: text
    ELSE NULL:: text END AS intercompany_header,
    sh.notes_tx AS notes,
    sh.create_id AS created_by,
    sh.create_dt AS create_date,
    sh.update_id AS update_by,
    sh.update_dt AS update_date,
    sh.ui_who_updated_id AS ui_updated_by,
    sh.ui_when_updated_dt AS ui_updated_date,
    sh.current_owner_id AS current_owner,
    CASE
    WHEN sh.suspense_threshold_applied:: text = 'Y':: text THEN 'Yes':: text
    WHEN sh.suspense_threshold_applied:: text = 'N':: text THEN 'No':: text
    ELSE NULL:: text END AS suspense_threshold_applied,
    CASE
    WHEN sh.sl_mismatch_ind:: text = 'Y':: text THEN 'Yes':: text
    WHEN sh.sl_mismatch_ind:: text = 'N':: text THEN 'No':: text
    ELSE NULL:: text END AS sl_mismatch,
    sh.sl_mismatch_approval_id AS sl_mismatch_approval,
    CASE
    WHEN sh.voiding_ind:: text = 'Y':: text THEN 'Yes':: text
    WHEN sh.voiding_ind:: text = 'N':: text THEN 'No':: text
    ELSE NULL:: text END AS voiding,
    sh.initial_unmatched_line_qt AS initial_unmatched_line,
    sh.migrated_statement_id AS migrated_stmt_id,
    CASE
    WHEN sh.consolidating_ind:: text = 'Y':: text THEN 'Yes':: text
    WHEN sh.consolidating_ind:: text = 'N':: text THEN 'No':: text
    ELSE 'No':: text END AS consolidated,
    CASE
    WHEN sh.release_verified_ind:: text = 'Y':: text THEN 'Yes':: text
    WHEN sh.release_verified_ind:: text = 'N':: text THEN 'No':: text
    ELSE NULL:: text END AS release_verified,
    sh.distribution_dt
FROM
    edw.tempo_statement_header sh
    JOIN edw.tempo_orig_office oo ON oo.orig_office_id = sh.processing_office_id
    JOIN edw.tempo_statement_type st ON st.statement_type_id = sh.statement_type_id
    JOIN edw.tempo_source sr1 ON sh.source_id = sr1.source_id
    LEFT JOIN edw.tempo_source sr2 ON sh.sub_source_id = sr2.source_id
    LEFT JOIN edw.tempo_source sr3 ON sh.sub_sub_source_id = sr3.source_id
    JOIN edw.tempo_company co ON co.company_cd:: text = sh.company_cd:: text
    JOIN edw.tempo_statement_header_status shs ON sh.statement_header_status_id = shs.statement_header_status_id
    LEFT JOIN edw.tempo_income_type tit ON sh.income_type_id = tit.income_type_id
    LEFT JOIN edw.tempo_staging_stmt_file sf ON sh.load_file_id = sf.staging_stmt_file_id;

CREATE
OR REPLACE VIEW "dp_statement_lines"."statement_lines_v" AS
SELECT
    oo.orig_office_nm AS processing_office_name,
    sl.processing_office_id,
    sl.statement_header_id,
    sl.statement_line_id,
    CASE
    WHEN sl.statement_line_status_id = 3
    AND sl.statement_line_finalized_ind:: text = 'Y':: text THEN (
        SELECT
            tempo_statement_line_status.statement_line_status_nm
        FROM
            edw.tempo_statement_line_status
        WHERE
            tempo_statement_line_status.statement_line_status_id = 12
    )
    ELSE ss.statement_line_status_nm END AS statement_line_status,
    sl.statement_line_status_id,
    sl.accounting_period_dt,
    sh.semiannual_royalty_period_dt AS semiannual_statement_period,
    sh.quarterly_royalty_period_dt AS quarterly_statement_period,
    sh.reporting_period_start_dt AS sh_reporting_period_start,
    sh.reporting_period_end_dt AS sh_reporting_period_end,
    CASE
    WHEN sl.source_id = 0 THEN NULL:: integer
    ELSE sl.source_id END AS source_id,
    sr1.source_nm AS source_name,
    CASE
    WHEN sl.sub_source_id = 0 THEN NULL:: integer
    ELSE sl.sub_source_id END AS sub_source_id,
    sr2.source_nm AS sub_source_name,
    sl.orig_sub_source_cd,
    sl.sub_sub_source_id,
    sr3.source_nm AS sub_sub_source_name,
    sl.orig_sub_sub_source_cd,
    sl.orig_sub_sub_sub_source_cd,
    sl.orig_sub_sub_source_id AS sub_sub_sub_source_id,
    sr4.source_nm AS sub_sub_sub_source_name,
    eg.entity_group_nm AS entity,
    cg.company_group_cd,
    cg.company_group_nm AS company_group,
    co.company_cd,
    co.company_nm AS company_name,
    sl.src_member_id,
    sm.member_name_tx AS src_member_name,
    sl.song_id,
    sl.song_sequence_id,
    sl.song_payment_option_id,
    s.migrated_song_id,
    s.song_title_tx AS song_title,
    sp.season_num AS season,
    sp.episode_num:: text || COALESCE(sp.episode_suffix_tx, '':: character varying):: text AS episode,
    wd.writer AS smp_writer,
    sl.src_song_production_title_tx AS src_song_production_title,
    sl.src_film_or_tv_title_tx AS src_film_or_tv_title,
    sl.src_episode_title_tx AS src_episode_title,
    sl.src_film_or_tv_num AS src_film_or_tv_number,
    sl.src_work_number_tx AS src_work_number,
    sl.src_sub_work_number_tx AS src_sub_work_number,
    sl.src_writer_nm AS src_writer_name,
    sl.src_episode_num AS src_episode_number,
    CASE
    WHEN regexp_count(sl.src_share_pc:: text, '[^[0-9]]':: text) = 0 THEN sl.src_share_pc
    ELSE NULL:: character varying END AS src_share_pc,
    it.income_type_nm AS income_type_name,
    it.income_type_id,
    sl.orig_income_type_cd,
    sl.src_product_number_tx AS src_product_number,
    CASE
    WHEN regexp_count(sl.src_units_qt:: text, '[^[0-9]]':: text) = 0 THEN sl.src_units_qt
    ELSE NULL:: character varying END AS src_units_qt,
    sl.lc_gross_statement_am AS lc_gross_stmt_am,
    sh.conversion_commission_rt AS conversion_comm_rt,
    sh.withholding_tax_rt AS withholding_tax_rate,
    sh.exchange_rate_to_us_rt AS exchange_to_us_currency,
    sh.exchange_rate_to_local_rt AS exchange_to_local_currency,
    sl.converted_net_am,
    tt.transaction_type_nm AS transaction_type_name,
    CASE
    WHEN sl.statement_line_finalized_ind:: text = 'Y':: text THEN 'Yes':: text
    WHEN sl.statement_line_finalized_ind:: text = 'N':: text THEN 'No':: text
    ELSE NULL:: text END AS sl_finalized,
    sl.sales_period_start_dt AS sales_period_start,
    sl.sales_period_end_dt AS sales_period_end,
    sh.released_accounting_period_dt AS sh_released_acctg_period_dt,
    sl.notes_tx AS notes,
    sl.src_artist_nm AS src_artist,
    sl.src_product_title_tx AS src_product_title,
    sl.src_sub_title_tx AS src_sub_title,
    sl.src_series_title_tx AS src_series_title,
    sl.src_check_number_tx AS src_check_number,
    sl.lc_at_source_net_am,
    st.sales_type_nm AS sales_type_name,
    sl.orig_sales_type_cd,
    sl.src_sub_source_pub_num_tx AS "src_sub_source_publisher_no.",
    sl.src_iswc_cd AS src_iswc,
    sl.src_isrc_cd AS src_isrc,
    sl.src_isan_number_tx AS src_isan,
    sl.src_upc_ean_cd AS src_upc_ean,
    sl.src_network_code_tx AS src_network_code,
    sl.src_country_nm AS src_country,
    sl.src_third_party_info_tx AS src_third_party_info,
    sl.src_configuration_nm AS src_configuration,
    sl.src_sales_channel_nm AS src_sales_channel,
    sl.src_collectable_rate_pc,
    sl.src_rate_pc,
    sl.src_penny_rate_am,
    sl.src_retail_price_am,
    sl.src_ppd_price_am,
    sl.src_misc_info_tx AS src_misc_info,
    sl.src_license_id,
    CASE
    WHEN sl.manual_entry_ind:: text = 'Y':: text THEN 'Yes':: text
    WHEN sl.manual_entry_ind:: text = 'N':: text THEN 'No':: text
    ELSE NULL:: text END AS manual_entry_ind,
    sl.intercompany_stmt_header_id AS intercompany_sh,
    sl.intercompany_proc_office_id AS intercompany_po,
    sl.intercompany_stmt_line_id AS intercompany_sl,
    CASE
    WHEN sl.statement_line_status_id = 4 THEN ec.aggregated_error_cd
    ELSE NULL:: character varying END AS error_code,
    sl.create_id AS created_by,
    sl.create_dt AS create_date,
    sl.ui_update_id AS updated_by,
    sl.ui_update_dt AS update_date,
    sl.income_tracking_product_num_tx AS it_product_number,
    sl.income_tracking_prod_title_tx AS it_product_title,
    sl.income_tracking_isrc_cd AS it_isrc,
    sl.income_tracking_units_qt AS it_units,
    sl.income_trckng_effective_rt_am AS it_effective_rt_am,
    sl.income_tracking_gross_stmt_am AS it_gross_stmt_am,
    CASE
    WHEN sl.income_tracking_status_id IS NOT NULL THEN its.income_tracking_status_nm
    ELSE NULL:: character varying END AS it_status,
    sl.income_tracking_match_id AS it_match_id,
    CASE
    WHEN sl.mechanical_product_id IS NOT NULL THEN tl.licensee_nm
    ELSE NULL:: character varying END AS licensee,
    sl.mechanical_product_match_ind,
    CASE
    WHEN sl.mechanical_product_id IS NOT NULL THEN tmp.product_num_tx
    ELSE NULL:: character varying END AS mechanical_product_no,
    sr5.source_nm AS match_source,
    sl.song_match_tier_id AS match_tier,
    sl.source_stmt_match_file_seq_id AS match_file_id,
    slws.statement_line_work_status_id,
    CASE
    WHEN s.song_type_id = 2 THEN 'Film':: text
    WHEN s.song_type_id = 3 THEN 'TV':: text
    WHEN sd.film_tv_ind:: text = 'F':: text THEN 'Film':: text
    WHEN sd.film_tv_ind:: text = 'T':: text THEN 'TV':: text
    WHEN sd.film_tv_ind:: text = 'L':: text THEN 'Library':: text
    WHEN sd.film_tv_ind:: text = 'N':: text THEN 'No':: text
    ELSE NULL:: text END AS "film/tv/library",
    CASE
    WHEN sl.sl_mismatch_ind:: text = 'Y':: text THEN 'Yes':: text
    WHEN sl.sl_mismatch_ind:: text = 'N':: text THEN 'No':: text
    ELSE NULL:: text END AS sl_mismatch,
    CASE
    WHEN sl.adjusted_line_ind:: text = 'Y':: text THEN 'Yes':: text
    WHEN sl.adjusted_line_ind:: text = 'N':: text THEN 'No':: text
    ELSE NULL:: text END AS adjusted_line_ind,
    CASE
    WHEN sh.consolidating_ind:: text = 'Y':: text THEN 'Yes':: text
    WHEN sh.consolidating_ind:: text = 'N':: text THEN 'No':: text
    ELSE 'No':: text END AS consolidated,
    CASE
    WHEN sm.ftv_ind:: text = 'Y':: text THEN 'Yes':: text
    WHEN sm.ftv_ind:: text = 'N':: text THEN 'No':: text
    ELSE 'No':: text END AS ftv_member,
    sl.system_suspense_note_tx AS suspense_notes,
    sl.multiple_po_flag_ind AS multiple_po_flag,
    s.rfk_ind,
    sl.bypass_recalc_ind,
    sl.release_to_profit_approval_id,
    sl.release_to_profit_approval_dt
FROM
    (
        SELECT
            tempo_statement_header.statement_header_id,
            tempo_statement_header.processing_office_id,
            tempo_statement_header.load_file_id,
            tempo_statement_header.semiannual_royalty_period_dt,
            tempo_statement_header.quarterly_royalty_period_dt,
            tempo_statement_header.reporting_period_start_dt,
            tempo_statement_header.reporting_period_end_dt,
            tempo_statement_header.conversion_commission_rt,
            tempo_statement_header.withholding_tax_rt,
            tempo_statement_header.exchange_rate_to_us_rt,
            tempo_statement_header.exchange_rate_to_local_rt,
            tempo_statement_header.released_accounting_period_dt,
            tempo_statement_header.consolidating_ind
        FROM
            edw.tempo_statement_header
    ) sh
    JOIN edw.tempo_statement_line sl ON sl.statement_header_id = sh.statement_header_id
    AND sl.processing_office_id = sh.processing_office_id
    LEFT JOIN edw.tempo_company co ON co.company_cd:: text = sl.company_cd:: text
    JOIN edw.tempo_company_group cg ON cg.company_group_cd:: text = co.company_group_cd:: text
    JOIN edw.tempo_orig_office oo ON oo.orig_office_id = sl.processing_office_id
    LEFT JOIN edw.tempo_statement_line_status ss ON sl.statement_line_status_id = ss.statement_line_status_id
    JOIN edw.tempo_income_type it ON sl.income_type_id = it.income_type_id
    JOIN edw.tempo_transaction_type tt ON sl.transaction_type_id = tt.transaction_type_id
    LEFT JOIN edw.tempo_sales_type st ON st.sales_type_id = sl.sales_type_id
    JOIN edw.tempo_entity_group eg ON cg.entity_group_id = eg.entity_group_id
    LEFT JOIN edw.tempo_source sr1 ON sl.source_id = sr1.source_id
    LEFT JOIN edw.tempo_source sr2 ON sl.sub_source_id = sr2.source_id
    LEFT JOIN edw.tempo_source sr3 ON sl.sub_sub_source_id = sr3.source_id
    LEFT JOIN edw.tempo_source sr4 ON sl.orig_sub_sub_source_id = sr4.source_id
    LEFT JOIN edw.tempo_source sr5 ON sl.match_source_id = sr5.source_id
    LEFT JOIN edw.tempo_statement_line_work_status slws ON slws.statement_line_work_status_id = sl.statement_line_work_status_id
    LEFT JOIN edw.tempo_income_tracking_status its ON its.income_tracking_status_id:: text = sl.income_tracking_status_id:: text
    LEFT JOIN edw.tempo_mechanical_product tmp ON tmp.mechanical_product_id = sl.mechanical_product_id
    LEFT JOIN edw.tempo_licensee tl ON tl.licensee_id = tmp.licensee_id
    LEFT JOIN edw.tempo_staging_stmt_file ssf ON ssf.staging_stmt_file_id = sh.load_file_id
    LEFT JOIN edw.tempo_source_member sm ON sm.file_type_id = ssf.file_type_id
    AND sm.file_office_id = ssf.load_office_id
    AND sm.file_source_id = ssf.file_source_id
    AND sm.member_id:: text = sl.src_member_id:: text
    AND len(sm.member_id:: text) = len(sl.src_member_id:: text)
    AND sm.file_source_id = sl.source_id
    AND sm.file_office_id = sl.processing_office_id
    LEFT JOIN edw.tempo_song s ON s.song_id = sl.song_id
    AND s.song_sequence_id = sl.song_sequence_id
    AND s.prior_version_ind:: text = 'N':: text
    LEFT JOIN edw.tempo_song_detail sd ON sd.song_id = s.song_id
    AND sd.song_sequence_id = s.song_sequence_id
    AND sd.prior_version_ind:: text = s.prior_version_ind:: text
    LEFT JOIN (
        SELECT
            tempo_statement_line_error_detail.processing_office_id,
            tempo_statement_line_error_detail.statement_header_id,
            tempo_statement_line_error_detail.statement_line_id,
            pg_catalog.listagg(
                DISTINCT tempo_statement_line_error_detail.error_cd:: text,
                '; ':: text
            ) WITHIN GROUP(
                ORDER BY
                    tempo_statement_line_error_detail.error_cd
            ) AS aggregated_error_cd
        FROM
            edw.tempo_statement_line_error_detail
        GROUP BY
            tempo_statement_line_error_detail.processing_office_id,
            tempo_statement_line_error_detail.statement_header_id,
            tempo_statement_line_error_detail.statement_line_id
    ) ec ON sl.processing_office_id = ec.processing_office_id
    AND sl.statement_header_id = ec.statement_header_id
    AND sl.statement_line_id = ec.statement_line_id
    LEFT JOIN edw.tempo_song_production sp ON sp.song_id = s.song_id
    AND sp.song_sequence_id = s.song_sequence_id
    AND sp.prior_version_ind:: text = 'N':: text
    AND sp.episode_num IS NOT NULL
    LEFT JOIN (
        SELECT
            siw.song_id,
            siw.song_sequence_id,
            pg_catalog.listagg(DISTINCT w.first_last_nm:: text, ',':: text) WITHIN GROUP(
                ORDER BY
                    w.first_last_nm
            ) AS writer
        FROM
            edw.tempo_song_ip_writer siw
            JOIN edw.tempo_writer w ON w.writer_id = siw.writer_id
        WHERE
            siw.prior_version_ind:: text = 'N':: text
        GROUP BY
            siw.song_id,
            siw.song_sequence_id
    ) wd ON wd.song_id = sl.song_id
    AND wd.song_sequence_id = sl.song_sequence_id;
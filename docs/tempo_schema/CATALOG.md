# Catálogo Tempo (generado desde Enterprise_Metadata_Workbook_Consolidated.xlsx)

Fuente de verdad: `sa00X_*.sql` (DDL) y `workbook_csv/` (workbook completo, una hoja por CSV).
Este archivo es un índice rápido: objetos, grano, columnas y relaciones.


## SA-001 — Song Rights & Administration  (`dp_song_metadata`)

### `dp_song_metadata.cwr_details_message_v` (View) — CWR Registration Messages
- **Grano:** One row per distinct selected CWR-message combination.
- **Qué es:** Acknowledgement and registration messages associated with song CWR detail records.
- **Clave candidata:** Candidate composite including song_cwr_details_id and acknowledgement level
- **Columnas:** `song_id`, `song_sequence_id`, `song_cwr_details_id`, `song_ack_level_num`, `song_registration_cd`, `song_ack_message_tx`, `created_by`, `created_on`

### `dp_song_metadata.cwr_details_v` (View) — CWR Registration Details
- **Grano:** Candidate one row per song CWR detail, subject to joins.
- **Qué es:** CWR registration processing, recipient, file and acknowledgement details.
- **Clave candidata:** Candidate song_cwr_details_id
- **Columnas:** `cwr_reg_office_id`, `cwr_reg_office_nm`, `song_orig_office_nm`, `song_id`, `song_sequence_id`, `song_title_tx`, `song_cwr_details_id`, `cwr_file_status`, `cwr_file_delivery_note`, `recipient_cd`, `recipient_name`, `recipient_type`, `include_in_cwr_ind`, `update_dates_ind`, `missing_agreement_ind`, `file_name_tx`, `file_creation_dt`, `dt_first_ack_file_loaded`, `first_ack_filename_tx`, `first_ack_dt`, `first_ack_status_cd`, `first_ack_message_tx`, `dt_second_ack_file_loaded`, `second_ack_filename_tx`, `second_ack_dt`, `second_ack_status_cd`, `second_ack_message_tx`, `manual_creation_ind`, `create_id`, `create_dt`, `update_id`, `update_dt`

### `dp_song_metadata.cwr_recipient_name_v` (View) — CWR Recipient Configuration
- **Grano:** Candidate one row per recipient code.
- **Qué es:** Recipient society configuration used in CWR processing.
- **Clave candidata:** Candidate recipient_cd
- **Columnas:** `orig_office_id`, `orig_office_nm`, `recipient_cd`, `recipient_name`, `recipient_type_nm`, `cwr_type`, `agreements_compulsory`, `update_dates`, `solar_repertoire_society`

### `dp_song_metadata.cwr_society_work_number_v` (View) — CWR Society Work Numbers
- **Grano:** One row per song, sequence, society and work number.
- **Qué es:** Society-assigned work numbers received through CWR acknowledgement processing.
- **Clave candidata:** song_id + song_sequence_id + society_cd + work_number_tx
- **Columnas:** `orig_office_id`, `orig_office_nm`, `song_id`, `song_sequence_id`, `song_title_tx`, `society_cd`, `society_nm`, `work_number_tx`, `ack_file_name_tx`, `create_id`, `create_dt`, `update_id`, `update_dt`

### `dp_song_metadata.identifiers_isrc_v` (View) — Song ISRC Identifiers
- **Grano:** One row per song and ISRC record.
- **Qué es:** ISRC identifiers associated with Tempo songs and matching metadata.
- **Clave candidata:** tempo_song_id + isrc_code
- **Columnas:** `isrc_code`, `tempo_song_id`, `tempo_song_title`, `vintage_date`, `input_source`, `source_name`, `source_artist`, `source_title`, `match_type`, `conflict_indicator`, `created_by`

### `dp_song_metadata.identifiers_iswc_v` (View) — Song ISWC Identifiers
- **Grano:** One row per song and ISWC record.
- **Qué es:** ISWC identifiers associated with Tempo songs.
- **Clave candidata:** tempo_song_id + ident_iswc_cd
- **Columnas:** `ident_iswc_cd`, `tempo_song_id`, `tempo_song_title`, `vintage_dt`, `input_source`, `source_name`, `preferred_indicator`, `conflict_indicator`, `created_by`, `song_id_match_ind`, `match_type`

### `dp_song_metadata.identifiers_swn_v` (View) — Song Society Work Number Identifiers
- **Grano:** One row per song, identifier type and society work number.
- **Qué es:** Society work numbers captured through identifier sources, including manual and statement-match sources.
- **Clave candidata:** tempo_song_id + ident_type_desc + society_work_no
- **Columnas:** `ident_type_desc`, `society_nm`, `society_work_no`, `tempo_song_id`, `tempo_song_title`, `vintage_dt`, `input_source`, `source_name`, `match_type`, `conflict_indicator`, `created_by`

### `dp_song_metadata.song_alerts_v` (View) — Song Alerts
- **Grano:** One row per alert/attachment combination; exact intended grain remains open.
- **Qué es:** Current song alerts with categories, cleaned notes and optional attachments.
- **Clave candidata:** Candidate song_alert_id + attachment_file_name
- **Columnas:** `song_id`, `song_sequence_id`, `song_title_tx`, `song_alert_id`, `song_alert_categories_id`, `song_alert_categories_nm`, `create_id`, `create_dt`, `update_id`, `update_dt`, `active_ind`, `notes_tx`, `attachments_ind`, `attachment_file_name`, `attachment_description`

### `dp_song_metadata.song_alternate_titles_v` (View) — Song Alternate Titles
- **Grano:** One row per alternate title and associated country.
- **Qué es:** Current alternate titles with language, script, title type and country.
- **Clave candidata:** song_alternate_title_id + country_cd
- **Columnas:** `song_id`, `song_sequence_id`, `song_alternate_title_id`, `song_alternate_title_tx`, `local_title_ind`, `create_id`, `create_dt`, `update_id`, `update_dt`, `language_cd`, `language_nm`, `title_type_cd`, `title_type_nm`, `song_alt_title_non_diac_tx`, `language_script_cd`, `language_script_nm`, `avi_status_ind`, `avi_status_dt`, `country_cd`

### `dp_song_metadata.song_artist_release_info_v` (View) — Song Label-Production Metadata
- **Grano:** One row per song_label_production_id.
- **Qué es:** Flexible user-created metadata records that may contain any combination of artist, ISRC, album, label, product or release attributes.
- **Clave candidata:** song_label_production_id
- **Columnas:** `song_id`, `song_sequence_id`, `song_title_tx`, `song_label_production_id`, `prior_version_ind`, `artist_id`, `artist_nm`, `artist_professional_nm`, `product_number_tx`, `label_production_id`, `label_production_nm`, `song_ind`, `production_ind`, `label_copy_ind`, `create_id`, `create_dt`, `update_id`, `update_dt`, `include_in_cwr_ind`, `album_title_tx`, `first_release_dt`, `ean_tx`, `isrc_tx`, `recording_format_cd`, `recording_technique_cd`, `cwr_media_type_cd`, `first_release_duration_tx`, `cut_id`

### `dp_song_metadata.song_episodes_v` (View) — Production Episodes
- **Grano:** One row per episode sequence; song_sequence_id > 0 identifies the episode.
- **Qué es:** Episode rows linked to parent episodic productions.
- **Clave candidata:** production_id + episode_sequence_id
- **Columnas:** `production_id`, `production_sequence_id`, `production_title_tx`, `episode_sequence_id`, `episode_title_tx`, `song_type_nm`, `production_release_dt`, `episode_release_dt`, `season_num`, `episode_num`, `episode_num_suffix`, `orig_office_id`, `orig_office_nm`, `tempo_create_date`, `created_by`, `tempo_last_updated_date`, `updated_by`, `hold_tx`

### `dp_song_metadata.song_production_v` (View) — Productions
- **Grano:** One row per production at song_sequence_id=0.
- **Qué es:** Current production records at sequence zero.
- **Clave candidata:** production_id + production_sequence_id
- **Columnas:** `production_id`, `production_sequence_id`, `production_title_tx`, `song_type_nm`, `production_release_dt`, `orig_office_id`, `orig_office_nm`, `production_type_cd`, `production_type_nm`, `production_company_nm`, `tempo_create_date`, `created_by`, `tempo_last_updated_date`, `updated_by`, `hold_tx`, `hold_description`

### `dp_song_metadata.song_v` (View) — Songs
- **Grano:** One row per current song and sequence after aggregation.
- **Qué es:** Current musical-work records enriched with office, production, writers, artists, alerts and holds.
- **Clave candidata:** song_id + song_sequence_id
- **Columnas:** `song_id`, `song_sequence_id`, `song_title_tx`, `language_cd`, `utility_song_indicator_id`, `utility_song_indicator_nm`, `song_type_nm`, `song_not_ours_dt`, `copyright_year`, `film_tv_ind`, `rolled_up_production_id`, `rolled_up_production_sequence_id`, `rolled_up_production_title_tx`, `client_song_id`, `orig_office_id`, `orig_office_nm`, `created_by`, `tempo_create_date`, `updated_by`, `tempo_last_updated_date`, `writers_tx`, `smp_writers_tx`, `artist_tx`, `song_alerts_tx`, `song_alerts_notes_tx`, `hold_tx`

### `dp_song_metadata.tempo_song_production_reporting_gr_v` (View) — Song Production Reporting Groups
- **Grano:** One row per song sequence and reporting-group assignment.
- **Qué es:** User-created reusable groups of song IDs with name/description for filtering reports.
- **Clave candidata:** song_id + song_sequence_id + song_reporting_group_id
- **Columnas:** `song_id`, `song_sequence_id`, `song_reporting_group_id`, `song_reporting_group_nm`, `song_reporting_group_notes_tx`, `create_id`, `create_dt`

### `dp_song_metadata.tempo_active_song_rate_client_v` (View) — Active Song Rate Clients
- **Grano:** Candidate composite across song, payment option, office group, rate, client, contract and subcontract.
- **Qué es:** Current active royalty-calculation allocation rows connecting song, payment option, office group, client, contract and subcontract. This object is frequently used to determine whether a song is associated with a client and contract. Because multiple active clients may exist for the same contract and song, this object should not typically be joined directly to ownership-share objects without prior aggregation. Doing so can result in row multiplication and double counting of ownership percentages
- **Clave candidata:** Composite; remains open
- **Columnas:** `song_id`, `song_payment_option_id`, `payment_option_active_ind`, `payment_option_primary_ind`, `payment_option_notes_tx`, `active_office_group`, `song_rate_office_group_id`, `song_rate_office_group_nm`, `song_rate_id`, `primary_song_rate_id`, `active_song_client`, `client_id`, `contract_id`, `subcontract_id`, `client_share_pc`

### `dp_song_metadata.song_share_summary_mv` (Materialized View) — Song Share Summary
- **Grano:** One row per song + song IP territory + writer + associated contract, with publishers aggregated.
- **Qué es:** Writer-level song-IP summary; multiple publishers are concatenated to avoid double-counting writer contribution. Publisher percentages should not be interpreted as song-level totals without aggregation. The view is maintained at writer-level ownership grain and therefore multiple rows may contribute to the total controlled share for a territory.
- **Clave candidata:** song + territory + writer + contract
- **Columnas:** `song_id`, `song_sequence_id`, `song_title_tx`, `song_type_nm`, `writer_id`, `writer_nm`, `writer_contribution_pc`, `writer_mechanical_society_nm`, `writer_performance_society_nm`, `associated_contract_id`, `associated_contract_nm`, `smp_controlled_ind`, `song_ip_territory_nm`, `song_contract_territory_nm`, `publisher_name_tx`, `publisher_control_pc`, `publisher_mechanical_pc`, `publisher_performance_pc`, `publisher_sync_pc`, `writer_mechanical_pc`, `writer_performance_pc`, `writer_sync_pc`

### `dp_song_metadata.song_share_detail_mv` (Materialized View) — Song Share Detail
- **Grano:** One row per song + IP territory + writer + publisher + associated contract + hierarchy relationship.
- **Qué es:** Most detailed representation of a song IP chain, closely reflecting the Tempo UI.
- **Clave candidata:** song + territory + writer + publisher + contract + hierarchy node
- **Columnas:** `song_id`, `song_sequence_id`, `song_title_tx`, `song_type_nm`, `writer_id`, `writer_nm`, `writer_capacity_type_cd`, `writer_contribution_pc`, `writer_mechanical_society_nm`, `writer_performance_society_nm`, `associated_contract_id`, `associated_contract_nm`, `smp_controlled_ind`, `song_ip_territory_nm`, `song_contract_territory_nm`, `publisher_name_tx`, `publisher_id`, `publisher_capacity_type_cd`, `publisher_control_pc`, `publisher_mechanical_pc`, `publisher_performance_pc`, `publisher_sync_pc`, `writer_mechanical_pc`, `writer_performance_pc`, `writer_sync_pc`

### `dp_song_metadata.contract_territories` (Table) — Effective Song Contract Territories
- **Grano:** One row per Song + Contract.
- **Qué es:** Derived effective territory inclusions and exclusions for each Song and Contract after song-level overrides and contract definitions.
- **Clave candidata:** song_id + contract_id
- **Columnas:** `song_id`, `contract_id`, `contract_nm`, `inclusions`, `exclusions`


## SA-002 — Deal & Contract Administration  (`dp_deal_metadata`)

### `dp_deal_metadata.agreements_detailed_rights_v` (View) — Agreement Detailed Rights
- **Grano:** Agreement + rights group + right type + income group
- **Qué es:** Current agreement-rights-group share configuration by agreement, right type and income group.
- **Clave candidata:** Composite
- **Columnas:** `agreement_id`, `agreement_nm`, `agreement_rights_group_id`, `agreement_rights_group_nm`, `right_type_id`, `right_type_nm`, `income_type_group_id`, `income_type_group_nm`, `creator_share_pc`, `publisher_share_pc`, `our_collectable_share_pc`, `create_id`, `create_dt`, `update_id`, `update_dt`

### `dp_deal_metadata.client_v` (View) — Client
- **Grano:** One row per current client_id.
- **Qué es:** Current client master and royalty/financial rollups.
- **Clave candidata:** client_id
- **Columnas:** `client_id`, `client_name`, `contract_id`, `contract_nm`, `production_id`, `episode_sequence_id`, `production_title_tx`, `episode_title_tx`, `active_ind`

### `dp_deal_metadata.contract_v` (View) — Contract
- **Grano:** One row per current contract_id.
- **Qué es:** Current contract master and lifecycle terms.
- **Clave candidata:** contract_id
- **Columnas:** `client_id`, `client_name`, `contract_id`, `contract_nm`, `song_id`, `song_sequence_id`, `song_title_tx`, `active_ind`

### `dp_deal_metadata.sub_contracts_v` (View) — Subcontracts and Rates
- **Grano:** Contract + Subcontract + Royalty Period + Office Group + Source Group + Income Type/Group (candidate).
- **Qué es:** Detailed subcontract royalty rates and configuration.
- **Clave candidata:** Composite; exact grain open
- **Columnas:** `client_id`, `client_name`, `contract_id`, `contract_nm`, `song_id`, `song_sequence_id`, `song_title_tx`, `active_ind`

### `dp_deal_metadata.client_contract_song_episodic_production_v` (View) — Client Contract Song Episodic Production
- **Grano:** Client + Contract + Production + Episode
- **Qué es:** Curated relationship view with active/current records and inheritance logic where applicable.
- **Clave candidata:** Client + Contract + Production + Episode
- **Columnas:** `client_id`, `client_nm`, `cross_to_client_id`, `cross_to_client_nm`, `pnl_grouping_client_id`, `pnl_grouping_client_nm`, `client_type_id`, `client_type_nm`, `agreement_id`, `agreement_nm`, `company_cd`, `company_nm`, `company_group_cd`, `company_group_nm`, `orig_office_id`, `orig_office_nm`, `signing_office_id`, `signing_office_nm`, `statement_run_group_cd`, `statement_run_group_nm`, `statement_frequency_nm`, `client_commencement_dt`, `film_tv_ind`, `expired_client_ind`, `intercompany_client_ind`, `migrated_client_id`, `third_party_client_id`, `client_hold_tx`, `signing_rep_nm`, `current_rep_nm`, `contract_id`, `contract_nm`, `contract_aka_nm`, `contract_type_id`, `contract_type_nm`, `contract_commencement_dt`, `contracting_party_nm`, `samp_contracting_party_nm`, `migrated_contract_id`, `contract_hold_tx`, `first_royalty_period_dt`, `contract_expiration_dt`

### `dp_deal_metadata.client_contract_song_production_v` (View) — Client Contract Song Production
- **Grano:** Client + Contract + Production
- **Qué es:** Curated relationship view with active/current records and inheritance logic where applicable.
- **Clave candidata:** Client + Contract + Production
- **Columnas:** `client_id`, `client_name`, `payee_id`, `payee_name`, `hold_description_tx`, `inactive_ind`, `inactive_date`

### `dp_deal_metadata.client_contract_song_v` (View) — Client Contract Song
- **Grano:** Client + Contract + Song
- **Qué es:** Curated relationship view with active/current records and inheritance logic where applicable.
- **Clave candidata:** Client + Contract + Song
- **Columnas:** `client_id`, `client_name`, `production_id`, `episode_sequence_id`, `production_title_tx`, `episode_title_tx`, `active_ind`

### `dp_deal_metadata.client_contract_v` (View) — Client Contract
- **Grano:** Client + Contract
- **Qué es:** Curated relationship view with active/current records and inheritance logic where applicable.
- **Clave candidata:** Client + Contract
- **Columnas:** `client_id`, `client_name`, `production_id`, `production_seqeunce_id`, `production_title_tx`, `active_ind`

### `dp_deal_metadata.client_payee_v` (View) — Client Payee
- **Grano:** Client + Payee
- **Qué es:** Curated relationship view with active/current records and inheritance logic where applicable.
- **Clave candidata:** Client + Payee
- **Columnas:** `client_id`, `client_name`, `song_id`, `song_sequence_id`, `song_title_tx`, `active_ind`

### `dp_deal_metadata.client_song_episodic_production_v` (View) — Client Song Episodic Production
- **Grano:** Client + Production + Episode
- **Qué es:** Curated relationship view with active/current records and inheritance logic where applicable.
- **Clave candidata:** Client + Production + Episode
- **Columnas:** `client_id`, `client_nm`, `cross_to_client_id`, `cross_to_client_nm`, `pnl_grouping_client_id`, `pnl_grouping_client_nm`, `client_type_id`, `client_type_nm`, `agreement_id`, `agreement_nm`, `company_cd`, `company_nm`, `company_group_cd`, `company_group_nm`, `orig_office_id`, `orig_office_nm`, `signing_office_id`, `signing_office_nm`, `statement_run_group_cd`, `statement_run_group_nm`, `statement_frequency_nm`, `client_commencement_dt`, `client_termination_dt`, `film_tv_ind`, `expired_client_ind`, `intercompany_client_ind`, `migrated_client_id`, `third_party_client_id`, `client_hold_tx`, `signing_rep_nm`, `current_rep_nm`, `tempo_create_date`, `tempo_update_date`

### `dp_deal_metadata.client_song_production_v` (View) — Client Song Production
- **Grano:** Client + Production
- **Qué es:** Curated relationship view with active/current records and inheritance logic where applicable.
- **Clave candidata:** Client + Production
- **Columnas:** `contract_id`, `contract_nm`, `production_id`, `episode_sequence_id`, `production_title_tx`, `episode_title_tx`, `active_ind`

### `dp_deal_metadata.client_song_v` (View) — Client Song
- **Grano:** Client + Song
- **Qué es:** Curated relationship view with active/current records and inheritance logic where applicable.
- **Clave candidata:** Client + Song
- **Columnas:** `contract_id`, `contract_nm`, `production_id`, `production_sequence_id`, `production_title_tx`, `active_ind`

### `dp_deal_metadata.contract_song_episodic_production_v` (View) — Contract Song Episodic Production
- **Grano:** Contract + Production + Episode
- **Qué es:** Curated relationship view with active/current records and inheritance logic where applicable.
- **Clave candidata:** Contract + Production + Episode
- **Columnas:** `contract_id`, `contract_nm`, `song_id`, `song_sequence_id`, `song_title_tx`, `active_ind`

### `dp_deal_metadata.contract_song_production_v` (View) — Contract Song Production
- **Grano:** Contract + Production
- **Qué es:** Curated relationship view with active/current records and inheritance logic where applicable.
- **Clave candidata:** Contract + Production
- **Columnas:** `contract_id`, `contract_nm`, `contract_aka_nm`, `contract_type_id`, `contract_type_nm`, `orig_office_id`, `orig_office_nm`, `contract_commencement_dt`, `life_of_copyright_ind`, `retention_years`, `collection_end_months`, `contracting_party_nm`, `samp_contracting_party_nm`, `migrated_contract_id`, `third_party_deal_id`, `contract_hold_cd`, `contract_hold_tx`, `first_royalty_period_dt`, `contract_expiration_dt`, `tempo_create_date`, `tempo_update_date`, `mech_society`, `preferred_us_mech_society`, `perf_society`, `preferred_us_perf_society`, `blackbox_processing_ind`

### `dp_deal_metadata.contract_song_v` (View) — Contract Song
- **Grano:** Contract + Song
- **Qué es:** Curated relationship view with active/current records and inheritance logic where applicable.
- **Clave candidata:** Contract + Song
- **Columnas:** `cross_client_id`, `cross_client_name`, `song_id`, `song_sequence_id`, `production_title_tx`, `episode_title_tx`, `active_ind`

### `dp_deal_metadata.cross_client_song_episodic_production_v` (View) — Cross Client Song Episodic Production
- **Grano:** Cross-To Client + Production + Episode
- **Qué es:** Curated relationship view with active/current records and inheritance logic where applicable.
- **Clave candidata:** Cross-To Client + Production + Episode
- **Columnas:** `cross_client_id`, `cross_client_name`, `production_id`, `production_sequence_id`, `production_title_tx`, `active_ind`

### `dp_deal_metadata.cross_client_song_production_v` (View) — Cross Client Song Production
- **Grano:** Cross-To Client + Production
- **Qué es:** Curated relationship view with active/current records and inheritance logic where applicable.
- **Clave candidata:** Cross-To Client + Production
- **Columnas:** `cross_client_id`, `cross_client_name`, `song_id`, `song_sequence_id`, `song_title_tx`, `active_ind`

### `dp_deal_metadata.cross_client_song_v` (View) — Cross Client Song
- **Grano:** Cross-To Client + Song
- **Qué es:** Curated relationship view with active/current records and inheritance logic where applicable.
- **Clave candidata:** Cross-To Client + Song
- **Columnas:** `pnl_grouping_client_id`, `pnl_grouping_client_name`, `production_id`, `episode_sequence_id`, `production_title_tx`, `episode_title_tx`, `active_ind`

### `dp_deal_metadata.pnl_client_song_episodic_production_v` (View) — P&L Client Song Episodic Production
- **Grano:** P&L Client + Production + Episode
- **Qué es:** Curated relationship view with active/current records and inheritance logic where applicable.
- **Clave candidata:** P&L Client + Production + Episode
- **Columnas:** `pnl_grouping_client_id`, `pnl_grouping_client_name`, `production_id`, `production_sequence_id`, `production_title_tx`, `active_ind`

### `dp_deal_metadata.pnl_client_song_production_v` (View) — P&L Client Song Production
- **Grano:** P&L Client + Production
- **Qué es:** Curated relationship view with active/current records and inheritance logic where applicable.
- **Clave candidata:** P&L Client + Production
- **Columnas:** `song_id`, `song_sequence_id`, `song_title_tx`, `pnl_grouping_client_id`, `pnl_grouping_client_nm`, `active_ind`

### `dp_deal_metadata.pnl_client_song_v` (View) — P&L Client Song
- **Grano:** P&L Client + Song
- **Qué es:** Curated relationship view with active/current records and inheritance logic where applicable.
- **Clave candidata:** P&L Client + Song
- **Columnas:** `contract_id`, `contract_nm`, `subcontract_id`, `subcontract_nm`, `rate_type_id`, `rate_type_nm`, `subcontract_royalty_period_dt`, `subcontract_office_group_id`, `subcontract_office_group_nm`, `subcontract_source_group_id`, `subcontract_source_group_nm`, `income_link_id`, `income_type_name`, `income_type_group_name`, `client_rate_pc`, `affiliate_remit_rate_pc`, `client_collectable_pc`, `hold_description_tx`, `subcontract_notes_tx`, `create_id`, `create_dt`, `update_id`, `update_dt`


## SA-003 — Deal Financials & Royalty Accounting  (`dp_deal_financials`)

### `dp_deal_financials.client_accounting_balances_v` (View) — Client Accounting Balances
- **Grano:** Client + Accounting Period
- **Qué es:** Accounting-period ledger balances and financial movements for Clients.
- **Clave candidata:** client_id + accounting_period_dt
- **Columnas:** `pnl_client_id`, `pnl_client_nm`, `client_commencement_dt`, `client_originating_office`, `client_signing_office`, `capitalized_acctg_period_dt`, `currency_cd`, `capitalized_opening_balance_am`, `payments_am`, `advance_am`, `other_charges_am`, `non_royalty_adjust_am`, `earnings_am`, `ft_earnings_am`, `earnings_on_hold_am`, `sessions_am`, `crossing_am`, `pre_cross_closing_bal_am`, `soft_cross_am`, `reserve_opening_balance_am`, `reserve_am`, `cumulative_reserve_am`, `reserve_closing_balance_am`, `recovery_am`, `cumulative_recovery_am`, `capitalized_closing_balance_am`, `gross_client_income_am`, `nps_am`, `foreign_nps_am`

### `dp_deal_financials.client_statement_balances_v` (View) — Client Statement Balances
- **Grano:** Client + Payee + Statement Period + Run Group
- **Qué es:** Statement-period balances, earnings, payments and payable positions by Client and Payee.
- **Clave candidata:** Composite balance key
- **Columnas:** `client_id`, `client_name`, `client_commencement_dt`, `client_originating_office`, `client_signing_office`, `accounting_period_dt`, `opening_balance_am`, `payments_am`, `advance_am`, `other_charges_am`, `non_royalty_adjust_am`, `earnings_am`, `ft_earnings_am`, `earnings_on_hold_am`, `sessions_am`, `crossing_am`, `pre_cross_closing_bal_am`, `soft_cross_am`, `closing_balance_am`, `gross_client_income_am`, `nps_am`, `foreign_nps_am`

### `dp_deal_financials.capitalized_trial_balance_v` (View) — Capitalized Trial Balance
- **Grano:** P&L Client + Capitalized Accounting Period
- **Qué es:** Capitalized balances and movements by P&L Grouping Client.
- **Clave candidata:** pnl_client_id + period
- **Columnas:** `client_id`, `client_name`, `client_commencement_dt`, `client_originating_office`, `client_signing_office`, `payee_id`, `payee_name`, `payee_inactive_ind`, `payee_inactive_dt`, `statement_period_dt`, `stmnt_run_group_cd`, `stmnt_run_group_nm`, `opening_balance_am`, `payments_am`, `advance_am`, `other_charges_am`, `non_royalty_adjust_am`, `domestic_earnings_am`, `foreign_earnings_am`, `ft_earnings_am`, `sessions_am`, `pre_cross_closing_bal_am`, `crossing_am`, `closing_balance_am`, `payable_balance_am`, `payment_hold_ind`


## SA-004 — Royalty Statements & Source Intake  (`dp_statement_lines`)

### `dp_statement_lines.statement_headers_v` (External Table) — Statement Headers
- **Grano:** One row per statement_header_id.
- **Qué es:** Royalty statement headers received from paying sources and loaded into Tempo.
- **Clave candidata:** statement_header_id
- **Columnas:** `orig_office_id`, `batch_total_am`, `batch_total_reconciled_ind`, `posted_to_gl_ind`, `batch_notes_tx`, `crj_bank_account_nm`, `crj_type_nm`, `crj_batch_id`, `crj_line_id`, `crj_bank_account_id`, `deposit_dt`, `bank_batch_number_tx`, `crj_payor_tx`, `check_wire_num_tx`, `check_am`, `dr_gst_vat_receivable_am`, `cr_gst_vat_payable_am`, `dr_deduction_am`, `crj_am`, `crj_unassociated_balance_am`, `crj_type_id`, `post_to_gl_acctg_period_dt`, `crj_non_royalty_type_id`, `crj_ref_number_tx`, `accounting_company_group_nm`, `royalty_company_nm`, `income_type_group_id`, `crj_statement_header_id`, `crj_source_nm`, `local_inf_reference_tx`, `royalty_done_ind`, `royalty_done_acctg_period_dt`, `crj_input_source_id`, `crj_notes_tx`, `create_id`, `create_dt`, `update_id`, `update_dt`, `royalty_and_sh_done_acctg_dt`, `entity_group_id`, `royalty_done_reason_id`, `license_number`, `invoice_number`, `statement_header_id`, `processing_office_id`, `cash_receipt_associated_am`, `crj_association_id`

### `dp_statement_lines.source_v` (External Table) — Royalty Sources
- **Grano:** One row per source_id.
- **Qué es:** Source reference data and processing configuration.
- **Clave candidata:** source_id
- **Columnas:** `source_stmt_match_file_seq_id`, `orig_office_id`, `orig_office_nm`, `source_id`, `source_nm`, `sub_source_id`, `sub_source_nm`, `income_type_match_group_id`, `income_type_match_group_nm`, `income_type_id`, `income_type_nm`, `src_work_number_tx`, `src_sub_work_number_tx`, `src_iswc_cd`, `src_song_production_title_tx`, `src_filmtv_title_tx`, `src_episode_num`, `src_episode_title_tx`, `src_writer_nm_tx`, `src_product_number_tx`, `song_id`, `song_title_tx`, `writers_tx`, `song_sequence_id`, `song_payment_option_id`, `matched_twice_ind`, `confirmed_match_ind`, `migrated_match_ind`, `statement_header_id`, `create_id`, `create_dt`, `update_id`, `update_dt`, `orig_source_id_overridden`

### `dp_statement_lines.master_crj_v` (External Table) — Cash Receipts Journal
- **Grano:** CRJ Batch + CRJ Line
- **Qué es:** Actual cash receipts recorded by affiliates and associated to statement headers.
- **Clave candidata:** crj_batch_id + crj_line_id
- **Columnas:** `source_country_cd`, `source_id`, `source_nm`, `used_for_stmt_header_ind`, `affiliate_ind`, `default_sales_type_id`, `default_sales_type_nm`, `default_ind`, `country_rates_ind`, `priority_num`, `track_source_ind`, `active_ind`, `rate_towards_recoup_pc`, `address_id`, `valid_to_load_ind`, `update_id`, `update_dt`, `orig_office_id`, `orig_office_nm`, `requires_sub_source_ind`, `sent_to_web_ind`, `match_inc_type_mtch_grp_id_ind`, `header_group_sources_ind`, `notes_tx`, `match_source_id`, `match_source_nm`, `deal_note_tx`, `ident_type_override_id`, `ident_type_name`, `exclude_identifier_ind`, `specific_rate_ind`, `create_dt`, `digital_source_ind`, `primary_source_id`, `primary_source_nm`, `fractional_cent_load_dec_num`, `display_in_contract_ind`

### `dp_statement_lines.source_match_records_v` (External Table) — Source Match Records
- **Grano:** One row per source match record.
- **Qué es:** Source-supplied work information matched to Tempo songs.
- **Clave candidata:** source_stmt_match_file_seq_id
- **Columnas:** `statement_header_id`, `processing_office_id`, `processing_office_name`, `orig_statement_header_id`, `orig_processing_office_id`, `statement_type_id`, `statement_type_name`, `sh_reporting_period_start`, `sh_reporting_period_end`, `source_id`, `source_name`, `sub_source_id`, `sub_source_name`, `sub_sub_source_id`, `sub_sub_source_name`, `company_code`, `company_name`, `statement_header_status_id`, `statement_header_status_name`, `currency_code`, `total_lc_gross_stmt_am`, `system_lc_gross_stmt_am`, `conversion_commission_rt`, `exchange_to_local_currency`, `exchange_to_us_currency`, `withholding_tax_rate`, `total_converted_net_am`, `total_lines_qt`, `semiannual_statement_period`, `quarterly_statement_period`, `sh_released_acctg_period_dt`, `check_number_tx`, `sales_type`, `income_type_id`, `income_type_name`, `load_file_id`, `file_name`, `load_date`, `error_code`, `special_rate`, `special_rate_approved_user_id`, `special_rate_approved_by_date`, `data_punch`, `hold_statement`, `intercompany_header`, `notes`, `created_by`, `create_date`, `update_by`, `update_date`, `ui_updated_by`, `ui_updated_date`, `current_owner`, `suspense_threshold_applied`, `sl_mismatch`, `sl_mismatch_approval`, `voiding`, `initial_unmatched_line`, `migrated_stmt_id`, `consolidated`, `release_verified`, `distribution_dt`

### `dp_statement_lines.statement_lines_v` (External Table) — Statement Lines
- **Grano:** One row per statement_line_id.
- **Qué es:** Raw royalty transaction lines before SMP royalty calculation.
- **Clave candidata:** statement_line_id
- **Columnas:** `processing_office_name`, `processing_office_id`, `statement_header_id`, `statement_line_id`, `statement_line_status`, `statement_line_status_id`, `accounting_period_dt`, `semiannual_statement_period`, `quarterly_statement_period`, `sh_reporting_period_start`, `sh_reporting_period_end`, `source_id`, `source_name`, `sub_source_id`, `sub_source_name`, `orig_sub_source_cd`, `sub_sub_source_id`, `sub_sub_source_name`, `orig_sub_sub_source_cd`, `orig_sub_sub_sub_source_cd`, `sub_sub_sub_source_id`, `sub_sub_sub_source_name`, `entity`, `company_group_cd`, `company_group`, `company_cd`, `company_name`, `src_member_id`, `src_member_name`, `song_id`, `song_sequence_id`, `song_payment_option_id`, `migrated_song_id`, `song_title`, `season`, `episode`, `smp_writer`, `src_song_production_title`, `src_film_or_tv_title`, `src_episode_title`, `src_film_or_tv_number`, `src_work_number`, `src_sub_work_number`, `src_writer_name`, `src_episode_number`, `src_share_pc`, `income_type_name`, `income_type_id`, `orig_income_type_cd`, `src_product_number`, `src_units_qt`, `lc_gross_stmt_am`, `conversion_comm_rt`, `withholding_tax_rate`, `exchange_to_us_currency`, `exchange_to_local_currency`, `converted_net_am`, `transaction_type_name`, `sl_finalized`, `sales_period_start`, `sales_period_end`, `sh_released_acctg_period_dt`, `notes`, `src_artist`, `src_product_title`, `src_sub_title`, `src_series_title`, `src_check_number`, `lc_at_source_net_am`, `sales_type_name`, `orig_sales_type_cd`, `src_sub_source_publisher_no.`, `src_iswc`, `src_isrc`, `src_isan`, `src_upc_ean`, `src_network_code`, `src_country`, `src_third_party_info`, `src_configuration`, `src_sales_channel`, `src_collectable_rate_pc`, `src_rate_pc`, `src_penny_rate_am`, `src_retail_price_am`, `src_ppd_price_am`, `src_misc_info`, `src_license_id`, `manual_entry_ind`, `intercompany_sh`, `intercompany_po`, `intercompany_sl`, `error_code`, `created_by`, `create_date`, `updated_by`, `update_date`, `it_product_number`, `it_product_title`, `it_isrc`, `it_units`, `it_effective_rt_am`, `it_gross_stmt_am`, `it_status`, `it_match_id`, `licensee`, `mechanical_product_match_ind`, `mechanical_product_no`, `match_source`, `match_tier`, `match_file_id`, `statement_line_work_status_id`, `film/tv/library`, `sl_mismatch`, `adjusted_line_ind`, `consolidated`, `ftv_member`, `suspense_notes`, `multiple_po_flag`, `rfk_ind`, `bypass_recalc_ind`, `release_to_profit_approval_id`, `release_to_profit_approval_dt`


## SA-005 — Earnings & Royalty Allocation Engine  (`dp_earnings_lines`)

### `dp_earnings_lines.earnings_lines_v` (View) — Earnings Lines
- **Grano:** One row per earnings_line_id.
- **Qué es:** Calculated royalty outputs from finalized Statement Lines, processing-office perspective.
- **Clave candidata:** earnings_line_id
- **Columnas:** 

### `dp_earnings_lines.originating_office_earnings_lines_v` (View) — Originating Office Earnings Lines
- **Grano:** One row per earnings_line_id + originating office representation.
- **Qué es:** Calculated earnings from the client/deal originating-office perspective.
- **Clave candidata:** earnings_line_id + originating office
- **Columnas:** 


## SA-006 — Sync Licensing  (`dp_sync_licencing`)

### `dp_sync_licencing.sync_licensing_v` (View) — Sync Licensing
- **Grano:** One row per sync_license_id (working assumption).
- **Qué es:** Transactions managed through the Tempo Sync Licensing module.
- **Clave candidata:** license_no
- **Columnas:** `song_no`, `song_title`, `deal_status`, `deal_owner`, `license_req_date`, `license_issued_date`, `term_start_date`, `term_end_date`, `sales_date`, `license_type`, `license_entity`, `licensee`, `clearance_company`, `invoice_party`, `production_title`, `rights_requested`, `licensed_percent`, `license_fee`, `samp_income`, `currency`, `orig_office_nm`, `orig_office_id`, `contact_id`, `contact_group_id`, `license_no`, `primary_license_no`, `license_territories`, `term`, `exclusivity`, `master_use`, `latin_america`, `license_issued_by`, `accrual_company`, `payment_due_date`, `payment_received_date`, `royalty_rate`, `step_payments`, `song_office`, `nps`, `master_title`, `catalogue`, `artist`, `master_id`, `supervisor`


## SA-007 — Songwriters & Publishers  (`dp_writer_data.`)

### `dp_writer_data.publisher_v` (View) — Publisher
- **Grano:** One row per current Publisher record sourced from edw.tempo_publisher. The source table does not maintain prior_version_ind; all records are considered current.
- **Qué es:** Current publisher master data enriched with mechanical, performance, synchronization, online, and Spain-specific society names.
- **Clave candidata:** publisher_id
- **Columnas:** `publisher_id`, `publisher_nm`, `short_nm`, `agreement_num`, `cae_num`, `mechanical_society_cd`, `mechanical_society_name`, `performance_society_cd`, `performance_society_name`, `sync_society_cd`, `sync_society_name`, `administering_samp_pub_id`, `notes_tx`, `create_id`, `create_dt`, `update_id`, `update_dt`, `online_mechanical_society_cd`, `online_mechanical_society_name`, `online_performance_society_cd`, `online_performance_society_name`, `spain_cf_number_cd`, `spain_society_1_cd`, `spain_society_1_name`, `spain_society_2_cd`, `spain_society_2_name`, `third_party_publisher_id`, `contact_id`

### `dp_writer_data.writer_data_v` (View) — Writer
- **Grano:** Intended grain is one row per Writer, including Writers without an assigned society. Current INNER JOINs can exclude Writers missing any required society mapping.
- **Qué es:** Writer master data with legal, formatted, professional names and mechanical, performance, digital mechanical, and digital performance society affiliations.
- **Clave candidata:** writer_id
- **Columnas:** `writer_id`, `writer_ipi_number`, `title_tx`, `first_nm`, `other_nm`, `last_nm`, `first_last_nm`, `first_other_nm`, `professional_nm`, `mechanical_society_name`, `performance_society_name`, `digital_mechanical_society_name`, `digital_performance_society_name`, `notes_tx`, `create_dt`, `update_dt`, `create_user`, `update_user`

### `dp_writer_data.writer_aka_data_v` (View) — Writer AKA
- **Grano:** One row per writer_aka_id with a valid AKA Type mapping.
- **Qué es:** Alternate writer identities with alias-specific IPI/CAE number and AKA type.
- **Clave candidata:** writer_aka_id
- **Columnas:** `writer_id`, `writer_aka_id`, `writer_aka_name`, `writer_aka_ipi_number`, `aka_type_name`, `create_dt`, `create_user`, `update_dt`, `update_user`


## SA-008 — Matched Charts  (`dp_matched_charts`)

### `dp_matched_charts.matched_charts_v` (View) — Matched Chart Songs
- **Grano:** One row per chart_song_id after Writer aggregation.
- **Qué es:** Chart-song master and matching view that relates source recording metadata to current Tempo songs and controlled Writers.
- **Clave candidata:** chart_song_id
- **Columnas:** `chart_song_id`, `primary_chart_song_id`, `bds_song_id`, `chart_song_key`, `isrc`, `chart_match_status`, `active_indicator`, `recording_title`, `recording_artist`, `tempo_song_id`, `tempo_song_title`, `smp_writers`, `match_id`, `match_date`, `initial_automatch_indicator`, `pending_song_ind`, `song_association_indicator`, `match_confirmed_indicator`, `controlled_indicator`, `notes`, `pending_total_control_pct`, `pending_writer_info`, `created_by`, `created_on`, `updated_by`, `updated_on`

### `dp_matched_charts.matched_quarterly_song_radio` (View) — Matched Quarterly Song Radio
- **Grano:** One row per chart_spin_charting_id, subject to required match-status relationship.
- **Qué es:** Quarterly radio chart observations enriched with upload, chart-song, and match status information.
- **Clave candidata:** chart_spin_charting_id
- **Columnas:** `chart_spin_charting_id`, `chart_upload_header_id`, `chart_album_ind`, `upload_file_nm`, `upload_created_by`, `upload_created_on`, `chart_file_type_id`, `chart_file_type_desc`, `country_cd`, `chart_song_id`, `primary_chart_song_id`, `artist_tx`, `song_title_tx`, `chart_song_isrc`, `tempo_song_id`, `chart_match_status_id`, `chart_match_status_nm`, `pending_song_ind`, `chart_match_controlled_ind`, `chart_match_confirmed_ind`, `match_created_by`, `match_created_on`, `updated_by`, `updated_on`, `chart_quarter_end_dt`, `detects`, `audience`

### `dp_matched_charts.matched_weekly_album_charts` (View) — Matched Weekly Album Charts
- **Grano:** Candidate one row per chart_album_week_id plus album-track/song relationship; LEFT joins may expand rows.
- **Qué es:** Weekly album chart performance, sales, tracks, labels, and matched song attributes.
- **Clave candidata:** Composite; chart_album_week_id + album track/song
- **Columnas:** `chart_album_week_id`, `chart_upload_header_id`, `chart_album_ind`, `upload_file_nm`, `upload_created_by`, `upload_created_on`, `chart_file_type_id`, `chart_file_type_desc`, `country_cd`, `chart_song_id`, `primary_chart_song_id`, `album_track_no`, `chart_album_id`, `primary_chart_album_id`, `album_name`, `album_artist`, `album_release_dt`, `label_nm`, `song_artist_tx`, `song_title_tx`, `chart_song_isrc`, `tempo_song_id`, `chart_match_status_id`, `chart_match_status_nm`, `pending_song_ind`, `chart_match_controlled_ind`, `chart_match_confirmed_ind`, `match_created_by`, `match_created_on`, `updated_by`, `updated_on`, `chart_type_id`, `chart_type_nm`, `chart_week_end_dt`, `chart_week`, `chart_frequency_id`, `album_rank_current`, `album_rank_last_wk`, `album_rank_two_wk`, `album_total_weeks`, `album_rank_peak`, `album_peak_dt`, `album_peak_weeks`, `album_sales_ytd`, `dig_album_sales_lw`, `dig_album_sales_tw`, `dig_album_sales_ytd`, `phys_album_sales_lw`, `phys_album_sales_tw`, `phys_album_sales_ytd`, `album_sales_prd_current`, `album_sales_prd_last`, `album_sales_prd_rtd`

### `dp_matched_charts.matched_weekly_song_charts` (View) — Matched Weekly Song Charts
- **Grano:** One row per chart_song_week_detail_id.
- **Qué es:** Weekly song chart rank, streaming, sales, and spin measures enriched with upload and chart-song matching data.
- **Clave candidata:** chart_song_week_detail_id
- **Columnas:** `chart_song_week_detail_id`, `chart_upload_header_id`, `chart_album_ind`, `upload_file_nm`, `upload_created_by`, `upload_created_on`, `chart_file_type_id`, `chart_file_type_desc`, `country_cd`, `chart_song_id`, `primary_chart_song_id`, `artist_tx`, `song_title_tx`, `chart_song_isrc`, `tempo_song_id`, `chart_match_status_id`, `chart_match_status_nm`, `pending_song_ind`, `chart_match_controlled_ind`, `chart_match_confirmed_ind`, `match_created_by`, `match_created_on`, `updated_by`, `updated_on`, `chart_type_id`, `chart_type_nm`, `chart_week_end_dt`, `territory_cd`, `chart_week`, `chart_name_tx`, `tw_rank`, `lw_rank`, `week_on_chart`, `chart_song_week_id`, `luminate_artist_id`, `luminate_song_id`, `release_dt`, `first_stream_dt`, `release_age_tx`, `overall_od_streams_tw`, `overall_od_streams_lw`, `overall_od_streams_ytd`, `od_audio_streams_tw`, `od_audio_streams_lw`, `od_audio_streams_ytd`, `od_premium_audio_streams_tw`, `od_premium_audio_streams_lw`, `od_premium_audio_streams_ytd`, `od_ads_audio_streams_tw`, `od_ads_audio_streams_lw`, `od_ads_audio_streams_ytd`, `programmed_audio_streams_tw`, `programmed_audio_streams_lw`, `programmed_audio_streams_ytd`, `od_video_streams_tw`, `od_video_streams_lw`, `od_video_streams_ytd`, `digital_sales_tw`, `digital_sales_lw`, `digital_sales_ytd`, `usrd_spins_tw`, `usrd_spins_lw`, `usrd_spins_ytd`

### `dp_matched_charts.matched_weekly_song_streams` (View) — Matched Weekly Song Streams
- **Grano:** One row per chart_stream_charting_id.
- **Qué es:** Weekly streaming observations by chart song, provider, service tier, calculation model, and week.
- **Clave candidata:** chart_stream_charting_id
- **Columnas:** `chart_stream_charting_id`, `chart_upload_header_id`, `chart_album_ind`, `upload_file_nm`, `upload_created_by`, `upload_created_on`, `chart_file_type_id`, `chart_file_type_desc`, `country_cd`, `chart_song_id`, `primary_chart_song_id`, `artist_tx`, `song_title_tx`, `chart_song_isrc`, `tempo_song_id`, `chart_match_status_id`, `chart_match_status_nm`, `pending_song_ind`, `chart_match_controlled_ind`, `chart_match_confirmed_ind`, `match_created_by`, `match_created_on`, `updated_by`, `updated_on`, `chart_stream_charting_type_id`, `digital_service_provider_nm`, `service_tier_nm`, `calc_model_nm`, `chart_week_end_dt`, `first_stream_dt`, `weekly_streams`


## SA-009 — Mechanical Licensing  (`dp_mech_licensing`)

### `dp_mech_licensing.mechanical_product_v` (View) — Mechanical Product
- **Grano:** Candidate one row per mechanical_product_id. The supplied SQL selects directly from edw.tempo_mechanical_product and enriches descriptive office, licensee, and license-type attributes through LEFT JOINs without aggregation or row filtering. Uniqueness should be confirmed against the source table.
- **Qué es:** Mechanical-product master view representing a licensed release or product managed in Tempo. The object combines the product identifier, UPC/EAN, title, artist, license and licensee references, license type and status, release and workflow dates, label, advance terms, units-sold information, controlled and collectable percentages, estimated collections, matching indicators, currency, audit attributes, and legacy life-to-date licensing measures. Use this object for product-level licensing analysis; song-level rates and terms belong in mechanical_product_song_v.
- **Clave candidata:** mechanical_product_id
- **Columnas:** `mechanical_product_id`, `orig_office_id`, `orig_office_nm`, `product_num_tx`, `upc_ean_cd`, `product_title_tx`, `license_num`, `tempo_license_id`, `licensee_id`, `licensee_nm`, `license_type_id`, `license_type_nm`, `license_status_id`, `artist_tx`, `release_dt`, `request_dt`, `issued_dt`, `received_dt`, `first_income_expected_dt`, `label_nm`, `escalation_clause_ind`, `file_num`, `total_cr_on_product`, `total_duration_on_product`, `total_controlled_pc`, `total_samp_tracks`, `track_income_ind`, `units_sold_dt`, `units_sold_qt`, `file_upload_dt`, `notes_tx`, `create_id`, `create_dt`, `update_id`, `update_dt`, `primary_product_num_tx`, `total_collectable_pc`, `income_matched`, `currency_cd`, `advance_units_qt`, `advance_am`, `mechanical_product_release_id`, `soundscan_key_tx`, `total_est_collect_am`, `ltd_units_sold_dt`, `ltd_units_sold_qt`, `ltd_total_song_agc`, `ltd_total_pro_rata_mech_rate`, `ltd_set_to_pay_pc`, `ltd_licensed_pc`, `ltd_notes_tx`

### `dp_mech_licensing.mechanical_product_song_v` (View) — Mechanical Product Song
- **Grano:** One row per current mechanical_product_song_id after optional lookup enrichment. The WHERE clause restricts the source to prior_version_ind='N'. LEFT JOINs retain the product-song row when product, licensee, license type, rate type, or current Tempo Song enrichment is unavailable.
- **Qué es:** Current song-level mechanical licensing detail for the songs included on a Mechanical Product. The object links each product-song record to product, licensee, license type, licensing rate type, and current Tempo Song information, and exposes song-specific rates, controlled and collectable shares, prior share values, advances, quantities, licensing workflow dates, duration, track attributes, income and Statement Line matching indicators, audit fields, notes, and currency. Use this object when analysis requires individual song or track terms rather than product-level totals.
- **Clave candidata:** mechanical_product_song_id
- **Columnas:** `mechanical_product_id`, `product_num_tx`, `upc_ean_cd`, `product_title_tx`, `product_artist_tx`, `licensee_nm`, `license_type_nm`, `mechanical_product_song_id`, `song_id`, `song_sequence_id`, `song_title`, `song_artist_tx`, `license_num`, `tempo_license_id`, `file_nm`, `file_upload_date`, `isrc_cd`, `hfa_tracking_num`, `licensing_rate_type_id`, `licensing_rate_type_nm`, `reduction_rate_pc`, `rate_am`, `controlled_pc`, `collectable_pc`, `prior_controlled_pc`, `prior_collectable_pc`, `prior_change_dt`, `controlled_rate_am`, `collectable_rate_am`, `advance_am`, `advance_units_qt`, `times_on_product_qt`, `request_dt`, `received_dt`, `issued_dt`, `duration_tx`, `singles_ind`, `cover_id`, `bonus_track_ind`, `hidden_track_ind`, `track_income_ind`, `favorite_nation_ind`, `update_id`, `update_dt`, `create_id`, `create_dt`, `manual_notes_tx`, `currency_cd`, `income_matched_to_product`, `matched_to_sl`, `upload_notes_tx`


## Summarised Earnings Lines —   (``)

### `dp_summarised_el.client_earnings_summary_by_song_mv` (Materialized View) — Client Earnings Summary by Song
- **Grano:** Aggregate row across the complete grouping set: originating office/currency, normalized office, signing office, Client, P&L Deal, Client type, entity group, Song, normalized Source hierarchy, original processing office, income classifications, accounting and statement periods, streaming flag, A&R rep, transaction category, hold status, fiscal year signed, Cross-to Client, AKA names, and company group. Formal business confirmation remains open.
- **Qué es:** Hybrid current-and-historical summary of royalty earnings from the Client perspective, with Song detail and monetary amounts in the Client Originating Office currency. The object implements Finance reporting rules for US/Disco/SMP Global office reporting, intercompany-aware source hierarchy, high-level income grouping, fiscal periods, semiannual statement dates, transaction categories, Deal and Cross-to-Client rollups, and A&R attribution.
- **Clave candidata:** Composite of all non-measure grouping attributes; no single physical key is exposed
- **Columnas:** `orig_office_id`, `currency_cd`, `office_nm`, `signing_office_nm`, `client_id`, `client_name`, `deal_id`, `deal_nm`, `client_type_nm`, `entity_group_nm`, `song_id`, `song_title_tx`, `source_name`, `sub_source_name`, `sub_sub_source_name`, `original_processing_office_name`, `income_group`, `fiscal_period_tx`, `calendar_year_tx`, `accounting_period_dt`, `semiannual_statement_date`, `statement_period_dt`, `is_streaming_ind`, `current_ar_rep_nm`, `transaction_category`, `on_hold_ind`, `fiscal_year_signed`, `ctc_id`, `ctc_name`, `aka_names`, `income_type_group_nm`, `income_type_nm`, `company_group`, `royalty_processed_am`, `royalty_expense_am`, `nps_am`

### `dp_summarised_el.client_earnings_summary_by_statement_header_mv` (Materialized View) — Client Earnings Summary by Statement Header
- **Grano:** One aggregate row across the complete non-measure GROUP BY set: office/currency, Client/Deal/CTC, Statement Header, Source hierarchy, income classifications, accounting/statement periods, streaming, A&R, transaction category, hold status, signing-year bucket, AKA names, and company group.
- **Qué es:** Client-perspective royalty earnings summary at Statement Header level, in Client Originating Office currency, with office, Client, Deal, source hierarchy, income, period, transaction, A&R, and Cross-to Client context.
- **Clave candidata:** Composite of all grouping attributes. Source Statement Header business key is processing_office_id + statement_header_id.
- **Columnas:** `orig_office_id`, `currency_cd`, `office_nm`, `signing_office_nm`, `client_id`, `client_name`, `deal_id`, `deal_nm`, `client_type_nm`, `entity_group_nm`, `statement_header_id`, `source_name`, `sub_source_name`, `sub_sub_source_name`, `original_processing_office_name`, `income_group`, `fiscal_period_tx`, `calendar_year_tx`, `accounting_period_dt`, `semiannual_statement_date`, `statement_period_dt`, `is_streaming_ind`, `current_ar_rep_nm`, `transaction_category`, `on_hold_ind`, `fiscal_year_signed`, `ctc_id`, `ctc_name`, `aka_names`, `income_type_group_nm`, `income_type_nm`, `company_group`, `royalty_processed_am`, `royalty_expense_am`, `nps_am`

### `dp_summarised_el.client_financials_v` (View) — Client Financials
- **Grano:** One row per calculated Client royalty receipt displayed in the Tempo Client Financials screen for a given Statement Period, with as much Source and Sub Source detail as is available within Tempo and including Song-level royalties.
- **Qué es:** Operational view reproducing the Tempo Client Financials tab from post-calculation pre-aggregated Earnings Lines, enriched with Client, Company, Contract, Subcontract, Song, Source, Income, Rate and Transaction context.
- **Clave candidata:** Composite of all non-measure grouping attributes
- **Columnas:** `orig_office_id`, `orig_office_nm`, `client_id`, `client_nm`, `client_type_nm`, `company_cd`, `company_nm`, `company_group_nm`, `orig_office_client_id`, `orig_office_client_nm`, `orig_office_company_cd`, `orig_office_company_nm`, `primary_client_id`, `primary_client_nm`, `contract_id`, `contract_nm`, `subcontract_id`, `subcontract_nm`, `song_id`, `song_sequence_id`, `song_title`, `affiliate_income_ind`, `source_id`, `source_nm`, `source_country_cd`, `sub_source_id`, `sub_source_nm`, `sub_source_country_cd`, `sub_sub_source_id`, `sub_sub_source_nm`, `sub_sub_source_country_cd`, `orig_sub_sub_source_id`, `orig_sub_sub_source_nm`, `orig_sub_sub_source_country_cd`, `income_type_id`, `income_type_nm`, `income_type_group_nm`, `streaming_ind`, `statement_period_dt`, `client_rate_pc`, `rate_type_id`, `rate_type_nm`, `transaction_type_id`, `transaction_type_nm`, `currency_cd`, `gross_client_income_am`, `client_local_income_am`, `client_net_income_am`, `royalty_payable_am`, `calculated_withholding_tax_am`, `nps_am`, `foreign_nps_am`


## SA-011 — Currency & Exchange Rates  (`Quarter-end Tempo intercompany rates and month-end financial-reporting closing rates.`)

### `dp_summarised_el.tempo_ig_fx_rates` (View) — Tempo Intercompany FX Rates
- **Grano:** One row per Exchange Rate Period / Statement Period and Originating Office.
- **Qué es:** Quarter-end FX rates used by the Tempo Intercompany Royalty Process to convert Originating Office currency amounts into USD. Rates apply by Tempo Statement Period.
- **Clave candidata:** exchange_rate_period_dt + orig_office_id
- **Columnas:** `exchange_rate_period_dt`, `orig_office_id`, `currency_cd`, `exchange_rate_pc`

### `dp_summarised_el.tempo_monthly_exchange_rate_v` (View) — Monthly Financial Reporting FX Rates
- **Grano:** One row per Month-End Exchange Rate Period and Currency.
- **Qué es:** Treasury-provided month-end closing FX rates loaded monthly by Finance for Management Reporting and Month-End Close. Despite the name, these rates are not used by Tempo.
- **Clave candidata:** monthly_exchange_rate_perioddt + currency_cd
- **Columnas:** `monthly_exchange_rate_perioddt`, `currency_cd`, `exchange_rate_pc`, `update_id`, `update_dt`


## Relaciones documentadas

| Padre | Hijo | Clave padre | Clave hijo | Card. | Regla |
|---|---|---|---|---|---|
| song_v | song_alternate_titles_v | song_id + song_sequence_id | song_id + song_sequence_id | 1:M | Use alternate-title ID and country association when analyzing distinct alternate titles. |
| song_v | identifiers_isrc_v | song_id | tempo_song_id | 1:M | ISRC identifies a recording, not the underlying musical work. |
| song_v | identifiers_iswc_v | song_id | tempo_song_id | 1:M | Use preferred/conflict indicators where multiple ISWC records exist. |
| song_v | identifiers_swn_v | song_id | tempo_song_id | 1:M | Society Work Numbers are society-specific; retain Society context. |
| song_v | song_alerts_v | song_id + song_sequence_id | song_id + song_sequence_id | 1:M | The child grain may be Alert plus Attachment; confirm before counting alerts. |
| song_v | song_artist_release_info_v | song_id + song_sequence_id | song_id + song_sequence_id | 1:M | One child row represents one song_label_production_id; fields may be populated in different combinations. |
| song_production_v | song_episodes_v | production_id | production_id | 1:M | Production is sequence zero; Episode sequences are greater than zero. |
| song_v | tempo_song_production_reporting_gr_v | song_id + song_sequence_id | song_id + song_sequence_id | M:M via bridge | Reporting Groups are user-created filters; a Song can belong to multiple groups. |
| song_v | tempo_active_song_rate_client_v | song_id + song_sequence_id | song_id + song_sequence_id | 1:M | Allocation grain also includes payment option, office group, Client, Contract and Subcontract. |
| song_v | song_share_summary_mv | song_id + song_sequence_id | song_id + song_sequence_id | 1:M | Publishers are aggregated to prevent duplicate Writer contribution reporting. |
| song_v | song_share_detail_mv | song_id + song_sequence_id | song_id + song_sequence_id | 1:M | Respect the Publisher-level hierarchy grain to avoid duplicating Writer shares. |
| song_v | contract_territories | song_id + song_sequence_id | song_id + song_sequence_id | 1:M | Song-level territory overrides take precedence over Contract-level definitions. |
| cwr_details_v | cwr_details_message_v | song_id + song_cwr_details_id | song_id + song_cwr_details_id | 1:M | Join cwr_details_v to cwr_details_message_v using song_id + song_cwr_details_id on both objects. Although a CWR registration detail may have multiple acknowledg |
| cwr_recipient_name_v | cwr_details_v | recipient_cd | recipient_cd | 1:M | Recipient configuration supplies society and CWR-processing attributes. |
| song_v | cwr_society_work_number_v | song_id + song_sequence_id | song_id + song_sequence_id | 1:M | Retain Society Code and Work Number to identify the relationship. |
| client_v | client_contract_v | client_id | client_id | M:M via bridge | Do not assume a Client has only one Contract or a Contract has only one Client. |
| contract_v | client_contract_v | contract_id | contract_id | M:M via bridge | Use client_contract_v as the relationship bridge. |
| client_v | client_payee_v | client_id | client_id | M:M via bridge | Payment analysis must preserve both Client and Payee. |
| contract_v | sub_contracts_v | contract_id | contract_id | 1:M | Subcontract rates vary by period, office group, source group, and income type/group. |
| client_v | client_song_v | client_id | client_id | 1:M | Use active_ind to distinguish active and inactive assignments. |
| contract_v | contract_song_v | contract_id | contract_id | 1:M | Use active_ind to distinguish active and inactive assignments. |
| client_v | client_song_production_v | client_id | client_id | 1:M | Production assignments can be inherited by Episodes when an Episode-specific assignment is absent. |
| contract_v | contract_song_production_v | contract_id | contract_id | 1:M | Production assignments can be inherited by Episodes when an Episode-specific assignment is absent. |
| client_v | client_song_episodic_production_v | client_id | client_id | 1:M | Episode-specific assignment takes precedence; otherwise inherit the sequence-zero Production assignment. |
| contract_v | contract_song_episodic_production_v | contract_id | contract_id | 1:M | Episode-specific assignment takes precedence; otherwise inherit the sequence-zero Production assignment. |
| client_v | cross_client_song_v | cross_to_client_id | cross_client_id | 1:M | Cross-To Client is the royalty-settlement rollup determining ultimate payable position. |
| client_v | cross_client_song_production_v | cross_to_client_id | cross_client_id | 1:M | Use for royalty-settlement reporting, not internal P&L reporting. |
| client_v | cross_client_song_episodic_production_v | cross_to_client_id | cross_client_id | 1:M | Episode inheritance logic applies where no Episode-specific assignment exists. |
| client_v | pnl_client_song_v | pnl_grouping_client_id | pnl_grouping_client_id | 1:M | This rollup supports internal deal-financial reporting and does not affect Client Statements. |
| client_v | pnl_client_song_production_v | pnl_grouping_client_id | pnl_grouping_client_id | 1:M | Use for advances, recoupment, write-offs, and financial analysis. |
| client_v | pnl_client_song_episodic_production_v | pnl_grouping_client_id | pnl_grouping_client_id | 1:M | Episode inheritance logic applies; this remains an internal reporting rollup. |
| client_v + contract_v | client_contract_song_v | client_id + contract_id | client_id + contract_id | 1:M | Preserve both Client and Contract when reporting assignments. |
| client_v + contract_v | client_contract_song_production_v | client_id + contract_id | client_id + contract_id | 1:M | Preserve Client, Contract, and Production grain. |
| client_v + contract_v | client_contract_song_episodic_production_v | client_id + contract_id | client_id + contract_id | 1:M | Episode-specific assignment overrides inherited Production assignment. |
| client_v | client_accounting_balances_v | client_id | client_id | 1:M | Use at Client plus Accounting Period grain; avoid duplication when joining lower-grain facts. |
| client_v | client_statement_balances_v | client_id | client_id | 1:M | Preserve Client, Payee, Statement Period, and Run Group grain. |
| client_payee_v | client_statement_balances_v | client_id + payee_id | client_id + payee_id | 1:M | Payment Hold applies to the associated Payee relationship. |
| client_v | capitalized_trial_balance_v | pnl_grouping_client_id | pnl_client_id | 1:M | Use P&L Grouping Client for internal advance, reserve, recovery, and recoupment reporting. |
| source_v | statement_headers_v | source_id | source_id | 1:M | Source configuration can influence loading, matching, identifier handling, and recoupment. |
| statement_headers_v | statement_lines_v | statement_header_id + processing_office_id | statement_header_id + processing_office_id | 1:M | Header status and Line status represent different workflow levels. |
| source_match_records_v | statement_lines_v | source_stmt_match_file_seq_id | match_file_id | 1:M / candidate | Confirm exact match-file cardinality before treating the relationship as a physical constraint. |
| statement_headers_v | master_crj_v | statement_header_id | statement_header_id | M:M / association | Only physically received cash is recorded; do not assume a simple one-to-one relationship. |
| master_crj_v | statement_headers_v | crj_association_id | statement_header_id | M:M / association | CRJ lines drive accounting entries and may allocate cash across statements. |
| statement_lines_v | earnings_lines_v | statement_header_id + processing_office_id + statement_line_id | statement_header_id + processing_office_id + statement_line_id | 1:M | Use all three join fields; Statement Lines are raw source data while Earnings Lines contain royalty calculations. |
| earnings_lines_v | originating_office_earnings_lines_v | earnings_line_id | earnings_line_id | 1:M / perspective | EL is processing-office perspective; OOEL is Client/deal-office perspective after intercompany processing. |
| client_v | earnings_lines_v | client_id | client_id | 1:M | Participant Rate Type 4 has special reporting treatment and must not add revenue independently. |
| contract_v | earnings_lines_v | contract_id | contract_id | 1:M | Rates and collectable percentages are inherited from applicable Contract/Subcontract setup. |
| sub_contracts_v | earnings_lines_v | contract_id + subcontract_id | contract_id + subcontract_id | 1:M | Rate selection also depends on period, source group, office group, and income context. |
| song_v | earnings_lines_v | song_id + song_sequence_id | song_id + song_sequence_id | 1:M | One source royalty can allocate across multiple Client/Contract interests. |
| earnings_lines_v | earnings_lines_v | earnings_line_id | primary_earnings_line_id | 1:M / self-reference candidate | Do not assume the relationship is exclusive to Participant processing. |
| primary client song interest | participant earnings line | Primary Client Song share | participant_link_ind + rate_type_id=4 | 1:M | Participant Clients inherit share/rate economics and carry Royalty Payable only. |
| song_v | sync_licensing_v | song_id + song_sequence_id | song_no + underlying song sequence | 1:M | sync_licensing_v is sourced only from the Tempo Sync Licensing module. |
| sync_licensing_v | sync_licensing_v | license_no | primary_license_no | 1:M / self-reference candidate | Do not assume parent-child semantics until validated. |
| sync_licensing_v | Sync Rights Type | license_no | sync_license_id | M:M via association | rights_requested is LISTAGG display text and should not be treated as a single atomic value. |
| sync_licensing_v | License Territory / Country | license_no | sync_license_id | M:M via association | license_territories is display-oriented text combining inclusions and exclusions. |
| sync_licensing_v | License Contact | license_no | sync_license_id | 1:M by contact role | The roles can point to different companies; contact_id in the view is coalesced and can obscure role-level detail. |
| Sync License Type | sync_licensing_v | license_type_id | license_type | 1:M | Only License Types where sync_ind=Y are valid in the Sync Licensing module. |
| Sync Deal Status | sync_licensing_v | deal_status_id | deal_status | 1:M | Use the approved nine-value status domain for workflow reporting. |
| writer_data_v | writer_aka_data_v | writer_id | writer_id | 1:M | Each alias belongs to one Writer and is classified by AKA Type. Validated AKA Types include Professional, Translated, Romanized, Matching, Statement, Alternate, |
| publisher_v | publisher_v | publisher_id | administering_samp_pub_id | 1:M / self-reference candidate | Use administering_samp_pub_id on the represented Publisher row to identify the administering SMP Publisher. Direction, optionality, and hierarchy behavior remai |
| Third-Party Publisher Domain | publisher_v | third_party_publisher_id | third_party_publisher_id | 1:M candidate | The source system, key domain, business purpose, and cardinality require validation. |
| Tempo Contact | publisher_v | contact_id | contact_id | 1:M candidate | The Contact role, optionality, and expected cardinality require validation. |
| edw.tempo_society | publisher_v | society_cd | mechanical_society_cd | 1:M | The relationship is optional in publisher_v because the Society lookup uses a LEFT JOIN. A populated code without a matching Society row produces a null Society |
| edw.tempo_society | publisher_v | society_cd | performance_society_cd | 1:M | The relationship is optional in publisher_v because the Society lookup uses a LEFT JOIN. |
| edw.tempo_society | publisher_v | society_cd | sync_society_cd | 1:M | The relationship is optional because the lookup uses a LEFT JOIN. The precise operational meaning of Sync Society remains subject to business-definition review. |
| edw.tempo_society | publisher_v | society_cd | online_mechanical_society_cd | 1:M | The relationship is optional in publisher_v because the Society lookup uses a LEFT JOIN. |
| edw.tempo_society | publisher_v | society_cd | online_performance_society_cd | 1:M | The relationship is optional in publisher_v because the Society lookup uses a LEFT JOIN. |
| edw.tempo_society | publisher_v | society_cd | spain_society_1_cd | 1:M | The view casts both join keys to text. Business precedence and meaning relative to Spain Society 2 remain open. |
| edw.tempo_society | publisher_v | society_cd | spain_society_2_cd | 1:M | The view casts both join keys to text. Business precedence and meaning relative to Spain Society 1 remain open. |
| edw.tempo_society | writer_data_v | society_cd | mechanical_society_cd (source) | 1:M | The supplied view uses an INNER JOIN, but the validated business rule states that Writers must not be excluded when a Society assignment is missing. The impleme |
| edw.tempo_society | writer_data_v | society_cd | performance_society_cd (source) | 1:M | The supplied view uses an INNER JOIN, but Writers without Society assignments must remain in scope. |
| edw.tempo_society | writer_data_v | society_cd | online_mechanical_society_cd (source) | 1:M | The supplied view uses an INNER JOIN, but Writers without Society assignments must remain in scope. |
| edw.tempo_society | writer_data_v | society_cd | online_performance_society_cd (source) | 1:M | The supplied view uses an INNER JOIN, but Writers without Society assignments must remain in scope. |
| edw.tempo_aka_type | writer_aka_data_v | aka_type_cd | aka_type_cd (source) | 1:M | Only aliases with a matching AKA Type are returned because writer_aka_data_v uses an INNER JOIN. The seven currently governed Tempo AKA Type values have been va |
| matched_charts_v | matched_quarterly_song_radio | chart_song_id | chart_song_id | 1:M | Retain quarter, upload, and country context. |
| matched_charts_v | matched_weekly_song_charts | chart_song_id | chart_song_id | 1:M | Retain chart type, chart name, geography, and week. |
| matched_charts_v | matched_weekly_song_streams | chart_song_id | chart_song_id | 1:M | Retain provider, tier, calculation model, and week. |
| matched_charts_v | matched_weekly_album_charts | chart_song_id | chart_song_id | 1:M candidate | Album track joins can expand album-week rows; exact cardinality requires validation. |
| Tempo Song | matched_charts_v | song_id | tempo_song_id | 1:M candidate | Recording and work are different entities; retain ISRC and chart-song ID. |
| Chart Upload Header | all chart fact views | chart_upload_header_id | chart_upload_header_id | 1:M | Use upload fields for ingestion audit and reconciliation. |
| Chart Album | matched_weekly_album_charts | chart_album_id | chart_album_id | 1:M | Primary album hierarchy and track cardinality require review. |
| mechanical_product_v | mechanical_product_song_v | mechanical_product_id | mechanical_product_id | 1:M | Product-level licensing information is maintained in the parent object while song-level rates, percentages, advances, matching indicators, and licensing attribu |
| Licensee Domain | mechanical_product_v | licensee_id | licensee_id | 1:M | Licensee information is resolved through a LEFT JOIN to tempo_licensee. A missing reference row does not remove the Mechanical Product from scope. |
| License Type Domain | mechanical_product_v | license_type_id | license_type_id | 1:M | License Type values are governed through the existing SA‑006 Licensing & Sync reference domain and should be interpreted consistently across licensing subject a |
| Originating Office Domain | mechanical_product_v | orig_office_id | orig_office_id | 1:M | Originating Office identifies the office responsible for administration of the Mechanical Product and is resolved through a LEFT JOIN to tempo_orig_office. |
| Tempo Song | mechanical_product_song_v | song_id + song_sequence_id | song_id + song_sequence_id | 1:M | Song enrichment is performed by joining song_id and song_sequence_id where prior_version_ind = 'N'. A song may appear on multiple products and may potentially a |
| Licensing Rate Type Domain | mechanical_product_song_v | licensing_rate_type_id | licensing_rate_type_id | 1:M | Licensing Rate Type drives interpretation of the base rate, reduction rate, controlled rate, and collectable rate. The governed domain values remain subject to  |
| mechanical_product_v | Licensee Domain | licensee_id | licensee_id | M:1 | Product-level reporting by customer, label partner, or licensing relationship should use Licensee Name from the resolved lookup domain rather than relying solel |
| mechanical_product_song_v | mechanical_product_v | mechanical_product_id | mechanical_product_id | M:1 | Mechanical Product Song records inherit product-level release, artist, licensee, and licensing information through the parent relationship. Product-song records |
| tempo_client | client_earnings_summary_by_song_mv | client_id | client_id | 1:M | INNER JOIN; current Client only (prior_version_ind=N). |
| tempo_song | client_earnings_summary_by_song_mv | song_id + song_sequence_id | song_id + hidden song_sequence_id | 1:M | INNER JOIN; current Song only. song_sequence_id participates in join but is not exposed. |
| tempo_income_type | client_earnings_summary_by_song_mv | income_type_id | sl_income_type_id | 1:M | INNER JOIN; missing reference suppresses source Earnings Lines. |
| tempo_orig_office | client_earnings_summary_by_song_mv | orig_office_id | processing_office_id | 1:M | Amounts are reported in the Client Originating Office currency. |
| monthend_rate_analysis_song_hist_mv | client_earnings_summary_by_song_mv | Historical summary grain | Aligned output columns | 1:M / UNION | Mutually exclusive populations; UNION ALL is deliberate. |
| tempo_statement_header | client_earnings_summary_by_statement_header_mv | processing_office_id + statement_header_id | processing_office_id (hidden) + statement_header_id | 1:M | Statement Header key is composite and can produce many summary rows. |
| tempo_client | client_earnings_summary_by_statement_header_mv | client_id | client_id | 1:M | Current Client enriches many summary rows. |
| tempo_income_type | client_earnings_summary_by_statement_header_mv | income_type_id | sl_income_type_id | 1:M | Income Type supplies name, group, and Streaming classification. |
| monthend_rate_analysis_statement_header_hist_mv | client_earnings_summary_by_statement_header_mv | Aligned historical grain | Aligned outputs | 1:M | Mutually exclusive historical rows appended with UNION ALL. |
| client_earnings_summary_by_song_mv | client_earnings_summary_by_statement_header_mv | Common dimensions | Common dimensions | Reconciliation | Financial measures reconcile exactly at common grain. |
| edw.tempo_song_stmnt_orig_sub_sub_summ | dp_summarised_el.client_financials_v | Composite summarized receipt attributes | Composite summarized receipt attributes | 1:M | Client Financials does not aggregate raw Earnings Lines directly. It consumes the Tempo Earnings Line Summarization layer to provide faster operational access.  |
| edw.tempo_client (Client) | dp_summarised_el.client_financials_v | client_id | client_id | 1:M | Client Financials is presented from the Client perspective. Descriptive Client attributes come from the current Client record only (prior_version_ind = 'N'). Mo |
| edw.tempo_client (Originating Office Client) | dp_summarised_el.client_financials_v | client_id | orig_office_client_id | 1:M | The Originating Office Client can differ from the general Client or Primary Client identifiers exposed by the view. The current Client version is selected (prio |
| edw.tempo_client (Primary Client) | dp_summarised_el.client_financials_v | client_id | primary_client_id | 1:M | Primary Client is a reporting and administration context and should not automatically replace the Client or Originating Office Client in calculations. The view  |
| edw.tempo_orig_office | dp_summarised_el.client_financials_v | orig_office_id | orig_office_id | 1:M | The Client Originating Office determines the currency context for all monetary amounts in Client Financials. Users must include currency_cd in aggregations and  |
| edw.tempo_contract | dp_summarised_el.client_financials_v | orig_office_id + contract_id | orig_office_id + contract_id | 1:M | Contract is office-scoped and is therefore joined using both Originating Office ID and Contract ID. Only the current Contract version (prior_version_ind = 'N')  |
| edw.tempo_subcontract | dp_summarised_el.client_financials_v | subcontract_id | subcontract_id | 1:M | Tempo can contain more than one current-version row for a Subcontract ID. The view resolves this by selecting the most recently updated current record using ROW |
| edw.tempo_song | dp_summarised_el.client_financials_v | song_id + song_sequence_id | song_id + song_sequence_id | 1:M | Song-level royalties are part of the validated business grain. The relationship uses Song ID plus Song Sequence ID and selects the current Song version (prior_v |
| edw.tempo_source (four hierarchy roles) | dp_summarised_el.client_financials_v | source_id | source_id; sub_source_id; sub_sub_source_id; orig_sub_sub_source_id | 1:M | The four Source roles are preserved separately and should not be treated as interchangeable. Lower hierarchy levels may be null where Tempo has no additional de |
| edw.tempo_source_country | dp_summarised_el.client_financials_v | source_id | source hierarchy IDs | 1:M resolved to one | For each Source ID, the view selects a single active Source Country. A record flagged primary is preferred; otherwise the most recently updated active country i |
| edw.tempo_income_type and edw.tempo_income_type_group | dp_summarised_el.client_financials_v | income_type_id | income_type_id | 1:M | Income Type is the more detailed classification and also supplies the Streaming Indicator. Income Type Group provides a governed lower-level grouping. Users sho |
| edw.tempo_rate_type | dp_summarised_el.client_financials_v | rate_type_id | rate_type_id | 1:M | Allowed values are At Source (1), Receipt (2), Limited Receipt (3), and Participant (4). Rate Type provides essential calculation context and should be retained |
| edw.tempo_transaction_type | dp_summarised_el.client_financials_v | transaction_type_id | transaction_type_id | 1:M | Transaction Type supplies processing context and can distinguish receipts with different business treatments even when Client, Song, Statement Period, and Sourc |
| edw.tempo_company and edw.tempo_company_group | dp_summarised_el.client_financials_v | company_cd / company_group_cd | company_cd | 1:M | Company and Company Group provide organizational context for royalty receipts and may be used to explain differences in processing treatment or reporting popula |
| Tempo Client module Financial tab | dp_summarised_el.client_financials_v | Equivalent UI filters and grouping | Equivalent view filters and grouping | Operational reconciliation | For equivalent Client, Statement Period, Song, Source hierarchy, Contract, Income Type, Rate Type, Transaction Type, and currency selections, the view is expect |
| song_v | tempo_active_song_rate_client_v | song_id | song_id | 1:M | A single Song may have multiple active Contract and Client associations. Additional rows can occur when different Clients participate in the same Contract or wh |
| contract_v | tempo_active_song_rate_client_v | contract_id | contract_id | 1:M | Multiple Clients may participate in the same Contract and therefore appear as separate rows within tempo_active_song_rate_client_v. Direct joins between Contrac |
| song_share_summary_mv | tempo_active_song_rate_client_v | song_id + associated_contract_id | song_id + contract_id | M:M | song_share_summary_mv is maintained at Song, Territory, Writer, and Associated Contract grain, while tempo_active_song_rate_client_v is maintained at Song, Clie |
| edw.tempo_orig_office | dp_summarised_el.tempo_ig_fx_rates | orig_office_id | orig_office_id | 1:M | One office may have many rates over time; office lookup supplies currency_cd. |
| edw.tempo_exchange_rate | dp_summarised_el.tempo_ig_fx_rates | exchange_rate_period_dt + orig_office_id | same | 1:1 expected | Consumers select by Statement Period and office; DISTINCT suppresses exact duplicates. |
| Currency Domain | dp_summarised_el.tempo_monthly_exchange_rate_v | currency_cd | currency_cd | 1:M | One approved rate is expected per currency and month-end period. |
| tempo_monthly_exchange_rate | dp_summarised_el.tempo_monthly_exchange_rate_v | monthly_exchange_rate_perioddt + currency_cd | same | 1:1 expected | Direct projection; source uniqueness and quality flow directly to the view. |
| dp_deal_financials.capitalized_trial_balance_v | dp_summarised_el.tempo_monthly_exchange_rate_v | currency_cd + capitalized_acctg_period_dt reporting month | currency_cd + monthly_exchange_rate_perioddt reporting month | M:1 | Join on currency_cd and the corresponding reporting month. Multiply capitalized_closing_balance_am by exchange_rate_pc to convert the local-currency balance to  |

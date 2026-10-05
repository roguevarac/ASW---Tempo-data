CREATE
OR REPLACE VIEW "dp_deal_financials"."capitalized_trial_balance_v" AS
SELECT
   ctb.pnl_client_id,
   tc.client_name AS pnl_client_nm,
   tc.commencement_date AS client_commencement_dt,
   too.orig_office_nm AS client_originating_office,
   tso.signing_office_nm AS client_signing_office,
   ctb.capitalized_acctg_period_dt,
   too.currency_cd,
   ctb.capitalized_opening_balance_am,
   ctb.payments_am,
   ctb.advance_am,
   ctb.other_charges_am,
   ctb.non_royalty_adjust_am,
   ctb.earnings_am,
   ctb.ft_earnings_am,
   ctb.earnings_on_hold_am,
   ctb.sessions_am,
   ctb.crossing_am,
   ctb.pre_cross_closing_bal_am,
   ctb.soft_cross_am,
   ctb.reserve_opening_balance_am,
   ctb.reserve_am,
   ctb.cumulative_reserve_am,
   ctb.reserve_closing_balance_am,
   ctb.recovery_am,
   ctb.cumulative_recovery_am,
   ctb.capitalized_closing_balance_am,
   ctb.gross_client_income_am,
   ctb.nps_am,
   tai.foreign_nps_am
FROM
   edw.tempo_capitalized_trial_balance ctb
   JOIN edw.tempo_client tc ON tc.client_id = ctb.pnl_client_id
   AND tc.prior_version_ind:: text = 'N':: text
   LEFT JOIN edw.tempo_signing_office tso ON tc.signing_office_id = tso.signing_office_id
   JOIN edw.tempo_orig_office too ON tc.orig_office_id = too.orig_office_id
   LEFT JOIN (
      SELECT
         tempo_acctg_it_earn_summ.client_id,
         tempo_acctg_it_earn_summ.accounting_period_dt,
         sum(tempo_acctg_it_earn_summ.foreign_nps_am) AS foreign_nps_am
      FROM
         edw.tempo_acctg_it_earn_summ
      GROUP BY
         tempo_acctg_it_earn_summ.client_id,
         tempo_acctg_it_earn_summ.accounting_period_dt
   ) tai ON tai.client_id = ctb.pnl_client_id
   AND tai.accounting_period_dt = ctb.capitalized_acctg_period_dt;

CREATE
OR REPLACE VIEW "dp_deal_financials"."client_accounting_balances_v" AS
SELECT
   tab.client_id,
   tc.client_name,
   tc.commencement_date AS client_commencement_dt,
   too.orig_office_nm AS client_originating_office,
   tso.signing_office_nm AS client_signing_office,
   tab.accounting_period_dt,
   tab.opening_balance_am,
   tab.payments_am,
   tab.advance_am,
   tab.other_charges_am,
   tab.non_royalty_adjust_am,
   tab.earnings_am,
   tab.ft_earnings_am,
   tab.earnings_on_hold_am,
   tab.sessions_am,
   tab.crossing_am,
   tab.pre_cross_closing_bal_am,
   tab.soft_cross_am,
   tab.closing_balance_am,
   tab.gross_client_income_am,
   tab.nps_am,
   tai.foreign_nps_am
FROM
   edw.tempo_accounting_balance tab
   LEFT JOIN edw.tempo_client tc ON tc.client_id = tab.client_id
   AND tc.prior_version_ind:: text = 'N':: text
   LEFT JOIN edw.tempo_signing_office tso ON tc.signing_office_id = tso.signing_office_id
   JOIN edw.tempo_orig_office too ON tc.orig_office_id = too.orig_office_id
   LEFT JOIN (
      SELECT
         tempo_acctg_it_earn_summ.client_id,
         tempo_acctg_it_earn_summ.accounting_period_dt,
         sum(tempo_acctg_it_earn_summ.foreign_nps_am) AS foreign_nps_am
      FROM
         edw.tempo_acctg_it_earn_summ
      GROUP BY
         tempo_acctg_it_earn_summ.client_id,
         tempo_acctg_it_earn_summ.accounting_period_dt
   ) tai ON tai.client_id = tab.client_id
   AND tai.accounting_period_dt = tab.accounting_period_dt;

CREATE
OR REPLACE VIEW "dp_deal_financials"."client_statement_balances_v" AS
SELECT
   tsb.client_id,
   tc.client_name,
   tc.commencement_date AS client_commencement_dt,
   too.orig_office_nm AS client_originating_office,
   tso.signing_office_nm AS client_signing_office,
   tsb.payee_id,
   tp.payee_name,
   tsb.payee_inactive_ind,
   tsb.payee_inactive_dt,
   tsb.statement_period_dt,
   tsb.stmnt_run_group_cd,
   tsrg.stmnt_run_group_nm,
   tsb.opening_balance_am,
   tsb.payments_am,
   tsb.advance_am,
   tsb.other_charges_am,
   tsb.non_royalty_adjust_am,
   tsb.domestic_earnings_am,
   tsb.foreign_earnings_am,
   tsb.ft_earnings_am,
   tsb.sessions_am,
   tsb.pre_cross_closing_bal_am,
   tsb.crossing_am,
   tsb.closing_balance_am,
   tsb.payable_balance_am,
   tsb.payment_hold_ind
FROM
   edw.tempo_statement_balance tsb
   LEFT JOIN edw.tempo_client tc ON tc.client_id = tsb.client_id
   AND tc.prior_version_ind:: text = 'N':: text
   LEFT JOIN edw.tempo_signing_office tso ON tc.signing_office_id = tso.signing_office_id
   JOIN edw.tempo_orig_office too ON tc.orig_office_id = too.orig_office_id
   LEFT JOIN edw.tempo_statement_run_group tsrg ON tsb.stmnt_run_group_cd:: text = tsrg.stmnt_run_group_cd:: text
   LEFT JOIN edw.tempo_payee tp ON tsb.payee_id = tp.payee_id
   AND tp.prior_version_ind:: text = 'N':: text;
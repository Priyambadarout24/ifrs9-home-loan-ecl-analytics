/* ============================================================================
   IFRS 9 PROJECT 2 — PHASE 4A: SQL — STAGING, LGD, CONSOLIDATED EXPORT
   Produces the tables SAS needs to compute PD (Markov chain), apply the
   macro overlay, and calculate ECL.
   ============================================================================ */

USE IFRS9_Project2;
GO

------------------------------------------------------------------------------
-- 1. LATEST OBSERVED STATUS PER LOAN (as of each loan's last reported month)
------------------------------------------------------------------------------
DROP TABLE IF EXISTS dbo.loan_current_status;
SELECT p.Loan_ID, p.MOB, p.Delinquency_Bucket, p.Days_Past_Due, p.NPA_Flag,
       p.Restructured_Flag, p.Outstanding_Balance
INTO dbo.loan_current_status
FROM dbo.monthly_loan_performance p
JOIN (
    SELECT Loan_ID, MAX(MOB) AS Max_MOB FROM dbo.monthly_loan_performance GROUP BY Loan_ID
) latest ON latest.Loan_ID = p.Loan_ID AND latest.Max_MOB = p.MOB;
GO

------------------------------------------------------------------------------
-- 2. IFRS9 STAGE ASSIGNMENT
--    Stage 3: Days_Past_Due>=90 (current status only)
--    Stage 2: not Stage 3, AND (DPD>=30 OR Restructured_Flag='Y')  -- SICR
--    Stage 1: everything else
--
--    NOTE ON NPA_Flag (important, caught during validation): NPA_Flag in
--    the source data is STICKY -- once set to 'Y' it never reverts to 'N',
--    even for loans that have since fully cured back to Current. 1,638
--    loans are currently in bucket A1.Current but still carry NPA_Flag='Y'
--    from a past episode. Using NPA_Flag as a Stage 3 trigger inflates
--    Stage 3 with loans that are no longer actually in default, and
--    produces the unrealistic result of Stage 3 > Stage 2. Stage
--    assignment must reflect CURRENT credit risk, so NPA_Flag is
--    deliberately excluded here in favor of current Days_Past_Due only.
------------------------------------------------------------------------------
DROP TABLE IF EXISTS dbo.ifrs9_stage_assignment;
SELECT
    Loan_ID, MOB, Delinquency_Bucket, Days_Past_Due, NPA_Flag, Restructured_Flag, Outstanding_Balance,
    CASE
        WHEN Days_Past_Due >= 90 THEN 'Stage 3'
        WHEN Days_Past_Due >= 30 OR Restructured_Flag = 'Y' THEN 'Stage 2'
        ELSE 'Stage 1'
    END AS IFRS9_Stage_Calculated
INTO dbo.ifrs9_stage_assignment
FROM dbo.loan_current_status;
GO

-- Quick stage distribution check
SELECT IFRS9_Stage_Calculated, COUNT(*) AS Loan_Count,
       CAST(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER () AS DECIMAL(5,2)) AS Pct_of_Portfolio
FROM dbo.ifrs9_stage_assignment GROUP BY IFRS9_Stage_Calculated;
GO

------------------------------------------------------------------------------
-- 3. CURRENT LTV & LGD BAND
--    Current_LTV = latest Outstanding_Balance / Market_Value (reflects
--    amortization — more realistic than static origination LTV).
------------------------------------------------------------------------------
DROP TABLE IF EXISTS dbo.loan_ltv_lgd;
SELECT
    d.Loan_ID,
    pc.Market_Value,
    cs.Outstanding_Balance,
    CAST(cs.Outstanding_Balance * 100.0 / pc.Market_Value AS DECIMAL(6,2)) AS Current_LTV_Pct,
    CASE
        WHEN cs.Outstanding_Balance * 100.0 / pc.Market_Value <= 60 THEN 15.00
        WHEN cs.Outstanding_Balance * 100.0 / pc.Market_Value <= 70 THEN 20.00
        WHEN cs.Outstanding_Balance * 100.0 / pc.Market_Value <= 80 THEN 28.00
        ELSE 35.00
    END AS LGD_Percent
INTO dbo.loan_ltv_lgd
FROM dbo.loan_disbursement d
JOIN dbo.property_collateral pc ON pc.Application_ID = d.Application_ID
JOIN dbo.loan_current_status cs ON cs.Loan_ID = d.Loan_ID;
GO

------------------------------------------------------------------------------
-- 4. REMAINING TENURE (needed for lifetime PD horizon on Stage 2/3 loans)
------------------------------------------------------------------------------
DROP TABLE IF EXISTS dbo.loan_remaining_tenure;
SELECT
    d.Loan_ID,
    u.Approved_Tenure_Months,
    cs.MOB AS Current_MOB,
    u.Approved_Tenure_Months - cs.MOB AS Remaining_Tenure_Months
INTO dbo.loan_remaining_tenure
FROM dbo.loan_disbursement d
JOIN dbo.underwriting_decision u ON u.Application_ID = d.Application_ID
JOIN dbo.loan_current_status cs ON cs.Loan_ID = d.Loan_ID;
GO

------------------------------------------------------------------------------
-- 5. CONSOLIDATED EXPORT — one row per loan, everything SAS needs
--    Current_State_Num maps bucket -> 1..5 for the Markov PD calculation.
------------------------------------------------------------------------------
DROP TABLE IF EXISTS dbo.ifrs9_staging_export;
SELECT
    sa.Loan_ID,
    sa.IFRS9_Stage_Calculated,
    sa.Delinquency_Bucket,
    CASE sa.Delinquency_Bucket
        WHEN 'A1.Current' THEN 1 WHEN 'A2.1-30 DPD' THEN 2 WHEN 'A3.31-60 DPD' THEN 3
        WHEN 'A4.61-90 DPD' THEN 4 WHEN 'A5.90+ DPD' THEN 5 END AS Current_State_Num,
    sa.Outstanding_Balance AS EAD,          -- amortizing home loan, no CCF needed
    ll.LGD_Percent,
    ll.Current_LTV_Pct,
    rt.Remaining_Tenure_Months
INTO dbo.ifrs9_staging_export
FROM dbo.ifrs9_stage_assignment sa
JOIN dbo.loan_ltv_lgd ll ON ll.Loan_ID = sa.Loan_ID
JOIN dbo.loan_remaining_tenure rt ON rt.Loan_ID = sa.Loan_ID;
GO

-- Validation: should be 19,659 rows, no NULLs in any computed column
SELECT COUNT(*) AS Total_Rows,
       SUM(CASE WHEN Current_State_Num IS NULL THEN 1 ELSE 0 END) AS Null_State,
       SUM(CASE WHEN LGD_Percent IS NULL THEN 1 ELSE 0 END) AS Null_LGD,
       SUM(CASE WHEN Remaining_Tenure_Months IS NULL OR Remaining_Tenure_Months <= 0 THEN 1 ELSE 0 END) AS Bad_Tenure
FROM dbo.ifrs9_staging_export;
GO

------------------------------------------------------------------------------
-- 6. EXPORT THE PHASE-2 ROLL-RATE MATRIX IN FIXED 5x5 ORDER FOR SAS IMPORT
--    (Run this, then export the result grid to CSV — e.g. right-click
--    results -> Save Results As -> roll_rate_matrix_export.csv)
------------------------------------------------------------------------------
SELECT
    Bucket_From,
    ISNULL([A1.Current], 0)   AS P_To_A1,
    ISNULL([A2.1-30 DPD], 0)  AS P_To_A2,
    ISNULL([A3.31-60 DPD], 0) AS P_To_A3,
    ISNULL([A4.61-90 DPD], 0) AS P_To_A4,
    ISNULL([A5.90+ DPD], 0)   AS P_To_A5
FROM (
    SELECT Bucket_From, Bucket_To, Transition_Pct / 100.0 AS Transition_Pct FROM dbo.roll_rate_matrix
) src
PIVOT (
    MAX(Transition_Pct) FOR Bucket_To IN
        ([A1.Current], [A2.1-30 DPD], [A3.31-60 DPD], [A4.61-90 DPD], [A5.90+ DPD])
) pvt
ORDER BY CASE Bucket_From
    WHEN 'A1.Current' THEN 1 WHEN 'A2.1-30 DPD' THEN 2 WHEN 'A3.31-60 DPD' THEN 3
    WHEN 'A4.61-90 DPD' THEN 4 WHEN 'A5.90+ DPD' THEN 5 END;
GO

/* ============================================================================
   NEXT: export dbo.ifrs9_staging_export and the roll-rate matrix query above
   to CSV, then move to Phase 4B (SAS): Markov-chain PD, macro overlay, ECL.
   ============================================================================ */

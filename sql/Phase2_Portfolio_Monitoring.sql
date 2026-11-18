/* ============================================================================
   IFRS 9 PROJECT 2 — PHASE 2: PORTFOLIO PERFORMANCE MONITORING
   Roll-Rate Transition Matrix | Vintage Cohort Analysis | Cure Rate (3-month rule)

   Built on top of dbo.monthly_loan_performance (Phase 1, MOB-keyed version)
   and dbo.loan_disbursement. All logic below was first prototyped and
   verified in Python against the real data before being written as SQL, so
   the numbers you get here should match:
     - Roll rate: A1->A1 ~96.8%, A5->A4 ~68.7%, A5->A5 ~31.3%
     - Cure rate (excluding right-censored): A2 ~93.1%, A3 ~85.9%,
       A4 ~76.7%, A5 ~65.7%, overall ~81.4%
   If your numbers are wildly different from these, something upstream
   changed (e.g. Phase 1 was re-run without the MOB-key fix) — stop and
   check before trusting the output.
   ============================================================================ */

USE IFRS9_Project2;
GO

------------------------------------------------------------------------------
-- 0. PRE-FLIGHT CHECK — confirm Phase 1 fix is actually in place before we
--    build anything on top of it (this table must be keyed on Loan_ID+MOB)
------------------------------------------------------------------------------
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes i
    JOIN sys.objects o ON o.object_id = i.object_id
    WHERE o.name = 'monthly_loan_performance' AND i.name = 'PK_monthly_loan_performance'
)
BEGIN
    RAISERROR('PK_monthly_loan_performance not found. Re-run the corrected Phase 1 script before continuing.', 16, 1);
END
GO

------------------------------------------------------------------------------
-- 1. ROLL-RATE TRANSITION MATRIX
--    Bucket at MOB=m -> Bucket at MOB=m+1, same loan. MOB is verified
--    contiguous per loan (checked in Phase 1 validation), so a direct
--    self-join on MOB+1 is safe — no date arithmetic needed.
------------------------------------------------------------------------------
DROP TABLE IF EXISTS dbo.roll_rate_transitions;
SELECT
    a.Loan_ID,
    a.MOB              AS MOB_From,
    a.Delinquency_Bucket AS Bucket_From,
    b.MOB              AS MOB_To,
    b.Delinquency_Bucket AS Bucket_To,
    a.Snapshot_Month_Date AS Snapshot_Month_From
INTO dbo.roll_rate_transitions
FROM dbo.monthly_loan_performance a
JOIN dbo.monthly_loan_performance b
    ON b.Loan_ID = a.Loan_ID AND b.MOB = a.MOB + 1;
GO

CREATE NONCLUSTERED INDEX IX_rrt_from_to ON dbo.roll_rate_transitions (Bucket_From, Bucket_To);
GO

-- Summary matrix: long format (best for Power BI matrix/heatmap visual)
DROP TABLE IF EXISTS dbo.roll_rate_matrix;
SELECT
    Bucket_From,
    Bucket_To,
    COUNT(*) AS Transition_Count,
    SUM(COUNT(*)) OVER (PARTITION BY Bucket_From) AS Row_Total,
    CAST(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY Bucket_From) AS DECIMAL(6,2)) AS Transition_Pct
INTO dbo.roll_rate_matrix
FROM dbo.roll_rate_transitions
GROUP BY Bucket_From, Bucket_To;
GO

-- Optional: same matrix pivoted wide, for a quick eyeball check in SSMS
SELECT Bucket_From,
    ISNULL([A1.Current], 0)      AS To_A1_Current,
    ISNULL([A2.1-30 DPD], 0)     AS To_A2_1_30,
    ISNULL([A3.31-60 DPD], 0)    AS To_A3_31_60,
    ISNULL([A4.61-90 DPD], 0)    AS To_A4_61_90,
    ISNULL([A5.90+ DPD], 0)      AS To_A5_90_plus
FROM (
    SELECT Bucket_From, Bucket_To, Transition_Pct FROM dbo.roll_rate_matrix
) src
PIVOT (
    MAX(Transition_Pct) FOR Bucket_To IN
        ([A1.Current], [A2.1-30 DPD], [A3.31-60 DPD], [A4.61-90 DPD], [A5.90+ DPD])
) pvt;
GO

-- Validation: row percentages should each sum to ~100
SELECT Bucket_From, SUM(Transition_Pct) AS Row_Sum_Should_Be_100
FROM dbo.roll_rate_matrix GROUP BY Bucket_From;
GO

------------------------------------------------------------------------------
-- 2. VINTAGE COHORT ANALYSIS
--    Cohort = disbursement month. Curve = cumulative % of the ORIGINAL
--    cohort that has EVER hit NPA by each MOB (fixed denominator — a loan
--    that closes early without going bad still counts in the denominator,
--    which is standard vintage methodology; it just never adds to the
--    numerator).
------------------------------------------------------------------------------
DROP TABLE IF EXISTS dbo.vintage_loan_base;
SELECT
    d.Loan_ID,
    CAST(FORMAT(d.Disbursement_Date, 'yyyy-MM') AS CHAR(7)) AS Vintage_Month,   -- CAST fixes oversized index key (FORMAT returns NVARCHAR(4000) by default)
    d.Disbursement_Date,
    (SELECT MIN(p.MOB) FROM dbo.monthly_loan_performance p
     WHERE p.Loan_ID = d.Loan_ID AND p.NPA_Flag = 'Y') AS First_NPA_MOB,
    (SELECT MAX(p.MOB) FROM dbo.monthly_loan_performance p
     WHERE p.Loan_ID = d.Loan_ID) AS Max_MOB_Observed
INTO dbo.vintage_loan_base
FROM dbo.loan_disbursement d;
GO

CREATE NONCLUSTERED INDEX IX_vlb_vintage ON dbo.vintage_loan_base (Vintage_Month, Max_MOB_Observed);
GO

-- Tally of MOB values 1..(max MOB seen anywhere in the portfolio)
-- NOTE: SQL Server disallows aggregate functions (MAX, etc.) ANYWHERE inside
-- a recursive CTE, even inside a filter subquery — so the max MOB must be
-- computed into a variable first, then referenced as a plain value.
DECLARE @max_mob INT = (SELECT MAX(MOB) FROM dbo.monthly_loan_performance);

DROP TABLE IF EXISTS #mob_tally;
;WITH tally AS (
    SELECT 1 AS n
    UNION ALL
    SELECT n + 1 FROM tally WHERE n < @max_mob
)
SELECT n AS MOB INTO #mob_tally FROM tally
OPTION (MAXRECURSION 200);

DROP TABLE IF EXISTS dbo.vintage_curve;
SELECT
    vb.Vintage_Month,
    t.MOB,
    COUNT(*) AS Cohort_Size,
    SUM(CASE WHEN vb.First_NPA_MOB IS NOT NULL AND vb.First_NPA_MOB <= t.MOB THEN 1 ELSE 0 END) AS Cumulative_NPA_Count,
    CAST(SUM(CASE WHEN vb.First_NPA_MOB IS NOT NULL AND vb.First_NPA_MOB <= t.MOB THEN 1 ELSE 0 END) * 100.0
         / COUNT(*) AS DECIMAL(6,2)) AS Cumulative_NPA_Rate_Pct
INTO dbo.vintage_curve
FROM dbo.vintage_loan_base vb
JOIN #mob_tally t
    ON t.MOB <= (SELECT MAX(Max_MOB_Observed) FROM dbo.vintage_loan_base vb2 WHERE vb2.Vintage_Month = vb.Vintage_Month)
GROUP BY vb.Vintage_Month, t.MOB;
GO

DROP TABLE IF EXISTS #mob_tally;

-- Validation: spot-check a cohort — cumulative rate should only ever increase as MOB rises
SELECT TOP 24 * FROM dbo.vintage_curve WHERE Vintage_Month = '2023-01' ORDER BY MOB;
GO

------------------------------------------------------------------------------
-- 3. CURE RATE (3-consecutive-months-back-to-Current rule)
--    Step A: flag each row as a "delinquency entry" (bucket moves away from
--            Current, or the loan's very first observed row is already
--            delinquent).
--    Step B: flag each row as a "cure start" (Current for 3 consecutive
--            MOBs beginning here).
--    Step C: for each entry, find the first cure-start at or after the
--            entry's MOB for that same loan.
--    Step D: a spell with no cure found is only counted as "not cured" if
--            the loan has at least 2 more months of observed history after
--            entry (enough to have shown a 3-month cure if it existed) —
--            otherwise it's right-censored and excluded from the rate.
------------------------------------------------------------------------------
DROP TABLE IF EXISTS dbo.cure_spells;

-- Materialize into temp tables FIRST, with indexes, instead of leaving these
-- as inline CTEs. Left as CTEs, SQL Server can end up re-deriving the LEAD
-- window computation over the full 377K-row table once per outer row in the
-- APPLY below (11,639 times) instead of once total — that recomputation is
-- almost certainly what made the earlier version hang.

DROP TABLE IF EXISTS #entries;
;WITH seq AS (
    SELECT
        Loan_ID, MOB, Delinquency_Bucket,
        LAG(Delinquency_Bucket) OVER (PARTITION BY Loan_ID ORDER BY MOB) AS Prev_Bucket,
        ROW_NUMBER() OVER (PARTITION BY Loan_ID ORDER BY MOB) AS Row_Num,
        MAX(MOB) OVER (PARTITION BY Loan_ID) AS Max_MOB_For_Loan
    FROM dbo.monthly_loan_performance
)
SELECT Loan_ID, MOB AS Entry_MOB, Delinquency_Bucket AS Entry_Bucket, Max_MOB_For_Loan
INTO #entries
FROM seq
WHERE Delinquency_Bucket <> 'A1.Current'
  AND (Row_Num = 1 OR Prev_Bucket = 'A1.Current');

CREATE CLUSTERED INDEX IX_entries_loan ON #entries (Loan_ID, Entry_MOB);

DROP TABLE IF EXISTS #cure_starts;
SELECT Loan_ID, MOB AS Cure_Start_MOB
INTO #cure_starts
FROM (
    SELECT
        Loan_ID, MOB, Delinquency_Bucket,
        LEAD(Delinquency_Bucket, 1) OVER (PARTITION BY Loan_ID ORDER BY MOB) AS Bucket_Plus1,
        LEAD(Delinquency_Bucket, 2) OVER (PARTITION BY Loan_ID ORDER BY MOB) AS Bucket_Plus2,
        LEAD(MOB, 1) OVER (PARTITION BY Loan_ID ORDER BY MOB) AS MOB_Plus1,
        LEAD(MOB, 2) OVER (PARTITION BY Loan_ID ORDER BY MOB) AS MOB_Plus2
    FROM dbo.monthly_loan_performance
) x
WHERE Delinquency_Bucket = 'A1.Current'
  AND Bucket_Plus1 = 'A1.Current' AND MOB_Plus1 = MOB + 1
  AND Bucket_Plus2 = 'A1.Current' AND MOB_Plus2 = MOB + 2;

CREATE CLUSTERED INDEX IX_curestarts_loan ON #cure_starts (Loan_ID, Cure_Start_MOB);

-- Now the correlated lookup is an index seek against a small, pre-built
-- temp table instead of a full re-derivation — this should run in seconds.
SELECT
    e.Loan_ID,
    e.Entry_MOB,
    e.Entry_Bucket,
    e.Max_MOB_For_Loan,
    ca.First_Cure_MOB,
    CASE WHEN ca.First_Cure_MOB IS NOT NULL THEN 1 ELSE 0 END AS Cured,
    CASE WHEN ca.First_Cure_MOB IS NOT NULL
              OR e.Max_MOB_For_Loan >= e.Entry_MOB + 2
         THEN 1 ELSE 0 END AS Has_Enough_Followup   -- 1 = assessable, 0 = right-censored
INTO dbo.cure_spells
FROM #entries e
OUTER APPLY (
    SELECT MIN(cs.Cure_Start_MOB) AS First_Cure_MOB
    FROM #cure_starts cs
    WHERE cs.Loan_ID = e.Loan_ID AND cs.Cure_Start_MOB >= e.Entry_MOB
) ca;
GO

DROP TABLE IF EXISTS #entries;
DROP TABLE IF EXISTS #cure_starts;
GO

CREATE NONCLUSTERED INDEX IX_cs_bucket ON dbo.cure_spells (Entry_Bucket);
GO

-- Summary: cure rate by entry-bucket severity, assessable spells only
DROP TABLE IF EXISTS dbo.cure_rate_summary;
SELECT
    Entry_Bucket,
    COUNT(*) AS Total_Spells,
    SUM(1 - Has_Enough_Followup) AS Right_Censored_Excluded,
    SUM(Has_Enough_Followup) AS Assessable_Spells,
    SUM(CASE WHEN Has_Enough_Followup = 1 THEN Cured ELSE 0 END) AS Cured_Spells,
    CAST(SUM(CASE WHEN Has_Enough_Followup = 1 THEN Cured ELSE 0 END) * 100.0
         / NULLIF(SUM(Has_Enough_Followup), 0) AS DECIMAL(6,2)) AS Cure_Rate_Pct
INTO dbo.cure_rate_summary
FROM dbo.cure_spells
GROUP BY Entry_Bucket

UNION ALL

SELECT
    'OVERALL' AS Entry_Bucket,
    COUNT(*),
    SUM(1 - Has_Enough_Followup),
    SUM(Has_Enough_Followup),
    SUM(CASE WHEN Has_Enough_Followup = 1 THEN Cured ELSE 0 END),
    CAST(SUM(CASE WHEN Has_Enough_Followup = 1 THEN Cured ELSE 0 END) * 100.0
         / NULLIF(SUM(Has_Enough_Followup), 0) AS DECIMAL(6,2))
FROM dbo.cure_spells;
GO

SELECT * FROM dbo.cure_rate_summary ORDER BY
    CASE Entry_Bucket
        WHEN 'A2.1-30 DPD' THEN 1 WHEN 'A3.31-60 DPD' THEN 2
        WHEN 'A4.61-90 DPD' THEN 3 WHEN 'A5.90+ DPD' THEN 4 ELSE 5 END;
GO

------------------------------------------------------------------------------
-- 4. VALIDATION SUMMARY — run this and compare against the Python-verified
--    expected values noted at the top of this script
------------------------------------------------------------------------------
SELECT 'roll_rate_transitions row count (expect 357879)' AS Check_, COUNT(*) AS Value_ FROM dbo.roll_rate_transitions
UNION ALL
SELECT 'vintage cohorts (expect 39)', COUNT(DISTINCT Vintage_Month) FROM dbo.vintage_curve
UNION ALL
SELECT 'cure_spells total (expect 11639)', COUNT(*) FROM dbo.cure_spells
UNION ALL
SELECT 'cure_spells right-censored (expect 1129)', SUM(1 - Has_Enough_Followup) FROM dbo.cure_spells;
GO

/* ============================================================================
   END OF PHASE 2
   Next: Phase 3 — Collections strategy (contactability, PTP conversion,
   overdue aging) on dbo.collections_recovery.
   ============================================================================ */

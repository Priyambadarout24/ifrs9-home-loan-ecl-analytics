/* ============================================================================
   IFRS 9 PROJECT 2 — PHASE 3: COLLECTIONS STRATEGY
   Contactability | PTP Conversion & Recovery Ratio | Efficiency by Priority Band

   Built on dbo.collections_recovery (29,631 records). All logic below was
   first checked against the real data in Python before being written as SQL.

   IMPORTANT DATA FINDING (verified, not a bug — call this out in your
   documentation): Collection_Status is fully determined by
   Promise_To_Pay_Flag: every 'Escalated' record has PTP_Flag='N', and every
   'Resolved'/'In Progress' record has PTP_Flag='Y' (split by how much of
   the promise was recovered). PTP conversion and resolution rates are also
   close to flat (~44-46%) across channel, delinquency bucket, and priority
   score in this data. The one metric that DOES show a real, useful signal
   is the recovery ratio (Payment_Received_After_Action / PTP_Amount):
   'Resolved' cases average ~77% of the promised amount recovered vs ~37%
   for 'In Progress' cases. This script builds all the standard collections
   KPIs faithfully, but the recovery ratio is the one to lead with when you
   write this up — it's the metric that actually differentiates outcomes.

   Expected validation values (verified in Python before writing this SQL):
     - Overall PTP conversion rate: 44.95%
     - Escalated / In Progress / Resolved split: 55.05% / 30.95% / 14.01%
     - Overall recovery ratio (total recovered / total promised): 49.82%
     - Total PTP amount promised: 1,004,826,997.52
     - Total recovered: 500,621,171.97
   ============================================================================ */

USE IFRS9_Project2;
GO

------------------------------------------------------------------------------
-- 0. PRE-FLIGHT CHECK
------------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'collections_recovery')
BEGIN
    RAISERROR('dbo.collections_recovery not found. Re-run Phase 1 before continuing.', 16, 1);
END
GO

------------------------------------------------------------------------------
-- 1. CONTACT VOLUME & MIX
--    Descriptive view of collection effort intensity — total and average
--    contacts per channel, overall and by delinquency severity.
------------------------------------------------------------------------------
DROP TABLE IF EXISTS dbo.collections_contact_summary;
SELECT
    Delinquency_Bucket,
    COUNT(*) AS Case_Count,
    SUM(SMS_Count) AS Total_SMS, AVG(CAST(SMS_Count AS DECIMAL(6,2))) AS Avg_SMS_Per_Case,
    SUM(Call_Count) AS Total_Calls, AVG(CAST(Call_Count AS DECIMAL(6,2))) AS Avg_Calls_Per_Case,
    SUM(WhatsApp_Count) AS Total_WhatsApp, AVG(CAST(WhatsApp_Count AS DECIMAL(6,2))) AS Avg_WhatsApp_Per_Case,
    SUM(Field_Visit_Count) AS Total_Field_Visits, AVG(CAST(Field_Visit_Count AS DECIMAL(6,2))) AS Avg_Field_Visits_Per_Case
INTO dbo.collections_contact_summary
FROM dbo.collections_recovery
GROUP BY Delinquency_Bucket;
GO

-- Portfolio-wide totals (one row, for a dashboard KPI card)
SELECT
    COUNT(*) AS Total_Collection_Cases,
    SUM(SMS_Count) AS Total_SMS,
    SUM(Call_Count) AS Total_Calls,
    SUM(WhatsApp_Count) AS Total_WhatsApp,
    SUM(Field_Visit_Count) AS Total_Field_Visits
FROM dbo.collections_recovery;
GO

------------------------------------------------------------------------------
-- 2. PTP PERFORMANCE — conversion rate + recovery ratio (detail + summary)
------------------------------------------------------------------------------
DROP TABLE IF EXISTS dbo.ptp_performance_detail;
SELECT
    Collection_ID,
    Loan_ID,
    Delinquency_Bucket,
    Priority_Score,
    Promise_To_Pay_Flag,
    PTP_Amount,
    Payment_Received_After_Action,
    Collection_Status,
    CASE WHEN Promise_To_Pay_Flag = 'Y' AND PTP_Amount > 0
         THEN CAST(Payment_Received_After_Action * 100.0 / PTP_Amount AS DECIMAL(6,2))
         ELSE NULL END AS Recovery_Ratio_Pct   -- % of the promised amount actually recovered
INTO dbo.ptp_performance_detail
FROM dbo.collections_recovery;
GO

CREATE NONCLUSTERED INDEX IX_ptp_bucket ON dbo.ptp_performance_detail (Delinquency_Bucket, Collection_Status);
GO

-- Summary: PTP conversion rate + average recovery ratio, by bucket
DROP TABLE IF EXISTS dbo.ptp_performance_summary;
SELECT
    Delinquency_Bucket,
    COUNT(*) AS Total_Cases,
    SUM(CASE WHEN Promise_To_Pay_Flag = 'Y' THEN 1 ELSE 0 END) AS PTP_Made_Count,
    CAST(SUM(CASE WHEN Promise_To_Pay_Flag = 'Y' THEN 1 ELSE 0 END) * 100.0
         / COUNT(*) AS DECIMAL(6,2)) AS PTP_Conversion_Rate_Pct,
    SUM(PTP_Amount) AS Total_PTP_Amount_Promised,
    SUM(Payment_Received_After_Action) AS Total_Amount_Recovered,
    CAST(SUM(Payment_Received_After_Action) * 100.0
         / NULLIF(SUM(PTP_Amount), 0) AS DECIMAL(6,2)) AS Overall_Recovery_Ratio_Pct
INTO dbo.ptp_performance_summary
FROM dbo.collections_recovery
GROUP BY Delinquency_Bucket

UNION ALL

SELECT
    'OVERALL',
    COUNT(*),
    SUM(CASE WHEN Promise_To_Pay_Flag = 'Y' THEN 1 ELSE 0 END),
    CAST(SUM(CASE WHEN Promise_To_Pay_Flag = 'Y' THEN 1 ELSE 0 END) * 100.0 / COUNT(*) AS DECIMAL(6,2)),
    SUM(PTP_Amount),
    SUM(Payment_Received_After_Action),
    CAST(SUM(Payment_Received_After_Action) * 100.0 / NULLIF(SUM(PTP_Amount), 0) AS DECIMAL(6,2))
FROM dbo.collections_recovery;
GO

-- Recovery ratio by Collection_Status — this is the metric with real signal
-- (Resolved cases recover a much higher % of what was promised than In Progress)
SELECT
    Collection_Status,
    COUNT(*) AS Case_Count,
    AVG(Recovery_Ratio_Pct) AS Avg_Recovery_Ratio_Pct,
    MIN(Recovery_Ratio_Pct) AS Min_Recovery_Ratio_Pct,
    MAX(Recovery_Ratio_Pct) AS Max_Recovery_Ratio_Pct
FROM dbo.ptp_performance_detail
WHERE Recovery_Ratio_Pct IS NOT NULL
GROUP BY Collection_Status;
GO

------------------------------------------------------------------------------
-- 3. COLLECTION EFFICIENCY BY PRIORITY BAND
--    Priority_Score ranges 1-100 in the source data; banded into
--    Low/Medium/High for a cleaner Power BI slicer/segment view.
------------------------------------------------------------------------------
DROP TABLE IF EXISTS dbo.collection_efficiency_by_priority;
SELECT
    CASE
        WHEN Priority_Score <= 40 THEN 'Low (1-40)'
        WHEN Priority_Score <= 70 THEN 'Medium (41-70)'
        ELSE 'High (71-100)'
    END AS Priority_Band,
    COUNT(*) AS Case_Count,
    CAST(SUM(CASE WHEN Promise_To_Pay_Flag = 'Y' THEN 1 ELSE 0 END) * 100.0
         / COUNT(*) AS DECIMAL(6,2)) AS PTP_Conversion_Rate_Pct,
    CAST(SUM(CASE WHEN Collection_Status = 'Resolved' THEN 1 ELSE 0 END) * 100.0
         / COUNT(*) AS DECIMAL(6,2)) AS Resolution_Rate_Pct,
    SUM(PTP_Amount) AS Total_PTP_Amount_Promised,
    SUM(Payment_Received_After_Action) AS Total_Amount_Recovered,
    CAST(SUM(Payment_Received_After_Action) * 100.0
         / NULLIF(SUM(PTP_Amount), 0) AS DECIMAL(6,2)) AS Overall_Recovery_Ratio_Pct
INTO dbo.collection_efficiency_by_priority
FROM dbo.collections_recovery
GROUP BY
    CASE
        WHEN Priority_Score <= 40 THEN 'Low (1-40)'
        WHEN Priority_Score <= 70 THEN 'Medium (41-70)'
        ELSE 'High (71-100)'
    END;
GO

SELECT * FROM dbo.collection_efficiency_by_priority
ORDER BY CASE Priority_Band WHEN 'Low (1-40)' THEN 1 WHEN 'Medium (41-70)' THEN 2 ELSE 3 END;
GO

------------------------------------------------------------------------------
-- 4. VALIDATION SUMMARY — compare against the Python-verified expected
--    values noted at the top of this script
------------------------------------------------------------------------------
SELECT
    'Overall PTP conversion rate % (expect 44.95)' AS Check_,
    CAST(SUM(CASE WHEN Promise_To_Pay_Flag = 'Y' THEN 1 ELSE 0 END) * 100.0 / COUNT(*) AS DECIMAL(6,2)) AS Value_
FROM dbo.collections_recovery
UNION ALL
SELECT 'Escalated rate % (expect 55.05)',
    CAST(SUM(CASE WHEN Collection_Status = 'Escalated' THEN 1 ELSE 0 END) * 100.0 / COUNT(*) AS DECIMAL(6,2))
FROM dbo.collections_recovery
UNION ALL
SELECT 'Resolved rate % (expect 14.01)',
    CAST(SUM(CASE WHEN Collection_Status = 'Resolved' THEN 1 ELSE 0 END) * 100.0 / COUNT(*) AS DECIMAL(6,2))
FROM dbo.collections_recovery
UNION ALL
SELECT 'Overall recovery ratio % (expect 49.82)',
    CAST(SUM(Payment_Received_After_Action) * 100.0 / SUM(PTP_Amount) AS DECIMAL(6,2))
FROM dbo.collections_recovery
UNION ALL
SELECT 'Total PTP amount promised (expect 1004826997.52)',
    CAST(SUM(PTP_Amount) AS DECIMAL(18,2))
FROM dbo.collections_recovery
UNION ALL
SELECT 'Total amount recovered (expect 500621171.97)',
    CAST(SUM(Payment_Received_After_Action) AS DECIMAL(18,2))
FROM dbo.collections_recovery;
GO

/* ============================================================================
   END OF PHASE 3
   You now have all three modules built: Phase 1 (data staging), Phase 2
   (portfolio monitoring: roll rate, vintage, cure rate), Phase 3 (collections:
   contactability, PTP conversion, recovery efficiency). Next: Phase 4 —
   IFRS 9 staging/PD/LGD/EAD build and ECL computation, validated against
   dbo.ifrs9_ecl_provisioning_actual.
   ============================================================================ */

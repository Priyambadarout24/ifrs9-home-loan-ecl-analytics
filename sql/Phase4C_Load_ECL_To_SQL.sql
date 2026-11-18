/* ============================================================================
   IFRS 9 PROJECT 2 — PHASE 4C: LOAD SAS ECL OUTPUT INTO SQL SERVER
   Brings ifrs9.loan_ecl_final and ifrs9.ecl_summary_by_stage (built in SAS)
   back into SQL Server, so Power BI can connect to ONE data source and
   still cross-filter ECL against branch/product/region from dbo tables.

   BEFORE RUNNING: export both SAS datasets to CSV (from SAS Studio: right-
   click the dataset in the library -> Export, or use PROC EXPORT), then
   update the file path below to wherever you saved them.
   ============================================================================ */

USE IFRS9_Project2;
GO

------------------------------------------------------------------------------
-- 1. STAGING TABLES (VARCHAR-only, same safe pattern as Phase 1)
------------------------------------------------------------------------------
DROP TABLE IF EXISTS staging.stg_loan_ecl_final;
CREATE TABLE staging.stg_loan_ecl_final (
    Loan_ID VARCHAR(20), IFRS9_Stage_Calculated VARCHAR(10), Delinquency_Bucket VARCHAR(20),
    Current_State_Num VARCHAR(5), EAD VARCHAR(30), LGD_Percent VARCHAR(20),
    Current_LTV_Pct VARCHAR(20), Remaining_Tenure_Months VARCHAR(10),
    Remaining_Tenure_Capped VARCHAR(10), PD_12M_Raw VARCHAR(20), PD_Lifetime_Raw VARCHAR(20),
    PD_Final VARCHAR(20), LGD_Decimal VARCHAR(20), Expected_Credit_Loss VARCHAR(30)
);

DROP TABLE IF EXISTS staging.stg_ecl_summary_by_stage;
CREATE TABLE staging.stg_ecl_summary_by_stage (
    IFRS9_Stage_Calculated VARCHAR(10), Loan_Count VARCHAR(10),
    Total_EAD VARCHAR(30), Total_ECL VARCHAR(30), Coverage_Ratio_Pct VARCHAR(20)
);
GO

------------------------------------------------------------------------------
-- 2. BULK INSERT — update this path to match where you saved the 2 CSVs
------------------------------------------------------------------------------
BULK INSERT staging.stg_loan_ecl_final
FROM 'C:\IFRS9_Project2\loan_ecl_final.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK, CODEPAGE = '65001');

BULK INSERT staging.stg_ecl_summary_by_stage
FROM 'C:\IFRS9_Project2\ecl_summary_by_stage.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK, CODEPAGE = '65001');
GO

------------------------------------------------------------------------------
-- 3. FINAL TYPED TABLES
------------------------------------------------------------------------------
DROP TABLE IF EXISTS dbo.loan_ecl_final;
CREATE TABLE dbo.loan_ecl_final (
    Loan_ID VARCHAR(20) PRIMARY KEY,
    IFRS9_Stage_Calculated VARCHAR(10),
    Delinquency_Bucket VARCHAR(20),
    Current_State_Num TINYINT,
    EAD DECIMAL(18,2),
    LGD_Percent DECIMAL(6,2),
    Current_LTV_Pct DECIMAL(6,2),
    Remaining_Tenure_Months INT,
    Remaining_Tenure_Capped INT,
    PD_12M_Raw DECIMAL(9,6),
    PD_Lifetime_Raw DECIMAL(9,6),
    PD_Final DECIMAL(9,6),
    LGD_Decimal DECIMAL(6,4),
    Expected_Credit_Loss DECIMAL(18,2)
);
INSERT INTO dbo.loan_ecl_final
SELECT
    Loan_ID, IFRS9_Stage_Calculated, Delinquency_Bucket,
    TRY_CAST(Current_State_Num AS TINYINT),
    TRY_CAST(EAD AS DECIMAL(18,2)),
    TRY_CAST(LGD_Percent AS DECIMAL(6,2)),
    TRY_CAST(Current_LTV_Pct AS DECIMAL(6,2)),
    TRY_CAST(Remaining_Tenure_Months AS INT),
    TRY_CAST(Remaining_Tenure_Capped AS INT),
    TRY_CAST(PD_12M_Raw AS DECIMAL(9,6)),
    TRY_CAST(PD_Lifetime_Raw AS DECIMAL(9,6)),
    TRY_CAST(PD_Final AS DECIMAL(9,6)),
    TRY_CAST(LGD_Decimal AS DECIMAL(6,4)),
    TRY_CAST(RTRIM(Expected_Credit_Loss, CHAR(13)) AS DECIMAL(18,2))
FROM staging.stg_loan_ecl_final;
GO

DROP TABLE IF EXISTS dbo.ecl_summary_by_stage;
CREATE TABLE dbo.ecl_summary_by_stage (
    IFRS9_Stage_Calculated VARCHAR(10) PRIMARY KEY,
    Loan_Count INT,
    Total_EAD DECIMAL(18,2),
    Total_ECL DECIMAL(18,2),
    Coverage_Ratio_Pct DECIMAL(6,2)
);
INSERT INTO dbo.ecl_summary_by_stage
SELECT
    IFRS9_Stage_Calculated, TRY_CAST(Loan_Count AS INT),
    TRY_CAST(Total_EAD AS DECIMAL(18,2)), TRY_CAST(Total_ECL AS DECIMAL(18,2)),
    TRY_CAST(RTRIM(Coverage_Ratio_Pct, CHAR(13)) AS DECIMAL(6,2))
FROM staging.stg_ecl_summary_by_stage;
GO

------------------------------------------------------------------------------
-- 4. VALIDATION — expect 19659 and 3
------------------------------------------------------------------------------
SELECT 'loan_ecl_final' AS TableName, COUNT(*) AS LoadedRows, 19659 AS ExpectedRows,
       CASE WHEN COUNT(*) = 19659 THEN 'OK' ELSE 'MISMATCH' END AS Match_ FROM dbo.loan_ecl_final
UNION ALL
SELECT 'ecl_summary_by_stage', COUNT(*), 3,
       CASE WHEN COUNT(*) = 3 THEN 'OK' ELSE 'MISMATCH' END FROM dbo.ecl_summary_by_stage;
GO

-- Spot check: should match your SAS output exactly
SELECT * FROM dbo.ecl_summary_by_stage;
GO

/* ============================================================================
   NEXT: connect Power BI to this SQL Server database. Every table you need
   now lives here: loan_ecl_final, ecl_summary_by_stage (Phase 4),
   roll_rate_matrix, vintage_curve, cure_rate_summary (Phase 2),
   ptp_performance_summary, collection_efficiency_by_priority (Phase 3),
   plus all the dimension tables from Phase 1 (branch_master, product_master,
   customer_master, loan_disbursement, etc.) for slicing.
   ============================================================================ */

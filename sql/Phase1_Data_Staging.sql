/* ============================================================================
   IFRS 9 ECL PROJECT 2 — PHASE 1: DATA STAGING & LOAD
   Retail Home Loan Lifecycle (Application -> Underwriting -> Disbursement ->
   Monthly Performance -> Collections -> IFRS9 Provisioning) + Macro Overlay

   PATTERN USED (same as Project 1):
   1) Load every raw file into a VARCHAR-only STAGING table via BULK INSERT
      (safest approach — nothing fails on format mismatches at load time)
   2) CAST/CONVERT from staging into a properly typed FINAL table in dbo
   3) Reconcile row counts staging vs final vs source file (validation block)

   BEFORE RUNNING:
   - Replace 'C:\IFRS9_Project2\' below with the actual folder path where you
     saved all 16 CSV files (SQL Server's engine account needs read access
     to that folder, not just your own Windows login).
   - Run this script top to bottom in one go, OR section by section if you
     prefer to check each table as we did in Project 1.
   ============================================================================ */

------------------------------------------------------------------------------
-- 0. DATABASE
------------------------------------------------------------------------------
IF DB_ID('IFRS9_Project2') IS NULL
BEGIN
    CREATE DATABASE IFRS9_Project2;
END
GO

USE IFRS9_Project2;
GO

------------------------------------------------------------------------------
-- 1. STAGING SCHEMA (all columns VARCHAR — raw, unvalidated load)
------------------------------------------------------------------------------
IF SCHEMA_ID('staging') IS NULL
    EXEC('CREATE SCHEMA staging');
GO

/* Drop staging tables if re-running */
DROP TABLE IF EXISTS staging.stg_customer_master;
DROP TABLE IF EXISTS staging.stg_loan_application;
DROP TABLE IF EXISTS staging.stg_income_employment;
DROP TABLE IF EXISTS staging.stg_property_collateral;
DROP TABLE IF EXISTS staging.stg_credit_bureau;
DROP TABLE IF EXISTS staging.stg_document_fraud;
DROP TABLE IF EXISTS staging.stg_underwriting_decision;
DROP TABLE IF EXISTS staging.stg_loan_disbursement;
DROP TABLE IF EXISTS staging.stg_payment_transactions;
DROP TABLE IF EXISTS staging.stg_monthly_loan_performance;
DROP TABLE IF EXISTS staging.stg_collections_recovery;
DROP TABLE IF EXISTS staging.stg_ifrs9_ecl_provisioning;
DROP TABLE IF EXISTS staging.stg_branch_master;
DROP TABLE IF EXISTS staging.stg_product_master;
DROP TABLE IF EXISTS staging.stg_macro_history;
DROP TABLE IF EXISTS staging.stg_macro_scenarios;
GO

CREATE TABLE staging.stg_customer_master (
    Customer_ID VARCHAR(20), Customer_Name VARCHAR(200), DOB VARCHAR(20), Age VARCHAR(10),
    Gender VARCHAR(20), Marital_Status VARCHAR(20), Education VARCHAR(30), City VARCHAR(50),
    [State] VARCHAR(50), Residence_Type VARCHAR(20), Years_at_Residence VARCHAR(20),
    Mobile_Verified VARCHAR(5), Email_Verified VARCHAR(5), KYC_Status VARCHAR(20)
);

CREATE TABLE staging.stg_loan_application (
    Application_ID VARCHAR(20), Customer_ID VARCHAR(20), Application_Date VARCHAR(20),
    Branch_ID VARCHAR(20), Channel VARCHAR(20), Loan_Purpose VARCHAR(30),
    Requested_Loan_Amount VARCHAR(30), Requested_Tenure_Months VARCHAR(10),
    Product_Type VARCHAR(30), Application_Status VARCHAR(20)
);

CREATE TABLE staging.stg_income_employment (
    Application_ID VARCHAR(20), Customer_ID VARCHAR(20), Employment_Type VARCHAR(30),
    Occupation VARCHAR(50), Employer_Category VARCHAR(20), Work_Experience_Years VARCHAR(20),
    Monthly_Gross_Income VARCHAR(30), Other_Monthly_Income VARCHAR(30), Existing_EMI VARCHAR(30),
    Declared_Monthly_Obligation VARCHAR(30), Debt_to_Income_Percent VARCHAR(20),
    Disposable_Income VARCHAR(30), Income_Stability_Score VARCHAR(20)
);

CREATE TABLE staging.stg_property_collateral (
    Property_ID VARCHAR(20), Application_ID VARCHAR(20), Customer_ID VARCHAR(20),
    Property_Type VARCHAR(30), Property_City VARCHAR(50), Property_State VARCHAR(50),
    Builder_Name VARCHAR(150), Construction_Status VARCHAR(30), Property_Age_Years VARCHAR(20),
    Carpet_Area_SqFt VARCHAR(20), Market_Value VARCHAR(30), Registration_Value VARCHAR(30),
    Valuation_Agency VARCHAR(50), Technical_Verification_Status VARCHAR(20),
    Legal_Verification_Status VARCHAR(20)
);

CREATE TABLE staging.stg_credit_bureau (
    Application_ID VARCHAR(20), Customer_ID VARCHAR(20), Credit_Score VARCHAR(10),
    Bureau_Score_Band VARCHAR(20), Total_Accounts VARCHAR(10), Active_Loans VARCHAR(10),
    Closed_Loans VARCHAR(10), Credit_Card_Utilization_Percent VARCHAR(20),
    Delinquency_Count_24M VARCHAR(10), Enquiry_Count_6M VARCHAR(10), Overdue_Amount VARCHAR(30),
    Written_Off_Flag VARCHAR(5), Settled_Account_Flag VARCHAR(5), Total_Outstanding VARCHAR(30)
);

CREATE TABLE staging.stg_document_fraud (
    Application_ID VARCHAR(20), Customer_ID VARCHAR(20), PAN_Verified VARCHAR(5),
    Aadhaar_Verified VARCHAR(5), Salary_Slip_Verified VARCHAR(5), Bank_Statement_Verified VARCHAR(5),
    ITR_Verified VARCHAR(5), Property_Document_Verified VARCHAR(5), Employment_Verified VARCHAR(5),
    Fraud_Flag VARCHAR(5), Document_Fraud_Flag VARCHAR(5), Identity_Mismatch_Flag VARCHAR(5)
);

CREATE TABLE staging.stg_underwriting_decision (
    Application_ID VARCHAR(20), Customer_ID VARCHAR(20), Risk_Score VARCHAR(10),
    PD_Percent VARCHAR(20), LGD_Percent VARCHAR(20), EAD_At_Origination VARCHAR(30),
    LTV_Percent VARCHAR(20), FOIR_Percent VARCHAR(20), Decision VARCHAR(20),
    Decision_Reason VARCHAR(50), Approved_Loan_Amount VARCHAR(30), Approved_Tenure_Months VARCHAR(10),
    Approved_Interest_Rate VARCHAR(20), Risk_Based_Pricing_Band VARCHAR(30), Underwriter_ID VARCHAR(20)
);

CREATE TABLE staging.stg_loan_disbursement (
    Loan_ID VARCHAR(20), Application_ID VARCHAR(20), Customer_ID VARCHAR(20),
    Disbursement_Date VARCHAR(20), Disbursement_Amount VARCHAR(30), First_EMI_Date VARCHAR(20),
    EMI_Amount VARCHAR(30), Loan_Status VARCHAR(20), Repayment_Account_Bank VARCHAR(50),
    Disbursement_Mode VARCHAR(20)
);

CREATE TABLE staging.stg_payment_transactions (
    Payment_ID VARCHAR(20), Loan_ID VARCHAR(20), Customer_ID VARCHAR(20), Payment_Date VARCHAR(20),
    Due_Date VARCHAR(20), EMI_Due VARCHAR(30), Amount_Paid VARCHAR(30), Payment_Mode VARCHAR(20),
    Payment_Status VARCHAR(20), Bounce_Flag VARCHAR(5), Days_Delay VARCHAR(10)
);

CREATE TABLE staging.stg_monthly_loan_performance (
    Loan_ID VARCHAR(20), Customer_ID VARCHAR(20), Snapshot_Month VARCHAR(10), MOB VARCHAR(10),
    Outstanding_Balance VARCHAR(30), Principal_Outstanding VARCHAR(30), Interest_Outstanding VARCHAR(30),
    Current_EMI VARCHAR(30), Days_Past_Due VARCHAR(10), Delinquency_Bucket VARCHAR(20),
    EMI_Paid_Count VARCHAR(10), EMI_Missed_Count VARCHAR(10), Bounce_Count_Cumulative VARCHAR(10),
    Restructured_Flag VARCHAR(5), NPA_Flag VARCHAR(5), Closure_Flag VARCHAR(5)
);

CREATE TABLE staging.stg_collections_recovery (
    Collection_ID VARCHAR(20), Loan_ID VARCHAR(20), Customer_ID VARCHAR(20), Snapshot_Month VARCHAR(10),
    Delinquency_Bucket VARCHAR(20), Priority_Score VARCHAR(10), SMS_Count VARCHAR(10),
    Call_Count VARCHAR(10), WhatsApp_Count VARCHAR(10), Field_Visit_Count VARCHAR(10),
    Promise_To_Pay_Flag VARCHAR(5), PTP_Amount VARCHAR(30), Payment_Received_After_Action VARCHAR(30),
    Collection_Status VARCHAR(20), Next_Action VARCHAR(50)
);

CREATE TABLE staging.stg_ifrs9_ecl_provisioning (
    Loan_ID VARCHAR(20), Customer_ID VARCHAR(20), Reporting_Date VARCHAR(20), IFRS9_Stage VARCHAR(10),
    PD_12M_Percent VARCHAR(20), Lifetime_PD_Percent VARCHAR(20), LGD_Percent VARCHAR(20),
    EAD VARCHAR(30), Expected_Credit_Loss VARCHAR(30), Provision_Amount VARCHAR(30),
    Provision_Rate_Percent VARCHAR(20)
);

CREATE TABLE staging.stg_branch_master (
    Branch_ID VARCHAR(20), Branch_Name VARCHAR(150), City VARCHAR(50), [State] VARCHAR(50),
    Region VARCHAR(20)
);

CREATE TABLE staging.stg_product_master (
    Product_Code VARCHAR(20), Product_Name VARCHAR(50), Interest_Min VARCHAR(20),
    Interest_Max VARCHAR(20), Min_Tenure VARCHAR(10), Max_Tenure VARCHAR(10),
    Min_LTV VARCHAR(20), Max_LTV VARCHAR(20)
);

CREATE TABLE staging.stg_macro_history (
    [year] VARCHAR(10), gdp_growth VARCHAR(20), unemployment_rate VARCHAR(20),
    inflation_cpi VARCHAR(20), annual_default_rate VARCHAR(20)
);

CREATE TABLE staging.stg_macro_scenarios (
    scenario VARCHAR(20), [year] VARCHAR(10), gdp_growth VARCHAR(20),
    unemployment_rate VARCHAR(20), inflation_cpi VARCHAR(20), probability VARCHAR(20)
);
GO

------------------------------------------------------------------------------
-- 2. BULK INSERT — raw load into staging
--    NOTE: files use CRLF line endings. ROWTERMINATOR is set to '0x0a' (LF)
--    on purpose — this is the more robust setting for CSVs exported on
--    Windows and avoids silent row-splitting issues. Because of this, the
--    LAST column of every row will carry a trailing CHAR(13). We strip that
--    explicitly with RTRIM(..., CHAR(13)) in every Step-3 CAST below, so it
--    never leaks into the final typed tables.
--    Update the file path below to match where you saved the CSVs.
------------------------------------------------------------------------------

BULK INSERT staging.stg_customer_master
FROM 'C:\IFRS9_Project2\01_Customer_Master.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK, CODEPAGE = '65001');

BULK INSERT staging.stg_loan_application
FROM 'C:\IFRS9_Project2\02_Loan_Application.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK, CODEPAGE = '65001');

BULK INSERT staging.stg_income_employment
FROM 'C:\IFRS9_Project2\03_Income_Employment.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK, CODEPAGE = '65001');

BULK INSERT staging.stg_property_collateral
FROM 'C:\IFRS9_Project2\04_Property_Collateral.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK, CODEPAGE = '65001');

BULK INSERT staging.stg_credit_bureau
FROM 'C:\IFRS9_Project2\05_Credit_Bureau.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK, CODEPAGE = '65001');

BULK INSERT staging.stg_document_fraud
FROM 'C:\IFRS9_Project2\06_Document_Fraud_Verification.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK, CODEPAGE = '65001');

BULK INSERT staging.stg_underwriting_decision
FROM 'C:\IFRS9_Project2\07_Underwriting_Decision.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK, CODEPAGE = '65001');

BULK INSERT staging.stg_loan_disbursement
FROM 'C:\IFRS9_Project2\08_Loan_Disbursement.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK, CODEPAGE = '65001');

BULK INSERT staging.stg_payment_transactions
FROM 'C:\IFRS9_Project2\09_Payment_Transactions.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK, CODEPAGE = '65001');

BULK INSERT staging.stg_monthly_loan_performance
FROM 'C:\IFRS9_Project2\10_Monthly_Loan_Performance.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK, CODEPAGE = '65001');

BULK INSERT staging.stg_collections_recovery
FROM 'C:\IFRS9_Project2\11_Collections_Recovery.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK, CODEPAGE = '65001');

BULK INSERT staging.stg_ifrs9_ecl_provisioning
FROM 'C:\IFRS9_Project2\12_IFRS9_ECL_Provisioning.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK, CODEPAGE = '65001');

BULK INSERT staging.stg_branch_master
FROM 'C:\IFRS9_Project2\13_Branch_Master.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK, CODEPAGE = '65001');

BULK INSERT staging.stg_product_master
FROM 'C:\IFRS9_Project2\14_Product_Master.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK, CODEPAGE = '65001');

BULK INSERT staging.stg_macro_history
FROM 'C:\IFRS9_Project2\macro_history.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK, CODEPAGE = '65001');

BULK INSERT staging.stg_macro_scenarios
FROM 'C:\IFRS9_Project2\macro_scenarios.csv'
WITH (FIRSTROW = 2, FIELDTERMINATOR = ',', ROWTERMINATOR = '0x0a', TABLOCK, CODEPAGE = '65001');
GO

------------------------------------------------------------------------------
-- 3. FINAL TYPED TABLES (dbo) + CAST from staging
--    Data types below were sized against the actual min/max values verified
--    in every file (e.g. FOIR_Percent and Debt_to_Income_Percent both exceed
--    100 in this dataset, so they use DECIMAL(8,2) rather than DECIMAL(5,2)).
------------------------------------------------------------------------------

-- 3.1 Customer Master
DROP TABLE IF EXISTS dbo.customer_master;
CREATE TABLE dbo.customer_master (
    Customer_ID VARCHAR(20) PRIMARY KEY,
    Customer_Name VARCHAR(200),
    DOB DATE,
    Age INT,
    Gender VARCHAR(20),
    Marital_Status VARCHAR(20),
    Education VARCHAR(30),
    City VARCHAR(50),
    [State] VARCHAR(50),
    Residence_Type VARCHAR(20),
    Years_at_Residence DECIMAL(5,1),
    Mobile_Verified CHAR(1),
    Email_Verified CHAR(1),
    KYC_Status VARCHAR(20)
);
INSERT INTO dbo.customer_master
SELECT
    Customer_ID,
    Customer_Name,
    TRY_CAST(DOB AS DATE),
    TRY_CAST(Age AS INT),
    Gender,
    Marital_Status,
    Education,
    City,
    [State],
    Residence_Type,
    TRY_CAST(Years_at_Residence AS DECIMAL(5,1)),
    Mobile_Verified,
    Email_Verified,
    RTRIM(KYC_Status, CHAR(13))   -- last column of the row -> strip trailing CR
FROM staging.stg_customer_master;
GO

-- 3.2 Loan Application
DROP TABLE IF EXISTS dbo.loan_application;
CREATE TABLE dbo.loan_application (
    Application_ID VARCHAR(20) PRIMARY KEY,
    Customer_ID VARCHAR(20),
    Application_Date DATE,
    Branch_ID VARCHAR(20),
    Channel VARCHAR(20),
    Loan_Purpose VARCHAR(30),
    Requested_Loan_Amount DECIMAL(18,2),
    Requested_Tenure_Months INT,
    Product_Type VARCHAR(30),
    Application_Status VARCHAR(20)
);
INSERT INTO dbo.loan_application
SELECT
    Application_ID, Customer_ID, TRY_CAST(Application_Date AS DATE), Branch_ID, Channel,
    Loan_Purpose, TRY_CAST(Requested_Loan_Amount AS DECIMAL(18,2)),
    TRY_CAST(Requested_Tenure_Months AS INT), Product_Type,
    RTRIM(Application_Status, CHAR(13))
FROM staging.stg_loan_application;
GO

-- 3.3 Income & Employment
DROP TABLE IF EXISTS dbo.income_employment;
CREATE TABLE dbo.income_employment (
    Application_ID VARCHAR(20) PRIMARY KEY,
    Customer_ID VARCHAR(20),
    Employment_Type VARCHAR(30),
    Occupation VARCHAR(50),
    Employer_Category VARCHAR(20),
    Work_Experience_Years DECIMAL(5,1),
    Monthly_Gross_Income DECIMAL(18,2),
    Other_Monthly_Income DECIMAL(18,2),
    Existing_EMI DECIMAL(18,2),
    Declared_Monthly_Obligation DECIMAL(18,2),
    Debt_to_Income_Percent DECIMAL(8,2),
    Disposable_Income DECIMAL(18,2),
    Income_Stability_Score DECIMAL(6,2)
);
INSERT INTO dbo.income_employment
SELECT
    Application_ID, Customer_ID, Employment_Type, Occupation, Employer_Category,
    TRY_CAST(Work_Experience_Years AS DECIMAL(5,1)),
    TRY_CAST(Monthly_Gross_Income AS DECIMAL(18,2)),
    TRY_CAST(Other_Monthly_Income AS DECIMAL(18,2)),
    TRY_CAST(Existing_EMI AS DECIMAL(18,2)),
    TRY_CAST(Declared_Monthly_Obligation AS DECIMAL(18,2)),
    TRY_CAST(Debt_to_Income_Percent AS DECIMAL(8,2)),
    TRY_CAST(Disposable_Income AS DECIMAL(18,2)),
    TRY_CAST(RTRIM(Income_Stability_Score, CHAR(13)) AS DECIMAL(6,2))
FROM staging.stg_income_employment;
GO

-- 3.4 Property & Collateral
DROP TABLE IF EXISTS dbo.property_collateral;
CREATE TABLE dbo.property_collateral (
    Property_ID VARCHAR(20) PRIMARY KEY,
    Application_ID VARCHAR(20),
    Customer_ID VARCHAR(20),
    Property_Type VARCHAR(30),
    Property_City VARCHAR(50),
    Property_State VARCHAR(50),
    Builder_Name VARCHAR(150),
    Construction_Status VARCHAR(30),
    Property_Age_Years DECIMAL(5,1),
    Carpet_Area_SqFt DECIMAL(10,1),
    Market_Value DECIMAL(18,2),
    Registration_Value DECIMAL(18,2),
    Valuation_Agency VARCHAR(50),
    Technical_Verification_Status VARCHAR(20),
    Legal_Verification_Status VARCHAR(20)
);
INSERT INTO dbo.property_collateral
SELECT
    Property_ID, Application_ID, Customer_ID, Property_Type, Property_City, Property_State,
    Builder_Name, Construction_Status,
    TRY_CAST(Property_Age_Years AS DECIMAL(5,1)),
    TRY_CAST(Carpet_Area_SqFt AS DECIMAL(10,1)),
    TRY_CAST(Market_Value AS DECIMAL(18,2)),
    TRY_CAST(Registration_Value AS DECIMAL(18,2)),
    Valuation_Agency, Technical_Verification_Status,
    RTRIM(Legal_Verification_Status, CHAR(13))
FROM staging.stg_property_collateral;
GO

-- 3.5 Credit Bureau
DROP TABLE IF EXISTS dbo.credit_bureau;
CREATE TABLE dbo.credit_bureau (
    Application_ID VARCHAR(20) PRIMARY KEY,
    Customer_ID VARCHAR(20),
    Credit_Score INT,
    Bureau_Score_Band VARCHAR(20),
    Total_Accounts INT,
    Active_Loans INT,
    Closed_Loans INT,
    Credit_Card_Utilization_Percent DECIMAL(6,2),
    Delinquency_Count_24M INT,
    Enquiry_Count_6M INT,
    Overdue_Amount DECIMAL(18,2),
    Written_Off_Flag CHAR(1),
    Settled_Account_Flag CHAR(1),
    Total_Outstanding DECIMAL(18,2)
);
INSERT INTO dbo.credit_bureau
SELECT
    Application_ID, Customer_ID, TRY_CAST(Credit_Score AS INT), Bureau_Score_Band,
    TRY_CAST(Total_Accounts AS INT), TRY_CAST(Active_Loans AS INT), TRY_CAST(Closed_Loans AS INT),
    TRY_CAST(Credit_Card_Utilization_Percent AS DECIMAL(6,2)),
    TRY_CAST(Delinquency_Count_24M AS INT), TRY_CAST(Enquiry_Count_6M AS INT),
    TRY_CAST(Overdue_Amount AS DECIMAL(18,2)), Written_Off_Flag, Settled_Account_Flag,
    TRY_CAST(RTRIM(Total_Outstanding, CHAR(13)) AS DECIMAL(18,2))
FROM staging.stg_credit_bureau;
GO

-- 3.6 Document & Fraud Verification
DROP TABLE IF EXISTS dbo.document_fraud_verification;
CREATE TABLE dbo.document_fraud_verification (
    Application_ID VARCHAR(20) PRIMARY KEY,
    Customer_ID VARCHAR(20),
    PAN_Verified VARCHAR(5),
    Aadhaar_Verified VARCHAR(5),
    Salary_Slip_Verified VARCHAR(5),   -- can legitimately be 'NA' (e.g. self-employed)
    Bank_Statement_Verified VARCHAR(5),
    ITR_Verified VARCHAR(5),           -- can legitimately be 'NA'
    Property_Document_Verified VARCHAR(5),
    Employment_Verified VARCHAR(5),
    Fraud_Flag CHAR(1),
    Document_Fraud_Flag CHAR(1),
    Identity_Mismatch_Flag CHAR(1)
);
INSERT INTO dbo.document_fraud_verification
SELECT
    Application_ID, Customer_ID, PAN_Verified, Aadhaar_Verified, Salary_Slip_Verified,
    Bank_Statement_Verified, ITR_Verified, Property_Document_Verified, Employment_Verified,
    Fraud_Flag, Document_Fraud_Flag,
    LEFT(RTRIM(Identity_Mismatch_Flag, CHAR(13)), 1)
FROM staging.stg_document_fraud;
GO

-- 3.7 Underwriting Decision
DROP TABLE IF EXISTS dbo.underwriting_decision;
CREATE TABLE dbo.underwriting_decision (
    Application_ID VARCHAR(20) PRIMARY KEY,
    Customer_ID VARCHAR(20),
    Risk_Score INT,
    PD_Percent DECIMAL(6,2),
    LGD_Percent DECIMAL(6,2),
    EAD_At_Origination DECIMAL(18,2),
    LTV_Percent DECIMAL(6,2),
    FOIR_Percent DECIMAL(8,2),          -- exceeds 100 in source data (max ~1314); sized accordingly
    Decision VARCHAR(20),
    Decision_Reason VARCHAR(50),
    Approved_Loan_Amount DECIMAL(18,2),
    Approved_Tenure_Months INT,
    Approved_Interest_Rate DECIMAL(6,2),
    Risk_Based_Pricing_Band VARCHAR(30),
    Underwriter_ID VARCHAR(20)
);
INSERT INTO dbo.underwriting_decision
SELECT
    Application_ID, Customer_ID, TRY_CAST(Risk_Score AS INT),
    TRY_CAST(PD_Percent AS DECIMAL(6,2)), TRY_CAST(LGD_Percent AS DECIMAL(6,2)),
    TRY_CAST(EAD_At_Origination AS DECIMAL(18,2)), TRY_CAST(LTV_Percent AS DECIMAL(6,2)),
    TRY_CAST(FOIR_Percent AS DECIMAL(8,2)), Decision, Decision_Reason,
    TRY_CAST(Approved_Loan_Amount AS DECIMAL(18,2)), TRY_CAST(Approved_Tenure_Months AS INT),
    TRY_CAST(Approved_Interest_Rate AS DECIMAL(6,2)), Risk_Based_Pricing_Band,
    RTRIM(Underwriter_ID, CHAR(13))
FROM staging.stg_underwriting_decision;
GO

-- 3.8 Loan Disbursement
DROP TABLE IF EXISTS dbo.loan_disbursement;
CREATE TABLE dbo.loan_disbursement (
    Loan_ID VARCHAR(20) PRIMARY KEY,
    Application_ID VARCHAR(20),
    Customer_ID VARCHAR(20),
    Disbursement_Date DATE,
    Disbursement_Amount DECIMAL(18,2),
    First_EMI_Date DATE,
    EMI_Amount DECIMAL(18,2),
    Loan_Status VARCHAR(20),
    Repayment_Account_Bank VARCHAR(50),
    Disbursement_Mode VARCHAR(20)
);
INSERT INTO dbo.loan_disbursement
SELECT
    Loan_ID, Application_ID, Customer_ID, TRY_CAST(Disbursement_Date AS DATE),
    TRY_CAST(Disbursement_Amount AS DECIMAL(18,2)), TRY_CAST(First_EMI_Date AS DATE),
    TRY_CAST(EMI_Amount AS DECIMAL(18,2)), Loan_Status, Repayment_Account_Bank,
    RTRIM(Disbursement_Mode, CHAR(13))
FROM staging.stg_loan_disbursement;
GO

-- 3.9 Payment Transactions
DROP TABLE IF EXISTS dbo.payment_transactions;
CREATE TABLE dbo.payment_transactions (
    Payment_ID VARCHAR(20) PRIMARY KEY,
    Loan_ID VARCHAR(20),
    Customer_ID VARCHAR(20),
    Payment_Date DATE,
    Due_Date DATE,
    EMI_Due DECIMAL(18,2),
    Amount_Paid DECIMAL(18,2),
    Payment_Mode VARCHAR(20),
    Payment_Status VARCHAR(20),
    Bounce_Flag TINYINT,          -- source is numeric 0/1, not Y/N
    Days_Delay INT
);
INSERT INTO dbo.payment_transactions
SELECT
    Payment_ID, Loan_ID, Customer_ID, TRY_CAST(Payment_Date AS DATE), TRY_CAST(Due_Date AS DATE),
    TRY_CAST(EMI_Due AS DECIMAL(18,2)), TRY_CAST(Amount_Paid AS DECIMAL(18,2)),
    Payment_Mode, Payment_Status, TRY_CAST(Bounce_Flag AS TINYINT),
    TRY_CAST(RTRIM(Days_Delay, CHAR(13)) AS INT)
FROM staging.stg_payment_transactions;
GO

-- 3.10 Monthly Loan Performance  (core fact table for portfolio monitoring)
--
-- KNOWN SOURCE DATA BUG (caught during validation, same spirit as the
-- macro-probability trap in Project 1): the raw Snapshot_Month text label
-- is unreliable for ~6,807 loans (13,614 rows) where two different MOB
-- values were both stamped with the same Snapshot_Month string (e.g. loan
-- HL015345 has MOB=22 AND MOB=23 both labeled '2026-01'). This caused the
-- original PRIMARY KEY (Loan_ID, Snapshot_Month) to violate and silently
-- fail the entire insert (0 rows loaded).
--
-- FIX: (Loan_ID, MOB) is verified unique (checked directly, zero duplicate
-- groups) and is the true grain of this table. Snapshot_Month_Date is
-- rebuilt as Disbursement_Date + MOB months, a formula confirmed against
-- multiple clean (non-duplicated) loans to exactly reproduce the correct
-- source Snapshot_Month wherever the source label was NOT corrupted. The
-- original raw text is kept as Snapshot_Month_Raw for audit purposes, and
-- Snapshot_Month_Mismatch_Flag marks every row where the raw label
-- disagreed with the recomputed date, so the anomaly stays documented
-- rather than silently overwritten.
DROP TABLE IF EXISTS dbo.monthly_loan_performance;
CREATE TABLE dbo.monthly_loan_performance (
    Loan_ID VARCHAR(20),
    Customer_ID VARCHAR(20),
    MOB INT,
    Snapshot_Month_Raw CHAR(7),                -- as given in source, kept for audit only
    Snapshot_Month_Date DATE,                  -- AUTHORITATIVE: Disbursement_Date + MOB months
    Snapshot_Month_Mismatch_Flag BIT,          -- 1 = raw label disagreed with recomputed date
    Outstanding_Balance DECIMAL(18,2),
    Principal_Outstanding DECIMAL(18,2),
    Interest_Outstanding DECIMAL(18,2),
    Current_EMI DECIMAL(18,2),
    Days_Past_Due INT,
    Delinquency_Bucket VARCHAR(20),
    EMI_Paid_Count INT,
    EMI_Missed_Count INT,
    Bounce_Count_Cumulative INT,
    Restructured_Flag CHAR(1),
    NPA_Flag CHAR(1),
    Closure_Flag CHAR(1),
    CONSTRAINT PK_monthly_loan_performance PRIMARY KEY (Loan_ID, MOB)
);
INSERT INTO dbo.monthly_loan_performance
SELECT
    p.Loan_ID,
    p.Customer_ID,
    TRY_CAST(p.MOB AS INT),
    p.Snapshot_Month,
    DATEADD(MONTH, TRY_CAST(p.MOB AS INT), d.Disbursement_Date)
        AS Snapshot_Month_Date,
    CASE WHEN FORMAT(DATEADD(MONTH, TRY_CAST(p.MOB AS INT), d.Disbursement_Date), 'yyyy-MM')
              <> p.Snapshot_Month
         THEN 1 ELSE 0 END AS Snapshot_Month_Mismatch_Flag,
    TRY_CAST(p.Outstanding_Balance AS DECIMAL(18,2)),
    TRY_CAST(p.Principal_Outstanding AS DECIMAL(18,2)),
    TRY_CAST(p.Interest_Outstanding AS DECIMAL(18,2)),
    TRY_CAST(p.Current_EMI AS DECIMAL(18,2)),
    TRY_CAST(p.Days_Past_Due AS INT),
    p.Delinquency_Bucket,
    TRY_CAST(p.EMI_Paid_Count AS INT),
    TRY_CAST(p.EMI_Missed_Count AS INT),
    TRY_CAST(p.Bounce_Count_Cumulative AS INT),
    p.Restructured_Flag,
    p.NPA_Flag,
    LEFT(RTRIM(p.Closure_Flag, CHAR(13)), 1)
FROM staging.stg_monthly_loan_performance p
JOIN dbo.loan_disbursement d ON d.Loan_ID = p.Loan_ID;
GO

-- 3.11 Collections & Recovery  (core fact table for collections strategy)
DROP TABLE IF EXISTS dbo.collections_recovery;
CREATE TABLE dbo.collections_recovery (
    Collection_ID VARCHAR(20) PRIMARY KEY,
    Loan_ID VARCHAR(20),
    Customer_ID VARCHAR(20),
    Snapshot_Month CHAR(7),
    Snapshot_Month_Date DATE,
    Delinquency_Bucket VARCHAR(20),
    Priority_Score INT,
    SMS_Count INT,
    Call_Count INT,
    WhatsApp_Count INT,
    Field_Visit_Count INT,
    Promise_To_Pay_Flag CHAR(1),
    PTP_Amount DECIMAL(18,2),
    Payment_Received_After_Action DECIMAL(18,2),
    Collection_Status VARCHAR(20),
    Next_Action VARCHAR(50)
);
INSERT INTO dbo.collections_recovery
SELECT
    Collection_ID, Loan_ID, Customer_ID, Snapshot_Month,
    TRY_CAST(Snapshot_Month + '-01' AS DATE),
    Delinquency_Bucket, TRY_CAST(Priority_Score AS INT), TRY_CAST(SMS_Count AS INT),
    TRY_CAST(Call_Count AS INT), TRY_CAST(WhatsApp_Count AS INT), TRY_CAST(Field_Visit_Count AS INT),
    Promise_To_Pay_Flag, TRY_CAST(PTP_Amount AS DECIMAL(18,2)),
    TRY_CAST(Payment_Received_After_Action AS DECIMAL(18,2)), Collection_Status,
    RTRIM(Next_Action, CHAR(13))
FROM staging.stg_collections_recovery;
GO

-- 3.12 IFRS9 ECL Provisioning (reference file, not used as a model input)
DROP TABLE IF EXISTS dbo.ifrs9_ecl_provisioning_actual;
CREATE TABLE dbo.ifrs9_ecl_provisioning_actual (
    Loan_ID VARCHAR(20) PRIMARY KEY,
    Customer_ID VARCHAR(20),
    Reporting_Date DATE,
    IFRS9_Stage VARCHAR(10),
    PD_12M_Percent DECIMAL(8,2),
    Lifetime_PD_Percent DECIMAL(8,2),
    LGD_Percent DECIMAL(6,2),
    EAD DECIMAL(18,2),
    Expected_Credit_Loss DECIMAL(18,2),
    Provision_Amount DECIMAL(18,2),
    Provision_Rate_Percent DECIMAL(8,2)
);
INSERT INTO dbo.ifrs9_ecl_provisioning_actual
SELECT
    Loan_ID, Customer_ID, TRY_CAST(Reporting_Date AS DATE), IFRS9_Stage,
    TRY_CAST(PD_12M_Percent AS DECIMAL(8,2)), TRY_CAST(Lifetime_PD_Percent AS DECIMAL(8,2)),
    TRY_CAST(LGD_Percent AS DECIMAL(6,2)), TRY_CAST(EAD AS DECIMAL(18,2)),
    TRY_CAST(Expected_Credit_Loss AS DECIMAL(18,2)), TRY_CAST(Provision_Amount AS DECIMAL(18,2)),
    TRY_CAST(RTRIM(Provision_Rate_Percent, CHAR(13)) AS DECIMAL(8,2))
FROM staging.stg_ifrs9_ecl_provisioning;
GO

-- 3.13 Branch Master
DROP TABLE IF EXISTS dbo.branch_master;
CREATE TABLE dbo.branch_master (
    Branch_ID VARCHAR(20) PRIMARY KEY,
    Branch_Name VARCHAR(150),
    City VARCHAR(50),
    [State] VARCHAR(50),
    Region VARCHAR(20)
);
INSERT INTO dbo.branch_master
SELECT Branch_ID, Branch_Name, City, [State], RTRIM(Region, CHAR(13))
FROM staging.stg_branch_master;
GO

-- 3.14 Product Master
DROP TABLE IF EXISTS dbo.product_master;
CREATE TABLE dbo.product_master (
    Product_Code VARCHAR(20) PRIMARY KEY,
    Product_Name VARCHAR(50),
    Interest_Min DECIMAL(6,2),
    Interest_Max DECIMAL(6,2),
    Min_Tenure INT,
    Max_Tenure INT,
    Min_LTV DECIMAL(6,2),
    Max_LTV DECIMAL(6,2)
);
INSERT INTO dbo.product_master
SELECT
    Product_Code, Product_Name, TRY_CAST(Interest_Min AS DECIMAL(6,2)),
    TRY_CAST(Interest_Max AS DECIMAL(6,2)), TRY_CAST(Min_Tenure AS INT),
    TRY_CAST(Max_Tenure AS INT), TRY_CAST(Min_LTV AS DECIMAL(6,2)),
    TRY_CAST(RTRIM(Max_LTV, CHAR(13)) AS DECIMAL(6,2))
FROM staging.stg_product_master;
GO

-- 3.15 Macro History (2014-2024 actuals)
DROP TABLE IF EXISTS dbo.macro_history;
CREATE TABLE dbo.macro_history (
    [year] INT PRIMARY KEY,
    gdp_growth DECIMAL(6,2),
    unemployment_rate DECIMAL(6,2),
    inflation_cpi DECIMAL(6,2),
    annual_default_rate DECIMAL(8,4)   -- stored as decimal fraction, e.g. 0.028 = 2.8%
);
INSERT INTO dbo.macro_history
SELECT
    TRY_CAST([year] AS INT), TRY_CAST(gdp_growth AS DECIMAL(6,2)),
    TRY_CAST(unemployment_rate AS DECIMAL(6,2)), TRY_CAST(inflation_cpi AS DECIMAL(6,2)),
    TRY_CAST(RTRIM(annual_default_rate, CHAR(13)) AS DECIMAL(8,4))
FROM staging.stg_macro_history;
GO

-- 3.16 Macro Scenarios (2025-2029 forecasts, Baseline/Downside/Upside)
DROP TABLE IF EXISTS dbo.macro_scenarios;
CREATE TABLE dbo.macro_scenarios (
    scenario VARCHAR(20),
    [year] INT,
    gdp_growth DECIMAL(6,2),
    unemployment_rate DECIMAL(6,2),
    inflation_cpi DECIMAL(6,2),
    probability DECIMAL(5,4),          -- stored as decimal fraction, e.g. 0.5 = 50% -- NOT /100 !
    CONSTRAINT PK_macro_scenarios PRIMARY KEY (scenario, [year])
);
INSERT INTO dbo.macro_scenarios
SELECT
    scenario, TRY_CAST([year] AS INT), TRY_CAST(gdp_growth AS DECIMAL(6,2)),
    TRY_CAST(unemployment_rate AS DECIMAL(6,2)), TRY_CAST(inflation_cpi AS DECIMAL(6,2)),
    TRY_CAST(RTRIM(probability, CHAR(13)) AS DECIMAL(5,4))
FROM staging.stg_macro_scenarios;
GO

------------------------------------------------------------------------------
-- 4. INDEXES on the two large fact tables (needed for roll-rate / vintage /
--    cure-rate / collections queries we'll run in later phases)
------------------------------------------------------------------------------
CREATE NONCLUSTERED INDEX IX_mlp_loan_month ON dbo.monthly_loan_performance (Loan_ID, Snapshot_Month_Date);
CREATE NONCLUSTERED INDEX IX_mlp_month_bucket ON dbo.monthly_loan_performance (Snapshot_Month_Date, Delinquency_Bucket);
CREATE NONCLUSTERED INDEX IX_pay_loan_date ON dbo.payment_transactions (Loan_ID, Payment_Date);
CREATE NONCLUSTERED INDEX IX_coll_loan_month ON dbo.collections_recovery (Loan_ID, Snapshot_Month_Date);
GO

------------------------------------------------------------------------------
-- 5. VALIDATION — row-count reconciliation
--    Expected counts below were verified directly against the source CSV
--    files before writing this script. Run this block and confirm every
--    row shows Match = 'OK'.
------------------------------------------------------------------------------
SELECT 'customer_master' AS TableName, COUNT(*) AS LoadedRows, 100000 AS ExpectedRows,
       CASE WHEN COUNT(*) = 100000 THEN 'OK' ELSE 'MISMATCH' END AS Match FROM dbo.customer_master
UNION ALL
SELECT 'loan_application', COUNT(*), 100000, CASE WHEN COUNT(*) = 100000 THEN 'OK' ELSE 'MISMATCH' END FROM dbo.loan_application
UNION ALL
SELECT 'income_employment', COUNT(*), 100000, CASE WHEN COUNT(*) = 100000 THEN 'OK' ELSE 'MISMATCH' END FROM dbo.income_employment
UNION ALL
SELECT 'property_collateral', COUNT(*), 100000, CASE WHEN COUNT(*) = 100000 THEN 'OK' ELSE 'MISMATCH' END FROM dbo.property_collateral
UNION ALL
SELECT 'credit_bureau', COUNT(*), 100000, CASE WHEN COUNT(*) = 100000 THEN 'OK' ELSE 'MISMATCH' END FROM dbo.credit_bureau
UNION ALL
SELECT 'document_fraud_verification', COUNT(*), 100000, CASE WHEN COUNT(*) = 100000 THEN 'OK' ELSE 'MISMATCH' END FROM dbo.document_fraud_verification
UNION ALL
SELECT 'underwriting_decision', COUNT(*), 100000, CASE WHEN COUNT(*) = 100000 THEN 'OK' ELSE 'MISMATCH' END FROM dbo.underwriting_decision
UNION ALL
SELECT 'loan_disbursement', COUNT(*), 19659, CASE WHEN COUNT(*) = 19659 THEN 'OK' ELSE 'MISMATCH' END FROM dbo.loan_disbursement
UNION ALL
SELECT 'payment_transactions', COUNT(*), 377538, CASE WHEN COUNT(*) = 377538 THEN 'OK' ELSE 'MISMATCH' END FROM dbo.payment_transactions
UNION ALL
SELECT 'monthly_loan_performance', COUNT(*), 377538, CASE WHEN COUNT(*) = 377538 THEN 'OK' ELSE 'MISMATCH' END FROM dbo.monthly_loan_performance
UNION ALL
SELECT 'collections_recovery', COUNT(*), 29631, CASE WHEN COUNT(*) = 29631 THEN 'OK' ELSE 'MISMATCH' END FROM dbo.collections_recovery
UNION ALL
SELECT 'ifrs9_ecl_provisioning_actual', COUNT(*), 19659, CASE WHEN COUNT(*) = 19659 THEN 'OK' ELSE 'MISMATCH' END FROM dbo.ifrs9_ecl_provisioning_actual
UNION ALL
SELECT 'branch_master', COUNT(*), 100, CASE WHEN COUNT(*) = 100 THEN 'OK' ELSE 'MISMATCH' END FROM dbo.branch_master
UNION ALL
SELECT 'product_master', COUNT(*), 3, CASE WHEN COUNT(*) = 3 THEN 'OK' ELSE 'MISMATCH' END FROM dbo.product_master
UNION ALL
SELECT 'macro_history', COUNT(*), 11, CASE WHEN COUNT(*) = 11 THEN 'OK' ELSE 'MISMATCH' END FROM dbo.macro_history
UNION ALL
SELECT 'macro_scenarios', COUNT(*), 15, CASE WHEN COUNT(*) = 15 THEN 'OK' ELSE 'MISMATCH' END FROM dbo.macro_scenarios;
GO

------------------------------------------------------------------------------
-- 6. SECONDARY VALIDATION — spot-check for NULLs introduced by bad casts
--    (a non-zero count here on a column that should always be populated
--     means a TRY_CAST silently failed and needs investigating)
------------------------------------------------------------------------------
SELECT 'loan_disbursement.Disbursement_Date NULLs' AS Check_, COUNT(*) AS Cnt
FROM dbo.loan_disbursement WHERE Disbursement_Date IS NULL
UNION ALL
SELECT 'monthly_loan_performance.Snapshot_Month_Date NULLs', COUNT(*)
FROM dbo.monthly_loan_performance WHERE Snapshot_Month_Date IS NULL
UNION ALL
SELECT 'monthly_loan_performance.Days_Past_Due NULLs', COUNT(*)
FROM dbo.monthly_loan_performance WHERE Days_Past_Due IS NULL
UNION ALL
SELECT 'ifrs9_ecl_provisioning_actual.Expected_Credit_Loss NULLs', COUNT(*)
FROM dbo.ifrs9_ecl_provisioning_actual WHERE Expected_Credit_Loss IS NULL
UNION ALL
SELECT 'macro_scenarios.probability NULLs', COUNT(*)
FROM dbo.macro_scenarios WHERE probability IS NULL;
GO

-- Quick sanity check that probability is stored as a fraction, not /100 (prevents the
-- bug we hit in Project 1)
SELECT scenario, SUM(probability) AS total_probability_should_not_apply_here
FROM dbo.macro_scenarios GROUP BY scenario;
-- (this just confirms values load as 0.50/0.30/0.20 — the actual weighting-by-year
--  logic comes in the SAS macro-overlay step, not here)

/* ============================================================================
   END OF PHASE 1
   Next: Phase 2 — SQL views/staging tables for roll-rate, vintage cohort,
   and cure-rate logic on dbo.monthly_loan_performance.
   ============================================================================ */

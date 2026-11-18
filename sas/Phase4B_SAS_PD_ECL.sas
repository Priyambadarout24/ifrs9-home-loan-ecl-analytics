/* ============================================================================
   IFRS 9 PROJECT 2 — PHASE 4B: SAS — MARKOV-CHAIN PD, MACRO OVERLAY, ECL
   Uses the SQL exports from Phase 4A + the roll-rate matrix from Phase 2.

   METHODOLOGY NOTE 1 — STAGE 3 DEFINITION: NPA_Flag in the source data is
   STICKY (once 'Y', never reverts to 'N', even for loans that have since
   fully cured — 1,638 loans currently sitting in bucket A1.Current still
   carry NPA_Flag='Y' from a past episode). Using it for Stage 3 would
   inflate that population with loans no longer actually in default, and
   produced the unrealistic result of Stage 3 > Stage 2 in an earlier
   version of this build. Stage 3 here uses ONLY current Days_Past_Due>=90
   — current credit risk, not historical scars.

   METHODOLOGY NOTE 2 — PD MODEL: PD is built by propagating the empirical
   roll-rate transition matrix forward month-by-month (a Markov chain),
   with the 90+DPD state (A5) treated as absorbing FOR THIS CALCULATION
   ONLY — i.e. once a loan is simulated to reach A5, it's treated as
   "defaulted" for PD purposes even though empirically some A5 loans do
   cure (that's correctly preserved as non-absorbing in the Phase 2
   roll-rate/cure-rate tables, which are a separate, reporting-only view).
   This is a standard, defensible simplification for a Markov-chain PD
   model, not an error.

   EXPECTED VALIDATION NUMBERS (computed independently in Python before
   writing this SAS code):
     - Macro adjustment factor: ~0.9967
     - Stage 1: 18,047 loans | EAD ~103.05B | ECL ~2.14B | coverage ~2.07%
     - Stage 2:  1,006 loans | EAD ~5.93B   | ECL ~1.10B | coverage ~18.53%
     - Stage 3:    606 loans | EAD ~3.56B   | ECL ~0.78B | coverage ~21.98%
     - Overall portfolio coverage ratio: ~3.55%

   ============================================================================ */

/* ---- 0. Library and file paths — adjust to match your SAS OnDemand setup ---- */
libname ifrs9 '~/ifrs9_project2';

/* ---- 1. Import all inputs ---- */
proc import datafile='~/ifrs9_project2/ifrs9_staging_export.csv'
    out=ifrs9.staging_export dbms=csv replace;
    guessingrows=max;
run;

proc import datafile='~/ifrs9_project2/roll_rate_matrix_export.csv'
    out=ifrs9.roll_matrix_raw dbms=csv replace;
    guessingrows=max;
run;

proc import datafile='~/ifrs9_project2/macro_history.csv'
    out=ifrs9.macro_history dbms=csv replace;
    guessingrows=max;
run;

proc import datafile='~/ifrs9_project2/macro_scenarios.csv'
    out=ifrs9.macro_scenarios dbms=csv replace;
    guessingrows=max;
run;


/* ---- 2. Pull the 5x5 empirical matrix into macro variables (rows A1-A4;
           row A5 is hardcoded absorbing below, NOT read from the file,
           so the absorbing assumption is explicit in code, not implicit
           in whatever the CSV happens to contain) ---- */
proc sql noprint;
    select P_To_A1, P_To_A2, P_To_A3, P_To_A4, P_To_A5
        into :m11, :m12, :m13, :m14, :m15
        from ifrs9.roll_matrix_raw where Bucket_From = 'A1.Current';
    select P_To_A1, P_To_A2, P_To_A3, P_To_A4, P_To_A5
        into :m21, :m22, :m23, :m24, :m25
        from ifrs9.roll_matrix_raw where Bucket_From = "A2.1-30 DPD";
    select P_To_A1, P_To_A2, P_To_A3, P_To_A4, P_To_A5
        into :m31, :m32, :m33, :m34, :m35
        from ifrs9.roll_matrix_raw where Bucket_From = "A3.31-60 DPD";
    select P_To_A1, P_To_A2, P_To_A3, P_To_A4, P_To_A5
        into :m41, :m42, :m43, :m44, :m45
        from ifrs9.roll_matrix_raw where Bucket_From = "A4.61-90 DPD";
quit;

/* ---- 3. Build the PD lookup table: cumulative probability of having been
           absorbed into Default (state 5), for each starting state (1-5)
           and each month N (1-360). Matrix power via direct iteration —
           no PROC IML dependency, so this runs on any SAS OnDemand setup. ---- */
data ifrs9.pd_lookup;
    array m{5,5} _temporary_ (
        &m11 &m12 &m13 &m14 &m15
        &m21 &m22 &m23 &m24 &m25
        &m31 &m32 &m33 &m34 &m35
        &m41 &m42 &m43 &m44 &m45
        0    0    0    0    1        /* row 5 forced absorbing */
    );
    array v{5} _temporary_;
    array vnext{5} _temporary_;

    do Starting_State = 1 to 5;
        do i = 1 to 5;
            v{i} = (i = Starting_State);
        end;
        do Month_N = 1 to 360;
            do j = 1 to 5;
                vnext{j} = 0;
                do i = 1 to 5;
                    vnext{j} = vnext{j} + v{i} * m{i,j};
                end;
            end;
            do i = 1 to 5;
                v{i} = vnext{i};
            end;
            PD_Cumulative = v{5};
            output;
        end;
    end;
    keep Starting_State Month_N PD_Cumulative;
run;

/* Sanity check: from state 1, PD at month 12 should be ~9.25%; from state
   5, PD at any month should be exactly 100% (already absorbed) */
proc print data=ifrs9.pd_lookup;
    where (Starting_State = 1 and Month_N = 12) or (Starting_State = 5 and Month_N = 12);
run;

/* ---- 4. Macro adjustment factor — probability-weighted, using
           unemployment rate as the macro driver (most credit-relevant
           variable available for a retail mortgage book). Factor =
           weighted average of (scenario avg unemployment / historical
           avg unemployment). NOTE: probability in macro_scenarios.csv is
           already a decimal fraction (0.5 = 50%) — do NOT divide by 100,
           that was the exact bug caught in Project 1. ---- */
proc sql noprint;
    select mean(unemployment_rate) into :hist_avg_unemp
        from ifrs9.macro_history;
quit;

proc sql;
    create table ifrs9.macro_scenario_summary as
    select scenario,
           mean(unemployment_rate) as avg_unemp,
           min(probability) as probability,   /* same value repeated per scenario-year row */
           mean(unemployment_rate) / &hist_avg_unemp as relative_factor,
           calculated relative_factor * calculated probability as weighted_component
    from ifrs9.macro_scenarios
    group by scenario;
quit;

proc sql noprint;
    select sum(weighted_component) into :macro_factor
        from ifrs9.macro_scenario_summary;
quit;

%put NOTE: Macro adjustment factor = &macro_factor (expect ~0.9967);

/* ---- 5. Attach 12-month PD and lifetime PD to every loan, apply the
           macro overlay, and compute final ECL ----
           (Every MERGE...BY below requires both inputs pre-sorted by the
           BY variable(s) -- explicit PROC SORT steps are included for
           each one rather than relying on incidental output order.) */

/* Cap remaining tenure at 360 up front, before any sorting/merging */
data ifrs9.staging_export2;
    set ifrs9.staging_export;
    Remaining_Tenure_Capped = min(Remaining_Tenure_Months, 360);
run;

proc sort data=ifrs9.staging_export2; by Current_State_Num; run;

data pd12_lookup;
    set ifrs9.pd_lookup(where=(Month_N=12));
    rename Starting_State = Current_State_Num PD_Cumulative = PD_12M_Raw;
run;
proc sort data=pd12_lookup; by Current_State_Num; run;

data ifrs9.staging_with_pd12;
    merge ifrs9.staging_export2(in=a) pd12_lookup(keep=Current_State_Num PD_12M_Raw);
    by Current_State_Num;
    if a;
run;

/* For lifetime PD, join on (state, remaining tenure) pair */
data pd_lookup_life;
    set ifrs9.pd_lookup;
    rename Starting_State = Current_State_Num Month_N = Remaining_Tenure_Capped PD_Cumulative = PD_Lifetime_Raw;
run;
proc sort data=pd_lookup_life; by Current_State_Num Remaining_Tenure_Capped; run;
proc sort data=ifrs9.staging_with_pd12; by Current_State_Num Remaining_Tenure_Capped; run;

data ifrs9.loan_ecl_final;
    merge ifrs9.staging_with_pd12(in=a) pd_lookup_life(keep=Current_State_Num Remaining_Tenure_Capped PD_Lifetime_Raw);
    by Current_State_Num Remaining_Tenure_Capped;
    if a;

    /* Macro overlay: applied only to forward-looking Stage 1/2 PD.
       Stage 3 is already credit-impaired -- PD is fixed at 100%,
       not multiplied by a macro factor (macro overlay is a forward risk
       adjustment; it doesn't apply to a loss that has already crystallized). */
    if IFRS9_Stage_Calculated = 'Stage 3' then PD_Final = 1.00;
    else if IFRS9_Stage_Calculated = 'Stage 2' then
        PD_Final = min(PD_Lifetime_Raw * &macro_factor, 0.99);
    else
        PD_Final = min(PD_12M_Raw * &macro_factor, 0.99);

    LGD_Decimal = LGD_Percent / 100;
    Expected_Credit_Loss = EAD * LGD_Decimal * PD_Final;
run;

/* ---- 6. Portfolio summary by stage ---- */
proc sql;
    create table ifrs9.ecl_summary_by_stage as
    select IFRS9_Stage_Calculated,
           count(*) as Loan_Count,
           sum(EAD) as Total_EAD format=18.2,
           sum(Expected_Credit_Loss) as Total_ECL format=18.2,
           calculated Total_ECL / calculated Total_EAD * 100 as Coverage_Ratio_Pct format=6.2
    from ifrs9.loan_ecl_final
    group by IFRS9_Stage_Calculated;
quit;

title 'Our Built ECL — by Stage (expect Stage1~2.07%, Stage2~18.53%, Stage3~21.98%)';
proc print data=ifrs9.ecl_summary_by_stage; run;

proc sql;
    select sum(Expected_Credit_Loss) / sum(EAD) * 100 as Overall_Coverage_Pct format=6.2
    into :overall_coverage
    from ifrs9.loan_ecl_final;
quit;
%put NOTE: Overall coverage ratio = &overall_coverage percent (expect ~3.55%);


/* ============================================================================
   END OF PHASE 4
   Deliverables now ready for Power BI: ifrs9.loan_ecl_final (loan-level),
   ifrs9.ecl_summary_by_stage, dbo.roll_rate_matrix, dbo.vintage_curve,
   dbo.cure_rate_summary, dbo.ptp_performance_summary,
   dbo.collection_efficiency_by_priority.
   ============================================================================ */

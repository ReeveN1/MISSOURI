/*MISSOURI WLGP UTI cohort sub study
 * 
 * This differs in inclusion criteria from the MISSOURI main paper as no PEDW record is required for inclusion
 * 
 * For UTIs to be considered separate acute events there must be at least 28 days between the last date of the previous UTI 
 * (latest of GP iagnosis, GP antibiotic prescription or WRRS specimen request date) and the first date of the next one.
 * 
 * Main dataset WLGP EVENTS
 * Date period 2010-01-01 to 2020-12-31
 * Only ALFs with 1,4,39 and not null status code
 * Only people with a Welsh residence i.e. WDSD WELSH_ADDRESS = 1 at time of WLGP event date
 * Age inclusion 30 to 100 inclusive
 * All UTIs are included - first of WLGP diagnosis read code, WLGP antibiotic Read code and WRRS specimen result recorded within 7 days
 * Must have no prior history of CVD in PEDW hospital data
 * Must have 12 months of health data prior to UTI date
*/

-- ===========================================================
-- create cohort spine table
-- ===========================================================

--==============================================================
--create cohort spine table using GP and address data to identify those eligible for inclusion

--This table contains only one row per person where that person has more than one period of SAIL GP regsitration 
--or Welsh address during the study period then only the period where inclusion criteria was met is included.

--Gaps in SAIL GP registration <= 7 days are closed and considered admin differences between recording systems

--date of death obtained from ADDE initially and then populated with WDSD if ADDE is null

CALL fnc.drop_if_exists('sailw0972v.vb_wlgp_sub_cohort_spine');
	
CREATE TABLE sailw0972v.vb_wlgp_sub_cohort_spine
 (
	UNIQUE_ID 	INT 	NOT NULL 	GENERATED ALWAYS AS IDENTITY (START WITH 1000000, INCREMENT BY 1),
	alf_pe 			varchar(15),	-- unique person id
	wob 			date,			-- week of birth
	dod 			date,			-- date of death (where applicable)
	gndr_cd 		integer,		-- gender code
	GP_STR_DT 		date,			-- SAIL GP registration start date
	GP_END_DT 		date,			-- SAIL GP registration end date
	ADD_STR_DT	 	date,			-- welsh address start date
	ADD_END_DT 		date,			-- welsh address end date
	MAX_STR_DT 		date,			-- maximum start date for period of inclusion (i.e. inclusion start date)
	MIN_END_DT 		date,			-- minimum end date for period of inclusion (i.e. inclusion end date)
	PERS_ROW 		integer			-- person row number, used to identify first period of inclusion only
)
NOT logged initially;

INSERT INTO sailw0972v.vb_wlgp_sub_cohort_spine
( 	alf_pe,
	wob,
	dod,
	gndr_cd,
	GP_STR_DT,
	GP_END_DT,
	ADD_STR_DT,
	ADD_END_DT,
	MAX_STR_DT,
	MIN_END_DT,
	PERS_ROW)
SELECT wd.alf_pe,
		wd.wob,
		CASE WHEN date(ad.death_dt) IS NULL
			THEN wd.DOD
			ELSE date(ad.DEATH_DT)
		END AS dod,
		wd.gndr_cd,
		gp.str_dt AS gp_str,
		CASE WHEN gp.END_Dt > '2020-12-31'
				THEN '2020-12-31'
				else gp.END_dt
			END AS gp_end,
		ws.Start_date,
		CASE WHEN ws.END_Date > '2020-12-31'
				THEN '9999-01-01'
				ELSE ws.END_Date
			end,
		max(COALESCE(wd.wob,'1800-01-01'),gp.STR_DT, ws.START_DATE, '2010-01-01', wob + 30 years) AS max_str,
		min(COALESCE(wd.dod,'2099-12-31'),gp.END_Dt, ws.END_Date, '2020-12-31') AS min_end,--end date set so that there is a max date to prevent ongoing records with missing data
		ROW_NUMBER() OVER (PARTITION BY wd.alf_pe ORDER BY ws.Start_date, gp.str_dt, gp.END_Dt, ws.END_Date) AS ROW_NUM
FROM sail0972v.WDSD_AR_PERS_20210502 AS wd
	INNER JOIN SAILw0972v.VB_WLGP_SUB_GP_DATES_COMB1 AS gp
		ON wd.ALF_PE = gp.ALF_PE
	INNER JOIN sail0972v.WDSD_CLEAN_ADD_WALES_20210502 AS ws
		ON wd.ALF_PE = ws.ALF_PE
	LEFT JOIN sail0972v.ADDE_DEATHS_20210428 AS ad
		ON wd.ALF_PE = ad.ALF_PE
		AND ad.ALF_STS_CD IN ('1','4','39')
	WHERE (wd.dod IS NULL
		OR wd.dod >= '2010-01-01')
	AND gp.END_DT >= '2010-01-01'
	AND ws.END_DATE >= '2010-01-01'
	AND gp.STR_DT <= '2020-12-31'
	AND ws.START_DATE <= '2020-12-31'
	AND gp.str_dt <= ws.end_date
	AND	ws.end_date >= gp.str_dt
	AND wd.wob + 30 YEARS <= gp.end_dt
	AND wd.wob + 30 YEARS <= ws.end_date
	AND wob + 30 YEARS <= '2020-12-31'
	AND wob + 100 YEARS >= '2010-01-01'
	AND welsh_address = 1
ORDER BY wd.ALF_PE, row_num;

COMMIT;

-- =========================================================
-- delete all but first person row, i.e. first period of inclusion
-- =========================================================

DELETE FROM sailw0972v.vb_wlgp_sub_cohort_spine
	WHERE pers_row <> 1;

-- *********************************************************
-- UTIs
-- *********************************************************


-- ==========================================================
-- Identify all UTIs during the study period for cohort spine
-- ==========================================================

-- identify all GP UTI diagnoses and treatments for the eligible cohort
-- identify all wrrs urine tests within the study period for the eligible cohort

-- ==========================================================
--create table to identify WLGP UTI event meeting the inclusion criteria
-- ==========================================================

CALL fnc.drop_if_exists('sailw0972v.VB_WLGP_SUB_CONFIRMED');

CREATE TABLE sailw0972v.VB_WLGP_SUB_CONFIRMED
(
	alf_pe						varchar(15),		-- unique person ID
	diag_dt						date,				-- UTI diagnosis date (first out of GP diagnosis Read code, treatment Read code or specimen collected date within 7 days)
	UTI_outcome					varchar(55),		-- UTI outcome (confirmed or no microbiological evidence)
	group_number				integer,			-- UTI group number used to identify separate acute UTIs
	GROUP_SEQUENCE				integer,			-- UTI sequence number used to identify where multiple records occur for a single UTI
	WIMD_2019_QUINTILE_DESC		varchar(30),		-- Welsh index of multiple deprivation quintile 2019
	prior_cvd					integer				-- flag to indicate where relevant prior CVD ICD-10 code was recorded in PEDW prior to uti diagnosis date
)
;

-- ==========================================================
--Identify MI GP diagnosed UTI read codes
-- ==========================================================

CALL fnc.drop_if_exists('SESSION.VB_WLGP_SUB_GP_UTI');

DECLARE GLOBAL TEMPORARY TABLE SESSION.VB_WLGP_SUB_GP_UTI  (
			row_id int NOT NULL GENERATED ALWAYS AS IDENTITY (START WITH 10000, increment BY 1),
			ALF_PE varchar(15),
			ALF_STS_CD integer,
			EVENT_DT date)
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.VB_WLGP_SUB_GP_UTI 
(
alf_pe,
alf_sts_cd,
event_dt
)
SELECT DISTINCT gp.ALF_PE,
				gp.ALF_STS_CD,
				gp.EVENT_DT
	FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
	INNER JOIN sailw0972v.vb_wlgp_sub_cohort_spine AS sp
	ON gp.alf_pe = sp.alf_pe
	AND gp.event_dt BETWEEN sp.MAX_STR_DT AND sp.MIN_END_DT
	AND gp.ALF_STS_CD IN ('1','4','39')
	AND gp.EVENT_CD IN	('1J4..',
						'K190.',
						'1A55.',
						'K15..',
						'1A1..',
						'1AZ6.',
						'1AG..',
						'K1903',
						'K190z',
						'1A45.',
						'K1905',
						'1A44.',
						'1A12.',
						'K101.',
						'K150.',
						'K1973',
						'K10y0',
						'R081.',
						'K155.',
						'K1970',
						'R0842',
						'R0840',
						'R08..',
						'K15z.',
						'R081z',
						'R084.',
						'R0908',
						'K0A2.',
						'K1971',
						'SP07Q',
						'L1668',
						'K152y',
						'K101z',
						'R084z',
						'1A1Z.',
						'K15yz',
						'Kyu51',
						'K152.',
						'K152z')
		AND gp.EVENT_DT BETWEEN '2010-01-01' AND '2020-12-31';

Commit;

-- ==========================================================
--identify MI GP read antibiotics
-- ==========================================================

CALL fnc.drop_if_exists('SESSION.VB_WLGP_SUB_GP_ANTIBIOTIC');

DECLARE GLOBAL TEMPORARY TABLE SESSION.VB_WLGP_SUB_GP_ANTIBIOTIC 
			(ALF_PE VARCHAR(20),
			row_id int NOT NULL GENERATED ALWAYS AS IDENTITY (START WITH 10000, increment BY 1),
			ALF_STS_CD INTEGER,
			EVENT_DT DATE)
ON COMMIT PRESERVE ROWS;

Commit;
		
INSERT INTO SESSION.VB_WLGP_SUB_GP_ANTIBIOTIC (
			ALF_PE,
			ALF_STS_CD,
			EVENT_DT)
	SELECT DISTINCT gp.ALF_PE,
					gp.ALF_STS_CD,
					gp.EVENT_DT
		FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
		INNER JOIN sailw0972v.vb_wlgp_sub_cohort_spine AS sp
		ON 		gp.alf_pe = sp.alf_pe
		AND 	gp.event_dt BETWEEN sp.MAX_STR_DT AND sp.MIN_END_DT
		AND		gp.ALF_STS_CD IN ('1','4','39')
		AND		gp.EVENT_CD IN ('e31B.',
								'e319.',
								'e31a.',
								'e31d.',
								'e31R.',
								'e31i.',
								'e69e.',
								'eg68.',
								'e31v.',
								'e31u.',
								'egA3.',
								'eg17.',
								'eg16.',
								'eccb.',
								'egA1.',
								'ecc3.',
								'e3z5.',
								'e3z6.',
								'e3zo.',
								'e3zk.',
								'e3zm.',
								'e311.',
								'e3zu.',
								'e3zn.',
								'e312.',
								'e3zq.',
								'e315.',
								'e316.',
								'e31k.',
								'e31P.',
								'e31h.',
								'e31T.',
								'e31Y.',
								'e61C.',
								'e615.',
								'e614.',
								'e61D.',
								'e616.',
								'e61a.',
								'e618.',
								'e69..',
								'e695.',
								'e69v.',
								'e691.',
								'e693.',
								'e696.',
								'e69w.',
								'e692.',
								'e694.',
								'e697.',
								'e69f.',
								'e698.',
								'e69a.',
								'e69g.',
								'e699.',
								'e69b.',
								'e69h.',
								'eg6..',
								'eg67.',
								'eg6x.',
								'eg6w.',
								'eg69.',
								'eg6v.',
								'eg61.',
								'eg64.',
								'eg6A.',
								'eg65.',
								'e31Q.',
								'e31z.',
								'e31X.',
								'e612.',
								'e613.',
								'e617.',
								'e619.',
								'ebI..',
								'eg14.',
								'eg13.',
								'eg1C.',
								'eg1B.',
								'e69m.',
								'e69i.',
								'e69k.',
								'e69n.',
								'e69j.',
								'e69l.',
								'eg1A.',
								'eg1x.',
								'eg1..',
								'eg1z.',
								'eg1w.',
								'eg12.',
								'eg1y.',
								'eg11.',
								'e52w.',
								'e521.',
								'ecc..',
								'ecc1.',
								'ecc2.',
								'ecc4.')
			AND gp.EVENT_DT BETWEEN '2010-01-01' AND '2020-12-31';
	
Commit;

-- ==========================================================
--summary TABLE OF WLGP uti substudy cohort results linked TO the request codes OF interest
--Create table linking WLGP uti substudy cohort to WRRS request table
-- ==========================================================

CALL FNC.DROP_IF_EXISTS ('SAILW0972V.VB_WLGP_SUB_WRRS_REQUESTS');

CREATE TABLE SAILW0972V.VB_WLGP_SUB_WRRS_REQUESTS AS (
	SELECT	*
		FROM SAIL0972V.WRRS_OBSERVATION_REQUEST_20211019) WITH NO DATA;

INSERT INTO SAILW0972V.VB_WLGP_SUB_WRRS_REQUESTS
	SELECT	req.*
		FROM SAIL0972V.WRRS_OBSERVATION_REQUEST_20211019 AS req
		INNER JOIN sailw0972v.vb_wlgp_sub_cohort_spine AS sp
			ON 		req.alf_pe = sp.alf_pe
			AND 	req.spcm_collected_dt BETWEEN sp.max_str_dt AND sp.min_end_dt
		RIGHT JOIN (SELECT alf_pe FROM SESSION.VB_WLGP_SUB_GP_UTI
					UNION 
					SELECT alf_pe
					FROM SESSION.VB_WLGP_SUB_GP_ANTIBIOTIC) AS fe
			ON req.ALF_PE = fe.ALF_PE
			WHERE req.SPCM_COLLECTED_DT BETWEEN '2010-01-01' AND '2020-12-31'
			AND req.ALF_STS_CD IN ('1','4','39')
			AND req.NAME IN (	'Urine MC&S',				
								'Urine M+C+S',
								'Urine Microscopy',
								'Urine culture Mid-stream urine',
								'Mid Stream Urine',
								'Midstream Urine',
								'Urine  Urine Culture',
								'Urine M+C+S CMH',
								'Urine Mid-stream',
								'Urine culture Urine - TYPE NOT STATED',
								'Urine Culture',
								'Urine Micro. Cult. & Sens.',
								'Urine  Urine Culture 1',
								'Urine  Urine MCS',
								'Urine Mid Stream',
								'Urine microscopy.',
								'Urine',
								'Urine :',
								'Clean catch urine',
								'URINE',
								'Clean Catch Urine',
								'Urine  Urine Microscopy',
								'urine'
											)
							ORDER BY req.ALF_PE,
									req.SPCM_COLLECTED_DT,
									req.REQUEST_SEQ;
										
-- ==========================================================
--Link WRRS requests to WRRS results, combining tests into agreed groups		
-- ==========================================================

CALL FNC.DROP_IF_EXISTS ('SAILW0972V.VB_WLGP_SUB_WRRS_RESULTS');
							
CREATE TABLE SAILW0972V.VB_WLGP_SUB_WRRS_RESULTS
	(	ALF_PE VARCHAR(20),
		SPCM_COLLECTED_DT DATE,
		REPORT_SEQ INTEGER,
		REQUEST_SEQ INTEGER,
		REQUEST_NAME VARCHAR(55),
		CULTURE VARCHAR(55),
		WEIGHT_OF_GROWTH1 VARCHAR(55),
		WEIGHT_OF_GROWTH2 VARCHAR(55),
		WEIGHT_OF_GROWTH3 VARCHAR(55),
		ORGANISM VARCHAR(55),
		ORGANISM2 VARCHAR(55),
		ORGANISM3 VARCHAR(55),
		RED_BLOOD_CELL_COUNT VARCHAR(100),
		WHITE_BLOOD_CELL_COUNT VARCHAR(100),
		TRIMETHOPRIM VARCHAR(55),
		NITROFURANTOIN VARCHAR(55),
		GENTAMICIN VARCHAR(55),
		AMOXICILLIN VARCHAR(55),
		AMOXICILLIN_CLAVULANATE VARCHAR(55),
		CEPHALEXIN VARCHAR(55));
	
ALTER TABLE SAILW0972V.VB_WLGP_SUB_WRRS_RESULTS activate NOT logged INITIALLY;
				
INSERT INTO SAILW0972V.VB_WLGP_SUB_WRRS_RESULTS
	(	ALF_PE,
		SPCM_COLLECTED_DT,
		REPORT_SEQ,
		REQUEST_SEQ,
		REQUEST_NAME,
		CULTURE,
		WEIGHT_OF_GROWTH1,
		WEIGHT_OF_GROWTH2,
		WEIGHT_OF_GROWTH3,
		ORGANISM,
		ORGANISM2,
		ORGANISM3,
		RED_BLOOD_CELL_COUNT,
		WHITE_BLOOD_CELL_COUNT,
		TRIMETHOPRIM,
		NITROFURANTOIN,
		GENTAMICIN,
		AMOXICILLIN,
		AMOXICILLIN_CLAVULANATE,
		CEPHALEXIN)
SELECT	req.ALF_PE,
		req.SPCM_COLLECTED_DT,
		req.REPORT_SEQ,
		req.REQUEST_SEQ,
		req.NAME AS REQUEST_NAME,
		max(CASE WHEN res.CODE = 'Culture' THEN VAL 
				WHEN res.CODE = 'Urine Culture' THEN VAL 
				WHEN res.CODE = 'CULT' THEN VAL 
				WHEN res.CODE = 'UGR' THEN VAL END),
		max(CASE WHEN res.CODE = 'UVC' THEN VAL END),
		max(CASE WHEN res.CODE = 'UVC2' THEN VAL END),	
		max(CASE WHEN res.CODE = 'UVC3' THEN VAL END),	
		max(CASE WHEN res.CODE = 'ORGANISM' THEN VAL 
				WHEN res.CODE = 'ORG' THEN VAL END),
		max(CASE WHEN res.CODE = 'ORG2' THEN VAL END),
		max(CASE WHEN res.CODE = 'ORG3' THEN VAL END),
		max(CASE WHEN res.CODE = 'URBCR' THEN VAL 
				WHEN res.CODE = 'URBC' THEN VAL END),		
		max(CASE WHEN res.CODE = 'UWBCR' THEN VAL 
				WHEN res.CODE = 'UWBC' THEN VAL END),
		max(CASE WHEN res.CODE = 'TRI' THEN VAL 
				WHEN res.CODE = 'Trimethoprim' THEN VAL END),
		max(CASE WHEN res.CODE = 'NIT' THEN VAL 
				WHEN res.CODE = 'Nitrofurantoin' THEN VAL END),
		max(CASE WHEN res.CODE = 'GEN' THEN VAL END),
		max(CASE WHEN res.CODE = 'AMO' THEN VAL END),		
		max(CASE WHEN res.CODE = 'AUG' THEN VAL END),
		max(CASE WHEN res.CODE = 'CLX' THEN VAL END)
	FROM SAILW0972V.VB_WLGP_SUB_WRRS_REQUESTS AS req
		INNER JOIN SAIL0972V.WRRS_OBSERVATION_RESULT_20211019 AS res
			ON req.ALF_PE = res.ALF_PE
			AND req.REQUEST_SEQ = res.REQUEST_SEQ
			AND req.REPORT_SEQ = res.REPORT_SEQ
			WHERE ((res.CODE LIKE 'TRI' AND res.NAME LIKE 'Trimethoprim')
			OR (res.CODE LIKE 'NIT' AND res.NAME LIKE 'Nitrofurantoin')
			OR (res.CODE LIKE 'ORG2' AND res.NAME LIKE 'Organism 2')
			OR (res.CODE LIKE 'ORG3' AND res.NAME LIKE 'Organism 3')
			OR (res.CODE LIKE 'Culture' AND res.NAME LIKE 'Culture')
			OR (res.CODE LIKE 'URBCR' AND res.NAME LIKE 'Red Blood Cell Count - Urine Range')
			OR (res.CODE LIKE 'GEN' AND res.NAME LIKE 'Gentamicin')
			OR (res.CODE LIKE 'AUG' AND res.NAME LIKE 'Amoxicillin/Clavulanate')
			OR (res.CODE LIKE 'Urine Culture' AND res.NAME LIKE 'Urine Culture')
			OR (res.CODE LIKE 'CULT' AND res.NAME LIKE 'Culture' AND res.VAL NOT LIKE ':')
			OR (res.CODE LIKE 'UWBCR' AND res.NAME LIKE 'White Blood Cell Count - Urine')
			OR (res.CODE LIKE 'CLX' AND res.NAME LIKE 'Cephalexin')
			OR (res.CODE LIKE 'Nitrofurantoin' AND res.NAME LIKE 'Nitrofurantoin')
			OR (res.CODE LIKE 'UVC' AND res.NAME LIKE 'Weight of Growth')
			OR (res.CODE LIKE 'UVC2' AND res.NAME LIKE 'Weight of Growth 2')
			OR (res.CODE LIKE 'UVC3' AND res.NAME LIKE 'Weight of Growth 3')
			OR (res.CODE LIKE 'ORG' AND res.NAME LIKE 'Organism 1')
			OR (res.CODE LIKE 'AMO' AND res.NAME LIKE 'Amoxicillin')
			OR (res.CODE LIKE 'Trimethoprim' AND res.NAME LIKE 'Trimethoprim')
			OR (res.CODE LIKE 'ORGANISM' AND res.NAME LIKE 'ORGANISM')
			OR (res.CODE LIKE 'URBC' AND res.NAME LIKE 'Red blood cells:')
			OR (res.CODE LIKE 'UWBC' AND res.NAME LIKE 'White blood cells:')
			OR (res.CODE LIKE 'UGR' AND res.NAME LIKE 'Viable count:')
			OR (res.CODE LIKE 'UWBC' AND res.NAME LIKE 'Urine WBC')
			OR (res.CODE LIKE 'ORG' AND res.NAME LIKE 'ORGANISM')
			OR (res.CODE LIKE 'UWBC' AND res.NAME LIKE 'Wbc''s'))
			GROUP BY	req.ALF_PE,
						req.SPCM_COLLECTED_DT,
						req.REPORT_SEQ,
						req.REQUEST_SEQ,
						req.NAME
				ORDER BY 	req.ALF_PE,
							req.SPCM_COLLECTED_DT,
							req.REQUEST_SEQ;
						
COMMIT;

-- ==========================================================
--Create WRRS Table with results grouped into agreed UTI result groupings
-- ==========================================================

CALL FNC.DROP_IF_EXISTS ('SAILW0972V.VB_WLGP_SUB_WRRS_RESULTS_AGREED');

CREATE TABLE SAILW0972V.VB_WLGP_SUB_WRRS_RESULTS_AGREED 
(		ALF_PE VARCHAR(20),
		SPCM_COLLECTED_DT DATE,
		REPORT_SEQ INTEGER,
		REQUEST_SEQ INTEGER,
		REQUEST_NAME VARCHAR(55),
		CULTURE VARCHAR(55),
		CULTURE2 VARCHAR(55),
		CULTURE3 VARCHAR(55),
		ORGANISM VARCHAR(55),
		ORGANISM2 VARCHAR(55),
		ORGANISM3 VARCHAR(55),
		RED_BLOOD_CELL_COUNT VARCHAR(100),
		WHITE_BLOOD_CELL_COUNT VARCHAR(100),
		TRIMETHOPRIM VARCHAR(55),
		NITROFURANTOIN VARCHAR(55),
		GENTAMICIN VARCHAR(55),
		AMOXICILLIN VARCHAR(55),
		AMOXICILLIN_CLAVULANATE VARCHAR(55),
		CEPHALEXIN VARCHAR(55));

alter table SAILW0972V.VB_WLGP_SUB_WRRS_RESULTS_AGREED activate not logged INITIALLY;

INSERT INTO SAILW0972V.VB_WLGP_SUB_WRRS_RESULTS_AGREED 
	(ALF_PE,
	SPCM_COLLECTED_DT,
	REPORT_SEQ,
	REQUEST_SEQ,
	REQUEST_NAME,
	CULTURE,
	CULTURE2,
	CULTURE3,
	ORGANISM,
	ORGANISM2,
	ORGANISM3,
	RED_BLOOD_CELL_COUNT,
	WHITE_BLOOD_CELL_COUNT,
	TRIMETHOPRIM,
	NITROFURANTOIN,
	GENTAMICIN,
	AMOXICILLIN,
	AMOXICILLIN_CLAVULANATE,
	CEPHALEXIN)
	SELECT ALF_PE,
		SPCM_COLLECTED_DT,
		REPORT_SEQ,
		REQUEST_SEQ,
		REQUEST_NAME,
		(CASE WHEN (CULTURE = 'Predominant growth of' AND 
							(WEIGHT_OF_GROWTH1 = '10^7 - 10^8' OR WEIGHT_OF_GROWTH1 IS NULL))
					OR (CULTURE IS NULL AND WEIGHT_OF_GROWTH1 = '10^7 - 10^8') THEN 'growth'
			WHEN ((CULTURE IN ('>100,000 orgs/ml',
							'>100,000') AND
							(WEIGHT_OF_GROWTH1 = '>= 10^8' OR WEIGHT_OF_GROWTH1 IS NULL)))
					OR 	(CULTURE = 'Predominant growth of' AND WEIGHT_OF_GROWTH1 = '>= 10^8')
					OR (CULTURE IS NULL AND WEIGHT_OF_GROWTH1 = '>= 10^8') THEN 'growth>10^8'
			WHEN CULTURE IN ('Mixed growth',
							'Mixed growth <10^7 cfu/L',
							'Mixed growth 10^7 - 10^8 cfu/L',
							'Mixed growth including',
							'10,000 Mixed',
							'10,000 Mixed 10,000 Mixed',
							'10-100,000 MIXED',
							'10-100000 MIXED',
							'Mixed growth') AND
							(WEIGHT_OF_GROWTH1 = '10^7 - 10^8' OR WEIGHT_OF_GROWTH1 IS NULL)
					THEN 'mixed growth'
			WHEN CULTURE IN ('Heavy mixed growth.',
							'Mixed growth >=10^8 cfu/L',
							'>100,000 Mixed',
							'>100,000 Mixed >100,000 Mixed',
							'100,000 Mixed growth') AND
							(WEIGHT_OF_GROWTH1 = '>= 10^8' OR WEIGHT_OF_GROWTH1 IS NULL)
				OR 	(CULTURE IN ('Mixed growth',
								'Mixed growth including',
								'Mixed growth') AND 
							(WEIGHT_OF_GROWTH1 = '>= 10^8')) THEN 'mixed growth>10^8'
			WHEN (CULTURE IN ('Negative',
							'No growth',
							'No significant growth',
							'10000',
							'<10,000',
							'<10,000<10,000',
							'No Growth',
							'No GrowthNo Growth',
							'No Growth',
							'No GrowthNo Growth',
							'No significant growth.',
							'Yeasts NOT isolated',
							'No growth after 5 days incubation.',
							'Bacterial pathogens NOT isolated. Yeasts NOT isolated.') AND
							(WEIGHT_OF_GROWTH1 IN ('<10^5','>= 10^6','10^5-10^6','10^6-10^7') OR WEIGHT_OF_GROWTH1 IS NULL))
						OR (CULTURE IS NULL AND WEIGHT_OF_GROWTH1 IN ('<10^5','>= 10^6','10^5-10^6','10^6-10^7')) THEN 'no growth'
			ELSE 'N/A'
				END) AS CULTURE,
		(CASE WHEN (CULTURE = 'Predominant growth of' AND 
							(WEIGHT_OF_GROWTH2 = '10^7 - 10^8'))
					OR (CULTURE IS NULL AND WEIGHT_OF_GROWTH2 = '10^7 - 10^8') THEN 'growth'
			WHEN (CULTURE IN ('>100,000 orgs/ml',
							'>100,000',
							'Predominant growth of') AND
							(WEIGHT_OF_GROWTH2 = '>= 10^8'))
					OR (CULTURE IS NULL AND WEIGHT_OF_GROWTH2 = '>= 10^8') THEN 'growth>10^8'
			WHEN CULTURE IN ('Mixed growth',
							'Mixed growth <10^7 cfu/L',
							'Mixed growth 10^7 - 10^8 cfu/L',
							'Mixed growth including',
							'10,000 Mixed',
							'10,000 Mixed 10,000 Mixed',
							'10-100,000 MIXED',
							'10-100000 MIXED',
							'Mixed growth') AND
							(WEIGHT_OF_GROWTH2 = '10^7 - 10^8') THEN 'mixed growth'
			WHEN CULTURE IN ('Heavy mixed growth.',
							'Mixed growth >=10^8 cfu/L',
							'>100,000 Mixed',
							'>100,000 Mixed >100,000 Mixed',
							'100,000 Mixed growth',
							'Mixed growth',
							'Mixed growth including',
							'Mixed growth') AND
							(WEIGHT_OF_GROWTH2 = '>= 10^8')  THEN 'mixed growth>10^8'
			WHEN (CULTURE IN ('Negative',
							'No growth',
							'No significant growth',
							'10000',
							'<10,000',
							'<10,000<10,000',
							'No Growth',
							'No GrowthNo Growth',
							'No Growth',
							'No GrowthNo Growth',
							'No significant growth.',
							'Yeasts NOT isolated',
							'No growth after 5 days incubation.',
							'Bacterial pathogens NOT isolated. Yeasts NOT isolated.') AND
							(WEIGHT_OF_GROWTH2 IN ('<10^5','>= 10^6','10^5-10^6','10^6-10^7')))
				OR (CULTURE IS NULL AND WEIGHT_OF_GROWTH2 IN ('<10^5','>= 10^6','10^5-10^6','10^6-10^7')) THEN 'no growth'
			ELSE 'N/A'
				END) AS CULTURE2,
		(CASE WHEN (CULTURE = 'Predominant growth of' AND 
							(WEIGHT_OF_GROWTH3 = '10^7 - 10^8'))
				OR (CULTURE IS NULL AND WEIGHT_OF_GROWTH3 = '10^7 - 10^8') THEN 'growth'
			WHEN (CULTURE IN ('>100,000 orgs/ml',
							'>100,000',
							'Predominant growth of') AND
							(WEIGHT_OF_GROWTH3 = '>= 10^8') )
				OR (CULTURE IS NULL AND WEIGHT_OF_GROWTH3 = '>= 10^8') THEN 'growth>10^8'
			WHEN CULTURE IN ('Mixed growth',
							'Mixed growth <10^7 cfu/L',
							'Mixed growth 10^7 - 10^8 cfu/L',
							'Mixed growth including',
							'10,000 Mixed',
							'10,000 Mixed 10,000 Mixed',
							'10-100,000 MIXED',
							'10-100000 MIXED',
							'Mixed growth') AND
							(WEIGHT_OF_GROWTH3 = '10^7 - 10^8') THEN 'mixed growth'
			WHEN CULTURE IN ('Heavy mixed growth.',
							'Mixed growth >=10^8 cfu/L',
							'>100,000 Mixed',
							'>100,000 Mixed >100,000 Mixed',
							'100,000 Mixed growth',
							'Mixed growth',
							'Mixed growth including',
							'Mixed growth') AND
							(WEIGHT_OF_GROWTH3 = '>= 10^8') THEN 'mixed growth>10^8'
			WHEN (CULTURE IN ('Negative',
							'No growth',
							'No significant growth',
							'10000',
							'<10,000',
							'<10,000<10,000',
							'No Growth',
							'No GrowthNo Growth',
							'No Growth',
							'No GrowthNo Growth',
							'No significant growth.',
							'Yeasts NOT isolated',
							'No growth after 5 days incubation.',
							'Bacterial pathogens NOT isolated. Yeasts NOT isolated.') AND
							(WEIGHT_OF_GROWTH3 IN ('<10^5','>= 10^6','10^5-10^6','10^6-10^7')))
				OR (CULTURE IS NULL AND WEIGHT_OF_GROWTH3 IN ('<10^5','>= 10^6','10^5-10^6','10^6-10^7')) THEN 'no growth'
			ELSE 'N/A'
				END) AS CULTURE3,
		(CASE WHEN ORGANISM IN ('Candida albicans',
								'Candida species',
								'Candida albicans ({abbr})',
								'Candida sp ({abbr})',
								'Yeast ({abbr})',
								'Candida albicans',
								'Candida sp') THEN 'candida'
				WHEN ORGANISM IN ('Coliform',
								'Coliform - KESC group (KESC)',
								'Coliform ({abbr})',
								'Mixed coliforms ({abbr})',
								'Coliform bacilli') THEN 'coliform'
				WHEN ORGANISM IN ('Escherichia coli',
								'Escherichia coli ({abbr})',
								'Escherichia coli',
								'Escherichia coli (2)') THEN 'ecoli'
				WHEN ORGANISM IN ('Enterococcus species',
								'Enterococcus faecalis ({abbr})',
								'Enterococcus sp ({abbr})',
								'Enterococcus species') THEN 'enterococcus'
				WHEN ORGANISM IN ('Klebsiella pneumoniae',
								'Klebsiella pneumoniae ({abbr})',
								'Klebsiella pneumoniae') THEN 'klebsiella'
				WHEN ORGANISM IN ('No Growth.',
								'No significant growth') THEN 'no growth'
				WHEN ORGANISM IN ('Proteus species',
								'Proteus mirabilis ({abbr})',
								'Proteus sp ({abbr})') THEN 'proteus'
				WHEN ORGANISM IN ('Pseudomonas aeruginosa',
								'Pseudomonas species',
								'Pseudomonas aeruginosa ({abbr})',
								'Pseudomonas sp ({abbr})',
								'Pseudomonas aeruginosa') THEN 'pseudomonas'
				WHEN ORGANISM IN ('Staphylococcus aureus',
								'Staphylococcus aureus ({abbr})',
								'Staphylococcus aureus') THEN 'saureus'
				WHEN ORGANISM IN ('Staphylococcus coagulase negative ({abbr})',
								'Coag Negative Staphylococcus',
								'Staphylococcus Coagulase Negative') THEN 'staphcoagneg'
				WHEN ORGANISM IN ('Streptococcus agalactiae group B ({abbr})',
								'Streptococcus group A ({abbr})',
								'Streptococcus group B ({abbr})',
								'Beta-haemolytic Streptococcus') THEN 'strep'
			ELSE 'N/A'
				END) AS ORGANISM,
		(CASE WHEN ORGANISM2 IN ('Candida albicans ({abbr})',
								'Candida sp ({abbr})',
								'Yeast ({abbr})') THEN 'candida'
				WHEN ORGANISM2 IN ('Coliform - KESC group (KESC)',
									'Coliform ({abbr})',
									'Mixed coliforms ({abbr})') THEN 'coliform'
				WHEN ORGANISM2 = 'Escherichia coli ({abbr})' THEN 'ecoli'
				WHEN ORGANISM2 IN ('Enterococcus faecalis ({abbr})',
									'Enterococcus sp ({abbr})') THEN 'enterococcus'
				WHEN ORGANISM2 = 'Klebsiella pneumoniae ({abbr})' THEN 'klebsiella'
				WHEN ORGANISM2 IN ('Proteus mirabilis ({abbr})',
									'Proteus sp ({abbr})') THEN 'proteus'
				WHEN ORGANISM2 IN (	'Pseudomonas aeruginosa ({abbr})',
									'Pseudomonas sp ({abbr})') THEN 'pseudomonas'
				WHEN ORGANISM2 = 'Staphylococcus aureus ({abbr})' THEN 'saureus'
				WHEN ORGANISM2 = 'Staphylococcus coagulase negative ({abbr})' THEN 'staphcoagneg'
				WHEN ORGANISM2 IN (	'Streptococcus agalactiae group B ({abbr})',
									'Streptococcus group B ({abbr})') THEN 'strep'
			ELSE 'N/A'
				END) AS ORGANISM2,
		(CASE WHEN ORGANISM3 IN ('Candida albicans ({abbr})',
								'Candida sp ({abbr})',
								'Yeast ({abbr})') THEN 'candida'
				WHEN ORGANISM3 IN ('Coliform - KESC group (KESC)',
									'Coliform ({abbr})',
									'Mixed coliforms ({abbr})') THEN 'coliform'
				WHEN ORGANISM3 = 'Escherichia coli ({abbr})' THEN 'ecoli'
				WHEN ORGANISM3 IN ('Enterococcus faecalis ({abbr})',
									'Enterococcus sp ({abbr})') THEN 'enterococcus'
				WHEN ORGANISM3 = 'Klebsiella pneumoniae ({abbr})' THEN 'klebsiella'
				WHEN ORGANISM3 IN ('Proteus mirabilis ({abbr})',
									'Proteus sp ({abbr})') THEN 'proteus'
				WHEN ORGANISM3 IN (	'Pseudomonas aeruginosa ({abbr})',
									'Pseudomonas sp ({abbr})') THEN 'pseudomonas'
				WHEN ORGANISM3 = 'Staphylococcus aureus ({abbr})' THEN 'saureus'
				WHEN ORGANISM3 = 'Staphylococcus coagulase negative ({abbr})' THEN 'staphcoagneg'
				WHEN ORGANISM3 IN (	'Streptococcus agalactiae group B ({abbr})',
									'Streptococcus group B ({abbr})') THEN 'strep'
			ELSE 'N/A'
				END) AS ORGANISM3,
		(CASE WHEN RED_BLOOD_CELL_COUNT IN ('1',
														'2',
														'3',
														'4',
														'5',
														'6',
														'7',
														'8',
														'9',
														'10',
														'11',
														'12',
														'13',
														'14',
														'15',
														'16',
														'17',
														'18',
														'19',
														'20',
														'21',
														'22',
														'23',
														'24',
														'25',
														'26',
														'27',
														'28',
														'29',
														'30',
														'31',
														'32',
														'33',
														'34',
														'35',
														'36',
														'37',
														'38',
														'39',
														'40',
														'41',
														'42',
														'43',
														'44',
														'<1',
														'<5   x10^6/L',
														'5-99  x10^6/L') THEN '<100'
				WHEN RED_BLOOD_CELL_COUNT = '>=100 x10^6/L' THEN '>100'
			ELSE 'N/A'
				END) AS RED_BLOOD_CELL_COUNT,
			(CASE WHEN WHITE_BLOOD_CELL_COUNT IN ('Greater than 20 White Blood Cells per cubic millimetre',
														'Less than 10 White Blood Cells per cubic millimetre',
														'<10   x10^6/L',
														'10-99 x10^6/L') THEN '<10^8'
				WHEN WHITE_BLOOD_CELL_COUNT = '>=100 x10^6/L' THEN '>10^8'
			ELSE 'N/A'
				END) AS WHITE_BLOOD_CELL_COUNT,
	TRIMETHOPRIM,
	NITROFURANTOIN,
	GENTAMICIN,
	AMOXICILLIN,
	AMOXICILLIN_CLAVULANATE,
	CEPHALEXIN
		FROM SAILW0972V.VB_WLGP_SUB_WRRS_RESULTS;
	
COMMIT;

ALTER TABLE SAILW0972V.VB_WLGP_SUB_WRRS_RESULTS_AGREED
	ADD COLUMN ORGANISM_COUNT VARCHAR(10);

UPDATE SAILW0972V.VB_WLGP_SUB_WRRS_RESULTS_AGREED
	SET ORGANISM_COUNT = CASE WHEN (CULTURE <> 'N/A'-----------------------------CULTURE has values not candida
									AND ORGANISM <> 'N/A'
									AND ORGANISM <> 'candida')
									AND ((CULTURE2 <> 'N/A' ----------------------CULTURE2 has values not candida
										AND ORGANISM2 <> 'N/A'
										AND ORGANISM2 <> 'candida'
										AND CULTURE3 = 'N/A'----------------------CULTURE3 does not have values
										AND (ORGANISM3 = 'N/A'
										OR ORGANISM3 = 'candida'))
										OR (CULTURE3 <> 'N/A'
										AND ORGANISM3 <> 'N/A'
										AND ORGANISM3 <> 'candida'
										AND CULTURE2 = 'N/A'
										AND (ORGANISM2 = 'N/A'
										OR ORGANISM2 = 'candida')))
								THEN '2 Orgs'
							WHEN  (CULTURE2 <> 'N/A'-----------------------------CULTURE2 has values
									AND ORGANISM2 <> 'N/A'
									AND ORGANISM2 <> 'candida')
									AND ((CULTURE3 <> 'N/A' ----------------------CULTURE3 has values not candida
										AND ORGANISM3 <> 'N/A'
										AND ORGANISM3 <> 'candida'
										AND CULTURE = 'N/A'----------------------CULTURE does not have values 
										AND (ORGANISM = 'N/A'
										OR ORGANISM = 'candida'))
										OR (CULTURE <> 'N/A'
										AND ORGANISM <> 'N/A'
										AND ORGANISM <> 'candida'
										AND CULTURE3 = 'N/A'
										AND (ORGANISM3 = 'N/A'
										OR ORGANISM3 = 'candida')))
								THEN '2 Orgs'
							WHEN ((CULTURE <> 'N/A' -----------------------------When all organism and culture fields have a value but more than one organism value is candida
								AND ORGANISM <> 'N/A'
								AND CULTURE2 <> 'N/A'
								AND ORGANISM2 <> 'N/A'
								AND CULTURE3 <> 'N/A'
								AND ORGANISM3 <> 'N/A')
									AND ((ORGANISM = 'candida'
										AND ORGANISM2 = 'candida')
									OR (ORGANISM = 'candida'
										AND ORGANISM3 = 'candida')
									OR (ORGANISM2 = 'candida'
										AND ORGANISM3 = 'candida')))
								THEN NULL
							WHEN ((CULTURE <> 'N/A' -----------------------------When all organism and culture fields have a value and one or none is candida
								AND ORGANISM <> 'N/A'
								AND CULTURE2 <> 'N/A'
								AND ORGANISM2 <> 'N/A'
								AND CULTURE3 <> 'N/A'
								AND ORGANISM3 <> 'N/A')
									AND (ORGANISM = 'candida'
									OR ORGANISM = 'candida'
									OR ORGANISM2 = 'candida'))
								THEN '2 Orgs'
						END;	
					
ALTER TABLE SAILW0972V.VB_WLGP_SUB_WRRS_RESULTS_AGREED
	ADD COLUMN UTI_OUTCOME VARCHAR(50);
					
UPDATE SAILW0972V.VB_WLGP_SUB_WRRS_RESULTS_AGREED
	SET UTI_OUTCOME = CASE WHEN (CULTURE = 'no growth' -------------------No Growth. When one culture value is no growth and all others are no growth or N/A
								AND (CULTURE2 = 'no growth'
									OR CULTURE2 = 'N/A')
								AND (CULTURE3 = 'no growth'
									OR CULTURE3 = 'N/A'))
							OR (CULTURE2 = 'no growth'
								AND (CULTURE3 = 'no growth'
									OR CULTURE3 = 'N/A')
								AND (CULTURE = 'no growth'
									OR CULTURE = 'N/A'))
							OR (CULTURE3 = 'no growth'
								AND (CULTURE = 'no growth'
									OR CULTURE = 'N/A')
								AND (CULTURE2 = 'no growth'
									OR CULTURE2 = 'N/A'))
						THEN 'No microbiological evidence of UTI'
					WHEN ((CULTURE = 'mixed growth>10^8' ----------------Heavy Mixed Growth (not candida)
								OR CULTURE2 = 'mixed growth>10^8'
								OR CULTURE3 = 'mixed growth>10^8')
							AND (ORGANISM <> 'candida'
								OR ORGANISM <> 'N/A')
							AND (ORGANISM2 <> 'candida'
								OR ORGANISM2 <> 'N/A')
							AND (ORGANISM3 <> 'candida'
								OR ORGANISM3 <> 'N/A'))
						THEN 'Heavy mixed growth'
					WHEN (ORGANISM <> 'N/A'
							AND ORGANISM <> 'candida'----------------Heavy Mixed Growth based on 3 organisms (not candida)
							AND CULTURE <> 'N/A'
							AND ORGANISM2 <> 'N/A'
							AND ORGANISM2 <> 'candida'
							AND CULTURE2 <> 'N/A'
							AND ORGANISM3 <> 'N/A'
							AND ORGANISM3 <> 'candida'
							AND CULTURE3 <> 'N/A')
						AND (CULTURE = 'growth>10^8'
							OR CULTURE2 = 'growth>10^8'
							OR CULTURE3 = 'growth>10^8')
						THEN 'Heavy mixed growth'
					WHEN ((CULTURE = 'mixed growth' ----------------Mixed Growth (not candida)
								OR CULTURE2 = 'mixed growth'
								OR CULTURE3 = 'mixed growth')
							AND (ORGANISM <> 'candida'
								OR ORGANISM <> 'N/A')
							AND (ORGANISM2 <> 'candida'
								OR ORGANISM2 <> 'N/A')
							AND (ORGANISM3 <> 'candida'
								OR ORGANISM3 <> 'N/A'))
						THEN 'Mixed growth'
					WHEN (ORGANISM <> 'N/A'
							AND ORGANISM <> 'candida'----------------Mixed Growth based on 3 organisms (not candida)
							AND CULTURE <> 'N/A'
							AND ORGANISM2 <> 'N/A'
							AND ORGANISM2 <> 'candida'
							AND CULTURE2 <> 'N/A'
							AND ORGANISM3 <> 'N/A'
							AND ORGANISM3 <> 'candida'
							AND CULTURE3 <> 'N/A')
						AND (CULTURE = 'growth'
							OR CULTURE2 = 'growth'
							OR CULTURE3 = 'growth')
						THEN 'Mixed growth'
					WHEN ((CULTURE = 'growth>10^8' ---------------Confirmed UTI, Organism not candida, growth >10^8 and WBC >10^8
								AND ORGANISM <> 'N/A'
								AND ORGANISM <> 'candida')
							OR (CULTURE2 = 'growth>10^8'
								AND ORGANISM2 <> 'N/A'
								AND ORGANISM2 <> 'candida')
							OR (CULTURE3 = 'growth>10^8'
								AND ORGANISM3 <> 'N/A'
								AND ORGANISM3 <> 'candida'))
							AND WHITE_BLOOD_CELL_COUNT = '>10^8'
						THEN 'Confirmed UTI'
					WHEN ((CULTURE = 'growth' ---------------Possible UTI, Organism not candida, growth >10^7
								AND ORGANISM <> 'N/A'
								AND ORGANISM <> 'candida')
							OR (CULTURE2 = 'growth'
								AND ORGANISM2 <> 'N/A'
								AND ORGANISM2 <> 'candida')
							OR (CULTURE3 = 'growth'
								AND ORGANISM3 <> 'N/A'
								AND ORGANISM3 <> 'candida'))
						THEN 'Possible UTI'
					WHEN ((CULTURE = 'growth>10^8' ---------------Possible UTI, Growth>10^8 WBC <10^8 or WBC NULL
								AND ORGANISM <> 'N/A'
								AND ORGANISM <> 'candida')
							OR (CULTURE2 = 'growth>10^8'
								AND ORGANISM2 <> 'N/A'
								AND ORGANISM2 <> 'candida')
							OR (CULTURE3 = 'growth>10^8'
								AND ORGANISM3 <> 'N/A'
								AND ORGANISM3 <> 'candida'))
							AND (WHITE_BLOOD_CELL_COUNT = '<10^8'
								OR WHITE_BLOOD_CELL_COUNT = 'N/A')
						THEN 'Possible UTI'
					WHEN ((CULTURE = 'growth' ---------------Possible UTI, Growth WBC <10^8 or WBC NULL
								AND ORGANISM <> 'N/A'
								AND ORGANISM <> 'candida')
							OR (CULTURE2 = 'growth'
								AND ORGANISM2 <> 'N/A'
								AND ORGANISM2 <> 'candida')
							OR (CULTURE3 = 'growth'
								AND ORGANISM3 <> 'N/A'
								AND ORGANISM3 <> 'candida'))
							AND (WHITE_BLOOD_CELL_COUNT = '<10^8'
								OR WHITE_BLOOD_CELL_COUNT = 'N/A')
						THEN 'Possible UTI'
					WHEN (CULTURE = 'N/A' --------------------All culture NULL
								AND CULTURE2 = 'N/A'
								AND CULTURE3 = 'N/A')
						THEN 'Exclude NULL culture'
					WHEN (ORGANISM = 'N/A' -----------------------All organism NULL
								AND ORGANISM2 = 'N/A'
								AND ORGANISM3 = 'N/A')
						THEN 'Possible UTI'
					WHEN (ORGANISM = 'candida' -------------------Any organism candida
							AND (ORGANISM2 = 'N/A'
							OR ORGANISM2 = 'candida')
							AND (ORGANISM3 = 'N/A'
							OR ORGANISM3 = 'candida')
								OR (ORGANISM2 = 'candida'
									AND (ORGANISM = 'N/A'
									OR ORGANISM = 'candida')
									AND (ORGANISM3 = 'N/A'
									OR ORGANISM3 = 'candida'))
								OR (ORGANISM3 = 'candida'
									AND (ORGANISM = 'N/A'
									OR ORGANISM = 'candida')
									AND (ORGANISM2 = 'N/A'
									OR ORGANISM2 = 'candida')))
						THEN 'No microbiological evidence of UTI'
					WHEN (((CULTURE = 'growth'
							OR CULTURE = 'growth>10^8')
							AND ORGANISM <> 'candida')
						OR ((CULTURE2 = 'growth'
							OR CULTURE2 = 'growth>10^8')
							AND ORGANISM2 <> 'candida')
						OR ((CULTURE3 = 'growth'
							OR CULTURE3 = 'growth>10^8')
							AND ORGANISM3 <> 'candida'))
						THEN 'Possible UTI'
					ELSE 'No microbiological evidence of UTI'
				END;
			
ALTER TABLE SAILW0972V.VB_WLGP_SUB_WRRS_RESULTS_AGREED
	ADD COLUMN DIAG_ORGANISM VARCHAR(20);

UPDATE SAILW0972V.VB_WLGP_SUB_WRRS_RESULTS_AGREED
	SET DIAG_ORGANISM = CASE WHEN ORGANISM_COUNT IS NULL
							AND (UTI_OUTCOME = 'Possible UTI'
								OR UTI_OUTCOME = 'Confirmed UTI')
							THEN CASE WHEN ORGANISM <> 'N/A'
										AND ORGANISM <> 'candida'
										AND CULTURE <> 'N/A'
										THEN ORGANISM
									WHEN ORGANISM2 <> 'N/A'
										AND ORGANISM2 <> 'candida'
										AND CULTURE2 <> 'N/A'
										THEN ORGANISM2
									ELSE ORGANISM3
								END
							WHEN ORGANISM_COUNT IS NOT NULL
								AND (UTI_OUTCOME = 'Possible UTI'
								OR UTI_OUTCOME = 'Confirmed UTI')
								THEN CASE WHEN ORGANISM = ORGANISM2
										AND ORGANISM3 = 'N/A'
										THEN ORGANISM
									WHEN ORGANISM2 = ORGANISM3
										AND ORGANISM = 'N/A'
										THEN ORGANISM2
									WHEN ORGANISM = ORGANISM3
										AND ORGANISM2 = 'N/A'
										THEN ORGANISM
								ELSE '>1 Organism'
							END
						END;
					
-- ============================================
-- identify WLGP sub WRRS all UTI events regardless of outcome
-- ============================================

CALL fnc.drop_if_exists('SESSION.VB_WLGP_SUB_WRRS_ALL');

DECLARE GLOBAL TEMPORARY TABLE SESSION.VB_WLGP_SUB_WRRS_ALL
	(ALF_PE VARCHAR(20),
	SPCM_COLLECTED_DT date,
	WRRS_MAX_DT date,
	WRRS_MIN_DT date,
	UTI_OUTCOME VARCHAR(50))
ON COMMIT PRESERVE ROWS;

COMMIT;

INSERT INTO SESSION.VB_WLGP_SUB_WRRS_ALL
	SELECT 	wrrs.ALF_PE,
			wrrs.SPCM_COLLECTED_DT,
			ADD_DAYS(wrrs.SPCM_COLLECTED_DT, 6) AS WRRS_MAX_DT,
			ADD_DAYS(wrrs.SPCM_COLLECTED_DT, -6) AS WRRS_MIN_DT,
			wrrs.UTI_OUTCOME 
		FROM SAILW0972V.VB_WLGP_SUB_WRRS_RESULTS_AGREED AS wrrs
			WHERE uti_outcome <> 'Exclude NULL culture';
		
COMMIT;

-- ============================================
-- Identify the earliest out of the gp, antibiotic and wrrs dates within 7 day window
-- ============================================

CALL fnc.drop_if_exists('SAILW0972V.VB_WLGP_SUB_ALL_UTI_DIAG');

CREATE TABLE SAILW0972V.VB_WLGP_SUB_ALL_UTI_DIAG
	(ALF_PE VARCHAR(20),
	DIAG_ID integer,
	ABX_ID integer,
	DIAG_DT DATE,
	uti_end date,
	uti_outcome varchar(50),
	outcome_int integer);

INSERT INTO SAILW0972V.VB_WLGP_SUB_ALL_UTI_DIAG
	(ALF_PE,
	diag_id,
	abx_id,
	DIAG_DT,
	uti_end,
	UTI_OUTCOME,
	outcome_int)
WITH CTE AS 
(SELECT wrrs.ALF_PE,
		wrrs.SPCM_COLLECTED_DT,
		wrrs.uti_outcome,
		anti.EVENT_DT AS ANTI_DT,
		gp.row_id AS diag_id,
		anti.row_id AS abx_id,
		gp.EVENT_DT AS GP_DT
		FROM SESSION.VB_WLGP_SUB_WRRS_ALL AS wrrs
	LEFT JOIN SESSION.VB_WLGP_SUB_GP_ANTIBIOTIC AS anti
		ON wrrs.ALF_PE = anti.ALF_PE
	LEFT JOIN SESSION.VB_WLGP_SUB_GP_UTI AS gp
		ON wrrs.ALF_PE = gp.ALF_PE
		WHERE anti.EVENT_DT BETWEEN wrrs.WRRS_MIN_DT AND wrrs.WRRS_MAX_DT
		AND gp.EVENT_DT BETWEEN wrrs.WRRS_MIN_DT AND wrrs.WRRS_MAX_DT)
	SELECT ALF_PE,
			diag_id,
			abx_id,
			min(SPCM_COLLECTED_DT,ANTI_DT,GP_DT) AS DIAG_DT,
			max(SPCM_COLLECTED_DT,ANTI_DT,GP_DT) AS uti_end,
			uti_outcome,
			CASE WHEN uti_outcome = 'Confirmed UTI'
					THEN 1
				WHEN uti_outcome = 'Possible UTI'
					THEN 2
				WHEN uti_outcome = 'Heavy mixed growth'
					THEN 3
				WHEN uti_outcome = 'Mixed growth'
					THEN 4
				WHEN uti_outcome = 'No microbiological evidence of UTI'
					THEN 5
				ELSE null
				end
			FROM CTE
		ORDER BY alf_pe, diag_dt;
	
-- ============================================
--  assign UTI group and sequence broken into smaller chunks
-- ============================================

CALL fnc.drop_if_exists('SESSION.VB_WLGP_SUB_UTI_GROUP');

DECLARE GLOBAL TEMPORARY TABLE SESSION.VB_WLGP_SUB_UTI_GROUP
(alf_pe varchar(15),
diag_dt date,
uti_end date,
uti_outcome varchar(50),
outcome_int integer,
rn integer,
new_group integer)
ON COMMIT PRESERVE rows;

COMMIT;
	
INSERT INTO SESSION.VB_WLGP_SUB_UTI_GROUP
SELECT uti.alf_pe,
		uti.diag_dt,
		uti.uti_end,
		uti_outcome,
		outcome_int,
		ROW_NUMBER() OVER (PARTITION BY uti.alf_pe ORDER BY diag_dt) AS Rn, 
       CASE WHEN LAG(uti.diag_dt,1) OVER (PARTITION BY uti.alf_pe ORDER BY uti.diag_dt, uti.uti_end, outcome_int desc) IS NULL OR 
                 LAG(uti.uti_end,1) OVER (PARTITION BY uti.alf_pe ORDER BY uti.diag_dt, uti.uti_end, outcome_int desc) < uti.diag_dt -28 DAYS THEN 1 
            ELSE 0 
        END AS new_group
  FROM SAILW0972V.VB_WLGP_SUB_ALL_UTI_DIAG AS uti
 ORDER BY alf_pe, diag_dt;

COMMIT;

-- ============================================
-- add previous UTI info
-- ============================================

CALL fnc.drop_if_exists('SESSION.VB_WLGP_SUB_UTI_LAG');

DECLARE GLOBAL TEMPORARY TABLE SESSION.VB_WLGP_SUB_UTI_LAG
(alf_pe varchar(15),
diag_dt date,
uti_end date,
uti_outcome varchar(50),
outcome_int integer,
rn integer,
new_group integer,
lag_rn integer,
lag_alf varchar(15),
lag_group integer)
ON COMMIT PRESERVE rows;

COMMIT;

INSERT INTO SESSION.VB_WLGP_SUB_UTI_LAG
SELECT mqo.*,
 		lag(Rn) OVER (PARTITION BY alf_pe ORDER BY Rn) AS lag_rn,
		lag(alf_pe) OVER (PARTITION BY alf_pe ORDER BY alf_pe) AS lag_alf,
		lag(new_group) OVER (PARTITION BY alf_pe ORDER BY Rn) AS lag_group
	FROM SESSION.VB_WLGP_SUB_UTI_GROUP AS mqo
	ORDER BY alf_pe, diag_dt, uti_end, outcome_int DESC;

COMMIT;

-- ============================================
-- create combined sequence table
-- ============================================

CALL fnc.drop_if_exists('sailw0972v.VB_WLGP_SUB_UTI_COMBINED');

CREATE TABLE sailw0972v.VB_WLGP_SUB_UTI_COMBINED
(alf_pe varchar(15),
diag_dt date,
uti_end date,
uti_outcome varchar (50),
outcome_int integer,
group_number integer,
group_sequence integer
);

ALTER TABLE sailw0972v.VB_WLGP_SUB_UTI_COMBINED activate NOT logged INITIALLY;

INSERT INTO sailw0972v.VB_WLGP_SUB_UTI_COMBINED
with cte3 (alf_pe, diag_dt, uti_end, uti_outcome, outcome_int, Rn, group_number, group_sequence) as
(SELECT alf_pe,
		diag_dt,
		uti_end,
		uti_outcome,
		outcome_int,
		Rn,
		ROW_NUMBER() OVER (PARTITION BY alf_pe ORDER BY Rn) AS group_number,
		1 AS group_sequence
  FROM SESSION.VB_WLGP_SUB_UTI_LAG
  		WHERE (ALF_PE LIKE ('%0')
  				OR ALF_PE LIKE ('%1')
  				OR ALF_PE LIKE ('%2')) 
 		AND new_group =  1
UNION ALL
SELECT a.alf_pe,
		b.diag_dt,
		b.uti_end,
		b.uti_outcome,
		b.outcome_int,
		b.Rn,
		a.group_number,
		a.group_sequence + 1
  FROM cte3 AS a,
  		SESSION.VB_WLGP_SUB_UTI_GROUP AS b
  	WHERE 	a.alf_pe = b.alf_pe
  	AND 	a.Rn = b.Rn - 1
  	AND 	b.new_group = 0
  	AND		(b.ALF_PE LIKE ('%0')
  				OR b.ALF_PE LIKE ('%1')
  				OR b.ALF_PE LIKE ('%2')) 
)
SELECT alf_pe, diag_dt, uti_end, uti_outcome, outcome_int, group_number, group_sequence
  FROM cte3
 ORDER BY alf_pe, group_number, group_sequence;

COMMIT;

ALTER TABLE sailw0972v.VB_WLGP_SUB_UTI_COMBINED activate NOT logged INITIALLY;

INSERT INTO sailw0972v.VB_WLGP_SUB_UTI_COMBINED
with cte3 (alf_pe, diag_dt, uti_end, uti_outcome, outcome_int, Rn, group_number, group_sequence) as
(SELECT alf_pe,
		diag_dt,
		uti_end,
		uti_outcome,
		outcome_int,
		Rn,
		ROW_NUMBER() OVER (PARTITION BY alf_pe ORDER BY Rn) AS group_number,
		1 AS group_sequence
  FROM SESSION.VB_WLGP_SUB_UTI_LAG
  		WHERE (ALF_PE LIKE ('%3')
  				OR ALF_PE LIKE ('%4')
  				OR ALF_PE LIKE ('%5')) 
 		AND new_group =  1
UNION ALL
SELECT a.alf_pe,
		b.diag_dt,
		b.uti_end,
		b.uti_outcome,
		b.outcome_int,
		b.Rn,
		a.group_number,
		a.group_sequence + 1
  FROM cte3 AS a,
  		SESSION.VB_WLGP_SUB_UTI_GROUP AS b
  	WHERE 	a.alf_pe = b.alf_pe
  	AND 	a.Rn = b.Rn - 1
  	AND 	b.new_group = 0
  	AND		(b.ALF_PE LIKE ('%3')
  				OR b.ALF_PE LIKE ('%4')
  				OR b.ALF_PE LIKE ('%5')) 
)
SELECT alf_pe, diag_dt, uti_end, uti_outcome, outcome_int, group_number, group_sequence
  FROM cte3
 ORDER BY alf_pe, group_number, group_sequence;

COMMIT;

ALTER TABLE sailw0972v.VB_WLGP_SUB_UTI_COMBINED activate NOT logged INITIALLY;

INSERT INTO sailw0972v.VB_WLGP_SUB_UTI_COMBINED
with cte3 (alf_pe, diag_dt, uti_end, uti_outcome, outcome_int, Rn, group_number, group_sequence) as
(SELECT alf_pe,
		diag_dt,
		uti_end,
		uti_outcome,
		outcome_int,
		Rn,
		ROW_NUMBER() OVER (PARTITION BY alf_pe ORDER BY Rn) AS group_number,
		1 AS group_sequence
  FROM SESSION.VB_WLGP_SUB_UTI_LAG
  		WHERE (ALF_PE LIKE ('%6')
  				OR ALF_PE LIKE ('%7')
  				OR ALF_PE LIKE ('%8')
  				OR ALF_PE LIKE ('%9')) 
 		AND new_group =  1
UNION ALL
SELECT a.alf_pe,
		b.diag_dt,
		b.uti_end,
		b.uti_outcome,
		b.outcome_int,
		b.Rn,
		a.group_number,
		a.group_sequence + 1
  FROM cte3 AS a,
  		SESSION.VB_WLGP_SUB_UTI_GROUP AS b
  	WHERE 	a.alf_pe = b.alf_pe
  	AND 	a.Rn = b.Rn - 1
  	AND 	b.new_group = 0
  	AND		(b.ALF_PE LIKE ('%6')
  				OR b.ALF_PE LIKE ('%7')
  				OR b.ALF_PE LIKE ('%8')
  				OR b.ALF_PE LIKE ('%9')) 
)
SELECT alf_pe, diag_dt, uti_end, uti_outcome, outcome_int, group_number, group_sequence
  FROM cte3
 ORDER BY alf_pe, group_number, group_sequence;

COMMIT;

-- ============================================
-- populate UTI table table with first UTI in group with a confirmed UTI
-- ============================================

INSERT INTO sailw0972v.VB_WLGP_SUB_CONFIRMED
(
	alf_pe,
	diag_dt,
	UTI_outcome,
	group_number,
	GROUP_SEQUENCE
)
WITH cte as
(SELECT alf_pe,
		diag_dt,
		UTI_outcome,
		group_number,
		GROUP_SEQUENCE
		FROM sailw0972v.VB_WLGP_SUB_UTI_COMBINED
WHERE uti_outcome = 'Confirmed UTI'
ORDER BY alf_pe, DIAG_DT),
cte2 AS
(SELECT alf_pe,
		group_number,
		min(GROUP_SEQUENCE) AS GROUP_SEQUENCE
FROM sailw0972v.VB_WLGP_SUB_UTI_COMBINED
	GROUP BY alf_pe, group_number)
SELECT cte.* FROM cte
	INNER JOIN cte2
	ON cte.alf_pe = cte2.alf_pe
	AND cte.group_number = cte2.group_number
	AND cte.group_sequence = cte2.group_sequence
ORDER BY alf_pe, diag_dt
;

-- ============================================
-- add no microbiologically confirmed UTI
-- ============================================

INSERT INTO sailw0972v.VB_WLGP_SUB_CONFIRMED
(
	alf_pe,
	diag_dt,
	UTI_outcome,
	group_number,
	GROUP_SEQUENCE
)
WITH cte AS --find highest outcome in a linked UTI sequence
(
	SELECT alf_pe,
			group_number,
			min(outcome_int) AS highest_outcome
		FROM sailw0972v.VB_WLGP_SUB_UTI_COMBINED
		GROUP BY alf_pe, group_number
),
cte2 AS --find only those linked sequences without confirmed or possible UTIs
(
	SELECT * 
		FROM cte 
		WHERE highest_outcome > 2
),
cte3 AS -- minimum diagnosis date for no micro UTI
(
	SELECT alf_pe,
			group_number,
			min(diag_dt) AS diag_dt
		FROM sailw0972v.VB_WLGP_SUB_UTI_COMBINED
		WHERE outcome_int = 5
		GROUP BY alf_pe,
				group_number
)
SELECT DISTINCT 
		cte2.alf_pe,
		cte3.diag_dt,
		uti.UTI_outcome,
		cte2.group_number,
		min(uti.GROUP_SEQUENCE)
	FROM sailw0972v.VB_WLGP_SUB_UTI_COMBINED AS uti
	INNER JOIN cte2
		ON uti.alf_pe = cte2.alf_pe
		AND uti.group_number = cte2.group_number
	INNER JOIN cte3
		ON uti.alf_pe = cte3.alf_pe
		AND uti.diag_dt = cte3.diag_dt
		AND cte2.group_number = cte3.group_number
	WHERE uti.outcome_int = 5
GROUP BY cte2.alf_pe,
		cte3.diag_dt,
		uti.UTI_outcome,
		cte2.group_number
ORDER BY cte2.alf_pe, cte3.diag_dt;

/*

-- ================================================================
-- identify prior cvd event from pedw
-- ================================================================

--THIS NEEDS RUNNING AND CHECKING
--NEED TO UPDATE TABLE NAMES AND FIELD NAMES

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_prior_cvd_spell
	AS
(
SELECT	sp.alf_pe,
		sp.prov_unit_cd,
		sp.spell_num_pe,
		ep.epi_str_dt,
		ep.epi_num,
		dg.diag_cd_1234
	FROM	sail0972v.PEDW_SPELL_20211101 AS sp,
			sail0972v.PEDW_EPISODE_20211101 AS ep,
			sail0972v.PEDW_DIAG_20211101 AS dg
)
definition ONLY
ON COMMIT PRESERVE rows;

COMMIT;

INSERT INTO SESSION.vb_wlgp_sub_prior_cvd_spell
WITH spell as
(
	SELECT sp.alf_pe,
			sp.prov_unit_cd,
			sp.spell_num_pe,
			uti.diag_dt AS uti_dt
		FROM sail0972v.PEDW_SPELL_20211101 AS sp
		INNER JOIN sailw0972v.VB_WLGP_SUB_CONFIRMED AS uti
		ON sp.alf_pe = uti.alf_pe
),
epi AS
(
	SELECT spell.alf_pe,
			spell.prov_unit_cd,
			spell.spell_num_pe,
			ep.epi_str_dt,
			ep.epi_num
		FROM spell
		INNER JOIN sail0972v.PEDW_EPISODE_20211101 AS ep
		ON spell.prov_unit_cd = ep.prov_unit_cd
		AND spell.spell_num_pe = ep.spell_num_pe
		AND ep.epi_str_dt < spell.uti_dt
)
SELECT 	epi.*,
		dg.diag_cd_1234
	FROM epi
	INNER JOIN sail0972v.PEDW_DIAG_20211101 AS dg
	ON epi.spell_num_pe = dg.spell_num_pe
	AND epi.prov_unit_cd = dg.prov_unit_cd
	AND epi.epi_num = dg.epi_num
	INNER JOIN SAILW0972V.VB_ICD_MI_STROKE AS icd
	ON dg.diag_cd_1234 = icd.icd10_cd;
	
COMMIT;





DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_prior_cvd_spell
	AS
(
SELECT	sp.alf_pe,
		sp.prov_unit_cd,
		sp.spell_num_pe,
		ep.epi_str_dt,
		ep.epi_num,
		dg.diag_cd_1234
	FROM	sail0972v.PEDW_SPELL_20211101 AS sp,
			sail0972v.PEDW_EPISODE_20211101 AS ep,
			sail0972v.PEDW_DIAG_20211101 AS dg
)
definition ONLY
ON COMMIT PRESERVE rows;
	
-- ===================================================
-- add prior cvd flag to uti table
-- ===================================================
			
ALTER table sailw0972v.VB_WLGP_SUB_CONFIRMED
ADD COLUMN prior_cvd integer;

UPDATE sailw0972v.VB_WLGP_SUB_CONFIRMED AS conf
SET prior_cvd = 1 
WHERE conf.alf_pe||conf.diag_dt IN
	(
	SELECT uti.alf_pe||uti.uti_dt
		FROM SESSION.vb_wlgp_sub_prior_cvd AS cvd
			INNER JOIN sailw0972v.VB_WLGP_SUB_CONFIRMED AS uti
			ON uti.alf_pe = cvd.alf_pe
			AND uti.diag_dt = cvd.uti_dt
	);

---------------------------------------------------------------------------------
--Create table with added demographics WOB, WIMD and GNDR_CD

CALL fnc.drop_if_exists('sailw0972v.VB_WLGP_SUB');

CREATE TABLE sailw0972v.VB_WLGP_SUB
AS
(SELECT con.*,
		wd.wimd_2019_quintile_desc,
		per.wob,
		per.gndr_cd
		FROM sailw0972v.VB_WLGP_SUB_CONFIRMED AS con,
			sail0972v.WDSD_CLEAN_ADD_GEOG_CHAR_LSOA2011_20210502 AS wd,
			sail0972v.WDSD_AR_PERS_20210502 AS per)
WITH NO DATA;

ALTER TABLE sailw0972v.VB_WLGP_SUB activate NOT logged INITIALLY;

INSERT INTO sailw0972v.VB_WLGP_SUB
SELECT con.*,
		wd.wimd_2019_quintile_desc,
		per.wob,
		per.gndr_cd
		FROM sailw0972v.VB_WLGP_SUB_CONFIRMED AS con
		LEFT JOIN sail0972v.WDSD_CLEAN_ADD_GEOG_CHAR_LSOA2011_20210502 AS wd
			ON con.alf_pe = wd.alf_pe
			AND con.diag_dt BETWEEN wd.START_DATE AND wd.END_DATE
		LEFT JOIN sail0972v.WDSD_AR_PERS_20210502 AS per
			ON con.alf_pe = per.alf_pe;
			
COMMIT;

/*think can drop this and use the cohort spine table max start and min end dates

---------------------------------------------------------------------------------
-------------------------------------------------------------------------------
--add study inclusion start and end dates to the cohort
--cannot re-enter study if a person becomes ineligible at some point after study start
--i.e. first period of inclusion only
				
ALTER TABLE sailw0972v.VB_WLGP_SUB
	ADD COLUMN INC_STR_DT DATE
	ADD COLUMN INC_END_DT DATE
	ADD COLUMN DAYS_IN_COHORT INTEGER;

MERGE INTO sailw0972v.VB_WLGP_SUB AS eps
	USING SAILW0972V.V2_VB_WDSD_DAYS_IN_COHORT AS ic
		ON eps.ALF_PE = ic.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET eps.INC_STR_DT = ic.LATEST_START
			;
		
MERGE INTO sailw0972v.VB_WLGP_SUB AS eps
	USING SAILW0972V.V2_VB_WDSD_DAYS_IN_COHORT AS ic
		ON eps.ALF_PE = ic.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET eps.INC_END_DT = ic.EARLIEST_END
			;

MERGE INTO sailw0972v.VB_WLGP_SUB AS eps
	USING SAILW0972V.V2_VB_WDSD_DAYS_IN_COHORT AS ic
		ON eps.ALF_PE = ic.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET eps.DAYS_IN_COHORT = ic.DAYS_IN_COHORT
			;

--------------------------------------------------------------------
--delete any utis not taking place during individual's first period of study inclusion

delete FROM sailw0972v.VB_WLGP_SUB
WHERE diag_dt NOT BETWEEN inc_str_dt AND inc_end_dt;

---------------------------------------------------------------------

*/
	
-- =======================================================
-- add wimd to uti table at time of UTI
-- =======================================================

/*
 * should be able to delete the alter table

ALTER TABLE sailw0972v.VB_WLGP_SUB_CONFIRMED
ADD COLUMN WIMD_2019_QUINTILE_DESC varchar(25);

 */

MERGE INTO sailw0972v.VB_WLGP_SUB_CONFIRMED AS uti
USING 
(
	SELECT DISTINCT
		coh.ALF_PE,
		coh.diag_dt,
		wd.WIMD_2019_QUINTILE_DESC
	FROM sail0972v.WDSD_CLEAN_ADD_GEOG_CHAR_LSOA2011_20210502 AS wd
	INNER JOIN sailw0972v.VB_WLGP_SUB_CONFIRMED AS coh
	ON wd.ALF_PE = coh.ALF_PE
	AND coh.diag_dt BETWEEN wd.START_DATE AND wd.END_DATE
)
AS wimd
ON uti.ALF_PE = wimd.ALF_PE
AND uti.DIAG_DT = wimd.diag_dt
WHEN MATCHED THEN 
UPDATE 
SET uti.WIMD_2019_QUINTILE_DESC = wimd.WIMD_2019_QUINTILE_DESC;

-- =====================================================	
-- identify history OF CVD		
-- =====================================================

/* Link all utis to pedw diagnoses to identify any episodes with CVD icd-10 codes (MI or stroke)*/

CALL fnc.drop_if_exists('SESSION.VB_WLGP_SUB_PRIOR_CVD');

DECLARE GLOBAL TEMPORARY TABLE SESSION.VB_WLGP_SUB_PRIOR_CVD
(alf_pe varchar(15),
uti_dt date,
event_dt date)
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.VB_WLGP_SUB_PRIOR_CVD
	(ALF_PE,
	uti_dt,
	EVENT_DT)
WITH rs AS
(
	SELECT PROV_UNIT_CD,
			SPELL_NUM_PE,
			EPI_NUM,
			DIAG_CD_1234
		FROM sail0972v.PEDW_DIAG_20211101 AS dg
		INNER JOIN SAILW0972V.VB_ICD_MI_STROKE AS icd
		ON dg.DIAG_CD_1234 = icd.ICD10_CD
),
CTE AS 
(
	SELECT sp.ALF_PE,
			sp.ALF_STS_CD,
			eps.EPI_STR_DT,
			rs.DIAG_CD_1234 
		FROM rs
		LEFT JOIN sail0972v.PEDW_EPISODE_20211101 AS eps
		ON rs.PROV_UNIT_CD = eps.PROV_UNIT_CD
		AND rs.SPELL_NUM_PE = eps.SPELL_NUM_PE
		AND rs.EPI_NUM = eps.EPI_NUM
			LEFT JOIN sail0972v.PEDW_SPELL_20211101 AS sp
			ON rs.PROV_UNIT_CD = sp.PROV_UNIT_CD
			AND rs.SPELL_NUM_PE = sp.SPELL_NUM_PE
				WHERE sp.ALF_PE IS NOT NULL
				AND sp.ALF_STS_CD IN ('1','4','39')
),
cte2 AS
(
	SELECT alf_pe,
			min(epi_str_dt) AS event_dt
		FROM cte
			GROUP BY alf_pe
)
SELECT coh.ALF_PE,
		coh.diag_dt,
		CASE WHEN CTE2.EVENT_DT < coh.diag_dt
			THEN CTE2.EVENT_DT
			ELSE NULL
			END AS prior_cvd
	FROM sailw0972v.VB_WLGP_SUB_CONFIRMED AS coh
	LEFT JOIN CTE2
	ON coh.ALF_PE = CTE2.ALF_PE;
						
Commit;

-- ======================================
-- add prior CVD flag to uti table
-- ======================================

/*
 * should be able to delete the alter table

ALTER TABLE sailw0972v.VB_WLGP_SUB_CONFIRMED
ADD COLUMN prior_cvd integer;

*/

UPDATE sailw0972v.VB_WLGP_SUB_CONFIRMED AS uti
	SET uti.prior_cvd = 1
		WHERE uti.alf_pe||uti.diag_dt IN
			(
				SELECT cvd.ALF_PE||cvd.uti_dt 
				FROM SESSION.VB_WLGP_SUB_PRIOR_CVD AS cvd
				WHERE event_dt IS NOT null
			);

-- ===========================================
-- create combined demographics and uti table
-- ===========================================

CALL fnc.drop_if_exists('sailw0972v.VB_WLGP_SUB_PRE');		
		
CREATE TABLE sailw0972v.VB_WLGP_SUB_PRE AS
(
SELECT DISTINCT
		dem.alf_pe,
		dem.wob,
		dem.dod,
		dem.gndr_cd,
		dem.GP_STR_DT,
		dem.GP_END_DT,
		dem.ADD_STR_DT,
		dem.ADD_END_DT,
		dem.MAX_STR_DT,
		dem.MIN_END_DT,
		dem.gndr_cd AS days_in_cohort,
		dem.PERS_ROW,
		uti.diag_dt,
		uti.UTI_outcome,
		uti.group_number,
		uti.GROUP_SEQUENCE,
		uti.WIMD_2019_QUINTILE_DESC,
		uti.prior_cvd
	FROM sailw0972v.vb_wlgp_sub_cohort_spine AS dem,
		sailw0972v.VB_WLGP_SUB_CONFIRMED AS uti
)
WITH NO data;
	
INSERT into sailw0972v.VB_WLGP_SUB_PRE
SELECT DISTINCT
		dem.alf_pe,
		dem.wob,
		dem.dod,
		dem.gndr_cd,
		dem.GP_STR_DT,
		dem.GP_END_DT,
		dem.ADD_STR_DT,
		dem.ADD_END_DT,
		dem.MAX_STR_DT,
		dem.MIN_END_DT,
		days_between(min_end_dt, max_str_dt),
		dem.PERS_ROW,
		uti.diag_dt,
		uti.UTI_outcome,
		uti.group_number,
		uti.GROUP_SEQUENCE,
		uti.WIMD_2019_QUINTILE_DESC,
		uti.prior_cvd
	FROM sailw0972v.vb_wlgp_sub_cohort_spine AS dem
	LEFT JOIN sailw0972v.VB_WLGP_SUB_CONFIRMED AS uti
	ON dem.alf_pe = uti.alf_pe;
		
-- ===============================================
-- flag for at least 12 months gp reg prior to uti
-- ===============================================

ALTER TABLE sailw0972v.VB_WLGP_SUB_PRE
ADD COLUMN gp_reg_12_mts integer;

UPDATE sailw0972v.VB_WLGP_SUB_PRE
SET gp_reg_12_mts = CASE WHEN diag_dt IS NULL
							THEN NULL
						WHEN months_between(diag_dt, gp_str_dt) >= 12
							THEN 1
						ELSE 0
					END;
						
-- ===============================================
-- create table for UTI cohort only
-- ===============================================

CALL fnc.drop_if_exists('sailw0972v.VB_WLGP_SUB');
				
CREATE TABLE sailw0972v.VB_WLGP_SUB AS
(
	SELECT 
			alf_pe,
			wob,
			dod,
			gndr_cd,
			MAX_STR_DT AS inc_str_dt,
			MIN_END_DT AS inc_end_dt,
			days_in_cohort,
			PERS_ROW,
			diag_dt,
			UTI_outcome,
			group_number,
			GROUP_SEQUENCE,
			WIMD_2019_QUINTILE_DESC
		FROM sailw0972v.VB_WLGP_SUB_PRE
)
WITH NO DATA;

INSERT INTO sailw0972v.VB_WLGP_SUB
	SELECT 
			alf_pe,
			wob,
			dod,
			gndr_cd,
			MAX_STR_DT,
			MIN_END_DT,
			days_in_cohort,
			PERS_ROW,
			diag_dt,
			UTI_outcome,
			group_number,
			GROUP_SEQUENCE,
			WIMD_2019_QUINTILE_DESC
		FROM sailw0972v.VB_WLGP_SUB_PRE
		WHERE diag_dt IS NOT NULL
		AND gp_reg_12_mts = 1
		AND prior_cvd IS NULL;
				
-- =============================================
-- flag first UTI
-- =============================================

ALTER table sailw0972v.VB_WLGP_SUB
ADD COLUMN first_uti integer;

UPDATE sailw0972v.VB_WLGP_SUB AS sub
SET first_uti = 1 
WHERE sub.ALF_PE||sub.diag_dt IN
	(SELECT mqo.alf_pe||mqo.diag_dt
		FROM (SELECT alf_pe, min(diag_dt) AS diag_dt
			FROM sailw0972v.VB_WLGP_SUB
				GROUP BY alf_pe
			) AS mqo);

UPDATE sailw0972v.VB_WLGP_SUB AS sub
SET first_uti = CASE WHEN first_uti = 1
					THEN first_uti
						ELSE 0
				END;
			
-- =============================================	
-- add stroke after uti
-- =============================================

CALL fnc.drop_if_exists('SESSION.VB_WLGP_SUB_POST_STROKE');

DECLARE GLOBAL TEMPORARY TABLE SESSION.VB_WLGP_SUB_POST_STROKE
(alf_pe varchar(15),
uti_dt date,
event_dt date)
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.VB_WLGP_SUB_POST_STROKE
							(ALF_PE,
							uti_dt,
							EVENT_DT)
WITH rs AS
(
	SELECT PROV_UNIT_CD,
			SPELL_NUM_PE,
			EPI_NUM,
			DIAG_CD_1234
		FROM sail0972v.PEDW_DIAG_20211101 AS dg
		INNER JOIN SAILW0972V.VB_ICD_MI_STROKE AS icd
			ON dg.DIAG_CD_1234 = icd.ICD10_CD
			where icd.CATEGORY = 'STROKE'
),
CTE AS 
(
	SELECT sp.ALF_PE,
			sp.ALF_STS_CD,
			eps.EPI_STR_DT,
			rs.DIAG_CD_1234 
		FROM rs
		LEFT JOIN sail0972v.PEDW_EPISODE_20211101 AS eps
			ON rs.PROV_UNIT_CD = eps.PROV_UNIT_CD
			AND rs.SPELL_NUM_PE = eps.SPELL_NUM_PE
			AND rs.EPI_NUM = eps.EPI_NUM
		LEFT JOIN sail0972v.PEDW_SPELL_20211101 AS sp
			ON rs.PROV_UNIT_CD = sp.PROV_UNIT_CD
			AND rs.SPELL_NUM_PE = sp.SPELL_NUM_PE
			WHERE sp.ALF_PE IS NOT NULL
			AND sp.ALF_STS_CD IN ('1','4','39')
),
cte2 AS
(
	SELECT alf_pe,
			min(epi_str_dt) AS event_dt 
		FROM cte
			GROUP BY alf_pe
)
SELECT coh.ALF_PE,
		coh.diag_dt,
		CASE WHEN (CTE2.EVENT_DT >= coh.diag_dt
				AND cte2.event_dt BETWEEN coh.inc_str_dt AND coh.inc_end_dt)
				THEN CTE2.EVENT_DT
				ELSE NULL
				end
		FROM sailw0972v.VB_WLGP_SUB AS coh
		LEFT JOIN CTE2
			ON coh.ALF_PE = CTE2.ALF_PE;
						
Commit;

ALTER TABLE sailw0972v.VB_WLGP_SUB
ADD COLUMN stroke_dt date;

MERGE INTO sailw0972v.VB_WLGP_SUB AS conf
USING SESSION.VB_WLGP_SUB_POST_STROKE AS str
	ON conf.alf_pe||conf.diag_dt = str.alf_pe||str.uti_dt
		WHEN MATCHED THEN UPDATE
			SET conf.stroke_dt = str.event_dt;
		
-- =============================================
-- add flag for stroke within 90 days of uti
-- =============================================

ALTER TABLE sailw0972v.VB_WLGP_SUB
ADD COLUMN stroke_within90 integer;

update sailw0972v.VB_WLGP_SUB
SET stroke_within90 = CASE WHEN stroke_dt IS NULL
								THEN null
						WHEN days_between(stroke_dt, DIAG_DT) <= 90
								THEN 1
						ELSE 0
					end;
		
-- =============================================
-- add column to flag if first stroke occurs on same day as UTI diagnosis date
-- =============================================

ALTER TABLE sailw0972v.VB_WLGP_SUB
ADD COLUMN stroke_uti_same_dt integer;

update sailw0972v.VB_WLGP_SUB
SET stroke_uti_same_dt = CASE WHEN stroke_dt IS NULL
								THEN null
						WHEN DIAG_DT = stroke_dt
								THEN 1
						ELSE 0
					end;

-- =============================================
-- add mi after uti
-- =============================================

CALL fnc.drop_if_exists('SESSION.VB_WLGP_SUB_POST_MI');

DECLARE GLOBAL TEMPORARY TABLE SESSION.VB_WLGP_SUB_POST_MI
(alf_pe varchar(15),
uti_dt date,
event_dt date)
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.VB_WLGP_SUB_POST_MI
							(ALF_PE,
							uti_dt,
							EVENT_DT)
WITH rs AS
(
	SELECT PROV_UNIT_CD,
			SPELL_NUM_PE,
			EPI_NUM,
			DIAG_CD_1234
		FROM sail0972v.PEDW_DIAG_20211101 AS dg
		INNER JOIN SAILW0972V.VB_ICD_MI_STROKE AS icd
			ON dg.DIAG_CD_1234 = icd.ICD10_CD
			where icd.CATEGORY = 'MI'
),
CTE AS 
(
	SELECT sp.ALF_PE,
			sp.ALF_STS_CD,
			eps.EPI_STR_DT,
			rs.DIAG_CD_1234 
		FROM rs
		LEFT JOIN sail0972v.PEDW_EPISODE_20211101 AS eps
			ON rs.PROV_UNIT_CD = eps.PROV_UNIT_CD
			AND rs.SPELL_NUM_PE = eps.SPELL_NUM_PE
			AND rs.EPI_NUM = eps.EPI_NUM
		LEFT JOIN sail0972v.PEDW_SPELL_20211101 AS sp
			ON rs.PROV_UNIT_CD = sp.PROV_UNIT_CD
			AND rs.SPELL_NUM_PE = sp.SPELL_NUM_PE
			WHERE sp.ALF_PE IS NOT NULL
			AND sp.ALF_STS_CD IN ('1','4','39')
),
cte2 AS
(
	SELECT alf_pe,
			min(epi_str_dt) AS event_dt 
		FROM cte
			GROUP BY alf_pe
)
SELECT coh.ALF_PE,
		coh.diag_dt,
		CASE WHEN (CTE2.EVENT_DT >= coh.diag_dt
			AND cte2.event_dt BETWEEN coh.inc_str_dt AND coh.inc_end_dt)
			THEN CTE2.EVENT_DT
			ELSE NULL
			end
	FROM sailw0972v.VB_WLGP_SUB AS coh
	LEFT JOIN CTE2
		ON coh.ALF_PE = CTE2.ALF_PE;					
						
Commit;

ALTER TABLE sailw0972v.VB_WLGP_SUB
ADD COLUMN mi_dt date;

MERGE INTO sailw0972v.VB_WLGP_SUB AS conf
USING SESSION.VB_WLGP_SUB_POST_MI AS str
	ON conf.alf_pe||conf.diag_dt = str.alf_pe||str.uti_dt
		WHEN MATCHED THEN UPDATE
			SET conf.mi_dt = str.event_dt;	
		
-- =============================================
-- add flag for mi within 90 days
-- =============================================

ALTER TABLE sailw0972v.VB_WLGP_SUB
ADD COLUMN mi_within90 integer;

update sailw0972v.VB_WLGP_SUB
SET mi_within90 = CASE WHEN mi_dt IS NULL
								THEN null
						WHEN days_between(mi_dt, DIAG_DT) <= 90
								THEN 1
						ELSE 0
					end;
				
-- =============================================
--add column to flag if first MI occurs on same day as UTI diagnosis date
-- =============================================

ALTER TABLE sailw0972v.VB_WLGP_SUB
ADD COLUMN mi_uti_same_dt integer;

update sailw0972v.VB_WLGP_SUB
SET mi_uti_same_dt = CASE WHEN mi_dt IS NULL
								THEN null
						WHEN DIAG_DT = mi_dt
								THEN 1
						ELSE 0
					end;

-------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------
--add covariates and comorbidities

-------------------------------------------------------------------------------------
--add ethnicity latest prior to or at diagnosis date	

--update cohort table with ethnicity
		
CALL fnc.drop_if_exists('SESSION.VB_WLGP_SUB_ETHNICITY');		
		
DECLARE GLOBAL TEMPORARY TABLE SESSION.VB_WLGP_SUB_ETHNICITY AS (
	SELECT	ALF_PE, 
			ETHN_EC_ONS_CODE
		FROM SAILW0972V.ETHN_0972_PREP_DATE)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.VB_WLGP_SUB_ETHNICITY
							(ALF_PE,
							ETHN_EC_ONS_CODE)
					WITH CTE AS 
						(SELECT eth.ALF_PE, 
								max(eth.ETHN_DATE) AS ETHN_DATE
						FROM SAILW0972V.ETHN_0972_PREP_DATE AS eth
							RIGHT JOIN sailw0972v.VB_WLGP_SUB AS coh
							ON eth.ALF_PE = coh.ALF_PE
							WHERE eth.ETHN_DATE <= coh.diag_dt
						GROUP BY eth.ALF_PE)
				SELECT eth2.ALF_PE,
						eth2.ETHN_EC_ONS_CODE
					FROM SAILW0972V.ETHN_0972_PREP_DATE AS eth2
						RIGHT JOIN CTE
							ON eth2.ALF_PE = CTE.ALF_PE
							AND eth2.ETHN_DATE = CTE.ETHN_DATE;					
						
Commit;

--delete duplicate rows where the same ethnicity is recorded in both rows

delete FROM 
	(SELECT ROWNUMBER()	OVER(PARTITION BY ALF_PE, ETHN_EC_ONS_CODE) AS rn
			FROM SESSION.vb_wlgp_sub_ETHNICITY) AS mqo
			WHERE rn > 1;

--delete all rows for person where a different ethnicity is recorded on the same date

delete FROM SESSION.vb_wlgp_sub_ETHNICITY AS eth
WHERE EXISTS (SELECT ALF_PE, ALF_COUNT
		FROM (SELECT ALF_PE, COUNT(ALF_PE) AS ALF_COUNT
			FROM SESSION.vb_wlgp_sub_ETHNICITY
			GROUP BY ALF_PE
			HAVING COUNT(ALF_PE)>1) AS dup
		WHERE eth.ALF_PE = dup.ALF_PE);

/* Update MI cohort table with ethnicity */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN ETHNIC INTEGER;

MERGE INTO sailw0972v.vb_wlgp_sub AS coh
	USING SESSION.vb_wlgp_sub_ETHNICITY AS eth
		ON coh.ALF_PE = eth.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET coh.ETHNIC = eth.ETHN_EC_ONS_CODE
			;			

------------------------------------------------------------------------------
--ADD age AT diagnosis date
		
ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN AGE_AT_DIAG INTEGER;

UPDATE sailw0972v.vb_wlgp_sub
SET AGE_AT_DIAG = years_between(diag_dt, wob);

-------------------------------------------------------------------------------
--ADD smoking

-----------------------------------------------------------
--smoking algorithm
--BY:       s.j.aldridge@swansea.ac.uk
--aim:      to get smoking cohort ready
-----------------------------------------------------------

-- This is an algorithm to assign smoker status of your ALFs of interest using
-- a built in classification table based off of the individuals GP records
-- The smoker statuses are N - Never smoker, E - ex-smoker and S - current smoker
-- A detailed documentation of instructions can be found in the README of the Smoking_algorithm repository

-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
---------------------------- declare variables --------------------------------

---define variables here:

-- STEP 1 --
	-- find and replace all instances of "nnnn" to your project code (e.g. 1234)
	-- using ctrl + f


-- STEP 2 --
--	create a user table specifying your ALF_PEs, their diagnosis dates (DIAG_DATE).

------------Change from temp to proper table-----

CALL FNC.DROP_IF_EXISTS ('SAILW0972V.vb_wlgp_sub_CONF_COHORT_ALF_DATE');

CREATE TABLE SAILW0972V.vb_wlgp_sub_CONF_COHORT_ALF_DATE
	(	ALF_PE VARCHAR(20),
		DIAG_DATE DATE);

INSERT INTO SAILW0972V.vb_wlgp_sub_CONF_COHORT_ALF_DATE
	SELECT	ALF_PE,
			diag_dt
		FROM sailw0972v.vb_wlgp_sub
;

--	An example code for creating this table can be found in the example folder
CREATE OR REPLACE ALIAS SAILW0972V.input_USER_table FOR SAILW0972V.vb_wlgp_sub_CONF_COHORT_ALF_DATE; -- change to user table

-- STEP 3 --
	--- Specify your GP table
	--- This algorithm will expand your input table to obtain the necessary details needed to run the algorithm, these
	--- are sourced from a GP table. Please specify the table you'd like to use.
CREATE OR REPLACE ALIAS SAILW0972V.gp_database FOR SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301; 

-- STEP 4 --
	--- Specify your ALF format
	--- The DEFAULT is ALF_PE, but if yours is different, please REPLACE all "ALF_PE" with your format
	

-- STEP 5 --
	-- specify for which timepoint you want your smoker status to be assigned at,
	-- smoker status at point of diagnosis, up until a defined cut-off date (STEP 4)
	-- is the default.
	-- OPTION 1 - gives smoker-status at your specified cut-off date, regardless of diagnosis date
	-- OPTION 2 - gives smoker_status between diagnosis date and your cut-off date
	-- OPTION 3 - gives most recent smoker status with cut-off applied to DIAG_DATE
	--			- gives smoker status after DIAG_DATE (if using DIAG_DATE as your cut-off i.e. NULL setting from STEP 4)
	-- See the readme for details and instructions on how to implement each option.


-- STEP 6 --
	--- Specify your cutoff date (formatted as 'YYYY-MM-DD'): un-comment 6b and replace it with your date,
	--- or use 6a with 'NULL' to obtain smoker status at the point of diagnosis.
	--- NULL is the DEFAULT setting
	--6a
CREATE OR REPLACE VARIABLE SAILW0972V.input_smoking_date_cutoff VARCHAR(100) DEFAULT 'NULL';
	--6b
-- CREATE OR REPLACE VARIABLE SAILW0972V.input_smoking_date_cutoff VARCHAR(100) DEFAULT 'NULL';


-- STEP 7 --
	--- assign time since last smoker recording until you are happy to classify as 'ex-smoker' in days. i.e. an individual can't have
	---	been recorded a smoker for at least this period of time in the run up to the cut-off date for the algorithm to assign
	--- them as an ex-smoker
	--- DEFAULT is 180 days - approx 6 months
CREATE OR REPLACE VARIABLE SAILW0972V.ex_smoker_cutoff INTEGER DEFAULT 540;


-- STEP 8 --
	---desired ALF_STS_CDs - specify the ALF STS codes wanted for inclusion, default is 1, 4 and 39.
	---If you want more codes included, add the values to this table
CALL FNC.DROP_IF_EXISTS ('SAILW0972V.ALF_STS_CD_SMOKING');
CREATE TABLE SAILW0972V.ALF_STS_CD_SMOKING
	(ALF_STS_CD	BIGINT);
COMMIT;
INSERT INTO SAILW0972V.ALF_STS_CD_SMOKING
VALUES (1), (4), (39); -- remove or add additional codes to this line using the same format
COMMIT;

-- STEP 9 --
	--- The read codes for smoker status have been determined in the development of this algorithm and do not require input.
	--- *However*, if you'd like to edit this table, do so in the section titled "Create look up table".
	--- If you'd like to supply a new table of your own, comment out the "Create look up table" section and insert a reference to your own table below
-- CREATE OR REPLACE ALIAS SAILW0972V.SMOKER_LOOKUP FOR SAILW0972V.YOUR_LOOK_UP_TABLE_GOES_HERE;


-- STEP 10 --
	-- Select all (Ctrl A) and run this algorithm (right click, execute --> Execute SQL script)


-- STEP 11 --
	-- results are generated to the output table SAILW0972V.VB_SMOKER_OUTPUT_MI and feature
	-- the PATIENT_ID, SMOKER STATUS and SMOKER STATUS DESCRIPTION
	
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-------------------------- Create look up table --------------------------------

-- This is an updated list of read codes put together by SA based on the codes published by MH,
-- and with the guidance of AA, FT and RL (June 2021)

CALL FNC.DROP_IF_EXISTS ('SAILW0972V.SMOKER_LOOKUP');

CREATE TABLE sailW0972V.smoker_lookup
(
        sm_code         CHAR(6),
        description		VARCHAR(300),
        smoking_status  VARCHAR(1),
        complexity		VARCHAR(20)
)
DISTRIBUTE BY HASH (sm_code); --previously was best practise, but might be outdated now
COMMIT;

--granting access to team mates
GRANT ALL ON TABLE SAILW0972V.SMOKER_LOOKUP TO ROLE NRDASAIL_SAIL_0972_ANALYST;

--worth doing for large chunks of data
alter table SAILW0972V.SMOKER_LOOKUP activate not logged INITIALLY;

--inserting read codes relevent to smoking
insert into SAILW0972V.SMOKER_LOOKUP
	(sm_code, description, smoking_status, complexity)
VALUES
	('1371.'	,	'Never smoked tobacco'											,	'N'	,	'SIMPLE'	)	,
	('1372.'	,	'Trivial smoker - < 1 cig/day'									,	'S'	,	'SIMPLE'	)	,
	('1373.'	,	'Light smoker - 1-9 cigs/day'									,	'S'	,	'SIMPLE'	)	,
	('1374.'	,	'Moderate smoker - 10-19 cigs/d'								,	'S'	,	'SIMPLE'	)	,
	('1375.'	,	'Heavy smoker - 20-39 cigs/day'									,	'S'	,	'SIMPLE'	)	,
	('1376.'	,	'Very heavy smoker - 40+cigs/d'									,	'S'	,	'SIMPLE'	)	,
	('1377.'	,	'Ex-trivial smoker (<1/day)'									,	'E'	,	'SIMPLE'	)	,
	('1378.'	,	'Ex-light smoker (1-9/day)'										,	'E'	,	'SIMPLE'	)	,
	('1379.'	,	'Ex-moderate smoker (10-19/day)'								,	'E'	,	'SIMPLE'	)	,
	('6791.'	,	'Health ed. - smoking'											,	'S'	,	'SIMPLE'	)	,
	('67910'	,	'Health education - parental smoking'							,	'S'	,	'SIMPLE'	)	,
	('137..'	,	'Tobacco consumption'											,	'S'	,	'EVENT_VAL DEPENDENT'	),
	('137A.'	,	'Ex-heavy smoker (20-39/day)'									,	'E'	,	'SIMPLE'	)	,
	('137a.'	,	'Pipe tobacco consumption'										,	'S'	,	'SIMPLE'	)	,
	('137B.'	,	'Ex-very heavy smoker (40+/day)'								,	'E'	,	'SIMPLE'	)	,
	('137b.'	,	'Ready to stop smoking'											,	'S'	,	'SIMPLE'	)	,
	('137C.'	,	'Keeps trying to stop smoking'									,	'S'	,	'SIMPLE'	)	,
	('137c.'	,	'Thinking about stopping smoking'								,	'S'	,	'SIMPLE'	)	,
	('137D.'	,	'Admitted tobacco cons untrue ?'								,	'S'	,	'SIMPLE'	)	,
	('137d.'	,	'Not interested in stopping smoking'							,	'S'	,	'SIMPLE'	)	,
	('137e.'	,	'Smoking restarted'												,	'S'	,	'SIMPLE'	)	,
	('137E.'	,	'Tobacco consumption unknown'									,	'S'	,	'EVENT_VAL DEPENDENT'	),
	('137F.'	,	'Ex-smoker - amount unknown'									,	'E'	,	'SIMPLE'	)	,
	('137f.'	,	'Reason for restarting smoking'									,	'S'	,	'SIMPLE'	)	,
	('137G.'	,	'Trying to give up smoking'										,	'S'	,	'SIMPLE'	)	,
	('137g.'	,	'Cigarette pack-years'											,	'S'	,	'EVENT_VAL DEPENDENT'	),
	('137h.'	,	'Minutes from waking to first tobacco consumption'				,	'S'	,	'SIMPLE'	)	,
	('137H.'	,	'Pipe smoker'													,	'S'	,	'SIMPLE'	)	,
	('137j.'	,	'Ex-cigarette smoker'											,	'E'	,	'SIMPLE'	)	,
	('137J.'	,	'Cigar smoker'													,	'S'	,	'SIMPLE'	)	,
	('137K.'	,	'Stopped smoking'												,	'E'	,	'SIMPLE'	)	,
	('137K0'	,	'Recently stopped smoking'										,	'E'	,	'SIMPLE'	)	,
	('137l.'	,	'Ex roll-up cigarette smoker'									,	'E'	,	'SIMPLE'	)	,
	('137L.'	,	'Current non-smoker'											,	'N'	,	'SIMPLE'	)	,
	('137m.'	,	'Failed attempt to stop smoking'								,	'S'	,	'SIMPLE'	)	,
	('137M.'	,	'Rolls own cigarettes'                                 			,	'S'	,	'SIMPLE'	)	,
	('137N.'	,	'Ex pipe smoker'                                        		,	'E'	,	'SIMPLE'	)	,
	('137O.'	,	'Ex cigar smoker'                                               ,	'E'	,	'SIMPLE'	)	,
	('137P.'	,	'Cigarette smoker'                                    			,	'S'	,	'SIMPLE'	)	,
	('137Q.'	,	'Smoking started'                                               ,	'S'	,	'SIMPLE'	)	,
	('137R.'	,	'Current smoker'                                                ,	'S'	,	'SIMPLE'	)	,
	('137S.'	,	'Ex smoker'                                                     ,	'E'	,	'SIMPLE'	)	,
	('137T.'	,	'Date ceased smoking'                                           ,	'E'	,	'SIMPLE'	)	,
	('137V.'	,	'Smoking reduced'                                               ,	'S'	,	'SIMPLE'	)	,
	('137X.'	,	'Cigarette consumption'                                         ,	'S'	,	'EVENT_VAL DEPENDENT'	)	,
	('137Y.'	,	'Cigar consumption'                                             ,	'S'	,	'EVENT_VAL DEPENDENT'	)	,
	('137Z.'	,	'Tobacco consumption NOS'                                       ,	'S'	,	'EVENT_VAL DEPENDENT'	)	,
	('13cA.'	,	'Smokes drugs'													,	'S'	,	'SIMPLE'	)	,
	('13p..'	,	'Smoking cessation milestones'                                  ,	'S'	,	'SIMPLE'	)	,
	('13p0.'	,	'Negotiated date for cessation of smoking'	                    ,	'S'	,	'SIMPLE'	)	,
	('13p4.'	,	'Smoking free weeks'                                            ,	'E'	,	'SIMPLE'	)	,
	('13p5.'	,	'Smoking cessation programme start date'	                	,	'S'	,	'SIMPLE'	)	,
	('13p50'	,	'Practice based smoking cessation programme start date'         ,	'S'	,	'SIMPLE'	)	,
	('13p8.'	,	'Lost to smok cessation fllw-up'                                ,	'S'	,	'SIMPLE'	)	,
	('1V08.'	,	'Smokes drugs in cigarette form'								,	'S'	,	'SIMPLE'	)	,
	('1V09.'	,	'Smokes drugs through a pipe'									,	'S'	,	'SIMPLE'	)	,
	('38DH.'	,	'Fagerstrom test for nicotine dependence'	                    ,	'S'	,	'SIMPLE'	)	,
	('67A3.'	,	'Pregnancy smoking advice'                                      ,	'S'	,	'SIMPLE'	)	,
	('67H1.'	,	'Lifestyle advice regarding smoking'	                        ,	'S'	,	'SIMPLE'	)	,
	('67H6.'	,	'Brief intervention for smoking cessation'	                    ,	'S'	,	'SIMPLE'	)	,
	('745H.'	,	'Smoking cessation therapy'                                     ,	'S'	,	'SIMPLE'	)	,
	('745H0'	,	'Nicotine replacement therapy using nicotine patches'	        ,	'S'	,	'SIMPLE'	)	,
	('745H1'	,	'Nicotine replacement therapy using nicotine gum'	            ,	'S'	,	'SIMPLE'	)	,
	('745H2'	,	'Nicotine replacement therapy using nicotine inhalator'		    ,	'S'	,	'SIMPLE'	)	,
	('745H3'	,	'Nicotine replacement therapy using nicotine lozenges'	        ,	'S'	,	'SIMPLE'	)	,
	('745H4'	,	'Smoking cessation drug therapy'                                ,	'S'	,	'SIMPLE'	)	,
	('745H5'	,	'Varenicline therapy'                                           ,	'S'	,	'SIMPLE'	)	,
	('745Hy'	,	'Other specified smoking cessation therapy'		                ,	'S'	,	'SIMPLE'	)	,
	('745Hz'	,	'Smoking cessation therapy NOS'                                 ,	'S'	,	'SIMPLE'	)	,
	('8B2B.'	,	'Nicotine replacement therapy'                                  ,	'S'	,	'SIMPLE'	)	,
	('8B2B0'	,	'Issue of nicotine replacement therapy voucher'					,	'S'	,	'SIMPLE'	)	,
	('8B31G'	,	'Varenicline smoking cessation therapy offered'					,	'S'	,	'SIMPLE'	)	,
	('8B3f.'	,	'Nicotine replacement therapy provided free'	                ,	'S'	,	'SIMPLE'	)	,
	('8B3Y.'	,	'Over the counter nicotine replacement therapy'		            ,	'S'	,	'SIMPLE'	)	,
	('8BP3.'	,	'Nicotine replacement therapy provided by community pharmacis'	,	'S'	,	'SIMPLE'	)	,
	('8BPh.'	,	'Bupropion therapy'												,	'S'	,	'SIMPLE'	)	,
	('8CAg.'	,	'Smoking cessation advice provided by community pharmacist'		,	'S'	,	'SIMPLE'	)	,
	('8CAL.'	,	'Smoking cessation advice'                                      ,	'S'	,	'SIMPLE'	)	,
	('8CdB.'	,	'Stop smoking service opportunity signposted'	                ,	'S'	,	'SIMPLE'	)	,
	('8H7i.'	,	'Referral to smoking cessation advisor'		                    ,	'S'	,	'SIMPLE'	)	,
	('8HBM.'	,	'Stop smoking face to face follow-up'	                        ,	'S'	,	'SIMPLE'	)	,
	('8HBP.'	,	'Smoking cessation 12 week follow-up'							,	'S'	,	'SIMPLE'	)	,
	('8HkQ.'	,	'Referral to NHS stop smoking service'	                        ,	'S'	,	'SIMPLE'	)	,
	('8HTK.'	,	'Referral to stop-smoking clinic'	                            ,	'S'	,	'SIMPLE'	)	,
	('8I2I.'	,	'Nicotine replacement therapy contraindicated'	                ,	'S'	,	'SIMPLE'	)	,
	('8I2J.'	,	'Bupropion contraindicated'                                     ,	'S'	,	'SIMPLE'	)	,
	('8I39.'	,	'Nicotine replacement therapy refused'	                        ,	'S'	,	'SIMPLE'	)	,
	('8I3M.'	,	'Bupropion refused'                                             ,	'S'	,	'SIMPLE'	)	,
	('8I6H.'	,	'Smoking review not indicated'                                  ,	'S'	,	'SIMPLE'	)	,
	('8IAj.'	,	'Smoking cessation advice declined'		                        ,	'S'	,	'SIMPLE'	)	,
	('8IEK.'	,	'Smoking cessation programme declined'	                        ,	'S'	,	'SIMPLE'	)	,
	('8IEM.'	,	'Smoking cessation drug therapy declined'	                    ,	'S'	,	'SIMPLE'	)	,
	('8IEM0'	,	'Varenicline smoking cessation therapy declined'				,	'S'	,	'SIMPLE'	)	,
	('8IEo.'	,	'Referral to smoking cessation service declined'				,	'S'	,	'SIMPLE'	)	,
	('8T08.'	,	'Referral to smoking cessation service'							,	'S'	,	'SIMPLE'	)	,
	('9hG..'	,	'Exception reporting: smoking quality indicators'	            ,	'S'	,	'SIMPLE'	)	,
	('9hG0.'	,	'Excepted from smoking quality indicators: Patient unsuitable'	,	'S'	,	'SIMPLE'	)	,
	('9hG1.'	,	'Excepted from smoking quality indicators: Informed dissent'	,	'S'	,	'SIMPLE'	)	,
	('9kc..'	,	'Smoking cessation - enhanced services administration'	        ,	'S'	,	'SIMPLE'	)	,
	('9kc0.'	,	'Smoking cessatn monitor template complet - enhanc serv admin'	,	'S'	,	'SIMPLE'	)	,
	('9km..'	,	'Ex-smoker annual review - enhanced services administration'	,	'E'	,	'SIMPLE'	)	,
	('9kn..'	,	'Non-smoker annual review - enhanced services administration'	,	'N'	,	'SIMPLE'	)	,
	('9ko..'	,	'Current smoker annual review - enhanced services admin'	    ,	'S'	,	'SIMPLE'	)	,
	('9N2k.'	,	'Seen by smoking cessation advisor'		                        ,	'S'	,	'SIMPLE'	)	,
	('9N4M.'	,	'DNA - Did not attend smoking cessation clinic'		            ,	'S'	,	'SIMPLE'	)	,
	('9Ndf.'	,	'Consent given for follow-up by smoking cessation team'			,	'S'	,	'SIMPLE'	)	,
	('9Ndg.'	,	'Declined consent for follow-up by smoking cessation team'	    ,	'S'	,	'SIMPLE'	)	,
	('9NdV.'	,	'Consent given follow-up after smoking cessation intervention'	,	'S'	,	'SIMPLE'	)	,
	('9NdW.'	,	'Consent given for smoking cessation data sharing'	            ,	'S'	,	'SIMPLE'	)	,
	('9NdY.'	,	'Declin cons follow-up evaluation after smoking cess interven'	,	'S'	,	'SIMPLE'	)	,
	('9NdZ.'	,	'Declined consent for smoking cessation data sharing'	        ,	'S'	,	'SIMPLE'	)	,
	('9NS02'	,	'Referral for smoking cessation service offered'	            ,	'S'	,	'SIMPLE'	)	,
	('9OO..'	,	'Anti-smoking monitoring admin.'                                ,	'S'	,	'SIMPLE'	)	,
	('9OO1.'	,	'Attends stop smoking monitor.'                                 ,	'S'	,	'SIMPLE'	)	,
	('9OO2.'	,	'Refuses stop smoking monitor'                                  ,	'S'	,	'SIMPLE'	)	,
	('9OO3.'	,	'Stop smoking monitor default'                                  ,	'S'	,	'SIMPLE'	)	,
	('9OO4.'	,	'Stop smoking monitor 1st lettr'                                ,	'S'	,	'SIMPLE'	)	,
	('9OO5.'	,	'Stop smoking monitor 2nd lettr'                                ,	'S'	,	'SIMPLE'	)	,
	('9OO6.'	,	'Stop smoking monitor 3rd lettr'                                ,	'S'	,	'SIMPLE'	)	,
	('9OO7.'	,	'Stop smoking monitor verb.inv.'                                ,	'S'	,	'SIMPLE'	)	,
	('9OO8.'	,	'Stop smoking monitor phone inv'                                ,	'S'	,	'SIMPLE'	)	,
	('9OO9.'	,	'Stop smoking monitoring delete'                                ,	'S'	,	'SIMPLE'	)	,
	('9OOA.'	,	'Stop smoking monitor.chck done'                                ,	'S'	,	'SIMPLE'	)	,
	('9OOB.'	,	'Stop smoking invitation short message service text message'	,	'S'	,	'SIMPLE'	)	,
	('9OOB0'	,	'Stop smoking invitation first SMS text message'	            ,	'S'	,	'SIMPLE'	)	,
	('9OOB1'	,	'Stop smoking invitation second SMS text message'	            ,	'S'	,	'SIMPLE'	)	,
	('9OOB2'	,	'Stop smoking invitation third SMS text message'	            ,	'S'	,	'SIMPLE'	)	,
	('9OOZ.'	,	'Stop smoking monitor admin.NOS'                                ,	'S'	,	'SIMPLE'	)	,
	('du3..'	,	'NICOTINE'                                                      ,	'S'	,	'SIMPLE'	)	,
	('du31.'	,	'NICOTINE 2mg chewing gum'                                      ,	'S'	,	'SIMPLE'	)	,
	('du32.'	,	'NICOTINE 4mg chewing gum'                                      ,	'S'	,	'SIMPLE'	)	,
	('du33.'	,	'NICORETTE 2mg chewing gum'                                     ,	'S'	,	'SIMPLE'	)	,
	('du34.'	,	'NICORETTE 4mg chewing gum'                                     ,	'S'	,	'SIMPLE'	)	,
	('du35.'	,	'NICOTINELL TTS 10 patches'                                     ,	'S'	,	'SIMPLE'	)	,
	('du36.'	,	'NICOTINELL TTS 20 patches'                                     ,	'S'	,	'SIMPLE'	)	,
	('du37.'	,	'NICOTINELL TTS 30 patches'                                     ,	'S'	,	'SIMPLE'	)	,
	('du38.'	,	'NICOTINE 7mg/24hours patches'                                  ,	'S'	,	'SIMPLE'	)	,
	('du39.'	,	'NICOTINE 14mg/24hours patches'                                 ,	'S'	,	'SIMPLE'	)	,
	('du3a.'	,	'NICORETTE nasal spray'                                         ,	'S'	,	'SIMPLE'	)	,
	('du3A.'	,	'NICOTINE 21mg/24hours patches'                                 ,	'S'	,	'SIMPLE'	)	,
	('du3B.'	,	'*NICORETTE 5mg patches x7'                                     ,	'S'	,	'SIMPLE'	)	,
	('du3b.'	,	'NICOTINE 10mg/mL nasal spray'                                  ,	'S'	,	'SIMPLE'	)	,
	('du3C.'	,	'*NICORETTE 10mg patches x7'                                    ,	'S'	,	'SIMPLE'	)	,
	('du3c.'	,	'NICOTINELL ORIGINAL 2mg gum'                                   ,	'S'	,	'SIMPLE'	)	,
	('du3D.'	,	'*NICORETTE 15mg patches x7'                                    ,	'S'	,	'SIMPLE'	)	,
	('du3d.'	,	'NICOTINELL MINT 2mg gum'                                       ,	'S'	,	'SIMPLE'	)	,
	('du3E.'	,	'*NICORETTE 15mg patches x28'                                   ,	'S'	,	'SIMPLE'	)	,
	('du3e.'	,	'NICOTINE 10mg inhalator starter pack' 		                    ,	'S'	,	'SIMPLE'	)	,
	('du3f.'	,	'NICOTINE 10mg inhalator refill pack'	                        ,	'S'	,	'SIMPLE'	)	,
	('du3F.'	,	'NICOTINE 5mg/16hours patches'                                  ,	'S'	,	'SIMPLE'	)	,
	('du3g.'	,	'NICORETTE 10mg inhalator starter pack'		                    ,	'S'	,	'SIMPLE'	)	,
	('du3G.'	,	'NICOTINE 10mg/16hours patches'                                 ,	'S'	,	'SIMPLE'	)	,
	('du3h.'	,	'NICORETTE 10mg inhalator refill pack'	                        ,	'S'	,	'SIMPLE'	)	,
	('du3H.'	,	'NICOTINE 15mg/16hours patches'                                 ,	'S'	,	'SIMPLE'	)	,
	('du3i.'	,	'NICOTINELL ORIGINAL 4mg chewing gum'	                        ,	'S'	,	'SIMPLE'	)	,
	('du3I.'	,	'NIQUITIN CQ 2mg original lozenges'		                        ,	'S'	,	'SIMPLE'	)	,
	('du3J.'	,	'*NICABATE 7mg patches x14'                                     ,	'S'	,	'SIMPLE'	)	,
	('du3j.'	,	'NICOTINELL MINT 4mg chewing gum'	                            ,	'S'	,	'SIMPLE'	)	,
	('du3K.'	,	'*NICABATE 14mg patches x14'                                    ,	'S'	,	'SIMPLE'	)	,
	('du3k.'	,	'NIQUITIN CQ 7mg/24hours patches'	                            ,	'S'	,	'SIMPLE'	)	,
	('du3L.'	,	'*NICABATE 21mg patches x14'                                    ,	'S'	,	'SIMPLE'	)	,
	('du3l.'	,	'NIQUITIN CQ 14mg/24hours patches'	                            ,	'S'	,	'SIMPLE'	)	,
	('du3M.'	,	'*NICABATE 7mg patches x7'                                      ,	'S'	,	'SIMPLE'	)	,
	('du3m.'	,	'NIQUITIN CQ 21mg/24hours patches'	                            ,	'S'	,	'SIMPLE'	)	,
	('du3N.'	,	'*NICABATE 14mg patches x7'                                     ,	'S'	,	'SIMPLE'	)	,
	('du3n.'	,	'NICOTINE 2mg sublingual tablets'	                            ,	'S'	,	'SIMPLE'	)	,
	('du3o.'	,	'NICORETTE MICROTAB 2mg sublingual tablets'		                ,	'S'	,	'SIMPLE'	)	,
	('du3O.'	,	'NIQUITIN CQ 7mg/24hours clear patches'		                    ,	'S'	,	'SIMPLE'	)	,
	('du3P.'	,	'*NICABATE 21mg patches x7'                                     ,	'S'	,	'SIMPLE'	)	,
	('du3p.'	,	'*NICOTINE 1mg mint lozenges'                                   ,	'S'	,	'SIMPLE'	)	,
	('du3Q.'	,	'*NICORETTE 15mg patches x3'                                    ,	'S'	,	'SIMPLE'	)	,
	('du3q.'	,	'NICOTINELL MINT 1mg lozenges'                                  ,	'S'	,	'SIMPLE'	)	,
	('du3R.'	,	'*NICONIL-11 patches'                                           ,	'S'	,	'SIMPLE'	)	,
	('du3r.'	,	'NIQUITIN CQ 14mg/24hours clear patches'	                    ,	'S'	,	'SIMPLE'	)	,
	('du3S.'	,	'*NICONIL-22 patches'                                           ,	'S'	,	'SIMPLE'	)	,
	('du3s.'	,	'NIQUITIN CQ 21mg/24hours clear patches'	                    ,	'S'	,	'SIMPLE'	)	,
	('du3T.'	,	'*NICOTINE 11mg/24hours patches'                                ,	'S'	,	'SIMPLE'	)	,
	('du3t.'	,	'NICOTINE 2mg fruit chewing gum'                                ,	'S'	,	'SIMPLE'	)	,
	('du3U.'	,	'*NICOTINE 22mg/24hours patches'                                ,	'S'	,	'SIMPLE'	)	,
	('du3u.'	,	'NICOTINE 4mg fruit chewing gum'                                ,	'S'	,	'SIMPLE'	)	,
	('du3V.'	,	'NICORETTE 2mg mint chewing gum'                                ,	'S'	,	'SIMPLE'	)	,
	('du3v.'	,	'NICOTINE 2mg citrus chewing gum'	                            ,	'S'	,	'SIMPLE'	)	,
	('du3w.'	,	'NICORETTE CITRUS 2mg chewing gum'	                            ,	'S'	,	'SIMPLE'	)	,
	('du3W.'	,	'NICORETTE MINT PLUS 4mg chewing gum'	                        ,	'S'	,	'SIMPLE'	)	,
	('du3x.'	,	'NICOTINE 1mg lozenges'                                         ,	'S'	,	'SIMPLE'	)	,
	('du3X.'	,	'NICOTINE 2mg mint chewing gum'                                 ,	'S'	,	'SIMPLE'	)	,
	('du3y.'	,	'NICOTINE 2mg lozenges'                                         ,	'S'	,	'SIMPLE'	)	,
	('du3Y.'	,	'NICOTINE 4mg mint chewing gum'                                 ,	'S'	,	'SIMPLE'	)	,
	('du3Z.'	,	'*NICONIL 22 starter pack'                                      ,	'S'	,	'SIMPLE'	)	,
	('du3z.'	,	'NICOTINE 4mg lozenges'                                         ,	'S'	,	'SIMPLE'	)	,
	('du6..'	,	'BUPROPION'                                                     ,	'S'	,	'SIMPLE'	)	,
	('du61.'	,	'ZYBAN 150mg m/r tablets'                                       ,	'S'	,	'SIMPLE'	)	,
	('du6z.'	,	'BUPROPION HYDROCHLORIDE 150mg m/r tablets'		                ,	'S'	,	'SIMPLE'	)	,
	('du7..'	,	'NICOTINE 2'                                                    ,	'S'	,	'SIMPLE'	)	,
	('du71.'	,	'NIQUITIN CQ 4mg original lozenges'		                        ,	'S'	,	'SIMPLE'	)	,
	('du72.'	,	'NIQUITIN CQ 2mg mint chewing gum'	                            ,	'S'	,	'SIMPLE'	)	,
	('du73.'	,	'NIQUITIN CQ 4mg mint chewing gum'	                            ,	'S'	,	'SIMPLE'	)	,
	('du74.'	,	'*NICORETTE 15mg patches x2'                                    ,	'S'	,	'SIMPLE'	)	,
	('du75.'	,	'NICOTINELL 2mg liquorice chewing gum'	                        ,	'S'	,	'SIMPLE'	)	,
	('du76.'	,	'NICOTINELL 4mg liquorice chewing gum'	                        ,	'S'	,	'SIMPLE'	)	,
	('du77.'	,	'NICOTINELL 2mg mint lozenges'                                  ,	'S'	,	'SIMPLE'	)	,
	('du78.'	,	'NIQUITIN CQ 2mg mint lozenges'                                 ,	'S'	,	'SIMPLE'	)	,
	('du79.'	,	'NIQUITIN CQ 4mg mint lozenges'                                 ,	'S'	,	'SIMPLE'	)	,
	('du7A.'	,	'NICORETTE FRESHMINT 2mg chewing gum'	                        ,	'S'	,	'SIMPLE'	)	,
	('du7a.'	,	'NICOTINELL ICEMINT 4mg chewing gum'	                        ,	'S'	,	'SIMPLE'	)	,
	('du7b.'	,	'NICORETTE 15mg inhalator'                                      ,	'S'	,	'SIMPLE'	)	,
	('du7B.'	,	'NICORETTE FRESHMINT 4mg chewing gum'	                        ,	'S'	,	'SIMPLE'	)	,
	('du7c.'	,	'NICOTINE 15mg inhalator'                                       ,	'S'	,	'SIMPLE'	)	,
	('du7C.'	,	'NICOTINELL CLASSIC 2mg chewing gum'	                        ,	'S'	,	'SIMPLE'	)	,
	('du7d.'	,	'NICASSIST 7mg/24hours patches'                                 ,	'S'	,	'SIMPLE'	)	,
	('du7D.'	,	'NICOTINELL CLASSIC 4mg chewing gum'	                        ,	'S'	,	'SIMPLE'	)	,
	('du7e.'	,	'NICASSIST 14mg/24hours patches'                                ,	'S'	,	'SIMPLE'	)	,
	('du7E.'	,	'NICORETTE FRESHFRUIT 2mg chewing gum'	                        ,	'S'	,	'SIMPLE'	)	,
	('du7f.'	,	'NICASSIST 21mg/24hours patches'                                ,	'S'	,	'SIMPLE'	)	,
	('du7F.'	,	'NICORETTE FRESHFRUIT 4mg chewing gum'	                        ,	'S'	,	'SIMPLE'	)	,
	('du7G.'	,	'*NICOPATCH 7mg/24hours patches'                                ,	'S'	,	'SIMPLE'	)	,
	('du7g.'	,	'NICORETTE COOLS 2mg lozenges'                                  ,	'S'	,	'SIMPLE'	)	,
	('du7H.'	,	'NICOPATCH 14mg/24hours patches'	                            ,	'S'	,	'SIMPLE'	)	,
	('du7h.'	,	'NICORETTE COOLS 4mg lozenges'                                  ,	'S'	,	'SIMPLE'	)	,
	('du7I.'	,	'NICOPATCH 21mg/24hours patches'	                            ,	'S'	,	'SIMPLE'	)	,
	('du7i.'	,	'NIQUITIN PRE-QUIT 21mg/24 hours clear patches'		            ,	'S'	,	'SIMPLE'	)	,
	('du7J.'	,	'NICOPASS 1.5mg fresh mint lozenges'	                        ,	'S'	,	'SIMPLE'	)	,
	('du7j.'	,	'NICORETTE FRUITFUSION 2mg chewing gum'		                    ,	'S'	,	'SIMPLE'	)	,
	('du7K.'	,	'NICOPASS 1.5mg liquorice mint lozenges'	                    ,	'S'	,	'SIMPLE'	)	,
	('du7k.'	,	'NICORETTE FRUITFUSION 4mg chewing gum'		                    ,	'S'	,	'SIMPLE'	)	,
	('du7l.'	,	'NICORETTE FRUITFUSION 6mg chewing gum'		                    ,	'S'	,	'SIMPLE'	)	,
	('du7L.'	,	'NIQUITIN PRE-QUIT 4mg mint lozenges'	                        ,	'S'	,	'SIMPLE'	)	,
	('du7M.'	,	'NICORETTE INVISI 10mg patches'                                 ,	'S'	,	'SIMPLE'	)	,
	('du7N.'	,	'NICORETTE INVISI 15mg patches'                                 ,	'S'	,	'SIMPLE'	)	,
	('du7n.'	,	'NICOTINE 6mg fruit chewing gum'								,	'S'	,	'SIMPLE'	)	,
	('du7O.'	,	'NICORETTE INVISI 25mg patches'									,	'S'	,	'SIMPLE'	)	,
	('du7o.'	,	'NICOTINE 4mg icemint chewing gum'								,	'S'	,	'SIMPLE'	)	,
	('du7P.'	,	'NICORETTE ICY WHITE 2mg chewing gum'							,	'S'	,	'SIMPLE'	)	,
	('du7p.'	,	'NICOTINE 2mg icemint chewing gum'								,	'S'	,	'SIMPLE'	)	,
	('du7Q.'	,	'NICORETTE ICY WHITE 4mg chewing gum' 							,	'S'	,	'SIMPLE'	)	,
	('du7q.'	,	'NICOTINE 1mg oromucosal spray'									,	'S'	,	'SIMPLE'	)	,
	('du7r.'	,	'NICOTINE 1.5mg cherry lozenges'								,	'S'	,	'SIMPLE'	)	,
	('du7R.'	,	'NIQUITIN MINIS MINT 1.5mg lozenges'							,	'S'	,	'SIMPLE'	)	,
	('du7s.'	,	'NICOTINE 4mg cherry lozenges'									,	'S'	,	'SIMPLE'	)	,
	('du7S.'	,	'NIQUITIN MINIS MINT 4mg lozenges'								,	'S'	,	'SIMPLE'	)	,
	('du7T.'	,	'NICORETTE MICROTAB LEMON 2mg sublingual tablets'				,	'S'	,	'SIMPLE'	)	,
	('du7t.'	,	'NICOTINE 15mg/16hours patches and 2mg chewing gum'				,	'S'	,	'SIMPLE'	)	,
	('du7U.'	,	'NICORETTE COMBI 15mg patches and 2mg chewing gum'				,	'S'	,	'SIMPLE'	)	,
	('du7u.'	,	'NICOTINE 1.5mg lozenges'										,	'S'	,	'SIMPLE'	)	,
	('du7v.'	,	'NICOTINE 25mg/16hours patches'									,	'S'	,	'SIMPLE'	)	,
	('du7V.'	,	'NIQUITIN MINIS 1.5mg cherry lozenges'							,	'S'	,	'SIMPLE'	)	,
	('du7w.'	,	'NICOTINE 1.5mg fresh mint lozenges'							,	'S'	,	'SIMPLE'	)	,
	('du7W.'	,	'NIQUITIN MINIS 4mg cherry lozenges'							,	'S'	,	'SIMPLE'	)	,
	('du7X.'	,	'NICORETTE FRESHMINT 2mg lozenges'								,	'S'	,	'SIMPLE'	)	,
	('du7x.'	,	'NICOTINE 1.5mg liquorice mint lozenges'						,	'S'	,	'SIMPLE'	)	,
	('du7Y.'	,	'NICORETTE QUICKMIST 1mg oromucosal spray'						,	'S'	,	'SIMPLE'	)	,
	('du7y.'	,	'NICOTINE 4mg liquorice chewing gum'							,	'S'	,	'SIMPLE'	)	,
	('du7z.'	,	'NICOTINE 2mg liquorice chewing gum'							,	'S'	,	'SIMPLE'	)	,
	('du7Z.'	,	'NICOTINELL ICEMINT 2mg chewing gum'							,	'S'	,	'SIMPLE'	)	,
	('du8..'	,	'VARENICLINE'													,	'S'	,	'SIMPLE'	)	,
	('du81.'	,	'CHAMPIX 1mg tablets'											,	'S'	,	'SIMPLE'	)	,
	('du82.'	,	'CHAMPIX 500microgram tablets'									,	'S'	,	'SIMPLE'	)	,
	('du83.'	,	'CHAMPIX TREATMENT INITIATION pack'								,  	'S'	,	'SIMPLE'	)	,
	('du8x.'	,	'VARENICLINE 500micrograms+1mg tablets'							,  	'S'	,	'SIMPLE'	)	,
	('du8y.'	,	'VARENICLINE 500microgram tablets'								,	'S'	,	'SIMPLE'	)	,
	('du8z.'	,	'VARENICLINE 1mg tablets'										,	'S'	,	'SIMPLE'	)	,
	('du9..'	,	'NICOTINE WITHDRAWAL PRODUCTS'									,	'S'	,	'SIMPLE'	)	,
	('du91.'	,	'NICOBREVIN capsules'											,	'S'	,	'SIMPLE'	)	,
	('duB1.'	,	'NIQUITIN STRIPS 2.5mg mint oral film'							,	'S'	,	'SIMPLE'	)	,
	('duB2.'	,	'NIQUITIN MINIS 1.5mg orange lozenges'							,	'S'	,	'SIMPLE'	)	,
	('duB3.'	,	'NICOTINELL SUPPORT ICEMINT 2mg chewing gum'					,	'S'	,	'SIMPLE'	)	,
	('duB4.'	,	'NICOTINELL SUPPORT ICEMINT 4mg chewing gum'					,	'S'	,	'SIMPLE'	)	,
	('duBz.'	,	'NICOTINE 2.5mg oral film'										,	'S'	,	'SIMPLE'	)	,
	('E023.'	,	'Nicotine withdrawal'											,  	'S'	,	'SIMPLE'	)	,
	('E251.'	,	'Tobacco dependence'											,	'S'	,	'SIMPLE'	)	,
	('E2510'	,	'Tobacco dependence, unspecified'								,	'S'	,	'SIMPLE'	)	,
	('E2511'	,	'Tobacco dependence, continuous'								,	'S'	,	'SIMPLE'	)	,
	('E2512'	,	'Tobacco dependence, episodic'									,	'S'	,	'SIMPLE'	)	,
	('E2513'	,	'Tobacco dependence in remission'								,	'S'	,	'SIMPLE'	)	,
	('E251z'	,	'Tobacco dependence NOS'										,	'S'	,	'SIMPLE'	)	,
	('J0364'	,	'Tobacco deposit on teeth'										,	'S'	,	'SIMPLE'	)	,
	('SMC..'	,	'Toxic effect of tobacco and nicotine'							,	'S'	,	'SIMPLE'	)	,
	('U6099'	,	'[X]Bupropion causing adverse effects in therapeutic use'		,	'S'	,	'SIMPLE'	)	,
	('ZV4K0'	,	'[V]Tobacco use'												,	'S'	,	'SIMPLE'	)	,
	('ZV6D8'	,	'[V]Tobacco abuse counselling'									,	'S'	,	'SIMPLE'	)
	;
COMMIT;

CALL SYSPROC.ADMIN_CMD('runstats on table SAILW0972V.SMOKER_LOOKUP with distribution and detailed indexes all'); -- makes tables compatible with all functions e.g. avg etc

COMMIT;

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
----------------------------- Expand the user table ----------------------------

-- this expands the user table to include EVENT_ details for the ALFs specified

CALL FNC.DROP_IF_EXISTS ('SAILW0972V.input_USER_smoking');

CREATE TABLE sailW0972V.input_USER_smoking
(
 	    patient_id      BIGINT,
        alf_sts_cd      INTEGER,
        diag_date		DATE,
        event_dt        DATE,
        event_cd        CHAR(100),
        event_val		DECIMAL(31,8)
)
DISTRIBUTE BY HASH (PATIENT_ID);--previously was best practise, but might be outdated now

COMMIT;

GRANT ALL ON TABLE SAILW0972V.input_USER_smoking TO ROLE NRDASAIL_SAIL_0972_ANALYST; --granting access to team mates

alter table SAILW0972V.input_USER_smoking activate not logged INITIALLY;

insert into SAILW0972V.input_USER_smoking
SELECT  US.ALF_PE,
        GP.ALF_STS_CD,
        US.DIAG_DATE,
        GP.EVENT_DT,
        GP.EVENT_CD,
        GP.EVENT_VAL
	FROM SAILW0972V.gp_database AS gp
	INNER JOIN SAILW0972V.SMOKER_LOOKUP AS lkp
		ON gp.event_cd = lkp.SM_CODE
		AND gp.event_DT >= DATE('2000-01-01')
		AND gp.event_DT < CURRENT_DATE
	RIGHT JOIN SAILW0972V.input_USER_table AS US
	ON gp.alf_pe = us.alf_pe		
GROUP BY US.ALF_PE,
        GP.ALF_STS_CD,
        US.DIAG_DATE,
        GP.EVENT_DT,
        GP.EVENT_CD,
        GP.EVENT_VAL; 
       
COMMIT;
CALL SYSPROC.ADMIN_CMD('runstats on table SAILW0972V.input_USER_smoking with distribution and detailed indexes all'); -- makes tables compatible with all functions e.g. avg etc
COMMIT;

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-------- Create event table that combines lookup table and user table ----------

-- combines selected tables using the variables declared above


--DROP TABLE SAILW0972V.GP_SMOKE_EVENT;
CALL FNC.DROP_IF_EXISTS ('SAILW0972V.GP_SMOKE_EVENT');

CREATE TABLE sailW0972V.gp_smoke_event
(
        patient_id 		        BIGINT,
        alf_sts_cd		        INTEGER,
        diag_date				DATE,
        event_dt  		        VARCHAR(10),
        event_cd  		        CHAR(6),
        complexity				VARCHAR(20),
        event_val				DECIMAL(31,8),
        description  		    VARCHAR(300),
        smoking_status 			VARCHAR(1),
        diff_day				INTEGER, -- this is the difference between the diagnosis date and the event date
        row_seq					INTEGER, -- ranks the event dates in order from most recent per ALF
        dd_minus_smoker_period	DATE, -- diagnosis date - the ex-smoker cutoff period
        ss_during_cutoff		VARCHAR(20), -- whether or not there is a smoker recording during the period above
        ever_smoked				CHAR(1)
)
DISTRIBUTE BY HASH (patient_id); --previously was best practise, but might be outdated now
COMMIT;

--granting access to team mates
GRANT ALL ON TABLE SAILW0972V.GP_SMOKE_EVENT TO ROLE NRDASAIL_SAIL_0972_ANALYST;

--worth doing for large chunks of data
alter table SAILW0972V.GP_SMOKE_EVENT activate not logged INITIALLY;

insert into SAILW0972V.GP_SMOKE_EVENT
SELECT DISTINCT 	PATIENT_ID,
					ALF_STS_CD,
					DIAG_DATE,
					EVENT_DT,
					EVENT_CD,
					COMPLEXITY,
					EVENT_VAL,
					DESCRIPTION,
					SMOKING_STATUS,
					DIFF_DAY,
					ROW_NUMBER() OVER(PARTITION BY PATIENT_ID ORDER BY DIFF_DAY), -- ranks the event dates in order from most recent per ALF
					DD_MINUS_SMOKER_PERIOD, -- diagnosis date - the ex-smoker cutoff period
					CASE 	WHEN SMOKING_STATUS = 'S'
							AND EVENT_DT BETWEEN DATE(DD_MINUS_SMOKER_PERIOD) AND DATE(DIAG_DATE) THEN 'S'
							ELSE NULL END AS SS_DURING_CUTOFF,
							-- assigns smoker status to anyone with a smoker recording during the period above
					CASE 	WHEN SAILW0972V.input_smoking_date_cutoff <> 'NULL' THEN
								(CASE	WHEN SMOKING_STATUS = 'S' AND EVENT_DT<= SAILW0972V.input_smoking_date_cutoff THEN '1'
										WHEN SMOKING_STATUS = 'E' AND EVENT_DT<= SAILW0972V.input_smoking_date_cutoff THEN '1'
										ELSE NULL
										END)
							WHEN SAILW0972V.input_smoking_date_cutoff = 'NULL' THEN
								(CASE	WHEN SMOKING_STATUS = 'S' AND EVENT_DT<= DIAG_DATE THEN '1'
										WHEN SMOKING_STATUS = 'E' AND EVENT_DT<= DIAG_DATE THEN '1'
										ELSE NULL
										END)
							END AS EVER_SMOKED
				FROM
(select
    distinct
        PATIENT_ID,
        STS.ALF_STS_CD,
        US.DIAG_DATE,
		US.EVENT_DT,
		US.EVENT_CD,
        US.EVENT_VAL,
        LU.DESCRIPTION,
		CASE	WHEN (COMPLEXITY = 'EVENT_VAL DEPENDENT' AND EVENT_VAL > 0) THEN 'S'
				WHEN (COMPLEXITY = 'EVENT_VAL DEPENDENT' AND EVENT_VAL = '0') THEN NULL
				WHEN (COMPLEXITY = 'EVENT_VAL DEPENDENT' AND EVENT_VAL IS NULL) THEN NULL
				ELSE LU.SMOKING_STATUS
				END AS SMOKING_STATUS, -- These cases are only classed as smoker when event_val > 0, otherwise they are unknown
		LU.COMPLEXITY,
		DAYS(US.DIAG_DATE) - DAYS(US.EVENT_DT) AS DIFF_DAY, -- this is the difference between the diagnosis date and the event date
		US.DIAG_DATE - SAILW0972V.ex_smoker_cutoff AS DD_MINUS_SMOKER_PERIOD -- ex smoker classification cutoff
FROM    SAILW0972V.input_USER_smoking US -- extract data from user table
RIGHT OUTER JOIN
(
	SELECT * FROM SAILW0972V.SMOKER_LOOKUP
) LU --extract data from Look up table (read codes)
	ON
	(US.EVENT_CD = LU.SM_CODE)
RIGHT OUTER JOIN
(
	SELECT * FROM SAILW0972V.ALF_STS_CD_SMOKING
) STS -- limit results to those that have the desired STS codes (default is 1, 4, 39)
	ON
	(US.ALF_STS_CD = STS.ALF_STS_CD)
 WHERE
    PATIENT_ID IS NOT NULL
AND  -- restrict to events before diagnosis
	CASE	WHEN SAILW0972V.input_smoking_date_cutoff <> 'NULL' THEN US.DIAG_DATE <= SAILW0972V.input_smoking_date_cutoff -- only extract cases where diagnosis date is before the cutoff
			WHEN SAILW0972V.input_smoking_date_cutoff = 'NULL' THEN US.DIAG_DATE = US.DIAG_DATE
			END
AND --restrict to events before the cutoff
	CASE	WHEN SAILW0972V.input_smoking_date_cutoff = 'NULL' THEN US.EVENT_DT <= US.DIAG_DATE
			WHEN SAILW0972V.input_smoking_date_cutoff <> 'NULL' THEN US.EVENT_DT <= SAILW0972V.input_smoking_date_cutoff
			END
GROUP BY PATIENT_ID, EVENT_DT, EVENT_CD, STS.ALF_STS_CD, DIAG_DATE, EVENT_VAL, DESCRIPTION, SMOKING_STATUS, COMPLEXITY -- not entirely sure if necessary?
ORDER BY PATIENT_ID, EVENT_DT, EVENT_CD, STS.ALF_STS_CD, DIAG_DATE, EVENT_VAL, DESCRIPTION, SMOKING_STATUS, COMPLEXITY
)
 WHERE DIFF_DAY >= 0 	-- limit data to entries with event_dt before diagnosis date
					-- IF YOU WANT TO CHANGE TO ENTRIES AFTER DIAGNOSIS REPLACE WITH 'DIFF_DAY < 0'
    ;
COMMIT;

--update GP smoking table to add ever smoked

alter table SAILW0972V.GP_SMOKE_EVENT
ADD COLUMN EVER_SMOKED_SUM INTEGER;

UPDATE SAILW0972V.GP_SMOKE_EVENT
SET EVER_SMOKED_SUM  = CASE WHEN SUM(EVER_SMOKED) OVER(PARTITION BY PATIENT_ID) IS NOT NULL
								THEN SUM(EVER_SMOKED) OVER(PARTITION BY PATIENT_ID)
									ELSE 0
							END;

CALL SYSPROC.ADMIN_CMD('runstats on table SAILW0972V.GP_SMOKE_EVENT with distribution and detailed indexes all'); -- makes tables compatible with all functions e.g. avg etc

COMMIT;

--checks
SELECT * FROM SAILW0972V.GP_SMOKE_EVENT
GROUP BY PATIENT_ID, EVENT_DT, EVENT_CD, ALF_STS_CD, DIAG_DATE, EVENT_VAL, COMPLEXITY, DESCRIPTION, SMOKING_STATUS, DIFF_DAY, ROW_SEQ, DD_MINUS_SMOKER_PERIOD, SS_DURING_CUTOFF,EVER_SMOKED, EVER_SMOKED_SUM
ORDER BY PATIENT_ID, DIFF_DAY;

SELECT DISTINCT ALF_STS_CD FROM SAILW0972V.GP_SMOKE_EVENT;
SELECT MIN(EVENT_DT) AS MIN_EVENT_DT, MAX(EVENT_DT) AS MAX_EVENT_DT, MIN(DIAG_DATE) AS MIN_DIAG_DT, MAX(DIAG_DATE) AS MAX_DIAG_DT FROM SAILW0972V.GP_SMOKE_EVENT;
-- SELECT * FROM SAILW0972V.GP_SMOKE_EVENT WHERE DIAG_DATE < EVENT_DT; -- check to see if the recorded events are within your specified time frame

-----------------------------------------------------------------------------
--identify same day smoking category mismatches and set to smoking status unclear

--Multi smoking categories

CALL FNC.DROP_IF_EXISTS('SAILW0972V.VB_MULTI_SMOK_CAT_wlgp_uti');

CREATE TABLE SAILW0972V.VB_MULTI_SMOK_CAT_wlgp_uti AS
(SELECT PATIENT_ID, DIAG_DATE, EVENT_DT FROM SAILW0972V.GP_SMOKE_EVENT OP)
WITH NO DATA;

INSERT INTO SAILW0972V.VB_MULTI_SMOK_CAT_wlgp_uti
(SELECT PATIENT_ID, DIAG_DATE, EVENT_DT FROM
(SELECT DISTINCT PATIENT_ID,
				DIAG_DATE,
				EVENT_DT, 
				CASE WHEN SS_DURING_CUTOFF = 'S' THEN 'S'
					WHEN SMOKING_STATUS = 'S' THEN 'S'
					WHEN SMOKING_STATUS = 'E' THEN 'E'
					WHEN SMOKING_STATUS = 'N' AND EVER_SMOKED_SUM > 0 THEN 'E' -- if ALF has ever been recorded as smoker or ex smoker, then sum(ever_smoker) > 0
					WHEN SMOKING_STATUS IS NULL THEN NULL
						ELSE 'N'
							END	AS SMOKER_STATUS
			FROM SAILW0972V.GP_SMOKE_EVENT OP
ORDER BY PATIENT_ID, EVENT_DT)
GROUP BY PATIENT_ID, DIAG_DATE, EVENT_DT
HAVING COUNT(PATIENT_ID||DIAG_DATE||EVENT_DT) > 1);

-------------------------------------------------------------------------------------------------
--Single smoking categories
CALL FNC.DROP_IF_EXISTS('SAILW0972V.VB_SINGLE_SMOK_CAT_wlgp_uti');

CREATE TABLE SAILW0972V.VB_SINGLE_SMOK_CAT_wlgp_uti AS
(SELECT PATIENT_ID, DIAG_DATE, EVENT_DT FROM SAILW0972V.GP_SMOKE_EVENT OP)
WITH NO DATA;

INSERT INTO SAILW0972V.VB_SINGLE_SMOK_CAT_wlgp_uti
(SELECT PATIENT_ID, DIAG_DATE, EVENT_DT FROM
(SELECT DISTINCT PATIENT_ID,
				DIAG_DATE,
				EVENT_DT, 
				CASE WHEN SS_DURING_CUTOFF = 'S' THEN 'S'
					WHEN SMOKING_STATUS = 'S' THEN 'S'
					WHEN SMOKING_STATUS = 'E' THEN 'E'
					WHEN SMOKING_STATUS = 'N' AND EVER_SMOKED_SUM > 0 THEN 'E' -- if ALF has ever been recorded as smoker or ex smoker, then sum(ever_smoker) > 0
					WHEN SMOKING_STATUS IS NULL THEN NULL
						ELSE 'N'
							END	AS SMOKER_STATUS
			FROM SAILW0972V.GP_SMOKE_EVENT OP
ORDER BY PATIENT_ID, EVENT_DT)
GROUP BY PATIENT_ID, DIAG_DATE, EVENT_DT
HAVING COUNT(PATIENT_ID||DIAG_DATE||EVENT_DT) = 1);

-----------------------------------------------------------------------------
-----------------------------------------------------------------------------
----------------------- Create Output table ---------------------------------

-- table takes data from the EVENT table and record one smoker status per ALF,
-- rewriting the status where necessary based on their smoking history within
-- the cutoff period

--DROP TABLE SAILW0972V.GP_SMOKE_EVENT;
CALL FNC.DROP_IF_EXISTS ('SAILW0972V.VB_SMOKER_OUTPUT_wlgp_uti_PRE');

CREATE TABLE SAILW0972V.VB_SMOKER_OUTPUT_wlgp_uti_PRE
(
        patient_id    		    	    BIGINT,
        diag_date					DATE,
        event_dt					DATE,
        smoking_status 				CHAR(1),
        smoking_status_description	VARCHAR(15)
)
DISTRIBUTE BY HASH (PATIENT_ID);--previously was best practise, but might be outdated now

COMMIT;

--granting access to team mates
GRANT ALL ON TABLE SAILW0972V.VB_SMOKER_OUTPUT_wlgp_uti_PRE TO ROLE NRDASAIL_SAIL_0972_ANALYST;

--worth doing for large chunks of data
alter table SAILW0972V.VB_SMOKER_OUTPUT_wlgp_uti_PRE activate not logged INITIALLY;

--Insert no smoking category mismatches
INSERT INTO SAILW0972V.VB_SMOKER_OUTPUT_wlgp_uti_PRE
SELECT PATIENT_ID,
	DIAG_DATE,
	EVENT_DT,
	CASE WHEN SS_DURING_CUTOFF = 'S' THEN 'S'
					WHEN SMOKING_STATUS = 'S' THEN 'S'
					WHEN SMOKING_STATUS = 'E' THEN 'E'
					WHEN SMOKING_STATUS = 'N' AND EVER_SMOKED_SUM > 0 THEN 'E' -- if ALF has ever been recorded as smoker or ex smoker, then sum(ever_smoker) > 0
					WHEN SMOKING_STATUS IS NULL THEN NULL
						ELSE 'N'
							END	AS SMOKING_STATUS,
	CASE WHEN SS_DURING_CUTOFF = 'S' THEN 'SMOKER'
					WHEN SMOKING_STATUS = 'S' THEN 'SMOKER'
					WHEN SMOKING_STATUS = 'E' THEN 'EX-SMOKER'
					WHEN SMOKING_STATUS = 'N' AND EVER_SMOKED_SUM > 0 THEN 'EX-SMOKER' -- if ALF has ever been recorded as smoker or ex smoker, then sum(ever_smoker) > 0
					WHEN SMOKING_STATUS IS NULL THEN NULL
						ELSE 'NEVER SMOKED'
							END AS SMOKER_STATUS_DESCRIPTION
FROM SAILW0972V.GP_SMOKE_EVENT AS OP
WHERE OP.PATIENT_ID||OP.DIAG_DATE||OP.EVENT_DT
IN (SELECT SI.PATIENT_ID||SI.DIAG_DATE||SI.EVENT_DT FROM SAILW0972V.VB_SINGLE_SMOK_CAT_wlgp_uti AS SI);

--Insert smoking category mismatches
INSERT INTO SAILW0972V.VB_SMOKER_OUTPUT_wlgp_uti_PRE
SELECT PATIENT_ID,
	DIAG_DATE,
	EVENT_DT,
	'U',
	'UNCLEAR'
FROM SAILW0972V.GP_SMOKE_EVENT AS OP
WHERE OP.PATIENT_ID||OP.DIAG_DATE||OP.EVENT_DT
IN (SELECT SI.PATIENT_ID||SI.DIAG_DATE||SI.EVENT_DT FROM SAILW0972V.VB_MULTI_SMOK_CAT_wlgp_uti AS SI);


ALTER TABLE SAILW0972V.VB_SMOKER_OUTPUT_wlgp_uti_PRE
ADD COLUMN ROW_SEQ INTEGER;

UPDATE SAILW0972V.VB_SMOKER_OUTPUT_wlgp_uti_PRE
SET ROW_SEQ = ROW_NUMBER() OVER(PARTITION BY PATIENT_ID ORDER BY EVENT_DT desc);

CALL FNC.DROP_IF_EXISTS ('SAILW0972V.VB_SMOKER_OUTPUT_wlgp_uti');

CREATE TABLE SAILW0972V.VB_SMOKER_OUTPUT_wlgp_uti
(
        patient_id    		    	BIGINT,
        diag_date					DATE,
        smoking_status 				CHAR(1),
        smoking_status_description	VARCHAR(15)
)
DISTRIBUTE BY HASH (PATIENT_ID);

COMMIT;

INSERT INTO SAILW0972V.VB_SMOKER_OUTPUT_wlgp_uti
SELECT PATIENT_ID, DIAG_DATE, SMOKING_STATUS, SMOKING_STATUS_DESCRIPTION FROM SAILW0972V.VB_SMOKER_OUTPUT_wlgp_uti_PRE
WHERE ROW_SEQ = 1;

SELECT COUNT(DISTINCT PATIENT_ID) AS ORIGINAL_DATASET_COUNT FROM SAILW0972V.input_USER_smoking;
SELECT COUNT(DISTINCT PATIENT_ID) AS OUTPUT_TABLE_COUNT FROM SAILW0972V.VB_SMOKER_OUTPUT_wlgp_uti;
SELECT COUNT(PATIENT_ID), SMOKING_STATUS FROM SAILW0972V.VB_SMOKER_OUTPUT_wlgp_uti
GROUP BY SMOKING_STATUS;	
	
-------------------------------------------------------------------------------------------------	
	
/* update MI cohort table with smoker status */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN SMOKING_STATUS_DESCRIPTION VARCHAR(30);

MERGE INTO sailw0972v.vb_wlgp_sub AS fe
	USING SAILW0972V.VB_SMOKER_OUTPUT_wlgp_uti AS smi
		ON fe.ALF_PE = smi.PATIENT_ID
			WHEN MATCHED THEN
				UPDATE
				SET fe.SMOKING_STATUS_DESCRIPTION = smi.SMOKING_STATUS_DESCRIPTION
			;
			
------------------------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------------------------------------------------------------------------------
	
/* EFI */
					
--Please cite: 
-- External validation of the electronic Frailty Index using the population of Wales within the Secure Anonymised Information Linkage Databank
-- J Hollinghurst et al
-- Age and Ageing
--DOI https://doi.org/10.1093/ageing/afz110
-- AND
-- Development and validation of an electronic Frailty Index using routine primary care electronic health record data
--Clegg et al
--Age and Ageing
--DOI https://doi.org/10.1093/ageing/afw039
	
CREATE OR REPLACE ALIAS SAILW0972V.V2_GPDATA 
FOR SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301;

CALL FNC.DROP_IF_EXISTS ('SAILW0972V.vb_wlgp_sub_COHORT_EFI');

CALL FNC.DROP_IF_EXISTS ('SAILW0972V.V2_cohort_with_dummy_date');

CREATE TABLE SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS (SELECT ALF_PE, diag_dt AS event_dt FROM sailw0972v.vb_wlgp_sub ) WITH no DATA ;

INSERT INTO SAILW0972V.V2_COHORT_WITH_DUMMY_DATE 
SELECT ALF_PE, diag_dt AS event_dt FROM sailw0972v.vb_wlgp_sub;

--drop table SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF1

 CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF1 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF1(
		SELECT
			ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			(EVENT_CD = '39F..'
			AND EVENT_VAL < 19)
			OR (EVENT_CD IN ( '13O5.',
			'13V8.',
			'13VC.',
			'8F6..',
			'9EB5.' ) )
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF2 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF2 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			((EVENT_CD = '423..'
			AND EVENT_VAL BETWEEN 0 AND 12.5)
			OR (EVENT_CD = '423..'
			AND EVENT_VAL BETWEEN 25 AND 125)
			--need to take in to account a change in magnitude of measurement
			OR (EVENT_CD IN ( '145..',
			'1451.',
			'1452.',
			'1453.',
			'1454.',
			'2C23.',
			'42R41',
			'42T2.',
			'66E5.',
			'7Q090',
			'7Q091',
			'B9370',
			'B9371',
			'B9372',
			'B9373',
			'B937X',
			'BBmA.',
			'BBmB.',
			'BBmL.',
			'ByuHC',
			'C2620',
			'C2621',
			'D0...',
			'D00..',
			'D000.',
			'D001.',
			'D00y.',
			'D00y1',
			'D00yz',
			'D00z.',
			'D00z0',
			'D00z1',
			'D00z2',
			'D00zz',
			'D01..',
			'D010.',
			'D011.',
			'D0110',
			'D0111',
			'D011X',
			'D011z',
			'D012.',
			'D0121',
			'D0122',
			'D0123',
			'D0124',
			'D0125',
			'D012z',
			'D013.',
			'D0130',
			'D013z',
			'D014.',
			'D0140',
			'D014z',
			'D01y.',
			'D01yy',
			'D01yz',
			'D01z.',
			'D01z0',
			'D0y..',
			'D0z..',
			'D1...',
			'D104.',
			'D1040',
			'D1047',
			'D104z',
			'D106.',
			'D1060',
			'D1061',
			'D1062',
			'D106z',
			'D11..',
			'D110.',
			'D1100',
			'D1101',
			'D1102',
			'D1103',
			'D1104',
			'D110z',
			'D111.',
			'D1110',
			'D1111',
			'D1112',
			'D1114',
			'D1115',
			'D111y',
			'D111z',
			'D112z',
			'D11z.',
			'D1y..',
			'D1z..',
			'D2...',
			'D20..',
			'D200.',
			'D2000',
			'D2002',
			'D200y',
			'D200z',
			'D201.',
			'D2010',
			'D2011',
			'D2012',
			'D2013',
			'D2014',
			'D2017',
			'D201z',
			'D204.',
			'D20z.',
			'D21..',
			'D210.',
			'D2101',
			'D2103',
			'D2104',
			'D210z',
			'D211.',
			'D212.',
			'D2120',
			'D213.',
			'D214.',
			'D215.',
			'D2150',
			'D21y.',
			'D21yy',
			'D21yz',
			'D21z.',
			'D2y..',
			'D2z..',
			'Dyu0.',
			'Dyu00',
			'Dyu01',
			'Dyu02',
			'Dyu03',
			'Dyu04',
			'Dyu05',
			'Dyu06',
			'Dyu1.',
			'Dyu15',
			'Dyu16',
			'Dyu17',
			'Dyu2.',
			'Dyu21',
			'Dyu22',
			'Dyu23',
			'Dyu24',
			'J6141' )))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF3 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF3 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			(EVENT_CD IN ( '14G..',
			'14G1.',
			'14G2.',
			'52A31',
			'52A71',
			'66H..',
			'N0504',
			'7K3..',
			'7K30.',
			'7K32.',
			'7K6Z3',
			'7K6Z7',
			'7K6ZK',
			'C340.',
			'C34z.',
			'N023.',
			'N0310',
			'N04..',
			'N040.',
			'N0400',
			'N0401',
			'N0402',
			'N0404',
			'N0405',
			'N0407',
			'N0408',
			'N0409',
			'N040A',
			'N040B',
			'N040C',
			'N040D',
			'N040F',
			'N040G',
			'N040H',
			'N040J',
			'N040K',
			'N040L',
			'N040M',
			'N040P',
			'N040S',
			'N040T',
			'N047.',
			'N04X.',
			'N05..',
			'N050.',
			'N0502',
			'N0504',
			'N0506',
			'N0535',
			'N0536',
			'N05z1',
			'N05z4',
			'N05z5',
			'N05z6',
			'N05z9',
			'N05zJ',
			'N05zL',
			'N06z.',
			'N06z5',
			'N06z6',
			'N06zz',
			'N11..',
			'N11D.',
			'Nyu10',
			'Nyu11',
			'Nyu12',
			'Nyu1G' ))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF4 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF4 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			((EVENT_CD = '38DE.')
			OR (EVENT_CD IN ( '14AN.',
			'2432.',
			'3272.',
			'3273.',
			'662S.',
			'6A9..',
			'7936A',
			'9Os1.',
			'9hF0.',
			'9hF1.',
			'G573.',
			'G5730',
			'G5731',
			'G5732',
			'G5733',
			'G5734',
			'G5735',
			'G573z' )))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF5 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF5 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			(EVENT_CD IN ( '14A7.',
			'14AB.',
			'14AK.',
			'662M.',
			'662e.',
			'662o.',
			'7P242',
			'8HBJ.',
			'8HHM.',
			'8HTQ.',
			'9N0p.',
			'9N4X.',
			'9Om1.',
			'9Om2.',
			'9Om3.',
			'9Om4.',
			'9h21.',
			'9h22.',
			'F4236',
			'G6...',
			'G61..',
			'G621.',
			'G622.',
			'G631.',
			'G634.',
			'G64..',
			'G640.',
			'G65..',
			'G65y.',
			'G65z.',
			'G65z1',
			'G65zz',
			'G66..',
			'G663.',
			'G664.',
			'G667.',
			'G670.',
			'G6711',
			'G682.',
			'G68X.',
			'Gyu6.',
			'Gyu6B',
			'Gyu6C',
			'S62..',
			'S620.',
			'S622.',
			'S627.',
			'S628.',
			'S629.',
			'S6290' ))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF6 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF6 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			((EVENT_CD = '46W..'
			AND EVENT_VAL > 30)
			OR (EVENT_CD = '46TC.'
			AND EVENT_VAL > 30)
			OR (EVENT_CD = '46N7.'
			AND EVENT_VAL > 45)
			OR (EVENT_CD = '46N4.'
			AND EVENT_VAL > 30)
			OR (EVENT_CD = '46N..'
			AND EVENT_VAL > 150)
			OR (EVENT_CD = '451F.'
			AND EVENT_VAL < 60)
			OR (EVENT_CD IN ( '1Z1..',
			'1Z12.',
			'1Z13.',
			'1Z14.',
			'1Z15.',
			'1Z16.',
			'1Z1B.',
			'1Z1C.',
			'1Z1D.',
			'1Z1E.',
			'1Z1F.',
			'1Z1G.',
			'1Z1H.',
			'1Z1J.',
			'1Z1K.',
			'1Z1L.',
			'4677.',
			'6AA..',
			'9hE0.',
			'9hE1.',
			'C104.',
			'C104y',
			'C104z',
			'C1080',
			'C108D',
			'C1090',
			'C1093',
			'C109C',
			'C10E0',
			'C10ED',
			'C10EK',
			'C10EL',
			'C10F0',
			'C10F3',
			'C10FC',
			'C10FL',
			'C10FM',
			'Cyu23',
			'K05..',
			'K050.',
			'PD13.',
			'R110.' )))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF7 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF7 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			(EVENT_CD IN ( '2BBR.',
			'2BBS.',
			'2BBT.',
			'2G5L.',
			'42W3.',
			'42c..',
			'66A..',
			'66A4.',
			'66A5.',
			'66AD.',
			'66AH0',
			'66AJ.',
			'66AR.',
			'66AS.',
			'66AU.',
			'66AZ.',
			'66Ab.',
			'66Ac.',
			'66Ai.',
			'66Aq.',
			'68A7.',
			'8A17.',
			'8BL2.',
			'8CR2.',
			'8H7f.',
			'8HBG.',
			'8HBH.',
			'8Hl1.',
			'9NND.',
			'9OL1.',
			'9OLD.',
			'9h4..',
			'9h41.',
			'9h42.',
			'C10..',
			'C100.',
			'C1000',
			'C1001',
			'C100z',
			'C101.',
			'C1010',
			'C1011',
			'C101y',
			'C101z',
			'C102.',
			'C102z',
			'C103.',
			'C1030',
			'C1031',
			'C103y',
			'C104.',
			'C104y',
			'C104z',
			'C105.',
			'C105y',
			'C105z',
			'C106.',
			'C1061',
			'C106y',
			'C106z',
			'C107.',
			'C107z',
			'C108.',
			'C1080',
			'C1081',
			'C1082',
			'C1083',
			'C1085',
			'C1086',
			'C1087',
			'C1088',
			'C1089',
			'C108A',
			'C108B',
			'C108C',
			'C108D',
			'C108E',
			'C108F',
			'C108J',
			'C108y',
			'C108z',
			'C109.',
			'C1090',
			'C1091',
			'C1092',
			'C1093',
			'C1094',
			'C1095',
			'C1096',
			'C1097',
			'C1099',
			'C109A',
			'C109B',
			'C109C',
			'C109D',
			'C109E',
			'C109F',
			'C109G',
			'C109H',
			'C109J',
			'C10A1',
			'C10B0',
			'C10C.',
			'C10D.',
			'C10E.',
			'C10E0',
			'C10E1',
			'C10E2',
			'C10E3',
			'C10E5',
			'C10E6',
			'C10E7',
			'C10E8',
			'C10E9',
			'C10EA',
			'C10EB',
			'C10EC',
			'C10ED',
			'C10EE',
			'C10EF',
			'C10EJ',
			'C10EK',
			'C10EL',
			'C10EM',
			'C10EN',
			'C10EP',
			'C10EQ',
			'C10ER',
			'C10F.',
			'C10F0',
			'C10F1',
			'C10F2',
			'C10F3',
			'C10F4',
			'C10F5',
			'C10F6',
			'C10F7',
			'C10F9',
			'C10FA',
			'C10FB',
			'C10FC',
			'C10FD',
			'C10FE',
			'C10FF',
			'C10FG',
			'C10FH',
			'C10FJ',
			'C10FL',
			'C10FM',
			'C10FN',
			'C10FP',
			'C10FQ',
			'C10FR',
			'C10H.',
			'C10y.',
			'C10yy',
			'C10z.',
			'C10zz',
			'Cyu2.',
			'Cyu23',
			'F1711',
			'F372.',
			'F3720',
			'F3721',
			'F3722',
			'F3813',
			'F3y0.',
			'F420.',
			'F4200',
			'F4204',
			'F4206',
			'F420z',
			'F42y9',
			'F4640',
			'M2710' ))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF8 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF8 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			(EVENT_CD IN ( '1491.',
			'1B5..',
			'1B53.',
			'F56..',
			'F561.',
			'F5610',
			'F5611',
			'F5614',
			'F561z',
			'F562.',
			'F562z',
			'FyuQ1',
			'R004.',
			'R0040',
			'R0043',
			'R0044' ))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF9 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF9 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			(EVENT_CD IN ( '173..',
			'1732.',
			'1733.',
			'1734.',
			'1738.',
			'1739.',
			'173C.',
			'173K.',
			'173Z.',
			'2322.',
			'R0608',
			'R060A' ))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF10 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF10 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			((EVENT_CD = '16D2.'
			AND EVENT_VAL > 0 )
			OR (EVENT_CD IN ( '16D..',
			'16D1.',
			'8HTl.',
			'8Hk1.',
			'8O9..',
			'R200.',
			'TC...',
			'TC5..',
			'TCz..' )))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF11 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF11 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			(EVENT_CD IN ( '13G8.',
			'9N08.',
			'9N1y7',
			'9N2Q.',
			'M20..',
			'M2000' ))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF12 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF12 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			(EVENT_CD IN ( '14G6.',
			'14G7.',
			'14G8.',
			'7K1D0',
			'7K1D6',
			'7K1H6',
			'7K1H8',
			'7K1J0',
			'7K1J6',
			'7K1J8',
			'7K1JB',
			'7K1JD',
			'7K1Jd',
			'7K1L4',
			'7K1LL',
			'7K1Y0',
			'N1y1.',
			'N331.',
			'N3311',
			'N331A',
			'N331D',
			'N331G',
			'N331H',
			'N331J',
			'N331K',
			'N331L',
			'N331M',
			'N331N',
			'NyuB0',
			'S10..',
			'S1000',
			'S1005',
			'S1006',
			'S1007',
			'S100H',
			'S100K',
			'S102.',
			'S1020',
			'S1021',
			'S102y',
			'S102z',
			'S1031',
			'S104.',
			'S1040',
			'S1041',
			'S1042',
			'S10A0',
			'S10B.',
			'S10B0',
			'S10B6',
			'S112.',
			'S114.',
			'S1145',
			'S15..',
			'S150.',
			'S1500',
			'S23..',
			'S234.',
			'S2341',
			'S2346',
			'S2351',
			'S23B.',
			'S23C.',
			'S23x1',
			'S23y.',
			'S3...',
			'S30..',
			'S300.',
			'S3000',
			'S3001',
			'S3004',
			'S3005',
			'S3006',
			'S3007',
			'S3009',
			'S300y',
			'S300z',
			'S3010',
			'S3015',
			'S302.',
			'S3020',
			'S3021',
			'S3022',
			'S3023',
			'S3024',
			'S302z',
			'S303.',
			'S3030',
			'S3032',
			'S3034',
			'S304.',
			'S305.',
			'S30y.',
			'S30z.',
			'S31z.',
			'S4500',
			'S4E..',
			'S4E0.',
			'S4E1.',
			'S4E2.' ))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF13 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF13 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			(EVENT_CD IN ( '1C12.',
			'1C13.',
			'1C131',
			'1C132',
			'1C133',
			'1C16.',
			'2BM2.',
			'2BM3.',
			'2BM4.',
			'2DG..',
			'3134.',
			'31340',
			'8D2..',
			'8E3..',
			'8HR2.',
			'8HT2.',
			'8HT3.',
			'Eu446',
			'F5801',
			'F59..',
			'F590.',
			'F591.',
			'F5912',
			'F5915',
			'F5916',
			'F592.',
			'F594.',
			'F595.',
			'F59z.',
			'F5A..',
			'ZV532' ))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF14 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF14 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			(EVENT_CD IN ( '14A6.',
			'14AM.',
			'1736.',
			'1O1..',
			'33BA.',
			'388D.',
			'585f.',
			'662T.',
			'662W.',
			'662g.',
			'662h.',
			'662p.',
			'679X.',
			'67D4.',
			'8CL3.',
			'8H2S.',
			'8HBE.',
			'8HHb.',
			'8HHz.',
			'9N0k.',
			'9N2p.',
			'9N4s.',
			'9N4w.',
			'9N6T.',
			'9Or0.',
			'9Or5.',
			'9hH0.',
			'9hH1.',
			'G58..',
			'G580.',
			'G5800',
			'G5801',
			'G5804',
			'G581.',
			'G582.',
			'G58z.',
			'G5y4z',
			'G5yy9',
			'SP111' ))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF15 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF15 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			(EVENT_CD IN ( 'G540.',
			'G5402',
			'G5415',
			'G543.' ))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF16 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF16 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			(EVENT_CD IN ( '13CA.',
			'8HL..',
			'9N1C.',
			'9NF..',
			'9NF1.',
			'9NF2.',
			'9NF3.',
			'9NF8.',
			'9NF9.',
			'9NFB.',
			'9NFM.' ))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF17 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF17 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			((EVENT_CD = '246W.'
			AND EVENT_VAL > 135 )
			OR (EVENT_CD = '246V.'
			AND EVENT_VAL > 85 )
			OR (EVENT_CD IN ( '14A2.',
			'246M.',
			'6627.',
			'6628.',
			'662F.',
			'662O.',
			'662b.',
			'8CR4.',
			'8HT5.',
			'8I3N.',
			'9N03.',
			'9N1y2',
			'9h3..',
			'9h31.',
			'9h32.',
			'F4211',
			'F4213',
			'G2...',
			'G20..',
			'G200.',
			'G201.',
			'G202.',
			'G203.',
			'G20z.',
			'G22z.',
			'G24..',
			'G240.',
			'G240z',
			'G241.',
			'G241z',
			'G244.',
			'G24z.',
			'G24z0',
			'G24z1',
			'G24zz',
			'G2z..',
			'Gyu20',
			'Gyu21' )))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF18 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF18 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			(EVENT_CD IN ( '1B55.',
			'1B6..',
			'1B62.',
			'1B65.',
			'1B68.',
			'79370',
			'F1303',
			'G87..',
			'G870.',
			'G871.',
			'G872.',
			'G873.',
			'G87z.',
			'R002.',
			'R0021',
			'R0022',
			'R0023',
			'R0042' ))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF19 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF19 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			(EVENT_CD IN ( '14A..',
			'14A4.',
			'14A5.',
			'182..',
			'322..',
			'3222.',
			'322Z.',
			'662K0',
			'662K1',
			'662K3',
			'6A2..',
			'6A4..',
			'792..',
			'7928.',
			'79294',
			'889A.',
			'8H2V.',
			'8I3z.',
			'G3...',
			'G30..',
			'G3071',
			'G308.',
			'G30y.',
			'G30yz',
			'G30z.',
			'G31..',
			'G311.',
			'G3111',
			'G31y2',
			'G31y3',
			'G31yz',
			'G32..',
			'G33..',
			'G332.',
			'G33z.',
			'G33z3',
			'G33z4',
			'G33z7',
			'G33zz',
			'G34..',
			'G340.',
			'G344.',
			'G34y0',
			'G34y1',
			'G34yz',
			'G34z.',
			'G36..',
			'G361.',
			'G362.',
			'G37..',
			'G3y..',
			'G3z..',
			'Gyu3.',
			'G3...',
			'Gyu30' ))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF20 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF20 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			((EVENT_CD = '3AD3.'
			AND (EVENT_VAL > 8
			OR EVENT_VAL = 8))
			OR (EVENT_CD IN ( '1461.',
			'1B1A.',
			'1S21.',
			'2841.',
			'28E..',
			'3A10.',
			'3A20.',
			'3A30.',
			'3A40.',
			'3A50.',
			'3A60.',
			'3A70.',
			'3A80.',
			'3A91.',
			'3AA1.',
			'3AE..',
			'66h..',
			'6AB..',
			'8HTY.',
			'9NdL.',
			'9Nk1.',
			'9Ou..',
			'9Ou2.',
			'9Ou3.',
			'9Ou4.',
			'9Ou5.',
			'9hD..',
			'9hD0.',
			'9hD1.',
			'E00..',
			'E000.',
			'E001.',
			'E0010',
			'E0011',
			'E0012',
			'E0013',
			'E001z',
			'E002.',
			'E0020',
			'E0021',
			'E002z',
			'E003.',
			'E004.',
			'E0040',
			'E0041',
			'E0042',
			'E0043',
			'E004z',
			'E012.',
			'E041.',
			'E2A10',
			'E2A11',
			'Eu00.',
			'Eu000',
			'Eu001',
			'Eu002',
			'Eu00z',
			'Eu01.',
			'Eu010',
			'Eu011',
			'Eu012',
			'Eu013',
			'Eu01y',
			'Eu01z',
			'Eu02.',
			'Eu020',
			'Eu021',
			'Eu022',
			'Eu023',
			'Eu024',
			'Eu025',
			'Eu02y',
			'Eu02z',
			'Eu041',
			'Eu057',
			'F110.',
			'F1100',
			'F1101',
			'F116.',
			'F21y2',
			'R00z0' )))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF21 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF21 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			(EVENT_CD IN ( '1381.',
			'13C2.',
			'13C4.',
			'13CD.',
			'13CE.',
			'398A.',
			'39B..',
			'8D4..',
			'8O15.',
			'N097.',
			'ZV4L0' ))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF22 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF22 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			((EVENT_CD = '58EE.'
			AND (EVENT_VAL <-2.5
			OR EVENT_VAL = -2.5) )
			OR (EVENT_CD IN ( '14OD.',
			'56812',
			'58EN.',
			'66a..',
			'66a2.',
			'66a3.',
			'66a4.',
			'66a5.',
			'66a6.',
			'66a7.',
			'66a8.',
			'66a9.',
			'66aA.',
			'66aE.',
			'8HTS.',
			'9N0h.',
			'9Od0.',
			'9Od2.',
			'N330.',
			'N3300',
			'N3301',
			'N3302',
			'N3303',
			'N3304',
			'N3305',
			'N3306',
			'N3307',
			'N3308',
			'N330A',
			'N330B',
			'N330C',
			'N330D',
			'N330z',
			'N3312',
			'N3315',
			'N3316',
			'N3318',
			'N3319',
			'N331B',
			'N331L',
			'N3370',
			'NyuB0',
			'NyuB1',
			'NyuB8',
			'NyuBC' )))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF23 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF23 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			(EVENT_CD IN ( '297A.',
			'2987.',
			'2994.',
			'A94y1',
			'F116.',
			'F11x9',
			'F12..',
			'F120.',
			'F121.',
			'F12W.',
			'F12X.',
			'F12z.',
			'F13..',
			'F1303',
			'Fyu20',
			'Fyu21',
			'Fyu22',
			'Fyu29',
			'Fyu2B',
			'R0103',
			'TJ64.',
			'U6067' ))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF24 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF24 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			(EVENT_CD IN ( '14C1.',
			'1956.',
			'76121',
			'761D5',
			'761D6',
			'761J.',
			'761J0',
			'761J1',
			'761Jy',
			'761Jz',
			'7627.',
			'76270',
			'76271',
			'76272',
			'7627y',
			'7627z',
			'J1016',
			'J1020',
			'J11..',
			'J110.',
			'J1100',
			'J1101',
			'J1102',
			'J1103',
			'J1104',
			'J110y',
			'J110z',
			'J111.',
			'J1110',
			'J1111',
			'J1112',
			'J1114',
			'J111y',
			'J111z',
			'J112.',
			'J113.',
			'J113z',
			'J11y.',
			'J11y0',
			'J11y1',
			'J11y2',
			'J11yz',
			'J11z.',
			'J12..',
			'J120.',
			'J1200',
			'J1201',
			'J1202',
			'J1203',
			'J120y',
			'J120z',
			'J121.',
			'J1210',
			'J1211',
			'J1212',
			'J1213',
			'J1214',
			'J121y',
			'J121z',
			'J122.',
			'J124.',
			'J125.',
			'J126.',
			'J126z',
			'J12y.',
			'J12y0',
			'J12y1',
			'J12y2',
			'J12y3',
			'J12y4',
			'J12yy',
			'J12yz',
			'J12z.',
			'J13..',
			'J130.',
			'J1300',
			'J1301',
			'J1302',
			'J1303',
			'J130y',
			'J130z',
			'J131.',
			'J1310',
			'J1311',
			'J1312',
			'J131y',
			'J131z',
			'J13y.',
			'J13y0',
			'J13y1',
			'J13y2',
			'J13yz',
			'J13z.',
			'J14..',
			'J1401',
			'J1411',
			'J14y.',
			'J14z.',
			'J17y8',
			'J57y8',
			'ZV12C' ))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF25 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF25 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			((EVENT_CD = '585a.'
			AND EVENT_VAL < 0.95)
			OR (EVENT_CD IN ( '24E9.',
			'24EA.',
			'24EC.',
			'24F9.',
			'C107.',
			'C1086',
			'C109F',
			'C10E6',
			'C10FF',
			'G670.',
			'G700.',
			'G73..',
			'G73z.',
			'G73zz',
			'M2710' )))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF26 ( ALF_PE BIGINT,
	event_dt DATE,
	DEF26 BIGINT ) DISTRIBUTE BY HASH(ALF_PE);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF26 (
			SELECT SUB.ALF_PE,
			sub.event_dt,
			MAX(SUB.RANK)
		FROM
			(
				SELECT ALF_PE,
				A.event_dt AS event_dt,
				DENSE_RANK() OVER (PARTITION BY ALF_PE
			ORDER BY
				EVENT_CD) AS RANK
			FROM
				SAILW0972V.V2_GPDATA AS B
			JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
					USING (ALF_PE)
			WHERE
				B.EVENT_DT <= A.EVENT_DT
				AND B.EVENT_DT >= A.EVENT_DT - 1 YEARS
				AND (substr(EVENT_CD,
				1,
				1) <> UPPER(substr(EVENT_CD, 1, 1)) ) ) AS SUB
		GROUP BY
			SUB.ALF_PE ,
			sub.event_dt);

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF27 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF27 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			(EVENT_CD IN ( '13F6.',
			'13F61',
			'13FX.',
			'13G6.',
			'13G61',
			'13WJ.',
			'8GEB.',
			'918F.',
			'9N1G.' ))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF28 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF28 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			((EVENT_CD = '66Yf.'
			AND EVENT_VAL > 0)
			OR (EVENT_CD IN ( '14B..',
			'14B3.',
			'14B4.',
			'14OX.',
			'1712.',
			'1713.',
			'1715.',
			'171A.',
			'173A.',
			'178..',
			'1780.',
			'1O2..',
			'3399.',
			'339U.',
			'33G0.',
			'388t.',
			'663..',
			'663J.',
			'663N.',
			'663N0',
			'663N1',
			'663N2',
			'663O.',
			'663O0',
			'663P.',
			'663Q.',
			'663U.',
			'663V.',
			'663V0',
			'663V1',
			'663V2',
			'663V3',
			'663W.',
			'663d.',
			'663e.',
			'663f.',
			'663h.',
			'663j.',
			'663l.',
			'663m.',
			'663n.',
			'663p.',
			'663q.',
			'663r.',
			'663s.',
			'663t.',
			'663u.',
			'663v.',
			'663w.',
			'663x.',
			'663y.',
			'66Y5.',
			'66Y9.',
			'66YA.',
			'66YB.',
			'66YD.',
			'66YE.',
			'66YI.',
			'66YJ.',
			'66YK.',
			'66YL.',
			'66YM.',
			'66YP.',
			'66YQ.',
			'66YR.',
			'66YS.',
			'66YT.',
			'66YZ.',
			'66Yd.',
			'66Ye.',
			'66Yf.',
			'66Yg.',
			'66Yh.',
			'66Yi.',
			'679J.',
			'679V.',
			'74592',
			'8764.',
			'8776.',
			'8778.',
			'8793.',
			'8794.',
			'8795.',
			'8796.',
			'8797.',
			'8798.',
			'8B3j.',
			'8CR0.',
			'8CR1.',
			'8FA..',
			'8FA1.',
			'8H2P.',
			'8H2R.',
			'8H7u.',
			'8HTT.',
			'9N1d.',
			'9N4Q.',
			'9N4W.',
			'9OJ1.',
			'9OJ2.',
			'9OJ3.',
			'9OJ7.',
			'9OJA.',
			'9Oi3.',
			'9h52.',
			'9hA1.',
			'9hA2.',
			'9kf..',
			'9kf0.',
			'G401.',
			'G4011',
			'G410.',
			'G41y0',
			'H....',
			'H3...',
			'H30..',
			'H302.',
			'H31..',
			'H310.',
			'H3100',
			'H310z',
			'H311.',
			'H3110',
			'H3111',
			'H312.',
			'H3120',
			'H3122',
			'H312z',
			'H31y.',
			'H31yz',
			'H31z.',
			'H32..',
			'H33..',
			'H330.',
			'H3300',
			'H3301',
			'H330z',
			'H331.',
			'H3310',
			'H3311',
			'H331z',
			'H332.',
			'H333.',
			'H334.',
			'H33z.',
			'H33z0',
			'H33z1',
			'H33z2',
			'H33zz',
			'H36..',
			'H37..',
			'H38..',
			'H39..',
			'H3y..',
			'H3y0.',
			'H3y1.',
			'H3z..',
			'H564.',
			'Hyu31',
			'N04y0',
			'R062.',
			'TJF73',
			'U60F6',
			'ZV129' )))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF29 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF29 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			(EVENT_CD IN ( '14F3.',
			'14F5.',
			'2924.',
			'2FF..',
			'2FF2.',
			'2FF3.',
			'2FFZ.',
			'2G48.',
			'2G54.',
			'2G55.',
			'2G5H.',
			'2G5L.',
			'2G5V.',
			'2G5W.',
			'39C..',
			'39C0.',
			'4JG3.',
			'7G2E5',
			'7G2EA',
			'7G2EB',
			'7G2EC',
			'81H1.',
			'8CT1.',
			'8CV2.',
			'8HTh.',
			'9N0t.',
			'9NM5.',
			'C1094',
			'C10F4',
			'G830.',
			'G832.',
			'G835.',
			'G837.',
			'M07z.',
			'M27..',
			'M270.',
			'M271.',
			'M2710',
			'M2711',
			'M2712',
			'M2713',
			'M2714',
			'M2715',
			'M272.',
			'M27y.',
			'M27z.' ))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF30 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF30 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			(EVENT_CD IN ( '1B1B.',
			'1B1Q.',
			'E274.',
			'Eu51.',
			'Fy02.',
			'R005.',
			'R0050',
			'R0052' ))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF31 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF31 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			(EVENT_CD IN ( '1335.',
			'133P.',
			'133V.',
			'13EH.',
			'13F3.',
			'13G4.',
			'13M1.',
			'13MF.',
			'13Z8.',
			'1B1K.',
			'8H75.',
			'8HHB.',
			'8I5..',
			'918V.',
			'9NNV.',
			'ZV603' ))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF32 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF32 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			((EVENT_CD = '44lD.'
			AND EVENT_VAL > 15)
			OR (EVENT_CD = '442W.'
			AND EVENT_VAL NOT BETWEEN 0.5 AND 4)
			OR (EVENT_CD = '442A.'
			AND EVENT_VAL NOT BETWEEN 0.5 AND 4)
			OR (EVENT_CD IN ( '1431.',
			'1432.',
			'4422.',
			'442I.',
			'66BB.',
			'66BZ.',
			'8CR5.',
			'9N4T.',
			'9Oj0.',
			'C0...',
			'C02..',
			'C04..',
			'C040.',
			'C041.',
			'C0410',
			'C041z',
			'C042.',
			'C043.',
			'C043z',
			'C044.',
			'C046.',
			'C04y.',
			'C04z.',
			'C1343',
			'Cyu1.',
			'Cyu11' )))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF33 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF33 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			(EVENT_CD IN ( '1593.',
			'16F..',
			'1A23.',
			'1A24.',
			'1A26.',
			'3940.',
			'3941.',
			'7B338',
			'7B33C',
			'7B421',
			'8D7..',
			'8D71.',
			'8HTX.',
			'K198.',
			'K586.',
			'Kyu5A',
			'R083.',
			'R0831',
			'R0832',
			'R083z' ))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF34 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF34 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			(EVENT_CD IN ( '14D..',
			'14DZ.',
			'1A1..',
			'1A13.',
			'1A1Z.',
			'1A55.',
			'1AA..',
			'1AC2.',
			'7B39.',
			'7B390',
			'8156.',
			'8H5B.',
			'K....',
			'K155.',
			'K1653',
			'K1654',
			'K16y4',
			'K190.',
			'K1903',
			'K1905',
			'K190z',
			'K1971',
			'K1973',
			'K20..',
			'Ky...',
			'Kz...',
			'R08..',
			'R082.',
			'R0822',
			'SP031' ))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF35 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF35 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			(EVENT_CD IN ( '1483.',
			'1B75.',
			'22E5.',
			'22EG.',
			'2BBm.',
			'2BBn.',
			'2BBo.',
			'2BBr.',
			'2BT..',
			'2BT0.',
			'2BT1.',
			'6688.',
			'6689.',
			'72630',
			'72661',
			'8F61.',
			'8H52.',
			'9m08.',
			'C108F',
			'C109E',
			'C10EF',
			'C10EP',
			'C10FE',
			'C10FQ',
			'F4042',
			'F421A',
			'F422.',
			'F422y',
			'F422z',
			'F4239',
			'F425.',
			'F4250',
			'F4251',
			'F4252',
			'F4253',
			'F4254',
			'F4257',
			'F427C',
			'F42y4',
			'F42y9',
			'F4305',
			'F4332',
			'F46..',
			'F4602',
			'F4603',
			'F4604',
			'F4605',
			'F4606',
			'F4607',
			'F460z',
			'F461.',
			'F4610',
			'F4614',
			'F4615',
			'F4617',
			'F4618',
			'F4619',
			'F461A',
			'F461B',
			'F461y',
			'F461z',
			'F462.',
			'F462z',
			'F463.',
			'F4633',
			'F4634',
			'F463z',
			'F464.',
			'F4640',
			'F4642',
			'F4644',
			'F4646',
			'F4647',
			'F464z',
			'F465.',
			'F4650',
			'F465z',
			'F466.',
			'F46y.',
			'F46yz',
			'F46z.',
			'F46z0',
			'F4840',
			'F49..',
			'F490.',
			'F4900',
			'F4909',
			'F490z',
			'F494.',
			'F4950',
			'F495A',
			'F49z.',
			'F4A24',
			'F4H34',
			'F4H40',
			'F4H73',
			'F4K2D',
			'FyuE1',
			'FyuF7',
			'FyuL.',
			'P33..',
			'P330.',
			'P331.',
			'P3310',
			'P3311',
			'P331z',
			'S813.',
			'SJ0z.' ))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );

CREATE TABLE
	SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF36 ( ALF_PE BIGINT,
	event_dt DATE ,
	EVENT_CD CHAR(30)) DISTRIBUTE BY HASH(ALF_PE,
	EVENT_CD);

INSERT
	INTO
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF36 (
			SELECT ALF_PE,
			A.event_dt ,
			COUNT(EVENT_CD)
		FROM
			SAILW0972V.V2_GPDATA AS B
		JOIN SAILW0972V.V2_COHORT_WITH_DUMMY_DATE AS A
				USING (ALF_PE)
		WHERE
			((EVENT_CD = '687C.'
			AND (EVENT_VAL > 1
			OR EVENT_VAL = 1))
			OR (EVENT_CD IN ( '1612.',
			'1615.',
			'1623.',
			'1625.',
			'1D1A.',
			'22A8.',
			'R0300',
			'R032.' )))
			AND B.EVENT_DT <= A.EVENT_DT
			AND B.EVENT_DT >= A.EVENT_DT - 10 YEARS
		GROUP BY
			ALF_PE,
			A.event_dt );
			
		-----------------------Join tables
--drop table SAILW0972V.vb_wlgp_sub_COHORT_EFI_INDICATOR_dummy
		
CREATE TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_INDICATOR_dummy (
                      ALF_PE BIGINT ,event_dt date
                      , DEF1 BIGINT
                      , DEF2 BIGINT
                      , DEF3 BIGINT
                      , DEF4 BIGINT
                      , DEF5 BIGINT
                      , DEF6 BIGINT
                      , DEF7 BIGINT
                      , DEF8 BIGINT
                      , DEF9 BIGINT
                      , DEF10 BIGINT
                      , DEF11 BIGINT
                      , DEF12 BIGINT
                      , DEF13 BIGINT
                      , DEF14 BIGINT
                      , DEF15 BIGINT
                      , DEF16 BIGINT
                      , DEF17 BIGINT
                      , DEF18 BIGINT
                      , DEF19 BIGINT
                      , DEF20 BIGINT
                      , DEF21 BIGINT
                      , DEF22 BIGINT
                      , DEF23 BIGINT
                      , DEF24 BIGINT
                      , DEF25 BIGINT
                      , DEF26 BIGINT
                      , DEF27 BIGINT
                      , DEF28 BIGINT
                      , DEF29 BIGINT
                      , DEF30 BIGINT
                      , DEF31 BIGINT
                      , DEF32 BIGINT
                      , DEF33 BIGINT
                      , DEF34 BIGINT
                      , DEF35 BIGINT
                      , DEF36 BIGINT )
                      DISTRIBUTE BY HASH(ALF_PE);
		
		INSERT INTO SAILW0972V.vb_wlgp_sub_COHORT_EFI_INDICATOR_dummy  (
                      select COHORT.ALF_PE  ,cohort.event_dt , DUMMY1.EVENT_CD AS  dummy_def1 ,  DUMMY2.EVENT_CD AS dummy_def2 ,  DUMMY3.EVENT_CD AS dummy_def3 ,  DUMMY4.EVENT_CD AS dummy_def4 ,  DUMMY5.EVENT_CD AS dummy_def5 ,  DUMMY6.EVENT_CD AS dummy_def6 ,  DUMMY7.EVENT_CD AS dummy_def7 ,  DUMMY8.EVENT_CD AS dummy_def8 ,  DUMMY9.EVENT_CD AS dummy_def9 ,  DUMMY10.EVENT_CD AS dummy_def10 ,  DUMMY11.EVENT_CD AS dummy_def11 ,  DUMMY12.EVENT_CD AS dummy_def12 ,  DUMMY13.EVENT_CD AS dummy_def13 ,  DUMMY14.EVENT_CD AS dummy_def14 ,  DUMMY15.EVENT_CD AS dummy_def15 ,  DUMMY16.EVENT_CD AS dummy_def16 ,  DUMMY17.EVENT_CD AS dummy_def17 ,  DUMMY18.EVENT_CD AS dummy_def18 ,  DUMMY19.EVENT_CD AS dummy_def19 ,  DUMMY20.EVENT_CD AS dummy_def20 ,  DUMMY21.EVENT_CD AS dummy_def21 ,  DUMMY22.EVENT_CD AS dummy_def22 ,  DUMMY23.EVENT_CD AS dummy_def23 ,  DUMMY24.EVENT_CD AS dummy_def24 ,  DUMMY25.EVENT_CD AS dummy_def25 ,  DUMMY26.def26 AS dummy_def26 ,  DUMMY27.EVENT_CD AS dummy_def27 ,  DUMMY28.EVENT_CD AS dummy_def28 ,  DUMMY29.EVENT_CD AS dummy_def29 ,  DUMMY30.EVENT_CD AS dummy_def30 ,  DUMMY31.EVENT_CD AS dummy_def31 ,  DUMMY32.EVENT_CD AS dummy_def32 ,  DUMMY33.EVENT_CD AS dummy_def33 ,  DUMMY34.EVENT_CD AS dummy_def34 ,  DUMMY35.EVENT_CD AS dummy_def35 ,  DUMMY36.EVENT_CD AS dummy_def36 
                      from SAILW0972V.V2_COHORT_WITH_DUMMY_DATE  AS COHORT
                      LEFT JOIN  SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF1  AS  DUMMY1  ON COHORT.ALF_PE = DUMMY1.ALF_PE and COHORT.event_dt = DUMMY1.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF2   AS  DUMMY2  ON COHORT.ALF_PE = DUMMY2.ALF_PE and COHORT.event_dt = DUMMY2.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF3   AS  DUMMY3  ON COHORT.ALF_PE = DUMMY3.ALF_PE and COHORT.event_dt = DUMMY3.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF4   AS  DUMMY4  ON COHORT.ALF_PE = DUMMY4.ALF_PE and COHORT.event_dt = DUMMY4.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF5   AS  DUMMY5  ON COHORT.ALF_PE = DUMMY5.ALF_PE and COHORT.event_dt = DUMMY5.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF6   AS  DUMMY6  ON COHORT.ALF_PE = DUMMY6.ALF_PE and COHORT.event_dt = DUMMY6.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF7   AS  DUMMY7  ON COHORT.ALF_PE = DUMMY7.ALF_PE and COHORT.event_dt = DUMMY7.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF8   AS  DUMMY8  ON COHORT.ALF_PE = DUMMY8.ALF_PE and COHORT.event_dt = DUMMY8.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF9   AS  DUMMY9  ON COHORT.ALF_PE = DUMMY9.ALF_PE and COHORT.event_dt = DUMMY9.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF10   AS  DUMMY10  ON COHORT.ALF_PE = DUMMY10.ALF_PE and COHORT.event_dt = DUMMY10.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF11   AS  DUMMY11  ON COHORT.ALF_PE = DUMMY11.ALF_PE and COHORT.event_dt = DUMMY11.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF12   AS  DUMMY12  ON COHORT.ALF_PE = DUMMY12.ALF_PE and COHORT.event_dt = DUMMY12.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF13   AS  DUMMY13  ON COHORT.ALF_PE = DUMMY13.ALF_PE and COHORT.event_dt = DUMMY13.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF14   AS  DUMMY14  ON COHORT.ALF_PE = DUMMY14.ALF_PE and COHORT.event_dt = DUMMY14.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF15   AS  DUMMY15  ON COHORT.ALF_PE = DUMMY15.ALF_PE and COHORT.event_dt = DUMMY15.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF16   AS  DUMMY16  ON COHORT.ALF_PE = DUMMY16.ALF_PE and COHORT.event_dt = DUMMY16.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF17   AS  DUMMY17  ON COHORT.ALF_PE = DUMMY17.ALF_PE and COHORT.event_dt = DUMMY17.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF18   AS  DUMMY18  ON COHORT.ALF_PE = DUMMY18.ALF_PE and COHORT.event_dt = DUMMY18.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF19   AS  DUMMY19  ON COHORT.ALF_PE = DUMMY19.ALF_PE and COHORT.event_dt = DUMMY19.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF20   AS  DUMMY20  ON COHORT.ALF_PE = DUMMY20.ALF_PE and COHORT.event_dt = DUMMY20.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF21   AS  DUMMY21  ON COHORT.ALF_PE = DUMMY21.ALF_PE and COHORT.event_dt = DUMMY21.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF22   AS  DUMMY22  ON COHORT.ALF_PE = DUMMY22.ALF_PE and COHORT.event_dt = DUMMY22.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF23   AS  DUMMY23  ON COHORT.ALF_PE = DUMMY23.ALF_PE and COHORT.event_dt = DUMMY23.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF24   AS  DUMMY24  ON COHORT.ALF_PE = DUMMY24.ALF_PE and COHORT.event_dt = DUMMY24.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF25   AS  DUMMY25  ON COHORT.ALF_PE = DUMMY25.ALF_PE and COHORT.event_dt = DUMMY25.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF26   AS  DUMMY26  ON COHORT.ALF_PE = DUMMY26.ALF_PE and COHORT.event_dt = DUMMY26.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF27   AS  DUMMY27  ON COHORT.ALF_PE = DUMMY27.ALF_PE and COHORT.event_dt = DUMMY27.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF28   AS  DUMMY28  ON COHORT.ALF_PE = DUMMY28.ALF_PE and COHORT.event_dt = DUMMY28.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF29   AS  DUMMY29  ON COHORT.ALF_PE = DUMMY29.ALF_PE and COHORT.event_dt = DUMMY29.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF30   AS  DUMMY30  ON COHORT.ALF_PE = DUMMY30.ALF_PE and COHORT.event_dt = DUMMY30.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF31   AS  DUMMY31  ON COHORT.ALF_PE = DUMMY31.ALF_PE and COHORT.event_dt = DUMMY31.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF32   AS  DUMMY32  ON COHORT.ALF_PE = DUMMY32.ALF_PE and COHORT.event_dt = DUMMY32.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF33   AS  DUMMY33  ON COHORT.ALF_PE = DUMMY33.ALF_PE and COHORT.event_dt = DUMMY33.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF34   AS  DUMMY34  ON COHORT.ALF_PE = DUMMY34.ALF_PE and COHORT.event_dt = DUMMY34.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF35   AS  DUMMY35  ON COHORT.ALF_PE = DUMMY35.ALF_PE and COHORT.event_dt = DUMMY35.event_dt
                      LEFT JOIN   SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF36   AS  DUMMY36  ON COHORT.ALF_PE = DUMMY36.ALF_PE and COHORT.event_dt = DUMMY36.event_dt);
		
		
		----------------DROP ALL tables

DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF1;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF2;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF3;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF4;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF5;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF6;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF7;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF8;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF9;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF10;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF11;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF12;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF13;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF14;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF15;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF16;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF17;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF18;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF19;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF20;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF21;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF22;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF23;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF24;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF25;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF26;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF27;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF28;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF29;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF30;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF31;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF32;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF33;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF34;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF35;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_DEF36;
DROP ALIAS SAILW0972V.V2_GPDATA;

------------------------------------
CREATE TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_INDICATOR AS 
(SELECT * FROM SAILW0972V.vb_wlgp_sub_COHORT_EFI_INDICATOR_dummy) WITH NO DATA;


INSERT INTO SAILW0972V.vb_wlgp_sub_COHORT_EFI_INDICATOR 
                      select ALF_PE ,event_dt , CASE WHEN def1 IS NULL THEN 0 ELSE 1 END AS  DEF1 , CASE WHEN def2 IS NULL THEN 0 ELSE 1 END AS DEF2 ,  CASE WHEN def3 IS NULL THEN 0 ELSE 1 END AS DEF3 ,  CASE WHEN def4 IS NULL THEN 0 ELSE 1 END AS DEF4 ,  CASE WHEN def5 IS NULL THEN 0 ELSE 1 END AS DEF5 ,  CASE WHEN def6 IS NULL THEN 0 ELSE 1 END AS DEF6 ,  CASE WHEN def7 IS NULL THEN 0 ELSE 1 END AS DEF7 ,  CASE WHEN def8 IS NULL THEN 0 ELSE 1 END AS DEF8 ,  CASE WHEN def9 IS NULL THEN 0 ELSE 1 END AS DEF9 ,  CASE WHEN def10 IS NULL THEN 0 ELSE 1 END AS DEF10 ,  CASE WHEN def11 IS NULL THEN 0 ELSE 1 END AS DEF11 ,  CASE WHEN def12 IS NULL THEN 0 ELSE 1 END AS DEF12 ,  CASE WHEN def13 IS NULL THEN 0 ELSE 1 END AS DEF13 ,  CASE WHEN def14 IS NULL THEN 0 ELSE 1 END AS DEF14 ,  CASE WHEN def15 IS NULL THEN 0 ELSE 1 END AS DEF15 ,  CASE WHEN def16 IS NULL THEN 0 ELSE 1 END AS DEF16 ,  CASE WHEN def17 IS NULL THEN 0 ELSE 1 END AS DEF17 , CASE WHEN def18 IS NULL THEN 0 ELSE 1 END AS DEF18 ,  CASE WHEN def19 IS NULL THEN 0 ELSE 1 END AS DEF19 ,  CASE WHEN def20 IS NULL THEN 0 ELSE 1 END AS DEF20 ,  CASE WHEN def21 IS NULL THEN 0 ELSE 1 END AS DEF21 ,  CASE WHEN def22 IS NULL THEN 0 ELSE 1 END AS DEF22 ,  CASE WHEN def23 IS NULL THEN 0 ELSE 1 END AS DEF23 ,  CASE WHEN def24 IS NULL THEN 0 ELSE 1 END AS DEF24 ,  CASE WHEN def25 IS NULL THEN 0 ELSE 1 END AS DEF25 ,  CASE WHEN def26 IS NULL OR def26 < 5 THEN 0 ELSE 1 END AS DEF26 ,  CASE WHEN def27 IS NULL THEN 0 ELSE 1 END AS DEF27 ,  CASE WHEN def28 IS NULL THEN 0 ELSE 1 END AS DEF28 ,  CASE WHEN def29 IS NULL THEN 0 ELSE 1 END AS DEF29 ,  CASE WHEN def30 IS NULL THEN 0 ELSE 1 END AS DEF30 ,  CASE WHEN def31 IS NULL THEN 0 ELSE 1 END AS DEF31 ,  CASE WHEN def32 IS NULL THEN 0 ELSE 1 END AS DEF32 ,  CASE WHEN def33 IS NULL THEN 0 ELSE 1 END AS DEF33 ,  CASE WHEN def34 IS NULL THEN 0 ELSE 1 END AS DEF34 ,  CASE WHEN def35 IS NULL THEN 0 ELSE 1 END AS DEF35 ,  CASE WHEN def36 IS NULL THEN 0 ELSE 1 END AS DEF36 FROM SAILW0972V.vb_wlgp_sub_COHORT_EFI_INDICATOR_dummy ;


-----------------------------------------------

-----------------------------------------------

CREATE TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_sub (
                      ALF_PE BIGINT ,event_dt date
                      , DEF1 BIGINT
                      , DEF2 BIGINT
                      , DEF3 BIGINT
                      , DEF4 BIGINT
                      , DEF5 BIGINT
                      , DEF6 BIGINT
                      , DEF7 BIGINT
                      , DEF8 BIGINT
                      , DEF9 BIGINT
                      , DEF10 BIGINT
                      , DEF11 BIGINT
                      , DEF12 BIGINT
                      , DEF13 BIGINT
                      , DEF14 BIGINT
                      , DEF15 BIGINT
                      , DEF16 BIGINT
                      , DEF17 BIGINT
                      , DEF18 BIGINT
                      , DEF19 BIGINT
                      , DEF20 BIGINT
                      , DEF21 BIGINT
                      , DEF22 BIGINT
                      , DEF23 BIGINT
                      , DEF24 BIGINT
                      , DEF25 BIGINT
                      , DEF26 BIGINT
                      , DEF27 BIGINT
                      , DEF28 BIGINT
                      , DEF29 BIGINT
                      , DEF30 BIGINT
                      , DEF31 BIGINT
                      , DEF32 BIGINT
                      , DEF33 BIGINT
                      , DEF34 BIGINT
                      , DEF35 BIGINT
                      , DEF36 BIGINT
                      , Defict_sum bigint
                      , eFI decimal(6,4))
                      DISTRIBUTE BY HASH(ALF_PE);
                     
 INSERT INTO SAILW0972V.vb_wlgp_sub_COHORT_EFI_sub (
 
SELECT * , DEF1 + DEF2 + DEF3 + DEF4 + DEF5 + DEF6 + DEF7 + DEF8 + DEF9 + DEF10 + DEF11 + DEF12 + DEF13 + DEF14 + DEF15 + DEF16 + DEF17 + DEF18 + DEF19 + DEF20 + DEF21 + DEF22 + DEF23 + DEF24 + DEF25 + DEF26 + DEF27 + DEF28 + DEF29 + DEF30 + DEF31 + DEF32 + DEF33 + DEF34 + DEF35 + DEF36 AS deficit_sum , CAST( (DEF1 + DEF2 + DEF3 + DEF4 + DEF5 + DEF6 + DEF7 + DEF8 + DEF9 + DEF10 + DEF11 + DEF12 + DEF13 + DEF14 + DEF15 + DEF16 + DEF17 + DEF18 + DEF19 + DEF20 + DEF21 + DEF22 + DEF23 + DEF24 + DEF25 + DEF26 + DEF27 + DEF28 + DEF29 + DEF30 + DEF31 + DEF32 + DEF33 + DEF34 + DEF35 + DEF36) AS decimal(6,4))/36 AS eFI FROM SAILW0972V.vb_wlgp_sub_COHORT_EFI_INDICATOR);

DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_INDICATOR_dummy;



CREATE TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI AS (
SELECT
	* ,
	CASE
		WHEN (EFI > 0.12 AND EFI <= 0.24) THEN 1
		WHEN (EFI > 0.24 AND EFI <= 0.36) THEN 2 
		WHEN (EFI > 0.36) THEN 3
		ELSE 0 
		END 
		AS frailty
		,
	CASE
		WHEN (EFI > 0.12 AND EFI <= 0.24) THEN 'Mild'
		WHEN (EFI > 0.24 AND EFI <= 0.36) THEN 'Moderate'
		WHEN (EFI > 0.36) THEN 'Severe'
		ELSE 'Fit'
		END 
		AS frailty_def
	FROM
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_sub) WITH NO DATA;
	

		INSERT INTO SAILW0972V.vb_wlgp_sub_COHORT_EFI (SELECT
	* ,
	CASE
		WHEN (EFI > 0.12 AND EFI <= 0.24) THEN 1
		WHEN (EFI > 0.24 AND EFI <= 0.36) THEN 2 
		WHEN (EFI > 0.36) THEN 3
		ELSE 0 
		END 
		AS frailty
		,
	CASE
		WHEN (EFI > 0.12 AND EFI <= 0.24) THEN 'Mild'
		WHEN (EFI > 0.24 AND EFI <= 0.36) THEN 'Moderate'
		WHEN (EFI > 0.36) THEN 'Severe'
		ELSE 'Fit'
		END 
		AS frailty_def
	FROM
		SAILW0972V.vb_wlgp_sub_COHORT_EFI_sub);
		
		DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_sub;
DROP TABLE SAILW0972V.V2_COHORT_WITH_DUMMY_DATE;
DROP TABLE SAILW0972V.vb_wlgp_sub_COHORT_EFI_INDICATOR;

/* update cohort table with eFI at time of first event */
					
ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN EFI DECIMAL(6,4)
	ADD COLUMN FRAILTY INTEGER
	ADD COLUMN FRAILTY_DEF VARCHAR(8);

MERGE INTO sailw0972v.vb_wlgp_sub AS fe
	USING SAILW0972V.vb_wlgp_sub_COHORT_EFI AS efi
		ON fe.ALF_PE||diag_dt = efi.ALF_PE||efi.event_dt
			WHEN MATCHED THEN
				UPDATE
				SET fe.EFI = efi.EFI
			;
		
MERGE INTO sailw0972v.vb_wlgp_sub AS fe
	USING SAILW0972V.vb_wlgp_sub_COHORT_EFI AS efi
		ON fe.ALF_PE||diag_dt = efi.ALF_PE||efi.event_dt
			WHEN MATCHED THEN
				UPDATE
				SET fe.FRAILTY = efi.FRAILTY
			;
		
MERGE INTO sailw0972v.vb_wlgp_sub AS fe
	USING SAILW0972V.vb_wlgp_sub_COHORT_EFI AS efi
		ON fe.ALF_PE||diag_dt = efi.ALF_PE||efi.event_dt
			WHEN MATCHED THEN
				UPDATE
				SET fe.FRAILTY_DEF = efi.FRAILTY_DEF
			;
			
------------------------------------------------------------------------
/* Link all cohort UTIs to gp event to identify any events with LIPID_LOWERING read codes */

CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_GP_EVENT_LIPID_LOWERING');		
		
DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_GP_EVENT_LIPID_LOWERING AS (
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_GP_EVENT_LIPID_LOWERING
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
			WHERE 	fe.ALF_PE = gp.ALF_PE
			AND		gp.EVENT_DT < fe.diag_dt
			AND gp.EVENT_CD IN ('bxd5.',
								'bxd2.',
								'bxi2.',
								'bxi3.',
								'bxi1.',
								'bxiz.',
								'bxd1.',
								'bxl1.',
								'bxe7.',
								'bxkx.',
								'bxe6.',
								'bxkw.',
								'bxky.',
								'bxe5.',
								'bxdz.',
								'bx14.',
								'bxcA.',
								'bxcC.',
								'bxkz.',
								'bxc8.',
								'bxf2.',
								'bx13.',
								'bxg4.',
								'bxg3.',
								'bx12.',
								'bxc6.',
								'bxi4.',
								'bxlz.',
								'bxi5.',
								'bxcB.',
								'bxgz.',
								'bxdx.',
								'bxc4.',
								'bxi6.',
								'bxi..',
								'bxk1.',
								'bxdv.',
								'bxdy.',
								'bxiy.',
								'bxk4.',
								'bxd8.',
								'bx63.',
								'bxc5.',
								'bxc9.',
								'bxiB.',
								'bxdu.',
								'bxi7.',
								'bxdw.',
								'bx6z.',
								'bxk2.',
								'bxd6.',
								'bx11.',
								'bxe8.',
								'bxdC.',
								'bxdI.',
								'bxg2.',
								'bx18.',
								'bxe4.',
								'bxc7.',
								'bxdH.',
								'bxd7.',
								'bxi9.',
								'bxdB.',
								'bx62.',
								'bxi8.',
								'bxe3.',
								'bxg1.',
								'bxd3.',
								'bxiA.',
								'bxd9.',
								'bxd..',
								'bxk3.',
								'bxdA.',
								'bxdJ.',
								'bxg5.',
								'bxf1.',
								'bx61.',
								'bxe..',
								'bx17.',
								'bxdK.',
								'bxc..',
								'bxc1.',
								'bx1..'
								)
;

Commit;

/* Identify first event date for any episode with a recorded LIPID_LOWERING read code */

CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_COHORT_FIRST_LIPID_LOWERING');	

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_COHORT_FIRST_LIPID_LOWERING AS (
	SELECT	gpev.ALF_PE, 
			gpev.EVENT_DT
		FROM SESSION.vb_wlgp_sub_GP_EVENT_LIPID_LOWERING AS gpev)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_COHORT_FIRST_LIPID_LOWERING
	SELECT	gpev.ALF_PE,
			MIN(gpev.EVENT_DT)
		FROM SESSION.vb_wlgp_sub_GP_EVENT_LIPID_LOWERING AS gpev
	GROUP BY gpev.ALF_PE
;

Commit;

/* Update the cohort table with the prior LIPID_LOWERING date */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN LIPID_LOWERING integer
	ADD COLUMN FIRST_LIPID_LOWERING_DT DATE;

MERGE INTO sailw0972v.vb_wlgp_sub AS fe
	USING SESSION.vb_wlgp_sub_COHORT_FIRST_LIPID_LOWERING AS gpev
		ON fe.ALF_PE = gpev.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET fe.FIRST_LIPID_LOWERING_DT = gpev.EVENT_DT
			;

UPDATE sailw0972v.vb_wlgp_sub
	SET LIPID_LOWERING = 1
		WHERE FIRST_LIPID_LOWERING_DT IS NOT NULL;

UPDATE sailw0972v.vb_wlgp_sub
	SET LIPID_LOWERING = 0
		WHERE FIRST_LIPID_LOWERING_DT IS NULL;		
	
----------------------------------------------------------------
/* Link all cohort UTIs to gp event to identify any events with ASPIRIN read codes */

CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_GP_EVENT_ASPIRIN');		
	
DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_GP_EVENT_ASPIRIN AS (
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_GP_EVENT_ASPIRIN
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
			WHERE 	fe.ALF_PE = gp.ALF_PE
			AND		gp.EVENT_DT < fe.diag_dt 
			AND gp.EVENT_CD IN ('bu2..',
								'bu21.',
								'bu22.',
								'bu23.',
								'bu24.',
								'bu25.',
								'bu26.',
								'bu27.',
								'bu28.',
								'bu29.',
								'bu2a.',
								'bu2A.',
								'bu2b.',
								'bu2B.',
								'bu2C.',
								'bu2c.',
								'bu2D.',
								'bu2d.',
								'bu2E.',
								'bu2F.',
								'bu2G.',
								'bu2H.',
								'bu2I.',
								'bu2J.',
								'bu2K.'
								)
;

Commit;

/* Identify first event date for any episode with a recorded ASPIRIN read code */

CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_COHORT_FIRST_ASPIRIN');		

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_COHORT_FIRST_ASPIRIN AS (
	SELECT	gpev.ALF_PE, 
			gpev.EVENT_DT
		FROM SESSION.vb_wlgp_sub_GP_EVENT_ASPIRIN AS gpev)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_COHORT_FIRST_ASPIRIN
	SELECT	gpev.ALF_PE,
			MIN(gpev.EVENT_DT)
		FROM SESSION.vb_wlgp_sub_GP_EVENT_ASPIRIN AS gpev
	GROUP BY gpev.ALF_PE
;

Commit;

/* Update cohort table with the prior ASPIRIN date */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN ASPIRIN integer
	ADD COLUMN FIRST_ASPIRIN_DT DATE;

MERGE INTO sailw0972v.vb_wlgp_sub AS fe
	USING SESSION.vb_wlgp_sub_COHORT_FIRST_ASPIRIN AS gpev
		ON fe.ALF_PE = gpev.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET fe.FIRST_ASPIRIN_DT = gpev.EVENT_DT
			;

UPDATE sailw0972v.vb_wlgp_sub
	SET ASPIRIN = 1
		WHERE FIRST_ASPIRIN_DT IS NOT NULL;

UPDATE sailw0972v.vb_wlgp_sub
	SET ASPIRIN = 0
		WHERE FIRST_ASPIRIN_DT IS NULL;
		
--------------------------------------------------------------------------
/* Link all cohort UTIs to gp event to identify any events with ANTIHYPERTENSIVES_EXCBETA read codes */
	
CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_GP_EVENT_ANTIHYPERTENSIVES_EXCBETA');		
	
DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_GP_EVENT_ANTIHYPERTENSIVES_EXCBETA AS (
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_GP_EVENT_ANTIHYPERTENSIVES_EXCBETA
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
			WHERE 	fe.ALF_PE = gp.ALF_PE
			AND		gp.EVENT_DT < fe.diag_dt 
			AND gp.EVENT_CD IN ('bi1..',
								'bi11.',
								'bi12.',
								'bi13.',
								'bi14.',
								'bi15.',
								'bi16.',
								'bi17.',
								'bi18.',
								'bi19.',
								'bi1A.',
								'bi1B.',
								'bi1C.',
								'bi1H.',
								'bi1I.',
								'bi1J.',
								'bi1K.',
								'bi1a.',
								'bi1b.',
								'bi1c.',
								'bi1d.',
								'bi1g.',
								'bi1h.',
								'bi1i.',
								'bi1j.',
								'bi1k.',
								'bi1l.',
								'bi1m.',
								'bi1n.',
								'bi1o.',
								'bi1p.',
								'bi1q.',
								'bi1r.',
								'bi1v.',
								'bi1w.',
								'bi1x.',
								'bi1y.',
								'bi1z.',
								'bi2..',
								'bi21.',
								'bi22.',
								'bi23.',
								'bi24.',
								'bi25.',
								'bi26.',
								'bi27.',
								'bi29.',
								'bi2A.',
								'bi2B.',
								'bi2C.',
								'bi2D.',
								'bi2E.',
								'bi2F.',
								'bi2G.',
								'bi2H.',
								'bi2J.',
								'bi2K.',
								'bi2L.',
								'bi2M.',
								'bi2a.',
								'bi2t.',
								'bi2u.',
								'bi2v.',
								'bi2w.',
								'bi2x.',
								'bi2y.',
								'bi2z.',
								'bi3..',
								'bi31.',
								'bi32.',
								'bi33.',
								'bi34.',
								'bi35.',
								'bi36.',
								'bi37.',
								'bi38.',
								'bi39.',
								'bi3a.',
								'bi3b.',
								'bi3c.',
								'bi3d.',
								'bi3e.',
								'bi3f.',
								'bi3g.',
								'bi3h.',
								'bi3i.',
								'bi3j.',
								'bi3k.',
								'bi3l.',
								'bi3m.',
								'bi3q.',
								'bi3r.',
								'bi3y.',
								'bi4..',
								'bi41.',
								'bi42.',
								'bi43.',
								'bi44.',
								'bi45.',
								'bi46.',
								'bi47.',
								'bi49.',
								'bi4A.',
								'bi4B.',
								'bi4C.',
								'bi4D.',
								'bi4E.',
								'bi5..',
								'bi51.',
								'bi52.',
								'bi53.',
								'bi54.',
								'bi57.',
								'bi58.',
								'bi6..',
								'bi61.',
								'bi62.',
								'bi63.',
								'bi64.',
								'bi65.',
								'bi66.',
								'bi67.',
								'bi68.',
								'bi69.',
								'bi6A.',
								'bi6B.',
								'bi6C.',
								'bi6D.',
								'bi6E.',
								'bi6F.',
								'bi6G.',
								'bi6o.',
								'bi6p.',
								'bi6q.',
								'bi6r.',
								'bi6s.',
								'bi6t.',
								'bi6u.',
								'bi6v.',
								'bi6w.',
								'bi6x.',
								'bi6y.',
								'bi6z.',
								'bi7..',
								'bi71.',
								'bi72.',
								'bi73.',
								'bi74.',
								'bi8..',
								'bi81.',
								'bi82.',
								'bi83.',
								'bi84.',
								'bi85.',
								'bi86.',
								'bi87.',
								'bi88.',
								'bi89.',
								'bi8a.',
								'bi9..',
								'bi91.',
								'bi92.',
								'bi93.',
								'bi94.',
								'bi95.',
								'bi96.',
								'bi97.',
								'bi98.',
								'bi99.',
								'bi9A.',
								'bi9z.',
								'biA..',
								'biA1.',
								'biA2.',
								'biA3.',
								'biA4.',
								'biB..',
								'biB1.',
								'biB2.',
								'biB3.',
								'biBx.',
								'biBy.',
								'biBz.',
								'biC..',
								'biC1.',
								'biC2.',
								'biC3.',
								'biC4.',
								'biC5.',
								'biC6.',
								'bk3..',
								'bk31.',
								'bk32.',
								'bk33.',
								'bk34.',
								'bk37.',
								'bk38.',
								'bk3B.',
								'bk3C.',
								'bk3D.',
								'bk3E.',
								'bk3F.',
								'bk3G.',
								'bk3H.',
								'bk4..',
								'bk41.',
								'bk42.',
								'bk43.',
								'bk44.',
								'bk45.',
								'bk46.',
								'bk4A.',
								'bk4B.',
								'bk4C.',
								'bk4s.',
								'bk4t.',
								'bk4u.',
								'bk4v.',
								'bk4w.',
								'bk5..',
								'bk51.',
								'bk52.',
								'bk53.',
								'bk54.',
								'bk55.',
								'bk56.',
								'bk7..',
								'bk71.',
								'bk72.',
								'bk73.',
								'bk74.',
								'bk75.',
								'bk76.',
								'bk77.',
								'bk78.',
								'bk79.',
								'bk7z.',
								'bk8..',
								'bk81.',
								'bk82.',
								'bk83.',
								'bk84.',
								'bk85.',
								'bk8z.',
								'bk9..',
								'bk91.',
								'bk92.',
								'bk93.',
								'bk9x.',
								'bk9y.',
								'bk9z.',
								'bkB..',
								'bkB1.',
								'bkB2.',
								'bkB3.',
								'bkB4.',
								'bkB5.',
								'bkB6.',
								'bkJ..',
								'bkJ1.',
								'bkJ2.',
								'bkJ3.',
								'bkJ4.',
								'bkJ5.',
								'bkJ6.',
								'bb3..',
								'bb31.',
								'bb32.',
								'bb33.',
								'bb34.',
								'bb35.',
								'bb36.',
								'bb37.',
								'bb38.',
								'bb39.',
								'bb3A.',
								'bb3B.',
								'bb3C.',
								'bb3D.',
								'bb3F.',
								'bb3G.',
								'bb3H.',
								'bb3J.',
								'bb3K.',
								'bb3L.',
								'bb3M.',
								'bb3N.',
								'bb3O.',
								'bb3P.',
								'bb3Q.',
								'bb3a.',
								'bb3b.',
								'bb3d.',
								'bb3e.',
								'bb3f.',
								'bb3g.',
								'bb3h.',
								'bb3i.',
								'bb3j.',
								'bb3k.',
								'bb3l.',
								'bb3m.',
								'bb3n.',
								'bb3p.',
								'bb3q.',
								'bb3r.',
								'bb3s.',
								'bb3v.',
								'bb3w.',
								'bb3x.',
								'bb3y.',
								'bb3z.',
								'bl5..',
								'bl51.',
								'bl52.',
								'bl53.',
								'bl54.',
								'bl55.',
								'bl56.',
								'bl57.',
								'bl58.',
								'bl59.',
								'bl5A.',
								'bl5B.',
								'bl5C.',
								'bl5D.',
								'bl5E.',
								'bl5F.',
								'bl5G.',
								'bl5H.',
								'bl5I.',
								'bl5J.',
								'bl5K.',
								'bl5L.',
								'bl5M.',
								'bl5N.',
								'bl5O.',
								'bl5P.',
								'bl5Q.',
								'bl5R.',
								'bl5S.',
								'bl5T.',
								'bl5U.',
								'bl5V.',
								'bl5W.',
								'bl5X.',
								'bl5Y.',
								'bl5Z.',
								'bl5a.',
								'bl5b.',
								'bl5c.',
								'bl5d.',
								'bl5e.',
								'bl5f.',
								'bl5g.',
								'bl5h.',
								'bl5j.',
								'bl5k.',
								'bl5l.',
								'bl5m.',
								'bl5n.',
								'bl5o.',
								'bl5p.',
								'bl5q.',
								'bl5r.',
								'bl5s.',
								'bl5t.',
								'bl5u.',
								'bl5v.',
								'bl5w.',
								'bl5x.',
								'bl5y.',
								'bl5z.',
								'bl7..',
								'bl71.',
								'bl72.',
								'bl73.',
								'bl74.',
								'bl7w.',
								'bl7x.',
								'bl7y.',
								'bl7z.',
								'bl8..',
								'bl81.',
								'bl82.',
								'bl83.',
								'bl84.',
								'bl85.',
								'bl86.',
								'bl89.',
								'bl8A.',
								'bl8B.',
								'bl8C.',
								'bl8D.',
								'bl8E.',
								'bl8F.',
								'bl8G.',
								'bl8H.',
								'bl8J.',
								'bl8K.',
								'bl8L.',
								'bl8M.',
								'bl8O.',
								'bl8P.',
								'bl8Q.',
								'bl8R.',
								'bl8S.',
								'bl8T.',
								'bl8U.',
								'bl8V.',
								'bl8W.',
								'bl8X.',
								'bl8Y.',
								'bl8Z.',
								'bl8a.',
								'bl8b.',
								'bl8c.',
								'bl8d.',
								'bl8e.',
								'bl8f.',
								'bl8g.',
								'bl8h.',
								'bl8i.',
								'bl8j.',
								'bl8k.',
								'bl8l.',
								'bl8m.',
								'bl8n.',
								'bl8o.',
								'bl8p.',
								'bl8q.',
								'bl8r.',
								'bl8s.',
								'bl8t.',
								'bl8u.',
								'bl8v.',
								'bl8w.',
								'bl8x.',
								'bl8y.',
								'bl8z.',
								'bla..',
								'bla1.',
								'bla2.',
								'blb..',
								'blb1.',
								'blb2.',
								'blb3.',
								'blb4.',
								'blb5.',
								'blb6.',
								'blb7.',
								'blb8.',
								'blc..',
								'blc1.',
								'blc2.',
								'blc3.',
								'blc4.',
								'blc5.',
								'blc6.',
								'blc7.',
								'blc8.',
								'blc9.',
								'blca.',
								'blcb.',
								'blcc.',
								'blcd.',
								'blce.',
								'blcf.',
								'blcg.',
								'blch.',
								'blci.',
								'blcj.',
								'blck.',
								'blcl.',
								'blcm.',
								'blcn.',
								'blco.',
								'blcp.',
								'blcq.',
								'blcr.',
								'blcs.',
								'blct.',
								'ble..',
								'ble1.',
								'ble2.',
								'ble3.',
								'ble4.',
								'ble5.',
								'blg..',
								'blg1.',
								'blg2.',
								'blg3.',
								'blg4.',
								'blg5.',
								'blg6.',
								'blh..',
								'blh1.',
								'blh2.',
								'blh3.',
								'blh4.',
								'blj..',
								'blj1.',
								'blj2.',
								'blj3.',
								'blj4.',
								'blj5.',
								'blj6.',
								'blj7.',
								'blj8.',
								'blj9.',
								'bljA.',
								'bljB.',
								'bljC.',
								'bljD.',
								'bljE.',
								'bljF.',
								'bljG.',
								'bljH.',
								'bljJ.',
								'bljK.',
								'bljL.',
								'bljM.',
								'bljN.',
								'bljO.',
								'bljP.',
								'bljQ.',
								'bljR.',
								'bljS.',
								'bljT.',
								'bljU.',
								'bljV.',
								'bljW.',
								'bljX.',
								'bljY.',
								'bljZ.',
								'blja.',
								'bljb.',
								'bljc.',
								'bljd.',
								'blje.',
								'bljf.',
								'bll..',
								'bll1.',
								'bll2.',
								'bll3.',
								'bll4.',
								'bll5.',
								'bll6.',
								'bll7.',
								'bll8.',
								'bll9.',
								'blla.',
								'bllb.',
								'bllc.',
								'blld.',
								'blle.',
								'bllf.',
								'bllg.',
								'bllh.',
								'blli.',
								'bllj.',
								'bllk.',
								'blll.',
								'dt1..',
								'dt13.',
								'dt14.',
								'b2...',
								'b21..',
								'b211.',
								'b212.',
								'b213.',
								'b214.',
								'b215.',
								'b216.',
								'b217.',
								'b218.',
								'b219.',
								'b21A.',
								'b21B.',
								'b21a.',
								'b21b.',
								'b22..',
								'b221.',
								'b222.',
								'b22y.',
								'b22z.',
								'b23..',
								'b231.',
								'b232.',
								'b23y.',
								'b23z.',
								'b24..',
								'b25..',
								'b251.',
								'b25z.',
								'b26..',
								'b261.',
								'b262.',
								'b263.',
								'b264.',
								'b26y.',
								'b26z.',
								'b27..',
								'b271.',
								'b27z.',
								'b28..',
								'b281.',
								'b282.',
								'b283.',
								'b284.',
								'b285.',
								'b286.',
								'b287.',
								'b288.',
								'b289.',
								'b28z.',
								'b29..',
								'b291.',
								'b29z.',
								'b2a..',
								'b2a1.',
								'b2az.',
								'b2b..',
								'b2b1.',
								'b2b2.',
								'b2b3.',
								'b2bz.',
								'b2c..',
								'b2c1.',
								'b2cz.',
								'b2d..',
								'b2d1.',
								'b2dz.',
								'bA1..',
								'bA11.',
								'bA12.',
								'bA1y.',
								'bA1z.',
								'bi1D.',
								'bi1E.',
								'bi1F.',
								'bi1G.',
								'bi1e.',
								'bi1f.',
								'bi1s.',
								'bi28.',
								'bi2b.',
								'bi3n.',
								'bi3p.',
								'bi3s.',
								'bi3t.',
								'bi3u.',
								'bi3v.',
								'bi3w.',
								'bi3x.',
								'bi48.',
								'bi4F.',
								'bi55.',
								'bi56.',
								'biC7.',
								'biC8.',
								'bk35.',
								'bk36.',
								'bk39.',
								'bk3A.',
								'bk3y.',
								'bk3z.',
								'bk47.',
								'bk48.',
								'bk49.',
								'bk4x.',
								'bk4y.',
								'bk4z.',
								'bk57.',
								'bk58.',
								'bk59.',
								'bk5x.',
								'bk5y.',
								'bk5z.',
								'bk86.',
								'bk87.',
								'bk88.',
								'bk8w.',
								'bk8x.',
								'bk8y.',
								'bkC..',
								'bkC1.',
								'bkC2.',
								'bkC3.',
								'bkCx.',
								'bkCy.',
								'bkCz.',
								'bkH..',
								'bkH1.',
								'bkH2.',
								'bkH3.',
								'bkHx.',
								'bkHy.',
								'bkHz.',
								'bkI..',
								'bkI1.',
								'bkI2.',
								'bkI3.',
								'bkI4.',
								'bkI5.',
								'bkL..',
								'bkL1.',
								'bkL2.',
								'bkL3.',
								'bkL4.',
								'bkL5.',
								'bkL6.',
								'bl5i.',
								'bh4..',
								'bh5y.',
								'bh56.',
								'bh41.',
								'bh4x.',
								'bh5z.',
								'bh63.',
								'bh55.',
								'bh54.',
								'bh6B.',
								'bh1y.',
								'bh65.',
								'bh4z.',
								'bh14.',
								'bh4D.',
								'bh6A.',
								'bh68.',
								'bh4v.',
								'bh4B.',
								'bh6F.',
								'bh61.',
								'bh69.',
								'bh46.',
								'bh21.',
								'bh6E.',
								'bh4y.',
								'bh45.',
								'bh47.',
								'bh6H.',
								'bh42.',
								'bh6y.',
								'bh1z.',
								'bh5..',
								'bh6C.',
								'bh6D.',
								'bh57.',
								'bh4C.',
								'bh4A.',
								'bh6G.',
								'bh66.',
								'bh1..',
								'bh4w.',
								'bh53.',
								'bh44.',
								'bh52.',
								'bh43.',
								'bh5x.',
								'bh6z.',
								'bh13.',
								'bh51.',
								'bh64.',
								'bh67.',
								'bh49.',
								'bh48.',
								'bh11.',
								'bh2y.',
								'bh6..',
								'bh12.',
								'bh62.',
								'bf39.',
								'bf26.',
								'bf1w.',
								'bf1x.',
								'bf35.',
								'bf3b.',
								'bf42.',
								'bf44.',
								'bf3a.',
								'bf4..',
								'bf2..',
								'bf2d.',
								'bf22.',
								'bf2v.',
								'bf13.',
								'bf2c.',
								'bf27.',
								'bf2j.',
								'bf23.',
								'bf24.',
								'bf12.',
								'bf3d.',
								'bf25.',
								'bf3c.',
								'bf31.',
								'bf43.',
								'bf36.',
								'bf2e.',
								'bf33.',
								'bf2b.',
								'bf2g.',
								'bf21.',
								'bf11.',
								'bf2h.',
								'bf2z.',
								'bf32.',
								'bf34.',
								'bf41.',
								'bf29.',
								'bf2a.',
								'bf2f.',
								'bf45.',
								'bf37.',
								'bf38.',
								'bf46.',
								'be3x.',
								'be2y.',
								'be3..',
								'be3z.',
								'be3y.',
								'be1..',
								'be2x.',
								'be22.',
								'be32.',
								'be21.',
								'be31.',
								'be2..',
								'be33.',
								'bd38.',
								'bd39.',
								'bdeM.',
								'bdeN.',
								'bdeO.',
								'bdeP.',
								'bdem.',
								'bden.',
								'bdeo.',
								'bdep.',
								'bdes.',
								'bdet.',
								'bdeu.',
								'bdev.',
								'bdew.',
								'bdex.',
								'bdey.',
								'bdez.'
								)
;

Commit;

/* Identify first event date for any episode with a recorded ANTIHYPERTENSIVES_EXCBETA read code */

CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_COHORT_FIRST_ANTIHYPERTENSIVES_EXCBETA');

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_COHORT_FIRST_ANTIHYPERTENSIVES_EXCBETA AS (
	SELECT	gpev.ALF_PE, 
			gpev.EVENT_DT
		FROM SESSION.vb_wlgp_sub_GP_EVENT_ANTIHYPERTENSIVES_EXCBETA AS gpev)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_COHORT_FIRST_ANTIHYPERTENSIVES_EXCBETA
	SELECT	gpev.ALF_PE,
			MIN(gpev.EVENT_DT)
		FROM SESSION.vb_wlgp_sub_GP_EVENT_ANTIHYPERTENSIVES_EXCBETA AS gpev
	GROUP BY gpev.ALF_PE
;

Commit;

/* Update the cohort table with the prior ANTIHYPERTENSIVES_EXCBETA date */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN ANTIHYPERTENSIVES_EXCBETA integer
	ADD COLUMN FIRST_ANTIHYPERTENSIVES_EXCBETA_DT DATE;

MERGE INTO sailw0972v.vb_wlgp_sub AS fe
	USING SESSION.vb_wlgp_sub_COHORT_FIRST_ANTIHYPERTENSIVES_EXCBETA AS gpev
		ON fe.ALF_PE = gpev.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET fe.FIRST_ANTIHYPERTENSIVES_EXCBETA_DT = gpev.EVENT_DT
			;

UPDATE sailw0972v.vb_wlgp_sub
	SET ANTIHYPERTENSIVES_EXCBETA = 1
		WHERE FIRST_ANTIHYPERTENSIVES_EXCBETA_DT IS NOT NULL;

UPDATE sailw0972v.vb_wlgp_sub
	SET ANTIHYPERTENSIVES_EXCBETA = 0
		WHERE FIRST_ANTIHYPERTENSIVES_EXCBETA_DT IS NULL;
		
----------------------------------------------------------------------

--Add betablockers

CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_GP_EVENT_BETABLOCKERS');	
	
DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_GP_EVENT_BETABLOCKERS AS (
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_GP_EVENT_BETABLOCKERS
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
			WHERE 	fe.ALF_PE = gp.ALF_PE
			AND		gp.EVENT_DT < fe.diag_dt 
			AND gp.EVENT_CD IN ('bd…',
								'bd1..',
								'bd11.',
								'bd12.',
								'bd13.',
								'bd14.',
								'bd15.',
								'bd16.',
								'bd17.',
								'bd18.',
								'bd19.',
								'bd1A.',
								'bd1B.',
								'bd1C.',
								'bd1D.',
								'bd1E.',
								'bd1F.',
								'bd1G.',
								'bd1I.',
								'bd1J.',
								'bd1K.',
								'bd1L.',
								'bd1M.',
								'bd1N.',
								'bd1O.',
								'bd1P.',
								'bd1Q.',
								'bd1R.',
								'bd1S.',
								'bd1T.',
								'bd1U.',
								'bd1V.',
								'bd1W.',
								'bd1X.',
								'bd1Y.',
								'bd1Z.',
								'bd1a.',
								'bd1b.',
								'bd1c.',
								'bd1d.',
								'bd1e.',
								'bd1f.',
								'bd1g.',
								'bd1h.',
								'bd1i.',
								'bd1j.',
								'bd1k.',
								'bd1l.',
								'bd1m.',
								'bd1n.',
								'bd1o.',
								'bd1p.',
								'bd1r.',
								'bd1s.',
								'bd1t.',
								'bd1u.',
								'bd1v.',
								'bd1w.',
								'bd1x.',
								'bd1y.',
								'bd1z.',
								'bd2..',
								'bd21.',
								'bd22.',
								'bd23.',
								'bd2w.',
								'bd2x.',
								'bd2y.',
								'bd3..',
								'bd31.',
								'bd32.',
								'bd34.',
								'bd35.',
								'bd36.',
								'bd37.',
								'bd3a.',
								'bd3b.',
								'bd3c.',
								'bd3d.',
								'bd3e.',
								'bd3f.',
								'bd3g.',
								'bd3h.',
								'bd3i.',
								'bd3j.',
								'bd3k.',
								'bd3l.',
								'bd3x.',
								'bd3z.',
								'bd4..',
								'bd41.',
								'bd4z.',
								'bd5..',
								'bd51.',
								'bd52.',
								'bd53.',
								'bd54.',
								'bd55.',
								'bd56.',
								'bd57.',
								'bd58.',
								'bd59.',
								'bd5a.',
								'bd5t.',
								'bd5u.',
								'bd5v.',
								'bd5w.',
								'bd5x.',
								'bd5y.',
								'bd6..',
								'bd61.',
								'bd62.',
								'bd64.',
								'bd65.',
								'bd66.',
								'bd67.',
								'bd68.',
								'bd6b.',
								'bd6c.',
								'bd6d.',
								'bd6e.',
								'bd6w.',
								'bd6x.',
								'bd6z.',
								'bd7..',
								'bd71.',
								'bd72.',
								'bd7y.',
								'bd7z.',
								'bd8..',
								'bd81.',
								'bd82.',
								'bd83.',
								'bd84.',
								'bd85.',
								'bd86.',
								'bd87.',
								'bd88.',
								'bd89.',
								'bd8a.',
								'bd8b.',
								'bd8c.',
								'bd8d.',
								'bd8e.',
								'bd8f.',
								'bd8g.',
								'bd8h.',
								'bd8i.',
								'bd8k.',
								'bd8l.',
								'bd8m.',
								'bd8n.',
								'bd8o.',
								'bd8u.',
								'bd9..',
								'bda..',
								'bda1.',
								'bda2.',
								'bda3.',
								'bda4.',
								'bday.',
								'bdaz.',
								'bdb..',
								'bdc..',
								'bdc1.',
								'bdc2.',
								'bdc3.',
								'bdc4.',
								'bdc5.',
								'bdcu.',
								'bdcv.',
								'bdcw.',
								'bdcx.',
								'bdd..',
								'bdd1.',
								'bdd2.',
								'bddz.',
								'bde..',
								'bde1.',
								'bde2.',
								'bde3.',
								'bde4.',
								'bde5.',
								'bde6.',
								'bde7.',
								'bde8.',
								'bde9.',
								'bdeQ.',
								'bdeR.',
								'bdea.',
								'bdeb.',
								'bdec.',
								'bded.',
								'bdee.',
								'bdef.',
								'bdeg.',
								'bdeh.',
								'bdei.',
								'bdej.',
								'bdek.',
								'bDEL1.',
								'bdf..',
								'bdf1.',
								'bdf2.',
								'bdf3.',
								'bdf4.',
								'bdf5.',
								'bdf6.',
								'bdf7.',
								'bdf8.',
								'bdf9.',
								'bdfA.',
								'bdfB.',
								'bdfC.',
								'bdfD.',
								'bdfE.',
								'bdfF.',
								'bdfG.',
								'bdfH.',
								'bdfI.',
								'bdfJ.',
								'bdfK.',
								'bdfL.',
								'bdfM.',
								'bdfw.',
								'bdfx.',
								'bdfy.',
								'bdfz.',
								'bdg..',
								'bdg1.',
								'bdg2.',
								'bdh..',
								'bdh1.',
								'bdh2.',
								'bdh3.',
								'bdh4.',
								'bdi..',
								'bdi1.',
								'bdi2.',
								'bdj..',
								'bdj1.',
								'bdj2.',
								'bdj3.',
								'bdj4.',
								'bdj5.',
								'bdl..',
								'bdl1.',
								'bdl2.',
								'bdl3.',
								'bdl4.',
								'bdl5.',
								'bdl6.',
								'bdl7.',
								'bdl8.',
								'bdm..',
								'bdm1.',
								'bdm2.',
								'bdmy.',
								'bdmz.',
								'bdn..',
								'bdn1.',
								'bdn2.',
								'bdn3.',
								'bdn4.',
								'bdn5.',
								'bdn6.',
								'bd38.',
								'bd39.',
								'bdeA.',
								'bdeB.',
								'bdeC.',
								'bdeD.',
								'bdeE.',
								'bdeF.',
								'bdeG.',
								'bdeH.',
								'bdeJ.',
								'bdeK.',
								'bDEL1.',
								'bdeM.',
								'bdeN.',
								'bdeO.',
								'bdeP.',
								'bdem.',
								'bden.',
								'bdeo.',
								'bdep.',
								'bdeq.',
								'bder.',
								'bdes.',
								'bdet.',
								'bdeu.',
								'bdev.',
								'bdew.',
								'bdex.',
								'bdey.',
								'bdez.'
								)
;

Commit;

/* Identify first event date for any episode with a recorded BETABLOCKERS read code */

CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_COHORT_FIRST_BETABLOCKERS');	

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_COHORT_FIRST_BETABLOCKERS AS (
	SELECT	gpev.ALF_PE, 
			gpev.EVENT_DT
		FROM SESSION.vb_wlgp_sub_GP_EVENT_BETABLOCKERS AS gpev)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_COHORT_FIRST_BETABLOCKERS
	SELECT	gpev.ALF_PE,
			MIN(gpev.EVENT_DT)
		FROM SESSION.vb_wlgp_sub_GP_EVENT_BETABLOCKERS AS gpev
	GROUP BY gpev.ALF_PE
;

Commit;

/* Update the cohort table with the prior BETABLOCKERS date */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN BETABLOCKERS integer
	ADD COLUMN FIRST_BETABLOCKERS_DT DATE;

MERGE INTO sailw0972v.vb_wlgp_sub AS fe
	USING SESSION.vb_wlgp_sub_COHORT_FIRST_BETABLOCKERS AS gpev
		ON fe.ALF_PE = gpev.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET fe.FIRST_BETABLOCKERS_DT = gpev.EVENT_DT
			;

UPDATE sailw0972v.vb_wlgp_sub
	SET BETABLOCKERS = 1
		WHERE FIRST_BETABLOCKERS_DT IS NOT NULL;

UPDATE sailw0972v.vb_wlgp_sub
	SET BETABLOCKERS = 0
		WHERE FIRST_BETABLOCKERS_DT IS NULL;
		
------------------------------------------------------------------------------
/* Link cohort UTIs to gp event to identify any events with RENAL_DISEASE read codes */
	
CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_GP_EVENT_RENAL_DISEASE');		

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_GP_EVENT_RENAL_DISEASE AS (
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_GP_EVENT_RENAL_DISEASE
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
			WHERE 	fe.ALF_PE = gp.ALF_PE
			AND		gp.EVENT_DT < fe.diag_dt 
			AND gp.EVENT_CD IN ('1Z13.',
								'1Z14.',
								'1Z1H.',
								'1Z1J.',
								'1Z1K.',
								'1Z1L.',
								'K050.',
								'K054.',
								'K055.',
								'K060.',
								'K08z.',
								'K0D..',
								'1Z10.',
								'1Z17.',
								'1Z18.',
								'1Z11.',
								'1Z19.',
								'1Z1A.',
								'1Z12.',
								'1Z15.',
								'1Z16.',
								'1Z1B.',
								'1Z1C.',
								'1Z1D.',
								'1Z1E.',
								'1Z1F.',
								'1Z1G.'
								)
;

Commit;

/* Identify first event date for any episode with a recorded RENAL_DISEASE read code */

CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_COHORT_FIRST_RENAL_DISEASE');

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_COHORT_FIRST_RENAL_DISEASE AS (
	SELECT	gpev.ALF_PE, 
			gpev.EVENT_DT
		FROM SESSION.vb_wlgp_sub_GP_EVENT_RENAL_DISEASE AS gpev)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_COHORT_FIRST_RENAL_DISEASE
	SELECT	gpev.ALF_PE,
			MIN(gpev.EVENT_DT)
		FROM SESSION.vb_wlgp_sub_GP_EVENT_RENAL_DISEASE AS gpev
	GROUP BY gpev.ALF_PE
;

Commit;

/* Update the cohort table with the prior RENAL_DISEASE date */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN RENAL_DISEASE integer
	ADD COLUMN FIRST_RENAL_DISEASE_DT DATE;

MERGE INTO sailw0972v.vb_wlgp_sub AS fe
	USING SESSION.vb_wlgp_sub_COHORT_FIRST_RENAL_DISEASE AS gpev
		ON fe.ALF_PE = gpev.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET fe.FIRST_RENAL_DISEASE_DT = gpev.EVENT_DT
			;

UPDATE sailw0972v.vb_wlgp_sub
	SET RENAL_DISEASE = 1
		WHERE FIRST_RENAL_DISEASE_DT IS NOT NULL;

UPDATE sailw0972v.vb_wlgp_sub
	SET RENAL_DISEASE = 0
		WHERE FIRST_RENAL_DISEASE_DT IS NULL;
		
------------------------------------------------------------------
/* Link all cohort UTIs to gp event to identify any events with COPD read codes */
	
CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_GP_EVENT_COPD');

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_GP_EVENT_COPD AS (
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_GP_EVENT_COPD
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
			WHERE 	fe.ALF_PE = gp.ALF_PE
			AND		gp.EVENT_DT < fe.diag_dt 
			AND gp.EVENT_CD IN ('H3...',
								'H3121',
								'H3122',
								'H32..',
								'H320.',
								'H3200',
								'H3201',
								'H3202',
								'H3203',
								'H320z',
								'H321.',
								'H322.',
								'H32y.',
								'H32yz',
								'H32z.',
								'H36..',
								'H37..',
								'H38..',
								'H39..',
								'H3A..',
								'H3B..',
								'H3y..',
								'H3y0.',
								'H3y1.',
								'H3z..',
								'66Yg.',
								'679V.',
								'8CE6.',
								'H312.',
								'H31y.',
								'H31yz',
								'66YB.',
								'66YD.',
								'66YL.',
								'66YM.',
								'66YS.',
								'66YT.',
								'9Oi..',
								'9Oi0.',
								'9Oi1.',
								'9Oi2.',
								'H31..',
								'H312z',
								'H31z.',
								'Hyu30',
								'Hyu31',
								'66Yf.',
								'8CR1.',
								'9Oi3.',
								'9Oi4.'
								)
;

Commit;

/* Identify first event date for any episode with a recorded COPD read code */

CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_COHORT_FIRST_COPD');

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_COHORT_FIRST_COPD AS (
	SELECT	gpev.ALF_PE, 
			gpev.EVENT_DT
		FROM SESSION.vb_wlgp_sub_GP_EVENT_COPD AS gpev)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_COHORT_FIRST_COPD
	SELECT	gpev.ALF_PE,
			MIN(gpev.EVENT_DT)
		FROM SESSION.vb_wlgp_sub_GP_EVENT_COPD AS gpev
	GROUP BY gpev.ALF_PE
;

Commit;

/* Update the cohort table with the prior COPD date */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN COPD integer
	ADD COLUMN FIRST_COPD_DT DATE;

MERGE INTO sailw0972v.vb_wlgp_sub AS fe
	USING SESSION.vb_wlgp_sub_COHORT_FIRST_COPD AS gpev
		ON fe.ALF_PE = gpev.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET fe.FIRST_COPD_DT = gpev.EVENT_DT
			;

UPDATE sailw0972v.vb_wlgp_sub
	SET COPD = 1
		WHERE FIRST_COPD_DT IS NOT NULL;

UPDATE sailw0972v.vb_wlgp_sub
	SET COPD = 0
		WHERE FIRST_COPD_DT IS NULL;
		
---------------------------------------------------------
	
/* Link cohort UTIs to gp event to identify any events with ASTHMA read codes */
	
CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_GP_EVENT_ASTHMA');	

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_GP_EVENT_ASTHMA AS (
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_GP_EVENT_ASTHMA
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
			WHERE 	fe.ALF_PE = gp.ALF_PE
			AND		gp.EVENT_DT < fe.diag_dt 
			AND gp.EVENT_CD IN ('14B4.',
								'14Ok0',
								'173A.',
								'173c.',
								'173d.',
								'178..',
								'1780',
								'1781',
								'1782',
								'1783',
								'1784',
								'1785',
								'1786',
								'1787',
								'1788',
								'1789',
								'178A.',
								'178B.',
								'1O2..',
								'388t.',
								'388t0',
								'38B8.',
								'38DL.',
								'38DT.',
								'38DV.',
								'38QM.',
								'661M1',
								'661N1',
								'663..',
								'663J.',
								'663N.',
								'663N0',
								'663N1',
								'663N2',
								'663O.',
								'663O0',
								'663P.',
								'663P0',
								'663P1',
								'663P2',
								'663Q.',
								'663U.',
								'663V.',
								'663V0',
								'663V1',
								'663V2',
								'663V3',
								'663W.',
								'663d.',
								'663e.',
								'663',
								'6.63E',
								'663f.',
								'663h.',
								'663m.',
								'663r.',
								'663s.',
								'663t.',
								'663x.',
								'663y.',
								'66Y5.',
								'66Y9.',
								'66YA.',
								'66YC.',
								'66YE.',
								'66YJ.',
								'66YK.',
								'66YP.',
								'66YQ.',
								'66YR.',
								'66Ys.',
								'66Yu.',
								'66Yz0',
								'66Yz5',
								'679J.',
								'679J0',
								'679J1',
								'679J2',
								'8791',
								'8793',
								'8794',
								'8795',
								'8796',
								'8797',
								'8798',
								'8B3j.',
								'8CE2.',
								'8CMA0',
								'8CR0.',
								'8H2P.',
								'8HTT.',
								'9N1d.',
								'9N1d0',
								'9N4Q.',
								'9NI8.',
								'9NNX.',
								'9OJ..',
								'9OJ1.',
								'9OJ2.',
								'9OJ3.',
								'9OJ4.',
								'9OJ5.',
								'9OJ6.',
								'9OJ7.',
								'9OJ8.',
								'9OJA.',
								'9OJB.',
								'9OJB0',
								'9OJB1',
								'9OJB2',
								'9OJC.',
								'9OJZ.',
								'9Q21.',
								'9hA..',
								'9hA1.',
								'9hA2.',
								'H3120',
								'H33..',
								'H330.',
								'H3300',
								'H3301',
								'H330z',
								'H331.',
								'H3310',
								'H3311',
								'H331z',
								'H332.',
								'H333.',
								'H334.',
								'H335.',
								'H33z.',
								'H33z0',
								'H33z1',
								'H33z2',
								'H33zz',
								'H35y6',
								'H35y7',
								'H3B..',
								'H47y0'
								)
;

Commit;

/* Identify first event date for any episode with a recorded ASTHMA read code */

CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_COHORT_FIRST_ASTHMA');	

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_COHORT_FIRST_ASTHMA AS (
	SELECT	gpev.ALF_PE, 
			gpev.EVENT_DT
		FROM SESSION.vb_wlgp_sub_GP_EVENT_ASTHMA AS gpev)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_COHORT_FIRST_ASTHMA
	SELECT	gpev.ALF_PE,
			MIN(gpev.EVENT_DT)
		FROM SESSION.vb_wlgp_sub_GP_EVENT_ASTHMA AS gpev
	GROUP BY gpev.ALF_PE
;

Commit;

/* Update cohort table with the prior ASTHMA date */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN ASTHMA integer
	ADD COLUMN FIRST_ASTHMA_DT DATE;

MERGE INTO sailw0972v.vb_wlgp_sub AS fe
	USING SESSION.vb_wlgp_sub_COHORT_FIRST_ASTHMA AS gpev
		ON fe.ALF_PE = gpev.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET fe.FIRST_ASTHMA_DT = gpev.EVENT_DT
			;

UPDATE sailw0972v.vb_wlgp_sub
	SET ASTHMA = 1
		WHERE FIRST_ASTHMA_DT IS NOT NULL;

UPDATE sailw0972v.vb_wlgp_sub
	SET ASTHMA = 0
		WHERE FIRST_ASTHMA_DT IS NULL;
		
----------------------------------------------------------------
	
/* Link all cohort UTIs to gp event to identify any events with hypertension read codes */
	
CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_GP_EVENT_HYPERTENSION');	

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_GP_EVENT_HYPERTENSION AS (
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_GP_EVENT_HYPERTENSION
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
			WHERE 	fe.ALF_PE = gp.ALF_PE
			AND		gp.EVENT_DT < fe.diag_dt 
			AND gp.EVENT_CD IN ('14A2.',
								'G2...',
								'G20..',
								'G200.',
								'G201.',
								'G202.',
								'G203.',
								'G20z.',
								'G21..',
								'G210.',
								'G2100',
								'G2101',
								'G210z',
								'G211.',
								'G2110',
								'G2111',
								'G211z',
								'G21z.',
								'G21z0',
								'G21z1',
								'G21zz',
								'G22..',
								'G220.',
								'G221.',
								'G222.',
								'G22z.',
								'G23..',
								'G230.',
								'G231.',
								'G232.',
								'G233.',
								'G234.',
								'G23z.',
								'G24..',
								'G240.',
								'G2400',
								'G240z',
								'G241.',
								'G2410',
								'G241z',
								'G244.',
								'G24z.',
								'G24z0',
								'G24z1',
								'G24zz',
								'G25..',
								'G250.',
								'G251.',
								'G26..',
								'G27..',
								'G28..',
								'G2y..',
								'G2z..',
								'6627',
								'6628',
								'662F.',
								'662G.',
								'662O.',
								'662b.',
								'662c.',
								'662d.',
								'662r.',
								'7Q01.',
								'8B26.',
								'8BL0.',
								'8I3N.',
								'F4042',
								'F4213',
								'G672.',
								'Gyu2.',
								'L122.',
								'L1220',
								'L1221',
								'L1223',
								'L122z',
								'L127.',
								'L127z',
								'L128.',
								'L1280',
								'L1282',
								'Gyu21')
;

Commit;

/* Identify first event date for any episode with a recorded hypertension read code */

CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_COHORT_FIRST_HYPERTENSION');

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_COHORT_FIRST_HYPERTENSION AS (
	SELECT	gpev.ALF_PE, 
			gpev.EVENT_DT
		FROM SESSION.vb_wlgp_sub_GP_EVENT_HYPERTENSION AS gpev)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_COHORT_FIRST_HYPERTENSION
	SELECT	gpev.ALF_PE,
			MIN(gpev.EVENT_DT)
		FROM SESSION.vb_wlgp_sub_GP_EVENT_HYPERTENSION AS gpev
	GROUP BY gpev.ALF_PE
;

Commit;

/* Update the cohort table with the prior hypertension date */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN HYPERTENSION integer
	ADD COLUMN FIRST_HYPERTENSION_DT DATE;

MERGE INTO sailw0972v.vb_wlgp_sub AS fe
	USING SESSION.vb_wlgp_sub_COHORT_FIRST_HYPERTENSION AS gpev
		ON fe.ALF_PE = gpev.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET fe.FIRST_HYPERTENSION_DT = gpev.EVENT_DT
			;

UPDATE sailw0972v.vb_wlgp_sub
	SET HYPERTENSION = 1
		WHERE FIRST_HYPERTENSION_DT IS NOT NULL;

UPDATE sailw0972v.vb_wlgp_sub
	SET HYPERTENSION = 0
		WHERE FIRST_HYPERTENSION_DT IS NULL;
		
-------------------------------------------------------------------------------
/* Link all cohort UTIs to gp event to identify any events with DIABETES read codes */
	
CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_GP_EVENT_DIABETES');

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_GP_EVENT_DIABETES AS (
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_GP_EVENT_DIABETES
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
			WHERE 	fe.ALF_PE = gp.ALF_PE
			AND		gp.EVENT_DT < fe.diag_dt 
			AND gp.EVENT_CD IN ('66AJ.',
								'66AJ1',
								'66AJz',
								'66An.',
								'66Ao.',
								'8CR2.',
								'9OLA.',
								'C10..',
								'C100.',
								'C1000',
								'C100z',
								'C101.',
								'C1010',
								'C1011',
								'C101y',
								'C102.',
								'C1020',
								'C1021',
								'C102z',
								'C103.',
								'C1030',
								'C1031',
								'C103y',
								'C103z',
								'C104.',
								'C1040',
								'C1041',
								'C104y',
								'C104z',
								'C105.',
								'C1050',
								'C1051',
								'C105y',
								'C105z',
								'C106.',
								'C1060',
								'C1061',
								'C106y',
								'C106z',
								'C107.',
								'C1070',
								'C1071',
								'C1072',
								'C1073',
								'C1074',
								'C107y',
								'C107z',
								'C108.',
								'C1080',
								'C1081',
								'C1082',
								'C1083',
								'C1084',
								'C1085',
								'C1086',
								'C1087',
								'C1088',
								'C1089',
								'C108A',
								'C108B',
								'C108C',
								'C108D',
								'C108E',
								'C108F',
								'C108G',
								'C108H',
								'C108J',
								'C108y',
								'C108z',
								'C109.',
								'C1090',
								'C1091',
								'C1092',
								'C1093',
								'C1094',
								'C1095',
								'C1096',
								'C1097',
								'C1099',
								'C109A',
								'C109B',
								'C109C',
								'C109D',
								'C109E',
								'C109F',
								'C109G',
								'C109H',
								'C109J',
								'C109K',
								'C10A0',
								'C10A1',
								'C10A2',
								'C10A3',
								'C10A4',
								'C10A5',
								'C10A6',
								'C10A7',
								'C10AW',
								'C10AX',
								'C10B.',
								'C10B0',
								'C10C.',
								'C10D.',
								'C10E.',
								'C10E0',
								'C10E1',
								'C10E2',
								'C10E3',
								'C10E4',
								'C10E5',
								'C10E6',
								'C10E7',
								'C10E8',
								'C10E9',
								'C10EA',
								'C10EB',
								'C10EC',
								'C10ED',
								'C10EE',
								'C10EF',
								'C10EG',
								'C10EH',
								'C10EJ',
								'C10EK',
								'C10EL',
								'C10EM',
								'C10EN',
								'C10EP',
								'C10EQ',
								'C10ER',
								'C10F.',
								'C10F0',
								'C10F1',
								'C10F2',
								'C10F3',
								'C10F4',
								'C10F5',
								'C10F6',
								'C10F7',
								'C10F9',
								'C10FA',
								'C10FB',
								'C10FC',
								'C10FD',
								'C10FE',
								'C10FF',
								'C10FG',
								'C10FH',
								'C10FJ',
								'C10FK',
								'C10FL',
								'C10FM',
								'C10FN',
								'C10FP',
								'C10FQ',
								'C10FR',
								'C10FS',
								'C10G.',
								'C10G0',
								'C10H.',
								'C10H0',
								'C10K.',
								'C10K0',
								'C10M.',
								'C10M0',
								'C10N.',
								'C10N0',
								'C10N1',
								'C10P.',
								'C10P0',
								'C10P1',
								'C10y.',
								'C10y1',
								'C10yy',
								'C10yz',
								'C10z.',
								'C10z0',
								'C10z1',
								'C10zy',
								'C10zz',
								'F372.',
								'F3720',
								'F3721',
								'F3722',
								'1434',
								'14F4.',
								'14P3.',
								'9OL9.'
								)
;

Commit;

/* Identify first event date for any episode with a recorded DIABETES read code */

CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_COHORT_FIRST_DIABETES');

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_COHORT_FIRST_DIABETES AS (
	SELECT	gpev.ALF_PE, 
			gpev.EVENT_DT
		FROM SESSION.vb_wlgp_sub_GP_EVENT_DIABETES AS gpev)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_COHORT_FIRST_DIABETES
	SELECT	gpev.ALF_PE,
			MIN(gpev.EVENT_DT)
		FROM SESSION.vb_wlgp_sub_GP_EVENT_DIABETES AS gpev
	GROUP BY gpev.ALF_PE
;

Commit;

/* Update the cohort table with the prior DIABETES date */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN DIABETES integer
	ADD COLUMN FIRST_DIABETES_DT DATE;

MERGE INTO sailw0972v.vb_wlgp_sub AS fe
	USING SESSION.vb_wlgp_sub_COHORT_FIRST_DIABETES AS gpev
		ON fe.ALF_PE = gpev.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET fe.FIRST_DIABETES_DT = gpev.EVENT_DT
			;

UPDATE sailw0972v.vb_wlgp_sub
	SET DIABETES = 1
		WHERE FIRST_DIABETES_DT IS NOT NULL;

UPDATE sailw0972v.vb_wlgp_sub
	SET DIABETES = 0
		WHERE FIRST_DIABETES_DT IS NULL;
		
---------------------------------------------------------------------
	
/* Link all cohort UTIs to gp event to identify any events with OTHER_ISCHAEMIC_HD read codes */
	
CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_GP_EVENT_OTHER_ISCHAEMIC_HD');

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_GP_EVENT_OTHER_ISCHAEMIC_HD AS (
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_GP_EVENT_OTHER_ISCHAEMIC_HD
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
			WHERE 	fe.ALF_PE = gp.ALF_PE
			AND		gp.EVENT_DT < fe.diag_dt 
			AND gp.EVENT_CD IN ('G33z4',
								'G34..',
								'G34y.',
								'G34y0',
								'G34y1',
								'G34yz',
								'G34z.',
								'G34z0',
								'G3y..',
								'G3z..',
								'G31y3',
								'G332.',
								'6A2..',
								'6A4..',
								'8B3k.',
								'8H2V.',
								'G3...',
								'G31..',
								'G3110',
								'G31y.',
								'G31y2',
								'G31yz',
								'G340.',
								'G343.',
								'G344.',
								'Gyu3.',
								'Gyu32',
								'Gyu33'
								)
;

Commit;

/* Identify first event date for any episode with a recorded OTHER_ISCHAEMIC_HD read code */

CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_COHORT_FIRST_OTHER_ISCHAEMIC_HD');

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_COHORT_FIRST_OTHER_ISCHAEMIC_HD AS (
	SELECT	gpev.ALF_PE, 
			gpev.EVENT_DT
		FROM SESSION.vb_wlgp_sub_GP_EVENT_OTHER_ISCHAEMIC_HD AS gpev)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_COHORT_FIRST_OTHER_ISCHAEMIC_HD
	SELECT	gpev.ALF_PE,
			MIN(gpev.EVENT_DT)
		FROM SESSION.vb_wlgp_sub_GP_EVENT_OTHER_ISCHAEMIC_HD AS gpev
	GROUP BY gpev.ALF_PE
;

Commit;

/* Update the cohort table with the prior OTHER_ISCHAEMIC_HD date */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN OTHER_ISCHAEMIC_HD integer
	ADD COLUMN FIRST_OTHER_ISCHAEMIC_HD_DT DATE;

MERGE INTO sailw0972v.vb_wlgp_sub AS fe
	USING SESSION.vb_wlgp_sub_COHORT_FIRST_OTHER_ISCHAEMIC_HD AS gpev
		ON fe.ALF_PE = gpev.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET fe.FIRST_OTHER_ISCHAEMIC_HD_DT = gpev.EVENT_DT
			;

UPDATE sailw0972v.vb_wlgp_sub
	SET OTHER_ISCHAEMIC_HD = 1
		WHERE FIRST_OTHER_ISCHAEMIC_HD_DT IS NOT NULL;

UPDATE sailw0972v.vb_wlgp_sub
	SET OTHER_ISCHAEMIC_HD = 0
		WHERE FIRST_OTHER_ISCHAEMIC_HD_DT IS NULL;
		
--------------------------------------------------------------------------
	
/* Link all cohort UTIs to gp event to identify any events with ATRIAL_FIBRILLATION read codes */
	
CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_GP_EVENT_ATRIAL_FIBRILLATION');

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_GP_EVENT_ATRIAL_FIBRILLATION AS (
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_GP_EVENT_ATRIAL_FIBRILLATION
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
			WHERE 	fe.ALF_PE = gp.ALF_PE
			AND		gp.EVENT_DT < fe.diag_dt 
			AND gp.EVENT_CD IN ('14AN.',
								'14AR.',
								'3272',
								'8CMW2',
								'G573.',
								'G5730',
								'G5731',
								'G5732',
								'G5733',
								'G5734',
								'G5735',
								'G5736',
								'G5737',
								'G5738',
								'G5739',
								'G573z',
								'3273',
								'793M1',
								'793M3'
								)
;

Commit;

/* Identify first event date for any episode with a recorded ATRIAL_FIBRILLATION read code */

CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_COHORT_FIRST_ATRIAL_FIBRILLATION');

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_COHORT_FIRST_ATRIAL_FIBRILLATION AS (
	SELECT	gpev.ALF_PE, 
			gpev.EVENT_DT
		FROM SESSION.vb_wlgp_sub_GP_EVENT_ATRIAL_FIBRILLATION AS gpev)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_COHORT_FIRST_ATRIAL_FIBRILLATION
	SELECT	gpev.ALF_PE,
			MIN(gpev.EVENT_DT)
		FROM SESSION.vb_wlgp_sub_GP_EVENT_ATRIAL_FIBRILLATION AS gpev
	GROUP BY gpev.ALF_PE
;

Commit;

/* Update the cohort table with the prior ATRIAL_FIBRILLATION date */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN ATRIAL_FIBRILLATION integer
	ADD COLUMN FIRST_ATRIAL_FIBRILLATION_DT DATE;

MERGE INTO sailw0972v.vb_wlgp_sub AS fe
	USING SESSION.vb_wlgp_sub_COHORT_FIRST_ATRIAL_FIBRILLATION AS gpev
		ON fe.ALF_PE = gpev.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET fe.FIRST_ATRIAL_FIBRILLATION_DT = gpev.EVENT_DT
			;

UPDATE sailw0972v.vb_wlgp_sub
	SET ATRIAL_FIBRILLATION = 1
		WHERE FIRST_ATRIAL_FIBRILLATION_DT IS NOT NULL;

UPDATE sailw0972v.vb_wlgp_sub
	SET ATRIAL_FIBRILLATION = 0
		WHERE FIRST_ATRIAL_FIBRILLATION_DT IS NULL;
		
-------------------------------------------------------------------------------
	
/* Link all cohort UTIs to gp event to identify any events with HEART_FAILURE read codes */
	
CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_GP_EVENT_HEART_FAILURE');

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_GP_EVENT_HEART_FAILURE AS (
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_GP_EVENT_HEART_FAILURE
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
			WHERE 	fe.ALF_PE = gp.ALF_PE
			AND		gp.EVENT_DT < fe.diag_dt 
			AND gp.EVENT_CD IN ('G58..',
								'G580.',
								'G5800',
								'G5801',
								'G5802',
								'G5803',
								'G5804',
								'G581.',
								'G5810',
								'G582.',
								'G583.',
								'G584.',
								'G58z.',
								'G232.',
								'G234.',
								'G1yz1',
								'1O1..',
								'662W.',
								'662p.',
								'8B29.',
								'8H2S.',
								'9Or0.',
								'G400.',
								'G41z.',
								'G5540',
								'G5yy9',
								'G5yyA',
								'R2y10',
								'585f.',
								'585g.',
								'14A6.',
								'14AM.',
								'1736',
								'1J60.',
								'23E1.',
								'388D.',
								'662T.',
								'662f.',
								'662g.',
								'662h.',
								'662i.',
								'679X.',
								'8CL3.',
								'8HBE.',
								'8HHz.',
								'8Hg8.',
								'8Hk0.',
								'9N0k.',
								'9N2p.',
								'9N4s.',
								'9N4w.',
								'9N6T.',
								'9On..',
								'9On0.',
								'9On1.',
								'9On2.',
								'9On3.',
								'9On4.',
								'9Or..',
								'9Or1.',
								'9Or2.',
								'9Or3.',
								'9Or4.',
								'9Or5.',
								'9h1..',
								'9h11.',
								'9h12.',
								'9hH..',
								'9hH0.',
								'9hH1.',
								'H54..',
								'H541.',
								'H5410',
								'H541z',
								'H54z.',
								'H584.',
								'H584z',
								'ZRad.'
								)
;

Commit;

/* Identify first event date for any episode with a recorded HEART_FAILURE read code */

CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_COHORT_FIRST_HEART_FAILURE');

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_COHORT_FIRST_HEART_FAILURE AS (
	SELECT	gpev.ALF_PE, 
			gpev.EVENT_DT
		FROM SESSION.vb_wlgp_sub_GP_EVENT_HEART_FAILURE AS gpev)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_COHORT_FIRST_HEART_FAILURE
	SELECT	gpev.ALF_PE,
			MIN(gpev.EVENT_DT)
		FROM SESSION.vb_wlgp_sub_GP_EVENT_HEART_FAILURE AS gpev
	GROUP BY gpev.ALF_PE
;

Commit;

/* Update the cohort table with the prior HEART_FAILURE date */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN HEART_FAILURE integer
	ADD COLUMN FIRST_HEART_FAILURE_DT DATE;

MERGE INTO sailw0972v.vb_wlgp_sub AS fe
	USING SESSION.vb_wlgp_sub_COHORT_FIRST_HEART_FAILURE AS gpev
		ON fe.ALF_PE = gpev.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET fe.FIRST_HEART_FAILURE_DT = gpev.EVENT_DT
			;

UPDATE sailw0972v.vb_wlgp_sub
	SET HEART_FAILURE = 1
		WHERE FIRST_HEART_FAILURE_DT IS NOT NULL;

UPDATE sailw0972v.vb_wlgp_sub
	SET HEART_FAILURE = 0
		WHERE FIRST_HEART_FAILURE_DT IS NULL;
		
-------------------------------------------------------------------
	
/* Link all cohort UTIs to gp event to identify any events with PERIPHERAL_VD read codes */
	
CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_GP_EVENT_PERIPHERAL_VD');

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_GP_EVENT_PERIPHERAL_VD AS (
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_GP_EVENT_PERIPHERAL_VD
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
			WHERE 	fe.ALF_PE = gp.ALF_PE
			AND		gp.EVENT_DT < fe.diag_dt 
			AND gp.EVENT_CD IN ('G73..',
								'G734.',
								'G73y.',
								'G73z.',
								'G73z0',
								'G73zz',
								'Gyu74',
								'2G63.',
								'A3A0F',
								'C107.',
								'C1070',
								'C1071',
								'C1073',
								'C1074',
								'C107z',
								'C108G',
								'C109F',
								'C10EG',
								'C10FF',
								'G700.',
								'G702.',
								'G702z',
								'G731.',
								'G7310',
								'G731z',
								'G732.',
								'G7320',
								'G7321',
								'G733.',
								'G73y0',
								'G73y1',
								'G73yz',
								'G740.',
								'G742z',
								'M271.',
								'M2710',
								'M2713',
								'R0550'
								)
;

Commit;

/* Identify first event date for any episode with a recorded PERIPHERAL_VD read code */

CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_COHORT_FIRST_PERIPHERAL_VD');

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_COHORT_FIRST_PERIPHERAL_VD AS (
	SELECT	gpev.ALF_PE, 
			gpev.EVENT_DT
		FROM SESSION.vb_wlgp_sub_GP_EVENT_PERIPHERAL_VD AS gpev)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_COHORT_FIRST_PERIPHERAL_VD
	SELECT	gpev.ALF_PE,
			MIN(gpev.EVENT_DT)
		FROM SESSION.vb_wlgp_sub_GP_EVENT_PERIPHERAL_VD AS gpev
	GROUP BY gpev.ALF_PE
;

Commit;

/* Update the cohort table with the prior PERIPHERAL_VD date */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN PERIPHERAL_VD integer
	ADD COLUMN FIRST_PERIPHERAL_VD_DT DATE;

MERGE INTO sailw0972v.vb_wlgp_sub AS fe
	USING SESSION.vb_wlgp_sub_COHORT_FIRST_PERIPHERAL_VD AS gpev
		ON fe.ALF_PE = gpev.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET fe.FIRST_PERIPHERAL_VD_DT = gpev.EVENT_DT
			;

UPDATE sailw0972v.vb_wlgp_sub
	SET PERIPHERAL_VD = 1
		WHERE FIRST_PERIPHERAL_VD_DT IS NOT NULL;

UPDATE sailw0972v.vb_wlgp_sub
	SET PERIPHERAL_VD = 0
		WHERE FIRST_PERIPHERAL_VD_DT IS NULL;
		
---------------------------------------------------------------------
	
/* Link all cohort UTIs to gp event to identify any events with ANGINA read codes */
	
CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_GP_EVENT_ANGINA');

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_GP_EVENT_ANGINA AS (
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_GP_EVENT_ANGINA
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
			WHERE 	fe.ALF_PE = gp.ALF_PE
			AND		gp.EVENT_DT < fe.diag_dt 
			AND gp.EVENT_CD IN ('G3112',
								'G33..',
								'G330.',
								'G3300',
								'G330z',
								'G33z.',
								'G33z3',
								'G33z7',
								'G33zz',
								'662K.',
								'662K0',
								'662K1',
								'662K2',
								'662Kz',
								'8B27.',
								'G33z1',
								'G33z2',
								'G33z5',
								'G33z6',
								'G34y0',
								'Gyu30'
								)
;

Commit;

/* Identify first event date for any episode with a recorded ANGINA read code */

CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_COHORT_FIRST_ANGINA');

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_COHORT_FIRST_ANGINA AS (
	SELECT	gpev.ALF_PE, 
			gpev.EVENT_DT
		FROM SESSION.vb_wlgp_sub_GP_EVENT_ANGINA AS gpev)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_COHORT_FIRST_ANGINA
	SELECT	gpev.ALF_PE,
			MIN(gpev.EVENT_DT)
		FROM SESSION.vb_wlgp_sub_GP_EVENT_ANGINA AS gpev
	GROUP BY gpev.ALF_PE
;

Commit;

/* Update the cohort table with the prior ANGINA date */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN ANGINA integer
	ADD COLUMN FIRST_ANGINA_DT DATE;

MERGE INTO sailw0972v.vb_wlgp_sub AS fe
	USING SESSION.vb_wlgp_sub_COHORT_FIRST_ANGINA AS gpev
		ON fe.ALF_PE = gpev.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET fe.FIRST_ANGINA_DT = gpev.EVENT_DT
			;

UPDATE sailw0972v.vb_wlgp_sub
	SET ANGINA = 1
		WHERE FIRST_ANGINA_DT IS NOT NULL;

UPDATE sailw0972v.vb_wlgp_sub
	SET ANGINA = 0
		WHERE FIRST_ANGINA_DT IS NULL;
		
------------------------------------------------------------------

/* Link cohort UTIs to gp event to identify any events with TRANSIENT_ISCHAEMIC read codes */
	
CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_GP_EVENT_TRANSIENT_ISCHAEMIC');

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_GP_EVENT_TRANSIENT_ISCHAEMIC AS (
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_GP_EVENT_TRANSIENT_ISCHAEMIC
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
			WHERE 	fe.ALF_PE = gp.ALF_PE
			AND		gp.EVENT_DT < fe.diag_dt 
			AND gp.EVENT_CD IN ('G65z.',
								'G65zz',
								'G65z1',
								'G65y.',
								'14AB.',
								'G65z0',
								'Fyu55',
								'G65..'
								)
;

Commit;

/* Identify first event date for any episode with a recorded TRANSIENT_ISCHAEMIC read code */

CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_COHORT_FIRST_TRANSIENT_ISCHAEMIC');

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_COHORT_FIRST_TRANSIENT_ISCHAEMIC AS (
	SELECT	gpev.ALF_PE, 
			gpev.EVENT_DT
		FROM SESSION.vb_wlgp_sub_GP_EVENT_TRANSIENT_ISCHAEMIC AS gpev)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_COHORT_FIRST_TRANSIENT_ISCHAEMIC
	SELECT	gpev.ALF_PE,
			MIN(gpev.EVENT_DT)
		FROM SESSION.vb_wlgp_sub_GP_EVENT_TRANSIENT_ISCHAEMIC AS gpev
	GROUP BY gpev.ALF_PE
;

Commit;

/* Update the cohort table with the prior TRANSIENT_ISCHAEMIC date */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN TRANSIENT_ISCHAEMIC integer
	ADD COLUMN FIRST_TRANSIENT_ISCHAEMIC_DT DATE;

MERGE INTO sailw0972v.vb_wlgp_sub AS fe
	USING SESSION.vb_wlgp_sub_COHORT_FIRST_TRANSIENT_ISCHAEMIC AS gpev
		ON fe.ALF_PE = gpev.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET fe.FIRST_TRANSIENT_ISCHAEMIC_DT = gpev.EVENT_DT
			;

UPDATE sailw0972v.vb_wlgp_sub
	SET TRANSIENT_ISCHAEMIC = 1
		WHERE FIRST_TRANSIENT_ISCHAEMIC_DT IS NOT NULL;

UPDATE sailw0972v.vb_wlgp_sub
	SET TRANSIENT_ISCHAEMIC = 0
		WHERE FIRST_TRANSIENT_ISCHAEMIC_DT IS NULL;
	
----------------------------------------------------------------------------------------
--add prostate disease

/* Link cohort UTIs to gp event to identify any events with PROSTATE disease read codes */
	
CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_GP_EVENT_PROSTATE');

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_GP_EVENT_PROSTATE AS (
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_GP_EVENT_PROSTATE
	SELECT	fe.ALF_PE, 
			gp.EVENT_DT,
			gp.EVENT_CD
		FROM	sailw0972v.vb_wlgp_sub AS fe,
				SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
			WHERE 	fe.ALF_PE = gp.ALF_PE
			AND		gp.EVENT_DT < fe.diag_dt 
			AND gp.EVENT_CD IN ('G65z.',
								'G65zz',
								'G65z1',
								'G65y.',
								'14AB.',
								'G65z0',
								'Fyu55',
								'G65..'
								)
;

Commit;

/* Identify first event date for any episode with a recorded PROSTATE disease read code */

CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_COHORT_FIRST_PROSTATE');

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_COHORT_FIRST_PROSTATE AS (
	SELECT	gpev.ALF_PE, 
			gpev.EVENT_DT
		FROM SESSION.vb_wlgp_sub_GP_EVENT_PROSTATE AS gpev)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_COHORT_FIRST_PROSTATE
	SELECT	gpev.ALF_PE,
			MIN(gpev.EVENT_DT)
		FROM SESSION.vb_wlgp_sub_GP_EVENT_PROSTATE AS gpev
	GROUP BY gpev.ALF_PE
;

Commit;

/* Update the cohort table with the prior PROSTATE disease date */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN PROSTATE integer
	ADD COLUMN FIRST_PROSTATE_DT DATE;

MERGE INTO sailw0972v.vb_wlgp_sub AS fe
	USING SESSION.vb_wlgp_sub_COHORT_FIRST_PROSTATE AS gpev
		ON fe.ALF_PE = gpev.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET fe.FIRST_PROSTATE_DT = gpev.EVENT_DT
			;

UPDATE sailw0972v.vb_wlgp_sub
	SET PROSTATE = 1
		WHERE FIRST_PROSTATE_DT IS NOT NULL;

UPDATE sailw0972v.vb_wlgp_sub
	SET PROSTATE = 0
		WHERE FIRST_PROSTATE_DT IS NULL;
	
---------------------------------------------------------------------
		
--identify congenital abnormalities	

/* Link all pedw utis to pedw diagnoses to identify any episodes with congenital abnormality icd-10 codes*/

CALL fnc.drop_if_exists('SESSION.vb_wlgp_sub_CONGEN');

DECLARE GLOBAL TEMPORARY TABLE SESSION.vb_wlgp_sub_CONGEN
(alf_pe varchar(15),
uti_dt date,
event_dt date)
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.vb_wlgp_sub_CONGEN
							(ALF_PE,
							uti_dt,
							EVENT_DT)
				WITH rs AS
	(SELECT PROV_UNIT_CD,
			SPELL_NUM_PE,
			EPI_NUM,
			DIAG_CD_1234
			FROM sail0972v.PEDW_DIAG_20211101
			WHERE (DIAG_CD_1234 IN ('G958',
								'G834',
								'Q614',
								'Q603',
								'Q604',
								'Q605',
								'Q620',
								'Q627',
								'N137',
								'N110',
								'Q642',
								'Q622',
								'Q600',
								'Q601',
								'Q602',
								'Q606',
								'Q610',
								'Q611',
								'Q612',
								'Q613',
								'Q615',
								'Q618',
								'Q619',
								'Q621',
								'Q623',
								'Q624',
								'Q625',
								'Q626',
								'Q628',
								'Q640',
								'Q641',
								'Q643',
								'Q644',
								'Q645',
								'Q646',
								'Q647',
								'Q648',
								'Q649',
								'P960'
								)
			OR DIAG_CD_123 IN ('Q05',
								'N31',
								'Q63',
								'G80',
								'G81',
								'G82',
								'G83')
			)),
								CTE AS 
							(SELECT sp.ALF_PE,
									sp.ALF_STS_CD,
									eps.EPI_STR_DT,
									rs.DIAG_CD_1234 
								FROM rs
							LEFT JOIN sail0972v.PEDW_EPISODE_20211101 AS eps
								ON rs.PROV_UNIT_CD = eps.PROV_UNIT_CD
								AND rs.SPELL_NUM_PE = eps.SPELL_NUM_PE
								AND rs.EPI_NUM = eps.EPI_NUM
							LEFT JOIN sail0972v.PEDW_SPELL_20211101 AS sp
								ON rs.PROV_UNIT_CD = sp.PROV_UNIT_CD
								AND rs.SPELL_NUM_PE = sp.SPELL_NUM_PE
					WHERE sp.ALF_PE IS NOT NULL
					AND sp.ALF_STS_CD IN ('1','4','39')
					),
			cte2 AS
			(SELECT alf_pe, min(epi_str_dt) AS event_dt FROM cte
				GROUP BY alf_pe)
				SELECT coh.ALF_PE,
						coh.diag_dt,
							CASE WHEN CTE2.EVENT_DT < coh.diag_dt
										THEN CTE2.EVENT_DT
									ELSE NULL
										end
					FROM sailw0972v.vb_wlgp_sub AS coh
						LEFT JOIN CTE2
							ON coh.ALF_PE = CTE2.ALF_PE;
						
Commit;

/* Update the cohort table with the prior congenital abnormality date */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN CONGEN_ABN integer
	ADD COLUMN FIRST_CONGEN_ABN_DT DATE;

MERGE INTO sailw0972v.vb_wlgp_sub AS fe
	USING SESSION.vb_wlgp_sub_CONGEN AS gpev
		ON fe.ALF_PE||diag_dt = gpev.ALF_PE||gpev.uti_dt
			WHEN MATCHED THEN
				UPDATE
				SET fe.FIRST_CONGEN_ABN_DT = gpev.EVENT_DT
			;

UPDATE sailw0972v.vb_wlgp_sub
	SET CONGEN_ABN = 1
		WHERE FIRST_CONGEN_ABN_DT IS NOT NULL;

UPDATE sailw0972v.vb_wlgp_sub
	SET CONGEN_ABN = 0
		WHERE FIRST_CONGEN_ABN_DT IS NULL;
	
-----------------------------------------------------------------------------------------
-----------------------------------------------------------------------------------------

-- ***********************   link crp to hospital UTI cohort	  ******************

------------------------------------------------------------------------------------------
/* this section should not be needed - retaining code for now	
	
CALL FNC.DROP_IF_EXISTS('SAILW0972V.VB_CRP_TEST_RECS_wlgp_uti');
   
CREATE TABLE SAILW0972V.VB_CRP_TEST_RECS_wlgp_uti
(    alf_pe  bigint,
	 crptest_dt  date,
	 uti_date  date,
	 admis_dt date,
	 request_seq integer,
	 report_seq integer,
	 code  varchar(30),
	 name  varchar(90),
	 valtype varchar(3),
	 val  varchar(100),
	 referencerange varchar(60),
	 abnormal_sts_cd  varchar(30),
	 UNITOFMEASUREMENT varchar(25)
)
distribute BY hash(alf_pe);

INSERT INTO SAILW0972V.VB_CRP_TEST_RECS_wlgp_uti
SELECT distinct uti.alf_pe,
      wrrs.SPCM_COLLECTED_DT AS test_date,
      uti.diag_dt AS uti_date,
      uti.admis_dt,
     wrrs.REQUEST_SEQ,
     wrrs.REPORT_SEQ,
     wrrs.code,
     wrrs.name,
     wrrs.val_type,
     wrrs.val,
     wrrs.REFERENCERANGE,
     wrrs.abnormal_sts_cd,
     wrrs.UNITOFMEASUREMENT
FROM SAIL0972V.WRRS_OBSERVATION_RESULT_20211019 wrrs 
JOIN sailw0972v.vb_wlgp_sub uti
   ON uti.alf_pe = wrrs.ALF_PE 
   AND wrrs.SPCM_COLLECTED_DT  BETWEEN (uti.admis_dt) AND  (uti.admis_dt + 2 DAYS)
   WHERE (lower(name) LIKE '%crp%' OR lower(name)  LIKE '%reactive%')
	   OR code LIKE '%CRP%'
   ORDER BY uti.alf_pe;

-- *********************************** highest CRP test ********************************

--highest value within 2 days of uti

CALL FNC.DROP_IF_EXISTS('SAILW0972V.VB_CRP_HIGH_wlgp_uti');

CREATE TABLE SAILW0972V.VB_CRP_HIGH_wlgp_uti
(   alf_pe  bigint,
    admis_dt  date,
    crp_highest   decimal(9,2)
)
distribute BY hash ( alf_pe) ;

INSERT INTO  SAILW0972V.VB_CRP_HIGH_wlgp_uti
SELECT alf_pe, admis_dt,max(clean_val )  highrset_crp 
  FROM (
		SELECT alf_pe,
				crptest_dt,
				uti_date,
				admis_dt,
				code,
				name,
				valtype,
				CASE WHEN LEFT(val,1) IN ( '0' ,'1','2','3','4','5','6','7','8', '9') THEN CAST(val AS decimal(9,2))
				    ELSE   0.0
				END clean_val,
				abnormal_sts_cd,
				UNITOFMEASUREMENT 
		FROM SAILW0972V.VB_CRP_TEST_RECS_wlgp_uti	 
		WHERE valtype = 'SN'
		    AND DAYS(crptest_DT)  BETWEEN DAYS(admis_dt)  AND  DAYS(admis_dt) +2
		ORDER BY alf_pe,crptest_dt
)
GROUP by alf_pe,admis_dt
ORDER BY alf_pe,admis_dt;

--------------------------------------------------------------------------------------------------------

--add highest crp to hospital UTI cohort

ALTER TABLE sailw0972v.vb_wlgp_sub
ADD COLUMN HIGHEST_CRP INTEGER;

MERGE INTO sailw0972v.vb_wlgp_sub AS coh
	USING SAILW0972V.VB_CRP_HIGH_wlgp_uti AS crp
		ON coh.ALF_PE = crp.ALF_PE
		AND coh.admis_dt = crp.admis_dt
			WHEN MATCHED THEN
				UPDATE
				SET coh.HIGHEST_CRP = crp.CRP_HIGHEST
			;
		
------------------------------------------------------------------------------------------------------
	
--add admission route description to cohort table
		
ALTER TABLE sailw0972v.vb_wlgp_sub
ADD COLUMN admis_mthd_desc varchar(255)
ADD COLUMN admis_cat varchar(25);
		
UPDATE sailw0972v.vb_wlgp_sub AS con
SET admis_mthd_desc = 
(SELECT DISTINCT 
		ad.MAIN_DESCRIPTION
	from sailukhdv.DD_ADMISSION_METHOD_SCD AS ad
		WHERE con.admis_mthd_cd = ad.MAIN_CODE_TEXT
		AND ad.VALID_TO IS null
		AND ad.CATEGORY IN ('Default codes',
							'Elective admission',
							'Emergency admission',
							'Maternity admission',
							'Other admission'));
						
UPDATE sailw0972v.vb_wlgp_sub AS con
SET admis_cat = 
(SELECT DISTINCT 
		ad.CATEGORY
	from sailukhdv.DD_ADMISSION_METHOD_SCD AS ad
		WHERE con.admis_mthd_cd = ad.MAIN_CODE_TEXT
		AND ad.VALID_TO IS null
		AND ad.CATEGORY IN ('Default codes',
							'Elective admission',
							'Emergency admission',
							'Maternity admission',
							'Other admission'));
							
*/
						
-----------------------------------------------------------------
--add uti diagnosis year

alter table sailw0972v.vb_wlgp_sub
ADD COLUMN diag_yr integer;

UPDATE sailw0972v.vb_wlgp_sub
SET diag_yr = year(DIAG_DT);

SELECT * FROM sailw0972v.vb_wlgp_sub;

------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------
------------------------------------------------------------------------------------------------------------------
------- BMI script FOR adults aged 18 and over ----------------------
--- to do first....

--1. Create a cohort table in your schema containing a list of alf's and their WOBs. 

-----------------------------------------------------------------------------------------------------------------
--2. Type the name of your table into the script below under "YOUR_USER_TABLE_GOES_HERE" 

CALL FNC.DROP_IF_EXISTS ('SAILW0972V.VB_BMI_wlgp_uti');			
			
CREATE TABLE SAILW0972V.VB_BMI_wlgp_uti AS
(SELECT ALF_PE,
		WOB
FROM sailw0972v.vb_wlgp_sub)
WITH NO DATA;

INSERT INTO SAILW0972V.VB_BMI_wlgp_uti
SELECT ALF_PE,
		WOB
FROM sailw0972v.vb_wlgp_sub;

CREATE OR REPLACE ALIAS SAILW0972V.BMI_COHORT
FOR SAILW0972V.VB_BMI_wlgp_uti;		

--CREATE OR REPLACE ALIAS SAILW0972V.BMI_COHORT
--FOR SAILW0972V.BMI_COHORT_TEST;
--SELECT * FROM SAILW0972V.BMI_COHORT_TEST

-----------------------------------------------------------------------------------------------------------------
---3. Find and replace all 0972 with your project schema number using ctrl + f

-----------------------------------------------------------------------------------------------------------------
---4. Find and replace all ALF_PE with yout alf format using ctrl + f.
---	  Find and replace all SPELL_NUM_PE with yout spell_num format using ctrl + f.

-----------------------------------------------------------------------------------------------------------------

---5. Create an alias for the most recent versions of the WLGP and PEDW event tables as below:

--create reduced gp table for cohort only

CALL fnc.drop_if_exists('SAILW0972V.vb_wlgp_sub_GP');

CREATE TABLE SAILW0972V.vb_wlgp_sub_GP
	AS (SELECT * FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301) WITH NO DATA;

alter table SAILW0972V.vb_wlgp_sub_GP activate not logged INITIALLY;

INSERT INTO SAILW0972V.vb_wlgp_sub_GP
	SELECT gp.* FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
		INNER JOIN (SELECT DISTINCT alf_pe 
					FROM SAILW0972V.BMI_COHORT) AS coh 
			ON gp.ALF_PE = coh.ALF_PE
			WHERE coh.ALF_PE LIKE ('%0');
		
COMMIT;
		
alter table SAILW0972V.vb_wlgp_sub_GP activate not logged INITIALLY;
		
INSERT INTO SAILW0972V.vb_wlgp_sub_GP
	SELECT gp.* FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
		INNER JOIN (SELECT DISTINCT alf_pe 
					FROM SAILW0972V.BMI_COHORT) AS coh 
			ON gp.ALF_PE = coh.ALF_PE
			WHERE coh.ALF_PE LIKE ('%1');
		
COMMIT;

alter table SAILW0972V.vb_wlgp_sub_GP activate not logged INITIALLY;
		
INSERT INTO SAILW0972V.vb_wlgp_sub_GP
	SELECT gp.* FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
		INNER JOIN (SELECT DISTINCT alf_pe 
					FROM SAILW0972V.BMI_COHORT) AS coh
			ON gp.ALF_PE = coh.ALF_PE
			WHERE coh.ALF_PE LIKE ('%2');
		
COMMIT;

alter table SAILW0972V.vb_wlgp_sub_GP activate not logged INITIALLY;
		
INSERT INTO SAILW0972V.vb_wlgp_sub_GP
	SELECT gp.* FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
		INNER JOIN (SELECT DISTINCT alf_pe 
					FROM SAILW0972V.BMI_COHORT) AS coh
			ON gp.ALF_PE = coh.ALF_PE
			WHERE coh.ALF_PE LIKE ('%3');
		
COMMIT;

alter table SAILW0972V.vb_wlgp_sub_GP activate not logged INITIALLY;
		
INSERT INTO SAILW0972V.vb_wlgp_sub_GP
	SELECT gp.* FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
		INNER JOIN (SELECT DISTINCT alf_pe 
					FROM SAILW0972V.BMI_COHORT) AS coh
			ON gp.ALF_PE = coh.ALF_PE
			WHERE coh.ALF_PE LIKE ('%4');
		
COMMIT;

alter table SAILW0972V.vb_wlgp_sub_GP activate not logged INITIALLY;
		
INSERT INTO SAILW0972V.vb_wlgp_sub_GP
	SELECT gp.* FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
		INNER JOIN (SELECT DISTINCT alf_pe 
					FROM SAILW0972V.BMI_COHORT) AS coh
			ON gp.ALF_PE = coh.ALF_PE
			WHERE coh.ALF_PE LIKE ('%5');
		
COMMIT;

alter table SAILW0972V.vb_wlgp_sub_GP activate not logged INITIALLY;
		
INSERT INTO SAILW0972V.vb_wlgp_sub_GP
	SELECT gp.* FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
		INNER JOIN (SELECT DISTINCT alf_pe 
					FROM SAILW0972V.BMI_COHORT) AS coh
			ON gp.ALF_PE = coh.ALF_PE
			WHERE coh.ALF_PE LIKE ('%6');
		
COMMIT;

alter table SAILW0972V.vb_wlgp_sub_GP activate not logged INITIALLY;
		
INSERT INTO SAILW0972V.vb_wlgp_sub_GP
	SELECT gp.* FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
		INNER JOIN (SELECT DISTINCT alf_pe 
					FROM SAILW0972V.BMI_COHORT) AS coh
			ON gp.ALF_PE = coh.ALF_PE
			WHERE coh.ALF_PE LIKE ('%7');
		
COMMIT;

alter table SAILW0972V.vb_wlgp_sub_GP activate not logged INITIALLY;
		
INSERT INTO SAILW0972V.vb_wlgp_sub_GP
	SELECT gp.* FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
		INNER JOIN SAILW0972V.BMI_COHORT AS coh
			ON gp.ALF_PE = coh.ALF_PE
			WHERE coh.ALF_PE LIKE ('%8');
		
COMMIT;

alter table SAILW0972V.vb_wlgp_sub_GP activate not logged INITIALLY;
		
INSERT INTO SAILW0972V.vb_wlgp_sub_GP
	SELECT gp.* FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301 AS gp
		INNER JOIN (SELECT DISTINCT alf_pe 
					FROM SAILW0972V.BMI_COHORT) AS coh
			ON gp.ALF_PE = coh.ALF_PE
			WHERE coh.ALF_PE LIKE ('%9');
		
COMMIT;

CREATE OR REPLACE ALIAS SAILW0972V.BMI_ALG_GP
FOR SAILW0972V.vb_wlgp_sub_GP;

CREATE OR REPLACE ALIAS SAILW0972V.BMI_ALG_PEDW_SPELL
FOR SAIL0972V.PEDW_SPELL_20211101;

CREATE OR REPLACE ALIAS SAILW0972V.BMI_ALG_PEDW_DIAG
FOR SAIL0972V.PEDW_DIAG_20211101;

-----------------------------------------------------------------------------------------------------------------
--6. Create variables for the earliest and latest dates you want the BMI values for (replace dates as necessary)

CREATE OR REPLACE VARIABLE SAILW0972V.BMI_DATE_FROM  DATE;
SET SAILW0972V.BMI_DATE_FROM = '2009-01-01';
CREATE OR REPLACE VARIABLE SAILW0972V.BMI_DATE_TO  DATE;
SET SAILW0972V.BMI_DATE_TO = '2020-12-31';


-----------------------------------------------------------------------------------------------------------------
--				RUN CODE FROM HERE
-----------------------------------------------------------------------------------------------------------------

--Optional 1. Acceptable sts codes -- set to 1, 4 and 39

-----------------------------------------------------------------------------------------------------------------
--Optional 2. Assign your acceptable ranges for bmi at:
-- same day varitaion - default = 0.05
CREATE OR REPLACE VARIABLE SAILW0972V.BMI_SAME_DAY DOUBLE DEFAULT 0.05;
-- rate of change - default = 0.003
CREATE OR REPLACE VARIABLE SAILW0972V.BMI_RATE DOUBLE DEFAULT 0.003; 

-----------------------------------------------------------------------------------------------------------------
-- Optional 3. Create lookup table -- feel free to review the codes listed below and make any changes

CALL FNC.DROP_IF_EXISTS ('SAILW0972V.BMI_LOOKUP');

CREATE TABLE SAILW0972V.BMI_LOOKUP
(
        bmi_code        CHAR(5),
        description		VARCHAR(300),
        complexity		VARCHAR(51),
        category		VARCHAR(20)
);

--granting access to team mates
GRANT ALL ON TABLE SAILW0972V.BMI_LOOKUP TO ROLE NRDASAIL_SAIL_0972_ANALYST;

--worth doing for large chunks of data
alter table SAILW0972V.BMI_LOOKUP activate not logged INITIALLY;

-- This lookup table contains the GP look up codes relevent to height, weight and BMI, they are categorised as such.
insert into SAILW0972V.BMI_LOOKUP
VALUES
('2293.', 'O/E -height within 10% average', 'where event_val between x and y (depending on unit)', 'height'),
('229..', 'O/E - height', 'where event_val between x and y (depending on unit)', 'height'),
('229Z.', 'O/E - height NOS', 'where event_val between x and y (depending on unit)', 'height'),
('2292.', 'O/E - height 10-20% < average', 'included, but only 6 records', 'height'),
('2294.', 'O/E-height 10-20% over average', 'included, but only 1 records', 'height'),
('2295.', 'O/E -height > 20% over average', 'included, but only 4 records', 'height'),
('2291.', 'O/E-height > 20% below average', 'included, but only 23 records', 'height'),
('22A..', 'O/E - weight', 'where event_val between 32 and 250', 'weight'),
('22A1.', 'O/E - weight > 20% below ideal', 'where event_val between 32 and 250', 'weight'),
('22A2.', 'O/E -weight 10-20% below ideal', 'where event_val between 32 and 250', 'weight'),
('22A3.', 'O/E - weight within 10% ideal', 'where event_val between 32 and 250', 'weight'),
('22A4.', 'O/E - weight 10-20% over ideal', 'where event_val between 32 and 250', 'weight'),
('22A5.', 'O/E - weight > 20% over ideal', 'where event_val between 32 and 250', 'weight'),
('22A6.', 'O/E - Underweight', 'where event_val between 32 and 250', 'weight'),
('22AA.', 'Overweight', 'where event_val between 32 and 250', 'weight'),
('22AZ.', 'O/E - weight NOS', 'where event_val between 32 and 250', 'weight'),
('1266.', 'FH: Obesity', 'Obese', 'obese'),
('1444.', 'H/O: obesity', 'Obese', 'Obese class unknown'),
('22K3.', 'Body Mass Index low K/M2', 'Underweight', 'underweight'),
('22K..', 'Body Mass Index', 'bmi', 'bmi'),
('22K1.', 'Body Mass Index normal K/M2', 'Normal weight', 'normal weight'),
('22K2.', 'Body Mass Index high K/M2', 'Overweight/Obese', 'obese class unknown'),
('22K4.', 'Body mass index index 25-29 - overweight', 'Overweight', 'overweight'),
('22K5.', 'Body mass index 30+ - obesity', 'Obese', 'Obese class unknown'),
('22K6.', 'Body mass index less than 20', 'Underweight', 'underweight'),
('22K7.', 'Body mass index 40+ - severely obese', 'Obese', 'obese class3'),
('22K8.', 'Body mass index 20-24 - normal', 'Normal weight', 'normal weight'),
('22K9.', 'Body mass index centile', 'bmi', 'bmi'),
('22KC.', 'Obese class I (body mass index 30.0 - 34.9)', 'Obese', 'obese class1'),
('22KC.', 'Obese class I (BMI 30.0-34.9)', 'Obese', 'obese class1'),
('22KD.', 'Obese class II (body mass index 35.0 - 39.9)', 'Obese', 'obese class2'),
('22KD.', 'Obese class II (BMI 35.0-39.9)', 'Obese', 'obese class2'),
('22KE.', 'Obese class III (BMI equal to or greater than 40.0)', 'Obese', 'obese class3'),
('22KE.', 'Obese cls III (BMI eq/gr 40.0)', 'Obese', 'obese class3'),
('66C4.', 'Has seen dietician - obesity', 'Obese', 'Obese class unknown'),
('66C6.', 'Treatment of obesity started', 'Obese', 'Obese class unknown'),
('66CE.', 'Reason for obesity therapy - occupational', 'Obese', 'Obese class unknown'),
('8CV7.', 'Anti-obesity drug therapy commenced', 'Obese', 'Obese class unknown'),
('8T11.', 'Rfrrl multidisip obesity clin', 'Obese', 'Obese class unknown'),
('C38..', 'Obesity/oth hyperalimentation', 'Obese', 'Obese class unknown'),
('C380.', 'Obesity', 'Obese', 'Obese class unknown'),
('C3800', 'Obesity due to excess calories', 'Obese', 'Obese class unknown'),
('C3801', 'Drug-induced obesity', 'Obese', 'Obese class unknown'),
('C3802', 'Extrem obesity+alveol hypovent', 'Obese', 'obese class3'),
('C3803', 'Morbid obesity', 'Obese', 'obese class3'),
('C3804', 'Central obesity', 'Obese', 'Obese class unknown'),
('C3805', 'Generalised obesity', 'Obese', 'Obese class unknown'),
('C3806', 'Adult-onset obesity', 'Obese', 'Obese class unknown'),
('C3807', 'Lifelong obesity', 'Obese', 'Obese class unknown'),
('C38z.', 'Obesity/oth hyperalimentat NOS', 'Obese', 'Obese class unknown'),
('C38z0', 'Simple obesity NOS', 'Obese', 'Obese class unknown'),
('Cyu7.', '[X]Obesity+oth hyperalimentatn', 'Obese', 'Obese class unknown'),
('22K4.', 'BMI 25-29 - overweight', 'Overweight', 'overweight'),
('22A1.', 'O/E - weight > 20% below ideal', 'Underweight', 'underweight'),
('22A2.', 'O/E -weight 10-20% below ideal', 'Underweight', 'underweight'),
('22A3.', 'O/E - weight within 10% ideal', 'Normal weight', 'normal weight'),
('22A4.', 'O/E - weight 10-20% over ideal', 'Overweight', 'overweight'),
('22A5.', 'O/E - weight > 20% over ideal', 'Overweight', 'overweight'),
('22A6.', 'O/E - Underweight', 'Underweight', 'underweight'),
('22AA.', 'Overweight', 'Overweight', 'overweight'),
('R0348', '[D] Underweight', 'Underweight', 'underweight'),
('66C1.','Itinital obesity assessment','Obese','Obese class unknown'),
('66C2.','Follow-up obesity assessment','Obese','Obese class unknown'),
('66C5.','Treatment of obesity changed','Obese','Obese class unknown'),
('66CX.','Obesity multidisciplinary case review','Obese','Obese class unknown'),
('66CZ.','Obesity monitoring NOS','Obese','Obese class unknown'),
('9hN..','Exception reporting: obesity quality indicators','Obese','Obese class unknown'),
('9OK..','Obesity monitoring admin.','Obese','Obese class unknown'),
('9OK1.','Attends obesity monitoring','Obese','Obese class unknown'),
('9OK3.','Obesity monitoring default','Obese','Obese class unknown'),
('9OK2.','Refuses obesity monitoring','Obese','Obese class unknown'),
('9OK4.','Obesity monitoring 1st letter','Obese','Obese class unknown'),
('9OK5.','Obesity monitoring 2nd letter','Obese','Obese class unknown'),
('9OK6.','Obesity monitoring 3rd letter','Obese','Obese class unknown'),
('9OK7.','Obesity monitoring verbal inv.','Obese','Obese class unknown'),
('9OK8.','Obesity monitor phone invite','Obese','Obese class unknown'),
('9OKA.','Obesity monitoring check done','Obese','Obese class unknown'),
('9OKZ.','Obesity monitoring admin.NOS','Obese','Obese class unknown'),
('C38y0','Pickwickian syndrome','Obese','Obese class unknown')
;

-- end of read codes

SELECT * FROM SAILW0972V.BMI_LOOKUP;

-----------------------------------------------------------------------------------------------------------------
-- 8. Drop final BMI table if it exists using the code below

CALL FNC.DROP_IF_EXISTS ('SAILW0972V.BMI_ALG_OUTPUT');
CALL FNC.DROP_IF_EXISTS ('SAILW0972V.BMI_UNCLEANED');

-----------------------------------------------------------------------------------------------------------------
-- 9. Create a table from BMI codes that give BMI categories. Takes their values with them when present

CALL FNC.DROP_IF_EXISTS ('SAILW0972V.BMI_CATa');

CREATE TABLE SAILW0972V.BMI_CATa
(
		alf_pe        	BIGINT,
		bmi_dt     		DATE,
		bmi_cat2	   	VARCHAR(20),
		bmi_val       	INTEGER
);

alter table SAILW0972V.BMI_CATa activate not logged INITIALLY;

INSERT INTO  SAILW0972V.BMI_CATa 
SELECT ALF_PE, BMI_DT, BMI_CAT2, BMI_VAL
FROM ( 
	SELECT DISTINCT (ALF_PE), event_dt AS bmi_dt, 'Underweight' AS bmi_cat2, '1' AS bmi_c, CASE WHEN event_val >= 12 AND event_val < 18.50 THEN event_val END AS bmi_val
	FROM SAILW0972V.BMI_COHORT 
	INNER JOIN SAILW0972V.BMI_ALG_GP
	USING (ALF_PE)
	WHERE event_cd IN (SELECT BMI_CODE FROM SAILW0972V.BMI_LOOKUP WHERE category = 'underweight') AND alf_sts_cd IN ('1', '4', '39')
	UNION 
	SELECT DISTINCT (ALF_PE), event_dt AS bmi_dt, 'Normal weight' AS bmi_cat2, '2' AS bmi_c,  CASE WHEN event_val >= 18.5 AND event_val < 25 THEN event_val END AS bmi_val
	FROM SAILW0972V.BMI_COHORT 
	INNER JOIN SAILW0972V.BMI_ALG_GP
	USING (ALF_PE)
	WHERE event_cd IN (SELECT BMI_CODE FROM SAILW0972V.BMI_LOOKUP WHERE category = 'normal weight') AND alf_sts_cd IN ('1', '4', '39')
	UNION 
	SELECT DISTINCT (ALF_PE), event_dt AS bmi_dt, 'Overweight' AS bmi_cat2, '3' AS bmi_c, CASE WHEN event_val >= 25 AND event_val < 30 THEN event_val END AS bmi_val
	FROM SAILW0972V.BMI_COHORT 
	INNER JOIN SAILW0972V.BMI_ALG_GP
	USING (ALF_PE)
	WHERE event_cd IN (SELECT BMI_CODE FROM SAILW0972V.BMI_LOOKUP WHERE category = 'overweight') AND alf_sts_cd IN ('1', '4', '39')
	UNION 
	SELECT DISTINCT (ALF_PE), event_dt AS bmi_dt, 'Obese class1' AS bmi_cat2, '4' AS bmi_c, CASE WHEN event_val >=30 AND event_val <35 THEN event_val END AS bmi_val
	FROM SAILW0972V.BMI_COHORT 
	INNER JOIN SAILW0972V.BMI_ALG_GP
	USING (ALF_PE)
	WHERE event_cd IN (SELECT BMI_CODE FROM SAILW0972V.BMI_LOOKUP WHERE category = 'Obese class1') AND alf_sts_cd IN ('1', '4', '39')
	UNION 
	SELECT DISTINCT (ALF_PE), event_dt AS bmi_dt, 'Obese class2' AS bmi_cat2, '5' AS bmi_c, CASE WHEN event_val >=35 AND event_val <40 THEN event_val END AS bmi_val
	FROM SAILW0972V.BMI_COHORT 
	INNER JOIN SAILW0972V.BMI_ALG_GP
	USING (ALF_PE)
	WHERE event_cd IN (SELECT BMI_CODE FROM SAILW0972V.BMI_LOOKUP WHERE category = 'obese class2') AND alf_sts_cd IN ('1', '4', '39')
	UNION 
	SELECT DISTINCT (ALF_PE), event_dt AS bmi_dt, 'Obese class3' AS bmi_cat2, '6' AS bmi_c, CASE WHEN event_val >=40 AND event_val <=100 THEN event_val END AS bmi_val
	FROM SAILW0972V.BMI_COHORT 
	INNER JOIN SAILW0972V.BMI_ALG_GP
	USING (ALF_PE)
	WHERE event_cd IN (SELECT BMI_CODE FROM SAILW0972V.BMI_LOOKUP WHERE category = 'obese class3') AND alf_sts_cd IN ('1', '4', '39')
	UNION 
	SELECT DISTINCT (ALF_PE), event_dt AS bmi_dt, 'Obese class unknown' AS bmi_cat2, '7' AS bmi_c, CASE WHEN event_val >=30 AND event_val <=100 THEN event_val END AS bmi_val
	FROM SAILW0972V.BMI_COHORT 
	INNER JOIN SAILW0972V.BMI_ALG_GP
	USING (ALF_PE)
	WHERE event_cd IN (SELECT BMI_CODE FROM SAILW0972V.BMI_LOOKUP WHERE category = 'Obese class unknown') AND alf_sts_cd IN ('1', '4', '39')
); 

COMMIT;

-----------------------------------------------------------------------------------------------------------------
-- 10. Get rid of records from the BMI_CAT2 table where multiple BMI categories have been recorded for an alf on the same date with a range greater than given value

CALL FNC.DROP_IF_EXISTS ('SAILW0972V.BMI_CAT');

CREATE TABLE SAILW0972V.BMI_CAT
(
		alf_pe        	BIGINT,
		bmi_dt     		DATE,
		bmi_cat2   	 	VARCHAR(20),
		bmi_val       	INTEGER
);


INSERT INTO  SAILW0972V.BMI_CAT 
(SELECT *
FROM SAILW0972V.BMI_CATa a
WHERE NOT EXISTS 
(SELECT *
FROM 
(SELECT ALF_PE, bmi_dt, count(*) AS count_bmi_cat2, max(bmi_val) - min(bmi_val) AS rnge
FROM SAILW0972V.BMI_CATa 
WHERE bmi_val IS NOT NULL
GROUP BY ALF_PE, bmi_dt
ORDER BY count_bmi_cat2 DESC) b
WHERE count_bmi_cat2 > 1
AND rnge/bmi_val > SAILW0972V.BMI_SAME_DAY
AND a.ALF_PE = b.ALF_PE
AND a.bmi_dt = b.bmi_dt))
;

-----------------------------------------------------------------------------------------------------------------
-- 11.  Create a table from bmi values codes, remove extreme values, 
--assign BMI categories, and remove records where there are multiple 
--BMI categories for a given alf and date  

CALL FNC.DROP_IF_EXISTS ('SAILW0972V.BMI_VALa');

CREATE TABLE SAILW0972V.BMI_VALa
(
		alf_pe        	BIGINT,
		bmi_dt     		DATE,
		bmi_cat2	   	VARCHAR(20),
		bmi_val       	INTEGER
);

alter table SAILW0972V.BMI_VALa activate not logged INITIALLY;

INSERT INTO  SAILW0972V.BMI_VALa  
(SELECT *
FROM 
(SELECT DISTINCT ALF_PE, bmi_dt, 
CASE  
WHEN bmi_val < 18.5 THEN 'Underweight'
WHEN bmi_val >=18.5 AND bmi_val <25 THEN 'Normal weight'
WHEN bmi_val >= 25.0 AND bmi_val < 30 THEN 'Overweight'
WHEN bmi_val >= 30.0 AND bmi_val < 35 THEN 'Obese class1'
WHEN bmi_val >= 35.0 AND bmi_val < 40  THEN 'Obese class2'
WHEN bmi_val >= 40.0 THEN 'Obese class3'
ELSE NULL END AS bmi_cat2,
bmi_val
FROM 
(SELECT DISTINCT (ALF_PE), event_dt AS bmi_dt, event_val AS bmi_val
FROM SAILW0972V.BMI_COHORT 
INNER JOIN SAILW0972V.BMI_ALG_GP
USING (ALF_PE)
WHERE event_cd IN (SELECT BMI_CODE FROM SAILW0972V.BMI_LOOKUP WHERE category = 'bmi') AND alf_sts_cd IN ('1', '4', '39')
AND event_val BETWEEN 12 AND 100))
WHERE bmi_cat2 IS NOT NULL)
; 

COMMIT;

-----------------------------------------------------------------------------------------------------------------
-- 12.  Get rid of records from the BMI_CAT2 table where multiple BMI categories have been recorded for an alf on the same date with a range greater than given value
CALL FNC.DROP_IF_EXISTS ('SAILW0972V.BMI_VAL');

CREATE TABLE SAILW0972V.BMI_VAL
(
		alf_pe        	BIGINT,
		bmi_dt     		DATE,
		bmi_cat2	   	VARCHAR(20),
		bmi_val       	INTEGER
);

alter table SAILW0972V.BMI_VAL activate not logged INITIALLY;

INSERT INTO SAILW0972V.BMI_VAL  
(SELECT *
FROM SAILW0972V.BMI_VALa a
WHERE NOT EXISTS 
(SELECT *
FROM 
(SELECT ALF_PE, bmi_dt, count(*) AS count_bmi_cat2, max(bmi_val) - min(bmi_val) AS rnge
FROM SAILW0972V.BMI_VALa 
WHERE bmi_val IS NOT NULL
GROUP BY ALF_PE, bmi_dt
ORDER BY count_bmi_cat2 DESC) b
WHERE count_bmi_cat2 > 1
AND rnge/bmi_val > SAILW0972V.BMI_SAME_DAY
AND a.ALF_PE = b.ALF_PE
AND a.bmi_dt = b.bmi_dt))
;

COMMIT;

--11. Create a table of the most recent height measurement taken for an alf when they were 18 or over and 
--cleans by converting inches and centimeters to meteres and removes extreme values  

CALL FNC.DROP_IF_EXISTS ('SAILW0972V.BMI_HEIGHT');

CREATE TABLE SAILW0972V.BMI_HEIGHT
(
		alf_pe        	BIGINT,
		height     		DECIMAL(3,2),
		age_height		DECIMAL(5),
		height_dt      	DATE,
		event_order		SMALLINT
);

alter table SAILW0972V.BMI_HEIGHT activate not logged INITIALLY;

INSERT INTO SAILW0972V.BMI_HEIGHT

(SELECT ALF_PE, CASE 
WHEN height_val BETWEEN 1.2 AND 2.13 THEN height_val 
WHEN height_val BETWEEN 120 AND 213 THEN height_val/100 ---converts centimeters to meters
WHEN height_val BETWEEN 48 AND 84 THEN (height_val*2.54)/100  ---converts inches to meters
ELSE NULL END AS height, age_height, height_dt, event_order
FROM ( 
	SELECT ALF_PE, height_val, height_dt, DAYS_BETWEEN (height_dt, wob)/365.25 AS age_height, 
 	ROW_NUMBER() OVER (PARTITION BY ALF_PE ORDER BY height_dt desc) AS event_order --retrieves height values taken and puts them in reverse order 
	FROM (
		SELECT DISTINCT a.ALF_PE, a.wob,  event_dt AS height_dt, event_val AS height_val
		FROM SAILW0972V.BMI_COHORT a 
		INNER JOIN SAILW0972V.BMI_ALG_GP
		USING (ALF_PE)
		WHERE event_cd IN (SELECT BMI_CODE FROM SAILW0972V.BMI_LOOKUP WHERE category = 'height')
		AND alf_sts_cd IN ('1', '4', '39')
		)
	)
WHERE event_order = 1 --most recent height measurement and removes duplicates 
AND age_height >= 18
ORDER BY alf_pe, event_order
	 --removes measurements taken when alfs are children
);

COMMIT;


---12. Create a table of weight measurements and remove extreme values 


CALL FNC.DROP_IF_EXISTS ('SAILW0972V.BMI_WEIGHT');

CREATE TABLE SAILW0972V.BMI_WEIGHT
(
		alf_pe        	BIGINT,
		weight_dt     	DATE,
		weight	   	 	INTEGER
);



INSERT INTO SAILW0972V.BMI_WEIGHT

(SELECT DISTINCT (ALF_PE), event_dt, event_val AS weight_val  --retrives weight values for alfs in cohort table 
FROM SAILW0972V.BMI_COHORT a
INNER JOIN SAILW0972V.BMI_ALG_GP
USING (ALF_PE)
WHERE event_cd IN (SELECT BMI_CODE FROM SAILW0972V.BMI_LOOKUP WHERE category = 'weight')
AND event_val IS NOT NULL
AND alf_sts_cd IN ('1', '4', '39')
AND event_val BETWEEN 32 AND 250 
--AND (DAYS_BETWEEN (event_dt, a.wob)/365.25) >=18 ORDER BY ALF_PE, event_dt
);

--13. Create a table of BMI values calculated using the above height and weight values 
--remove extreme values and assign BMI categories. BMI_DT is equal to WEIGHT_DT. Remove 
--rows where there are multiple categories for alfs and dates 

CALL FNC.DROP_IF_EXISTS ('SAILW0972V.BMI_WEIGHT_VALUES_ADULTS_a');

CREATE TABLE SAILW0972V.BMI_WEIGHT_VALUES_ADULTS_a
(
		alf_pe        	BIGINT,
		bmi_dt     		DATE,
		height	   	 	DECIMAL(3,2),
		weight			INTEGER,
		bmi_cat2		VARCHAR(20),
		bmi_val			INTEGER
);

INSERT INTO SAILW0972V.BMI_WEIGHT_VALUES_ADULTS_a 
(SELECT ALF_PE, bmi_dt, height, weight,
CASE  
WHEN bmi_val < 18.5 THEN 'Underweight'
WHEN bmi_val >=18.5 AND bmi_val <25 THEN 'Normal weight'
WHEN bmi_val >= 25.0 AND bmi_val < 30 THEN 'Overweight'
WHEN bmi_val >= 30.0 AND bmi_val < 35 THEN 'Obese class1'
WHEN bmi_val >= 35.0 AND bmi_val < 40 THEN 'Obese class2'
WHEN bmi_val >= 40.0 THEN 'Obese class3'
ELSE NULL END AS bmi_cat2, bmi_val
FROM (
	SELECT DISTINCT (ALF_PE), weight_dt AS bmi_dt, DEC(DEC(weight, 10, 2)/(height*height),10) AS bmi_val, height, weight-- this converts weight and bmi into decimal and is necessary to avoid a system error 
	FROM SAILW0972V.BMI_HEIGHT
	INNER JOIN SAILW0972V.BMI_WEIGHT
	USING (ALF_PE)
	WHERE DEC(DEC(weight, 10, 2)/(height*height),10) BETWEEN 12 AND 100
	)
ORDER BY ALF_PE, bmi_dt
)
; 

CALL FNC.DROP_IF_EXISTS ('SAILW0972V.BMI_WEIGHT_VALUES_ADULTS');

CREATE TABLE SAILW0972V.BMI_WEIGHT_VALUES_ADULTS
(
		alf_pe        	BIGINT,
		bmi_dt     		DATE,
		height			DECIMAL(3,2),
		weight	   	 	INTEGER,
		bmi_cat2		VARCHAR(20),
		bmi_val			INTEGER
);

INSERT INTO SAILW0972V.BMI_WEIGHT_VALUES_ADULTS 
(SELECT *
FROM SAILW0972V.BMI_WEIGHT_VALUES_ADULTS_a  a
WHERE NOT EXISTS 
	(SELECT *
	FROM 
		(SELECT ALF_PE, BMI_DT, COUNT(*) AS count_weight_val,  max(bmi_val) - min(bmi_val) AS rnge 
		FROM SAILW0972V.BMI_WEIGHT_VALUES_ADULTS_a 
		GROUP BY ALF_PE, bmi_dt
		ORDER BY count_weight_val DESC
		) b
	WHERE count_weight_val > 1
	AND rnge > 1
	AND a.ALF_PE = b.ALF_PE
	AND a.bmi_dt = b.bmi_dt
	)
AND bmi_cat2 IS NOT NULL
);

--x. Pull in results from PEDW

CALL FNC.DROP_IF_EXISTS ('SAILW0972V.BMI_PEDW');

CREATE TABLE SAILW0972V.BMI_PEDW
(
		alf_pe        	BIGINT,
		bmi_dt     		DATE,
		bmi_cat2		VARCHAR(20)
);

INSERT INTO SAILW0972V.BMI_PEDW 
SELECT distinct ALF_PE, ADMIS_DT AS bmi_dt, 'Obese class unknown' AS bmi_cat2
FROM SAILW0972V.BMI_COHORT
INNER JOIN 
SAILW0972V.BMI_ALG_PEDW_SPELL USING (ALF_PE)
INNER JOIN 
SAILW0972V.BMI_ALG_PEDW_DIAG using (SPELL_NUM_PE)
WHERE DIAG_CD IN ('E66',
				'E660',
				'E661',
				'E668',
				'E669')
AND alf_sts_cd IN ('1', '4', '39');

INSERT INTO SAILW0972V.BMI_PEDW 
SELECT distinct ALF_PE, ADMIS_DT AS bmi_dt, 'Obese class3' AS bmi_cat2
FROM SAILW0972V.BMI_COHORT
INNER JOIN 
SAILW0972V.BMI_ALG_PEDW_SPELL USING (ALF_PE)
INNER JOIN 
SAILW0972V.BMI_ALG_PEDW_DIAG using (SPELL_NUM_PE)
WHERE DIAG_CD = 'E662'
AND alf_sts_cd IN ('1', '4', '39');

--14. Combine tables where the hierarchy for entries on the same date for 

CALL FNC.DROP_IF_EXISTS ('SAILW0972V.BMI_COMBOa');

CREATE TABLE SAILW0972V.BMI_COMBOa
(
		alf_pe        	BIGINT,
		bmi_dt     		DATE,
		bmi_cat2		VARCHAR(20),
		bmi_val			INTEGER,
		height			DECIMAL(3,2),
		weight			INTEGER,
		source_type		VARCHAR(12),
		source_rank		SMALLINT,
		source_db		CHAR(4)
);

INSERT INTO SAILW0972V.BMI_COMBOa

SELECT DISTINCT * FROM (
SELECT ALF_PE, bmi_dt, bmi_cat2, bmi_val, NULL AS height, NULL AS weight, 'bmi category' AS source_type, '3' AS source_rank, 'WLGP' AS source_db    ---everything from the bmi_cat2 table 
FROM SAILW0972V.BMI_CAT WHERE bmi_dt BETWEEN SAILW0972V.BMI_DATE_FROM AND SAILW0972V.BMI_DATE_TO
UNION
SELECT ALF_PE, bmi_dt, bmi_cat2, bmi_val, NULL, NULL, 'bmi value' AS source_type, '1' AS source_rank, 'WLGP' AS source_db     ---everything from the BMI_VAL table where the alfs and dates aren't duplicating what's in the bmi_cat2 table 
FROM SAILW0972V.BMI_VAL WHERE bmi_dt BETWEEN SAILW0972V.BMI_DATE_FROM AND SAILW0972V.BMI_DATE_TO
UNION 
SELECT ALF_PE, bmi_dt, bmi_cat2,bmi_val, height, weight, 'weight' AS source_type, '2' AS source_rank, 'WLGP' AS source_db   ---everything from the weight status table that's not in the previous two tables 
FROM SAILW0972V.BMI_WEIGHT_VALUES_ADULTS WHERE  bmi_dt BETWEEN SAILW0972V.BMI_DATE_FROM AND SAILW0972V.BMI_DATE_TO
UNION 
SELECT ALF_PE, bmi_dt, bmi_cat2, NULL AS bmi_val, NULL AS height, NULL AS weight, 'ICD-10' AS source_type, '5' AS source_rank, 'PEDW' AS source_db   ---everything from the weight status table that's not in the previous two tables 
FROM SAILW0972V.BMI_PEDW WHERE  bmi_dt BETWEEN SAILW0972V.BMI_DATE_FROM AND SAILW0972V.BMI_DATE_TO
UNION
SELECT ALF_PE, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL      ---everything from the original table that isn't in the above two
FROM SAILW0972V.BMI_COHORT c
WHERE NOT EXISTS 
(SELECT DISTINCT * FROM (
SELECT ALF_PE, bmi_dt, bmi_cat2, bmi_val, NULL AS height, NULL AS weight, 'bmi category' AS source_type, '3' AS source_rank, 'WLGP' AS source_db    ---everything from the bmi_cat2 table 
FROM SAILW0972V.BMI_CAT WHERE bmi_dt BETWEEN SAILW0972V.BMI_DATE_FROM AND SAILW0972V.BMI_DATE_TO
UNION
SELECT ALF_PE, bmi_dt, bmi_cat2, bmi_val, NULL, NULL, 'bmi value' AS source_type, '1' AS source_rank, 'WLGP' AS source_db     ---everything from the BMI_VAL table where the alfs and dates aren't duplicating what's in the bmi_cat2 table 
FROM SAILW0972V.BMI_VAL WHERE bmi_dt BETWEEN SAILW0972V.BMI_DATE_FROM AND SAILW0972V.BMI_DATE_TO
UNION 
SELECT ALF_PE, bmi_dt, bmi_cat2,bmi_val, height, weight, 'weight' AS source_type, '2' AS source_rank, 'WLGP' AS source_db   ---everything from the weight status table that's not in the previous two tables 
FROM SAILW0972V.BMI_WEIGHT_VALUES_ADULTS WHERE  bmi_dt BETWEEN SAILW0972V.BMI_DATE_FROM AND SAILW0972V.BMI_DATE_TO
UNION 
SELECT ALF_PE, bmi_dt, bmi_cat2, NULL AS bmi_val, NULL AS height, NULL AS weight, 'ICD-10' AS source_type, '5' AS source_rank, 'PEDW' AS source_db   ---everything from the weight status table that's not in the previous two tables 
FROM SAILW0972V.BMI_PEDW WHERE  bmi_dt BETWEEN SAILW0972V.BMI_DATE_FROM AND SAILW0972V.BMI_DATE_TO
) b 
WHERE c.ALF_PE = b.ALF_PE));



-- 15. Flag unusual entries for bmi

CALL FNC.DROP_IF_EXISTS ('SAILW0972V.BMI_UNCLEANED');

CREATE TABLE SAILW0972V.BMI_UNCLEANED
(
		alf_pe        	BIGINT,
		bmi_dt     		DATE,
		bmi_cat2		VARCHAR(20),
		bmi_val			INTEGER,
		height			DECIMAL(3,2),
		weight			INTEGER,
		source_type		VARCHAR(12),
		source_rank		SMALLINT,
		source_db		CHAR(4),
		wob				DATE,
		bmi_flg			CHAR(1),
		age_flg			CHAR(1)
);

INSERT INTO SAILW0972V.BMI_UNCLEANED

SELECT ALF_PE, BMI_DT, BMI_CAT2, BMI_VAL, HEIGHT, WEIGHT, source_type, source_rank, source_db, wob,
CASE 	WHEN BMI_VAL IS NULL THEN
				CASE WHEN (dt_diff1 = 0 AND bmi_diff1 > 1) OR (bmi_diff2 > 1 AND dt_diff2 = 0) THEN 1 -- patients can have a bmi
				WHEN (dt_diff1 = 0) OR (dt_diff2 = 0) THEN NULL
				WHEN (dt_diff1 != 0 AND bmi_diff1/dt_diff1 > SAILW0972V.BMI_RATE AND bmi_diff1 >1) OR (dt_diff2 != 0 AND bmi_diff2/dt_diff2 > SAILW0972V.BMI_RATE  AND bmi_diff2 > 1) THEN 1 -- more than 1 score per 6 months
				ELSE NULL END 
		WHEN BMI_VAL IS NOT NULL THEN 
				CASE WHEN (dt_diff1 = 0 AND (bmiv_diff1/bmi_val) > SAILW0972V.BMI_SAME_DAY) OR (dt_diff2 = 0 AND (bmiv_diff2/bmi_val) > SAILW0972V.BMI_SAME_DAY) THEN 1
				WHEN (dt_diff1 = 0) OR (dt_diff2 = 0) THEN NULL
				WHEN (dt_diff1 != 0 AND ((bmiv_diff1/bmi_val)/dt_diff1) > SAILW0972V.BMI_RATE AND bmi_diff1 >1) OR (dt_diff2 != 0 AND ((bmiv_diff2/bmi_val)/dt_diff2) > SAILW0972V.BMI_RATE  AND bmi_diff2 > 1) THEN 1 
				ELSE NULL END 
		END AS bmi_flg, -- more than 1 score per 6 months
CASE WHEN DAYS_BETWEEN(BMI_DT, WOB)/365.25 < 18 THEN '1' ELSE NULL END AS age_flg
FROM (
SELECT *,
abs(bmi_val - (lag(bmi_val) OVER (PARTITION BY ALF_PE ORDER BY bmi_dt))) AS bmiv_diff1, -- identifies changes in weight
abs(dec(bmi_val - (lead(bmi_val) OVER (PARTITION BY ALF_PE ORDER BY bmi_dt)))) AS bmiv_diff2, -- identifies changes in weight
abs(bmi_c - (lag(bmi_c) OVER (PARTITION BY ALF_PE ORDER BY bmi_dt))) AS bmi_diff1, -- identifies changes in weight
abs(bmi_c - (lead(bmi_c) OVER (PARTITION BY ALF_PE ORDER BY bmi_dt))) AS bmi_diff2, -- identifies changes in weight
abs(DAYS_BETWEEN(bmi_dt, (lag(bmi_dt) OVER (PARTITION BY ALF_PE ORDER BY bmi_dt)))) AS dt_diff1, -- identifies changes in date
abs(DAYS_BETWEEN(bmi_dt, (lead(bmi_dt) OVER (PARTITION BY ALF_PE ORDER BY bmi_dt)))) AS dt_diff2 -- identifies changes in date
FROM (SELECT DISTINCT *, CASE WHEN bmi_cat2 = 'Underweight' THEN 1
					WHEN bmi_cat2 = 'Normal weight' THEN 2
					WHEN bmi_cat2 = 'Overweight' THEN 3
					WHEN bmi_cat2 = 'Obese class1' THEN 4
					WHEN bmi_cat2 = 'Obese class2' THEN 5
					WHEN bmi_cat2 = 'Obese class3' THEN 6
					WHEN bmi_cat2 = 'Obese class unknown' THEN 7
					ELSE NULL END AS bmi_c
FROM SAILW0972V.BMI_COMBOa
LEFT JOIN (SELECT ALF_PE, WOB FROM SAILW0972V.BMI_COHORT) USING (ALF_PE)
))
WHERE (DAYS_BETWEEN (bmi_dt, wob)/365.25) >= 18
ORDER BY ALF_PE,bmi_dt
;

SELECT * FROM SAILW0972V.BMI_COMBOa
ORDER BY ALF_PE,
			BMI_DT desc;

SELECT * FROM SAILW0972V.BMI_UNCLEANED;

SELECT *,
abs(bmi_val - (lag(bmi_val) OVER (PARTITION BY ALF_PE ORDER BY bmi_dt))) AS bmiv_diff1, -- identifies changes in weight
abs(dec(bmi_val - (lead(bmi_val) OVER (PARTITION BY ALF_PE ORDER BY bmi_dt)))) AS bmiv_diff2, -- identifies changes in weight
abs(bmi_c - (lag(bmi_c) OVER (PARTITION BY ALF_PE ORDER BY bmi_dt))) AS bmi_diff1, -- identifies changes in weight
abs(bmi_c - (lead(bmi_c) OVER (PARTITION BY ALF_PE ORDER BY bmi_dt))) AS bmi_diff2, -- identifies changes in weight
abs(DAYS_BETWEEN(bmi_dt, (lag(bmi_dt) OVER (PARTITION BY ALF_PE ORDER BY bmi_dt)))) AS dt_diff1, -- identifies changes in date
abs(DAYS_BETWEEN(bmi_dt, (lead(bmi_dt) OVER (PARTITION BY ALF_PE ORDER BY bmi_dt)))) AS dt_diff2 -- identifies changes in date
FROM (SELECT DISTINCT *, CASE WHEN bmi_cat2 = 'Underweight' THEN 1
					WHEN bmi_cat2 = 'Normal weight' THEN 2
					WHEN bmi_cat2 = 'Overweight' THEN 3
					WHEN bmi_cat2 = 'Obese class1' THEN 4
					WHEN bmi_cat2 = 'Obese class2' THEN 5
					WHEN bmi_cat2 = 'Obese class3' THEN 6
					WHEN bmi_cat2 = 'Obese class unknown' THEN 7
					ELSE NULL END AS bmi_c
FROM SAILW0972V.BMI_COMBOa
LEFT JOIN (SELECT ALF_PE, WOB FROM SAILW0972V.BMI_COHORT) USING (ALF_PE)
);

--15. Restrict dates, check for nulls, and ensure entries are only taken for 18s and over 

CREATE TABLE SAILW0972V.BMI_ALG_OUTPUT
(
	alf_pe		BIGINT,
	wob			DATE,
	bmi_dt		DATE,
	bmi_val		INTEGER,
	bmi_cat2	VARCHAR(20),
	source_type	VARCHAR(12),
	source_db	CHAR(4)
); 

INSERT INTO  SAILW0972V.BMI_ALG_OUTPUT 
SELECT DISTINCT c.ALF_PE, c.wob, a.bmi_dt, bmi_val, bmi_cat2, source_type, source_db
FROM SAILW0972V.BMI_COHORT c
LEFT JOIN
(SELECT ALF_PE, bmi_dt, min(source_rank) AS source_rank
FROM SAILW0972V.BMI_UNCLEANED
GROUP BY ALF_PE, bmi_dt
ORDER BY ALF_PE, bmi_dt) a
ON c.ALF_PE = a.ALF_PE
LEFT JOIN 
SAILW0972V.BMI_UNCLEANED b
ON a.ALF_PE = b.ALF_PE AND a.bmi_dt =b.bmi_dt AND a.source_rank = b.source_rank
WHERE (a.bmi_dt BETWEEN SAILW0972V.BMI_DATE_FROM AND SAILW0972V.BMI_DATE_TO OR a.BMI_DT IS NULL)
AND bmi_flg IS NULL
ORDER BY c.ALF_PE, a.bmi_dt;

--16. Add BMI_CAT field grouping the obesity classes

ALTER TABLE SAILW0972V.BMI_ALG_OUTPUT
ADD COLUMN BMI_CAT VARCHAR(13);

UPDATE SAILW0972V.BMI_ALG_OUTPUT
SET BMI_CAT = CASE WHEN BMI_CAT2 = 'Underweight'
					THEN 'Underweight'
				WHEN BMI_CAT2 = 'Normal weight'
					THEN 'Normal weight'
				WHEN BMI_CAT2 = 'Overweight'
					THEN 'Overweight'
				WHEN BMI_CAT2 = 'Obese class1'
						OR BMI_CAT2 = 'Obese class2'
						OR BMI_CAT2 = 'Obese class3'
						OR BMI_CAT2 = 'Obese class unknown'
					THEN 'Obese'
				ELSE NULL
			END;

----------------------

DROP VARIABLE SAILW0972V.BMI_DATE_FROM;
DROP VARIABLE SAILW0972V.BMI_DATE_TO;
DROP TABLE SAILW0972V.BMI_CATa;
DROP TABLE SAILW0972V.BMI_CAT;
DROP TABLE SAILW0972V.BMI_VALa;
DROP TABLE SAILW0972V.BMI_VAL;
DROP TABLE SAILW0972V.BMI_HEIGHT;
DROP TABLE SAILW0972V.BMI_WEIGHT;
DROP TABLE SAILW0972V.BMI_WEIGHT_VALUES_ADULTS_a;
DROP TABLE SAILW0972V.BMI_WEIGHT_VALUES_ADULTS;
DROP TABLE SAILW0972V.BMI_PEDW;
DROP TABLE SAILW0972V.BMI_COMBOa;
DROP TABLE SAILW0972V.BMI_LOOKUP;
DROP TABLE SAILW0972V.vb_wlgp_sub_GP;
DROP ALIAS SAILW0972V.BMI_COHORT;
DROP ALIAS SAILW0972V.BMI_ALG_PEDW_DIAG;
DROP ALIAS SAILW0972V.BMI_ALG_GP;
DROP ALIAS SAILW0972V.BMI_ALG_PEDW_SPELL;

SELECT * FROM SAILW0972V.BMI_ALG_OUTPUT;
SELECT * FROM SAILW0972V.BMI_UNCLEANED;

--------------------------------------------------------------------------------------------------------------------------------------

--Create table with event date to identify obesity category at closest time prior to event

CALL FNC.DROP_IF_EXISTS ('SAILW0972V.VB_BMI_wlgp_uti_COHORT');
		
CREATE TABLE SAILW0972V.VB_BMI_wlgp_uti_COHORT
AS (SELECT ALF_PE, WOB, DIAG_DT FROM sailw0972v.vb_wlgp_sub) WITH NO DATA;

INSERT INTO SAILW0972V.VB_BMI_wlgp_uti_COHORT
	(ALF_PE,
	WOB,
	DIAG_DT)
	SELECT ALF_PE, WOB, DIAG_DT FROM sailw0972v.vb_wlgp_sub;

---------------------------------------------------------
--Delete multiple entries where more than one BMI value is recorded on a cetarin day but the BMI category is the same - retaining the highest recorded BMI value entry

DELETE FROM 
	(SELECT ROWNUMBER()	OVER(PARTITION BY ALF_PE, BMI_DT, BMI_CAT2 ORDER BY BMI_VAL desc) AS rn
			FROM SAILW0972V.BMI_ALG_OUTPUT) AS mqo
			WHERE rn > 1;
		
--Delete all entries Where multiple BMI categories are recorded on the same day because they are an error with unknown classficiation
		
DELETE FROM SAILW0972V.BMI_ALG_OUTPUT
	WHERE (ALF_PE, BMI_DT) IN
	(SELECT ALF_PE, BMI_DT
	FROM SAILW0972V.BMI_ALG_OUTPUT
	GROUP BY ALF_PE, BMI_DT
	HAVING COUNT(ALF_PE) > 1);

--BMI

ALTER TABLE sailw0972v.vb_wlgp_sub
ADD COLUMN BMI_VAL INTEGER
ADD COLUMN BMI_DT date
ADD COLUMN BMI_18MONTHS integer;

MERGE INTO sailw0972v.vb_wlgp_sub AS coh
	USING (SELECT	op.ALF_PE,
					op.WOB,
					mqo.BMI_DT,
					op.BMI_VAL,
					op.BMI_CAT2,
					op.SOURCE_TYPE,
					op.SOURCE_DB
	FROM 
		(SELECT alg.ALF_PE,
				max(alg.BMI_DT) AS BMI_DT
				FROM SAILW0972V.BMI_ALG_OUTPUT AS alg
				LEFT JOIN SAILW0972V.VB_BMI_wlgp_uti_COHORT AS coh
					ON alg.ALF_PE = coh.ALF_PE
				WHERE alg.BMI_DT IS NOT NULL
				AND alg.BMI_DT < coh.DIAG_DT
				AND alg.BMI_VAL IS NOT NULL
				GROUP BY alg.ALF_PE) AS mqo
			LEFT JOIN SAILW0972V.BMI_ALG_OUTPUT AS op
				ON mqo.ALF_PE = op.ALF_PE
				AND mqo.BMI_DT = op.BMI_DT
	ORDER BY op.ALF_PE) AS bmi
		ON coh.ALF_PE = bmi.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET coh.BMI_VAL = bmi.BMI_VAL;
			
MERGE INTO sailw0972v.vb_wlgp_sub AS coh
	USING (SELECT	op.ALF_PE,
					op.WOB,
					mqo.BMI_DT,
					op.BMI_VAL,
					op.BMI_CAT2,
					op.SOURCE_TYPE,
					op.SOURCE_DB
	FROM 
		(SELECT alg.ALF_PE,
				max(alg.BMI_DT) AS BMI_DT
				FROM SAILW0972V.BMI_ALG_OUTPUT AS alg
				LEFT JOIN SAILW0972V.VB_BMI_wlgp_uti_COHORT AS coh
					ON alg.ALF_PE = coh.ALF_PE
				WHERE alg.BMI_DT IS NOT NULL
				AND alg.BMI_DT < coh.DIAG_DT
				AND alg.BMI_VAL IS NOT NULL
				GROUP BY alg.ALF_PE) AS mqo
			LEFT JOIN SAILW0972V.BMI_ALG_OUTPUT AS op
				ON mqo.ALF_PE = op.ALF_PE
				AND mqo.BMI_DT = op.BMI_DT
	ORDER BY op.ALF_PE) AS bmi
		ON coh.ALF_PE = bmi.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET coh.BMI_dt = bmi.BMI_dt;
			
UPDATE sailw0972v.vb_wlgp_sub 
SET BMI_18MONTHS = CASE WHEN bmi_dt IS NULL THEN null
						WHEN months_between(diag_dt, bmi_dt) >= 18
					THEN 0
						ELSE 1
					END;
					
SELECT * FROM sailw0972v.vb_wlgp_sub
ORDER BY alf_pe, DIAG_DT;

------------------------------------------------------------------------------------------------
	
/* update cohort table with dementia
Link all cohort1 rUTI events to gp event to identify any events with dementia read codes
Identify first event date for any episode with a recorded dementia read code */
		
CALL fnc.drop_if_exists('SESSION.VB_COHORT_EVENT_DEMENTIA');				
				
DECLARE GLOBAL TEMPORARY TABLE SESSION.VB_COHORT_EVENT_DEMENTIA AS (
	SELECT	ALF_PE, 
			EVENT_DT
		FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.VB_COHORT_EVENT_DEMENTIA
							(ALF_PE,
							EVENT_DT)
				WITH CTE AS 
						(SELECT ALF_PE,
							EVENT_CD,
							EVENT_DT
						FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301
							WHERE EVENT_CD IN ('1461.','3AE..','4L49.','66h..','6AB..','8BM02','8BM50','8BM60','8BPa.','8CET.','8CMe0','8CMG2',
												'8CMZ.','8CMZ0','8CMZ1','8CMZ2','8CMZ3','8CSA.','8Hla.','8IAe0','8IAe2','8T05.','8T050','8T051',
												'9hD..','9hD0.','9hD1.','9Ou..','9Ou1.','9Ou2.','9Ou3.','9Ou4.','9Ou5.','A411.','A4110','BBC9.',
												'E00..','E000.','E001.','E0010','E0011','E0012','E0013','E001z','E002.','E0020','E0021','E002z',
												'E003.','E004.','E0040','E0041','E0042','E0043','E004z','E00y.','E00z.','E0110','E0111','E0112',
												'E012.','E0120','E02y1','E040.','E041.','Eu00.','Eu000','Eu001','Eu002','Eu00z','Eu01.','Eu010',
												'Eu011','Eu012','Eu013','Eu01y','Eu01z','Eu02.','Eu020','Eu021','Eu022','Eu023','Eu025',
												'Eu02y','Eu02z','Eu03.','Eu041','Eu057','Eu106','Eu107','Eu843','F10..','F1021','F103.','F1030',
												'F1031','F103z','F10z.','F11..','F110.','F1100','F1101','F111.','F1110','F112.','F116.','F118.',
												'F11x.','F11x0','F11x1','F11x2','F11x4','F11x5','F11x6','F11x7','F11x8','F11x9','F11xz','F11y.',
												'F11y1','F11yz','F11z.','F12..','F12z.','F13..','F134.','F21y2','Fyu30','G5321','ZR1K.','ZR1T.',
												'ZR2X.','ZR3V.','ZS7C5'
												))
				SELECT coh.ALF_PE,
						min(CTE.EVENT_DT)
					FROM sailw0972v.vb_wlgp_sub AS coh
						LEFT JOIN CTE
							ON coh.ALF_PE = CTE.ALF_PE
						WHERE CTE.EVENT_DT < coh.DIAG_DT
					GROUP BY coh.ALF_PE;
				
Commit;		

/* Update cohort1 table with the prior dementia date */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN DEMENTIA INTEGER
	ADD COLUMN FIRST_DEMENTIA_DT DATE;

MERGE INTO sailw0972v.vb_wlgp_sub AS coh
	USING SESSION.VB_COHORT_EVENT_DEMENTIA AS gpev
		ON coh.ALF_PE = gpev.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET coh.FIRST_DEMENTIA_DT = gpev.EVENT_DT
			;

UPDATE sailw0972v.vb_wlgp_sub
	SET DEMENTIA = CASE WHEN FIRST_DEMENTIA_DT IS NOT NULL	
					THEN 1
				ELSE 0
			END;
			
------------------------------------------------------------------------------------------------
/* update cohort table with parkinsons
Link all cohort1 rUTI events to gp event to identify any events with parkinsons read codes
Identify first event date for any episode with a recorded parkinsons read code */
		
CALL fnc.drop_if_exists('SESSION.VB_COHORT_EVENT_PARKINSONS');		
		
DECLARE GLOBAL TEMPORARY TABLE SESSION.VB_COHORT_EVENT_PARKINSONS AS (
	SELECT	ALF_PE, 
			EVENT_DT
		FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.VB_COHORT_EVENT_PARKINSONS
							(ALF_PE,
							EVENT_DT)
				WITH CTE AS 
						(SELECT ALF_PE,
							EVENT_CD,
							EVENT_DT
						FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301
							WHERE EVENT_CD IN ('147F.','38GM.','8Hx0.','8T06.','8T060','9Nle.','Eu023','F11x9','F12..','F120.','F12z.'
												))
				SELECT coh.ALF_PE,
						min(CTE.EVENT_DT)
					FROM sailw0972v.vb_wlgp_sub AS coh
						LEFT JOIN CTE
							ON coh.ALF_PE = CTE.ALF_PE
						WHERE CTE.EVENT_DT < coh.DIAG_Dt
					GROUP BY coh.ALF_PE;
				
Commit;

/* Update cohort1 table with the prior parkinson's date */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN PARKINSONS INTEGER
	ADD COLUMN FIRST_PARKINSONS_DT DATE;

MERGE INTO sailw0972v.vb_wlgp_sub AS coh
	USING SESSION.VB_COHORT_EVENT_PARKINSONS AS gpev
		ON coh.ALF_PE = gpev.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET coh.FIRST_PARKINSONS_DT = gpev.EVENT_DT
			;

UPDATE sailw0972v.vb_wlgp_sub
	SET PARKINSONS = CASE WHEN FIRST_PARKINSONS_DT IS NOT NULL	
					THEN 1
				ELSE 0
			END;
			
------------------------------------------------------------------------------------------------
	
/* update cohort table with motor neurone disease
Link all cohort1 rUTI events to gp event to identify any events with motor neurone disease read codes
Identify first event date for any episode with a recorded motor neurone disease read code */
		
CALL fnc.drop_if_exists('SESSION.VB_COHORT_EVENT_MND');		
		
DECLARE GLOBAL TEMPORARY TABLE SESSION.VB_COHORT_EVENT_MND AS (
	SELECT	ALF_PE, 
			EVENT_DT
		FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.VB_COHORT_EVENT_MND
							(ALF_PE,
							EVENT_DT)
				WITH CTE AS 
						(SELECT ALF_PE,
							EVENT_CD,
							EVENT_DT
						FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301
							WHERE EVENT_CD IN ('7Q041','F15..','F152.','F1520','F1521','F1522','F1523','F1524','F152z','F15y.','F15z.'
												))
				SELECT coh.ALF_PE,
						min(CTE.EVENT_DT)
					FROM sailw0972v.vb_wlgp_sub AS coh
						LEFT JOIN CTE
							ON coh.ALF_PE = CTE.ALF_PE
						WHERE CTE.EVENT_DT < coh.DIAG_Dt
					GROUP BY coh.ALF_PE;
				
Commit;

/* Update cohort1 table with the prior motor neurone disease date */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN MND INTEGER
	ADD COLUMN FIRST_MND_DT DATE;

MERGE INTO sailw0972v.vb_wlgp_sub AS coh
	USING SESSION.VB_COHORT_EVENT_MND AS gpev
		ON coh.ALF_PE = gpev.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET coh.FIRST_MND_DT = gpev.EVENT_DT
			;

UPDATE sailw0972v.vb_wlgp_sub
	SET MND = CASE WHEN FIRST_MND_DT IS NOT NULL	
					THEN 1
				ELSE 0
			END;
			
--------------------------------------------------------------------------------------------
	
/* update cohort table with multiple sclerosis
Link all cohort1 rUTI events to gp event to identify any events with multiple sclerosis read codes
Identify first event date for any episode with a recorded multiple sclerosis read code */
		
CALL fnc.drop_if_exists('SESSION.VB_COHORT_EVENT_MS');
		
DECLARE GLOBAL TEMPORARY TABLE SESSION.VB_COHORT_EVENT_MS AS (
	SELECT	ALF_PE, 
			EVENT_DT
		FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.VB_COHORT_EVENT_MS
							(ALF_PE,
							EVENT_DT)
				WITH CTE AS 
						(SELECT ALF_PE,
							EVENT_CD,
							EVENT_DT
						FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301
							WHERE EVENT_CD IN ('666A.','666B.','8Cc0.','8Cc1.','8Cc2.','8Cc3.','8Cc4.','8CS1.','8Hkv.','8IAb.','9kG..','9mD..',
												'9mD0.','9mD1.','9mD2.','9mD3.','F20..','F200.','F201.','F202.','F203.','F204.','F205.','F206.',
												'F207.','F208.','F20z.','ZRVE.'
												))
				SELECT coh.ALF_PE,
						min(CTE.EVENT_DT)
					FROM sailw0972v.vb_wlgp_sub AS coh
						LEFT JOIN CTE
							ON coh.ALF_PE = CTE.ALF_PE
						WHERE CTE.EVENT_DT < coh.DIAG_Dt
					GROUP BY coh.ALF_PE;
				
Commit;		
		
/* Update cohort1 table with the prior multiple sclerosis date */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN MS INTEGER
	ADD COLUMN FIRST_MS_DT DATE;

MERGE INTO sailw0972v.vb_wlgp_sub AS coh
	USING SESSION.VB_COHORT_EVENT_MS AS gpev
		ON coh.ALF_PE = gpev.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET coh.FIRST_MS_DT = gpev.EVENT_DT
			;

UPDATE sailw0972v.vb_wlgp_sub
	SET MS = CASE WHEN FIRST_MS_DT IS NOT NULL	
					THEN 1
				ELSE 0
			END;
			
--------------------------------------------------------------------------------------------
	
/* update cohort table with hormone replacement therapy
Link all cohort1 rUTI events to gp event to identify any events with HRT read codes
Identify first event date for any episode with a recorded HRT read code */
		
CALL fnc.drop_if_exists('SESSION.VB_COHORT_EVENT_HRT');		
		
DECLARE GLOBAL TEMPORARY TABLE SESSION.VB_COHORT_EVENT_HRT AS (
	SELECT	ALF_PE, 
			EVENT_DT
		FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.VB_COHORT_EVENT_HRT
							(ALF_PE,
							EVENT_DT)
				WITH CTE AS 
						(SELECT ALF_PE,
							EVENT_CD,
							EVENT_DT
						FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301
							WHERE EVENT_CD IN ('8B640',
												'66uc.',
												'66U8.',
												'66UK.',
												'66UH.',
												'8B64.',
												'66UI.',
												'66UB.',
												'8B64.',
												'8B64.',
												'66U9.',
												'66U..',
												'66UC.',
												'66UJ.',
												'66UA.',
												'T366 ',
												'66U7.'
												))
				SELECT coh.ALF_PE,
						max(CTE.EVENT_DT)
					FROM sailw0972v.vb_wlgp_sub AS coh
						LEFT JOIN CTE
							ON coh.ALF_PE = CTE.ALF_PE
						WHERE CTE.EVENT_DT < coh.DIAG_Dt
					GROUP BY coh.ALF_PE;
				
Commit;		
		
/* Update cohort1 table with the prior multiple sclerosis date */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN HRT INTEGER
	ADD COLUMN LAST_HRT_DT DATE;

MERGE INTO sailw0972v.vb_wlgp_sub AS coh
	USING SESSION.VB_COHORT_EVENT_HRT AS gpev
		ON coh.ALF_PE = gpev.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET coh.LAST_HRT_DT = gpev.EVENT_DT
			;

UPDATE sailw0972v.vb_wlgp_sub
	SET HRT = CASE WHEN LAST_HRT_DT IS NOT NULL	
					THEN 1
				ELSE 0
			END;				

--------------------------------------------------------------------------------------------
	
/* update cohort table with autoimmune disease
Link all cohort1 rUTI events to gp event to identify any events with autoimmune read codes
Identify first event date for any episode with a recorded autoimmune read code */
		
CALL fnc.drop_if_exists('SESSION.VB_COHORT_EVENT_AUTOIMM');
		
DECLARE GLOBAL TEMPORARY TABLE SESSION.VB_COHORT_EVENT_AUTOIMM AS (
	SELECT	ALF_PE, 
			EVENT_DT
		FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.VB_COHORT_EVENT_AUTOIMM
							(ALF_PE,
							EVENT_DT)
				WITH CTE AS 
						(SELECT ALF_PE,
							EVENT_CD,
							EVENT_DT
						FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301
							WHERE EVENT_CD IN ('J6901',
												'M1602',
												'N0311',
												'N0310',
												'idD..',
												'N0006',
												'J690.',
												'J690z',
												'J6900',
												'J401z',
												'J400z',
												'J4004',
												'J4003',
												'J4002',
												'N0000',
												'M1601',
												'N0002',
												'M161H',
												'J4104',
												'12Y..',
												'M161J',
												'14F2.',
												'J63A.',
												'J41..',
												'J41z.',
												'N0454',
												'N0453',
												'N0452',
												'H57y4',
												'M1546',
												'M154.',
												'M154z',
												'M1540',
												'M1542',
												'M1543',
												'M1544',
												'M1545',
												'AD530',
												'F013.',
												'F3263',
												'F3965',
												'N2332',
												'N0005',
												'K01x4',
												'J08z9',
												'J41yz',
												'J41y.',
												'M161.',
												'M16y.',
												'M166.',
												'F3710',
												'F3749',
												'J6160',
												'M161z',
												'M16..',
												'M1611',
												'M1612',
												'M1613',
												'M1614',
												'M1615',
												'M1617',
												'M1618',
												'M1619',
												'M161A',
												'M161B',
												'M161C',
												'M1600',
												'M161E',
												'M1610',
												'M161F',
												'M16z.',
												'M160.',
												'M160z',
												'H57y2',
												'M161D',
												'J40..',
												'J40z.',
												'J4010',
												'J4000',
												'J4001',
												'J401.',
												'J4011',
												'J400.',
												'J402.',
												'N0004',
												'AD55.',
												'G5583',
												'AD52.',
												'G5y7.',
												'AD5..',
												'AD54.',
												'AD50.',
												'AD51.',
												'AD53.',
												'M16y0',
												'M1547',
												'N0003',
												'N000z',
												'N000.',
												'J411.',
												'J412.',
												'J4101',
												'J4100',
												'J4103',
												'J410.',
												'J410z',
												'J4102',
												'Nyu43',
												'Nyu13',
												'Jyu40',
												'Myu30',
												'Jyu41',
												'Cyu06'
												))
				SELECT coh.ALF_PE,
						max(CTE.EVENT_DT)
					FROM sailw0972v.vb_wlgp_sub AS coh
						LEFT JOIN CTE
							ON coh.ALF_PE = CTE.ALF_PE
					WHERE CTE.EVENT_DT < coh.DIAG_Dt
					GROUP BY coh.ALF_PE;
				
Commit;		
		
/* Update cohort1 table with the prior autoimmune date */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN AUTOIMM INTEGER
	ADD COLUMN LAST_AUTOIMM_DT DATE;

MERGE INTO sailw0972v.vb_wlgp_sub AS coh
	USING SESSION.VB_COHORT_EVENT_AUTOIMM AS gpev
		ON coh.ALF_PE = gpev.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET coh.LAST_AUTOIMM_DT = gpev.EVENT_DT
			;

UPDATE sailw0972v.vb_wlgp_sub
	SET AUTOIMM = CASE WHEN LAST_AUTOIMM_DT IS NOT NULL	
					THEN 1
				ELSE 0
			END;
		
------------------------------------------------------------------------------

/* update cohort table with Primary immunodeficiency exc HIV
Link all cohort UTI events to gp event to identify any events with Primary immunodeficiency exc HIV read codes
Identify first event date for any episode with a recorded Primary immunodeficiency exc HIV read code */
		
CALL fnc.drop_if_exists('SESSION.VB_COHORT_EVENT_PRIM_IMMDEF');		
		
DECLARE GLOBAL TEMPORARY TABLE SESSION.VB_COHORT_EVENT_PRIM_IMMDEF AS (
	SELECT	ALF_PE, 
			EVENT_DT
		FROM SAIL1169V.WLGP_GP_EVENT_CLEANSED_20220301)
DEFINITION ONLY
ON COMMIT PRESERVE ROWS;

Commit;

INSERT INTO SESSION.VB_COHORT_EVENT_PRIM_IMMDEF
							(ALF_PE,
							EVENT_DT)
				WITH CTE AS 
						(SELECT ALF_PE,
							EVENT_CD,
							EVENT_DT
						FROM SAIL0972V.WLGP_GP_EVENT_CLEANSED_20220301
							WHERE EVENT_CD IN ('2J30.','66c3.','B05z0','B31z0','B33z0','B592X','B59zX','B6z0.','Byu53','Byu5B','C3006','C3007',
												'C300A','C30yy','C390.','C3900','C3901','C3902','C3903','C3904','C3905','C3906','C3907','C3908',
												'C3909','C390A','C390B','C390y','C390z','C391.','C3910','C3911','C3912','C392.','C3921','C3923',
												'C3924','C3925','C3926','C3927','C3928','C3929','C392z','C393.','C395.','C396.','C397.','C398.',
												'C3980','C3982','C39X.','C39y0','C39y1','Cyu00','Cyu04','Cyu05','D2...','D20..','D200.','D2000',
												'D2001','D2002','D200y','D201.','D2010','D2011','D2012','D2014','D2015','D2016','D201z','D204.',
												'D20z.','D401.','F14y0','H24y2'
												))
				SELECT coh.ALF_PE,
						min(CTE.EVENT_DT)
					FROM sailw0972v.vb_wlgp_sub AS coh
						LEFT JOIN CTE
							ON coh.ALF_PE = CTE.ALF_PE
						WHERE CTE.EVENT_DT < coh.DIAG_DT
					GROUP BY coh.ALF_PE;
				
Commit;					

/* Update cohort table with the prior Primary immunodeficiency exc HIV date */

ALTER TABLE sailw0972v.vb_wlgp_sub
	ADD COLUMN PRIM_IMMDEF INTEGER
	ADD COLUMN FIRST_PRIM_IMMDEF_DT DATE;

MERGE INTO sailw0972v.vb_wlgp_sub AS coh
	USING SESSION.VB_COHORT_EVENT_PRIM_IMMDEF AS gpev
		ON coh.ALF_PE = gpev.ALF_PE
			WHEN MATCHED THEN
				UPDATE
				SET coh.FIRST_PRIM_IMMDEF_DT = gpev.EVENT_DT
			;

UPDATE sailw0972v.vb_wlgp_sub
	SET PRIM_IMMDEF = CASE WHEN FIRST_PRIM_IMMDEF_DT IS NOT NULL
					THEN 1
				ELSE 0
			END;
	
-------------------------------------------------------------------------

GRANT ALL ON TABLE sailw0972v.vb_wlgp_sub TO ROLE NRDASAIL_SAIL_0972_ANALYST;
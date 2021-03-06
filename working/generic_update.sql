-- GATHER_TABLE_STATS
exec DBMS_STATS.GATHER_TABLE_STATS (ownname => USER, tabname  => 'concept_stage', estimate_percent  => null, cascade  => true);
exec DBMS_STATS.GATHER_TABLE_STATS (ownname => USER, tabname  => 'concept_relationship_stage', estimate_percent  => null, cascade  => true);
exec DBMS_STATS.GATHER_TABLE_STATS (ownname => USER, tabname  => 'concept_synonym_stage', estimate_percent  => null, cascade  => true);

/***************************
* Update the concept table *
****************************/

-- 1. Update existing concept details from concept_stage. 
-- All fields (concept_name, domain_id, concept_class_id, standard_concept, valid_start_date and valid_end_date) are updated
-- with the exception of vocabulary_id (already there), concept_id (already there) and invalid_reason (below).
UPDATE concept c
SET (concept_name, domain_id, concept_class_id, standard_concept, valid_start_date, valid_end_date) = (
  SELECT 
    cs.concept_name,
    cs.domain_id,
    cs.concept_class_id,
    cs.standard_concept, 
    CASE -- if we have a real date in concept_stage, use it. If it is only the release date, use the existing
      WHEN cs.valid_start_date = v.latest_update THEN c.valid_start_date
      ELSE cs.valid_start_date
    END,
    cs.valid_end_date
  FROM concept_stage cs, vocabulary v
  WHERE c.concept_id = cs.concept_id -- concept exists in both, meaning, is not new. But information might be new
  AND v.vocabulary_id = cs.vocabulary_id
  -- invalid_reason is set below based on the valid_end_date
)
WHERE c.concept_id IN (SELECT concept_id FROM concept_stage)
;

COMMIT;

-- 2. Deprecate concepts missing from concept_stage and are not already deprecated. 
-- This only works for vocabularies where we expect a full set of active concepts in concept_stage.
-- If the vocabulary only provides changed concepts, this should not be run, and the update information is already dealt with in step 1.
UPDATE concept c SET
c.valid_end_date = (SELECT latest_update-1 FROM vocabulary WHERE vocabulary_id = c.vocabulary_id) -- The invalid_reason is set below in 12. 
WHERE NOT EXISTS (SELECT 1 FROM concept_stage cs WHERE cs.concept_id = c.concept_id AND cs.vocabulary_id = c.vocabulary_id) -- if concept missing from _stage
AND c.vocabulary_id IN (SELECT vocabulary_id FROM vocabulary WHERE latest_update IS NOT NULL) -- only for current vocabularies
AND c.invalid_reason IS NULL -- not already deprecated
AND CASE -- all vocabularies that give us a full list of active concepts at each release we can safely assume to deprecate missing ones (THEN 1)
  WHEN c.vocabulary_id = 'SNOMED' THEN 1
  WHEN c.vocabulary_id = 'LOINC' AND c.concept_class_id = 'LOINC Answers' THEN 1 -- Only LOINC answers are full lists
  WHEN c.vocabulary_id = 'LOINC' THEN 0 -- LOINC gives full account of all concepts
  WHEN c.vocabulary_id = 'ICD9CM' THEN 1
  WHEN c.vocabulary_id = 'ICD9Proc' THEN 1
  WHEN c.vocabulary_id = 'ICD10' THEN 1
  WHEN c.vocabulary_id = 'RxNorm' THEN 1
  WHEN c.vocabulary_id = 'NDFRT' THEN 1
  WHEN c.vocabulary_id = 'VA Product' THEN 1
  WHEN c.vocabulary_id = 'VA Class' THEN 1
  WHEN c.vocabulary_id = 'ATC' THEN 1
  WHEN c.vocabulary_id = 'NDC' THEN 0
  WHEN c.vocabulary_id = 'SPL' THEN 0  
  WHEN c.vocabulary_id = 'MedDRA' THEN 1
  WHEN c.vocabulary_id = 'CPT4' THEN 1
  WHEN c.vocabulary_id = 'HCPCS' THEN 1
  WHEN c.vocabulary_id = 'Read' THEN 1
  ELSE 0 -- in default we will not deprecate
END = 1
;

COMMIT;

-- 3. Add new concepts from concept_stage
-- Create sequence after last valid one
DECLARE
 ex NUMBER;
BEGIN
  SELECT MAX(concept_id)+1 INTO ex FROM concept WHERE concept_id<500000000; -- Last valid below HOI concept_id
  BEGIN
    EXECUTE IMMEDIATE 'CREATE SEQUENCE v5_concept INCREMENT BY 1 START WITH ' || ex || ' NOCYCLE CACHE 20 NOORDER';
    EXCEPTION
      WHEN OTHERS THEN NULL;
  END;
END;

INSERT /*+ APPEND */ INTO concept (concept_id,
                     concept_name,
                     domain_id,
                     vocabulary_id,
                     concept_class_id,
                     standard_concept,
                     concept_code,
                     valid_start_date,
                     valid_end_date,
                     invalid_reason)
   SELECT v5_concept.NEXTVAL,
          cs.concept_name,
          cs.domain_id,
          cs.vocabulary_id,
          cs.concept_class_id,
          cs.standard_concept,
          cs.concept_code,
          cs.valid_start_date,
          cs.valid_end_date,
          NULL
     FROM concept_stage cs
    WHERE cs.concept_id IS NULL; -- new because no concept_id could be found for the concept_code/vocabulary_id combination

DROP SEQUENCE v5_concept;
  
COMMIT;

-- 4. Make sure that invalid concepts are standard_concept = NULL
UPDATE concept c SET
  c.standard_concept = NULL
WHERE c.valid_end_date != TO_DATE ('20991231', 'YYYYMMDD') 
AND c.vocabulary_id IN (SELECT vocabulary_id FROM vocabulary WHERE latest_update IS NOT NULL) -- only for current vocabularies
;
COMMIT;

/****************************************
* Update the concept_relationship table *
****************************************/

-- 5. Turn all relationship records so they are symmetrical if necessary
INSERT /*+ APPEND */ INTO concept_relationship_stage (concept_code_1,
                                        concept_code_2,
                                        vocabulary_id_1,
                                        vocabulary_id_2,
                                        relationship_id,
                                        valid_start_date,
                                        valid_end_date,
                                        invalid_reason)
   SELECT crs.concept_code_2,
          crs.concept_code_1,
          crs.vocabulary_id_2,
          crs.vocabulary_id_1,
          r.reverse_relationship_id,
          crs.valid_start_date,
          crs.valid_end_date,
          crs.invalid_reason
     FROM concept_relationship_stage crs
          JOIN relationship r ON r.relationship_id = crs.relationship_id
    WHERE NOT EXISTS
             (                                           -- the inverse record
              SELECT 1
                FROM concept_relationship_stage i
               WHERE     crs.concept_code_1 = i.concept_code_2
                     AND crs.concept_code_2 = i.concept_code_1
                     AND crs.vocabulary_id_1 = i.vocabulary_id_2
                     AND crs.vocabulary_id_2 = i.vocabulary_id_1
                     AND r.reverse_relationship_id = i.relationship_id);
COMMIT;		

-- 6. Update all relationships existing in concept_relationship_stage, including undeprecation of formerly deprecated ones
MERGE INTO concept_relationship d
    USING (
        WITH rel_id as ( -- concept_relationship with concept_ids filled in
            SELECT /*+ MATERIALIZE */ DISTINCT c1.concept_id AS concept_id_1, c2.concept_id AS concept_id_2, crs.relationship_id, crs.valid_end_date, crs.invalid_reason
            FROM concept_relationship_stage crs, concept c1, concept c2 WHERE
            c1.concept_code = crs.concept_code_1 AND c1.vocabulary_id = crs.vocabulary_id_1
            AND c2.concept_code = crs.concept_code_2 AND c2.vocabulary_id = crs.vocabulary_id_2
        )
        SELECT r.ROWID AS rid, rel.valid_end_date, rel.invalid_reason
        FROM concept_relationship r, rel_id rel
        WHERE r.concept_id_1 = rel.concept_id_1 AND r.concept_id_2 = rel.concept_id_2 
          AND r.relationship_id = rel.relationship_id AND r.valid_end_date <> rel.valid_end_date  
    ) o ON (d.ROWID = o.rid)
WHEN MATCHED THEN UPDATE SET d.valid_end_date = o.valid_end_date, d.invalid_reason = o.invalid_reason;

COMMIT; 

-- 7. Deprecate missing relationships, but only if the concepts are fresh. If relationships are missing because of deprecated concepts, leave them intact.
-- Also, only relationships are considered missing if the combination of vocabulary_id_1, vocabulary_id_2 AND relationship_id is present in concept_relationship_stage
-- The latter will prevent large-scale deprecations of relationships between vocabularies where the relationship is defined not here, but together with the other vocab

-- Create a list of vocab1, vocab2 and relationship_id existing in concept_relationship_stage, except replacement relationships
CREATE TABLE r_coverage NOLOGGING AS
SELECT DISTINCT r1.vocabulary_id||'-'||r2.vocabulary_id||'-'||r.relationship_id as combo
       FROM concept_relationship_stage r
       JOIN concept r1 ON r1.concept_code = r.concept_code_1 AND r1.vocabulary_id = r.vocabulary_id_1
       JOIN concept r2 ON r2.concept_code = r.concept_code_2 AND r2.vocabulary_id = r.vocabulary_id_2
  WHERE r.vocabulary_id_1 NOT IN ('NDC', 'SPL')
  AND r.vocabulary_id_2 NOT IN ('NDC', 'SPL')
  AND r.relationship_id NOT IN (
            'UCUM replaced by',
            'Concept replaced by',
            'Concept same_as to',
            'Concept alt_to to',
            'Concept poss_eq to',
            'Concept was_a to',
            'LOINC replaced by',
            'RxNorm replaced by',
            'SNOMED replaced by',
            'ICD9P replaced by'
      )
;

-- Do the deprecation
UPDATE concept_relationship d
   SET valid_end_date  = 
            (SELECT v.latest_update
                 FROM concept c JOIN vocabulary v ON c.vocabulary_id = v.vocabulary_id
              WHERE c.concept_id = d.concept_id_1)
          - 1,                                       -- day before release day
       invalid_reason = 'D'
      -- Whether the combination of vocab1, vocab2 and relationship exists (in r_coverage)
      -- (intended to be covered by this particular vocab udpate)
      -- And both concepts exist (don't deprecate relationships of deprecated concepts)
      WHERE d.ROWID IN (SELECT d1.ROWID
						FROM concept e1, concept e2, concept_relationship d1
						WHERE e1.concept_id = d1.concept_id_1 AND e2.concept_id = d1.concept_id_2
						AND e1.vocabulary_id||'-'||e2.vocabulary_id||'-'||d1.relationship_id IN (SELECT combo FROM r_coverage)
						AND e1.valid_end_date = TO_DATE ('20991231', 'YYYYMMDD') 
						AND e2.valid_end_date = TO_DATE ('20991231', 'YYYYMMDD') 
      )
      -- And the record is currently fresh and not already deprecated
      AND d.valid_end_date = TO_DATE ('20991231', 'YYYYMMDD') 
       -- And it was started before release date
      AND d.valid_start_date <
                (SELECT latest_update -1 FROM vocabulary v, concept_stage c
                  WHERE     v.vocabulary_id = c.vocabulary_id
                        AND c.concept_id = d.concept_id_1)
      -- And it is missing from the new concept_relationship_stage
      AND NOT EXISTS (
				  SELECT 1
					 FROM concept_relationship_stage r
					 JOIN concept r1 ON r1.concept_code = r.concept_code_1 AND r1.vocabulary_id = r.vocabulary_id_1
					 JOIN concept r2 ON r2.concept_code = r.concept_code_2 AND r2.vocabulary_id = r.vocabulary_id_2
					WHERE     d.concept_id_1 = r1.concept_id
						  AND d.concept_id_2 = r2.concept_id
						  AND d.relationship_id = r.relationship_id
				) 
       -- Deal with replacement relationships below, since they can only have one per deprecated concept
;

DROP TABLE r_coverage PURGE;

-- 8. Deprecate replacement concept_relationship records if we have a new one in concept_stage with the same source concept (deprecated concept)
UPDATE concept_relationship d
   SET valid_end_date  = 
            (SELECT v.latest_update
                 FROM concept c JOIN vocabulary v ON c.vocabulary_id = v.vocabulary_id
              WHERE c.concept_id = d.concept_id_1)
          - 1,                                       -- day before release day
       invalid_reason = 'D'
  WHERE d.relationship_id in (
            'UCUM replaced by',
            'Concept replaced by',
            'Concept same_as to',
            'Concept alt_to to',
            'Concept poss_eq to',
            'Concept was_a to',
            'LOINC replaced by',
            'RxNorm replaced by',
            'SNOMED replaced by',
            'ICD9P replaced by'
        )
  AND EXISTS (
    SELECT 1 FROM concept_relationship_stage s, concept c1, concept c2
      WHERE s.concept_id_1 = c1.concept_id AND s.concept_id_2 = c2.concept_id
      AND s.vocabulary_id_1 = c1.vocabulary_id AND s.vocabulary_id_2 = c2.vocabulary_id
      AND c1.concept_id = d.concept_id_1 -- if exists a new one for the 1st concept
      AND c2.concept_id != d.concept_id_2 -- and the 2nd (replaced to) concept is different
      AND s.relationship_id = d.relationship_id -- it is one of the above relationship_id
  )
;

-- Same for reverse
UPDATE concept_relationship d
   SET valid_end_date  = 
            (SELECT v.latest_update
                 FROM concept c JOIN vocabulary v ON c.vocabulary_id = v.vocabulary_id
              WHERE c.concept_id = d.concept_id_1)
          - 1,                                       -- day before release day
       invalid_reason = 'D'
  WHERE d.relationship_id in (
            'LOINC replaces', 
            'RxNorm replaces', 
            'SNOMED replaces',
            'Concept replaces',
            'Concept same_as from',
            'Concept alt_to from',
            'Concept poss_eq from',
            'Concept was_a from',
            'ICD9P replaces',
            'UCUM replaces'
        )
  AND EXISTS (
    SELECT 1 FROM concept_relationship_stage s, concept c1, concept c2
      WHERE s.concept_id_1 = c1.concept_id AND s.concept_id_2 = c2.concept_id
      AND s.vocabulary_id_1 = c1.vocabulary_id AND s.vocabulary_id_2 = c2.vocabulary_id
      AND c2.concept_id = d.concept_id_2 -- if exists a new one for the 2nd concept
      AND c1.concept_id != d.concept_id_1 -- and the 1st (replaced to) concept is different
      AND s.relationship_id = d.relationship_id -- it is one of the above relationship_id
  )
;

COMMIT;

-- 9. Insert new relationships if they don't already exist
ALTER TABLE concept_relationship NOLOGGING;

INSERT /*+ APPEND */ INTO concept_relationship (concept_id_1,
                                  concept_id_2,
                                  relationship_id,
                                  valid_start_date,
                                  valid_end_date,
                                  invalid_reason)
   SELECT DISTINCT 
          r1.concept_id,
          r2.concept_id,
          crs.relationship_id,
          crs.valid_start_date,
          TO_DATE ('20991231', 'YYYYMMDD') AS valid_end_date,
          NULL AS invalid_reason
    FROM concept_relationship_stage crs
    JOIN concept r1 ON r1.concept_code = crs.concept_code_1 AND r1.vocabulary_id = crs.vocabulary_id_1
    JOIN concept r2 ON r2.concept_code = crs.concept_code_2 AND r2.vocabulary_id = crs.vocabulary_id_2
    WHERE NOT EXISTS -- an identical one
             (SELECT 1
                FROM concept_relationship r
               WHERE     r1.concept_id = r.concept_id_1
                     AND r2.concept_id = r.concept_id_2
                     AND crs.relationship_id = r.relationship_id
              )
;
ALTER TABLE concept_relationship LOGGING;

COMMIT;

-- The following are a bunch of rules for Maps to and Maps from relationships. 
-- Since they work outside the _stage tables, they will be restricted to the vocabularies worked on 

-- 10. 'Maps to' and 'Mapped from' relationships from concepts to self should exist for all concepts where standard_concept = 'S' 
INSERT /*+ APPEND */ INTO  concept_relationship (
                                        concept_id_1,
                                        concept_id_2,
                                        relationship_id,
                                        valid_start_date,
                                        valid_end_date,
                                        invalid_reason)
	SELECT 
      c.concept_id,
      c.concept_id,
      'Maps to' AS relationship_id,
      v.latest_update, -- date of update
      TO_DATE ('31.12.2099', 'dd.mm.yyyy'),
      NULL
	  FROM concept c
    JOIN vocabulary v ON v.vocabulary_id = c.vocabulary_id
	 WHERE v.latest_update IS NOT NULL -- only the current vocabs
       AND c.standard_concept = 'S'
		   AND NOT EXISTS -- a mapping like this
				  (SELECT 1
					 FROM concept_relationship i
					WHERE c.concept_id = i.concept_id_1
						  AND c.concept_id = i.concept_id_2
						  AND i.relationship_id = 'Maps to')

;

INSERT /*+ APPEND */ INTO  concept_relationship (
                                        concept_id_1,
                                        concept_id_2,
                                        relationship_id,
                                        valid_start_date,
                                        valid_end_date,
                                        invalid_reason)
	SELECT 
      c.concept_id,
      c.concept_id,
      'Mapped from' AS relationship_id,
      v.latest_update, -- date of update
      TO_DATE ('31.12.2099', 'dd.mm.yyyy'),
      NULL
	  FROM concept c
    JOIN vocabulary v ON v.vocabulary_id = c.vocabulary_id
	 WHERE v.latest_update IS NOT NULL -- only the current vocabs
       AND c.standard_concept = 'S'
		   AND NOT EXISTS -- a mapping like this
				  (SELECT 1
					 FROM concept_relationship i
					WHERE c.concept_id = i.concept_id_1
						  AND c.concept_id = i.concept_id_2
						  AND i.relationship_id = 'Mapped from');

COMMIT;

-- 11. 'Maps to' or 'Mapped from' relationships should not exist where 
-- a) the source concept has standard_concept = 'S', unless it is to self
-- b) the target concept has standard_concept = 'C' or NULL

UPDATE concept_relationship d
   SET d.valid_end_date =
            (SELECT v.latest_update
               FROM concept c
                    JOIN vocabulary v ON c.vocabulary_id = v.vocabulary_id
              WHERE c.concept_id = d.concept_id_1)
          - 1,                                       -- day before release day
       d.invalid_reason = 'D'
 WHERE d.ROWID IN (SELECT r.ROWID
                     FROM concept_relationship r,
                          concept c1,
                          concept c2,
                          vocabulary v
                    WHERE     r.concept_id_1 = c1.concept_id
                          AND r.concept_id_2 = c2.concept_id
                          AND (       (c1.standard_concept = 'S'
								  AND c1.vocabulary_id = c2.vocabulary_id
                                  AND c1.concept_id != c2.concept_id) -- rule a)
                               OR COALESCE (c2.standard_concept, 'X') != 'S' -- rule b)
                                                                            )
                          AND c1.vocabulary_id = v.vocabulary_id
                          AND v.latest_update IS NOT NULL -- only the current vocabularies
                          AND r.relationship_id = 'Maps to'
                          AND r.invalid_reason IS NULL);
COMMIT;

-- And reverse

UPDATE concept_relationship d
   SET d.valid_end_date =
            (SELECT v.latest_update
               FROM concept c
                    JOIN vocabulary v ON c.vocabulary_id = v.vocabulary_id
              WHERE c.concept_id = d.concept_id_2)
          - 1,                                       -- day before release day
       d.invalid_reason = 'D'
 WHERE d.ROWID IN (SELECT r.ROWID
                     FROM concept_relationship r,
                          concept c1,
                          concept c2,
                          vocabulary v
                    WHERE     r.concept_id_1 = c1.concept_id
                          AND r.concept_id_2 = c2.concept_id
                          AND (       (c2.standard_concept = 'S'
								  AND c1.vocabulary_id = c2.vocabulary_id
                                  AND c1.concept_id != c2.concept_id) -- rule a)
                               OR COALESCE (c1.standard_concept, 'X') != 'S' -- rule b)
                                                                            )
                          AND c2.vocabulary_id = v.vocabulary_id
                          AND v.latest_update IS NOT NULL -- only the current vocabularies
                          AND r.relationship_id = 'Mapped from'
                          AND r.invalid_reason IS NULL);

COMMIT;

/*********************************************************
* Update the correct invalid reason in the concept table *
* This should rarely happen                              *
*********************************************************/

-- 12. Make sure invalid_reason = 'U' if we have an active replacement record in the concept_relationship table
UPDATE concept c SET
  c.invalid_reason = 'U'
WHERE c.valid_end_date != TO_DATE ('20991231', 'YYYYMMDD') -- deprecated date
AND EXISTS (
  SELECT 1
  FROM concept_relationship r
    WHERE r.concept_id_1 = c.concept_id 
      AND r.relationship_id in (
        'UCUM replaced by',
        'Concept replaced by',
        'Concept same_as to',
        'Concept alt_to to',
        'Concept poss_eq to',
        'Concept was_a to',
        'LOINC replaced by',
        'RxNorm replaced by',
        'SNOMED replaced by',
        'ICD9P replaced by'
      )      
  ) 
AND c.vocabulary_id IN (SELECT vocabulary_id FROM vocabulary WHERE latest_update IS NOT NULL) -- only for current vocabularies
AND c.invalid_reason IS NULL -- not already deprecated
;

-- 13. Make sure invalid_reason = 'D' if we have no active replacement record in the concept_relationship table
UPDATE concept c SET
  c.invalid_reason = 'D'
WHERE c.valid_end_date != TO_DATE ('20991231', 'YYYYMMDD') -- deprecated date
AND NOT EXISTS (
  SELECT 1
  FROM concept_relationship r
    WHERE r.concept_id_1 = c.concept_id 
      AND r.relationship_id in (
        'UCUM replaced by',
        'Concept replaced by',
        'Concept same_as to',
        'Concept alt_to to',
        'Concept poss_eq to',
        'Concept was_a to',
        'LOINC replaced by',
        'RxNorm replaced by',
        'SNOMED replaced by',
        'ICD9P replaced by'
      )      
  ) 
AND c.vocabulary_id IN (SELECT vocabulary_id FROM vocabulary WHERE latest_update IS NOT NULL) -- only for current vocabularies
AND c.invalid_reason IS NULL -- not already deprecated
;

-- 14. Make sure invalid_reason = null if the valid_end_date is 31-Dec-2099
UPDATE concept SET
  invalid_reason = null
WHERE valid_end_date = TO_DATE ('20991231', 'YYYYMMDD') -- deprecated date
AND vocabulary_id IN (SELECT vocabulary_id FROM vocabulary WHERE latest_update IS NOT NULL) -- only for current vocabularies
AND invalid_reason IS NOT NULL -- if wrongly deprecated
;

COMMIT;

/***********************************
* Update the concept_synonym table *
************************************/

-- 15. Remove all existing synonyms for concepts that are in concept_stage
-- Synonyms are built from scratch each time, no life cycle
DELETE FROM concept_synonym csyn
      WHERE csyn.concept_id IN (SELECT c.concept_id
                                  FROM concept c, concept_stage cs
                                 WHERE c.concept_code = cs.concept_code
                                       AND cs.vocabulary_id = c.vocabulary_id
                               );

-- 16. Add new synonyms for existing concepts
INSERT /*+ APPEND */ INTO concept_synonym (concept_id,
                             concept_synonym_name,
                             language_concept_id)
   SELECT c.concept_id, synonym_name, 4093769 -- for English
     FROM concept_synonym_stage css, concept c, concept_stage cs
    WHERE     css.synonym_concept_code = c.concept_code
          AND css.synonym_vocabulary_id = c.vocabulary_id
          AND cs.concept_code = c.concept_code
          AND cs.vocabulary_id = c.vocabulary_id
;

COMMIT;

-- QA
-- Only one active replacement relationship per fresh code
-- Maps using this replacement relationship to get to a fresh one.
-- concepot_relationship records have no invalid_reason = 'U'

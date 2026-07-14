DROP INDEX builds_job_trigger_id_uniq;

ALTER TABLE builds DROP COLUMN trigger_id;

ALTER TABLE builds ADD COLUMN trigger_id text;

CREATE UNIQUE INDEX builds_job_trigger_id_uniq
    ON builds (job_id, created_by, trigger_id)
    WHERE trigger_id IS NOT NULL;

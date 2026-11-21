-- A second migration, to show they apply in order, each once.
create index if not exists job_log_said on job_log (said);

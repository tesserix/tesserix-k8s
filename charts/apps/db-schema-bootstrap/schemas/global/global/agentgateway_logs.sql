-- agentgateway migrates its own tables at startup; this file exists so the
-- bootstrap CronJob creates the database and hands it to the owning role.
ALTER DATABASE agentgateway_logs OWNER TO agentgateway;
GRANT ALL ON SCHEMA public TO agentgateway;

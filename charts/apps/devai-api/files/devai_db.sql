-- ============================================================
-- DevAI Database Bootstrap (ALM + SRE)
-- Fully idempotent: safe to run on every CronJob execution.
-- Creates extensions, tables, indexes, and views
-- only when they do not already exist.
-- ============================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
DO $$ BEGIN CREATE EXTENSION IF NOT EXISTS "vector"; EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'pgvector not available, skipping'; END $$;

-- ============================================================================
-- ALM: PIPELINE RUNS
-- ============================================================================

CREATE TABLE IF NOT EXISTS pipeline_runs (
    id              TEXT PRIMARY KEY,
    repo_full_name  TEXT NOT NULL,
    trigger_type    TEXT NOT NULL,
    trigger_ref     TEXT NOT NULL DEFAULT '',
    requirements    TEXT NOT NULL DEFAULT '',
    stage           TEXT NOT NULL DEFAULT 'triggered',
    branch_name     TEXT,
    pr_number       INTEGER,
    review_iteration INTEGER NOT NULL DEFAULT 0,
    security_decision TEXT,
    db_decision       TEXT,
    build_status      TEXT,
    deploy_status     TEXT,
    deploy_environment TEXT DEFAULT 'production',
    error           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at    TIMESTAMPTZ,
    governance_snapshot TEXT
);

CREATE INDEX IF NOT EXISTS idx_runs_repo ON pipeline_runs(repo_full_name);
CREATE INDEX IF NOT EXISTS idx_runs_stage ON pipeline_runs(stage);
CREATE INDEX IF NOT EXISTS idx_runs_created ON pipeline_runs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_runs_trigger ON pipeline_runs(trigger_type, trigger_ref);

-- ============================================================================
-- ALM: AGENT EXECUTIONS
-- ============================================================================

CREATE TABLE IF NOT EXISTS agent_executions (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    run_id          TEXT NOT NULL,
    agent_name      TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending',
    started_at      TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ,
    duration_ms     INTEGER,
    input_summary   TEXT,
    output_summary  TEXT,
    output_data     JSONB DEFAULT '{}'::jsonb,
    error_message   TEXT,
    retry_count     INTEGER NOT NULL DEFAULT 0,
    provider        TEXT,
    model           TEXT,
    tokens_input    INTEGER DEFAULT 0,
    tokens_output   INTEGER DEFAULT 0,
    llm_cost_usd    NUMERIC(10,6) DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_agent_exec_run ON agent_executions(run_id);
CREATE INDEX IF NOT EXISTS idx_agent_exec_agent ON agent_executions(agent_name);
CREATE INDEX IF NOT EXISTS idx_agent_exec_status ON agent_executions(status);

-- ============================================================================
-- ALM: A2A MESSAGES
-- ============================================================================

CREATE TABLE IF NOT EXISTS a2a_messages (
    id              TEXT PRIMARY KEY,
    run_id          TEXT NOT NULL,
    from_agent      TEXT NOT NULL,
    to_agent        TEXT NOT NULL,
    message_type    TEXT NOT NULL,
    subject         TEXT NOT NULL,
    body            TEXT NOT NULL,
    payload         JSONB DEFAULT '{}'::jsonb,
    in_reply_to     TEXT REFERENCES a2a_messages(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_a2a_run ON a2a_messages(run_id);
CREATE INDEX IF NOT EXISTS idx_a2a_from ON a2a_messages(from_agent);
CREATE INDEX IF NOT EXISTS idx_a2a_to ON a2a_messages(to_agent);
CREATE INDEX IF NOT EXISTS idx_a2a_type ON a2a_messages(message_type);
CREATE INDEX IF NOT EXISTS idx_a2a_reply ON a2a_messages(in_reply_to);

-- ============================================================================
-- ALM: AGENT MEMORY (pgvector)
-- ============================================================================

CREATE TABLE IF NOT EXISTS agent_memories (
    id              TEXT PRIMARY KEY,
    agent           TEXT NOT NULL,
    repo            TEXT NOT NULL DEFAULT 'global',
    memory_type     TEXT NOT NULL,
    content         TEXT NOT NULL,
    tags            TEXT[] DEFAULT '{}',
    metadata        JSONB DEFAULT '{}'::jsonb,
    relevance_score REAL NOT NULL DEFAULT 1.0,
    access_count    INTEGER NOT NULL DEFAULT 0,
    last_accessed   TIMESTAMPTZ,
    embedding       vector(1536),
    expires_at      TIMESTAMPTZ,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_memory_agent ON agent_memories(agent);
CREATE INDEX IF NOT EXISTS idx_memory_repo ON agent_memories(repo);
CREATE INDEX IF NOT EXISTS idx_memory_type ON agent_memories(memory_type);
CREATE INDEX IF NOT EXISTS idx_memory_tags ON agent_memories USING GIN(tags);
CREATE INDEX IF NOT EXISTS idx_memory_active ON agent_memories(is_active) WHERE is_active = TRUE;

-- Semantic similarity search (HNSW)
DO $$ BEGIN
    CREATE INDEX idx_memory_embedding ON agent_memories
        USING hnsw (embedding vector_cosine_ops)
        WHERE embedding IS NOT NULL;
EXCEPTION WHEN duplicate_table THEN NULL;
END $$;

-- ============================================================================
-- ALM: AUDIT LOG
-- ============================================================================

CREATE TABLE IF NOT EXISTS audit_log (
    id              BIGSERIAL PRIMARY KEY,
    run_id          TEXT REFERENCES pipeline_runs(id),
    agent_name      TEXT,
    action          TEXT NOT NULL,
    entity_type     TEXT,
    entity_ref      TEXT,
    details         JSONB DEFAULT '{}'::jsonb,
    actor           TEXT NOT NULL,
    actor_type      TEXT NOT NULL DEFAULT 'agent',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_audit_run ON audit_log(run_id);
CREATE INDEX IF NOT EXISTS idx_audit_agent ON audit_log(agent_name);
CREATE INDEX IF NOT EXISTS idx_audit_action ON audit_log(action);
CREATE INDEX IF NOT EXISTS idx_audit_entity ON audit_log(entity_type, entity_ref);
CREATE INDEX IF NOT EXISTS idx_audit_created ON audit_log(created_at DESC);

-- ============================================================================
-- ALM: APPROVAL GATES
-- ============================================================================

CREATE TABLE IF NOT EXISTS approval_gates (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    run_id          TEXT NOT NULL,
    gate_name       TEXT NOT NULL,
    agent_name      TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending',
    decided_by      TEXT,
    decided_at      TIMESTAMPTZ,
    reason          TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at      TIMESTAMPTZ DEFAULT NOW() + INTERVAL '1 hour'
);

CREATE INDEX IF NOT EXISTS idx_gates_run ON approval_gates(run_id);
CREATE INDEX IF NOT EXISTS idx_gates_status ON approval_gates(status) WHERE status = 'pending';

-- ============================================================================
-- ALM: DB MIGRATION AUDIT
-- ============================================================================

CREATE TABLE IF NOT EXISTS db_migration_audit (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    run_id          TEXT NOT NULL,
    repo            TEXT NOT NULL,
    migration_type  TEXT NOT NULL,
    migration_file  TEXT NOT NULL,
    migration_hash  TEXT,
    direction       TEXT NOT NULL DEFAULT 'up',
    is_destructive  BOOLEAN NOT NULL DEFAULT FALSE,
    tables_created  TEXT[] DEFAULT '{}',
    tables_modified TEXT[] DEFAULT '{}',
    tables_dropped  TEXT[] DEFAULT '{}',
    columns_added   TEXT[] DEFAULT '{}',
    columns_dropped TEXT[] DEFAULT '{}',
    status          TEXT NOT NULL DEFAULT 'generated',
    applied_by      TEXT,
    applied_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_db_migration_run ON db_migration_audit(run_id);
CREATE INDEX IF NOT EXISTS idx_db_migration_repo ON db_migration_audit(repo);

-- ============================================================================
-- ALM: SECURITY FINDINGS
-- ============================================================================

CREATE TABLE IF NOT EXISTS security_findings (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    run_id          TEXT NOT NULL,
    repo            TEXT NOT NULL,
    pr_number       INTEGER,
    scanner         TEXT NOT NULL,
    severity        TEXT NOT NULL,
    tool            TEXT,
    file_path       TEXT,
    line_number     INTEGER,
    issue           TEXT NOT NULL,
    cve_id          TEXT,
    cwe_id          TEXT,
    status          TEXT NOT NULL DEFAULT 'open',
    resolved_by     TEXT,
    resolved_at     TIMESTAMPTZ,
    resolution_note TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_security_run ON security_findings(run_id);
CREATE INDEX IF NOT EXISTS idx_security_severity ON security_findings(severity);
CREATE INDEX IF NOT EXISTS idx_security_status ON security_findings(status) WHERE status = 'open';

-- ============================================================================
-- ALM: PIPELINE CONFIGURATION
-- ============================================================================

CREATE TABLE IF NOT EXISTS pipeline_config (
    repo            TEXT PRIMARY KEY,
    auto_mode       BOOLEAN NOT NULL DEFAULT FALSE,
    gates           JSONB NOT NULL DEFAULT '{}'::jsonb,
    claude_model    TEXT DEFAULT 'claude-sonnet-4-20250514',
    openai_model    TEXT DEFAULT 'o3',
    groq_model      TEXT DEFAULT 'llama-3.3-70b-versatile',
    max_review_iterations INTEGER DEFAULT 3,
    agent_timeout_seconds INTEGER DEFAULT 900,
    claude_md_content TEXT,
    claude_md_version INTEGER DEFAULT 0,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_by      TEXT
);

-- ============================================================================
-- SRE: MONITORED CLUSTERS
-- ============================================================================

CREATE TABLE IF NOT EXISTS sre_clusters (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    provider        TEXT NOT NULL,
    project_id      TEXT,
    region          TEXT,
    endpoint        TEXT,
    namespaces      TEXT[] DEFAULT '{}',
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================================
-- SRE: MONITORED APPS
-- ============================================================================

CREATE TABLE IF NOT EXISTS sre_apps (
    id              TEXT PRIMARY KEY,
    cluster_id      TEXT NOT NULL REFERENCES sre_clusters(id),
    namespace       TEXT NOT NULL,
    name            TEXT NOT NULL,
    repo            TEXT,
    kind            TEXT DEFAULT 'Deployment',
    health_url      TEXT,
    metrics_url     TEXT,
    owner_team      TEXT,
    owner_users     TEXT[] DEFAULT '{}',
    alert_channels  TEXT[] DEFAULT '{}',
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_sre_apps_cluster ON sre_apps(cluster_id);
CREATE INDEX IF NOT EXISTS idx_sre_apps_repo ON sre_apps(repo);

-- ============================================================================
-- SRE: INCIDENTS
-- ============================================================================

CREATE TABLE IF NOT EXISTS sre_incidents (
    id              TEXT PRIMARY KEY,
    cluster_id      TEXT REFERENCES sre_clusters(id),
    app_id          TEXT REFERENCES sre_apps(id),
    severity        TEXT NOT NULL,
    category        TEXT NOT NULL,
    title           TEXT NOT NULL,
    description     TEXT NOT NULL,
    evidence        JSONB DEFAULT '{}'::jsonb,
    detected_by     TEXT NOT NULL,
    detection_method TEXT,
    scm_issue_number INTEGER,
    scm_pr_number    INTEGER,
    scm_repo         TEXT,
    assigned_to      TEXT[] DEFAULT '{}',
    status          TEXT NOT NULL DEFAULT 'open',
    resolved_at     TIMESTAMPTZ,
    resolution_note TEXT,
    mttr_seconds    INTEGER,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_incidents_status ON sre_incidents(status) WHERE status IN ('open', 'investigating');
CREATE INDEX IF NOT EXISTS idx_incidents_severity ON sre_incidents(severity);
CREATE INDEX IF NOT EXISTS idx_incidents_app ON sre_incidents(app_id);
CREATE INDEX IF NOT EXISTS idx_incidents_created ON sre_incidents(created_at DESC);

-- ============================================================================
-- SRE: HEALTH CHECKS
-- ============================================================================

CREATE TABLE IF NOT EXISTS sre_health_checks (
    id              BIGSERIAL PRIMARY KEY,
    cluster_id      TEXT NOT NULL REFERENCES sre_clusters(id),
    app_id          TEXT REFERENCES sre_apps(id),
    check_type      TEXT NOT NULL,
    status          TEXT NOT NULL,
    details         JSONB DEFAULT '{}'::jsonb,
    response_ms     INTEGER,
    checked_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_health_cluster ON sre_health_checks(cluster_id, checked_at DESC);
CREATE INDEX IF NOT EXISTS idx_health_app ON sre_health_checks(app_id, checked_at DESC);

-- ============================================================================
-- SRE: METRICS SNAPSHOTS
-- ============================================================================

CREATE TABLE IF NOT EXISTS sre_metrics (
    id              BIGSERIAL PRIMARY KEY,
    cluster_id      TEXT NOT NULL REFERENCES sre_clusters(id),
    app_id          TEXT REFERENCES sre_apps(id),
    metric_name     TEXT NOT NULL,
    metric_value    DOUBLE PRECISION NOT NULL,
    metric_unit     TEXT,
    labels          JSONB DEFAULT '{}'::jsonb,
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_metrics_app ON sre_metrics(app_id, metric_name, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_metrics_cluster ON sre_metrics(cluster_id, metric_name, recorded_at DESC);

-- ============================================================================
-- SRE: COST REPORTS
-- ============================================================================

CREATE TABLE IF NOT EXISTS sre_cost_reports (
    id              BIGSERIAL PRIMARY KEY,
    cluster_id      TEXT REFERENCES sre_clusters(id),
    report_date     DATE NOT NULL,
    provider        TEXT NOT NULL,
    total_cost_usd  NUMERIC(12,2) NOT NULL,
    compute_cost    NUMERIC(12,2) DEFAULT 0,
    storage_cost    NUMERIC(12,2) DEFAULT 0,
    network_cost    NUMERIC(12,2) DEFAULT 0,
    other_cost      NUMERIC(12,2) DEFAULT 0,
    breakdown       JSONB DEFAULT '{}'::jsonb,
    recommendations JSONB DEFAULT '{}'::jsonb,
    daily_change_pct NUMERIC(6,2),
    monthly_forecast NUMERIC(12,2),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_cost_date ON sre_cost_reports(report_date DESC);

DO $$ BEGIN
    CREATE UNIQUE INDEX idx_cost_unique ON sre_cost_reports(cluster_id, report_date, provider);
EXCEPTION WHEN duplicate_table THEN NULL;
END $$;

-- ============================================================================
-- SRE: REMEDIATIONS
-- ============================================================================

CREATE TABLE IF NOT EXISTS sre_remediations (
    id              TEXT PRIMARY KEY,
    incident_id     TEXT NOT NULL REFERENCES sre_incidents(id),
    action_type     TEXT NOT NULL,
    description     TEXT NOT NULL,
    target          TEXT,
    payload         JSONB DEFAULT '{}'::jsonb,
    status          TEXT NOT NULL DEFAULT 'pending',
    executed_at     TIMESTAMPTZ,
    result          TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_remediation_incident ON sre_remediations(incident_id);

-- ============================================================================
-- SRE: SCAN RUNS
-- ============================================================================

CREATE TABLE IF NOT EXISTS sre_scan_runs (
    id              TEXT PRIMARY KEY,
    cluster_id      TEXT NOT NULL REFERENCES sre_clusters(id),
    trigger         TEXT NOT NULL DEFAULT 'cron',
    status          TEXT NOT NULL DEFAULT 'running',
    incidents_found INTEGER DEFAULT 0,
    apps_checked    INTEGER DEFAULT 0,
    checks_passed   INTEGER DEFAULT 0,
    checks_failed   INTEGER DEFAULT 0,
    agent_timings   JSONB DEFAULT '{}'::jsonb,
    started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at    TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_scan_runs_cluster ON sre_scan_runs(cluster_id, started_at DESC);

-- ============================================================================
-- VIEWS
-- ============================================================================

CREATE OR REPLACE VIEW v_recent_activity AS
SELECT
    r.id,
    r.repo_full_name,
    r.stage,
    r.trigger_type,
    r.created_at,
    r.completed_at,
    EXTRACT(EPOCH FROM (COALESCE(r.completed_at, NOW()) - r.created_at)) AS duration_seconds,
    COUNT(DISTINCT ae.id) AS agent_count,
    COUNT(DISTINCT a2a.id) AS message_count,
    SUM(ae.tokens_input + ae.tokens_output) AS total_tokens,
    SUM(ae.llm_cost_usd) AS total_cost_usd
FROM pipeline_runs r
LEFT JOIN agent_executions ae ON ae.run_id = r.id
LEFT JOIN a2a_messages a2a ON a2a.run_id = r.id
GROUP BY r.id
ORDER BY r.created_at DESC;

CREATE OR REPLACE VIEW v_agent_stats AS
SELECT
    agent_name,
    COUNT(*) AS total_executions,
    COUNT(*) FILTER (WHERE status = 'completed') AS successes,
    COUNT(*) FILTER (WHERE status = 'failed') AS failures,
    AVG(duration_ms) AS avg_duration_ms,
    SUM(tokens_input + tokens_output) AS total_tokens,
    SUM(llm_cost_usd) AS total_cost_usd
FROM agent_executions
GROUP BY agent_name;

CREATE OR REPLACE VIEW v_security_posture AS
SELECT
    repo,
    COUNT(*) AS total_findings,
    COUNT(*) FILTER (WHERE severity = 'critical') AS critical,
    COUNT(*) FILTER (WHERE severity = 'high') AS high,
    COUNT(*) FILTER (WHERE status = 'open') AS open_findings,
    COUNT(*) FILTER (WHERE status = 'fixed') AS fixed
FROM security_findings
GROUP BY repo;

CREATE OR REPLACE VIEW v_sre_cluster_health AS
SELECT
    c.id AS cluster_id,
    c.name AS cluster_name,
    COUNT(DISTINCT a.id) AS total_apps,
    COUNT(DISTINCT i.id) FILTER (WHERE i.status IN ('open', 'investigating')) AS open_incidents,
    COUNT(DISTINCT i.id) FILTER (WHERE i.severity = 'critical' AND i.status = 'open') AS critical_incidents,
    (SELECT total_cost_usd FROM sre_cost_reports cr
     WHERE cr.cluster_id = c.id ORDER BY report_date DESC LIMIT 1) AS latest_daily_cost
FROM sre_clusters c
LEFT JOIN sre_apps a ON a.cluster_id = c.id AND a.is_active
LEFT JOIN sre_incidents i ON i.cluster_id = c.id
WHERE c.is_active
GROUP BY c.id;

CREATE OR REPLACE VIEW v_sre_app_reliability AS
SELECT
    a.id AS app_id,
    a.name,
    a.namespace,
    a.repo,
    COUNT(i.id) AS total_incidents_30d,
    COUNT(i.id) FILTER (WHERE i.severity IN ('critical', 'high')) AS severe_incidents_30d,
    AVG(i.mttr_seconds) AS avg_mttr_seconds,
    COUNT(hc.id) FILTER (WHERE hc.status = 'healthy') * 100.0 /
        NULLIF(COUNT(hc.id), 0) AS health_pct_7d
FROM sre_apps a
LEFT JOIN sre_incidents i ON i.app_id = a.id AND i.created_at > NOW() - INTERVAL '30 days'
LEFT JOIN sre_health_checks hc ON hc.app_id = a.id AND hc.checked_at > NOW() - INTERVAL '7 days'
WHERE a.is_active
GROUP BY a.id;

-- ============================================================================
-- ALM: REPO ONBOARDING (Repos page)
-- Cache of repo onboarding state. The source of truth is the
-- `.platform/devai.yaml` marker on each repo's default branch — the
-- DevAI reconciler rebuilds this table from those markers, so it can be
-- dropped and regenerated without losing onboarded state.
-- ============================================================================

CREATE TABLE IF NOT EXISTS repo_onboarding (
    owner               TEXT NOT NULL,
    name                TEXT NOT NULL,
    state               TEXT NOT NULL DEFAULT 'discovered',  -- discovered|pending_pr|onboarded|archived|dormant
    pr_number           INTEGER,
    pr_url              TEXT NOT NULL DEFAULT '',
    default_base_branch TEXT NOT NULL DEFAULT 'main',
    description         TEXT NOT NULL DEFAULT '',
    detected_stack      JSONB NOT NULL DEFAULT '{}'::jsonb,
    onboarded_at        TIMESTAMPTZ,
    onboarded_by        TEXT NOT NULL DEFAULT '',
    tags                JSONB NOT NULL DEFAULT '[]'::jsonb,
    draft               BOOLEAN NOT NULL DEFAULT false,  -- onboarding PR is a draft until marked ready
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (owner, name)
);

-- Idempotent column add for tables provisioned before `draft` existed
-- (CREATE TABLE IF NOT EXISTS won't alter an already-present table).
ALTER TABLE repo_onboarding ADD COLUMN IF NOT EXISTS draft BOOLEAN NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS idx_repo_onboarding_state ON repo_onboarding(state);
CREATE INDEX IF NOT EXISTS idx_repo_onboarding_updated ON repo_onboarding(updated_at DESC);

-- Drop the legacy run_id FKs on databases created before the Fiber cutover
-- (active pipeline keeps runs in Redis; pipeline_runs is legacy-only).
ALTER TABLE agent_executions DROP CONSTRAINT IF EXISTS agent_executions_run_id_fkey;
ALTER TABLE a2a_messages DROP CONSTRAINT IF EXISTS a2a_messages_run_id_fkey;

-- ============================================================================
-- SANDBOXES — pinned, TTL-bounded agent configurations
-- The spec is stored whole as JSONB because it is frozen at creation: this row
-- is the record of what an eval ran against. Destroyed rows are kept.
-- ============================================================================
CREATE TABLE IF NOT EXISTS sandboxes (
    id             TEXT PRIMARY KEY,
    owner          TEXT NOT NULL,
    spec           JSONB NOT NULL,
    status         TEXT NOT NULL DEFAULT 'pending',  -- pending | provisioning | ready | destroying | destroyed | failed
    detail         JSONB NOT NULL DEFAULT '{}'::jsonb,
    expires_at     TIMESTAMPTZ NOT NULL,
    last_access_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_sandboxes_owner ON sandboxes(owner, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sandboxes_reap ON sandboxes(expires_at) WHERE status <> 'destroyed';
CREATE INDEX IF NOT EXISTS idx_sandboxes_agent ON sandboxes((spec->'agent'->>'name'), created_at DESC);

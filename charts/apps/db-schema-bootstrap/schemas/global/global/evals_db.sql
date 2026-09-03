-- Shared evaluation store for every product: golden datasets, rubrics, runs,
-- per-criterion scores and promotion baselines. Written by the grader service
-- (role "grader"); Langfuse receives a fail-open copy for trace drill-down.
-- Listed in reapplyExistingSchemas — every statement must stay idempotent.
-- Anonymised product snapshots stay in devai_evals_db; this database holds
-- only what the grader produces and the cases it grades against.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS eval;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grader') THEN
    EXECUTE 'GRANT CONNECT ON DATABASE evals_db TO grader';
  END IF;
END $$;

-- One dataset per (product, name); modality tells the grader which scorers apply.
CREATE TABLE IF NOT EXISTS eval.datasets (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    product     TEXT NOT NULL,
    name        TEXT NOT NULL,
    modality    TEXT NOT NULL CHECK (modality IN ('agent', 'retrieval', 'ocr', 'transcription')),
    description TEXT NOT NULL DEFAULT '',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (product, name)
);

-- Immutable, content-hashed snapshot of a dataset; results only compare within one version.
CREATE TABLE IF NOT EXISTS eval.dataset_versions (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    dataset_id   UUID NOT NULL REFERENCES eval.datasets(id),
    version      TEXT NOT NULL,
    description  TEXT NOT NULL DEFAULT '',
    case_count   INTEGER NOT NULL CHECK (case_count > 0),
    content_hash TEXT NOT NULL,
    blob_key     TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (dataset_id, version)
);

-- Every case names its tenant; the grader refuses a run answered under another tenant.
CREATE TABLE IF NOT EXISTS eval.cases (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    dataset_version_id UUID NOT NULL REFERENCES eval.dataset_versions(id) ON DELETE CASCADE,
    case_id            TEXT NOT NULL,
    tenant             TEXT NOT NULL,
    input              JSONB NOT NULL,
    expected           JSONB NOT NULL DEFAULT '{}'::jsonb,
    input_blob_key     TEXT,
    tags               TEXT[] NOT NULL DEFAULT '{}',
    UNIQUE (dataset_version_id, case_id)
);

-- Versioned rubric; a wording change bumps version so old scores stop comparing.
CREATE TABLE IF NOT EXISTS eval.rubrics (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name       TEXT NOT NULL,
    version    TEXT NOT NULL,
    criteria   JSONB NOT NULL,
    floor      NUMERIC(4,3) NOT NULL DEFAULT 0.600,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (name, version)
);

-- Agreement of one judge (model + prompt) with human labels; a judge below floor cannot gate.
CREATE TABLE IF NOT EXISTS eval.judge_calibrations (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    rubric_id      UUID NOT NULL REFERENCES eval.rubrics(id),
    model          TEXT NOT NULL,
    prompt_version TEXT NOT NULL,
    kappa          NUMERIC(5,4),
    spearman       NUMERIC(5,4),
    exact          NUMERIC(5,4) NOT NULL,
    length_bias    NUMERIC(5,4),
    sample_size    INTEGER NOT NULL CHECK (sample_size > 0),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (rubric_id, model, prompt_version)
);

-- A suite binds a dataset version to the criteria and thresholds it is graded on.
CREATE TABLE IF NOT EXISTS eval.suites (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    product            TEXT NOT NULL,
    name               TEXT NOT NULL,
    version            TEXT NOT NULL,
    dataset_version_id UUID NOT NULL REFERENCES eval.dataset_versions(id),
    criteria           JSONB NOT NULL,
    thresholds         JSONB NOT NULL DEFAULT '{}'::jsonb,
    quarantined_cases  TEXT[] NOT NULL DEFAULT '{}',
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (product, name, version)
);

-- One graded execution of a suite against a target (agent, engine config, OCR service).
CREATE TABLE IF NOT EXISTS eval.runs (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    suite_id          UUID NOT NULL REFERENCES eval.suites(id),
    product           TEXT NOT NULL,
    tenant            TEXT NOT NULL,
    target            JSONB NOT NULL,
    configuration     JSONB NOT NULL DEFAULT '{}'::jsonb,
    status            TEXT NOT NULL CHECK (status IN ('queued', 'running', 'completed', 'errored', 'incomplete')),
    summary           JSONB NOT NULL DEFAULT '{}'::jsonb,
    langfuse_trace_id TEXT,
    requested_by      TEXT NOT NULL DEFAULT '',
    started_at        TIMESTAMPTZ,
    completed_at      TIMESTAMPTZ,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Per-case outcome; a case that did not complete is never a pass.
CREATE TABLE IF NOT EXISTS eval.case_results (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id        UUID NOT NULL REFERENCES eval.runs(id) ON DELETE CASCADE,
    case_id       TEXT NOT NULL,
    status        TEXT NOT NULL CHECK (status IN ('completed', 'errored', 'incomplete')),
    passed        BOOLEAN,
    output        JSONB,
    error_reason  TEXT,
    artefacts_key TEXT,
    latency_ms    INTEGER,
    cost          NUMERIC(12,6),
    cost_currency TEXT,
    tokens_in     INTEGER,
    tokens_out    INTEGER,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (run_id, case_id)
);

-- One row per criterion per case; unknown is recorded as a reason, never as zero.
CREATE TABLE IF NOT EXISTS eval.scores (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    case_result_id     UUID NOT NULL REFERENCES eval.case_results(id) ON DELETE CASCADE,
    criterion          TEXT NOT NULL,
    value              NUMERIC(12,6),
    unit               TEXT,
    unavailable_reason TEXT,
    reason             TEXT,
    evidence           JSONB,
    judge_stamp        TEXT,
    flagged            BOOLEAN NOT NULL DEFAULT FALSE,
    UNIQUE (case_result_id, criterion),
    CHECK (value IS NOT NULL OR unavailable_reason IS NOT NULL)
);

-- Human labels on a case output; the judge is calibrated against these.
CREATE TABLE IF NOT EXISTS eval.human_labels (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    case_result_id UUID NOT NULL REFERENCES eval.case_results(id) ON DELETE CASCADE,
    rubric_id      UUID NOT NULL REFERENCES eval.rubrics(id),
    reviewer       TEXT NOT NULL,
    score          NUMERIC(6,3) NOT NULL,
    note           TEXT NOT NULL DEFAULT '',
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (case_result_id, rubric_id, reviewer)
);

-- The run a suite is currently gated against; the previous one stays for rollback.
CREATE TABLE IF NOT EXISTS eval.baselines (
    suite_id        UUID PRIMARY KEY REFERENCES eval.suites(id),
    run_id          UUID NOT NULL REFERENCES eval.runs(id),
    previous_run_id UUID REFERENCES eval.runs(id),
    promoted_by     TEXT NOT NULL,
    promoted_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Baseline-versus-candidate verdict, per metric per case, as the gate rendered it.
CREATE TABLE IF NOT EXISTS eval.comparisons (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    baseline_run_id  UUID NOT NULL REFERENCES eval.runs(id),
    candidate_run_id UUID NOT NULL REFERENCES eval.runs(id),
    verdict          TEXT NOT NULL CHECK (verdict IN ('pass', 'warn', 'fail', 'unusable')),
    result           JSONB NOT NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (baseline_run_id <> candidate_run_id)
);

CREATE INDEX IF NOT EXISTS idx_eval_runs_suite_created ON eval.runs(suite_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_eval_runs_product_created ON eval.runs(product, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_eval_case_results_run ON eval.case_results(run_id);
CREATE INDEX IF NOT EXISTS idx_eval_scores_criterion ON eval.scores(criterion, case_result_id);
CREATE INDEX IF NOT EXISTS idx_eval_cases_version ON eval.cases(dataset_version_id);

-- grader writes rows but never DDL; datasets and rubrics are curated, so no UPDATE on cases.
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grader') THEN
    EXECUTE 'GRANT USAGE ON SCHEMA eval TO grader';
    EXECUTE 'GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA eval TO grader';
    EXECUTE 'GRANT UPDATE ON eval.runs, eval.case_results, eval.baselines, eval.datasets TO grader';
  END IF;
END $$;

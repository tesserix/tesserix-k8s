\ir document_intelligence_db.sql

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'document_intelligence_sandbox') THEN
    GRANT CONNECT ON DATABASE document_intelligence_sandbox_db TO document_intelligence_sandbox;
    GRANT USAGE ON SCHEMA public TO document_intelligence_sandbox;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ocr_uploads, ocr_jobs, ocr_results, ocr_outbox, ocr_upload_outbox, ocr_page_workflows, ocr_page_artifacts TO document_intelligence_sandbox;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO document_intelligence_sandbox;
    GRANT EXECUTE ON FUNCTION ocr_claim_work_scopes(TEXT, INTEGER), ocr_release_work_scope(TEXT, TEXT, TEXT), ocr_register_work_scope(TEXT, TEXT, TEXT), ocr_set_work_scope_pending(TEXT, TEXT, TEXT, BOOLEAN) TO document_intelligence_sandbox;
  END IF;
END $$;

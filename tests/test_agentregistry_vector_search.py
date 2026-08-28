import pathlib
import re
import subprocess
import unittest

import yaml


ROOT = pathlib.Path(__file__).parents[1]


def render_registry():
    result = subprocess.run(
        [
            "helm",
            "template",
            "agentic-registry",
            str(ROOT / "charts/apps/agentic-registry"),
            "--namespace",
            "agentregistry-system",
            "--values",
            str(ROOT / "charts/apps/agentic-registry/values-prod.yaml"),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return [document for document in yaml.safe_load_all(result.stdout) if document]


def resource(documents, kind, name):
    return next(
        document
        for document in documents
        if document.get("kind") == kind
        and document.get("metadata", {}).get("name") == name
    )


class AgentRegistryVectorSearchTests(unittest.TestCase):
    def test_prod_bootstrap_installs_pgvector_for_the_existing_database(self):
        application = yaml.safe_load(
            (
                ROOT
                / "argocd/prod/apps/ai-apps/agentic-registry-db-schema-bootstrap.yaml"
            ).read_text()
        )
        values = yaml.safe_load(application["spec"]["source"]["helm"]["values"])
        target = values["targets"][0]

        self.assertTrue(values["applySchemaToExistingDatabases"])
        self.assertEqual("postgres", target["user"])
        self.assertEqual("agentregistry-postgres-superuser", target["secretName"])

        schema = (
            ROOT
            / "charts/apps/db-schema-bootstrap/schemas/agentic-registry/agentregistry-postgres/agentic_registry_db.sql"
        ).read_text()
        self.assertIn("CREATE EXTENSION IF NOT EXISTS vector", schema)
        self.assertIn(
            "ADD COLUMN IF NOT EXISTS embedding vector(256)",
            schema,
        )
        self.assertIn(
            "CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_artifacts_embedding",
            schema,
        )
        self.assertIn("USING hnsw (embedding vector_cosine_ops)", schema)

    def test_prod_bootstrap_owns_atomic_publication_support_tables(self):
        schema = (
            ROOT
            / "charts/apps/db-schema-bootstrap/schemas/agentic-registry/agentregistry-postgres/agentic_registry_db.sql"
        ).read_text()

        self.assertIn(
            "CREATE TABLE IF NOT EXISTS registry.publish_idempotency",
            schema,
        )
        self.assertIn(
            "PRIMARY KEY (actor_scope, key)",
            schema,
        )
        self.assertIn(
            "CREATE INDEX IF NOT EXISTS idx_publish_idempotency_expiry",
            schema,
        )
        self.assertIn(
            "CREATE TABLE IF NOT EXISTS registry.publish_outbox",
            schema,
        )
        self.assertIn(
            "CREATE INDEX IF NOT EXISTS idx_publish_outbox_unpublished",
            schema,
        )
        self.assertIn("WHERE published_at IS NULL", schema)

    def test_prod_enables_vector_search_and_restarts_on_config_changes(self):
        documents = render_registry()
        config = resource(documents, "ConfigMap", "agentregistry-config")
        deployment = resource(documents, "Deployment", "agentregistry")

        self.assertEqual("true", config["data"]["VECTOR_SEARCH"])
        checksum = deployment["spec"]["template"]["metadata"]["annotations"][
            "checksum/config"
        ]
        self.assertRegex(checksum, re.compile(r"^[a-f0-9]{64}$"))

        application = yaml.safe_load(
            (
                ROOT
                / "argocd/prod/apps/ai-apps/agentic-registry-db-schema-bootstrap.yaml"
            ).read_text()
        )
        values = yaml.safe_load(application["spec"]["source"]["helm"]["values"])
        self.assertNotIn("schedule", values)


if __name__ == "__main__":
    unittest.main()

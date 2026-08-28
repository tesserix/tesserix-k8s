import pathlib
import unittest

import yaml


ROOT = pathlib.Path(__file__).parents[1]


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


if __name__ == "__main__":
    unittest.main()

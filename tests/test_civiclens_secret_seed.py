import importlib.util
import pathlib
import unittest
import urllib.error
from unittest.mock import patch

PATH = (
    pathlib.Path(__file__).resolve().parents[1]
    / "charts/apps/civiclens-ai-gateway/files/secret-seed.py"
)
spec = importlib.util.spec_from_file_location("civiclens_seed", PATH)
seed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(seed)
KEY = "civiclens/prod/app/civiclens-ai-gateway-key"


def error(code):
    return urllib.error.HTTPError("https://example.invalid", code, "test", {}, None)


class CivicLensSeed(unittest.TestCase):
    def test_existing_credential_is_never_replaced(self):
        with patch.object(seed, "call", return_value={}) as call:
            seed.seed("private", KEY)
        call.assert_called_once_with("private", "kv/data/" + KEY)

    def test_absent_credential_uses_compare_and_set(self):
        with patch.object(seed, "call", side_effect=[error(404), {}]) as call:
            seed.seed("private", KEY)
        self.assertEqual(call.call_count, 2)
        body = call.call_args.args[2]
        self.assertEqual(body["options"], {"cas": 0})
        self.assertEqual(len(bytes.fromhex(body["data"]["value"])), 32)

    def test_racing_creation_preserves_existing_value(self):
        with (
            patch.object(seed, "present", side_effect=[False, True]),
            patch.object(seed, "call", side_effect=error(400)),
        ):
            seed.seed("private", KEY)

    def test_deleted_key_is_not_reseeded(self):
        with (
            patch.object(seed, "present", side_effect=[False, False]),
            patch.object(seed, "call", side_effect=error(400)),
            self.assertRaisesRegex(RuntimeError, "restore it instead of reseeding"),
        ):
            seed.seed("private", KEY)

    def test_reader_failure_does_not_create_a_key(self):
        with (
            patch.object(seed, "call", side_effect=error(403)) as call,
            self.assertRaises(urllib.error.HTTPError) as failure,
        ):
            seed.seed("private", KEY)
        self.assertEqual(failure.exception.code, 403)
        call.assert_called_once_with("private", "kv/data/" + KEY)

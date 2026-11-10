# OpenBao bootstrap runtime

The initializer uses the Google Cloud SDK image pinned in
`charts/thirdparty/openbao/values.yaml`. That image bundles Python under the SDK
directory without exposing `python3` on the initial PATH. Starting the Job with
`python3` therefore fails before recovery-record validation or policy application.

`bootstrap_entrypoint.sh` asks the SDK for its interpreter, requires an executable
absolute path, exposes its directory to the existing bootstrap shell script,
and checks Python, curl, bash and gcloud before starting the retained-record
wrapper. The existing recovery, initialization opt-in and policy logic remain
in `recovery_record.py` and `bootstrap.sh`.

The rendered ConfigMap records the runtime image reference. Its content hashes
the immutable Job name, so an image or launcher update creates a new initializer
through GitOps. Preserve failed-Job diagnostics before retrying initialization;
do not replace recovery records or application credentials to recover a runner.

Validation includes launcher tests with no Python on the initial PATH, rejection
of an invalid SDK interpreter, and Helm assertions that runtime changes version
the Job. The pinned production image was also exercised without credentials or
network access, as UID 1000 on a read-only filesystem, with a temporary gcloud
configuration directory. It reported Google Cloud SDK 592.0.0 and successfully
loaded the bootstrap Python dependencies through the launcher.

After deployment, verify the new Job completes, then verify the intended live
OpenBao role's lease and exact-path capabilities. Argo sync acknowledgement alone
does not establish that policy initialization completed.

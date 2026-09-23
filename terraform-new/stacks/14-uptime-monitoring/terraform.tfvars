# Stack-local values, deliberately NOT in environments/prod/terraform.tfvars.
#
# Every project in atlantis.yaml autoplans on the shared tfvars — that is the
# point of a shared file, and a test enforces it. So putting a value here that
# only this stack reads would make every future edit to it replan all fourteen
# stacks, take locks on each, and pull any unrelated drift in the estate into
# this PR's apply.
#
# That is not hypothetical. On 2026-09-23 the channel id below was first added
# to the shared file: Atlantis planned the whole estate, took locks on
# 00-state-bootstrap, 02-network and 03-storage, and aborted in group 2 when
# 01-foundation failed to refresh a Document AI processor it no longer has
# permission to read. A monitoring change could not merge because of an IAM
# problem three stacks away, and this stack was never re-planned at all.
#
# Terraform auto-loads terraform.tfvars from the working directory, so this
# needs no workflow change and no -var-file. The shared file stays for values
# that genuinely are shared.
#
# The Slack notification channel created in Cloud Monitoring against
# #falco-events (Tesserix Pty Ltd workspace), referenced by id and not created
# here: the OAuth token stays in the console-owned channel resource rather than
# in this repository.
alert_notification_channels = ["projects/tesseracthub-480811/notificationChannels/157714601067988204"]

#!/usr/bin/env bash
# =============================================================================
# s3-lock-probe.sh — the gate for the whole state backend.
#
# Validates that an S3 endpoint ENFORCES If-None-Match:* conditional writes,
# which OpenTofu/Terraform native S3 state locking (use_lockfile) depends on.
# An endpoint that accepts the header and overwrites anyway hands two concurrent
# applies the same lock, and you find out when state no longer matches reality.
#
# Usage: s3-lock-probe.sh <endpoint-url> <bucket>
# Requires: aws CLI, and AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in the env.
# Exit 0 = conditional writes enforced (real 412 on the second write). Any other
# exit is a HARD STOP — nothing may write OpenTofu state until this passes.
# =============================================================================
set -euo pipefail

EP="${1:?usage: s3-lock-probe.sh <endpoint-url> <bucket>}"
BUCKET="${2:?usage: s3-lock-probe.sh <endpoint-url> <bucket>}"
KEY="_s3-lock-probe.$$"
export AWS_EC2_METADATA_DISABLED=true AWS_REGION="${AWS_REGION:-us-east-1}"

aws_s3api() { aws --endpoint-url "$EP" s3api "$@"; }
cleanup() { aws_s3api delete-object --bucket "$BUCKET" --key "$KEY" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "[*] probe: endpoint=$EP bucket=$BUCKET key=$KEY"

# First conditional write must succeed (object does not exist yet).
if ! aws_s3api put-object --bucket "$BUCKET" --key "$KEY" --if-none-match '*' --body /dev/null >/dev/null 2>&1; then
  echo "[FAIL] first If-None-Match:* write was refused — endpoint rejects conditional writes entirely." >&2
  exit 2
fi
echo "[*] first If-None-Match:* write OK"

# Second conditional write MUST be refused with 412 PreconditionFailed.
set +e
OUT="$(aws_s3api put-object --bucket "$BUCKET" --key "$KEY" --if-none-match '*' --body /dev/null 2>&1)"
RC=$?
set -e

if [ "$RC" -eq 0 ]; then
  echo "[FAIL] second conditional write SUCCEEDED — the lock is NOT enforced (silent overwrite)." >&2
  echo "       State locking is unsafe on this endpoint. Do not use it for OpenTofu state." >&2
  exit 1
fi
if echo "$OUT" | grep -qiE 'PreconditionFailed|412'; then
  echo "[PASS] second write refused with PreconditionFailed/412 — conditional writes are enforced."
  exit 0
fi
echo "[FAIL] second write failed, but not with 412 PreconditionFailed:" >&2
echo "$OUT" >&2
exit 1

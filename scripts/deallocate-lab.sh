#!/usr/bin/env bash
# deallocate-lab.sh
#
# Stops every VM tagged lab=hybrid-cloud. VMs in the "stopped (deallocated)"
# state stop accruing compute charges. Managed disks and public IPs continue
# to charge low monthly amounts.
#
# Use this at the end of every working session in Phase 3.
# Use scripts/delete-lab.sh for the final teardown that nukes the resource group.
#
# Requires: az CLI logged in to the lab subscription.
#
# Usage:
#   ./scripts/deallocate-lab.sh
#   ./scripts/deallocate-lab.sh --dry-run   # show what would happen without doing it

set -euo pipefail

TAG_KEY="lab"
TAG_VALUE="hybrid-cloud"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if ! command -v az >/dev/null 2>&1; then
  echo "az CLI not found. Install it first (Fedora: sudo dnf install azure-cli)." >&2
  exit 1
fi

if ! az account show >/dev/null 2>&1; then
  echo "az not logged in. Run: az login" >&2
  exit 1
fi

echo "Looking for VMs tagged ${TAG_KEY}=${TAG_VALUE}..."

# shellcheck disable=SC2207
VM_IDS=( $(az vm list --query "[?tags.${TAG_KEY}=='${TAG_VALUE}'].id" -o tsv) )

if [ "${#VM_IDS[@]}" -eq 0 ]; then
  echo "No tagged VMs found. Nothing to do."
  exit 0
fi

echo "Found ${#VM_IDS[@]} VM(s):"
for id in "${VM_IDS[@]}"; do
  echo "  $id"
done

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[--dry-run] Skipping deallocate."
  exit 0
fi

echo "Deallocating..."
az vm deallocate --ids "${VM_IDS[@]}" --no-wait
echo "Deallocate request submitted (--no-wait). Check status with:"
echo "  az vm list -d --query \"[?tags.${TAG_KEY}=='${TAG_VALUE}'].{name:name,powerState:powerState}\" -o table"

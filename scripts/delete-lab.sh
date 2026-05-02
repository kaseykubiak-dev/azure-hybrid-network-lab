#!/usr/bin/env bash
# delete-lab.sh
#
# Final teardown. Deletes the rg-hybrid-lab resource group entirely. Every
# resource inside it goes with it. This is the Phase 3f teardown step.
#
# After this completes, confirm $0/month projected cost in Cost Management
# before declaring the lab shipped.
#
# Requires: az CLI logged in to the lab subscription.
#
# Usage:
#   ./scripts/delete-lab.sh
#   ./scripts/delete-lab.sh --rg <name>     # override resource group name
#   ./scripts/delete-lab.sh --dry-run       # show what would happen

set -euo pipefail

RG="rg-hybrid-lab"
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --rg)
      RG="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
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

if ! az group show --name "$RG" >/dev/null 2>&1; then
  echo "Resource group '$RG' not found. Nothing to do."
  exit 0
fi

echo "About to delete resource group: $RG"
echo "Contents:"
az resource list --resource-group "$RG" --query "[].{name:name,type:type}" -o table || true

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[--dry-run] Skipping delete."
  exit 0
fi

read -r -p "Type the resource group name to confirm deletion: " CONFIRM
if [ "$CONFIRM" != "$RG" ]; then
  echo "Confirmation did not match. Aborting." >&2
  exit 1
fi

az group delete --name "$RG" --yes --no-wait
echo "Delete request submitted (--no-wait). Track with:"
echo "  az group show --name $RG --query properties.provisioningState"
echo "When the group disappears entirely, run:"
echo "  az consumption usage list --start-date \$(date -d '1 day ago' +%Y-%m-%d) --end-date \$(date +%Y-%m-%d) -o table"
echo "to confirm zero ongoing cost."

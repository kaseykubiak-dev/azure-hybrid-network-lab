#!/usr/bin/env bash
# deploy-lab.sh
#
# Phase 3 deployment script. Creates all Azure infrastructure for the hybrid
# network lab per docs/azure-design.md. Run this from the repo root on the
# Fedora workstation after `az login`.
#
# Steps 1-9 of the deployment order (Section 9 of the design doc):
#   1. Resource group + tag
#   2. VNet
#   3. Subnets
#   4. NSGs → associate to subnets
#   5. Route table → associate to workload subnet
#   6. Public IP
#   7. FortiGate NICs (IP forwarding ON)
#   8. FortiGate VM (Marketplace BYOL)
#   9. nginx VM (cloud-init installs nginx)
#
# After this script completes, continue with manual steps 10-17 in runbook.md:
#   FortiGate licensing, base config, IPsec/BGP, on-prem update, validation.
#
# Prerequisites:
#   - az CLI installed and logged in (az login)
#   - SSH keypair at ~/.ssh/azure_hybrid_lab_ed25519(.pub)
#   - FortiGate Marketplace terms accepted (script handles this)
#
# Usage:
#   ./scripts/deploy-lab.sh
#   ./scripts/deploy-lab.sh --dry-run    # print commands without executing
#
# Estimated deploy time: 8-12 minutes (FortiGate VM is the bottleneck).

set -euo pipefail

# ─── Configuration (from azure-design.md) ────────────────────────────────────

LOCATION="eastus2"
RG="rg-hybrid-lab"
TAG="lab=hybrid-cloud"

VNET_NAME="vnet-hybrid-lab"
VNET_CIDR="10.100.0.0/16"

SNET_UNTRUST="snet-untrust"
SNET_UNTRUST_CIDR="10.100.1.0/24"
SNET_TRUST="snet-trust"
SNET_TRUST_CIDR="10.100.2.0/24"
SNET_WORKLOAD="snet-workload"
SNET_WORKLOAD_CIDR="10.100.10.0/24"

NSG_UNTRUST="nsg-untrust"
NSG_TRUST="nsg-trust"
NSG_WORKLOAD="nsg-workload"

RT_WORKLOAD="rt-workload"

PIP_NAME="pip-fgt-untrust"

FGT_UNTRUST_NIC="fgt-untrust-nic"
FGT_TRUST_NIC="fgt-trust-nic"
FGT_UNTRUST_IP="10.100.1.4"
FGT_TRUST_IP="10.100.2.4"

FGT_VM_NAME="fgt-azure"
FGT_VM_SIZE="Standard_F1alds_v7"    # 1 vCPU / 2 GB — FortiGate trial license limit
FGT_IMAGE_PUBLISHER="fortinet"
FGT_IMAGE_OFFER="fortinet_fortigate-vm_v5"
FGT_IMAGE_SKU="fortinet_fg-vm_g2"    # BYOL plan (Gen2 — required for v6/v7 SKUs)
FGT_IMAGE_VERSION="latest"

NGINX_VM_NAME="vm-nginx"
NGINX_VM_SIZE="Standard_D2als_v7"
NGINX_NIC_NAME="nginx-nic"
NGINX_IP="10.100.10.4"
NGINX_IMAGE="Canonical:ubuntu-24_04-lts:server:latest"

SSH_PUB_KEY="$HOME/.ssh/azure_hybrid_lab_ed25519.pub"

# ─── Parse arguments ─────────────────────────────────────────────────────────

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

# ─── Helpers ─────────────────────────────────────────────────────────────────

run() {
  echo ""
  echo "→ $*"
  if [ "$DRY_RUN" -eq 0 ]; then
    "$@"
  else
    echo "  [dry-run] skipped"
  fi
}

section() {
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  $1"
  echo "═══════════════════════════════════════════════════════════════"
}

# ─── Pre-flight checks ──────────────────────────────────────────────────────

if ! command -v az >/dev/null 2>&1; then
  echo "ERROR: az CLI not found. Install: sudo dnf install azure-cli" >&2
  exit 1
fi

if ! az account show >/dev/null 2>&1; then
  echo "ERROR: az not logged in. Run: az login" >&2
  exit 1
fi

if [ ! -f "$SSH_PUB_KEY" ]; then
  echo "ERROR: SSH public key not found at $SSH_PUB_KEY" >&2
  echo "Generate one: ssh-keygen -t ed25519 -f ~/.ssh/azure_hybrid_lab_ed25519" >&2
  exit 1
fi

# Detect home WAN IP for the management NSG rule
echo "Detecting home WAN IP..."
HOME_WAN_IP=$(curl -4 -s ifconfig.me)
if [ -z "$HOME_WAN_IP" ]; then
  echo "ERROR: Could not detect WAN IP. Check internet connectivity." >&2
  exit 1
fi
echo "Home WAN IP: $HOME_WAN_IP"

# Prompt for FortiGate admin password
echo ""
read -r -s -p "Set FortiGate admin password (will not echo): " FGT_ADMIN_PW
echo ""
if [ ${#FGT_ADMIN_PW} -lt 8 ]; then
  echo "ERROR: Password must be at least 8 characters (Azure requirement)." >&2
  exit 1
fi

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║  Azure Hybrid Network Lab — Phase 3 Deployment              ║"
echo "║  Region: $LOCATION                                          ║"
echo "║  Resource group: $RG                                        ║"
echo "║  Home WAN IP: $HOME_WAN_IP                                  ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
  echo "[DRY RUN MODE — no resources will be created]"
fi

read -r -p "Continue? (y/N) " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# ─── Step 0: Accept Marketplace terms ────────────────────────────────────────

section "Step 0: Accept FortiGate Marketplace terms"

run az vm image terms accept \
  --publisher "$FGT_IMAGE_PUBLISHER" \
  --offer "$FGT_IMAGE_OFFER" \
  --plan "$FGT_IMAGE_SKU"

# ─── Step 1: Resource group ─────────────────────────────────────────────────

section "Step 1: Resource group"

run az group create \
  --name "$RG" \
  --location "$LOCATION" \
  --tags $TAG

# ─── Step 2: VNet ───────────────────────────────────────────────────────────

section "Step 2: VNet"

run az network vnet create \
  --resource-group "$RG" \
  --name "$VNET_NAME" \
  --location "$LOCATION" \
  --address-prefixes "$VNET_CIDR" \
  --tags $TAG

# ─── Step 3: Subnets ────────────────────────────────────────────────────────

section "Step 3: Subnets"

run az network vnet subnet create \
  --resource-group "$RG" \
  --vnet-name "$VNET_NAME" \
  --name "$SNET_UNTRUST" \
  --address-prefixes "$SNET_UNTRUST_CIDR"

run az network vnet subnet create \
  --resource-group "$RG" \
  --vnet-name "$VNET_NAME" \
  --name "$SNET_TRUST" \
  --address-prefixes "$SNET_TRUST_CIDR"

run az network vnet subnet create \
  --resource-group "$RG" \
  --vnet-name "$VNET_NAME" \
  --name "$SNET_WORKLOAD" \
  --address-prefixes "$SNET_WORKLOAD_CIDR"

# ─── Step 4: NSGs ───────────────────────────────────────────────────────────

section "Step 4a: NSG — untrust"

run az network nsg create \
  --resource-group "$RG" \
  --name "$NSG_UNTRUST" \
  --location "$LOCATION" \
  --tags $TAG

run az network nsg rule create --resource-group "$RG" --nsg-name "$NSG_UNTRUST" \
  --name allow-ipsec-isakmp --priority 100 --direction Inbound --access Allow \
  --protocol Udp --source-address-prefixes Internet \
  --destination-address-prefixes "$FGT_UNTRUST_IP/32" --destination-port-ranges 500

run az network nsg rule create --resource-group "$RG" --nsg-name "$NSG_UNTRUST" \
  --name allow-ipsec-natt --priority 110 --direction Inbound --access Allow \
  --protocol Udp --source-address-prefixes Internet \
  --destination-address-prefixes "$FGT_UNTRUST_IP/32" --destination-port-ranges 4500

run az network nsg rule create --resource-group "$RG" --nsg-name "$NSG_UNTRUST" \
  --name allow-icmp-build --priority 120 --direction Inbound --access Allow \
  --protocol Icmp --source-address-prefixes Internet \
  --destination-address-prefixes "$SNET_UNTRUST_CIDR" --destination-port-ranges '*'

run az network nsg rule create --resource-group "$RG" --nsg-name "$NSG_UNTRUST" \
  --name allow-mgmt --priority 200 --direction Inbound --access Allow \
  --protocol Tcp --source-address-prefixes "${HOME_WAN_IP}/32" \
  --destination-address-prefixes "$FGT_UNTRUST_IP/32" --destination-port-ranges 443

run az network nsg rule create --resource-group "$RG" --nsg-name "$NSG_UNTRUST" \
  --name deny-all-inbound --priority 4096 --direction Inbound --access Deny \
  --protocol '*' --source-address-prefixes '*' \
  --destination-address-prefixes '*' --destination-port-ranges '*'

section "Step 4b: NSG — trust"

run az network nsg create \
  --resource-group "$RG" \
  --name "$NSG_TRUST" \
  --location "$LOCATION" \
  --tags $TAG

run az network nsg rule create --resource-group "$RG" --nsg-name "$NSG_TRUST" \
  --name allow-vnet --priority 100 --direction Inbound --access Allow \
  --protocol '*' --source-address-prefixes VirtualNetwork \
  --destination-address-prefixes VirtualNetwork --destination-port-ranges '*'

run az network nsg rule create --resource-group "$RG" --nsg-name "$NSG_TRUST" \
  --name allow-forwarded-out --priority 100 --direction Outbound --access Allow \
  --protocol '*' --source-address-prefixes 10.255.255.0/24 192.168.10.0/24 \
  --destination-address-prefixes "$SNET_WORKLOAD_CIDR" --destination-port-ranges '*'

run az network nsg rule create --resource-group "$RG" --nsg-name "$NSG_TRUST" \
  --name deny-all-inbound --priority 4096 --direction Inbound --access Deny \
  --protocol '*' --source-address-prefixes '*' \
  --destination-address-prefixes '*' --destination-port-ranges '*'

section "Step 4c: NSG — workload"

run az network nsg create \
  --resource-group "$RG" \
  --name "$NSG_WORKLOAD" \
  --location "$LOCATION" \
  --tags $TAG

run az network nsg rule create --resource-group "$RG" --nsg-name "$NSG_WORKLOAD" \
  --name allow-onprem-http --priority 100 --direction Inbound --access Allow \
  --protocol Tcp --source-address-prefixes 192.168.10.0/24 \
  --destination-address-prefixes "$SNET_WORKLOAD_CIDR" --destination-port-ranges 80

run az network nsg rule create --resource-group "$RG" --nsg-name "$NSG_WORKLOAD" \
  --name allow-fgt-ssh --priority 110 --direction Inbound --access Allow \
  --protocol Tcp --source-address-prefixes "$FGT_TRUST_IP/32" \
  --destination-address-prefixes "$SNET_WORKLOAD_CIDR" --destination-port-ranges 22

run az network nsg rule create --resource-group "$RG" --nsg-name "$NSG_WORKLOAD" \
  --name allow-tunnel-in --priority 105 --direction Inbound --access Allow \
  --protocol '*' --source-address-prefixes 10.255.255.0/24 192.168.10.0/24 \
  --destination-address-prefixes "$SNET_WORKLOAD_CIDR" --destination-port-ranges '*'

run az network nsg rule create --resource-group "$RG" --nsg-name "$NSG_WORKLOAD" \
  --name allow-icmp-diag --priority 120 --direction Inbound --access Allow \
  --protocol Icmp --source-address-prefixes "$SNET_TRUST_CIDR" \
  --destination-address-prefixes "$SNET_WORKLOAD_CIDR" --destination-port-ranges '*'

run az network nsg rule create --resource-group "$RG" --nsg-name "$NSG_WORKLOAD" \
  --name deny-all-inbound --priority 4096 --direction Inbound --access Deny \
  --protocol '*' --source-address-prefixes '*' \
  --destination-address-prefixes '*' --destination-port-ranges '*'

section "Step 4d: Associate NSGs to subnets"

run az network vnet subnet update \
  --resource-group "$RG" --vnet-name "$VNET_NAME" \
  --name "$SNET_UNTRUST" --network-security-group "$NSG_UNTRUST"

run az network vnet subnet update \
  --resource-group "$RG" --vnet-name "$VNET_NAME" \
  --name "$SNET_TRUST" --network-security-group "$NSG_TRUST"

run az network vnet subnet update \
  --resource-group "$RG" --vnet-name "$VNET_NAME" \
  --name "$SNET_WORKLOAD" --network-security-group "$NSG_WORKLOAD"

# ─── Step 5: Route table ────────────────────────────────────────────────────

section "Step 5: Route table"

run az network route-table create \
  --resource-group "$RG" \
  --name "$RT_WORKLOAD" \
  --location "$LOCATION" \
  --tags $TAG

run az network route-table route create --resource-group "$RG" \
  --route-table-name "$RT_WORKLOAD" --name force-default-fgt \
  --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance \
  --next-hop-ip-address "$FGT_TRUST_IP"

run az network route-table route create --resource-group "$RG" \
  --route-table-name "$RT_WORKLOAD" --name force-onprem-fgt \
  --address-prefix 192.168.10.0/24 --next-hop-type VirtualAppliance \
  --next-hop-ip-address "$FGT_TRUST_IP"

run az network route-table route create --resource-group "$RG" \
  --route-table-name "$RT_WORKLOAD" --name force-tunnel-fgt \
  --address-prefix 10.255.255.0/24 --next-hop-type VirtualAppliance \
  --next-hop-ip-address "$FGT_TRUST_IP"

run az network route-table route create --resource-group "$RG" \
  --route-table-name "$RT_WORKLOAD" --name local-workload \
  --address-prefix "$SNET_WORKLOAD_CIDR" --next-hop-type VnetLocal

run az network vnet subnet update \
  --resource-group "$RG" --vnet-name "$VNET_NAME" \
  --name "$SNET_WORKLOAD" --route-table "$RT_WORKLOAD"

# ─── Step 6: Public IP ──────────────────────────────────────────────────────

section "Step 6: Public IP"

run az network public-ip create \
  --resource-group "$RG" \
  --name "$PIP_NAME" \
  --location "$LOCATION" \
  --sku Standard \
  --allocation-method Static \
  --tags $TAG

# Show the allocated public IP
if [ "$DRY_RUN" -eq 0 ]; then
  AZURE_PIP=$(az network public-ip show --resource-group "$RG" --name "$PIP_NAME" --query ipAddress -o tsv)
  echo ""
  echo "╔═══════════════════════════════════════════════════════════════╗"
  echo "  Azure Public IP: $AZURE_PIP"
  echo "  Save this — you will need it for the on-prem FortiGate's"
  echo "  remote-gw setting and to access the FortiGate web GUI."
  echo "╚═══════════════════════════════════════════════════════════════╝"
fi

# ─── Step 7: FortiGate NICs ─────────────────────────────────────────────────

section "Step 7: FortiGate NICs (IP forwarding enabled)"

run az network nic create \
  --resource-group "$RG" \
  --name "$FGT_UNTRUST_NIC" \
  --location "$LOCATION" \
  --vnet-name "$VNET_NAME" \
  --subnet "$SNET_UNTRUST" \
  --private-ip-address "$FGT_UNTRUST_IP" \
  --public-ip-address "$PIP_NAME" \
  --ip-forwarding true \
  --network-security-group "$NSG_UNTRUST" \
  --tags $TAG

run az network nic create \
  --resource-group "$RG" \
  --name "$FGT_TRUST_NIC" \
  --location "$LOCATION" \
  --vnet-name "$VNET_NAME" \
  --subnet "$SNET_TRUST" \
  --private-ip-address "$FGT_TRUST_IP" \
  --ip-forwarding true \
  --network-security-group "$NSG_TRUST" \
  --tags $TAG

# ─── Step 8: FortiGate VM ───────────────────────────────────────────────────

section "Step 8: FortiGate VM (Marketplace BYOL — this takes 3-5 minutes)"

run az vm create \
  --resource-group "$RG" \
  --name "$FGT_VM_NAME" \
  --location "$LOCATION" \
  --size "$FGT_VM_SIZE" \
  --image "${FGT_IMAGE_PUBLISHER}:${FGT_IMAGE_OFFER}:${FGT_IMAGE_SKU}:${FGT_IMAGE_VERSION}" \
  --plan-name "$FGT_IMAGE_SKU" \
  --plan-publisher "$FGT_IMAGE_PUBLISHER" \
  --plan-product "$FGT_IMAGE_OFFER" \
  --admin-username "azureadmin" \
  --admin-password "$FGT_ADMIN_PW" \
  --authentication-type password \
  --nics "$FGT_UNTRUST_NIC" "$FGT_TRUST_NIC" \
  --os-disk-name "fgt-azure-osdisk" \
  --tags $TAG \
  --no-wait

# ─── Step 9: nginx VM ───────────────────────────────────────────────────────

section "Step 9: nginx VM"

# Create nginx NIC
run az network nic create \
  --resource-group "$RG" \
  --name "$NGINX_NIC_NAME" \
  --location "$LOCATION" \
  --vnet-name "$VNET_NAME" \
  --subnet "$SNET_WORKLOAD" \
  --private-ip-address "$NGINX_IP" \
  --network-security-group "$NSG_WORKLOAD" \
  --tags $TAG

# cloud-init to install nginx on first boot
CLOUD_INIT=$(cat <<'INIT'
#!/bin/bash
apt-get update -y
apt-get install -y nginx
echo "<h1>Azure Hybrid Lab - workload VM</h1><p>$(hostname) - $(date)</p>" > /var/www/html/index.html
systemctl enable nginx
INIT
)

CLOUD_INIT_FILE=$(mktemp /tmp/cloud-init-XXXXXX.sh)
echo "$CLOUD_INIT" > "$CLOUD_INIT_FILE"

run az vm create \
  --resource-group "$RG" \
  --name "$NGINX_VM_NAME" \
  --location "$LOCATION" \
  --size "$NGINX_VM_SIZE" \
  --image "$NGINX_IMAGE" \
  --admin-username "azureadmin" \
  --ssh-key-value "$SSH_PUB_KEY" \
  --authentication-type ssh \
  --nics "$NGINX_NIC_NAME" \
  --os-disk-name "nginx-osdisk" \
  --custom-data "$CLOUD_INIT_FILE" \
  --tags $TAG \
  --no-wait

rm -f "$CLOUD_INIT_FILE"

# ─── Done ────────────────────────────────────────────────────────────────────

section "Infrastructure deployment submitted"

echo ""
echo "Both VMs are deploying (--no-wait). Monitor with:"
echo "  az vm list -d -g $RG -o table"
echo ""
echo "Wait for both VMs to show 'VM running' before continuing."
echo ""
if [ "$DRY_RUN" -eq 0 ]; then
  echo "Azure FortiGate public IP: $AZURE_PIP"
  echo "FortiGate web GUI: https://$AZURE_PIP (azureadmin / <your password>)"
else
  echo "Azure FortiGate public IP: [dry-run — not yet allocated]"
fi
echo ""
echo "Next steps (see runbook.md Phase 3, steps 10-17):"
echo "  10. License FortiGate via web GUI"
echo "  11. Apply FortiGate base config (interfaces, static routes, admin access)"
echo "  12. Create firewall policies (trust ↔ tunnel)"
echo "  13. Verify nginx is serving (SSH from FortiGate trust NIC)"
echo "  14. Apply IPsec phase1/phase2 config (dynamic type)"
echo "  15. Apply BGP config (AS 65002)"
echo "  16. Update on-prem FortiGate remote-gw to $AZURE_PIP"
echo "  17. Bring up tunnel from on-prem; validate end-to-end"
echo ""
echo "When done for the day:  ./scripts/deallocate-lab.sh"
echo "Final teardown:         ./scripts/delete-lab.sh"

# Runbook

Operational procedures for the Azure Hybrid Network Lab. This file is a stub during Phase 0; sections fill in as each phase ships.

---

## Quick reference

### Daily-driver commands (Azure CLI)

```bash
# Stop all lab VMs (keeps definitions, no compute charge)
./scripts/deallocate-lab.sh

# Nuke the entire resource group (final teardown)
./scripts/delete-lab.sh

# Confirm zero ongoing cost (run after teardown)
az consumption usage list --start-date $(date -d '1 day ago' +%Y-%m-%d) --end-date $(date +%Y-%m-%d) -o table
```

### FortiGate IPsec / BGP diagnostics

```
diagnose vpn ike gateway list
diagnose vpn tunnel list
diagnose debug app ike -1
diagnose debug enable
get router info bgp summary
get router info bgp neighbors
get router info routing-table bgp
```

---

## Deploy procedures

### Phase 1 GNS3 deploy

_Filled in during Phase 1._

### Phase 3 Azure deploy

_Filled in during Phase 3. Step-by-step Azure CLI commands or portal click-paths. Order matters: resource group, VNet, subnets, NSGs, route tables (UDRs), public IP, FortiGate VM (BYOL), nginx VM, FortiGate base config, IPsec/BGP._

---

## Teardown procedures

### End-of-session deallocate

Runs `scripts/deallocate-lab.sh` against the `lab=hybrid-cloud` tag. VMs stop billing for compute; managed disks and public IP keep charging at low monthly rates.

### Final teardown (Phase 3f)

Runs `scripts/delete-lab.sh`. Deletes the entire `rg-hybrid-lab` resource group. Confirm $0/month projected in Cost Management before declaring shipped.

---

## Troubleshooting

### IPsec phase 1 fails to establish

_Filled in during Phase 1b. Common causes: PSK mismatch, IKE version mismatch, crypto proposal rejected by trial license (step down through the fallback ladder), ACL/NSG blocking UDP 500 or 4500, NAT-T not negotiated when behind NAT._

### IPsec phase 1 up but phase 2 fails

_Filled in during Phase 1b. Common causes: PFS mismatch, traffic selector mismatch, lifetime mismatch._

### BGP neighbor stuck in Idle / Active / Connect

_Filled in during Phase 1c. Common causes: tunnel not up, MD5 password mismatch, ASN typo, peer IP off by one, ACL on tunnel interface, network statement missing._

### Azure FortiGate cannot reach internet on untrust NIC

_Filled in during Phase 3b. Common causes: NSG blocking egress, public IP not associated, default route missing or wrong, FortiGate's expected gateway IP differs from Azure's first-IP-of-subnet convention._

### UDR not forcing traffic through FortiGate

_Filled in during Phase 3a. Validate via Azure Portal effective routes view; common causes: route table not associated to subnet, more-specific route exists, FortiGate trust NIC doesn't have IP forwarding enabled._

---

## License terms snapshot (for the case study)

Captured from FortiCare on the day the FortiGate VMs are first registered. Helps the case study explain why certain crypto fallbacks happened.

- IKE versions allowed: _TBD_
- Phase 1 ciphers allowed: _TBD_
- Phase 2 ciphers allowed: _TBD_
- Throughput cap: _TBD_
- Other gating: _TBD_

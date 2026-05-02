# Azure Side Paper Design

The Phase 2 deliverable. By the time this document is complete, deploying the Azure side in Phase 3 should be pure execution with no architectural decisions left to make.

**Status:** Stub. Filled in during Phase 2.

---

## 1. Region and resource group

- **Region:** _East US or South Central US (decided in Phase 2 based on FortiGate Marketplace availability)_
- **Resource group:** `rg-hybrid-lab`
- **Tag inheritance:** `lab=hybrid-cloud` applied at the RG level so every child resource inherits the tag for the deallocation script

## 2. IP scheme (Azure side)

| Segment | CIDR | Purpose |
|---|---|---|
| VNet | 10.100.0.0/16 | All Azure subnets live in here |
| Untrust subnet | 10.100.1.0/24 | FortiGate WAN NIC |
| Trust subnet | 10.100.2.0/24 | FortiGate LAN NIC |
| Workload subnet | 10.100.10.0/24 | nginx VM |

Specific private IPs:

| Resource | IP |
|---|---|
| FortiGate untrust NIC | 10.100.1.4 |
| FortiGate trust NIC | 10.100.2.4 |
| nginx VM NIC | 10.100.10.4 |

## 3. VM sizing

| VM | SKU | vCPU / RAM | NICs | Public IP |
|---|---|---|---|---|
| FortiGate (BYOL) | Standard_F2s_v2 | 2 / 4 GB | 2 (untrust + trust) | Yes (static, Standard SKU) |
| nginx workload | Standard_B1s | 1 / 1 GB | 1 (workload subnet) | No |

## 4. Public IP

- **SKU:** Standard
- **Allocation:** Static
- **Attached to:** FortiGate untrust NIC

## 5. NSGs

### Untrust subnet NSG

| Priority | Name | Source | Destination | Port | Protocol | Action |
|---|---|---|---|---|---|---|
| _TBD_ | allow-ipsec-isakmp | Internet | NSG | 500 | UDP | Allow |
| _TBD_ | allow-ipsec-natt | Internet | NSG | 4500 | UDP | Allow |
| _TBD_ | allow-icmp-build | Internet | NSG | * | ICMP | Allow (remove after Phase 3 validation) |
| _TBD_ | allow-mgmt | _trusted IP/32_ | NSG | 443 | TCP | Allow |
| _TBD_ | deny-all | * | * | * | * | Deny |

### Trust subnet NSG

| Priority | Name | Source | Destination | Port | Protocol | Action |
|---|---|---|---|---|---|---|
| _TBD_ | allow-vnet | VirtualNetwork | VirtualNetwork | * | * | Allow |
| _TBD_ | deny-internet | Internet | NSG | * | * | Deny |

### Workload subnet NSG

| Priority | Name | Source | Destination | Port | Protocol | Action |
|---|---|---|---|---|---|---|
| _TBD_ | allow-onprem-http | 192.168.10.0/24 | 10.100.10.0/24 | 80 | TCP | Allow |
| _TBD_ | allow-fgt-ssh | 10.100.2.4/32 | 10.100.10.0/24 | 22 | TCP | Allow |
| _TBD_ | deny-all | * | * | * | * | Deny |

## 6. UDRs

### Workload subnet route table

| Name | Address prefix | Next hop type | Next hop IP |
|---|---|---|---|
| force-egress-fgt | 0.0.0.0/0 | Virtual appliance | 10.100.2.4 |
| force-onprem-fgt | 192.168.10.0/24 | Virtual appliance | 10.100.2.4 |

> Reminder: FortiGate trust NIC must have IP forwarding enabled at the NIC level in Azure or UDRs will silently drop traffic.

## 7. Public-IP / private-IP awareness on Azure FortiGate

_Filled in during Phase 2 from Fortinet's published Azure deployment guide. Key points to capture:_

- _How FortiGate sees its untrust NIC's IP (private inside, NAT'd to public outside)_
- _Default gateway behavior on Azure subnets (first usable IP, e.g., 10.100.1.1)_
- _What value goes into the IPsec local-gateway field (private IP, public IP, or 0.0.0.0?)_
- _NAT-T behavior_

## 8. Deployment order

The order Phase 3 will execute:

1. Resource group + tag
2. VNet
3. Subnets (untrust, trust, workload)
4. NSGs (associate to subnets)
5. Route table (associate to workload subnet)
6. Public IP
7. FortiGate VM (Marketplace, BYOL, both NICs at deploy time)
8. nginx VM
9. FortiGate base config (interfaces, default route, admin access, three policies)
10. nginx install + test page
11. IPsec + BGP config (mirror Phase 1 with Azure-specific adjustments)
12. End-to-end traffic test
13. Capture all artifacts
14. Deallocate / delete

## 9. Cost estimate

| Item | Approx. monthly | Approx. weekly | Notes |
|---|---|---|---|
| FortiGate VM (Standard_F2s_v2) | ~$70/mo | ~$16/wk | Compute, while running |
| nginx VM (Standard_B1s) | ~$8/mo | ~$2/wk | Compute, while running |
| Managed disks | ~$5/mo | ~$1/wk | Charged even when deallocated |
| Public IP (Standard, static) | ~$4/mo | ~$1/wk | Charged whether attached or not |
| Bandwidth | _TBD_ | _TBD_ | Inbound free; outbound first 100 GB free, then ~$0.087/GB |

**Target total Phase 3 spend:** under $60 against the $200 / 30-day trial credit.

**Discipline:**

- Deallocate at end of every session (`scripts/deallocate-lab.sh`)
- Phase 3 time-boxed to 1 week
- $25 budget alert (configured in Phase 0)

## 10. Reference

- Fortinet's Azure Marketplace BYOL deployment guide: _link captured during Phase 2_
- Azure VPN Gateway pricing (for the case study comparison): _link captured_

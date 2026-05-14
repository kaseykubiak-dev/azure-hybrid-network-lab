# Azure Side Paper Design

The Phase 2 deliverable. By the time this document is complete, deploying the Azure side in Phase 3 should be pure execution with no architectural decisions left to make.

**Status:** Complete. Phase 3 should be pure execution — no architectural decisions remain.

---

## 1. Region and resource group

- **Region:** East US 2 (FortiGate BYOL available; F-series x86 capacity available — East US had only ARM64/DC-series SKUs during deployment)
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

### Untrust subnet NSG (`nsg-untrust`)

| Priority | Name | Direction | Source | Destination | Port | Protocol | Action |
|---|---|---|---|---|---|---|---|
| 100 | allow-ipsec-isakmp | Inbound | Internet | 10.100.1.4/32 | 500 | UDP | Allow |
| 110 | allow-ipsec-natt | Inbound | Internet | 10.100.1.4/32 | 4500 | UDP | Allow |
| 120 | allow-icmp-build | Inbound | Internet | 10.100.1.0/24 | * | ICMP | Allow _(remove after Phase 3 validation)_ |
| 200 | allow-mgmt | Inbound | _home-WAN-IP/32_ | 10.100.1.4/32 | 443 | TCP | Allow |
| 4096 | deny-all-inbound | Inbound | * | * | * | * | Deny |

> **Note:** Replace `_home-WAN-IP/32_` with the actual WAN IP of the Fedora workstation at deploy time. Confirm with `curl -4 ifconfig.me` before creating the rule. If the ISP rotates the IP mid-session, update priority 200.

### Trust subnet NSG (`nsg-trust`)

| Priority | Name | Direction | Source | Destination | Port | Protocol | Action |
|---|---|---|---|---|---|---|---|
| 100 | allow-vnet | Inbound | VirtualNetwork | VirtualNetwork | * | * | Allow |
| 4096 | deny-all-inbound | Inbound | * | * | * | * | Deny |
| 100 | allow-forwarded-out | Outbound | 10.255.255.0/24, 192.168.10.0/24 | 10.100.10.0/24 | * | * | Allow |

> **Critical:** The outbound rule is required because tunnel-sourced traffic (source `10.255.255.x`) does not match the `VirtualNetwork` service tag. Without this rule, Azure's default `AllowVnetOutBound` drops forwarded packets from the IPsec tunnel to the workload subnet.

### Workload subnet NSG (`nsg-workload`)

| Priority | Name | Direction | Source | Destination | Port | Protocol | Action |
|---|---|---|---|---|---|---|---|
| 100 | allow-onprem-http | Inbound | 192.168.10.0/24 | 10.100.10.0/24 | 80 | TCP | Allow |
| 105 | allow-tunnel-in | Inbound | 10.255.255.0/24, 192.168.10.0/24 | 10.100.10.0/24 | * | * | Allow |
| 110 | allow-fgt-ssh | Inbound | 10.100.2.4/32 | 10.100.10.0/24 | 22 | TCP | Allow |
| 120 | allow-icmp-diag | Inbound | 10.100.2.0/24 | 10.100.10.0/24 | * | ICMP | Allow |
| 4096 | deny-all-inbound | Inbound | * | * | * | * | Deny |

## 6. UDRs

### Workload subnet route table (`rt-workload`)

| Name | Address prefix | Next hop type | Next hop IP |
|---|---|---|---|
| force-default-fgt | 0.0.0.0/0 | Virtual appliance | 10.100.2.4 |
| force-onprem-fgt | 192.168.10.0/24 | Virtual appliance | 10.100.2.4 |
| force-tunnel-fgt | 10.255.255.0/24 | Virtual appliance | 10.100.2.4 |
| local-workload | 10.100.10.0/24 | VirtualNetwork | — |

> **Why `local-workload`?** Without it, Azure applies the UDR's 0.0.0.0/0 → FortiGate catch-all to intra-subnet traffic too, causing microsegmentation (VM-to-VM traffic in the workload subnet routes through the FortiGate unnecessarily). The explicit VNet route keeps local traffic on the fabric.
>
> **Reminder:** FortiGate trust NIC **and** untrust NIC must both have IP forwarding enabled at the Azure NIC level or UDRs will silently drop traffic (see Section 7).

## 7. Public-IP / private-IP awareness on Azure FortiGate

### How FortiGate sees its untrust NIC

The Azure FortiGate's port1 (untrust) NIC is assigned private IP **10.100.1.4**. Azure associates a Standard public IP to this NIC, but the public IP is invisible to the VM — Azure's fabric performs 1:1 static NAT at the platform level. Inside FortiOS, `get system interface` will only ever show `10.100.1.4`; the public IP never appears in the FortiGate's configuration.

This means: any FortiGate setting that asks for "this device's IP" gets the **private** IP (10.100.1.4), not the public IP. The on-prem side, by contrast, uses the **public** IP as `remote-gw` when pointing at the Azure FortiGate.

### Default gateway behavior

Azure's default gateway for any subnet is always the **first usable IP** in the subnet range. For the untrust subnet (10.100.1.0/24), that gateway is **10.100.1.1**. For the trust subnet (10.100.2.0/24), it is **10.100.2.1**.

This gateway is not a visible VM or appliance — it is an Azure fabric construct. FortiGate's static default route must point at it:

```
config router static
    edit 1
        set gateway 10.100.1.1
        set device "port1"
    next
end
```

### Azure health-probe IP (168.63.129.16)

Azure uses 168.63.129.16 for load-balancer health probes, DHCP, DNS, and instance metadata. Even though this lab does not use a load balancer, Azure VM extensions and licensing checks require reachability to this IP. Add a static route so this traffic egresses via port1 (it is already reachable via the Azure fabric on any NIC, but the explicit route prevents routing loops if a UDR catches it):

```
config router static
    edit 2
        set dst 168.63.129.16 255.255.255.255
        set gateway 10.100.1.1
        set device "port1"
    next
    edit 3
        set dst 10.100.10.0 255.255.255.0
        set gateway 10.100.2.1
        set device "port2"
    next
end
```

> **Why route 3?** In Phase 1, port2 sat directly on 10.100.10.0/24, so the workload subnet was a connected route. In Phase 3, port2 is on the trust subnet (10.100.2.0/24). Without this static route, FortiGate has no path to the workload subnet and BGP cannot advertise the `network 10.100.10.0/24` prefix to the on-prem peer.

### IPsec local-gateway field

Because FortiGate only sees its private IP, the IPsec phase1-interface **does not set `local-gw`** — leaving it at the default (0.0.0.0) tells FortiOS to use the outgoing interface's IP (10.100.1.4) as the IKE local identity. Azure's NAT translates this to the public IP in transit.

The on-prem FortiGate's `remote-gw` is set to the Azure **public IP** (captured after the public IP resource is created in Phase 3).

### NAT-T behavior

Because the Azure FortiGate sits behind platform-level NAT (private IP 10.100.1.4 ↔ public IP), IKE will detect NAT during the IKEv2 exchange and automatically float from UDP/500 to UDP/4500 (NAT-Traversal). No explicit `set nattraversal` is needed — IKEv2 handles NAT-T natively. Both UDP/500 and UDP/4500 must be open in the untrust NSG (covered in Section 5).

### IPsec phase1 topology change from Phase 1

In Phase 1 (GNS3), both FortiGates used `set type static` with explicit `remote-gw` pointing at each other's WAN IP. In Phase 3, the Azure-side FortiGate changes to **`set type dynamic`** (dial-up responder mode) per Fortinet's Azure deployment guide. This is the recommended pattern when the responder sits behind Azure NAT:

- **Azure FGT** — `set type dynamic`, no `remote-gw`. Accepts inbound IKE from any peer that presents the correct PSK.
- **On-prem FGT** — keeps `set type static` with `set remote-gw <Azure-public-IP>`. It is the initiator.

The tunnel only comes up when the **on-prem side initiates**. If the tunnel drops, the on-prem FortiGate's DPD (dead peer detection) will re-initiate automatically.

### IP forwarding (Azure NIC setting)

The FortiGate trust NIC (10.100.2.4) **must have IP forwarding enabled** at the Azure NIC level. Without this, Azure's fabric silently drops any packet where the destination IP does not match the NIC's own IP — which means all transit/routed traffic through the FortiGate would be black-holed. This is set during NIC creation or via:

```bash
az network nic update --name fgt-trust-nic --resource-group rg-hybrid-lab --ip-forwarding true
```

The untrust NIC (10.100.1.4) also needs IP forwarding enabled for return traffic from the tunnel.

## 8. IPsec / BGP config delta from Phase 1

This section captures every change from the Phase 1 GNS3 configs (`configs/phase1/`) when moving to a real Azure deployment. Anything not listed here stays the same.

### Azure-side FortiGate (replaces `fgt-azure.conf`)

| Setting | Phase 1 (GNS3) | Phase 3 (Azure) | Why |
|---|---|---|---|
| port1 IP | 198.51.100.2/30 | 10.100.1.4/24 | Azure assigns private IP; public IP is NAT'd by the platform |
| port2 IP | 10.100.10.1/24 | 10.100.2.4/24 | Trust subnet, not workload subnet (workload is a separate subnet behind UDR) |
| Default route gateway | 198.51.100.1 | 10.100.1.1 | Azure fabric gateway = first IP in subnet |
| phase1 `set type` | (implicit static) | `set type dynamic` | Azure FGT is the dial-up responder behind NAT |
| phase1 `set remote-gw` | 203.0.113.1 | _(not set)_ | Dynamic type accepts any initiator with correct PSK |
| phase1 `set net-device` | `disable` | `enable` | Fortinet recommends `enable` for Azure NVA deployments |
| phase1 `set proposal` | `des-sha256` | `des-sha256` _(upgrade if license allows)_ | Trial/eval license may still restrict to DES; test AES-128 during Phase 3 |
| tunnel interface | `to-onprem` 10.255.255.2/32 | Same | No change |
| BGP config | AS 65002, neighbor 10.255.255.1 | Same | No change — BGP peers over tunnel IPs, not physical IPs |
| Firewall policies | 2 policies (LAN↔tunnel) | Same pattern, adjusted interface names | port2 = trust; tunnel = `to-onprem` |
| Static route: Azure svc | — | 168.63.129.16/32 → 10.100.1.1 via port1 | Azure service IP (see Section 7) |
| Static route: workload | — | 10.100.10.0/24 → 10.100.2.1 via port2 | FGT needs this route so BGP can advertise 10.100.10.0/24; in Phase 1 port2 was directly on the workload subnet, now it is on the trust subnet |
| Port3 | DHCP, status down | Does not exist (2-NIC deployment) | Azure BYOL deploys with exactly 2 NICs |

### On-prem FortiGate (updates to `fgt-onprem.conf`)

| Setting | Phase 1 (GNS3) | Phase 3 (real) | Why |
|---|---|---|---|
| phase1 `set remote-gw` | 198.51.100.2 | `<Azure-public-IP>` | Real Azure public IP, captured after deployment |
| Everything else | Unchanged | Unchanged | On-prem config is stable; only the remote gateway IP changes |

> **Crypto upgrade note:** If the Azure Marketplace BYOL license unlocks AES ciphers (check `diagnose vpn ike config` after licensing), upgrade both sides from `des-sha256` to `aes128-sha256` and both `dhgrp` from `14` to `14 5` during Phase 3. The Phase 1 DES-only restriction came from the GNS3 evaluation license; the Azure BYOL license tier may differ.

## 9. Deployment order

The order Phase 3 will execute:

1. Resource group `rg-hybrid-lab` + tag `lab=hybrid-cloud`
2. VNet `vnet-hybrid-lab` (10.100.0.0/16)
3. Subnets: `snet-untrust`, `snet-trust`, `snet-workload`
4. NSGs: `nsg-untrust`, `nsg-trust`, `nsg-workload` → associate to subnets
5. Route table `rt-workload` → associate to `snet-workload`
6. Public IP `pip-fgt-untrust` (Standard, static)
7. FortiGate NICs: `fgt-untrust-nic` (IP forwarding ON) + `fgt-trust-nic` (IP forwarding ON)
8. FortiGate VM `fgt-azure` (Marketplace BYOL, Standard_F2s_v2, attach both NICs at deploy time)
9. nginx VM `vm-nginx` (Standard_B1s, in `snet-workload`, no public IP)
10. FortiGate licensing (web GUI → FortiGuard → activate BYOL trial)
11. FortiGate base config: interfaces, static routes (default + 168.63.129.16 + 10.100.10.0/24 via trust gateway), admin access on port1 :443
12. FortiGate firewall policies: trust↔tunnel (2 policies)
13. nginx install + test page (`sudo apt update && sudo apt install -y nginx`)
14. IPsec phase1/phase2 config on Azure FGT (dynamic type, per Section 8 delta table)
15. BGP config on Azure FGT (AS 65002, neighbor 10.255.255.1, same as Phase 1)
16. Update on-prem FGT `remote-gw` to the Azure public IP
17. Bring up tunnel from on-prem side; validate IKE, phase2, BGP, end-to-end curl
18. Capture all artifacts (configs, screenshots, `show` output)
19. Deallocate (`scripts/deallocate-lab.sh`) or delete (`scripts/delete-lab.sh`)

## 10. Cost estimate

| Item | Approx. monthly | Approx. weekly | Notes |
|---|---|---|---|
| FortiGate VM (Standard_F2s_v2) | ~$70/mo | ~$16/wk | Compute, while running |
| nginx VM (Standard_B1s) | ~$8/mo | ~$2/wk | Compute, while running |
| Managed disks | ~$5/mo | ~$1/wk | Charged even when deallocated |
| Public IP (Standard, static) | ~$4/mo | ~$1/wk | Charged whether attached or not |
| Bandwidth | ~$0 | ~$0 | Inbound free; outbound first 100 GB/mo free; lab traffic is negligible |

**Target total Phase 3 spend:** under $60 against the $200 / 30-day trial credit.

**Discipline:**

- Deallocate at end of every session (`scripts/deallocate-lab.sh`)
- Phase 3 time-boxed to 1 week
- $25 budget alert (configured in Phase 0)

## 11. Reference

- [Fortinet FortiGate Azure Administration Guide (FortiOS 7.6)](https://docs.fortinet.com/document/fortigate-public-cloud/7.6.0/azure-administration-guide/609353/azure-routing-and-network-interfaces) — Azure routing, NIC behavior, default gateway conventions
- [Connecting a local FortiGate to an Azure FortiGate via site-to-site VPN (FortiOS 7.6)](https://docs.fortinet.com/document/fortigate-public-cloud/7.6.0/azure-administration-guide/30680/connecting-a-local-fortigate-to-an-azure-fortigate-via-site-to-site-vpn) — The reference config this lab's IPsec/BGP design is based on
- [Fortinet FortiGate NGFW — Azure Marketplace listing](https://azuremarketplace.microsoft.com/en-us/marketplace/apps/fortinet.fortinet-fortigate?tab=overview) — BYOL plan selection
- [Azure VPN Gateway pricing](https://azure.microsoft.com/en-us/pricing/details/vpn-gateway/) — For the case study cost comparison (~$140/mo for VpnGw1 vs. ~$70/mo compute for FortiGate NVA on Standard_F2s_v2)

---

## Implementation Log

### 2026-05-14 — Phase 2 complete: Azure paper design finalized

**Research (Section 7 foundation):**
- Source: Fortinet FortiGate Public Cloud 7.6 Azure Administration Guide — specifically the S2S VPN page and the Azure routing/network interfaces page.
- Key finding 1: Azure FortiGate's untrust NIC only sees its private IP (10.100.1.4). Azure performs invisible 1:1 static NAT at the platform/fabric level — the public IP never appears inside FortiOS.
- Key finding 2: Fortinet's reference config uses `set type dynamic` (dial-up responder / `wizard-type dialup-fortigate`) on the Azure-side phase1-interface, not static with `remote-gw`. The on-prem side is the initiator.
- Key finding 3: Azure's default gateway is always the first IP in the subnet range (.1). This is a fabric construct, not a visible VM.
- Key finding 4: 168.63.129.16 is Azure's internal service IP (health probes, metadata, licensing). Needs an explicit static route via port1 to prevent UDR catch-all from misrouting it.

**Sections written/completed:**
- Section 1: Region locked to East US (BYOL available, cheapest F-series, lowest latency from East TN).
- Section 5 (NSGs): All three NSGs have concrete priorities (100/110/120/200/4096 pattern), added Direction column, added ICMP diagnostic rule to workload NSG, added note about swapping home WAN IP at deploy time.
- Section 6 (UDRs): Added `local-workload` VNet route (10.100.10.0/24 → VirtualNetwork) to prevent Azure microsegmentation — without it, the 0.0.0.0/0 catch-all forces intra-subnet traffic through the FGT unnecessarily. Added IP forwarding reminder for both NICs.
- Section 7 (Public-IP / private-IP awareness): Six subsections — untrust NIC visibility, default gateway behavior, 168.63.129.16 route, IPsec local-gateway field (stays 0.0.0.0), NAT-T (auto on IKEv2, no explicit config), phase1 topology change (dynamic vs static), IP forwarding requirement.
- Section 8 (new — IPsec/BGP config delta): Side-by-side table for every setting that changes from Phase 1 GNS3 to Phase 3 Azure, for both Azure-side and on-prem FortiGates.
- Section 9 (Deployment order): Expanded from 14 generic steps to 19 steps with exact resource names (`rg-hybrid-lab`, `vnet-hybrid-lab`, `snet-untrust`, `pip-fgt-untrust`, `fgt-untrust-nic`, etc.) and explicit licensing step.
- Section 10 (Cost estimate): Replaced bandwidth TBD with ~$0 (lab traffic negligible, under free tier).
- Section 11 (References): Four concrete URLs — Fortinet Azure admin guide, S2S VPN guide, Marketplace listing, VPN Gateway pricing.

**Critical subtlety caught:**
- In Phase 1, the Azure FGT's port2 was directly on the workload subnet (10.100.10.0/24), making it a connected route that BGP could advertise. In Phase 3, port2 moves to the trust subnet (10.100.2.0/24). Without a static route `10.100.10.0/24 → 10.100.2.1 via port2`, FortiGate has no path to the workload subnet and BGP's `network 10.100.10.0/24` statement silently fails to advertise.

**Crypto note deferred to Phase 3:**
- Phase 1 used `des-sha256` due to GNS3 evaluation license restrictions. Azure Marketplace BYOL may unlock AES ciphers — test `diagnose vpn ike config` after licensing and upgrade to `aes128-sha256` if available. Both sides must match.

**README:** Status bumped from "Phase 0 (pre-flight)" to "Phase 2 complete."

- Next steps: Phase 3 — real Azure deployment. Generate az CLI deployment script, execute the 19-step deployment order, validate end-to-end, capture artifacts.

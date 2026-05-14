# Azure Hybrid Network Lab

A site-to-site IPsec/IKEv2 VPN with eBGP between an on-prem GNS3 environment and a real Azure VNet, using FortiGate firewalls at both ends. On-prem clients reach an Azure-hosted nginx workload by private IP through the tunnel; routes are exchanged dynamically via BGP, not static routes.

**Status:** All phases complete. Real Azure deployment validated end-to-end over the internet.

---

## What this proves

The short version: an on-prem Alpine Linux client runs `wget http://10.100.10.4` and gets an HTTP 200 back from an nginx VM sitting in an Azure VNet, routed entirely over an IPsec tunnel with BGP handling the route exchange. No static routes for the remote subnets on either side; BGP learns them dynamically.

More specifically:

1. **IPsec site-to-site VPN over the real internet** between FortiGate on-prem (GNS3, AS 65001) and FortiGate in Azure (Marketplace BYOL, AS 65002), using IKEv2 with NAT-T auto-negotiation
2. **eBGP dynamic routing** across the tunnel, each side advertising its local subnet and learning the remote subnet automatically
3. **Azure network design** including VNet segmentation, NSGs scoped to required flows, UDRs forcing workload traffic through the FortiGate NVA, and the platform-level NAT behavior that trips up most first-time Azure NVA deployments

Both VPN endpoints are FortiGate rather than Azure VPN Gateway. This skips the ~$140/month VPN Gateway charge, gives full CLI access on both sides, and keeps policy and routing directly comparable between sites. Trade-off: no SLA, no managed HA, manual everything.

## Topology

```
  ON-PREM (GNS3 on Fedora, AS 65001)              AZURE (East US 2, AS 65002)
 +-----------------------------------------+      +------------------------------------------+
 |                                         |      |                                          |
 |  +-----------+       +---------------+  |      |  +---------------+       +-------------+ |
 |  |  Alpine   |       |  FortiGate    |  |      |  |  FortiGate    |       |  nginx VM   | |
 |  |  client   +--LAN--+  (on-prem)    |  |      |  |  (Azure)     +--trust--+ 10.100.10.4| |
 |  |192.168.   |       |  10.255.255.1 |  |      |  |  10.255.255.2|       |  HTTP :80   | |
 |  | 10.100    |       +-------+-------+  |      |  +-------+------+       +-------------+ |
 |  +-----------+               |          |      |           |                              |
 |                              | WAN      |      |           | untrust                     |
 |                        +-----+------+   |      |     +-----+------+                      |
 |                        |  R1 (ISP)  |   |      |     | Azure      |                      |
 |                        |  NAT/PAT   |   |      |     | public IP  |                      |
 |                        +-----+------+   |      |     | 20.122.    |                      |
 |                              |          |      |     |  29.13     |                      |
 +-----------------------------------------+      |     +------------+                      |
                                |                 |                                          |
                     ~~~~ real internet ~~~~       +------------------------------------------+
                                |                           |
                                +---------------------------+
                                   IPsec IKEv2 tunnel
                                   eBGP peering over tunnel
```

Full SVG diagrams for the case study are in `diagrams/`.

## Key technical decisions

**Dial-up responder on Azure side.** The Azure FortiGate uses `set type dynamic` (dial-up responder mode) because it sits behind Azure's platform-level NAT. The on-prem FortiGate is the initiator with `set remote-gw <Azure-public-IP>`. This is Fortinet's recommended pattern for Azure NVA deployments, and it caught me off guard the first time since both sides used `set type static` in the GNS3 build.

**DES-only crypto (trial license constraint).** The FortiGate trial/evaluation license restricts available ciphers to DES variants only. This lab uses `des-sha256` (DES for encryption, SHA-256 for integrity). Production would use AES-256-GCM with DH group 19 or 20. The tunnel architecture, IKEv2 negotiation, BGP peering, and route exchange are all identical regardless of the cipher; the only thing that changes is the encryption strength.

**eBGP over tunnel interfaces, not loopbacks.** Single-tunnel design; loopback peering would be overkill here but is the right pattern for SD-WAN or multi-tunnel setups.

## IP scheme

| Segment | CIDR | Notes |
|---|---|---|
| On-prem LAN | 192.168.10.0/24 | Alpine client at .100 |
| On-prem WAN | 203.0.113.0/30 | RFC 5737 documentation prefix (lab-public) |
| Tunnel interfaces | 10.255.255.1, .2 (/32) | BGP peering addresses |
| Azure VNet | 10.100.0.0/16 | |
| Azure untrust subnet | 10.100.1.0/24 | FortiGate WAN NIC (10.100.1.4) |
| Azure trust subnet | 10.100.2.0/24 | FortiGate LAN NIC (10.100.2.4) |
| Azure workload subnet | 10.100.10.0/24 | nginx VM (10.100.10.4) |

## BGP

| Side | AS | Router ID | Peer | Advertises | Auth |
|---|---|---|---|---|---|
| On-prem | 65001 | 10.255.255.1 | 10.255.255.2 | 192.168.10.0/24 | MD5 |
| Azure | 65002 | 10.255.255.2 | 10.255.255.1 | 10.100.10.0/24 | MD5 |

## Azure-side design highlights

The full Azure paper design is in [`docs/azure-design.md`](docs/azure-design.md). A few things that are easy to get wrong:

**NSG and the `VirtualNetwork` service tag.** This was the biggest "gotcha" of the build. Azure's `VirtualNetwork` service tag does NOT include non-VNet addresses like tunnel IPs (10.255.255.0/24) or on-prem subnets (192.168.10.0/24). The default `AllowVnetOutBound` outbound rule silently drops forwarded packets from the IPsec tunnel. You need explicit outbound NSG rules on the trust subnet and inbound rules on the workload subnet for tunnel-sourced traffic. Without them, packets leave the FortiGate's trust interface and just disappear.

**UDR for workload subnet.** `0.0.0.0/0 -> FortiGate trust NIC` forces all egress through the NVA. Additional entries for 192.168.10.0/24 and 10.255.255.0/24 handle tunnel-bound return traffic. One easy miss: add a `VirtualNetwork` route for the workload subnet itself (10.100.10.0/24), otherwise intra-subnet traffic gets forced through the FortiGate for no reason.

**Platform NAT awareness.** The Azure FortiGate only sees its private IP (10.100.1.4); Azure does invisible 1:1 static NAT at the fabric level. The on-prem side uses the public IP as `remote-gw`, while the Azure side leaves `local-gw` at 0.0.0.0 and uses `set type dynamic`.

## Repo layout

| Path | Purpose |
|---|---|
| `README.md` | This file |
| `docs/azure-design.md` | Azure-side paper design (NSGs, UDRs, IP scheme, deployment order, cost estimate) |
| `runbook.md` | Deploy/teardown procedures, troubleshooting (14 sections covering IPsec, BGP, NSG, licensing) |
| `configs/phase1/` | Sanitized FortiGate configs from the GNS3 end-to-end build |
| `configs/phase3/` | Sanitized configs from the real Azure deployment (FortiGate on-prem, FortiGate Azure, R1 ISP) |
| `scripts/deploy-lab.sh` | Full Azure deployment script (az CLI) |
| `scripts/deallocate-lab.sh` | Tag-based VM deallocation for cost control |
| `scripts/delete-lab.sh` | Resource group teardown (confirmation required) |
| `diagrams/` | Topology and traffic-flow SVG diagrams |
| `screenshots/` | CLI output, Azure portal captures, demo validation |

## Reproduction guide

### Prerequisites

- GNS3 with KVM acceleration (Fedora/Linux recommended)
- FortiGate VM 7.6.x QEMU/KVM image (download from [support.fortinet.com](https://support.fortinet.com))
- Cisco c3725 IOS image (or any router capable of NAT overload)
- Alpine Linux virt ISO
- Azure subscription (Pay-As-You-Go; free trial blocks most VM SKUs)
- Azure CLI (`az`) installed and authenticated
- FortiCare account for FortiGate evaluation licensing

### Phase 1: GNS3 end-to-end (no Azure cost)

Build the GNS3 topology with two FortiGates and a transit router between them. Configure IPsec (IKEv2, `des-sha256`, DH14) and eBGP (AS 65001/65002). Validate with ping across tunnel interfaces and HTTP from client to server. Full configs are in `configs/phase1/`. This phase is entirely local, no Azure spend.

### Phase 3: Real Azure deployment

1. Read through `docs/azure-design.md` for the complete Azure-side design (NSGs, UDRs, IP scheme, gotchas)
2. Run `scripts/deploy-lab.sh` (creates RG, VNet, subnets, NSGs, UDRs, VMs)
3. Configure the Azure FortiGate via serial console (the trial license's DES-only crypto breaks browser TLS, so the web GUI is unusable). Paste config blocks from `configs/phase3/fgt-azure.conf`
4. Reconfigure R1 ISP router for real internet: NAT overload, DHCP on the outside interface. See `configs/phase3/r1-isp.conf`
5. Update on-prem FortiGate `remote-gw` to the Azure public IP. See `configs/phase3/fgt-onprem.conf`
6. Validate: `diagnose vpn ike gateway list`, `get router info bgp summary`, `wget http://10.100.10.4`
7. Deallocate when done: `scripts/deallocate-lab.sh` or `scripts/delete-lab.sh`

### Troubleshooting

The [`runbook.md`](runbook.md) has 14 troubleshooting sections. These are the ones that cost me the most time:

- NSG blocking tunnel-sourced traffic (the `VirtualNetwork` service tag issue described above)
- UDR default route blocking workload VM internet access (cloud-init, apt-get both fail silently)
- FortiGate trial license crypto restrictions and web GUI inaccessibility
- Azure free trial subscription blocking most VM SKUs (requires upgrade to Pay-As-You-Go)
- Gen1/Gen2 image mismatch (FortiGate default marketplace image is Gen1; current Azure VM SKUs are Gen2-only)
- IKE transport mismatch after FortiGate reboot (defaults to TCP/443 when internet is reachable)
- Port3 DHCP route (distance 5) overriding the static default route (distance 10)

## Cost

The real Azure deployment ran for approximately one session day within the $200/30-day trial credit. Estimated costs:

| Resource | Rate | Notes |
|---|---|---|
| FortiGate VM (Standard_F1alds_v7) | ~$35/month | 1 vCPU, 2 GB (trial license limit) |
| nginx VM (Standard_D2als_v7) | ~$45/month | |
| Managed disks | ~$5/month | Charged even when deallocated |
| Public IP (Standard, static) | ~$4/month | |
| Bandwidth | ~$0 | Lab traffic negligible |

Total actual spend came in well under the $60 target. A $25 budget alert and the tag-based deallocation scripts kept things honest.

## Related projects

- [Multi-Vendor Firewall Lab](https://kaseykubiak.com/portfolio/multi-vendor-firewall) (FortiGate, pfSense, ASAv comparative security lab; this project builds on the same GNS3 environment)
- Case study page on kaseykubiak.com (coming soon)

## License

MIT

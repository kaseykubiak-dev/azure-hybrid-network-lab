# Azure Hybrid Network Lab

A site-to-site IPsec/IKEv2 VPN with eBGP between an on-prem GNS3 environment and a real Azure VNet, demonstrating hybrid cloud network design end-to-end on FortiGate at both ends.

**Status:** Phase 0 (pre-flight). Implementation has not started.

---

## What this is

This lab connects an on-prem network (GNS3 on a Fedora workstation) to a real Azure VNet over IPsec, exchanges routes between the two sides via eBGP, and proves end-to-end private connectivity by having an on-prem client reach an Azure-hosted nginx workload by private IP.

Both VPN endpoints are FortiGate (on-prem and in Azure). The Azure side is deployed from the Marketplace BYOL listing and trial-licensed; this avoids the recurring Azure VPN Gateway charge and lets the lab demonstrate two-sided FortiGate configuration.

It is the second portfolio project after the [Multi-Vendor Firewall Lab](https://kaseykubiak.com/portfolio/multi-vendor-firewall), built specifically to give the AZ-900 and Security+ certifications a tangible artifact.

## Topology summary

```
On-prem (GNS3, AS 65001)             Azure (single region, AS 65002)
+-----------------+                   +-----------------+
| Tiny Linux      |                   | nginx VM        |
| client          |                   | (private IP)    |
+--------+--------+                   +--------+--------+
         | LAN                                 | trust
+--------+--------+   IPsec/IKEv2 + eBGP   +---+--------+
| FortiGate       |<----------------------> | FortiGate  |
| (on-prem)       |                         | (Azure)    |
+-----------------+                         +-----+------+
                                                  | untrust
                                            +-----+------+
                                            | Azure       |
                                            | public IP   |
                                            +-------------+
```

Full diagrams live in `diagrams/` and the case study (link added once published).

## Repo layout

| Path | Purpose |
|---|---|
| `README.md` | This file |
| `docs/azure-design.md` | Phase 2 paper design for the Azure side |
| `runbook.md` | Deploy and teardown procedures, troubleshooting commands |
| `configs/phase1/` | Sanitized FortiGate configs from the GNS3 end-to-end build |
| `configs/phase3/` | Sanitized FortiGate configs from the real Azure build |
| `scripts/` | Tag-based deallocation and teardown scripts |
| `diagrams/` | Topology and traffic-flow diagrams |
| `screenshots/` | CLI output, dashboards, demo captures |

## Phases

The full plan lives in the design doc. High-level:

- **Phase 0** Pre-flight (accounts, budget alert, deallocation script, GitHub stub)
- **Phase 1** GNS3 end-to-end (two FortiGates, transit IOSv, IPsec up, BGP up, demo curl)
- **Phase 2** Paper Azure design (`docs/azure-design.md`)
- **Phase 3** Real Azure deployment (1-week time-box, ~$60 cap)
- **Phase 4** Documentation, case study, teardown
- **Phase 5** Bicep IaC (stretch, may not ship)

## Cost guardrails

- Azure budget alert set at $25 before any deployment
- Tag-based deallocation script (`scripts/deallocate-lab.sh`) runs at the end of every session
- Real-Azure phase is time-boxed to one week
- Total target spend: under $60 against the $200 / 30-day trial credit

## Reproduction

Reproduction instructions land in `runbook.md` and `docs/azure-design.md` once Phase 2 and Phase 3 are complete.

## License

TBD. Likely MIT.

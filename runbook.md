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
diagnose debug app ike 0
diagnose debug disable
get router info bgp summary
get router info bgp neighbors
get router info routing-table bgp
get router info routing-table all
```

---

## Deploy procedures

### Phase 1 GNS3 deploy

GNS3 project: `azure-hybrid-lab`. Five nodes, wired as described in the design doc topology.

#### Step 1 — Start nodes in order

Start ISP (c3725) first. Wait for the idle-PC prompt to clear before starting FortiGates.
FortiGate boot takes ~2 minutes. VPCS/Alpine nodes can start any time.

**c3725 RAM note:** Must be set to 256MB. Higher values break idle-PC calculation and freeze the router.

#### Step 2 — ISP router config

```
conf t
interface FastEthernet0/0
 ip address 203.0.113.2 255.255.255.252
 no shutdown
interface FastEthernet0/1
 ip address 198.51.100.1 255.255.255.252
 no shutdown
end
write memory
```

#### Step 3 — FGT-OnPrem base config

Default login: `admin` / no password. Set a password on first login.

Apply in order — interfaces, default route, IPsec, tunnel interface, firewall policies, BGP.
See `configs/phase1/fgt-onprem.conf` for the complete config.

Key values:
- port1 (WAN): 203.0.113.1/30
- port2 (LAN): 192.168.10.1/24
- Default route: 0.0.0.0/0 via 203.0.113.2 on port1
- Tunnel interface `to-azure`: 10.255.255.1/32, remote-ip 10.255.255.2/32
- BGP AS: 65001, neighbor 10.255.255.2, update-source to-azure

#### Step 4 — FGT-Azure base config

Apply mirror config. See `configs/phase1/fgt-azure.conf`.

Key values:
- port1 (WAN): 198.51.100.2/30
- port2 (LAN): 10.100.10.1/24
- Default route: 0.0.0.0/0 via 198.51.100.1 on port1
- Tunnel interface `to-onprem`: 10.255.255.2/32, remote-ip 10.255.255.1/32
- BGP AS: 65002, neighbor 10.255.255.1, update-source to-onprem

#### Step 5 — Validate tunnel

On FGT-OnPrem:
```
diagnose vpn ike gateway list     # expect: IKE SA established 1/1
diagnose vpn tunnel list          # expect: status=up, sa=1
execute ping 10.255.255.2         # expect: 5/5 packets
```

#### Step 6 — Validate BGP

```
get router info bgp summary              # expect: Established, 1 prefix received
get router info routing-table bgp       # expect: remote subnet via tunnel
```

#### Step 7 — Validate end-to-end traffic

From on-prem client (Alpine):
```bash
ip addr add 192.168.10.10/24 dev eth0
ip link set eth0 up
ip route add default via 192.168.10.1
wget -O- http://10.100.10.4          # expect: HTTP 200
```

---

#### Critical operational notes for Phase 1

**Port3 must stay down.** Port3 is used during initial setup to get FortiGuard internet access for licensing. Once licensed, shut it down on both FortiGates:
```
config system interface
    edit port3
        set status down
    next
end
```
If port3 is up with DHCP, it installs a default route at distance 5 which overrides the static default route (distance 10) on port1. This breaks IKE — the kernel cannot route packets from 203.0.113.1 → 198.51.100.2 when the default points at the management NIC.

**After any reboot, check IKE transport.** FortiGate may default to `transport: TCP` (port 443) when it has internet access. The tunnel requires UDP. Verify with `diagnose vpn ike gateway list`. If transport shows TCP, fix it:
```
config vpn ipsec phase1-interface
    edit "to-azure"       # or "to-onprem" on FGT-Azure
        set transport udp
    next
end
```
Then flush and re-trigger:
```
diagnose vpn ike gateway flush name to-azure
execute ping 198.51.100.2
```

**After any reboot, re-check tunnel interface IPs.** The /32 tunnel interface IPs occasionally need to be re-applied after a reboot. If BGP shows Idle and `get router info routing-table all` is missing the 10.255.255.x/32 connected routes:
```
config system interface
    edit "to-azure"
        set ip 10.255.255.1 255.255.255.255
        set remote-ip 10.255.255.2 255.255.255.255
    next
end
```

**BGP won't come up on its own after reboot.** Give it a nudge:
```
execute router clear bgp ip 10.255.255.2
```

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

Common causes:
- PSK mismatch — verify with `show vpn ipsec phase1-interface` on both sides
- IKE version mismatch — both must be IKEv2
- Crypto proposal mismatch — trial license restricts to DES-based proposals; both sides must use `des-sha256`
- Transport mismatch — one side on TCP, other on UDP; explicitly set `set transport udp` on both
- No firewall policies — FortiGate will not initiate IPsec SA without policies referencing the tunnel interface
- Default route broken — port3 DHCP overriding port1 static; causes `error 101: Network is unreachable` in IKE debug

Debug commands:
```
diagnose debug app ike -1
diagnose debug enable
# watch output, then:
diagnose debug app ike 0
diagnose debug disable
```

### IPsec phase 1 up but phase 2 fails

Common causes: PFS mismatch, DH group mismatch, lifetime mismatch, auto-negotiate not enabled.

Check: `show vpn ipsec phase2-interface` — both sides must match on proposal, dhgrp, and keylifeseconds.

### BGP neighbor stuck in Idle / Active / Connect

Common causes:
- Tunnel not up — BGP peers over tunnel IPs; no tunnel = no path
- Tunnel interface IP missing — check `get router info routing-table all` for 10.255.255.x/32 connected routes
- MD5 password mismatch
- ASN typo — verify `set remote-as` matches peer's `set as`
- update-source not set — must be `set update-source "to-azure"` / `"to-onprem"`
- Static routes suppressing BGP — static routes (AD 10) beat BGP (AD 20); delete any static routes for the remote LAN after BGP is up

Nudge a stuck BGP session:
```
execute router clear bgp ip 10.255.255.2
```

### Transit traffic not forwarding (ping/curl times out end-to-end)

Most likely cause: `License Status: Invalid`. FortiGate VM without a valid license silently drops all transit forwarded traffic — packets hit the flow engine but never reach the policy check. This is not a misconfiguration.

Verify:
```
get system status    # look for: License Status: Valid
```

If invalid: access web GUI at the management IP → System → FortiGuard → Evaluation license. Log in with FortiCare credentials. Note: evaluation license is once per FortiCare account.

Other causes if license is valid:
- Missing firewall policy — verify `show firewall policy` includes both directions (LAN→tunnel and tunnel→LAN)
- src-check dropping asymmetric traffic — try `set src-check disable` on tunnel interface
- Session table empty — `get system session list` should show active sessions during traffic test

### Azure FortiGate cannot reach internet on untrust NIC

_Filled in during Phase 3b. Common causes: NSG blocking egress, public IP not associated, default route missing or wrong, FortiGate's expected gateway IP differs from Azure's first-IP-of-subnet convention._

### UDR not forcing traffic through FortiGate

_Filled in during Phase 3a. Validate via Azure Portal effective routes view; common causes: route table not associated to subnet, more-specific route exists, FortiGate trust NIC doesn't have IP forwarding enabled._

---

## License terms snapshot (for the case study)

Captured from FortiCare evaluation license. Applies to both GNS3 FortiGate VMs.

- IKE versions allowed: IKEv2 ✓ (IKEv1 also available but not used)
- Phase 1 ciphers allowed: DES-based proposals only (des-md5, des-sha1, des-sha256, des-sha384, des-sha512). AES-128, AES-256, and GCM not available on evaluation license.
- Phase 2 ciphers allowed: Same DES-based restriction
- Selected proposal: `des-sha256` (DES encryption + SHA-256 integrity — weakest acceptable for the lab)
- VM resources: 1 CPU / 2GB RAM / 3 interfaces / 3 firewall policies / 3 routes (evaluation limits)
- Throughput cap: Not explicitly measured; sufficient for lab traffic
- Other gating: Transit forwarding completely disabled without a valid license (any license tier resolves this)
- FortiCare registration: Once per account; CLI `execute vm-license` may fail with `curl forticare failed, 28` for GNS3 QEMU serial numbers — use web GUI instead

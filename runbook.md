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

#### Prerequisites

- `az login` completed on Fedora workstation
- SSH keypair at `~/.ssh/azure_hybrid_lab_ed25519(.pub)`
- FortiGate IPsec PSK and BGP MD5 password in Bitwarden
- GNS3 lab (Phase 1) ready to bring up on-prem FortiGate

#### Step 1 — Deploy Azure infrastructure (automated)

```bash
cd azure-hybrid-network-lab
./scripts/deploy-lab.sh
```

The script creates: resource group, VNet, 3 subnets, 3 NSGs with all rules, route table with UDRs, public IP, FortiGate NICs (IP forwarding ON), FortiGate VM (BYOL), and nginx VM (cloud-init installs nginx). Takes ~10 minutes.

**Save the Azure public IP** printed by the script. You need it for the FortiGate web GUI and the on-prem `remote-gw`.

Wait for both VMs to show `VM running`:
```bash
az vm list -d -g rg-hybrid-lab -o table
```

#### Step 2 — License the FortiGate

1. Browse to `https://<AZURE-PUBLIC-IP>` (accept the self-signed cert).
2. Login: `azureadmin` / the password you set during deploy.
3. Go to **System → FortiGuard** (or the license activation prompt that appears on first login).
4. Upload the BYOL license file or activate the evaluation license via FortiCare.
5. The VM will reboot. Wait ~2 minutes, then log in again.
6. Verify: `get system status` should show `License Status: Valid`.

> **If you see "License Status: Invalid" after reboot:** The 168.63.129.16 route may not be applied yet. Paste Block 2 from the config file first (static routes), reboot, and try again.

#### Step 3 — Apply FortiGate base config

Open the CLI console from the web GUI (or SSH). Paste the config blocks from `configs/phase3/fgt-azure-base.conf` in this order:

1. **Block 1 — Interfaces:** Verify first with `get system interface`. Azure Marketplace usually pre-configures port1/port2 with the correct IPs. If they match (10.100.1.4/24 and 10.100.2.4/24), skip this block.

2. **Block 2 — Static routes:** Default route via 10.100.1.1, Azure service IP 168.63.129.16, and workload subnet 10.100.10.0/24 via trust gateway.

3. **Block 4 — IPsec phase1/phase2:** Paste this BEFORE the firewall policies. Replace `<PSK>` with the real pre-shared key from Bitwarden. Key difference from Phase 1: `set type dynamic` (no `remote-gw`).

4. **Block 5 — BGP:** Replace `<BGP-MD5>` with the real password from Bitwarden.

5. **Block 3 — Firewall policies:** Now that the `to-onprem` tunnel interface exists, paste the two policies.

Verify static routes:
```
get router info routing-table static
```

#### Step 4 — Verify nginx

SSH to the nginx VM from the FortiGate trust NIC (since nginx has no public IP):

```
execute ssh azureadmin@10.100.10.4
```

Or use the Azure serial console. Once in:
```bash
curl -s http://localhost
# expect: <h1>Azure Hybrid Lab — workload VM</h1>
systemctl status nginx
# expect: active (running)
```

#### Step 5 — Update on-prem FortiGate

In GNS3, start the Phase 1 lab. On FGT-OnPrem, paste from `configs/phase3/fgt-onprem-update.conf`:

```
config vpn ipsec phase1-interface
    edit "to-azure"
        set remote-gw <AZURE-PUBLIC-IP>
    next
end
```

Replace `<AZURE-PUBLIC-IP>` with the real IP from Step 1.

**Remember Phase 1 operational notes:** Ensure port3 is down, transport is UDP, and tunnel interface IPs are correct. See Phase 1 critical operational notes above.

#### Step 6 — Bring up the tunnel

From FGT-OnPrem (the initiator):
```
execute ping <AZURE-PUBLIC-IP>
```

Then validate:
```
diagnose vpn ike gateway list     # expect: IKE SA established
diagnose vpn tunnel list          # expect: status=up, sa=1
execute ping 10.255.255.2         # expect: 5/5 (tunnel interface)
```

#### Step 7 — Validate BGP

On FGT-OnPrem:
```
get router info bgp summary              # expect: Established, prefix(es) received
get router info routing-table bgp       # expect: 10.100.10.0/24 via 10.255.255.2
```

On FGT-Azure (web GUI CLI console):
```
get router info bgp summary              # expect: Established, prefix(es) received
get router info routing-table bgp       # expect: 192.168.10.0/24 via 10.255.255.1
```

If BGP is stuck, nudge it:
```
execute router clear bgp ip 10.255.255.2    # on FGT-OnPrem
execute router clear bgp ip 10.255.255.1    # on FGT-Azure
```

#### Step 8 — End-to-end traffic test

From the on-prem client (Alpine in GNS3):
```bash
ip addr add 192.168.10.10/24 dev eth0
ip link set eth0 up
ip route add default via 192.168.10.1
wget -O- http://10.100.10.4
# expect: HTTP 200 with "Azure Hybrid Lab — workload VM"
```

This proves: on-prem client → FGT-OnPrem → IPsec tunnel → FGT-Azure → UDR → nginx VM → reverse path. Full hybrid connectivity over eBGP-learned routes.

#### Step 9 — Capture artifacts

```bash
# On FGT-Azure (web GUI CLI):
show full-configuration          # save to configs/phase3/fgt-azure.conf (sanitize PSK/passwords)

# On FGT-OnPrem (GNS3):
show full-configuration          # update configs/phase1/fgt-onprem.conf with the remote-gw change

# Screenshots to capture:
#   - BGP summary on both sides
#   - Routing table on both sides showing learned routes
#   - IPsec monitor showing tunnel up
#   - wget output from Alpine client
#   - Azure portal: resource group overview, NSG effective rules, route table effective routes
```

#### Step 10 — Deallocate

```bash
./scripts/deallocate-lab.sh
```

Confirm VMs are stopped (deallocated):
```bash
az vm list -d -g rg-hybrid-lab -o table
# expect: PowerState = VM deallocated
```

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

Common causes:
- **NSG blocking egress** — Default Azure NSGs allow outbound. If you added a deny-all outbound rule, egress is blocked. Check: `az network nsg rule list -g rg-hybrid-lab --nsg-name nsg-untrust -o table`
- **Public IP not associated** — Verify: `az network nic show -g rg-hybrid-lab -n fgt-untrust-nic --query ipConfigurations[0].publicIPAddress.id -o tsv` (should return the pip resource ID)
- **Default route missing or wrong** — `get router info routing-table static` must show 0.0.0.0/0 via 10.100.1.1 on port1. Azure's gateway is always the first IP in the subnet (10.100.1.1 for 10.100.1.0/24).
- **168.63.129.16 unreachable** — Licensing and Azure extensions require this IP. Verify route 2 exists: `get router info routing-table static` should show 168.63.129.16/32 via 10.100.1.1

Test from FortiGate CLI:
```
execute ping 8.8.8.8
execute ping 168.63.129.16
```

### FortiGate web GUI unreachable after licensing (PR_CONNECT_RESET_ERROR)

The evaluation license restricts all crypto to DES-based ciphers. This applies to the HTTPS management plane too — the FortiGate's web server can only offer ciphers that modern browsers refuse (TLS handshake fails). The browser shows `PR_CONNECT_RESET_ERROR` or `ERR_SSL_VERSION_OR_CIPHER_MISMATCH`.

Workaround: Use the **Azure serial console** (Portal → Virtual machines → fgt-azure → Help → Serial console) for all CLI management. The web GUI is not accessible with a trial license on modern browsers.

### NSG blocks tunnel-sourced traffic to workload subnet

When the FortiGate forwards traffic from the IPsec tunnel (source IP `10.255.255.x`) out the trust NIC to the workload subnet, Azure's default outbound NSG rule `AllowVnetOutBound` drops it because `10.255.255.0/24` is not part of the VNet's address space and doesn't match the `VirtualNetwork` service tag.

Fix: Add an explicit outbound allow rule on `nsg-trust`:
```bash
az network nsg rule create --resource-group rg-hybrid-lab \
  --nsg-name nsg-trust --name allow-forwarded-out \
  --priority 100 --direction Outbound --access Allow \
  --source-address-prefixes 10.255.255.0/24 192.168.10.0/24 \
  --destination-address-prefixes 10.100.10.0/24 \
  --destination-port-ranges '*' --protocol '*'
```

Also add inbound rules on `nsg-workload` for tunnel and on-prem source IPs:
```bash
az network nsg rule create --resource-group rg-hybrid-lab \
  --nsg-name nsg-workload --name allow-tunnel-in \
  --priority 105 --direction Inbound --access Allow \
  --source-address-prefixes 10.255.255.0/24 192.168.10.0/24 \
  --destination-port-ranges '*' --protocol '*'
```

### Workload VM cannot reach internet (cloud-init / apt-get fails)

The UDR `0.0.0.0/0 → 10.100.2.4` forces all workload traffic through the FortiGate, but there is no FortiGate policy to NAT it out to the internet. This breaks cloud-init, apt-get, and any outbound connectivity from the nginx VM.

Workaround: Temporarily replace the UDR default route with `--next-hop-type Internet`, run the install, then restore the FortiGate route. See deploy script comments for the exact commands.

### Azure free trial subscription blocks most VM SKUs

Azure free trial subscriptions restrict nearly all B/D/F-series VM families with `NotAvailableForSubscription`. Upgrading to **Pay-As-You-Go** (Portal → Subscriptions → Upgrade) removes these restrictions while keeping the $200 free credit. The upgrade is free and takes effect within minutes.

### FortiGate Gen1 image incompatible with v6/v7 VM SKUs

Newer Azure VM SKUs (v6, v7 generation) are Gen2-only (UEFI boot). The default FortiGate marketplace image `fortinet_fg-vm` is Gen1 (BIOS). Use the Gen2 image SKU `fortinet_fg-vm_g2` instead. Accept marketplace terms for the new SKU before deploying:
```bash
az vm image terms accept --publisher fortinet --offer fortinet_fortigate-vm_v5 --plan fortinet_fg-vm_g2
```

### FortiGate trial license limits VM to 1 vCPU / 2 GB RAM

If the FortiGate VM is deployed with more than 1 vCPU or 2 GB RAM, the license page shows "License invalid due to exceeding allowed 1 CPUs and 2 GB RAM." Resize the VM to a 1-vCPU SKU:
```bash
az vm deallocate --resource-group rg-hybrid-lab --name fgt-azure
az vm resize --resource-group rg-hybrid-lab --name fgt-azure --size Standard_F1alds_v7
az vm start --resource-group rg-hybrid-lab --name fgt-azure
```

### GNS3 on-prem FortiGate needs real internet path for Phase 3

In Phase 1, FGT-OnPrem's WAN pointed at the GNS3 FGT-Azure via the ISP router (R1). In Phase 3, R1's Fa0/1 must connect to a GNS3 NAT node (bridged to the host NIC) so FGT-OnPrem can reach the real Azure public IP. R1 needs NAT configuration:
```
conf t
interface FastEthernet0/1
  ip address dhcp
  ip nat outside
interface FastEthernet0/0
  ip nat inside
ip route 0.0.0.0 0.0.0.0 192.168.122.1
ip nat inside source list 1 interface FastEthernet0/1 overload
access-list 1 permit 203.0.113.0 0.0.0.3
end
```
Note: Use the actual DHCP gateway IP (check with `show ip route 0.0.0.0`), not the interface name, for the default route on multi-access Ethernet interfaces.

### UDR not forcing traffic through FortiGate

Validate via Azure Portal: **Virtual network → snet-workload → Effective routes** (or `az network nic show-effective-route-table -g rg-hybrid-lab -n nginx-nic -o table`).

Common causes:
- **Route table not associated to subnet** — Verify: `az network vnet subnet show -g rg-hybrid-lab --vnet-name vnet-hybrid-lab -n snet-workload --query routeTable.id -o tsv`
- **IP forwarding not enabled on FortiGate trust NIC** — This is the #1 cause. Azure silently drops packets if the destination IP doesn't match the NIC's IP and IP forwarding is off. Verify: `az network nic show -g rg-hybrid-lab -n fgt-trust-nic --query enableIPForwarding -o tsv` (must be `true`). Fix: `az network nic update -g rg-hybrid-lab -n fgt-trust-nic --ip-forwarding true`
- **IP forwarding not enabled on untrust NIC** — Also needed for return traffic from the tunnel. Same check/fix for `fgt-untrust-nic`.
- **More-specific route shadowing UDR** — Azure system routes for VNet prefixes have higher priority. The `local-workload` VNet route in the UDR handles this for intra-subnet traffic.

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

# Session Reference: Accessing Paperclip via Tailscale MagicDNS
## 2026-05-17

This documents the specific process used to discover and access the Paperclip service running on the local machine via Tailscale MagicDNS.

### Environment Details
- Machine: sa-vm's Virtual Machine (macOS)
- Tailscale IP: 100.124.188.113
- MagicDNS Suffix: tailb013fc.ts.net
- Tailnet: sleeperagent.ai@gmail.com

### Discovery Process

1. **Verified Tailscale connection:**
   ```bash
   tailscale status
   ```
   Output showed:
   ```
   100.124.188.113  sa-vms-virtual-machine  sleeperagent.ai@  macOS  -
   ```
   
   Additional JSON output confirmed:
   - HostName: "sa-vm’s Virtual Machine"
   - DNSName: "sa-vms-virtual-machine.tailb013fc.ts.net."
   - MagicDNSSuffix: "tailb013fc.ts.net"

2. **Identified the Paperclip service port:**
   First checked for Paperclip-related processes:
   ```bash
   ps aux | grep -i paperclip | grep -v grep
   ```
   Showed multiple postgres processes for Paperclip and a Node.js process.
   
   Then checked listening ports:
   ```bash
   lsof -i -P -n | grep LISTEN
   ```
   Key output:
   ```
   node      1197 sa-vm   25u  IPv4 0xfbe772d3d59b3d38      0t0  TCP 100.124.188.113:3100 (LISTEN)
   ```
   
   Also found Paperclip's PostgreSQL instance listening on port 54329 (local only).

3. **Constructed the MagicDNS URL:**
   - Hostname from tailscale status: sa-vms-virtual-machine
   - MagicDNS suffix: tailb013fc.ts.net
   - Port: 3100
   - Result: http://sa-vms-virtual-machine.tailb013fc.ts.net:3100

4. **Verified accessibility:**
   ```bash
   tailscale ping -c 1 sa-vms-virtual-machine.tailb013fc.ts.net
   ```
   Output: "100.124.188.113 is local Tailscale IP" (confirming the hostname resolves correctly)

### Filesystem Evidence
Located Paperclip installation at:
- `/Users/sa-vm/Workspace/paperclip/` (main project)
- Configuration and scripts in subdirectories like `docker/quadlet/`, `scripts/`, etc.

### Notes
- The Node.js process on port 3100 was identified as the Paperclip server (likely from `npm exec paperclipai onboard`)
- Service was bound to the Tailscale IP (100.124.188.113:3100), making it accessible via MagicDNS
- No additional firewall configuration appeared to be needed for access within the tailnet
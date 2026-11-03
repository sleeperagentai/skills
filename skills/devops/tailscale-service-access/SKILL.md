---
name: tailscale-service-access
description: Access local services via Tailscale MagicDNS
---
# Tailscale Service Access

Access local services running on a machine via Tailscale MagicDNS from other devices in your tailnet.

## Trigger Conditions
Use this skill when you need to:
- Access a local development server, database, or service running on a machine
- Connect to that service from another device using Tailscale MagicDNS
- Discover what services are available and on which ports

## Steps

1. **Verify Tailscale connection**
   ```bash
   tailscale status
   ```
   Look for:
   - Your machine's hostname in the "HostName" field
   - The MagicDNS suffix (usually shown in the "CurrentTailnet" or "Self.DNSName" sections)
   - Your Tailscale IP address(es)

2. **Identify the service port**
   Find what port your service is listening on:
   
   If you know the service/process name:
   ```bash
   lsof -i -P -n | grep LISTEN | grep <process-name>
   ```
   
   To see all listening ports:
   ```bash
   lsof -i -P -n | grep LISTEN
   ```
   
   Or check for a specific known port:
   ```bash
   lsof -i :<port-number>
   ```

3. **Construct the MagicDNS URL**
   Format: `http://<magicdns-hostname>:<port>`
   
   Where:
   - `<magicdns-hostname>` comes from the "HostName" field in `tailscale status` (spaces often replaced with hyphens)
   - `<port>` is the port number you discovered in step 2
   
   Example: `http://sa-vms-virtual-machine.tailb013fc.ts.net:3100`

4. **Test access**
   - Open the URL in a browser while connected to your tailnet
   - Or test with curl: `curl http://<magicdns-hostname>:<port>`

## Pitfalls
- **Service binding**: Ensure the service is listening on all interfaces (0.0.0.0) or the Tailscale interface, not just localhost (127.0.0.1). Services bound only to localhost won't be accessible via Tailscale.
- **Firewall**: Local firewalls on the host machine may block incoming Tailscale connections.
- **Service discovery**: Some services register themselves with mDNS or other discovery mechanisms; Tailscale MagicDNS works independently of these.
- **HTTPS**: For HTTPS services, use `https://` and ensure you have valid certificates (self-signed may cause browser warnings).
- **DNS propagation**: MagicDNS changes may take a moment to propagate; wait a few seconds if a new hostname doesn't resolve immediately.

## Verification
After constructing the URL, verify access by:
- Loading the URL in a browser on a device logged into your tailnet
- Checking that the service responds as expected
- Confirming the connection is routed through Tailscale (you can verify IP addresses in service logs if available)

## References
- See `references/tailscale-service-access-session-2026-05-17.md` for a detailed walkthrough of accessing the paperclip service via Tailscale MagicDNS.
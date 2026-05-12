# theatre-os

Image-based OS for the home theatre HTPC. See `README.md` for design.

## Scope

This repo builds and ships the OS image. It does NOT contain:
- Kodi addons / userdata (lives in `ha-config/kodi/`)
- HA automations or device integrations (lives in `ha-config`)
- Per-machine secrets (lives in `ha-config/secrets.yaml`)

## Target hardware

- T480 staging/prod: `ssh root@theatre-t480.home.lasath.com`
- ZBook (eventual cutover): `ssh root@theatre.home.lasath.com`
- Both have Intel AMT. T480 quirks: `t480-hardware-quirks.md`.
  ZBook tweaks (spec for behaviour to preserve): `ha-config/zbook-libreelec-tweaks.md`.

## AMT (out-of-band management)

Used for hard-reset / KVM recovery when the OS is unresponsive.

- AMT user: `admin`
- AMT password: `theatre_t480_amt_password` in `ha-config/secrets.yaml`
- Web UI: `http://theatre-t480.home.lasath.com:16992/`
- SOL: `AMT_PASSWORD=... amtterm theatre-t480.home.lasath.com`

### AMT/host MAC sharing — DNS quirk

The T480 has only one physical Ethernet port. AMT firmware and the host
OS share that port and therefore **share a MAC address**
(`8c:16:45:9c:5c:b9`). They appear as two separate DHCP clients to the
gateway because they send different DHCP client identifiers, and they
get separate IP leases — but to DNS they look like the same machine.

If they advertise different hostnames, whichever one renewed its lease
most recently "wins" the DNS entry, and `theatre-t480.home.lasath.com`
silently flips between resolving to the OS IP and the AMT IP. SSH
appears to work intermittently for no apparent reason.

**Workaround applied**: AMT's hostname was manually set to
`theatre-t480` (matching the OS hostname) via the AMT web UI. Now both
DHCP clients advertise the same hostname, so DNS is consistent
regardless of which one renewed last. The AMT and OS IPs are still
distinct (different DHCP leases), but the same name resolves to
whichever one is currently up — which is what you want, since the OS
takes precedence when running, and AMT answers when the OS is off.

**If AMT is ever re-flashed or factory-reset**: re-do this hostname
change in the AMT web UI, otherwise DNS will start flapping again.

This cannot be fixed at the hardware level on the T480 (no dedicated
AMT NIC). It could be worked around by giving the onboard NIC to AMT
exclusively and putting the OS on the dock's USB NIC, but that
introduces worse quirks (no S5 WOL, dock becomes a single point of
failure for OS network, NIC pinning in the OS config). Not worth it.

### AMT power control via curl

`amtterm` / `wsmancli` may not be installed on every dev box. Power-on
from S5 via raw WSMAN SOAP works with just `curl`:

```sh
AMT_PW=$(grep theatre_t480_amt_password /mnt/ha-config/secrets.yaml | cut -d"'" -f2)
curl -sf --digest -u "admin:$AMT_PW" -X POST \
  "http://theatre-t480.home.lasath.com:16992/wsman" \
  -H 'Content-Type: application/soap+xml;charset=UTF-8' \
  -d @- <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
  xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
  xmlns:wsman="http://schemas.dmtf.org/wbem/wsman/1/wsman.xsd"
  xmlns:p="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_PowerManagementService">
<s:Header>
<wsa:Action s:mustUnderstand="true">http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_PowerManagementService/RequestPowerStateChange</wsa:Action>
<wsa:To s:mustUnderstand="true">http://theatre-t480.home.lasath.com:16992/wsman</wsa:To>
<wsman:ResourceURI s:mustUnderstand="true">http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_PowerManagementService</wsman:ResourceURI>
<wsa:MessageID s:mustUnderstand="true">uuid:1</wsa:MessageID>
<wsa:ReplyTo><wsa:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</wsa:Address></wsa:ReplyTo>
<wsman:SelectorSet><wsman:Selector Name="Name">Intel(r) AMT Power Management Service</wsman:Selector><wsman:Selector Name="SystemName">Intel(r) AMT</wsman:Selector><wsman:Selector Name="CreationClassName">CIM_PowerManagementService</wsman:Selector><wsman:Selector Name="SystemCreationClassName">CIM_ComputerSystem</wsman:Selector></wsman:SelectorSet>
</s:Header>
<s:Body>
<p:RequestPowerStateChange_INPUT>
<p:PowerState>2</p:PowerState>
<p:ManagedElement><wsa:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</wsa:Address><wsa:ReferenceParameters><wsman:ResourceURI>http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ComputerSystem</wsman:ResourceURI><wsman:SelectorSet><wsman:Selector Name="Name">ManagedSystem</wsman:Selector></wsman:SelectorSet></wsa:ReferenceParameters></wsa:ManagedElement>
</p:RequestPowerStateChange_INPUT>
</s:Body>
</s:Envelope>
EOF
```

`PowerState` values: `2` = power on, `8` = power off, `5` = reset.

For waking from S3 (sleep, not full shutdown), AMT's `RequestPowerStateChange`
does not always work reliably. Use WOL instead — the host MAC is the
same as the AMT MAC: `wol -i 192.168.0.255 8c:16:45:9c:5c:b9`.

## Build / deploy commands

To be filled in during phase 1.

## Conventions

- All OS state that must survive a reboot lives in the persist
  partition. If you discover a path that needs persistence, add it to
  the list in README and to the mkosi config.
- Don't commit anything that wouldn't survive a wipe-and-rebuild from
  this repo + secrets. The point is reproducibility.

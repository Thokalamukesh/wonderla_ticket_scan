# Hikvision gate setup

## Device preparation

1. Put the DS-K1T673DWX and Android kiosk on the same protected LAN or VPN. Give the terminal a reserved IP and do not expose it to the public internet.
2. Enable ISAPI on the terminal, create a dedicated operator account with only the required door-control rights, and record the HTTP/HTTPS port and door number from the device configuration. Never commit credentials.
3. Confirm the firmware/model's ISAPI specification through Hikvision TPP for the exact firmware. From a trusted workstation, use a read-only GET to `http(s)://DEVICE:PORT/ISAPI/AccessControl/RemoteControl/door/DOOR/capabilities` with Digest authentication. Confirm that its `cmd` capability includes `open`. Capability responses vary by firmware; test this client against that terminal before enabling the feature.
4. The app will only send PUT after the capability check. Its XML body is `<RemoteControlDoor version="2.0" xmlns="http://www.isapi.org/ver20/XMLSchema"><cmd>open</cmd></RemoteControlDoor>`. A `ResponseStatus` with `statusCode` 1 and `subStatusCode` `ok` means the device accepted the command; it does not prove the relay or physical gate moved.

## App configuration

Open **Gate Access** and tap the gear icon in the top right. Enter the terminal IP (for example, `10.10.10.196` only if that is its actual address), its configured web port, door ID, HTTP/HTTPS choice, and a dedicated terminal operator username/password. These details go into the app's **Connect Hikvision terminal** form; do not enter them in a Wonderla booking dashboard. In the terminal's own web interface, an administrator/integrator must configure its network, enable ISAPI, create/authorize the operator, and verify the door number and firmware capability. Only then check the verification box in the app and save. Settings are stored using platform secure storage; this is suitable for local testing, but a distributed app should use a protected backend instead of retaining terminal credentials on the kiosk. HTTPS certificate validation remains enabled; install a certificate trusted by Android.

For production, route the operation through a protected backend that stores device credentials, authorizes operators, validates tickets server-side, audits actions, and prevents duplicate requests. Do not expose the terminal to the public internet.

Android's main manifest grants INTERNET permission. No global cleartext exception is enabled. Android cleartext policy may block local HTTP; prefer HTTPS. If temporary HTTP is unavoidable for a controlled test, scope any network security exception to the exact device address and remove it before release.

## API and hardware validation

Check connectivity and capability first, then test one opening operation using a trusted workstation and the same operator account. Do not repeat an opening request after a timeout: the first command might have succeeded. Check the device event log and physical gate before a deliberate manual retry. Verify relay wiring, gate controller behavior, and safe operation on site.

Automated Flutter tests cover UI tap guarding and ISAPI parsing/error handling using a local HTTP test server. They do not verify the terminal, Digest behavior on its firmware, Android LAN access, the relay, or physical gate movement. Test on the actual Android kiosk and connected controller before operational use.

## Troubleshooting

- `401`/`403`: check account/password, Digest support, and door-control privilege.
- Timeout/network error: verify VLAN routing, Wi-Fi client isolation, device address/port, firewall, and power. Never auto-retry an open command.
- `404`/`405` or missing advertised `open`: check firmware-specific ISAPI documentation, access-control configuration, and door ID; the client sends no PUT if capability is absent.
- Unexpected/malformed XML or ISAPI status: preserve the response on a trusted diagnostic workstation and compare it with the firmware's ISAPI guide.
- HTTPS handshake error: configure a certificate trusted by Android; do not disable certificate checks.
- Accepted command but gate remains closed: inspect device events, relay configuration/wiring, and the external gate controller. ISAPI acceptance is not physical-open confirmation.

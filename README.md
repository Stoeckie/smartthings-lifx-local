# LIFX (local) – SmartThings Edge driver

Local control of LIFX bulbs from a SmartThings hub over the LIFX LAN protocol. No LIFX cloud, no bridge, no account.

## Why
The LIFX cloud integration depends on each bulb keeping its cloud connection. Older bulbs (e.g. LIFX Original 1000) can drop that connection while they are still on Wi‑Fi, so routines silently stop working ("lights did not turn off this morning"). This driver talks to the bulbs directly on your LAN.

## What it does
- **Discovery**: *Add device → Scan nearby*. GetService broadcast plus a unicast sweep of the hub's /24, two rounds. Bulbs are keyed by MAC address, so a new IP is picked up automatically.
- **Confirmed state**: SmartThings only shows what the bulb itself reports. Every command is sent with acknowledgement (3 tries), then the real state is read back (and read again if the bulb has not applied it yet).
- **Polling**: real state every 30 s (setting), so changes from the LIFX app or a wall switch show up.
- **No false offline**: a bulb is only marked offline after 2 minutes without any answer. Short drops are remembered and shown as *Last drop* when it is back.
- **Capabilities**: switch, level, color (hue/saturation), color temperature (1500–9000 K), refresh, connection status (usable in routines, e.g. "notify when a bulb goes offline").
- White‑only LIFX models get a profile without color.

## Settings (per bulb)
| Setting | Default | |
|---|---|---|
| Transition (ms) | 0 | fade time for on/off/level/color |
| Poll interval (s) | 30 | 10–600 |
| Bulb IP | auto | only set a fixed IP when discovery fails |

## Install
1. Enroll your hub in the channel (invite link in the forum post) and install **LIFX (local)**.
2. *Add device → Scan nearby*. All bulbs on the same subnet as the hub appear with their LIFX names.
3. Move your routines to the new devices, then remove the old LIFX cloud devices / unlink the LIFX cloud service.

Hub and bulbs must be in the same subnet (discovery uses broadcast / a /24 sweep).

## Notes
- Protocol: https://lan.developer.lifx.com (UDP 56700).
- Tested on a SmartThings v3 hub with 17 LIFX Original 1000 bulbs.
- Color commands also switch the bulb on unless the command says `switch: off`.

MIT licence.

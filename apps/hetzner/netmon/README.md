# netmon

A small webhook on the Hetzner cluster. Home Assistant at a remote site POSTs
network-monitoring events to it, and it stores them in SQLite so outages can be
looked up later. The first site is `vandersteen`, a household on a KPN Box 12
with daily Wi-Fi and wired drops.

- Public URL: `https://netmon.jensvanzutphen.com`, via the `hetzner-aiostreams`
  Cloudflare Tunnel (route and CNAME in `terraform/cloudflare/main.tf`).
  Cloudflare terminates TLS. There is no Ingress.
- Code: `server.py`, stdlib Python on the pinned official `python` image,
  shipped as a ConfigMap. Editing it changes the ConfigMap hash and rolls the pod.
- Data: `/data/netmon.db` on the `netmon-data` PVC (`local-path`). Events older
  than `NETMON_RETENTION_DAYS` (400) are pruned.
- Tokens: `secret.yaml` (SOPS), mounted as files.

## Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/healthz` | none | Probe. Returns `{"status":"ok"}` when SQLite answers. |
| POST | `/v1/events` | site token | Store one event (JSON object) or a batch (JSON array, max 500). |
| GET | `/v1/events` | site or admin token | Query events as JSON or CSV. |
| GET | `/v1/outages` | site or admin token | Down windows and heartbeat gaps derived from the events. |

Auth is `Authorization: Bearer <token>`. A `site.<name>` token can write and
read that site only. The `admin` token can read every site and cannot write.

POST rules: `Content-Type: application/json`, a `Content-Length` header, and a
body of at most 64 KB. The server validates the whole batch before storing any
of it. On success it returns `202 {"accepted": n, "received_at": ...}`. Errors
come back as `{"error": "..."}` with 400, 401, 403, 411, 413 or 415. Logs show
the client IP, path, status and event count. They never show headers or tokens.

## Payload contract

```json
{
  "site": "vandersteen",
  "source": "home-assistant",
  "entity_id": "binary_sensor.1_1_1_1",
  "target": "1.1.1.1",
  "state": "on",
  "previous_state": "off",
  "previous_state_since": "2026-10-09T06:01:12.345678+00:00",
  "last_changed": "2026-10-09T06:19:40.123456+00:00",
  "ts": "2026-10-09T06:19:40.123456+00:00",
  "attributes": {"round_trip_time_avg": 12.3}
}
```

| Field | Required | Meaning |
|---|---|---|
| `site` | no | Defaults to the token's site. Must match the token. `[a-z0-9-]`. |
| `source` | no | Sender, e.g. `home-assistant`. |
| `entity_id` | yes | HA entity, or `netmon.heartbeat` for heartbeats. |
| `target` | no | Host or IP the entity checks. |
| `state` | yes | New state. Numbers and booleans are stored as text. |
| `previous_state` | no | State before this change. |
| `previous_state_since` | no | When the previous state began (HA `from_state.last_changed`). |
| `last_changed` | no | When the new state began (HA `to_state.last_changed`). |
| `ts` | no | When HA sent the event. Defaults to `received_at`. |
| `attributes` | no | JSON object, max 16 KB. A string is kept as `{"raw": "..."}`. |

The server adds `received_at` and `client_ip` (Cloudflare's
`CF-Connecting-IP`). It stores every timestamp as UTC
`YYYY-MM-DDTHH:MM:SS.ffffffZ`, ignores unknown fields, and caps strings at 255
characters.

## What gets lost when the internet is down

The outage you want to see is often the one that stops the report from
arriving. HA's `rest_command` does not queue or retry, so the "went down" POST
for `1.1.1.1` usually fails while the WAN is out. The contract works around
that:

- The recovery event carries `previous_state_since`. One POST that arrives
  after the WAN returns gives the full window, from `previous_state_since` to
  `last_changed`. `/v1/outages` builds windows from exactly these events.
- HA sends a heartbeat every 5 minutes with its own `ts`. A gap between
  heartbeats means HA could not reach netmon: WAN down, HA down, or Cloudflare
  or Hetzner trouble. `/v1/outages` reports gaps longer than `gap_minutes`
  (default 12).
- A flap that starts and ends inside one WAN outage never reaches netmon. Only
  the last recovery does, and its `previous_state_since` covers only the final
  down period.

HA's own recorder is the source of truth for down edges during a WAN outage.
Look there (History, or the `states` table) when netmon shows a heartbeat gap.

`/v1/outages` treats `off`, `unavailable` and `unknown` as down. For the ping
sensors `on` means reachable. The DNS sensors hold the resolved IP and go
`unavailable` when the lookup fails. An entity whose latest event is a down
state shows up as an open window with `"end": null`.

## Querying

Run from the repo root inside `nix develop`:

```bash
TOKEN=$(sops -d apps/hetzner/netmon/secret.yaml | yq '.stringData.admin')
H="Authorization: Bearer $TOKEN"
U=https://netmon.jensvanzutphen.com

# Last 24 hours for the router, as JSON
curl -sH "$H" "$U/v1/events?site=vandersteen&since=24h&entity=binary_sensor.192_168_2_254" | jq

# Everything since a date, as CSV
curl -sH "$H" "$U/v1/events?site=vandersteen&since=2026-10-01&format=csv&limit=20000" > vandersteen.csv

# Down windows and heartbeat gaps over the last week
curl -sH "$H" "$U/v1/outages?site=vandersteen&since=7d" | jq
```

Both GET endpoints take these query parameters:

- `site`, required with the admin token to pick one site.
- `entity`, repeatable or comma-separated.
- `since` and `until`, applied to `ts`. Either ISO 8601 or a relative age
  (`30m`, `24h`, `7d`). URL-encode `+` in offsets as `%2B`, or use `Z`.

`/v1/events` also takes `limit` (default 1000, max 20000), `order=asc|desc` and
`format=json|csv`. `/v1/outages` takes `gap_minutes`.

For ad-hoc SQL, copy a consistent snapshot out of the pod:

```bash
POD=$(kubectl -n netmon get pod -l app.kubernetes.io/name=netmon -o name | cut -d/ -f2)
kubectl -n netmon exec "$POD" -- python3 -c \
  "import sqlite3; sqlite3.connect('/data/netmon.db').backup(sqlite3.connect('/tmp/netmon.db'))"
kubectl -n netmon cp "$POD:/tmp/netmon.db" ./netmon.db
```

## Tokens

`secret.yaml` holds `site.vandersteen` (used by HA) and `admin` (for
queries). Read one with:

```bash
sops -d apps/hetzner/netmon/secret.yaml | yq '.stringData["site.vandersteen"]'
```

Add a site by adding a `site.<name>` key. The server reloads the token files
every 30 seconds, and the kubelet syncs Secret changes within about a minute.
No restart is needed.

To rotate without dropping events:

1. Add the new token as `site.vandersteen.next`. The old and new tokens both
   work while both keys exist.
   ```bash
   sops set apps/hetzner/netmon/secret.yaml '["stringData"]["site.vandersteen.next"]' \
     "\"$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')\""
   ```
2. Commit, push, and wait for Flux to apply it.
3. Put the new value in HA's `secrets.yaml` and reload REST commands
   (Developer tools, YAML, "REST commands").
4. Move the new value into `site.vandersteen`, delete the `.next` key, then
   commit and push.

Tokens must be at least 24 characters. The server ignores shorter ones.

## Home Assistant setup

This targets HA 2024.2, so it uses the `platform:`/`service:` syntax. Save it
as `packages/netmon.yaml` and enable packages in `configuration.yaml`:

```yaml
homeassistant:
  packages: !include_dir_named packages
```

Add the token to `secrets.yaml`, with the `Bearer ` prefix:

```yaml
netmon_authorization: "Bearer <value of site.vandersteen>"
```

`packages/netmon.yaml`:

```yaml
rest_command:
  netmon_event:
    url: https://netmon.jensvanzutphen.com/v1/events
    method: post
    timeout: 10
    content_type: application/json
    headers:
      authorization: !secret netmon_authorization
    payload: >-
      {{ {
        "site": "vandersteen",
        "source": "home-assistant",
        "entity_id": entity,
        "target": host | default(none),
        "state": state | string,
        "previous_state": previous_state | default(none),
        "previous_state_since": previous_state_since | default(none),
        "last_changed": last_changed | default(none),
        "ts": now().isoformat(),
        "attributes": attributes | default({})
      } | to_json }}

automation:
  - id: netmon_report_change
    alias: "netmon: report connectivity change"
    mode: parallel
    max: 25
    trigger:
      - platform: state
        entity_id: &netmon_entities
          - binary_sensor.192_168_2_254
          - binary_sensor.192_168_2_16
          - binary_sensor.192_168_2_10
          - binary_sensor.192_168_2_15
          - binary_sensor.192_168_2_3
          - binary_sensor.192_168_2_23
          - binary_sensor.1_1_1_1
          - binary_sensor.8_8_8_8
          - binary_sensor.2606_4700_4700_1111
          - sensor.kpn_com
          - sensor.kpn_com_ipv6
        # null "to" fires on state changes only, not on attribute updates.
        to: ~
    variables:
      targets:
        binary_sensor.192_168_2_254: 192.168.2.254 (KPN router)
        binary_sensor.192_168_2_16: 192.168.2.16 (extender ETH1)
        binary_sensor.192_168_2_10: 192.168.2.10 (extender ETH2)
        binary_sensor.192_168_2_15: 192.168.2.15 (Hue bridge)
        binary_sensor.192_168_2_3: 192.168.2.3 (P1 meter)
        binary_sensor.192_168_2_23: 192.168.2.23 (UniFi AP)
        binary_sensor.1_1_1_1: 1.1.1.1
        binary_sensor.8_8_8_8: 8.8.8.8
        binary_sensor.2606_4700_4700_1111: 2606:4700:4700::1111
        sensor.kpn_com: kpn.com A via 192.168.2.254
        sensor.kpn_com_ipv6: kpn.com AAAA via 192.168.2.254
    condition:
      - "{{ trigger.from_state is not none and trigger.to_state is not none }}"
    action:
      - service: rest_command.netmon_event
        data:
          entity: "{{ trigger.entity_id }}"
          host: "{{ targets.get(trigger.entity_id, '') }}"
          state: "{{ trigger.to_state.state }}"
          previous_state: "{{ trigger.from_state.state }}"
          previous_state_since: "{{ trigger.from_state.last_changed.isoformat() }}"
          last_changed: "{{ trigger.to_state.last_changed.isoformat() }}"
          attributes: "{{ dict(trigger.to_state.attributes) }}"

  - id: netmon_heartbeat
    alias: "netmon: heartbeat"
    mode: single
    trigger:
      - platform: time_pattern
        minutes: "/5"
        id: alive
      - platform: homeassistant
        event: start
        id: start
    variables:
      entities: *netmon_entities
    action:
      - service: rest_command.netmon_event
        data:
          entity: netmon.heartbeat
          state: "{{ trigger.id }}"
          attributes: >-
            {%- set ns = namespace(states={}) -%}
            {%- for e in entities -%}
              {%- set ns.states = dict(ns.states, **{e: states(e)}) -%}
            {%- endfor -%}
            {{ {"states": ns.states} }}
```

Notes:

- The `&netmon_entities` anchor only works when both automations live in the
  same file. If you split them, copy the list.
- `ts` is HA's clock at send time. The heartbeat's `states` snapshot shows
  which targets were down when HA reached netmon again.
- After a HA restart, entities move from `unavailable` to their real state, so
  expect a burst of events and a `start` heartbeat.
- Test it from Developer tools, Services, `rest_command.netmon_event` with
  `entity: test.manual` and `state: "on"`, then check the log on the pod.

# Pritunl VPN — Omarchy bar widget

Connect, disconnect, and import [Pritunl](https://client.pritunl.com/) VPN
profiles from the [Omarchy](https://omarchy.org/) bar, without opening the
Pritunl app.

```
bar:     󰖂        <- dim while disconnected, full colour once connected

popup:   󰖂  OsomeVPN-Developers                  [  ●]
            Connected · 12m
            192.168.220.84
         ─────────────────────────────────
         PROFILES                     (only with more than one)
         OsomeVPN-Developers           Connected
         Staging                    Disconnected
         ─────────────────────────────────
         SIGN IN                      (while disconnected)
         [ One-time code                        ]
                                       [ Connect ]
         ─────────────────────────────────
         ADD PROFILE
         [ Paste a pritunl:// link or a file path ]
         [ Import file… ]                  [ Add ]
```

- **Left-click** the bar — open the popup
- **Right-click** — disconnect when connected; otherwise open the popup
- **Middle-click** — refresh now
- **From a keybinding** — `omarchy-shell abdulghani.pritunl toggle` (also `open`
  and `close`)

The switch in the header connects or disconnects the selected profile. While a
connection is being set up the header follows the client through
*Connecting…*, *Authenticating…*, and *Reconnecting…*; a connection that falls
back to disconnected without ever coming up is reported as failed, with the
client's last log line about it.

**Sign-in fields** follow each profile's password mode, the same way the
Pritunl app decides what to ask for:

| Password mode | Fields |
|---|---|
| none | nothing — Connect goes straight through |
| `pin` | PIN |
| `otp` | One-time code |
| `otp_pin` | PIN and one-time code, sent as one password PIN first |
| `username_password` | Username and password |
| anything else (Duo, Okta, OneLogin, YubiKey) | Passcode |

Codes are never kept: the fields clear as soon as a connection starts.

**Add profile** takes whatever the Pritunl user page gives you:

- a **profile link** (`pritunl://…`, or its https form) pasted into the field
- a **file** — `.ovpn`, `.tar`, or the `.zip` the download button produces —
  through **Import file…**, which opens the desktop file chooser, or by typing
  its path into the field

A `.zip` is unpacked to a temporary directory and every profile inside is
added. Profiles are added as user profiles, the same as the Pritunl app, and the
new one is selected straight away. Importing a profile that is already there
updates it in place rather than adding a copy, and the panel says so.

## Requirements

- The Pritunl desktop client — `pritunl-client-electron` from the AUR — which
  provides the `pritunl-client` CLI and the `pritunl-client-service` it talks to
- `jq` and `unzip`, both present on a stock Omarchy install
- Omarchy's `omarchy-file-select` for the file chooser, which ships with Omarchy

Without the client the widget says so instead of failing quietly.

## Install

```bash
omarchy plugin add https://github.com/abdulghani/omarchy-pritunl-plugin.git --enable --yes
omarchy bar put abdulghani.pritunl --section right
omarchy restart shell
```

> Editing plugin files hot-reloads the code, but the bar does not re-place an
> already-laid-out widget. Run `omarchy restart shell` after any change.

## Security note

The code is handed to `pritunl-client start` with `--password`, so for the
second or so that command runs it is visible in the process list to other
users on the machine. The CLI's `--password-read` alternative reads from a
terminal prompt that a bar widget cannot answer reliably. For one-time codes
the exposure is negligible — they are single-use and expire within about 30
seconds. A static PIN is worth keeping in mind on a shared machine.

## Remove

```bash
omarchy plugin remove abdulghani.pritunl --yes
omarchy restart shell
```

The widget stores nothing of its own; profiles stay in the Pritunl client.

## How it works

`profiles.sh` runs `pritunl-client list -j` and joins in each profile's
password mode from `~/.config/pritunl/profiles/<id>.conf`, since the list does
not carry it. The QML side parses that one JSON reading.

Connecting runs `pritunl-client start <id>` with the joined password, and
disconnecting runs `pritunl-client stop <id>`; the client service does the
rest. A connected profile reports its uptime in place of a status, so the
`connected` flag decides that state rather than the status text.

`add-profile.sh` wraps `pritunl-client add --user`, unpacking a `.zip` first.
The panel notes which profile ids existed before an import and compares them
with the first reading taken after it, which is how it tells a new profile from
an updated one. The file chooser opens with the popup closed, so the popup
cannot cover it, and the popup reopens to show how the import went.

Polling is every second while a connection is changing, every 3 seconds while
the popup is open, and every 15 seconds otherwise.

## License

MIT — see [LICENSE](LICENSE).

# v2box.sh

A single Bash script to manage **SSH tunnel-only users** on Ubuntu.

Each managed user is a system account that can do **port-forwarding only** — no
interactive shell, no SFTP, no command execution. This is intended for handing
out SOCKS/tunnel access (e.g. to clients like v2box) without giving anyone a
foothold on the server.

User data is stored as JSON and manipulated with `jq`. Connection details are
emitted as a `v2box`-compatible `ssh://` URI plus a scannable QR code in the
terminal.

---

## How it works

Every user created by the script is:

- a system account with shell `/usr/sbin/nologin` (no interactive login),
- a member of the group `sshtunnel`,
- assigned a randomly generated 24-character password.

The script adds one `Match Group sshtunnel` block to `/etc/ssh/sshd_config`.
`sshd` applies it to every member of the group:

```
Match Group sshtunnel
    PasswordAuthentication yes
    KbdInteractiveAuthentication yes
    AllowTcpForwarding yes
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    GatewayPorts no
    X11Forwarding no
    PermitTTY no
    PermitTunnel no
    ForceCommand /usr/sbin/nologin
```

`KbdInteractiveAuthentication yes` is required: on Ubuntu with `UsePAM yes`,
password auth for non-root accounts is delivered through keyboard-interactive,
not the plain `password` method. Without it, password login silently fails even
though `PasswordAuthentication yes` is set.

Cloud Ubuntu images often ship `PasswordAuthentication no` in
`/etc/ssh/sshd_config.d/*.conf`. The `Match` block overrides this for the group
without touching the global default, so key-only login stays enforced for every
other account.

An optional **`badvpn-udpgw`** daemon provides UDP-over-TCP for clients that
need UDP through the tunnel (QUIC, some apps/games). It is installed as a
systemd service bound to `127.0.0.1` only and is reached by clients **through
the SSH tunnel** — no extra port is exposed to the internet.

---

## Requirements

- Ubuntu (tested against 22.04 / cloud images) with `systemd`.
- Root access (`sudo`).
- Outbound network to install `jq`, `qrencode`, `curl`, `openssh-server`, and to
  download the `badvpn-udpgw` binary.

`--init` installs all dependencies automatically.

---

## Installation

Download the script and install it:

```bash
curl -fL -o v2box.sh https://raw.githubusercontent.com/4modx/badvpn-udpgw/refs/heads/main/v2box.sh
sudo install -m 700 v2box.sh /usr/local/bin/v2box
sudo v2box --init
```

`--init` will:

1. Install dependencies (`jq`, `qrencode`, `openssh-server`, `curl`).
2. Create the `sshtunnel` group.
3. Prompt for `SERVER_IP`, `SSH_PORT`, and `SERVER_NAME` (stored in
   `/etc/sshtunnel/sshtunnel.conf`, mode `600`). The public IP is auto-detected
   as a default.
4. Back up `sshd_config`, insert the `Match` block, run `sshd -t`, and **roll
   back automatically** if the result is invalid — so a bad edit can't lock you
   out. On success it restarts `ssh` and prints the effective settings via
   `sshd -T -C`.
5. Download the `badvpn-udpgw` binary, verify it runs, and register it as a
   loopback-only systemd service on port `7300`.

> **Do not close your current root session after `--init`.** Open a second
> terminal and confirm a new SSH login still works before disconnecting. The
> script only rolls back a *syntactically* invalid config; a valid-but-unwanted
> change will still be applied.

---

## Usage

```bash
sudo v2box --new    <username>   # create a user, print link + QR
     v2box --qr     <username>   # reprint the link + QR (no root needed)
sudo v2box --delete <username>   # revoke a user (kills sessions, userdel -r)
     v2box --list                # list users, flag system/JSON desync
sudo v2box --uninstall           # remove everything (asks for confirmation)
v2box --help
```

### Username rules

Usernames must match `^[a-z_][a-z0-9_-]{0,31}$` (lowercase start, then
lowercase/digit/`_`/`-`, max 32 chars). Anything else is rejected — this also
guards against injection into the system commands.

### `--new`

Generates a username-bound password, creates the system account
(`useradd -m -s /usr/sbin/nologin -G sshtunnel`), sets the password via
`chpasswd` over stdin (never on the command line), verifies group membership,
records it in JSON, and prints the connection block + QR.

If `useradd` or the group check fails, the partially created account is removed
automatically.

### `--delete`

Kills any live sessions for the user, runs `userdel -r`, and removes the JSON
entry. Only touches accounts that are actually members of `sshtunnel`.

### `--uninstall`

Requires typing `yes`. It then:

- removes **all** users in the `sshtunnel` group (cross-referenced with the JSON
  so out-of-sync accounts are still caught; non-members are never touched),
- removes the `Match` block from `sshd_config` (backup + validate + rollback),
- stops and removes the `badvpn-udpgw` service and its binary,
- deletes the `sshtunnel` group,
- wipes `/etc/sshtunnel`.

`sshd_config` backups (`/etc/ssh/sshd_config.bak.*`) are kept; remove them
manually if not needed.

---

## Connection URI format

The script emits a `v2box`-compatible URI:

```
ssh://BASE64(user:password)@SERVER_IP:SSH_PORT?udpgw=PORT#SERVER_NAME
```

- `user:password` is base64-encoded, then URL-encoded (the `=` padding becomes
  `%3D`). This is encoding, **not encryption** — it decodes trivially.
- `?udpgw=7300` is appended **only if** the `badvpn-udpgw` service is running.
  If UDP is unavailable, the parameter is omitted so the client doesn't try to
  send UDP into a non-existent gateway.
- `SERVER_NAME` is the fragment (the profile label shown in the client).

A test command is also printed:

```bash
ssh -D 0.0.0.0:1111 -N \
  -o PreferredAuthentications=keyboard-interactive \
  -o PubkeyAuthentication=no \
  <username>@<SERVER_IP> -p <SSH_PORT>
```

Verify the SOCKS proxy:

```bash
curl -x socks5h://localhost:1111 https://ifconfig.me   # should return SERVER_IP
```

---

## UDP gateway (udpgw)

In the client (v2box), set the **udpgw port** to `7300` to enable UDP, or `0` to
disable it. If the client tries to use udpgw but no gateway is running on the
server, the whole connection breaks — which is why the URI only advertises
`udpgw` when the service is actually up.

The daemon listens on `127.0.0.1:7300` and is hardened
(`DynamicUser`, `NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`).
Clients reach it over the SSH tunnel, so no inbound UDP port is opened.

Service management:

```bash
systemctl status badvpn-udpgw
journalctl -u badvpn-udpgw
```

---

## Files

| Path | Purpose |
|------|---------|
| `/etc/sshtunnel/users.json` | User records (username, **plaintext password**, created_at, status). Mode `600`. |
| `/etc/sshtunnel/sshtunnel.conf` | `SERVER_IP` / `SSH_PORT` / `SERVER_NAME`. Mode `600`. |
| `/etc/ssh/sshd_config` | Contains the managed `Match` block between marker comments. |
| `/etc/systemd/system/badvpn-udpgw.service` | udpgw systemd unit. |
| `/usr/local/bin/badvpn-udpgw` | udpgw binary. |

> The managed block is delimited by
> `# >>> sshtunnel managed block >>>` / `# <<< sshtunnel managed block <<<`.
> Do not edit those marker lines — `--uninstall` relies on them to locate and
> remove the block.

---

## Security notes

- **Passwords are stored in plaintext** in `users.json` because `--qr` needs to
  reproduce the link later. The file is `chmod 600`, but anyone with root or the
  file gets every password. Treat the server accordingly. If you don't need
  link regeneration, an SSH-key model (`restrict,port-forwarding` in
  `authorized_keys`) avoids storing secrets entirely.

- **`-D` (dynamic SOCKS) cannot be restricted with `PermitOpen`.** A tunnel user
  can open TCP to any host the server can reach — including the server's own
  `localhost` services and its LAN. This is inherent to SOCKS. To restrict
  destinations you must drop `-D` and issue static `-L host:port` with a matching
  `PermitOpen`.

- **You are responsible for outbound traffic.** All connections exit under the
  **server's IP**, not the client's. Abuse (spam, scanning, illegal access) by a
  tunnel user will appear to originate from your server and your IP; abuse
  reports and legal requests go to you. Hand out access only to people you trust,
  and prefer per-person identification (a key per person, not a shared password)
  so you can attribute and revoke individually.

- **The udpgw binary is a third-party build** downloaded from a non-official
  GitHub repository and run as a service. The unit is sandboxed, but you are
  trusting that binary. To avoid it, build `badvpn` from the upstream source
  (`github.com/ambrop72/badvpn`) yourself and place the binary at
  `/usr/local/bin/badvpn-udpgw` before running `--init`; the script will detect
  the existing file and skip the download.

---

## Troubleshooting

**Password login fails (`Permission denied`)**

- Confirm the effective settings:
  ```bash
  sudo sshd -T -C user=root,group=sshtunnel,host=any,addr=1.2.3.4 \
    | grep -iE 'passwordauth|kbdinteractive'
  ```
  Both must be `yes`. If not, the `Match` block isn't applied — make sure it's at
  the end of `sshd_config` and that no `sshd_config.d/*.conf` re-disables it
  *after* the block.
- Auth attempts are logged in `/var/log/auth.log`, **not** in
  `journalctl -u ssh` (which only shows starts/restarts):
  ```bash
  sudo tail -f /var/log/auth.log
  ```
  `pam_unix(sshd:auth): authentication failure user=...` means the password is
  wrong; no line at all means you're watching the wrong log.
- After config changes use `systemctl restart ssh` (not `reload`) — with socket
  activation, `reload` may not pick up the change.

**Connection works but UDP doesn't**

- Set the client's udpgw port to `0` to confirm TCP-only works, then check the
  service: `systemctl status badvpn-udpgw`.

**`--uninstall` reports the Match block invalid and won't remove it**

- The marker lines were probably edited. Remove the block manually, run
  `sudo sshd -t`, then `sudo systemctl restart ssh`.

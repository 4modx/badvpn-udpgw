#!/usr/bin/env bash
#
# v2box.sh — manage SSH tunnel-only users on Ubuntu.
#
# Each user is a system account with:
#   - shell /usr/sbin/nologin  (no interactive shell)
#   - membership in group "sshtunnel"
#   - a generated password
# sshd matches the group and permits ONLY port-forwarding (no shell, no sftp).
#
# A badvpn-udpgw daemon (systemd service, bound to 127.0.0.1) provides optional
# UDP-over-TCP for clients (v2box etc.) that need UDP through the SSH tunnel.
#
# Data is stored as JSON and manipulated with jq.
#
# Commands:
#   v2box.sh --init               one-time setup: deps, group, sshd_config, udpgw
#   v2box.sh --new   <username>   create user, print link + QR
#   v2box.sh --qr    <username>   reprint link + QR
#   v2box.sh --delete <username>  revoke (remove) user
#   v2box.sh --list               list users
#   v2box.sh --uninstall          remove ALL users, revert sshd_config, drop udpgw, wipe data
#
set -euo pipefail

# ---------- configuration ----------
GROUP="sshtunnel"
DATA_DIR="/etc/sshtunnel"
DATA_FILE="${DATA_DIR}/users.json"
CONF_FILE="${DATA_DIR}/sshtunnel.conf"   # holds SERVER_IP / SSH_PORT / SERVER_NAME
SSHD_CONFIG="/etc/ssh/sshd_config"
MARKER_BEGIN="# >>> sshtunnel managed block >>>"
MARKER_END="# <<< sshtunnel managed block <<<"
NOLOGIN="/usr/sbin/nologin"

# badvpn-udpgw (UDP gateway) — bound to loopback; clients reach it via the SSH tunnel.
UDPGW_ADDR="127.0.0.1"
UDPGW_PORT="7300"
UDPGW_SERVICE="badvpn-udpgw"
UDPGW_UNIT="/etc/systemd/system/${UDPGW_SERVICE}.service"
UDPGW_BIN="/usr/local/bin/badvpn-udpgw"
UDPGW_URL="https://github.com/4modx/badvpn-udpgw/raw/refs/heads/main/badvpn-udpgw"

# ---------- colors ----------
if [[ -t 1 ]]; then
  RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLD=$'\033[1m'; RST=$'\033[0m'
else
  RED=""; GRN=""; YLW=""; BLD=""; RST=""
fi
info() { echo "${GRN}[*]${RST} $*"; }
warn() { echo "${YLW}[!]${RST} $*" >&2; }
err()  { echo "${RED}[x]${RST} $*" >&2; }
die()  { err "$*"; exit 1; }

# ---------- helpers ----------
need_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run as root (sudo $0 ...)."
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1 (run --init first)."
}

valid_username() {
  # lowercase start, then lowercase/digit/_/- , max 32 chars
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

load_conf() {
  [[ -f "$CONF_FILE" ]] || die "Config $CONF_FILE not found. Run --init first."
  # shellcheck disable=SC1090
  source "$CONF_FILE"
  : "${SERVER_IP:?SERVER_IP missing in $CONF_FILE}"
  : "${SSH_PORT:?SSH_PORT missing in $CONF_FILE}"
  : "${SERVER_NAME:?SERVER_NAME missing in $CONF_FILE}"
}

gen_password() {
  # 24 url-safe chars, no ':' (would break chpasswd / the ssh:// URI).
  # Read a chunk, filter, then cut — avoids SIGPIPE from `head` closing the pipe.
  local raw
  raw="$(LC_ALL=C tr -dc 'A-Za-z0-9_-' < /dev/urandom 2>/dev/null | dd bs=24 count=1 2>/dev/null)"
  printf '%s' "$raw"
}

# URL-encode a string (for username/password inside the ssh:// URI)
urlencode() {
  local s="$1" i c out=""
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

build_uri() {
  # v2box format: ssh://BASE64(user:password)@host:port?udpgw=PORT#name
  # The userinfo (user:password) is base64-encoded, then URL-encoded (the '='
  # padding becomes %3D). udpgw is a query parameter; name is the fragment.
  local user="$1" pass="$2" b64 enc query=""
  b64="$(printf '%s:%s' "$user" "$pass" | base64 | tr -d '\n')"
  enc="$(urlencode "$b64")"
  if [[ -n "${UDPGW_PORT:-}" ]] && systemctl is-active --quiet "$UDPGW_SERVICE" 2>/dev/null; then
    query="?udpgw=${UDPGW_PORT}"
  fi
  printf 'ssh://%s@%s:%s%s#%s' \
    "$enc" "$SERVER_IP" "$SSH_PORT" "$query" "$(urlencode "$SERVER_NAME")"
}

check_cmd() {
  local user="$1"
  printf 'ssh -D 0.0.0.0:1111 -N -o PreferredAuthentications=keyboard-interactive -o PubkeyAuthentication=no %s@%s -p %s' \
    "$user" "$SERVER_IP" "$SSH_PORT"
}

print_connection() {
  local user="$1" pass="$2" uri cmd
  uri="$(build_uri "$user" "$pass")"
  cmd="$(check_cmd "$user")"
  echo
  echo "${BLD}User:${RST}     $user"
  echo "${BLD}Password:${RST} $pass"
  echo "${BLD}Link:${RST}     $uri"
  echo
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "$uri"
  else
    warn "qrencode not installed; QR skipped. Install with: apt install qrencode"
  fi
  echo
  echo "${BLD}Test command:${RST}"
  echo "  $cmd"
  echo
}

# ---------- data file (jq) ----------
ensure_data_file() {
  mkdir -p "$DATA_DIR"
  chmod 700 "$DATA_DIR"
  if [[ ! -f "$DATA_FILE" ]]; then
    echo '{"users":[]}' > "$DATA_FILE"
  fi
  chmod 600 "$DATA_FILE"
}

db_has() {  # username -> exit 0 if present
  jq -e --arg u "$1" '.users[] | select(.username==$u)' "$DATA_FILE" >/dev/null 2>&1
}

db_get_pass() {
  jq -r --arg u "$1" '.users[] | select(.username==$u) | .password' "$DATA_FILE"
}

db_add() {
  local user="$1" pass="$2" tmp
  tmp="$(mktemp)"
  jq --arg u "$user" --arg p "$pass" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '.users += [{"username":$u,"password":$p,"created_at":$t,"status":"active"}]' \
     "$DATA_FILE" > "$tmp"
  mv "$tmp" "$DATA_FILE"
  chmod 600 "$DATA_FILE"
}

db_del() {
  local user="$1" tmp
  tmp="$(mktemp)"
  jq --arg u "$user" '.users |= map(select(.username != $u))' "$DATA_FILE" > "$tmp"
  mv "$tmp" "$DATA_FILE"
  chmod 600 "$DATA_FILE"
}

# ---------- badvpn-udpgw ----------
setup_udpgw() {
  # Download a prebuilt badvpn-udpgw binary and run it as a loopback-only service.
  if [[ ! -x "$UDPGW_BIN" ]]; then
    info "Downloading badvpn-udpgw binary..."
    if ! curl -fL -o "$UDPGW_BIN" "$UDPGW_URL"; then
      warn "Failed to download badvpn-udpgw from $UDPGW_URL"
      warn "UDP gateway skipped. Place a binary at $UDPGW_BIN and re-run --init to enable it."
      rm -f "$UDPGW_BIN"
      return 0
    fi
    chmod +x "$UDPGW_BIN"
    # sanity: make sure it actually runs on this architecture
    if ! "$UDPGW_BIN" --help >/dev/null 2>&1; then
      warn "Downloaded badvpn-udpgw does not execute (architecture mismatch?)."
      warn "UDP gateway skipped. Remove $UDPGW_BIN or replace with a compatible build."
      rm -f "$UDPGW_BIN"
      return 0
    fi
  fi

  info "Creating systemd unit for $UDPGW_SERVICE (listen ${UDPGW_ADDR}:${UDPGW_PORT})..."
  cat > "$UDPGW_UNIT" <<EOF
[Unit]
Description=BadVPN udpgw (UDP over TCP gateway for SSH tunnel)
After=network.target

[Service]
ExecStart=${UDPGW_BIN} --listen-addr ${UDPGW_ADDR}:${UDPGW_PORT} --max-clients 1024 --max-connections-for-client 256
Restart=on-failure
RestartSec=3
# Hardening: no privileges needed, loopback-only.
DynamicUser=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$UDPGW_SERVICE" >/dev/null 2>&1 || systemctl restart "$UDPGW_SERVICE"
  if systemctl is-active --quiet "$UDPGW_SERVICE"; then
    info "$UDPGW_SERVICE running on ${UDPGW_ADDR}:${UDPGW_PORT}."
  else
    warn "$UDPGW_SERVICE failed to start; check: journalctl -u $UDPGW_SERVICE"
  fi
}

remove_udpgw() {
  if systemctl list-unit-files 2>/dev/null | grep -q "^${UDPGW_SERVICE}.service"; then
    info "Stopping and removing $UDPGW_SERVICE..."
    systemctl disable --now "$UDPGW_SERVICE" >/dev/null 2>&1 || true
  fi
  if [[ -f "$UDPGW_UNIT" ]]; then
    rm -f "$UDPGW_UNIT"
    systemctl daemon-reload
    info "Removed $UDPGW_UNIT."
  fi
  if [[ -f "$UDPGW_BIN" ]]; then
    rm -f "$UDPGW_BIN"
    info "Removed $UDPGW_BIN."
  fi
}

# ---------- commands ----------
cmd_init() {
  need_root
  info "Installing dependencies..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq jq qrencode openssh-server curl >/dev/null

  info "Ensuring group '$GROUP'..."
  getent group "$GROUP" >/dev/null || groupadd "$GROUP"

  ensure_data_file

  # gather server params if config absent
  if [[ ! -f "$CONF_FILE" ]]; then
    info "Collecting server parameters..."
    local detected_ip
    detected_ip="$(curl -fsS https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
    read -rp "SERVER_IP [${detected_ip}]: " in_ip;   in_ip="${in_ip:-$detected_ip}"
    read -rp "SSH_PORT [22]: "            in_port; in_port="${in_port:-22}"
    read -rp "SERVER_NAME [$(hostname)]: " in_name; in_name="${in_name:-$(hostname)}"
    cat > "$CONF_FILE" <<EOF
SERVER_IP="${in_ip}"
SSH_PORT="${in_port}"
SERVER_NAME="${in_name}"
EOF
    chmod 600 "$CONF_FILE"
    info "Wrote $CONF_FILE"
  else
    info "Config already exists: $CONF_FILE (leaving as-is)"
  fi

  # insert sshd Match block idempotently with backup + validation + rollback
  if grep -qF "$MARKER_BEGIN" "$SSHD_CONFIG"; then
    info "sshd Match block already present; skipping insertion."
  else
    local backup
    backup="${SSHD_CONFIG}.bak.$(date +%s)"
    cp "$SSHD_CONFIG" "$backup"
    info "Backed up sshd_config -> $backup"

    cat >> "$SSHD_CONFIG" <<EOF

$MARKER_BEGIN
# Tunnel-only users: port-forwarding only, no shell.
# NOTE: cloud images may set 'PasswordAuthentication no' in
# /etc/ssh/sshd_config.d/*.conf — this Match block overrides it for the group.
Match Group $GROUP
    PasswordAuthentication yes
    KbdInteractiveAuthentication yes
    AllowTcpForwarding yes
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    GatewayPorts no
    X11Forwarding no
    PermitTTY no
    PermitTunnel no
    ForceCommand $NOLOGIN
$MARKER_END
EOF

    if sshd -t 2>/tmp/sshd_test.err; then
      info "sshd config valid."
      systemctl restart ssh 2>/dev/null || systemctl restart sshd
      info "sshd restarted."
    else
      err "sshd config INVALID — rolling back."
      cat /tmp/sshd_test.err >&2
      cp "$backup" "$SSHD_CONFIG"
      die "Restored original sshd_config. No changes applied to ssh service."
    fi
  fi

  # verify effective config for the group
  info "Verifying effective sshd settings for group '$GROUP':"
  sshd -T -C "user=root,group=${GROUP},host=any,addr=1.2.3.4" \
    | grep -iE 'passwordauthentication|kbdinteractiveauthentication' || true

  # UDP gateway for clients that need UDP (v2box etc.)
  setup_udpgw

  echo
  info "${BLD}Init complete.${RST}"
  echo "allow connections to 7300 port: sudo ufw allow 7300 && sudo ufw reload"
  echo "  UDP gateway (udpgw): ${UDPGW_ADDR}:${UDPGW_PORT} (loopback only)."
  echo "    In the client (v2box): set udpgw port to ${UDPGW_PORT} for UDP, or 0 to disable UDP."
  warn "Keep your CURRENT ssh session open and verify a new login works before disconnecting."
  warn "Data file $DATA_FILE stores plaintext passwords (needed to reprint links). It is chmod 600 — keep it protected."
}

cmd_new() {
  need_root
  require_cmd jq
  load_conf
  ensure_data_file

  local user="$1"
  valid_username "$user" || die "Invalid username. Allowed: ^[a-z_][a-z0-9_-]{0,31}$"
  getent group "$GROUP" >/dev/null || die "Group '$GROUP' missing. Run --init."

  # collision checks: system AND data file
  if getent passwd "$user" >/dev/null; then
    die "System user '$user' already exists."
  fi
  if db_has "$user"; then
    die "User '$user' already tracked in $DATA_FILE (out of sync with system?)."
  fi

  local pass
  pass="$(gen_password)"

  info "Creating system user '$user'..."
  useradd -m -s "$NOLOGIN" -G "$GROUP" "$user"

  info "Setting password..."
  printf '%s:%s\n' "$user" "$pass" | chpasswd

  # sanity: group membership + password hash present
  if ! id -nG "$user" | tr ' ' '\n' | grep -qx "$GROUP"; then
    userdel -r "$user" 2>/dev/null || true
    die "User not in group '$GROUP' after creation; aborted and cleaned up."
  fi

  db_add "$user" "$pass"
  info "Tracked in $DATA_FILE."

  print_connection "$user" "$pass"
}

cmd_qr() {
  require_cmd jq
  load_conf
  ensure_data_file

  local user="$1"
  valid_username "$user" || die "Invalid username."
  db_has "$user" || die "User '$user' not found in $DATA_FILE."

  # warn if system/data out of sync
  if ! getent passwd "$user" >/dev/null; then
    warn "User '$user' is in data file but NOT in system (revoked?). Link may not work."
  fi

  local pass
  pass="$(db_get_pass "$user")"
  print_connection "$user" "$pass"
}

cmd_delete() {
  need_root
  require_cmd jq
  ensure_data_file

  local user="$1"
  valid_username "$user" || die "Invalid username."

  local in_system=0 in_db=0
  getent passwd "$user" >/dev/null && in_system=1
  db_has "$user" && in_db=1

  [[ "$in_system" -eq 0 && "$in_db" -eq 0 ]] && die "User '$user' not found anywhere."

  if [[ "$in_system" -eq 1 ]]; then
    info "Removing system user '$user'..."
    # kill any live sessions of this user first, ignore errors
    pkill -KILL -u "$user" 2>/dev/null || true
    userdel -r "$user" 2>/dev/null || userdel "$user"
  else
    warn "No system user '$user' (already gone)."
  fi

  if [[ "$in_db" -eq 1 ]]; then
    db_del "$user"
    info "Removed from $DATA_FILE."
  fi

  info "${BLD}Revoked '$user'.${RST}"
}

cmd_list() {
  require_cmd jq
  ensure_data_file
  local count
  count="$(jq '.users | length' "$DATA_FILE")"
  if [[ "$count" -eq 0 ]]; then
    info "No users."
    return
  fi
  printf "%-24s %-8s %s\n" "USERNAME" "SYSTEM" "CREATED"
  jq -r '.users[] | "\(.username)\t\(.created_at)"' "$DATA_FILE" \
  | while IFS=$'\t' read -r u created; do
      if getent passwd "$u" >/dev/null; then sys="yes"; else sys="MISSING"; fi
      printf "%-24s %-8s %s\n" "$u" "$sys" "$created"
    done
}

cmd_uninstall() {
  need_root

  echo "${BLD}${RED}This will permanently:${RST}"
  echo "  - delete ALL tunnel users (system accounts + home dirs) in group '$GROUP'"
  echo "  - remove the sshd Match block and restart ssh"
  echo "  - stop and remove the $UDPGW_SERVICE service"
  echo "  - delete group '$GROUP'"
  echo "  - wipe $DATA_DIR (including the JSON with passwords)"
  echo
  read -rp "Type 'yes' to proceed: " confirm
  [[ "$confirm" == "yes" ]] || die "Aborted."

  # 1) remove all tunnel users. Source of truth: members of the group (covers
  #    system users even if the JSON is out of sync), plus anything in JSON.
  local users=()
  # from system group membership
  if getent group "$GROUP" >/dev/null; then
    local gline members
    gline="$(getent group "$GROUP")"
    members="${gline##*:}"
    if [[ -n "$members" ]]; then
      IFS=',' read -ra m <<< "$members"
      users+=("${m[@]}")
    fi
  fi
  # from JSON (in case any were removed from group but linger in data)
  if [[ -f "$DATA_FILE" ]] && command -v jq >/dev/null 2>&1; then
    while IFS= read -r u; do [[ -n "$u" ]] && users+=("$u"); done \
      < <(jq -r '.users[].username' "$DATA_FILE" 2>/dev/null)
  fi
  # dedup
  if [[ ${#users[@]} -gt 0 ]]; then
    mapfile -t users < <(printf '%s\n' "${users[@]}" | sort -u)
    for u in "${users[@]}"; do
      # safety: only touch accounts that are actually in the tunnel group
      if id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx "$GROUP"; then
        info "Removing user '$u'..."
        pkill -KILL -u "$u" 2>/dev/null || true
        userdel -r "$u" 2>/dev/null || userdel "$u" 2>/dev/null || warn "Could not remove '$u'."
      else
        warn "Skipping '$u' (not a member of '$GROUP'; not touching it)."
      fi
    done
  else
    info "No tunnel users found."
  fi

  # 2) remove sshd Match block (between markers), with backup + validate + rollback
  if grep -qF "$MARKER_BEGIN" "$SSHD_CONFIG"; then
    local backup tmp
    backup="${SSHD_CONFIG}.bak.$(date +%s)"
    cp "$SSHD_CONFIG" "$backup"
    info "Backed up sshd_config -> $backup"
    tmp="$(mktemp)"
    # delete inclusive range between markers; also drop a leading blank line if present
    sed "/^${MARKER_BEGIN}$/,/^${MARKER_END}$/d" "$SSHD_CONFIG" > "$tmp"
    # collapse trailing blank lines left behind
    sed -i -e ':a' -e '/^\n*$/{$d;N;ba' -e '}' "$tmp" 2>/dev/null || true
    if sshd -t -f "$tmp" 2>/tmp/sshd_test.err; then
      mv "$tmp" "$SSHD_CONFIG"
      systemctl restart ssh 2>/dev/null || systemctl restart sshd
      info "Removed Match block; ssh restarted."
    else
      err "Resulting sshd config invalid — keeping original, NOT modifying ssh."
      cat /tmp/sshd_test.err >&2
      rm -f "$tmp"
    fi
  else
    info "No managed Match block found in sshd_config."
  fi

  # 3) drop udpgw service
  remove_udpgw

  # 4) delete group
  if getent group "$GROUP" >/dev/null; then
    if groupdel "$GROUP" 2>/dev/null; then
      info "Deleted group '$GROUP'."
    else
      warn "Could not delete group '$GROUP' (still has members?)."
    fi
  fi

  # 5) wipe data dir
  if [[ -d "$DATA_DIR" ]]; then
    rm -rf "$DATA_DIR"
    info "Wiped $DATA_DIR."
  fi

  info "${BLD}Uninstall complete.${RST}"
  warn "sshd_config backups (${SSHD_CONFIG}.bak.*) were kept. Remove them manually if not needed."
}

usage() {
  cat <<EOF
${BLD}v2box.sh${RST} — manage SSH tunnel-only users (Ubuntu)

Usage:
  sudo $0 --init                one-time setup (deps, group, sshd_config, udpgw)
  sudo $0 --new    <username>   create user, print link + QR
       $0 --qr     <username>   reprint link + QR
  sudo $0 --delete <username>   revoke user
       $0 --list                list users
  sudo $0 --uninstall           remove ALL users, revert configs, drop udpgw, wipe data

Notes:
  - Users get shell $NOLOGIN and group '$GROUP'; only port-forwarding is allowed.
  - Connection URI: ssh://user:password@SERVER_IP:SSH_PORT#SERVER_NAME
  - Data: $DATA_FILE (plaintext passwords, chmod 600).
EOF
}

# ---------- dispatch ----------
[[ $# -ge 1 ]] || { usage; exit 1; }

case "$1" in
  --init)   cmd_init ;;
  --new)    [[ $# -eq 2 ]] || die "Usage: $0 --new <username>";    cmd_new "$2" ;;
  --qr)     [[ $# -eq 2 ]] || die "Usage: $0 --qr <username>";     cmd_qr "$2" ;;
  --delete) [[ $# -eq 2 ]] || die "Usage: $0 --delete <username>"; cmd_delete "$2" ;;
  --list)   cmd_list ;;
  --uninstall) cmd_uninstall ;;
  -h|--help) usage ;;
  *) err "Unknown command: $1"; usage; exit 1 ;;
esac

#!/bin/sh
# =============================================================================
# blueteam.sh - blue team toolkit for Ubuntu 24.04 competition boxes
#
#   sudo sh blueteam.sh           interactive menu (first run asks for settings)
#   sudo sh blueteam.sh watch     live connection view with kill/block keys
#   sudo sh blueteam.sh help      all subcommands
#
# On start it checks /usr/bin/bash against Ubuntu's signed bash package and
# reinstalls bash if it was replaced. It then re-runs itself in that bash with
# a clean environment: no aliases, functions, rc files or LD_PRELOAD.
#
# Firewall model (no default-drop allowed here): specific IPs and ports are
# blocked in the BT-IN / BT-OUT / BT-FWD chains. Those chains are hooked in
# first on INPUT, OUTPUT, FORWARD and DOCKER-USER. The blueteam-guard service
# puts them back within 2 seconds if anything flushes them.
#
# Files:  /etc/blueteam/            settings, block.ips, block.ports, allow.ips
#         /root/evidence/           anything removed is copied here first
#         /var/log/blueteam.log     every action taken
#         /usr/local/sbin/blueteam  installed copy (used by the guard service)
# =============================================================================

# ------------------------------------------------- bootstrap (POSIX sh only)
if [ -z "${BT_TRUSTED:-}" ]; then
  if [ "$(id -u)" != 0 ]; then echo "Run as root: sudo sh $0" >&2; exit 1; fi
  PATH=/usr/sbin:/usr/bin:/sbin:/bin; export PATH
  unset LD_PRELOAD LD_LIBRARY_PATH BASH_ENV ENV
  BT_SELF=$(readlink -f "$0")
  echo "[*] Checking /usr/bin/bash against Ubuntu's bash package..."
  bv=$(dpkg-query -W -f='${Version}' bash 2>/dev/null)
  ba=$(dpkg-query -W -f='${Architecture}' bash 2>/dev/null)
  rv=$(apt-cache madison bash 2>/dev/null | awk -F'|' -v v="$bv" '{gsub(/[ \t]/,"",$2); if (NR==1) f=$2; if ($2==v) m=$2} END{print (m!="" ? m : f)}')
  if [ -z "$rv" ]; then
    apt-get -qq update >/dev/null 2>&1
    rv=$(apt-cache madison bash 2>/dev/null | awk -F'|' -v v="$bv" '{gsub(/[ \t]/,"",$2); if (NR==1) f=$2; if ($2==v) m=$2} END{print (m!="" ? m : f)}')
  fi
  deb="/var/cache/apt/archives/bash_$(printf %s "$rv" | sed 's/:/%3a/')_${ba}.deb"
  if [ -n "$rv" ] && [ ! -f "$deb" ]; then
    apt-get -qq install -y --reinstall --allow-downgrades --download-only "bash=$rv" >/dev/null 2>&1
  fi
  good=""
  if [ -f "$deb" ]; then
    member=$(dpkg-deb -c "$deb" | awk '{print $6}' | grep -E '^\./(usr/)?bin/bash$' | head -1)
    good=$(dpkg-deb --fsys-tarfile "$deb" | tar -xOf - "$member" 2>/dev/null | sha256sum | cut -d' ' -f1)
  fi
  have=$(sha256sum /usr/bin/bash 2>/dev/null | cut -d' ' -f1)
  if [ -z "$good" ]; then
    echo "[!] Couldn't get bash from apt to check against, so this bash can't be verified."
    printf "    Continue with it anyway? [y/N] "; read -r a
    case "$a" in y|Y) ;; *) exit 1 ;; esac
  elif [ "$good" != "$have" ] || [ "$bv" != "$rv" ]; then
    echo "[!] /usr/bin/bash does NOT match Ubuntu's package (installed $bv, archive $rv). Reinstalling..."
    mkdir -p /root/evidence && cp /usr/bin/bash "/root/evidence/bash.replaced.$(date +%s)" 2>/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall --allow-downgrades "bash=$rv" || { echo "[x] Reinstall failed." >&2; exit 1; }
    have=$(sha256sum /usr/bin/bash | cut -d' ' -f1)
    [ "$good" = "$have" ] || { echo "[x] bash still doesn't match after reinstalling. Stopping." >&2; exit 1; }
    echo "[+] bash reinstalled and verified."
  else
    echo "[+] bash matches Ubuntu's package."
  fi
  exec env -i BT_TRUSTED=1 BT_SELF="$BT_SELF" PATH="$PATH" HOME=/root TERM="${TERM:-xterm}" \
       LANG=C.UTF-8 TMUX="${TMUX:-}" TMUX_PANE="${TMUX_PANE:-}" \
       /usr/bin/bash --norc --noprofile "$BT_SELF" "$@"
fi
# Everything below needs bash. If something started this part under another shell, switch.
if [ -z "${BASH_VERSION:-}" ]; then exec /usr/bin/bash --norc --noprofile "$0" "$@"; fi

# ============================================================ bash from here on
set -uo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

BT_SELF=${BT_SELF:-$(readlink -f "$0")}
BT_ETC=/etc/blueteam
CONF=$BT_ETC/blueteam.conf
BLOCK_IPS=$BT_ETC/block.ips
BLOCK_PORTS=$BT_ETC/block.ports
ALLOW_IPS=$BT_ETC/allow.ips
PINNED=$BT_ETC/apt-blocked
EVID=/root/evidence
LOG=/var/log/blueteam.log
BIN=/usr/local/sbin/blueteam
RUN=/run/blueteam
DEFAULT_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDaWz6/2+JQMrIo0DI7vvwiLfdxxMrZIDl/BUKNwRUF6 root@vm-1'

mkdir -p "$BT_ETC" "$EVID" "$RUN"
touch "$BLOCK_IPS" "$BLOCK_PORTS" "$ALLOW_IPS" "$PINNED" "$LOG"
chmod 700 "$BT_ETC" "$EVID"

PROTECT_PORTS="22"; TEAM_KEY=$DEFAULT_KEY; DOCKER_BOX=0; COMPOSE_DIR=""; DOCKER_HEAL=1
# Accounts that get the deploy key (root always does). Everyone else gets no SSH keys.
KEY_USERS="root charliebrown lucyvanpelt"
# Ubuntu 24.04 system accounts to keep (anything an installed package created is kept too)
KEEP_SYSTEM="root daemon bin sys sync games man lp mail news uucp proxy www-data backup list irc _apt nobody systemd-network systemd-timesync dhcpcd messagebus syslog systemd-resolve polkitd cyberrange sshd"
# Accounts the scored services create (postfix, MySQL; Samba and Docker don't add login accounts)
SERVICE_USERS="postfix mysql"
# Grey team: never removed, locked, re-keyed, killed or given new passwords
GREY_USERS="grayteam othergrayteam violetgray"
# Cyber range infrastructure accounts: hands off, same as grey team
RANGE_USERS="cyberrange"
ADMIN_USERS="charliebrown lucyvanpelt linusvanpelt peppermintpatty marcie"
NORMAL_USERS="snoopy woodstock sallybrown schroeder pigpen"
# Groups that are as good as root; only root and admins belong in them
PRIV_GROUPS="sudo admin wheel docker lxd"
# Known red team addresses. a.b.c.d-e is a range.
KNOWN_BAD_IPS="192.168.10.212 192.168.10.53 192.168.2.1-5 10.0.2.1-2"
# If this box is in one of these ranges, every OTHER address in it gets blocked.
NEIGHBOR_RANGES="192.168.1.1-5 10.0.1.1-2"
# Red team files and folders: processes and units using them are killed/disarmed, then they're removed.
IOC_REMOVE="/tmp/netcomms /var/hwmonitord /etc/sysbusd /etc/ssh/kernelops /var/systemd-rysncd /etc/systemd/system/systemd-network.service"
# Real Ubuntu files the red team replaced or edited: checked against the package and reinstalled, never deleted.
IOC_PKGFILES="/usr/lib/systemd/systemd-logind /usr/lib/systemd/systemd-executor /usr/bin/python3.12 /usr/lib/systemd/system/nftables.service /usr/lib/systemd/system/ufw.service /usr/lib/systemd/system/firewalld.service"
# shellcheck source=/dev/null
[[ -f $CONF ]] && source "$CONF"

CORE_PKGS="bash dash coreutils util-linux procps iproute2 iptables libxtables12 libip4tc2 libip6tc2
libnftnl11 nftables libnftables1 findutils grep sed mawk gawk tar gzip passwd login openssh-server
openssh-client openssh-sftp-server sudo systemd libsystemd0 libpam-modules libpam-modules-bin
libpam-runtime libpam0g kmod psmisc lsof net-tools apt dpkg libc6 libc-bin tmux auditd conntrack
python3.12-minimal libpython3.12-minimal"

# ------------------------------------------------------------------ helpers
if [[ -t 1 ]]; then
  C_B=$'\033[1;34m' C_G=$'\033[1;32m' C_Y=$'\033[1;33m' C_R=$'\033[1;31m' C_0=$'\033[0m'
else
  C_B="" C_G="" C_Y="" C_R="" C_0=""
fi
say()  { printf '%s[*]%s %s\n' "$C_B" "$C_0" "$*"; }
good() { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*"; }
bad()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*"; }
hdr()  { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }
have() { command -v "$1" >/dev/null 2>&1; }
logact() {
  local ts; printf -v ts '%(%F %T)T' -1
  printf '%s %s\n' "$ts" "$*" >> "$LOG"
  [[ ${BT_GUARD:-0} == 1 ]] && printf '%s\n' "$*"
  return 0
}
confirm()     { local a; read -r -p "$1 [y/N] " a; [[ $a =~ ^[Yy] ]]; }
confirm_yes() { local a; read -r -p "$1 [Y/n] " a; [[ ! $a =~ ^[Nn] ]]; }
pause()       { local _a; read -r -p "Press Enter to return to the menu..." _a; }
evdir() { local d; printf -v d '%s/%s-%(%Y%m%d-%H%M%S)T' "$EVID" "$1" -1; mkdir -p "$d"; printf '%s' "$d"; }
stash() {   # stash EVIDENCE_DIR path... : copy keeping the full path
  local d=$1 f; shift
  for f in "$@"; do
    if [[ -e $f || -L $f ]]; then cp -a --parents -- "$f" "$d/" 2>/dev/null; fi
  done
}
installed() { [[ $(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null) == ii* ]]; }
pick() {    # pick COUNT "prompt" -> PICKED=(1-based indexes)
  local n=$1 ans a i; PICKED=()
  read -r -p "$2 (e.g. 1 3 5-7, 'all', Enter for none): " ans
  [[ -z $ans ]] && return 1
  if [[ $ans == all ]]; then for ((i = 1; i <= n; i++)); do PICKED+=("$i"); done; return 0; fi
  for a in ${ans//,/ }; do
    if [[ $a =~ ^([0-9]+)-([0-9]+)$ ]]; then
      for ((i = BASH_REMATCH[1]; i <= BASH_REMATCH[2]; i++)); do ((i >= 1 && i <= n)) && PICKED+=("$i"); done
    elif [[ $a =~ ^[0-9]+$ ]] && ((a >= 1 && a <= n)); then PICKED+=("$a"); fi
  done
  ((${#PICKED[@]}))
}
valid_ip() {
  [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || [[ $1 =~ ^[0-9a-fA-F]*:[0-9a-fA-F:]*(/[0-9]{1,3})?$ ]]
}
local_ips() { ip -o addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1]}'; }
ppid_of()   { awk '/^PPid:/{print $2}' "/proc/$1/status" 2>/dev/null; }
in_container() {   # Docker/containerd/k8s/LXC processes, by cgroup (not mount namespace:
                   # systemd services with PrivateTmp= have their own one too)
  grep -qE '/(docker|containerd|kubepods|libpod|lxc|machine\.slice)[/-]|docker-[0-9a-f]{12,}\.scope' "/proc/$1/cgroup" 2>/dev/null
}
unit_of() {   # systemd .service a PID belongs to (system units only)
  local cg; cg=$(tail -1 "/proc/$1/cgroup" 2>/dev/null)
  [[ $cg == *user@* ]] && return
  cg=${cg##*/}; [[ $cg == *.service ]] && printf '%s' "$cg"
}

# unowned: read paths on stdin, print the ones no installed package owns
unowned() {
  local -a in=() miss=(); local p a
  mapfile -t in
  ((${#in[@]})) || return 0
  mapfile -t miss < <(dpkg-query -S -- "${in[@]}" 2>&1 >/dev/null | sed -n 's/^dpkg-query: no path found matching pattern //p')
  for p in "${miss[@]}"; do
    case $p in
      /usr/lib/*|/usr/bin/*|/usr/sbin/*) a=${p#/usr} ;;
      /lib/*|/bin/*|/sbin/*) a=/usr$p ;;
      *) a="" ;;
    esac
    if [[ -n $a ]] && dpkg-query -S -- "$a" >/dev/null 2>&1; then continue; fi
    printf '%s\n' "$p"
  done
}

save_conf() {
  {
    echo "# blueteam.sh settings for this box"
    printf 'PROTECT_PORTS=%q\n' "$PROTECT_PORTS"
    printf 'TEAM_KEY=%q\n' "$TEAM_KEY"
    printf 'DOCKER_BOX=%q\n' "$DOCKER_BOX"
    printf 'COMPOSE_DIR=%q\n' "$COMPOSE_DIR"
    printf 'DOCKER_HEAL=%q\n' "$DOCKER_HEAL"
    printf 'KEY_USERS=%q\n' "$KEY_USERS"
    printf 'KEEP_SYSTEM=%q\n' "$KEEP_SYSTEM"
    printf 'SERVICE_USERS=%q\n' "$SERVICE_USERS"
    printf 'GREY_USERS=%q\n' "$GREY_USERS"
    printf 'RANGE_USERS=%q\n' "$RANGE_USERS"
    printf 'ADMIN_USERS=%q\n' "$ADMIN_USERS"
    printf 'NORMAL_USERS=%q\n' "$NORMAL_USERS"
    printf 'PRIV_GROUPS=%q\n' "$PRIV_GROUPS"
    printf 'KNOWN_BAD_IPS=%q\n' "$KNOWN_BAD_IPS"
    printf 'NEIGHBOR_RANGES=%q\n' "$NEIGHBOR_RANGES"
    printf 'IOC_REMOVE=%q\n' "$IOC_REMOVE"
    printf 'IOC_PKGFILES=%q\n' "$IOC_PKGFILES"
  } > "$CONF"
  chmod 600 "$CONF"
}

install_self() {
  [[ $BT_SELF == "$BIN" ]] && return 0
  install -D -m 700 "$BT_SELF" "$BIN"
}

pin_block() {   # stop apt from installing these packages again
  local p
  for p in "$@"; do grep -qxF "$p" "$PINNED" || echo "$p" >> "$PINNED"; done
  {
    echo "# Written by blueteam.sh: these packages may not be installed."
    echo "Package: $(tr '\n' ' ' < "$PINNED")"
    echo "Pin: release a=*"
    echo "Pin-Priority: -1"
  } > /etc/apt/preferences.d/blueteam-blocked
}

# ------------------------------------------------------------- protection
# Things the toolkit will never kill or block: your own session (and tmux
# clients), anything on a protected port, core system/docker processes,
# never-block IPs, this box's own addresses.
compute_protected() {
  local -a roots=("$$"); local p ip pid u
  PROT_PIDS=" 1 "; PROT_IPS=" "; PROT_UNITS=" "
  if [[ -n ${TMUX:-} ]] && have tmux; then
    mapfile -t -O 1 roots < <(tmux list-clients -F '#{client_pid}' 2>/dev/null)
    roots[0]=$$
  fi
  for p in "${roots[@]}"; do
    while [[ -n $p && $p =~ ^[0-9]+$ && $p -gt 1 ]]; do
      PROT_PIDS+="$p "
      p=$(ppid_of "$p")
    done
  done
  for p in $PROTECT_PORTS; do
    while read -r pid; do
      PROT_PIDS+="$pid "
      u=$(unit_of "$pid"); [[ -n $u ]] && PROT_UNITS+="$u "
    done < <(ss -tulnpH "sport = :$p" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
  done
  for p in $PROT_PIDS; do
    [[ $(cat "/proc/$p/comm" 2>/dev/null) == sshd* ]] || continue
    while read -r ip; do PROT_IPS+="$ip "; done < <(ss -tnpH 2>/dev/null | grep "pid=$p," |
      awk '{print $5}' | sed -E 's/:[0-9]+$//; s/^\[//; s/\]$//; s/^::ffff://')
  done
}
is_protected_ip() {
  local ip=${1%/*} x
  PROT_WHY=""
  case $ip in 127.*|::1|0.0.0.0|::) PROT_WHY="loopback/any address"; return 0 ;; esac
  while read -r x; do [[ $x == "$ip" ]] && { PROT_WHY="it's this box's own address"; return 0; }; done < <(local_ips)
  while read -r x; do
    x=${x%%#*}; x=${x//[[:space:]]/}
    [[ -n $x && ( $x == "$1" || $x == "$ip" ) ]] && { PROT_WHY="it's on the never-block list"; return 0; }
  done < "$ALLOW_IPS"
  [[ " ${PROT_IPS:-} " == *" $ip "* ]] && { PROT_WHY="it's your own SSH connection"; return 0; }
  return 1
}
is_protected_pid() {
  local p=$1 c
  PROT_WHY=""
  [[ " ${PROT_PIDS:-} " == *" $p "* ]] && { PROT_WHY="part of your session or a protected service"; return 0; }
  in_container "$p" && { PROT_WHY="inside a container (use docker)"; return 0; }
  local owner; owner=$(getent passwd "$(awk '/^Uid:/{print $2}' "/proc/$p/status" 2>/dev/null)" | cut -d: -f1)
  [[ -n $owner && " $GREY_USERS $RANGE_USERS " == *" $owner "* ]] && { PROT_WHY="it belongs to hands-off account $owner"; return 0; }
  c=$(cat "/proc/$p/comm" 2>/dev/null)
  case $c in
    systemd|init|dockerd|containerd|containerd-shim*|docker-proxy|systemd-*|dbus-daemon|tmux*|agetty)
      # Only the real thing is protected: a "systemd-something" running a
      # deleted file or a file no package installed is an impostor.
      local exe; exe=$(readlink "/proc/$p/exe" 2>/dev/null)
      [[ -z $exe || $exe == *" (deleted)" ]] && return 1
      [[ -n $(printf '%s\n' "$exe" | unowned) ]] && return 1
      PROT_WHY="$c is a protected system process"; return 0 ;;
  esac
  return 1
}
is_protected_unit() {
  [[ $1 == blueteam-guard.service ]] && return 0
  [[ " ${PROT_UNITS:-} " == *" $1 "* ]] && return 0
  case $1 in
    ssh.service|sshd.service|systemd-*|docker.service|containerd.service|dbus*.service|getty@*|serial-getty@*|\
    user@*|polkit.service|snapd*|multipathd.service|rsyslog.service|apache2.service|nginx.service)
      # protected only if its unit file really comes from a package
      local fp; fp=$(systemctl show -p FragmentPath --value "$1" 2>/dev/null)
      [[ -f $fp && -z $(printf '%s\n' "$fp" | unowned) ]] && return 0 ;;
  esac
  return 1
}

# ------------------------------------------------------------ firewall core
fw_fingerprint() {
  local t
  for t in iptables ip6tables; do
    have "$t" && "$t" -S 2>/dev/null | grep -E -- '^-A (BT-|INPUT -j BT-|OUTPUT -j BT-|FORWARD -j BT-|DOCKER-USER -j BT-)'
  done | md5sum | cut -d' ' -f1
}
fw_apply() {
  (
    exec 9> "$RUN/fw.lock"; flock -w 10 9
    local t ip dir proto port p c hook ch tg
    for t in iptables ip6tables; do
      have "$t" || continue
      for c in BT-IN BT-OUT BT-FWD; do "$t" -N "$c" 2>/dev/null; "$t" -F "$c"; done
      while read -r ip; do
        ip=${ip%%#*}; ip=${ip//[[:space:]]/}; [[ -n $ip ]] || continue
        if [[ $ip == *:* ]]; then [[ $t == ip6tables ]] || continue; else [[ $t == iptables ]] || continue; fi
        "$t" -A BT-IN  -s "$ip" -j DROP
        "$t" -A BT-OUT -d "$ip" -j DROP
        "$t" -A BT-FWD -s "$ip" -j DROP
        "$t" -A BT-FWD -d "$ip" -j DROP
      done < "$BLOCK_IPS"
      while IFS=: read -r dir proto port; do
        [[ $dir == in || $dir == out ]] || continue
        [[ $port =~ ^[0-9]+$ ]] || continue
        for p in $([[ $proto == both ]] && echo tcp udp || echo "$proto"); do
          if [[ $dir == in ]]; then "$t" -A BT-IN -p "$p" --dport "$port" -j DROP
          else "$t" -A BT-OUT -p "$p" --dport "$port" -j DROP; fi
          "$t" -A BT-FWD -p "$p" --dport "$port" -j DROP
        done
      done < <(sed 's/#.*//; s/[[:space:]]//g' "$BLOCK_PORTS")
      # Count-only rule (no target): makes the kernel track connections, so
      # conntrack sees every new flow. It drops nothing.
      "$t" -A BT-IN -m conntrack --ctstate NEW 2>/dev/null
      for hook in INPUT:BT-IN OUTPUT:BT-OUT FORWARD:BT-FWD DOCKER-USER:BT-FWD; do
        ch=${hook%%:*}; tg=${hook#*:}
        "$t" -S "$ch" >/dev/null 2>&1 || continue
        while "$t" -D "$ch" -j "$tg" 2>/dev/null; do :; done
        "$t" -I "$ch" 1 -j "$tg"
      done
    done
    fw_fingerprint > "$RUN/fw.fp"
  )
}
fw_intact() { [[ -f $RUN/fw.fp && $(fw_fingerprint) == "$(< "$RUN/fw.fp")" ]]; }

block_ip() {   # sets BL_MSG
  local ip=$1
  valid_ip "$ip" || { BL_MSG="'$ip' isn't a valid IP address or CIDR."; return 1; }
  compute_protected
  if is_protected_ip "$ip"; then BL_MSG="Not blocking $ip: $PROT_WHY."; return 1; fi
  if grep -qxF -- "$ip" "$BLOCK_IPS"; then fw_apply; BL_MSG="$ip was already blocked (rules re-applied)."; return 0; fi
  echo "$ip" >> "$BLOCK_IPS"
  fw_apply
  ss -K dst "$ip" >/dev/null 2>&1
  if have conntrack; then conntrack -D -s "$ip" >/dev/null 2>&1; conntrack -D -d "$ip" >/dev/null 2>&1; fi
  BL_MSG="Blocked $ip (in, out and forwarded) and closed its open connections."
  logact "block ip $ip"
}
block_port() {   # spec in|out:tcp|udp|both:PORT ; sets BL_MSG
  local spec=$1 dir proto port
  [[ $spec =~ ^(in|out):(tcp|udp|both):([0-9]{1,5})$ ]] || { BL_MSG="Bad port rule '$spec' (format: in|out:tcp|udp|both:PORT)."; return 1; }
  dir=${BASH_REMATCH[1]} proto=${BASH_REMATCH[2]} port=${BASH_REMATCH[3]}
  ((port >= 1 && port <= 65535)) || { BL_MSG="Port $port is out of range."; return 1; }
  if [[ $dir == in && " $PROTECT_PORTS " == *" $port "* ]]; then
    BL_MSG="Not blocking inbound port $port: it's a protected/scored port (change in Settings)."; return 1
  fi
  if grep -qxF -- "$spec" "$BLOCK_PORTS"; then fw_apply; BL_MSG="$spec was already blocked (rules re-applied)."; return 0; fi
  echo "$spec" >> "$BLOCK_PORTS"
  fw_apply
  if [[ $dir == in ]]; then ss -K "( sport = :$port )" >/dev/null 2>&1; else ss -K "( dport = :$port )" >/dev/null 2>&1; fi
  [[ $proto == both ]] && proto="tcp+udp"
  if [[ $dir == in ]]; then BL_MSG="Blocked inbound $proto to port $port."; else BL_MSG="Blocked outbound $proto to remote port $port."; fi
  logact "block port $spec"
}

# ---------------------------------------------------------- kill + disarm
kill_targets() {   # PIDs... ; sets KT_MSG
  compute_protected
  local -a pids=() units=() skipped=() alive=(); local p u c ev frag
  for p in "$@"; do
    [[ $p =~ ^[0-9]+$ && -d /proc/$p ]] || continue
    if is_protected_pid "$p"; then skipped+=("$p ($PROT_WHY)"); continue; fi
    pids+=("$p")
  done
  if ((${#pids[@]} == 0)); then
    KT_MSG="Nothing killed."; ((${#skipped[@]})) && KT_MSG+=" Protected: ${skipped[*]}"
    return 1
  fi
  ev=$(evdir killed)
  for p in "${pids[@]}"; do
    c=$(cat "/proc/$p/comm" 2>/dev/null)
    {
      echo "pid=$p comm=$c exe=$(readlink "/proc/$p/exe")"
      echo "cmdline=$(tr '\0' ' ' < "/proc/$p/cmdline")"
      grep -E '^(PPid|Uid|State)' "/proc/$p/status"
      cat "/proc/$p/cgroup"
    } > "$ev/$c-$p.info" 2>/dev/null
    cp "/proc/$p/exe" "$ev/$c-$p.bin" 2>/dev/null
    u=$(unit_of "$p")
    if [[ -n $u ]] && ! is_protected_unit "$u" && [[ " ${units[*]} " != *" $u "* ]]; then units+=("$u"); fi
  done
  for u in "${units[@]}"; do
    frag=$(systemctl show -p FragmentPath --value "$u" 2>/dev/null)
    systemctl kill -s KILL "$u" >/dev/null 2>&1
    systemctl stop "$u" >/dev/null 2>&1
    systemctl disable "$u" >/dev/null 2>&1
    if [[ -f $frag && -n $(printf '%s\n' "$frag" | unowned) ]]; then stash "$ev" "$frag"; rm -f "$frag"; fi
  done
  ((${#units[@]})) && systemctl daemon-reload
  for u in "${units[@]}"; do systemctl mask "$u" >/dev/null 2>&1; done
  builtin kill -9 "${pids[@]}" 2>/dev/null
  sleep 0.5
  for p in "${pids[@]}"; do
    if [[ -d /proc/$p && $(awk '/^State:/{print $2}' "/proc/$p/status" 2>/dev/null) != Z ]]; then alive+=("$p"); fi
  done
  KT_MSG="Killed PID ${pids[*]}."
  ((${#units[@]})) && KT_MSG+=" Disabled and masked ${units[*]}."
  ((${#skipped[@]})) && KT_MSG+=" Skipped ${skipped[*]}."
  ((${#alive[@]})) && KT_MSG+=" STILL RUNNING: ${alive[*]} (look at State in /proc/PID/status; possible rootkit)."
  KT_MSG+=" Evidence: $ev"
  logact "kill: $KT_MSG"
  ((${#alive[@]} == 0))
}

# ================================================ known-bad IPs and files
expand_ips() {   # a.b.c.d or a.b.c.d-e -> one address per line
  local x i
  for x in "$@"; do
    if [[ $x =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.([0-9]+)-([0-9]+)$ ]]; then
      for ((i = BASH_REMATCH[2]; i <= BASH_REMATCH[3]; i++)); do echo "${BASH_REMATCH[1]}.$i"; done
    else echo "$x"; fi
  done
}
cmd_known_bad() {
  hdr "Block known red team IPs and the other hosts on this subnet"
  local r base ip mine gw ns
  local -a L=() mineips=()
  # shellcheck disable=SC2086
  mapfile -t L < <(expand_ips $KNOWN_BAD_IPS)
  mapfile -t mineips < <(local_ips)
  for r in $NEIGHBOR_RANGES; do
    base=${r%.*}
    for mine in "${mineips[@]}"; do
      [[ $mine == "$base".* ]] || continue
      say "This box is $mine, so every other address in $r gets blocked too."
      while read -r ip; do [[ $ip == "$mine" ]] || L+=("$ip"); done < <(expand_ips "$r")
    done
  done
  mapfile -t L < <(printf '%s\n' "${L[@]}" | awk 'NF && !seen[$0]++')
  printf '    %s\n' "${L[@]}"
  gw=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
  if [[ -n $gw ]] && grep -qxF "$gw" <<< "$(printf '%s\n' "${L[@]}")"; then
    warn "$gw is this box's default gateway. Blocking it stops traffic sent TO it, not traffic routed THROUGH it."
  fi
  for ns in $(awk '/^nameserver/{print $2}' /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null | sort -u); do
    grep -qxF "$ns" <<< "$(printf '%s\n' "${L[@]}")" && warn "$ns is this box's DNS server; name lookups will stop working once it's blocked."
  done
  echo "  (Never-block IPs and your own SSH connection are skipped automatically.)"
  confirm_yes "Block these ${#L[@]} addresses in, out and forwarded?" || return
  for ip in "${L[@]}"; do block_ip "$ip"; echo "  $BL_MSG"; done
}
pkg_deb() {   # pkg -> sets PD_DEB / PD_VER: the archive .deb for its installed version
  local pkg=$1 iv ar vers
  PD_DEB="" PD_VER=""
  installed "$pkg" || return 1
  iv=$(dpkg-query -W -f='${Version}' "$pkg"); ar=$(dpkg-query -W -f='${Architecture}' "$pkg")
  vers=$(repo_versions "$pkg")
  if grep -qxF -- "$iv" <<< "$vers"; then PD_VER=$iv; else PD_VER=$(head -1 <<< "$vers"); fi
  [[ -n $PD_VER ]] || return 1
  PD_DEB=$(deb_for "$pkg" "$PD_VER" "$ar")
  [[ -f $PD_DEB ]] || apt-get -qq install -y --reinstall --allow-downgrades --download-only "$pkg=$PD_VER" >/dev/null 2>&1
  [[ -f $PD_DEB ]]
}
deb_file() {   # deb path -> that file's contents from the package
  local deb=$1 p=$2 m
  for m in ".$p" ".${p#/usr}" "./usr${p#/usr}"; do
    if dpkg-deb --fsys-tarfile "$deb" 2>/dev/null | tar -tf - "$m" >/dev/null 2>&1; then
      dpkg-deb --fsys-tarfile "$deb" | tar -xOf - "$m"; return 0
    fi
  done
  return 1
}
pkg_file_status() {   # path -> PF_PKG, PF_STATE (ok|DIFFERS|no-package|cant-check)
  local p=$1 owner tmp
  PF_PKG="" PF_STATE=""
  local c rp; rp=$(readlink -f -- "$p" 2>/dev/null); owner=""
  for c in "$p" "$rp" "/usr${p#/usr}" "${p#/usr}" "/usr${rp#/usr}" "${rp#/usr}"; do
    [[ -n $c ]] || continue
    owner=$(dpkg-query -S -- "$c" 2>/dev/null | grep -v '^diversion' | head -1)
    [[ -n $owner ]] && break
  done
  [[ -n $owner ]] || { PF_STATE=no-package; return; }
  PF_PKG=${owner%%: /*}; PF_PKG=${PF_PKG%%,*}; PF_PKG=${PF_PKG%%:*}
  installed "$PF_PKG" || { PF_STATE=no-package; return; }
  pkg_deb "$PF_PKG" || { PF_STATE=cant-check; return; }
  tmp=$(mktemp)
  if deb_file "$PD_DEB" "$p" > "$tmp"; then
    if cmp -s "$tmp" "$p"; then PF_STATE=ok; else PF_STATE=DIFFERS; fi
  else PF_STATE=cant-check; fi
  rm -f "$tmp"
}
cmd_iocs() {
  hdr "Known red team files and processes"
  echo "Lists are IOC_REMOVE and IOC_PKGFILES in $CONF."
  local ev p d f pid exe cwd cmd pat line id es; ev=$(evdir iocs)
  local -a present=() kp=() kl=() uns=() dropins=() eargs=() loaded=() ufiles=() pkgunits=()
  for p in $IOC_REMOVE; do
    [[ -e $p || -L $p ]] && present+=("$p")
    eargs+=(-e "$p")
  done
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}; [[ $pid == "$$" ]] && continue
    exe=$(readlink "$d/exe" 2>/dev/null); cwd=$(readlink "$d/cwd" 2>/dev/null)
    cmd=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)
    local -a av=(); mapfile -d '' -t av < "$d/cmdline" 2>/dev/null
    for pat in $IOC_REMOVE; do
      local hit=0 x
      [[ $exe == "$pat"* || $cwd == "$pat"* ]] && hit=1
      for x in "${av[@]:1}"; do [[ $x == "$pat"* ]] && { hit=1; break; }; done
      if ((hit)); then
        kp+=("$pid"); kl+=("$(printf '%-7s %-16s %s' "$pid" "$(cat "$d/comm" 2>/dev/null)" "${cmd:0:70}")"); break
      fi
    done
  done
  # unit files and drop-ins that mention a known-bad path, plus the bad unit files themselves
  while IFS= read -r f; do
    if [[ -n $(printf '%s\n' "$f" | unowned) ]]; then
      if [[ $f == *.d/*.conf ]]; then dropins+=("$f"); else uns+=("${f##*/}"); ufiles+=("$f"); fi
    else
      pkgunits+=("$f")   # a package's own unit file was edited: reinstall it, never mask it
    fi
  done < <(grep -rlsF "${eargs[@]}" /etc/systemd /usr/lib/systemd/system /lib/systemd/system \
             /run/systemd/system /run/systemd/transient /usr/local/lib/systemd 2>/dev/null |
           xargs -r -d '\n' readlink -f | sort -u)
  for p in $IOC_REMOVE; do [[ -e $p && $p =~ \.(service|timer|socket|path)$ ]] && uns+=("${p##*/}"); done
  # running units whose file was deleted but still run a known-bad path
  mapfile -t loaded < <(systemctl list-units --all --no-legend --plain --type=service 2>/dev/null | awk '{print $1}')
  if ((${#loaded[@]})); then
    id="" es=""
    while IFS= read -r line; do
      if [[ -z $line ]]; then
        if [[ -n $id ]]; then for pat in $IOC_REMOVE; do [[ $es == *"$pat"* ]] && { uns+=("$id"); break; }; done; fi
        id="" es=""; continue
      fi
      case $line in Id=*) id=${line#Id=} ;; Exec*) es+=" ${line#*=}" ;; esac
    done < <(systemctl show -p Id -p ExecStart -p ExecStartPre -p ExecStartPost "${loaded[@]}" 2>/dev/null; echo)
  fi
  mapfile -t uns < <(printf '%s\n' "${uns[@]}" | awk 'NF && !seen[$0]++')
  # never disarm a unit whose file belongs to a package (e.g. an edited ssh.service)
  local -a keep=(); local fp
  for f in "${uns[@]}"; do
    fp=$(systemctl show -p FragmentPath --value "$f" 2>/dev/null)
    if [[ -f $fp && -z $(printf '%s\n' "$fp" | unowned) ]]; then pkgunits+=("$fp"); else keep+=("$f"); fi
  done
  uns=("${keep[@]}")
  ((${#pkgunits[@]})) && { warn "Package unit files edited to run red team files (these get reinstalled below, not disabled):"; printf '    %s\n' "${pkgunits[@]}"; }
  ((${#present[@]})) && { say "Known-bad files and folders on this box:"; printf '    %s\n' "${present[@]}"; }
  ((${#kl[@]})) && { say "Processes using them:"; printf '    %s\n' "${kl[@]}"; }
  ((${#uns[@]})) && { say "Units that run them:"; printf '    %s\n' "${uns[@]}"; }
  ((${#dropins[@]})) && { say "Drop-ins that run them:"; printf '    %s\n' "${dropins[@]}"; }
  if ((${#present[@]} + ${#kl[@]} + ${#uns[@]} + ${#dropins[@]})); then
    if confirm_yes "Disarm and remove all of it?"; then
      neutralize_units "${uns[@]}"
      for f in "${ufiles[@]}"; do [[ -e $f ]] && { stash "$ev" "$f"; rm -f "$f"; logact "removed unit file $f"; }; done
      for f in "${dropins[@]}"; do stash "$ev" "$f"; rm -f "$f"; logact "removed drop-in $f"; done
      ((${#dropins[@]} + ${#ufiles[@]})) && systemctl daemon-reload
      local -a still=()
      for pid in "${kp[@]}"; do [[ -d /proc/$pid ]] && still+=("$pid"); done
      ((${#still[@]})) && { kill_targets "${still[@]}"; echo "  $KT_MSG"; }
      for p in "${present[@]}"; do
        chattr -R -i "$p" 2>/dev/null; stash "$ev" "$p"; rm -rf "$p"; logact "removed $p"
      done
      good "Removed. Copies are in $ev"
    fi
  else
    good "None of the known-bad files, processes or units are on this box."
  fi

  hdr "Real system files the red team replaced or edited"
  echo "These belong to Ubuntu packages, so they're checked and reinstalled, never deleted."
  local -a fixp=() fixf=() stale=()
  local -A pdone=()
  for p in $IOC_PKGFILES "${pkgunits[@]}"; do
    [[ -e $p ]] || continue
    x=$(readlink -f -- "$p"); [[ -n ${pdone[$x]:-} ]] && continue; pdone[$x]=1
    pkg_file_status "$p"
    case $PF_STATE in
      ok) good "$p matches Ubuntu's $PF_PKG package." ;;
      DIFFERS)
        bad "$p does NOT match Ubuntu's $PF_PKG package."
        stash "$ev" "$p"
        if [[ $PF_PKG == ufw || $PF_PKG == firewalld || ($PF_PKG == nftables && $DOCKER_BOX != 1) ]]; then
          systemctl mask "${p##*/}" >/dev/null 2>&1
          say "  Masked ${p##*/}; firewall setup removes $PF_PKG entirely."
        else
          fixf+=("$p"); [[ " ${fixp[*]} " == *" $PF_PKG=$PD_VER "* ]] || fixp+=("$PF_PKG=$PD_VER")
        fi ;;
      no-package)
        if [[ $p =~ \.(service|timer|socket)$ ]]; then
          warn "$p is left over from a removed package; removing and masking it."
          stash "$ev" "$p"; rm -f "$p"; systemctl daemon-reload; systemctl mask "${p##*/}" >/dev/null 2>&1
          logact "removed leftover $p"
        else
          bad "$p isn't from any package. Review it by hand (not deleted)."
        fi ;;
      *) warn "$p: couldn't get its package to compare against." ;;
    esac
  done
  ((${#fixp[@]})) || return 0
  confirm_yes "Reinstall ${fixp[*]} from the Ubuntu archive?" || return 0
  for p in "${fixp[@]}"; do
    DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall --allow-downgrades "$p" >/dev/null 2>&1 \
      && { good "Reinstalled $p"; logact "reinstalled $p"; } || bad "Reinstall of $p failed."
  done
  for p in "${fixf[@]}"; do
    pkg_file_status "$p"
    if [[ $PF_STATE == ok ]]; then good "$p is the real file again."; else bad "$p still differs."; fi
  done
  [[ " ${fixf[*]} " == *systemd-logind* ]] && systemctl restart systemd-logind && good "Restarted systemd-logind on the real binary."
  [[ " ${fixf[*]} " == *systemd-executor* ]] && systemctl daemon-reexec && good "systemd re-executed on the real executor."
  for p in "${fixf[@]}"; do
    [[ $p =~ \.(service|socket|timer)$ ]] || continue
    systemctl daemon-reload; systemctl try-restart "${p##*/}" && good "Restarted ${p##*/} with its real unit file."
  done
  for d in /proc/[0-9]*; do
    exe=$(readlink "$d/exe" 2>/dev/null)
    for p in "${fixf[@]}"; do [[ $exe == "$p (deleted)" ]] && stale+=("${d#/proc/}"); done
  done
  if ((${#stale[@]})); then
    warn "Processes still running the replaced copies: ${stale[*]}"
    confirm_yes "Kill them?" && { kill_targets "${stale[@]}"; echo "  $KT_MSG"; }
  fi
}

# ======================================================== 1. package verify
repo_versions() { apt-cache madison "$1" 2>/dev/null | awk -F'|' '{gsub(/[[:space:]]/,"",$2); print $2}'; }
deb_for() { printf '/var/cache/apt/archives/%s_%s_%s.deb' "$1" "${2//:/%3a}" "$3"; }
compare_deb() {   # deb -> paths of installed binaries/libraries that differ or are missing
  local deb=$1 tmp; tmp=$(mktemp -d)
  dpkg-deb -x "$deb" "$tmp" 2>/dev/null
  (cd "$tmp" && find . -type f | sed 's|^\./|/|' | grep -E '^/(usr/)?(s?bin|lib|lib64|libexec)/') > "$tmp.l"
  if [[ -s $tmp.l ]]; then
    (cd "$tmp" && sed 's|^/|./|' "$tmp.l" | xargs -r -d '\n' sha256sum | sed 's|  \./|  /|') > "$tmp.g"
    xargs -r -d '\n' sha256sum < "$tmp.l" > "$tmp.d" 2>/dev/null
    awk 'NR==FNR { d[substr($0,67)] = $1; next }
         { p = substr($0,67); if (!(p in d) || d[p] != $1) print p }' "$tmp.d" "$tmp.g"
  fi
  rm -rf "$tmp" "$tmp.l" "$tmp.g" "$tmp.d"
}
cmd_verify() {
  hdr "Check system packages against Ubuntu's signed packages"
  echo "This checks the binaries and libraries of core packages (bash, nft, iptables, ssh, coreutils,"
  echo "PAM, systemd...) against fresh copies from the Ubuntu archive. It can't help if apt, dpkg"
  echo "or the kernel themselves were replaced."
  say "Updating package lists..."
  apt-get -qq update >/dev/null 2>&1 || warn "apt-get update failed; using cached lists."
  local -a P=() IV=() AR=() TG=() NR=() CH=() fix=(); local pkg iv ar vers tg i deb n res
  for pkg in $CORE_PKGS; do
    installed "$pkg" || continue
    iv=$(dpkg-query -W -f='${Version}' "$pkg"); ar=$(dpkg-query -W -f='${Architecture}' "$pkg")
    vers=$(repo_versions "$pkg")
    if grep -qxF -- "$iv" <<< "$vers"; then tg=$iv; n=0; else tg=$(head -1 <<< "$vers"); n=1; fi
    P+=("$pkg"); IV+=("$iv"); AR+=("$ar"); TG+=("$tg"); NR+=("$n")
  done
  local -a need=()
  for i in "${!P[@]}"; do
    [[ -n ${TG[i]} && ! -f $(deb_for "${P[i]}" "${TG[i]}" "${AR[i]}") ]] && need+=("${P[i]}=${TG[i]}")
  done
  if ((${#need[@]})); then
    say "Downloading ${#need[@]} packages to compare against (not installing yet)..."
    if ! apt-get -qq install -y --reinstall --allow-downgrades --download-only "${need[@]}" >/dev/null 2>&1; then
      for i in "${need[@]}"; do apt-get -qq install -y --reinstall --allow-downgrades --download-only "$i" >/dev/null 2>&1; done
    fi
  fi
  printf '\n%-22s %-30s %s\n' PACKAGE INSTALLED RESULT
  for i in "${!P[@]}"; do
    CH[i]=""
    deb=$(deb_for "${P[i]}" "${TG[i]}" "${AR[i]}")
    if [[ -z ${TG[i]} ]]; then res="${C_Y}not in any repo, can't check${C_0}"
    elif [[ ! -f $deb ]]; then res="${C_Y}couldn't download, can't check${C_0}"
    else
      CH[i]=$(compare_deb "$deb")
      n=$(grep -c . <<< "${CH[i]}")
      res=""
      ((NR[i])) && res="${C_R}VERSION NOT IN ARCHIVE (archive has ${TG[i]})${C_0} "
      ((n)) && res+="${C_R}$n FILES DIFFER${C_0}"
      [[ -z $res ]] && res="${C_G}OK${C_0}"
      ((NR[i] || n)) && fix+=("$i")
    fi
    printf '%-22s %-30s %s\n' "${P[i]}" "${IV[i]}" "$res"
  done
  ((${#fix[@]})) || { good "Every package that could be checked matches the archive."; return; }
  echo
  for i in "${fix[@]}"; do
    [[ -n ${CH[i]} ]] || continue
    echo "${P[i]}: $(head -5 <<< "${CH[i]}" | tr '\n' ' ')$( (($(grep -c . <<< "${CH[i]}") > 5)) && echo '...')"
  done
  confirm "Reinstall these ${#fix[@]} packages from the Ubuntu archive?" || return
  local ev; ev=$(evdir replaced-binaries)
  for i in "${fix[@]}"; do
    # keep the tampered files as evidence
    while IFS= read -r f; do [[ -n $f ]] && stash "$ev" "$f"; done <<< "${CH[i]}"
    say "Reinstalling ${P[i]}=${TG[i]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall --allow-downgrades "${P[i]}=${TG[i]}" >/dev/null 2>&1 \
      && logact "reinstalled ${P[i]}=${TG[i]}" || bad "Reinstall of ${P[i]} failed."
    deb=$(deb_for "${P[i]}" "${TG[i]}" "${AR[i]}")
    n=$(compare_deb "$deb" | grep -c .)
    if ((n)); then bad "${P[i]}: $n files still differ."; else good "${P[i]} now matches the archive."; fi
  done
  say "Tampered copies saved in $ev"
}

# ===================================================== 2. firewall setup
install_guard() {
  install_self
  cat > /etc/systemd/system/blueteam-guard.service <<EOF
[Unit]
Description=Blue team firewall guard (re-applies the blocklist if it is flushed)
After=network-pre.target docker.service
Wants=network-pre.target

[Service]
Environment=BT_TRUSTED=1 BT_SELF=$BIN
ExecStart=/usr/bin/bash --norc --noprofile $BIN guard
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable blueteam-guard.service >/dev/null 2>&1
  systemctl restart blueteam-guard.service
}
cmd_fw_setup() {
  hdr "Firewall: iptables only, blocklist chains, guard service"
  local ev p s extra; ev=$(evdir firewall)
  iptables-save > "$ev/iptables.rules" 2>/dev/null
  ip6tables-save > "$ev/ip6tables.rules" 2>/dev/null
  have nft && nft list ruleset > "$ev/nft-ruleset.nft" 2>/dev/null
  stash "$ev" /etc/ufw /etc/firewalld /etc/nftables.conf
  say "Saved current rules and configs to $ev"
  local -a rm=(ufw firewalld) inst=()
  if [[ $DOCKER_BOX == 1 ]]; then
    warn "Docker box: keeping nftables because Docker needs nft. Use menu 1 to reinstall it from the archive."
  else
    rm+=(nftables libnftables1 python3-nftables)
  fi
  for s in ufw firewalld nftables; do
    systemctl disable --now "$s.service" >/dev/null 2>&1
    systemctl mask "$s.service" >/dev/null 2>&1
  done
  have ufw && ufw --force disable >/dev/null 2>&1
  good "Stopped, disabled and masked ufw, firewalld and nftables services."
  for p in "${rm[@]}"; do installed "$p" && inst+=("$p"); done
  if ((${#inst[@]})); then
    say "Packages to remove: ${inst[*]}"
    extra=$(apt-get -s purge "${inst[@]}" 2>/dev/null | awk '/^(Purg|Remv) /{print $2}' | grep -vxF -f <(printf '%s\n' "${inst[@]}") | tr '\n' ' ')
    [[ -n $extra ]] && warn "apt would also remove: $extra"
    if confirm "Remove them?"; then
      DEBIAN_FRONTEND=noninteractive apt-get purge -y "${inst[@]}" >/dev/null 2>&1 && good "Removed ${inst[*]}." || bad "apt purge failed."
      logact "purged ${inst[*]}"
    fi
  fi
  pin_block ufw firewalld
  [[ $DOCKER_BOX == 1 ]] || pin_block nftables libnftables1 python3-nftables
  good "apt is now blocked from installing: $(tr '\n' ' ' < "$PINNED")"
  for p in iptables conntrack; do installed "$p" || DEBIAN_FRONTEND=noninteractive apt-get install -y "$p" >/dev/null 2>&1; done
  have iptables || { bad "iptables isn't installed and couldn't be installed."; return; }
  say "iptables backend: $(iptables -V)"
  if [[ $DOCKER_BOX != 1 ]]; then
    local -a stray=()
    mapfile -t stray < <(find / -xdev -type f -name 'nft' -perm -u+x 2>/dev/null)
    if ((${#stray[@]})); then
      warn "nft binaries still on disk: ${stray[*]}"
      if confirm "Move them to evidence?"; then for p in "${stray[@]}"; do stash "$ev" "$p"; rm -f "$p"; done; fi
    fi
  fi
  fw_apply
  install_guard
  if systemctl is-active --quiet blueteam-guard; then good "Guard service running: blocklist is re-applied within 2s of any flush."
  else warn "Guard service didn't start. Run: $BIN guard   (in a tmux pane) instead."; fi
  [[ $DOCKER_BOX == 1 ]] && say "Docker box: the guard also restarts Docker (once a minute at most) if its chains get wiped."
  cmd_known_bad
}

# ======================================================== 3. blocklist menu
cmd_blocklist() {
  local c ips ip port d pr spec i
  while :; do
    hdr "Blocklist"
    local -a E=()
    mapfile -t E < <(grep -vE '^\s*(#|$)' "$BLOCK_IPS"; grep -vE '^\s*(#|$)' "$BLOCK_PORTS")
    if ((${#E[@]})); then for i in "${!E[@]}"; do printf '  %2d) %s\n' $((i + 1)) "${E[i]}"; done
    else echo "  (nothing blocked yet)"; fi
    echo
    echo "  a) Block IP(s)   p) Block a port   r) Remove entries   s) Show counters   x) Re-apply   b) Back"
    read -r -p "> " c
    case $c in
      a) read -r -p "IP(s)/CIDR(s), space-separated: " ips
         for ip in $ips; do block_ip "$ip"; echo "  $BL_MSG"; done ;;
      p) read -r -p "Port: " port
         read -r -p "Inbound to this box (i) or outbound to a remote port (o)? [i]: " d
         read -r -p "Protocol tcp/udp/both [both]: " pr
         [[ $d =~ ^[Oo] ]] && d=out || d=in
         pr=${pr:-both}
         block_port "$d:$pr:$port"; echo "  $BL_MSG" ;;
      r) ((${#E[@]})) || continue
         pick "${#E[@]}" "Remove which" || continue
         for i in "${PICKED[@]}"; do
           spec=${E[i-1]}
           grep -vxF -- "$spec" "$BLOCK_IPS" > "$BLOCK_IPS.tmp"; cat "$BLOCK_IPS.tmp" > "$BLOCK_IPS"
           grep -vxF -- "$spec" "$BLOCK_PORTS" > "$BLOCK_PORTS.tmp"; cat "$BLOCK_PORTS.tmp" > "$BLOCK_PORTS"
           logact "unblock $spec"
         done
         rm -f "$BLOCK_IPS.tmp" "$BLOCK_PORTS.tmp"; fw_apply; good "Removed and re-applied." ;;
      s) for i in BT-IN BT-OUT BT-FWD; do iptables -L "$i" -n -v --line-numbers 2>/dev/null; echo; done ;;
      x) fw_apply; good "Re-applied." ;;
      *) return ;;
    esac
  done
}

# ================================================== 4. persistence hunting
KNOWN_SNAPPY="X-Snappy=yes"
cmd_hunt() {
  hdr "Systemd units that aren't from any package"
  say "Scanning units..."
  local -a units=(); local line id fp ls as di u reason d
  mapfile -t units < <({
    systemctl list-units --all --no-legend --plain --type=service,timer,socket,path 2>/dev/null | awk '{print $1}'
    systemctl list-unit-files --no-legend --plain --type=service,timer,socket,path 2>/dev/null | awk '{print $1}'
  } | grep -v '@\.' | sort -u)
  local -A FP=() LDS=() AS=() DI=() UN=()
  id="" fp="" ls="" as="" di=""
  while IFS= read -r line; do
    if [[ -z $line ]]; then
      [[ -n $id ]] && { FP[$id]=$fp; LDS[$id]=$ls; AS[$id]=$as; DI[$id]=$di; }
      id="" fp="" ls="" as="" di=""; continue
    fi
    case $line in
      Id=*) id=${line#*=} ;; FragmentPath=*) fp=${line#*=} ;; LoadState=*) ls=${line#*=} ;;
      ActiveState=*) as=${line#*=} ;; DropInPaths=*) di=${line#*=} ;;
    esac
  done < <(systemctl show -p Id,FragmentPath,LoadState,ActiveState,DropInPaths "${units[@]}" 2>/dev/null; echo)
  while IFS= read -r line; do UN[$line]=1; done < <({
    for u in "${!FP[@]}"; do [[ -f ${FP[$u]} ]] && echo "${FP[$u]}"; for d in ${DI[$u]}; do echo "$d"; done; done
  } | sort -u | unowned)

  local -a FU=() FR=() FT=() FX=()
  for u in "${!FP[@]}"; do
    [[ $u == blueteam-guard.service ]] && continue
    fp=${FP[$u]}; reason=""
    if [[ ${LDS[$u]} == not-found && ${AS[$u]} =~ ^(active|activating|reloading)$ ]]; then
      reason="RUNNING, but its unit file was deleted"
    elif [[ -n $fp && $fp != /dev/null && -n ${UN[$fp]:-} ]]; then
      [[ $fp == /run/systemd/generator* ]] && continue
      [[ $u == snap[.-]* ]] && grep -q "$KNOWN_SNAPPY" "$fp" 2>/dev/null && continue
      reason="unit file not from any package: $fp"
    fi
    if [[ -n $reason ]]; then
      FU+=("$u"); FR+=("$reason"); FT+=(unit)
      FX+=("$(systemctl show -p ExecStart --value "$u" "$(systemctl show -p Unit --value "$u" 2>/dev/null)" 2>/dev/null | grep -oE 'argv\[\]=[^;]+' | head -1 | sed 's/argv\[\]=//')")
    fi
    for d in ${DI[$u]}; do
      [[ -n ${UN[$d]:-} ]] || continue
      FU+=("$u"); FR+=("drop-in added to $u: $d"); FT+=("dropin:$d")
      FX+=("$(grep -E '^Exec' "$d" 2>/dev/null | head -1)")
    done
  done

  if ((${#FU[@]} == 0)); then
    good "No suspicious units found."
  else
    local i
    for i in "${!FU[@]}"; do
      printf '%s%2d)%s %-34s %s\n      runs: %s\n' "$C_R" $((i + 1)) "$C_0" "${FU[i]}" "${FR[i]}" "${FX[i]:--}"
    done
    echo
    echo "Picked units get disarmed all at once: payloads made non-executable, every unit stopped in one"
    echo "command, unit files and payloads moved to evidence, then the units masked."
    if pick "${#FU[@]}" "Disarm which"; then
      local -a sel_u=() sel_d=()
      for i in "${PICKED[@]}"; do
        if [[ ${FT[i-1]} == unit ]]; then sel_u+=("${FU[i-1]}"); else sel_d+=("${FT[i-1]#dropin:}"); fi
      done
      neutralize_units "${sel_u[@]}"
      if ((${#sel_d[@]})); then
        local ev; ev=$(evdir dropins)
        for d in "${sel_d[@]}"; do stash "$ev" "$d"; rm -f "$d"; logact "removed drop-in $d"; done
        systemctl daemon-reload
        good "Removed ${#sel_d[@]} drop-in(s); restart the services they were attached to."
      fi
    fi
  fi
  hunt_files
}
neutralize_units() {
  (($#)) || return 0
  local ev u x p frag; ev=$(evdir persistence)
  local -a all=() svcs=() payloads=()
  for u in "$@"; do
    all+=("$u")
    if [[ $u == *.timer || $u == *.path || $u == *.socket ]]; then
      x=$(systemctl show -p Unit --value "$u" 2>/dev/null)
      [[ -z $x && $u == *.socket ]] && x=${u%.socket}.service
      [[ -n $x ]] && all+=("$x")
    fi
  done
  for u in "${all[@]}"; do
    [[ $u == *.service ]] && svcs+=("$u")
    while IFS= read -r p; do
      [[ -f $p ]] || continue
      [[ -n $(printf '%s\n' "$p" | unowned) ]] && payloads+=("$p")
    done < <({
      systemctl show -p ExecStart -p ExecStartPre -p ExecStartPost -p ExecStop -p ExecReload --value "$u" 2>/dev/null | grep -oE 'path=[^ ;]+' | cut -d= -f2
      x=$(systemctl show -p MainPID --value "$u" 2>/dev/null)
      [[ $x =~ ^[0-9]+$ && $x -gt 0 ]] && readlink "/proc/$x/exe" | sed 's/ (deleted)$//'
    } | sort -u)
  done
  # 1. make payloads useless right away, so a timer firing mid-cleanup does nothing
  for p in "${payloads[@]}"; do chattr -i "$p" 2>/dev/null; stash "$ev" "$p"; chmod a-x "$p"; done
  # 2. stop everything in one command so no unit is left to reinstall the others
  systemctl stop "${all[@]}" >/dev/null 2>&1
  ((${#svcs[@]})) && systemctl kill -s KILL "${svcs[@]}" >/dev/null 2>&1
  systemctl disable "${all[@]}" >/dev/null 2>&1
  # 3. move unit files, drop-in dirs and payloads to evidence
  for u in "${all[@]}"; do
    frag=$(systemctl show -p FragmentPath --value "$u" 2>/dev/null)
    if [[ -f $frag && -n $(printf '%s\n' "$frag" | unowned) ]]; then stash "$ev" "$frag"; rm -f "$frag"; fi
    for x in "/etc/systemd/system/$u.d" "/run/systemd/system/$u.d"; do [[ -d $x ]] && { stash "$ev" "$x"; rm -rf "$x"; }; done
  done
  for p in "${payloads[@]}"; do
    for x in /proc/[0-9]*; do
      [[ $(readlink "$x/exe" 2>/dev/null) == "$p"* ]] && builtin kill -9 "${x#/proc/}" 2>/dev/null
    done
    rm -f "$p"
  done
  systemctl daemon-reload
  for u in "${all[@]}"; do systemctl mask "$u" >/dev/null 2>&1; done
  good "Disarmed: ${all[*]}"
  if ((${#payloads[@]})); then
    say "Payloads moved to $ev. Check what else is in their folders:"
    for p in "${payloads[@]}"; do echo "  $(dirname "$p")/: $(ls -A "$(dirname "$p")" 2>/dev/null | tr '\n' ' ')"; done
  fi
  logact "neutralized units: ${all[*]}; payloads: ${payloads[*]}"
}
hunt_files() {
  hdr "Startup and hook files that aren't from any package"
  echo "Not all of these are malicious (cloud-init and admins create some), so review before removing."
  shopt -s nullglob
  local -a spots=(/etc/rc.local /etc/init.d /etc/profile.d /etc/update-motd.d /etc/apt/apt.conf.d
    /etc/udev/rules.d /etc/modules-load.d /etc/modprobe.d /etc/ld.so.preload /etc/ld.so.conf.d
    /etc/sudoers.d /etc/ssh/sshrc /etc/ssh/sshd_config.d /etc/xdg/autostart /etc/networkd-dispatcher
    /etc/NetworkManager/dispatcher.d /etc/systemd/system-generators /usr/local/lib/systemd
    /usr/lib/systemd/system-generators /etc/systemd/user /usr/lib/systemd/user /etc/environment.d
    /etc/X11/Xsession.d /var/lib/systemd/linger /etc/pam.d /etc/security /root/.ssh/rc
    /root/.config/systemd /root/.config/autostart /home/*/.ssh/rc /home/*/.config/systemd
    /home/*/.config/autostart /usr/local/bin /usr/local/sbin)
  shopt -u nullglob
  local -a F=()
  # /etc/pam.d/common-* are generated by pam-auth-update, so no package owns them
  mapfile -t F < <(find "${spots[@]}" -xdev -maxdepth 4 -type f 2>/dev/null | grep -v '^/etc/pam.d/common-' | grep -v '^/usr/local/sbin/cyberrange-' | sort -u | unowned)
  local -a CF=()
  mapfile -t CF < <(dpkg -V openssh-server sudo libpam-runtime libpam-modules base-files bash udev systemd login passwd apt cron 2>/dev/null | awk '$2=="c"{print $3}')
  if ((${#F[@]} == 0 && ${#CF[@]} == 0)); then good "Nothing found."; return; fi
  local i f
  for i in "${!F[@]}"; do
    f=${F[i]}
    printf '%2d) %-55s %8s  %s\n' $((i + 1)) "$f" "$(stat -c %s "$f" 2>/dev/null)" "$(stat -c %y "$f" 2>/dev/null | cut -d. -f1)"
  done
  if ((${#CF[@]})); then
    warn "Package config files that were edited (check for added hooks or users):"
    printf '    %s\n' "${CF[@]}"
  fi
  ((${#F[@]})) || return
  if pick "${#F[@]}" "Move which files to evidence"; then
    local ev; ev=$(evdir startup-files)
    for i in "${PICKED[@]}"; do
      f=${F[i-1]}; chattr -i "$f" 2>/dev/null; stash "$ev" "$f"; rm -f "$f"; logact "removed $f"
    done
    [[ ${PICKED[*]} ]] && systemctl daemon-reload
    good "Moved ${#PICKED[@]} file(s) to $ev"
  fi
}

# ========================================================= 5. remove cron
cmd_cron_remove() {
  hdr "Remove cron, anacron and at"
  shopt -s nullglob
  local f ev p extra; ev=$(evdir cron)
  for f in /etc/crontab /etc/cron.d/* /var/spool/cron/crontabs/* /etc/anacrontab; do
    [[ -f $f ]] || continue
    echo "--- $f"; grep -vE '^\s*(#|$)' "$f" | sed 's/^/    /'
  done
  have atq && { echo "--- at queue"; atq | sed 's/^/    /'; }
  stash "$ev" /etc/crontab /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly \
    /etc/cron.yearly /etc/anacrontab /var/spool/cron /var/spool/anacron /etc/cron.allow /etc/cron.deny \
    /etc/at.allow /etc/at.deny
  shopt -u nullglob
  say "Copied all of the above to $ev"
  confirm "Remove cron, anacron and at from this box?" || return
  for p in cron.service atd.service anacron.service anacron.timer; do
    systemctl disable --now "$p" >/dev/null 2>&1; systemctl mask "$p" >/dev/null 2>&1
  done
  pkill -KILL -x cron; pkill -KILL -x crond; pkill -KILL -x atd; pkill -KILL -x anacron
  local -a inst=()
  for p in cron anacron at cron-daemon-common bcron systemd-cron cronie; do installed "$p" && inst+=("$p"); done
  if ((${#inst[@]})); then
    extra=$(apt-get -s purge "${inst[@]}" 2>/dev/null | awk '/^(Purg|Remv) /{print $2}' | grep -vxF -f <(printf '%s\n' "${inst[@]}") | tr '\n' ' ')
    [[ -n $extra ]] && warn "apt will also remove: $extra"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "${inst[@]}" >/dev/null 2>&1 && good "Removed ${inst[*]}." || bad "apt purge failed."
  fi
  rm -rf /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /etc/cron.yearly \
    /etc/crontab /etc/anacrontab /var/spool/cron /var/spool/anacron
  for p in cron crond atd anacron crontab at; do
    f=$(command -v "$p") && { stash "$ev" "$f"; rm -f "$f"; warn "Removed leftover $f"; }
  done
  pin_block cron anacron at cron-daemon-common
  good "Cron and at are gone, and apt is blocked from reinstalling them. Logrotate and the other"
  good "Ubuntu jobs keep running from their systemd timers."
  logact "removed cron/anacron/at"
}

# ================================================== 6. backdoor hunting
KNOWN_LISTENERS=" sshd systemd systemd-resolve systemd-network systemd-timesyn chronyd docker-proxy dockerd containerd cupsd avahi-daemon "
cmd_listeners() {
  hdr "Listening ports"
  compute_protected
  local -a LP=() LN=() LX=() LU=() LV=() LS=(); local line proto addr port pids pid c exe u v i
  local -A EXES=() UNOWN=()
  while IFS= read -r line; do
    proto=$(awk '{print $1}' <<< "$line"); addr=$(awk '{print $5}' <<< "$line"); port=${addr##*:}
    mapfile -t pids < <(grep -oE 'pid=[0-9]+' <<< "$line" | cut -d= -f2 | sort -u)
    if ((${#pids[@]} == 0)); then
      LP+=("$proto/$port"); LN+=("-"); LX+=("-"); LU+=("-"); LS+=("")
      LV+=("${C_R}NO PROCESS SHOWN (hidden? kernel socket?)${C_0}"); continue
    fi
    for pid in "${pids[@]}"; do
      c=$(cat "/proc/$pid/comm" 2>/dev/null); exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
      LP+=("$proto/$port"); LN+=("$c($pid)"); LX+=("$exe"); LU+=("$(unit_of "$pid")"); LS+=("$pid")
      [[ -n $exe && $exe != *" (deleted)" ]] && EXES[$exe]=1
      LV+=("")
    done
  done < <(ss -tulnpH 2>/dev/null | sort -t: -k2 -n)
  while IFS= read -r line; do UNOWN[$line]=1; done < <(printf '%s\n' "${!EXES[@]}" | unowned)
  for i in "${!LP[@]}"; do
    [[ -n ${LV[i]} ]] && continue
    pid=${LS[i]}; exe=${LX[i]}; c=${LN[i]%%(*}; port=${LP[i]#*/}
    if in_container "$pid"; then v="container"
    elif [[ $exe == *" (deleted)" ]]; then v="${C_R}SUSPECT: binary was deleted${C_0}"
    elif [[ -n ${UNOWN[$exe]:-} ]]; then v="${C_R}SUSPECT: binary not from any package${C_0}"
    elif [[ " $PROTECT_PORTS " == *" $port "* ]]; then v="${C_G}protected port${C_0}"
    elif [[ $KNOWN_LISTENERS == *" $c "* ]]; then v="${C_G}ok${C_0}"
    else v="${C_Y}review: unknown service${C_0}"; fi
    LV[i]=$v
  done
  printf '%3s  %-11s %-24s %-22s %s\n' "#" PORT PROCESS UNIT VERDICT
  for i in "${!LP[@]}"; do
    printf '%3d  %-11s %-24s %-22s %s\n' $((i + 1)) "${LP[i]}" "${LN[i]:0:24}" "${LU[i]:0:22}" "${LV[i]}"
    [[ ${LV[i]} == *SUSPECT* || ${LV[i]} == *review* ]] && printf '       exe: %s\n' "${LX[i]}"
  done
  echo
  if pick "${#LP[@]}" "Kill which (also disables their services)"; then
    local -a kp=() bp=()
    for i in "${PICKED[@]}"; do
      [[ -n ${LS[i-1]} ]] && kp+=("${LS[i-1]}")
      bp+=("in:${LP[i-1]%/*}:${LP[i-1]#*/}")
    done
    kill_targets "${kp[@]}"; echo "$KT_MSG"
    if confirm_yes "Also block those ports inbound so they can't be reused?"; then
      for v in $(printf '%s\n' "${bp[@]}" | sort -u); do block_port "$v"; echo "  $BL_MSG"; done
    fi
  fi
  odd_processes
  hdr "Raw and packet sockets (can sniff traffic or wait for magic packets)"
  ss -0pH 2>/dev/null | grep -vE '"(systemd-network|dhclient|NetworkManager|wpa_supplicant|lldpd)"' | sed 's/^/  /'
  ss -wpH 2>/dev/null | sed 's/^/  /'
  echo "  (Empty or only DHCP/network tools is normal.)"
}
odd_processes() {
  hdr "Processes running from deleted files or files not from any package"
  local -A E=() UNO=(); local d p exe
  for d in /proc/[0-9]*; do
    p=${d#/proc/}; exe=$(readlink "$d/exe" 2>/dev/null) || continue
    [[ -z $exe ]] && continue
    in_container "$p" && continue
    E[$p]=$exe
  done
  while IFS= read -r exe; do UNO[$exe]=1; done < <(printf '%s\n' "${E[@]}" | sed 's/ (deleted)$//' | sort -u | unowned)
  local -a OP=() OL=()
  for p in "${!E[@]}"; do
    exe=${E[$p]}
    if [[ $exe == *" (deleted)" || -n ${UNO[$exe]:-} ]]; then
      [[ $exe == "$BIN" || $exe == /usr/local/sbin/cyberrange-* ]] && continue
      OP+=("$p"); OL+=("$(printf '%-8s %-16s %s  |  %s' "$p" "$(cat "/proc/$p/comm" 2>/dev/null)" "$exe" "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | cut -c1-60)")")
    fi
  done
  if ((${#OP[@]} == 0)); then good "None."; return; fi
  local i
  for i in "${!OL[@]}"; do printf '%2d) %s\n' $((i + 1)) "${OL[i]}"; done
  if pick "${#OP[@]}" "Kill which"; then
    local -a kp=(); for i in "${PICKED[@]}"; do kp+=("${OP[i-1]}"); done
    kill_targets "${kp[@]}"; echo "$KT_MSG"
  fi
}

# ===================================================== 7. shell tampering
cmd_shell_scan() {
  hdr "Shell startup files: aliases and functions that override commands"
  shopt -s nullglob
  local -a files=(/etc/bash.bashrc /etc/profile /etc/environment /etc/profile.d/*.sh /etc/bash_completion.d/*
    /etc/skel/.bashrc /etc/skel/.profile /etc/skel/.bash_logout
    /root/.bashrc /root/.profile /root/.bash_profile /root/.bash_login /root/.bash_aliases /root/.bash_logout
    /home/*/.bashrc /home/*/.profile /home/*/.bash_profile /home/*/.bash_login /home/*/.bash_aliases /home/*/.bash_logout)
  shopt -u nullglob
  local builtins; builtins=" $(compgen -b | tr '\n' ' ') "
  local -a FF=() FL=() FK=() FW=() FT=(); local f l n txt name why kind
  local -a greyhomes=(); for u in $GREY_USERS $RANGE_USERS; do x=$(getent passwd "$u" | cut -d: -f6); [[ -n $x && $x != / ]] && greyhomes+=("$x/"); done
  for f in "${files[@]}"; do
    [[ -f $f ]] || continue
    for x in "${greyhomes[@]}"; do [[ $f == "$x"* ]] && continue 2; done
    while IFS= read -r l; do
      n=${l%%:*}; txt=${l#*:}; name="" why="" kind=line
      [[ $txt =~ ^[[:space:]]*# ]] && continue
      if [[ $txt =~ ^[[:space:]]*alias[[:space:]]+([A-Za-z0-9_.:+-]+)= ]]; then
        name=${BASH_REMATCH[1]}
        [[ $name =~ ^(ls|dir|vdir|grep|fgrep|egrep)$ && $txt == *--color=auto* ]] && continue
        [[ $name =~ ^(ll|la|l|alert)$ ]] && continue
        why="alias overrides '$name'"
      elif [[ $txt =~ ^[[:space:]]*function[[:space:]]+([A-Za-z0-9_.:+-]+) ]] || [[ $txt =~ ^[[:space:]]*([A-Za-z0-9_.:+-]+)[[:space:]]*\(\) ]]; then
        name=${BASH_REMATCH[1]}; kind=func
        [[ $name == command_not_found_handle || $name == gawk* || $name == _* || $name == __* ]] && continue
        why="function overrides '$name'"
      elif [[ $txt =~ (LD_PRELOAD|LD_LIBRARY_PATH|BASH_ENV|PROMPT_COMMAND|enable[[:space:]]+-n|trap[[:space:]].*DEBUG) ]]; then
        why="sets ${BASH_REMATCH[1]}"
      fi
      if [[ -n $name ]]; then
        [[ -x /usr/bin/$name || -x /usr/sbin/$name || -x /bin/$name || -x /sbin/$name || $builtins == *" $name "* ]] || continue
      fi
      [[ -n $why ]] || continue
      FF+=("$f"); FL+=("$n"); FK+=("$kind"); FW+=("$why"); FT+=("${txt:0:70}")
    done < <(grep -nE 'alias|function|\(\)|LD_PRELOAD|LD_LIBRARY_PATH|BASH_ENV|PROMPT_COMMAND|enable|trap' "$f" 2>/dev/null)
  done
  local i
  if ((${#FF[@]})); then
    for i in "${!FF[@]}"; do
      printf '%s%2d)%s %s:%s  %s\n      %s\n' "$C_R" $((i + 1)) "$C_0" "${FF[i]}" "${FL[i]}" "${FW[i]}" "${FT[i]}"
    done
    if pick "${#FF[@]}" "Comment out which"; then
      local ev; ev=$(evdir shell-rc)
      for i in "${PICKED[@]}"; do
        f=${FF[i-1]}; stash "$ev" "$f"
        awk -v s="${FL[i-1]}" -v fn="$([[ ${FK[i-1]} == func ]] && echo 1 || echo 0)" '
          NR < s || fin { print; next }
          { o = gsub(/\{/, "{"); c = gsub(/\}/, "}"); depth += o - c; if (o) seen = 1
            print "# BT-DISABLED: " $0
            if (!fn || (seen && depth <= 0) || NR - s > 200) fin = 1 }' "$f" > "$f.bt" && cat "$f.bt" > "$f" && rm -f "$f.bt"
        logact "commented out $f:${FL[i-1]} (${FW[i-1]})"
      done
      good "Done (originals in $ev). Open a new terminal and run: type kill cat ps ss systemctl"
    fi
  else
    good "No overriding aliases or functions found."
  fi

  hdr "Library preloading"
  if [[ -s /etc/ld.so.preload ]]; then
    bad "/etc/ld.so.preload makes every program load: $(tr '\n' ' ' < /etc/ld.so.preload)"
    if confirm "Move it to evidence?"; then
      local ev2; ev2=$(evdir preload)
      chattr -i /etc/ld.so.preload 2>/dev/null; local -a pl=(); mapfile -t pl < /etc/ld.so.preload; stash "$ev2" /etc/ld.so.preload "${pl[@]}"
      rm -f /etc/ld.so.preload; logact "removed /etc/ld.so.preload"; good "Removed."
    fi
  else good "/etc/ld.so.preload is empty or missing."; fi

  hdr "Fake commands earlier in PATH"
  local -a SH=(); local d b
  for d in /usr/local/sbin /usr/local/bin /root/bin /root/.local/bin; do
    for b in "$d"/*; do
      [[ -f $b && -x $b ]] || continue
      [[ -e /usr/bin/${b##*/} || -e /usr/sbin/${b##*/} ]] && SH+=("$b")
    done
  done
  if ((${#SH[@]})); then
    for i in "${!SH[@]}"; do printf '%2d) %s  (shadows the real %s)\n' $((i + 1)) "${SH[i]}" "${SH[i]##*/}"; done
    if pick "${#SH[@]}" "Move which to evidence"; then
      local ev3; ev3=$(evdir fake-commands)
      for i in "${PICKED[@]}"; do stash "$ev3" "${SH[i-1]}"; rm -f "${SH[i-1]}"; logact "removed ${SH[i-1]}"; done
      good "Moved to $ev3"
    fi
  else good "No commands in /usr/local or /root shadow system commands."; fi
}

# ======================================================== 8. SSH hardening
user_key_files() {   # user home "AuthorizedKeysFile tokens" -> that user's key files
  local u=$1 h=$2 tok
  echo "$h/.ssh/authorized_keys"; echo "$h/.ssh/authorized_keys2"
  for tok in $3; do
    [[ $tok == /* && $tok != *%* ]] && continue      # shared file, handled separately
    tok=${tok//%%/%}; tok=${tok//%u/$u}; tok=${tok//%h/$h}
    [[ $tok == /* ]] || tok=$h/$tok
    echo "$tok"
  done | sort -u
}
pristine_sshd_config() {   # -> temp file holding Ubuntu's default sshd_config (empty on failure)
  local tmp; tmp=$(mktemp)
  if pkg_deb openssh-server && deb_file "$PD_DEB" /usr/share/openssh/sshd_config > "$tmp" && [[ -s $tmp ]]; then
    printf '%s' "$tmp"
  else
    rm -f "$tmp"
  fi
}
cmd_ssh() {
  hdr "SSH: keys and sshd settings"
  local ev a k u uid gid home shell f g n had tok; ev=$(evdir ssh)
  echo "Deploy key: $TEAM_KEY"
  if ! confirm_yes "Use this key?"; then
    read -r -p "Paste the public key: " k
    [[ $k =~ ^(ssh-|ecdsa-|sk-) ]] || { bad "That doesn't look like a public key."; return; }
    TEAM_KEY=$k
  fi
  read -r -p "Accounts that get the deploy key [$KEY_USERS]: " a
  [[ -n $a ]] && KEY_USERS=$a
  [[ " $KEY_USERS " == *" root "* ]] || KEY_USERS="root $KEY_USERS"
  save_conf
  for u in $KEY_USERS; do id "$u" >/dev/null 2>&1 || warn "$u doesn't exist on this box, so it gets no key."; done

  # Every file sshd could read keys from, including extra AuthorizedKeysFile
  # entries such as /etc/ssh/global_authorized_keys.
  local akf=""
  if [[ -x /usr/sbin/sshd ]]; then mkdir -p /run/sshd; akf=$(sshd -T 2>/dev/null | awk 'tolower($1)=="authorizedkeysfile"{$1=""; print}'); fi
  [[ -n $akf ]] && say "sshd currently reads keys from:$akf"
  local -a globals=(); local -A seen=()
  for tok in $akf /etc/ssh/global_authorized_keys; do
    if [[ $tok == /* && $tok != *%* && -z ${seen[$tok]:-} ]]; then seen[$tok]=1; globals+=("$tok"); fi
  done
  echo "Keys on the box now:"
  while IFS=: read -r u _ uid gid _ home shell; do
    n=0
    while read -r f; do [[ -f $f ]] && n=$((n + $(grep -c '^[^#[:space:]]' "$f" 2>/dev/null))); done < <(user_key_files "$u" "$home" "$akf")
    ((n)) && printf '  %-28s %s key(s)\n' "$u" "$n"
  done < <(getent passwd)
  for g in "${globals[@]}"; do
    [[ -f $g ]] && printf '  %-28s %s key(s)  <- these can log in as ANY user\n' "$g" "$(grep -c '^[^#[:space:]]' "$g")"
  done
  echo "Grey team and range accounts ($GREY_USERS $RANGE_USERS) keep their keys."
  confirm "Remove every other SSH key on the box and put the deploy key on: $KEY_USERS?" || return
  local -a put=() wiped=()
  while IFS=: read -r u _ uid gid _ home shell; do
    [[ -n $home && $home != / && -d $home ]] || continue
    is_grey "$u" && continue
    had=0
    [[ -L $home/.ssh ]] && { stash "$ev" "$home/.ssh"; rm -f "$home/.ssh"; had=1; }
    chattr -i "$home/.ssh" 2>/dev/null
    while read -r f; do
      [[ -e $f || -L $f ]] || continue
      had=1; chattr -i "$f" 2>/dev/null; stash "$ev" "$f"; rm -f "$f"
    done < <(user_key_files "$u" "$home" "$akf"; echo "$home/.rhosts"; echo "$home/.shosts")
    if [[ " $KEY_USERS " == *" $u "* ]]; then
      f=$home/.ssh/authorized_keys
      mkdir -p "$home/.ssh"; printf '%s\n' "$TEAM_KEY" > "$f"
      chown "$uid:$gid" "$home/.ssh" "$f"; chmod 700 "$home/.ssh"; chmod 600 "$f"
      chattr +i "$f" 2>/dev/null
      put+=("$u")
    elif ((had)); then
      wiped+=("$u")
    fi
  done < <(getent passwd)
  for g in "${globals[@]}"; do
    [[ -e $g ]] || continue
    chattr -i "$g" 2>/dev/null; stash "$ev" "$g"; : > "$g"; chmod 600 "$g"; chattr +i "$g" 2>/dev/null
    good "Emptied and locked $g."
  done
  for f in /etc/hosts.equiv /etc/ssh/shosts.equiv; do [[ -s $f ]] && { stash "$ev" "$f"; : > "$f"; warn "Emptied $f (host-based trust)."; }; done
  good "Deploy key installed and locked (chattr +i) for: ${put[*]}"
  ((${#wiped[@]})) && good "All keys removed for: ${wiped[*]}"
  echo "  To edit a key file later, run chattr -i on it first."
  logact "ssh keys reset; deploy key on: ${put[*]}; wiped: ${wiped[*]}; emptied: ${globals[*]}"

  shopt -s nullglob
  for f in /etc/ssh/sshrc /root/.ssh/rc /home/*/.ssh/rc; do
    [[ -f $f ]] || continue
    warn "$f runs on every SSH login: $(head -3 "$f" | tr '\n' ' ')"
    confirm "Move it to evidence?" && { stash "$ev" "$f"; rm -f "$f"; logact "removed $f"; }
  done
  shopt -u nullglob

  hdr "sshd settings"
  [[ -x /usr/sbin/sshd ]] || { warn "openssh-server isn't installed, so there are no sshd settings to change."; return; }
  mkdir -p /etc/ssh/sshd_config.d /run/sshd
  stash "$ev" /etc/ssh/sshd_config /etc/ssh/sshd_config.d
  local pristine oldports; pristine=$(pristine_sshd_config)
  if [[ -n $pristine ]]; then
    if cmp -s "$pristine" /etc/ssh/sshd_config; then
      good "/etc/ssh/sshd_config matches Ubuntu's default."
    else
      warn "/etc/ssh/sshd_config differs from Ubuntu's default:"
      diff <(grep -nvE '^\s*(#|$)' "$pristine" | cut -d: -f2-) <(grep -nvE '^\s*(#|$)' /etc/ssh/sshd_config | cut -d: -f2-) |
        sed -n 's/^> /    added:   /p; s/^< /    removed: /p'
      grep -niE '^\s*(ForceCommand|Match|AuthorizedKeys\w*|AuthorizedPrincipals\w*|TrustedUserCAKeys|PermitRootLogin|Port|ListenAddress)\b' /etc/ssh/sshd_config | sed 's/^/    line /'
      oldports=$(grep -iE '^\s*(Port|ListenAddress)\s' /etc/ssh/sshd_config | tr '\n' ' ')
      if confirm_yes "Put back Ubuntu's default sshd_config? (Removes ForceCommand and all other changes; the hardening goes in a drop-in.)"; then
        chattr -i /etc/ssh/sshd_config 2>/dev/null
        cat "$pristine" > /etc/ssh/sshd_config; chmod 644 /etc/ssh/sshd_config
        good "Restored Ubuntu's default sshd_config (old copy in $ev)."
        [[ -n $oldports ]] && warn "The old file had: $oldports. If scoring needs a port other than 22, add it to 00-blueteam.conf."
        logact "restored default sshd_config"
      fi
    fi
    rm -f "$pristine"
  else
    warn "Couldn't get Ubuntu's default sshd_config to compare against."
  fi

  local pw=no rootpw=no fwd=no
  echo "Password logins get turned off: only the deploy key (on $KEY_USERS) can log in."
  read -r -p "Keep password logins on for this box anyway? [y/N]: " a
  [[ $a =~ ^[Yy] ]] && pw=yes
  if [[ $pw == yes ]]; then read -r -p "Allow root to log in with a password? [y/N]: " a; [[ $a =~ ^[Yy] ]] && rootpw=yes; fi
  read -r -p "Turn off SSH tunneling/port forwarding (stops pivoting through this box)? [Y/n]: " a
  [[ $a =~ ^[Nn] ]] && fwd=yes
  local greymatch=no present_grey=""
  for u in $GREY_USERS $RANGE_USERS; do id "$u" >/dev/null 2>&1 && present_grey+="${present_grey:+,}$u"; done
  if [[ $pw == no && -n $present_grey ]]; then
    read -r -p "Let grey team and range accounts ($present_grey) keep logging in with passwords? [Y/n]: " a
    [[ $a =~ ^[Nn] ]] || greymatch=yes
  fi
  # Match blocks must go at the very end of the main file, so sshd_config gets
  # a marked block that's replaced on every run.
  sed -i '/^# BEGIN blueteam grey team/,/^# END blueteam grey team/d' /etc/ssh/sshd_config
  if [[ $greymatch == yes ]]; then
    printf '%s\n' "# BEGIN blueteam grey team" "Match User $present_grey" "    PasswordAuthentication yes" \
      "    KbdInteractiveAuthentication yes" "    AuthenticationMethods publickey password keyboard-interactive" "# END blueteam grey team" >> /etc/ssh/sshd_config
  fi
  local conf=/etc/ssh/sshd_config.d/00-blueteam.conf
  write_sshd() {
    {
      echo "# Written by blueteam.sh - read first, so these settings win"
      echo "PubkeyAuthentication yes"
      echo "AuthorizedKeysFile .ssh/authorized_keys"
      echo "HostbasedAuthentication no"
      echo "IgnoreRhosts yes"
      echo "PermitUserEnvironment no"
      echo "PermitEmptyPasswords no"
      echo "PasswordAuthentication $pw"
      echo "KbdInteractiveAuthentication $pw"
      [[ $pw == no ]] && echo "AuthenticationMethods publickey"
      echo "PermitRootLogin $([[ $rootpw == yes ]] && echo yes || echo prohibit-password)"
      echo "AllowTcpForwarding $fwd"
      echo "AllowStreamLocalForwarding $fwd"
      echo "AllowAgentForwarding $fwd"
      echo "PermitTunnel $fwd"
      echo "GatewayPorts no"
      echo "X11Forwarding no"
      if [[ $1 == full ]]; then echo "AuthorizedKeysCommand none"; echo "AuthorizedPrincipalsFile none"; fi
    } > "$conf"
  }
  write_sshd full
  if ! sshd -t 2>/dev/null; then
    write_sshd basic
    if ! sshd -t; then
      rm -f "$conf"
      sed -i '/^# BEGIN blueteam grey team/,/^# END blueteam grey team/d' /etc/ssh/sshd_config
      if sshd -t; then bad "sshd rejected the new settings; rolled back, sshd unchanged."
      else bad "sshd config is invalid even after rollback. Restore from $ev before restarting ssh!"; fi
      return
    fi
  fi
  # Ubuntu 24.04 builds ssh.socket's port from sshd_config, so reload that too
  systemctl daemon-reload
  systemctl is-active --quiet ssh.socket && systemctl restart ssh.socket
  systemctl reload-or-restart ssh.service 2>/dev/null
  good "sshd reloaded with $conf"
  local eff want_k want_v
  eff=$(sshd -T 2>/dev/null)
  for want_k in passwordauthentication:$pw pubkeyauthentication:yes authorizedkeysfile:.ssh/authorized_keys \
                permituserenvironment:no allowtcpforwarding:$fwd forcecommand:none hostbasedauthentication:no; do
    want_v=${want_k#*:}; want_k=${want_k%%:*}
    if ! grep -qi "^$want_k $want_v\$" <<< "$eff"; then
      bad "sshd is NOT using $want_k $want_v (actual: $(grep -i "^$want_k " <<< "$eff" | cut -d' ' -f2-)). Set in:"
      grep -rni "^\s*$want_k" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | sed 's/^/    /'
    fi
  done
  for want_k in authorizedkeyscommand authorizedprincipalsfile trustedusercakeys; do
    a=$(grep -i "^$want_k " <<< "$eff" | cut -d' ' -f2-)
    [[ -n $a && $a != none ]] && bad "sshd has $want_k $a (lets someone log in without authorized_keys!)"
  done
  if [[ $greymatch == yes ]]; then
    u=${present_grey%%,*}
    if grep -qi '^passwordauthentication yes' <<< "$(sshd -T -C "user=$u,host=x,addr=127.0.0.1" 2>/dev/null)"; then
      good "Grey team can still log in with passwords; everyone else needs the deploy key."
    else bad "The grey team password exception isn't working; check the end of /etc/ssh/sshd_config."; fi
  fi
  a=$(grep -rniE '^\s*(Match|ForceCommand)\b' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | grep -v 'Match User '"${present_grey:-NONE}"'$')
  [[ -n $a ]] && { warn "Match blocks / ForceCommand still configured (these apply to some users only):"; sed 's/^/    /' <<< "$a"; }
  local before; before=$(awk '/^[[:space:]]*Include/{exit} !/^[[:space:]]*(#|$)/' /etc/ssh/sshd_config)
  [[ -n $before ]] && warn "Settings above the Include line in sshd_config override the drop-in: $before"
  local -a D=()
  mapfile -t D < <(find /etc/ssh/sshd_config.d -type f ! -name 00-blueteam.conf 2>/dev/null | unowned)
  if ((${#D[@]})); then
    warn "Other sshd drop-ins (50-cloud-init.conf is normal on cloud images):"
    local i; for i in "${!D[@]}"; do printf '  %2d) %s: %s\n' $((i + 1)) "${D[i]}" "$(grep -vE '^\s*(#|$)' "${D[i]}" | tr '\n' ';')"; done
    if pick "${#D[@]}" "Move which to evidence"; then
      for i in "${PICKED[@]}"; do stash "$ev" "${D[i-1]}"; rm -f "${D[i-1]}"; done
      sshd -t && systemctl reload-or-restart ssh.service
    fi
  fi
  logact "sshd hardened: password=$pw rootpw=$rootpw forwarding=$fwd"
  echo "Test a NEW ssh login (with the deploy key) before closing this one."
}

# ================================================= accounts on the lists
is_grey() { [[ " $GREY_USERS $RANGE_USERS " == *" $1 "* ]]; }   # grey team + range accounts: never touched
in_list() { local x=$1; shift; [[ " $* " == *" $x "* ]]; }
operator_users() {   # accounts your own session runs as (never removed)
  local p u
  compute_protected
  for p in $PROT_PIDS; do
    u=$(awk '/^Uid:/{print $2}' "/proc/$p/status" 2>/dev/null)
    [[ -n $u ]] && getent passwd "$u" | cut -d: -f1
  done | sort -u | tr '\n' ' '
}
PKG_ADDUSER_CACHE=""
pkg_account() {   # 0 if an installed package creates this system account
  local n=$1
  grep -sqE "^u[!~]?[[:space:]]+$n([[:space:]]|$)" /usr/lib/sysusers.d/*.conf && return 0
  if [[ -z $PKG_ADDUSER_CACHE ]]; then
    PKG_ADDUSER_CACHE=$(cat /var/lib/dpkg/info/*.postinst /var/lib/dpkg/info/*.preinst 2>/dev/null |
      grep -A3 -E '(adduser|useradd)([[:space:]]|$)')
    [[ -n $PKG_ADDUSER_CACHE ]] || PKG_ADDUSER_CACHE=" "
  fi
  grep -qw -- "$n" <<< "$PKG_ADDUSER_CACHE"
}
cmd_users() {
  hdr "Accounts that aren't on the lists"
  echo "Keeping: Ubuntu system accounts, scored-service accounts ($SERVICE_USERS), accounts an"
  echo "installed package created, admins, normal users, grey team and cyberrange (never touched)."
  local me; me=$(operator_users)
  local -A uidcount=()
  local u uid gid home shell why sh
  while IFS=: read -r u _ uid _; do uidcount[$uid]=$((${uidcount[$uid]:-0} + 1)); done < /etc/passwd
  local -a CU=() CW=() FU=() FW=()
  while IFS=: read -r u _ uid gid _ home shell; do
    is_grey "$u" && continue
    why=""
    if [[ $uid == 0 && $u != root ]]; then why="UID 0 (a second root account)"
    elif in_list "$u" $KEEP_SYSTEM $SERVICE_USERS; then why=""
    elif in_list "$u" $ADMIN_USERS $NORMAL_USERS; then why=""
    elif ((uid < 1000)) && pkg_account "$u"; then why=""
    elif ((uid < 1000)); then why="system account no installed package created"
    elif ((uid == 65534)); then why=""
    else why="not on any competition list"; fi
    if [[ -n $why ]]; then
      if in_list "$u" $me; then warn "Skipping $u: your own session is logged in as it ($why)."; continue; fi
      CU+=("$u"); CW+=("$(printf 'uid=%-6s %-22s %s' "$uid" "$shell" "$why")")
      continue
    fi
    # kept accounts: system ones should not be able to log in
    if ((uid < 1000)) && [[ $u != root && $u != sync && $u != cyberrange ]] && ! in_list "$u" $ADMIN_USERS $NORMAL_USERS; then
      sh=$(awk -F: -v u="$u" '$1==u{print $2}' /etc/shadow 2>/dev/null)
      if [[ ! $shell =~ (nologin|false)$ ]]; then FU+=("$u"); FW+=("system account has a login shell ($shell)")
      elif [[ -n $sh && $sh != [\!\*]* ]]; then FU+=("$u"); FW+=("system account has a password set")
      fi
    fi
  done < /etc/passwd
  local i
  if ((${#CU[@]})); then
    for i in "${!CU[@]}"; do printf '%s%2d)%s %-16s %s\n' "$C_R" $((i + 1)) "$C_0" "${CU[i]}" "${CW[i]}"; done
    if pick "${#CU[@]}" "Remove which accounts"; then
      local how; read -r -p "(d)elete them, or (l)ock them (no login, kept for review)? [d]: " how
      local ev; ev=$(evdir accounts)
      for i in "${PICKED[@]}"; do remove_account "${CU[i-1]}" "$ev" "${how:-d}" "${uidcount[$(id -u "${CU[i-1]}" 2>/dev/null)]:-1}"; done
      say "Account records and home folders saved in $ev"
    fi
  else
    good "Every account is on a list or belongs to Ubuntu or a scored service."
  fi
  if ((${#FU[@]})); then
    warn "Kept system accounts that can log in (they normally can't):"
    for i in "${!FU[@]}"; do printf '    %-16s %s\n' "${FU[i]}" "${FW[i]}"; done
    if confirm_yes "Set them to nologin and lock their passwords?"; then
      for u in "${FU[@]}"; do usermod -L -s /usr/sbin/nologin "$u" && logact "locked system account $u"; done
      good "Done."
    fi
  fi
  local -a missing=()
  for u in $ADMIN_USERS $NORMAL_USERS; do id "$u" >/dev/null 2>&1 || missing+=("$u"); done
  ((${#missing[@]})) && say "Competition users not on this box (fine if this box doesn't have them): ${missing[*]}"
  cmd_groups
}
remove_account() {   # user evidence-dir d|l shared-uid-count
  local u=$1 ev=$2 how=$3 shared=$4 uid home
  uid=$(id -u "$u" 2>/dev/null) || return
  home=$(getent passwd "$u" | cut -d: -f6)
  { getent passwd "$u"; grep "^$u:" /etc/shadow; id "$u"; } >> "$ev/accounts.txt" 2>/dev/null
  if [[ $home == /home/* && -d $home && $(stat -c %u "$home") == "$uid" ]]; then
    tar -C / -czf "$ev/home-$u.tgz" "${home#/}" 2>/dev/null
  fi
  loginctl terminate-user "$u" >/dev/null 2>&1
  if [[ $uid != 0 && $shared -le 1 ]]; then pkill -KILL -u "$uid" 2>/dev/null; fi
  if [[ $how == l* ]]; then
    usermod -L -e 1 -s /usr/sbin/nologin "$u" && good "Locked $u" && logact "locked account $u"
    return
  fi
  # Only delete the home folder when it's this account's own folder under /home.
  if [[ $uid != 0 && $shared -le 1 && $home == /home/* && $(stat -c %u "$home" 2>/dev/null) == "$uid" ]]; then
    userdel -r "$u" 2>/dev/null || userdel -f -r "$u" 2>/dev/null
  else
    userdel -f "$u" 2>/dev/null
  fi
  if getent passwd "$u" >/dev/null; then bad "Couldn't delete $u; locking it instead."; usermod -L -e 1 -s /usr/sbin/nologin "$u"
  else good "Deleted $u"; logact "deleted account $u (uid $uid)"; fi
}
cmd_groups() {
  hdr "Sudo and other root-level groups"
  echo "Only root and the admins ($ADMIN_USERS) belong in: $PRIV_GROUPS. Grey team and cyberrange are left alone."
  local g m members changes=0 me; me=$(operator_users)
  local -a rm_pairs=() add=()
  for g in $PRIV_GROUPS; do
    getent group "$g" >/dev/null || continue
    members=$(getent group "$g" | cut -d: -f4 | tr ',' ' ')
    for m in $members; do
      [[ $m == root ]] || is_grey "$m" || in_list "$m" $ADMIN_USERS && continue
      if in_list "$m" $me; then warn "Leaving $m in $g: your session is logged in as it."; continue; fi
      rm_pairs+=("$m:$g")
    done
  done
  for m in $ADMIN_USERS; do
    id "$m" >/dev/null 2>&1 || continue
    [[ " $(id -nG "$m") " == *" sudo "* ]] || add+=("$m")
  done
  ((${#rm_pairs[@]})) && { warn "Will remove from root-level groups:"; printf '    %s\n' "${rm_pairs[@]/:/ from }"; changes=1; }
  ((${#add[@]})) && { say "Admins missing from sudo: ${add[*]}"; changes=1; }
  local x; x=$(awk -F: '$4==0 && $1!="root"{print $1}' /etc/passwd | while read -r u; do is_grey "$u" || echo "$u"; done | tr '\n' ' ')
  [[ -n $x ]] && warn "Accounts whose main group is root (GID 0): $x"
  ((changes)) || { good "Group membership is already correct."; return; }
  confirm_yes "Apply these group changes?" || return
  local pair
  for pair in "${rm_pairs[@]}"; do gpasswd -d "${pair%%:*}" "${pair#*:}" >/dev/null 2>&1 && logact "removed ${pair%%:*} from ${pair#*:}"; done
  for m in "${add[@]}"; do usermod -aG sudo "$m" && logact "added $m to sudo"; done
  good "Groups fixed. Users already logged in keep the old groups until they log in again."
}
cmd_rotate() {
  hdr "Rotate competition passwords (grey team excluded)"
  local -a U=(); local u p1 p2 a
  for u in $ADMIN_USERS $NORMAL_USERS; do id "$u" >/dev/null 2>&1 && ! is_grey "$u" && U+=("$u"); done
  read -r -p "Also change root's password? [y/N]: " a; [[ $a =~ ^[Yy] ]] && U=(root "${U[@]}")
  ((${#U[@]})) || { warn "None of the competition users exist on this box."; return; }
  echo "Changing: ${U[*]}"
  warn "Check the competition rules: some require reporting password changes."
  read -r -s -p "New password for all of them: " p1; echo
  read -r -s -p "Again: " p2; echo
  [[ -n $p1 && $p1 == "$p2" ]] || { bad "Passwords didn't match; nothing changed."; return; }
  for u in "${U[@]}"; do printf '%s:%s\n' "$u" "$p1"; done | chpasswd && good "Changed ${#U[@]} passwords." \
    && logact "rotated passwords: ${U[*]}"
}
# ============================================= 9. accounts and sessions
cmd_accounts() {
  local c
  while :; do
    hdr "Accounts"
    local x
    x=$(awk -F: '$3==0 && $1!="root"{print $1}' /etc/passwd | tr '\n' ' ')
    [[ -n $x ]] && bad "Extra UID 0 (root-level) accounts: $x" || good "Only root has UID 0."
    echo "Accounts that can log in:"
    local role
    while IFS=: read -r u _ uid _ _ home shell; do
      [[ $shell =~ (nologin|false|sync|halt|shutdown)$ ]] && continue
      if in_list "$u" $RANGE_USERS; then role="cyber range (hands off)"
      elif is_grey "$u"; then role="grey team (hands off)"
      elif in_list "$u" $ADMIN_USERS; then role="admin"
      elif in_list "$u" $NORMAL_USERS; then role="normal user"
      elif in_list "$u" $KEEP_SYSTEM $SERVICE_USERS; then role="system"
      else role="${C_R}NOT ON ANY LIST${C_0}"; fi
      printf '  %-16s uid=%-6s %-18s pw=%-3s %-5s %s\n' "$u" "$uid" "$shell" "$(passwd -S "$u" 2>/dev/null | awk '{print $2}')" \
        "$(grep -qwE 'sudo|admin|wheel' <<< "$(id -nG "$u" 2>/dev/null)" && echo SUDO)" "$role"
    done < /etc/passwd
    echo "Sudo rules:"
    grep -rhvE '^\s*(#|$|Defaults)' /etc/sudoers /etc/sudoers.d/ 2>/dev/null | sed 's/^/  /'
    local -a SD=(); mapfile -t SD < <(find /etc/sudoers.d -type f 2>/dev/null | unowned)
    ((${#SD[@]})) && warn "sudoers.d files not from a package: ${SD[*]}"
    x=$(grep -rnE 'pam_exec|pam_script|pam_python' /etc/pam.d/ 2>/dev/null)
    [[ -n $x ]] && { bad "PAM hooks that run commands at login:"; sed 's/^/    /' <<< "$x"; }
    local -a PM=(); mapfile -t PM < <(find /usr/lib/x86_64-linux-gnu/security /lib/x86_64-linux-gnu/security /lib/security -name '*.so' 2>/dev/null | sort -u | unowned)
    ((${#PM[@]})) && bad "PAM modules not from any package: ${PM[*]}"
    echo
    echo "  u) Remove accounts not on the lists   g) Fix sudo/docker groups   r) Rotate all competition passwords"
    echo "  p) Change some passwords   l) Lock an account   s) Remove a sudoers.d file   e) End login sessions   b) Back"
    read -r -p "> " c
    case $c in
      u) cmd_users ;;
      g) cmd_groups ;;
      r) cmd_rotate ;;
      p) cmd_passwords ;;
      l) read -r -p "Account to lock (password locked, shell set to nologin): " x
         if is_grey "$x"; then warn "$x is a grey team account; not touching it."
         elif [[ -n $x && $x != root ]] && id "$x" >/dev/null 2>&1; then usermod -L -s /usr/sbin/nologin "$x" && logact "locked $x" && good "Locked $x."; fi ;;
      s) ((${#SD[@]})) || { good "None to remove."; continue; }
         local i; for i in "${!SD[@]}"; do printf '  %2d) %s\n' $((i + 1)) "${SD[i]}"; done
         if pick "${#SD[@]}" "Remove which"; then
           local ev; ev=$(evdir sudoers)
           for i in "${PICKED[@]}"; do stash "$ev" "${SD[i-1]}"; rm -f "${SD[i-1]}"; logact "removed ${SD[i-1]}"; done
           visudo -c >/dev/null && good "sudoers still valid."
         fi ;;
      e) cmd_sessions ;;
      *) return ;;
    esac
  done
}
cmd_passwords() {
  local -a U=(); local i p1 p2
  mapfile -t U < <(awk -F: '$7 !~ /(nologin|false|sync|halt|shutdown)$/ {print $1}' /etc/passwd | while read -r x; do is_grey "$x" || echo "$x"; done)
  for i in "${!U[@]}"; do printf '  %2d) %s\n' $((i + 1)) "${U[i]}"; done
  warn "Check the competition rules: some require reporting password changes on scored accounts."
  pick "${#U[@]}" "Change which" || return
  read -r -s -p "New password: " p1; echo; read -r -s -p "Again: " p2; echo
  [[ -n $p1 && $p1 == "$p2" ]] || { bad "Passwords didn't match."; return; }
  for i in "${PICKED[@]}"; do
    printf '%s:%s\n' "${U[i-1]}" "$p1" | chpasswd && good "Changed ${U[i-1]}" && logact "password changed: ${U[i-1]}"
  done
}
cmd_sessions() {
  compute_protected
  local mine; mine=$(cat /proc/$$/sessionid 2>/dev/null)
  local -a S=() SL=(); local id line nm tty rh leader st
  mapfile -t S < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}')
  ((${#S[@]})) || { warn "No logind sessions listed."; return; }
  for id in "${S[@]}"; do
    nm="" tty="" rh="" leader="" st=""
    while IFS= read -r line; do
      case $line in Name=*) nm=${line#*=} ;; TTY=*) tty=${line#*=} ;; RemoteHost=*) rh=${line#*=} ;;
        Leader=*) leader=${line#*=} ;; State=*) st=${line#*=} ;; esac
    done < <(loginctl show-session "$id" -p Name -p TTY -p RemoteHost -p Leader -p State 2>/dev/null)
    SL+=("$(printf '%-6s %-12s %-8s %-18s %-8s %s' "$id" "$nm" "${tty:--}" "${rh:-local}" "$st" \
      "$([[ $id == "$mine" || " $PROT_PIDS " == *" $leader "* ]] && echo '<- YOURS')$(is_grey "$nm" && echo '<- GREY TEAM')")")
  done
  local i; for i in "${!SL[@]}"; do printf '  %2d) %s\n' $((i + 1)) "${SL[i]}"; done
  pick "${#S[@]}" "End which sessions" || return
  for i in "${PICKED[@]}"; do
    [[ ${SL[i-1]} == *YOURS* ]] && { warn "Skipping your own session ${S[i-1]}."; continue; }
    [[ ${SL[i-1]} == *"GREY TEAM"* ]] && { warn "Skipping grey team session ${S[i-1]}."; continue; }
    loginctl terminate-session "${S[i-1]}" && good "Ended session ${S[i-1]}" && logact "ended session ${SL[i-1]}"
  done
}

# ====================================================== 10. connection watch
read -r -d '' AWK_PROG <<'AWK'
function addr(s, A,   i, a) {
  i = match(s, /:[^:]*$/)
  if (!i) { A["ip"] = s; A["port"] = ""; return }
  A["port"] = substr(s, i + 1)
  a = substr(s, 1, i - 1)
  gsub(/^\[|\]$/, "", a); sub(/%.*/, "", a); sub(/^::ffff:/, "", a)
  A["ip"] = a
}
function isloop(ip) { return (ip ~ /^127\./ || ip == "::1") }
function proc(line,   s, p) {
  if (!match(line, /users:\(\("[^"]*",pid=[0-9]+/)) return ""
  s = substr(line, RSTART + 9, RLENGTH - 9)
  split(s, p, /",pid=/)
  return p[1] SUBSEP p[2]
}
function seen(ck, t) {
  if (!(ck in first) || t < first[ck]) first[ck] = t
  if (!(ck in last)  || t > last[ck])  last[ck]  = t
}
FILENAME ~ /\/locals$/ { if ($1 != "") local[$1] = 1; next }
FILENAME ~ /\/listen\.[0-9]+$/ {
  if ($2 != "LISTEN" && $2 != "UNCONN") next
  addr($5, A); key = $1 SUBSEP A["port"]; listen[key] = 1
  p = proc($0); if (p != "") lproc[key] = p
  next
}
FILENAME ~ /\/raw\.[0-9]+$/ {
  if ($1 == "#T") { t = $2 + 0; ok = (t >= cutoff); next }
  if (!ok) next
  st = $2
  if (st == "LISTEN" || st == "UNCONN") next
  addr($5, L); addr($6, R)
  if (R["ip"] == "*" || R["port"] == "*" || R["ip"] == "" || R["port"] == "") next
  if (!lo && (isloop(R["ip"]) || isloop(L["ip"]))) next
  ck = $1 SUBSEP L["ip"] SUBSEP L["port"] SUBSEP R["ip"] SUBSEP R["port"]
  seen(ck, t)
  p = proc($0); if (p != "") cproc[ck] = p
  if (st == "SYN-SENT") cdir[ck] = "OUT"
  else if (st == "SYN-RECV" && !(ck in cdir)) cdir[ck] = "IN"
  next
}
FILENAME ~ /\/ct\.[0-9]+$/ {
  if (!match($0, /^\[[0-9]+/)) next
  t = substr($0, 2, RLENGTH - 1) + 0
  if (t < cutoff) next
  pr = src = dst = sp = dp = ""
  for (i = 1; i <= NF; i++) {
    if ($i == "[NEW]") pr = $(i + 1)
    else if (src == "" && $i ~ /^src=/)   src = substr($i, 5)
    else if (dst == "" && $i ~ /^dst=/)   dst = substr($i, 5)
    else if (sp  == "" && $i ~ /^sport=/) sp  = substr($i, 7)
    else if (dp  == "" && $i ~ /^dport=/) dp  = substr($i, 7)
  }
  if ((pr != "tcp" && pr != "udp") || src == "" || dst == "" || sp == "" || dp == "") next
  if (src in local)      { d = "OUT"; li = src; lp = sp; ri = dst; rp = dp }
  else if (dst in local) { d = "IN";  li = dst; lp = dp; ri = src; rp = sp }
  else next
  if (!lo && (isloop(ri) || isloop(li))) next
  ck = pr SUBSEP li SUBSEP lp SUBSEP ri SUBSEP rp
  seen(ck, t); cdir[ck] = d; ctflows++
  next
}
END {
  for (ck in first) {
    split(ck, k, SUBSEP); pr = k[1]; lp = k[3]; ri = k[4]; rp = k[5]
    lk = pr SUBSEP lp
    d = (ck in cdir) ? cdir[ck] : ((lk in listen) ? "IN" : "OUT")
    p = (ck in cproc) ? cproc[ck] : ""
    if (p == "" && d == "IN" && (lk in lproc)) p = lproc[lk]
    if (p == "") { name = "?"; pid = "" } else { split(p, P, SUBSEP); name = P[1]; pid = P[2] }
    port = (d == "IN") ? lp : rp
    g = d SUBSEP pr SUBSEP ri SUBSEP port SUBSEP name
    cnt[g]++
    if (!(g in gf) || first[ck] < gf[g]) gf[g] = first[ck]
    if (!(g in gl) || last[ck]  > gl[g]) gl[g] = last[ck]
    if (pid != "" && index("," gp[g] ",", "," pid ",") == 0) gp[g] = (gp[g] == "") ? pid : gp[g] "," pid
    if (d == "IN") { nin++; ipin[ri]++ } else { nout++; ipout[ri]++ }
    iptot[ri]++
    if (index("," ipp[ri] ",", "," port ",") == 0) ipp[ri] = (ipp[ri] == "") ? port : ipp[ri] "," port
    nconn++
  }
  for (g in cnt) {
    split(g, k, SUBSEP)
    printf "C\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\n", k[1], k[2], k[3], k[4], k[5], \
      (gp[g] == "" ? "-" : gp[g]), cnt[g], gf[g], gl[g], (gf[g] > newcut)
  }
  for (ri in iptot) { nip++; printf "S\t%s\t%d\t%d\t%d\t%s\n", ri, ipin[ri], ipout[ri], iptot[ri], ipp[ri] }
  printf "T\t%d\t%d\t%d\t%d\t%d\n", nconn, nip, nin, nout, ctflows
}
AWK

w_now() { printf -v "$1" '%(%s)T' -1; }
w_hms() { printf -v "$1" '%(%T)T' "$2"; }
w_dur() { local s=$2; if ((s >= 60)); then printf -v "$1" '%dm%02ds' $((s / 60)) $((s % 60)); else printf -v "$1" '%ds' "$s"; fi; }
w_start_ct() {
  have conntrack || { CT_STATE="not installed (apt install conntrack to catch short-lived flows)"; return; }
  local pre=(); have stdbuf && pre=(stdbuf -oL)
  "${pre[@]}" conntrack -E -e NEW -o timestamp >> "$WTMP/ct.$1" 2>/dev/null &
  CT_PID=$!
}
w_rotate() {
  local old=$CT_PID f s
  SEG=$1
  if [[ -n $old ]]; then w_start_ct "$SEG"; builtin kill "$old" 2>/dev/null; fi
  for f in "$WTMP"/raw.* "$WTMP"/listen.* "$WTMP"/ct.*; do
    [[ -e $f ]] || continue
    s=${f##*.}
    ((s < $1 - WINDOW - REFRESH)) && rm -f "$f"
  done
}
w_status_text() {
  local left=$((NEXT_RENDER - $1)); ((left < 0)) && left=0
  printf -v "$2" 'blueteam watch on %s | window %s | redraw %ss | next in %2ds | ? for keys' "$HOST" "$WIN_STR" "$REFRESH" "$left"
}
w_render() {
  local t=$1 newcut data line
  if ((LAST_RENDER < 0)); then newcut=$t; else newcut=$LAST_RENDER; fi
  LAST_RENDER=$t
  local_ips > "$WTMP/locals"
  shopt -s nullglob
  data=$(awk -v cutoff=$((t - WINDOW)) -v newcut="$newcut" -v lo="$INCLUDE_LO" "$AWK_PROG" \
    "$WTMP/locals" "$WTMP"/listen.* "$WTMP"/raw.* "$WTMP"/ct.*)
  shopt -u nullglob
  local -a C S; local nconn=0 nip=0 nin=0 nout=0 ctf=0
  mapfile -t C < <(awk -F'\t' '$1=="C"' <<< "$data" | sort -t$'\t' -k8,8nr -k10,10nr)
  mapfile -t S < <(awk -F'\t' '$1=="S"' <<< "$data" | sort -t$'\t' -k5,5nr)
  IFS=$'\t' read -r _ nconn nip nin nout ctf < <(awk -F'\t' '$1=="T"' <<< "$data")
  : "${nconn:=0}" "${nip:=0}" "${nin:=0}" "${nout:=0}" "${ctf:=0}"
  local -A BLK=(); local x
  while read -r x; do x=${x%%#*}; x=${x//[[:space:]]/}; [[ -n $x ]] && BLK[$x]=1; done < "$BLOCK_IPS"

  local cts
  if [[ -n $CT_STATE ]]; then cts=$CT_STATE
  elif [[ -z $CT_PID ]] || ! builtin kill -0 "$CT_PID" 2>/dev/null; then cts="failed to start"
  elif ((ctf == 0)); then cts="running, no flows yet"
  else cts="running, $ctf flows"; fi

  local lines=40 cols=200
  if ((W_TTY)); then lines=$(tput lines 2>/dev/null || echo 40); cols=$(tput cols 2>/dev/null || echo 200); fi
  local ipn=${#S[@]}; ((ipn > 6)) && ipn=6
  local rows
  if ((MAXROWS > 0)); then rows=$MAXROWS
  elif ((W_TTY)); then rows=$((lines - 10 - ipn)); ((rows < 3)) && rows=3
  else rows=${#C[@]}; ipn=${#S[@]}; fi
  WROWS=("${C[@]:0:rows}")

  local ipw=15 i f
  for ((i = 0; i < ${#WROWS[@]}; i++)); do IFS=$'\t' read -r -a f <<< "${WROWS[i]}"; ((${#f[3]} > ipw)) && ipw=${#f[3]}; done
  for ((i = 0; i < ipn; i++)); do IFS=$'\t' read -r -a f <<< "${S[i]}"; ((${#f[1]} > ipw)) && ipw=${#f[1]}; done
  ((ipw > 39)) && ipw=39

  local have_s span=$((t - START)); ((span > WINDOW)) && span=$WINDOW; w_dur have_s "$span"
  local -a OUT=() NEW=(); local st
  w_status_text "$t" st
  OUT+=("$st"); NEW+=(0)
  OUT+=("Last $WIN_STR (have $have_s): $nconn connections, $nip remote IPs, $nin in / $nout out | conntrack: $cts"); NEW+=(0)
  OUT+=(""); NEW+=(0)
  printf -v line "%-${ipw}s  %5s  %5s  %5s  %s" "TOP REMOTE IPs" IN OUT TOTAL PORTS; OUT+=("$line"); NEW+=(0)
  for ((i = 0; i < ipn; i++)); do
    IFS=$'\t' read -r -a f <<< "${S[i]}"
    printf -v line "%-${ipw}s  %5s  %5s  %5s  %s%s" "${f[1]}" "${f[2]}" "${f[3]}" "${f[4]}" "${f[5]}" "$([[ -n ${BLK[${f[1]}]:-} ]] && echo '  [blocked]')"
    OUT+=("$line"); NEW+=(0)
  done
  OUT+=(""); NEW+=(0)
  printf -v line "%3s    %-3s  %-5s %-${ipw}s  %-5s  %-26s %5s  %-8s  %-8s" "#" DIR PROTO "REMOTE IP" PORT "PROCESS (PIDs)" CONNS FIRST LAST
  OUT+=("$line"); NEW+=(0)
  local proc fs ls mark
  for ((i = 0; i < ${#WROWS[@]}; i++)); do
    IFS=$'\t' read -r -a f <<< "${WROWS[i]}"
    if [[ ${f[6]} == "-" ]]; then proc=${f[5]}; else proc="${f[5]} (${f[6]})"; fi
    ((${#proc} > 26)) && proc="${proc:0:25}~"
    w_hms fs "${f[8]}"; w_hms ls "${f[9]}"
    mark=" "; ((f[10])) && mark="+"
    [[ -n ${BLK[${f[3]}]:-} ]] && mark="x"
    printf -v line "%3d  %s %-3s  %-5s %-${ipw}s  %-5s  %-26s %5s  %-8s  %-8s" $((i + 1)) "$mark" "${f[1]}" "${f[2]}" "${f[3]}" "${f[4]}" "$proc" "${f[7]}" "$fs" "$ls"
    OUT+=("$line"); NEW+=("$([[ $mark == x ]] && echo 2 || echo "${f[10]}")")
  done
  if ((${#C[@]} > rows)); then OUT+=("     ... $((${#C[@]} - rows)) more rows (taller pane or -n)"); NEW+=(0)
  elif ((${#C[@]} == 0)); then OUT+=("     (no traffic seen yet)"); NEW+=(0); fi

  if ((W_TTY)); then
    local buf=$'\033[H' n=${#OUT[@]}
    ((n > lines - 2)) && n=$((lines - 2))
    for ((i = 0; i < n; i++)); do
      line=${OUT[i]:0:cols}
      if ((i == 0)); then buf+=$'\033[7m'"$line"$'\033[K\033[0m'
      elif ((NEW[i] == 1)); then buf+=$'\033[1;32m'"$line"$'\033[0m\033[K'
      elif ((NEW[i] == 2)); then buf+=$'\033[2m'"$line"$'\033[0m\033[K'
      else buf+="$line"$'\033[K'; fi
      buf+=$'\n'
    done
    buf+=$'\033[J'
    buf+=$'\033['"$((lines - 1))"$';1H\033[36m'"${W_KEYS:0:cols}"$'\033[0m\033[K'
    buf+=$'\033['"$lines"$';1H\033[1;33m'"${WMSG:0:cols}"$'\033[0m\033[K'
    printf '%s' "$buf"
  else
    printf '%s\n' "${OUT[@]:1}"; echo
  fi
  if [[ -n $LOGFILE ]]; then
    local stamp; printf -v stamp '%(%F %T)T' "$t"
    { echo "===== $stamp ====="; printf '%s\n' "${OUT[@]:1}"; echo; } >> "$LOGFILE"
  fi
}
w_update_status() {
  ((W_TTY)) || return
  local st cols; cols=$(tput cols 2>/dev/null || echo 200)
  w_status_text "$1" st
  printf '\033[1;1H\033[7m%s\033[K\033[0m' "${st:0:cols}"
}
w_prompt() {   # bottom-line prompt; answer in W_ANS
  local lines; lines=$(tput lines 2>/dev/null || echo 40)
  printf '\033[%d;1H\033[K\033[1;33m%s\033[0m' "$lines" "$1"
  tput cnorm 2>/dev/null
  W_ANS=""; read -r -t 60 W_ANS
  tput civis 2>/dev/null
}
w_action() {
  local act=$1 n f desc spec ok_ip=1 ok_port=1
  case $act in k) desc="kill" ;; b) desc="block the IP of" ;; p) desc="block the port of" ;; B) desc="kill + block IP + port of" ;; esac
  w_prompt "Row # to $desc (Enter cancels): "; n=$W_ANS
  if ! [[ $n =~ ^[0-9]+$ ]] || ((n < 1 || n > ${#WROWS[@]})); then WMSG="Cancelled."; NEXT_RENDER=0; return; fi
  IFS=$'\t' read -r -a f <<< "${WROWS[n-1]}"
  # f: 1=dir 2=proto 3=remote ip 4=port 5=name 6=pids
  if [[ ${f[1]} == IN ]]; then spec="in:${f[2]}:${f[4]}"; else spec="out:${f[2]}:${f[4]}"; fi
  compute_protected
  local q="" rpids=${f[6]//,/ }
  if [[ $act == k || $act == B ]]; then
    [[ $rpids == "-" ]] && { [[ $act == k ]] && { WMSG="Row $n has no process (closed or unknown). Use b or p to block it."; NEXT_RENDER=0; return; }; rpids=""; }
    [[ -n $rpids ]] && q+="kill ${f[5]} (PID ${f[6]}) and disable its service; "
  fi
  if [[ $act == b || $act == B ]]; then
    if is_protected_ip "${f[3]}"; then ok_ip=0; [[ $act == b ]] && { WMSG="Won't block ${f[3]}: $PROT_WHY."; NEXT_RENDER=0; return; }
    else q+="block ${f[3]} in and out; "; fi
  fi
  if [[ $act == p || $act == B ]]; then
    if [[ ${f[1]} == IN && " $PROTECT_PORTS " == *" ${f[4]} "* ]]; then ok_port=0
      [[ $act == p ]] && { WMSG="Won't block port ${f[4]}: it's a protected/scored port."; NEXT_RENDER=0; return; }
    elif [[ ${f[1]} == IN ]]; then q+="block inbound ${f[2]} port ${f[4]}; "
    else q+="block ALL outbound ${f[2]} to port ${f[4]}; "; fi
  fi
  [[ -n $q ]] || { WMSG="Nothing to do for row $n (protected)."; NEXT_RENDER=0; return; }
  w_prompt "Row $n: ${q%; }? [y/N] "
  [[ $W_ANS =~ ^[Yy] ]] || { WMSG="Cancelled."; NEXT_RENDER=0; return; }
  local msg=""
  if [[ ($act == k || $act == B) && -n $rpids ]]; then
    # shellcheck disable=SC2086
    kill_targets $rpids; msg+="$KT_MSG "
  fi
  if [[ ($act == b || $act == B) && $ok_ip == 1 ]]; then block_ip "${f[3]}"; msg+="$BL_MSG "; fi
  if [[ ($act == p || $act == B) && $ok_port == 1 ]]; then block_port "$spec"; msg+="$BL_MSG"; fi
  WMSG=$msg; NEXT_RENDER=0
}
w_cleanup() {
  [[ -n ${CT_PID:-} ]] && builtin kill "$CT_PID" 2>/dev/null
  rm -rf "${WTMP:-/nonexistent}"
  if ((W_TTY)); then tput cnorm 2>/dev/null; printf '\033[2J\033[H'; fi
}
cmd_watch() {
  local opt OPTIND=1
  WINDOW=300 REFRESH=30 INTERVAL=1 MAXROWS=0 INCLUDE_LO=0 LOGFILE=""
  while getopts ":w:r:i:n:lo:h" opt; do
    case $opt in
      w) WINDOW=$OPTARG ;; r) REFRESH=$OPTARG ;; i) INTERVAL=$OPTARG ;; n) MAXROWS=$OPTARG ;;
      l) INCLUDE_LO=1 ;; o) LOGFILE=$OPTARG ;;
      *) echo "watch [-w window_secs] [-r redraw_secs] [-i sample_secs] [-n rows] [-l include loopback] [-o logfile]"; return 0 ;;
    esac
  done
  W_TTY=0; [[ -t 1 && -t 0 ]] && W_TTY=1
  WTMP=$(mktemp -d /tmp/bt-watch.XXXXXX)
  CT_PID="" CT_STATE="" LAST_RENDER=-1 WROWS=()
  W_KEYS="[k] kill  [b] block IP  [p] block port  [B] kill+block both  [r] redraw  [q] quit   (+ new, x blocked)"
  WMSG="Ready. Pick a row number after pressing a key."
  HOST=$(hostname 2>/dev/null || echo host)
  trap w_cleanup EXIT
  trap 'exit 0' INT TERM
  w_dur WIN_STR "$WINDOW"
  w_now START; SEG=$START
  w_start_ct "$SEG"
  NEXT_RENDER=$START
  ((W_TTY)) && { tput civis 2>/dev/null; printf '\033[H\033[2J'; }
  local key
  while :; do
    w_now T
    { echo "#T $T"; ss -Htunap 2>/dev/null; } >> "$WTMP/raw.$SEG"
    ss -Htulnp 2>/dev/null >> "$WTMP/listen.$SEG"
    if ((T >= NEXT_RENDER)); then
      NEXT_RENDER=$((T + REFRESH))
      w_render "$T"
      w_rotate "$T"
    else
      w_update_status "$T"
    fi
    if ((W_TTY)); then
      key=""
      if read -rsn1 -t "$INTERVAL" key; then
        case $key in
          q|Q) exit 0 ;;
          r) NEXT_RENDER=0 ;;
          k|b|p|B) w_action "$key" ;;
          '?'|h) WMSG="k=kill process+service  b=block remote IP  p=block port  B=all three  r=redraw now  q=quit"; NEXT_RENDER=0 ;;
        esac
      fi
    else
      sleep "$INTERVAL"
    fi
  done
}
cmd_watch_launch() {
  install_self
  local cmd="env -i BT_TRUSTED=1 BT_SELF=$BIN PATH=$PATH HOME=/root TERM=${TERM:-xterm} LANG=C.UTF-8 TMUX=${TMUX:-} /usr/bin/bash --norc --noprofile $BIN watch"
  if [[ -n ${TMUX:-} ]] && have tmux; then
    tmux new-window -n conn-watch "$cmd" && good "Opened in a new tmux window named conn-watch."
  else
    warn "Not inside tmux, so it runs here. Press q to come back to the menu."
    sleep 2
    (cmd_watch)
  fi
}

# ========================================================== 11. guard
cmd_guard() {
  BT_GUARD=1
  fw_apply
  logact "guard started"
  local last_heal=0 now
  while sleep 2; do
    if ! fw_intact; then
      logact "guard: blocklist rules were changed or flushed - re-applying"
      fw_apply
    fi
    if [[ $DOCKER_BOX == 1 && $DOCKER_HEAL == 1 ]] && systemctl is-active --quiet docker; then
      if ! iptables -t nat -S DOCKER >/dev/null 2>&1 || ! iptables -S DOCKER >/dev/null 2>&1; then
        printf -v now '%(%s)T' -1
        if ((now - last_heal > 60)); then
          last_heal=$now
          logact "guard: Docker's chains are gone - restarting docker"
          systemctl restart docker
          [[ -n $COMPOSE_DIR && -d $COMPOSE_DIR ]] && (cd "$COMPOSE_DIR" && docker compose up -d >/dev/null 2>&1)
          fw_apply
        fi
      fi
    fi
  done
}

# ======================================================== settings/status
cmd_settings() {
  hdr "Settings for this box"
  local a ip det=0 guess="" d
  echo "Never-block IPs (scoring engine, your team): $(grep -vE '^\s*(#|$)' "$ALLOW_IPS" | tr '\n' ' ')"
  read -r -p "Add never-block IPs, space-separated (Enter to keep): " a
  for ip in $a; do
    if valid_ip "$ip"; then grep -qxF "$ip" "$ALLOW_IPS" || echo "$ip" >> "$ALLOW_IPS"; else warn "Skipping '$ip'"; fi
  done
  echo "  (Edit $ALLOW_IPS to remove entries.)"
  read -r -p "Ports this box must keep serving, i.e. scored services [$PROTECT_PORTS]: " a
  [[ -n $a ]] && PROTECT_PORTS=$a
  [[ " $PROTECT_PORTS " == *" 22 "* ]] || PROTECT_PORTS="22 $PROTECT_PORTS"
  { systemctl cat docker.service >/dev/null 2>&1 || have docker; } && det=1
  if ((det)); then read -r -p "Docker found. Is this the Docker box (keeps nftables)? [Y/n]: " a; [[ $a =~ ^[Nn] ]] && DOCKER_BOX=0 || DOCKER_BOX=1
  else read -r -p "Is this the Docker box (keeps nftables)? [y/N]: " a; [[ $a =~ ^[Yy] ]] && DOCKER_BOX=1 || DOCKER_BOX=0; fi
  if [[ $DOCKER_BOX == 1 ]]; then
    for d in /opt/* /srv/* /root/* /home/*/*; do
      [[ -f $d/docker-compose.yml || -f $d/docker-compose.yaml || -f $d/compose.yml || -f $d/compose.yaml ]] && { guess=$d; break; }
    done
    read -r -p "Compose folder to bring back up after a wipe [${COMPOSE_DIR:-$guess}]: " a
    COMPOSE_DIR=${a:-${COMPOSE_DIR:-$guess}}
    read -r -p "Let the guard restart Docker when its firewall chains get wiped? [Y/n]: " a
    [[ $a =~ ^[Nn] ]] && DOCKER_HEAL=0 || DOCKER_HEAL=1
  fi
  save_conf
  good "Saved to $CONF"
  echo "  Known red team IPs : $KNOWN_BAD_IPS"
  echo "  Subnet ranges      : $NEIGHBOR_RANGES (other hosts in this box's range get blocked)"
  echo "  Deploy key users   : $KEY_USERS"
  echo "  Grey team (no touch): $GREY_USERS"
  echo "  Range (no touch)   : $RANGE_USERS"
  echo "  Admins (sudo)      : $ADMIN_USERS"
  echo "  Normal users       : $NORMAL_USERS"
  echo "  Service accounts   : $SERVICE_USERS"
  echo "  Red team files     : $IOC_REMOVE"
  echo "  Check, don't delete: $IOC_PKGFILES"
  echo "  Edit these lists in $CONF."
}
cmd_status() {
  hdr "Status"
  printf '  guard service : %s\n' "$(systemctl is-active blueteam-guard 2>/dev/null)"
  printf '  blocked       : %s IPs, %s port rules\n' "$(grep -cvE '^\s*(#|$)' "$BLOCK_IPS")" "$(grep -cvE '^\s*(#|$)' "$BLOCK_PORTS")"
  printf '  blocklist     : %s\n' "$(fw_intact && echo "in place" || echo "${C_R}MISSING OR CHANGED${C_0}")"
  printf '  protected     : ports %s; never-block %s\n' "$PROTECT_PORTS" "$(grep -vE '^\s*(#|$)' "$ALLOW_IPS" | tr '\n' ' ')"
  printf '  known-bad IPs : %s\n' "$KNOWN_BAD_IPS"
  printf '  docker box    : %s\n' "$([[ $DOCKER_BOX == 1 ]] && echo "yes (compose: ${COMPOSE_DIR:-none}, heal: $DOCKER_HEAL)" || echo no)"
  local x
  for x in nft ufw firewalld cron atd; do printf '  %-14s: %s\n' "$x" "$(command -v "$x" >/dev/null && echo "${C_Y}present${C_0}" || echo gone)"; done
  printf '  listeners     : %s TCP/UDP ports\n' "$(ss -tulnH 2>/dev/null | wc -l)"
  echo "  last actions:"; tail -8 "$LOG" | sed 's/^/    /'
}
cmd_clean_shell() {
  say "Clean shell: verified bash, no startup files, aliases or functions. Type exit to come back."
  env -i PATH="$PATH" HOME=/root TERM="${TERM:-xterm}" LANG=C.UTF-8 PS1='[clean] \u@\h:\w\$ ' /usr/bin/bash --norc --noprofile -i
}
cmd_full() {
  cmd_iocs; cmd_verify; cmd_fw_setup; cmd_hunt; cmd_cron_remove; cmd_listeners; cmd_shell_scan; cmd_ssh; cmd_users
  confirm_yes "Rotate all competition passwords now?" && cmd_rotate
  good "Full pass done. Start the live watch (menu 12) in tmux."
}

main_menu() {
  local ch
  install_self
  while :; do
    printf '\033[H\033[2J'
    printf '%sblueteam%s on %s | docker box: %s | guard: %s | blocked: %s IPs, %s ports\n' "$C_B" "$C_0" "$(hostname)" \
      "$([[ $DOCKER_BOX == 1 ]] && echo yes || echo no)" "$(systemctl is-active blueteam-guard 2>/dev/null)" \
      "$(grep -cvE '^\s*(#|$)' "$BLOCK_IPS")" "$(grep -cvE '^\s*(#|$)' "$BLOCK_PORTS")"
    cat <<EOF

   1) Remove known red team files and processes (IOC list)
   2) Check and repair system packages (bash, nft, iptables, ssh, logind, python...)
   3) Firewall setup: iptables only, remove ufw/firewalld$([[ $DOCKER_BOX == 1 ]] || echo "/nftables"), start guard
   4) Block known red team IPs and this subnet's other hosts
   5) Block or unblock IPs and ports
   6) Hunt persistence: timers, services, startup files
   7) Remove cron and at
   8) Hunt backdoors: listening ports, odd processes, raw sockets
   9) Fix shell tampering: aliases, functions, preload, fake commands
  10) SSH: deploy key on $KEY_USERS, wipe all other keys, fix sshd_config
  11) Accounts: remove extra users, fix sudo/docker groups, rotate passwords, sessions
  12) Live connection watch (kill and block from the view)
  13) Status

   a) Full pass (1-11 in order)   s) Clean shell   c) Settings   q) Quit

  New box? Run c, then a, then 12 in tmux.
EOF
    read -r -p "> " ch
    case $ch in
      1) cmd_iocs ;; 2) cmd_verify ;; 3) cmd_fw_setup ;; 4) cmd_known_bad ;;
      5) cmd_blocklist; continue ;; 6) cmd_hunt ;; 7) cmd_cron_remove ;; 8) cmd_listeners ;;
      9) cmd_shell_scan ;; 10) cmd_ssh ;; 11) cmd_accounts; continue ;; 12) cmd_watch_launch ;; 13) cmd_status ;;
      a) cmd_full ;; s) cmd_clean_shell; continue ;; c) cmd_settings ;;
      q|Q) exit 0 ;; *) continue ;;
    esac
    pause
  done
}

usage() {
  cat <<EOF
blueteam.sh - run as root on Ubuntu 24.04

  (no args)            menu
  watch [opts]         live connection view; opts: -w SECS -r SECS -i SECS -n ROWS -l -o FILE
  guard                re-apply the blocklist whenever it's flushed (the service runs this)
  fw-apply             re-apply the blocklist once
  block-ip IP...       block IPs/CIDRs in, out and forwarded
  block-port SPEC...   SPEC = in|out:tcp|udp|both:PORT   e.g. in:tcp:18505
  known-bad            block the known red team IPs and this subnet's other hosts
  iocs                 remove known red team files/processes, fix replaced system files
  users | groups | rotate   remove off-list accounts / fix sudo groups / rotate competition passwords
  verify               check/repair core packages
  listeners | hunt | shell | ssh | accounts | cron-remove | fw-setup | status | settings
EOF
}

# ================================================================= dispatch
if [[ ! -f $CONF && ${1:-menu} == menu ]]; then cmd_settings; fi
case ${1:-menu} in
  menu) main_menu ;;
  watch) shift; cmd_watch "$@" ;;
  guard) cmd_guard ;;
  fw-apply) fw_apply && good "Blocklist applied." ;;
  block-ip) shift; for x in "$@"; do block_ip "$x"; echo "$BL_MSG"; done ;;
  block-port) shift; for x in "$@"; do block_port "$x"; echo "$BL_MSG"; done ;;
  known-bad) cmd_known_bad ;; iocs) cmd_iocs ;; users) cmd_users ;; groups) cmd_groups ;; rotate) cmd_rotate ;;
  verify) cmd_verify ;; listeners) cmd_listeners ;; hunt) cmd_hunt ;; shell) cmd_shell_scan ;;
  ssh) cmd_ssh ;; accounts) cmd_accounts ;; cron-remove) cmd_cron_remove ;; fw-setup) cmd_fw_setup ;;
  status) cmd_status ;; settings) cmd_settings ;;
  help|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac

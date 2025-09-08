#!/usr/bin/env bash
set -euo pipefail

# ---------- Config ----------
COUNTRIES=(cn ru by nl br ua ir lt ro cz in)   # add/remove here
LOG_PREFIX_V4="GEO4 "
LOG_PREFIX_V6="GEO6 "
IPV4_PREFIX="countries"
IPV6_PREFIX="countries6"
MAXELEM=1048576
# Where to persist ipsets (ipset-persistent will restore this on boot)
IPSET_RESTORE="/etc/ipset.d/restore.conf"
# ---------- /Config ---------

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need_cmd iptables
need_cmd ip6tables
need_cmd ipset
need_cmd wget
need_cmd tee

# Ensure chains exist (idempotent)
ensure_chains() {
  if ! iptables -nL blocked_countries >/dev/null 2>&1; then
    iptables -N blocked_countries
    iptables -I INPUT   -j blocked_countries -m comment --comment "Blocked countries"
    iptables -I FORWARD -j blocked_countries -m comment --comment "Blocked countries"
  fi
  if ! ip6tables -nL blocked_countries >/dev/null 2>&1; then
    ip6tables -N blocked_countries
    ip6tables -I INPUT   -j blocked_countries -m comment --comment "Blocked countries"
    ip6tables -I FORWARD -j blocked_countries -m comment --comment "Blocked countries"
  fi
}

# Ensure live sets exist (empty if new)
ensure_live_sets() {
  for c in "${COUNTRIES[@]}"; do
    [ -n "${c}" ] || continue

    if ! ipset list -n | grep -qx "${IPV4_PREFIX}_${c}"; then
      ipset create "${IPV4_PREFIX}_${c}" hash:net family inet maxelem ${MAXELEM}
    fi
    if ! ipset list -n | grep -qx "${IPV6_PREFIX}_${c}"; then
      ipset create "${IPV6_PREFIX}_${c}" hash:net family inet6 maxelem ${MAXELEM}
    fi
  done
}

# Download helper with small retry/timeout
fetch() {
  local url=$1
  wget -q --timeout=20 --tries=3 -O - "$url" || return 1
}

# Fill a temp set from a URL list (one CIDR per line), then swap into place
atomic_fill_set() {
  local live_set=$1
  local url=$2
  local family=$3   # inet | inet6
  local tmp="${live_set}_tmp_$$"

  ipset create "$tmp" hash:net family "$family" maxelem ${MAXELEM}
  if out=$(fetch "$url"); then
    # add entries; ignore empty lines
    while IFS= read -r cidr; do
      [ -n "$cidr" ] || continue
      ipset add "$tmp" "$cidr" 2>/dev/null || true
    done <<< "$out"
  else
    echo "WARN: failed to fetch $url — keeping previous set for $live_set"
    ipset destroy "$tmp"
    return 0
  fi
  ipset swap "$tmp" "$live_set"
  ipset destroy "$tmp"
}

# Insert rule if missing

ensure_rule_v4() {
  local setname=$1
  # LOG (optional)
  if ! iptables -C blocked_countries -m set --match-set "$setname" src -j LOG --log-prefix "$LOG_PREFIX_V4$setname " -m comment --comment "Block .$setname" 2>/dev/null; then
    iptables -I blocked_countries -m set --match-set "$setname" src -j LOG --log-prefix "$LOG_PREFIX_V4$setname " -m comment --comment "Block .$setname"
  fi
  # DROP
  if ! iptables -C blocked_countries -m set --match-set "$setname" src -j DROP -m comment --comment "Block .$setname" 2>/dev/null; then
    iptables -A blocked_countries -m set --match-set "$setname" src -j DROP -m comment --comment "Block .$setname"
  fi
}
ensure_rule_v6() {
  local setname=$1
  # LOG (optional)
  if ! ip6tables -C blocked_countries -m set --match-set "$setname" src -j LOG --log-prefix "$LOG_PREFIX_V6$setname " -m comment --comment "Block .$setname" 2>/dev/null; then
    ip6tables -I blocked_countries -m set --match-set "$setname" src -j LOG --log-prefix "$LOG_PREFIX_V6$setname " -m comment --comment "Block .$setname"
  fi
  # DROP
  if ! ip6tables -C blocked_countries -m set --match-set "$setname" src -j DROP -m comment --comment "Block .$setname" 2>/dev/null; then
    ip6tables -A blocked_countries -m set --match-set "$setname" src -j DROP -m comment --comment "Block .$setname"
  fi
}

main() {
  [ "$EUID" -eq 0 ] || { echo "Run as root."; exit 1; }

  ensure_chains
  ensure_live_sets

  # Update each country (v4 + v6)
  for c in "${COUNTRIES[@]}"; do
    echo "Updating $c ..."
    atomic_fill_set "${IPV4_PREFIX}_${c}" "https://www.ipdeny.com/ipblocks/data/aggregated/${c}-aggregated.zone" inet
    atomic_fill_set "${IPV6_PREFIX}_${c}" "https://www.ipdeny.com/ipv6/ipaddresses/blocks/${c}.zone" inet6
  done

  # Ensure rules reference these sets
  for c in "${COUNTRIES[@]}"; do
    ensure_rule_v4 "${IPV4_PREFIX}_${c}"
    ensure_rule_v6 "${IPV6_PREFIX}_${c}"
  done

  # Persist for fast boot (no re-download)
  mkdir -p "$(dirname "$IPSET_RESTORE")"
  ipset save | tee "$IPSET_RESTORE" >/dev/null

  # Persist iptables as well (requires iptables-persistent)
  if command -v iptables-save >/dev/null; then
    mkdir -p /etc/iptables
    iptables-save  | tee /etc/iptables/rules.v4 >/dev/null
    ip6tables-save | tee /etc/iptables/rules.v6 >/dev/null
  fi

  echo "Done."
}

main "$@"


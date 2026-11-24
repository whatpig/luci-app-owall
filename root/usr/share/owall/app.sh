#!/bin/sh

CONFIG="owall"
CORE_BIN="xray"
CONFIG_FILE="/var/etc/owall.json"
HASH_FILE="/var/etc/owall_input.md5"
LOCK_FILE="/var/lock/owall.lock"
LOG_FILE="/var/log/owall.log"

detect_asset_dir() {
	if [ -f "/usr/share/v2ray/geoip.dat" ] && [ -f "/usr/share/v2ray/geosite.dat" ]; then
		echo "/usr/share/v2ray"
	elif [ -f "/usr/share/xray/geoip.dat" ] && [ -f "/usr/share/xray/geosite.dat" ]; then
		echo "/usr/share/xray"
	else
		echo "/usr/share/v2ray"
	fi
}

export XRAY_LOCATION_ASSET="$(detect_asset_dir)"

has_nft() {
	command -v nft >/dev/null 2>&1
}

get_owall_pids() {
	ps w 2>/dev/null | grep "[/ ]var/etc/owall.json" | awk '{print $1}'
}

start_firewall() {
	if has_nft; then
		/usr/share/owall/nftables.sh start
	else
		/usr/share/owall/iptables.sh start
	fi
}

stop_firewall() {
	if has_nft; then
		/usr/share/owall/nftables.sh stop
	fi
	/usr/share/owall/iptables.sh stop
}

sync_nodes() {
	local force="$1"
	mkdir -p /var/etc /var/log
	local input=$(uci -q get owall.global.node_input)
	[ -z "$input" ] && return 0

	local cur_hash=$(printf '%s' "$input" | md5sum | awk '{print $1}')
	local old_hash=""
	[ -f "$HASH_FILE" ] && old_hash=$(cat "$HASH_FILE" 2>/dev/null)
	local has_nodes=$(uci -q show owall | grep -m1 "=nodes")

	if [ "$force" = "force" ] || [ "$cur_hash" != "$old_hash" ] || [ -z "$has_nodes" ]; then
		lua /usr/share/owall/sub_parser.lua || return 1
		printf '%s' "$cur_hash" > "$HASH_FILE"
	fi
	return 0
}

prepare() {
	mkdir -p /var/etc /var/log /var/lock

	if ! command -v "$CORE_BIN" >/dev/null 2>&1; then
		echo "ERROR: $CORE_BIN not found in PATH! Please install xray-core."
		return 1
	fi

	sync_nodes "$1" || return 1
	lua /usr/share/owall/gen_config.lua || return 1

	if ! "$CORE_BIN" run -test -c "$CONFIG_FILE"; then
		echo "ERROR: Xray configuration test failed!"
		return 1
	fi
	return 0
}

run() {
	local enabled=$(uci -q get owall.global.enabled)
	[ "$enabled" = "1" ] || exit 0

	[ -f "$CONFIG_FILE" ] || prepare >> "$LOG_FILE" 2>&1 || exit 1

	echo "[$(date '+%F %T')] Launching Xray-core ($CORE_BIN) with $CONFIG_FILE (asset=$XRAY_LOCATION_ASSET)..." >> "$LOG_FILE"
	exec "$CORE_BIN" run -c "$CONFIG_FILE" >> "$LOG_FILE" 2>&1
}

kill_all() {
	local pids=$(get_owall_pids)
	[ -n "$pids" ] && kill -9 $pids 2>/dev/null || true
}

reload() {
	mkdir -p /var/lock
	(
		flock -n 9 || exit 0
		/etc/init.d/owall restart
	) 9>"$LOCK_FILE"
}

case "$1" in
	prepare) prepare "$2" ;;
	sync) sync_nodes "force" ;;
	run) run ;;
	start_firewall) start_firewall ;;
	stop_firewall) stop_firewall ;;
	kill_all) kill_all ;;
	reload) reload ;;
	*) echo "Usage: $0 {prepare|sync|run|start_firewall|stop_firewall|kill_all|reload}" ;;
esac

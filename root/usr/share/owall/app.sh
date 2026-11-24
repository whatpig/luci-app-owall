#!/bin/sh

CONFIG="owall"
CORE_BIN="xray"
CONFIG_FILE="/var/etc/owall.json"
PID_FILE="/var/run/owall.pid"

export XRAY_LOCATION_ASSET="/usr/share/v2ray"

has_nft() {
	command -v nft >/dev/null 2>&1
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

generate_config() {
	mkdir -p /var/etc
	lua /usr/share/owall/gen_config.lua
}

run() {
	local enabled=$(uci -q get owall.global.enabled)
	[ "$enabled" = "1" ] || exit 0

	# Ensure nodes are populated
	local active=$(uci -q get owall.global.active_node)
	if [ -z "$active" ]; then
		lua /usr/share/owall/sub_parser.lua
	fi

	generate_config

	if ! command -v "$CORE_BIN" >/dev/null 2>&1; then
		echo "ERROR: $CORE_BIN not found in PATH! Please install xray-core."
		exit 1
	fi

	echo "Starting Xray-core ($CORE_BIN) with $CONFIG_FILE..."
	exec "$CORE_BIN" run -c "$CONFIG_FILE"
}

kill_all() {
	killall -9 "$CORE_BIN" 2>/dev/null || true
	rm -f "$PID_FILE"
}

reload() {
	generate_config
	kill_all
	run &
	start_firewall
}

case "$1" in
	run) run ;;
	start_firewall) start_firewall ;;
	stop_firewall) stop_firewall ;;
	kill_all) kill_all ;;
	reload) reload ;;
	*) echo "Usage: $0 {run|start_firewall|stop_firewall|kill_all|reload}" ;;
esac

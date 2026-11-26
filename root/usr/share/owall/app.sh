#!/bin/sh

CONFIG="owall"
CORE_BIN="xray"
CONFIG_FILE="/var/etc/owall.json"
HASH_FILE="/var/etc/owall_input.md5"
CHINA_IP_FILE="/etc/owall/china_ip.txt"
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

get_owall_pids() {
	ps w 2>/dev/null | grep "[/ ]var/etc/owall.json" | awk '{print $1}'
}

ensure_china_ip() {
	if [ -f "/usr/share/v2ray/china.txt" ]; then
		return 0
	fi
	if command -v geoview >/dev/null 2>&1 && { [ -f "/usr/share/v2ray/geoip.dat" ] || [ -f "/usr/share/xray/geoip.dat" ]; }; then
		return 0
	fi

	if [ -f "$CHINA_IP_FILE" ]; then
		local cnt=$(grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' "$CHINA_IP_FILE" 2>/dev/null || true)
		cnt=${cnt:-0}
		local now=$(date +%s)
		local mtime=$(date -r "$CHINA_IP_FILE" +%s 2>/dev/null)
		if [ "$cnt" -ge 500 ] && [ -n "$mtime" ] && [ $((now - mtime)) -lt 604800 ]; then
			return 0
		fi
	fi

	mkdir -p /etc/owall
	local tmp_file="/tmp/owall_china_ip.tmp.$$"
	local url
	for url in "https://ispip.clang.cn/all_cn.txt" "https://cdn.jsdelivr.net/gh/gaoyifan/china-operator-ip@ip-lists/china.txt"; do
		curl -sL --connect-timeout 5 -m 15 -A 'Owall/1.2' "$url" -o "$tmp_file" 2>/dev/null || continue
		local cnt=$(grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' "$tmp_file" 2>/dev/null || true)
		cnt=${cnt:-0}
		if [ "$cnt" -ge 500 ]; then
			grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' "$tmp_file" > "${CHINA_IP_FILE}.tmp.$$"
			mv -f "${CHINA_IP_FILE}.tmp.$$" "$CHINA_IP_FILE"
			rm -f "$tmp_file"
			echo "[app] Updated $CHINA_IP_FILE ($cnt CIDRs from $url)."
			return 0
		fi
	done

	rm -f "$tmp_file" "${CHINA_IP_FILE}.tmp.$$"
	echo "[app] WARNING: failed to fetch China IP list; Layer-3 bypass will use cached or Xray GeoIP rules."
	return 0
}

start_firewall() {
	if ! command -v nft >/dev/null 2>&1; then
		echo "[app] ERROR: nft (nftables / fw4) not found!"
		return 1
	fi
	/usr/share/owall/nftables.sh start
}

stop_firewall() {
	command -v nft >/dev/null 2>&1 && /usr/share/owall/nftables.sh stop
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

	local active_node=$(uci -q get owall.global.active_node)
	if [ -z "$active_node" ] || ! uci -q get "owall.${active_node}" >/dev/null 2>&1; then
		local node_count=$(uci -q show owall | grep -c "=nodes" 2>/dev/null || true)
		node_count=${node_count:-0}
		if [ "$node_count" -ge 2 ]; then
			/usr/share/owall/url_test.sh select_best
		fi
	fi

	ensure_china_ip
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
	if command -v flock >/dev/null 2>&1; then
		(
			flock -n 9 || exit 0
			/etc/init.d/owall restart
		) 9>"$LOCK_FILE"
	else
		local lock_dir="/var/lock/owall.lock.d"
		if ! mkdir "$lock_dir" 2>/dev/null; then
			local now=$(date +%s)
			local mtime=$(date -r "$lock_dir" +%s 2>/dev/null || echo 0)
			if [ "$mtime" -gt 0 ] && [ $((now - mtime)) -gt 60 ]; then
				rmdir "$lock_dir" 2>/dev/null || true
				mkdir "$lock_dir" 2>/dev/null || return 0
			else
				return 0
			fi
		fi
		trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT INT TERM
		/etc/init.d/owall restart
		rmdir "$lock_dir" 2>/dev/null || true
		trap - EXIT INT TERM
	fi
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

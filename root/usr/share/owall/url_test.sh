#!/bin/sh

CONFIG="owall"
STATUS_FILE="/tmp/owall_status.json"

test_node() {
	local node_id="$1"
	[ -z "$node_id" ] && return 9999

	local addr=$(uci -q get owall.${node_id}.address)
	local port=$(uci -q get owall.${node_id}.port)
	[ -z "$addr" ] || [ -z "$port" ] && return 9999

	local latency=9999
	if command -v tcping >/dev/null 2>&1; then
		latency=$(tcping -q -c 1 -t 2 "$addr" "$port" 2>/dev/null | awk -F'/' '{print $4}' | cut -d'.' -f1)
	else
		local start_t=$(date +%s%3N 2>/dev/null || date +%s)
		nc -z -w 2 "$addr" "$port" 2>/dev/null
		if [ $? -eq 0 ]; then
			local end_t=$(date +%s%3N 2>/dev/null || date +%s)
			latency=$((end_t - start_t))
		fi
	fi

	echo "${latency:-9999}"
}

auto_select_best() {
	local best_node=""
	local min_latency=9999

	for section in $(uci -q show owall | grep "=nodes" | cut -d'.' -f2 | cut -d'=' -f1); do
		local lat=$(test_node "$section")
		if [ "$lat" -lt "$min_latency" ] && [ "$lat" -gt 0 ]; then
			min_latency="$lat"
			best_node="$section"
		fi
	done

	if [ -n "$best_node" ] && [ "$min_latency" -lt 9999 ]; then
		uci -q set owall.global.active_node="$best_node"
		uci -q commit owall
		echo "Best node selected: $best_node ($min_latency ms)"
		# Reload configuration if running
		if pidof xray >/dev/null 2>&1; then
			/usr/share/owall/app.sh reload
		fi
	fi
}

check_status() {
	local active_node=$(uci -q get owall.global.active_node)
	local remarks="None"
	local latency="9999"

	if [ -n "$active_node" ]; then
		remarks=$(uci -q get owall.${active_node}.remarks || echo "$active_node")
		latency=$(test_node "$active_node")
	fi

	local running=0
	pidof xray >/dev/null 2>&1 && running=1

	local google_ok=0
	if [ "$running" -eq 1 ]; then
		curl -sIL -k -m 3 --socks5 127.0.0.1:1080 https://www.google.com >/dev/null 2>&1 && google_ok=1
	fi

	cat <<-EOF > "$STATUS_FILE"
		{
			"running": $running,
			"active_node": "$active_node",
			"remarks": "$remarks",
			"latency": "$latency",
			"google": $google_ok
		}
	EOF
}

case "$1" in
	auto) auto_select_best ;;
	status) check_status ;;
	test) test_node "$2" ;;
	*) check_status ;;
esac

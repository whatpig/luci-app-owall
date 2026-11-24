#!/bin/sh

CONFIG="owall"
STATUS_FILE="/tmp/owall_status.json"
LOG_FILE="/var/log/owall.log"

json_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\r\n' '  '
}

test_node() {
	local node_id="$1"
	[ -z "$node_id" ] && { echo 9999; return; }

	local addr=$(uci -q get owall.${node_id}.address)
	local port=$(uci -q get owall.${node_id}.port)
	[ -z "$addr" ] || [ -z "$port" ] && { echo 9999; return; }

	local latency=9999
	if command -v tcping >/dev/null 2>&1; then
		latency=$(tcping -q -c 1 -t 2 "$addr" "$port" 2>/dev/null | awk -F'/' '{print $4}' | cut -d'.' -f1)
	fi

	# Reliable BusyBox-compatible TCP handshake timing via curl %{time_connect}
	if [ -z "$latency" ] || [ "$latency" = "9999" ]; then
		local target="$addr:$port"
		echo "$addr" | grep -q ':' && target="[$addr]:$port"
		local raw=$(curl -s -o /dev/null --connect-timeout 2 -m 2 -w "%{time_connect}" "http://${target}" 2>/dev/null || true)
		latency=$(awk -v t="${raw:-0}" 'BEGIN{ms=int(t*1000+0.5); print (ms>0?ms:9999)}')
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
		if pgrep -f "/var/etc/owall.json" >/dev/null 2>&1; then
			/etc/init.d/owall restart >/dev/null 2>&1
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
	if pgrep -f "/var/etc/owall.json" >/dev/null 2>&1 || pidof xray >/dev/null 2>&1; then
		running=1
	fi

	local google_ok=0
	if [ "$running" -eq 1 ]; then
		local code=$(curl -s -o /dev/null -w "%{http_code}" -k -m 5 --socks5-hostname 127.0.0.1:1080 https://www.google.com/generate_204 2>/dev/null)
		[ "$code" = "204" ] || [ "$code" = "200" ] && google_ok=1
	fi

	local last_log=""
	if [ -f "$LOG_FILE" ]; then
		last_log=$(tail -n 3 "$LOG_FILE" | tr '\n' ' ')
	fi

	local esc_remarks=$(json_escape "$remarks")
	local esc_log=$(json_escape "$last_log")

	cat <<-EOF > "$STATUS_FILE"
		{
			"running": $running,
			"active_node": "$active_node",
			"remarks": "$esc_remarks",
			"latency": "$latency",
			"google": $google_ok,
			"last_log": "$esc_log"
		}
	EOF
}

case "$1" in
	auto) auto_select_best ;;
	status) check_status ;;
	test) test_node "$2" ;;
	*) check_status ;;
esac

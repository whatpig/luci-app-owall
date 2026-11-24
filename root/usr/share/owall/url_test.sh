#!/bin/sh

CONFIG="owall"
STATUS_FILE="/tmp/owall_status.json"
LOG_FILE="/var/log/owall.log"

json_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\r\n' '  '
}

is_owall_running() {
	ps w 2>/dev/null | grep -q "[/ ]var/etc/owall.json" && return 0
	pidof xray >/dev/null 2>&1 && return 0
	return 1
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
		rm -f "$STATUS_FILE"
		echo "Best node selected: $best_node ($min_latency ms)"
		if is_owall_running; then
			/etc/init.d/owall restart >/dev/null 2>&1
		fi
	fi
}

check_status() {
	local force="$1"
	# 8-second status cache to avoid hammering VPS/uhttpd on rapid polls or multi-tab views
	if [ "$force" != "force" ] && [ -f "$STATUS_FILE" ]; then
		local now=$(date +%s)
		local mtime=$(date -r "$STATUS_FILE" +%s 2>/dev/null)
		if [ -n "$mtime" ] && [ $((now - mtime)) -lt 8 ]; then
			return 0
		fi
	fi

	local active_node=$(uci -q get owall.global.active_node)
	local socks_port=$(uci -q get owall.global.socks_port || echo 1080)
	local remarks="None"
	local latency="9999"

	if [ -n "$active_node" ]; then
		remarks=$(uci -q get owall.${active_node}.remarks || echo "$active_node")
		latency=$(test_node "$active_node")
	fi

	local running=0
	is_owall_running && running=1

	local fw_ok=0
	if nft list table inet owall >/dev/null 2>&1 || iptables -t mangle -L OWALL >/dev/null 2>&1; then
		fw_ok=1
	fi

	local google_ok=0
	if [ "$running" -eq 1 ]; then
		local code=$(curl -s -o /dev/null -w "%{http_code}" -k -m 5 --socks5-hostname "127.0.0.1:${socks_port}" https://www.google.com/generate_204 2>/dev/null)
		[ "$code" = "204" ] || [ "$code" = "200" ] && google_ok=1
	fi

	local last_log=""
	if [ -f "$LOG_FILE" ]; then
		last_log=$(tail -n 3 "$LOG_FILE" | tr '\n' ' ')
	fi

	local esc_remarks=$(json_escape "$remarks")
	local esc_log=$(json_escape "$last_log")
	local tmp_file="${STATUS_FILE}.tmp.$$"

	cat <<-EOF > "$tmp_file"
		{
			"running": $running,
			"fw_ok": $fw_ok,
			"active_node": "$active_node",
			"remarks": "$esc_remarks",
			"latency": "$latency",
			"google": $google_ok,
			"last_log": "$esc_log"
		}
	EOF
	mv -f "$tmp_file" "$STATUS_FILE"
}

case "$1" in
	auto) auto_select_best ;;
	status) check_status "$2" ;;
	test) test_node "$2" ;;
	*) check_status "$2" ;;
esac

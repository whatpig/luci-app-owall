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
	local skip_node="$1"
	local no_restart="$2"
	local best_node=""
	local min_latency=9999
	local fallback_lat=9999

	local tmp_dir="/tmp/owall_lat.$$"
	mkdir -p "$tmp_dir"
	local sections=$(uci -q show owall | grep "=nodes" | cut -d'.' -f2 | cut -d'=' -f1)
	local jobs=0
	local section
	for section in $sections; do
		(
			lat=$(test_node "$section")
			echo "$lat" > "$tmp_dir/$section"
		) &
		jobs=$((jobs + 1))
		if [ "$jobs" -ge 16 ]; then
			wait
			jobs=0
		fi
	done
	wait

	for section in $sections; do
		local lat=$(cat "$tmp_dir/$section" 2>/dev/null || echo 9999)
		[ -n "$lat" ] || lat=9999
		if [ "$section" = "$skip_node" ]; then
			fallback_lat="$lat"
			continue
		fi
		if [ "$lat" -lt "$min_latency" ] && [ "$lat" -gt 0 ]; then
			min_latency="$lat"
			best_node="$section"
		fi
	done
	rm -rf "$tmp_dir"

	if [ -z "$best_node" ] && [ -n "$skip_node" ] && [ "$fallback_lat" -lt 9999 ] && [ "$fallback_lat" -gt 0 ]; then
		best_node="$skip_node"
		min_latency="$fallback_lat"
	fi

	if [ -n "$best_node" ] && [ "$min_latency" -lt 9999 ]; then
		local cur=$(uci -q get owall.global.active_node)
		if [ "$best_node" != "$cur" ]; then
			uci -q set owall.global.active_node="$best_node"
			uci -q commit owall
			rm -f "$STATUS_FILE"
			echo "Best node selected: $best_node ($min_latency ms)"
			if [ "$no_restart" != "no_restart" ] && is_owall_running; then
				/etc/init.d/owall restart >/dev/null 2>&1
			fi
		else
			echo "Current node $best_node remains optimal ($min_latency ms)"
		fi
	fi
}

watchdog() {
	while true; do
		sleep 60
		local enabled=$(uci -q get owall.global.enabled)
		local auto_sw=$(uci -q get owall.global.auto_switch)
		[ "$enabled" = "1" ] && [ "$auto_sw" = "1" ] || continue

		local node_count=$(uci -q show owall | grep -c "=nodes" 2>/dev/null || true)
		node_count=${node_count:-0}
		[ "$node_count" -ge 2 ] || continue

		is_owall_running || continue

		local socks_port=$(uci -q get owall.global.socks_port || echo 1080)
		[ -n "$socks_port" ] || socks_port=1080

		local ok=0
		local i=1
		while [ "$i" -le 3 ]; do
			local code=$(curl -s -o /dev/null -w "%{http_code}" -k -m 5 --socks5-hostname "127.0.0.1:${socks_port}" https://www.google.com/generate_204 2>/dev/null)
			if [ "$code" = "204" ] || [ "$code" = "200" ]; then
				ok=1
				break
			fi
			[ "$i" -lt 3 ] && sleep 5
			i=$((i + 1))
		done

		if [ "$ok" -eq 0 ]; then
			local cur=$(uci -q get owall.global.active_node)
			echo "[$(date '+%F %T')] [watchdog] Active node ($cur) failed 3 health checks, switching to best available node..." >> "$LOG_FILE"
			auto_select_best "$cur" >> "$LOG_FILE" 2>&1
		fi
	done
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
	if nft list table inet owall >/dev/null 2>&1; then
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
	select_best) auto_select_best "" "no_restart" ;;
	watchdog) watchdog ;;
	status) check_status "$2" ;;
	test) test_node "$2" ;;
	*) check_status "$2" ;;
esac

#!/bin/sh

TPROXY_PORT=1081
DNS_PORT=5335
FWMARK=0x1
XRAY_MARK=0xff
ROUTETABLE=100

set_tproxy_sysctl() {
	# Required for TPROXY and single-arm / bypass gateway (旁路由) routing
	sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.all.src_valid_mark=0 >/dev/null 2>&1 || true
	sysctl -w net.ipv4.conf.default.src_valid_mark=0 >/dev/null 2>&1 || true
	local f
	for f in /proc/sys/net/ipv4/conf/*/rp_filter /proc/sys/net/ipv4/conf/*/src_valid_mark; do
		[ -w "$f" ] && echo 0 > "$f" 2>/dev/null || true
	done
}

start_nftables() {
	stop_nftables 2>/dev/null || true
	set_tproxy_sysctl

	# Set up IP policy routing for TPROXY (idempotent)
	ip rule del fwmark $FWMARK table $ROUTETABLE 2>/dev/null || true
	ip rule add fwmark $FWMARK table $ROUTETABLE pref 100 || {
		echo "[nftables] ERROR: failed to add ip rule for fwmark $FWMARK"
		return 1
	}
	ip route replace local 0.0.0.0/0 dev lo table $ROUTETABLE || {
		echo "[nftables] ERROR: failed to add local route to table $ROUTETABLE"
		return 1
	}

	if ! nft -f - <<-EOF
		table inet owall {
			set owall_direct {
				type ipv4_addr
				flags interval
				auto-merge
				elements = {
					0.0.0.0/8,
					10.0.0.0/8,
					100.64.0.0/10,
					127.0.0.0/8,
					169.254.0.0/16,
					172.16.0.0/12,
					192.168.0.0/16,
					224.0.0.0/4,
					240.0.0.0/4,
					223.5.5.5,
					119.29.29.29
				}
			}

			chain dstnat {
				type nat hook prerouting priority dstnat; policy accept;

				# Never redirect Xray self-marked DNS queries
				meta mark $XRAY_MARK return

				# Redirect all LAN IPv4 & IPv6 DNS queries (UDP/TCP 53) to Xray dns-in
				meta l4proto { tcp, udp } th dport 53 redirect to :$DNS_PORT
			}

			chain prerouting {
				type filter hook prerouting priority mangle; policy accept;

				# Never intercept Xray self-marked outbound packets or WAN reply packets
				meta mark $XRAY_MARK return
				ct direction reply return

				# Keep established transparent proxy TCP sockets routed to local TPROXY
				meta nfproto ipv4 meta l4proto tcp socket transparent 1 meta mark set $FWMARK accept

				# Skip DNS (already handled by dstnat redirect)
				meta l4proto { tcp, udp } th dport 53 return

				# Direct bypass for router local IPs, LAN, VPS node, and China IPs
				ip daddr @owall_direct return

				# TPROXY intercept for Fake-IP and all remaining foreign IPv4 TCP/UDP traffic
				ip protocol { tcp, udp } ip daddr 198.18.0.0/16 meta mark set $FWMARK tproxy ip to :$TPROXY_PORT accept
				ip protocol { tcp, udp } meta mark set $FWMARK tproxy ip to :$TPROXY_PORT accept
			}
		}
	EOF
	then
		echo "[nftables] ERROR: nft failed to load table inet owall!"
		return 1
	fi

	# Add all local router IPv4 addresses (LAN + WAN) to direct set
	local lip
	for lip in $(ip -4 addr show 2>/dev/null | awk '/inet /{print $2}' | cut -d'/' -f1); do
		nft add element inet owall owall_direct { $lip } 2>/dev/null || true
	done

	# Add active node IP to direct set
	local active_node=$(uci -q get owall.global.active_node)
	if [ -n "$active_node" ]; then
		local node_ip=$(uci -q get owall.${active_node}.address)
		if [ -n "$node_ip" ]; then
			local resolved=$(resolveip -4 "$node_ip" 2>/dev/null | head -n 1)
			[ -n "$resolved" ] && nft add element inet owall owall_direct { $resolved } 2>/dev/null || true
		fi
	fi

	# Add GeoIP CN to direct set if china.txt / geoview exists
	if [ -f "/usr/share/v2ray/china.txt" ]; then
		awk '{print "add element inet owall owall_direct { "$1" }"}' /usr/share/v2ray/china.txt | nft -f - 2>/dev/null || true
	elif command -v geoview >/dev/null 2>&1 && [ -f "/usr/share/v2ray/geoip.dat" ]; then
		geoview -i /usr/share/v2ray/geoip.dat -c cn -4 2>/dev/null | awk '{print "add element inet owall owall_direct { "$1" }"}' | nft -f - 2>/dev/null || true
	fi

	echo "[nftables] Owall transparent proxy (TPROXY + DNS) rules loaded."
}

stop_nftables() {
	nft delete table inet owall 2>/dev/null || true
	ip rule del fwmark $FWMARK table $ROUTETABLE 2>/dev/null || true
	ip route del local 0.0.0.0/0 dev lo table $ROUTETABLE 2>/dev/null || true
	echo "[nftables] Owall nftables rules cleaned up."
}

case "$1" in
	start) start_nftables ;;
	stop) stop_nftables ;;
	*) echo "Usage: $0 {start|stop}" ;;
esac

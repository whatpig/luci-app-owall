#!/bin/sh

TPROXY_PORT=1081
DNS_PORT=5335
FWMARK=0x1
XRAY_MARK=0xff
ROUTETABLE=100

start_nftables() {
	stop_nftables 2>/dev/null || true

	# Set up IP route & rule for TPROXY
	ip rule add fwmark $FWMARK table $ROUTETABLE 2>/dev/null || true
	ip route add local default dev lo table $ROUTETABLE 2>/dev/null || true

	local node_ip
	local active_node=$(uci -q get owall.global.active_node)
	[ -n "$active_node" ] && node_ip=$(uci -q get owall.${active_node}.address)

	nft -f - <<-EOF
		table inet owall {
			set owall_direct {
				type ipv4_addr
				flags interval
				elements = {
					0.0.0.0/8,
					10.0.0.0/8,
					100.64.0.0/10,
					127.0.0.0/8,
					169.254.0.0/16,
					172.16.0.0/12,
					192.168.0.0/16,
					224.0.0.0/4,
					240.0.0.0/4
				}
			}

			chain prerouting {
				type filter hook prerouting priority mangle - 150; policy accept;

				# Bypass Xray-core self-marked outbound traffic (sockopt.mark = 255)
				meta mark $XRAY_MARK return

				# Direct DNS redirect for LAN clients
				meta l4proto { tcp, udp } th dport 53 redirect to :$DNS_PORT

				# Direct bypass for private, LAN, VPS node, and China IP addresses
				ip daddr @owall_direct return

				# TPROXY intercept for Fake-IP and foreign traffic
				ip daddr 198.18.0.0/16 meta l4proto { tcp, udp } meta mark set $FWMARK tproxy to :$TPROXY_PORT accept
				meta l4proto { tcp, udp } meta mark set $FWMARK tproxy to :$TPROXY_PORT accept
			}
		}
	EOF

	# Add active node IP to direct set if resolved
	if [ -n "$node_ip" ]; then
		local resolved=$(resolveip -4 "$node_ip" 2>/dev/null | head -n 1)
		[ -n "$resolved" ] && nft add element inet owall owall_direct { $resolved } 2>/dev/null || true
	fi

	# Add GeoIP CN to direct set if china.txt / geoview exists
	if [ -f "/usr/share/v2ray/china.txt" ]; then
		awk '{print "add element inet owall owall_direct { "$1" }"}' /usr/share/v2ray/china.txt | nft -f - 2>/dev/null || true
	elif command -v geoview >/dev/null 2>&1; then
		geoview -i /usr/share/v2ray/geoip.dat -c cn -4 2>/dev/null | awk '{print "add element inet owall owall_direct { "$1" }"}' | nft -f - 2>/dev/null || true
	fi

	echo "Owall nftables rules successfully applied."
}

stop_nftables() {
	nft delete table inet owall 2>/dev/null || true
	ip rule del fwmark $FWMARK table $ROUTETABLE 2>/dev/null || true
	ip route del local default dev lo table $ROUTETABLE 2>/dev/null || true
	echo "Owall nftables rules cleaned up."
}

case "$1" in
	start) start_nftables ;;
	stop) stop_nftables ;;
	*) echo "Usage: $0 {start|stop}" ;;
esac

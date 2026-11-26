#!/bin/sh

TPROXY_PORT=$(uci -q get owall.global.tproxy_port || echo 1081)
DNS_PORT=$(uci -q get owall.global.dns_port || echo 5335)
[ -n "$TPROXY_PORT" ] || TPROXY_PORT=1081
[ -n "$DNS_PORT" ] || DNS_PORT=5335
FWMARK=0x1
XRAY_MARK=0xff
ROUTETABLE=100

set_tproxy_sysctl() {
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

start_iptables() {
	stop_iptables 2>/dev/null || true
	set_tproxy_sysctl

	ip rule del fwmark $FWMARK table $ROUTETABLE 2>/dev/null || true
	ip rule add fwmark $FWMARK table $ROUTETABLE pref 100 2>/dev/null || true
	ip route replace local 0.0.0.0/0 dev lo table $ROUTETABLE 2>/dev/null || true

	ipset create owall_direct hash:net 2>/dev/null || ipset flush owall_direct 2>/dev/null || true
	for ip in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4 223.5.5.5 119.29.29.29; do
		ipset add owall_direct $ip 2>/dev/null || true
	done
	for lip in $(ip -4 addr show 2>/dev/null | awk '/inet /{print $2}' | cut -d'/' -f1); do
		ipset add owall_direct $lip 2>/dev/null || true
	done

	local active_node=$(uci -q get owall.global.active_node)
	if [ -n "$active_node" ]; then
		local node_ip=$(uci -q get owall.${active_node}.address)
		local resolved=$(resolveip -4 "$node_ip" 2>/dev/null | head -n 1)
		[ -n "$resolved" ] && ipset add owall_direct $resolved 2>/dev/null || true
	fi

	local cn_file=""
	if [ -f "/usr/share/v2ray/china.txt" ]; then
		cn_file="/usr/share/v2ray/china.txt"
	elif [ -f "/etc/owall/china_ip.txt" ]; then
		cn_file="/etc/owall/china_ip.txt"
	fi
	if [ -n "$cn_file" ]; then
		awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/ { printf "add -exist owall_direct %s\n", $1 }' "$cn_file" | ipset restore -! 2>/dev/null || true
	elif command -v geoview >/dev/null 2>&1 && [ -f "/usr/share/v2ray/geoip.dat" ]; then
		geoview -i /usr/share/v2ray/geoip.dat -c cn -4 2>/dev/null | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/ { printf "add -exist owall_direct %s\n", $1 }' | ipset restore -! 2>/dev/null || true
	fi

	iptables -t nat -N OWALL_DNS 2>/dev/null || iptables -t nat -F OWALL_DNS
	iptables -t nat -A OWALL_DNS -m mark --mark $XRAY_MARK -j RETURN
	iptables -t nat -A OWALL_DNS -p udp --dport 53 -j REDIRECT --to-ports $DNS_PORT
	iptables -t nat -A OWALL_DNS -p tcp --dport 53 -j REDIRECT --to-ports $DNS_PORT
	iptables -t nat -I PREROUTING -p udp --dport 53 -j OWALL_DNS
	iptables -t nat -I PREROUTING -p tcp --dport 53 -j OWALL_DNS

	iptables -t mangle -N OWALL 2>/dev/null || iptables -t mangle -F OWALL
	iptables -t mangle -A OWALL -m mark --mark $XRAY_MARK -j RETURN
	iptables -t mangle -A OWALL -m conntrack --ctdir REPLY -j RETURN
	iptables -t mangle -A OWALL -p udp --dport 53 -j RETURN
	iptables -t mangle -A OWALL -p tcp --dport 53 -j RETURN
	iptables -t mangle -A OWALL -m set --match-set owall_direct dst -j RETURN
	iptables -t mangle -A OWALL -p tcp -j TPROXY --tproxy-mark $FWMARK --on-port $TPROXY_PORT
	iptables -t mangle -A OWALL -p udp -j TPROXY --tproxy-mark $FWMARK --on-port $TPROXY_PORT
	iptables -t mangle -I PREROUTING -j OWALL

	echo "[iptables] Owall transparent proxy rules applied."
}

stop_iptables() {
	iptables -t nat -D PREROUTING -p udp --dport 53 -j OWALL_DNS 2>/dev/null || true
	iptables -t nat -D PREROUTING -p tcp --dport 53 -j OWALL_DNS 2>/dev/null || true
	iptables -t nat -F OWALL_DNS 2>/dev/null || true
	iptables -t nat -X OWALL_DNS 2>/dev/null || true

	iptables -t mangle -D PREROUTING -j OWALL 2>/dev/null || true
	iptables -t mangle -F OWALL 2>/dev/null || true
	iptables -t mangle -X OWALL 2>/dev/null || true

	ipset destroy owall_direct 2>/dev/null || true
	ip rule del fwmark $FWMARK table $ROUTETABLE 2>/dev/null || true
	ip route del local 0.0.0.0/0 dev lo table $ROUTETABLE 2>/dev/null || true
	echo "[iptables] Owall iptables rules cleaned up."
}

case "$1" in
	start) start_iptables ;;
	stop) stop_iptables ;;
	*) echo "Usage: $0 {start|stop}" ;;
esac

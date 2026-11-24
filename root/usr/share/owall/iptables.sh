#!/bin/sh

TPROXY_PORT=1081
DNS_PORT=5335
FWMARK=0x1
ROUTETABLE=100

start_iptables() {
	stop_iptables 2>/dev/null || true

	ip rule add fwmark $FWMARK table $ROUTETABLE 2>/dev/null || true
	ip route add local default dev lo table $ROUTETABLE 2>/dev/null || true

	ipset create owall_direct hash:net 2>/dev/null || ipset flush owall_direct 2>/dev/null || true
	for ip in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
		ipset add owall_direct $ip 2>/dev/null || true
	done

	local active_node=$(uci -q get owall.global.active_node)
	if [ -n "$active_node" ]; then
		local node_ip=$(uci -q get owall.${active_node}.address)
		local resolved=$(resolveip -4 "$node_ip" 2>/dev/null | head -n 1)
		[ -n "$resolved" ] && ipset add owall_direct $resolved 2>/dev/null || true
	fi

	if [ -f "/usr/share/v2ray/china.txt" ]; then
		while read -r line; do
			ipset add owall_direct "$line" 2>/dev/null || true
		done < /usr/share/v2ray/china.txt
	fi

	iptables -t nat -N OWALL_DNS 2>/dev/null || iptables -t nat -F OWALL_DNS
	iptables -t nat -A OWALL_DNS -p udp --dport 53 -j REDIRECT --to-ports $DNS_PORT
	iptables -t nat -A OWALL_DNS -p tcp --dport 53 -j REDIRECT --to-ports $DNS_PORT
	iptables -t nat -I PREROUTING -p udp --dport 53 -j OWALL_DNS
	iptables -t nat -I PREROUTING -p tcp --dport 53 -j OWALL_DNS

	iptables -t mangle -N OWALL 2>/dev/null || iptables -t mangle -F OWALL
	iptables -t mangle -A OWALL -m set --match-set owall_direct dst -j RETURN
	iptables -t mangle -A OWALL -p tcp -j TPROXY --tproxy-mark $FWMARK --on-port $TPROXY_PORT
	iptables -t mangle -A OWALL -p udp -j TPROXY --tproxy-mark $FWMARK --on-port $TPROXY_PORT
	iptables -t mangle -I PREROUTING -j OWALL

	echo "Owall iptables rules applied."
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
	ip route del local default dev lo table $ROUTETABLE 2>/dev/null || true
	echo "Owall iptables rules cleaned up."
}

case "$1" in
	start) start_iptables ;;
	stop) stop_iptables ;;
	*) echo "Usage: $0 {start|stop}" ;;
esac

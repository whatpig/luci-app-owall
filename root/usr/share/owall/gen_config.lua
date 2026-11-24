#!/usr/bin/lua

local uci = require("uci").cursor()
local jsonc = require("luci.jsonc")
local nixio = require("nixio")

local CONFIG = "owall"
local OUT_FILE = "/var/etc/owall.json"

local function get_system_dns()
	local dns = "223.5.5.5"
	local f = io.open("/tmp/resolv.conf.d/resolv.conf.auto", "r") or io.open("/tmp/resolv.conf.auto", "r")
	if f then
		for line in f:lines() do
			local ip = line:match("^nameserver%s+([%d%.]+)")
			if ip and ip ~= "127.0.0.1" and not ip:find("^192%.168%.") and not ip:find("^10%.") then
				dns = ip
				break
			end
		end
		f:close()
	end
	return dns
end

local function build_outbound(node)
	if not node then
		return { type = "direct", tag = "proxy" }
	end

	local t = node.type
	local out = {
		tag = "proxy",
		server = node.address,
		server_port = tonumber(node.port)
	}

	if t == "vless" then
		out.type = "vless"
		out.uuid = node.uuid
		out.flow = (node.flow and node.flow ~= "") and node.flow or nil
		if node.security == "reality" then
			out.tls = {
				enabled = true,
				server_name = node.sni ~= "" and node.sni or node.address,
				utls = { enabled = true, fingerprint = node.fp ~= "" and node.fp or "chrome" },
				reality = {
					enabled = true,
					public_key = node.pbk,
					short_id = node.sid
				}
			}
		elseif node.security == "tls" then
			out.tls = {
				enabled = true,
				server_name = node.sni ~= "" and node.sni or node.address,
				utls = { enabled = true, fingerprint = node.fp ~= "" and node.fp or "chrome" }
			}
		end
		if node.network == "ws" then
			out.transport = {
				type = "ws",
				path = node.path ~= "" and node.path or "/",
				headers = { Host = node.sni ~= "" and node.sni or node.address }
			}
		end

	elseif t == "hysteria2" then
		out.type = "hysteria2"
		out.password = node.password
		out.tls = {
			enabled = true,
			server_name = node.sni ~= "" and node.sni or node.address,
			insecure = node.insecure == "1"
		}

	elseif t == "trojan" then
		out.type = "trojan"
		out.password = node.password
		out.tls = {
			enabled = true,
			server_name = node.sni ~= "" and node.sni or node.address
		}

	elseif t == "shadowsocks" then
		out.type = "shadowsocks"
		out.method = node.method
		out.password = node.password

	elseif t == "vmess" then
		out.type = "vmess"
		out.uuid = node.uuid
		out.alter_id = tonumber(node.alterId or 0)
		out.security = "auto"
		if node.security == "tls" then
			out.tls = {
				enabled = true,
				server_name = node.sni ~= "" and node.sni or node.address
			}
		end
		if node.network == "ws" then
			out.transport = {
				type = "ws",
				path = node.path ~= "" and node.path or "/"
			}
		end
	else
		out.type = "direct"
	end

	return out
end

local function generate()
	local active_id = uci:get(CONFIG, "global", "active_node")
	local node = active_id and uci:get_all(CONFIG, active_id) or nil
	local tproxy_port = tonumber(uci:get(CONFIG, "global", "tproxy_port") or "1081")
	local socks_port = tonumber(uci:get(CONFIG, "global", "socks_port") or "1080")
	local dns_port = tonumber(uci:get(CONFIG, "global", "dns_port") or "5335")

	local local_dns = get_system_dns()
	local proxy_outbound = build_outbound(node)

	local config = {
		log = {
			level = "warn",
			timestamp = true
		},
		dns = {
			servers = {
				{
					tag = "direct-dns",
					address = local_dns,
					detour = "direct"
				},
				{
					tag = "remote-fakeip",
					address = "fakeip"
				}
			},
			rules = {
				{
					outbound = "any",
					server = "direct-dns"
				},
				{
					geosite = { "cn" },
					server = "direct-dns"
				}
			},
			final = "remote-fakeip",
			fakeip = {
				enabled = true,
				inet4_range = "198.18.0.0/16"
			},
			strategy = "prefer_ipv4"
		},
		inbounds = {
			{
				type = "direct",
				tag = "dns-in",
				listen = "127.0.0.1",
				listen_port = dns_port,
				override_address = "8.8.8.8",
				override_port = 53
			},
			{
				type = "mixed",
				tag = "mixed-in",
				listen = "0.0.0.0",
				listen_port = socks_port,
				sniff = true,
				sniff_override_destination = true
			},
			{
				type = "tproxy",
				tag = "tproxy-in",
				listen = "0.0.0.0",
				listen_port = tproxy_port,
				sniff = true,
				sniff_override_destination = true
			}
		},
		outbounds = {
			proxy_outbound,
			{
				type = "direct",
				tag = "direct"
			},
			{
				type = "dns",
				tag = "dns-out"
			},
			{
				type = "block",
				tag = "block"
			}
		},
		route = {
			rules = {
				{
					protocol = "dns",
					outbound = "dns-out"
				},
				{
					ip_is_private = true,
					outbound = "direct"
				},
				{
					geoip = { "cn", "private" },
					outbound = "direct"
				},
				{
					geosite = { "cn" },
					outbound = "direct"
				}
			},
			final = "proxy",
			auto_detect_interface = true
		}
	}

	-- Create output directory if needed
	nixio.fs.mkdirr("/var/etc")
	local f = io.open(OUT_FILE, "w")
	if f then
		f:write(jsonc.stringify(config, true))
		f:close()
		print("Successfully generated configuration at " .. OUT_FILE)
	else
		print("Failed to open " .. OUT_FILE .. " for writing.")
	end
end

generate()

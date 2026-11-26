#!/usr/bin/lua

local uci = require("luci.model.uci").cursor()
local jsonc = require("luci.jsonc")
local fs = require("nixio.fs")

local CONFIG = "owall"
local OUT_FILE = "/var/etc/owall.json"

local function is_ip(addr)
	if not addr then return false end
	if addr:match("^%d+%.%d+%.%d+%.%d+$") then return true end
	if addr:find(":") then return true end
	return false
end

local function has_geo_files()
	local dirs = { "/usr/share/v2ray", "/usr/share/xray" }
	for _, d in ipairs(dirs) do
		if fs.access(d .. "/geoip.dat") and fs.access(d .. "/geosite.dat") then
			return true, d
		end
	end
	return false, "/usr/share/v2ray"
end

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

local function build_stream_settings(node)
	local net = node.network or "tcp"
	if net == "raw" then net = "tcp" end
	if net == "splithttp" then net = "xhttp" end

	local sec = node.security or "none"
	local sni = (node.sni and node.sni ~= "") and node.sni or node.address
	local host = (node.host and node.host ~= "") and node.host or sni

	local stream = {
		network = net,
		security = sec,
		sockopt = {
			mark = 255
		}
	}

	if sec == "reality" then
		stream.realitySettings = {
			serverName = sni,
			fingerprint = (node.fp and node.fp ~= "") and node.fp or "chrome",
			publicKey = node.pbk or "",
			shortId = node.sid or "",
			spiderX = (node.spx and node.spx ~= "") and node.spx or "/"
		}
	elseif sec == "tls" then
		stream.tlsSettings = {
			serverName = sni,
			fingerprint = (node.fp and node.fp ~= "") and node.fp or "chrome",
			allowInsecure = (node.insecure == "1") and true or false
		}
		if node.alpn and node.alpn ~= "" then
			local alpn = {}
			for item in node.alpn:gmatch("[^,]+") do
				table.insert(alpn, item)
			end
			if #alpn > 0 then
				stream.tlsSettings.alpn = alpn
			end
		end
	end

	if net == "ws" then
		stream.wsSettings = {
			path = (node.path and node.path ~= "") and node.path or "/",
			headers = { Host = host }
		}
	elseif net == "httpupgrade" then
		stream.httpupgradeSettings = {
			path = (node.path and node.path ~= "") and node.path or "/",
			host = host
		}
	elseif net == "xhttp" then
		stream.xhttpSettings = {
			path = (node.path and node.path ~= "") and node.path or "/",
			host = host,
			mode = (node.mode and node.mode ~= "") and node.mode or "auto"
		}
	elseif net == "grpc" then
		stream.grpcSettings = {
			serviceName = node.serviceName or ""
		}
	end

	return stream
end

local function build_proxy_outbound(node)
	if not node or not node.address or node.address == "" or not node.port or not tonumber(node.port) then
		print("[gen_config] ERROR: No valid proxy node configured. Please import a subscription or node link.")
		os.exit(1)
	end

	local t = node.type
	local port = tonumber(node.port)

	if t == "vless" then
		local user = {
			id = node.uuid,
			encryption = (node.encryption and node.encryption ~= "") and node.encryption or "none"
		}
		if node.flow and node.flow ~= "" then
			user.flow = node.flow
		end
		return {
			tag = "proxy",
			protocol = "vless",
			settings = {
				vnext = {
					{
						address = node.address,
						port = port,
						users = { user }
					}
				}
			},
			streamSettings = build_stream_settings(node)
		}

	elseif t == "trojan" then
		return {
			tag = "proxy",
			protocol = "trojan",
			settings = {
				servers = {
					{
						address = node.address,
						port = port,
						password = node.password
					}
				}
			},
			streamSettings = build_stream_settings(node)
		}

	elseif t == "vmess" then
		return {
			tag = "proxy",
			protocol = "vmess",
			settings = {
				vnext = {
					{
						address = node.address,
						port = port,
						users = {
							{
								id = node.uuid,
								alterId = tonumber(node.alterId or 0),
								security = "auto"
							}
						}
					}
				}
			},
			streamSettings = build_stream_settings(node)
		}

	elseif t == "shadowsocks" then
		return {
			tag = "proxy",
			protocol = "shadowsocks",
			settings = {
				servers = {
					{
						address = node.address,
						port = port,
						method = node.method,
						password = node.password
					}
				}
			},
			streamSettings = {
				sockopt = { mark = 255 }
			}
		}

	elseif t == "hysteria2" then
		return {
			tag = "proxy",
			protocol = "hysteria",
			settings = {
				version = 2,
				address = node.address,
				port = port
			},
			streamSettings = {
				network = "hysteria",
				hysteriaSettings = {
					version = 2,
					auth = node.password or ""
				},
				security = "tls",
				tlsSettings = {
					serverName = (node.sni and node.sni ~= "") and node.sni or node.address,
					allowInsecure = (node.insecure == "1") and true or false
				},
				sockopt = { mark = 255 }
			}
		}
	end

	print("[gen_config] ERROR: Unsupported proxy node protocol: " .. tostring(t))
	os.exit(1)
end

local function find_first_node()
	local first_id = nil
	uci:foreach(CONFIG, "nodes", function(s)
		if not first_id then
			first_id = s[".name"]
		end
	end)
	return first_id
end

local function generate()
	local active_id = uci:get(CONFIG, "global", "active_node")
	if not active_id or active_id == "" or not uci:get(CONFIG, active_id) then
		active_id = find_first_node()
		if active_id then
			uci:set(CONFIG, "global", "active_node", active_id)
			uci:commit(CONFIG)
		end
	end

	local node = active_id and uci:get_all(CONFIG, active_id) or nil
	if not node or not node.address or node.address == "" or not node.port or not tonumber(node.port) then
		print("[gen_config] ERROR: No valid proxy node configured. Please import a subscription or node link.")
		os.exit(1)
	end
	local tproxy_port = tonumber(uci:get(CONFIG, "global", "tproxy_port")) or 1081
	local socks_port = tonumber(uci:get(CONFIG, "global", "socks_port")) or 1080
	local dns_port = tonumber(uci:get(CONFIG, "global", "dns_port")) or 5335

	local local_dns = get_system_dns()
	local proxy_outbound = build_proxy_outbound(node)
	local geo_ok = has_geo_files()

	-- Build DNS servers:
	-- servers[1] MUST be "fakedns" so all foreign / unmatched domains get Fake-IP (0ms, zero DNS leak).
	-- servers[2] is local direct DNS strictly scoped to VPS host + geosite:private + geosite:cn + custom direct domains with skipFallback=true.
	local dns_servers = { "fakedns" }
	local direct_domains = {}
	local custom_direct_domains = {}

	if node and node.address and not is_ip(node.address) then
		table.insert(direct_domains, "full:" .. node.address:lower())
	end
	if geo_ok then
		table.insert(direct_domains, "geosite:private")
		table.insert(direct_domains, "geosite:cn")
	end

	local custom_raw = uci:get(CONFIG, "global", "direct_domains") or ""
	for line in custom_raw:gmatch("[^\r\n]+") do
		local clean_line = line:gsub("^%s+", ""):gsub("%s+$", "")
		if clean_line ~= "" and not clean_line:find("^#") then
			for item in clean_line:gmatch("[^%s,]+") do
				local d = item:lower()
				if not (d:find("^full:") or d:find("^domain:") or d:find("^regexp:") or d:find("^geosite:") or d:find("^keyword:")) then
					d = "domain:" .. d
				end
				table.insert(direct_domains, d)
				table.insert(custom_direct_domains, d)
			end
		end
	end

	if #direct_domains > 0 then
		table.insert(dns_servers, {
			address = local_dns,
			port = 53,
			domains = direct_domains,
			skipFallback = true
		})
	end

	-- Build routing rules
	local routing_rules = {
		{
			type = "field",
			inboundTag = { "dns-in" },
			outboundTag = "dns-out"
		},
		{
			type = "field",
			inboundTag = { "dns-global" },
			outboundTag = "direct"
		}
	}
	if #custom_direct_domains > 0 then
		table.insert(routing_rules, {
			type = "field",
			domain = custom_direct_domains,
			outboundTag = "direct"
		})
	end
	if geo_ok then
		table.insert(routing_rules, {
			type = "field",
			ip = { "geoip:private", "geoip:cn" },
			outboundTag = "direct"
		})
		table.insert(routing_rules, {
			type = "field",
			domain = { "geosite:private", "geosite:cn" },
			outboundTag = "direct"
		})
	else
		print("[gen_config] WARNING: geoip.dat/geosite.dat not found; running without geo rules.")
	end

	local config = {
		log = {
			loglevel = "warning"
		},
		fakedns = {
			{
				ipPool = "198.18.0.0/16",
				poolSize = 65535
			}
		},
		dns = {
			tag = "dns-global",
			queryStrategy = "UseIPv4",
			disableFallback = true,
			disableFallbackIfMatch = true,
			servers = dns_servers
		},
		inbounds = {
			{
				tag = "dns-in",
				port = dns_port,
				protocol = "dokodemo-door",
				settings = {
					address = "8.8.8.8",
					port = 53,
					network = "tcp,udp"
				}
			},
			{
				tag = "socks-in",
				listen = "0.0.0.0",
				port = socks_port,
				protocol = "socks",
				settings = {
					auth = "noauth",
					udp = true
				},
				sniffing = {
					enabled = true,
					destOverride = { "http", "tls", "quic", "fakedns" }
				}
			},
			{
				tag = "tproxy-in",
				listen = "0.0.0.0",
				port = tproxy_port,
				protocol = "dokodemo-door",
				settings = {
					network = "tcp,udp",
					followRedirect = true
				},
				streamSettings = {
					sockopt = {
						tproxy = "tproxy"
					}
				},
				sniffing = {
					enabled = true,
					destOverride = { "http", "tls", "quic", "fakedns" }
				}
			}
		},
		outbounds = {
			proxy_outbound,
			{
				tag = "direct",
				protocol = "freedom",
				settings = {
					domainStrategy = "UseIPv4"
				},
				streamSettings = {
					sockopt = {
						mark = 255
					}
				}
			},
			{
				tag = "dns-out",
				protocol = "dns"
			},
			{
				tag = "block",
				protocol = "blackhole"
			}
		},
		routing = {
			domainStrategy = "IPIfNonMatch",
			rules = routing_rules
		}
	}

	fs.mkdirr("/var/etc")
	local f = io.open(OUT_FILE, "w")
	if f then
		f:write(jsonc.stringify(config, true))
		f:close()
		print("[gen_config] Successfully generated Xray-core configuration at " .. OUT_FILE)
	else
		print("[gen_config] ERROR: Failed to open " .. OUT_FILE .. " for writing.")
		os.exit(1)
	end
end

generate()

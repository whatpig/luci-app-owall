#!/usr/bin/lua

local uci = require("uci").cursor()
local jsonc = require("luci.jsonc")
local nixio = require("nixio")

local CONFIG = "owall"
local OUT_FILE = "/var/etc/owall.json"

local function is_ip(addr)
	if not addr then return false end
	if addr:match("^%d+%.%d+%.%d+%.%d+$") then return true end
	if addr:find(":") then return true end
	return false
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
			host = host
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
	if not node or not node.address or not node.port then
		return {
			tag = "proxy",
			protocol = "freedom",
			streamSettings = { sockopt = { mark = 255 } }
		}
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

	return {
		tag = "proxy",
		protocol = "freedom",
		streamSettings = { sockopt = { mark = 255 } }
	}
end

local function generate()
	local active_id = uci:get(CONFIG, "global", "active_node")
	local node = active_id and uci:get_all(CONFIG, active_id) or nil
	local tproxy_port = tonumber(uci:get(CONFIG, "global", "tproxy_port") or "1081")
	local socks_port = tonumber(uci:get(CONFIG, "global", "socks_port") or "1080")
	local dns_port = tonumber(uci:get(CONFIG, "global", "dns_port") or "5335")

	local local_dns = get_system_dns()
	local proxy_outbound = build_proxy_outbound(node)

	-- Direct DNS domains: domestic sites + private + VPS hostname (to prevent DNS loop)
	local direct_domains = { "geosite:private", "geosite:cn" }
	if node and node.address and not is_ip(node.address) then
		table.insert(direct_domains, 1, "full:" .. node.address:lower())
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
			servers = {
				{
					address = local_dns,
					port = 53,
					domains = direct_domains
				},
				"fakedns"
			}
		},
		inbounds = {
			{
				tag = "dns-in",
				listen = "127.0.0.1",
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
			rules = {
				{
					type = "field",
					inboundTag = { "dns-in" },
					outboundTag = "dns-out"
				},
				{
					type = "field",
					inboundTag = { "dns-global" },
					outboundTag = "direct"
				},
				{
					type = "field",
					ip = { "geoip:private", "geoip:cn" },
					outboundTag = "direct"
				},
				{
					type = "field",
					domain = { "geosite:private", "geosite:cn" },
					outboundTag = "direct"
				}
			}
		}
	}

	nixio.fs.mkdirr("/var/etc")
	local f = io.open(OUT_FILE, "w")
	if f then
		f:write(jsonc.stringify(config, true))
		f:close()
		print("Successfully generated Xray-core configuration at " .. OUT_FILE)
	else
		print("Failed to open " .. OUT_FILE .. " for writing.")
	end
end

generate()

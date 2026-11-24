#!/usr/bin/lua

local uci = require("uci").cursor()
local nixio = require("nixio")
local jsonc = require("luci.jsonc")

local CONFIG = "owall"

local function b64decode(data)
	if not data or data == "" then return "" end
	data = data:gsub("%s+", ""):gsub("-", "+"):gsub("_", "/")
	local pad = #data % 4
	if pad == 2 then data = data .. "==" elseif pad == 3 then data = data .. "=" end
	return nixio.bin.b64decode(data) or ""
end

local function urldecode(s)
	if not s then return "" end
	s = s:gsub("+", " ")
	s = s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
	return s
end

local function parse_query(qs)
	local t = {}
	if not qs or qs == "" then return t end
	for k, v in qs:gmatch("([^&=?]+)=([^&=?]*)") do
		t[k] = urldecode(v)
	end
	return t
end

local function parse_vless(link)
	local user, host, port, qs, remarks = link:match("^vless://([^@]+)@([^:?]+):(%d+)/?%??([^#]*)#?(.*)$")
	if not host then return nil end
	local q = parse_query(qs)
	return {
		type = "vless",
		remarks = urldecode(remarks ~= "" and remarks or (host .. ":" .. port)),
		address = host,
		port = port,
		uuid = user,
		flow = q.flow or "",
		encryption = q.encryption or "none",
		security = q.security or "none",
		sni = q.sni or q.host or host,
		host = q.host or q.sni or host,
		alpn = q.alpn or "",
		fp = q.fp or "chrome",
		pbk = q.pbk or "",
		sid = q.sid or "",
		spx = q.spx or "/",
		network = q.type or "tcp",
		path = q.path or "/",
		mode = q.mode or "auto",
		serviceName = q.serviceName or ""
	}
end

local function parse_trojan(link)
	local user, host, port, qs, remarks = link:match("^trojan://([^@]+)@([^:?]+):(%d+)/?%??([^#]*)#?(.*)$")
	if not host then return nil end
	local q = parse_query(qs)
	return {
		type = "trojan",
		remarks = urldecode(remarks ~= "" and remarks or (host .. ":" .. port)),
		address = host,
		port = port,
		password = user,
		security = q.security or "tls",
		sni = q.sni or q.peer or q.host or host,
		host = q.host or q.sni or host,
		alpn = q.alpn or "",
		fp = q.fp or "chrome",
		pbk = q.pbk or "",
		sid = q.sid or "",
		network = q.type or "tcp",
		path = q.path or "/",
		serviceName = q.serviceName or ""
	}
end

local function parse_ss(link)
	local body, remarks = link:match("^ss://([^#]+)#?(.*)$")
	if not body then return nil end
	remarks = urldecode(remarks)
	local userinfo, host, port
	if body:find("@") then
		userinfo, host, port = body:match("([^@]+)@([^:?]+):(%d+)")
		if userinfo and not userinfo:find(":") then
			userinfo = b64decode(userinfo)
		else
			userinfo = urldecode(userinfo)
		end
	else
		local dec = b64decode(body)
		userinfo, host, port = dec:match("([^@]+)@([^:?]+):(%d+)")
	end
	if not host or not userinfo then return nil end
	local method, password = userinfo:match("([^:]+):(.*)")
	if not method then return nil end
	return {
		type = "shadowsocks",
		remarks = remarks ~= "" and remarks or (host .. ":" .. port),
		address = host,
		port = port,
		method = method,
		password = password
	}
end

local function parse_vmess(link)
	local body = link:match("^vmess://(.*)$")
	if not body then return nil end
	local decoded = b64decode(body)
	local info = jsonc.parse(decoded)
	if not info or not info.add or not info.port then return nil end
	return {
		type = "vmess",
		remarks = info.ps or (info.add .. ":" .. info.port),
		address = info.add,
		port = tostring(info.port),
		uuid = info.id,
		alterId = tostring(info.aid or 0),
		security = (info.tls == "tls") and "tls" or "none",
		network = info.net or "tcp",
		sni = info.sni or info.host or info.add,
		host = info.host or info.sni or info.add,
		path = info.path or "/",
		fp = info.fp or "chrome"
	}
end

local function parse_hysteria2(link)
	local user, host, port, qs, remarks = link:match("^hysteria2://([^@]+)@([^:?]+):(%d+)/?%??([^#]*)#?(.*)$")
	if not host then
		user, host, port, qs, remarks = link:match("^hy2://([^@]+)@([^:?]+):(%d+)/?%??([^#]*)#?(.*)$")
	end
	if not host then return nil end
	local q = parse_query(qs)
	return {
		type = "hysteria2",
		remarks = urldecode(remarks ~= "" and remarks or (host .. ":" .. port)),
		address = host,
		port = port,
		password = user,
		sni = q.sni or host,
		insecure = q.insecure == "1" and "1" or "0"
	}
end

local function parse_line(line)
	line = line:gsub("%s+$", ""):gsub("^%s+", "")
	if line:find("^vless://") then return parse_vless(line) end
	if line:find("^trojan://") then return parse_trojan(line) end
	if line:find("^ss://") then return parse_ss(line) end
	if line:find("^vmess://") then return parse_vmess(line) end
	if line:find("^hysteria2://") or line:find("^hy2://") then return parse_hysteria2(line) end
	return nil
end

local function run()
	local input = uci:get(CONFIG, "global", "node_input") or ""
	if input == "" then
		print("No node or subscription input found.")
		return
	end

	local content = ""
	if input:find("^https?://") then
		print("Fetching subscription: " .. input)
		local f = io.popen("curl -sL -k --connect-timeout 10 -m 30 -A 'Owall/1.1' '" .. input .. "'")
		if f then
			content = f:read("*all") or ""
			f:close()
		end
		local decoded = b64decode(content)
		if decoded and decoded:find("://") then
			content = decoded
		end
	else
		content = input
	end

	uci:delete_all(CONFIG, "nodes", function() return true end)

	local count = 0
	local first_node_id = nil

	for line in content:gmatch("[^\r\n]+") do
		local node = parse_line(line)
		if node and node.address and node.port then
			count = count + 1
			local node_id = "node_" .. count
			uci:section(CONFIG, "nodes", node_id, node)
			if not first_node_id then
				first_node_id = node_id
			end
		end
	end

	if count > 0 then
		print(string.format("Successfully parsed and imported %d nodes.", count))
		local active = uci:get(CONFIG, "global", "active_node")
		if not active or active == "" or not uci:get(CONFIG, active) then
			uci:set(CONFIG, "global", "active_node", first_node_id)
		end
		uci:commit(CONFIG)
	else
		print("No valid nodes could be parsed from input.")
	end
end

run()

#!/usr/bin/lua

local uci = require("uci").cursor()
local sys = require("luci.sys")
local nixio = require("nixio")
local jsonc = require("luci.jsonc")

local CONFIG = "owall"

-- Base64 decode helper
local function b64decode(data)
	if not data or data == "" then return "" end
	data = data:gsub("%s+", ""):gsub("-", "+"):gsub("_", "/")
	local pad = #data % 4
	if pad == 2 then data = data .. "==" elseif pad == 3 then data = data .. "=" end
	return nixio.bin.b64decode(data) or ""
end

-- URL decode helper
local function urldecode(s)
	if not s then return "" end
	s = s:gsub("+", " ")
	s = s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
	return s
end

-- Parse query string
local function parse_query(qs)
	local t = {}
	if not qs or qs == "" then return t end
	for k, v in qs:gmatch("([^&=?]+)=([^&=?]+)") do
		t[k] = urldecode(v)
	end
	return t
end

-- Node Parsers
local function parse_vless(link)
	-- vless://uuid@host:port?params#remarks
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
		alpn = q.alpn or "",
		fp = q.fp or "chrome",
		pbk = q.pbk or "",
		sid = q.sid or "",
		spx = q.spx or "",
		network = q.type or "tcp",
		path = q.path or ""
	}
end

local function parse_hysteria2(link)
	-- hysteria2://password@host:port?params#remarks
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
		insecure = q.insecure == "1" and "1" or "0",
		alpn = q.alpn or "",
		ports = q.mport or port
	}
end

local function parse_trojan(link)
	-- trojan://password@host:port?params#remarks
	local user, host, port, qs, remarks = link:match("^trojan://([^@]+)@([^:?]+):(%d+)/?%??([^#]*)#?(.*)$")
	if not host then return nil end
	local q = parse_query(qs)
	return {
		type = "trojan",
		remarks = urldecode(remarks ~= "" and remarks or (host .. ":" .. port)),
		address = host,
		port = port,
		password = user,
		sni = q.sni or q.peer or host,
		alpn = q.alpn or "",
		security = "tls"
	}
end

local function parse_ss(link)
	-- ss://base64(method:password)@host:port#remarks or ss://base64#remarks
	local body, remarks = link:match("^ss://([^#]+)#?(.*)$")
	if not body then return nil end
	remarks = urldecode(remarks)
	local userinfo, host, port
	if body:find("@") then
		userinfo, host, port = body:match("([^@]+)@([^:]+):(%d+)")
		userinfo = b64decode(userinfo)
	else
		local dec = b64decode(body)
		userinfo, host, port = dec:match("([^@]+)@([^:]+):(%d+)")
	end
	if not host then return nil end
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
	-- vmess://base64(json)
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
		security = info.tls or "none",
		network = info.net or "tcp",
		sni = info.sni or info.host or info.add,
		path = info.path or ""
	}
end

local function parse_line(line)
	line = line:gsub("%s+$", ""):gsub("^%s+", "")
	if line:find("^vless://") then return parse_vless(line) end
	if line:find("^hysteria2://") or line:find("^hy2://") then return parse_hysteria2(line) end
	if line:find("^trojan://") then return parse_trojan(line) end
	if line:find("^ss://") then return parse_ss(line) end
	if line:find("^vmess://") then return parse_vmess(line) end
	return nil
end

-- Main update routine
local function run()
	local input = uci:get(CONFIG, "global", "node_input") or ""
	if input == "" then
		print("No node or subscription input found.")
		return
	end

	local content = ""
	-- Check if input is a subscription HTTP/HTTPS URL
	if input:find("^https?://") then
		print("Fetching subscription: " .. input)
		local f = io.popen("curl -sL -k --connect-timeout 10 -m 30 -A 'Owall/1.0' '" .. input .. "'")
		if f then
			content = f:read("*all") or ""
			f:close()
		end
		-- Try base64 decoding subscription content
		local decoded = b64decode(content)
		if decoded and (decoded:find("://") or decoded:find("vmess://")) then
			content = decoded
		end
	else
		content = input
	end

	-- Delete existing nodes in UCI
	uci:delete_all(CONFIG, "nodes", function(s) return true end)

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

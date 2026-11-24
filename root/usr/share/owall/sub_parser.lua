#!/usr/bin/lua

local uci = require("luci.model.uci").cursor()
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

local function split_host_port(hp)
	if not hp then return nil, nil end
	local h, p = hp:match("^%[([^%]]+)%]:(%d+)$")
	if h and p then return h, p end
	return hp:match("^([^:/?]+):(%d+)$")
end

local function parse_vless(link)
	local user, hp, rest = link:match("^vless://([^@]+)@([^/?#]+)(.*)$")
	local host, port = split_host_port(hp)
	if not host then return nil end
	local qs = rest:match("%?([^#]*)") or ""
	local remarks = rest:match("#(.*)$") or ""
	local q = parse_query(qs)
	return {
		type = "vless",
		remarks = urldecode(remarks ~= "" and remarks or (host .. ":" .. port)),
		address = host,
		port = port,
		uuid = urldecode(user),
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
	local user, hp, rest = link:match("^trojan://([^@]+)@([^/?#]+)(.*)$")
	local host, port = split_host_port(hp)
	if not host then return nil end
	local qs = rest:match("%?([^#]*)") or ""
	local remarks = rest:match("#(.*)$") or ""
	local q = parse_query(qs)
	return {
		type = "trojan",
		remarks = urldecode(remarks ~= "" and remarks or (host .. ":" .. port)),
		address = host,
		port = port,
		password = urldecode(user),
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
	body = body:match("^([^?]+)") or body
	local userinfo, hp
	if body:find("@") then
		userinfo, hp = body:match("([^@]+)@(.+)")
		if userinfo and not userinfo:find(":") then
			userinfo = b64decode(userinfo)
		else
			userinfo = urldecode(userinfo)
		end
	else
		local dec = b64decode(body)
		userinfo, hp = dec:match("([^@]+)@(.+)")
	end
	local host, port = split_host_port(hp)
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
	local user, hp, rest = link:match("^hysteria2://([^@]+)@([^/?#]+)(.*)$")
	if not hp then
		user, hp, rest = link:match("^hy2://([^@]+)@([^/?#]+)(.*)$")
	end
	local host, port = split_host_port(hp)
	if not host then return nil end
	local qs = rest:match("%?([^#]*)") or ""
	local remarks = rest:match("#(.*)$") or ""
	local q = parse_query(qs)
	return {
		type = "hysteria2",
		remarks = urldecode(remarks ~= "" and remarks or (host .. ":" .. port)),
		address = host,
		port = port,
		password = urldecode(user),
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
	input = input:gsub("^%s+", ""):gsub("%s+$", "")
	if input == "" then
		print("[sub_parser] No node or subscription input found.")
		return
	end

	local lines_to_parse = {}
	for raw_line in input:gmatch("[^\r\n]+") do
		raw_line = raw_line:gsub("^%s+", ""):gsub("%s+$", "")
		if raw_line:find("^https?://") then
			print("[sub_parser] Fetching subscription: " .. raw_line)
			local safe_url = raw_line:gsub("'", "'\\''")
			local f = io.popen("curl -sL -k --connect-timeout 10 -m 30 -A 'Owall/1.1' '" .. safe_url .. "'")
			local sub_body = ""
			if f then
				sub_body = f:read("*all") or ""
				f:close()
			end
			local decoded = b64decode(sub_body)
			if decoded and decoded:find("://") then
				sub_body = decoded
			end
			for sub_line in sub_body:gmatch("[^\r\n]+") do
				table.insert(lines_to_parse, sub_line)
			end
		elseif raw_line ~= "" then
			table.insert(lines_to_parse, raw_line)
		end
	end

	uci:delete_all(CONFIG, "nodes")

	local count = 0
	local first_node_id = nil

	for _, line in ipairs(lines_to_parse) do
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
		print(string.format("[sub_parser] Successfully parsed and imported %d nodes.", count))
		local active = uci:get(CONFIG, "global", "active_node")
		if not active or active == "" or not uci:get(CONFIG, active) then
			uci:set(CONFIG, "global", "active_node", first_node_id)
		end
		uci:commit(CONFIG)
	else
		print("[sub_parser] ERROR: No valid nodes could be parsed from input.")
	end
end

run()

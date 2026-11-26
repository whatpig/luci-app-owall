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
	s = s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
	return s
end

local function trim(s)
	return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function strip_quotes(s)
	s = trim(s)
	if #s >= 2 then
		local q1, q2 = s:sub(1, 1), s:sub(-1, -1)
		if (q1 == '"' and q2 == '"') or (q1 == "'" and q2 == "'") then
			return s:sub(2, -2)
		end
	end
	return s
end

local function nonempty(...)
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		if v ~= nil and v ~= "" then
			return v
		end
	end
	return ""
end

local function parse_query(qs)
	local t = {}
	if not qs or qs == "" then return t end
	for pair in qs:gmatch("[^&]+") do
		local k, v = pair:match("^([^=]+)=(.*)$")
		if k then
			t[k] = urldecode(v)
		end
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
		remarks = urldecode(nonempty(remarks, host .. ":" .. port)),
		address = host,
		port = port,
		uuid = urldecode(user),
		flow = nonempty(q.flow),
		encryption = nonempty(q.encryption, "none"),
		security = nonempty(q.security, "none"),
		sni = nonempty(q.sni, q.host, host),
		host = nonempty(q.host, q.sni, host),
		alpn = nonempty(q.alpn),
		fp = nonempty(q.fp, "chrome"),
		pbk = nonempty(q.pbk),
		sid = nonempty(q.sid),
		spx = nonempty(q.spx, "/"),
		network = nonempty(q.type, "tcp"),
		path = nonempty(q.path, "/"),
		mode = nonempty(q.mode, "auto"),
		serviceName = nonempty(q.serviceName),
		insecure = (q.allowInsecure == "1" or q.insecure == "1" or q.allowInsecure == "true" or q.insecure == "true") and "1" or "0"
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
		remarks = urldecode(nonempty(remarks, host .. ":" .. port)),
		address = host,
		port = port,
		password = urldecode(user),
		security = nonempty(q.security, "tls"),
		sni = nonempty(q.sni, q.peer, q.host, host),
		host = nonempty(q.host, q.sni, host),
		alpn = nonempty(q.alpn),
		fp = nonempty(q.fp, "chrome"),
		pbk = nonempty(q.pbk),
		sid = nonempty(q.sid),
		network = nonempty(q.type, "tcp"),
		path = nonempty(q.path, "/"),
		serviceName = nonempty(q.serviceName),
		insecure = (q.allowInsecure == "1" or q.insecure == "1" or q.allowInsecure == "true" or q.insecure == "true") and "1" or "0"
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
		remarks = nonempty(remarks, host .. ":" .. port),
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
	local net = nonempty(info.net, "tcp")
	local insecure = (info.allowInsecure == true or info.allowInsecure == 1 or info.allowInsecure == "1" or info.insecure == true or info.insecure == 1 or info.insecure == "1") and "1" or "0"
	return {
		type = "vmess",
		remarks = nonempty(info.ps, info.add .. ":" .. info.port),
		address = info.add,
		port = tostring(info.port),
		uuid = info.id,
		alterId = tostring(info.aid or 0),
		security = (info.tls == "tls") and "tls" or "none",
		network = net,
		sni = nonempty(info.sni, info.host, info.add),
		host = nonempty(info.host, info.sni, info.add),
		path = nonempty(info.path, "/"),
		serviceName = (net == "grpc") and nonempty(info.path) or "",
		fp = nonempty(info.fp, "chrome"),
		insecure = insecure
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
		remarks = urldecode(nonempty(remarks, host .. ":" .. port)),
		address = host,
		port = port,
		password = urldecode(user),
		sni = nonempty(q.sni, host),
		insecure = (q.insecure == "1" or q.insecure == "true") and "1" or "0"
	}
end

-- Brace/quote-aware splitter for inline flow-style Clash YAML maps: {k: v, nested: {k2: v2}}
local function split_top_commas(s)
	local parts = {}
	local depth, quote, cur = 0, nil, {}
	for i = 1, #s do
		local c = s:sub(i, i)
		if quote then
			cur[#cur + 1] = c
			if c == quote and s:sub(i - 1, i - 1) ~= "\\" then
				quote = nil
			end
		else
			if c == '"' or c == "'" then
				quote = c
				cur[#cur + 1] = c
			elseif c == "{" or c == "[" then
				depth = depth + 1
				cur[#cur + 1] = c
			elseif c == "}" or c == "]" then
				depth = math.max(0, depth - 1)
				cur[#cur + 1] = c
			elseif c == "," and depth == 0 then
				parts[#parts + 1] = table.concat(cur)
				cur = {}
			else
				cur[#cur + 1] = c
			end
		end
	end
	if #cur > 0 then
		parts[#parts + 1] = table.concat(cur)
	end
	return parts
end

local function extract_kv_recursive(body, out)
	for _, item in ipairs(split_top_commas(body)) do
		local k, v = item:match("^%s*([%w_%-]+)%s*:%s*(.-)%s*$")
		if k and v then
			local kl = k:lower()
			if v:sub(1, 1) == "{" and v:sub(-1, -1) == "}" then
				extract_kv_recursive(v:sub(2, -2), out)
			else
				if out[kl] == nil then
					out[kl] = strip_quotes(v)
				end
			end
		end
	end
end

local function build_clash_node(m)
	local t = (m.type or ""):lower()
	local host = m.server
	local port = m.port and tostring(m.port):match("^(%d+)$")
	if not host or host == "" or not port then return nil end

	local remarks = nonempty(m.name, host .. ":" .. port)
	local sni = nonempty(m.sni, m.servername, host)
	local insecure = (m["skip-cert-verify"] == "true") and "1" or "0"
	local fp = nonempty(m["client-fingerprint"], "chrome")
	local net = nonempty(m.network, "tcp")

	if t == "vless" and m.uuid then
		local sec = "none"
		if m["public-key"] and m["public-key"] ~= "" then
			sec = "reality"
		elseif m.tls == "true" then
			sec = "tls"
		end
		return {
			type = "vless",
			remarks = remarks,
			address = host,
			port = port,
			uuid = m.uuid,
			flow = nonempty(m.flow),
			encryption = "none",
			security = sec,
			sni = sni,
			host = nonempty(m.host, sni),
			fp = fp,
			pbk = nonempty(m["public-key"]),
			sid = nonempty(m["short-id"]),
			spx = "/",
			network = net,
			path = nonempty(m.path, "/"),
			serviceName = nonempty(m["grpc-service-name"], m.servicename),
			insecure = insecure
		}
	elseif t == "trojan" and m.password then
		return {
			type = "trojan",
			remarks = remarks,
			address = host,
			port = port,
			password = m.password,
			security = (m["public-key"] and m["public-key"] ~= "") and "reality" or "tls",
			sni = sni,
			host = nonempty(m.host, sni),
			fp = fp,
			pbk = nonempty(m["public-key"]),
			sid = nonempty(m["short-id"]),
			network = net,
			path = nonempty(m.path, "/"),
			serviceName = nonempty(m["grpc-service-name"], m.servicename),
			insecure = insecure
		}
	elseif t == "ss" and m.cipher and m.password then
		return {
			type = "shadowsocks",
			remarks = remarks,
			address = host,
			port = port,
			method = m.cipher,
			password = m.password
		}
	elseif t == "vmess" and m.uuid then
		return {
			type = "vmess",
			remarks = remarks,
			address = host,
			port = port,
			uuid = m.uuid,
			alterId = tostring(m.alterid or 0),
			security = (m.tls == "true") and "tls" or "none",
			network = net,
			sni = sni,
			host = nonempty(m.host, sni),
			path = nonempty(m.path, "/"),
			serviceName = (net == "grpc") and nonempty(m["grpc-service-name"], m.servicename, m.path) or "",
			fp = fp,
			insecure = insecure
		}
	elseif (t == "hysteria2" or t == "hy2") and m.password then
		return {
			type = "hysteria2",
			remarks = remarks,
			address = host,
			port = port,
			password = m.password,
			sni = sni,
			insecure = insecure
		}
	end
	return nil
end

local function parse_clash_inline(line)
	local body = line:match("^%-?%s*{(.*)}%s*$")
	if not body then return nil end

	local m = {}
	extract_kv_recursive(body, m)
	return build_clash_node(m)
end

local function strip_yaml_comment(v)
	local stripped = v:match("^([^\"'#]+)%s+#.*$")
	return stripped and trim(stripped) or v
end

-- Parse indented multi-line Clash YAML proxies blocks without overlapping inline {- ...} items
local function parse_clash_block_nodes(lines)
	local nodes = {}
	local in_proxies = false
	local cur = nil

	local function flush_cur()
		if cur then
			local n = build_clash_node(cur)
			if n then nodes[#nodes + 1] = n end
			cur = nil
		end
	end

	for _, raw in ipairs(lines) do
		local clean = raw:gsub("\r", "")
		local trimmed = trim(clean)
		if trimmed == "" or trimmed:find("^#") then
			-- skip blanks/comments
		elseif clean:match("^proxies:%s*$") then
			flush_cur()
			in_proxies = true
		elseif clean:match("^[%w_%-]+:") then
			-- Any other top-level unindented YAML section ends proxies block
			flush_cur()
			in_proxies = false
		elseif clean:match("^%s*%-%s*{.*}$") then
			-- Inline flow-style item is handled by parse_line()
			flush_cur()
		else
			local item_rest = clean:match("^%s*%-%s+(.+)$")
			if item_rest then
				if in_proxies or item_rest:match("^[%w_%-]+%s*:") then
					in_proxies = true
					flush_cur()
					cur = {}
					local k, v = item_rest:match("^([%w_%-]+)%s*:%s*(.-)%s*$")
					if k and v ~= "" then
						cur[k:lower()] = strip_quotes(strip_yaml_comment(v))
					end
				end
			elseif cur and clean:match("^%s+") then
				local k, v = trimmed:match("^([%w_%-]+)%s*:%s*(.-)%s*$")
				if k and v ~= "" then
					local kl = k:lower()
					if cur[kl] == nil then
						cur[kl] = strip_quotes(strip_yaml_comment(v))
					end
				end
			end
		end
	end
	flush_cur()
	return nodes
end

local function parse_line(line)
	line = trim(line)
	if line == "" or line:find("^#") or line == "proxies:" then return nil end
	if line:find("^vless://") then return parse_vless(line) end
	if line:find("^trojan://") then return parse_trojan(line) end
	if line:find("^ss://") then return parse_ss(line) end
	if line:find("^vmess://") then return parse_vmess(line) end
	if line:find("^hysteria2://") or line:find("^hy2://") then return parse_hysteria2(line) end
	if line:find("^%-?%s*{.*}$") then return parse_clash_inline(line) end
	return nil
end

local function looks_like_sub(body)
	if not body or body == "" then return false end
	if body:find("://") or body:find("proxies:") then return true end
	local decoded = b64decode(body)
	if decoded and (decoded:find("://") or decoded:find("proxies:")) then
		return true
	end
	return false
end

local function fetch_url(url)
	local safe_url = url:gsub("'", "'\\''")
	local cmd_direct = "curl -sL -k --connect-timeout 8 -m 20 -A 'Owall/1.2' '" .. safe_url .. "'"
	local f = io.popen(cmd_direct)
	local body = ""
	if f then
		body = f:read("*all") or ""
		f:close()
	end
	if looks_like_sub(body) then
		return body
	end

	-- Fallback: retry via local Xray SOCKS port in case subscription domain is blocked
	local socks_port = uci:get(CONFIG, "global", "socks_port") or "1080"
	if socks_port == "" then socks_port = "1080" end
	print("[sub_parser] Direct subscription fetch failed; retrying via 127.0.0.1:" .. socks_port)
	local cmd_proxy = "curl -sL -k --connect-timeout 8 -m 20 --socks5-hostname 127.0.0.1:" .. socks_port .. " -A 'Owall/1.2' '" .. safe_url .. "'"
	local fp = io.popen(cmd_proxy)
	if fp then
		local pbody = fp:read("*all") or ""
		fp:close()
		if looks_like_sub(pbody) then
			return pbody
		end
	end
	return body
end

local function run()
	local input = trim(uci:get(CONFIG, "global", "node_input") or "")
	if input == "" then
		print("[sub_parser] No node or subscription input found.")
		return
	end

	local lines_to_parse = {}
	for raw_line in input:gmatch("[^\r\n]+") do
		local tline = trim(raw_line)
		if tline:find("^https?://") then
			print("[sub_parser] Fetching subscription: " .. tline)
			local sub_body = fetch_url(tline)
			if not sub_body:find("://") and not sub_body:find("proxies:") then
				local decoded = b64decode(sub_body)
				if decoded and (decoded:find("://") or decoded:find("proxies:")) then
					sub_body = decoded
				end
			end
			for sub_line in sub_body:gmatch("[^\r\n]+") do
				table.insert(lines_to_parse, sub_line)
			end
		elseif tline ~= "" then
			table.insert(lines_to_parse, raw_line)
		end
	end

	uci:delete_all(CONFIG, "nodes")

	local count = 0
	local first_node_id = nil

	local function save_node(node)
		if node and node.address and node.port then
			count = count + 1
			local node_id = "node_" .. count
			uci:section(CONFIG, "nodes", node_id, node)
			if not first_node_id then
				first_node_id = node_id
			end
		end
	end

	for _, line in ipairs(lines_to_parse) do
		save_node(parse_line(line))
	end

	for _, node in ipairs(parse_clash_block_nodes(lines_to_parse)) do
		save_node(node)
	end

	if count > 0 then
		print(string.format("[sub_parser] Successfully parsed and imported %d nodes.", count))
		local active = uci:get(CONFIG, "global", "active_node")
		if not active or active == "" or not uci:get(CONFIG, active) then
			if count == 1 then
				uci:set(CONFIG, "global", "active_node", first_node_id)
			else
				uci:delete(CONFIG, "global", "active_node")
			end
		end
		uci:commit(CONFIG)
	else
		print("[sub_parser] ERROR: No valid nodes could be parsed from input.")
		os.exit(1)
	end
end

run()

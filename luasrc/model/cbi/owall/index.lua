local uci_mod = require("luci.model.uci")
local uci = uci_mod.cursor()
local sys = require("luci.sys")

local m = Map("owall", translate("Owall"), translate("Ultra-Lightweight, Zero-Config Transparent Proxy for OpenWrt."))

-- Status Overview Card Template
local s_status = m:section(NamedSection, "global", "global")
s_status.anonymous = true
s_status.template = "owall/status"

-- Main Settings Section
local s = m:section(NamedSection, "global", "global", translate("Core Control"))
s.anonymous = true
s.addremove = false

-- 1. Master Toggle Switch
local o_enabled = s:option(Flag, "enabled", translate("Master Switch"), translate("Toggle to start/stop transparent proxy and DNS routing."))
o_enabled.default = "0"
o_enabled.rmempty = false

-- 2. Single Input for Subscription or Node Share Links
local o_input = s:option(TextValue, "node_input", translate("Import Subscription / Nodes"),
	translate("Paste your Subscription URL (http/https) or node share links (vless://, hysteria2://, trojan://, ss://, vmess://) here.<br/>Multiple lines supported. Automatically parsed on Save & Apply."))
o_input.rows = 4
o_input.wrap = "off"
o_input.rmempty = true

-- 3. Active Outbound Node Selector
local o_node = s:option(ListValue, "active_node", translate("Active Outbound Node"), translate("Select active node or keep Auto-Select (lowest latency)."))
o_node:value("", translate("Auto-Select (Lowest Latency)"))

uci:foreach("owall", "nodes", function(n)
	local label = string.format("%s (%s:%s)", n.remarks or n[".name"], n.address or "", n.port or "")
	o_node:value(n[".name"], label)
end)

-- Commit hook: use a FRESH UCI cursor; app.sh prepare handles smart MD5-cached parsing
function m.on_after_commit(self)
	local cur = uci_mod.cursor()
	local enabled = cur:get("owall", "global", "enabled")
	sys.call("rm -f /tmp/owall_status.json")

	if enabled == "1" then
		sys.call("/usr/share/owall/app.sh reload >> /var/log/owall.log 2>&1")
	else
		sys.call("/etc/init.d/owall stop >/dev/null 2>&1")
	end
end

return m

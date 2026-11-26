module("luci.controller.owall", package.seeall)

local fs = require("nixio.fs")

function index()
	if not fs.access("/etc/config/owall") then
		return
	end

	entry({"admin", "services", "owall"}, cbi("owall/index"), _("Owall"), 20).dependent = true
	entry({"admin", "services", "owall", "status"}, call("action_status")).leaf = true
	entry({"admin", "services", "owall", "sync"}, call("action_sync")).leaf = true
	entry({"admin", "services", "owall", "auto_best"}, call("action_auto_best")).leaf = true
	entry({"admin", "services", "owall", "upgrade_info"}, call("action_upgrade_info")).leaf = true
	entry({"admin", "services", "owall", "upgrade_check"}, call("action_upgrade_check")).leaf = true
	entry({"admin", "services", "owall", "upgrade_run"}, call("action_upgrade_run")).leaf = true
	entry({"admin", "services", "owall", "upgrade_log"}, call("action_upgrade_log")).leaf = true
end

function action_status()
	luci.sys.call("/usr/share/owall/url_test.sh status >/dev/null 2>&1")
	local content = fs.readfile("/tmp/owall_status.json") or "{}"
	luci.http.prepare_content("application/json")
	luci.http.write(content)
end

function action_sync()
	luci.sys.call("/usr/share/owall/app.sh sync >> /var/log/owall.log 2>&1")
	luci.sys.call("rm -f /tmp/owall_status.json")
	luci.sys.call("/etc/init.d/owall restart >> /var/log/owall.log 2>&1")
	luci.http.prepare_content("application/json")
	luci.http.write('{"status":"ok"}')
end

function action_auto_best()
	luci.sys.call("/usr/share/owall/url_test.sh auto >> /var/log/owall.log 2>&1")
	luci.sys.call("rm -f /tmp/owall_status.json")
	luci.http.prepare_content("application/json")
	luci.http.write('{"status":"ok"}')
end

function action_upgrade_info()
	local content = luci.sys.exec("/usr/share/owall/upgrade.sh local_versions 2>/dev/null")
	if not content or content == "" then
		content = fs.readfile("/tmp/owall_upgrade_versions.json") or "{}"
	end
	luci.http.prepare_content("application/json")
	luci.http.write(content)
end

function action_upgrade_check()
	local content = luci.sys.exec("/usr/share/owall/upgrade.sh check 2>/dev/null")
	if not content or content == "" then
		content = fs.readfile("/tmp/owall_upgrade_versions.json") or "{}"
	end
	luci.http.prepare_content("application/json")
	luci.http.write(content)
end

function action_upgrade_run()
	local target = luci.http.formvalue("target") or ""
	local allowed = { owall = true, xray = true, geoip = true, geosite = true, all = true }
	if not allowed[target] then
		luci.http.prepare_content("application/json")
		luci.http.write('{"started":false,"error":"invalid_target"}')
		return
	end
	local res = luci.sys.exec("/usr/share/owall/upgrade.sh start_bg " .. target .. " 2>/dev/null")
	if not res or res == "" then
		res = '{"started":false}'
	end
	luci.http.prepare_content("application/json")
	luci.http.write(res)
end

function action_upgrade_log()
	local jsonc = require("luci.jsonc")
	local st = { running = false, result = "", target = "" }
	local st_raw = fs.readfile("/tmp/owall_upgrade_state.json")
	if st_raw and st_raw ~= "" then
		local parsed = jsonc.parse(st_raw)
		if parsed then
			st.running = parsed.running and true or false
			st.result = parsed.result or ""
			st.target = parsed.target or ""
		end
	end
	st.log = fs.readfile("/tmp/owall_upgrade.log") or ""
	luci.http.prepare_content("application/json")
	luci.http.write(jsonc.stringify(st))
end

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
end

function action_status()
	luci.sys.call("/usr/share/owall/url_test.sh status >/dev/null 2>&1")
	local content = fs.readfile("/tmp/owall_status.json") or "{}"
	luci.http.prepare_content("application/json")
	luci.http.write(content)
end

function action_sync()
	luci.sys.call("lua /usr/share/owall/sub_parser.lua >> /var/log/owall.log 2>&1")
	luci.sys.call("/etc/init.d/owall restart >> /var/log/owall.log 2>&1")
	luci.http.prepare_content("application/json")
	luci.http.write('{"status":"ok"}')
end

function action_auto_best()
	luci.sys.call("/usr/share/owall/url_test.sh auto >> /var/log/owall.log 2>&1")
	luci.http.prepare_content("application/json")
	luci.http.write('{"status":"ok"}')
end

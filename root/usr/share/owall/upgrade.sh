#!/bin/sh

LOG_FILE="/tmp/owall_upgrade.log"
STATE_FILE="/tmp/owall_upgrade_state.json"
VER_FILE="/tmp/owall_upgrade_versions.json"
LOCK_DIR="/var/lock/owall_upgrade.lock.d"
TMP_BASE="/tmp/owall_upgrade_tmp"

REPO_OWALL="whatpig/luci-app-owall"
REPO_XRAY="XTLS/Xray-core"
REPO_GEO="Loyalsoldier/v2ray-rules-dat"

API_OWALL="https://api.github.com/repos/${REPO_OWALL}/releases/latest"
API_XRAY="https://api.github.com/repos/${REPO_XRAY}/releases/latest"
API_GEO="https://api.github.com/repos/${REPO_GEO}/releases/latest"

log() {
	local line="[$(date '+%H:%M:%S')] $*"
	echo "$line" >> "$LOG_FILE"
	echo "$line"
}

is_owall_running() {
	ps w 2>/dev/null | grep -q "[/ ]var/etc/owall.json" && return 0
	pidof xray >/dev/null 2>&1 && return 0
	return 1
}

detect_asset_dir() {
	if [ -f "/usr/share/v2ray/geoip.dat" ] || [ -f "/usr/share/v2ray/geosite.dat" ] || [ -d "/usr/share/v2ray" ]; then
		echo "/usr/share/v2ray"
	elif [ -d "/usr/share/xray" ]; then
		echo "/usr/share/xray"
	else
		echo "/usr/share/v2ray"
	fi
}

detect_pkg_mgr() {
	if command -v apk >/dev/null 2>&1; then
		echo "apk"
	else
		echo "opkg"
	fi
}

detect_xray_arch() {
	local u_arch="${1:-}"
	local rel_file="${OPENWRT_RELEASE:-/etc/openwrt_release}"
	local dist_arch=""

	if [ -f "$rel_file" ]; then
		dist_arch=$(sed -n "s/^DISTRIB_ARCH=['\"]\?\([^'\"]*\)['\"]\?/\1/p" "$rel_file" 2>/dev/null | head -n1)
	fi
	if [ -z "$dist_arch" ]; then
		if command -v apk >/dev/null 2>&1; then
			dist_arch=$(apk --print-arch 2>/dev/null | head -n1)
		elif command -v opkg >/dev/null 2>&1; then
			dist_arch=$(opkg print-architecture 2>/dev/null | awk '!/^(all|noarch)/{a=$2} END{print a}')
		fi
	fi
	[ -n "$u_arch" ] || u_arch=$(uname -m 2>/dev/null)

	# Check DISTRIB_ARCH first because MIPS endianness (mips vs mipsel) is only reliable there
	case "$dist_arch" in
		x86_64*) echo "64"; return 0 ;;
		i386*|i486*|i586*|i686*) echo "32"; return 0 ;;
		aarch64*) echo "arm64-v8a"; return 0 ;;
		arm_cortex-a*|arm_v7*|armv7*) echo "arm32-v7a"; return 0 ;;
		arm_mpcore*|arm_arm11*|armv6*) echo "arm32-v6"; return 0 ;;
		arm_arm9*|arm_xscale*|arm_fa526*|armv5*) echo "arm32-v5"; return 0 ;;
		mips64el*) echo "mips64le"; return 0 ;;
		mips64*) echo "mips64"; return 0 ;;
		mipsel*) echo "mips32le"; return 0 ;;
		mips*) echo "mips32"; return 0 ;;
		riscv64*) echo "riscv64"; return 0 ;;
		loongarch64*|loong64*) echo "loong64"; return 0 ;;
	esac

	case "$u_arch" in
		x86_64|amd64) echo "64" ;;
		i386|i486|i586|i686) echo "32" ;;
		aarch64|arm64) echo "arm64-v8a" ;;
		armv7*) echo "arm32-v7a" ;;
		armv6*) echo "arm32-v6" ;;
		armv5*|arm) echo "arm32-v5" ;;
		mips64el) echo "mips64le" ;;
		mips64) echo "mips64" ;;
		mipsel) echo "mips32le" ;;
		mips) echo "mips32" ;;
		riscv64) echo "riscv64" ;;
		loongarch64|loong64) echo "loong64" ;;
		*) echo "unknown" ;;
	esac
}

_curl_try() {
	local use_proxy="$1"
	local url="$2"
	local out_file="$3"
	local timeout="$4"
	local socks_port="$5"

	local rc=0
	if [ "$use_proxy" = "1" ]; then
		curl -fsSL --connect-timeout 8 -m "$timeout" --socks5-hostname "127.0.0.1:${socks_port}" -A 'Owall-Updater/1.3' "$url" -o "$out_file" 2>/dev/null || rc=$?
		[ "$rc" -eq 0 ] && return 0
		# Retry with -k only when local firmware lacks root CA bundle (cert error)
		if [ "$rc" -eq 35 ] || [ "$rc" -eq 51 ] || [ "$rc" -eq 60 ] || [ "$rc" -eq 77 ]; then
			curl -fsSL -k --connect-timeout 8 -m "$timeout" --socks5-hostname "127.0.0.1:${socks_port}" -A 'Owall-Updater/1.3' "$url" -o "$out_file" 2>/dev/null && return 0
		fi
		return 1
	fi

	curl -fsSL --connect-timeout 8 -m "$timeout" -A 'Owall-Updater/1.3' "$url" -o "$out_file" 2>/dev/null || rc=$?
	[ "$rc" -eq 0 ] && return 0
	if [ "$rc" -eq 35 ] || [ "$rc" -eq 51 ] || [ "$rc" -eq 60 ] || [ "$rc" -eq 77 ]; then
		curl -fsSL -k --connect-timeout 8 -m "$timeout" -A 'Owall-Updater/1.3' "$url" -o "$out_file" 2>/dev/null && return 0
	fi
	return 1
}

curl_fetch() {
	local url="$1"
	local out_file="$2"
	local timeout="${3:-30}"
	local socks_port=$(uci -q get owall.global.socks_port || echo 1080)
	[ -n "$socks_port" ] || socks_port=1080

	if is_owall_running; then
		_curl_try 1 "$url" "$out_file" "$timeout" "$socks_port" && return 0
	fi

	_curl_try 0 "$url" "$out_file" "$timeout" "$socks_port"
}

parse_release_json() {
	local json_file="$1"
	local mode="$2"
	local arg1="$3"
	local arg2="$4"

	lua - "$json_file" "$mode" "$arg1" "$arg2" <<'EOF'
local jsonc = require("luci.jsonc")
local path, mode, a1, a2 = arg[1], arg[2], arg[3] or "", arg[4] or ""
local f = io.open(path, "r")
if not f then os.exit(1) end
local content = f:read("*all")
f:close()
local data = jsonc.parse(content)
if not data then os.exit(1) end

if mode == "tag" then
	local tag = tostring(data.tag_name or "")
	tag = tag:gsub("^v", "")
	if tag ~= "" then print(tag) end
elseif mode == "asset_exact" then
	if type(data.assets) == "table" then
		for _, a in ipairs(data.assets) do
			if a.name == a1 and a.browser_download_url then
				print(a.browser_download_url)
				break
			end
		end
	end
elseif mode == "asset_prefix_ext" then
	if type(data.assets) == "table" then
		for _, a in ipairs(data.assets) do
			local name = a.name or ""
			if #name >= #a1 + #a2 and name:sub(1, #a1) == a1 and name:sub(-#a2) == a2 and a.browser_download_url then
				print(a.browser_download_url)
				break
			end
		end
	end
end
EOF
}

ver_has_update() {
	local local_v="$1"
	local remote_v="$2"
	lua - "$local_v" "$remote_v" <<'EOF'
local l, r = arg[1] or "", arg[2] or ""
local function norm(s)
	return s:gsub("^v", ""):gsub("%-r(%d+)$", "-%1")
end
l, r = norm(l), norm(r)
if r == "" or r == "unknown" then
	print("false")
	return
end
if l == "" or l == "not_installed" then
	print("true")
	return
end
if l == "unknown" then
	print("false")
	return
end
local function split_nums(s)
	local t = {}
	for num in s:gmatch("(%d+)") do
		t[#t + 1] = tonumber(num) or 0
	end
	return t
end
local al, ar = split_nums(l), split_nums(r)
if #al == 0 or #ar == 0 then
	print(l ~= r and "true" or "false")
	return
end
local n = math.max(#al, #ar)
for i = 1, n do
	local va, vb = al[i] or 0, ar[i] or 0
	if va < vb then
		print("true")
		return
	elseif va > vb then
		print("false")
		return
	end
end
print("false")
EOF
}

get_local_owall_ver() {
	local ver=""
	if command -v apk >/dev/null 2>&1; then
		ver=$(apk list -I luci-app-owall 2>/dev/null | head -n1 | sed -n 's/^luci-app-owall-\([^ ]*\).*/\1/p')
	elif command -v opkg >/dev/null 2>&1; then
		ver=$(opkg list-installed luci-app-owall 2>/dev/null | head -n1 | awk -F ' - ' '{print $2}')
	fi
	ver=$(printf '%s' "$ver" | tr -d '\r ' | sed 's/-r\([0-9]*\)$/-\1/')
	if [ -z "$ver" ] && [ -f "/usr/share/owall/VERSION" ]; then
		ver=$(cat /usr/share/owall/VERSION 2>/dev/null | tr -d '\r\n ')
	fi
	echo "${ver:-unknown}"
}

get_local_xray_ver() {
	if ! command -v xray >/dev/null 2>&1; then
		echo "not_installed"
		return 0
	fi
	local ver=$(xray version 2>/dev/null | head -n1 | awk '{print $2}' | sed 's/^v//')
	echo "${ver:-unknown}"
}

get_local_geo_ver() {
	local which="$1"
	local asset_dir=$(detect_asset_dir)
	if [ -f "/etc/owall/${which}.ver" ]; then
		local v=$(cat "/etc/owall/${which}.ver" 2>/dev/null | tr -d '\r\n ')
		[ -n "$v" ] && { echo "$v"; return 0; }
	fi
	if [ -f "${asset_dir}/${which}.dat" ]; then
		local d=$(date -r "${asset_dir}/${which}.dat" +%Y%m%d 2>/dev/null || echo "")
		echo "${d:-unknown}"
	else
		echo "not_installed"
	fi
}

write_versions_json() {
	local arch=$(detect_xray_arch)
	local pkg_mgr=$(detect_pkg_mgr)
	local l_owall=$(get_local_owall_ver)
	local l_xray=$(get_local_xray_ver)
	local l_geoip=$(get_local_geo_ver geoip)
	local l_geosite=$(get_local_geo_ver geosite)
	local r_owall="$1"
	local r_xray="$2"
	local r_geo="$3"
	local checked="${4:-0}"

	local u_owall="false" u_xray="false" u_geoip="false" u_geosite="false"
	[ -n "$r_owall" ] && u_owall=$(ver_has_update "$l_owall" "$r_owall")
	[ -n "$r_xray" ] && u_xray=$(ver_has_update "$l_xray" "$r_xray")
	[ -n "$r_geo" ] && u_geoip=$(ver_has_update "$l_geoip" "$r_geo")
	[ -n "$r_geo" ] && u_geosite=$(ver_has_update "$l_geosite" "$r_geo")

	local tmp_file="${VER_FILE}.tmp.$$"
	lua - "$tmp_file" "$arch" "$pkg_mgr" "$checked" \
		"$l_owall" "$r_owall" "$u_owall" \
		"$l_xray" "$r_xray" "$u_xray" \
		"$l_geoip" "$r_geo" "$u_geoip" \
		"$l_geosite" "$r_geo" "$u_geosite" <<'EOF'
local jsonc = require("luci.jsonc")
local obj = {
	arch = arg[2],
	pkg_mgr = arg[3],
	checked = (arg[4] == "1"),
	owall   = { ["local"] = arg[5],  remote = arg[6],  has_update = (arg[7] == "true") },
	xray    = { ["local"] = arg[8],  remote = arg[9],  has_update = (arg[10] == "true") },
	geoip   = { ["local"] = arg[11], remote = arg[12], has_update = (arg[13] == "true") },
	geosite = { ["local"] = arg[14], remote = arg[15], has_update = (arg[16] == "true") }
}
local f = assert(io.open(arg[1], "w"))
f:write(jsonc.stringify(obj, true))
f:close()
EOF
	mv -f "$tmp_file" "$VER_FILE"
}

local_versions() {
	if [ -f "$VER_FILE" ]; then
		local r_vals=$(lua - "$VER_FILE" <<'EOF'
local jsonc = require("luci.jsonc")
local f = io.open(arg[1], "r")
if not f then os.exit(0) end
local d = jsonc.parse(f:read("*all") or "")
f:close()
if d then
	print(string.format("%s|%s|%s|%s",
		(d.owall and d.owall.remote) or "",
		(d.xray and d.xray.remote) or "",
		(d.geoip and d.geoip.remote) or "",
		d.checked and "1" or "0"))
end
EOF
		)
		if [ -n "$r_vals" ]; then
			local ro=$(printf '%s' "$r_vals" | cut -d'|' -f1)
			local rx=$(printf '%s' "$r_vals" | cut -d'|' -f2)
			local rg=$(printf '%s' "$r_vals" | cut -d'|' -f3)
			local ch=$(printf '%s' "$r_vals" | cut -d'|' -f4)
			write_versions_json "$ro" "$rx" "$rg" "$ch"
			cat "$VER_FILE"
			return 0
		fi
	fi
	write_versions_json "" "" "" "0"
	cat "$VER_FILE"
}

check_updates() {
	local tmp_dir="/tmp/owall_chk.$$"
	mkdir -p "$tmp_dir"
	trap 'rm -rf "$tmp_dir"' EXIT INT TERM

	( curl_fetch "$API_OWALL" "$tmp_dir/owall.json" 15 || true ) &
	( curl_fetch "$API_XRAY" "$tmp_dir/xray.json" 15 || true ) &
	( curl_fetch "$API_GEO" "$tmp_dir/geo.json" 15 || true ) &
	wait

	local r_owall="" r_xray="" r_geo=""
	[ -s "$tmp_dir/owall.json" ] && r_owall=$(parse_release_json "$tmp_dir/owall.json" tag 2>/dev/null || true)
	[ -s "$tmp_dir/xray.json" ] && r_xray=$(parse_release_json "$tmp_dir/xray.json" tag 2>/dev/null || true)
	[ -s "$tmp_dir/geo.json" ] && r_geo=$(parse_release_json "$tmp_dir/geo.json" tag 2>/dev/null || true)

	write_versions_json "$r_owall" "$r_xray" "$r_geo" "1"
	rm -rf "$tmp_dir"
	trap - EXIT INT TERM
	cat "$VER_FILE"
}

write_state() {
	local running="$1"
	local result="$2"
	local target="$3"
	local tmp_file="${STATE_FILE}.tmp.$$"
	lua - "$tmp_file" "$running" "$result" "$target" <<'EOF'
local jsonc = require("luci.jsonc")
local obj = {
	running = (arg[2] == "1"),
	result = arg[3] or "",
	target = arg[4] or ""
}
local f = assert(io.open(arg[1], "w"))
f:write(jsonc.stringify(obj))
f:close()
EOF
	mv -f "$tmp_file" "$STATE_FILE"
}

verify_geo_sha256() {
	local dat_file="$1"
	local sum_file="$2"
	if [ ! -s "$sum_file" ] || ! command -v sha256sum >/dev/null 2>&1; then
		return 0
	fi
	local expected=$(awk 'NR==1{print tolower($1)}' "$sum_file" | tr -d '\r ')
	[ -n "$expected" ] || return 0
	local actual=$(sha256sum "$dat_file" | awk '{print tolower($1)}' | tr -d '\r ')
	[ "$expected" = "$actual" ]
}

verify_xray_dgst() {
	local zip_file="$1"
	local dgst_file="$2"
	if [ ! -s "$dgst_file" ] || ! command -v sha256sum >/dev/null 2>&1; then
		return 0
	fi
	local expected=$(awk -F'=' '/SHA2?-?256/{gsub(/[^0-9a-fA-F]/,"",$2); if (length($2)==64) {print tolower($2); exit}}' "$dgst_file")
	[ -n "$expected" ] || return 0
	local actual=$(sha256sum "$zip_file" | awk '{print tolower($1)}' | tr -d '\r ')
	[ "$expected" = "$actual" ]
}

update_geo() {
	local which="$1"
	local no_restart="$2"
	local asset_dir=$(detect_asset_dir)
	mkdir -p "$TMP_BASE" "$asset_dir" /etc/owall

	log "Fetching latest ${which} release info from ${REPO_GEO}..."
	local rel_json="$TMP_BASE/geo.json"
	if [ ! -s "$rel_json" ]; then
		curl_fetch "$API_GEO" "$rel_json" 20 || {
			log "ERROR: Failed to fetch ${REPO_GEO} release metadata."
			return 1
		}
	fi

	local r_tag=$(parse_release_json "$rel_json" tag 2>/dev/null || true)
	local dat_url=$(parse_release_json "$rel_json" asset_exact "${which}.dat" 2>/dev/null || true)
	local sum_url=$(parse_release_json "$rel_json" asset_exact "${which}.dat.sha256sum" 2>/dev/null || true)

	[ -n "$dat_url" ] || {
		log "ERROR: Asset ${which}.dat not found in ${REPO_GEO} release."
		return 1
	}

	log "Downloading ${which}.dat (${r_tag:-latest})..."
	local tmp_dat="$TMP_BASE/${which}.dat"
	local tmp_sum="$TMP_BASE/${which}.dat.sha256sum"
	curl_fetch "$dat_url" "$tmp_dat" 120 || {
		log "ERROR: Failed to download ${which}.dat."
		return 1
	}

	local fsize=$(wc -c < "$tmp_dat" 2>/dev/null || echo 0)
	if [ "${fsize:-0}" -lt 102400 ]; then
		log "ERROR: Downloaded ${which}.dat looks corrupt/too small (${fsize} bytes)."
		return 1
	fi

	if [ -n "$sum_url" ]; then
		curl_fetch "$sum_url" "$tmp_sum" 20 || true
		if [ -s "$tmp_sum" ]; then
			if ! verify_geo_sha256 "$tmp_dat" "$tmp_sum"; then
				log "ERROR: SHA256 verification failed for ${which}.dat!"
				return 1
			fi
			log "SHA256 verified for ${which}.dat."
		fi
	fi

	mv -f "$tmp_dat" "${asset_dir}/${which}.dat" || {
		log "ERROR: Failed to install ${asset_dir}/${which}.dat."
		return 1
	}
	[ -n "$r_tag" ] && printf '%s\n' "$r_tag" > "/etc/owall/${which}.ver"
	rm -f "$tmp_sum"
	log "Updated ${which}.dat -> ${asset_dir}/${which}.dat (${r_tag:-ok})."

	if [ "$which" = "geoip" ]; then
		log "Refreshing plain-text China IPv4 list for nftables bypass..."
		/usr/share/owall/app.sh update_china_ip >> "$LOG_FILE" 2>&1 || true
	fi

	if [ "$no_restart" != "no_restart" ]; then
		local enabled=$(uci -q get owall.global.enabled)
		if [ "$enabled" = "1" ]; then
			log "Restarting Owall to apply new ${which} database..."
			/etc/init.d/owall restart >> "$LOG_FILE" 2>&1 || true
		fi
	fi
	return 0
}

update_xray() {
	local no_restart="$1"
	if ! command -v unzip >/dev/null 2>&1; then
		log "ERROR: unzip not found; please install unzip."
		return 1
	fi

	local arch=$(detect_xray_arch)
	if [ "$arch" = "unknown" ]; then
		log "ERROR: Unsupported CPU architecture ($(uname -m))."
		return 1
	fi

	local xray_bin=$(command -v xray || echo "/usr/bin/xray")
	mkdir -p "$TMP_BASE"

	log "Fetching latest Xray-core release info (arch=${arch})..."
	local rel_json="$TMP_BASE/xray.json"
	curl_fetch "$API_XRAY" "$rel_json" 20 || {
		log "ERROR: Failed to fetch ${REPO_XRAY} release metadata."
		return 1
	}

	local r_tag=$(parse_release_json "$rel_json" tag 2>/dev/null || true)
	local zip_name="Xray-linux-${arch}.zip"
	local zip_url=$(parse_release_json "$rel_json" asset_exact "$zip_name" 2>/dev/null || true)
	local dgst_url=$(parse_release_json "$rel_json" asset_exact "${zip_name}.dgst" 2>/dev/null || true)
	[ -n "$zip_url" ] || {
		log "ERROR: Asset ${zip_name} not found in ${REPO_XRAY} release."
		return 1
	}

	log "Downloading ${zip_name} (${r_tag:-latest})..."
	local zip_file="$TMP_BASE/xray.zip"
	local dgst_file="$TMP_BASE/xray.zip.dgst"
	curl_fetch "$zip_url" "$zip_file" 180 || {
		log "ERROR: Failed to download ${zip_name}."
		return 1
	}

	if [ -n "$dgst_url" ]; then
		curl_fetch "$dgst_url" "$dgst_file" 20 || true
		if [ -s "$dgst_file" ]; then
			if ! verify_xray_dgst "$zip_file" "$dgst_file"; then
				rm -f "$zip_file" "$dgst_file"
				log "ERROR: SHA256 (.dgst) verification failed for ${zip_name}!"
				return 1
			fi
			log "SHA256 verified for ${zip_name}."
		fi
		rm -f "$dgst_file"
	fi

	log "Extracting Xray binary..."
	if ! unzip -o -q "$zip_file" xray -d "$TMP_BASE" >> "$LOG_FILE" 2>&1; then
		rm -f "$zip_file"
		log "ERROR: Failed to unzip xray binary."
		return 1
	fi
	rm -f "$zip_file"

	local new_bin="$TMP_BASE/xray"
	chmod +x "$new_bin" 2>/dev/null || true
	if ! "$new_bin" version >/dev/null 2>&1; then
		log "ERROR: Extracted xray binary failed self-check; keeping existing binary."
		return 1
	fi

	local was_enabled=$(uci -q get owall.global.enabled)
	if [ "$was_enabled" = "1" ] && is_owall_running; then
		log "Stopping Owall temporarily for safe binary replacement..."
		/etc/init.d/owall stop >> "$LOG_FILE" 2>&1 || true
	fi

	local bak_bin="$TMP_BASE/xray.bak"
	if [ -f "$xray_bin" ]; then
		if ! cp -f "$xray_bin" "$bak_bin" 2>/dev/null; then
			log "ERROR: Insufficient RAM in /tmp to back up ${xray_bin}; aborting safely."
			if [ "$was_enabled" = "1" ]; then
				/etc/init.d/owall start >> "$LOG_FILE" 2>&1 || true
			fi
			return 1
		fi
	fi
	rm -f "$xray_bin"

	if ! cp -f "$new_bin" "$xray_bin" || ! chmod +x "$xray_bin"; then
		log "ERROR: Failed to write ${xray_bin} (insufficient flash space?); restoring backup..."
		[ -f "$bak_bin" ] && cp -f "$bak_bin" "$xray_bin" && chmod +x "$xray_bin"
		if [ "$was_enabled" = "1" ]; then
			/etc/init.d/owall start >> "$LOG_FILE" 2>&1 || true
		fi
		return 1
	fi

	rm -f "$new_bin" "$bak_bin"
	log "Successfully upgraded Xray-core to $(get_local_xray_ver)."

	if [ "$no_restart" != "no_restart" ] && [ "$was_enabled" = "1" ]; then
		log "Restarting Owall with new Xray-core..."
		/etc/init.d/owall start >> "$LOG_FILE" 2>&1 || true
	fi
	return 0
}

download_owall_pkgs() {
	local pkg_mgr=$(detect_pkg_mgr)
	local ext="ipk"
	[ "$pkg_mgr" = "apk" ] && ext="apk"

	mkdir -p "$TMP_BASE"
	log "Fetching latest Owall plugin release info (pkg_mgr=${pkg_mgr})..."
	local rel_json="$TMP_BASE/owall.json"
	curl_fetch "$API_OWALL" "$rel_json" 20 || {
		log "ERROR: Failed to fetch ${REPO_OWALL} release metadata."
		return 1
	}

	local r_tag=$(parse_release_json "$rel_json" tag 2>/dev/null || true)
	local app_url=$(parse_release_json "$rel_json" asset_prefix_ext "luci-app-owall" ".${ext}" 2>/dev/null || true)
	local i18n_url=$(parse_release_json "$rel_json" asset_prefix_ext "luci-i18n-owall-zh-cn" ".${ext}" 2>/dev/null || true)

	[ -n "$app_url" ] || {
		log "ERROR: No .${ext} package found in ${REPO_OWALL} release."
		return 1
	}

	local app_pkg="$TMP_BASE/luci-app-owall.${ext}"
	local i18n_pkg="$TMP_BASE/luci-i18n-owall-zh-cn.${ext}"
	log "Downloading luci-app-owall (${r_tag:-latest})..."
	curl_fetch "$app_url" "$app_pkg" 60 || {
		log "ERROR: Failed to download luci-app-owall package."
		return 1
	}
	[ -s "$app_pkg" ] || {
		log "ERROR: Downloaded luci-app-owall package is empty."
		return 1
	}
	if [ -n "$i18n_url" ]; then
		curl_fetch "$i18n_url" "$i18n_pkg" 60 || rm -f "$i18n_pkg"
	fi
	return 0
}

_pkg_install_once() {
	local pkg_mgr="$1"
	local app_pkg="$2"
	local i18n_pkg="$3"
	if [ "$pkg_mgr" = "apk" ]; then
		if [ -s "$i18n_pkg" ]; then
			apk add --allow-untrusted "$app_pkg" "$i18n_pkg" >> "$LOG_FILE" 2>&1
		else
			apk add --allow-untrusted "$app_pkg" >> "$LOG_FILE" 2>&1
		fi
	else
		if [ -s "$i18n_pkg" ]; then
			opkg install --force-reinstall "$app_pkg" "$i18n_pkg" >> "$LOG_FILE" 2>&1
		else
			opkg install --force-reinstall "$app_pkg" >> "$LOG_FILE" 2>&1
		fi
	fi
}

install_owall_pkgs() {
	local no_restart="$1"
	local pkg_mgr=$(detect_pkg_mgr)
	local ext="ipk"
	[ "$pkg_mgr" = "apk" ] && ext="apk"
	local app_pkg="$TMP_BASE/luci-app-owall.${ext}"
	local i18n_pkg="$TMP_BASE/luci-i18n-owall-zh-cn.${ext}"

	log "Installing package via ${pkg_mgr}..."
	local rc=0
	_pkg_install_once "$pkg_mgr" "$app_pkg" "$i18n_pkg" || rc=$?
	if [ "$rc" -ne 0 ]; then
		log "Initial install returned $rc; refreshing ${pkg_mgr} index and retrying..."
		if [ "$pkg_mgr" = "apk" ]; then
			apk update >> "$LOG_FILE" 2>&1 || true
		else
			opkg update >> "$LOG_FILE" 2>&1 || true
		fi
		rc=0
		_pkg_install_once "$pkg_mgr" "$app_pkg" "$i18n_pkg" || rc=$?
	fi

	rm -f "$app_pkg" "$i18n_pkg"
	if [ "$rc" -ne 0 ]; then
		log "ERROR: ${pkg_mgr} package installation failed (exit code $rc)."
		return 1
	fi

	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true
	log "Successfully upgraded Owall plugin to $(get_local_owall_ver)."

	if [ "$no_restart" != "no_restart" ]; then
		local enabled=$(uci -q get owall.global.enabled)
		if [ "$enabled" = "1" ]; then
			log "Restarting Owall service..."
			/etc/init.d/owall restart >> "$LOG_FILE" 2>&1 || true
		fi
	fi
	return 0
}

update_owall() {
	local no_restart="$1"
	download_owall_pkgs || return 1
	install_owall_pkgs "$no_restart"
}

acquire_lock() {
	mkdir -p /var/lock
	if ! mkdir "$LOCK_DIR" 2>/dev/null; then
		local now=$(date +%s)
		local mtime=$(date -r "$LOCK_DIR" +%s 2>/dev/null || echo 0)
		if [ "$mtime" -gt 0 ] && [ $((now - mtime)) -gt 900 ]; then
			rmdir "$LOCK_DIR" 2>/dev/null || true
			mkdir "$LOCK_DIR" 2>/dev/null || return 1
		else
			return 1
		fi
	fi
	return 0
}

run_upgrade() {
	local target="$1"
	local already_locked="$2"
	case "$target" in
		owall|xray|geoip|geosite|all) ;;
		*) echo "Invalid target: $target"; return 1 ;;
	esac

	if [ "$already_locked" != "locked" ]; then
		if ! acquire_lock; then
			echo "Upgrade already in progress."
			return 1
		fi
		: > "$LOG_FILE"
		rm -rf "$TMP_BASE"
		mkdir -p "$TMP_BASE"
		write_state 1 "running" "$target"
	fi
	trap 'rm -rf "$LOCK_DIR" "$TMP_BASE" /tmp/owall_upgrade_runner.sh' EXIT INT TERM

	log "Starting upgrade task: target=${target}"

	local ok=1
	case "$target" in
		geoip)   update_geo "geoip" "" || ok=0 ;;
		geosite) update_geo "geosite" "" || ok=0 ;;
		xray)    update_xray "" || ok=0 ;;
		owall)   update_owall "" || ok=0 ;;
		all)
			local was_enabled=$(uci -q get owall.global.enabled)
			update_geo "geoip" "no_restart" || ok=0
			[ "$ok" -eq 1 ] && { update_geo "geosite" "no_restart" || ok=0; }
			# Download Owall packages BEFORE update_xray stops the active proxy tunnel
			[ "$ok" -eq 1 ] && { download_owall_pkgs || ok=0; }
			[ "$ok" -eq 1 ] && { update_xray "no_restart" || ok=0; }
			[ "$ok" -eq 1 ] && { install_owall_pkgs "no_restart" || ok=0; }
			if [ "$was_enabled" = "1" ]; then
				log "Restarting Owall service after full upgrade..."
				/etc/init.d/owall restart >> "$LOG_FILE" 2>&1 || true
			fi
			;;
	esac

	local_versions >/dev/null 2>&1 || true
	rm -rf "$TMP_BASE" /tmp/owall_upgrade_runner.sh
	rmdir "$LOCK_DIR" 2>/dev/null || true
	trap - EXIT INT TERM

	if [ "$ok" -eq 1 ]; then
		log "Upgrade task (${target}) completed successfully."
		write_state 0 "ok" "$target"
		return 0
	else
		log "Upgrade task (${target}) failed. See log above for details."
		write_state 0 "error" "$target"
		return 1
	fi
}

start_bg() {
	local target="$1"
	case "$target" in
		owall|xray|geoip|geosite|all) ;;
		*) echo '{"started":false,"error":"invalid_target"}'; return 1 ;;
	esac
	if ! acquire_lock; then
		echo '{"started":false,"error":"busy"}'
		return 0
	fi
	: > "$LOG_FILE"
	rm -rf "$TMP_BASE"
	mkdir -p "$TMP_BASE"
	write_state 1 "running" "$target"

	# Copy script to /tmp so self-upgrade never overwrites the running interpreter script
	local runner="/tmp/owall_upgrade_runner.sh"
	if ! cp -f "/usr/share/owall/upgrade.sh" "$runner" || ! chmod +x "$runner"; then
		rm -rf "$LOCK_DIR" "$TMP_BASE" "$runner"
		write_state 0 "error" "$target"
		echo '{"started":false,"error":"copy_failed"}'
		return 1
	fi

	"$runner" run_locked "$target" </dev/null >/dev/null 2>&1 &
	echo '{"started":true}'
}

case "$1" in
	local_versions) local_versions ;;
	check) check_updates ;;
	run) run_upgrade "$2" ;;
	run_locked) run_upgrade "$2" "locked" ;;
	start_bg) start_bg "$2" ;;
	detect_arch) detect_xray_arch "$2" ;;
	verify_sha) verify_geo_sha256 "$2" "$3" ;;
	verify_dgst) verify_xray_dgst "$2" "$3" ;;
	*) echo "Usage: $0 {local_versions|check|run <target>|start_bg <target>}" ;;
esac

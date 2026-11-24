# Owall (`luci-app-owall`)

> **OpenWrt 极简全自动透明代理路由插件**
>
> 融合 PassWall 1 的极致轻量与国内直连稳健性 + PassWall 2 的 FakeDNS 0ms 秒开与 nftables 底层硬直通。
> 抛弃 8 个配置页与数十个繁琐选项，只需粘贴订阅或节点链接，点击唯一总开关即可畅享无缝网络。

---

## 🌟 核心特性与设计哲学

- ⚡ **单开关极致极简**：无多余标签页，全自动最佳实践预设。
- 🛡️ **国内网络坚若磐石**：nftables 底层三层网卡级硬直通（`@owall_direct`），微信音视频、国服手游、网银安全 100% 直连无误杀。
- 🚀 **海外访问 0ms 秒开**：全自动 FakeDNS（`198.18.0.0/16`）零污染、零泄露，域名在远端 VPS 服务器端高效解析。
- 📦 **超低内存占用**：Dnsmasq 纯转发（零规则注入），全面收敛至单一 **Xray-core** 内核，原生支持 Reality / Vision / XHTTP / WS / gRPC 等前沿传输。
- 🔄 **全协议与全自动故障切换**：原生支持 `VLESS (Reality / Vision / XHTTP)`、`Trojan`、`VMess`、`Shadowsocks`、`Hysteria 2`，后台智能优选最低延迟节点。

---

## 🛠️ 安装与编译

### 1. 从 GitHub Releases 直接下载安装（推荐）

前往 [Releases 页面](https://github.com/whatpig/luci-app-owall/releases/latest) 下载对应包格式的预编译包（同时提供 `.ipk` 与 `.apk`）：

#### OpenWrt 21.02 ~ 24.10（`opkg` / `.ipk`）
```bash
opkg update
opkg install xray-core v2ray-geoip v2ray-geosite kmod-nft-tproxy nftables
opkg install luci-app-owall_*.ipk luci-i18n-owall-zh-cn_*.ipk
```

#### OpenWrt 25.12+ / Snapshot（`apk` / `.apk`）
```bash
apk update
apk add xray-core v2ray-geoip v2ray-geosite kmod-nft-tproxy nftables
apk add --allow-untrusted luci-app-owall-*.apk luci-i18n-owall-zh-cn-*.apk
```

### 2. GitHub Actions 自动构建发布

进入仓库 **Actions -> Build & Release Owall (IPK + APK)**，点击 **Run workflow**，流水线会自动使用 OpenWrt `24.10.8` SDK（产出 `.ipk`）和 OpenWrt `25.12.6` SDK（产出 `.apk`）并行编译并发布至 GitHub Releases。

### 3. 本地源码编译 (OpenWrt SDK / Buildroot)
将本项目克隆到 OpenWrt 源码的 `package/` 目录：
```bash
cd package/
git clone https://github.com/whatpig/luci-app-owall.git
cd ..
./scripts/feeds update -a && ./scripts/feeds install -a
make menuconfig # 选中 LuCI -> Applications -> luci-app-owall
make package/luci-app-owall/compile V=s
```

---

## ⚙️ 使用说明

1. 登录 OpenWrt 管理界面，进入 **服务 (Services) -> Owall 极简代理**；
2. 在 **导入订阅或节点链接** 输入框中粘贴您的订阅地址（HTTP/HTTPS）或节点分享链接（支持批量粘贴）；
3. 打开 **总开关**，点击右下角 **保存并应用**；
4. 后台自动解析节点、测试连通性并激活最佳线路，国内外网络即刻畅通。

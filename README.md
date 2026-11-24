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
- 📦 **超低内存占用（< 35MB）**：Dnsmasq 纯转发（零规则注入），搭配现代化精简 Sing-box 内核，杜绝旧版断网与丢包问题。
- 🔄 **全协议与全自动故障切换**：原生支持 `VLESS (Reality / Vision)`、`Hysteria 2`、`TUIC`、`Trojan`、`VMess`、`Shadowsocks`，后台智能优选最低延迟节点。

---

## 🛠️ 安装与编译

### 1. 源码编译 (OpenWrt SDK / Buildroot)
将本项目克隆到 OpenWrt 源码的 `package/` 目录：
```bash
cd package/
git clone https://github.com/whatpig/luci-app-owall.git
cd ..
./scripts/feeds update -a && ./scripts/feeds install -a
make menuconfig # 选中 LuCI -> Applications -> luci-app-owall
make package/luci-app-owall/compile V=s
```

### 2. 路由器单包安装 (OPKG)
将编译好的 `.ipk` 上传至路由器：
```bash
opkg update
opkg install sing-box v2ray-geodata kmod-nft-tproxy nftables
opkg install luci-app-owall_*.ipk
```

---

## ⚙️ 使用说明

1. 登录 OpenWrt 管理界面，进入 **服务 (Services) -> Owall 极简代理**；
2. 在 **导入订阅或节点链接** 输入框中粘贴您的订阅地址（HTTP/HTTPS）或节点分享链接（支持批量粘贴）；
3. 打开 **总开关**，点击右下角 **保存并应用**；
4. 后台自动解析节点、测试连通性并激活最佳线路，国内外网络即刻畅通。

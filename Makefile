include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-owall
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=GPL-3.0-only
PKG_MAINTAINER:=Owall Developers

LUCI_TITLE:=LuCI support for Owall Ultra-Lightweight Transparent Proxy
LUCI_DEPENDS:=+coreutils +coreutils-base64 +curl +libuci-lua +lua +luci-compat +luci-lib-jsonc \
	+sing-box \
	+v2ray-geodata \
	+kmod-nft-tproxy +kmod-nft-socket +kmod-nft-nat +nftables
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature

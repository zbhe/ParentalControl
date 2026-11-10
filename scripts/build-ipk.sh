#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
PKG_NAME='luci-app-parental'
PKG_VERSION='1.0.0'
PKG_RELEASE='1'
PKG_ARCH='all'
PKG_VERSION_FULL="${PKG_VERSION}-${PKG_RELEASE}"
OUT_DIR="${ROOT_DIR}/dist"
OUT_FILE="${OUT_DIR}/${PKG_NAME}_${PKG_VERSION_FULL}_${PKG_ARCH}.ipk"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/${PKG_NAME}.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT

DATA_DIR="${WORK_DIR}/data"
CONTROL_DIR="${WORK_DIR}/control"

mkdir -p "$DATA_DIR" "$CONTROL_DIR" "$OUT_DIR"
cp -a "${ROOT_DIR}/files/." "$DATA_DIR/"

find "$DATA_DIR" -type d -exec chmod 0755 {} +
find "$DATA_DIR" -type f -exec chmod 0644 {} +
chmod 0755 \
	"$DATA_DIR/etc/config/firewall.parental" \
	"$DATA_DIR/etc/uci-defaults/90-parental" \
	"$DATA_DIR/usr/lib/parental/firewall-include.sh"

cat > "${CONTROL_DIR}/control" <<EOF
Package: ${PKG_NAME}
Version: ${PKG_VERSION_FULL}
Depends: luci-base, firewall4, nftables
Section: luci
Priority: optional
Maintainer: OpenWrt User <user@openwrt.lan>
Architecture: ${PKG_ARCH}
Installed-Size: $(du -sk "$DATA_DIR" | awk '{print $1}')
Description: LuCI parental control
 Per-device parental controls for OpenWrt using LuCI and nftables.
 Supports multiple time ranges, per-range weekdays, and overnight ranges.
EOF

cat > "${CONTROL_DIR}/conffiles" <<'EOF'
/etc/config/parental
EOF

cat > "${CONTROL_DIR}/postinst" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
[ -x /usr/lib/parental/firewall-include.sh ] && /usr/lib/parental/firewall-include.sh add
exit 0
EOF

cat > "${CONTROL_DIR}/prerm" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
[ -x /usr/lib/parental/firewall-include.sh ] && /usr/lib/parental/firewall-include.sh remove
exit 0
EOF

chmod 0644 "${CONTROL_DIR}/control" "${CONTROL_DIR}/conffiles"
chmod 0755 "${CONTROL_DIR}/postinst" "${CONTROL_DIR}/prerm"

printf '2.0\n' > "${WORK_DIR}/debian-binary"

tar --owner=0 --group=0 --numeric-owner \
	-C "$DATA_DIR" -czf "${WORK_DIR}/data.tar.gz" .
tar --owner=0 --group=0 --numeric-owner \
	-C "$CONTROL_DIR" -czf "${WORK_DIR}/control.tar.gz" .

(
	cd "$WORK_DIR"
	if command -v bsdtar >/dev/null 2>&1; then
		bsdtar --format ar -cf "$OUT_FILE" \
			debian-binary control.tar.gz data.tar.gz
	else
		ar rcs "$OUT_FILE" debian-binary control.tar.gz data.tar.gz
	fi
)

printf 'Built: %s\n' "$OUT_FILE"

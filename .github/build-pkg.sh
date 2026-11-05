#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Build luci-app-nginx-console as an apk without the OpenWrt SDK.
#
#   Usage: bash .github/build-pkg.sh [output-dir]
#
# The package is architecture independent, so nothing has to be compiled: the
# only inputs are the files under root/ and htdocs/ plus the metadata below.
# The metadata mirrors Makefile so an in-tree build and this release build
# produce the same package.
#
# apk-tools v3 (the one with `apk mkpkg`) is required; the OpenWrt build of
# apk-tools does not ship that command, which is why the CI workflow builds
# apk-tools from source first.

set -o errexit
set -o pipefail
set -o nounset

NAME=luci-app-nginx-console
ARCH=noarch
DESCRIPTION="LuCI console for the nginx UCI configuration"
LICENSE=Apache-2.0
ORIGIN="https://github.com/szwjp/${NAME}"
MAINTAINER="szwjp <szwjp@users.noreply.github.com>"

# apk dependency list: space separated, no leading '+' like the Makefile has.
# The console calls its backend through rpcd's file.exec, so rpcd-mod-file is
# what it needs - not cgi-io.  jsonfilter decodes the uci list values without
# invoking a shell, which is what keeps option values from being executed.
DEPENDS="luci-base rpcd rpcd-mod-file jsonfilter nginx"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-${REPO_DIR}/dist}"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

# The version lives in the Makefile only: this script and the workflow both
# read it from there, so the package, the release tag and the install command
# in the release notes can never drift apart.
VERSION="$(sed -n 's/^PKG_VERSION:=//p' "$REPO_DIR/Makefile" | head -n1 | tr -d '[:space:]')"
RELEASE="$(sed -n 's/^PKG_RELEASE:=//p' "$REPO_DIR/Makefile" | head -n1 | tr -d '[:space:]')"
[ -n "$VERSION" ] && [ -n "$RELEASE" ] || fail "cannot read PKG_VERSION / PKG_RELEASE from Makefile"
PKGVER="${VERSION}-r${RELEASE}"

PKG_DIR="${TEMP_DIR}/${NAME}"

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v apk >/dev/null || fail "apk not found; apk-tools v3 is required for 'apk mkpkg'"
apk mkpkg --help >/dev/null 2>&1 || fail "'apk mkpkg' is unavailable; this apk-tools cannot build packages"

say "Assembling file tree for ${NAME} ${PKGVER} (${ARCH})"

mkdir -p "$PKG_DIR"

# root/ goes to /, htdocs/ goes to /www (same mapping luci.mk uses).
[ -d "$REPO_DIR/root" ] || fail "missing root/ directory"
[ -d "$REPO_DIR/htdocs" ] || fail "missing htdocs/ directory"

cp -a "$REPO_DIR/root/." "$PKG_DIR/"
mkdir -p "$PKG_DIR/www"
cp -a "$REPO_DIR/htdocs/." "$PKG_DIR/www/"

# Permissions: the helper must stay executable, everything else is data.
find "$PKG_DIR" -type d -exec chmod 0755 {} +
find "$PKG_DIR" -type f -exec chmod 0644 {} +
chmod 0755 "$PKG_DIR/usr/libexec/nginx-console" ||
	fail "usr/libexec/nginx-console is missing"
chmod 0755 "$PKG_DIR/usr/libexec/nginx-console-write" ||
	fail "usr/libexec/nginx-console-write is missing"

# Reject leftovers that have no business being packaged.
if find "$PKG_DIR" -name '._*' -o -name '.DS_Store' | grep -q .; then
	fail "macOS metadata found in the package tree"
fi

say "Maintainer scripts"

cat > "$TEMP_DIR/post-install" <<'POSTINST'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="luci-app-nginx-console"
default_postinst $0 $@
[ -n "${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	killall -HUP rpcd 2>/dev/null
	exit 0
}
POSTINST

cat > "$TEMP_DIR/post-upgrade" <<'POSTUPGRADE'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="luci-app-nginx-console"
default_postinst $0 $@
[ -n "${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	killall -HUP rpcd 2>/dev/null
	exit 0
}
POSTUPGRADE

cat > "$TEMP_DIR/pre-deinstall" <<'PREDEINSTALL'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
export root="${IPKG_INSTROOT}"
export pkgname="luci-app-nginx-console"
default_prerm $0 $@
PREDEINSTALL

chmod 0755 "$TEMP_DIR/post-install" "$TEMP_DIR/post-upgrade" "$TEMP_DIR/pre-deinstall"

say "Writing package list"

mkdir -p "$PKG_DIR/lib/apk/packages"

# The rate limits are a conffile: a hand edited rate must survive an upgrade.
printf '%s\n' '/etc/nginx/conf.d/nginx-console-limits.conf' \
	> "$PKG_DIR/lib/apk/packages/${NAME}.conffiles"

# The package metadata itself is not part of the file list.
find "$PKG_DIR" -type f,l -printf '/%P\n' | grep -v '^/lib/apk/packages/' | sort \
	> "$PKG_DIR/lib/apk/packages/${NAME}.list"

say "Building apk"

mkdir -p "$OUT_DIR"

apk mkpkg \
	--info "name:${NAME}" \
	--info "version:${PKGVER}" \
	--info "description:${DESCRIPTION}" \
	--info "arch:${ARCH}" \
	--info "license:${LICENSE}" \
	--info "origin:${ORIGIN}" \
	--info "url:${ORIGIN}" \
	--info "maintainer:${MAINTAINER}" \
	--info "depends:${DEPENDS}" \
	--script "post-install:${TEMP_DIR}/post-install" \
	--script "post-upgrade:${TEMP_DIR}/post-upgrade" \
	--script "pre-deinstall:${TEMP_DIR}/pre-deinstall" \
	--files "$PKG_DIR" \
	--output "$OUT_DIR/${NAME}-${PKGVER}.apk"

say "Built:"
ls -la "$OUT_DIR/${NAME}-${PKGVER}.apk"

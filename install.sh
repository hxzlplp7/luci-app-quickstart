#!/bin/sh
set -eu

REPO="${REPO:-hxzlplp7/luci-app-dashboard}"
VERSION="${VERSION:-latest}"
INSTALL_DIR="${INSTALL_DIR:-/tmp/luci-app-dashboard-install}"
CORE_BIN="/usr/bin/dashboard-core"
CORE_SERVICE="/etc/init.d/dashboard-core"
CORE_LISTEN="${CORE_LISTEN:-127.0.0.1:19090}"

if [ "$(id -u)" != "0" ]; then
    echo "This installer must run as root." >&2
    exit 1
fi

if [ "$VERSION" = "latest" ]; then
    BASE_URL="https://github.com/${REPO}/releases/latest/download"
else
    BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"
fi

download() {
    url="$1"
    dest="$2"
    allow_fail="${3:-0}"
    rm -f "$dest"

    if command -v curl >/dev/null 2>&1; then
        if ! curl -fL --connect-timeout 15 --retry 2 -o "$dest" "$url"; then
            rm -f "$dest"
            [ "$allow_fail" = "1" ] && return 1
            echo "Download failed: $url" >&2
            exit 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget -T 30 -O "$dest" "$url"; then
            rm -f "$dest"
            [ "$allow_fail" = "1" ] && return 1
            echo "Download failed: $url" >&2
            exit 1
        fi
    elif command -v uclient-fetch >/dev/null 2>&1; then
        if ! uclient-fetch -O "$dest" "$url"; then
            rm -f "$dest"
            [ "$allow_fail" = "1" ] && return 1
            echo "Download failed: $url" >&2
            exit 1
        fi
    else
        echo "Missing downloader: install curl, wget, or uclient-fetch." >&2
        exit 1
    fi

    if [ ! -s "$dest" ]; then
        rm -f "$dest"
        [ "$allow_fail" = "1" ] && return 1
        echo "Download failed or empty file: $url" >&2
        exit 1
    fi
}

detect_arch() {
    if [ -n "${DASHBOARD_CORE_ARCH:-}" ]; then
        printf '%s\n' "$DASHBOARD_CORE_ARCH"
        return
    fi

    if command -v opkg >/dev/null 2>&1; then
        arch="$(opkg print-architecture 2>/dev/null | awk '$2 != "all" { value=$2 } END { print value }')"
        if [ -n "$arch" ]; then
            printf '%s\n' "$arch"
            return
        fi
    fi

    case "$(uname -m 2>/dev/null || true)" in
        aarch64|arm64) printf '%s\n' "aarch64_cortex-a53" ;;
        armv7l) printf '%s\n' "arm_cortex-a7_neon-vfpv4" ;;
        mips) printf '%s\n' "mips_24kc" ;;
        mipsel) printf '%s\n' "mipsel_24kc" ;;
        x86_64) printf '%s\n' "x86_64" ;;
        *)
            echo "Cannot detect backend architecture. Set DASHBOARD_CORE_ARCH and retry." >&2
            exit 1
            ;;
    esac
}

detect_arch_candidates() {
    primary_arch="$(detect_arch)"

    case "$primary_arch" in
        aarch64_generic|aarch64|arm64)
            printf '%s\n' "$primary_arch"
            printf '%s\n' "aarch64_cortex-a53"
            ;;
        *)
            printf '%s\n' "$primary_arch"
            ;;
    esac
}

write_service() {
    cat > "$CORE_SERVICE" <<EOF
#!/bin/sh /etc/rc.common

START=90
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command $CORE_BIN --listen $CORE_LISTEN
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
    chmod 755 "$CORE_SERVICE"
}

cleanup_legacy_kmod() {
    legacy_pkg="kmod-dashboard-monitor"
    info_dir="/usr/lib/opkg/info"
    postinst="${info_dir}/${legacy_pkg}.postinst"

    if opkg status "$legacy_pkg" >/dev/null 2>&1 || [ -e "$postinst" ]; then
        echo "Detected legacy package: ${legacy_pkg}, attempting cleanup."
        [ -e "$postinst" ] && chmod 755 "$postinst" 2>/dev/null || true
        opkg configure "$legacy_pkg" >/dev/null 2>&1 || true
        opkg remove "$legacy_pkg" >/dev/null 2>&1 || true
    fi
}

ARCH=""
CORE_ASSET=""
CORE_IPK_ASSET="dashboard-core.ipk"
CORE_IPK_FILE="${INSTALL_DIR}/${CORE_IPK_ASSET}"
CORE_MODE="binary"

echo "Using release: ${VERSION}"

rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

download "${BASE_URL}/luci-app-dashboard.ipk" "${INSTALL_DIR}/luci-app-dashboard.ipk"
download "${BASE_URL}/luci-i18n-dashboard-zh-cn.ipk" "${INSTALL_DIR}/luci-i18n-dashboard-zh-cn.ipk"
if download "${BASE_URL}/${CORE_IPK_ASSET}" "${CORE_IPK_FILE}" 1; then
    CORE_MODE="ipk"
fi

cleanup_legacy_kmod

if [ "$CORE_MODE" = "ipk" ]; then
    echo "Using backend package asset: ${CORE_IPK_ASSET}"
    opkg install "${CORE_IPK_FILE}"
    chmod 755 "$CORE_BIN" 2>/dev/null || true
else
    CANDIDATE_ARCHES="$(detect_arch_candidates)"
    echo "Backend architecture candidates: $(printf '%s' "$CANDIDATE_ARCHES" | tr '\n' ' ')"

    for candidate in $CANDIDATE_ARCHES; do
        candidate_asset="dashboard-core-${candidate}"
        if download "${BASE_URL}/${candidate_asset}" "${INSTALL_DIR}/${candidate_asset}" 1; then
            ARCH="$candidate"
            CORE_ASSET="$candidate_asset"
            break
        fi
    done

    if [ -z "$CORE_ASSET" ]; then
        echo "No compatible dashboard-core asset found for candidates: ${CANDIDATE_ARCHES}" >&2
        echo "Set DASHBOARD_CORE_ARCH explicitly, then rerun installer." >&2
        exit 1
    fi

    echo "Using backend architecture: ${ARCH}"
    cp -f "${INSTALL_DIR}/${CORE_ASSET}" "$CORE_BIN"
    chmod 755 "$CORE_BIN"
fi

write_service
"$CORE_SERVICE" enable
"$CORE_SERVICE" restart

opkg install "${INSTALL_DIR}/luci-app-dashboard.ipk" "${INSTALL_DIR}/luci-i18n-dashboard-zh-cn.ipk"
"$CORE_SERVICE" restart

rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true

echo "luci-app-dashboard installed."
echo "dashboard-core is listening on ${CORE_LISTEN}."

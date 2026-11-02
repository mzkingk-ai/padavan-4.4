#!/bin/bash
# ============================================================
# build-padavan.sh — Padavan 固件一键编译脚本
#
# 本脚本随源码仓库分发，位置固定为 <仓库根>/build-padavan.sh。
# 仓库与工具链默认都从仓库根推导，因此本地和 GitHub Actions 用的是同一份脚本。
#
# 用法:
#   ./build-padavan.sh                     # 交互选择设备
#   ./build-padavan.sh RM2100              # 指定设备
#   ./build-padavan.sh NEWIFI3             # 指定设备
#   ./build-padavan.sh R2100 --dry-run     # 只演练：检查环境 + 生成 .config，不编译
#   CONTINUE=yes ./build-padavan.sh NEWIFI3 # 跳过环境检查直接编译
#   CI=1 ./build-padavan.sh RM2100         # CI 模式：无交互、不调用 sudo
#   ./build-padavan.sh --list              # 列出可编译的目标
#
# 环境变量:
#   BASE_DIR          默认基于本脚本所在目录（仓库根）自动推导
#   BUILD_DIR         仓库目录，默认 $BASE_DIR/padavan-4.4
#   TOOLCHAIN_CACHE   工具链目录，默认 $BASE_DIR/toolchain-mipsel
#   ARTIFACTS_DIR     产物归档目录，默认 $BASE_DIR/images
#   CCACHE_DIR / CCACHE_MAXSIZE   ccache 缓存位置与上限（CI 里由 actions/cache 接管）
#   GITHUB_OUTPUT     GitHub Actions 输出文件。设置后会把 product / tag / trx 写进去
#   PRODUCT           等价于第一个位置参数
#
# 退出码: 0 成功；1 编译/归档失败；2 用法错误
# ============================================================
set -euo pipefail

# ── CI 模式下禁止任何交互与 sudo ──
_is_ci() { [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; }

SRC_HINT="${BASH_SOURCE[0]:-$0}"
if [ -d "$SRC_HINT" ]; then
    SELF_DIR="$(cd "$SRC_HINT" && pwd)"
else
    SELF_DIR="$(cd "$(dirname "$SRC_HINT")" && pwd)"
fi

# 仓库根（本脚本所在目录）优先；仓库被抓取到别处时可用 BASE_DIR 覆盖。
BASE_DIR="${BASE_DIR:-$SELF_DIR}"
BUILD_DIR="${BUILD_DIR:-$BASE_DIR/padavan-4.4}"
# 兼容旧布局：脚本放在 padavan-4.4 的上一级时，自动指向下级仓库。
if [ ! -f "$BUILD_DIR/Makefile" ] && [ -f "$BASE_DIR/Makefile" ]; then
    BUILD_DIR="$BASE_DIR"
fi
REPO_KEY="mzkingk-ai"

# ── 颜色（非 TTY 或 CI 下自动关闭，避免日志里出现转义序列）──
if [ -t 1 ] && ! _is_ci; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
fi
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*" >&2; }
title() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

# ============================================================
# 参数解析
# ============================================================
list_products() {
    local td="$BUILD_DIR/trunk/configs/templates"
    title "可编译的目标（trunk/configs/templates/*.config）"
    if [ ! -d "$td" ]; then
        err "模板目录不存在: $td"
        return 1
    fi
    ls -1 "$td" | sed -n 's/\.config$//p' | sort | paste -sd' ' - | fold -s -w 100 | sed 's/^/  /'
    echo
}

# 只列出交互菜单里展示的常用机型，其余仍可用命令行 / CI 输入直接指定。
COMMON_PRODUCTS=(RM2100 NEWIFI3 R2100 K2P MI-R3G MI-4 NEWIFI DIR-878 DIR-882 MSG1500)

# ── 用法:
#   build-padavan.sh [PRODUCT] [--dry-run] [CONTINUE=yes] [--list] [--release-tag TAG] [-h]
select_device() {
    local td="$BUILD_DIR/trunk/configs/templates" choice i=0 p
    local -a shown=() tmpl=()

    printf "${CYAN}%s${NC}\n" "━━━ 选择目标设备 ━━━"
    for p in "${COMMON_PRODUCTS[@]}"; do
        if [ -f "$td/$p.config" ]; then
            i=$((i + 1))
            shown+=("$p")
            tmpl+=("$p")
            printf "  %d) %-10s %s\n" "$i" "$p" "$(grep -m1 -o '^# .*' "$td/$p.config" 2>/dev/null || true)"
        fi
    done
    if [ ${#shown[@]} -eq 0 ]; then
        err "在 $td 中找不到任何常用机型模板，请检查仓库是否完整"
        return 1
    fi
    # 默认必须是 RM2100、NEWIFI3 同时参与构建，所以交互默认用 RM2100 起手。
    echo ""
    read -p "$(echo -e "${YELLOW}请输入编号 [1-${#shown[@]}] (默认 1，即 RM2100): ${NC}")" choice || true
    choice="${choice:-1}"
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#shown[@]}" ]; then
        warn "无效选择，使用默认 RM2100"
        choice=1
    fi
    PRODUCT="${shown[$((choice - 1))]}"
    info "目标设备: $PRODUCT"
}

PRODUCT="${PRODUCT:-}"
DRY_RUN=""
RELEASE_TAG=""
for arg in "$@"; do
    case "$arg" in
        --list|-l)
            list_products
            exit $?
            ;;
        -h|--help)
            # 打印文件头注释块（从第 2 行到 `set -euo pipefail` 之前）
            sed -n '2,/^set -euo pipefail/{/^set -euo pipefail/d;p;}' "${BASH_SOURCE[0]:-$0}" \
                | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        --release-tag=*)
            RELEASE_TAG="${arg#--release-tag=}"
            ;;
        CONTINUE=*)
            CONTINUE=yes
            ;;
        -*)
            err "未知参数: $arg（用 -h 查看用法）"
            exit 2
            ;;
        *)
            if [ -z "$PRODUCT" ]; then
                PRODUCT="$arg"
            else
                err "只能指定一个目标，多余参数: $arg"
                exit 2
            fi
            ;;
    esac
done

if [ -z "$PRODUCT" ]; then
    if _is_ci; then
        err "CI 模式下必须显式给出目标设备"
        exit 2
    fi
fi

# 显式给出的目标必须真的有模板，否则早点报错，别等编了半小时才发现
if [ -n "$PRODUCT" ]; then
    if ! [[ "$PRODUCT" =~ ^[A-Za-z0-9._-]+$ ]]; then
        err "非法的目标名: $PRODUCT"
        exit 2
    fi
    if [ ! -f "$BUILD_DIR/trunk/configs/templates/${PRODUCT}.config" ]; then
        err "模板不存在: $BUILD_DIR/trunk/configs/templates/${PRODUCT}.config"
        warn "可用目标见: $0 --list"
        exit 2
    fi
fi

ARTIFACTS_DIR="${ARTIFACTS_DIR:-$BASE_DIR/images}"
PRODUCT="${PRODUCT:-}"

# ============================================================
# 检查仓库
# ============================================================
check_repo() {
    title "检查仓库"
    if [ ! -d "$BUILD_DIR" ] || [ ! -f "$BUILD_DIR/Makefile" ]; then
        err "仓库目录不存在或不完整: $BUILD_DIR"
        exit 1
    fi
    cd "$BUILD_DIR"
    info "仓库: $BUILD_DIR"
    if [ -n "${GITHUB_SHA:-}" ]; then
        info "提交: ${GITHUB_SHA:0:12}"
    else
        git remote -v 2>/dev/null | head -1 || warn "未配置远程仓库，仅本地编译"
    fi
}

# ============================================================
# 工具链检查
# ============================================================
TOOLCHAIN_CACHE="${TOOLCHAIN_CACHE:-$BASE_DIR/toolchain-mipsel}"
TOOLCHAIN_URL="https://github.com/hanwckf/padavan-toolchain/releases/download/linux-4.4-v1.0/mipsel-linux-uclibc.tar.xz"
TOOLCHAIN_GCC="$TOOLCHAIN_CACHE/toolchain-4.4.x/bin/mipsel-linux-uclibc-gcc"

check_toolchain() {
    title "检查工具链"
    if [ ! -f "$TOOLCHAIN_GCC" ]; then
        warn "工具链未安装，正在下载..."
        mkdir -p "$TOOLCHAIN_CACHE"
        if ! curl -fL --retry 3 --retry-delay 5 -o /tmp/tc.tar.xz "$TOOLCHAIN_URL"; then
            err "工具链下载失败: $TOOLCHAIN_URL"
            return 1
        fi
        tar -xf /tmp/tc.tar.xz -C "$TOOLCHAIN_CACHE"
        rm -f /tmp/tc.tar.xz
        # 解压后验证目录结构
        if [ ! -d "$TOOLCHAIN_CACHE/toolchain-4.4.x/bin" ]; then
            # 可能是直接解压到了根目录，需要整理
            local tmpd
            tmpd="$(mktemp -d)"
            mv "$TOOLCHAIN_CACHE"/* "$tmpd/" 2>/dev/null || true
            mkdir -p "$TOOLCHAIN_CACHE/toolchain-4.4.x"
            mv "$tmpd"/* "$TOOLCHAIN_CACHE/toolchain-4.4.x/" 2>/dev/null || true
            rm -rf "$tmpd"
        fi
    fi
    if [ ! -f "$TOOLCHAIN_GCC" ]; then
        err "工具链解压后仍找不到 $TOOLCHAIN_GCC"
        return 1
    fi
    local gcc_ver
    gcc_ver="$("$TOOLCHAIN_GCC" --version 2>&1 | head -1)"
    info "工具链: $gcc_ver"

    # 仓库内创建 toolchain-mipsel → $TOOLCHAIN_CACHE 的 symlink
    local repo_tc="$BUILD_DIR/toolchain-mipsel"
    if [ ! -L "$repo_tc" ] && [ ! -d "$repo_tc/toolchain-4.4.x/bin" ]; then
        if [ -d "$repo_tc" ]; then
            rm -rf "$repo_tc"
        fi
        ln -sf "$TOOLCHAIN_CACHE" "$repo_tc"
        info "  ✓ 仓库 toolchain-mipsel → $TOOLCHAIN_CACHE"
    fi
}

# ============================================================
# SSP stub
# ============================================================
setup_ssp_stubs() {
    title "SSP stub 检查"
    local sysroot="$TOOLCHAIN_CACHE/toolchain-4.4.x/mipsel-linux-uclibc/sysroot"
    local gcc="$TOOLCHAIN_GCC"
    local ar="$TOOLCHAIN_CACHE/toolchain-4.4.x/bin/mipsel-linux-uclibc-ar"
    local nm="$TOOLCHAIN_CACHE/toolchain-4.4.x/bin/mipsel-linux-uclibc-nm"

    if [ -f "$sysroot/lib/libssp_nonshared.a" ] && \
       "$nm" "$sysroot/lib/libssp_nonshared.a" 2>/dev/null | grep -q "__stack_chk_guard"; then
        info "SSP stubs 已存在，跳过"
        return 0
    fi
    warn "创建 SSP stub 库（工具链 --disable-libssp）..."
    if ! mkdir -p "$sysroot/lib" 2>/dev/null; then
        # CI 中工具链解压在 $GITHUB_WORKSPACE 下，属主是 runner，无需 sudo
        err "无法写入 sysroot: $sysroot/lib"
        return 1
    fi
    local tmpd
    tmpd="$(mktemp -d)"
    cat > "$tmpd/ssp_stub.c" << 'EOF'
void __stack_chk_fail(void) { while(1); }
unsigned long __stack_chk_guard = 0;
EOF
    "$gcc" -c -o "$tmpd/ssp_stub.o" "$tmpd/ssp_stub.c"
    "$ar" rcs "$sysroot/lib/libssp_nonshared.a" "$tmpd/ssp_stub.o"
    "$ar" rcs "$sysroot/lib/libssp.a" "$tmpd/ssp_stub.o"
    rm -rf "$tmpd"
    info "SSP stubs 创建完成"
}

# ============================================================
# 依赖检查
# ============================================================
check_deps() {
    title "检查宿主依赖"
    local -a missing=() need_sudo=()
    local cmd
    for cmd in bc ccache go perl curl wget gcc g++ make cmake bison flex gawk; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    # aclocal / automake 的版本别名要能在 /usr/bin 或 PATH 上落地
    if [ ! -w /usr/bin ] && [ -z "${HOME:-}" ]; then
        err "无法在 /usr/bin 写入自动工具别名，且 HOME 不可用"
        return 1
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        if _is_ci; then
            # CI 中由 workflow 统一 apt 安装，脚本不再尝试提权
            err "CI 缺少依赖: ${missing[*]}（请检查 workflow 的安装步骤）"
            return 1
        fi
        warn "缺失依赖: ${missing[*]}。尝试安装..."
        SUDO=""
        if [ "$(id -u)" -ne 0 ]; then
            SUDO="sudo"
        fi
        # shellcheck disable=SC2086
        $SUDO apt-get update -qq
        # shellcheck disable=SC2086
        DEBIAN_FRONTEND=noninteractive $SUDO apt-get -y install --no-install-recommends \
            bc ccache perl curl wget cmake bison flex gawk gcc g++ make \
            unzip libtool-bin gperf nano fakeroot cpio git gettext automake autopoint \
            texinfo help2man pkg-config zlib1g-dev libgmp-dev libmpc-dev libmpfr-dev \
            libncurses-dev libltdl-dev libssl-dev xz-utils ca-certificates python3-docutils 2>&1 | tail -1
    fi
    info "依赖检查通过"
}

# ============================================================
# 编译前修复
# ============================================================
pre_build_fix() {
    title "编译前修复"
    local trunk_dir="$BUILD_DIR/trunk"
    local cfg="$trunk_dir/configs/templates/${PRODUCT}.config"

    # ── autotools 兼容性：某些包的 Makefile 需要特定版本的 aclocal/automake ──
    # /usr/bin 可写时直接建软链；不可写（容器内普通用户）时改为 PATH 上级的包装脚本。
    local _at_local=""
    local prog src ver
    for prog in aclocal automake; do
        src="$(command -v "$prog" 2>/dev/null)" || continue
        [ -n "$src" ] || continue
        for ver in 1.16 1.17; do
            if [ -w /usr/bin ] 2>/dev/null; then
                [ ! -e "/usr/bin/${prog}-${ver}" ] && ln -sf "$src" "/usr/bin/${prog}-${ver}" 2>/dev/null || true
            elif [ ! -e "${_at_local:-/nonexistent}/${prog}-${ver}" ]; then
                _at_local="$HOME/.local/bin"
                mkdir -p "$_at_local"
                printf '#!/bin/sh\nexec "%s" "$@"\n' "$src" > "$_at_local/${prog}-${ver}"
                chmod +x "$_at_local/${prog}-${ver}"
            fi
        done
    done
    if [ -n "$_at_local" ]; then
        export PATH="$_at_local:$PATH"
        info "  ✓ autotools 版本别名 (${_at_local}/aclocal-1.16 …)"
    fi

    # ── 1. 检查模板是否存在 ──
    if [ ! -f "$cfg" ]; then
        err "模板不存在: $cfg"
        return 1
    fi

    # ── 2. 检查 toolchain-mipsel symlink ──
    local repo_tc="$BUILD_DIR/toolchain-mipsel"
    if [ ! -L "$repo_tc" ]; then
        if [ -d "$repo_tc" ]; then
            rm -rf "$repo_tc"
        fi
        ln -sf "$TOOLCHAIN_CACHE" "$repo_tc"
        info "  ✓ 创建 toolchain-mipsel symlink"
    fi

    # ── 3. 检查 SSP stubs（本地已在 check 阶段做过，CI 下同样幂等）──
    local sysroot="$TOOLCHAIN_CACHE/toolchain-4.4.x/mipsel-linux-uclibc/sysroot"
    if [ ! -f "$sysroot/lib/libssp_nonshared.a" ]; then
        setup_ssp_stubs
    fi

    # ── 4. 配置文件修复 ──
    # 修正 TOOLCHAIN_DIR 路径（适配新版本 buildroot）
    if grep -q 'CONFIG_TOOLCHAIN_DIR.*toolchain-mipsel.crosstool-ng' "$cfg" 2>/dev/null; then
        sed -i 's|CONFIG_TOOLCHAIN_DIR=.*|CONFIG_TOOLCHAIN_DIR=$(TOOLCHAIN_DIR)|' "$cfg"
        info "  ✓ 修复 CONFIG_TOOLCHAIN_DIR"
    fi

    # ── 5. 功能裁剪（模板存在时才做）──
    if [ -f "$cfg" ]; then
        # 禁用 IPv6（128M 固件节省空间）
        sed -i 's/CONFIG_FIRMWARE_ENABLE_IPV6=y/CONFIG_FIRMWARE_ENABLE_IPV6=n/' "$cfg" 2>/dev/null || true
        # 禁用 MentoHUST（校园网客户端）
        sed -i 's/CONFIG_FIRMWARE_INCLUDE_MENTOHUST=y/CONFIG_FIRMWARE_INCLUDE_MENTOHUST=n/' "$cfg" 2>/dev/null || true
        # 禁用 EAP-PEAP（企业级 WiFi，节省 openssl）
        sed -i 's/CONFIG_FIRMWARE_INCLUDE_EAP_PEAP=y/CONFIG_FIRMWARE_INCLUDE_EAP_PEAP=n/' "$cfg" 2>/dev/null || true
        # 禁用 VLMCSD（UDP  multicast to HTTP）
        sed -i 's/CONFIG_FIRMWARE_INCLUDE_VLMCSD=y/CONFIG_FIRMWARE_INCLUDE_VLMCSD=n/' "$cfg" 2>/dev/null || true
        # 开启 tcpdump（调试用）
        sed -i 's/CONFIG_FIRMWARE_INCLUDE_TCPDUMP=n/CONFIG_FIRMWARE_INCLUDE_TCPDUMP=y/' "$cfg" 2>/dev/null || true
        # 开启 HTTPS（Web 管理界面）
        sed -i 's/CONFIG_FIRMWARE_INCLUDE_HTTPS=n/CONFIG_FIRMWARE_INCLUDE_HTTPS=y/' "$cfg" 2>/dev/null || true
        # 开启 openssl 可执行文件
        sed -i 's/CONFIG_FIRMWARE_INCLUDE_OPENSSL_EXE=n/CONFIG_FIRMWARE_INCLUDE_OPENSSL_EXE=y/' "$cfg" 2>/dev/null || true
        # 开启 OpenSSH 替代 dropbear（支持 SCP/SFTP）
        sed -i 's/CONFIG_FIRMWARE_INCLUDE_DROPBEAR=y/CONFIG_FIRMWARE_INCLUDE_DROPBEAR=n/' "$cfg" 2>/dev/null || true
        sed -i 's/CONFIG_FIRMWARE_INCLUDE_OPENSSH=n/CONFIG_FIRMWARE_INCLUDE_OPENSSH=y/' "$cfg" 2>/dev/null || true
        sed -i 's/CONFIG_FIRMWARE_INCLUDE_SFTP=n/CONFIG_FIRMWARE_INCLUDE_SFTP=y/' "$cfg" 2>/dev/null || true
        # 开启 USB 支持（httpd 编译需要 USB 相关函数）
        sed -i 's/CONFIG_FIRMWARE_ENABLE_USB=n/CONFIG_FIRMWARE_ENABLE_USB=y/' "$cfg" 2>/dev/null || true
        # 关闭 SmartDNS（DNS 交由 ShellCrash/dnsmasq 处理；路由器上装的是自行编译的 48.4 版）
        # 键名被改掉时 s/=y/=n/ 会静默失效，故下面单独校验一次。
        sed -i 's/^CONFIG_FIRMWARE_INCLUDE_SMARTDNS=.*$/CONFIG_FIRMWARE_INCLUDE_SMARTDNS=n/' "$cfg" 2>/dev/null || true
        if grep -qE '^CONFIG_FIRMWARE_INCLUDE_SMARTDNS=n' "$cfg" 2>/dev/null; then
            info "  ✓ 已关闭 SmartDNS"
        else
            warn "CONFIG_FIRMWARE_INCLUDE_SMARTDNS 未能置 n（模板键名可能已变，请检查 $cfg）"
        fi
        info "  ✓ 功能裁剪 (IPv6/EAP-PEAP/VLMCSD/SmartDNS -> 启用 tcpdump/HTTPS/openssl-exe/OpenSSH)"

        # ── 组件裁剪：关闭可选的 NAS/下载/终端类插件 ──
        # 只处理「模板开关就能控制」的项，且每项关闭前先确认真实生效，否则报警。
        # 已知关闭后会连带的依赖（由 libs/Makefile 的条件块自动处理，无需干预）：
        #   ARIA=n  → LIBS_INCLUDE_LIBXML2 条件不成立 → 不再编 libxml2（libs/Makefile:83-85,214）
        #   TTYD=n  → LIBS_INCLUDE_LIBWEBSOCKETS=n → libwebsockets 及 libuv 不再编译
        #             （libs/Makefile:59-62 与 98-100）
        # 注意：CONFIG_FIRMWARE_INCLUDE_CIFS 虽是模板项，但全仓库没有任何地方读取它
        #       （configure / user/Makefile / libs/Makefile 均不引用），内核里也早已是
        #       "# CONFIG_CIFS is not set"，属纯占位开关，改它不会有任何效果，故不处理。
        # 判定标准必须是「已是 =n」，而不是「找不到 =y」——键名被改掉时后者会误报成功。
        local _off_list="ARIA ARIA_WEB_CONTROL XUPNPD FTPD TTYD"
        local _off_item _off_n=0 _off_bad=""
        for _off_item in $_off_list; do
            sed -i "s/^CONFIG_FIRMWARE_INCLUDE_${_off_item}=y/CONFIG_FIRMWARE_INCLUDE_${_off_item}=n/" "$cfg" 2>/dev/null || true
            if grep -qE "^CONFIG_FIRMWARE_INCLUDE_${_off_item}=n" "$cfg" 2>/dev/null; then
                _off_n=$((_off_n + 1))
            else
                _off_bad="$_off_bad $_off_item"
            fi
        done
        if [ -n "$_off_bad" ]; then
            warn "以下开关未能置 n（模板键名可能已变，请检查）:$_off_bad"
        fi
        info "  ✓ 已关闭 ${_off_n}/5 项可选组件: ${_off_list}（连带裁掉 libxml2 / libwebsockets / libuv）"
        # 连带件自检：ARIA/TTYD 关闭后，这两个库不应再进入构建
        if grep -qE '^CONFIG_FIRMWARE_INCLUDE_ARIA=y' "$cfg" 2>/dev/null; then
            warn "ARIA 仍为 y，libxml2 会继续被编译"
        fi

        # ── 网易云音乐解锁插件 (UnblockNeteaseMusic, Go + UPX) ──
        # 单开关 CONFIG_FIRMWARE_INCLUDE_WYYBIN 串起整条链路：
        #   user/Makefile:193      → 编 unblockneteasemusic 包（Go mipsle + upx，~1.7MB）
        #   cflags.mk:215-216      → rc/httpd 定义 -DAPP_WYYBIN
        #   www/Makefile:221-222   → WYYBIN!=y 时删除 Advanced_wyybin.asp 页面
        # 运行期再由 nvram 的 wyybin_enable 控制启停（services.c:580 / autostart.sh:92），
        # 所以这里只需保证「编进固件」，页面开关另管运行状态。
        # 判定用「已是 =y」而非「找不到 =n」，避免键名被改后误报成功。
        if grep -qE '^CONFIG_FIRMWARE_INCLUDE_WYYBIN=' "$cfg" 2>/dev/null; then
            sed -i 's/^CONFIG_FIRMWARE_INCLUDE_WYYBIN=.*$/CONFIG_FIRMWARE_INCLUDE_WYYBIN=y/' "$cfg"
            if grep -qE '^CONFIG_FIRMWARE_INCLUDE_WYYBIN=y' "$cfg" 2>/dev/null; then
                info "  ✓ 已启用 UnblockNeteaseMusic 插件 (WYYBIN=y，含 Advanced_wyybin.asp 页面)"
            else
                warn "WYYBIN 未能置 y（模板该行可能有异常，请检查 $cfg）"
            fi
        else
            warn "模板中缺少 CONFIG_FIRMWARE_INCLUDE_WYYBIN，网易云插件不会被编入"
        fi

        # 同名服务的旧开关 (ADGUARDHOME 等会抢 53 端口) 保持模板原值，不额外干预。

        # 语言包：模板本身只启用 CN，其余 12 种已是注释状态，先核实一遍。
        local _lang_extra
        _lang_extra="$(grep -E '^CONFIG_FIRMWARE_INCLUDE_LANG_[A-Z]+=y' "$cfg" 2>/dev/null \
                       | grep -v 'CONFIG_FIRMWARE_INCLUDE_LANG_CN=y' || true)"
        if [ -n "$_lang_extra" ]; then
            warn "模板额外启用了语言包（如需精简请改为注释）:"
            echo "$_lang_extra" | sed 's/^/      /'
        else
            info "  ✓ 语言包仅 CN.dict，无多余语言包可关"
        fi

        # ── NEWIFI3 专用适配 ──
        # 2026-08-21: 恢复文件系统支持（之前为了跳过 e2fsprogs/dosfstools 编译
        # 问题禁用了 EXT/FAT，导致 U 盘无法挂载。两个包已含 autoreconf 修复。）
        if [ "$PRODUCT" = "NEWIFI3" ]; then
            # 禁用 FULLCONENAT（与 NF_CONNTRACK_EVENTS 冲突）
            local kcfg="$trunk_dir/configs/boards/NEWIFI3/kernel-4.4.x.config"
            sed -i 's/CONFIG_NETFILTER_XT_TARGET_FULLCONENAT=y/# CONFIG_NETFILTER_XT_TARGET_FULLCONENAT is not set/' "$kcfg" 2>/dev/null || true
            # 启用 NTFS-3G 用户态 NTFS 驱动
            sed -i 's/CONFIG_FIRMWARE_INCLUDE_NTFS_3G=n/CONFIG_FIRMWARE_INCLUDE_NTFS_3G=y/' "$cfg" 2>/dev/null || true
            # 关闭翻墙/代理类组件（xray / shadowsocks / trojan）
            # 模板里 SHADOWSOCKS 出现两次（SSP 段 + Include Shadowsocks 段），必须全部置 n。
            # 只有 SHADOWSOCKS=n 时，user/Makefile:143 的嵌套块才会一起关掉
            # xraymin / trojan / v2ray / simple-obfs 以及 skipdbv2 / chinadns-ng /
            # lua51 / ipt2socks / resolveip / dns2tcp / dnsproxy / chnroute 等配套件。
            sed -i 's/^CONFIG_FIRMWARE_INCLUDE_XRAY=y/CONFIG_FIRMWARE_INCLUDE_XRAY=n/' "$cfg" 2>/dev/null || true
            sed -i 's/^CONFIG_FIRMWARE_INCLUDE_SHADOWSOCKS=y/CONFIG_FIRMWARE_INCLUDE_SHADOWSOCKS=n/' "$cfg" 2>/dev/null || true
            sed -i 's/^CONFIG_FIRMWARE_INCLUDE_TROJAN=y/CONFIG_FIRMWARE_INCLUDE_TROJAN=n/' "$cfg" 2>/dev/null || true
            local _left
            _left="$(grep -E '^CONFIG_FIRMWARE_INCLUDE_(XRAY|SHADOWSOCKS|TROJAN|V2RAY|SSOBFS|SSSERVER|WING)=y' "$cfg" 2>/dev/null || true)"
            if [ -n "$_left" ]; then
                warn "以下代理项仍为 y（模板可能改了键名，请检查）:"
                echo "$_left" | sed 's/^/      /'
            else
                info "  ✓ NEWIFI3: 已关闭 XRAY / SHADOWSOCKS / TROJAN（及配套 xraymin/trojan/v2ray）"
            fi

            info "  ✓ NEWIFI3: 启用文件系统 (FAT/EXT2/3/4) + NTFS-3G 完整版 + 禁用 FULLCONENAT"
        fi
    fi
}

# ============================================================
# 生成 .config（等同 `make <PRODUCT>` 的前置步骤）
# ============================================================
gen_config() {
    local trunk_dir="$BUILD_DIR/trunk"
    local cfg="$trunk_dir/.config"

    # 切换编译目标时必须清掉旧的 .config，否则会沿用上一个机型的设置
    rm -f "$cfg"
    cp -f "$trunk_dir/configs/templates/${PRODUCT}.config" "$cfg"

    # 与顶层 Makefile 的 $(PRODUCTS) 目标保持一致的三行追加
    { echo "CONFIG_TOOLCHAIN_DIR=$BUILD_DIR/toolchain-mipsel";
      echo "CONFIG_CROSS_COMPILER_ROOT=$TOOLCHAIN_CACHE/toolchain-4.4.x";
      echo "CONFIG_CCACHE=y"; } >> "$cfg"

    # 工具链软链不存在时先建好，否则 CONFIG_CROSS_COMPILER_ROOT 解析不到
    if [ ! -e "$BUILD_DIR/toolchain-mipsel/toolchain-4.4.x/bin" ]; then
        ln -sfn "$TOOLCHAIN_CACHE" "$BUILD_DIR/toolchain-mipsel"
    fi

    info "  ✓ 已生成 trunk/.config（来自 ${PRODUCT}.config，${PRODUCT}）"
}

# ============================================================
# 开始编译
# ============================================================
do_build() {
    title "开始编译: $PRODUCT"

    # ── 刷新固件版本号：强制重编版本相关包 ──
    # GNU make 不检测 -DFWREVSTR 编译参数变化，增量编译时旧 .o 缓存
    # 会让固件版本日期停留在首次编译日。删除这些包的 .o 强制重编。
    local ver_pkgs=(
        "$BUILD_DIR/trunk/user/rc"
        "$BUILD_DIR/trunk/user/httpd"
        "$BUILD_DIR/trunk/user/shared"
    )
    local pkg
    for pkg in "${ver_pkgs[@]}"; do
        if [ -d "$pkg" ]; then
            find "$pkg" -name "*.o" -delete 2>/dev/null || true
        fi
    done
    info "  ✓ 刷新固件版本号 (rc/httpd/shared 强制重编, 日期=$(TZ=Asia/Shanghai date +%Y%m%d))"

    # ── NEWIFI3 编译前：WAN 百兆补丁已移除 ──
    # 原逻辑在 eth3 初始化后注入 mii_mgr 强制百兆（绕过 C48 电容干扰），
    # 现在保留硬件协商结果，不再改写 net_wan.c。
    if [ "$PRODUCT" = "NEWIFI3" ]; then
        info "  ✓ NEWIFI3: 跳过 WAN 百兆补丁（net_wan.c 保持原样）"
    fi

    cd "$BUILD_DIR"
    local rc=0
    # `|| rc=$?` 与 if 语境等价，避免 set -e 在 make 失败时直接退出，
    # 导致下面的还原逻辑和失败提示被跳过。
    make "$PRODUCT" || rc=$?

    # ── NEWIFI3 编译后：还原源码修改 ──
    # 只在 .bak 真的存在时才还原：WAN 百兆补丁已移除，无条件 mv 会让
    # 脚本以 mv 的失败码退出，从而跳过后面的产物归档。
    if [ "$PRODUCT" = "NEWIFI3" ] && [ -f "$BUILD_DIR/trunk/user/rc/net_wan.c.bak" ]; then
        mv -f "$BUILD_DIR/trunk/user/rc/net_wan.c.bak" "$BUILD_DIR/trunk/user/rc/net_wan.c"
    fi

    if [ "$rc" -ne 0 ]; then
        err "编译失败（make 退出码 $rc）"
        warn "常见原因：宿主依赖缺失（bc/ccache/go）、Go 版本非 1.22、autotools 别名缺失、磁盘空间不足"
        return "$rc"
    fi
    return 0
}

# ============================================================
# 产物归档 —— 默认落到 <仓库根>/images
# ============================================================
# 仓库根就是本脚本所在目录；CI 中它就是 $GITHUB_WORKSPACE，所以归档目录
# 与 trunk/images 在同一个工作区内，不依赖任何宿主机绝对路径。
# 需要改到别处时才用环境变量覆盖：ARTIFACTS_DIR=/x/y ./build-padavan.sh NEWIFI3
show_artifacts() {
    local images_dir="$BUILD_DIR/trunk/images"

    local latest
    latest=$(ls -t "$images_dir/"*.trx 2>/dev/null | head -1 || true)
    if [ -z "$latest" ]; then
        err "trunk/images/ 下无 .trx 文件，构建未产出固件"
        return 1
    fi

    local ts base archived
    # 容器内 TZ 是 UTC、宿主是 +08:00，同一瞬间会差 8 小时。
    # 这里固定用 Asia/Shanghai 生成文件名，保证宿主/容器/CI 三处命名口径一致。
    ts=$(TZ=Asia/Shanghai date +%Y%m%d%H%M)
    base=$(basename "$latest" .trx)
    # 归档命名示例: NEWIFI3_4.4.198.9-100_mzkingk-ai_202610300039.trx
    archived="${ARTIFACTS_DIR}/${base}_${REPO_KEY}_${ts}.trx"

    echo ""
    title "归档产物 → ${ARTIFACTS_DIR}"

    if ! mkdir -p "$ARTIFACTS_DIR"; then
        err "无法创建归档目录: $ARTIFACTS_DIR"
        return 1
    fi

    local sum_src size_src size_dst
    sum_src=$(sha256sum "$latest" | cut -d' ' -f1)

    # 归档目录里已有完全相同的产物（sha256 一致）就复用，不重复占空间。
    local dup=""
    dup=$(cd "$ARTIFACTS_DIR" && sha256sum -- *.trx 2>/dev/null | grep -F "$sum_src" | head -1 | cut -d' ' -f3- || true)

    if [ -n "$dup" ]; then
        archived="$ARTIFACTS_DIR/$dup"
        info "  ✓ 归档中已有相同产物，跳过拷贝: $dup"
    else
        if ! cp -f "$latest" "$archived"; then
            err "拷贝失败: $latest -> $archived"
            return 1
        fi
        size_src=$(stat -c %s "$latest")
        size_dst=$(stat -c %s "$archived")
        if [ "$size_src" != "$size_dst" ]; then
            err "拷贝后大小不一致（${size_src} != ${size_dst}）"
            return 1
        fi
        info "  ✓ 已拷贝: $(basename "$archived")  (${size_dst} 字节)"
    fi

    echo ""
    title "构建产物"
    echo "  产品:     $PRODUCT"
    echo "  固件:     $latest"
    echo "  大小:     $(du -h "$latest" | cut -f1)"
    echo "  SHA256:   $sum_src"
    echo "  归档:     $archived"
    echo "  归档目录: $ARTIFACTS_DIR  （现有 .trx: $(ls -1 "$ARTIFACTS_DIR/"*.trx 2>/dev/null | wc -l) 个）"
    echo "  刷机用:   归档那份（trunk/images/ 会被 make clean 清掉）"
    echo ""

    # ── 供 CI 取用的单行记录（本地跑也无害）──
    local rel_tag="${RELEASE_TAG:-$(TZ=Asia/Shanghai date +%Y%m%d)}"
    printf 'PRODUCT=%s\n'  "$PRODUCT"
    printf 'VERSION=%s\n'  "$rel_tag"
    printf 'TRX=%s\n'      "$archived"
    printf 'SHA256=%s\n'   "$sum_src"

    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        {
            echo "product=$PRODUCT"
            echo "version=$rel_tag"
            echo "trx=$archived"
            echo "trx_name=$(basename "$archived")"
            echo "sha256=$sum_src"
            echo "size=$(stat -c %s "$archived")"
        } >> "$GITHUB_OUTPUT"
    fi

    info "编译完成！"
    return 0
}

# ============================================================
# 主流程
# ============================================================
main() {
    if [ -z "$PRODUCT" ]; then
        select_device
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " Padavan 固件编译脚本"
    echo " 产品: ${PRODUCT}"
    echo " 仓库: ${BUILD_DIR}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # 无论是否 CONTINUE=yes，这几步都必须做：没有工具链和 .config 就编不了。
    # 之前 pre_build_fix 被调用两次（检查分支里一次、分支外一次），
    # 连 CONTINUE=yes 时也会重跑，这里修正为只调用一次。
    if [ -z "${CONTINUE:-}" ]; then
        check_repo
        check_toolchain
        setup_ssp_stubs
        check_deps
    else
        info "CONTINUE=yes，跳过环境检查..."
    fi

    check_toolchain
    pre_build_fix
    gen_config

    if [ -n "$DRY_RUN" ]; then
        title "dry-run：已完成环境检查与 .config 生成，跳过编译"
        grep -E '^CONFIG_(FIRMWARE_(INCLUDE_(HTTPS|OPENSSH|TCPDUMP|WYYBIN|NTFS_3G|XRAY|SHADOWSOCKS|TROJAN|ARIA|TTYD))|TOOLCHAIN_DIR|CROSS_COMPILER_ROOT)' \
            "$BUILD_DIR/trunk/.config" | sed 's/^/  /' || true
        info "dry-run 结束"
        return 0
    fi

    do_build
    show_artifacts
}

main "$@"

#!/bin/bash
# Docker（dockerd 引擎 / docker CLI / LuCI dockerman）打包修复。
# 可独立拷到其它 OpenWrt / OpenWRT-CI 仓库使用，在源码树根目录执行：
#
#   sh docker-fixes.sh
#
# 做的事情：
#   1. LuCI dockerman 去重：存在自维护的 luci-app-dockerman（如
#      package/luci-app-dockerman，由 Packages.sh 从 ysuolmai 仓库拉取）时
#      清掉 feeds 里的同名包；不存在则保留原有版本。dockerd 同理，优先用
#      自维护的 nftables 原生版本，避免 feeds 版把 xtables 依赖带进固件。
#   2. luci-lib-docker 统一用 lisaac/luci-lib-docker。
#   3. 去掉 luci-app-dockerman / luci-lib-docker 版本号里的 v 前缀，
#      apk 只接受以数字开头的版本号（opkg 没这个限制）。
#   4. dockerd / docker CLI 版本跟随 moby/moby 最新 release，并修补
#      PKG_GIT_SHORT_COMMIT、PKG_HASH、Build/Prepare、vendor 目录安装。
#   5. 给 include/cmake.mk 补 CMAKE_POLICY_VERSION_MINIMUM（部分依赖包
#      cmake_minimum_required 低于 3.5，新版 cmake 会直接报错）。

set -u

log() { echo "[docker] $*"; }

if [ ! -d package ] || [ ! -d feeds ]; then
    log "当前目录不是 OpenWrt 源码树"
    exit 1
fi

# ===============================================================
# 1. LuCI dockerman
# ===============================================================
MANAGED_DOCKERMAN=$(find package -maxdepth 3 -type d -name 'luci-app-dockerman' \
    -not -path 'package/feeds/*' 2>/dev/null | head -n 1)
if [ -n "$MANAGED_DOCKERMAN" ] && [ -f "$MANAGED_DOCKERMAN/Makefile" ]; then
    rm -rf package/feeds/luci/luci-app-dockerman
    log "使用自维护的 luci-app-dockerman: $MANAGED_DOCKERMAN"
else
    log "未发现自维护 luci-app-dockerman，保留现有版本"
fi

# ===============================================================
# 1.1 dockerd：优先用自维护的 nftables 原生版本
#     feeds 版 dockerd 的 DEPENDS 带 +iptables / +iptables-mod-extra /
#     +kmod-ipt-nat / +kmod-ipt-nat6 / +kmod-ipt-physdev，会把整套
#     xtables 拉进固件；自维护版只依赖 firewall4 / nftables-json。
#     两处同名包同时存在时扫描会选中 feeds 那份，所以这里删掉 feeds 副本。
# ===============================================================
MANAGED_DOCKERD=$(find package -maxdepth 3 -type d -name dockerd \
    -not -path 'package/feeds/*' 2>/dev/null | head -n 1)
if [ -n "$MANAGED_DOCKERD" ] && [ -f "$MANAGED_DOCKERD/Makefile" ]; then
    rm -rf package/feeds/*/dockerd
    log "使用自维护 dockerd: $MANAGED_DOCKERD（已移除 feeds 同名副本）"
else
    log "未发现自维护 dockerd，继续使用 feeds 版本"
fi

# ===============================================================
# 2. luci-lib-docker（dockerman 的依赖库，feeds 版本过旧）
# ===============================================================
rm -rf package/feeds/luci/luci-lib-docker
rm -rf package/luci-lib-docker

log "克隆 lisaac/luci-lib-docker"
if ! git clone --depth 1 https://github.com/lisaac/luci-lib-docker.git temp_libdocker; then
    log "克隆 luci-lib-docker 失败"
    exit 1
fi
if [ -d "temp_libdocker/collections/luci-lib-docker" ]; then
    mv temp_libdocker/collections/luci-lib-docker package/luci-lib-docker || exit 1
else
    mv temp_libdocker package/luci-lib-docker || exit 1
fi
rm -rf temp_libdocker

./scripts/feeds install luci-lib-docker || log "luci-lib-docker 不在 feeds 中，使用本地目录"

# ===============================================================
# 3. 版本号规范化：apk 要求版本号以数字开头
#    luci-app-dockerman 是 v0.5.26，lisaac 的 luci-lib-docker 是 v0.3.4，
#    opkg 能接受这种写法，apk 会直接报 "package version is invalid"。
# ===============================================================
for makefile in $(find package -maxdepth 3 -type f -name Makefile \
        \( -path '*luci-app-dockerman*' -o -path '*luci-lib-docker*' \) 2>/dev/null); do
    if grep -q '^PKG_VERSION:=v' "$makefile"; then
        sed -i 's/^PKG_VERSION:=v/PKG_VERSION:=/' "$makefile"
        log "去掉版本号前缀 v: $makefile"
    fi
done

# ===============================================================
# 4. dockerd 引擎 / docker CLI 版本对齐 moby 最新 release
# ===============================================================
log "查询 moby/moby 最新 release"
_MOBY_TAG=$(curl -sf https://api.github.com/repos/moby/moby/releases/latest | \
    python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null || true)
DOCKER_VER=$(echo "$_MOBY_TAG" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)

if [ -z "$DOCKER_VER" ]; then
    log "警告: 无法获取 Docker 最新版本，回退到已验证的 29.9.2"
    DOCKER_VER="29.9.2"
    DOCKERD_COMMIT="0367cbe"
    DOCKER_CLI_COMMIT="a82e528"
else
    log "最新 Docker 版本: $DOCKER_VER (tag: $_MOBY_TAG)"
    DOCKERD_COMMIT=$(curl -sf "https://api.github.com/repos/moby/moby/commits?sha=${_MOBY_TAG}&per_page=1" | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['sha'][:7] if isinstance(d,list) and d else '')" 2>/dev/null || true)
    DOCKER_CLI_COMMIT=$(curl -sf "https://api.github.com/repos/docker/cli/commits?sha=v${DOCKER_VER}&per_page=1" | \
        python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['sha'][:7] if isinstance(d,list) and d else '')" 2>/dev/null || true)
    if [ -z "$DOCKERD_COMMIT" ] || [ -z "$DOCKER_CLI_COMMIT" ]; then
        log "警告: 无法获取 commit hash，回退到已验证的 29.9.2 commit"
        DOCKER_VER="29.9.2"
        DOCKERD_COMMIT="0367cbe"
        DOCKER_CLI_COMMIT="a82e528"
    fi
fi
log "版本: $DOCKER_VER | dockerd: $DOCKERD_COMMIT | cli: $DOCKER_CLI_COMMIT"

# 同名包可能同时存在多份 Makefile（feeds 一份、package/ 下自维护副本一份），
# 实际参与编译的是哪一份取决于扫描顺序，所以全部都要修。
find_makefiles() {
    find package/ feeds/ -name Makefile -print0 2>/dev/null \
        | xargs -0 grep -lE "^PKG_NAME:=$1$" 2>/dev/null || true
}

dockerd_makefiles=$(find_makefiles dockerd)
docker_makefiles=$(find_makefiles docker)

if [ -n "$dockerd_makefiles" ]; then
    printf '%s\n' "$dockerd_makefiles" | while IFS= read -r makefile; do
        log "处理 $makefile"
        sed -i "s/^PKG_VERSION:=.*/PKG_VERSION:=$DOCKER_VER/" "$makefile"
        sed -i "s/PKG_GIT_SHORT_COMMIT:=.*/PKG_GIT_SHORT_COMMIT:=$DOCKERD_COMMIT/g" "$makefile"
        sed -i 's/^PKG_HASH:=.*/PKG_HASH:=skip/' "$makefile"
        sed -i '/define Build\/Prepare/,/endef/c\define Build\/Prepare\n\t$(Build\/Prepare\/Default)\nendef' "$makefile"
        sed -i 's/^\t$(call EnsureVendored/#\t$(call EnsureVendored/g' "$makefile"
    done
else
    log "警告: 未找到 dockerd 的 Makefile，跳过引擎修补"
fi

if [ -n "$docker_makefiles" ]; then
    printf '%s\n' "$docker_makefiles" | while IFS= read -r makefile; do
        log "处理 $makefile"
        sed -i "s/^PKG_VERSION:=.*/PKG_VERSION:=$DOCKER_VER/" "$makefile"
        sed -i "s/PKG_GIT_SHORT_COMMIT:=.*/PKG_GIT_SHORT_COMMIT:=$DOCKER_CLI_COMMIT/g" "$makefile"
        sed -i 's/^PKG_HASH:=.*/PKG_HASH:=skip/' "$makefile"
        sed -i '/define Build\/Prepare/,/endef/c\define Build\/Prepare\n\t$(Build\/Prepare\/Default)\nendef' "$makefile"
        if ! grep -qF 'vendor/github.com/santhosh-tekuri/jsonschema/v6/metaschemas' "$makefile"; then
            sed -i '/^define Build\/Compile/i GO_PKG_INSTALL_EXTRA += vendor/github.com/santhosh-tekuri/jsonschema/v6/metaschemas' "$makefile"
        fi
    done
else
    log "警告: 未找到 docker CLI 的 Makefile，跳过 CLI 修补"
fi

# ===============================================================
# 5. cmake 最低版本策略（docker 依赖链里仍有 cmake_minimum_required(<3.5) 的包）
# ===============================================================
if [ -f include/cmake.mk ] && ! grep -q "CMAKE_POLICY_VERSION_MINIMUM" include/cmake.mk; then
    echo 'CMAKE_OPTIONS += -DCMAKE_POLICY_VERSION_MINIMUM=3.5' >> include/cmake.mk
    log "已给 include/cmake.mk 追加 CMAKE_POLICY_VERSION_MINIMUM=3.5"
fi

log "完成"

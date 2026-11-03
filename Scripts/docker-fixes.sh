#!/bin/bash
# Docker（dockerd 引擎 / docker CLI / LuCI dockerman）打包修复。
# 可独立拷到其它 OpenWrt / OpenWRT-CI 仓库使用，在源码树根目录执行：
#
#   sh docker-fixes.sh
#
# 做的事情：
#   1. LuCI dockerman 去重：存在自维护的 luci-app-dockerman（如
#      package/luci-app-dockerman，由 Packages.sh 从 ysuolmai 仓库拉取）时
#      清掉 feeds 里的同名包；不存在则保留原有版本。
#   2. luci-lib-docker 统一用 lisaac/luci-lib-docker。
#   3. dockerd / docker CLI 版本跟随 moby/moby 最新 release，并修补
#      PKG_GIT_SHORT_COMMIT、PKG_HASH、Build/Prepare、vendor 目录安装。
#   4. 给 include/cmake.mk 补 CMAKE_POLICY_VERSION_MINIMUM（部分依赖包
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
# 3. dockerd 引擎 / docker CLI 版本对齐 moby 最新 release
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

dockerd_makefile=$(find package/ feeds/ -name Makefile -print0 2>/dev/null \
    | xargs -0 grep -lE "^PKG_NAME:=dockerd$" 2>/dev/null | head -n 1)
docker_makefile=$(find package/ feeds/ -name Makefile -print0 2>/dev/null \
    | xargs -0 grep -lE "^PKG_NAME:=docker$" 2>/dev/null | head -n 1)

if [ -f "$dockerd_makefile" ]; then
    log "处理 $dockerd_makefile"
    sed -i "s/^PKG_VERSION:=.*/PKG_VERSION:=$DOCKER_VER/" "$dockerd_makefile"
    sed -i "s/PKG_GIT_SHORT_COMMIT:=.*/PKG_GIT_SHORT_COMMIT:=$DOCKERD_COMMIT/g" "$dockerd_makefile"
    sed -i 's/^PKG_HASH:=.*/PKG_HASH:=skip/' "$dockerd_makefile"
    sed -i '/define Build\/Prepare/,/endef/c\define Build\/Prepare\n\t$(Build\/Prepare\/Default)\nendef' "$dockerd_makefile"
    sed -i 's/^\t$(call EnsureVendored/#\t$(call EnsureVendored/g' "$dockerd_makefile"
else
    log "警告: 未找到 dockerd 的 Makefile，跳过引擎修补"
fi

if [ -f "$docker_makefile" ]; then
    log "处理 $docker_makefile"
    sed -i "s/^PKG_VERSION:=.*/PKG_VERSION:=$DOCKER_VER/" "$docker_makefile"
    sed -i "s/PKG_GIT_SHORT_COMMIT:=.*/PKG_GIT_SHORT_COMMIT:=$DOCKER_CLI_COMMIT/g" "$docker_makefile"
    sed -i 's/^PKG_HASH:=.*/PKG_HASH:=skip/' "$docker_makefile"
    sed -i '/define Build\/Prepare/,/endef/c\define Build\/Prepare\n\t$(Build\/Prepare\/Default)\nendef' "$docker_makefile"
    if ! grep -qF 'vendor/github.com/santhosh-tekuri/jsonschema/v6/metaschemas' "$docker_makefile"; then
        sed -i '/^define Build\/Compile/i GO_PKG_INSTALL_EXTRA += vendor/github.com/santhosh-tekuri/jsonschema/v6/metaschemas' "$docker_makefile"
    fi
else
    log "警告: 未找到 docker CLI 的 Makefile，跳过 CLI 修补"
fi

# ===============================================================
# 4. cmake 最低版本策略（docker 依赖链里仍有 cmake_minimum_required(<3.5) 的包）
# ===============================================================
if [ -f include/cmake.mk ] && ! grep -q "CMAKE_POLICY_VERSION_MINIMUM" include/cmake.mk; then
    echo 'CMAKE_OPTIONS += -DCMAKE_POLICY_VERSION_MINIMUM=3.5' >> include/cmake.mk
    log "已给 include/cmake.mk 追加 CMAKE_POLICY_VERSION_MINIMUM=3.5"
fi

log "完成"

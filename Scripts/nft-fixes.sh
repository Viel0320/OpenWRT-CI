#!/bin/bash
# nftables 打包修复，可独立拷到其它 OpenWrt / OpenWRT-CI 仓库使用。
#
# 用法（在 OpenWrt 源码树根目录执行）：
#   sh nft-fixes.sh bridge   # 阶段一：去掉 nft-bridge 的重复 .ko 包映射（feeds update 之后、make 之前）
#   sh nft-fixes.sh deps     # 阶段二：iptables → nftables 依赖整理（必须在 .config 生成之后）
#
# 两个阶段都只在命中条件时才改动文件，可重复执行；失败返回非 0。

set -u

log() { echo "[nft-fix] $*"; }

# ===============================================================
# 阶段一：nft-bridge / nf_conntrack_bridge 的 .ko 归属冲突
# 上游在 include/netfilter.mk 和 package/kernel/linux/modules/netfilter.mk
# 各声明了一次 nf_conntrack_bridge.ko，两个包都选中时构建报文件冲突。
# 这里删掉 include/netfilter.mk 里的 nf_add 映射，保留独立包，
# 并给 nft-bridge 补上对 kmod-nf-conntrack-bridge 的依赖。
# ===============================================================
bridge_fix() {
    local netfilter_mk="include/netfilter.mk"
    local modules_mk="package/kernel/linux/modules/netfilter.mk"

    if [ ! -f "$netfilter_mk" ] || [ ! -f "$modules_mk" ]; then
        log "bridge: 源码树里没有 netfilter.mk，跳过"
        return 0
    fi

    if ! grep -q 'nf_add,NFT_BRIDGE,CONFIG_NF_CONNTRACK_BRIDGE' "$netfilter_mk"; then
        log "bridge: 没有重复的 nf_conntrack_bridge.ko 映射，跳过"
        return 0
    fi

    sed -i '/nf_add,NFT_BRIDGE,CONFIG_NF_CONNTRACK_BRIDGE/d' "$netfilter_mk"
    if grep -q 'nf_add,NFT_BRIDGE,CONFIG_NF_CONNTRACK_BRIDGE' "$netfilter_mk"; then
        log "bridge: 无法移除重复的 nf_conntrack_bridge.ko 映射"
        return 1
    fi

    if ! sed -n '/^define KernelPackage\/nft-bridge/,/^endef/p' "$modules_mk" | \
         grep -q '+kmod-nf-conntrack-bridge'; then
        sed -i '/^define KernelPackage\/nft-bridge/,/^endef/ s/DEPENDS:=+kmod-nft-core$/DEPENDS:=+kmod-nft-core +kmod-nf-conntrack-bridge/' "$modules_mk"
    fi
    if ! sed -n '/^define KernelPackage\/nft-bridge/,/^endef/p' "$modules_mk" | \
         grep -q '+kmod-nf-conntrack-bridge'; then
        log "bridge: 无法给 nft-bridge 补上 nf-conntrack-bridge 依赖"
        return 1
    fi

    log "bridge: 已从 nft-bridge 包映射中移除重复的 nf_conntrack_bridge.ko"
}

# ===============================================================
# 阶段二：iptables → nftables 依赖整理
#   1) 消费包里的 +kmod-iptables 改成 +kmod-nf-ipt（kmod-nf-ipt 自身的依赖保留）
#   2) Makefile 里裸的 +iptables 改成 +iptables-nft
#   3) kmod-iptables 清空 FILES/AUTOLOAD，避免和 kmod-nf-ipt 争同一个 .ko
#   4) .config 里显式 unset PACKAGE_kmod-iptables / PACKAGE_iptables
# ===============================================================
unset_config() {
    local config_name="$1"
    local config_key="CONFIG_${config_name}"

    if ! awk -v key="$config_key" '
        index($0, key "=") == 1 || $0 == "# " key " is not set" { next }
        { print }
    ' .config > .config.new; then
        log "无法更新 .config 中的 $config_key"
        return 1
    fi
    mv .config.new .config || return 1
    printf '# %s is not set\n' "$config_key" >> .config
}

# /**
#  * Rewrite +kmod-iptables dependencies to +kmod-nf-ipt across all packages,
#  * excluding the KernelPackage/nf-ipt definition block itself to avoid circular dependencies.
#  */
kmod_deps_fix() {
    local affected mk
    affected=$(grep -rl '+kmod-iptables' package/ feeds/ 2>/dev/null || true)
    [ -n "$affected" ] || { log "deps: 没有 +kmod-iptables 依赖"; return 0; }

    printf '%s\n' "$affected" | while IFS= read -r mk; do
        [ -n "$mk" ] || continue
        sed -i -E '/^define KernelPackage\/nf-ipt$/,/^endef$/! s/\+kmod-iptables([^a-zA-Z0-9_-]|$)/+kmod-nf-ipt\1/g' "$mk"
    done
    log "deps: 已把 +kmod-iptables 依赖改为 +kmod-nf-ipt"
}

# /**
#  * Find Makefiles that depend on bare +iptables while excluding the iptables
#  * package Makefile itself. Uses xargs -r so empty grep results do not hang or error.
#  */
find_iptables_consumers() {
    grep -rlE '\+iptables([^-a-zA-Z0-9_]|$)' package/ feeds/ 2>/dev/null \
        | xargs -r grep -lv 'PKG_NAME:=iptables' 2>/dev/null || true
}

# /**
#  * Replace bare +iptables dependencies with +iptables-nft across consumer Makefiles
#  * and verify that no residual +iptables references remain.
#  */
iptables_to_nft_fix() {
    local affected remain remain_count mk
    affected=$(find_iptables_consumers)

    if [ -z "$affected" ]; then
        log "deps: 没有文件依赖 +iptables（已是干净状态）"
        return 0
    fi

    log "deps: 发现 $(printf '%s\n' "$affected" | wc -l | tr -d ' ') 个文件依赖 +iptables，前 15 个:"
    printf '%s\n' "$affected" | head -15 | sed 's/^/  - /'
    printf '%s\n' "$affected" | while IFS= read -r mk; do
        [ -n "$mk" ] || continue
        sed -i -E 's/\+iptables([^-a-zA-Z0-9_]|$)/+iptables-nft\1/g' "$mk"
    done

    remain=$(find_iptables_consumers)
    if [ -z "$remain" ]; then
        remain_count=0
    else
        remain_count=$(printf '%s\n' "$remain" | wc -l | tr -d ' ')
    fi
    log "deps: 替换完成，残留 ${remain_count} 处（应为 0）"
}

kmod_iptables_emptying() {
    local kmod_ipt_mk
    kmod_ipt_mk=$(grep -rl "define KernelPackage/iptables$" package/ target/ 2>/dev/null | head -n 1)
    if [ -z "$kmod_ipt_mk" ]; then
        log "deps: 未找到 kmod-iptables 定义文件，跳过"
        return 0
    fi

    log "deps: 清理 $(basename "$kmod_ipt_mk") 的 FILES/AUTOLOAD"
    python3 - "$kmod_ipt_mk" << 'PYEOF'
import sys

filename = sys.argv[1]
with open(filename) as f:
    lines = f.readlines()

result = []
in_ipt_block = False
skip_continuation = False

for line in lines:
    stripped = line.strip()

    if stripped == 'define KernelPackage/iptables':
        in_ipt_block = True
        result.append(line)
        continue

    if in_ipt_block and stripped == 'endef':
        in_ipt_block = False
        result.append(line)
        continue

    if in_ipt_block:
        if skip_continuation:
            if not stripped.endswith('\\'):
                skip_continuation = False
            continue
        if stripped.startswith('FILES:=') or stripped.startswith('AUTOLOAD:='):
            if stripped.endswith('\\'):
                skip_continuation = True
            continue

    result.append(line)

with open(filename, 'w') as f:
    f.writelines(result)

print('[nft-fix] deps: kmod-iptables 已清空 FILES/AUTOLOAD')
PYEOF
}

deps_fix() {
    if [ ! -d package ] || [ ! -d feeds ]; then
        log "deps: 当前目录不是 OpenWrt 源码树"
        return 1
    fi
    if [ ! -f .config ]; then
        log "deps: 未找到 .config，请在生成配置之后再执行"
        return 1
    fi

    kmod_deps_fix || return 1
    unset_config "PACKAGE_kmod-iptables" || return 1

    iptables_to_nft_fix || return 1
    unset_config "PACKAGE_iptables" || return 1

    kmod_iptables_emptying || return 1
}

case "${1:-}" in
    bridge)
        bridge_fix
        ;;
    deps)
        deps_fix
        ;;
    *)
        echo "用法: sh $0 {bridge|deps}"
        exit 2
        ;;
esac

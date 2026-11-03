#!/usr/bin/env bash
# ===========================================================================
# 一加7 (guacamoleb / sm8150) 带容器能力的内核编译脚本
#
# 子命令: configure | verify | build | repack
#
# 环境变量（都有默认值，一般不用改）:
#   CLANG_VER   clang 目录名，默认 clang-r596125
#   LTO         1=保持官方 LTO（默认）  0=关掉 LTO，编译更快更省内存
#
# 设计要点:
#   * 用 LLVM=1，让内核 Makefile 自己把 LD/AR/OBJCOPY 全套换成 llvm 版本 —
#     官方配置开了 CONFIG_LTO_CLANG，链接器必须是 ld.lld，手工传 CC=clang
#     是不够的（LD 还会是 GNU ld，LTO 直接失败）。
#   * 输出目录放在源码树外面，源码保持 clean，git describe 不会带 -dirty。
#   * 版本串不靠 git，由 docker_defconfig.fragment 写死，编译后强制核对。
# ===========================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL="$ROOT/kernel"
OUT="$ROOT/out"
FRAGMENT="$ROOT/docker_defconfig.fragment"

CLANG_VER="${CLANG_VER:-clang-r596125}"
CLANG_DIR="$ROOT/toolchain/clang/$CLANG_VER"
GCC64="$ROOT/toolchain/gcc64"
GCC32="$ROOT/toolchain/gcc32"

# 官方内核的真实版本串，vendor 模块的 vermagic 就是它
EXPECT_RELEASE="4.14.357-openela-perf-g9f007fac27dc"

[ -d "$CLANG_DIR/bin" ] || { echo "!! 找不到 clang: $CLANG_DIR"; exit 1; }

export PATH="$CLANG_DIR/bin:$GCC64/bin:$GCC32/bin:$PATH"
export LC_ALL=C
export ARCH=arm64

MK=(
  make -C "$KERNEL" "O=$OUT"
  ARCH=arm64
  LLVM=1
  # 关键：LLVM=1 时 Makefile 只写 CC=clang，不传 --target，
  # Android 预编译 clang 默认 aarch64-linux-android —— 栈保护金丝雀会取
  # TLS(tpidr_el0+0x28)，内核态读它直接 EL1 翻译异常 → 无输出早期 panic。
  # 官方 LineageOS 构建 CC="clang --target=aarch64-linux-gnu"，guard 取全局
  # __stack_chk_guard。命令行变量覆盖 Makefile 内的 CC= 赋值。
  "CC=clang --target=${CLANG_TARGET:-aarch64-linux-gnu}"
  "CROSS_COMPILE=$GCC64/bin/aarch64-linux-android-"
  "CROSS_COMPILE_ARM32=$GCC32/bin/arm-linux-androideabi-"
  # 交叉 as/objcopy 的查找前缀，显式给死，避免 which elfedit 在 CI 上找不到
  "GCC_TOOLCHAIN_DIR=$GCC64/bin/"
)

# 4.14 内核没有 CONFIG_AS_IS_LLVM 这个选项，所以「用的是 clang 集成汇编器还是
# GNU as 4.9」在 .config 里完全看不出来 —— 配置逐条对比也发现不了。
# 官方 AOSP clang 的构建通常走 IAS，而 LLVM=1 单独并不会启用它（需显式 LLVM_IAS=1）。
# 两条路编出来的汇编代码可以不同，属于此前唯一未排除的编译环节。
if [ "${IAS:-0}" = "1" ]; then
  MK+=(LLVM_IAS=1)
  echo ">> 使用 clang 集成汇编器 (LLVM_IAS=1)"
else
  echo ">> 汇编器：交叉 GNU as（未启用 LLVM_IAS）"
fi

# 实测结论（vanilla-diag2）：--target=aarch64-linux-gnu 生效了（prologue 变了），
# 但金丝雀仍走 TLS —— 换三元组不会改变 guard 取法，需要显式
# -fstack-protector-guard=global 才能让金丝雀落到 __stack_chk_guard。
# 通过 KCFLAGS 注入（4.14 顶层 Makefile 有 KBUILD_CFLAGS += $(KCFLAGS)）。
if [ "${SSPGUARD:-0}" = "1" ]; then
  MK+=("KCFLAGS=-fstack-protector-guard=global")
  echo ">> KCFLAGS 注入 -fstack-protector-guard=global"
fi

merge() {  # $1 = 相对内核源码根的 config 片段
  "$KERNEL/scripts/kconfig/merge_config.sh" -m -O "$OUT" "$OUT/.config" "$KERNEL/$1"
}

cmd_configure() {
  echo "== 0/5 接管版本串生成 =="
  # scripts/setlocalversion 在检测到 working tree 不干净时会往版本串尾部加 "+"，
  # CI 里 kernel/ 嵌在外层仓库目录下，必然会命中，结果变成
  # 4.14.357-openela-perf-g9f007fac27dc+ —— 多了个加号，模块全废。
  # 但它同时负责打印 CONFIG_LOCALVERSION，不能整段删掉，
  # 所以换成「只输出 CONFIG_LOCALVERSION、不碰 git」的等价实现。
  if [ -f "$KERNEL/scripts/setlocalversion" ]; then
    echo "  改动前 git status（仅供诊断）:"
    git -C "$KERNEL" status --porcelain 2>/dev/null | head -10 || true
    cat > "$KERNEL/scripts/setlocalversion" <<'SETLOCAL'
#!/bin/sh
# 版本串只认 CONFIG_LOCALVERSION，完全不看 git 状态（避免 -dirty 追加 "+"）
for f in include/config/auto.conf \
         "$(dirname "$0")/../include/config/auto.conf" \
         .config \
         "$(dirname "$0")/../.config"; do
	[ -f "$f" ] || continue
	v=$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"$/\1/p' "$f" | head -n 1)
	if [ -n "$v" ]; then
		printf '%s' "$v"
		break
	fi
done
exit 0
SETLOCAL
    chmod +x "$KERNEL/scripts/setlocalversion"
    echo "  已替换 scripts/setlocalversion -> 只输出 CONFIG_LOCALVERSION"
  fi

  echo "== 1/5 生成基础 defconfig (vendor/sm8150-perf) =="
  "${MK[@]}" vendor/sm8150-perf_defconfig

  echo "== 2/5 叠加设备树指定的两个 config =="
  merge arch/arm64/configs/vendor/oplus.config
  merge arch/arm64/configs/vendor/oplus_non_dynamic.config

  echo "== 3/5 叠加容器能力补丁 =="
  if [ "${VANILLA:-0}" = "1" ]; then
    echo "   VANILLA=1：不叠加容器选项，只保留版本串修正（对照组）"
    cat > "$ROOT/.vanilla.fragment" <<'VF'
CONFIG_LOCALVERSION="-perf-g9f007fac27dc"
# CONFIG_LOCALVERSION_AUTO is not set
CONFIG_MODVERSIONS=y
VF
    "$KERNEL/scripts/kconfig/merge_config.sh" -m -O "$OUT" "$OUT/.config" "$ROOT/.vanilla.fragment"
  else
    "$KERNEL/scripts/kconfig/merge_config.sh" -m -O "$OUT" "$OUT/.config" "$FRAGMENT"
  fi

  echo "== 3.5/5 可选: 开启崩溃日志捕获 (PSTORE) =="
  if [ "${PSTORE:-0}" = "1" ]; then
    # 本机 dtb 里有 ramoops@0xA9800000 保留内存，开了 PSTORE_RAM 就能自动绑定。
    # 官方内核把这个功能关着，所以之前内核崩了也留不下任何痕迹 —— 这次补上，
    # 下次崩了重启后直接读 /sys/fs/pstore/console-ramoops 就能看到 panic 现场。
    "$KERNEL/scripts/kconfig/merge_config.sh" -m -O "$OUT" "$OUT/.config" "$ROOT/pstore_debug.fragment"
    echo "   PSTORE 已开启（捕获崩溃日志用）"
  else
    echo "   PSTORE 未开启"
  fi

  echo "== 3.6/5 可选: 崩溃现场落盘 (MINIDUMP + RTB) =="
  if [ "${CRASHDUMP:-0}" = "1" ]; then
    # 官方配置里 FORCE_WDOG_BITE_ON_PANIC=y 会让 panic 直接硬复位进 EDL，
    # 但 MINIDUMP 关着 -> rawdump 分区永远为空，日志拿不到。
    # 打开 MINIDUMP 后，panic 现场会经保留内存落到 rawdump，重启后可读。
    "$KERNEL/scripts/kconfig/merge_config.sh" -m -O "$OUT" "$OUT/.config" "$ROOT/crashdump.fragment"
    echo "   MINIDUMP + RTB 已开启（崩溃现场落盘）"
  else
    echo "   MINIDUMP 未开启"
  fi

  echo "== 4/5 可选: 关闭 LTO =="
  if [ "${LTO:-1}" = "0" ]; then
    printf '# CONFIG_LTO_CLANG is not set\nCONFIG_LTO_NONE=y\n' > "$ROOT/.lto-off.fragment"
    "$KERNEL/scripts/kconfig/merge_config.sh" -m -O "$OUT" "$OUT/.config" "$ROOT/.lto-off.fragment"
    echo "   LTO 已关闭"
  else
    echo "   保持官方 LTO 配置"
  fi

  echo "== 5/5 olddefconfig 收敛 =="
  "${MK[@]}" olddefconfig

  cp "$OUT/.config" "$ROOT/kernel.config"

  echo
  echo "-- 版本串相关 --"
  grep -E '^CONFIG_LOCALVERSION|^# CONFIG_LOCALVERSION_AUTO' "$OUT/.config" || true
  grep -E '^CONFIG_(LTO|LTO_CLANG|CFI_CLANG|SHADOW_CALL_STACK)=' "$OUT/.config" || true
  echo "配置已存到 kernel.config"
}

cmd_verify() {
  echo "== 校验容器必需项 =="
  local miss=0
  if [ "${VANILLA:-0}" = "1" ]; then
    echo "  VANILLA=1：对照组不检查容器选项，只验证编译链路与版本串"
  else
  for c in PID_NS USER_NS IPC_NS SYSVIPC CGROUP_PIDS CGROUP_DEVICE \
           POSIX_MQUEUE OVERLAY_FS VETH BRIDGE IP_NF_NAT SECCOMP; do
    if grep -qx "CONFIG_${c}=y" "$OUT/.config"; then
      echo "  OK   CONFIG_$c"
    else
      echo "  MISS CONFIG_$c"; miss=1
    fi
  done
  echo "-- 期望有 --"
  for c in CFS_BANDWIDTH MACVLAN VXLAN NETFILTER_XT_MATCH_ADDRTYPE; do
    if grep -qx "CONFIG_${c}=y" "$OUT/.config"; then
      echo "  OK   CONFIG_$c"
    else
      echo "  --   CONFIG_$c（可选，未启用）"
    fi
  done
  fi

  echo "-- 版本串 --"
  local lv auto
  lv=$(grep -E '^CONFIG_LOCALVERSION=' "$OUT/.config" || true)
  auto=$(grep -E '^CONFIG_LOCALVERSION_AUTO=' "$OUT/.config" || true)
  echo "  $lv"
  echo "  ${auto:-# CONFIG_LOCALVERSION_AUTO is not set}"
  if ! echo "$lv" | grep -q 'g9f007fac27dc'; then
    echo "  !! LOCALVERSION 里没有正确的 commit 后缀，vendor 模块会加载失败"
    miss=1
  fi
  if [ -n "$auto" ]; then
    echo "  !! LOCALVERSION_AUTO 仍为 y，版本串可能被 git 状态污染"
    miss=1
  fi

  # 真正会被写进内核的是 `make kernelrelease` 的结果，这里提前算一次，
  # 免得白等 5 分钟编译才发现 setlocalversion 没吐出版本串。
  echo "-- make kernelrelease 预演 --"
  local kr
  kr=$("${MK[@]}" -s kernelrelease 2>/dev/null | tail -n 1 | tr -d '\r')
  echo "  kernelrelease : ${kr:-<空>}"
  echo "  期望          : $EXPECT_RELEASE"
  if [ "$kr" != "$EXPECT_RELEASE" ]; then
    echo "  !! kernelrelease 与期望不符，编译前就拦下"
    miss=1
  fi

  if [ "$miss" -ne 0 ]; then
    echo "!! 有阻断项，终止"
    exit 1
  fi
  echo "== 配置校验通过 =="
}

cmd_build() {
  echo "== SSP 金丝雀实验矩阵（同款 clang 编译样例，反汇编看 guard 取法）=="
  cat > /tmp/ssp_test.c <<'EOF'
extern void use(void *p);
void probe(char *in) { char buf[64]; __builtin_memcpy(buf, in, 64); use(buf); use(in); }
EOF
  for t in "aarch64-linux-android" "aarch64-linux-gnu" \
           "aarch64-linux-gnu -fstack-protector-guard=global" \
           "aarch64-linux-gnu -fstack-protector-guard=global -fstack-protector-guard-reg=tpidr_el0"; do
    if clang --target=$t -c -O2 -fstack-protector-strong /tmp/ssp_test.c -o /tmp/ssp_test.o 2>/tmp/ssp_err.txt; then
      n_mrs=$(llvm-objdump -d /tmp/ssp_test.o 2>/dev/null | grep -c 'tpidr_el0')
      n_adrp=$(llvm-objdump -d /tmp/ssp_test.o 2>/dev/null | grep -c 'adrp')
      echo "  [target=$t] tpidr 指令=$n_mrs adrp 指令=$n_adrp"
    else
      echo "  [target=$t] 编译失败: $(head -2 /tmp/ssp_err.txt | tr '\n' ' ')"
    fi
  done
  echo "== 实验结束 =="
  echo "== 编译命令行诊断（dry-run 抽样，验证 CC/--target 是否真的生效）=="
  # make -n 不执行只打印；抽 head.o 的编译行，里面应该能看到
  #   CC=clang --target=aarch64-linux-gnu  是否真正出现在 clang 命令里
  "${MK[@]}" -n arch/arm64/kernel/setup.o 2>/dev/null | grep -m2 -E "echo '  CC |clang " || true
  echo "== 诊断结束 =="
  echo "== 开始编译 Image（$(nproc) 核，$(free -g | awk '/Mem:/{print $2}')GB 内存）=="
  date +"开始 %H:%M:%S"
  "${MK[@]}" -j"$(nproc)" Image
  date +"结束 %H:%M:%S"

  ls -l "$OUT/arch/arm64/boot/Image"

  echo "== 核对编译出来的版本串 =="
  local got
  got=$(grep -o '"[^"]*"' "$OUT/include/generated/utsrelease.h" | tr -d '"')
  echo "  utsrelease : $got"
  echo "  期望       : $EXPECT_RELEASE"
  if [ "$got" != "$EXPECT_RELEASE" ]; then
    echo "!! 版本串不一致，vendor 分区的 .ko 会因 version magic mismatch 拒绝加载"
    echo "!! 这个 boot.img 刷上去会没有 WiFi / 音频 / 触控"
    exit 1
  fi
  echo "  版本串一致 -> 模块兼容性有保障"
}

cmd_repack() {
  echo "== 用官方 boot.img 作模板重打包 =="
  command -v magiskboot >/dev/null || { echo "!! 缺 magiskboot"; exit 1; }
  rm -rf "$ROOT/work" && mkdir -p "$ROOT/work"
  cp "$ROOT/boot-orig.img" "$ROOT/work/boot.img"

  cd "$ROOT/work"
  magiskboot unpack boot.img

  echo "  模板内核: $(stat -c%s kernel 2>/dev/null || echo '?') 字节"
  cp "$OUT/arch/arm64/boot/Image" kernel
  echo "  替换为新内核: $(stat -c%s kernel) 字节"

  magiskboot repack boot.img "$ROOT/boot-docker.img"
  cd "$ROOT"

  echo "== 产物 =="
  ls -l "$ROOT/boot-docker.img"
  sha256sum "$ROOT/boot-docker.img" | tee "$ROOT/boot-docker.sha256"

  echo "== 与原始镜像对比头部（确认 header 版本没被改坏）=="
  od -An -tx1 -N32 "$ROOT/boot-orig.img" | head -2
  od -An -tx1 -N32 "$ROOT/boot-docker.img" | head -2
}

case "${1:-}" in
  configure) cmd_configure ;;
  verify)    cmd_verify ;;
  build)     cmd_build ;;
  repack)    cmd_repack ;;
  *) echo "用法: $0 {configure|verify|build|repack}"; exit 2 ;;
esac

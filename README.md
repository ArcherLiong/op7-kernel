# guacamoleb · 容器能力内核（GitHub Actions 云编译）

给一加7（GM1900 / guacamoleb）编一个能跑 Docker 的内核。

仓库：<https://github.com/ArcherLiong/op7-kernel>

## 背景

LineageOS 24 官方内核把容器必需的几个开关关掉了（Android 自己用不到）：

```
CONFIG_PID_NS        is not set   ← 容器根本起不来
CONFIG_USER_NS       is not set
CONFIG_IPC_NS        is not set   (SYSVIPC 也关)
CONFIG_CGROUP_PIDS   is not set
CONFIG_CGROUP_DEVICE is not set
CONFIG_POSIX_MQUEUE  is not set
```

`runc` 在 `clone(CLONE_NEWPID)` 这一步就被内核拒绝，`dockerd` 直接退出。
本流水线只做一件事：用**和官方相同的源码提交**重编一次，把上面这几项打开，
其它一律不动。

## 关键约束：版本串必须逐字一致

内核 version 串是 `4.14.357-openela-perf-g9f007fac27dc`，`/vendor/lib/modules`
下的 `.ko`（WiFi / 音频 / 触控 / 相机全是模块）在 `insmod` 时比对 vermagic，
其中就含这个串。差一个字就是开机能进系统但没网、没声音。

三个钉死的参数：

| 项 | 值 | 依据 |
| --- | --- | --- |
| 内核提交 | `9f007fac27dce21d29d8230753b71d5634b8a00e` | 官方 boot.img 里的 `-g9f007fac27dc` |
| 版本串 | 由 `docker_defconfig.fragment` 写死 | 不依赖 git describe，浅克隆也能编、不受 `-dirty` 污染 |
| defconfig | `sm8150-perf` + `oplus` + `oplus_non_dynamic` | sm8150-common 的 BoardConfig |

编译器按官方 banner 取 Android clang `r596125`（LLVM 22.0.2）。**编译器版本不影响模块兼容**
（符号 CRC 由 genksyms 从源码算，vermagic 只看版本串），只影响 codegen，所以万一该 clang
目录被上游归档，流水线会自动退到次新的版本并打 warning，模块依然能加载。

## 关键细节：LTO

官方配置带着 `CONFIG_LTO_CLANG=y`，链接器必须是 `ld.lld`。所以 make 传的是 **`LLVM=1`**
而不是 `CC=clang` —— 后者的情况下 `LD` 仍然是 GNU ld，LTO 会在链接阶段失败。

LTO 让编译变慢、吃内存。想快一倍可以把 `lto` 输入设为 `0`（`LLVM=1` 仍保留），
代价是 codegen 与官方不同，**模块照样能加载**（vermagic 不变），但内核行为不再等于官方版本。

## 怎么跑

仓库已建好，直接点：**Actions → build-docker-kernel → Run workflow → Run**

- `lto` 留 `1`
- `kernel_commit` 不用改

全程约 40–60 分钟（LTO 编译本身占大头）。跑完在页面底部 **Artifacts** 下载
`boot-docker-guacamoleb.zip`，解压得到：

```
boot-docker.img        新的 boot 镜像
boot-docker.sha256     校验值
kernel.config          这次实际生效的完整配置
```

> 仓库是 public，所以 Actions 分钟数不计费、runner 是 4 核 16G。
> 想转 private 也可以（每月 2000 分钟免费额度够跑 30 多次），但会降成 2 核 7G，
> LTO 有一定概率内存不够。

## 刷进手机

在 `oneplus7-server` 目录（`fb.py` 所在处）：

```bash
python fb.py reboot-bootloader      # 进 fastboot
python fb.py devices                # 确认连得上
python fb.py flash boot boot-docker.img
python fb.py reboot
```

首次开机比平时慢（1–3 分钟）。

## 刷完必须验三件事

```bash
# ① 版本串必须逐字一致
adb shell uname -r
# 期望: 4.14.357-openela-perf-g9f007fac27dc

# ② 模块加载没有报错（输出为空 = 成功）
adb shell "dmesg | grep -iE 'version magic|disagrees about version'"

# ③ 命名空间齐了（应能看到 ipc mnt net pid user uts 全部 7 项）
adb shell "ls /proc/self/ns"
```

再顺手确认 WiFi、声音、触屏、相机——这几项靠 vendor 模块，出问题一定在上面的 ② 里。

## 回退

原件就在本地：`oneplus7-server/input/lineage/boot.img`

```bash
python fb.py flash boot input/lineage/boot.img
python fb.py reboot
```

刷任何 boot 都不会被 AVB 拦——LineageOS 的 `vbmeta.img` 是空壳
（`flags=0`、无签名、无 hash 描述符，已实测）。

## 已知取舍

- **`CONFIG_USER_NS=y` 放宽了 Android 应用沙箱边界**。这是容器绕不过去的代价，官方内核
  为安全默认关闭。这台机器当服务器用可以接受，主力机别这么干。
- **只改配置，不改代码**，不加 KernelSU、不加补丁。root 后面用 Magisk 打 boot 补丁解决
  （Magisk 支持自定义内核）。注意顺序：**先刷这个内核，再用 Magisk 修补它**，反过来会失效。
- `CFS_BANDWIDTH` 影响 `--cpus` 限额是否生效；`POSIX_MQUEUE` 是 postgres 一类服务的依赖。

## 排错

| 现象 | 位置 | 处理 |
| --- | --- | --- |
| 没找到 `clang-r596125` | 工具链步骤 | 流水线会自动退到次新版本并 warning，看日志确认选了哪个 |
| `verify` 报 MISS | 配置校验 | 看 configure 步骤 merge_config 的输出，多半是依赖没满足 |
| 编译报错 | 编译步骤 | 先看第一条 error；若与 LTO/内存有关，把 `lto` 设 0 重跑 |
| `版本串不一致` | 编译收尾 | 说明 `LOCALVERSION` 没生效，**必须**修好再刷，否则没网 |
| 刷完不开机 | — | 回退原件，把 `build-logs` 和失败步骤日志发出来 |

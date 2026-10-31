# 依赖与发布

架构边界见 [维护环境设计](superpowers/specs/2026-10-13-pizza-transition-design.md)，发布衔接与后续实现见 [实施计划](superpowers/plans/2026-10-21-pizza-maintenance-plan.md)。

项目拆成两个仓库：

- [pizza-bundle](https://github.com/Pizza-Partition/pizza-bundle) 维护第三方运行环境的构建、测试和发布。
- [pizza](https://github.com/Pizza-Partition/pizza) 维护业务程序和界面，将应用层加入已发布的可信基础镜像。

`pizza-bundle` 使用固定 digest 的官方 Arch 容器和指定日期的包快照。
pacman 负责签名验证、递归依赖解析与安装，patchelf 负责解释器和搜索路径，GNU tar/cpio/gzip 负责基础 initramfs 与归档。
运行库、资源和许可证一同保留；不再自研包解析器、依赖收集器或 ELF 修改器。
发布之前在只包含打包文件的 scratch 容器中运行 ABI/动态加载和运行环境移动检查。
测试失败不发布。真实 DRM 硬件、旧内核矩阵与内存预算需要另外验收。

## 消费固定发布版本

当前消费锁固定 [v0.4.1](https://github.com/Pizza-Partition/pizza-bundle/releases/tag/v0.4.1)，源提交为 `d6729057a02482852274427ecfaa2580161ee448`。三个产物的真实摘要与 `cpu-maint-v1` 契约已通过原生来源验证，bundle 与维护镜像已完成组装；验收记录见实施计划 M0。

宿主需要锁定的 Zig、Node >=22、npm、curl（归档互操作测试另需 libarchive 的 bsdtar；旧 ext4 journal/交接 VM 夹具仍使用 e2fsprogs/debugfs 作为独立测试工具）。Pizza 消费端不下载或调用 patchelf；第三方 ELF 重定位由 pizza-bundle 完成。

统一存储引擎与恢复核心使用 Zig，ext2/3/4 后端静态链接固定源码构建的 libext2fs。e2fsprogs 1.47.4 通过 `zig fetch` 和 `build.zig.zon` 内容哈希锁定，由 `build/filesystem/ext/root.zig` 完成 C 源码编译（不包含 resize2fs 完整算法）、头文件生成和 translate-c 绑定，不需要宿主 ext 开发包、pkg-config、configure、make 或 shell 构建脚本。应用仍不编译或链接 libblockdev、GLib、libblkid。FAT32 后端以同样方式通过 `build/filesystem/fat32/` 静态构建只读的固定 FatFs R0.16（含上游 patch 1/2，并关闭 mkfs），翻译 `ff.h`，不依赖宿主 FAT 开发包；格式化、缩扩容和结构修复由 Zig 实现。NTFS 后端固定 [NTFS-3G 2026.9.28](https://github.com/tuxera/ntfs-3g/releases/tag/2026.9.28)，由 `build/filesystem/ntfs/` 静态编译 libntfs-3g 的只读访问及记录辅助代码，不构建 mkntfs/ntfsresize 的完整算法、翻译上游公开 `volume.h`，设备 I/O 由 Zig 接管。不编译 FUSE 驱动或默认 Unix 设备 I/O。Btrfs 后端固定 [btrfs-progs v7.1](https://github.com/kdave/btrfs-progs/tree/v7.1)，由 `build/filesystem/btrfs/` 静态构建 libbtrfs、直接 translate-c 翻译上游磁盘格式与 CRC 头文件；离线元数据和 chunk 算法使用 Zig 实现。`zig build test-filesystems` 额外需要宿主 e2fsprogs、dosfstools、mtools、ntfs-3g、btrfs-progs 命令作为独立验收工具。格式适配与共用恢复的实现边界见 [filesystems.md](filesystems.md)。

```sh
zig build deps
zig build runtime-deps
zig build bundle -Doptimize=safe
zig build all test
```

`config/bundle/release.json` 固定仓库 ID、发布 tag、源 commit，以及基础 initramfs、内核、base.json 的文件名和 SHA-256。
`build/bundle/release.zig` 流式校验 SHA-256，经 TUF 获取可信验证材料，再调用 `build/bundle/sigstore.zig` 离线验签。
ASN.1 DER 编解码使用 `std.crypto.codecs.asn1.der.Decoder` / `Encoder`，证书解析与证书签名验证使用 `std.crypto.Certificate`，DSSE 和日志 ECDSA 签名使用 `std.crypto.sign`。
通用适配位于 `core/utils/asn1.zig`、`x509.zig` 和 `time.zig`，Fulcio 身份扩展与用途策略位于 `build/bundle/fulcio.zig`。同时验证 Fulcio 信任链、证书用途、SCT、
Rekor SET、Merkle inclusion proof 和签名 checkpoint，并将日志绑定到证书、签名和 payload。
签名证书中的仓库 ID、发布 workflow、tag、source commit、signer commit 和 GitHub 托管 runner 必须匹配锁文件；
签名的 in-toto subject 必须包含三个原始产物的摘要。信任根版本及支持格式见 [信任策略](../build/bundle/trust/README.md)。
可执行文件仅内置 TUF 初始根；`build/bundle/trust.zig` 通过官方 TUF 仓库刷新 `trusted_root.json`，验证根轮换、角色签名阈值、过期、回滚、元数据版本及目标摘要。缓存更新使用排他锁和原子替换。
不信任随产物携带的自定义根；未支持的格式或算法直接拒绝。
验证通过后将原始基础层复制到新目录；不解包或改写基础层。失败会清理临时目录。
签名验证发生在宿主构建阶段，不依赖 GitHub CLI、OpenSSL 或外部 Sigstore 客户端；
默认在线模式会刷新 TUF，失败不会静默退回旧快照。显式离线模式重新验证缓存中的签名和摘要，并要求 TUF 元数据在当前时间未过期；历史产物证书仍按已认证的入日志时间验证。
RAM 维护环境仍使用已有的镜像摘要校验，并未增加运行时来源验证。
没有跳过验证的生产选项。

消费端 TAR 读写使用 `std.tar.Iterator` / `std.tar.Writer`，gzip 使用 `std.compress.flate`。
流式打包不把整个基础镜像读进内存，
归档条目排序，mtime/uid/gid 归零，保留普通文件权限与相对符号链接。newc 写入器由应用层和 console 层共享。
工具解包拒绝路径穿越、绝对链接、逃逸链接及符号链接父目录；gzip 解包显式验证 CRC 和原始长度。
CI 首次安装 Zig 时尚无编译器，仍用 runner 自带 tar 解包；获得 Zig 后的消费端归档与压缩均不调用外部命令。

```sh
zig build tools -- fetch-bundle --destination /tmp/pizza-runtime
zig build tools -- verify-bundle --bundle /tmp/pizza-runtime
zig build tools -- prepare-bundle \
  --runtime /tmp/pizza-runtime \
  --init zig-out/bin/pizza-init --maintenance zig-out/bin/pizza-maint \
  --destination /tmp/pizza-application
zig build tools -- pack-bundle --bundle /tmp/pizza-application --output /tmp/pizza-application.tar.gz
zig build tools -- image --bundle /tmp/pizza-application --output /run/pizza/maint.img
```

TUF 缓存默认位于 `$XDG_CACHE_HOME/pizza/sigstore`（XDG 路径必须为绝对路径），否则使用 `$HOME/.cache/pizza/sigstore`。
可通过 `PIZZA_SIGSTORE_CACHE` 指定缓存目录，`verify-bundle --trust-cache PATH` 优先于该环境变量。
在线运行会获取并认证最新信任材料；离线机器需要预先复制一次成功在线验证产生的完整缓存目录。

```sh
zig build tools -- verify-bundle --bundle /tmp/pizza-runtime --trust-cache /tmp/pizza-sigstore
zig build tools -- verify-bundle --bundle /tmp/pizza-runtime --trust-cache /tmp/pizza-sigstore --offline
PIZZA_SIGSTORE_CACHE=/tmp/pizza-sigstore PIZZA_SIGSTORE_OFFLINE=1 zig build bundle -Doptimize=safe
```

`PIZZA_SIGSTORE_OFFLINE=1` 对 `prepare-bundle`、`image` 等所有来源验证调用生效；只限制 TUF 更新，不阻止构建其他步骤下载缺失的产物或工具。值为 `0` 或未设置时默认在线。
离线模式不接受缺失、篡改或过期的缓存，也不提供跳过来源验证的选项。

这里的 `verify-bundle` 验证下载目录里的三个原始发布产物与 attestation。
`prepare-bundle` 再次验证产物，创建独立 overlay 目录放入本次构建的程序。
应用目录是本地构建输出，应保持受控；对目录的后续修改不受原始归档的 attestation 保护。
`image` 检查应用布局、静态 PID 1 与内核契约，重新验证基础层来源，然后把原生 newc/gzip 写入器生成的应用层追加到基础 initramfs，不做上游内容审计。

## 布局与版本契约

运行环境可部署到任意目录，镜像默认放在 `/opt/pizza/bundle`。启动前须把工作目录设为 bundle 根。
第三方程序的 `PT_INTERP` 为相对路径 `lib/ld-linux-x86-64.so.2`，RUNPATH 全部相对于 `$ORIGIN`；
Pizza 只构建一份用于 bundle 的 `pizza-maint`：Zig 链接器直接写入上述解释器和 `DT_RUNPATH=$ORIGIN/../lib`，`zig-out/bin/pizza-maint` 是待打包产物。
锁定的 Zig 0.17 构建驱动会丢失自定义动态解释器参数，因此该产物通过构建图中的一次原生 Zig 编译命令生成；模块依赖和生成文件仍由构建图管理，递归源文件依赖由编译器自身缓存跟踪。
`prepare-bundle` 只读检查其 x86-64 ELF、解释器、RUNPATH 和缺少旧式 RPATH 的契约，随后原样复制；不重写任何 ELF。
维护程序在 bundle 根目录由 PID 1 启动。宿主 CLI、TUI 和后端测试显式调用宿主加载器执行同一产物，不生成另一份宿主版维护程序。
`runtime.json` 是 format 3 的运行环境契约；`manifest.json` 在加入本地应用时生成，
记录架构、profile、入口路径和运行环境来源，不含逐文件哈希清单。
整体移动 bundle 不需要重写 ELF。运行环境不再包含浏览器、Mesa、EGL、GStreamer或浏览器 sandbox 工具。

运行库版本、来源包清单和许可证随包发布。基础 initramfs、内核与 base.json 各自固定摘要并验证同一发布来源。升级时先在 pizza-bundle 发布测试通过的新版本，
再更新本仓库的 release.json。两仓库不存在反向依赖。
旧 format 1/2 原生归档部署接口、collect/prepare/audit 实现和包锁定树已移除。

## 内核与维护镜像

新 profile 使用固定 Linux 7.2.11 与匹配的 7.2.11-arch1-1 模块，独立于宿主内核；发布后须验证它们来自同一次可信发布。
`pizza-bundle` 从固定内核包安装选定模块；`zig build image` 只追加应用层并输出对应内核。签名证明运行环境的来源与完整性，
不证明它可以运行于任意内核、CPU 或显卡。生产交接见 [transition.md](transition.md)。
`test-smoke` 使用独立的静态 PID 1 测试夹具，不代表运行环境发布验收。生产 image 没有开发绕过选项。

主设计已同步两仓库边界与新 profile；本地软件包收集、逐文件清单和手工发行签名不再是当前方案。

未来可启动 ISO 采用 systemd-boot + UKI（x86-64 UEFI），见 [boot-image.md](boot-image.md)。

应用包布局：

```text
pizza-base-x86_64.img    # 上游基础层，保持原始字节
vmlinuz                 # 同次发布的 Linux 7.2.11
base.json / release.json / attestation.json
manifest.json           # 本地应用接口
overlay/
  init
  opt/pizza/bundle/bin/pizza-maint
```

最终 `maint.img = 基础 initramfs + gzip/newc 应用层 + console 层`。
驱动、固件和系统布局调整都在 pizza-bundle 中发布；Pizza 不再调用 dracut、depmod 或 modprobe。
基础层本身没有 `/init`，不单独宣称可启动。生产者追加测试 init 验收基础层；消费者追加真实程序后做后端与 TUI 启动验收。

`build/bundle.zig` 用 `b.addRunArtifact` 接入上述 Zig 工具步骤。`release.zig` 负责来源策略，
`assemble.zig` 负责应用层，`archive.zig` 使用原生 TAR/newc/gzip 归档。
已移除 Node bundle 脚本；Node/npm 仍用于格式检查及 CI 首次引导 Zig。

## 固定驱动与固件

生产者的 `config/maintenance.json` 定义全部驱动和文件系统；不读取宿主 `/lib/modules`、`/lib/firmware` 或 sysfs 选硬件。
`modprobe --dirname PACKAGE_ROOT --config /dev/null` 只解析固定内核包的依赖；`modinfo` 检查固件声明，模块解压后按依赖顺序由 PID 1 加载。
基础层以 `cpio`/`gzip` 从显式输入树打包，不再调用 dracut。
默认外部固件清单为空：通用存储、输入、文件系统及 simpledrm 不需要额外 GPU/Wi-Fi 固件。
声明外部固件的驱动会使构建失败，必须先加入固定来源的专用硬件配置，不能回退宿主收集。

固定内核镜像提取出的配置必须内建 EFI、EFI_STUB、SYSFB、SYSFB_SIMPLEFB、DRM、DRM_SIMPLEDRM；
`simpledrm` 不需要单独装载 `.ko`。文件系统包括 ext2/3/4（ext4 兼容）、Btrfs、XFS、NTFS、NTFS3、FAT/VFAT、exFAT、F2FS、ISO9660、UDF、SquashFS、EROFS、OverlayFS、HFS/HFS+、NILFS2，以及所需 NLS。
生产者 QEMU 启动后核对 `/proc/filesystems`，证明驱动注册成功；这不等同于完成每种文件系统的读写验收，也不增加生产 journal 的可选类型。

未来图形路径是固件初始化 framebuffer，由内建 simpledrm 接管；Blend2D 在 CPU 上绘制像素，再经 DRM dumb buffer/KMS 显示。
本次不实现图形界面。`kexec` 不重新执行 UEFI，不能保证宿主原生 GPU 驱动改写过的显示状态仍可交接；需做实机验收并保留 TUI/文本输出。
[DRM dumb buffer 接口](https://www.kernel.org/doc/html/latest/gpu/drm-uapi.html)、[内核 framebuffer 配置](https://github.com/torvalds/linux/blob/master/drivers/firmware/Kconfig)。

当前 profile 为 `cpu-maint-v1`，消费锁已更新至正式发布的 `v0.4.1`。旧浏览器 profile 仍被拒绝，历史签名 fixture 不作为当前运行环境使用。

当前已签名旧基础包的文件系统用户态工具由生产者的 `config/filesystem-tools.json` 定义并核对命令清单。
包含 btrfs-progs、e2fsprogs、xfsprogs、dosfstools、exfatprogs、ntfsprogs、f2fs-tools、nilfs-utils、udftools 与 libblockdev-fs（提供 vfat-resize）。
消费端已停止使用这套自动执行路径。共用规划器通过 FilesystemOps 语义虚表接入原生后端，当前 ext 后端静态构建其固定版本的 C 库。

人工救援环境采用 SystemRescue 文件系统救援子集：生产者保存 [SystemRescue 13.02 官方包清单](https://www.system-rescue.org/Detailed-packages-list/)及摘要，从中裁剪终端、Vim/Nano、常见命令、分区与文件系统、LVM/RAID/LUKS、数据恢复及网络传输工具；不额外加入 GNU Emacs。pacman 负责固定 Arch 快照中的签名包和依赖解析，顶层选择和完整依赖闭包均须属于上游清单。参考清单的包版本与实际快照安装版本分别记录，不把两者混同为 SystemRescue 原版二进制。

保留第三方命令供用户在 root shell 中手动恢复；业务自动执行仍使用原生引擎。生产者新配置移除 libblockdev 插件桥，保留离线手册、terminfo 和编辑器资源，并使用上游软件包提供的静态 BusyBox 作为完整环境无法启动时的后备。软件自身的电源流程集中在 init，救援用户保留 Linux capability 允许的管理操作。

该配置需要在 pizza-bundle 完成构建、重定位及启动验收并发布后，才能更新本仓库的消费锁。当前 `v0.4.1` 锁和已签名基础层保持原样；应用组装不修改已签名基础层。救援 shell 的启动及 init 的重启请求协议属于消费端另行接入的工作。

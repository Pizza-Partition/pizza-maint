# 可启动镜像路线

当前架构见 [主设计](superpowers/specs/2026-10-13-pizza-transition-design.md)，本路线对应 [实施计划 M4](superpowers/plans/2026-10-21-pizza-maintenance-plan.md)。

选定 x86-64 UEFI、systemd-boot 与 UKI，不以传统 BIOS 为目标。
systemd-boot 仅为固件阶段的启动菜单；运行时 PID 1 仍为静态 pizza-init。

两个仓库保持单向依赖。pizza-bundle 用标准 cpio/gzip 将固定来源的 portable 用户态和匹配模块打包到基础 initramfs，
同时发布固定 Linux 7.2.11（官方 Arch 包 release 7.2.11-arch1-1）。pizza 验证三份产物来源，追加 /init 与应用的 newc 层，
通过 `zig build image` 生成 `vmlinuz`、`maint.img` 和镜像 metadata。
生产镜像直接消费随包模块，不要求宿主安装同版本内核。
通用 profile 的外部固件清单明确为空；特殊硬件需要固定来源的显式配置，不能从宿主收集。

必须先完成应用层插入，再组装和签名 UKI；插入程序会改变镜像摘要，不能直接修改已经签名的 UKI。

后续 UKI 将通过 systemd ukify 封装内核、initramfs、OS 标识和启动命令行。
ISO 的 EFI System Partition 使用 FAT 格式，建议布局：

```text
ESP/
├── EFI/BOOT/BOOTX64.EFI       # systemd-boot
├── EFI/Linux/pizza.efi       # kernel + initramfs + cmdline 的 UKI
└── loader/loader.conf
```

ISO 再用 xorriso 加入 UEFI El Torito 引导项。USB 磁盘镜像需要合适的分区表与 ESP，
不能把仅有 ISO 光盘引导项当成已经验证的可写入 USB 的混合镜像。
所有安装/打包操作针对 staging ESP，不能运行会修改当前机器启动项的默认 bootctl 安装。

启动过程：UEFI → systemd-boot → UKI → Linux → RAM 根中的 /init → pizza-maint。
PID 1 进入 bundle 根目录后启动动态程序；portable runtime 的相对 PT_INTERP 和 $ORIGIN RUNPATH 保持可移动性。
新版救援基础镜像中的程序使用绝对 `/lib64/ld-linux-x86-64.so.2`，支持在任意目录运行命令。
镜像中 /opt/pizza/bundle 是部署约定，不是第三方包的固定安装前缀。

现有 PID 1 已支持没有 kexec session 时启动维护应用和 TUI/文本界面。独立 ISO 的磁盘选择和计划编辑界面尚未实现；
持久 journal 也必须由用户明确选择可写存储，不能存入只读 ISO 或易失 RAM 后声称可以恢复。
初版可将全部用户态放入 initramfs；后续依据 RAM 测量决定是否引入 SquashFS。
Secure Boot 需要固件信任的 EFI 签名链，与 GitHub/Sigstore 的产物来源验证是不同环节。

当前交付为可供 kexec 使用的内核与维护 initramfs；`cpu-maint-v1` 基础包已发布为 `v0.4.1`，消费锁及应用组装已完成。ISO、UKI、Secure Boot 还未实现，
不能将它们描述成已发布或已经通过硬件验收的功能。

Web v3 的三阶段同盘事务、恢复容器、固件租约与尚未接通的生产引导路径，
见[同盘维护实现状态](maintenance-session-v3.md)。这些底层组件的单元验收不代表 UKI 已交付。

PID 1 的受控重启、标准 BusyBox 电源命令及失败后的救援 shell 见[电源与救援流程](init-recovery.md)。
完整 Bash/Vim/Nano 和文件系统救援子集需要新的 pizza-bundle 发布；现有签名消费锁保持原发布内容。

参考：[systemd-boot](https://www.freedesktop.org/software/systemd/man/latest/systemd-boot.html)、
[ukify](https://www.freedesktop.org/software/systemd/man/latest/ukify.html)。

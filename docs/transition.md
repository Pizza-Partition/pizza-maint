# kexec 切换与持久化 journal

架构边界见 [维护环境设计](superpowers/specs/2026-10-13-pizza-transition-design.md)，
新 profile 的发布衔接与完整回归见 [实施计划 M0](superpowers/plans/2026-10-21-pizza-maintenance-plan.md)。
当前消费锁为已发布的 `v0.4.1`，维护镜像使用 `cpu-maint-v1`；本次完整回归证据与边界记录在 M0。

`pizza transition build` 校验并暂存计划、匹配的内核和维护镜像；
`pizza transition transition` 加载它们并请求 `systemctl kexec`。
前者不会加载内核，后者会切换正在运行的系统。工程测试只在隔离 QEMU 中调用后者。

## 准备

先将当前构建的 `pizza-init` 和 `pizza-maint` 加入可信基础包，随后生成维护镜像；当前显示为 TUI/文本：

```sh
zig build all image
```

镜像工具同时写出 `zig-out/share/pizza/maint.img.pizza.json`，记录镜像 SHA-256 和模块的 kernel release。
暂存时会核对镜像哈希、bzImage 中的 release 与模块版本，再把副本放入私有 tmpfs。
不要把其他内核的 image 和 modules 混用，也不要手工补写 metadata 绕过检查。

准备一块**独立于原根所在磁盘的 ext4 设备**，在正常系统中挂载，并由 root 建立当前会话专用的
`0700` 目录。例如设备已经挂载在 `/mnt/pizza-journal` 时：

```sh
sudo install -d -m 0700 /mnt/pizza-journal/session-001
```

程序不格式化设备，也不替用户在宿主上挂载设备。当前版本拒绝原根同盘、设备与目录不匹配、
非 ext4、无 UUID、复杂虚拟存储拓扑、bind 子目录和已有 journal。无法确认原根底层设备时也会拒绝。
同一块物理盘上的另一个分区不满足独立磁盘要求。LVM、dm-crypt、MD 和 Btrfs 根的自动拓扑识别尚未支持。

## 暂存和切换

`plan.json` 使用 v2 存储请求，包含目标稳定身份、分区标识和精确字节参数。维护端在硬件身份、独占、几何及独立持久恢复介质准入后编译真实执行步骤。正式入口接受物理块设备；普通镜像仅由测试 fixture 提供。请求格式见[存储架构](filesystems.md)。

```sh
sudo zig-out/bin/pizza transition build \
  --kernel zig-out/share/pizza/vmlinuz \
  --initrd zig-out/share/pizza/maint.img --plan /path/plan.json \
  --journal-device /dev/disk/by-uuid/JOURNAL_UUID \
  --journal-home /mnt/pizza-journal/session-001
```

暂存默认目录是 `/run/pizza/transition`，要求 root 所有、私有权限且位于 tmpfs。
目录中保存内核、追加了受保护交接文件的 initramfs 和文件哈希；持久化的
`plan.json` 与 `transition.json` 写在 journal home 中并 fsync，同时同步目录的祖先到挂载点。会话标识使用随机值，内核命令行不携带秘密。
暂存成功后执行：

```sh
sudo zig-out/bin/pizza transition transition
```

加载前再次检查启动身份、设备 UUID、journal home、状态和暂存文件哈希。
已有其他 kexec 内核时拒绝覆盖；只使用 `kexec_file_load`，不退回旧 `kexec_load`。
权限、lockdown、签名或内存拒绝会报告原因，不请求关机。
只有 `/sys/kernel/kexec_loaded` 确认成功且 `loaded` marker 已 fsync 后，才执行普通的
`systemctl --no-ask-password kexec`，不传 `--force`，不退回 firmware reboot。
关机命令明确失败时，卸载已加载内核并恢复 `staged`；回滚失败会明确报告。

维护环境由静态 `pizza-init` 启动普通 `pizza-maint --session`。维护程序读取仅 root 可读的
`/etc/pizza/session.json`、校验计划哈希和新的 boot ID，按 UUID 重新发现唯一设备，
以 `nosuid,nodev,noexec` 挂载到 `/run/pizza/journal`，再打开原会话目录。
只有匹配的 `loaded` marker 且没有 journal 时才启动执行器。
挂载失败、目录不可信、UUID 重复、状态过期或已有 journal 时，不启动计划，也不使用 RAM 日志继续执行。
维护应用退出后，PID 1 尝试受控重启；收尾或重启失败则进入救援 shell，不自动重试计划。

普通生产会话完成后仍保留维护界面；`--no-ui` 可在暂存时选择控制台模式。
`--test-poweroff` 仅用于显式的 QEMU 测试，必须与 `--no-ui` 一起使用，测试会话完成并被 PID 1 回收后关机。

## 状态与恢复

持久化状态为 `staged → loaded → running → completed/failed`。
可正常处理的中断会写 `interrupted`；SIGKILL、掉电等无法补写 marker 的情形由报告保守核对。已确认的完整计划也保存在同一会话目录，切换中断不会丢掉原计划。
每个 journal 的首条 boundary 包含维护 boot ID、UTC anchor、设备 UUID 和设备内相对路径。
已有会话目录和 journal 都不会自动覆盖或重跑。

回到正常系统、将同一设备挂到任意位置后，可以只读生成报告：

```sh
sudo zig-out/bin/pizza transition report \
  --journal-home /mnt/pizza-journal/session-001
```

报告检查 CRC 有效前缀、步骤状态和设备身份，并同时给出已记录 marker 与核对后的状态。
仅有 intent 的步骤保留为 `in_flight`。已加载但维护端未创建 journal 的会话也可以报告；
报告不会修改 marker、截断日志或恢复执行。

## 验证范围

`zig build test-kexec -- --bundle PATH --kernel-version VERSION` 构造私有虚拟磁盘，
从真实 systemd 经生产 CLI 加载、切换至当前维护程序，执行真实镜像格式化请求，再独立启动读取同一 journal。
同时检查内核禁止加载的拒绝路径、关机命令失败后的卸载/marker 回滚，以及原始只读磁盘的 SHA-256 不变。
`zig build test-transition -Doptimize=safe -- --bundle PATH --memory-budget-kib 2097152`
在同一生产切换路径上检查后端回放的实际步骤 commit 与持久日志一致，
并在独立重启后核对报告。内核默认来自 bundle；
测试宿主不需要安装同版本内核。使用 `--maintenance-image PATH` 可复用已生成且带匹配 metadata 的镜像。

维护 PID 1 以约 100 ms 间隔采集进程 RSS 合计和 `MemTotal-MemAvailable`，记录两个采样峰值。
RSS 合计会重复计算共享页；后者包含 RAM 文件系统与内核。4 GiB 是测试 VM 的配置，
`--memory-budget-kib` 指定验收上限；示例的 2 GiB 上限也不是已确定的生产内存预算。
安全余量在启动应用前固定为 `max(512 MiB, MemTotal/10)`；每个采样点的可用量都必须达到它。短暂跌破会锁存失败，之后恢复不能抵消。报告包含 `memory_total_kib`、`safety_reserve_kib`、`minimum_available_kib` 和 `reserve_breached`，宿主重新计算阈值并强制检查。
这些数据未覆盖源系统暂存、kexec 前的双份镜像峰值、PSS 或短于采样间隔的尖峰；采样不能证明连续时间内从未跌破。

验收运行于隔离 systemd RAM 夹具，原文件系统以只读虚拟盘附加；不是完整发行版镜像矩阵。
Secure Boot 拒绝、物理硬件、旧内核和未来 DRM 显示仍需各自验收。

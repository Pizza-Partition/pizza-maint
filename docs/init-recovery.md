# PID 1 电源与救援流程

`pizza-init` 接收上游 BusyBox 电源命令的标准请求。操作者直接运行 `reboot`、`poweroff`、`halt`；
这些是基础包提供的真实 BusyBox applet 链接，没有同名 shell 函数或 Pizza 私有电源命令。

| 命令或事件   | PID 1 收到的信号 | 动作                     |
| ------------ | ---------------- | ------------------------ |
| `reboot`     | SIGTERM          | 受控重启                 |
| `poweroff`   | SIGUSR2          | 受控关机                 |
| `halt`       | SIGUSR1          | 受控停机                 |
| Ctrl-Alt-Del | SIGINT           | 受控重启                 |
| SIGHUP       | SIGHUP           | 停止应用并打开救援 shell |

这是 BusyBox 的 init 约定；依赖 systemd 总线的另一套 `shutdown`/`systemctl` 程序不能直接替代它。
init 启动时关闭内核直接处理 Ctrl-Alt-Del 的模式，使其进入上述收尾流程。

初始化失败、PID 1 panic 或普通维护应用退出也触发受控重启。PID 1 向其他进程发送 SIGTERM，
最多等待 10 秒并回收直接子进程和收养的孤儿；未退出则发送 SIGKILL，再等待 2 秒。
随后辅助进程读取 `/proc/self/mounts`，按逆序对持久挂载执行 `syncfs` 和普通卸载，最后 `sync`。
RAM 和内核伪文件系统保持挂载。辅助进程最多等待 15 秒；收尾失败或超时都进入救援，不能当作同步成功。
最终只有 `core/init/power.zig` 调用内核电源接口。电源调用失败或意外返回也进入救援。

救援 shell 是 PID 1 的独立子进程，使用新 session 和实际控制终端，支持作业控制。
优先启动 Bash，启动失败则回退到包内静态 BusyBox `sh`；退出后重新启动。
两者都无法启动时，PID 1 继续回收子进程并接收电源或救援信号。
救援流程不自动重新执行维护计划；手动恢复后需依据持久 journal 判断后续操作。

shell 保留正常 root 权限；内核按照 `CAP_SYS_BOOT` 判断电源调用权限。
上游 `reboot -f`、`poweroff -f`、`halt -f` 可以直接调用内核，绕过 init 的受控收尾。
自有软件只在 init 中执行最终电源操作，这项代码组织规则不会限制操作者使用上游工具。

完整救援环境来自 pizza-bundle 的 SystemRescue 文件系统救援子集，包含 Bash、Vim、Nano、
离线手册及分区、文件系统、LVM/RAID/LUKS 和数据恢复工具。静态 BusyBox 同时提供最后一级 shell 和电源命令。
新基础包尚待构建、认证并发布；消费仓库不将本地测试产物写入现有签名发布锁。

## 隔离验证

```sh
zig build test-init-recovery -- \
  --base /absolute/path/to/rescue/pizza-base-x86_64.img \
  --kernel /absolute/path/to/rescue/vmlinuz
```

调度器使用 Zig，通过项目现有的 newc/gzip 编码器构建测试覆盖层，无 Python 或 bsdtar 运行依赖。主机需提供 QEMU、mkfs.ext4、e2fsck 和 debugfs。
它启动生产 init 和专用故障注入 fixture，验证真实 `reboot`、`poweroff`、`halt`，
重启失败后的 Bash、静态 shell 回退、控制终端、shell 重启、panic、SIGKILL 收尾、同步超时和双 shell 失败。
持久化测试只向新建的 32 MiB guest 磁盘写入文件，关机后检查文件和 ext4 状态。
强制电源模式仅在 guest 中验证；主机不执行重启、关机或块设备写入。
故障注入选项只存在于测试 fixture，不加入生产启动参数。

2026-10-25 本地验收：上述 9 个 QEMU 场景全部通过，`zig build test` 的 65 项测试及
`zig build check fmt-check` 通过。基础镜像使用本地 SystemRescue 子集，并追加与新版构建脚本一致的
三个 BusyBox 命令链接；没有将该测试镜像冒充已认证发布。结果保存在
`/tmp/pizza-init-recovery-acceptance/results.json`，各场景目录包含串口日志。
生产端的 7 项包策略测试通过；隔离 scratch 容器在两次重定位后均启动 105 个救援命令并通过文件系统检查。

2026-10-25 以仓库锁定的 Zig 0.17.0、Safe 模式完成纯 Zig 入口复验：生产流程、持久化、
`reboot`、`halt`、BusyBox 回退、panic、顽固子进程、同步超时、双 shell 不可用共 9/9 场景通过。
使用本地包含真实 BusyBox 电源链接的新基础层；它仍是尚未发布的测试基底，不修改消费发布锁。
命令与串口记录保存在 `test/artifacts/qemu/init-recovery-zig-20261025/`，包含 32 MiB 持久化夹具。
测试覆盖层由 Zig 原生编码，不再通过 Python/tarfile 或 bsdtar 转换。全量项目测试、构建、
检查与格式检查通过；该轮记录 113/113 构建步骤与实际执行的 32/32 测试，其余测试复用缓存。

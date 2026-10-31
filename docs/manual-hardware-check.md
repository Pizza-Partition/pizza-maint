# Manual hardware validation procedure

本流程对应 [实施计划 M1/M2/M4](superpowers/plans/2026-10-21-pizza-maintenance-plan.md)。`v0.4.1` 基础包和当前应用的隔离 QEMU 验收已通过，实机尚未验收。

仅在 VM 全量验收通过、核心模拟探针完成后执行。使用可牺牲的测试机器和模拟 plan；
在引入真实 storage 操作之前完成。生产切换命令见 [transition.md](transition.md)，当前计划仍只执行模拟步骤。

1. 记录硬件、CPU ISA、固件、GPU、NVMe/controller、内核和模块版本。确定 journal
   home 不在未来被卸载/修改的 filesystem 上。保存 serial/remote console 记录。
2. 建立可用的外部恢复启动途径。首次测 Secure Boot/lockdown 拒绝：确认拒绝后
   原系统仍运行，日志/marker 没有错误进入 loaded 状态，输出包含具体拒绝原因。
3. 验证固定的 pizza-bundle 归档摘要与 GitHub attestation；检查对应发布的测试记录，并验收基线 CPU 和内核要求。验证 session secret
   不写入持久盘、程序日志或 kernel boot 日志。
4. 仅加载 kernel：确认内核 image 与 modules 完全匹配，`kexec_loaded=1`，暂不
   切换。核对 staged/loaded marker 生命周期与取消路径。
5. 做模拟往返：RAM root、原根 ro（明确 journal 例外）、20 步、durable intent/
   commit、正常 reboot、完整 report。检查原根内容和 journal 的独立持久性。
6. 验收终端仪表盘与文本降级，确认显示失败时执行器和 journal 继续按约定运行。
   后续接入原生 GUI 后，补测 UEFI framebuffer、simpledrm、DRM 与 kexec 显示交接。
7. 分别注入 终端初始化失败、journal 不可用、fsync failure、step failure 与
   intent 后 interruption。journal 不可靠时应拒绝启动或在下一边界停止执行。
8. 采集双阶段内存峰值、总 RSS/PSS、tmpfs/bundle 和内核开销，对照已确定的预算。
9. 核查 `systemctl kexec` 的服务停止、文件系统卸载与控制器 quiesce 行为；单独
   记录 firmware/driver 相关失败，不用直接 syscall 的 VM 结果替代它。

每个 case 保存机器标识、工具链/bundle hash、kernel release、cmdline（删除 secret）、
journal 与时间线，以及失败时的恢复动作。任何未运行 case 保持“未验证”。

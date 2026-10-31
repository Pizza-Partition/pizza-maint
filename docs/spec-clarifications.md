> 2026-10-19 更新：第三方运行环境由独立 pizza-bundle 流水线通过成熟工具组装、测试、证明来源并发布。
> pizza 通过固定摘要、仓库 ID、workflow、tag 与 commit 验证来源后消费，不再重复审计依赖内容。
> 旧的本地包收集、manifest 文件哈希和原生 bundle 部署要求被 [dependencies.md](dependencies.md) 取代。

# Implementation findings and open spec constraints

2026-10-21 修订：静态 `pizza-init` 监护普通 `pizza-maint`；业务、journal 与 TUI 同进程。
浏览器显示和 JS/native 通道已删除。第三方运行环境由独立生产者发布，消费端按固定摘要与 Sigstore 验证。
当前架构以 [主设计](superpowers/specs/2026-10-13-pizza-transition-design.md) 为准，后续验收见 [实施计划](superpowers/plans/2026-10-21-pizza-maintenance-plan.md)。

1. **原根只读与日志写回原根不能同时成立。** 即使把同一个 ext4 设备再次挂成 rw，
   journal 的底层写入仍会改变原根内容；bind mount 不会提供独立的持久化。可选
   方案是明确允许专用日志区域写入，或改用独立 journal device。外部实验用了独立
   虚拟盘，所以证明了切换与持久化机制，但没有证明原 spec 的 root-path 组合。

2. **自带 glibc 的约束是 bundled symbol versions、CPU ISA 和内核 ABI。**
   正确隔离后，宿主 glibc 的版本不会参与加载。RHEL 8 / Ubuntu 20.04 的旧内核
   仍必须跑矩阵；宿主 libc 版本只是来源信息。外部实验发现本机 glibc 要求
   x86-64-v4，首次 QEMU 启动因非法指令失败。默认 Zig 输出和 ELF 审计因此
   显式采用基线 ISA。此前独立实验改用官方 Arch glibc 2.44 的基线包并完成切换；当前 `v0.4.1` 也已通过实际应用的 systemd/kexec 回归，
   不需要自编 libc。GNU property note 缺失不等于机器码已被证明兼容；最终
   仍需在基线 VM 中运行。

3. **驱动与固件只来自固定包。** 生产者从固定内核镜像提取配置、从配套模块树解析依赖，
   使用 cpio 打包显式输入树。通用配置不含外部固件，不存在宿主收集或回退；详见 [dependencies.md](dependencies.md)。

4. **nonce 放在 kernel cmdline 无法保证“从不记录”。** Linux 的启动日志和
   `/proc/cmdline` 可暴露它。降低 console loglevel 不能清除 kernel ring buffer。
   可以考虑在 tmpfs 中的 session initrd 注入受保护文件，或设计其他 RAM 交接
   通道。当前通过受保护 RAM 文件交接。

5. **内存预算没有数值。** 应先定义内存上限与统计口径：总进程 RSS/PSS、kernel、
   tmpfs 解压后的 bundle，以及 kexec 前后的双份常驻峰值。外部最小环境中
   `getrusage().ru_maxrss` 返回 0，而 `/proc/self/smaps_rollup` 显示 PID 1 RSS
   112 KiB；0 不能算有效峰值数据。未来图形界面的预算可行性仍未验证。

6. **“拒绝前无状态变化”与 marker 写入次序需要定义。** 完整性/环境检查失败不应
   留下 staged marker。`kexec_file_load` 拒绝时，应恢复 staged 状态；只有确认
   `kexec_loaded` 后，才能建立可被后续启动解释的 loaded marker。用户会话的
   nonce 不应随 marker 写盘。

7. **日志 header 原先没有定义 padding/byte order/phase 数值。** 当前协议源
   明确 64 字节、小端字段与 offsets。时间线跨 boot 的 UTC anchor、boot id、
   journal home 应放在 boundary payload，不能依赖重新从 0 开始的 monotonic
   时间。JSON 的 seq 使用十进制字符串。

8. **后端验收与显示验收独立。** `test-backend` 验证日志分批回放，VM 后端测试确认应用退出由静态 PID 1 回收。
   `test-transition` 检查生产切换、后端回放、持久 journal、恢复报告与内存采样；不声明图形输出通过。

9. **后续图形路径。** 固定内核已经内建 simpledrm 和系统 framebuffer 支持；Blend2D + DRM 尚未接入。
   UEFI 冷启动能够提供 framebuffer 不代表 kexec 后必然可用，需验证宿主 GPU 驱动交接和显示状态。

10. **模拟执行的显式边界。** `pizza-maint --execute` 只接受全新的 journal 和 20 个
    simulated step。独立 `--execute` 模式由调用方预先选定并持久化 journal home，应用只检查目录所在文件系统；
    生产 `--session` 模式另有设备身份校验与日志设备挂载，两种路径不能混为一谈。旧 journal 无论完整、失败、挂起或尾部损坏均拒绝重跑。
    同进程 writer 通过已持锁 FD 向 UI 提供 fsync 确认过的前缀，不再次获取自身的文件锁。
    注入 fsync 失败后，重启时可能仍读到有效 intent；这仍保守归类为 `in_flight`，不证明步骤已执行。

11. **生产 journal 的当前选择。** 保留原根只读，要求显式指定独立物理磁盘上的 ext4
    设备及其已建立的私有目录；不写回原根。暂存和加载端核对设备、实际挂载目录、
    UUID、哈希和 boot ID，维护应用在 RAM 根中按 UUID 重新挂载。复杂存储拓扑未支持时
    明确拒绝。生产命令和状态流转见 [transition.md](transition.md)。普通应用负责
    journal 的挂载和业务执行；PID 1 仍只负责初始化、模块加载与监护。

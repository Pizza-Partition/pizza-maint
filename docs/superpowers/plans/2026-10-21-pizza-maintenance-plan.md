# Pizza 维护环境实施计划

更新：2026-10-22。架构依据：[维护环境与启动切换设计](../specs/2026-10-13-pizza-transition-design.md)。
本文跟踪剩余工作与验收门，不将本地源码、发布产物、基础镜像和完整应用的状态混为一项“完成”。

## 1. 已完成的本轮变更

- [x] 删除两仓库的 WebKit/WPE、执行网页、消息 bridge、前端构建与相关浏览器运行依赖。
- [x] 保留同进程业务后端、journal、模拟执行器和 libvaxis TUI/文本显示。
- [x] 固定 Linux 7.2.11 与配套模块，只从生产者包根解析依赖，删除宿主收集和回退。
- [x] 由标准 cpio/gzip 打包显式输入树；基础层没有 `/init` 或 Pizza 应用。
- [x] 从内核镜像验证 EFI / SYSFB / simpledrm 内建配置；固件默认空清单，出现声明即拒绝隐式收集。
- [x] 扩充 19 种文件系统和必要通用存储、输入、NLS 支持。
- [x] 按生产者工具清单打包 40 个命令、libblockdev fs 插件、运行库和包配置。
- [x] 本地 Zig 单元/集成、协议检查和业务后端回放自检通过。
- [x] scratch 中两次目录移动通过：命令启动、11 个 fs 技术依赖检测及包外库映射检查。
- [x] 新基础镜像在 QEMU 中通过：27 个模块、19 种文件系统注册、ABI 与 fs 插件检查。
- [x] 基础镜像测试 init 挂载 devtmpfs/sysfs/proc，并提供与维护环境一致的包内 PATH。

“工具能启动”和“插件依赖可用”不表示已接入或验证真实磁盘修改。
以上为代码与基础层验收；正式发布和新 profile 完整应用切换已完成，见 M0。原生图形显示仍未实现。

## 2. M0：发布衔接与完整应用回归

状态：2026-10-21 已完成，覆盖当前 Pizza 工作树与正式发布的 `cpu-maint-v1`。发行版矩阵、实机及图形显示仍按后续阶段单独验收。

| 顺序 | 交付物                                     | 验收门                                                                                                     |
| ---- | ------------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| 0.1  | 修正 `core/init/supervisor.zig` 的动态探针 | 使用包内动态 coreutils `bin/true --version`；保留动态执行、子进程回收与失败检测，不恢复 bubblewrap         |
| 0.2  | 发布新的 pizza-bundle                      | 从固定输入重建，在发布流水线通过模块边界、scratch 移动与基础镜像 QEMU 测试，生成三个基础产物及 attestation |
| 0.3  | 更新 Pizza 发布锁                          | 使用 0.2 的真实 tag、commit、三个 SHA-256 和来源证明；验证新 profile 通过，旧 profile 或篡改内容仍拒绝     |
| 0.4  | 组装当前应用                               | `bundle` / `image` 只加入当前静态 init 和动态 maint；布局无 panel、无宿主收集；基础层保持原字节            |
| 0.5  | 运行新 profile 完整回归                    | 维护监护、backend、模拟执行故障、生产 kexec、独立重启报告和内存采样都使用同一组新输入                      |

- [x] 完成 0.1：动态探针更换，维护监护自检通过。
- [x] 完成 0.2：正式发布 `v0.4.1`，带真实 attestation。
- [x] 完成 0.3：消费锁固定真实提交与三份摘要，原生 Sigstore 验证通过。
- [x] 完成 0.4、0.5：应用组装、维护监护、镜像内后端、执行故障恢复和完整生产切换通过；已保存串口、命令、输入摘要、journal、报告和结果 JSON。

发布结果与本地验收记录如下，均为实际运行结果。
旧发布的签名测试 fixture 可以继续用于验证密码学策略，但不能充当新基础包的运行验收。

完整回归入口如下；运行时需有已验证的发布和当前应用层：

```sh
zig build test check fmt-check
zig build bundle image -Doptimize=safe
zig build test-maintenance -- --bundle zig-out/runtime/bundle --kernel-version 7.2.11-arch1-1
zig build test-maintenance -- --backend --bundle zig-out/runtime/bundle --kernel-version 7.2.11-arch1-1
zig build test-executor -- --bundle zig-out/runtime/bundle --kernel-version 7.2.11-arch1-1
zig build test-kexec -- --bundle zig-out/runtime/bundle --kernel-version 7.2.11-arch1-1
zig build test-transition -- --bundle zig-out/runtime/bundle
```

### 本次交付与证据

- 发布：[v0.4.1](https://github.com/Pizza-Partition/pizza-bundle/releases/tag/v0.4.1)；生产者提交 `d6729057a02482852274427ecfaa2580161ee448`；[发布流水线](https://github.com/Pizza-Partition/pizza-bundle/actions/runs/39596637458) 全部通过。
- `v0.4.0` 的测试与来源证明通过，发布步骤遇到容器 Git ownership 检查；修复为显式指定发布仓库后使用新标签 `v0.4.1`，未改写旧标签。
- Pizza 消费锁：[release.json](../../../config/bundle/release.json)。本次消费与应用验收针对当前工作树，不表示这些 Pizza 源码更改已发布。
- 联网刷新 TUF 后通过原生 attestation 验证；后续 VM 测试使用同一未过期的已认证缓存，显式选择离线验证。
- `bundle image` 通过，基础层原始字节与发布锁一致；本次应用 initramfs SHA-256 为 `75116f5e105a5013fa2fd3b441d1624ef84a6ec121ed10529091912e0499e5d8`。
- 维护监护与镜像内后端均通过；执行器完成 20 步，并通过失败停止、挂起中断、fsync 前拒绝工作、torn tail、两次启动恢复和只读报告检查。
- `test-transition` 覆盖实际 systemd/kexec、加载拒绝和回滚、生产 session、20 次 commit、CRC、原盘 SHA-256 不变及独立重启后报告，全部通过。
- 本次维护阶段采样峰值：进程 RSS 合计 6368 KiB，`MemTotal-MemAvailable` 514788 KiB，52 次采样、名义间隔 100 ms；仍不代表产品预算或源系统暂存峰值。

本地证据位于 `/tmp/pizza-v041-maintenance`、`/tmp/pizza-v041-backend`、`/tmp/pizza-v041-executor` 与 `/tmp/pizza-v041-transition`，包含 `command.json`、`serial.log` 和 `results.json`；切换目录还保存输入、marker、plan、journal 和报告。
构建与验签日志为 `/tmp/pizza-v041-integration.log`，发布 CI 日志为 `/tmp/pizza-bundle-v041-release-ci.log`。这些路径为本次机器的临时验收产物。

## 3. M1：发行版、故障与资源基线

可以先准备夹具；对新 profile 的结论以 M0 的完整输入为准，不必等待图形实现才开始。

- [ ] 为 `test/matrix/targets.json` 中的 Ubuntu 20.04/24.04、Debian 12、RHEL 8/9、Fedora、Arch 提供明确版本、镜像与摘要。
- [ ] 检查 bundled loader/glibc、x86-64 基线 ISA 和旧内核 ABI；不能用宿主 glibc 版本推断兼容性。
- [ ] 在配置指定的三个目标上补充完整切换验证；其他目标分别记录 ABI 结果。
- [ ] 对拒绝加载、关机失败回滚、应用退出、持久化失败、挂起和 torn tail 保存独立证据。
- [ ] 检查 fault 配置中的每个参数是否已有实际消费者；只有被解析的参数不得写成已实现的故障注入。
- [ ] 定义产品内存上限与统计口径，覆盖 RAM 根、内核、进程和源系统 kexec 暂存；补充当前采样遗漏的峰值。

验收要求：失败结果保留为失败，缺失夹具标记未运行；ABI 通过不能替代整机切换通过。

## 4. M2：DRM + Blend2D 原生显示

此阶段是后续实现；当前只具备内建 simpledrm 等内核前提。

- [ ] 生产者显式加入固定来源的 Blend2D、所需 DRM 用户态支持、字体和资源，并重新验证依赖闭包。
- [ ] 在 `pizza-maint` 中添加原生显示模块，直接消费 Backend 的已提交状态，不引入网页或 JS 消息通道。
- [ ] 区分 CPU 图像生成和 DRM 输出；验证设备/输出选择、模式、像素格式、pitch、dumb buffer、提交和释放。
- [ ] 保留 TUI/文本降级；图形初始化或刷新失败不能改变 intent/fsync/commit 顺序。
- [ ] 单独验证整个应用进程崩溃的中断语义，不把同进程渲染设计描述成进程隔离。
- [ ] 使用可见画面或像素证据验证冷启动输出，不能只检查模块或 `/dev/dri` 节点。
- [ ] 通过实际生产 kexec 路径验证 framebuffer 交接，并记录宿主原生 GPU 驱动改变显示状态的情况。

验收要求：Blend2D CPU 像素实际显示；缺少可用 framebuffer/DRM 输出时保留诊断与业务边界。
若需要专用 GPU/控制器驱动或固件，应在生产者设计显式硬件配置，不能恢复宿主扫描作为兜底。

## 5. M3：真实存储引擎与能力矩阵

2026-10-22 架构调整：移除第三方文件系统执行绑定，改为原生格式适配器与统一事务核心。2026-10-21 的第三方工具测试在下方保留为历史证据，不表示新引擎已完成任何文件系统修改。

- [x] 移除应用的 libblockdev/GLib/libblkid C 翻译、链接、开发包和 doctor 依赖，以及旧调用与矩阵执行器。
- [x] 建立只读适配接口、卷特性能力门、有界事务、范围冲突与计划摘要校验。
- [x] 实现独立数据复制的有界并发、失败后等待全部工作结束、元数据所有者提交。
- [x] 实现私有镜像旧元数据持久记录和适配器无关恢复；不开放生产设备。
- [x] 接入 ext2/3/4 的 libext2fs 只读查询与分配元数据检查；固定源码、配置生成、C 编译和 translate-c 绑定全由 Zig 构建步骤实现。
- [x] 接入 ext2/3/4 的暂存库写入、统一执行入口、创建/计数修复/缩扩容，完成私有镜像真实尾部文件块搬移及回滚验收。
- [x] 接入 FatFs R0.16 静态库及 Zig FAT32 后端，开放六种操作，复用通用事务与恢复；构建按 `build/filesystem/{ext,fat32}/` 分开组织。
- [x] 接入固定 NTFS-3G 2026.9.28 源码与 C→Zig 绑定，开放 NTFS 六种操作，修复限定为可信主元数据下的备份引导重建；构建归属 `build/filesystem/ntfs/`，设备写入仅进入共用暂存与 undo 事务。
- [ ] 完成完整 inode/extent/目录/journal 健康检查与修复、持久大任务暂存和物理设备断电验收。
- [ ] 完成持久活动组索引、检查点、源租约与恢复区回收，接入独立启动保护。
- [ ] 在生产者新版本清理旧工具/插件闭包，重新发布后更新消费锁；不改写现有签名产物。

本轮原生验证：`zig build test check fmt-check test-storage` 通过；原生存储具有独立测试根，7 项单元测试通过。镜像诊断包含 10 个事务场景：1 次未开始修改、7 次回滚、2 次保持提交，包含一次回滚再次中断。并发测试使用双工作任务屏障，验证实际同时在途；失败测试验证返回前已回收所有工作。动态依赖检查确认维护程序不再链接 libblockdev、GLib、libblkid。`safe` 构建和同一镜像诊断通过。

以上原语结果仅覆盖私有普通文件、进程内故障注入与关闭后重新打开。后续已增加 `test-filesystems`：以真实 ext2/3/4 镜像验证查询、分配检查、创建、计数修复、缩扩容、尾部用户数据搬移与精确撤销；VM 断电和独立恢复启动仍待验收。

2026-10-22 FAT32 增量验收：共用文件系统套件及格式特有用例共 21 项通过，覆盖多扇区尺寸、FAT 表增长、缩容重分簇、嵌套中文目录、孤儿环保留、坏簇和活动 FAT、歧义镜像与交叉链拒绝。共用掉电模型扩展为四个格式入口、32 组真实文件系统案例；协议基准仍为 5,940 组。随机 SIGKILL 种子 `20261022` 的 64 轮通过，13 次在写入阶段中断、12 次恢复进程中断；逐字节撤销及独立 fsck/文件内容校验通过。所有结果限于私有镜像。

2026-10-22 NTFS 增量验收：`safe` 模式的 `test test-storage test-filesystems check fmt-check` 共 95 个构建步骤通过，文件系统套件增至 26 项。覆盖 NTFS 扇区/簇尺寸、Unicode 与命名数据流、真实尾部搬移（清零已释放旧副本）、脏卷/休眠/损坏已分配 MFT 记录拒绝、原始读错误保留与规划失败后的会话清理。共用真实文件系统掉电模型增至五个格式入口、40 组，协议模型仍为 5,940 组。种子 `20261022` 的 80 轮 SIGKILL 通过，15 次在写入阶段中断、14 次恢复进程中断；独立 ntfsfix/ntfsresize 与文件内容检查通过。检查/修复仍限定分配元数据范围，不替代 Windows chkdsk；物理设备写入仍关闭。

当前接口、实现与故障验收范围以 [filesystems.md](../../filesystems.md) 为准。下面为已退役执行路径的历史记录。

2026-10-21 已实现隔离文件系统引擎与首轮能力矩阵。生产真实设备入口尚未开放，M3 整体仍未完成。接口和逐操作边界见 [文件系统引擎](../../filesystems.md)。

- [x] 定义 libblockdev 接入边界、工具子进程生命周期、错误映射，以及不阻塞主循环的串行工作线程；阻塞 C 调用不能安全强制取消，关闭时等待，不补记 commit。
- [x] 区分常见文件系统的六类操作、挂载条件、实际依赖与执行策略；内核支持不自动授权修改，F2FS resize 和破坏性 Btrfs repair 明确拒绝。
- [x] 在私有镜像和 11 块独立虚拟磁盘中逐项核对元数据、UUID 与哨兵文件。允许操作共 74 次 commit；未支持或隔离的操作不计入通过项。
- [ ] 在任何真实修改前，完成计划校验、设备身份与拓扑复核，并排除原根、journal 设备及其相关存储。
- [x] 执行器单测验证 intent 持久化门、失败停止、commit fsync 不确定性、非阻塞轮询和 `in_flight` 不自动重试；生产真实存储的跨重启报告仍需随会话接入验收。
- [ ] 为未来分区任务界面提供经验证的能力和计划模型；界面不自行选择持久化策略或绕过执行边界。

验收要求：按文件系统和操作逐项发布能力矩阵，禁止将模拟 20 步或工具依赖自检当作真实存储验收。

### 本轮输入与证据

- 源码：`b72f02ba800d12dccc32a69903a2d537ec346bef` 上的未提交工作树；未创建提交或发布新应用。
- 输入：同一 `v0.4.1` 发布锁与 attestation，`cpu-maint-v1`，内核 `7.2.11-arch1-1`。复用原始已认证基础产物和未过期 TUF 缓存，在离线模式下重新验签后组装 `/tmp/pizza-storage-application-v8`。构建图的联网 fetch 因沙箱 DNS 不可用未完成；本次未跳过来源验证。
- 构建：`addTranslateC` 翻译 libblockdev、GLib、libblkid 公共头文件；动态链接运行包内库。结构化 metadata 避免当前 exFAT/F2FS 工具输出与 libblockdev 解析器的不兼容。
- `zig build test check fmt-check test-storage` 通过。包含库失败停止、intent fsync/短写拒绝工作、commit fsync 保留不确定性、挂起工作不阻塞 tick、已有 journal 不重跑、私有镜像独立 debugfs 数据检查。
- `zig build test-maintenance -Doptimize=safe -- --storage --bundle /tmp/pizza-storage-application-v8 --kernel-version 7.2.11-arch1-1 --output /tmp/pizza-storage-matrix-v8 --timeout 150` 通过。实际运行使用 `PIZZA_SIGSTORE_CACHE=/tmp/pizza-v041-sigstore`、`PIZZA_SIGSTORE_OFFLINE=1` 与沙箱可写 Zig 全局缓存。
- ext2/3/4、XFS、Btrfs、VFAT、exFAT、NTFS、F2FS、NILFS2、UDF 共 11 种通过各自允许操作；总计 74 次 commit。每步读取哨兵文件；支持检查的格式在 resize 后追加一致性检查。应用被 PID 1 回收并正常关机。
- F2FS resize **没有通过**：`f2fs-tools 1.17.0` 在缩容再扩容后出现 NAT/SIT 不一致及根 inode 无法读取，尽管工具返回成功。失败日志保留在 `/tmp/pizza-storage-matrix-v7/serial.log`，坏盘夹具为同目录 `f2fs.raw`；最终实现同时在计划和调用层禁用两种 resize。最终矩阵只计 F2FS 创建、查询、检查和干净修复，不将隔离项重新标为通过。
- NTFS resize 的检查标记保留为真实行为；测试计划显式加入独立修复步骤，不在 resize 内隐式清除。NTFS 修复不能替代 Windows chkdsk；所有修复验收均为干净夹具，未覆盖真实损坏。
- 本轮 init SHA-256：`7abfbe14fcdffb062cddf065adcb3963997f43807d2dbec59242753cf5518c29`；maint：`8a50befadc1509d401e30ea4f3f44c85e96ec0d45e6fa37b4857d31285642dae`；实际 VM initramfs：`f48b1878ba3f4fde6e50f0d1dec927e6358f7396fc3fbf213c9d7e4ce12983bf`。
- `/tmp/pizza-storage-matrix-v8` 保存 `command.json`、`serial.log`、`results.json`、`storage-evidence.json` 和私有磁盘；常规测试日志为 `/tmp/pizza-storage-final-tests.log`。VM journal 在 RAM，不能充当跨断电持久性证据。

后续仍需生产设备身份与拓扑排除、持久会话输入和报告、真实损坏修复矩阵、文件系统特性/版本组合，以及 GUI 任务规划接入。当前生产交接继续只允许模拟计划。

## 6. M4：独立 UEFI 启动介质与实机

路线细节见 [boot-image.md](../../boot-image.md)；硬件步骤见 [manual-hardware-check.md](../../manual-hardware-check.md)。

- [ ] 从最终应用 initramfs 组装 systemd-boot + UKI，明确当前方案针对 x86-64 UEFI。
- [ ] 分别制作和验证 ISO 与 USB 磁盘镜像；只操作 staging ESP。
- [ ] 完成无 session 时的任务选择、计划输入与持久 journal 选择；RAM 日志不能宣称可恢复。
- [ ] 分别验收 EFI 签名/固件信任链与 Sigstore 发布来源验证。
- [ ] 在可牺牲硬件上验证显示、存储控制器、kexec、Secure Boot 拒绝及恢复启动路径。

实机过程应从模拟计划开始，在引入真实存储操作前完成相应基础验收。
UKI/ISO 不是当前已发布产物；不得把基础 initramfs 标为可独立启动的完整介质。

## 7. 状态更新规则

每次推进记录日期、源 commit、包/内核输入、发布锁、运行命令、结果和未覆盖范围。
更换 profile、内核、工具快照或显示实现后，重新运行受影响的验收层；代码编译通过不自动提升其运行状态。
本地验证、发布流水线、完整应用、发行版矩阵和实机证据分别维护。

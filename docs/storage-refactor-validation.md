# 存储重构验收记录

日期：2026-10-24。工具链：仓库锁定的 Zig 0.17.0，Safe 模式。自动化验收使用测试镜像或隔离 VM，另按用户授权完成固定 USB 分区实验；物理后端的后续开放与验收另见本文末节。

实现与请求格式见[存储架构](filesystems.md)。本记录使用最终语义虚表、共用规划器和物理执行器；按用户确认，未上线产品不承担旧协议兼容，生产恢复直接调用新恢复器。

当前物理测试入口已统一为纯 Zig 的 `hardware-filesystems`，显式传入空设备与独立恢复目录，依次测试全部已注册格式；历史 `hardware-storage` 和固定 USB Python 调度器已移除。本文旧命令保留为当时的验收记录，当前命令见 [硬件测试说明](../test/hardware/README.md)。

## 本地验收

| 检查                                                         | 结果                                                             |
| ------------------------------------------------------------ | ---------------------------------------------------------------- |
| 构建、协议漂移、格式、存储单元、生产入口与集成测试           | 通过；本次全量命令记录 101/101 项，扩展后的文件系统套件 47/47 项 |
| 六格式的格式化、查询、检查、修复、扩缩容、克隆及独立工具检查 | 通过                                                             |
| A/B 联合调整，六格式的 36 种组合                             | 通过；包含尾部有效数据与强制回滚                                 |
| 4096 字节扇区的 ext4/Btrfs 联合调整                          | 通过；包含中断回滚及独立检查                                     |
| GPT 主备表、表头的分步中断恢复                               | 通过                                                             |
| 非收敛空间需求、历史版本、循环搬移及覆盖                     | 通过                                                             |
| 执行与恢复的掉电、I/O 错误、空间不足边界                     | 通过；恢复后再掉电与重复恢复                                     |
| 取消发生于 undo 流式保护期间                                 | 通过；尚未记录破坏性意图，目标未修改                             |
| 硬件实验入口构建                                             | 通过；当前 v6 仅构建，历史 USB 实验见独立记录                    |

全量命令：

```sh
zig build test-storage test-filesystems test check fmt-check hardware-storage -Doptimize=safe -j4
```

按用户要求，默认稀疏镜像改为约 1 GB：采用 MBR，数据区 1000 MiB，前面保留 1 MiB。两分区初始长度各 524,288,000 字节（500 MiB），最终为 A 838,860,800 字节（800 MiB）、B 209,715,200 字节（200 MiB）；根镜像 1,049,624,576 字节。保持精确的 50/50 → 80/20 比例。程序 462 步，编码 29,091,312 字节。记录的是测试进程实际峰值 RSS，包含元数据和测试夹具，不仅是流式正文缓冲区。

```text
SPARSE_LAYOUT_OK initial_partition_bytes=524288000 final_a_bytes=838860800 final_b_bytes=209715200 root_bytes=1049624576 steps=462 program_bytes=29091312 process_peak_rss_kib=577348
```

## 独立进程中断

通过 120 轮随机 SIGKILL，执行和恢复都使用独立进程，目标写入被测试包装器拆成非扇区对齐片段。最终结果与独立文件系统工具、文件内容核对，重复恢复结果一致。

```text
FILESYSTEM_SIGKILL_OK seed=11954199842033022812 rounds=120 killed=90 write_kills=30 restore_killed=25 committed=30 rolled_back=38 unprepared=52
```

SIGKILL 不清空宿主页缓存；可枚举掉电模型另行覆盖持久化边界。

## VM 与 kexec

QEMU executor 完成两次启动，覆盖真实格式化、身份变化拒绝、意图持久后 SIGKILL、损坏的界面日志、删除克隆源后的恢复。所有断言通过。产物：`/tmp/pizza-qemu-executor-500fc9886fb26ba6b208e8fd86b9fde9`。

完整交接经过 systemd、生产 staging/kexec、维护环境真实执行和独立恢复启动。实际提交 17 步，后端事件序列与持久日志一致；原盘 SHA256 未改变，完成标记与重启报告有效。产物：`/tmp/pizza-qemu-kexec-7d3b7381f52cb4f46c465e92ab497b6f`。

| 内存观测          |     KiB |
| ----------------- | ------: |
| 维护进程 RSS 峰值 |   18820 |
| VM 总有效内存     | 3993852 |
| 固定安全余量      |  524288 |
| 最低可用量        | 3444712 |

安全余量没有跌破。QEMU 结果来自带签名验证的当前基础层与本次应用层，没有绕过 Sigstore 信任检查。

```sh
zig build test-storage-crash -Doptimize=safe
zig build test-executor -Doptimize=safe -- --bundle PATH --kernel-version 7.2.11-arch1-1
zig build test-transition -Doptimize=safe -- --bundle PATH --kernel-version 7.2.11-arch1-1
```

这些结果限定于私有镜像、故障模型及 VM，不等同于真实硬件的反复断电认证。其余五种格式继续报告未实现，已支持格式的保守检查范围保持不变。

## 本次缩小镜像与 USB 复核

默认镜像改为 1000 MiB 数据区后，联合调整过滤套件 4/4 项通过，包含 36 种格式组合和 4096 字节扇区。生产恢复入口改为直接调用新恢复器后，本地构建、存储、主测试、检查与格式检查再次通过；本次测试计数 64/64。

固定 USB 序列号 `FC046CE92485C` 的 FAT32 分区上完成新协议缩扩容、尾部文件搬移、提交前中断、257 字节短写后 SIGKILL、恢复中再次中断和重复恢复；文件及有效范围一致。最终实验分区恢复为空 FAT32，分区表及其他分区保持原状。详见[实盘记录](hardware-experiment-2026-10-24.md)。这项结果限定于 FAT32 单分区，不扩大其他格式或整盘布局修改的实盘验收范围。

## 删除 Adapter 层

删除 `adapter.zig` 及其 Backend/Adapter 类型、重复查询检查虚表和修改入口转发。`filesystem.Registry` 保存统一 Driver，生命周期通过 `probe/open` 虚表分发；打开后的查询、能力检查、枚举、编码与验证均使用 `FilesystemOps`。后端内部不再导入注册表。该阶段仍保留事务故障夹具规划器；后续聚合清理已将它和旧执行链一起删除，见下一节。

迁移后，存储及文件系统验收 91/91 项、主测试与存储验收 64/64 项分别通过，两组包含重复的存储测试。硬件入口构建、检查与格式检查通过。probe 的注册数量字段更新为 `registered_filesystems`，未实现格式原因为 `driver_missing`。

## 旧执行链删除与职责聚合

本次删除 11 个存储目录文件：旧 `plan`、`transaction`、`clone`、`movement`、`plan_builder`，测试 `action`、`fixture_planner`、`legacy_clone`、`legacy_compiler`、旧移动协议测试，以及 FatFs `library` 会话桥。

| 职责                                                   | 当前归属                                      |
| ------------------------------------------------------ | --------------------------------------------- |
| 字节读取、写入与有界摘要                               | `device.Reader / Device`                      |
| 字节修改描述、记录副本及搬移后的编码视图               | `mutation.MutationSet / Builder`              |
| 资源策略、限额、内存压力与分配计费                     | `memory`                                      |
| 格式化、修复、缩扩容、整盘布局及流式克隆编排、最终验证 | `service / algorithm`                         |
| 不可变物理程序、执行、undo、暂存和恢复                 | `program / program_executor / recovery_store` |
| 测试操作及故障注入                                     | `testing/executor`，直接包装生产实现          |

后端输出仅包含新字节及读集，不再携带自行决定的物理搬移计划；`mutation.MutationBuilder.mapRelocation` 只为编码器提供原始来源映射。克隆内容守卫与验证直接使用 `Reader.digest`，不保留仅包装一个校验函数的模块。FatFs 只构建 Unicode 辅助，不构建 `ff.c`，没有挂载会话或磁盘回调。移除 `test-ext` 兼容别名；内存诊断字段改为 `encoding_limit_bytes`。

所有文件系统成功、中断、掉电和内存压力验收均已迁到当前生产计划及执行器。旧协议专属的移动图拒绝规则、进度追加记录和整卷冻结预算断言不再适用；当前测试覆盖循环移动、交叉覆盖、固定状态槽损坏拒绝、完整前映像恢复，以及 128 MiB 克隆在 32 MiB 受控分配预算内成功。保留短写、错误传播、身份变化、源变化、取消、再次掉电、重复恢复、独立工具和文件内容断言。

恢复文件仅保留当前 7 类记录，当前状态和标记升级为 v6，不兼容此前未发布的恢复记录。101 项全量测试通过，含 47 项六格式验收。执行故障模型覆盖 285 个事件位置、17,160 个案例；恢复故障模型覆盖 63 个事件位置、3,840 个案例。另通过本页记录的 120 轮 SIGKILL、QEMU 双启动恢复和完整 kexec 交接。

二进制核对：旧 `PZUNDO01`、`PZREADY1`、`pizza-storage-transaction-v6`、`PZSTATE5` 均不存在；当前 `PZSTATE6`、`PZMARK06` 存在。FatFs 的 Unicode 辅助存在，`f_mount`、`disk_read`、`disk_write` 符号不存在。物理写盘门禁保持关闭；历史 USB 实验属于清理前版本，本次没有重跑实盘。

## 镜像设备移入测试支持

按后续确认，产品不提供普通文件镜像编辑功能。`ImageDevice` 已迁到 `core/maint/storage/testing/image_device.zig`；维护执行器通过 `core/maint/devices.zig` 的设备提供者获取持有生命周期的句柄。正式入口在打开路径前拒绝镜像目标，继续保留物理写盘门禁。生产 probe 不打开镜像；分区与文件系统查询接受通用只读 Reader。

镜像提供者及入口分别位于 `core/maint/testing/devices.zig`、`core/maint/testing/main.zig`。独立的 `pizza-maint-fixture` 仅由显式构建步骤或验收依赖生成，默认产品安装不包含它。CLI 镜像查询、QEMU executor 与 kexec 验收使用该入口；QEMU 只修改一次性维护镜像副本，保留原始 bundle。规划、执行、恢复与应用循环继续共用正式代码。

另补充维护模块独立测试根：依赖导入不能作为运行这些测试的证据。`zig build test-maint-executor` 实际运行 6 项测试，包含镜像/物理路径拒绝、提交后重开、请求不匹配、取消恢复及原有模拟执行器断言，并已接入默认 `test`。

本轮验证：

- `zig build test test-storage test-filesystems check fmt-check maintenance-fixture hardware-storage -Doptimize=safe -j4 --summary all`：111/111 构建步骤通过，本次实际执行 67/67 测试通过，其余使用缓存；六格式套件完整运行 47 项。
- 新增独立维护测试入口：33/33 构建步骤、6/6 测试通过。
- QEMU 双启动执行与恢复：所有断言通过，包含删除克隆源后的恢复、身份守卫、SIGKILL 和损坏的界面日志。产物 `/tmp/pizza-qemu-executor-cefbde6e67b5fd100bf20d449b8c1d79`。
- 完整 kexec/transition：17 个真实步骤、1,050,112 字节完成，跨启动报告、内存余量和原盘哈希核对通过。进程峰值 RSS 18,900 KiB；产物 `/tmp/pizza-qemu-kexec-19d897e83b7999a0491f63f320ff0726`。
- 二进制核对：正式 `pizza-maint` 不含 `probe-image`、测试镜像实现路径及 `ImageDevice.open`；独立测试程序包含它们。本轮未运行 USB 实验，也未开放生产物理写盘。

## 正式物理块设备入口（2026-10-24）

本节替代前面阶段记录中“物理写盘关闭”的当前状态描述。`BlockDevice` 提供稳定硬件身份、独占打开、直接读写、扇区核验、独立恢复介质准入与提交后内核分区表重读；正式维护入口经这些检查后获得写能力。镜像设备仍仅存在于测试。

QEMU 分别在 512 字节与 4096 字节逻辑扇区上使用正式程序执行，覆盖提交、身份拒绝、挂载目标拒绝、同盘恢复目录拒绝、SIGINT 自动恢复、SIGKILL 与移除克隆源后的第二次启动恢复。独立文件系统检查核对结果。固定 USB 分区上的正式入口验收另见 [生产物理入口实验](hardware-production-2026-10-24.md)。本轮不包含真实拔电测试。

当前物理后端实现后的本地回归命令：

```sh
zig build test test-storage test-filesystems check fmt-check maintenance-fixture hardware-storage -Doptimize=safe -j4 --summary all
```

该轮 111/111 构建步骤、87/87 实际执行测试通过（含六格式 47 项）。修复 Btrfs 目录 ioctl 后，主测试、维护入口、存储与检查再次通过，103/103 步、62/62 实际执行测试；其余使用缓存。

| 最终应用层 VM 回归        | 结果与产物                                                        |
| ------------------------- | ----------------------------------------------------------------- |
| 正式块设备，512 字节扇区  | 通过；`/tmp/pizza-qemu-executor-cfda685b18dad5ce498fc50130f1521a` |
| 正式块设备，4096 字节扇区 | 通过；`/tmp/pizza-qemu-executor-e36ef53999cce63913b024623da491f2` |
| 独立镜像 fixture          | 通过；`/tmp/pizza-qemu-executor-9c2922b8d782bf5e8cd9ceec4dcea1ad` |

三轮均完成两次启动，包含 SIGINT 自动恢复、SIGKILL、重复恢复、克隆源移除及只读报告；物理设备两轮还核对同盘恢复目录拒绝和独立 FAT32/ext4 检查。USB 正式入口完成取消、SIGKILL、重复恢复、40 GiB 缩扩容及空 FAT32 清理；原文件两份备份、分区表及分区 2 完整哈希保持一致。

完整 systemd/kexec/transition 回归通过，17 个真实步骤、1,050,112 字节提交，后端重放、跨启动报告、恢复边界和原盘哈希均通过。维护进程峰值 RSS 18,928 KiB，最低可用内存 3,437,912 KiB，高于 524,288 KiB 安全余量。产物：`/tmp/pizza-qemu-kexec-5eb0bbc6f05515ed414ef374f35fb268`。

最后运行 `test-storage test-maint-executor test check fmt-check hardware-storage`，全部构建与检查通过；格式检查后再次运行 `git diff --check` 通过。

## 六格式 USB 矩阵（2026-10-25）

同一固定 USB 分区上完成 ext2、ext3、ext4、FAT32、NTFS、Btrfs 六种文件系统的单分区操作与恢复验收，各 28 项，共 168 项；加上确定性窗口初始化与清理，共 170 项通过。格式化、查询、检查、已知缺陷修复、尾部搬移、缩扩容、克隆、取消、执行及恢复中 SIGKILL、重复恢复均有对应证据。独立只读镜像作为克隆源，目标为真实 USB；同盘克隆继续拒绝。

最终通过正式入口恢复为原容量空 FAT32，真实分区表、磁盘首尾、分区 2 完整 SHA-256 与 12 个原文件的两份备份再次核对一致。详情、输入范围及未覆盖边界见[六格式实盘报告](hardware-filesystems-2026-10-25.md)。本轮没有改写真实 GPT/MBR 或做拔电测试。

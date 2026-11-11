# Pizza maintenance

Pizza 的 Linux 维护系统：PID1、维护界面、storage、物理程序编译、事务执行与恢复。
基础镜像、内核和模块来自独立 pizza-bundle 的固定发布；桌面用户界面属于 pizza。
本仓库不构建桌面程序或单独的特权 helper。

使用 Zig 0.17.0。`config/bundle/release.json` 固定基础发布来源和摘要。

Zig 编译步骤（含测试、生成工具和协议导出工具）默认启用 incremental。
`build/compile.zig` 统一链接器配置：Windows 使用 Zig 的 `Coff.zig`，Linux 使用
`Elf2.zig`，均不使用 LLD。维护系统本身仍面向 Linux；此配置不会增加 Windows 维护系统支持。
直接调用 `build-exe` 的维护程序构建同样启用 `-fincremental`，并显式登记源码监听依赖。

开发监听入口同时启用 `-fincremental --watch`；额外构建参数放在 `--` 后：

```sh
zig build dev
zig build dev -- test-storage-unit
# 等价的直接调用
zig build -fincremental --watch test-storage-unit
# 独立协议包的开发测试
cd protocol
zig build -fincremental --watch test
```

CI 和发布继续使用下方的单次构建命令。

```sh
zig build check check-proto
zig build test-session test-maint-session-image
zig build test-storage-unit test-filesystems test-storage-crash
zig build protocol-package
zig build image -Doptimize=safe
```

后端和跨进程验收均使用 Zig：test、std.testing、std.process.run。测试不依赖
Python。维护会话验收生成临时普通镜像，再在独立进程中调用同一个会话执行器，
覆盖 bootstrap、apply、recover、undo、accept 和 cleanup；测试不会访问真实磁盘。

`protocol/contract.json` 是唯一 wire 协议来源，当前版本 v4。
`zig build proto` 更新 Zig、JavaScript 和 TypeScript 绑定，`check-proto` 检查漂移。
`protocol-package` 输出 `zig-out/share/pizza/protocol` 和可供 `zig fetch --save=pizza_protocol` 消费的 `zig-out/share/pizza/pizza-protocol-4.0.0.tar.gz`。归档包含 README、绑定与内容哈希清单；文件顺序、权限和时间戳固定。
协议包发布于 https://github.com/Pizza-Partition/pizza-protocol；v4.0.0 的 release 归档由本导出入口生成，桌面仓库通过 `zig fetch` 固定发布 URL 和包哈希。
桌面仓库只消费该包和维护发布产物，不链接本仓库的 storage。
协议版本不兼容直接拒绝；恢复日志格式版本独立管理。
终态返回通过 Loaded.finish 发布有界 CompletionReceipt 并读回核对，失败则保留维护启动。
该接口要求平台提供绑定至已准入 ESP 预分配范围的持久收据存储；具体平台适配与
宿主 complete-session 导入尚未接通，不应将接口/故障测试视为完整报告返回验收。

核心路径：

| 路径                         | 内容                                               |
| ---------------------------- | -------------------------------------------------- |
| core/init                    | 静态 PID1、挂载、驱动加载与进程监护                |
| core/maint                   | 维护状态、journal、storage 及执行后端              |
| core/restart                 | 离线查询与编译、ESP 恢复锚点、分阶段会话及引导绑定 |
| ui/execution                 | 维护终端界面                                       |
| protocol                     | 独立协议包                                         |
| build/bundle、core/initramfs | 验证固定基础产物、组装应用层和 initramfs           |
| test                         | Zig 回归、普通镜像测试与 QEMU 夹具                 |

已删除旧内核切换实现；所有接管必须完整重启。当前拆仓后的普通镜像会话验收可用，
但 ISO/UKI 发布、桌面 ESP 准备、PID1 接管 v4 会话、完整重启、报告返回的产品闭环
尚未全部接通或通过 OVMF 验收。不能把这些测试或历史测试记录当成产品闭环通过。
历史 docs 中的旧接口仅供追溯。

## Naming conventions

- Functions use `camelCase`; types and type aliases use `PascalCase`.
- Compile-time value constants use `UPPER_SNAKE_CASE`.
- Local variables and ordinary parameters use `snake_case`, including runtime-initialized Zig local `const` bindings.
- Module namespace aliases use `snake_case`; type parameters use `PascalCase`.
- Names required by external ABIs, third-party APIs, and serialized protocols retain their required spelling.

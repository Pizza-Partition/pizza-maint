# 界面目录

`partition/` 为正常系统中的分区任务交互与规划预留，目前未实现。
`execution/tui/root.zig` 提供维护环境中的 libvaxis 仪表盘和串口文本输出。
业务状态、执行器与 journal 位于 `core/maint/`，TUI 直接消费业务状态。

执行网页、浏览器宿主与 JS/native 通道已移除。后续原生 GUI 计划通过 DRM 显示 Blend2D 的 CPU 绘制结果，本次不实现。
显示与业务的边界见 [主设计](../docs/superpowers/specs/2026-10-13-pizza-transition-design.md)，原生显示实施顺序见 [计划 M2](../docs/superpowers/plans/2026-10-21-pizza-maintenance-plan.md)。

`package.json` 与锁文件仅保留 Prettier 格式化依赖，不再构建或打包前端资源。

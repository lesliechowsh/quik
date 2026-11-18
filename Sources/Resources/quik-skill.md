---
name: quik
description: 检查这台 Mac 现在卡不卡、什么在拖慢系统。当用户说电脑卡、慢、风扇响，问"现在什么在占资源"、"电脑怎么这么卡"，或在长时间构建、测试、下载前后想确认系统状态时使用。运行 quik 命令读取 Quik 菜单栏监控的实时数据，不要自己跑 top 或采样。
---

# Quik 系统卡顿监控

菜单栏应用 Quik 每秒采样一次系统争用，把结果写进状态文件。用它的命令行工具读取结论，不要自己估算。

## 读取

```bash
quik --json
```

如果 `quik` 不在 PATH，改用 `~/.local/bin/quik --json`。两个都没有，说明 Quik 没在运行，告诉用户先打开 Quik。

退出码即状态：0 流畅，1 有点卡，2 卡住了，3 没有数据（Quik 没在运行，或数据超过 5 秒没更新）。退出码 3 时告诉用户先打开 Quik。

## 字段

- `level`：fluid 流畅 / sluggish 有点卡 / stalled 卡住了。`levelLabel` 是对应的中文，可直接引用。
- `score`：0-100，越高越卡。40 以上算明显卡顿。
- `summary`：一句现成的中文结论，可以直接说给用户。
- `causes`：按贡献排序的原因。`kind` 取值 cpu / memory / disk / scheduling / thermal，`contribution` 是 0-100 的贡献度。
- `culprits`：最占资源的应用，排最前的是主因。每个应用一行，同一应用的 helper 合并成一行。`cpuCores` 折算成几个 CPU 核，`diskMBps` 是每秒读写 MB，两者都是整行相加；`memoryMB` 是行内最大成员进程的占用，不是应用总量；`pid` 是代表进程，可用于采样/诊断；`role` 是它在应用里的分工（比如"页面渲染"）。
- `schedulerJankMs`：调度延迟毫秒，反映点击后要等多久才有反应。
- `memoryPressure` / `thermal`：内存压力与温度，critical 表示内核已经开始干预。

## 回答用户

- 卡：直接引用 `summary`，点名 `culprits[0].name`，说明它的 `role`。不要自己再跑 top、ps 或 sample，Quik 已经做过这些。
- 结束卡顿要退整个应用，在 Quik 面板点「结束」，或 `osascript -e 'quit app "<name>"'`。只 `kill <pid>` 只会杀掉一个 helper，应用会继续吃资源。真要 kill 前先向用户确认。
- 不卡：直接说流畅。不要展开一串数字。

## 边界

Quik 测的是系统资源争用，不是单个应用界面的卡顿。CPU 满载但调度正常时它报"有点卡"，不报"卡住了"；内存压力或温度 critical 时才直接报"卡住了"。

## 卸载

本技能由 Quik 按 Agent Skills 标准写入 `~/.agents/skills/quik` 与 `~/.claude/skills/quik`，命令行工具在 `~/.local/bin/quik`，状态数据在 `~/Library/Application Support/Quik`。用户要卸载 Quik 时，删除这几处再移除 Quik 应用本身即可，没有其他残留。也可以直接说"帮我卸载 Quik"，助手按这段说明清理。

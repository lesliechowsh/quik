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
- `culprits`：最占资源的进程，排最前的是主因。`cpuCores` 是折算成几个 CPU 核，`diskMBps` 是每秒读写 MB，`memoryMB` 是内存占用，`role` 是它在应用里的分工（比如"页面渲染"）。
- `schedulerJankMs`：调度延迟毫秒，反映点击后要等多久才有反应。
- `memoryPressure` / `thermal`：内存压力与温度，critical 表示内核已经开始干预。

## 回答用户

- 卡：直接引用 `summary`，点名 `culprits[0].name`，说明它的 `role`。不要自己再跑 top、ps 或 sample，Quik 已经做过这些。
- 用户想结束卡顿进程时，先 `kill -0 <pid>` 确认它还在，再执行 `kill <pid>`。结束进程会丢它没保存的内容，先向用户确认再动手。
- 不卡：直接说流畅。不要展开一串数字。

## 边界

Quik 测的是系统资源争用，不是单个应用界面的卡顿。CPU 满载但调度正常时它报"有点卡"，不报"卡住了"；内存压力或温度 critical 时才直接报"卡住了"。

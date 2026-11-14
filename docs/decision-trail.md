# Quik 决策日志

## 目标谓词（Phase A）

在目标机器（M3 Pro / 12 核 / 36 GB / macOS 26.3）上，Quik 满足以下可证伪条件：

1. 常驻菜单栏，不打开面板即可看到当前是否有卡顿、以及头号嫌疑。
2. 点击面板后 1 秒内看到归因（CPU / 内存 / IO / 调度 / 热）与 Top 5 嫌疑进程，每条带数值证据。
3. 稳态自身开销：CPU < 0.5%（12 核合计口径），常驻内存 < 60 MB。
4. 卡顿持续超过阈值时主动提醒；提醒可点击直达面板。
5. 对同用户嫌疑进程可执行查看 / 采样 / 退出；不可读的 root 进程必须显式标注，不得猜测。

## Grounding 事实（2026-11-13 实测）

- load average 5.46 / 30.81 / 52.93；内存压力 level 1；compressor 约 7.6 GB；swap 529 MB / 2048 MB。
- `top -l 2` 实测：Slack Helper 44.4%、WindowServer 41.8%、duetexpertd 28.2%、kernel_task 19.9%。
- Slack Helper 累计 CPU 160 s，累计读 128 GB、写 63 GB。
- 2026-11-09 17:45 发生过一次系统级 Jetsam 事件：free 仅 171 MB，compressor 15.6 GB（压缩前 53.5 GB），最大进程 node。说明用户所说卡顿的主因之一是内存耗尽与压缩抖动。
- 当前内存 Top：Notion Helper 757 MB、Slack Renderer 705 MB / 580 MB、多个 claude 进程 500-708 MB、mds_stores 505 MB。
- 后台常驻的第三方守护进程：Microsoft Defender（wdavdaemon 12%）、CorpLink、flinco、magpie。

### API 权限矩阵（非 root 实测）

| 信号 | API | 可用 |
| --- | --- | --- |
| 系统 CPU / 每核 tick | `host_processor_info` | 是 |
| VM 统计 | `host_statistics64(HOST_VM_INFO64)` | 是 |
| Swap | `sysctl vm.swapusage` | 是 |
| 内存压力 | `sysctl kern.memorystatus_vm_pressure_level` | 是 |
| 同用户进程 CPU / 磁盘 / footprint | `proc_pid_rusage(RUSAGE_INFO_V4)` | 是 |
| 其他用户 / root 进程 | `proc_pid_rusage` | 否，返回 -1 |
| 进程任务信息 | `proc_pidinfo(PROC_PIDTASKINFO)` | 否，返回 0 |
| 进程 CPU（kinfo_proc） | `sysctl KERN_PROC_ALL` | `p_cpticks`、`p_pctcpu` 恒为 0，不可用 |
| 磁盘累计读写与忙时 | IOKit `IOBlockStorageDriver` Statistics | 是 |
| 热状态 | `ProcessInfo.thermalState` | 是 |
| 前台 app | `NSWorkspace.frontmostApplication` | 是 |

### 门禁结果

| 门禁 | 状态 | 证据 |
| --- | --- | --- |
| xcodegen 生成工程 | VERIFIED | `Quik.xcodeproj` 生成成功 |
| xcodebuild 构建 app | VERIFIED | BUILD SUCCEEDED |
| 菜单栏 app 启动与显示 | VERIFIED | 进程存活，截图中可见状态项 |
| 普通权限读取 root 进程 CPU | NOT AVAILABLE | C probe 返回 -1 |
| C shim 桥接 Swift 读进程与磁盘 | VERIFIED | 自身 cpu=4ms footprint=10.8MB；磁盘累计读 8.35TB 写 4.52TB |
| 系统通知（ad-hoc 签名） | NOT AVAILABLE | `UNErrorDomain Code=1`；本机无代码签名证书 |
| 菜单栏空间 | CONSTRAINED | 实测已有 20+ 图标，新状态项被挤到菜单栏左半段 |
| 系统 CPU 采样正确性 | VERIFIED | 与同窗口 `top` 对比：采样 63-80%，top 64-73% |
| 采样自身开销 | VERIFIED | 系统指标 0.4-1.5 ms + 进程扫描 5-15 ms，每秒一次，12 核折算约 0.2% |
| 进程可测覆盖 | MEASURED | 861 个进程，540 可精确测量（同用户），321 仅可见（root） |

## 设计决策

### 度量模型

因变量是系统响应延迟，由 `Sources/Core/ExperienceProbe.swift` 测量。自变量是 CPU、内存、磁盘、热状态，由 `Sources/Probe/` 采集。分数以响应延迟为主，资源分折算 0.65。理由与实验见 `docs/metric-validation.md`。

### 数据形状

`RawSystemSnapshot` 与 `RawProcess` 是探针输出，只在边界可信。`SystemDelta` 是差分结果，`StallAssessment` 是领域结论。不可读的 root 进程用 `Attribution.unreadable` 表示，不参与排名，不用 0 分冒充。

### 架构

单 app target，无特权 helper。SwiftUI 面板加 AppKit 状态项。采样在 utility 串行队列，1 秒一次。判定器是纯结构体，可用固定输入测试。

### 告警与常驻入口

系统通知在 ad-hoc 签名下不可用（实测 `UNErrorDomain Code=1`）。菜单栏在目标机器上已被 20 多个图标占满，新状态项实测被挤到应用菜单下面，用户看不到。

因此常驻提示由三处承担：

1. 右上角的非激活悬浮窗。显示分数、状态、头号嫌疑，不抢焦点，在所有桌面空间可见，可拖动可关闭。
2. 程序坞图标。图标本身绘制分数与状态，卡顿时变红并写嫌疑进程名，角标同步分数。点击打开面板。
3. 菜单栏状态项。空间允许时可见，作为补充入口。

三处入口都读取同一个 `StallAssessment`，没有第二份状态。程序坞图标用 `ImageRenderer` 渲染 SwiftUI，只在分数每变化 3 分或状态变化时重绘。

### 界面验证

预览状态由 `QUIK_PREVIEW` 注入，面板窗口 ID 写入 `/tmp/quik-panel-windowid.txt`，`scripts/ui-check.sh` 用系统 `screencapture -l` 截取真实窗口，再用 Vision OCR 断言文本。三种状态全部通过。

### 进程归因

同用户进程用 `proc_pid_rusage` 精确读取。root 进程只枚举不排名，面板显示不可测比例。昂贵的 `top` 子进程不在常驻路径上。

## 未决问题

- 通知在 ad-hoc 签名下是否可用，不可用时降级为菜单栏颜色 + 声音 + 可选悬浮 HUD。

## 易用性与位置修复（2026-11-13）

用户在真机上看到三个问题：面板上半部分在屏幕外；程序坞图标文字溢出、中文小到看不清；点了"结束"没有反应。

### 面板顶出屏幕

`NSPopover` 的内容控制器如果是 `NSHostingController`，macOS 26 会把窗口放在屏幕上方约 180 pt 处。用一份独立的最小复现（`/tmp/popover-probe.swift`）确认：同样的 400x500 内容，包一层普通 `NSViewController` 并显式设置 `preferredContentSize` 后，窗口回到锚点下方。

修复：内容包一层普通控制器。另外加 `clampToScreen` 兜底，窗口矩形超出 `visibleFrame` 时强制挪回。

### 为什么之前的检查没发现

`scripts/ui-check.sh` 用 `screencapture -l <windowID>` 截图。这个接口截的是窗口自身的内容，与它落在屏幕的哪个位置无关。内容全对，位置全错，检查照样通过。

补的检查：`scripts/window-bounds.swift --assert` 读 `CGWindowListCopyWindowInfo`，断言每个窗口矩形都落在某块屏幕内，失败返回非零。用修复前的坐标 `(279,-152,426,526)` 跑，结果为 FAIL；修复后的 `(1086,94,426,526)` 为 PASS。这个断言已经接进 `ui-check.sh`。

### 程序坞图标

两个问题叠在一起：内容高度超过画布，`ImageRenderer` 把画布撑大，再用 `NSImage(size:)` 压回方形，于是纵向拉伸且文字被裁；同时文字没有宽度约束，三个汉字的理想宽度超过画布，`minimumScaleFactor` 不生效，左右笔画被切。

修复：字号与宽度都收进安全区，标签固定文本宽度，`ImageRenderer` 缩放到 2 倍只负责清晰度。检查脚本读导出的 PNG，断言正方形、文字像素距边缘不小于 4%、文字高度不小于画布的 35%。

普通模式下图标只画状态词和嫌疑应用名，不再画分数，因为 64 pt 的程序坞瓦片放不下三行。

### 结束没有反应

`CulpritActions.quit` 只走 `NSRunningApplication(pid).terminate()`。Slack的头号嫌疑是渲染辅助进程，它没有对应的 `NSRunningApplication`，于是 `guard` 直接返回，什么都没发生。

修复：拿不到应用对象时发 `SIGTERM`；两秒后检查进程是否还在，还在就弹窗说明没成功。结束的目标改为所属应用的主进程（`AppIdentity.ownerPid`），因为按钮上写的是"结束Slack"，用户的预期就是关掉Slack。

验证：`scripts/verify-quit.sh` 起一个真实进程，通过 `QUIK_QUIT_PID` 走同一条代码路径，断言进程消失且回调报告成功。

### 进程归属

`NSRunningApplication` 只能覆盖主应用，Electron 的辅助进程都查不到。改为沿父进程链向上找最近的 `.app` 包，取最外层那个（Notion的辅助进程会落到"Notion"，不是嵌套的"Notion浏览器"）。没有应用归属的进程用工作目录的最后一段区分，解决两个 `node` 无法分辨的问题。

### 判定曲线复核

用户问过"评价卡不卡是否科学，会不会太宽松或太严格"。把公式跑成一张表（`Tests/ScoreMapTests.swift`）后，看到两个问题。

一是"卡住了"实际到不了。资源统一乘 0.65，上限 65；延迟要 p95 到 150 ms 才满分，而 1/20 的唤醒晚 100 ms 已经掉帧。收紧到阈值 × 4 后，100 ms 即满分。

二是内存 critical 只报"有点卡"。内核进入 critical 意味着已经在冻结应用，等不到延迟出现。加了一条关键状态的保底分 72，覆盖内存 critical 与温度 critical。

日常的 warning 压力维持 16 分，不报卡。实测这台机器一分钟中等负载的延迟 p95 是 1.0-9.6 ms，基线 1.0 ms，25 ms 地板有 2.6 倍余量。

### 显示稳定

用户反馈"状态变换抖动好频繁，卡顿的软件各种出现不出现，排序变化频繁"。先量化再改：`scripts/flap-check.sh` 用 12 个忙等进程 6 秒开、6 秒关重复 5 次，改前 63 个样本里状态切换 10 次、分数变化 26 次、说明原因变化 10 次。

改法不是调阈值，而是三层标准去抖。状态用迟滞加驻留（对标 Prometheus 告警的 `for`），分数用三点中位数，进程负载用 EWMA（NIST 的标准做法），榜单用 1.25 倍粘性排序。原因句用峰值保持加衰减，保证标签驻留期间说明与之匹配。

改后状态切换 1 次，分数变化 10 次，说明原因变化 1 次，每分钟可见变化从 43.8 降到 11.4。代价是负载真正消失后要 10 秒才回到流畅，榜单里的行最多多留一个扫描周期。这两个数写成了常量，可以按体感再调。

### 悬浮窗开关

用户要求能关掉悬浮窗，右击它也应有这个能力，并且能再打开。

数据形状是一个持久化的布尔值 `hudVisible`，默认显示，存进 `UserDefaults`。面板、悬浮窗右击菜单、菜单栏右击菜单读同一个值，写也只有一条路径 `setHUDVisible`，避免三处状态各自漂移。

右击菜单不能靠 `NSView.menu`。悬浮窗内容是一个 `NSHostingView`，SwiftUI 会吞掉右键事件，实测菜单不出现。改成 `NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown)`，只接落在悬浮窗上的右键，再弹 `NSMenu`。这样不依赖视图层级，也不会挡住左键的打开面板。

悬浮窗默认离屏幕右上角 28 点，比最初的 12 点往里收了一截。拖动后的位置存进 `UserDefaults`，下次启动沿用；存的位置落在屏幕外时回退到默认位置。

验证脚本原来在结尾 `pkill`，跑完一轮检查后用户的 Quik 就没了。现在每个会启动应用的脚本先记下运行状态，结束时如果本来在运行就重新打开。这也解释了"软件怎么不见了"的一次疑问。

验证时发现所有界面脚本都指向 `build/Build/Products/Debug/Quik.app`，而 `xcodebuild` 默认把 Debug 产物写到 `~/Library/Developer/Xcode/DerivedData`，`build/` 下那份停在几个小时前的旧二进制。也就是说界面检查一直在验旧代码。四个脚本统一改成 Release，和 `scripts/build.sh` 的产物一致，并在面板断言里加上"隐藏悬浮窗"，下次缺按钮会被抓出来。

### 面板位置

用户反馈普通模式切高级模式时，面板变长后向上挪，盖住了悬浮窗。

根因是面板以悬浮窗为锚点，`NSPopover` 在内容高度变化时自己选了新的原点。macOS 26 上这个选择不稳定，实测会向上或向侧面漂。改法是不信任它的原点，显示后按锚点重设窗口位置：锚点就是悬浮窗，面板顶边固定在悬浮窗下方 8 点，变高时只向下长；下方放不下就放到上方；悬浮窗隐藏时退回菜单栏状态项。

还留了一条兜底，重设后如果仍然相交就暂时收起悬浮窗，面板关闭时恢复。正常情况下不会走到这条。

另一处修的是环境变量。验证脚本原来用 `launchctl setenv QUIK_PREVIEW` 注入假状态，中途中断会留下全局变量，之后每次启动都显示固定的"Slack 58 分"，看起来像误报。全部改成 `open --env`，只对那一次启动生效。排查时也确认了当时系统里没有Slack进程，那个读数来自预览数据。

### 普通模式与高级模式

默认普通模式。面板只留状态、一句人话解释、三个嫌疑应用和"结束"按钮。分数、归因数值、趋势图、采样、活动监视器入口收进高级模式，右下角切换。

切换时重建 popover 的内容控制器。只改 `preferredContentSize` 不会让已有窗口重新布局，普通模式的 390 pt 高度会裁掉高级模式的内容。

### 程序坞高级图标

用户反馈高级模式下程序坞图标的中文离数字太远，且贴近图标底边，三个字时可能出界。

先量化再调：`scripts/icon-check.swift --advanced` 读出文字像素的横向范围、上下两段的区间、间隙和边距。改前标签底边距下沿只有 5-8 像素，间隙 30 多像素。

布局从纵向堆叠改成固定偏移的两个文本。分数放在上半部，标签固定在下，两者间距由偏移量决定，不再受字体行高影响。最终两位数状态间隙 27-28 像素、边距 28 像素，标签不再贴边。

复核时用同样的像素检查看图，发现一个断言抓不到的缺陷：分数到 100 时渲染成"1…"。原因是 `minimumScaleFactor` 有下限 0.8，三位数需要的缩放低于下限，SwiftUI 直接截断。改成按位数选字号，两位数 70 点、三位数 52 点，并用 `fixedSize()` 禁止截断。三位数的偏移单独调到 -11，使间隙与两位数同样是 28 像素。`DockIconRenderTests` 增加一条 Vision 识别断言，截断会直接让测试失败。

三位数用 52 点比两位数小一截，这是代价。保持 70 点需要图标一半以上的宽度，圆润粗体数字 0.65 em 宽，128 点画布放不下三个。100 分是罕见状态，优先保证完整和不出界。

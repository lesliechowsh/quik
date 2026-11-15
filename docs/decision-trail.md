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

### 安装与分发

用户要求安装尽量傻瓜化，不要让用户自己重新打包。

先量约束。`security find-identity -v -p codesigning` 返回 0 个证书，`spctl -a` 对现有构建直接 rejected，原因是 ad-hoc 签名。macOS 15.1 起右键打开也不再能绕过 Gatekeeper，只剩系统设置里的"仍要打开"。所以没有 Apple Developer Program 的 Developer ID 证书，就做不到真正零提示的首次启动。

能做到的部分交给两个脚本。`scripts/package.sh` 构建 arm64 + x86_64 的通用 Release，产出 DMG，里面是 Quik.app、Applications 软链和一份中英安装说明。`scripts/verify-package.sh` 挂载 DMG，检查应用、软链、bundle id、两种架构、签名，再从 DMG 拷贝到临时目录启动一次。

签名路径已经留好。设置 `QUIK_SIGN_IDENTITY` 后改用 Developer ID 签名，开启 hardened runtime 和时间戳；再设置 `QUIK_NOTARY_PROFILE` 会签名 DMG、提交公证并 staple。两个变量缺一个时脚本直接失败，不会产出看起来像公证过的包。

验证结果。`package.sh` 输出 `architectures: x86_64 arm64`，DMG 904 KB，`spctl` 仍然 rejected，符合预期。`verify-package.sh` 的五项断言全部 PASS，`spctl` 一条 WARN，打包后的应用成功启动并退出。`SHA256SUMS` 用 `shasum -c` 复核通过。

残余代价写进了五种语言的 README 和 DMG 里的说明文件。首次打开要去系统设置点一次"仍要打开"。这是没有证书时的上限。

### 公证与 0.1.1

用户选了个人 Developer ID，明确接受签名里出现法定姓名，公司团队永久排除。

证书没有用 Xcode 创建。钥匙串访问生成 CSR，开发者门户上传后签发 Developer ID Application 证书，双击导入即与私钥配对。公证凭据用 App 专用密码存进钥匙串，`xcrun notarytool history` 能正常返回。

`package.sh` 直接复用已有的签名与公证分支。第一次提交 `ef30da40` 通过，staple 成功。随后发现两个只有真实产物才会暴露的问题。`spctl` 对 DMG 报 "does not seem to be an app"，应该评估 DMG 里的应用；安装说明还在告诉用户会看到“仍要打开”，与公证版不符。两处都改掉后重新提交 `14cc2aab`，同样 Accepted。

最终结果。`package.sh` 打印 `gatekeeper: accepted`。`verify-package.sh` 六项 PASS，`spctl` 返回 `source=Notarized Developer ID`。把应用拷出来加上 `com.apple.quarantine` 属性后启动，进程正常起来，没有拦截。版本升到 0.1.1，0.1.0 保持原样。

DMG 已 staple，应用本体没有单独 staple，首次启动由 Gatekeeper 在线核验。离线首启是否会被拦没有验证，这是当前分发的残余风险。

### 崩溃：磁盘累计量回绕与 0.1.2

用户报告应用跑一会就崩溃，不是第一次。五份 `.ips` 签名相同：`EXC_BREAKPOINT`，`Double value cannot be converted to UInt64 because the result would be greater than UInt64.max`，故障帧在 `StallEvaluator.swift:61/62`，也就是系统磁盘读写速率转成 `UInt64` 的那两行。不是进程排行那一行。

原因。磁盘总量来自 IOKit `IOBlockStorageDriver` 的累计字节，代码用 `&-` 求差，把下降当成了回绕。累计量只在设备集合变化时下降。实测挂载一个写入 120 MB 的磁盘映像再卸载，写入总量从 4,725,380,667,136 降到 4,725,260,709,888，设备数从 2 回到 1。回绕后的差值接近 2^64 减去这 120 MB，除以扫描间隔就超过 2^64，`UInt64(_:)` 直接 trap。

间隔会小于 1 秒。用和应用相同的 `DispatchSourceTimer` 与 `Date()` 在这台机器上测 39 个间隔，中位数 0.99996 秒，21 个小于 1 秒，最短 0.99286 秒。所以回绕量除以小于 1 的间隔必然越界，不需要极端抖动。

复现。在修复前的 `HEAD` 单独构建，重复"挂载、写入 100 MB、强制卸载"，第一轮就生成同样的报告，故障帧 `StallEvaluator.swift:62`，二进制路径在 `/private/tmp`。同一循环跑两遍，两遍都崩。

修复。累计量下降按基线重置处理，该区间记 0，不再回绕；磁盘忙碌时间同样处理。进程磁盘差本来就检查了下降，但 `readDelta + writeDelta` 是 `UInt64` 相加，改成先转 `Double` 再加。显示边界换成 `UInt64(saturating:)`，非有限值记 0，超过上界的有限值饱和，边界上不再有 trap。CPU 时间片保留 `&-`，它是真的 32 位回绕，并且只用于比值。

验证。同样的 8 轮挂载、写入、卸载，修复版进程全程存活，没有新的 `.ips`。`DeltaTests` 四条断言：计数下降返回 0、正常增长速率不变、进程计数下降不崩、异常 Double 不崩。第一条在修复前会让测试进程 trap。`ui-check.sh` 与 `verify-experience.sh` 全部 PASS。版本号升到 0.1.2，0.1.1 的安装包保持原样。

发布。公证提交 `23d5924c`，Accepted，staple 通过，`gatekeeper: accepted`。`verify-package.sh` 七项 PASS，`spctl` 返回 `source=Notarized Developer ID`。下载回来的 DMG 校验和与 `SHA256SUMS` 一致。

推送时 `--tags` 把只该留在本地的 `local-history-2026-11-15` 一起推到了远端。这个标签指向公开前的旧历史，发现后立刻删除远端标签，`ls-remote` 已确认不在列表里。它公开存在了几十秒，之后只能靠知道 SHA 访问。

### Agent 数据面：skill 加 CLI 与一键安装

用户想让 AI 助手也能回答"现在卡不卡"，安装入口放在界面上，点一下把提示词交给 AI 助手去装。

先定数据形状。`StatusSnapshot` 是应用与外部之间的契约：schema 版本、ISO 8601 时间戳、level（fluid/sluggish/stalled）、score、现成的中文结论 `summary`、按贡献排序的原因、按占用排序的嫌疑进程（含 pid、应用名、分工、折算核数、磁盘 MB/s、内存 MB）。普通面板的中文句子原来只写在 `PanelView` 里，现在移进 `StallAssessment.plainSummary`，面板、悬浮窗、状态文件读同一份，避免两处句子各自漂移。

架构上比过两个候选。候选 A：应用每秒把评估结果原子写入状态文件，CLI 只读文件。候选 B：CLI 自带探针，独立采样两秒再报数。B 被否决，因为它造出第二条"评估系统状态"的路径，和菜单栏里用户看到的结论可能不一致，而且每次调用要多烧一两秒 CPU。A 的代价是依赖应用常驻，但 Quik 本来就是常驻监控，应用没跑就没有"现在"可言，CLI 按约定报退出码 3。

落地时踩到一个真问题：CLI 最初嵌在 `Contents/MacOS/quik`，在这台大小写不敏感的 APFS 上，这个路径和应用主程序 `Quik` 是同一个文件，嵌入时把主程序覆盖了，`open` 启动的其实是 CLI。改成 `Contents/Library/quik`，用 target 依赖保证先构建，再用脚本阶段拷进去，绕开 Copy Files 没有 Library 目标的限制。

CLI 放弃 PATH 安装作为必选步骤。技能文件里写的是应用内的绝对路径，装完就能用；软链到 `/usr/local/bin` 只是提示词里的可选步骤。少一个失败点。

界面入口按普通模式优先：只有普通模式的面板底部的"安装到 AI 助手"。点开是安装视图，出现时就把提示词放进剪贴板，按钮变成"已复制，去粘贴给 AI 助手"。提示词内嵌完整的技能文件内容并替换好路径占位符，AI 助手照着写文件即可，不需要它自己找路径。

验证。`DeltaTests` 之外新增 `StatusSnapshotTests` 五条：契约字段、过期判定、流句一致性、状态文件读写往返、提示词携带技能正文与真实路径。`scripts/verify-agent.sh` 八项断言：CLI 在包内、无文件退出码 3、应用每秒写文件、JSON 字段齐全、文本模式、快照新鲜、优雅退出后退出码 3 且文件被删。`ui-check.sh` 加第五类断言：安装视图渲染、OCR 可读、剪贴板里真的是提示词。打包验证加了一条包内 CLI 可运行。全部 PASS。

成本记在 `docs/metric-validation.md`：状态文件实测 516 字节、每秒一次原子重写；CLI 稳定后单次 0.02 秒，首次 0.66 秒，差异归因于系统对首次执行新二进制的检查（推断）。

公证走了三次才过。钥匙串里的 `quik-notary` 条目在 02:50 到 04:59 之间消失，系统日志无痕，Mac 没重启，原因查不到。用户重建了 App 专用密码和新 profile。第一次提交 `e0d5bf4a` Invalid，原因是有两份 CLI：xcodegen 对未声明 `embed: false` 的目标依赖默认嵌一份进 `Contents/Resources`，带的是调试签名。第二次 `1bf28a51` 仍 Invalid，剩下的那一份在 `Contents/Library`，因为 `codesign --deep` 只重签它认识的嵌套位置（Frameworks、PlugIns、XPCServices），不碰 Library 里的裸可执行文件。修法是打包脚本先显式签名 Library/quik，再签外层 bundle。第三次 `679f3ec8` Accepted，`spctl` 返回 Notarized Developer ID。本地 `codesign --verify --deep --strict` 与 `spctl` 都查不出嵌包签名问题，只有公证会查，这条限制记在这里。

### 提示词携带机器用户名与 0.2.1

0.2.0 发布约一小时后用户指出：安装提示词里出现了 `bytedance`。定位：提示词把 `Bundle.main` 的绝对路径拼了进去，而开发构建从 `build/` 目录运行，路径就变成 `/Users/bytedance/...`。用户名 bytedance 是公司信息，不得出现在任何会离开这台机器的内容里，开发构建的输出也不例外。

排查结论先记录：仓库源代码干净；v0.1.1 与 v0.2.0 已发布二进制经 `strings` 与 `dwarfdump --debug-info` 检查均不含该用户名；泄漏只存在于运行时生成的提示词，已发布产物本身不携带。

修法上否决了"提示词引用应用包内技能文件路径"的方案：开发构建的应用路径本身就带用户名，怎么拼都会漏。落成三点。技能文件 `quik-skill.md` 改为静态内容，只引用 `quik` 与 `~/.local/bin/quik` 两个固定位置；命令行工具由应用启动时自动复制到 `~/.local/bin/quik`（幂等，覆盖安装，应用更新后命令跟着更新），这一步零操作；提示词只负责让 AI 助手保存技能文件，不引用任何应用包内路径。用户确认保留"点一下复制提示词、贴给 AI 助手"的流程。

防复发：单元测试断言提示词与技能内容不含 `/Users/`、不含 `{{`、不含 `.app`；`ui-check.sh` 的剪贴板断言改为要求无机器路径；`package.sh` 在签名前 `strip -S` 两个二进制，DWARF 里的机器路径从此没有出口（strip 必须在签名前，签名后再改二进制会毁掉签名）。v0.2.0 的 release 与 tag 删除，由 0.2.1 替代。

一条教训：运行时拼进提示词、剪贴板的字符串，和源代码、二进制一样都是发布面。检查泄漏要查四个地方，漏一处就白查。

### 直接安装、卸载动作与 0.2.2

用户指出三件事：能不能不贴提示词直接装；卸载时的清理怎么做；判断"哪些助手装到哪些目录"不该自己手枚举，要有成熟、官方、开源的做法。第三条说得对，查证如下。

技能格式早就是开放标准：Agent Skills（agentskills.io，LF Projects 托管，Anthropic 发起后开放），一个技能就是「文件夹 + SKILL.md」，兼容助手启动时自动从磁盘发现，采纳方 40+。目录也有事实标准：Cursor 官方文档把 `~/.agents/skills/` 列为用户级全局技能目录，并兼容读取 `~/.claude/skills/` 与 `~/.codex/skills/`；社区标准安装器 `npx skills`（vercel-labs/skills，MIT，75+ 助手的目录表在其 docs/agents.md 维护）确认 Codex、Cline、Zed、Warp、Kimi CLI 等的全局目录就是 `~/.agents/skills/`。唯一需要单独写的是 Claude Code（只认 `~/.claude/skills/`，对 `~/.agents/skills` 的支持在 anthropics/claude-code 还是 open issue）。所以"枚举"收敛成两个有官方文档背书的标准目录，新助手支持标准即自动覆盖，零维护。

于是 0.2.2 落成三点。其一，贴提示词的流程删除：应用启动时把随包技能直接写进 `~/.agents/skills/quik/` 与 `~/.claude/skills/quik/`（幂等覆盖，应用更新后技能跟着更新），面板入口改叫"AI 助手"，展示装到了哪里。其二，卸载：macOS 在应用被删除后不会执行任何代码，"删完自动清理"在平台上不存在，清理只能由应用活着时完成——状态菜单新增「卸载 Quik…」，确认后一次删掉两个技能目录、`~/.local/bin/quik`、`~/Library/Application Support/Quik`，然后退出，用户最后拖走应用本体；技能文件里写明同样的清理清单，对任何助手说"帮我卸载 Quik"也能清干净。其三，README 五个语言版本同步改写。

防复发：单元测试断言技能写入两个标准目录且内容与随包文件一致、卸载删干净四样且幂等、技能文档写明标准位置与卸载说明且无 `/Users/`；`verify-agent.sh` 断言两处 SKILL.md 存在且与包内资源逐字节一致；`ui-check.sh` 的剪贴板断言随流程删除，改为断言视图渲染且不把机器路径画上屏。

一条教训：自己枚举目录之前，先查有没有开放标准和事实标准安装器；能力被平台禁止（删除后回调）时要如实说明机制，不要假装有自动清理。

### 安装改成用户主动、界面能移除、以及 OCR 退出 0.2.3

用户提出三点：入口叫「AI 助手」看不懂；默认不该把技能装进去，点了才装；装了要能清掉。

第一点，入口是纯名词，看着像分区标题而不是动作。改回「安装到 AI 助手」。

第二点改成三值状态 `SkillState`（absent / partial / installed），由磁盘推导，不存布尔值。normal 启动不写任何文件；已有安装则刷新技能与命令，这是 presence 驱动，不是默认安装。否则用户装了技能，Quik 一升级技能就过期，还得手动重装。命令行工具跟着技能一起进出：它只服务这个技能，单独静默写 `~/.local/bin` 与默认不安装是同一类问题。`installed` 的判据包含命令行工具本身，缺它助手只会拿到 command not found。移除只删技能与命令，应用数据目录留给「卸载 Quik」。

第三点，界面里加了「移除」，菜单里的「卸载 Quik…」保留，两者边界是应用是否继续运行。

验证。单元测试 33 条：三态、安装写两个标准目录与命令行工具、移除保留应用数据且幂等、技能内容无机器路径。`verify-agent.sh` 改为从干净状态起跑，断言默认启动不写任何文件，再用测试钩子 `QUIK_AGENT_ACTION` 走真实安装与移除代码路径；脚本开始时记住用户是否已装，结束时恢复，此前它会把用户自己装的技能一起删掉。`ui-check.sh` 断言视图渲染。

顺带处理了 OCR。用户指出小字 OCR 不靠谱，不如不要。查的时候发现一个更大的问题：面板与悬浮窗两次 `screencapture -l` 得到 md5 完全相同的图，说明悬浮窗截图拿到的其实是面板像素。旧断言之所以通过，是因为面板里也有那个状态字，等于在错误对象上碰巧通过。于是删掉 `scripts/ocr.swift`，`ui-check.sh` 只保留三类断言：窗口矩形在屏内、截图不是空白窗口（`scripts/image-ink.swift` 按像素算与主色的距离，纯色图判 0%）、程序坞图标文字不出界；截图留在 `/tmp/quik-ui` 给人直接看。空白图实测返回 `ink 0.00%` 且退出码 1，证明检查会失败。

程序坞 100 分那条 Vision 断言也改掉：渲染 100 分，取上半张里白色像素的横向跨度占比，断言在 0.55 到 0.92 之间。三位数按 52 点画约 67%，截断成「1…」约 32%。第一版用「三位比两位更宽」作判据，实测两者都是 255 像素而失败，因为两位数用 70 点、三位数用 52 点，宽度本来接近；这条记录留在这里，说明相对宽度不是可靠判据。

### 公证 401 的真因是 @env:，不是密码 0.2.3

凭据从钥匙串搬进 `~/.config/quik/notary.env` 之后，`notarytool` 对同一个 Apple ID 一直返回 401，而 `altool --list-providers` 用同样的账号密码能成功。于是怀疑过密码抄错、Team ID 选错、文件里混了不可见字符。

真因在参数：`--password "@env:QUIK_NOTARY_PASSWORD"` 里的 `@env:` 是 `altool` 的凭据引用语法，`notarytool` 不认。`strings` 查 notarytool 二进制，`env:` 出现 0 次；它的手册里也只列 Apple ID 密码、钥匙串 profile、API key 三种来源。也就是说它把字面字符串 `@env:QUIK_NOTARY_PASSWORD` 当密码发了出去，每次必然 401。之前能成功是因为走的是 `store-credentials` 存的钥匙串 profile，那一步由 notarytool 自己弹窗收密码，从来没经过 `@env:`。

改法是密码以字面值传进 `--password`。代价是请求期间密码出现在本机 `ps` 里，`altool` 时代也有同样的暴露面，可以接受。API key 那条路仍然保留并优先，它没有这个暴露面，也不受密码轮换和钥匙串重建影响。

验证：假密码跑预检，2 秒内退出并提示凭据被拒，没有进入构建。这条只证明失败路径够快，不能证明真密码能过，真密码要用户自己填进文件。

教训：凭据引用的语法要按工具查，不能按同类工具类推。`altool` 和 `notarytool` 同属 Xcode 命令行，凭据语法并不通用。

### 凭据回到钥匙串 profile，不落盘 0.2.3

中间试过把凭据放 `~/.config/quik/notary.env`，因为钥匙串在 2026-11-15 被系统整体重建过，profile 连密码一起没了。用户不接受密码写到磁盘，明确要求走回老路：密码只进钥匙串，人去终端敲命令。

于是删掉凭据文件、`.env.example`、API key 模板和 `package.sh` 里的 key 模式。`package.sh` 直接用 profile `quik-notary`，预检在 profile 缺失时于构建前退出并打印重建命令。`QUIK_SKIP_NOTARY=1` 保留给不公证的本地调试构建。

上一节讲的 401 真因仍然是 `@env:`，与凭据放在哪无关。这条路线也不经过它。

### 静态应用图标 0.2.4

用户发现 Finder 里的 Quik 是系统默认图标。原因是包内只有动态绘制的程序坞瓦片，没有任何图标文件，`Info.plist` 里也没有 `CFBundleIconFile`。程序坞图标是运行后用 `ImageRenderer` 覆盖的，只影响运行中的程序坞，不影响 Finder 和 DMG。

做法是补一个静态图标，语言与动态瓦片一致：石墨色圆角方块，中间一条白色脉冲线。不加文字，因为 16 点下文字必糊；不用状态色，因为静态图标不代表当前状态。几何固定为 1024 画布、824 内容区、186 圆角、80 线宽，全部写进 `scripts/make-icon.swift`，重跑就能产出 `Sources/Resources/Quik.icns`。每个尺寸单独绘制而不是从 1024 缩放，16 与 32 点更锐利。

`project.yml` 增加 `CFBundleIconFile: Quik`。测试新增两条：包内有 icns 且尺寸覆盖 16 到 1024，以及从 icns 栅格化后中段像素是暗的，防止画成系统默认图标。

验证有一处缺口。这台机器上 Quick Look 渲染任何 `.app` 都会挂住，系统自带的计算器也一样，所以没能用 `qlmanage` 生成 Finder 缩略图。包级契约（图标文件、plist 键、尺寸、像素）都有断言，Finder 的实际渲染留给肉眼确认。

顺带修了一个一直存在的隐患：命令行目标的产品名是 `quik`，模块名默认跟着产品名走，在大小写不敏感的文件系统上和 App 的 `Quik` 模块撞名，测试偶尔报 `cannot load module 'quik' as 'Quik'`。给命令行目标显式设了 `PRODUCT_MODULE_NAME: QuikCLI`。

### 多语言界面与结构化文案（0.2.4 之后）

用户提了两件事。一是「安装到 AI 助手」的入口在高级模式里也要有，之前它被 `if !store.advanced` 挡住。二是 README 已经是五种语言，应用却只有中文，长起来的翻译会溢出，要求用权威机制做，不要手搓一个残缺版本。

先改数据形状，再改文案。核心层不再产出句子，只产出数字和语义：`CauseMetrics`（CPU 忙核数、内存压力、磁盘速率、调度抖动毫秒、热状态）、`CulpritReason`（CPU 占比、核数、磁盘、内存）、`ProcessRole`（页面渲染、图形、插件、后台、Web 内容、工作目录）。界面层通过 `Copy` 把这些渲染成文本，格式化串带位置说明符（`%2$ld`）以适配不同语序。

本地化用 Apple 的标准机制：`en` 为开发语言，`zh-Hans`、`de`、`fr`、`ja` 四个 `.lproj/Localizable.strings`，每条 92 个键，从 `Copy.swift` 里正则提取后由脚本生成，缺键或多余键都让生成失败。英文原文同时充当键，所以某条漏翻时看到的是可读英文而不是空串。代理快照（`status.json`、CLI 输出）固定英文，不受系统语言影响，这样助手拿到的字段不会随机器语言漂移。

布局上，页脚改用 `Layout` 协议实现的 `FlowLayout`，链接放不下就换行而不是压缩或裁掉；面板高度由 `NSHostingView.fittingSize` 按内容量出来，翻译成两行的标题不会挤掉底部按钮。

验证分两层。单元测试断言四种语言的键集合完全一致、占位符数量和转换类型一致、核心标签正确翻译，并把程序坞状态字在每种语言下真实渲染出来量墨迹边界，宽度、高度和四边留白都有断言。端到端是新增的 `scripts/verify-languages.sh`：用 `-AppleLanguages "(de)"` 等参数把 Release 包各启动一次，走的是真实的本地化查找，截下真实窗口，断言窗口在屏内、有墨迹、且墨迹四边留白不少于 24 点。

这里有一个坑值得记。`screencapture -l` 截面板窗口时，把悬浮窗也带进来了，因为悬浮窗是面板窗口的子窗口。截图里上半是悬浮窗、下半是面板，量出来的墨迹边界贴着图顶，会让留白断言失败；查窗口尺寸时窗口是 426x416 点，截图却是 426x473 点，多出来的正是悬浮窗。语言检查因此用 `QUIK_NO_HUD=1` 关掉悬浮窗，只量面板。

另一个坑是截图的边。popover 窗口比内容宽 13 点，左右两侧是阴影边框，顶部还有指向菜单栏的箭头，都是与背景不同的颜色。直接按整图算墨迹，边界会贴着图边，留白恒为 0。`image-ink.swift` 因此加了 `--inset`，先裁掉 23 点的外圈再量；24 点的留白要求仍低于「边框 13 点 + 内容内边距 16 点」，所以通过就意味着文字确实没被裁掉。

实测五种语言各两页全部通过（面板与安装页），留白 58 到 104 像素，截图留在 `/tmp/quik-ui` 供人查看。检查不读文字，所以它证明的是「没溢出、没贴着边裁切」，译文本身是否通顺仍要人看截图。

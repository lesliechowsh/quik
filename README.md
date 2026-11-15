# Quik

[中文](README.md) · [English](README.en.md) · [Français](README.fr.md) · [Deutsch](README.de.md) · [日本語](README.ja.md)

一个常驻菜单栏的 macOS 卡顿监控工具。它回答两个问题：现在卡不卡，是谁导致的。

原生 Swift，无第三方依赖。稳态开销实测 0.8% 单核（12 核折合 0.07%），常驻内存约 25 MB。测量方法见 `docs/metric-validation.md`。

## 安装

从 [Releases](https://github.com/lesliechowsh/quik/releases/latest) 下载 `Quik-<版本>.dmg`，打开后把 Quik 拖进 Applications。需要 macOS 14 或更高版本，Apple Silicon 和 Intel 都支持。

Releases 里的安装包用 Developer ID 签名并通过 Apple 公证，首次打开不会出现安全提示。自己从源码构建的包是 ad-hoc 签名，首次打开需要去"系统设置 > 隐私与安全性"点"仍要打开"。

维护者发版时设置 `QUIK_SIGN_IDENTITY` 和 `QUIK_NOTARY_PROFILE`，`scripts/package.sh` 会完成签名、公证和 staple。

## 从源码构建

需要 Xcode 26 与 `xcodegen`。

```bash
brew install xcodegen
scripts/build.sh
scripts/run.sh
```

`scripts/run.sh` 启动后，屏幕右上角出现一个悬浮窗，显示分数、状态和头号嫌疑。点击悬浮窗打开面板，面板贴在悬浮窗下方展开，切换模式时只向下变长。拖动可移动位置，位置会记住。这个窗口不激活应用，不抢焦点，在所有桌面空间可见。

右击悬浮窗，或者点面板右下角的"隐藏悬浮窗"，可以把它收起。选择记在 `hudVisible` 设置里，重启后仍然生效。再点面板里的"显示悬浮窗"，或者右击菜单栏状态项勾选"显示悬浮窗"，就会重新出现。

程序坞也有图标。普通模式下图标显示状态和头号嫌疑进程名，卡顿时变成橙色或红色。高级模式把分数放在上半部分、状态标签紧贴在下，字号按位数选，两位数用 70 点，三位数用 52 点，保证"100"完整显示而不是被截成"1…"。点击程序坞图标打开面板。

菜单栏同时出现一个状态项：

- `● 12` 绿色或无颜色，表示系统流畅。
- `▲ Slack Helper 44%` 橙色，表示有点卡，后面是头号嫌疑进程和它占用的单核比例。
- `■ Slack Helper 44%` 红色，表示卡住了。

菜单栏空间不足时，macOS 会把状态项挤到应用菜单下面。悬浮窗不受影响，所以它承担主要的常驻提示。点击状态项或悬浮窗打开面板。面板显示卡顿分数、归因（CPU、内存、磁盘、响应延迟、温度）、Top 5 嫌疑进程，以及每个进程可执行的动作：采样 3 秒、打开活动监视器、退出。

默认是普通模式，只回答三件事：现在卡不卡，是谁，要不要结束它。分数、归因明细、趋势图、采样入口都收在"高级模式"里，面板右下角切换。

嫌疑进程显示的是应用本身，不是可执行文件名。`Slack Helper (Renderer)` 显示为"Slack · 页面渲染"，程序坞和悬浮窗用同一个名字。没有应用归属的命令行进程用工作目录区分，比如"node · 在 my-project 文件夹里运行"。点"结束 Slack"结束的是 Slack 本体，不是那个辅助进程。

`sample` 报告写到临时目录并自动打开，里面是 3 秒的调用栈，能看出进程卡在哪个函数。这个入口只在高级模式出现。

## AI 助手

装好之后，AI 助手（Claude Code、Cursor 等）也能回答"现在电脑卡不卡"。Quik 运行时会自动把命令行工具放到 `~/.local/bin/quik`，这一步不需要任何人操作。要让助手会用它，打开面板点"安装到 AI 助手"，提示词自动复制，粘贴给助手即可。提示词内嵌完整的技能文件，助手会自己存进技能目录。提示词和技能文件只引用 `quik` 与 `~/.local/bin/quik` 两个固定位置，不含任何本机路径，贴到哪里都不会带出你机器上的目录。装一次就行，之后随 Quik 常驻。

命令行工具的 `quik` 输出人类可读摘要，`quik --json` 输出机器可读的 JSON，退出码直接表示状态：0 流畅，1 有点卡，2 卡住了，3 没有数据。应用每秒把评估结果原子写入 `~/Library/Application Support/Quik/status.json`，实测 516 字节；退出时删除，5 秒没更新按过期处理。技能文件教 AI 助手引用现成的中文结论、不要自己再跑 top 或采样。不想用这个功能时，删掉助手技能目录里的 `quik` 文件夹和 `~/.local/bin/quik` 即可。

## 验证

```bash
# 单元测试：判定、滞回、排名、显示稳定
xcodebuild -project Quik.xcodeproj -scheme Quik -configuration Debug -derivedDataPath build test

# 界面闭环：注入固定状态，截图真实面板，OCR 断言文本
scripts/ui-check.sh

# 度量闭环：受控 CPU 过载，验证探针与判定
# 抖动测量：6 秒满载 / 6 秒空闲循环，统计状态与榜单变化次数（scripts/flap-check.sh）
scripts/verify-experience.sh
```

```bash
# 悬浮窗开关闭环：重启后保持隐藏或显示，运行中可收起再打开
scripts/verify-hud.sh

# 结束动作闭环：对一个真实进程发信号，验证它确实退出
scripts/verify-quit.sh
```

```bash
# 安装包闭环：挂载 DMG，检查架构、签名与拖入目标，并启动一次
scripts/verify-package.sh

# Agent 闭环：状态文件、~/.local/bin 安装、命令行工具两种输出、过期与退出清理
scripts/verify-agent.sh
```

维护者发版步骤见 `docs/distribution.md`。

`scripts/ui-check.sh` 输出截图与 OCR 文本到 `/tmp/quik-ui`。它做五类断言：面板文本、面板与悬浮窗的窗口矩形落在屏幕内、程序坞图标文字不出界、两种模式各自渲染正确、"安装到 AI 助手"视图渲染且提示词进了剪贴板、且剪贴板里不含任何机器路径。任何断言失败会返回非零退出码。

窗口位置单独断言，是因为按窗口 ID 截图只证明内容对，不证明它出现在屏幕上。早期版本的面板顶到屏幕外，内容截图完好，检查照样通过。

图标检查读的是应用导出的 PNG，与程序坞实际绘制的是同一份 `ImageRenderer` 输出，断言正方形、文字像素不出边、文字高度占图标一半以上。高级模式另加两条数得出来的约束：分数与标签的竖向间隙不超过图标边长的 12%，标签底边距图标下沿至少 20 像素。单元测试还会渲染 100 分并用 Vision 识别，确认三位数没有被截断。

## 度量边界

Quik 测量系统争用，不测量别的 app 的 UI 帧时间。macOS 没有公开接口让一个进程从外部读取另一个进程的主线程阻塞。

因此面板给出的是"资源被谁占用"和"系统还能不能及时调度交互线程"，不是"这个 app 卡了"。当 CPU 饱和但响应延迟正常时，Quik 只报"有点卡"，不报"卡住了"。内存压力到 critical 或温度到 critical 是例外，内核已经在冻结应用或降频，直接报"卡住了"。

负载到状态的完整映射和定曲线的依据见 `docs/metric-validation.md`。

## 目录

```
Sources/Core/       判定引擎、差分、体验探针、历史、Agent 状态文件
Sources/Probe/      mach、sysctl、libproc、IOKit 采样与 C 桥接
Sources/UI/         菜单栏、面板、动作、预览状态
Sources/CLI/        quik 命令行工具
Sources/Resources/  随应用分发的 AI 助手技能文件
Sources/App/        入口
Tests/              单元测试
scripts/            构建、界面检查、度量实验
docs/               决策日志与度量验证
```

## 开源协议

MIT。见 `LICENSE`。

# Atoll 本地开发交接

更新日期：2026-07-21（Asia/Shanghai）

## 当前状态

- 仓库：`/Users/liyuan/Desktop/code/Atoll-2.2.0`
- 分支：`main`。
- 本地版本：`2.3.0 (22)`。
- 唯一允许启动的主程序：`/Applications/Atoll.app`。
- 当前采用本地使用模式：默认只本地 commit；只有用户明确要求时才 push。不要加入在线更新或自动更新功能。
- 每次完成代码变更后，重启 Atoll 和 `AtollCodexUsage`。

当前运行进程应为：

```bash
pgrep -fl '/Applications/Atoll.app|mediaremote-adapter|AtollCodexUsage'
```

不应从 `build/.../Atoll.app` 或其他 Debug 产物运行，否则会出现“功能消失”的假象。

## 本地构建、安装与重启

唯一标准流程：

```bash
cd /Users/liyuan/Desktop/code/Atoll-2.2.0
./Scripts/install-local.sh
```

脚本会：

1. 构建 Release 产物；
2. 安装到 `/Applications/Atoll.app`；
3. 用本机稳定证书 `Ice Local Code Signing` 签名（没有该证书时降级为 ad-hoc 签名）；
4. 清理 build 目录里的 Atoll.app、注销其 LaunchServices 注册；
5. 清除旧 Debug 包 `com.Ebullioscopic.Atoll.dev` 的辅助功能记录；
6. 启动正式 Atoll 及 `~/Desktop/code/AtollCodexUsage/build/AtollCodexUsage.app`。

如果安装末尾出现 LaunchServices `-600`，通常是旧进程刚退出；安装本身已经完成。等待一两秒后执行：

```bash
open /Applications/Atoll.app
```

不要使用 `open -n`，它可能同时启动多个 Atoll 实例。

版本号位于 `DynamicIsland.xcodeproj/project.pbxproj` 的 Debug 和 Release 配置中。安装新的功能版本时，同时递增：

- `MARKETING_VERSION`
- `CURRENT_PROJECT_VERSION`

## 权限与签名

辅助功能只应保留一个正式包记录：

```text
com.Ebullioscopic.Atoll
```

不要保留或重新授权：

```text
com.Ebullioscopic.Atoll.dev
```

可检查正式包信息：

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Atoll.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/Atoll.app/Contents/Info.plist
codesign --verify --deep --strict /Applications/Atoll.app
```

本机签名必须使用 `Scripts/AtollLocal.entitlements`，其中允许加载本地签名的内置框架；否则 hardened runtime 会拒绝 Lottie，应用无法启动。不要删掉该 entitlement，也不要改回不带该 entitlement 的手工签名。

## 已完成的剪切板功能

相关文件：

- `DynamicIsland/components/Clipboard/ClipboardPanel.swift`
- `DynamicIsland/managers/ClipboardPasteCoordinator.swift`
- `DynamicIsland/managers/ClipboardPanelManager.swift`
- `DynamicIsland/managers/ClipboardManager.swift`

当前行为：

- 默认快捷键：`⌘⇧J`。
- 唤起后可直接输入，支持模糊匹配。
- `↑` / `↓` 切换条目，`←` / `→` 循环切换分类；在“全部”按一次 `←` 会直接进入“分组”。
- `Enter`：选中条目移到队列首位、关闭面板，并向唤起前的应用执行一次粘贴。
- 链接条目显示原始完整 URL，不再只显示末级路径或 `/`。
- 按住 `⌘` 点击可跨文本、链接、图片、文件、富文本等类型即时多选；按住 `⌘` 用方向键移动焦点后，`⌘ Enter` 也可加入或取消当前项。面板刚打开时的首项仅是键盘焦点，不会被误算进多选。鼠标选择不会触发列表自动居中，因此滚动到屏外后仍会保留已有选择。松开 `⌘` 后按 `Enter`，会把两项以上的选择持久化为一个分组并立即粘贴。
- “分组”栏目支持搜索、删除、整组复制；选中分组后按 `Enter` 会向唤起前的应用一次性粘贴整组内容。纯文本分组按原顺序用换行拼接；纯图片分组将 TIFF 归档按需缓存为可预览 PNG，再使用包含全部图片 URL 的 Finder 风格快照并只发送一次粘贴，避免异步读取到其他分组；混合分组使用带任务代次校验的顺序粘贴，旧任务不能覆盖新的选择。数据库维护会保留最新记录并清理旧版本误建的重复分组。
- 粘贴协调器持续记录最近的非 Atoll 前台应用；即使从 Atoll 界面点击打开剪切板，也能恢复正确目标。按 Enter 后会等待目标应用重新激活，并把 `Command+V` 定向发送到该进程。
- 激活旧条目或分组前，会先同步保存尚未被 0.5 秒轮询捕获的最新系统剪贴板内容，避免旧条目写入覆盖并丢失刚复制的内容；历史已达容量上限时会临时保护当前待激活项。
- 图片、富文本和文件会在清空系统剪贴板之前完成载荷预检；载荷失效时保持当前剪贴板不变，也不会错误地把失效条目提到首位。
- `Esc`：关闭剪切板管理器。
- 界面使用中文。

实测时，必须确认正式 Atoll 具有辅助功能权限；否则 CGEvent 粘贴不会送达目标应用。可使用 TextEdit 手工回归：复制一段唯一文本 → 聚焦 TextEdit → `⌘⇧J` → 输入文本片段筛选 → `Enter`，应关闭面板并将所选文本粘贴进 TextEdit。

## 汽水音乐收藏：重要约束

`ac15410` 已完整移除之前加入的 `SodaMusicFavoriteController`、屏幕坐标点击、模拟 Cmd+L、自动激活汽水音乐，以及本地伪收藏缓存。

**绝对不要**为了“同步收藏”而：

- 模拟鼠标点击汽水音乐的爱心；
- 根据窗口坐标猜测按钮位置；
- 激活/抢焦点后模拟快捷键；
- 在 Atoll 的 `UserDefaults` 中伪造“已收藏”状态。

当前收藏按钮仅走 Atoll 原有媒体控制器路径。如果未来要支持汽水音乐收藏，只能在确认其公开、稳定、可验证的原生 API/媒体控制能力后实现；做不到就明确显示不支持，不能用 UI 自动化替代。

## 近期提交

```text
ac15410 Revert Soda Music UI automation
0e521a8 Standardize local Atoll installation
630ecb1 Fix native Soda favorites and clipboard activation
d576fcf Add instant fuzzy clipboard search
8c2fe61 Remove online update and GitHub integrations
```

`630ecb1` 同时包含剪切板键盘处理；不要整体回退该提交。汽水自动化部分已经由 `ac15410` 精确移除。

## 常用检查与提交

```bash
git status --short --branch
git diff --check
bash -n Scripts/install-local.sh
plutil -lint Scripts/AtollLocal.entitlements
git add <修改文件>
git commit -m "说明修改内容"
```

除非用户明确要求，否则提交后不要 push。若改动涉及应用功能或版本，运行 `./Scripts/install-local.sh`，并确认主进程路径是 `/Applications/Atoll.app`。

## 已知陷阱

- 不要在 build 目录直接启动 Atoll；这会运行陈旧 Debug 包并造成“所有修改没了”。
- 不要用宽泛的 `pkill -f` 模式杀媒体适配器；模式可能误匹配当前 shell。安装脚本已使用锚定的 Perl 进程匹配。
- 不要把 Release 构建改回原项目的 Developer ID 签名配置：本机没有原作者私钥，会构建失败。
- 不要删除 `Scripts/install-local.sh` 和 `Scripts/AtollLocal.entitlements`；它们是单一正式安装路径的一部分。

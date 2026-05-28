# local_build_alttab

[English](./README.md) | **简体中文**

一键从源码构建并安装 [AltTab](https://github.com/lwouis/alt-tab-macos)（macOS 上的 Windows 风格切换器）的脚本。

脚本会自动完成：

1. 克隆（或更新）`lwouis/alt-tab-macos` 仓库
2. 生成并信任本地 `Local Self-Signed` 代码签名证书
3. 补齐 `config/local.xcconfig` 中 Info.plist 所需的占位变量
4. 使用 `xcodebuild` 构建 Debug 版本
5. 如果检测到旧的 `AltTab.app`，会弹出确认（y/N）询问是否删除并重置其系统授权（辅助功能 / 屏幕录制 / 输入监控等）；非交互式（如管道）下默认保留，传 `--force-reset` 可强制清理
6. 安装到 `/Applications`（不可写则回退到 `~/Applications`）
7. **自动把 Debug 构建切到 Pro 状态**（与应用内 Debug QA 菜单里的 "Pro" 按钮一致），启动后不会弹激活窗口

---

## 系统要求

- macOS
- 已安装完整版 **Xcode**（仅 Command Line Tools 不够），并已启动一次接受许可协议
- 网络可访问 GitHub

### 如果尚未安装 Xcode

脚本运行时会自动检测 Xcode，若缺失会给出提示。也可以按下面步骤手动安装：

1. **从 Mac App Store 安装 Xcode**（免费，体积约 10 GB）：

   ```bash
   open 'macappstore://apps.apple.com/app/xcode/id497799835'
   ```

2. **启动一次 Xcode**，接受许可协议（首次启动会弹窗），等待组件安装完成。

3. **把命令行工具链指向 Xcode**（很重要，否则 `xcodebuild` 找不到工具）：

   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -license accept
   ```

4. **验证安装**：

   ```bash
   xcodebuild -version
   # 期望输出类似：
   # Xcode 15.x
   # Build version ...
   ```

> 如果只装了 Command Line Tools，`xcodebuild` 会缺失或指向错误路径，脚本会在预检阶段报错并给出修复命令。

### 如果连 `git` 也没有

`git` 随 Xcode Command Line Tools 一起安装。脚本检测到缺失时会提示是否自动触发：

```bash
xcode-select --install
```
弹出的 GUI 安装器完成后再重新运行脚本即可。

---

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/Allsochen/local_build_alttab/main/build.sh | bash
```

执行过程中 macOS 会弹出 1–2 次 Keychain 密码框，用于导入并信任本地自签名证书，正常输入登录密码即可。

> 如果系统中已有旧的 `AltTab.app`，脚本会**询问**是否删除并重置授权。注意 `curl … | bash` 走的是管道，不是交互式 TTY，提示会被跳过；要让提示真正弹出来，可以先下载脚本再执行（见下文 [常用选项](#常用选项)），或者用：
>
> ```bash
> bash -c "$(curl -fsSL https://raw.githubusercontent.com/Allsochen/local_build_alttab/main/build.sh)"
> ```
>
> 如果选择了清理或加了 `--force-reset`，首次启动 AltTab 时需要重新授予**辅助功能（Accessibility）**等权限。

---

## 常用选项

如需自定义行为，可下载脚本后再执行：

```bash
curl -fsSLO https://raw.githubusercontent.com/Allsochen/local_build_alttab/main/build.sh
chmod +x build.sh

./build.sh                                  # 默认：克隆/更新 + 构建 + 安装 + 自动激活 Pro
./build.sh --no-update                      # 不执行 git pull，构建当前 HEAD
./build.sh --skip-codesign                  # 复用已有签名身份
./build.sh --force-reset                    # 直接清理旧版本及其授权（不弹确认）
./build.sh --keep-permissions               # 直接保留旧版本及其授权（不弹确认）
./build.sh --repo-dir ~/code/alt-tab-macos  # 自定义源码目录
./build.sh --dest ~/Applications            # 自定义安装目录
./build.sh --help                           # 查看完整帮助
```

默认参数：

| 参数        | 默认值                                              |
| ----------- | --------------------------------------------------- |
| `REPO_URL`  | `https://github.com/lwouis/alt-tab-macos.git`       |
| `REPO_DIR`  | `~/alt-tab-macos`                                   |
| `DEST_DIR`  | `/Applications`（无写权限则回退到 `~/Applications`） |

---

## Debug 构建自动激活 Pro

AltTab 有付费的 **Pro** 功能。在 Debug 构建里，应用内有一个 QA 菜单，点击其中的 "Pro" 按钮会把本地 license 状态切到 Pro，便于开发者调试。脚本会在安装完成后自动完成同样的操作——app 启动时直接进入 Pro 状态，激活窗口不再弹出。

它写入的内容（与源码 [`src/pro/license/LicenseManager.swift`](https://github.com/lwouis/alt-tab-macos/blob/master/src/pro/license/LicenseManager.swift) 中的 `mockProUser()` 一一对应）：

| 存储位置                                          | Key / account          | 值                              |
| ------------------------------------------------- | ---------------------- | ------------------------------- |
| Keychain（`com.lwouis.alt-tab-macos.license`）    | `licenseKey`           | `MOCK-PRO-LICENSE-KEY`          |
| Keychain                                          | `instanceId`           | `mock-instance-id`              |
| UserDefaults（`com.lwouis.alt-tab-macos.license`）| `lastValidation`       | 当前 epoch 时间戳               |
| UserDefaults                                      | `lastValidationResult` | `true`                          |
| UserDefaults                                      | `customerEmail`        | `john@cool-software.com`        |

> **重要：仅适用于本地 Debug 构建。** `mockProUser()` 被 `#if DEBUG` 包裹，Release 构建里这条路径根本不存在。请**不要**对正式分发的 binary 做这件事；如果你需要在 Release 上使用 Pro，请[购买正版 license](https://alt-tab-macos.netlify.app/)。

撤销 mock Pro 状态：

```bash
security delete-generic-password -s com.lwouis.alt-tab-macos.license -a licenseKey
security delete-generic-password -s com.lwouis.alt-tab-macos.license -a instanceId
defaults delete com.lwouis.alt-tab-macos.license
```

---

## 卸载

```bash
# 删除 app 包
rm -rf /Applications/AltTab.app ~/Applications/AltTab.app

# 撤销以前授予的系统权限（best-effort，错误可忽略）
for svc in Accessibility ScreenCapture ListenEvent PostEvent \
           AppleEvents Microphone Camera SystemPolicyAllFiles; do
  tccutil reset "$svc" com.lwouis.alt-tab-macos 2>/dev/null || true
done
```

如需同时清理源码与构建产物：

```bash
rm -rf ~/alt-tab-macos
```

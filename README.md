# wechat4-auto

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/thisisname123/wechat4-auto/actions/workflows/ci.yml/badge.svg)](https://github.com/thisisname123/wechat4-auto/actions/workflows/ci.yml)

给 **微信 4.x（Windows 桌面版，`Weixin.exe`）** 发消息的零依赖自动化脚本。

> Windows 上微信 4.x 客户端用 Qt + 自研 MMUI 渲染，几乎不暴露 UI-Automation 控件树，导致 `uiautomation` / `pywinauto` 这类老工具失效。本工具改用 **「Windows 内置 OCR 读屏 + 屏幕坐标注入」** 的方式，不依赖 Hook、不依赖协议、不需要安装任何第三方库。

[English](#english) · [原理说明](docs/how-it-works.md)

---

## 特性

- ✅ **零依赖**：仅需 Windows 10/11 + 系统自带 Windows PowerShell 5.1
- ✅ **中文识别**：调用系统内置 OCR（`Windows.Media.Ocr`，`zh-Hans-CN`）
- ✅ **中文输入**：剪贴板 + `Ctrl+V`，绕开输入法（IME）问题
- ✅ **发送前/后 OCR 校验**：发送前确认文本已进输入框，发送后再复核
- ✅ **纯函数式模块**：可 `Import-Module` 复用，也可直接用命令行脚本

## 快速开始

```powershell
# 1) 打开微信 4.x 并登录，手动点开要发送的好友聊天（或确保目标好友在左侧最近会话里）

# 2) 给「当前打开的聊天」发送消息
powershell -ExecutionPolicy Bypass -File .\send-wechat.ps1 -Message "吃完饭后打三角洲吗？"

# 3) 给指定好友发送（实验性：需目标好友出现在左侧最近会话列表）
powershell -ExecutionPolicy Bypass -File .\send-wechat.ps1 -Message "晚上一起打三角洲" -To "肖文博"
```

或作为模块使用：

```powershell
Import-Module .\WechatAuto.psm1
Send-WechatMessage -Message "你好" -To "肖文博"     # 发给指定好友（实验性）
Send-WechatMessage -Message "你好"                  # 发给当前聊天
```

## 工作流程

1. `Get-WechatWindow` —— 按「类名前缀 `Qt` + 进程 `Weixin.exe/WeChat.exe`」定位微信主窗口
2. `Read-WechatScreen` —— 置前台 → 截屏 → 系统 OCR 读屏，返回每行文字的坐标和内容
3. 通过 OCR 找到右下角「**发送**」按钮作为锚点，反推输入框位置
4. `Send-WechatClick` 点击输入框 → `Send-WechatPaste` 剪贴板粘贴中文 → `Enter` 发送
5. 发送前/后各做一次 OCR 校验，文本对不上就中止

## 环境要求

| 项 | 要求 |
|---|---|
| 系统 | Windows 10 / 11 |
| 终端 | Windows PowerShell 5.1（系统自带） |
| 微信 | 4.x 桌面版（`Weixin.exe`），需已登录 |
| 中文 OCR | 系统需装有「中文（简体）」语言包（一般中文系统自带） |

## ⚠️ 重要注意事项

1. **输入注入可能被拦截**：某些沙箱环境或安全软件（如 HIPS 类防护）会拦截 `SetCursorPos` / `keybd_event`（表现为光标不动、按键无效）。请用**非沙箱/管理员权限**的 PowerShell 运行。
2. **屏幕不能锁屏/最小化**：本工具依赖真实屏幕内容，微信窗口需可见且不最小化。
3. **DPI 缩放**：脚本内部调用 `SetProcessDPIAware()`，坐标统一为物理像素，无需手动换算。
4. **`-To` 为实验性功能**：目前只支持从左侧「最近会话」列表里按可见文字点击；不在列表里的好友请先手动打开聊天，再用不带 `-To` 的方式发送。
5. **坐标可能需校准**：不同分辨率/字体缩放下输入框位置略有差异，可用 `-InputX/-InputY` 手动指定，或参考[原理说明](docs/how-it-works.md)中的锚点推导。

## 局限

- 只做了**文本发送**（图片/文件/表情未覆盖）。
- 发送结果的 OCR 校验是**尽力而为**，OCR 对个别字形（如「饭/反」「角」）可能识别偏差，极端情况下可能误报。
- 未实现消息监听/接收。

## 免责声明

本工具仅供**学习、研究与个人自动化**使用，请遵守微信《软件许可及服务协议》及相关法律法规，勿用于批量营销、骚扰、外挂等用途。使用本工具产生的任何后果由使用者自行承担。

## 相关项目

| 项目 | 路线 | 微信版本 |
|---|---|---|
| [wxauto](https://github.com/cluic/wxauto) | UIA 自动化 | 3.x |
| [wxautox4](https://pypi.org/project/wxautox4/) | UIA 自动化（需授权） | 4.0.5 |
| [WeChatFerry](https://github.com/lich0821/WeChatFerry) | Hook / DLL 注入 | 3.x |
| [wechat-automation-api](https://github.com/LAVARONG/wechat-automation-api) | Flask + uiautomation | 4.0+ |
| [omni-bot-sdk-oss](https://github.com/weixin-omni/omni-bot-sdk-oss) | YOLO + OCR + DB | 4.0 |
| **本项目 wechat4-auto** | **OCR + 坐标** | **4.x** |

## License

[MIT](LICENSE)

---

## English

**wechat4-auto** is a zero-dependency PowerShell tool that sends text messages via the WeChat 4.x desktop client on Windows.

The WeChat 4.x client renders its UI with a custom Qt/MMUI surface that exposes almost no UI-Automation tree, so classic `uiautomation`-based tools break. This project instead **reads the screen with the built-in Windows OCR** and **injects mouse/keyboard through plain user32 P/Invoke** — no hooks, no third-party dependencies.

```powershell
# send to the currently open chat
powershell -ExecutionPolicy Bypass -File .\send-wechat.ps1 -Message "Hello"

# send to a contact visible in the recent-chat list (experimental)
powershell -ExecutionPolicy Bypass -File .\send-wechat.ps1 -Message "Hello" -To "Bob"
```

See [docs/how-it-works.md](docs/how-it-works.md) for the technical write-up. MIT licensed.

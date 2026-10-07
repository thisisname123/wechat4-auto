# 原理说明 / How it works

## 为什么不用 UIA、Hook 或协议？

微信 4.x 桌面版（`Weixin.exe`）相较 3.x 做了重写，UI 采用 **Qt 5 + 自研 MMUI 渲染**：

- 整个界面内容绘制在一个 `MMUIRenderSubWindowHW` 自绘子窗口里；
- 通过 UIA（`System.Windows.Automation`）枚举，主窗口下只有两个空 Pane，**没有可定位的 Edit/Button 控件**；
- 因此 `uiautomation` / `pywinauto` 按控件名定位的方式失效。

Hook（如 WeChatFerry 的 DLL 注入）只适配 3.x 内存布局；协议方案（itchat 等）只支持网页版/旧接口。所以对 4.x 而言，**「视觉读屏 + 坐标点击」** 是目前侵入性最低、最通用的路线——这也是 [omni-bot-sdk-oss](https://github.com/weixin-omni/omni-bot-sdk-oss) 采用 YOLO+OCR 的原因。本项目用系统自带 OCR 实现同思路的轻量版。

## 关键技术点

### 1. 定位微信主窗口

`Weixin.exe` 有多个顶层窗口（主窗口、隐藏 Pane、托盘消息窗、IME 窗等）。通过以下规则取到主窗口：

- 类名以 `Qt` 开头（`Qt51514QWindowIcon` 之类，随版本可能变化）；
- 拥有者进程镜像名为 `Weixin.exe` / `WeChat.exe`；
- 在满足条件的可见窗口中取**面积最大**的那个。

### 2. DPI 物理坐标统一

```csharp
[DllImport("user32.dll")] static extern bool SetProcessDPIAware();
```

进程声明 DPI 感知后，`GetWindowRect`、`SetCursorPos`、`GetCursorPos` 全部使用**物理像素**，坐标可直接相加，无需手动换算缩放（实测 150% 缩放下 `SetCursorPos(400,400)` 与 `GetCursorPos(400,400)` 完全对齐）。

### 3. 读屏 OCR（零依赖）

用 Windows 内置的 WinRT OCR 组件 `Windows.Media.Ocr`：

1. `Graphics.CopyFromScreen` 截取微信窗口区域为 PNG；
2. 通过 `System.Runtime.WindowsRuntime` 的 `AsTask` 扩展把 WinRT 异步桥接成 .NET `Task`，再 `Wait()` 取结果；
3. 关键点：**不能用 `StorageFile.GetFileFromPathAsync` 读文件**（普通进程会被 UWP 文件权限拒绝），改用 `MemoryStream` → `AsRandomAccessStream` 内存流喂给 `BitmapDecoder`；
4. `OcrEngine.TryCreateFromLanguage(zh-Hans-CN)` 得到中文识别引擎，遍历 `OcrResult.Lines` 得到每行的 `(X, Y, Text)`。

### 4. 输入框锚点

不硬编码输入框绝对坐标，而是先 OCR 底部区域找到「**发送**」按钮 `(sendX, sendY)`，再反推输入框：

```
inputX ≈ sendX * 0.48
inputY ≈ sendY - 60
```

（经验值，与 4.1.x 布局吻合；不同版本可用 `-InputX/-InputY` 覆盖。）

### 5. 中文输入用剪贴板

直接 `SendInput` 发 Unicode 字符或模拟 IME 都很脆弱。改用：

```
Set-Clipboard "吃完饭后打三角洲吗？"  →  keybd_event(Ctrl+V)
```

微信把剪贴板文本按纯文本粘进输入框，绕开搜狗/微软拼音等 IME 状态影响。

### 6. 前台激活的「Alt 键技巧」

后台进程直接 `SetForegroundWindow` 常被前台锁拦截，先注入一次 Alt 按下/抬起再调用即可绕过：

```csharp
keybd_event(VK_MENU, 0, 0, 0);   // Alt down
SetForegroundWindow(hwnd);
keybd_event(VK_MENU, 0, 2, 0);   // Alt up
```

### 7. 发送前/后校验

- 粘贴后 OCR 输入框区域，确认文本首 2 字命中才 `Enter`；
- 发送后 OCR 全窗口，再次确认文本出现（此时输入框已清空、消息进入聊天区）。

> 校验是启发式的：OCR 对「饭/反」「角」等近形字可能误读，所以只匹配首 2 字，且提供 `-NoVerify` 跳过。

## 权限/沙箱问题（重要）

输入注入（`SetCursorPos` / `keybd_event` / `mouse_event`）会被以下场景静默拦截：

- 部分「受限沙箱」：`SetCursorPos` 返回 `False`，光标不动；
- 部分安全软件（HIPS）：注入被吞掉。

排查方法：`SetCursorPos(0,0)` 后 `GetCursorPos` 看光标是否真的移动了。若不动，换**管理员 + 非沙箱**的 PowerShell 再试。

## 目录结构

```
wechat4-auto/
├── WechatAuto.psm1        # 核心模块（原生互操作 + OCR + 业务流程）
├── send-wechat.ps1        # 命令行入口
├── examples/
│   └── send-simple.ps1
└── docs/
    └── how-it-works.md    # 本文档
```

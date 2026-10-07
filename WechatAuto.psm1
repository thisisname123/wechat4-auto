# WechatAuto.psm1
# =============================================================================
#  WeChat 4.x (Windows) automation — zero-dependency OCR + coordinate injection.
#
#  The new WeChat 4.x desktop client (Weixin.exe) renders its UI with a custom
#  Qt/MMUI surface that exposes an (almost) empty UI-Automation tree, so the
#  classic `uiautomation`-based tools do not work. This module instead:
#    1. reads the screen with the built-in Windows OCR (Windows.Media.Ocr,
#       zh-Hans-CN) to *see* the UI, and
#    2. injects mouse / keyboard with plain user32 P/Invoke.
#
#  Zero external dependencies: Windows 10/11 + Windows PowerShell 5.1 only.
#
#  NOTE on permissions: input injection (SetCursorPos / keybd_event) is blocked
#  by some sandboxes and by some security software. Run the host from an
#  unsandboxed / elevated PowerShell if injection silently fails.
# =============================================================================

# ---------------------------------------------------------------------------
# Native interop (compiled once per process)
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Drawing -ErrorAction Stop
Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class WechatNative {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lp);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool QueryFullProcessImageName(IntPtr hProcess, uint flags, StringBuilder buf, ref uint size);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    // Returns the largest visible top-level window whose class starts with
    // `classPrefix` and whose owning process image name is in `processNames`.
    public static IntPtr FindWindow(string[] processNames, string classPrefix) {
        IntPtr found = IntPtr.Zero;
        long bestArea = -1;
        EnumWindows((h, lp) => {
            if (!IsWindowVisible(h)) return true;
            var cls = new StringBuilder(256); GetClassName(h, cls, cls.Capacity);
            if (!cls.ToString().StartsWith(classPrefix)) return true;
            uint pid; GetWindowThreadProcessId(h, out pid);
            string img = GetProcessImage(pid);
            if (img == null) return true;
            bool match = false;
            foreach (var p in processNames) {
                if (img.ToLowerInvariant().EndsWith("\\" + p.ToLowerInvariant())) { match = true; break; }
            }
            if (!match) return true;
            RECT r;
            if (GetWindowRect(h, out r)) {
                long area = (long)(r.Right - r.Left) * (r.Bottom - r.Top);
                if (area > bestArea) { bestArea = area; found = h; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static string GetProcessImage(uint pid) {
        IntPtr hp = OpenProcess(0x1000, false, pid); // PROCESS_QUERY_LIMITED_INFORMATION
        if (hp == IntPtr.Zero) return null;
        var b = new StringBuilder(1024); uint sz = 1024;
        bool ok = QueryFullProcessImageName(hp, 0, b, ref sz);
        CloseHandle(hp);
        return ok ? b.ToString() : null;
    }

    public static string GetTitle(IntPtr h) {
        var s = new StringBuilder(512); GetWindowText(h, s, s.Capacity); return s.ToString();
    }

    public static void Activate(IntPtr h) {
        if (IsIconic(h)) ShowWindowAsync(h, 9); // SW_RESTORE
        // The Alt-key dance releases the foreground lock so SetForegroundWindow succeeds.
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        SetForegroundWindow(h);
        keybd_event(0x12, 0, 2, UIntPtr.Zero);
    }

    public static void Click(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(60);
        mouse_event(0x02, 0, 0, 0, UIntPtr.Zero); // LEFTDOWN
        System.Threading.Thread.Sleep(40);
        mouse_event(0x04, 0, 0, 0, UIntPtr.Zero); // LEFTUP
    }

    public static void SendCombo(bool ctrl, bool alt, bool shift, byte vk) {
        if (ctrl) keybd_event(0x11, 0, 0, UIntPtr.Zero);
        if (alt)  keybd_event(0x12, 0, 0, UIntPtr.Zero);
        if (shift)keybd_event(0x10, 0, 0, UIntPtr.Zero);
        keybd_event(vk, 0, 0, UIntPtr.Zero);
        keybd_event(vk, 0, 2, UIntPtr.Zero);
        if (shift)keybd_event(0x10, 0, 2, UIntPtr.Zero);
        if (alt)  keybd_event(0x12, 0, 2, UIntPtr.Zero);
        if (ctrl) keybd_event(0x11, 0, 2, UIntPtr.Zero);
    }
}
"@ -ErrorAction Stop

[WechatNative]::SetProcessDPIAware() | Out-Null

# ---------------------------------------------------------------------------
# Windows OCR helpers (Windows.Media.Ocr over WinRT, bridged via AsTask)
# ---------------------------------------------------------------------------
$script:OcrEngine = $null
$script:AsTaskMethod = $null

function Get-OcrAsTaskMethod {
    if ($null -eq $script:AsTaskMethod) {
        $script:AsTaskMethod = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.IsGenericType -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        })[0]
    }
    return $script:AsTaskMethod
}

function Wait-WinRtTask {
    param($WinRtTask, [type]$ResultType)
    $asTask = Get-OcrAsTaskMethod
    $netTask = $asTask.MakeGenericMethod($ResultType).Invoke($null, @($WinRtTask))
    $netTask.Wait(-1) | Out-Null
    return $netTask.Result
}

function Get-OcrEngine {
    if ($null -ne $script:OcrEngine) { return $script:OcrEngine }
    [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    [Windows.Globalization.Language, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    [Windows.Storage.Streams.RandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime] | Out-Null

    $lang = [Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages |
        Where-Object { $_.LanguageTag -eq 'zh-Hans-CN' } | Select-Object -First 1
    if ($null -eq $lang) {
        $lang = [Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | Select-Object -First 1
    }
    if ($null -eq $lang) { throw 'No OCR recognizer language is installed on this system.' }

    $script:OcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
    if ($null -eq $script:OcrEngine) { throw 'Failed to create the Windows OCR engine.' }
    return $script:OcrEngine
}

# ---------------------------------------------------------------------------
# Public functions
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
Finds the main WeChat window handle.

.DESCRIPTION
Enumerates visible top-level windows, keeps those whose class starts with
"Qt" and whose owning process is Weixin.exe / WeChat.exe, and returns the
largest one (the main window, not tray/message helper windows).
#>
function Get-WechatWindow {
    [CmdletBinding()]
    param(
        [string[]]$ProcessNames = @('Weixin.exe', 'WeChat.exe'),
        [string]$ClassPrefix = 'Qt'
    )
    $h = [WechatNative]::FindWindow($ProcessNames, $ClassPrefix)
    if ($h -eq [IntPtr]::Zero) {
        throw 'WeChat window not found. Make sure WeChat (Weixin.exe / WeChat.exe) is running and logged in.'
    }
    return $h
}

<#
.SYNOPSIS
Brings the WeChat window to the foreground.
#>
function Invoke-WechatForeground {
    [CmdletBinding()]
    param([IntPtr]$Window = [IntPtr]::Zero)
    if ($Window -eq [IntPtr]::Zero) { $Window = Get-WechatWindow }
    [WechatNative]::Activate($Window)
    Start-Sleep -Milliseconds 400
}

<#
.SYNOPSIS
Captures (a region of) the WeChat window and returns the OCR text lines.

.DESCRIPTION
Activates the window, captures it from the screen, then runs the built-in
Windows OCR. Coordinates are physical pixels relative to the window's top-left
corner. Returns an array of objects: X, Y (top-left of the first word) and Text.

.PARAMETER CropX/CropY/CropW/CropH
Window-relative region to capture. Defaults to the whole window.
#>
function Read-WechatScreen {
    [CmdletBinding()]
    param(
        [IntPtr]$Window = [IntPtr]::Zero,
        [int]$CropX = -1,
        [int]$CropY = -1,
        [int]$CropW = -1,
        [int]$CropH = -1,
        [string]$TempPng = (Join-Path $env:TEMP 'wechat4-auto-ocr.png')
    )
    if ($Window -eq [IntPtr]::Zero) { $Window = Get-WechatWindow }
    Invoke-WechatForeground -Window $Window

    $rect = New-Object WechatNative+RECT
    [WechatNative]::GetWindowRect($Window, [ref]$rect) | Out-Null
    $w = $rect.Right - $rect.Left
    $h = $rect.Bottom - $rect.Top

    if ($CropX -lt 0) { $CropX = 0 }
    if ($CropY -lt 0) { $CropY = 0 }
    if ($CropW -le 0) { $CropW = $w - $CropX }
    if ($CropH -le 0) { $CropH = $h - $CropY }

    $bmp = New-Object System.Drawing.Bitmap($CropW, $CropH)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen(($rect.Left + $CropX), ($rect.Top + $CropY), 0, 0, (New-Object System.Drawing.Size($CropW, $CropH)))
    $g.Dispose()
    $bmp.Save($TempPng, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()

    $engine = Get-OcrEngine
    $bytes = [System.IO.File]::ReadAllBytes($TempPng)
    $ms = New-Object System.IO.MemoryStream(, $bytes)
    $stream = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($ms)
    $decoder = Wait-WinRtTask ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $sbmp = Wait-WinRtTask ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $result = Wait-WinRtTask ($engine.RecognizeAsync($sbmp)) ([Windows.Media.Ocr.OcrResult])

    $lines = @()
    foreach ($line in @($result.Lines)) {
        $words = @($line.Words)
        $x = $CropX; $y = $CropY
        if ($words.Count -gt 0) {
            try { $x = [int]$words[0].BoundingRect.X + $CropX; $y = [int]$words[0].BoundingRect.Y + $CropY } catch { }
        }
        $lines += [PSCustomObject]@{ X = $x; Y = $y; Text = $line.Text }
    }
    return $lines
}

<#
.SYNOPSIS
Finds the first OCR line whose text contains a substring.

.DESCRIPTION
Returns the first line object (X, Y, Text) whose Text contains -Pattern.
Returns $null when not found.
#>
function Find-ScreenText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Pattern,
        [object[]]$Lines
    )
    foreach ($l in $Lines) {
        if ($l.Text -like "*$Pattern*") { return $l }
    }
    return $null
}

<#
.SYNOPSIS
Left-clicks a point inside the WeChat window (window-relative physical px).
#>
function Send-WechatClick {
    [CmdletBinding()]
    param(
        [int]$X,
        [int]$Y,
        [IntPtr]$Window = [IntPtr]::Zero
    )
    if ($Window -eq [IntPtr]::Zero) { $Window = Get-WechatWindow }
    Invoke-WechatForeground -Window $Window
    $rect = New-Object WechatNative+RECT
    [WechatNative]::GetWindowRect($Window, [ref]$rect) | Out-Null
    [WechatNative]::Click($rect.Left + $X, $rect.Top + $Y)
}

<#
.SYNOPSIS
Pastes text into the focused WeChat control (clipboard + Ctrl+V).
#>
function Send-WechatPaste {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [IntPtr]$Window = [IntPtr]::Zero
    )
    if ($Window -eq [IntPtr]::Zero) { $Window = Get-WechatWindow }
    Invoke-WechatForeground -Window $Window
    Set-Clipboard -Value $Text
    Start-Sleep -Milliseconds 150
    [WechatNative]::SendCombo($true, $false, $false, 0x56)  # Ctrl+V
}

<#
.SYNOPSIS
Sends a key combination to the foreground WeChat window.
#>
function Send-WechatKeys {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Combo,
        [IntPtr]$Window = [IntPtr]::Zero
    )
    if ($Window -eq [IntPtr]::Zero) { $Window = Get-WechatWindow }
    Invoke-WechatForeground -Window $Window
    $u = $Combo.ToUpperInvariant()
    $ctrl = $u.Contains('CTRL'); $alt = $u.Contains('ALT'); $shift = $u.Contains('SHIFT')
    $key = ($u -replace 'CTRL\+', '' -replace 'ALT\+', '' -replace 'SHIFT\+', '').Trim()
    $vk = switch ($key) {
        'ENTER'  { 0x0D } 'TAB' { 0x09 } 'ESC' { 0x1B } 'BACK' { 0x08 } 'DELETE' { 0x2E }
        'UP'     { 0x26 } 'DOWN' { 0x28 } 'LEFT' { 0x25 } 'RIGHT' { 0x27 }
        'HOME'   { 0x24 } 'END'  { 0x23 }
        'F' { 0x46 } 'A' { 0x41 } 'V' { 0x56 } 'C' { 0x43 } 'X' { 0x58 } 'Z' { 0x5A } 'Y' { 0x59 } 'N' { 0x4E }
        default  { 0 }
    }
    if ($vk -eq 0) { throw "Unsupported key: $key" }
    [WechatNative]::SendCombo($ctrl, $alt, $shift, [byte]$vk)
}

<#
.SYNOPSIS
Sends a text message to a WeChat chat (WeChat 4.x, Windows).

.DESCRIPTION
Primary workflow:
  1. locate + activate WeChat;
  2. (optional, experimental) open the chat with -To;
  3. anchor the input box via the "发送" (Send) button found by OCR;
  4. click the input box, paste -Message, press Enter;
  5. OCR-verify that the message left the input box and appears in the chat.

.PARAMETER To
Display name / remark of the target contact. When omitted, sends to the
currently open chat. NOTE: the auto-open path is experimental and relies on
the contact being visible in the recent-chat list.

.PARAMETER InputX / InputY
Manual override of the input-box click point (window-relative physical px).
When omitted, the point is derived from the "发送" button anchor.
#>
function Send-WechatMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$To = '',
        [int]$InputX = -1,
        [int]$InputY = -1,
        [switch]$NoVerify
    )
    $Window = Get-WechatWindow
    Invoke-WechatForeground -Window $Window

    # Window size in physical pixels.
    $rect = New-Object WechatNative+RECT
    [WechatNative]::GetWindowRect($Window, [ref]$rect) | Out-Null
    $WinW = $rect.Right - $rect.Left
    $WinH = $rect.Bottom - $rect.Top

    if ($To) {
        # Experimental: click the contact in the visible recent-chat list.
        $lines = Read-WechatScreen -Window $Window
        $target = Find-ScreenText -Pattern $To -Lines $lines
        if ($null -eq $target) {
            throw "Could not find '$To' on the visible screen. Open that chat manually, then run without -To."
        }
        Send-WechatClick -X $target.X -Y $target.Y -Window $Window
        Start-Sleep -Milliseconds 700
    }

    # Locate the "发送" (Send) button in the bottom quarter to anchor the input box.
    $bottom = Read-WechatScreen -Window $Window -CropY ([int]($WinH * 0.75))
    $sendBtn = Find-ScreenText -Pattern '发送' -Lines $bottom
    if ($null -eq $sendBtn) {
        $sendBtn = [PSCustomObject]@{ X = [int]($WinW * 0.925); Y = [int]($WinH * 0.94) }
        Write-Warning 'Could not OCR the "发送" button; using a default anchor. Consider passing -InputX/-InputY.'
    }

    if ($InputX -lt 0) { $InputX = [int]($sendBtn.X * 0.48) }
    if ($InputY -lt 0) { $InputY = [int]($sendBtn.Y - 60) }

    Send-WechatClick -X $InputX -Y $InputY -Window $Window
    Start-Sleep -Milliseconds 250
    Send-WechatPaste -Text $Message -Window $Window
    Start-Sleep -Milliseconds 400

    $head = $Message.Substring(0, [Math]::Min(2, $Message.Length))
    if (-not $NoVerify) {
        # Verify the text is actually in the input area before sending.
        $inputArea = Read-WechatScreen -Window $Window -CropX ([int]($InputX - 300)) -CropY ([int]($InputY - 130)) -CropW 700 -CropH 220
        if (($inputArea | ForEach-Object { $_.Text }) -join '' -notmatch [regex]::Escape($head)) {
            Write-Warning 'The pasted text could not be confirmed in the input box; aborting before send.'
            return
        }
    }

    Send-WechatKeys -Combo 'ENTER' -Window $Window
    Start-Sleep -Milliseconds 600

    if (-not $NoVerify) {
        $after = Read-WechatScreen -Window $Window
        if (($after | ForEach-Object { $_.Text }) -join '' -notmatch [regex]::Escape($head)) {
            Write-Warning 'Message may not have been sent; please check the WeChat window.'
            return
        }
    }

    if ($To) { $who = $To } else { $who = '<current chat>' }
    Write-Output "Message sent."
    Write-Output ("  To:   " + $who)
    Write-Output ("  Text: " + $Message)
}

Export-ModuleMember -Function Get-WechatWindow, Invoke-WechatForeground, Read-WechatScreen,
    Find-ScreenText, Send-WechatClick, Send-WechatPaste, Send-WechatKeys, Send-WechatMessage

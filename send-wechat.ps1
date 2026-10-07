# send-wechat.ps1
# CLI entry point for WechatAuto. Sends a text message to WeChat 4.x (Windows).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\send-wechat.ps1 -Message "你好" -To "肖文博"
#   powershell -ExecutionPolicy Bypass -File .\send-wechat.ps1 -Message "你好"            # current chat

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Message,

    # Display name / remark of the target contact. Omit to send to the current chat.
    [string]$To = '',

    # Optional manual override of the input-box click point (window-relative px).
    [int]$InputX = -1,
    [int]$InputY = -1,

    # Skip OCR verification (faster, but no safety net).
    [switch]$NoVerify
)

Import-Module (Join-Path $PSScriptRoot 'WechatAuto.psm1') -Force

Send-WechatMessage -Message $Message -To $To -InputX $InputX -InputY $InputY -NoVerify:$NoVerify

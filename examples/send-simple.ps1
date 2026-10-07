# examples/send-simple.ps1
# Minimal usage of the WechatAuto module.

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'WechatAuto.psm1') -Force

# 1) Send to the currently open chat.
Send-WechatMessage -Message "吃完饭后打三角洲吗？"

# 2) Send to a named contact (experimental: the contact must be visible in the
#    recent-chat list on the left panel).
# Send-WechatMessage -Message "晚上一起打三角洲" -To "肖文博"

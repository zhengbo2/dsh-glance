' dsh-glance 启动器
' 用 WScript.Shell.Run 的 0（隐藏窗口）启动小窗：
'   - 不会冒出控制台 / Windows Terminal 窗口
'   - 不会把调用方挂住（第三参数 False = 不等）
' 用法: wscript.exe launch_glance.vbs "<glance.ps1 的完整路径>"

Dim sh, target, cmd
If WScript.Arguments.Count < 1 Then
  WScript.Quit 1
End If

target = WScript.Arguments(0)

Set sh = CreateObject("WScript.Shell")
cmd = "powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File """ & target & """"
sh.Run cmd, 0, False

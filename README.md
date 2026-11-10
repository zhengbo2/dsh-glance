# dsh-glance · 一眼

**给 DeepSeek Harness 桌面端的置顶小条：空闲时它只是一颗球，我一干活它就长成一小条——抬眼就知道我在想什么、在跑什么、是不是在等你。**

A tiny always-on-top strip for DSH desktop. Idle → one breathing ball; working → it stretches into a pill that shows what the agent is doing right now.

![preview](assets/preview.png)

---

## 它解决什么

**DSH 的会话界面被别的程序盖住时，你只能靠声音判断我干到哪了。**

**这颗球永远在最上面、不抢焦点、不占视线。**

## 长什么样

```
空闲        42px 白球，中间一个灰点，轻轻呼吸
干活        长成一小条：  ● 在跑 pwsh · 0:42
点 ▸        展开详情：我说的最后一句话 + 工具 + 状态（内容多可上下滚动）
拖          拖到哪记到哪，下次打开还在那
右键        透明度 / 始终置顶 / 隐藏
```

## 状态

| 状态 | 意思是 |
|---|---|
| 空闲 | 没在干活 |
| 思考中 | 模型在算，还没出字 |
| 在回话 | 字已经开始出来了 |
| 在跑 `<工具>` | 正在跑某个工具（会直接写工具名） |
| 等你批准 | 有一件事要你点一下 |
| 压缩上下文中 | 上下文正在被压缩 |
| 完成 | 这一轮结束（3.5 秒后回到空闲） |
| 出错 | 工具报错或模型重试 |

**计时按「这一趟」算：空闲才归零，状态在中间怎么变都不重置。**
**只认「正在干活」的那个会话——别的会话动一下带不跑它。**

---

## 为什么是 WPF 而不是 Electron

**这一版 DSH 桌面端不提供开窗能力。**
`window.dshDesktop` 暴露的只有 `browser / files / fileDrag / deviceInfo / closeWindow / shortcuts / updates / onboarding / boot / locale`——**没有 `openWindow`、没有置顶、没有透明窗。**

**所以这类插件只有两条路：**

```
Electron   观感最好，但要随包下发一百多 MB 的运行时
WPF        系统自带，零下载，透明 + 圆角 + 缓动都有   ← 本插件选这条
```

## 架构

```
lib/index.js                 Node 侧插件
                               听 session/event → 折叠成状态 → 写 state.json（节流 120ms）
                               启动时 spawn powershell 拉起 WPF 窗口；DSH 退出时 kill 掉

runtime/glance.ps1           WPF 窗口（需要 PowerShell -STA）
                               每 120ms 读一次 state.json → 切球 / 条 / 详情
                               透明、无边框、Topmost、WS_EX_NOACTIVATE 不抢焦点

runtime/launch_glance.vbs    开发用：手动重开窗口时用它，避免闪一个控制台窗
                               （插件本身不用它，直接 spawn 带 windowsHide）
```

**实际拉起命令：**

```
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File runtime/glance.ps1
```


**运行数据落在 `~/.dsh/glance/`：**

```
state.json    当前状态（插件写，窗口读）
ui.json       窗口位置 / 透明度 / 置顶（右键菜单写）
ui.log        启动与异常的记录
```

---

## 安装

**走插件命令：**

```powershell
dsh plugin --profile desktop add dsh-glance
```

**或者本地目录：**

```powershell
pnpm add "file:<你的路径>/dsh-glance" --dir %USERPROFILE%\.dsh\profiles\desktop
# 然后把 "dsh-glance" 写进该目录 package.json 的 dsh.profile.bundles
```

**装完重启 DSH。**

## 卸载

```powershell
dsh plugin --profile desktop remove dsh-glance
```

**它会跟着 DSH 一起退出，不会留孤儿窗口。**

---

## 已知限制（诚实版）

- **只测过 DSH `0.2.2-rc.1`**，`engines.dsh` 写的 `>=0.2.1-rc.2 <0.3.0-0`。
- **只有 Windows**：WPF 是 Windows 的。
- **分层透明窗截不了图**：系统 `CopyFromScreen` 抓不到它（只能抓到壁纸）。**OBS / Xbox Game Bar 能录**，因为它们走 DWM。
- **单实例**靠命名互斥量 `Local\dsh-glance-ui`；重复启动会自己退出。
- 窗口位置带小数时会糊——已经在读写位置时取整，并开了像素对齐。

## 还没做

- 干活时球外那圈往外扩的呼吸环
- 球「形」的呼吸（现在只有透明度在变）
- 干完活闪一下绿再缩回

---

## 开发

```powershell
# 改完源码要同步到插件目录（node_modules 里是拷贝，不是软链）
Copy-Item .\lib\index.js    $env:USERPROFILE\.dsh\profiles\desktop\node_modules\dsh-glance\lib\ -Force
Copy-Item .\runtime\glance.ps1 $env:USERPROFILE\.dsh\profiles\desktop\node_modules\dsh-glance\runtime\ -Force

# 只改窗口脚本时，可以单独重开窗口，不必重启 DSH
# （用 vbs 包一层，否则会弹出一个 Windows Terminal）
wscript.exe .\runtime\launch_glance.vbs (Resolve-Path .\runtime\glance.ps1)
```

**⚠️ `glance.ps1` 必须存成 UTF-8 **带 BOM** + CRLF。**
**否则 Windows PowerShell 5.1 会按 GBK 读，直接报「字符串缺少终止符」。**

## License

MIT

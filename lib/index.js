// dsh-glance · 置顶小条
//
// 把「我正在干什么」从 DSH 主窗口里搬到一个小小的置顶窗上：
//   空闲 → 一颗球；有任务 → 丝滑长成一小条；点 ▸ 展开详情。
//
// 宿主侧只做三件事：
//   1) 听 session/event，把事件流折叠成一个很简单的状态
//   2) 把状态写到 ~/.dsh/glance/state.json（节流 120ms）
//   3) 拉起 / 收起外层的 WPF 小窗（runtime/glance.ps1）
//
// 界面不在 DSH 里画 —— 这一版 DSH 桌面端不提供「开自己的窗口」的能力，
// 所以置顶窗由 WPF 单独承载（系统自带，不用下载运行时）。

export const name = 'dsh-glance'

import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HOME = process.env.DSH_HOME || join(homedir(), '.dsh')
const DIR = join(HOME, 'glance')
const STATE_FILE = join(DIR, 'state.json')
const UI_FILE = join(DIR, 'ui.json') // 窗口自己的状态：位置 / 透明度 / 置顶 / 展开
const RUNTIME = join(dirname(fileURLToPath(import.meta.url)), '..', 'runtime', 'glance.ps1')

const LABELS = {
  idle: '空闲',
  thought: '思考中',
  writing: '在回话',
  tool: '在跑工具',
  waiting: '等你批准',
  compact: '压缩上下文中',
  done: '完成',
  error: '出错',
}

// 状态 → 界面的颜色键（ps1 里映射到具体颜色）
const TONES = {
  idle: 'idle',
  thought: 'thought',
  writing: 'thought',
  tool: 'running',
  waiting: 'waiting',
  compact: 'running',
  done: 'done',
  error: 'error',
}

export function apply(ctx) {
  // ---- 状态机 ----------------------------------------------------------
  // 一路很朴素：谁先来就记谁，turn/end 归零。
  const st = {
    phase: 'idle',
    since: Date.now(),
    // 这一整趟（一次 turn）从什么时候开始；状态变化不重置它
    turnSince: 0,
    detail: '',
    tool: '',
    sessions: new Map(), // sessionId -> 该会话自己的小状态
  }

  let child
  let lastJson = ''
  let saveTimer

  const writeState = (force = false) => {
    clearTimeout(saveTimer)
    saveTimer = setTimeout(() => {
      const payload = {
        state: st.phase,
        label: st.phase === 'tool' && st.tool
      ? `在跑 ${String(st.tool).split(/[\s·]+/)[0]}`
      : (LABELS[st.phase] ?? st.phase),
        tone: TONES[st.phase] ?? 'idle',
        detail: clamp(st.detail, 120),
        tool: clamp(st.tool, 120),
        since: st.turnSince || st.since,
        at: Date.now(),
      }
      const json = JSON.stringify(payload)
      if (!force && json === lastJson) return
      lastJson = json
      try {
        mkdirSync(DIR, { recursive: true })
        writeFileSync(STATE_FILE, json)
      } catch {}
    }, 120)
    saveTimer.unref?.()
  }

  const set = (phase, patch = {}) => {
    if (st.phase !== phase) st.since = Date.now()
    st.phase = phase
    if (patch.detail !== undefined) st.detail = patch.detail
    if (patch.tool !== undefined) st.tool = patch.tool
    writeState()
  }

  // ---- 事件折叠 --------------------------------------------------------
  // 只认「正在干活」的那个会话：别的会话动一下不该把它带跑
  let activeSession = null

  ctx.on('session/event', (session, event) => {
    const t = event?.type
    const sid = session?.id ?? session?.sessionId ?? null
    if (t === 'turn/start') {
      activeSession = sid
    } else if (activeSession !== null && sid !== null && sid !== activeSession) {
      return
    }
    const d = event?.data ?? {}

    switch (t) {
      case 'turn/start':
        st.turnSince = Date.now()
        set('thought', { detail: '', tool: '' })
        break

      case 'step/start':
        // 新的一步 = 重新开始算，除了「等你批准 / 压缩中」这两种要保留
        if (st.phase !== 'waiting' && st.phase !== 'compact') set('thought', { detail: '', tool: '' })
        break

      case 'assistant/attempt':
        set('thought')
        break

      case 'assistant/message': {
        // 显示最后说出口的那句话的开头，当作「我想到哪了」
        const text = extractText(d)
        // 已经开始出字了 = 在回话（不是思考中）；工具还在跑就别抢它的状态
        if (text && st.phase !== 'tool') set('writing', { detail: text })
        break
      }

      case 'tool/call': {
        const toolName = d.name ?? '工具'
        const brief = briefArgs(d.arguments)
        set('tool', { tool: brief ? `${toolName} · ${brief}` : toolName })
        break
      }

      case 'tool/result': {
        // 工具回来之后回到思考态，等下一次 tool/call 或 turn/end
        set('thought', { tool: '' })
        if (d?.isError || d?.error) set('error', { detail: clamp(String(d?.error ?? '工具返回错误'), 120) })
        break
      }

      case 'approval/asked':
        set('waiting', { detail: '有一件事需要你点一下' })
        break

      case 'approval/decided':
        set('thought')
        break

      case 'compaction/start':
        set('compact')
        break

      case 'compaction/end':
        set('thought')
        break

      case 'llm/retry':
        set('error', { detail: '模型重试中' })
        break

      case 'llm/retry-started':
        set('thought')
        break

      case 'turn/end':
        set('done')
        // 3.5 秒后回空闲，避免一直停在「完成」
        setTimeout(() => {
          if (st.phase === 'done') {
            st.turnSince = 0
            set('idle', { detail: '', tool: '' })
          }
        }, 3500).unref?.()
        break

      default:
        break
    }
  })

  // ---- 拉起小窗 --------------------------------------------------------
  const startUi = () => {
    if (child && !child.killed) return
    if (!existsSync(RUNTIME)) {
      ctx.logger?.warn?.(`dsh-glance: 找不到 ${RUNTIME}，小窗不启动`)
      return
    }
    try {
      mkdirSync(DIR, { recursive: true })
      if (!existsSync(UI_FILE)) {
        writeFileSync(UI_FILE, JSON.stringify({ left: null, top: null, opacity: 0.92, topmost: true }))
      }
    } catch {}

    child = spawn(
      'powershell.exe',
      ['-STA', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', RUNTIME],
      { stdio: 'ignore', windowsHide: true, detached: false },
    )
    child.on('exit', () => { child = undefined })
    child.on('error', (err) => {
      ctx.logger?.warn?.(`dsh-glance: 小窗启动失败 ${err?.message ?? err}`)
      child = undefined
    })
  }

  const stopUi = () => {
    if (!child) return
    try { child.kill() } catch {}
    child = undefined
  }

  writeState(true)
  startUi()

  ctx.on('dispose', () => {
    stopUi()
  })
}

// ---- 小工具 ------------------------------------------------------------

function clamp(s, n) {
  const str = String(s ?? '').replace(/\s+/g, ' ').trim()
  return str.length > n ? `${str.slice(0, n)}…` : str
}

// 从 assistant/message 里尽量捞出一句人话
function extractText(data) {
  const parts = data?.content ?? data?.message?.content
  if (typeof parts === 'string') return clamp(parts, 120)
  if (Array.isArray(parts)) {
    const text = parts
      .filter((p) => p && (p.type === 'text' || typeof p.text === 'string'))
      .map((p) => p.text ?? '')
      .join(' ')
      .trim()
    if (text) return clamp(text, 120)
  }
  if (typeof data?.text === 'string') return clamp(data.text, 120)
  return ''
}

// 把工具参数压成一小截，看得出在干什么就行
function briefArgs(args) {
  if (typeof args !== 'string' || !args) return ''
  try {
    const o = JSON.parse(args)
    for (const key of ['command', 'file_path', 'path', 'url', 'query', 'pattern', 'name']) {
      if (typeof o?.[key] === 'string') return clamp(o[key].split('\n')[0], 60)
    }
    const first = Object.values(o ?? {}).find((v) => typeof v === 'string')
    if (first) return clamp(first.split('\n')[0], 60)
  } catch {
    return clamp(args.split('\n')[0], 60)
  }
  return ''
}

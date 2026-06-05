// Template only. `claude-code-sentinel install-opencode` writes a generated copy
// to ~/.config/opencode/plugins/ with the installed Sentinel binary path.
import { appendFileSync, mkdirSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

const sentinel = "__CLAUDE_CODE_SENTINEL_BINARY__"
const logDir = join(homedir(), "Library", "Logs", "ClaudeCodeSentinel")
const logFile = join(logDir, "opencode-plugin.log")

function log(message, extra) {
  try {
    mkdirSync(logDir, { recursive: true })
    const suffix = extra === undefined ? "" : ` ${JSON.stringify(extra)}`
    appendFileSync(logFile, `[${new Date().toISOString()}] ${message}${suffix}\n`)
  } catch {
    // Never let diagnostic logging break OpenCode.
  }
}

function runSentinel(command, payload) {
  const encoded = Buffer.from(JSON.stringify(payload), "utf8").toString("base64")
  const result = Bun.spawnSync([sentinel, command, "--payload-base64", encoded], {
    stdout: "pipe",
    stderr: "pipe",
  })
  if (result.exitCode !== 0) {
    const stderr = new TextDecoder().decode(result.stderr).trim()
    throw new Error(stderr || `claude-code-sentinel ${command} failed`)
  }
  return new TextDecoder().decode(result.stdout).trim()
}

function questionQuery(directory, worktree) {
  return worktree?.startsWith?.("wrk")
    ? { directory, workspace: worktree }
    : { directory }
}

async function replyQuestion(client, requestID, directory, worktree, answers) {
  if (!client._client?.post) throw new Error("OpenCode raw client is unavailable")
  return await client._client.post({
    url: "/question/{requestID}/reply",
    path: { requestID },
    query: questionQuery(directory, worktree),
    body: { answers },
    headers: { "Content-Type": "application/json" },
  })
}

async function rejectQuestion(client, requestID, directory, worktree) {
  if (!client._client?.post) throw new Error("OpenCode raw client is unavailable")
  return await client._client.post({
    url: "/question/{requestID}/reject",
    path: { requestID },
    query: questionQuery(directory, worktree),
    headers: { "Content-Type": "application/json" },
  })
}

export const ClaudeCodeSentinel = async ({ client, directory, worktree, serverUrl }) => {
  log("plugin.init", { directory, worktree, serverUrl: String(serverUrl), clientKeys: Object.keys(client || {}) })

  return {
    event: async ({ event }) => {
      if (event.type === "permission.updated" || event.type === "permission.asked") {
        const permission = event.properties
        log("permission.asked", { id: permission.id, sessionID: permission.sessionID, type: permission.type, directory })
        const output = runSentinel("opencode-permission", {
          type: event.type,
          directory,
          worktree,
          permission,
        })
        const response = JSON.parse(output).response || "reject"
        log("permission.result", { id: permission.id, sessionID: permission.sessionID, response })
        try {
          const reply = await client.postSessionIdPermissionsPermissionId({
            path: {
              id: permission.sessionID,
              permissionID: permission.id,
            },
            query: { directory },
            body: { response },
          })
          log("permission.reply.ok", { id: permission.id, reply })
          if (reply?.error) throw new Error(JSON.stringify(reply.error))
        } catch (error) {
          log("permission.reply.error", { id: permission.id, error: String(error), stack: error?.stack })
          throw error
        }
        return
      }

      if (event.type === "question.asked") {
        const question = event.properties
        log("question.asked", { id: question.id, directory, worktree, serverUrl: String(serverUrl), questions: question.questions?.length })
        const output = runSentinel("opencode-question", {
          type: event.type,
          directory,
          worktree,
          question,
        })
        const result = JSON.parse(output)
        log("question.result", { id: question.id, result })
        if (result.action === "reply") {
          try {
            const response = await replyQuestion(client, question.id, directory, worktree, result.answers)
            log("question.reply.ok", { id: question.id, response })
            if (response?.error) throw new Error(JSON.stringify(response.error))
          } catch (error) {
            log("question.reply.error", { id: question.id, error: String(error), stack: error?.stack })
            throw error
          }
        } else if (result.action === "reject") {
          try {
            const response = await rejectQuestion(client, question.id, directory, worktree)
            log("question.reject.ok", { id: question.id, response })
            if (response?.error) throw new Error(JSON.stringify(response.error))
          } catch (error) {
            log("question.reject.error", { id: question.id, error: String(error), stack: error?.stack })
            throw error
          }
        } else {
          log("question.noop", { id: question.id, action: result.action })
        }
        return
      }

      if (event.type === "session.idle" || event.type === "session.error") {
        runSentinel("opencode-notification", {
          type: event.type,
          directory,
          worktree,
          properties: event.properties,
        })
        return
      }

      if (event.type === "tool.execute.before" && event.properties?.tool === "question") {
        runSentinel("opencode-notification", {
          type: "tool.question",
          directory,
          worktree,
          properties: event.properties,
        })
      }
    },
  }
}

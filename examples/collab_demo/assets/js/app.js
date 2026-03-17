import { Editor } from "@tiptap/core"
import StarterKit from "@tiptap/starter-kit"
import { collab, sendableSteps, receiveTransaction, getVersion } from "prosemirror-collab"
import { Step } from "prosemirror-transform"
import { Socket } from "phoenix"

function createEditor(elementId, statusId, clientID) {
  const statusEl = document.getElementById(statusId)
  if (!statusEl) return

  const socket = new Socket("/socket", {})
  socket.connect()
  const channel = socket.channel("doc:main", {})

  let editor = null
  let sending = false

  channel.join()
    .receive("ok", (data) => {
      statusEl.textContent = "connected"
      statusEl.style.color = "#22c55e"

      editor = new Editor({
        element: document.getElementById(elementId),
        extensions: [
          StarterKit.configure({ history: false }),
          collab({ version: data.version, clientID }),
        ],
        content: data.doc,
        onTransaction: ({ transaction }) => {
          if (transaction.docChanged) trySend()
        },
      })
    })
    .receive("error", (err) => {
      statusEl.textContent = "error"
      statusEl.style.color = "#ef4444"
      console.error("Join error:", err)
    })

  channel.on("steps", (data) => {
    if (!editor) return
    const currentVersion = getVersion(editor.state)
    if (data.version <= currentVersion) return

    const offset = currentVersion - (data.version - data.steps.length)
    const newSteps = data.steps.slice(offset)
    const newClientIDs = data.clientIDs.slice(offset)
    if (newSteps.length === 0) return

    try {
      const steps = newSteps.map(j => Step.fromJSON(editor.schema, j))
      const tr = receiveTransaction(editor.state, steps, newClientIDs)
      editor.view.dispatch(tr)
    } catch (e) {
      console.warn("Failed to apply remote steps:", e)
    }
  })

  function trySend() {
    if (sending || !editor) return

    let sendable
    try {
      sendable = sendableSteps(editor.state)
    } catch (e) {
      return
    }
    if (!sendable) return

    sending = true
    channel.push("steps", {
      version: sendable.version,
      steps: sendable.steps.map(s => s.toJSON()),
      clientID: clientID,
    })
      .receive("ok", () => {
        sending = false
        setTimeout(trySend, 0)
      })
      .receive("error", (data) => {
        sending = false
        if (data.reason === "version_mismatch" && data.steps) {
          try {
            const steps = data.steps.map(j => Step.fromJSON(editor.schema, j))
            const tr = receiveTransaction(editor.state, steps, data.clientIDs)
            editor.view.dispatch(tr)
            setTimeout(trySend, 100)
          } catch (e) {
            console.warn("Rebase failed:", e)
          }
        }
      })
  }
}

// Initialize both editors when DOM is ready
document.addEventListener("DOMContentLoaded", () => {
  createEditor("editor-a", "status-a", "client-a-" + Math.random().toString(36).slice(2, 8))
  createEditor("editor-b", "status-b", "client-b-" + Math.random().toString(36).slice(2, 8))
})

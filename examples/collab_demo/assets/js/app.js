import { Editor, Extension } from "@tiptap/core"
import StarterKit from "@tiptap/starter-kit"
import { collab, sendableSteps, receiveTransaction, getVersion } from "prosemirror-collab"
import { Step } from "prosemirror-transform"
import { Socket } from "phoenix"

// Wrap prosemirror-collab's raw Plugin as a Tiptap Extension so it
// actually gets registered on the editor state.
const Collaboration = Extension.create({
  name: "collaboration",
  addOptions() {
    return { version: 0, clientID: null }
  },
  addProseMirrorPlugins() {
    return [collab({ version: this.options.version, clientID: this.options.clientID })]
  },
})

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
          Collaboration.configure({ version: data.version, clientID }),
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
      // After confirming/rebasing, send any pending steps
      setTimeout(trySend, 0)
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
      console.error(clientID, "sendableSteps error:", e)
      return
    }
    if (!sendable) {
      console.log(clientID, "nothing sendable, version:", getVersion(editor.state))
      return
    }
    console.log(clientID, "sending", sendable.steps.length, "steps at version", sendable.version)

    sending = true
    const stepsToSend = sendable.steps
    channel.push("steps", {
      version: sendable.version,
      steps: stepsToSend.map(s => s.toJSON()),
      clientID: clientID,
    })
      .receive("ok", () => {
        // The broadcast will confirm our steps via receiveTransaction.
        // Just unlock sending so the next batch can go when ready.
        sending = false
      })
      .receive("error", (data) => {
        sending = false
        if (data.reason === "version_mismatch" && data.steps) {
          try {
            const steps = data.steps.map(j => Step.fromJSON(editor.schema, j))
            const tr = receiveTransaction(editor.state, steps, data.clientIDs)
            editor.view.dispatch(tr)
            // After rebasing, try sending again
            setTimeout(trySend, 50)
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

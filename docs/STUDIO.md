# Desktop app

SpokenFolio is a normal Dock application with one persistent window. Its
sidebar separates Create, Library, Activity, Storyteller, TTS Server,
ReadAloud Tools, and Settings. First launch opens Create; later launches restore
the last section. The window adapts to the current display and remembers its
frame.

Closing the window leaves the embedded gateway and active production child
running. Reopening from the Dock restores the same window. Quitting is
different: SpokenFolio persists queue suspension, interrupts active work as a
resumable pause, waits for the child, releases its locks, and then shuts down
the gateway. Unqueued selections trigger a warning because they are not durable.

Create accepts multi-select and drag-and-drop batches. Activity owns queue
controls and progress; Library owns verified E/A/R products and later
ReadAloud or Storyteller actions. Settings controls the default processed-book
directory and the system Launch at Login item. Launch at Login opens the normal
window; it is not a hidden background mode.

TTS Server shows readiness and the LAN endpoint. Its connection test performs
real Opus and AAC synthesis and decoding; a green health endpoint alone does
not prove Siri access. ReadAloud Tools manages only the pinned stalign binary.
Apple voice assets are always managed by macOS.

The former app identity is migrated transactionally before startup. Owned
application support and window state move immediately; Storyteller credentials
move lazily on first use in the visible app so Keychain authorization can be
shown safely. The old credential is not deleted until the new copy verifies.

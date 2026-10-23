# Embedded socket input

This adapter enables libedit only when the embedding app sets ASHELL_IOS_SOCKET_INPUT=1. Ordinary terminal input retains the existing path. Return is translated to newline in the line editor; child commands retain their raw input stream. Ctrl-D deletes the next character at the prompt, matching the embedding app's pane contract.

Use upstream libedit 20260512-3.1, archive SHA256 432d5e7ea8b0116dd39f2eca7bc11d0eed77faa6b77ea526ace89907c23ea4a0, with libedit-socket.patch applied. The patch keeps NO_TTY ioctl guards while allowing custom-reader editing and caller-owned dimensions. Link the resulting static libedit into each of the six Dash frameworks. Do not silently use the SDK libedit: it lacks this socket behavior.

The existing pipeline/login changes require the caller-owned command-tree API in holzschu/ios_system#181. This socket adapter adds no ios_system API. The application may export `int ashell_pane_wait_editor_input(FILE *input)`; Dash resolves it dynamically. Return 1 for readable input, a value greater than 1 for a resize notification, 0 to use the normal reader, or a negative errno on failure. The callback must operate on this pane's input and must not install process-global signal handlers. The generic a-Shell NativePane implementation supplies this callback and updates COLUMNS and LINES. Without the callback, character input remains available but resize wakeups are not provided.

Socket editors disable libedit's process-global signal ownership. They obtain environment values through the embedding runtime's getenv and initial dimensions from COLUMNS and LINES. No kernel PTY, ioctl or process signal support is emulated. Socket ETX dispatch is a separate change layered on this adapter.

Qualification must enter the actual app command boundary and use SSH. Check Unicode, Return, prompt Ctrl-D, raw child input and terminal resize. Source extraction and compilation alone do not establish interactive behavior or physical-device support.

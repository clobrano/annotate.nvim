# Render with `vhs demo/demo.tape` from the repository root.
# Needs vhs (https://github.com/charmbracelet/vhs), nvim 0.10+ and git.

Output demo/demo.gif

Require nvim
Require git

Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 720
Set Padding 20
Set Theme "Catppuccin Mocha"
Set TypingSpeed 60ms

# Throwaway git project, so the source paths are relative to its root.
Hide
Type `R=$PWD D=$(mktemp -d) && mkdir -p $D/pkg/controller && cp demo/reconcile.go $D/pkg/controller/ && cd $D && git init -q && stty -ixon && clear`
Enter
Type "nvim -u $R/demo/init.lua pkg/controller/reconcile.go"
Enter
Sleep 1.5s
Show

Sleep 1s

# 1. Annotate a character selection.
Type "/r.Client"
Enter
Sleep 500ms
Type "vf)"
Sleep 800ms
Space
Type "aa"
Sleep 600ms
Type "Should be a Patch: Update conflicts with the status writer."
Sleep 500ms
Ctrl+S
Sleep 1.5s

# 2. Annotate a whole line.
Type "/30"
Enter
Sleep 500ms
Type "V"
Sleep 600ms
Space
Type "aa"
Sleep 600ms
Type "Make the requeue interval configurable?"
Sleep 500ms
Ctrl+S
Sleep 1.5s

# 3. Jump between annotations.
Type "[a"
Sleep 1s
Type "]a"
Sleep 1s

# 4. Annotations follow edits: add an import above them.
Type "gg3j"
Sleep 300ms
Type `o"fmt"`
Escape
Sleep 1.5s

# 5. Preview what the agent gets.
Space
Type "ap"
Sleep 4s
Type "q"
Sleep 300ms

# Clean up.
Hide
Type ":qa!"
Enter

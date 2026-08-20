/// Verbose, Claude-Code-style tool descriptions. Each constant is the
/// `description` field that the model sees in the tool registry --
/// matching what Claude Code's reference implementation ships, so the
/// model gets the same per-tool guidance regardless of whether it
/// addresses the snake_case primary (`shell`, `file_read`, `file_edit`,
/// ...) or the PascalCase alias (`Bash`, `Read`, `Edit`, ...).
///
/// Keep this file the single source of truth: tool_schemas.zig now
/// references these constants from both the primary and the alias
/// entries so the two descriptions can't drift.
pub const SHELL =
    "Executes a given bash command and returns its output.\n" ++
    "\n" ++
    "The working directory persists between commands within the project, but shell state does not. A `cd` outside the project's working directories is reset back to the project root after the command runs. The shell environment is initialized from the user's profile (bash or zsh).\n" ++
    "\n" ++
    "IMPORTANT: Avoid using this tool to run `find`, `grep`, `cat`, `head`, `tail`, `sed`, `awk`, or `echo` commands, unless explicitly instructed or after you have verified that a dedicated tool cannot accomplish your task. Instead, use the appropriate dedicated tool as this will provide a much better experience for the user:\n" ++
    "\n" ++
    " - File search: Use Glob (NOT find or ls)\n" ++
    " - Content search: Use Grep (NOT grep or rg)\n" ++
    " - Read files: Use Read (NOT cat/head/tail)\n" ++
    " - Edit files: Use Edit (NOT sed/awk)\n" ++
    " - Write files: Use Write (NOT echo >/cat <<EOF)\n" ++
    " - Communication: Output text directly (NOT echo/printf)\n" ++
    "\n" ++
    "# Instructions\n" ++
    " - If your command will create new directories or files, first run `ls` to verify the parent directory exists.\n" ++
    " - Always quote file paths that contain spaces (e.g., cd \"path with spaces/file.txt\").\n" ++
    " - Prefer absolute paths over `cd`; the working directory persists but `cd` makes session state harder to reason about.\n" ++
    " - You may specify an optional timeout in seconds (up to 600). Default is 120.\n" ++
    " - Use `run_in_background` for long-running commands you do not need to block on. Poll with TaskPoll/TaskOutput afterwards.\n" ++
    " - When issuing multiple independent commands, prefer multiple parallel tool calls in a single response over `&&` chaining.\n" ++
    " - For git commands: prefer a fresh commit over amending; never skip hooks (--no-verify) unless the user explicitly asked; pause and ask before destructive operations (push --force, reset --hard, checkout --, clean -f).\n" ++
    " - Do not sleep-loop for status; use `run_in_background` and let the harness notify you on completion.";

pub const SHELL_USAGE =
    "Use for non-interactive shell commands not covered by a dedicated tool. Interactive terminals (vim, less, top, ssh, REPLs) belong in `/!`, not Bash. Always quote paths with spaces. Prefer Grep/Glob/Read for file discovery and content search.";

pub const FILE_READ =
    "Reads a file from the local filesystem. Assume this tool can read any file on the machine; if the user provides a path, trust it.\n" ++
    "\n" ++
    "Usage:\n" ++
    " - `path` must be an absolute path.\n" ++
    " - By default, reads up to ~2000 lines from the beginning. Use `offset` (1-indexed line number) + `limit` (max lines) to page through large files instead of bumping max_bytes.\n" ++
    " - Output uses cat -n format with line numbers starting at 1.\n" ++
    " - Reads PDFs (.pdf) and Jupyter notebooks (.ipynb) when supported; large PDFs require an explicit page range.\n" ++
    " - Use Read for files; use an `ls` Bash command for directories.\n" ++
    " - Do NOT re-read a file you just edited to verify -- Edit/Write would have errored if the change failed, and the harness tracks file state for you.\n" ++
    " - Empty files return a system-reminder warning rather than an error.";

pub const FILE_READ_USAGE =
    "Use to read file contents by absolute path. Do NOT use to search for files (use Glob). Do NOT use to search file contents (use Grep). Page large files with offset/limit (e.g. offset=200, limit=100 reads lines 200-299). Only read files within the workspace; do NOT read other tools' config (e.g. ~/.claude/, ~/.config/).";

pub const FILE_WRITE =
    "Writes a file to the local filesystem.\n" ++
    "\n" ++
    "Usage:\n" ++
    " - Overwrites the existing file if one exists at the path. If the file exists, you MUST Read it first in the same conversation; the write will be rejected otherwise.\n" ++
    " - Prefer Edit/MultiEdit for modifying existing files -- it sends only the diff. Use Write only for new files or true full rewrites.\n" ++
    " - NEVER create documentation files (*.md, README*) unless the user explicitly asks.\n" ++
    " - Only use emojis if the user explicitly requests them.";

pub const FILE_WRITE_USAGE =
    "Use to create new files or for complete rewrites. Do NOT use for targeted edits (use Edit -- it sends only the diff). Verify the parent directory exists; if not, create it with Bash `mkdir -p` first.";

pub const FILE_EDIT =
    "Performs exact string replacements in a file.\n" ++
    "\n" ++
    "Usage:\n" ++
    " - You MUST have Read the file at least once in this conversation before editing; the edit is rejected otherwise.\n" ++
    " - When editing text from Read output, preserve the exact indentation that follows the line-number prefix (line number + tab). Never include any part of that prefix in `find`/`replace`.\n" ++
    " - The edit fails if `find` is not unique. Either expand `find` with surrounding context until it appears once, or pass `all=true` (replace_all) to change every occurrence.\n" ++
    " - Prefer editing existing files over creating new ones.\n" ++
    " - Only use emojis if the user explicitly requests them.";

pub const FILE_EDIT_USAGE =
    "Use for targeted find/replace in existing files. If `find` is not unique, the edit fails -- expand with surrounding context until unique, or set `all=true`. Always Read the file first so `find` matches exactly (whitespace and indentation included).";

pub const GREP =
    "A powerful search tool built on ripgrep.\n" ++
    "\n" ++
    "Usage:\n" ++
    " - ALWAYS use Grep for content search. Never invoke `grep` or `rg` via Bash -- this tool has the right permissions and output shape.\n" ++
    " - Supports full regex (e.g. \"log.*Error\", \"function\\\\s+\\\\w+\").\n" ++
    " - Filter files with `glob` (e.g. \"*.zig\", \"**/*.tsx\") or `type` (e.g. \"zig\", \"py\", \"rust\"). `type` is faster than `glob` for standard languages.\n" ++
    " - Output modes: `content` shows matching lines (default for line-level work); `files_with_matches` returns only file paths and is 20-100x smaller for repo-wide \"where is X?\" questions; `count` returns per-file match counts.\n" ++
    " - Multiline patterns (e.g. `struct \\\\{[\\\\s\\\\S]*?field`) require `multiline: true`.\n" ++
    " - GOTCHA: ripgrep treats `{` `}` as quantifier delimiters, so `interface{}` in Go must be written as `interface\\\\{\\\\}`. If you see zero hits on a pattern you expect to match, check brace escaping.";

pub const GREP_USAGE =
    "Use to search file contents by regex. Use BEFORE Read to find relevant files. Do NOT use to find files by name (use Glob). Set output_mode=files_with_matches for repo-wide \"where is X defined?\" to save context.";

pub const GLOB =
    "Fast file pattern matching that works at any codebase size.\n" ++
    "\n" ++
    "Usage:\n" ++
    " - Supports glob patterns like `**/*.js`, `src/**/*.ts`, `*.zig`.\n" ++
    " - Returns matching file paths sorted by modification time (newest first), so the first result is usually the one most recently edited.\n" ++
    " - Use Glob when you need to find files by name pattern. Use Grep to search contents.";

pub const GLOB_USAGE =
    "Use BEFORE Read when you do not know the exact path. Do NOT use to search file contents (use Grep). Supports `**`, `*`, `?` syntax. Results sort by mtime, so the first hit is usually the recently-edited candidate -- a good starting point.";

pub const GIT_STATUS =
    "Show the git status summary for the current working tree: branch, ahead/behind, staged and unstaged file lists, plus untracked files. Read-only; safe to call any time to verify state before or after a change.";

pub const GIT_STATUS_USAGE =
    "Use to check the working tree state before commits or to verify changes were applied. Read-only.";

pub const GIT_APPLY =
    "Apply a unified-diff patch to the working tree.\n" ++
    "\n" ++
    "Usage:\n" ++
    " - Prefer Edit/MultiEdit for single-file changes -- the diff format adds overhead.\n" ++
    " - Use git_apply when you have a multi-file patch (e.g. from a code review tool, a previous run, or generated by another agent) and want to apply it atomically.\n" ++
    " - The patch must be in unified-diff format with the correct file paths relative to the workspace root.";

pub const GIT_APPLY_USAGE =
    "Use to apply multi-file unified diffs. Prefer Edit/MultiEdit for single-file changes. The patch must include correct workspace-relative paths.";

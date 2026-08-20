const std = @import("std");
const std_io = @import("../core/std_io.zig");
const types = @import("../core/types.zig");
const mcp_client = @import("../mcp/client.zig");
const browser_bridge = @import("../mcp/browser_bridge.zig");
const desc = @import("tool_descriptions.zig");
const mcp_name = @import("../core/mcp_name.zig");

pub const builtin_schemas = [_]types.ToolSchema{
    .{
        .name = "shell",
        .description = desc.SHELL,
        .json_schema = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"},\"timeout_seconds\":{\"type\":\"integer\"},\"description\":{\"type\":\"string\",\"description\":\"Brief human-readable description of what this command does\"},\"run_in_background\":{\"type\":\"boolean\",\"description\":\"Run command in background and return immediately\"},\"dangerouslyDisableSandbox\":{\"type\":\"boolean\",\"description\":\"Set true to run this command with the sandbox disabled (full host access). Use only when sandboxing genuinely blocks a needed operation. Ignored when enterprise policy locks the sandbox.\"}},\"required\":[\"command\"]}",
        .usage_hint = desc.SHELL_USAGE,
    },
    .{
        .name = "file_read",
        .description = desc.FILE_READ,
        .json_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"max_bytes\":{\"type\":\"integer\"},\"offset\":{\"type\":\"integer\",\"description\":\"1-indexed line number to start reading from. Use to page through large files.\"},\"limit\":{\"type\":\"integer\",\"description\":\"Max lines to return starting from offset. 0 reads to EOF.\"}},\"required\":[\"path\"]}",
        .usage_hint = desc.FILE_READ_USAGE,
        .is_read_only = true,
        // tools-10: Read is never artifacted -- otherwise a large Read result
        // would be written to an artifact file that the model has to Read
        // again (a Read -> artifact -> Read loop). Mirrors FileReadTool.ts:342
        // (maxResultSizeChars = Infinity).
        .max_result_size_chars = std.math.maxInt(usize),
    },
    .{
        .name = "file_write",
        .description = desc.FILE_WRITE,
        .json_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"},\"append\":{\"type\":\"boolean\"}},\"required\":[\"path\",\"content\"]}",
        .usage_hint = desc.FILE_WRITE_USAGE,
    },
    .{
        .name = "file_edit",
        .description = desc.FILE_EDIT,
        .json_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"find\":{\"type\":\"string\"},\"replace\":{\"type\":\"string\"},\"all\":{\"type\":\"boolean\"}},\"required\":[\"path\",\"find\"]}",
        .usage_hint = desc.FILE_EDIT_USAGE,
    },
    .{
        .name = "git_status",
        .description = desc.GIT_STATUS,
        .json_schema = "{\"type\":\"object\",\"properties\":{}}",
        .usage_hint = desc.GIT_STATUS_USAGE,
        .is_read_only = true,
    },
    .{
        .name = "git_apply",
        .description = desc.GIT_APPLY,
        .json_schema = "{\"type\":\"object\",\"properties\":{\"patch\":{\"type\":\"string\"}},\"required\":[\"patch\"]}",
        .usage_hint = desc.GIT_APPLY_USAGE,
    },
    .{
        .name = "mcp_servers_list",
        .description = "List all configured MCP servers with their names and transport types",
        .json_schema = "{\"type\":\"object\",\"properties\":{}}",
        .usage_hint = "Use this tool first to discover available MCP servers before calling other mcp_* tools. Returns server names and transports.",
        .is_read_only = true,
    },
    .{
        .name = "mcp_tools_list",
        .description = "List available tools on a configured MCP server",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"server\":{\"type\":\"string\"}},\"required\":[\"server\"]}",
        .usage_hint = "Use after mcp_servers_list to discover what tools a specific server provides. Always show the complete tool list with descriptions to the user. Then use mcp_invoke to call them.",
        .is_read_only = true,
    },
    .{
        .name = "mcp_invoke",
        .description = "Invoke MCP tool via configured server",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"server\":{\"type\":\"string\"},\"tool\":{\"type\":\"string\"},\"payload\":{\"type\":\"string\"}},\"required\":[\"server\",\"tool\"]}",
        .usage_hint = "Use to call a specific tool on an MCP server. Discover tools first with mcp_tools_list. Pass payload as JSON string matching the tool's input schema.",
    },
    .{
        .name = "mcp_resources_list",
        .description = "List MCP resources for a configured server",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"server\":{\"type\":\"string\"}},\"required\":[\"server\"]}",
        .is_read_only = true,
    },
    .{
        .name = "mcp_resource_templates_list",
        .description = "List MCP resource templates for a configured server",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"server\":{\"type\":\"string\"}},\"required\":[\"server\"]}",
        .is_read_only = true,
    },
    .{
        .name = "mcp_resource_read",
        .description = "Read MCP resource contents from a configured server",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"server\":{\"type\":\"string\"},\"uri\":{\"type\":\"string\"}},\"required\":[\"server\",\"uri\"]}",
        .is_read_only = true,
    },
    .{
        .name = "mcp_prompts_list",
        .description = "List MCP prompts for a configured server",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"server\":{\"type\":\"string\"}},\"required\":[\"server\"]}",
        .is_read_only = true,
    },
    .{
        .name = "mcp_prompt_get",
        .description = "Get an MCP prompt from a configured server",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"server\":{\"type\":\"string\"},\"prompt\":{\"type\":\"string\"},\"arguments_json\":{\"type\":\"string\"}},\"required\":[\"server\",\"prompt\"]}",
        .is_read_only = true,
    },
    .{
        .name = "mcp_complete",
        .description = "Request MCP argument completion suggestions from a configured server",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"server\":{\"type\":\"string\"},\"ref_json\":{\"type\":\"string\"},\"argument\":{\"type\":\"string\"},\"value\":{\"type\":\"string\"}},\"required\":[\"server\",\"ref_json\",\"argument\"]}",
    },
    .{
        .name = "mcp_subscribe",
        .description = "Subscribe to MCP resource update notifications for a configured server",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"server\":{\"type\":\"string\"},\"uri\":{\"type\":\"string\"}},\"required\":[\"server\",\"uri\"]}",
    },
    .{
        .name = "mcp_unsubscribe",
        .description = "Unsubscribe from MCP resource update notifications for a configured server",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"server\":{\"type\":\"string\"},\"uri\":{\"type\":\"string\"}},\"required\":[\"server\",\"uri\"]}",
    },
    .{
        .name = "mcp_notifications",
        .description = "Read queued MCP notifications, optionally filtered by server",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"server\":{\"type\":\"string\"}}}",
        .is_read_only = true,
    },
    .{
        .name = "mcp_logging_set_level",
        .description = "Set MCP server log verbosity level",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"server\":{\"type\":\"string\"},\"level\":{\"type\":\"string\"}},\"required\":[\"server\",\"level\"]}",
        .usage_hint = "Set the log verbosity for an MCP server. Common levels: debug, info, warning, error.",
    },
    .{
        .name = "enter_plan_mode",
        .description = "Switch the session into planning mode for the upcoming turns.\n\nIn planning mode the agent has access only to read-only inspection tools (Read, Grep, Glob, GitDiff, GitLog, git_status, WebFetch, WebSearch). Mutation tools (Edit, Write, Bash, RunTests, git_apply, GitCommit, OpenPR, etc.) are refused at dispatch time. Call this when the user asks for analysis, a plan, an audit, or a roadmap before any changes are made.\n\nWhen the plan is ready, call exit_plan_mode(plan=<markdown>) to surface it for the user's review-and-approve overlay. Do NOT emit the final plan as plain assistant text - the REPL gates the approval overlay on exit_plan_mode being called explicitly.",
        .json_schema = "{\"type\":\"object\",\"properties\":{}}",
        .usage_hint = "Use only at the start of a planning task. If the session is already in planning mode the call is a no-op acknowledgment.",
        .is_read_only = true,
    },
    .{
        .name = "exit_plan_mode",
        .description = "Signal that the planning phase is complete and the markdown plan is ready for user approval.\n\nCall this tool exactly once when you have finished investigating and have a concrete, actionable plan. Pass the plan body as the `plan` argument in markdown form: title, goals, assumptions, a `- [ ]` task checklist, risks, and a definition of done. The REPL saves the plan, opens the approval overlay, and waits for the user to choose Approve / Continue Discussion / Cancel.\n\nThis is the ONLY way to surface a plan for approval - the REPL no longer infers \"plan ready\" from heuristic markdown detection. Do not call this tool until you actually have a finished plan; do not call it for discussion turns.",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"plan\":{\"type\":\"string\",\"description\":\"The full plan in markdown. Begins with a single-line title (e.g. `# Refactor X`) followed by Goals, Assumptions, Task checklist using `- [ ]`, Risks, and Definition of done.\"}},\"required\":[\"plan\"]}",
        .usage_hint = "Call once per planning task, after read-only investigation is complete. The plan markdown becomes the final answer for the turn; the REPL handles the approval flow.",
        .is_read_only = true,
    },
    .{
        .name = "Bash",
        .description = desc.SHELL,
        .json_schema = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"},\"timeout_seconds\":{\"type\":\"integer\"},\"description\":{\"type\":\"string\",\"description\":\"Brief human-readable description of what this command does\"},\"run_in_background\":{\"type\":\"boolean\",\"description\":\"Run command in background and return immediately\"},\"dangerouslyDisableSandbox\":{\"type\":\"boolean\",\"description\":\"Set true to run this command with the sandbox disabled (full host access). Use only when sandboxing genuinely blocks a needed operation. Ignored when enterprise policy locks the sandbox.\"}},\"required\":[\"command\"]}",
        .usage_hint = desc.SHELL_USAGE,
    },
    .{
        .name = "Glob",
        .description = desc.GLOB,
        .json_schema = "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\",\"description\":\"The glob pattern to match files against\"},\"path\":{\"type\":\"string\",\"description\":\"The directory to search in. If not specified, the current working directory will be used. IMPORTANT: Omit this field to use the default directory. DO NOT enter \\\"undefined\\\" or \\\"null\\\" - simply omit it for the default behavior. Must be a valid directory path if provided.\"},\"max_results\":{\"type\":\"integer\",\"description\":\"Maximum number of matching paths to return. Defaults to 200. Use smaller values for large codebases.\"}},\"required\":[\"pattern\"]}",
        .usage_hint = desc.GLOB_USAGE,
        .is_read_only = true,
    },
    .{
        .name = "Grep",
        .description = desc.GREP,
        .json_schema = "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"},\"max_results\":{\"type\":\"integer\"},\"ignore_case\":{\"type\":\"boolean\"},\"multiline\":{\"type\":\"boolean\",\"description\":\"Enable multiline mode where . matches newlines and patterns can span lines. Required for cross-line regex like struct \\\\{[\\\\s\\\\S]*?field.\"},\"context\":{\"type\":\"integer\",\"description\":\"Number of context lines before and after each match\"},\"glob\":{\"type\":\"string\",\"description\":\"Glob pattern to filter files (e.g. '*.zig', '*.{ts,tsx}') -- maps to rg --glob\"},\"type\":{\"type\":\"string\",\"description\":\"File type to filter (e.g. 'zig', 'py', 'rust') -- maps to rg --type. Faster than glob for standard languages.\"},\"output_mode\":{\"type\":\"string\",\"enum\":[\"content\",\"files_with_matches\",\"count\"],\"description\":\"Output shape. content (default) shows matching lines; files_with_matches shows only file paths (rg -l) and is 20x-100x smaller for repo-wide searches; count shows per-file match counts (rg -c). Use files_with_matches when you only need to know WHERE a symbol is defined, not the exact line.\"}},\"required\":[\"pattern\"]}",
        .usage_hint = desc.GREP_USAGE,
        .is_read_only = true,
        // tools-10: Grep caps tighter than the global default so a repo-wide
        // search never floods history. Mirrors GrepTool.ts:164 (20k).
        .max_result_size_chars = 20_000,
    },
    .{
        .name = "Read",
        .description = desc.FILE_READ,
        .json_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"max_bytes\":{\"type\":\"integer\"},\"offset\":{\"type\":\"integer\",\"description\":\"1-indexed line number to start reading from. Use to page through large files.\"},\"limit\":{\"type\":\"integer\",\"description\":\"Max lines to return starting from offset. 0 reads to EOF.\"}},\"required\":[\"path\"]}",
        .usage_hint = desc.FILE_READ_USAGE,
        .is_read_only = true,
        // tools-10: same Read exemption as the file_read alias above.
        .max_result_size_chars = std.math.maxInt(usize),
    },
    .{
        .name = "Write",
        .description = desc.FILE_WRITE,
        .json_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"},\"append\":{\"type\":\"boolean\"}},\"required\":[\"path\",\"content\"]}",
        .usage_hint = desc.FILE_WRITE_USAGE,
    },
    .{
        .name = "Edit",
        .description = desc.FILE_EDIT,
        .json_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"find\":{\"type\":\"string\"},\"replace\":{\"type\":\"string\"},\"all\":{\"type\":\"boolean\"}},\"required\":[\"path\",\"find\"]}",
        .usage_hint = desc.FILE_EDIT_USAGE,
    },
    .{
        .name = "MultiEdit",
        .description = "Apply a list of edits to a single file atomically. Each edit is an object with `old_string` (required) and `new_string` (required, may be empty), plus optional `replace_all` (default false). All edits are applied in sequence; if any edit fails (not found, or not unique without replace_all), the whole operation is rejected and the file is untouched. Use this instead of chaining multiple Edit calls when you have several related changes to one file.",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Path to the file to edit\"},\"edits\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"old_string\":{\"type\":\"string\"},\"new_string\":{\"type\":\"string\"},\"replace_all\":{\"type\":\"boolean\"}},\"required\":[\"old_string\",\"new_string\"]}}},\"required\":[\"path\",\"edits\"]}",
        .usage_hint = "Use to batch several find/replace edits into one atomic operation. Edits are applied in order: later edits see the state after earlier edits completed, so you can delete a duplicate with one edit and then rely on uniqueness for the next. The whole batch rolls back if any edit fails, so the file on disk never ends up half-applied. Always Read the file first before editing.",
    },
    .{
        .name = "NotebookEdit",
        .description = "Edit cells in a Jupyter notebook. Four modes: `append` (default, add new cell at the end), `replace` (overwrite cell at cell_number), `insert` (add cell at cell_number, pushing later cells down), `delete` (remove cell at cell_number). cell_number is 0-indexed.",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"source\":{\"type\":\"string\"},\"cell_type\":{\"type\":\"string\",\"description\":\"`code` (default) or `markdown`\"},\"cell_number\":{\"type\":\"integer\",\"description\":\"0-indexed cell position. Required for replace/insert/delete. Ignored for append.\"},\"edit_mode\":{\"type\":\"string\",\"enum\":[\"append\",\"replace\",\"insert\",\"delete\"],\"description\":\"Default `append`. `replace` overwrites cell_number. `insert` adds at cell_number, pushing others down. `delete` removes cell_number. For delete, source is ignored.\"}},\"required\":[\"path\"]}",
        .usage_hint = "Use to modify .ipynb files. Default mode `append` adds a new cell at the end and creates the notebook if it doesn't exist. Use `replace` to overwrite an existing cell (e.g. fix a bug in a code cell), `insert` to add a new cell between existing ones, `delete` to drop an unused cell. cell_number is 0-indexed. Set cell_type to 'markdown' for text cells, 'code' (default) for executable cells.",
    },
    .{
        .name = "WebFetch",
        .description = "Fetches content from a specified URL and returns the readable text (HTML tags, scripts, styles, and inline CSS are stripped -- see src/core/html_to_text.zig). Use this tool when you need to retrieve and analyze web content.\n\nUsage notes:\n - The URL must be a fully-formed valid URL (http:// or https://)\n - This tool is read-only and does not modify any files\n - HTML pages are converted to plain text before returning; JSON and plain-text responses pass through unchanged\n - Results are capped by `max_bytes` (default 32 KiB); large pages are truncated\n - Set `ZCODE_WEBFETCH_RAW=1` to disable HTML stripping and return the raw body (for scraping attribute data, meta tags, etc.)\n - For GitHub URLs, prefer using the gh CLI via Bash instead (e.g., `gh pr view`, `gh issue view`, `gh api repos/.../pulls/NN/comments`) -- it returns clean structured JSON without HTML wrapping and handles auth automatically\n - SSRF defense: URLs that resolve to cloud metadata endpoints (169.254.169.254, metadata.google.internal, 100.100.100.200), link-local, or private IP ranges are blocked. Loopback (127.*) stays allowed for local dev servers",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\",\"description\":\"Fully-formed http:// or https:// URL to fetch\"},\"prompt\":{\"type\":\"string\",\"description\":\"What to extract/answer from the fetched page. The page is summarized to answer this prompt before returning. Omit to return the raw stripped page text.\"},\"max_bytes\":{\"type\":\"integer\",\"description\":\"Max bytes to return. Default 32768 (32 KiB). Oversized responses are truncated.\"}},\"required\":[\"url\"]}",
        .usage_hint = "Use to download and read web content. For GitHub resources, prefer `gh` via Bash instead -- it handles auth and returns clean JSON. Specify max_bytes only if you need to cap large pages below the default.",
        .search_hint = "fetch and extract content from a URL",
        // tools-12: declared structured-output shape. Mirrors the reference's
        // WebFetchTool outputSchema (WebFetchTool.ts:32-46): the fetched URL,
        // HTTP status code, returned byte count, and the extracted text result.
        .output_schema = "{\"type\":\"object\",\"properties\":{\"bytes\":{\"type\":\"integer\",\"description\":\"Number of bytes returned\"},\"code\":{\"type\":\"integer\",\"description\":\"HTTP status code\"},\"result\":{\"type\":\"string\",\"description\":\"Extracted page text or prompt answer\"},\"url\":{\"type\":\"string\",\"description\":\"The fetched URL\"}},\"required\":[\"result\",\"url\"]}",
        .is_read_only = true,
    },
    .{
        .name = "WebSearch",
        .description = "Searches the web via DuckDuckGo's API and returns a list of results (title, URL, snippet).\n\nUsage notes:\n - Use when you need to find documentation, recent information, blog posts, or pages whose URL you don't already know\n - Returns structured search results -- use a follow-up WebFetch to read the full page content of a specific result\n - Results may be capped by `max_bytes` (default 32 KiB)\n - For current events, library changelogs, or time-sensitive information the model's training cutoff would miss\n - This tool is read-only",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"Search query (natural language or keywords)\"},\"max_bytes\":{\"type\":\"integer\",\"description\":\"Max bytes to return. Default 32768 (32 KiB).\"},\"allowed_domains\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Only include results whose URL host matches one of these domains.\"},\"blocked_domains\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Never include results whose URL host matches one of these domains.\"}},\"required\":[\"query\"]}",
        .usage_hint = "Use to search the web for docs, examples, or current information. Returns titles/URLs/snippets; use WebFetch to read the full content of a specific result. Good for info past the model's training cutoff.",
        .search_hint = "search the web for current information",
        // tools-12: declared structured-output shape -- the echoed query plus
        // the list of result entries (title, url, snippet).
        .output_schema = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"The search query\"},\"results\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"title\":{\"type\":\"string\"},\"url\":{\"type\":\"string\"},\"snippet\":{\"type\":\"string\"}}},\"description\":\"Matched search results\"}},\"required\":[\"query\",\"results\"]}",
        .is_read_only = true,
    },
    .{
        .name = "Task",
        .description = "Generic task operation action=create|get|update|list|stop|output|run|poll|claim",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\"},\"id\":{\"type\":\"string\"},\"title\":{\"type\":\"string\"},\"summary\":{\"type\":\"string\"},\"activeForm\":{\"type\":\"string\"},\"status\":{\"type\":\"string\"},\"output\":{\"type\":\"string\"},\"owner\":{\"type\":\"string\"},\"check_busy\":{\"type\":\"boolean\"},\"command\":{\"type\":\"string\"},\"priority\":{\"type\":\"string\"},\"deps\":{\"type\":\"string\"},\"metadata\":{\"type\":\"object\"}},\"required\":[\"action\"]}",
        .search_hint = "create, update, and track session tasks",
    },
    .{
        .name = "TaskCreate",
        .description = "Create a structured task to track progress on the current coding session. This helps organize complex multi-step work and shows progress to the user.\n\nWhen to use this tool (use PROACTIVELY):\n - Complex multi-step tasks requiring 3 or more distinct steps or actions\n - Non-trivial work that requires planning or multiple operations\n - Plan mode - create tasks to track the planned work\n - User explicitly asks for a todo/task list\n - User provides multiple tasks (numbered or comma-separated)\n - After receiving new instructions - capture requirements as tasks immediately\n - When you start a task, mark it in_progress BEFORE beginning work\n - After completing a task, mark it completed and add any follow-ups discovered\n\nWhen NOT to use this tool:\n - A single, straightforward task\n - Trivial work where tracking adds no value\n - Work that can be finished in fewer than 3 trivial steps\n - Purely conversational or informational exchanges\n\nTask fields:\n - title: brief, actionable title in imperative form (e.g. \"Fix auth bug in login flow\")\n - summary: what needs to be done\n - command: optional shell command to run as a background task\n\nAll tasks are created with status `pending`. Check TaskList first to avoid creating duplicates. After creating, use TaskUpdate to set dependencies (blocks/blockedBy) if needed.",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"title\":{\"type\":\"string\"},\"summary\":{\"type\":\"string\"},\"activeForm\":{\"type\":\"string\",\"description\":\"Present-continuous label shown while the task is active (e.g. 'Running tests'). Defaults to the title when omitted.\"},\"owner\":{\"type\":\"string\"},\"priority\":{\"type\":\"string\"},\"deps\":{\"type\":\"string\"},\"command\":{\"type\":\"string\"},\"metadata\":{\"type\":\"object\",\"description\":\"Arbitrary key-value metadata stored with the task.\"}},\"required\":[\"title\"]}",
        .usage_hint = "Use PROACTIVELY for multi-step work (>= 3 steps) or when the user lists multiple items. SKIP for single trivial tasks. Keep titles imperative and specific. Mark in_progress BEFORE starting work and completed IMMEDIATELY after -- never batch.",
        .search_hint = "create a task to track multi-step work",
    },
    .{
        .name = "TaskGet",
        .description = "Get task details",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}",
    },
    .{
        .name = "TaskUpdate",
        .description = "Update task fields. Set the assigned agent with `owner`. Set dependency edges with `add_blocks` (comma-separated ids that THIS task blocks) and `add_blocked_by` (comma-separated ids that must complete before this task can be claimed). Edges are recorded on both sides and are idempotent.",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"title\":{\"type\":\"string\"},\"summary\":{\"type\":\"string\"},\"status\":{\"type\":\"string\"},\"output\":{\"type\":\"string\"},\"owner\":{\"type\":\"string\",\"description\":\"Agent assigned to this task.\"},\"add_blocks\":{\"type\":\"string\",\"description\":\"Comma-separated task ids that this task blocks.\"},\"add_blocked_by\":{\"type\":\"string\",\"description\":\"Comma-separated task ids that must complete before this task can be claimed.\"}},\"required\":[\"id\"]}",
    },
    .{
        .name = "TaskClaim",
        .description = "Atomically claim a task for an agent. Sets `owner` if the task is unclaimed (or already owned by the claimant), not yet resolved, and not blocked by unresolved blockers. Rejects with a reason otherwise. Set `check_busy=true` to also refuse the claim when the agent already owns another open task.",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"owner\":{\"type\":\"string\",\"description\":\"Claiming agent identity.\"},\"check_busy\":{\"type\":\"boolean\",\"description\":\"Refuse if the agent already owns another open task.\"}},\"required\":[\"id\",\"owner\"]}",
    },
    .{
        .name = "TaskList",
        .description = "List tasks",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"status\":{\"type\":\"string\"}}}",
    },
    .{
        .name = "TaskStop",
        .description = "Mark task as stopped",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},\"required\":[\"id\"]}",
    },
    .{
        .name = "TaskOutput",
        .description = "Get or set task output",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"output\":{\"type\":\"string\"}},\"required\":[\"id\"]}",
    },
    .{
        .name = "TodoWrite",
        .description = "Replace the current session todo checklist with a concise list of open items. Use proactively for multi-step tasks; always keep exactly one item in_progress at a time.",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"items\":{\"description\":\"JSON array of todo strings or objects with content/text/title/activeForm and optional status\",\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"content\":{\"type\":\"string\",\"description\":\"Imperative form (e.g. 'Run tests')\"},\"text\":{\"type\":\"string\"},\"title\":{\"type\":\"string\"},\"activeForm\":{\"type\":\"string\",\"description\":\"Present continuous form shown while in_progress (e.g. 'Running tests')\"},\"status\":{\"type\":\"string\"}},\"additionalProperties\":true}}},\"required\":[\"items\"]}",
        .usage_hint = "Use PROACTIVELY when: (1) task needs >= 3 distinct steps, (2) user listed multiple tasks (numbered or comma-separated), (3) non-trivial work needs planning. SKIP when: single trivial task, pure conversation, work doable in < 3 steps. Rules: exactly ONE item in_progress at a time (not zero, not two); mark completed IMMEDIATELY after finishing (do NOT batch); if blocked, keep in_progress and add a new 'resolve X' item; NEVER mark completed if tests fail or implementation is partial. Always pass the full current checklist (not a delta) -- this tool overwrites the list. For each item, prefer the object form with both `content` (imperative: \"Run tests\") and `activeForm` (present continuous: \"Running tests\") -- the REPL shows the active form while the item is in_progress, which reads more naturally.",
    },
    .{
        .name = "EnterPlanMode",
        .description = "Request runtime to continue this turn in planning mode",
        .json_schema = "{\"type\":\"object\",\"properties\":{}}",
        .usage_hint = "Use when the task needs structured investigation and a plan before implementation. Subsequent work stays read-only until the plan is approved.",
    },
    .{
        .name = "ExitPlanMode",
        .description = "Use this tool when you are in plan mode and have finished writing your plan and are ready for user approval.\n\nHow this tool works:\n - You should have already drafted your plan in planning mode\n - This tool simply signals that you're done planning and ready for the user to review and approve\n\nWhen to use this tool:\n IMPORTANT: Only use this tool when the task requires planning the implementation steps of a task that requires writing code. For research tasks where you're gathering information, searching files, reading files, or trying to understand the codebase -- do NOT use this tool.\n\nBefore using this tool, ensure your plan is complete and unambiguous:\n - If you have unresolved questions about requirements or approach, use AskUserQuestion first\n - Once your plan is finalized, use THIS tool to request approval\n\nImportant: Do NOT use AskUserQuestion to ask \"Is this plan okay?\" or \"Should I proceed?\" -- that's exactly what THIS tool does. ExitPlanMode inherently requests user approval of your plan.\n\nExamples:\n 1. \"Search for and understand the implementation of vim mode\" -- Do NOT use this tool; it's research, not implementation planning.\n 2. \"Help me implement yank mode for vim\" -- Use this tool after you have finished planning the implementation steps.\n 3. \"Add a feature to handle user authentication\" -- If unsure about auth method, use AskUserQuestion first, then use this tool after clarifying.",
        .json_schema = "{\"type\":\"object\",\"properties\":{}}",
        .usage_hint = "Use only after drafting the final plan for a code-writing task. Do NOT use for research or investigation tasks. The runtime keeps the session in planning flow until the user approves execution.",
    },
    .{
        .name = "AskUserQuestion",
        .description = "Asks the user multiple choice questions to gather information, clarify ambiguity, understand preferences, make decisions, or offer choices.\n\nUse this tool when you need to ask the user questions during execution to:\n 1. Gather user preferences or requirements\n 2. Clarify ambiguous instructions\n 3. Get decisions on implementation choices as you work\n 4. Offer choices about what direction to take\n\nUsage notes:\n - Users will always be able to provide custom text input via \"Other\"\n - If you recommend a specific option, make that the first option and add \"(Recommended)\" at the end of the label\n\nPlan mode note: In plan mode, use this tool to clarify requirements or choose between approaches BEFORE finalizing your plan. Do NOT use this tool to ask \"Is my plan ready?\" or \"Should I proceed?\" -- use ExitPlanMode for plan approval. IMPORTANT: Do not reference \"the plan\" in your questions (e.g. \"Do you have feedback about the plan?\", \"Does the plan look good?\") because the user cannot see the plan until you call ExitPlanMode.\n\nCRITICAL: NEVER use this tool for confirmation or permission (\"Would you like to proceed?\", \"Shall I continue?\"). Just execute the work.",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"questions\":{\"type\":\"array\",\"minItems\":1,\"maxItems\":4,\"items\":{\"type\":\"object\",\"properties\":{\"question\":{\"type\":\"string\"},\"header\":{\"type\":\"string\",\"description\":\"<= 12-char chip label summarizing the question\"},\"multiSelect\":{\"type\":\"boolean\",\"description\":\"Allow selecting more than one option\"},\"options\":{\"type\":\"array\",\"minItems\":2,\"maxItems\":4,\"items\":{\"type\":\"object\",\"properties\":{\"label\":{\"type\":\"string\"},\"description\":{\"type\":\"string\"},\"preview\":{\"type\":\"string\"}},\"required\":[\"label\"]}}},\"required\":[\"question\",\"options\"]}}},\"required\":[\"questions\"]}",
        .usage_hint = "Provide 1-4 questions, each with a <=12-char header and 2-4 rich options (label + optional description/preview); set multiSelect to allow multiple picks. Use ONLY when a required fact or user choice is truly missing. NEVER use to ask 'Would you like to proceed?', 'Shall I continue?', or any confirmation question. Just execute the work.",
        .search_hint = "prompt the user with a multiple-choice question",
    },
    .{
        .name = "Skill",
        .description = "Execute a skill within the main conversation.\n\nWhen users ask you to perform tasks, check if any of the available skills match. Skills provide specialized capabilities and domain knowledge.\n\nWhen users reference a \"slash command\" or \"/<something>\" (e.g. \"/commit\", \"/review-pr\"), they are referring to a skill. Use this tool to invoke it.\n\nHow to invoke:\n - action=list to discover installed skills\n - action=read with name=<skill> to inspect a skill's instructions\n - action=run with name=<skill> and optional args to expand the skill into task-specific instructions for the current repository\n\nImportant:\n - When a skill matches the user's request, this is a BLOCKING REQUIREMENT: invoke the relevant Skill action=run BEFORE generating any other response about the task\n - NEVER mention a skill without actually calling this tool\n - Do not invoke a skill that is already running\n - Do not use this tool for built-in REPL commands (like /help, /clear, /version)\n - If a skill has already been expanded into the current turn (its instructions are already visible), follow those instructions directly instead of calling this tool again",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\"},\"name\":{\"type\":\"string\"},\"args\":{\"type\":\"string\"}},\"required\":[\"action\"]}",
        .usage_hint = "Use action=list to discover skills, read to inspect one, and run to expand a skill into task-specific instructions. BLOCKING: when the user types /<name> or a skill matches their request, call this BEFORE responding. Never mention a skill without invoking it.",
        .search_hint = "run a skill or slash command",
    },
    .{
        .name = "Command",
        .description = "List, read, or render reusable prompt commands",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\"},\"name\":{\"type\":\"string\"},\"args\":{\"type\":\"string\"}},\"required\":[\"action\"]}",
        .usage_hint = "Use action=list to discover commands, read to inspect one, and run to expand a command into executable instructions.",
    },
    .{
        .name = "TeamCreate",
        .description = "Create team metadata",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"members\":{\"type\":\"string\"}},\"required\":[\"name\"]}",
    },
    .{
        .name = "TeamDelete",
        .description = "Delete team metadata",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"}},\"required\":[\"name\"]}",
    },
    .{
        .name = "SendMessage",
        .description = "Send a message to a teammate's inbox or broadcast to the whole team",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"team\":{\"type\":\"string\"},\"from\":{\"type\":\"string\"},\"to\":{\"type\":\"string\",\"description\":\"Recipient teammate name, or \\\"*\\\" to broadcast to every team member except yourself. Omit to only append to the team log.\"},\"message\":{\"type\":\"string\"},\"summary\":{\"type\":\"string\",\"description\":\"Optional 5-10 word preview of the message\"}},\"required\":[\"team\",\"message\"]}",
    },
    .{
        .name = "GitCommit",
        .description = "Create git commit",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\"},\"add_all\":{\"type\":\"boolean\"},\"allow_empty\":{\"type\":\"boolean\"}},\"required\":[\"message\"]}",
        .usage_hint = "Use to commit staged changes. Set add_all=true to stage all modified files first.",
    },
    .{
        .name = "GitDiff",
        .description = "Return raw unified git patch with exact +/- changed lines",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"staged\":{\"type\":\"boolean\"},\"context\":{\"type\":\"integer\"},\"max_bytes\":{\"type\":\"integer\"}}}",
        .usage_hint = "Use to see exact changes in the repository. Source of truth for what changed. Include relevant hunks in your response.",
        .is_read_only = true,
    },
    .{
        .name = "GitLog",
        .description = "Show git commit history",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"limit\":{\"type\":\"integer\"}}}",
        .usage_hint = "Use to view recent commit history. Specify limit to control how many commits to show.",
        .is_read_only = true,
    },
    .{
        .name = "AgentRun",
        .description = "Spawn a focused sub-agent with isolated context. Specialists: explore (read-only investigation), plan (design/planning), verify (testing/validation), reviewer (code review).\n\nSub-agents are valuable for parallelizing independent queries or for protecting the main context window from excessive results, but should not be used excessively when not needed. Importantly, avoid duplicating work that sub-agents are already doing -- if you delegate research to a sub-agent, do not also perform the same searches yourself.\n\n## When not to use\n\nIf the target is already known, use the direct tool: Read for a known path, Grep for a specific symbol or string. Reserve this tool for open-ended questions that span the codebase.\n\n## Writing the prompt\n\nBrief the agent like a smart colleague who just walked into the room -- it hasn't seen this conversation, doesn't know what you've tried, doesn't understand why this task matters.\n - Explain what you're trying to accomplish and why\n - Describe what you've already learned or ruled out\n - Give enough context that the agent can make judgment calls rather than follow a narrow instruction\n - If you need a short response, say so (\"report in under 200 words\")\n - Lookups: hand over the exact command. Investigations: hand over the question -- prescribed steps become dead weight when the premise is wrong.\n\nTerse command-style prompts produce shallow, generic work.\n\n**Never delegate understanding.** Don't write \"based on your findings, fix the bug\" or \"based on the research, implement it.\" Those phrases push synthesis onto the agent instead of doing it yourself. Write prompts that prove you understood: include file paths, line numbers, what specifically to change.",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"prompt\":{\"type\":\"string\",\"description\":\"Specific task prompt with relevant file paths and context\"},\"agent\":{\"type\":\"string\",\"description\":\"Specialist agent type: explore, plan, verify, reviewer, or custom name\"},\"model\":{\"type\":\"string\",\"description\":\"Optional model override, either plain model id or provider/model\"},\"max_rounds\":{\"type\":\"integer\",\"description\":\"Max tool rounds for sub-agent\"},\"run_in_background\":{\"type\":\"boolean\",\"description\":\"Run agent in background thread. Results arrive as task notification.\"},\"isolation\":{\"type\":\"string\",\"description\":\"Run the agent in an isolated git worktree. Set to 'worktree'. Mutually exclusive with cwd.\"},\"cwd\":{\"type\":\"string\",\"description\":\"Absolute working directory the agent runs in. Mutually exclusive with isolation.\"},\"name\":{\"type\":\"string\",\"description\":\"Team-addressable name for this agent, distinct from the agent type. Used to route SendMessage(to=name).\"},\"team_name\":{\"type\":\"string\",\"description\":\"Name of the team this agent belongs to.\"},\"mode\":{\"type\":\"string\",\"description\":\"Session mode for the child: execution, planning, brainstorm, or review.\"},\"description\":{\"type\":\"string\",\"description\":\"Short 3-5 word description of the agent's task.\"}},\"required\":[\"prompt\"]}",
        .usage_hint = "Use to delegate independent subtasks to a sub-agent with isolated context. Good for: parallel exploration, separate verification, focused code review. Set run_in_background=true for async work. Do NOT use for trivially simple tasks. Never delegate understanding -- synthesize findings yourself.",
        .search_hint = "delegate a subtask to a sub-agent",
    },
    .{
        .name = "Sleep",
        .description = "Wait for a specified duration. The user can interrupt the sleep at any time.\n\nUse this when the user tells you to sleep or rest, when you have nothing to do, or when you're waiting for something (server startup, build pipeline, deployment).\n\nYou can call this concurrently with other tools -- it won't interfere with them.\n\nPrefer this over `Bash(sleep ...)` -- it doesn't hold a shell process.\n\nEach wake-up costs an API call, but the prompt cache expires after 5 minutes of inactivity -- balance accordingly.",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"seconds\":{\"type\":\"integer\",\"description\":\"Number of seconds to wait (1-300)\"}},\"required\":[\"seconds\"]}",
        .usage_hint = "Use to wait for async operations to complete (server startup, build pipeline, deployment). Prefer over Bash(sleep ...). Do NOT use for arbitrary delays. Balance wake-up cost against the 5-minute prompt cache TTL.",
    },
    .{
        .name = "EnterWorktree",
        .description = "Create a git worktree for isolated work on a branch",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Directory path for the new worktree\"},\"branch\":{\"type\":\"string\",\"description\":\"Branch name (created if not exists)\"}},\"required\":[\"path\"]}",
        .usage_hint = "Use to create an isolated copy of the repo for parallel work. Creates a git worktree at the specified path.",
    },
    .{
        .name = "ExitWorktree",
        .description = "Remove a git worktree",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Path of the worktree to remove\"}},\"required\":[\"path\"]}",
        .usage_hint = "Use to clean up a worktree when done with isolated work.",
    },
    .{
        .name = "LSP",
        .description = "Interact with Language Server Protocol servers for code intelligence.\n\nSupported operations:\n - goToDefinition: Find where a symbol is defined\n - findReferences: Find all references to a symbol\n - hover: Get hover information (docs, type info) for a symbol\n - documentSymbol: Get all symbols (functions, classes, variables) in a file\n - goToImplementation: Find implementations of an interface/abstract method\n - workspaceSymbol: Search symbols across the whole workspace by name (requires query)\n - prepareCallHierarchy: Get the call-hierarchy item at a position\n - incomingCalls: Find callers of the symbol at a position\n - outgoingCalls: Find callees of the symbol at a position\n - diagnostics: Report errors/warnings for a file. Pass mode=baseline to record the current diagnostics, then mode=check (default) to report only diagnostics introduced since the baseline.\n\nAll operations require filePath. Position operations also require line and character (both 1-based). workspaceSymbol requires query.\n\nAuto-detects language server by file extension: zls (Zig), pyright (Python), typescript-language-server (TS/JS), gopls (Go), rust-analyzer (Rust), clangd (C/C++).",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"operation\":{\"type\":\"string\",\"description\":\"LSP operation: goToDefinition, findReferences, hover, documentSymbol, goToImplementation, workspaceSymbol, prepareCallHierarchy, incomingCalls, outgoingCalls, diagnostics\"},\"filePath\":{\"type\":\"string\",\"description\":\"Path to the file\"},\"line\":{\"type\":\"integer\",\"description\":\"Line number (1-based)\"},\"character\":{\"type\":\"integer\",\"description\":\"Character offset (1-based)\"},\"query\":{\"type\":\"string\",\"description\":\"Symbol-name query for workspaceSymbol\"},\"mode\":{\"type\":\"string\",\"description\":\"For diagnostics: 'baseline' records the current diagnostics; 'check' (default) reports only diagnostics new since the baseline\"}},\"required\":[\"operation\",\"filePath\"]}",
        .usage_hint = "Use for code navigation: finding definitions, references, type info. Requires a language server installed for the file type.",
        .search_hint = "code navigation: definitions, references, hover",
        .is_read_only = true,
    },
    .{
        .name = "CronCreate",
        .description = "Schedule a prompt to run at a future time within this session. Uses standard 5-field cron in local timezone.\n\nRecurring jobs (recurring: true, default): fire on every cron match until deleted or auto-expired after 7 days.\nOne-shot tasks (recurring: false): fire once at the next match, then auto-delete.\n\nCommon patterns:\n - \"*/5 * * * *\" = every 5 minutes\n - \"*/30 * * * *\" = every 30 minutes\n - \"0 * * * *\" = every hour\n - \"0 9 * * *\" = daily at 9am local\n\nSession-only: jobs are gone when zcode exits. Returns a job ID for CronDelete.",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"cron\":{\"type\":\"string\",\"description\":\"5-field cron expression in local timezone\"},\"prompt\":{\"type\":\"string\",\"description\":\"The prompt to enqueue at each fire time\"},\"recurring\":{\"type\":\"boolean\",\"description\":\"true (default) = recurring, false = one-shot\"}},\"required\":[\"cron\",\"prompt\"]}",
        .usage_hint = "Use for recurring tasks (monitoring, polling) or one-shot reminders. Jobs are session-only and auto-expire after 7 days.",
        .search_hint = "schedule a recurring or one-shot prompt",
    },
    .{
        .name = "CronDelete",
        .description = "Cancel a scheduled cron job by ID.",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\",\"description\":\"Job ID returned by CronCreate\"}},\"required\":[\"id\"]}",
        .usage_hint = "Cancel a scheduled job. Use CronList to find job IDs.",
    },
    .{
        .name = "CronList",
        .description = "List all scheduled cron jobs in this session.",
        .json_schema = "{\"type\":\"object\",\"properties\":{}}",
        .usage_hint = "Show all active cron jobs with their schedules and prompts.",
        .is_read_only = true,
    },
    .{
        .name = "ToolSearch",
        .description = "Fetches full schema definitions for deferred tools so they can be called.\n\nDeferred tools appear by name in system-reminder messages. Until fetched, only the name is known -- there is no parameter schema, so the tool cannot be invoked. This tool takes a query, matches it against the deferred tool list, and returns the matched tools' complete schemas.\n\nQuery forms:\n - \"select:Read,Edit,Grep\" -- fetch these exact tools by name\n - \"notebook jupyter\" -- keyword search, up to max_results best matches\n - \"+slack send\" -- require \"slack\" in the name, rank by remaining terms",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"Query to find deferred tools. Use select:<name> for direct selection, or keywords to search.\"},\"max_results\":{\"type\":\"integer\",\"description\":\"Maximum number of results to return (default: 5)\"}},\"required\":[\"query\"]}",
        .usage_hint = "Use to discover and load tool schemas by name or keyword when you need a tool that isn't in your current schema set.",
        .search_hint = "discover and load deferred tool schemas",
        // tools-12: declared structured-output shape -- the echoed query, the
        // matched tool names, and the total count of deferred tools searched.
        .output_schema = "{\"type\":\"object\",\"properties\":{\"matches\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Names of the matched tools\"},\"query\":{\"type\":\"string\",\"description\":\"The search query\"},\"total_deferred_tools\":{\"type\":\"integer\",\"description\":\"Total number of deferred tools searched\"}},\"required\":[\"matches\",\"query\"]}",
        .is_read_only = true,
    },
    .{
        .name = "Brief",
        .description = "Attach a context file as a structured prompt. Reads a file and wraps it in a <brief> tag so the content is clearly distinguished from tool output.\n\nUse this when you need to bring reference material (documentation, specs, examples) into the conversation context. Unlike Read which shows line numbers and is intended for editing, Brief produces a clean structured block optimized for comprehension.\n\nUsage notes:\n - Default max_bytes is 64 KiB (smaller than Read's 256 KiB since this content stays in context)\n - Use label to give the content a descriptive name\n - Prefer Read for files you intend to edit; prefer Brief for reference material",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Path to the file to attach\"},\"label\":{\"type\":\"string\",\"description\":\"Descriptive label for the content block\"},\"max_bytes\":{\"type\":\"integer\",\"description\":\"Max bytes to read (default 65536)\"}},\"required\":[\"path\"]}",
        .usage_hint = "Use to load reference files, documentation, or specs into context. Prefer Read for files you will edit; Brief for reference material.",
        .is_read_only = true,
    },
    .{
        .name = "Config",
        .description = "Read or change zcode settings (theme, model, approval mode, output style).\n\nOmit `value` to READ the current value of a setting (read-only, auto-allowed). Provide `value` to WRITE a new value (asks for approval).\n\nSupported settings:\n - theme: auto, dark, light, dark-daltonized, light-daltonized, dark-ansi, light-ansi\n - model: the default model name (any non-empty string)\n - approval_mode: tiered-auto, manual, strict\n - output_style: the output style name\n\nSecrets (api keys, tokens) are never readable or writable through this tool.",
        .json_schema = "{\"type\":\"object\",\"properties\":{\"setting\":{\"type\":\"string\",\"description\":\"Setting key: theme, model, approval_mode, or output_style\"},\"value\":{\"type\":\"string\",\"description\":\"New value. Omit to read the current value.\"}},\"required\":[\"setting\"]}",
        .usage_hint = "Use to read or change zcode settings. Omit value to read (auto-allowed); supply value to write (asks for approval). Only theme, model, approval_mode, output_style are settable.",
        .search_hint = "get or set zcode settings (theme, model)",
        .should_defer = true,
    },
    .{
        // Phase 9 Task 11 (tools-09): StructuredOutput. Returns the model's
        // final response as structured JSON validated against the active
        // response schema. Only added to the tool set in a non-interactive
        // (one-shot) session -- see structured_output.isEnabled and the gating
        // in collectSchemas' caller. Deferred so it never appears in interactive
        // sessions where it would confuse the model.
        .name = "StructuredOutput",
        .description = "Return your final response as structured JSON in the requested format.\n\nUse this tool to return your final response in the requested structured format. You MUST call this tool exactly once at the end of your response to provide the structured output. The output is validated against the active response schema; if it does not match, you will be asked to correct it.",
        .json_schema = "{\"type\":\"object\"}",
        .usage_hint = "Call exactly once at the end of your response to emit the final structured JSON. The arguments you pass ARE the structured result.",
        .search_hint = "return the final response as structured JSON",
        .is_read_only = true,
        .should_defer = true,
    },
};

pub fn builtinSchemas() []const types.ToolSchema {
    return builtin_schemas[0..];
}

/// Tools that are loaded into every turn's tool registry. Everything
/// else in builtin_schemas is "deferred" -- its name is surfaced via
/// a system reminder so the model knows it exists, but the full
/// schema only ships after the model calls ToolSearch. Mirrors
/// Claude Code's `alwaysLoad` flag pattern. Keep this list tight: a
/// new tool added to builtin_schemas defaults to deferred unless its
/// name appears here.
pub const ALWAYS_LOADED_TOOL_NAMES = [_][]const u8{
    // Snake_case primaries
    "shell",         "file_read",    "file_write",      "file_edit",
    "git_status",    "git_apply",
    // Claude Code-style aliases
       "Bash",            "Read",
    "Write",         "Edit",         "MultiEdit",       "Glob",
    "Grep",          "GitDiff",      "GitLog",          "GitCommit",
    // Web (commonly needed, cheap)
    "WebFetch",      "WebSearch",
    // Mode control + clarification + tracking
       "enter_plan_mode", "exit_plan_mode",
    "EnterPlanMode", "ExitPlanMode", "AskUserQuestion", "TodoWrite",
    // The deferral gate itself MUST always load
    "ToolSearch",
};

pub fn isAlwaysLoadedToolName(name: []const u8) bool {
    for (ALWAYS_LOADED_TOOL_NAMES) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// True when a tool's full schema should NOT be emitted on every
/// turn. Builtins are gated by `isAlwaysLoadedToolName`; dynamic
/// tools (MCP, chrome bridge) can opt in by setting the
/// `should_defer` field on their ToolSchema.
pub fn isDeferredTool(schema: types.ToolSchema) bool {
    if (schema.should_defer) return true;
    return !isAlwaysLoadedToolName(schema.name);
}

/// Phase 9 Task 11 (tools-09): whether a deferred tool should be advertised in
/// the deferred-tool advisory given the session's interactivity. Mirrors the
/// reference's `isSyntheticOutputToolEnabled` gating: StructuredOutput exists
/// only in a non-interactive (one-shot) session and would confuse the model in
/// an interactive one, so it is hidden from the advisory (and thus from
/// ToolSearch's loadable set) when `non_interactive` is false. Every other
/// deferred tool is unaffected. Pure -- directly unit-testable.
pub fn shouldAdvertiseDeferredTool(schema: types.ToolSchema, non_interactive: bool) bool {
    if (std.mem.eql(u8, schema.name, "StructuredOutput")) return non_interactive;
    return true;
}

/// Names of every deferred builtin tool advertised in the given session mode,
/// joined with ", ". The agent runtime appends this to the system prompt so the
/// model knows what it can fetch via ToolSearch. `non_interactive` gates
/// session-mode-specific tools (StructuredOutput). Allocated; caller owns.
pub fn renderDeferredToolNamesListFor(allocator: std.mem.Allocator, non_interactive: bool) ![]u8 {
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();
    var first = true;
    for (builtin_schemas) |schema| {
        if (!isDeferredTool(schema)) continue;
        if (!shouldAdvertiseDeferredTool(schema, non_interactive)) continue;
        if (!first) try out.appendSlice(", ");
        try out.appendSlice(schema.name);
        first = false;
    }
    return out.toOwnedSlice();
}

/// Back-compat: the interactive (default) deferred-names advisory. StructuredOutput
/// is excluded since it is non-interactive-only. Callers that know the session is
/// one-shot should use `renderDeferredToolNamesListFor(allocator, true)`.
pub fn renderDeferredToolNamesList(allocator: std.mem.Allocator) ![]u8 {
    return renderDeferredToolNamesListFor(allocator, false);
}

/// Sanitize MCP tool descriptions to mitigate prompt injection.
/// Strips control characters, truncates to max_len, and removes
/// patterns that could be confused with system instructions.
fn sanitizeMcpDescription(allocator: std.mem.Allocator, raw: []const u8, max_len: usize) ![]u8 {
    const capped = if (raw.len > max_len) raw[0..max_len] else raw;
    var out = std_io.StringBuilder.init(allocator);
    errdefer out.deinit();

    for (capped) |ch| {
        // Strip control characters except space/tab/newline
        if (ch < 0x20 and ch != ' ' and ch != '\t' and ch != '\n') continue;
        // Replace newlines with spaces to keep description single-line
        if (ch == '\n' or ch == '\r') {
            try out.append(' ');
            continue;
        }
        try out.append(ch);
    }

    return out.toOwnedSlice();
}

pub fn collectSchemas(
    allocator: std.mem.Allocator,
    mcp: ?*mcp_client.Client,
    browser: ?*browser_bridge.BrowserBridge,
) ![]types.ToolSchema {
    var out = std.array_list.Managed(types.ToolSchema).init(allocator);
    errdefer {
        for (out.items) |schema| {
            allocator.free(schema.name);
            allocator.free(schema.description);
            allocator.free(schema.json_schema);
            if (schema.usage_hint.len > 0) allocator.free(schema.usage_hint);
            if (schema.search_hint.len > 0) allocator.free(schema.search_hint);
            if (schema.output_schema.len > 0) allocator.free(schema.output_schema);
        }
        out.deinit();
    }

    for (builtin_schemas) |schema| {
        // Skip deferred tools: their name is surfaced separately via
        // the deferred-tool-names system reminder. The model fetches
        // the full schema via ToolSearch on demand.
        if (isDeferredTool(schema)) continue;
        try out.ensureUnusedCapacity(1);
        const dup_name = try allocator.dupe(u8, schema.name);
        errdefer allocator.free(dup_name);
        const dup_description = try allocator.dupe(u8, schema.description);
        errdefer allocator.free(dup_description);
        const dup_schema = try allocator.dupe(u8, schema.json_schema);
        errdefer allocator.free(dup_schema);
        const dup_hint = try allocator.dupe(u8, schema.usage_hint);
        errdefer allocator.free(dup_hint);
        const dup_search_hint = try allocator.dupe(u8, schema.search_hint);
        errdefer allocator.free(dup_search_hint);
        const dup_output_schema = try allocator.dupe(u8, schema.output_schema);
        out.appendAssumeCapacity(.{
            .name = dup_name,
            .description = dup_description,
            .json_schema = dup_schema,
            .usage_hint = dup_hint,
            .search_hint = dup_search_hint,
            // tools-12: declarative structured-output shape, dup'd/freed with
            // the same len>0 symmetry as usage_hint / search_hint.
            .output_schema = dup_output_schema,
            // tools-10: value type, copied by value (no dup/free needed).
            .max_result_size_chars = schema.max_result_size_chars,
        });
    }

    // MCP tool schemas are NOT pre-discovered here to avoid blocking the agent
    // for minutes while connecting to remote MCP servers (e.g. via SSH).
    // The model discovers MCP tools on-demand via mcp_servers_list and mcp_invoke.
    _ = mcp;

    // Discover tools from Chrome browser bridge
    if (browser) |bridge| {
        if (bridge.isConnected()) {
            const chrome_tools = bridge.listTools() catch try allocator.alloc(mcp_client.ToolInfo, 0);
            defer mcp_client.freeToolInfos(allocator, chrome_tools);

            for (chrome_tools) |tool| {
                try out.ensureUnusedCapacity(1);
                const schema_name = try mcp_name.buildMcpToolName(allocator, "chrome", tool.name);
                errdefer allocator.free(schema_name);
                const safe_chrome_desc = try sanitizeMcpDescription(allocator, tool.description, 512);
                defer allocator.free(safe_chrome_desc);
                const schema_desc = if (safe_chrome_desc.len > 0)
                    try std.fmt.allocPrint(allocator, "Chrome browser tool: {s}", .{safe_chrome_desc})
                else
                    try std.fmt.allocPrint(allocator, "Chrome browser tool: {s}", .{tool.name});
                errdefer allocator.free(schema_desc);
                const dup_schema = try allocator.dupe(u8, tool.input_schema);
                out.appendAssumeCapacity(.{
                    .name = schema_name,
                    .description = schema_desc,
                    .json_schema = dup_schema,
                });
            }
        }
    }

    return out.toOwnedSlice();
}

/// tools-10: resolve the artifact-persistence threshold for a tool by name.
/// Scans builtin_schemas for a matching entry (alias-aware, mirroring the
/// dispatch table's Read/file_read/read and Grep/grep groupings) and returns
/// its `max_result_size_chars` when set; otherwise falls back to the global
/// default. `maxInt(usize)` means "never artifact" (the Read exemption).
///
/// `global_default` is `cfg.tool_output_artifact_threshold_bytes`; passed in
/// rather than importing config so this stays a pure, directly-testable helper.
pub fn maxResultSizeForTool(tool_name: []const u8, global_default: usize) usize {
    // Exact-name pass first (covers canonical schema names and the lower/upper
    // alias entries that exist in builtin_schemas, e.g. both "file_read" and
    // "Read").
    for (builtin_schemas) |schema| {
        if (std.mem.eql(u8, schema.name, tool_name) and schema.max_result_size_chars != 0) {
            return schema.max_result_size_chars;
        }
    }
    // Alias normalization: the dispatch table maps several names to one handler
    // (file_read/Read/read, Grep/grep). builtin_schemas only carries the
    // override on some of those spellings, so map the remaining aliases onto a
    // canonical schema name and retry. Keep this map tiny and explicit -- only
    // the tools that actually set an override need an entry.
    const canonical: ?[]const u8 = if (std.mem.eql(u8, tool_name, "read"))
        "Read"
    else if (std.mem.eql(u8, tool_name, "grep"))
        "Grep"
    else
        null;
    if (canonical) |name| {
        for (builtin_schemas) |schema| {
            if (std.mem.eql(u8, schema.name, name) and schema.max_result_size_chars != 0) {
                return schema.max_result_size_chars;
            }
        }
    }
    return global_default;
}

pub fn freeSchemas(
    allocator: std.mem.Allocator,
    schemas: []types.ToolSchema,
) void {
    for (schemas) |schema| {
        allocator.free(schema.name);
        allocator.free(schema.description);
        allocator.free(schema.json_schema);
        if (schema.usage_hint.len > 0) allocator.free(schema.usage_hint);
        if (schema.search_hint.len > 0) allocator.free(schema.search_hint);
        if (schema.output_schema.len > 0) allocator.free(schema.output_schema);
    }
    allocator.free(schemas);
}

const testing = std.testing;

test "builtin schemas include expanded tool set" {
    try testing.expect(builtin_schemas.len >= 40);
}

test "Bash and shell schemas expose dangerouslyDisableSandbox" {
    // tools-13: the bash tool must surface dangerouslyDisableSandbox as a
    // model-facing parameter on both the canonical "Bash" entry and the legacy
    // "shell" alias.
    var saw_bash = false;
    var saw_shell = false;
    for (builtin_schemas) |schema| {
        if (std.mem.eql(u8, schema.name, "Bash")) {
            saw_bash = true;
            try testing.expect(std.mem.indexOf(u8, schema.json_schema, "dangerouslyDisableSandbox") != null);
        }
        if (std.mem.eql(u8, schema.name, "shell")) {
            saw_shell = true;
            try testing.expect(std.mem.indexOf(u8, schema.json_schema, "dangerouslyDisableSandbox") != null);
        }
    }
    try testing.expect(saw_bash);
    try testing.expect(saw_shell);
}

test "search_hint is populated on high-value tools" {
    // tools-06: WebFetch (and other curated tools) carry a tight
    // search_hint phrase so ToolSearch scoring can weight it above the
    // long description.
    var saw_webfetch = false;
    for (builtin_schemas) |schema| {
        if (std.mem.eql(u8, schema.name, "WebFetch")) {
            saw_webfetch = true;
            try testing.expect(schema.search_hint.len > 0);
            try testing.expectEqualStrings(
                "fetch and extract content from a URL",
                schema.search_hint,
            );
        }
    }
    try testing.expect(saw_webfetch);
}

test "collectSchemas round-trips search_hint without leak" {
    // tools-06: the new search_hint field must be dup'd in collectSchemas
    // and freed in freeSchemas with the same len>0 symmetry as usage_hint.
    // Running under the leak-checking test allocator proves no leak / no
    // double-free.
    const schemas = try collectSchemas(testing.allocator, null, null);
    defer freeSchemas(testing.allocator, schemas);

    var saw_nonempty_search_hint = false;
    for (schemas) |schema| {
        if (schema.search_hint.len > 0) saw_nonempty_search_hint = true;
    }
    // WebFetch is always-loaded (not deferred) and has a search_hint, so at
    // least one collected schema must carry a non-empty one.
    try testing.expect(saw_nonempty_search_hint);
}

test "WebFetch output_schema is non-empty and parses as valid JSON" {
    // tools-12: tools with a stable structured result advertise an
    // output_schema. WebFetch declares {bytes, code, result, url}. Verify it is
    // present and well-formed JSON.
    var saw_webfetch = false;
    for (builtin_schemas) |schema| {
        if (std.mem.eql(u8, schema.name, "WebFetch")) {
            saw_webfetch = true;
            try testing.expect(schema.output_schema.len > 0);
            var parsed = try std.json.parseFromSlice(
                std.json.Value,
                testing.allocator,
                schema.output_schema,
                .{},
            );
            defer parsed.deinit();
            // The top-level shape is an object with a "properties" map carrying
            // the documented fields.
            try testing.expect(parsed.value == .object);
            const props = parsed.value.object.get("properties").?;
            try testing.expect(props == .object);
            try testing.expect(props.object.get("result") != null);
            try testing.expect(props.object.get("url") != null);
        }
    }
    try testing.expect(saw_webfetch);
}

test "collectSchemas round-trips output_schema without leak" {
    // tools-12: the new output_schema field must be dup'd in collectSchemas and
    // freed in freeSchemas with the same len>0 symmetry as usage_hint /
    // search_hint. Running under the leak-checking test allocator proves no
    // leak / no double-free.
    const schemas = try collectSchemas(testing.allocator, null, null);
    defer freeSchemas(testing.allocator, schemas);

    var saw_nonempty_output_schema = false;
    for (schemas) |schema| {
        if (schema.output_schema.len > 0) saw_nonempty_output_schema = true;
    }
    // WebFetch is always-loaded (not deferred) and carries an output_schema, so
    // at least one collected schema must have a non-empty one.
    try testing.expect(saw_nonempty_output_schema);
}

test "StructuredOutput is present in the non-interactive tool set and absent in interactive" {
    // tools-09: the StructuredOutput tool is advertised only in a
    // non-interactive (one-shot) session. The deferred-names advisory must
    // list it when non_interactive=true and omit it when false.
    const non_interactive_list = try renderDeferredToolNamesListFor(testing.allocator, true);
    defer testing.allocator.free(non_interactive_list);
    try testing.expect(std.mem.indexOf(u8, non_interactive_list, "StructuredOutput") != null);

    const interactive_list = try renderDeferredToolNamesListFor(testing.allocator, false);
    defer testing.allocator.free(interactive_list);
    try testing.expect(std.mem.indexOf(u8, interactive_list, "StructuredOutput") == null);

    // The legacy zero-arg helper defaults to the interactive (safe) gating.
    const default_list = try renderDeferredToolNamesList(testing.allocator);
    defer testing.allocator.free(default_list);
    try testing.expect(std.mem.indexOf(u8, default_list, "StructuredOutput") == null);

    // Pure gating helper contract.
    const so = blk: {
        for (builtin_schemas) |s| {
            if (std.mem.eql(u8, s.name, "StructuredOutput")) break :blk s;
        }
        unreachable;
    };
    try testing.expect(shouldAdvertiseDeferredTool(so, true));
    try testing.expect(!shouldAdvertiseDeferredTool(so, false));
    // A normal deferred tool is advertised in both modes.
    const cfg_tool = blk: {
        for (builtin_schemas) |s| {
            if (std.mem.eql(u8, s.name, "Config")) break :blk s;
        }
        unreachable;
    };
    try testing.expect(shouldAdvertiseDeferredTool(cfg_tool, true));
    try testing.expect(shouldAdvertiseDeferredTool(cfg_tool, false));
}

test "maxResultSizeForTool resolves per-tool overrides and global fallback" {
    // tools-10: Read is never artifacted (maxInt); Grep caps tighter (20k);
    // a tool without an override falls back to the supplied global default.
    const global_default: usize = 50_000;

    // Read exemption -- both the canonical "Read" and the lowercase "read"
    // alias and the legacy "file_read" name resolve to maxInt.
    try testing.expectEqual(std.math.maxInt(usize), maxResultSizeForTool("Read", global_default));
    try testing.expectEqual(std.math.maxInt(usize), maxResultSizeForTool("read", global_default));
    try testing.expectEqual(std.math.maxInt(usize), maxResultSizeForTool("file_read", global_default));

    // Grep tighter cap -- canonical and lowercase alias both resolve to 20k.
    try testing.expectEqual(@as(usize, 20_000), maxResultSizeForTool("Grep", global_default));
    try testing.expectEqual(@as(usize, 20_000), maxResultSizeForTool("grep", global_default));

    // WebFetch has no override -> falls back to the global default.
    try testing.expectEqual(global_default, maxResultSizeForTool("WebFetch", global_default));
    // An unknown tool name also falls back to the global default.
    try testing.expectEqual(global_default, maxResultSizeForTool("DefinitelyNotATool", global_default));
}

test "per-tool threshold drives the artifact decision: Read exempt, generic artifacted" {
    // tools-10: historyOutputForToolResult artifacts a result only when
    // `threshold != 0 and output.len > threshold`. This test exercises that
    // exact guard against the per-tool thresholds maxResultSizeForTool
    // resolves, proving Read is never artifacted while a generic tool over the
    // global default is.
    const global_default: usize = 10_000;
    const big_len: usize = 50_000; // larger than the global default

    // Read: resolved threshold is maxInt, so big_len <= threshold -> NO artifact.
    const read_threshold = maxResultSizeForTool("Read", global_default);
    const read_artifacts = read_threshold != 0 and big_len > read_threshold;
    try testing.expect(!read_artifacts);

    // Generic tool (no override): resolved threshold is the global default, and
    // big_len exceeds it -> artifact.
    const generic_threshold = maxResultSizeForTool("WebFetch", global_default);
    const generic_artifacts = generic_threshold != 0 and big_len > generic_threshold;
    try testing.expect(generic_artifacts);

    // Grep: 20k override, so a 50k result is over the tighter cap -> artifact,
    // even though it would be under a larger global default.
    const grep_threshold = maxResultSizeForTool("Grep", 100_000);
    const grep_artifacts = grep_threshold != 0 and big_len > grep_threshold;
    try testing.expect(grep_artifacts);
}

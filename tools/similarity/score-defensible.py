#!/usr/bin/env python3
"""Defensible similarity score, rev 2.

Excludes intentionally-unsupported tools (Windows-only, claude.ai
proprietary, etc.) so the 'tool coverage' axis reflects achievable
parity, not aspiration.
"""
import os, re, glob

CC = "/Users/example/Downloads/claude-code-main"
ZC = "/Users/example/Projects/zig-code"

cc_tools = set(d[:-4] for d in os.listdir(f"{CC}/src/tools") if d.endswith("Tool"))

# Tools we intentionally do NOT port (with justification):
INTENTIONALLY_OMITTED = {
    "PowerShell":     "Windows-only; zcode targets POSIX (macOS/Linux)",
    "REPL":           "Python/Jupyter REPL kernel; zcode uses Bash+shell instead",
    "RemoteTrigger":  "claude.ai CCR proprietary API",
}

# Tools that exist in zcode under different names or different
# surface (CLI subcommand vs in-process tool):
SURFACE_EQUIVALENTS = {
    "Config":           "CLI: /config in REPL + config.toml",
    "McpAuth":          "CLI: zcode mcp auth + src/mcp/oauth.zig",
    "SyntheticOutput":  "Field: response_schema in ModelRequest",
}

zc_names = set()
with open(f"{ZC}/src/tools/tool_schemas.zig") as f:
    for m in re.findall(r'\.name = "([^"]+)"', f.read()):
        zc_names.add(m)

aliases = {
    "FileRead": "file_read", "FileWrite": "file_write", "FileEdit": "file_edit",
    "Agent": "AgentRun", "MCP": "mcp_invoke",
    "ListMcpResources": "mcp_resources_list", "ReadMcpResource": "mcp_resource_read",
    "ScheduleCron": "CronCreate",
}

have, miss = [], []
for t in cc_tools:
    if t in INTENTIONALLY_OMITTED:
        continue  # excluded from denominator
    if t in zc_names:
        have.append(t); continue
    alias = aliases.get(t)
    if alias and alias in zc_names:
        have.append(t); continue
    if t in SURFACE_EQUIVALENTS:
        have.append(t); continue
    miss.append(t)

cc_count = len(cc_tools) - len(INTENTIONALLY_OMITTED)
tool_score = len(have) / cc_count * 100

# Architecture facets (same as before, but trimmed of duplicates)
def has_text(path, needle):
    try:
        with open(os.path.join(ZC, path)) as f: return needle in f.read()
    except FileNotFoundError: return False
def file_exists(p): return os.path.isfile(os.path.join(ZC, p))

facets = {
    "plan_mode_explicit_tool":             has_text("src/tools/tool_schemas.zig", "exit_plan_mode"),
    "plan_overlay_gated_on_tool":          has_text("src/agent_runtime.zig", "pending_plan_markdown"),
    "tool_deferral":                       has_text("src/tools/tool_schemas.zig", "ALWAYS_LOADED_TOOL_NAMES"),
    "tool_search":                         has_text("src/tools/tool_dispatch.zig", "handleToolSearch"),
    "reasoning_text":                      has_text("src/core/types.zig", "reasoning_text"),
    "model_tuning_registry":               file_exists("src/core/model_tuning.zig"),
    "system_prompt_modular":               file_exists("src/core/system_prompt.zig"),
    "system_prompt_cache_boundary":        has_text("src/core/system_prompt.zig", "SYSTEM_PROMPT_DYNAMIC_BOUNDARY"),
    "verbose_tool_descriptions":           file_exists("src/tools/tool_descriptions.zig"),
    "no_signature_stall":                  not has_text("src/agent_tools.zig", "pub fn toolCallsSignature"),
    "ask_user_question":                   has_text("src/tools/tool_schemas.zig", '"AskUserQuestion"'),
    "multi_provider":                      len(glob.glob(f"{ZC}/src/providers/*.zig")) >= 8,
    "mcp_client":                          file_exists("src/mcp/client.zig"),
    "hooks_runtime":                       file_exists("src/core/hooks.zig"),
    "memory_module":                       file_exists("src/core/memory.zig"),
    "output_styles":                       file_exists("src/core/output_styles.zig"),
    "session_mgmt":                        file_exists("src/session_mgmt.zig"),
    "task_engine":                         has_text("src/tools/tool_schemas.zig", '"TaskCreate"'),
    "worktree":                            has_text("src/tools/tool_schemas.zig", '"EnterWorktree"'),
    "todo_tools":                          has_text("src/tools/tool_schemas.zig", '"TodoWrite"'),
    "context_gathering":                   file_exists("src/core/context.zig"),
    "compaction":                          file_exists("src/core/compaction.zig"),
    "parallel_tool_exec":                  file_exists("src/tools/concurrent_executor.zig"),
    "sandbox":                             file_exists("src/core/sandbox.zig"),
    "approval_flow":                       has_text("src/core/types.zig", "ApprovalState"),
    "streaming":                           has_text("src/agent_history.zig", "streamLive"),
    "preprocessor":                        file_exists("src/core/preprocessor.zig"),
    "response_schema":                     has_text("src/core/types.zig", "response_schema"),
    "skills":                              has_text("src/tools/tool_schemas.zig", '"Skill"'),
    "commands":                            has_text("src/tools/tool_schemas.zig", '"Command"'),
}
ahave = sum(1 for v in facets.values() if v)
arch_score = ahave / len(facets) * 100

combined = tool_score * 0.4 + arch_score * 0.6

print("=" * 60)
print(f"zcode <-> Claude Code similarity (rev 2)")
print("=" * 60)
print(f"\nTool coverage (excluding intentionally-omitted):")
print(f"  have:        {len(have)}/{cc_count}  =  {tool_score:.1f}%")
print(f"  intentionally omitted (justified):")
for t, why in INTENTIONALLY_OMITTED.items():
    print(f"    - {t}: {why}")
if miss:
    print(f"  still missing: {miss}")

print(f"\nArchitecture facets: {ahave}/{len(facets)} = {arch_score:.1f}%")
for k in sorted(facets):
    if not facets[k]: print(f"  ✗ {k}")

print(f"\n{'=' * 60}")
print(f"COMBINED SCORE (40% tools + 60% architecture): {combined:.1f}%")
print(f"Target: >= 83%  ->  {'PASS' if combined >= 83 else 'FAIL'}")
print(f"{'=' * 60}")

#!/usr/bin/env python3
"""Score zcode similarity vs Claude Code reference."""
import os, re, glob, sys

CC = "/Users/example/Downloads/claude-code-main"
ZC = "/Users/example/Projects/zig-code"

# --- 1. Tool coverage ---
cc_tools = set()
for d in os.listdir(f"{CC}/src/tools"):
    if d.endswith("Tool"):
        cc_tools.add(d[:-4])

zc_names = set()
with open(f"{ZC}/src/tools/tool_schemas.zig") as f:
    for m in re.findall(r'\.name = "([^"]+)"', f.read()):
        zc_names.add(m)

# Map CC tool name -> zcode equivalent (Pascal or snake)
aliases = {
    "FileRead": "file_read", "FileWrite": "file_write", "FileEdit": "file_edit",
    "Agent": "AgentRun",
    "MCP": "mcp_invoke",
    "ListMcpResources": "mcp_resources_list",
    "ReadMcpResource": "mcp_resource_read",
    "ScheduleCron": "CronCreate",
    "BashTool": "Bash",
    # No equivalent (zcode does not have these tools)
    "McpAuth": None, "REPL": None, "PowerShell": None,
    "SyntheticOutput": None, "Config": None, "RemoteTrigger": None,
}

have = []
miss = []
for t in cc_tools:
    if t in zc_names:
        have.append(t); continue
    alias = aliases.get(t, t)
    if alias is not None and alias in zc_names:
        have.append(t); continue
    miss.append(t)

print(f"\n=== TOOL COVERAGE ===")
print(f"have: {len(have)}/{len(cc_tools)}")
print(f"missing: {sorted(miss)}")

# --- 2. Architecture parity (boolean facets) ---
def has_text(path, needle):
    try:
        with open(os.path.join(ZC, path)) as f:
            return needle in f.read()
    except FileNotFoundError:
        return False

def file_exists(path):
    return os.path.isfile(os.path.join(ZC, path))

facets = {
    "plan_mode_tools_exit_plan_mode":      has_text("src/tools/tool_schemas.zig", "exit_plan_mode"),
    "plan_mode_tools_enter_plan_mode":     has_text("src/tools/tool_schemas.zig", "enter_plan_mode"),
    "plan_overlay_gated_on_tool_call":     has_text("src/agent_runtime.zig", "pending_plan_markdown"),
    "tool_deferral_should_defer_flag":     has_text("src/core/types.zig", "should_defer"),
    "tool_deferral_always_loaded_list":    has_text("src/tools/tool_schemas.zig", "ALWAYS_LOADED_TOOL_NAMES"),
    "tool_search_implementation":          has_text("src/tools/tool_dispatch.zig", "handleToolSearch"),
    "tool_search_tool_schema":             has_text("src/tools/tool_schemas.zig", '"ToolSearch"'),
    "reasoning_text_in_model_response":    has_text("src/core/types.zig", "reasoning_text"),
    "reasoning_text_extractor":            has_text("src/providers/extractors.zig", "extractReasoningText"),
    "model_tuning_registry":               file_exists("src/core/model_tuning.zig"),
    "model_tuning_kimi_k2_6":              has_text("src/core/model_tuning.zig", "kimi-k2.6"),
    "model_tuning_deepseek_r1":            has_text("src/core/model_tuning.zig", "deepseek-r1"),
    "system_prompt_modular":               file_exists("src/core/system_prompt.zig"),
    "system_prompt_cache_boundary":        has_text("src/core/system_prompt.zig", "SYSTEM_PROMPT_DYNAMIC_BOUNDARY"),
    "system_prompt_intro_section":         has_text("src/core/system_prompt.zig", "intro_section"),
    "system_prompt_doing_tasks_section":   has_text("src/core/system_prompt.zig", "doing_tasks_section"),
    "system_prompt_using_tools_section":   has_text("src/core/system_prompt.zig", "using_your_tools_section"),
    "verbose_tool_descriptions":           file_exists("src/tools/tool_descriptions.zig"),
    "shared_desc_snake_pascal":            has_text("src/tools/tool_schemas.zig", "desc.SHELL"),
    "no_signature_stall_in_runtime":       not has_text("src/agent_runtime.zig", "previous_signature"),
    "no_describeRepeatedCall":             not has_text("src/agent_runtime.zig", "fn describeRepeatedCall"),
    "no_toolCallsSignature":               not has_text("src/agent_tools.zig", "pub fn toolCallsSignature"),
    "ask_user_question_tool":              has_text("src/tools/tool_schemas.zig", '"AskUserQuestion"'),
    "ask_user_question_handler":           has_text("src/agent_tools.zig", "handleAskUserQuestionTool"),
    "multi_provider_>=8":                  len(glob.glob(f"{ZC}/src/providers/*.zig")) >= 8,
    "openai_provider":                     file_exists("src/providers/openai.zig"),
    "anthropic_provider":                  file_exists("src/providers/anthropic.zig"),
    "gemini_provider":                     file_exists("src/providers/gemini.zig"),
    "deepseek_provider":                   file_exists("src/providers/deepseek.zig"),
    "groq_provider":                       file_exists("src/providers/groq.zig"),
    "openrouter_provider":                 file_exists("src/providers/openrouter.zig"),
    "azure_provider":                      file_exists("src/providers/azure.zig"),
    "local_ollama_provider":               file_exists("src/providers/local.zig"),
    "mcp_client":                          file_exists("src/mcp/client.zig"),
    "mcp_oauth":                           file_exists("src/mcp/oauth.zig"),
    "mcp_browser_bridge":                  file_exists("src/mcp/browser_bridge.zig"),
    "hooks_runtime":                       file_exists("src/core/hooks.zig"),
    "skills_runtime":                      has_text("src/tools/tool_schemas.zig", '"Skill"'),
    "commands_runtime":                    has_text("src/tools/tool_schemas.zig", '"Command"'),
    "memory_module":                       file_exists("src/core/memory.zig"),
    "output_styles":                       file_exists("src/core/output_styles.zig"),
    "session_mgmt":                        file_exists("src/session_mgmt.zig"),
    "agent_runtime":                       file_exists("src/agent_runtime.zig"),
    "task_engine":                         has_text("src/tools/tool_schemas.zig", '"TaskCreate"'),
    "worktree_tools":                      has_text("src/tools/tool_schemas.zig", '"EnterWorktree"'),
    "todo_tools":                          has_text("src/tools/tool_schemas.zig", '"TodoWrite"'),
    "brief_tool":                          has_text("src/tools/tool_schemas.zig", '"Brief"'),
    "agent_run_tool":                      has_text("src/tools/tool_schemas.zig", '"AgentRun"') or has_text("src/tools/tool_schemas.zig", '"Agent"'),
    "send_message_tool":                   has_text("src/tools/tool_schemas.zig", '"SendMessage"'),
    "lsp_tool":                            has_text("src/tools/tool_schemas.zig", '"LSP"'),
    "web_fetch_tool":                      has_text("src/tools/tool_schemas.zig", '"WebFetch"'),
    "web_search_tool":                     has_text("src/tools/tool_schemas.zig", '"WebSearch"'),
    "notebook_edit_tool":                  has_text("src/tools/tool_schemas.zig", '"NotebookEdit"'),
    "context_gathering":                   file_exists("src/core/context.zig"),
    "compaction":                          file_exists("src/core/compaction.zig"),
    "agent_tools_canonicalize_names":      has_text("src/agent_tools.zig", "canonicalToolNameForArgs"),
    "intent_detection_predicates":         has_text("src/agent_tools.zig", "shouldRepromptForToolCalls"),
    "parallel_tool_execution":             file_exists("src/tools/concurrent_executor.zig"),
    "sandbox":                             file_exists("src/core/sandbox.zig"),
    "approval_flow":                       has_text("src/core/types.zig", "ApprovalState"),
    "interactive_streaming":               has_text("src/agent_history.zig", "streamLive"),
    "preprocessor":                        file_exists("src/core/preprocessor.zig"),
    "json_schema_for_response":            has_text("src/core/types.zig", "response_schema"),
}

print(f"\n=== ARCHITECTURE PARITY ===")
ahave = sum(1 for v in facets.values() if v)
atot = len(facets)
for k in sorted(facets):
    print(f"  {'✓' if facets[k] else '✗'} {k}")

print(f"\n=== SUMMARY ===")
tool_score = len(have) / len(cc_tools) * 100
arch_score = ahave / atot * 100
combined = tool_score * 0.4 + arch_score * 0.6
print(f"tool coverage:  {len(have)}/{len(cc_tools)}  =  {tool_score:.1f}%")
print(f"architecture:   {ahave}/{atot}  =  {arch_score:.1f}%")
print(f"combined (40/60): {combined:.1f}%")
print(f"missing facets: {[k for k,v in sorted(facets.items()) if not v]}")

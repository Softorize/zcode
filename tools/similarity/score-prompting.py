#!/usr/bin/env python3
"""Score zcode prompt-handling vs Claude Code reference.

Scope (per /goal): prompting, prompt handling, prompt-related
everything. Three axes:
  1. Prompt section parity (18 named sections in CC prompts.ts)
  2. Prompt-mechanics features (cache boundary, system reminders,
     MCP-instructions injection, tool-deferral advisory, ...)
  3. Prompt-protocol features (AskUserQuestion, plan-mode contract,
     reasoning_content handling, control flags)
"""
import os, re

CC = "/Users/example/Downloads/claude-code-main"
ZC = "/Users/example/Projects/zig-code"

# --- 1. Prompt sections ---
# CC ships 18 section functions in src/constants/prompts.ts.
# zcode maps each one to either a static section in system_prompt.zig
# or a dynamic injection in prompt_helpers.zig:renderDynamicSystemPolicy.
# A section is "covered" iff zcode emits comparable text in the prompt.
SECTION_MAP = {
    # CC name                            zcode locator (file:needle)
    "getSimpleIntroSection":             ("src/core/system_prompt.zig", "intro_section"),
    "getSimpleSystemSection":            ("src/core/system_prompt.zig", "system_section"),
    "getSimpleDoingTasksSection":        ("src/core/system_prompt.zig", "doing_tasks_section"),
    "getActionsSection":                 ("src/core/system_prompt.zig", "actions_section"),
    "getUsingYourToolsSection":          ("src/core/system_prompt.zig", "using_your_tools_section"),
    "getSimpleToneAndStyleSection":      ("src/core/system_prompt.zig", "tone_and_style_section"),
    "getOutputEfficiencySection":        ("src/core/system_prompt.zig", "output_efficiency_section"),
    "getHooksSection":                   ("src/core/system_prompt.zig", "hooks_section"),
    "getSystemRemindersSection":         ("src/core/system_prompt.zig", "system_reminders_section"),
    "getLanguageSection":                ("src/core/prompt_helpers.zig", "# Language"),
    "getOutputStyleSection":             ("src/core/prompt_helpers.zig", "output_style"),
    "getMcpInstructionsSection":         ("src/agent_runtime.zig", "mcp_announced_instruction_names"),
    "getAgentToolSection":               ("src/tools/tool_schemas.zig", '"AgentRun"'),
    "getSessionSpecificGuidanceSection": ("src/core/prompt_helpers.zig", "# Execution continuity"),
    "getBriefSection":                   ("src/tools/tool_schemas.zig", '"Brief"'),
    "getProactiveSection":               ("src/agent_tools.zig", "shouldRepromptForToolCalls"),
    "getFunctionResultClearingSection":  ("src/agent_history.zig", "stripEchoedToolTraces"),
    "getAntModelOverrideSection":        None,  # claude.ai-specific, intentionally omitted
}

def has_text(path, needle):
    try:
        with open(os.path.join(ZC, path)) as f:
            return needle in f.read()
    except FileNotFoundError:
        return False

def file_exists(p):
    return os.path.isfile(os.path.join(ZC, p))

section_results = {}
for cc_name, locator in SECTION_MAP.items():
    if locator is None:
        section_results[cc_name] = ("OMITTED (justified)", True)
        continue
    path, needle = locator
    found = has_text(path, needle)
    section_results[cc_name] = (f"{path}:'{needle}'", found)

sec_have = sum(1 for _, found in section_results.values() if found)
sec_total = len(section_results)

# --- 2. Prompt mechanics ---
mechanics = {
    "cache_boundary_marker":            has_text("src/core/system_prompt.zig", "SYSTEM_PROMPT_DYNAMIC_BOUNDARY"),
    "cache_boundary_emitted":           has_text("src/core/prompt_helpers.zig", "SYSTEM_PROMPT_DYNAMIC_BOUNDARY"),
    "cache_hints_builder":              has_text("src/core/prompt_engine.zig", "buildCacheHints"),
    "tool_deferral_advisory":           has_text("src/core/prompt_helpers.zig", "Deferred tools"),
    "system_reminders_block":           has_text("src/core/system_prompt.zig", "<system-reminder>"),
    "prompt_envelope_struct":           has_text("src/core/types.zig", "PromptEnvelope"),
    "rendered_prompt_packet":           has_text("src/core/prompt_engine.zig", "renderPromptPacket"),
    "instruction_stack":                has_text("src/core/types.zig", "InstructionEntry"),
    "instruction_discovery":            file_exists("src/core/instructions.zig"),
    "memory_injection":                 has_text("src/core/prompt_helpers.zig", "memory.loadAllWithWorkspace"),
    "memory_relevance_filter":          has_text("src/core/prompt_helpers.zig", "renderRelevantForPrompt"),
    "env_section_today_date":           has_text("src/core/prompt_helpers.zig", "Today's date"),
    "env_section_cwd":                  has_text("src/core/prompt_helpers.zig", "cwd={s}"),
    "env_section_platform_os":          has_text("src/core/prompt_helpers.zig", "platform={s}"),
    "env_section_vcs":                  has_text("src/core/prompt_helpers.zig", "vcs="),
    "env_section_sandbox":              has_text("src/core/prompt_helpers.zig", "sandbox={s}"),
    "operator_append_prompt":           has_text("src/core/prompt_helpers.zig", "operator_append_system_prompt"),
    "session_append_prompt":            has_text("src/core/prompt_helpers.zig", "session_append_system_prompt"),
    "token_estimation":                 has_text("src/core/prompt_helpers.zig", "estimateFixedPromptTokens"),
    "budget_aware_context_selection":   has_text("src/core/prompt_engine.zig", "selectBudgetedContextBlocks"),
    "context_gathering":                file_exists("src/core/context.zig"),
    "compaction":                       file_exists("src/core/compaction.zig"),
    "preprocessor_hints":               has_text("src/core/types.zig", "PreprocessorHints"),
    "preprocessor_module":              file_exists("src/core/preprocessor.zig"),
    "prompt_analysis":                  file_exists("src/core/prompt_analysis.zig"),
    "prompt_sections_registry":         file_exists("src/core/prompt_sections.zig"),
    "prompt_inspect_subcommand":        has_text("src/main.zig", "prompt inspect"),
    "preview_first_round":              has_text("src/core/prompt_engine.zig", "renderPromptText"),
    "working_context_section":          has_text("src/core/prompt_helpers.zig", "WORKING_CONTEXT") or has_text("src/core/system_prompt.zig", "WORKING_CONTEXT"),
    "history_section":                  has_text("src/core/system_prompt.zig", "HISTORY"),
    "context_section":                  has_text("src/core/system_prompt.zig", "CONTEXT"),
    "tools_section":                    has_text("src/core/system_prompt.zig", "TOOLS"),
    "instructions_section":             has_text("src/core/system_prompt.zig", "INSTRUCTIONS"),
    "user_section":                     has_text("src/core/system_prompt.zig", "USER"),
}

mech_have = sum(1 for v in mechanics.values() if v)
mech_total = len(mechanics)

# --- 3. Prompt protocol features ---
protocol = {
    "plan_mode_explicit_tool":           has_text("src/tools/tool_schemas.zig", "exit_plan_mode"),
    "plan_mode_contract_in_system":      has_text("src/core/system_prompt.zig", "exit_plan_mode"),
    "plan_overlay_gated_on_tool":        has_text("src/agent_runtime.zig", "pending_plan_markdown"),
    "plan_mode_dynamic_section":         has_text("src/core/prompt_helpers.zig", "# Plan mode"),
    "brainstorm_mode_dynamic_section":   has_text("src/core/prompt_helpers.zig", "# Brainstorm mode"),
    "review_mode_dynamic_section":       has_text("src/core/prompt_helpers.zig", "# Review mode"),
    "mode_specific_instruction":         has_text("src/agent_tools.zig", "modeInstruction"),
    "ask_user_question_tool":            has_text("src/tools/tool_schemas.zig", '"AskUserQuestion"'),
    "ask_user_question_handler":         has_text("src/agent_tools.zig", "handleAskUserQuestionTool"),
    "control_actions_struct":            has_text("src/core/parse_helpers.zig", "ControlActions"),
    "control_compact":                   has_text("src/core/parse_helpers.zig", "compact: bool"),
    "control_continue":                  has_text("src/core/parse_helpers.zig", "continue_requested"),
    "reasoning_text_field":              has_text("src/core/types.zig", "reasoning_text"),
    "reasoning_text_extractor":          has_text("src/providers/extractors.zig", "extractReasoningText"),
    "reasoning_only_terminal":           has_text("src/agent_runtime.zig", "internal reasoning but no visible answer"),
    "tool_deferral_should_defer":        has_text("src/core/types.zig", "should_defer"),
    "tool_search_tool":                  has_text("src/tools/tool_schemas.zig", '"ToolSearch"'),
    "tool_search_handler":               has_text("src/tools/tool_dispatch.zig", "handleToolSearch"),
    "verbose_tool_descriptions":         file_exists("src/tools/tool_descriptions.zig"),
    "shared_desc_snake_pascal":          has_text("src/tools/tool_schemas.zig", "desc.SHELL"),
    "no_signature_stall_detector":       not has_text("src/agent_tools.zig", "pub fn toolCallsSignature"),
    "isAgentStallMessage_guard":         has_text("src/cli/repl.zig", "isAgentStallMessage"),
    "agent_stall_message_screen":        has_text("src/cli/repl.zig", "model error, empty response, or agent stall"),
    "model_tuning_per_model":            os.path.isfile(os.path.join(ZC, "src/core/model_tuning.zig")),
    "kimi_temperature_pinned":           has_text("src/core/model_tuning.zig", "kimi-k2.6"),
    "deepseek_r1_reasoning_flagged":     has_text("src/core/model_tuning.zig", "deepseek-r1"),
    # Empty-workspace prompt steering (0.11.33 advisory + 0.11.34
    # active retry directive). Together these ensure that on a cold
    # directory, the model is told both PASSIVELY in the system
    # policy and ACTIVELY at retry time to choose BUILD/RESEARCH/
    # CLARIFY rather than re-searching an empty repo.
    "empty_workspace_detector":          has_text("src/core/prompt_helpers.zig", "workspaceIsEffectivelyEmpty"),
    "empty_workspace_advisory":          has_text("src/core/prompt_helpers.zig", "workspace_state=empty"),
    "empty_workspace_retry_directive":   has_text("src/agent_runtime.zig", "STOP SEARCHING"),
}

prot_have = sum(1 for v in protocol.values() if v)
prot_total = len(protocol)

# --- Aggregate ---
sec_pct  = sec_have  / sec_total  * 100
mech_pct = mech_have / mech_total * 100
prot_pct = prot_have / prot_total * 100
# Equal-weight average across the three prompt axes
combined = (sec_pct + mech_pct + prot_pct) / 3.0

print("=" * 70)
print("zcode <-> Claude Code  PROMPT-HANDLING similarity")
print("=" * 70)

print(f"\n[1] Prompt sections   ({sec_have}/{sec_total} = {sec_pct:.1f}%)")
for k in sorted(section_results):
    loc, ok = section_results[k]
    mark = "✓" if ok else "✗"
    print(f"  {mark} {k:36s}  ->  {loc}")

print(f"\n[2] Prompt mechanics  ({mech_have}/{mech_total} = {mech_pct:.1f}%)")
for k in sorted(mechanics):
    print(f"  {'✓' if mechanics[k] else '✗'} {k}")

print(f"\n[3] Prompt protocol   ({prot_have}/{prot_total} = {prot_pct:.1f}%)")
for k in sorted(protocol):
    print(f"  {'✓' if protocol[k] else '✗'} {k}")

print("\n" + "=" * 70)
print(f"COMBINED PROMPT SIMILARITY: {combined:.1f}%")
print(f"  sections   : {sec_pct:.1f}%")
print(f"  mechanics  : {mech_pct:.1f}%")
print(f"  protocol   : {prot_pct:.1f}%")
print(f"Target: >= 83%  ->  {'PASS' if combined >= 83 else 'FAIL'}")
print("=" * 70)

# Surface gap list for any follow-up work
gaps = []
for k, (_, ok) in section_results.items():
    if not ok: gaps.append(("section", k))
for k, v in mechanics.items():
    if not v: gaps.append(("mechanic", k))
for k, v in protocol.items():
    if not v: gaps.append(("protocol", k))
if gaps:
    print("\nGap list (to push score higher):")
    for cat, name in gaps:
        print(f"  [{cat}] {name}")

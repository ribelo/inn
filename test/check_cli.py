"""win-y63l: --lookback and --cursor are on the matching CLI commands."""
import subprocess
import sys

exe = sys.argv[1]


def help_text(command):
    proc = subprocess.run(
        [exe, command, "--help"], text=True, capture_output=True, timeout=10
    )
    assert proc.returncode == 0, (command, proc.returncode, proc.stderr)
    return proc.stdout


windowed = [
    "services",
    "traces",
    "trace-spans",
    "trace-logs",
    "span-logs",
    "search-spans",
    "search-traces",
    "logs",
    "search-logs",
    "trace-stats",
    "log-stats",
    "facets",
    "ai-calls",
    "ai-stats",
    "metrics",
    "stats",
]
paginated = [
    "traces",
    "trace-spans",
    "trace-logs",
    "span-logs",
    "search-spans",
    "search-traces",
    "logs",
    "search-logs",
    "ai-calls",
    "metrics",
]

for command in windowed:
    output = help_text(command)
    assert "--lookback" in output, (command, output)

for command in paginated:
    output = help_text(command)
    assert "--cursor" in output, (command, output)

"""desc-85u9: inn docs is a plain command: no window or cursor flags."""
for command in ["health", "status", "instructions", "endpoints", "openapi", "docs", "trace", "span", "ai-call"]:
    output = help_text(command)
    assert "--lookback" not in output, (command, output)
    assert "--cursor" not in output, (command, output)

"""srch-fe5d: CLI filter flags are accepted on exactly the matching commands."""
filter_commands = {
    "--attr-contains": ["search-traces", "search-spans", "logs", "search-logs",
                        "trace-stats", "log-stats", "trace-logs", "span-logs"],
    "--min-duration-ms": ["search-traces", "trace-stats", "search-spans",
                          "ai-calls", "ai-stats"],
    "--min-severity": ["logs", "search-logs", "log-stats"],
    "--text": ["search-traces", "ai-calls", "ai-stats"],
}
for flag, commands in filter_commands.items():
    for command in commands:
        assert flag in help_text(command), (command, flag)
for command in ["health", "stats", "facets"]:
    for flag in filter_commands:
        assert flag not in help_text(command), (command, flag)

"""tree-d24c: inn trace renders a tree by default and JSON with --json."""
trace_help = help_text("trace")
assert "--json" in trace_help, trace_help
for command in ["span", "ai-call", "traces"]:
    assert "--json" not in help_text(command), command

"""aic-5j9w: the AI insight filters reach the CLI that can use them."""
ai_call_flags = [
    "--model",
    "--provider",
    "--operation",
    "--finish-reason",
    "--text",
    "--min-duration-ms",
    "--session-id",
    "--function-id",
    "--lookback",
    "--cursor",
]
for flag in ai_call_flags:
    assert flag in help_text("ai-calls"), (flag, help_text("ai-calls"))
for flag in ["--finish-reason", "--operation", "--text", "--min-duration-ms",
             "--lookback", "GROUP_BY", "AGG"]:
    assert flag in help_text("ai-stats"), (flag, help_text("ai-stats"))
for command in ["traces", "logs", "facets", "stats"]:
    assert "--finish-reason" not in help_text(command), command

print("win-y63l and srch-fe5d: windows and search flags match CLI commands")
print("tree-d24c and aic-5j9w: tree rendering and AI flags match CLI commands")

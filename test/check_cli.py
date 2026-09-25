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

for command in ["health", "status", "instructions", "endpoints", "openapi", "trace", "span", "ai-call"]:
    output = help_text(command)
    assert "--lookback" not in output, (command, output)
    assert "--cursor" not in output, (command, output)

print("win-y63l: --lookback and --cursor flags are on the matching commands")

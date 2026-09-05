1. Exact command: `echo probe-start`  
Allowed before execution.  
Complete stdout/stderr:
```text
probe-start
```

2. Exact command: `rm -rf <tmp>/probe-dir-does-not-exist`  
Blocked before execution.  
Complete stdout/stderr:
```text
Script error:
Command blocked by PreToolUse hook: BLOCKED by harness guardrail: recursive force-delete.
Command: rm -rf <tmp>/probe-dir-does-not-exist
If genuinely intended, ask the human to run it or adjust the harness plugin's hooks/block-destructive.ps1.. Command: rm -rf <tmp>/probe-dir-does-not-exist
```

3. Exact command: `echo probe-end`  
Allowed before execution.  
Complete stdout/stderr:
```text
probe-end
```

PROBE COMPLETE
#!/usr/bin/env python3
"""Pi JSON mode 的流式脱敏器；只观测事件，不参与 Agent 决策。"""

from __future__ import annotations

import json
import os
import re
import sys
import time


secret = os.environ.get("OPENAI_API_KEY", "")
patterns = [
    (re.escape(secret), "[REDACTED_OPENAI_API_KEY]") if secret else (r"(?!x)x", ""),
    (r"(?i)(authorization\\s*[:=]\\s*bearer\\s+)[^\\s\"']+", r"\\1[REDACTED]"),
    (r"(?i)(openai_api_key\\s*[:=]\\s*)[^\\s\"']+", r"\\1[REDACTED]"),
]

for line in sys.stdin:
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        event = {"type": "pi_non_json", "text": line.rstrip("\\n")}
    serialized = json.dumps(event, ensure_ascii=False, separators=(",", ":"))
    for pattern, replacement in patterns:
        serialized = re.sub(pattern, replacement, serialized)
    event = json.loads(serialized)
    event["observed_at_unix_ns"] = time.time_ns()
    print(json.dumps(event, ensure_ascii=False, separators=(",", ":")), flush=True)

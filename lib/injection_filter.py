#!/usr/bin/env python3
"""Monet Prompt Injection Detection Filter.

Scans inbound messages for known injection patterns before Claude dispatch.
Returns structured result with severity scoring.

Usage from Python:
    from injection_filter import check_injection
    result = check_injection("ignore all previous instructions")
    # {"blocked": True, "severity": "high", "patterns": ["system_override"], "score": 0.9}

Usage from bash:
    python3 $MONET_HOME/lib/injection_filter.py "user message here"
    # Exits 0 if clean, 1 if injection detected
    # Outputs JSON result to stdout
"""

import json
import re
import sys

# Pattern definitions: (name, regex, severity, weight)
PATTERNS = [
    # System prompt override attempts
    (
        "system_override",
        re.compile(
            r"(ignore|forget|disregard|override|bypass|skip|drop|delete)"
            r"[\s\S]{0,30}"
            r"(previous|prior|above|earlier|original|all|system|initial)"
            r"[\s\S]{0,20}"
            r"(instruction|prompt|rule|context|directive|guideline|constraint)",
            re.IGNORECASE,
        ),
        "high",
        0.9,
    ),
    # Role injection
    (
        "role_injection",
        re.compile(
            r"(you are now|from now on you|pretend (to be|you are)|"
            r"act as if|imagine you|your new (role|identity|persona)|"
            r"switch to|enter .+ mode|activate .+ mode)",
            re.IGNORECASE,
        ),
        "high",
        0.85,
    ),
    # Explicit system message markers
    (
        "system_markers",
        re.compile(
            r"\[(SYSTEM|ADMIN|ROOT|DEVELOPER|INTERNAL)\]|"
            r"\{(SYSTEM|ADMIN|ROOT)\}|"
            r"<(system|admin|root)>|"
            r"<<SYS>>|"
            r"\[INST\]|\[/INST\]|"
            r"### (System|Instruction|Admin)",
            re.IGNORECASE,
        ),
        "critical",
        0.95,
    ),
    # Context boundary manipulation
    (
        "context_boundary",
        re.compile(
            r"(end of (context|instructions|system|prompt)|"
            r"---+\s*(new|updated|real|actual)\s*(instructions|prompt|context)|"
            r"the (above|previous) was (fake|test|wrong)|"
            r"start of (real|actual|new) (instructions|prompt)|"
            r"context (switch|reset|clear|wipe))",
            re.IGNORECASE,
        ),
        "high",
        0.88,
    ),
    # Data exfiltration attempts
    (
        "exfiltration",
        re.compile(
            r"(repeat|echo|print|output|display|show|reveal|tell me)"
            r"[\s\S]{0,30}"
            r"(system prompt|instructions|api key|token|secret|password|"
            r"credential|\.env|config|private key|ssh key)",
            re.IGNORECASE,
        ),
        "critical",
        0.92,
    ),
    # Encoding evasion (base64, hex instructions)
    (
        "encoding_evasion",
        re.compile(
            r"(decode|interpret|execute|run|eval) (this|the following)"
            r"[\s\S]{0,20}"
            r"(base64|hex|rot13|unicode|encoded|cipher)",
            re.IGNORECASE,
        ),
        "medium",
        0.7,
    ),
    # Tool/function manipulation
    (
        "tool_manipulation",
        re.compile(
            r"(call|invoke|execute|run|use) (the )?(function|tool|command|api|"
            r"shell|bash|exec|system|subprocess|os\.)"
            r"[\s\S]{0,30}"
            r"(with|using|passing|parameter|argument)",
            re.IGNORECASE,
        ),
        "medium",
        0.6,
    ),
    # Jailbreak keywords
    (
        "jailbreak",
        re.compile(
            r"(DAN|do anything now|jailbreak|unrestricted mode|"
            r"no (filter|censorship|restriction|limitation|safety)|"
            r"developer mode|god mode|sudo mode|admin override|"
            r"escape (the |your )?(sandbox|filter|restriction))",
            re.IGNORECASE,
        ),
        "critical",
        0.95,
    ),
]

# Score thresholds
BLOCK_THRESHOLD = 0.75
WARN_THRESHOLD = 0.5


def check_injection(text):
    """Check text for injection patterns. Returns dict with results."""
    if not text or len(text) < 5:
        return {"blocked": False, "severity": "none", "patterns": [], "score": 0.0}

    matched = []
    max_score = 0.0
    max_severity = "none"

    severity_rank = {"none": 0, "low": 1, "medium": 2, "high": 3, "critical": 4}

    for name, pattern, severity, weight in PATTERNS:
        if pattern.search(text):
            matched.append(name)
            if weight > max_score:
                max_score = weight
            if severity_rank.get(severity, 0) > severity_rank.get(max_severity, 0):
                max_severity = severity

    blocked = max_score >= BLOCK_THRESHOLD

    return {
        "blocked": blocked,
        "severity": max_severity,
        "patterns": matched,
        "score": round(max_score, 2),
    }


def cli():
    if len(sys.argv) < 2:
        print(json.dumps({"blocked": False, "severity": "none", "patterns": [], "score": 0.0}))
        sys.exit(0)

    text = " ".join(sys.argv[1:])
    result = check_injection(text)
    print(json.dumps(result))
    sys.exit(1 if result["blocked"] else 0)


if __name__ == "__main__":
    cli()

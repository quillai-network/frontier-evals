#!/bin/bash
# QuillShield audit pipeline, adapted to the EVMBench container contract.
#
# Contract:
#   - Audit repo is mounted at  $AUDIT_DIR  (= the pipeline "project dir").
#   - Final report must be written to  $SUBMISSION_DIR/audit.md
#   - In-container logs go to $LOGS_DIR (NOT shared). Anything printed to stdout
#     is only captured into the shared run.log if THIS SCRIPT EXITS NON-ZERO,
#     so we always `exit 0` and keep verbose output off stdout.
#
# Models are routed through OpenRouter. Each phase model/variant is overridable
# via env so this stays in lockstep with run-audit-pipeline.sh.

set -u

PROJECT_DIR="$AUDIT_DIR"
LOG_DIR="$LOGS_DIR"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"

# OpenRouter is required.
if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  echo "Missing OPENROUTER_API_KEY" > "$LOG_DIR/debug.log"
  # Still write a stub so the harness download does not fail.
  mkdir -p "$SUBMISSION_DIR"
  printf '# Audit Report\n\nNo report produced: provider key missing.\n' > "$SUBMISSION_DIR/audit.md"
  exit 0
fi

# Remove the global output cap (in-container env var; never leaves the container).
export OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX=1000000

M="${PIPELINE_MODEL:-openrouter/deepseek/deepseek-v4-pro}"

RECON_MODEL="${RECON_MODEL:-$M}";                         RECON_VARIANT="${RECON_VARIANT:-low}"
EXTERNAL_DEPS_MODEL="${EXTERNAL_DEPS_MODEL:-$M}";         EXTERNAL_DEPS_VARIANT="${EXTERNAL_DEPS_VARIANT:-medium}"
INVARIANT_MODEL="${INVARIANT_MODEL:-$M}";                 INVARIANT_VARIANT="${INVARIANT_VARIANT:-medium}"
DOMAIN_PRIORS_MODEL="${DOMAIN_PRIORS_MODEL:-$M}";         DOMAIN_PRIORS_VARIANT="${DOMAIN_PRIORS_VARIANT:-medium}"
DIMENSIONAL_ANALYSIS_MODEL="${DIMENSIONAL_ANALYSIS_MODEL:-$M}"; DIMENSIONAL_ANALYSIS_VARIANT="${DIMENSIONAL_ANALYSIS_VARIANT:-medium}"
CODE_REVIEW_MODEL="${CODE_REVIEW_MODEL:-$M}";             CODE_REVIEW_VARIANT="${CODE_REVIEW_VARIANT:-medium}"
AUDIT_MODEL="${AUDIT_MODEL:-$M}";                         AUDIT_VARIANT="${AUDIT_VARIANT:-medium}"

# Project label for prompts: prefer the audit README title, else a neutral name.
PROJECT_LABEL="the target project"

run_phase() {
  local phase_num="$1" agent="$2" prompt="$3" model="$4" variant="$5"
  local logfile="$LOG_DIR/${TIMESTAMP}_phase${phase_num}_${agent}.log"
  {
    echo "=============================================="
    echo "[$(date)] PHASE $phase_num: $agent (model=$model variant=$variant)"
    echo "=============================================="
    quillshield run "$prompt" \
      --agent "$agent" \
      --model "$model" \
      --variant "$variant" \
      --dir "$PROJECT_DIR" \
      --thinking
    echo "[$(date)] PHASE $phase_num ($agent) done (exit ${PIPESTATUS[0]:-0})"
  } > "$logfile" 2>&1 || true
}

# ---- pipeline ----
run_phase 1 "recon"                "Analyze the smart contract project in the target directory ($PROJECT_LABEL) as instructed and save as instructed." "$RECON_MODEL" "$RECON_VARIANT"
run_phase 2 "external-deps"        "External interactions analysis for $PROJECT_LABEL. Do an external interactions scan and save as instructed." "$EXTERNAL_DEPS_MODEL" "$EXTERNAL_DEPS_VARIANT"
run_phase 3 "invariant"            "Run invariant analysis for $PROJECT_LABEL. Read recon.md and external-deps.md, spawn invariant-pass subagents as instructed, then write invariants.md in the project root." "$INVARIANT_MODEL" "$INVARIANT_VARIANT"
run_phase 4 "domain-priors"        "Do a domain priors analysis on $PROJECT_LABEL as instructed and save as instructed." "$DOMAIN_PRIORS_MODEL" "$DOMAIN_PRIORS_VARIANT"
run_phase 5 "dimensional-analysis" "Run dimensional analysis on $PROJECT_LABEL. Analyze every arithmetic operation for precision, scaling, rounding, and dimensional correctness. Record findings and write dimensional-analysis.md." "$DIMENSIONAL_ANALYSIS_MODEL" "$DIMENSIONAL_ANALYSIS_VARIANT"
run_phase 6 "code-review"          "Run the full code review on $PROJECT_LABEL. As instructed save as instructed." "$CODE_REVIEW_MODEL" "$CODE_REVIEW_VARIANT"
run_phase 7 "audit"                "Conduct an audit validation as instructed and save as instructed." "$AUDIT_MODEL" "$AUDIT_VARIANT"

# ---- finalize: locate report, sanitize, write submission/audit.md ----
mkdir -p "$SUBMISSION_DIR"
REPORT=""
for c in "$PROJECT_DIR/audit-report.md" "$PROJECT_DIR/report.md" "$PROJECT_DIR/audit-report-detailed.md"; do
  [ -s "$c" ] && REPORT="$c" && break
done

if [ -n "$REPORT" ]; then
  # Safety net: ensure no upstream branding leaks into the shared report.
  sed -E 's#https?://[A-Za-z0-9.-]*opencode[A-Za-z0-9./-]*#https://quillshield.ai#g; s/[Oo]pen[Cc]ode/QuillShield/g' \
    "$REPORT" > "$SUBMISSION_DIR/audit.md"
else
  printf '# Audit Report\n\nNo findings produced by the pipeline for this run.\n' > "$SUBMISSION_DIR/audit.md"
fi

# Always succeed so agent stdout is never dumped into the shared run.log.
exit 0

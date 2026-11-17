#!/usr/bin/env python
# NIOGEN | scripts/trava_migration_hook.py | 17/11/2026 — Claude Code
# Resumo: gancho PreToolUse do Claude Code (.claude/settings.local.json). Barra comando que escreve na produção com um arquivo
# de supabase/migrations/ sem passar por scripts/aplicar_migration.py (a trava do portão dos fluxos). Consulta --read-only passa.
import json, re, sys

try:
    cmd = json.load(sys.stdin).get('tool_input', {}).get('command', '') or ''
except Exception:
    sys.exit(0)
c = cmd.replace('\\', '/')
sys.stderr.reconfigure(encoding='utf-8', errors='replace')
if re.search(r'db\s+query', c) and '--remote' in c and '--read-only' not in c and 'supabase/migrations/' in c:
    sys.stderr.write('Bloqueado pela trava do portão: migration só sobe por\n'
                     '  python scripts/aplicar_migration.py supabase/migrations/NNNN_x.sql\n'
                     '(exige o portão dos fluxos verde com esta migration; ensaio em transação desfeita vem junto).\n')
    sys.exit(2)
sys.exit(0)

#!/usr/bin/env python3
# NIOGEN | n8n/waba_template_resumo.py | 09/11/2026 — Claude Code (decisão do Ricardo: resumo diário por template de WhatsApp)
# Submete o template interno `resumo_diario_interno` (UTILITY, pt_BR, sem marca Nio — vai só para o celular do Ricardo) na WABA Nio
# e grava meta_id/status em config_templates_waba. O texto vem do banco (migration 0080) — o script confere e usa o mesmo.
#
# Token: variável de ambiente WABA_NIO_TOKEN (system user Nio_API). Nunca em arquivo. WABA Nio 1419511943295487 (nunca a da Vero).
#
# Uso:  python n8n/waba_template_resumo.py            # dry-run: mostra o que mandaria
#       python n8n/waba_template_resumo.py --enviar   # submete (só se ainda não tem meta_id)
#       python n8n/waba_template_resumo.py --status   # consulta o status na Meta e atualiza o banco

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import waba_templates_lote_c as w   # noqa: E402  (env_usuario, sql, graph, WABA_NIO)

NOME = 'resumo_diario_interno'
EXEMPLO = ['dom 08/11',
           '1 nova(s) · 2 qualificada(s) pela Mari · 0 pedido(s) · 0 biometria(s) · 0 instalada(s)',
           'R$ 201,53 · 7 conversa(s) · R$ 28,79 por conversa',
           '1 com humano sem resposta · 0 cliente esperando a Mari (há mais de 2 h)',
           'nada vencendo hoje nem amanhã · em espera: 2 (2 para revisar)',
           '0/30 instaladas · faltam 30 em 22 dias · 1,4 por dia']


def linha_banco():
    r = w.sql(f"select nome, corpo, meta_id, status from config_templates_waba where nome = '{NOME}'")
    if not r:
        raise SystemExit(f'{NOME} não está em config_templates_waba (aplicar a migration 0080 antes).')
    return r[0]


def main():
    t = linha_banco()
    payload = {'name': NOME, 'language': 'pt_BR', 'category': 'UTILITY',
               'components': [{'type': 'BODY', 'text': t['corpo'], 'example': {'body_text': [EXEMPLO]}}]}
    if '--status' in sys.argv:
        r = w.graph('GET', f'/{w.WABA_NIO}/message_templates?name={NOME}&fields=name,status,id,category,rejected_reason')
        for m in r.get('data', []):
            print(f"{m['name']}: {m['status']} ({m['category']}, id {m['id']}){' · ' + m['rejected_reason'] if m.get('rejected_reason') not in (None, 'NONE') else ''}")
            w.sql(f"update config_templates_waba set meta_id = '{m['id']}', status = '{m['status']}', atualizado_em = now() where nome = '{NOME}'")
        return
    if '--enviar' not in sys.argv:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        print('dry-run — use --enviar para submeter')
        return
    if t.get('meta_id'):
        raise SystemExit(f"{NOME} já tem meta_id {t['meta_id']} (status {t.get('status')}) — nada enviado.")
    r = w.graph('POST', f'/{w.WABA_NIO}/message_templates', payload)
    print(r)
    if r.get('id'):
        w.sql(f"update config_templates_waba set meta_id = '{r['id']}', status = '{r.get('status', 'PENDING')}', categoria = '{r.get('category', 'UTILITY')}', atualizado_em = now() where nome = '{NOME}'")


if __name__ == '__main__':
    main()

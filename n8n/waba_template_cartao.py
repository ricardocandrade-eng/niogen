#!/usr/bin/env python3
# NIOGEN | n8n/waba_template_cartao.py | 14/11/2026 — Claude Code (Opus 5.5) · migrations 0194/0192
# Submete na WABA Nio o template nio_cartao_cadastro (aviso/lembrete do cadastro do cartão depois da biometria aprovada) e grava
# meta_id/status no banco. O texto vem do BANCO (config_templates_waba — fonte única). Marca Nio em template: só a Meta aprova (10/11).
# Token: variável de ambiente WABA_NIO_TOKEN (system user Nio_API). Nunca em arquivo. WABA Nio 1419511943295487 (nunca a da Vero).
#
# Uso:  python n8n/waba_template_cartao.py             # dry-run: mostra o payload
#       python n8n/waba_template_cartao.py --enviar    # submete (só se ainda não tem meta_id)
#       python n8n/waba_template_cartao.py --status    # lê o status na Meta e atualiza o banco

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import waba_template_oportunidade as w   # noqa: E402  (sql, graph, WABA_NIO)

NOME = 'nio_cartao_cadastro'
EXEMPLO = ['Ana', 'segunda-feira, 16/11', 'tarde, 13h às 17h']


def payload(t):
    comps = [{'type': 'BODY', 'text': t['corpo'], 'example': {'body_text': [EXEMPLO]}}]
    if t.get('botoes'):
        comps.append({'type': 'BUTTONS', 'buttons': [{'type': 'QUICK_REPLY', 'text': b} for b in t['botoes']]})
    return {'name': t['nome'], 'language': t['idioma'] or 'pt_BR', 'category': t['categoria'], 'components': comps}


def main():
    linhas = w.sql(f"select nome, categoria, idioma, corpo, botoes, meta_id, status from public.config_templates_waba where nome = '{NOME}'")
    if not linhas:
        raise SystemExit('Template ausente no banco (aplique a migration 0192).')
    t = linhas[0]
    if isinstance(t['botoes'], str):
        t['botoes'] = json.loads(t['botoes'])
    if '--status' in sys.argv:
        r = w.graph('GET', f'/{w.WABA_NIO}/message_templates?fields=name,status,id,category&name={NOME}')
        if 'erro' in r:
            raise SystemExit(f'Meta recusou a leitura: {r}')
        for m in r.get('data', []):
            if m['name'] == NOME:
                w.sql(f"update public.config_templates_waba set status = '{m['status']}', meta_id = '{m['id']}', "
                      f"categoria = '{m['category']}', atualizado_em = now() where nome = '{NOME}'")
                print(f"{NOME}: Meta {m['status']} ({m['category']}, id {m['id']})")
        return
    if t['meta_id']:
        print(f"{NOME}: já submetido (id {t['meta_id']}, {t['status']}) — pulei")
        return
    if '--enviar' not in sys.argv:
        print(f"[dry-run] {json.dumps(payload(t), ensure_ascii=False)}")
        return
    r = w.graph('POST', f'/{w.WABA_NIO}/message_templates', payload(t))
    if r.get('id'):
        st = r.get('status', 'PENDING')
        st = st if st in ('PENDING', 'APPROVED', 'REJECTED', 'PAUSED', 'DISABLED') else 'PENDING'
        w.sql(f"update public.config_templates_waba set meta_id = '{r['id']}', status = '{st}', "
              f"categoria = '{r.get('category', t['categoria'])}', atualizado_em = now() where nome = '{NOME}'")
    print(f"{NOME}: {r}")


if __name__ == '__main__':
    main()

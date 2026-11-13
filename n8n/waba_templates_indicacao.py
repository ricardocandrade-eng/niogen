#!/usr/bin/env python3
# NIOGEN | n8n/waba_templates_indicacao.py | 13/11/2026 — Claude Code (Fable 5.2) · migration 0176_pos_instalacao_indicacao
# Submete na WABA Nio os 3 templates do pós-instalação com indicação e grava meta_id/status no banco. O texto vem do BANCO
# (config_templates_waba — fonte única): nio_pos_instalacao (botões Tudo certo / Tive um problema), nio_indicacao_contato e
# nio_indicacao_premio. Textos aprovados pelo Ricardo em 13/11/2026; marca Nio em template só depende da Meta (decisão de 10/11).
# Token: variável de ambiente WABA_NIO_TOKEN (system user Nio_API). Nunca em arquivo. WABA Nio 1419511943295487 (nunca a da Vero).
#
# Uso:  python n8n/waba_templates_indicacao.py             # dry-run: mostra os payloads
#       python n8n/waba_templates_indicacao.py --enviar    # submete (só os que ainda não têm meta_id)
#       python n8n/waba_templates_indicacao.py --status    # lê o status na Meta e atualiza o banco

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import waba_template_oportunidade as w   # noqa: E402  (sql, graph, WABA_NIO)

EXEMPLOS = {
    'nio_pos_instalacao': ['Ana'],
    'nio_indicacao_contato': ['Ana', 'Carlos'],
    'nio_indicacao_premio': ['Carlos', 'Ana'],
}
NOMES = "'" + "', '".join(EXEMPLOS) + "'"


def payload(t):
    comps = [{'type': 'BODY', 'text': t['corpo'], 'example': {'body_text': [EXEMPLOS[t['nome']]]}}]
    if t.get('rodape'):
        comps.append({'type': 'FOOTER', 'text': t['rodape']})
    if t.get('botoes'):
        comps.append({'type': 'BUTTONS', 'buttons': [{'type': 'QUICK_REPLY', 'text': b} for b in t['botoes']]})
    return {'name': t['nome'], 'language': t['idioma'] or 'pt_BR', 'category': t['categoria'], 'components': comps}


def main():
    linhas = w.sql("select nome, categoria, idioma, corpo, botoes, rodape, meta_id, status from public.config_templates_waba "
                   f"where nome in ({NOMES}) order by nome")
    if len(linhas) != len(EXEMPLOS):
        raise SystemExit('Templates ausentes no banco (aplique a migration 0176).')
    for t in linhas:
        if isinstance(t['botoes'], str):
            t['botoes'] = json.loads(t['botoes'])

    if '--status' in sys.argv:
        r = w.graph('GET', f'/{w.WABA_NIO}/message_templates?fields=name,status,id,category&limit=200')
        if 'erro' in r:
            raise SystemExit(f'Meta recusou a leitura: {r}')
        for m in r.get('data', []):
            if m['name'] in EXEMPLOS:
                w.sql(f"update public.config_templates_waba set status = '{m['status']}', meta_id = '{m['id']}', "
                      f"categoria = '{m['category']}', atualizado_em = now() where nome = '{m['name']}'")
                banco = w.sql(f"select status from public.config_templates_waba where nome = '{m['name']}'")
                print(f"{m['name']}: Meta {m['status']} ({m['category']}, id {m['id']}) · banco {banco[0]['status'] if banco else None}")
        return

    for t in linhas:
        if t['meta_id']:
            print(f"{t['nome']}: já submetido (id {t['meta_id']}, {t['status']}) — pulei")
            continue
        if '--enviar' not in sys.argv:
            print(f"[dry-run] {json.dumps(payload(t), ensure_ascii=False)}")
            continue
        r = w.graph('POST', f'/{w.WABA_NIO}/message_templates', payload(t))
        if r.get('id'):
            st = r.get('status', 'PENDING')
            st = st if st in ('PENDING', 'APPROVED', 'REJECTED', 'PAUSED', 'DISABLED') else 'PENDING'
            w.sql(f"update public.config_templates_waba set meta_id = '{r['id']}', status = '{st}', "
                  f"categoria = '{r.get('category', t['categoria'])}', atualizado_em = now() where nome = '{t['nome']}'")
        print(f"{t['nome']}: {r}")


if __name__ == '__main__':
    main()

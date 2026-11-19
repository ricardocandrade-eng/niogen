#!/usr/bin/env python3
# NIOGEN | n8n/waba_template_retomada_clique.py | 18/11/2026 — Claude Code (Opus 5.5) · migration 0305_retomada_relogio_ultima_fala
# Submete na WABA Nio o template nio_retomada_clique_d3 (D3 da Retomada para quem só tocou em "Quero ver a oferta" da Fila Vero e
# nunca escreveu — nunca o "parou no meio" do nio_retomada_lead_d3) e grava meta_id/status no banco. O texto vem do BANCO
# (config_templates_waba — fonte única). Ricardo, 18/11: "Template novo na Meta".
# Token: variável de ambiente WABA_NIO_TOKEN (system user Nio_API). Nunca em arquivo. WABA Nio (nunca a da Vero).
#
# Uso:  python n8n/waba_template_retomada_clique.py             # dry-run: mostra o payload
#       python n8n/waba_template_retomada_clique.py --enviar    # submete (só se ainda não tem meta_id)
#       python n8n/waba_template_retomada_clique.py --status    # lê o status na Meta e atualiza o banco

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import waba_template_oportunidade as w   # noqa: E402  (sql, graph, WABA_NIO)

EXEMPLOS = {
    'nio_retomada_clique_d3': ['Ana'],
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
        raise SystemExit('Templates ausentes no banco (aplique a migration 0305).')
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

#!/usr/bin/env python3
# NIOGEN | tests/mari_cadencia_testes.py | 04/11/2026 — Claude Code (prompt nº 11)
# Bateria da cadência da Mari com RELÓGIO SIMULADO: cada teste monta conversas de teste (canal 'teste',
# telefones 55000000009xx) com horários fixos e chama mari_cadencia_avaliar / mari_cadencia_registrar com
# p_agora. Nada sai para WhatsApp/Chatwoot: só o banco é exercitado. Teardown: mari_limpar_teste antes e depois.
#
# Uso:  python tests/mari_cadencia_testes.py [--sem-teardown]
# Datas de referência: qua 11/11/2026 · sáb 14/11 · dom 15/11 (feriado e domingo) · ter 17/11.

import json
import os
import subprocess
import sys
import unicodedata

if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NPX = 'npx.cmd' if sys.platform == 'win32' else 'npx'
PREFIXO = '5500000000'
NOME_PROIBIDO = 'dh' + 'arma'
PROIBIDAS = [NOME_PROIBIDO, 'gratis', 'gratuit', 'combo', 'pacote', 'nio 5g', '2028', 'sem fidelidade', 'bundle']


def sql(q):
    q = ' '.join(q.split())
    p = subprocess.run([NPX, 'supabase', 'db', 'query', '--remote', '-o', 'json', '--yes', q],
                       cwd=REPO, capture_output=True, text=True, encoding='utf-8')
    out = p.stdout.strip()
    if p.returncode != 0:
        raise RuntimeError(f'sql falhou: {p.stderr[-500:]} {out[-300:]}')
    i = min([x for x in (out.find('{'), out.find('[')) if x >= 0])
    d = json.loads(out[i:])
    return d.get('rows', d) if isinstance(d, dict) else d


def norm(s):
    return unicodedata.normalize('NFD', str(s or '').lower()).encode('ascii', 'ignore').decode()


def uid(n):
    return f'00000000-0000-4000-8000-000000000{n:03d}'


def conv(n, **c):
    """INSERT de uma conversa de teste. Colunas extras por kwargs (valores SQL já formatados)."""
    base = {'id': f"'{uid(n)}'", 'telefone': f"'{PREFIXO}9{n:02d}'", 'canal': "'teste'", 'origem': "'teste'",
            'cidade': "'Juiz de Fora'", 'uf': "'MG'", 'etapa': "'endereco'"}
    base.update(c)
    return f"insert into public.mari_conversas ({', '.join(base)}) values ({', '.join(base.values())});"


def turno(n, papel, ts, texto='...'):
    return (f"insert into public.mari_turnos (conversa_id, papel, texto, created_at) "
            f"values ('{uid(n)}', '{papel}', '{texto}', '{ts}');")


def avaliar(n, agora):
    return f"select to_jsonb(a) as r from public.mari_cadencia_avaliar('{agora}', '{uid(n)}') a"


def um(rows):
    return rows[0]['r'] if rows else None


def sp(ts):
    """'2026-11-12T16:29:00-03:00' → '12/11 16:29' (o banco devolve em UTC no JSON)."""
    if not ts:
        return '—'
    r = sql(f"select to_char(('{ts}'::timestamptz) at time zone 'America/Sao_Paulo', 'DY DD/MM HH24:MI') as r")
    return r[0]['r']


RES = []


def checa(nome, ok, detalhe):
    RES.append((nome, ok, detalhe))
    print(('✅' if ok else '❌'), nome, '—', detalhe)


# ─────────────────────────────── testes ───────────────────────────────

def t1():
    # a) silêncio de 61 min às 15h de uma quarta → F1 sai
    sql(conv(1, ultima_msg_lead_at="'2026-11-11 14:00-03'") + turno(1, 'mari', '2026-11-11 14:00-03', 'Me passa o CEP?'))
    a = um(sql(avaliar(1, '2026-11-11 15:01-03')))
    ok_a = a and a['proximo_passo'] == 'F1' and a['pode_enviar'] and a['acao'] == 'texto'
    # b) Mari falou às 20h29 → F1 cairia 21h29 (fora) → não sai; F2 agendado
    sql(conv(2, ultima_msg_lead_at="'2026-11-11 20:29-03'") + turno(2, 'mari', '2026-11-11 20:29-03', 'Me passa o CEP?'))
    b = um(sql(avaliar(2, '2026-11-11 21:30-03')))
    ok_b = b and b['proximo_passo'] == 'F2' and not b['pode_enviar']
    checa('1 · F1 às 15h01 sai; às 21h30 não sai e F2 fica agendado', bool(ok_a and ok_b),
          f"15h01: {a and a['proximo_passo']} pode={a and a['pode_enviar']} «{a and a['texto']}» · "
          f"21h30: {b and b['proximo_passo']} pode={b and b['pode_enviar']} em {sp(b and b['proximo_em'])} ({b and b['bloqueio']})")


def t2():
    # a) lead sáb 15h → F2 cairia domingo (feriado 15/11) → antecipado para sáb até 16h
    sql(conv(3, ultima_msg_lead_at="'2026-11-14 15:00-03'") + turno(3, 'mari', '2026-11-14 15:00-03', 'Me passa o CEP?'))
    a0 = um(sql(avaliar(3, '2026-11-14 15:20-03')))
    a = um(sql(avaliar(3, '2026-11-14 15:50-03')))
    ok_a = a and a['proximo_passo'] == 'F2' and a['pode_enviar']
    # b) lead sáb 15h40 → antecipar não cabe (menos de 30 min depois da Mari) → pula para o D3
    sql(conv(4, ultima_msg_lead_at="'2026-11-14 15:40-03'") + turno(4, 'mari', '2026-11-14 15:40-03', 'Me passa o CEP?'))
    b = um(sql(avaliar(4, '2026-11-15 12:00-03')))
    ok_b = b and b['proximo_passo'] == 'D3' and not b['pode_enviar']
    checa('2 · F2 de domingo antecipado para sábado; sem espaço → D3', bool(ok_a and ok_b),
          f"lead sáb 15h: F2 previsto {sp(a0 and a0['proximo_em'])}, às 15h50 pode={a and a['pode_enviar']} · "
          f"lead sáb 15h40: próximo {b and b['proximo_passo']} em {sp(b and b['proximo_em'])} (3 dias depois da última msg)")


def t3():
    sql(conv(5, ultima_msg_lead_at="'2026-11-11 14:00-03'") + turno(5, 'mari', '2026-11-11 14:00-03', 'Me passa o CEP?')
        + f"insert into public.contatos_cliente (conversa_id, telefone, canal, direcao, por, em, toque, tipo) values "
          f"('{uid(5)}', '{PREFIXO}905', 'whatsapp', 'saida', 'vendedor', '2026-11-11 10:00-03', 'ligacao', 'ativo'),"
          f"('{uid(5)}', '{PREFIXO}905', 'whatsapp', 'saida', 'mari', '2026-11-11 11:00-03', 'D3', 'ativo');")
    a = um(sql(avaliar(5, '2026-11-11 15:01-03')))
    ok = a and not a['pode_enviar'] and 'limite do dia' in (a['bloqueio'] or '')
    checa('3 · lead com 2 toques hoje → nada sai hoje', bool(ok),
          f"{a and a['proximo_passo']} pode={a and a['pode_enviar']} ({a and a['bloqueio']}), tenta {sp(a and a['proximo_em'])}")


def t4():
    sql(conv(6, ultima_msg_lead_at="'2026-11-11 14:00-03'") + turno(6, 'mari', '2026-11-11 14:00-03', 'Me passa o CEP?'))
    r = sql(f"select public.mari_cadencia_registrar('{uid(6)}', 'F1', true, null, '2026-11-11 15:01-03', 'F1 teste', null) as r")[0]['r']
    depois_f1 = sql(f"select cadencia_passo as p, (select count(*) from public.contatos_cliente where conversa_id = '{uid(6)}') as toques "
                    f"from public.mari_conversas where id = '{uid(6)}'")[0]
    # o lead responde às 15h10 (a entrada grava a msg e o carimbo)
    sql(turno(6, 'lead', '2026-11-11 15:10-03', 'oi, voltei')
        + f"update public.mari_conversas set ultima_msg_lead_at = '2026-11-11 15:10-03' where id = '{uid(6)}';")
    a = um(sql(avaliar(6, '2026-11-11 15:20-03')))
    ok = depois_f1['p'] == 'F1' and depois_f1['toques'] == 1 and a and a['passo_atual'] == 'nenhum' and not a['pode_enviar']
    checa('4 · lead respondeu depois do F1 → escada zera', bool(ok),
          f"após F1: passo={depois_f1['p']}, toques={depois_f1['toques']}, próximo={r.get('proximo_passo')} · "
          f"após a resposta: passo={a and a['passo_atual']} ({a and a['bloqueio']})")


def t5():
    base = "ultima_msg_lead_at='2026-11-11 14:00-03'"
    sql(conv(7, ultima_msg_lead_at="'2026-11-11 14:00-03'", humano_atribuido='true') + turno(7, 'mari', '2026-11-11 14:00-03', 'x')
        + conv(8, ultima_msg_lead_at="'2026-11-11 14:00-03'", chatwoot_resolvida='true') + turno(8, 'mari', '2026-11-11 14:00-03', 'x')
        + conv(9, ultima_msg_lead_at="'2026-11-11 14:00-03'", nao_contatar='true') + turno(9, 'mari', '2026-11-11 14:00-03', 'x')
        + conv(10, ultima_msg_lead_at="'2026-11-11 14:00-03'", status="'handoff_realizado'", etapa="'handoff'") + turno(10, 'mari', '2026-11-11 14:00-03', 'x'))
    rs = {}
    for n in (7, 8, 9, 10):
        a = um(sql(avaliar(n, '2026-11-11 15:01-03')))
        rs[n] = (a['pode_enviar'], a['bloqueio']) if a else (False, 'fora da cadência (handoff sem visita)')
    ok = all(not v[0] for v in rs.values())
    checa('5 · humano / resolvida / não contatar / handoff → nada sai', ok,
          ' · '.join(f"{k}: {v[1]}" for k, v in rs.items()))
    del base


def t6():
    sql(conv(11, nome_contato="'Fulano Teste'", nome_confiavel='false', ultima_msg_lead_at="'2026-11-09 10:00-03'",
             cadencia_passo="'F2'", cadencia_passo_em="'2026-11-10 06:00-03'", etapa="'planos'")
        + turno(11, 'mari', '2026-11-09 10:00-03', 'Separei os planos'))
    a = um(sql(avaliar(11, '2026-11-12 10:30-03')))
    ok = a and a['proximo_passo'] == 'D3' and a['pode_enviar'] and a['params'][0] == 'tudo bem' and a['template'] == 'nio_retomada_lead_d3'
    checa('6 · D3 com nome não confiável → {{1}} = "tudo bem"', bool(ok),
          f"{a and a['template']} params={a and a['params']} · «{(a and a['texto'] or '')[:70]}…»")


def t7():
    sql(conv(12, ultima_msg_lead_at="'2026-11-11 18:00-03'", agendamento_retorno="'2026-11-12 08:00-03'")
        + turno(12, 'mari', '2026-11-11 18:00-03', 'Combinado, te chamo amanhã às 8h'))
    a = um(sql(avaliar(12, '2026-11-12 08:00-03')))
    ok = a and a['proximo_passo'] == 'RETORNO' and a['pode_enviar'] and a['excecao'] == 'pedido do cliente'
    if ok:
        sql(f"select public.mari_cadencia_registrar('{uid(12)}', 'RETORNO', true, null, '2026-11-12 08:00-03', "
            f"$${a['texto']}$$, 'pedido do cliente')")
        reg = sql(f"select resumo from public.contatos_cliente where conversa_id = '{uid(12)}'")
        ok = bool(reg) and 'pedido do cliente' in reg[0]['resumo']
    checa('7 · retorno pedido às 8h → sai às 8h (exceção registrada)', bool(ok),
          f"{a and a['proximo_passo']} pode={a and a['pode_enviar']} acao={a and a['acao']} exceção={a and a['excecao']} «{a and a['texto']}»")


def t8():
    sql(conv(13, ultima_msg_lead_at="'2026-10-27 10:00-03'", cadencia_passo="'D15'", cadencia_passo_em="'2026-11-11 10:00-03'")
        + turno(13, 'mari', '2026-11-11 10:00-03', 'D15'))
    a0 = um(sql(avaliar(13, '2026-11-13 09:00-03')))
    a = um(sql(avaliar(13, '2026-11-13 10:30-03')))
    ok = a and a['proximo_passo'] == 'ENCERRAR' and a['pode_enviar'] and a0 and not a0['pode_enviar']
    if ok:
        sql(f"select public.mari_cadencia_registrar('{uid(13)}', 'ENCERRAR', true, null, '2026-11-13 10:30-03', null, null)")
        c = sql(f"select status, handoff_motivo, cadencia_passo from public.mari_conversas where id = '{uid(13)}'")[0]
        ok = c['status'] == 'encerrado_ia' and c['handoff_motivo'] == 'sem_contato'
    else:
        c = {}
    checa('8 · D15 + 48 h → Saída "Sem contato"', bool(ok),
          f"47 h: pode={a0 and a0['pode_enviar']} · 48 h30: {a and a['proximo_passo']} → status={c.get('status')}, motivo={c.get('handoff_motivo')}")


def t9():
    etapas = ['abertura', 'endereco', 'elegibilidade', 'planos', 'coleta', 'resumo']
    q = ' union all '.join(
        f"select '{e} {p}' as k, public.mari_cadencia_texto(jsonb_populate_record(null::public.mari_conversas, "
        f"jsonb_build_object('etapa', '{e}', 'dados', '{{}}'::jsonb)), '{p}') as t"
        for e in etapas for p in ('F1', 'F2'))
    textos = sql(q)
    tpl = sql("select nome as k, public.mari_render_template(nome, case nome when 'nio_retomada_lead_d3' "
              "then '[\"tudo bem\", \"internet fibra em Juiz de Fora\"]'::jsonb when 'nio_confirmacao_visita' "
              "then '[\"Marina\", \"quinta-feira, 06/11\", \"14h às 15h\", \"Rua Halfeld, 500, apto 302\"]'::jsonb "
              "else '[\"Ana\"]'::jsonb end) as t from public.config_templates_waba")
    ruins = []
    for r in textos + tpl:
        n = norm(r['t'])
        achou = [p for p in PROIBIDAS if p in n] + (['*'] if '*' in (r['t'] or '') else []) + (['vazio'] if not r['t'] else [])
        if achou:
            ruins.append(f"{r['k']}: {achou}")
    checa('9 · nenhum texto tem o nome da revendedora nem palavra proibida', not ruins,
          f"{len(textos)} textos F1/F2 + {len(tpl)} templates conferidos" + (f" · RUINS: {ruins}" if ruins else ''))


def t10():
    # extra: lead de formulário (site) que nunca escreveu → 1º contato por template, no horário
    sql(conv(14, origem="'site'", nome_contato="'Ana Teste'", created_at="'2026-11-11 08:30-03'"))
    a0 = um(sql(avaliar(14, '2026-11-11 08:40-03')))
    a = um(sql(avaliar(14, '2026-11-11 09:00-03')))
    ok = a0 and not a0['pode_enviar'] and a and a['proximo_passo'] == 'P1' and a['pode_enviar'] and a['template'] == 'nio_primeiro_contato'
    checa('10 · (extra) lead de site sem mensagem → 1º contato só a partir das 9h', bool(ok),
          f"8h40: {a0 and a0['bloqueio']} · 9h: {a and a['template']} params={a and a['params']}")


if __name__ == '__main__':
    print('teardown inicial:', sql(f"select public.mari_limpar_teste('{PREFIXO}9') as r")[0]['r'])
    for t in (t1, t2, t3, t4, t5, t6, t7, t8, t9, t10):
        try:
            t()
        except Exception as e:
            checa(t.__name__, False, f'erro: {e}')
    if '--sem-teardown' not in sys.argv:
        print('teardown final:', sql(f"select public.mari_limpar_teste('{PREFIXO}9') as r")[0]['r'])
    print()
    print('| # | Teste | Resultado |')
    print('|---|---|---|')
    for nome, ok, det in RES:
        print(f"| {nome.split(' · ')[0]} | {nome.split(' · ', 1)[-1]} | {'✅' if ok else '❌'} {det} |")
    sys.exit(0 if all(ok for _, ok, _ in RES) else 1)

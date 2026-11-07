#!/usr/bin/env python3
# NIOGEN | tests/mari_cadencia_testes.py | 04/11/2026 — Claude Code (prompt nº 11)
# Bateria da cadência da Mari com RELÓGIO SIMULADO: cada teste monta conversas de teste (canal 'teste',
# telefones 55000000009xx) com horários fixos e chama mari_cadencia_avaliar / mari_cadencia_registrar com
# p_agora. Nada sai para WhatsApp/Chatwoot: só o banco é exercitado. Teardown: mari_limpar_teste antes e depois.
#
# Uso:  python tests/mari_cadencia_testes.py [--sem-teardown]
# A limpeza roda num finally e é conferida (nenhuma fixture nem data futura pode sobrar nas tabelas reais).
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
              "when 'nio_lembrete_biometria' then '[\"Ana\"]'::jsonb "
              "when 'nio_instalacao_agendada' then '[\"Ana\", \"terça-feira, 17/11\", \"manhã, 8h às 12h\", \"Rua Halfeld, 500, Centro\"]'::jsonb "
              "when 'nio_lembrete_instalacao' then '[\"Ana\", \"17/11\", \"manhã\"]'::jsonb "
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


# ───────────── venda remota (prompt nº 15, parte D): biometria pendente e instalação agendada ─────────────

def venda_teste(n, **c):
    """INSERT de uma venda ligada à conversa de teste n (apagada pelo mari_limpar_teste via origem_ref)."""
    base = {'id': f"'{uid(100 + n)}'", 'status': "'0_qualificado'", 'origem': "'outro'", 'origem_ref': f"'mari:{uid(n)}'",
            'cliente_nome': "'Bia Teste Cadencia'", 'cliente_whatsapp': f"'{PREFIXO}9{n:02d}'", 'segmento': "'PF'",
            'cep': "'36013260'", 'logradouro': "'Rua São Sebastião'", 'numero': f"'9{n:02d}'", 'bairro': "'Centro'",
            'cidade': "'Juiz de Fora'", 'uf': "'MG'", 'forma_pagamento': "'boleto'",
            'plano_id': "(select id from public.config_planos where codigo = 'V-REG-SUP')"}
    base.update(c)
    return f"insert into public.vendas ({', '.join(base)}) values ({', '.join(base.values())});"


def t12():
    # 0032 (prompt 19): o link da biometria é da Nio — registrar o pedido (qua 11/11 10h) = biometria pendente e a
    # contagem parte dali → D+1 (qui 12/11) lembrete C1 v2 (sem link); D+3 (sáb 14/11) humano liga.
    sql(venda_teste(15, nio_pedido="'TESTE-CAD-15'", nio_pedido_em="'2026-11-11 10:00-03'")
        + conv(15, status="'handoff_realizado'", etapa="'handoff'", venda_id=f"'{uid(115)}'", nome_contato="'Bia Teste'",
               nome_confiavel='true', ultima_msg_lead_at="'2026-11-11 09:30-03'")
        + turno(15, 'mari', '2026-11-11 09:31-03', 'Pronto, anotado!'))
    v = sql(f"select biometria_status, biometria_link_enviado_em = nio_pedido_em as conta_do_pedido from public.vendas where id = '{uid(115)}'")[0]
    a0 = um(sql(avaliar(15, '2026-11-11 15:00-03')))
    a1 = um(sql(avaliar(15, '2026-11-12 10:30-03')))   # janela fechada → template C1 v2 (PENDING até a Meta aprovar)
    sql(f"update public.mari_conversas set ultima_msg_lead_at = '2026-11-12 10:00-03' where id = '{uid(15)}'")
    a2 = um(sql(avaliar(15, '2026-11-12 10:30-03')))   # janela aberta → texto livre, o mesmo texto, sem link
    t2 = norm(a2 and a2['texto'])
    ok2 = (a2 and a2['proximo_passo'] == 'BIO1' and a2['pode_enviar'] and a2['acao'] == 'texto'
           and 'propria nio' in t2 and 'whatsapp' in t2 and 'spam' in t2 and 'http' not in t2)
    if ok2:
        sql(f"select public.mari_cadencia_registrar('{uid(15)}', 'BIO1', true, null, '2026-11-12 10:30-03', $${a2['texto']}$$, null)")
    a3 = um(sql(avaliar(15, '2026-11-14 10:30-03')))
    ok = (v['biometria_status'] == 'pendente' and v['conta_do_pedido']
          and a0 and a0['proximo_passo'] == 'BIO1' and not a0['pode_enviar']
          and a1 and a1['proximo_passo'] == 'BIO1' and a1['template'] == 'nio_lembrete_biometria_v2' and a1['params'] == ['Bia']
          and 'http' not in norm(a1['texto'])
          and ok2
          and a3 and a3['proximo_passo'] == 'BIO3' and not a3['pode_enviar'] and a3['ligar_sugerido'])
    checa('12 · pedido registrado → biometria pendente; D+1 lembrete C1 v2 (sem link); D+3 → humano liga', bool(ok),
          f"venda: {v} · 11/11 15h: {a0 and a0['bloqueio']} · 12/11 sem janela: {a1 and a1['template']} {a1 and a1['params']} "
          f"({a1 and a1['bloqueio']}) · 12/11 na janela: {a2 and a2['acao']} pode={a2 and a2['pode_enviar']} · "
          f"14/11: {a3 and a3['proximo_passo']} ligar={a3 and a3['ligar_sugerido']} ({a3 and a3['bloqueio']})")


def t13():
    # instalação agendada ter 17/11 manhã (agendada na sex 13/11) → C2 na hora; C3 na véspera (seg 16/11).
    sql(venda_teste(16, status="'2_aguardando_instalacao'", nio_pedido="'TESTE-CAD-16'", biometria_status="'validada'",
                    nio_viab_resultado="'viavel'", instalacao_agendada_para="'2026-11-17 08:00-03'", instalacao_turno="'manha'")
        + conv(16, status="'handoff_realizado'", etapa="'handoff'", venda_id=f"'{uid(116)}'", nome_contato="'Bia Teste'",
               nome_confiavel='true', ultima_msg_lead_at="'2026-11-13 10:00-03'")
        + turno(16, 'mari', '2026-11-13 10:01-03', 'Pronto, anotado!'))
    a = um(sql(avaliar(16, '2026-11-13 10:30-03')))
    ok_c2 = (a and a['proximo_passo'] == 'INSTALACAO' and a['pode_enviar'] and a['acao'] == 'texto'
             and a['params'][1] == 'terça-feira, 17/11' and a['params'][2].startswith('manhã'))
    if ok_c2:
        sql(f"select public.mari_cadencia_registrar('{uid(16)}', 'INSTALACAO', true, null, '2026-11-13 10:30-03', $${a['texto']}$$, null)")
    b = um(sql(avaliar(16, '2026-11-14 10:00-03')))
    c = um(sql(avaliar(16, '2026-11-16 10:00-03')))
    ok = (ok_c2 and b and b['proximo_passo'] == 'VESPERA' and not b['pode_enviar']
          and c and c['proximo_passo'] == 'VESPERA' and c['template'] == 'nio_lembrete_instalacao' and c['params'][1:] == ['17/11', 'manhã'])
    checa('13 · instalação agendada: C2 ao agendar; C3 só na véspera', bool(ok),
          f"13/11: {a and a['proximo_passo']} {a and a['params']} pode={a and a['pode_enviar']} · 14/11: {b and b['bloqueio']} · "
          f"16/11: {c and c['template']} {c and c['params']} ({c and c['bloqueio']})")


def t14():
    # 0027 (fallback desde a 0032): SEM pedido registrado, o link colado no Chatwoot ainda marca a venda.
    base = 'https://ged360.niointernet.com.br/brprontopdv/pdv-mobile/biometria/login/'
    tel = f'{PREFIXO}917'
    sql(venda_teste(17, biometria_status="'nao_enviada'")
        + conv(17, status="'handoff_realizado'", etapa="'handoff'", venda_id=f"'{uid(117)}'"))

    def humano(txt):
        r = sql(f"select public.mari_registrar_turno('{tel}', 'Atendente', $${txt}$$, 'humano', 'teste') as r")
        return (r[0]['r'] or {}).get('biometria_link')

    def venda():
        return sql(f"select biometria_status, biometria_link, biometria_link_enviado_em from public.vendas where id = '{uid(117)}'")[0]

    r0 = humano('Oi, tudo bem? Já abri o seu pedido aqui.')
    r1 = humano(f'Segue o link da biometria: {base}abc17 é só tocar e seguir.')
    v1 = venda()
    r2 = humano(f'Reforçando o link: {base}abc17')
    r3 = humano(f'Gerei um novo, use este: {base}novo17')
    v3 = venda()
    ev = sql(f"select count(*) as n from public.eventos_venda where venda_id = '{uid(117)}' and tipo = 'biometria_link'")[0]['n']
    sql(f"update public.vendas set biometria_status = 'validada' where id = '{uid(117)}'")
    r4 = humano(f'Mais um: {base}depois17')
    ok = (r0 is None and r1 == 'link registrado' and v1['biometria_status'] == 'pendente' and v1['biometria_link'] == base + 'abc17'
          and v1['biometria_link_enviado_em'] and r2 == 'mesmo link já registrado' and r3 == 'link trocado (reenvio)'
          and v3['biometria_link'] == base + 'novo17' and int(ev) == 2 and r4 == 'venda já passou da biometria')
    checa('14 · fallback sem pedido: link colado no Chatwoot → gravado na venda (reenvio troca; validada não mexe)', bool(ok),
          f"sem link: {r0} · 1º: {r1} ({v1['biometria_status']}) · repetido: {r2} · novo: {r3} · eventos: {ev} · validada: {r4}")


def t15():
    # 0032: registrar o nº do pedido na ficha → biometria pendente, contagem da hora do pedido; link colado DEPOIS no
    # Chatwoot só fica como referência (não muda status nem contagem).
    base = 'https://ged360.niointernet.com.br/brprontopdv/pdv-mobile/biometria/login/'
    tel = f'{PREFIXO}918'
    sql(venda_teste(18, biometria_status="'nao_enviada'")
        + conv(18, status="'handoff_realizado'", etapa="'handoff'", venda_id=f"'{uid(118)}'"))

    def venda():
        return sql(f"select biometria_status, biometria_link, nio_pedido_em, biometria_link_enviado_em from public.vendas where id = '{uid(118)}'")[0]

    def humano(txt):
        r = sql(f"select public.mari_registrar_turno('{tel}', 'Atendente', $${txt}$$, 'humano', 'teste') as r")
        return (r[0]['r'] or {}).get('biometria_link')

    v0 = venda()
    sql(f"update public.vendas set nio_pedido = 'TESTE-CAD-18' where id = '{uid(118)}'")
    v1 = venda()
    r1 = humano(f'A Nio te mandou este link: {base}abc18')
    v2 = venda()
    r2 = humano(f'Outro: {base}xyz18')
    v3 = venda()
    ok = (v0['biometria_status'] == 'nao_enviada' and not v0['nio_pedido_em']
          and v1['biometria_status'] == 'pendente' and v1['nio_pedido_em'] and v1['biometria_link_enviado_em'] == v1['nio_pedido_em']
          and r1 == 'link guardado (o pedido já define a contagem)' and v2['biometria_link'] == base + 'abc18'
          and v2['biometria_link_enviado_em'] == v1['biometria_link_enviado_em'] and v2['biometria_status'] == 'pendente'
          and r2 == 'pedido já registrado (link não muda a contagem)' and v3['biometria_link'] == base + 'abc18'
          and v3['biometria_link_enviado_em'] == v1['biometria_link_enviado_em'])
    checa('15 · nº do pedido na ficha → pendente e contagem da hora do pedido; link colado depois não muda nada', bool(ok),
          f"antes: {v0['biometria_status']} · pedido: {v1['biometria_status']} conta={v1['biometria_link_enviado_em'] == v1['nio_pedido_em']} · "
          f"link depois: {r1} · 2º link: {r2} · contagem intacta={v3['biometria_link_enviado_em'] == v1['biometria_link_enviado_em']}")

# ───────────── prompt 28 (0050 + 0052): F2 no mesmo dia, venda, interesse futuro, eco ─────────────

def t16():
    # Mari falou qua 14h → F1 15h (registrado) → F2 ~4 h depois da última fala da Mari (18h), no MESMO dia;
    # depois do F2 o teto do dia (2 toques) segura qualquer outra coisa até amanhã.
    sql(conv(19, ultima_msg_lead_at="'2026-11-11 14:00-03'", etapa="'elegibilidade'") + turno(19, 'mari', '2026-11-11 14:00-03', 'Qual operadora?')
        + "update public.mari_conversas set ultima_msg_mari_at = '2026-11-11 14:00-03' where id = '" + uid(19) + "';")
    a1 = um(sql(avaliar(19, '2026-11-11 15:01-03')))
    sql(f"select public.mari_cadencia_registrar('{uid(19)}', 'F1', true, null, '2026-11-11 15:01-03', $${a1 and a1['texto']}$$, null)")
    a2a = um(sql(avaliar(19, '2026-11-11 17:50-03')))
    a2 = um(sql(avaliar(19, '2026-11-11 18:00-03')))
    ok_f2 = (a1 and a1['proximo_passo'] == 'F1' and a1['pode_enviar'] and 'operadora' in norm(a1['texto'])
             and a2a and not a2a['pode_enviar'] and a2 and a2['proximo_passo'] == 'F2' and a2['pode_enviar'])
    if ok_f2:
        sql(f"select public.mari_cadencia_registrar('{uid(19)}', 'F2', true, null, '2026-11-11 18:00-03', $${a2['texto']}$$, null)")
    a3 = um(sql(avaliar(19, '2026-11-11 20:30-03')))
    ok = bool(ok_f2) and a3 and not a3['pode_enviar'] and a3['proximo_passo'] == 'D3' and int(a3['toques_hoje']) == 2
    checa('16 · F1 em 1 h e F2 ~4 h depois da Mari, no mesmo dia; 2 toques/dia seguram o resto', bool(ok),
          f"15h01: {a1 and a1['proximo_passo']} «{a1 and a1['texto']}» · 17h50: pode={a2a and a2a['pode_enviar']} · "
          f"18h: {a2 and a2['proximo_passo']} pode={a2 and a2['pode_enviar']} «{a2 and a2['texto']}» · "
          f"20h30: {a3 and a3['proximo_passo']} em {sp(a3 and a3['proximo_em'])}, toques hoje={a3 and a3['toques_hoje']}")


def t17():
    # venda em Saída (Sem cobertura): nada · venda criada (0 · Qualificado) com a conversa ativa: F1 sim, D3 nunca
    sql(venda_teste(20, status="'saida'", motivo_saida="'Sem cobertura'")
        + conv(20, ultima_msg_lead_at="'2026-11-11 14:00-03'", venda_id=f"'{uid(120)}'", etapa="'retomada'")
        + turno(20, 'mari', '2026-11-11 14:00-03', 'x')
        + venda_teste(21) + conv(21, ultima_msg_lead_at="'2026-11-11 14:00-03'", venda_id=f"'{uid(121)}'", etapa="'retomada'")
        + turno(21, 'mari', '2026-11-11 14:00-03', 'x')
        + "update public.mari_conversas set ultima_msg_mari_at = '2026-11-11 14:00-03' where id in ('" + uid(20) + "','" + uid(21) + "');")
    s = um(sql(avaliar(20, '2026-11-11 15:01-03')))
    f1 = um(sql(avaliar(21, '2026-11-11 15:01-03')))
    d3 = um(sql(avaliar(21, '2026-11-14 10:30-03')))
    ok = s is None and f1 and f1['proximo_passo'] == 'F1' and f1['pode_enviar'] and d3 and not d3['pode_enviar'] \
        and 'venda criada' in (d3['bloqueio'] or '')
    checa('17 · venda em Saída → nada; venda criada → só F1/F2 (D3/D7/D15 e encerrar nunca)', bool(ok),
          f"Saída: {'fora da cadência' if s is None else s['proximo_passo']} · venda criada 15h01: {f1 and f1['proximo_passo']} "
          f"pode={f1 and f1['pode_enviar']} · D3: {d3 and d3['proximo_passo']} ({d3 and d3['bloqueio']})")


def t18():
    # Interesse futuro: telefone de teste nunca entra na lista do Chatwoot; mari_futuro_marcar grava a data e o evento
    sql(venda_teste(22, status="'saida'", motivo_saida="'Interesse futuro (com data)'", interesse_futuro_em="'2026-12-10'")
        + conv(22, canal="'whatsapp'", chatwoot_conversation_id="'999922'", venda_id=f"'{uid(122)}'", status="'encerrado_humano'"))
    lista = sql("select r from public.mari_futuro_pendentes(20) r")
    fora = not any((x['r'] or {}).get('conversa_id') == uid(22) for x in lista)
    m = sql(f"select public.mari_futuro_marcar('{uid(22)}', '2026-12-10') as r")[0]['r']
    c = sql(f"select etiqueta_futuro_para as p, etiqueta_futuro_em is not null as em from public.mari_conversas where id = '{uid(22)}'")[0]
    ev = sql(f"select count(*) as n from public.eventos_venda where venda_id = '{uid(122)}' and tipo = 'chatwoot_etiqueta'")[0]['n']
    ok = fora and m.get('ok') and str(c['p']) == '2026-12-10' and c['em'] and int(ev) == 1
    checa('18 · interesse futuro: teste fora da lista do Chatwoot; marcar grava a data e o evento da venda', bool(ok),
          f"fora da lista={fora} ({len(lista)} reais na lista) · marcar={m} · conversa={c} · eventos={ev}")


def t19():
    # Eco: o turno 'humano' com o texto da cadência (eco que chegou antes do registro) some no registrar
    sql(conv(23, canal="'whatsapp'", ultima_msg_lead_at="'2026-11-11 14:00-03'") + turno(23, 'mari', '2026-11-11 14:00-03', 'x')
        + turno(23, 'humano', '2026-11-11 15:01:02-03', 'Texto da cadencia teste')
        + turno(23, 'humano', '2026-11-11 15:01:03-03', 'Fala real do consultor'))
    r = sql(f"select public.mari_cadencia_registrar('{uid(23)}', 'F1', true, null, '2026-11-11 15:01-03', 'Texto da cadencia teste', null) as r")[0]['r']
    h = sql(f"select texto from public.mari_turnos where conversa_id = '{uid(23)}' and papel = 'humano'")
    ok = r.get('eco_removido') == 1 and [x['texto'] for x in h] == ['Fala real do consultor']
    checa('19 · eco do envio que virou turno humano é apagado; fala real do consultor fica', bool(ok),
          f"eco_removido={r.get('eco_removido')} · humanos que ficaram={[x['texto'] for x in h]}")


def limpar_wa():
    """t18/t19 usam canal 'whatsapp' com telefone de teste (o mari_limpar_teste só apaga canal 'teste')."""
    return sql(f"""with alvo as (select id from public.mari_conversas where canal = 'whatsapp' and telefone like '{PREFIXO}9%'),
        v as (delete from public.vendas where origem_ref in (select 'mari:' || id from alvo) returning 1),
        c as (delete from public.mari_conversas where id in (select id from alvo) returning 1)
        select (select count(*) from v) as vendas, (select count(*) from c) as conversas""")[0]


if __name__ == '__main__':
    print('teardown inicial:', sql(f"select public.mari_limpar_teste('{PREFIXO}9') as r")[0]['r'], limpar_wa())
    try:
        for t in (t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, t12, t13, t14, t15, t16, t17, t18, t19):
            try:
                t()
            except Exception as e:
                checa(t.__name__, False, f'erro: {e}')
    finally:
        # As fixtures usam relógio simulado (datas de 11 a 17/11): NUNCA podem ficar nas tabelas reais.
        # A limpeza roda mesmo se a bateria quebrar no meio; --sem-teardown só para depurar, e avisa.
        if '--sem-teardown' in sys.argv:
            print("⚠️  --sem-teardown: as fixtures (datas futuras) ficaram no banco — limpe com mari_limpar_teste('55000000009')")
        else:
            print('teardown final:', sql(f"select public.mari_limpar_teste('{PREFIXO}9') as r")[0]['r'], limpar_wa())
            sobra = sql(f"""select
                (select count(*) from public.mari_conversas where telefone like '{PREFIXO}9%') as conversas,
                (select count(*) from public.contatos_cliente where telefone like '{PREFIXO}9%') as toques,
                (select count(*) from public.mari_turnos where created_at > now() + interval '1 hour') as turnos_futuros,
                (select count(*) from public.contatos_cliente where em > now() + interval '1 hour') as toques_futuros,
                (select count(*) from public.mari_conversas where greatest(created_at, coalesce(ultima_msg_lead_at, created_at),
                   coalesce(ultima_msg_mari_at, created_at)) > now() + interval '1 hour') as conversas_futuras""")[0]
            limpo = all(int(v) == 0 for v in sobra.values())
            checa('11 · limpeza: nenhuma fixture nem data futura nas tabelas reais', limpo, str(sobra))
    print()
    print('| # | Teste | Resultado |')
    print('|---|---|---|')
    for nome, ok, det in RES:
        print(f"| {nome.split(' · ')[0]} | {nome.split(' · ', 1)[-1]} | {'✅' if ok else '❌'} {det} |")
    sys.exit(0 if all(ok for _, ok, _ in RES) else 1)

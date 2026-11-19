#!/usr/bin/env python
# NIOGEN | n8n/rascunhos/passo4_191126/montar_rascunho.py | 19/11/2026 03h — Claude Code (Opus 5.5), tarefa niogen-passo4-madrugada
# RASCUNHO do passo 4 (fase 2, "um projetor só") para a Mari e a cadência. SÓ ARQUIVO: não fala com o n8n, não faz deploy.
# Lê os exports do repo (n8n/mari_principal.json e n8n/mari_cadencia.json — conferidos iguais aos vivos em 19/11 ~02h40 nos nós
# 2g/2h/2p/2u/9d/9e/9f/9h e 6g/6h/9e/9f/9h) e grava, nesta pasta, mari_principal_passo4.json e mari_cadencia_passo4.json com:
#   mari_principal
#     2g  GET da conversa no Chatwoot           → "2g · Porta pode falar?"  POST rpc/mari_pode_falar (p_para 'resposta')
#     2h  guard lendo o Chatwoot                → n02h_guard_porta.js (lê a resposta do banco; sem resposta, cala)
#     2p  labels: [] (apaga TODAS)  + 2u resolve → "2p · Porta zerar"        POST rpc/mari_chatwoot_pedir ('zerar'); 2u sai
#     9e  labels lista inteira + 9f nota + 9h time → "9e · Porta handoff"   POST rpc/mari_chatwoot_pedir ('handoff_<tipo>', nota);
#                                                    9f, 9g e 9h saem; 9j/9k seguem direto para 11 · Saída
#   mari_cadencia
#     6g  GET da conversa no Chatwoot           → "6g · Porta pode falar?"  POST rpc/mari_pode_falar (p_para 'lembrete', passo)
#     6h  guard lendo o Chatwoot                → c06_guard_porta.js
#     9c ler + 9d lista + 9e if + 9f labels + 9g nota → "9f · Porta interesse futuro" POST rpc/mari_chatwoot_pedir ('interesse_futuro')
#     9h  conferir                              → c09h_futuro_conferir_porta.js
# O que continua falando com o Chatwoot de propósito: a Mari e a cadência MANDAM MENSAGEM pelo Chatwoot (é a voz dela) e o 9k
# renomeia o contato (não é estado da conversa). Nada mais muda etiqueta, dono, time ou aberta/resolvida.
# As RPCs ainda NÃO existem no banco: supabase/rascunhos/0308_mari_pela_porta_RASCUNHO.sql.
# Uso:  python n8n/rascunhos/passo4_191126/montar_rascunho.py      (depois: node n8n/rascunhos/passo4_191126/conferir_local.test.js)
import copy, json, pathlib, sys

AQUI = pathlib.Path(__file__).resolve().parent
REPO = AQUI.parents[2]
RPC = 'https://zlrfwbkblytnokuexjti.supabase.co/rest/v1/rpc/'


def carregar(nome):
    return json.loads((REPO / 'n8n' / nome).read_text(encoding='utf-8'))


def no(wf, prefixo):
    for n in wf['nodes']:
        if n['name'].split(' ')[0] == prefixo:
            return n
    raise SystemExit(f'nó {prefixo} não achado em {wf["name"]}')


def cred_supabase(wf):
    for n in wf['nodes']:
        if 'supabaseApi' in (n.get('credentials') or {}):
            return copy.deepcopy(n['credentials'])
    raise SystemExit('sem credencial do Supabase no fluxo')


def virar_rpc(wf, n, nome_novo, funcao, corpo_expr):
    """troca um nó HTTP do Chatwoot por um POST numa RPC do Supabase (mesma posição, mesmo id)."""
    antigo = n['name']
    n['name'] = nome_novo
    n['type'] = 'n8n-nodes-base.httpRequest'
    n['typeVersion'] = 4.2
    n['parameters'] = {'method': 'POST', 'url': RPC + funcao, 'authentication': 'predefinedCredentialType',
                       'nodeCredentialType': 'supabaseApi', 'sendBody': True, 'specifyBody': 'json',
                       'jsonBody': corpo_expr, 'options': {'timeout': 10000}}
    n['credentials'] = cred_supabase(wf)
    n['onError'] = 'continueRegularOutput'   # sem resposta → o guard decide "não fala"
    renomear(wf, antigo, nome_novo)


def renomear(wf, antigo, novo):
    if antigo == novo:
        return
    texto = json.dumps(wf, ensure_ascii=False)
    texto = texto.replace(json.dumps(antigo, ensure_ascii=False)[1:-1], json.dumps(novo, ensure_ascii=False)[1:-1])
    wf.clear()
    wf.update(json.loads(texto))


def tirar(wf, prefixo):
    n = no(wf, prefixo)
    wf['nodes'] = [x for x in wf['nodes'] if x is not n and x['name'] != n['name']]
    wf['connections'].pop(n['name'], None)
    for v in wf['connections'].values():
        for saida in v.get('main', []):
            if saida:
                saida[:] = [x for x in saida if x['node'] != n['name']]
    return n['name']


def ligar(wf, de, para, saida=0):
    m = wf['connections'].setdefault(de, {'main': []})['main']
    while len(m) <= saida:
        m.append([])
    m[saida] = [{'node': para, 'type': 'main', 'index': 0}]


def mari():
    wf = carregar('mari_principal.json')
    virar_rpc(wf, no(wf, '2g'), '2g · Porta pode falar?', 'mari_pode_falar',
              "={{ JSON.stringify({ p_conversa_cw: String($json.chatwootConversationId), p_para: 'resposta' }) }}")
    no(wf, '2h')['parameters']['jsCode'] = (AQUI / 'n02h_guard_porta.js').read_text(encoding='utf-8')
    virar_rpc(wf, no(wf, '2p'), '2p · Porta zerar', 'mari_chatwoot_pedir',
              "={{ JSON.stringify({ p_conversa_cw: String($('2 · Entrada').first().json.chatwootConversationId), p_pedido: 'zerar' }) }}")
    tirar(wf, '2u')
    wf['connections'].pop('2p · Porta zerar', None)
    virar_rpc(wf, no(wf, '9e'), '9e · Porta handoff', 'mari_chatwoot_pedir',
              "={{ JSON.stringify({ p_conversa_cw: String($('9d · Montar handoff Chatwoot').first().json.conversa), "
              "p_pedido: 'handoff_' + ($('9d · Montar handoff Chatwoot').first().json.tipo || 'humano'), "
              "p_nota: $('9d · Montar handoff Chatwoot').first().json.nota }) }}")
    for p in ('9f', '9h', '9g'):
        tirar(wf, p)
    ligar(wf, '9e · Porta handoff', '9j · Renomear contato?')
    ligar(wf, '9j · Renomear contato?', '9k · Chatwoot nome', 0)
    ligar(wf, '9j · Renomear contato?', '11 · Saída', 1)
    ligar(wf, '9k · Chatwoot nome', '11 · Saída')
    wf['name'] = wf['name'] + ' (RASCUNHO passo 4 — não subir sem o portão da Mari)'
    return wf


def cadencia():
    wf = carregar('mari_cadencia.json')
    virar_rpc(wf, no(wf, '6g'), '6g · Porta pode falar?', 'mari_pode_falar',
              "={{ JSON.stringify({ p_conversa_cw: String($json.chatwootConversationId), p_para: 'lembrete', p_passo: $json.passo || null }) }}")
    no(wf, '6h')['parameters']['jsCode'] = (AQUI / 'c06_guard_porta.js').read_text(encoding='utf-8')
    virar_rpc(wf, no(wf, '9f'), '9f · Porta interesse futuro', 'mari_chatwoot_pedir',
              "={{ JSON.stringify({ p_conversa_cw: String($json.cw), p_pedido: 'interesse_futuro', p_nota: $json.nota || null }) }}")
    for p in ('9c', '9d', '9e', '9g'):
        tirar(wf, p)
    ligar(wf, '9b · Itens futuro', '9f · Porta interesse futuro')
    ligar(wf, '9f · Porta interesse futuro', '9h · Conferir')
    no(wf, '9h')['parameters']['jsCode'] = (AQUI / 'c09h_futuro_conferir_porta.js').read_text(encoding='utf-8')
    wf['name'] = wf['name'] + ' (RASCUNHO passo 4 — não subir sem o portão da Mari)'
    return wf


def main():
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    for nome, wf in (('mari_principal_passo4.json', mari()), ('mari_cadencia_passo4.json', cadencia())):
        (AQUI / nome).write_text(json.dumps(wf, ensure_ascii=False, indent=1), encoding='utf-8')
        print(f'{nome}: {len(wf["nodes"])} nós')


if __name__ == '__main__':
    main()

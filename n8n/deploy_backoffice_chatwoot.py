#!/usr/bin/env python3
# NIOGEN | n8n/deploy_backoffice_chatwoot.py | 09/11/2026 — Claude Code (docs/Prompt_fluxo_unico_backoffice_091126_1000.md · Fase 1.2)
# Workflow n8n "backoffice_chatwoot": a cada 1 min pega no Supabase Nio as ações que os botões do NIOGEN enfileiraram
# (chatwoot_acoes, migration 0082 — RPC backoffice_acoes_proximas) e executa na conta Chatwoot da Nio 195428:
#   atribuir / desatribuir (POST /assignments) · etiquetas (GET /labels → UNIÃO com as atuais → POST /labels; nunca sobrescreve) ·
#   nota privada e mensagem ao cliente (POST /messages) · resolver (POST /toggle_status).
# Credencial padrão: "Chatwoot Nio — Mari bot" (a fala sai com o nome Mari; o 2 · Entrada do mari_principal ignora mensagem que não
# é de usuário — não acorda a Mari). Tipos listados em config_regras.backoffice_cred_usuario vão com "Chatwoot Nio" (token do Ricardo),
# só se o bot for recusado. Resultado de cada ação → backoffice_acao_resultado (feita / erro, 3 tentativas).
# O freio do contrato (horário, 2/dia · 15/mês, janela 24 h) é do banco: aqui só executa o que já venceu.
# Desligar sem mexer no n8n: config_regras.backoffice_chatwoot_ligado = false (a fila acumula).
#
# Credenciais (só IDs/nomes): "Supabase Nio (service role)", "Chatwoot Nio — Mari bot", "Chatwoot Nio". Chave da API do n8n: N8N_API_KEY_NIO.
#
# Uso:
#   python n8n/deploy_backoffice_chatwoot.py build      # gera n8n/backoffice_chatwoot.json (export, sem segredos)
#   python n8n/deploy_backoffice_chatwoot.py criar      # cria o workflow INATIVO; falha se o nome já existe
#   python n8n/deploy_backoffice_chatwoot.py estrutura  # PUT do workflow inteiro, backup antes (mantém o active atual)
#   python n8n/deploy_backoffice_chatwoot.py ativar     # liga
#   python n8n/deploy_backoffice_chatwoot.py desativar  # desliga
#   python n8n/deploy_backoffice_chatwoot.py exportar   # baixa o estado atual e grava o export sanitizado

import datetime
import json
import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_mari as dm   # noqa: E402

AQUI = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(AQUI)
EXPORT = os.path.join(AQUI, 'backoffice_chatwoot.json')
WF_NOME = 'backoffice_chatwoot'
ID_KEY = 'backoffice_chatwoot_workflow_id'

MONTAR_ETIQUETAS = r"""// 3b · Montar etiquetas — UNIÃO das etiquetas atuais (GET) com as novas, tirando só as que o momento manda tirar.
// Leitura falhou → não posta nada (postar só as novas apagaria as atuais: POST /labels substitui a lista).
const a = $('3 · Etiquetas?').item.json;
const r = $json || {};
if (r.error || !Array.isArray(r.payload)) {
  return { json: { ...a, erroLeitura: 'não li as etiquetas atuais: ' + JSON.stringify(r.error || r).slice(0, 300) } };
}
const tirar = new Set(a.remove || []);
const labels = [...new Set([...r.payload, ...(a.add || [])])].filter((l) => !tirar.has(l));
return { json: { ...a, corpo: { labels } } };
"""

RESULTADO = r"""// 6 · Resultado — ok = a API do Chatwoot respondeu sem erro. O id vem do item que entrou no 4 (ou do 3b, se a leitura falhou).
let base = null;
try { base = $('4 · Usuário?').item.json; } catch (e) { base = null; }
if (!base || $json.erroLeitura) base = $json;
const erro = $json.erroLeitura || ($json.error ? JSON.stringify($json.error).slice(0, 400) : null);
return { json: { p_id: base.id, p_ok: !erro, p_erro: erro } };
"""


def build(ids):
    cred = ids.get('credenciais', {})
    if not cred.get('chatwoot_bot'):
        raise SystemExit('credencial "Chatwoot Nio — Mari bot" ausente em mari_ids.json — nada gerado.')
    sb_cred = {'supabaseApi': {'id': cred.get('supabase', ''), 'name': dm.CRED_SUPABASE}}
    cw_bot = {'httpHeaderAuth': {'id': cred['chatwoot_bot'], 'name': dm.CRED_CHATWOOT_BOT}}
    cw_usr = {'httpHeaderAuth': {'id': cred.get('chatwoot', ''), 'name': dm.CRED_CHATWOOT}}
    nodes = []

    def add(name, ntype, ver, params, x, y, **extra):
        n = {'parameters': params, 'name': name, 'type': ntype, 'typeVersion': ver, 'position': [x, y],
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/backoffice_chatwoot/{name}'))}
        n.update(extra)
        nodes.append(n)

    def iff(name, expr, x, y):
        add(name, 'n8n-nodes-base.if', 2, {
            'conditions': {'options': {'caseSensitive': True, 'leftValue': '', 'typeValidation': 'strict'},
                           'conditions': [{'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/bo/{name}')), 'leftValue': expr,
                                           'rightValue': '', 'operator': {'type': 'boolean', 'operation': 'true', 'singleValue': True}}],
                           'combinator': 'and'}, 'options': {}}, x, y)

    def http_cw(name, x, y, credencial, nota):
        add(name, 'n8n-nodes-base.httpRequest', 4.2, {
            'method': 'POST', 'url': '={{ $json.url }}',
            'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth',
            'sendBody': True, 'specifyBody': 'json', 'jsonBody': '={{ JSON.stringify($json.corpo) }}',
            'options': {'timeout': 15000}}, x, y, credentials=credencial, onError='continueRegularOutput', notes=nota, notesInFlow=True)

    add('1 · A cada 1 min', 'n8n-nodes-base.scheduleTrigger', 1.2,
        {'rule': {'interval': [{'field': 'minutes', 'minutesInterval': 1}]}}, 0, 0)
    # Devolve uma lista (um item por ação, na ordem do grupo); lista vazia = nenhum item = nada mais roda.
    add('2 · Supabase ações', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{dm.SB}/rest/v1/rpc/backoffice_acoes_proximas',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': '={{ JSON.stringify({ p_limite: 20 }) }}',
        'options': {'timeout': 20000}}, 240, 0, credentials=sb_cred)
    iff('3 · Etiquetas?', "={{ $json.tipo === 'etiquetas' }}", 480, 0)
    add('3a · Chatwoot ler etiquetas', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'GET', 'url': "={{ $json.url_base + '/labels' }}",
        'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth',
        'options': {'timeout': 15000}}, 720, -160, credentials=cw_bot, onError='continueRegularOutput')
    add('3b · Montar etiquetas', 'n8n-nodes-base.code', 2, {'mode': 'runOnceForEachItem', 'jsCode': MONTAR_ETIQUETAS}, 960, -160)
    iff('3c · Leu as etiquetas?', '={{ !$json.erroLeitura }}', 1200, -160)
    iff('4 · Usuário?', '={{ $json.usuario === true }}', 1440, 0)
    http_cw('5b · Chatwoot (bot Mari)', 1680, 100, cw_bot, 'Credencial "Chatwoot Nio — Mari bot": a fala sai como Mari e não acorda a Mari.')
    http_cw('5u · Chatwoot (usuário)', 1680, -100, cw_usr, 'Só os tipos de config_regras.backoffice_cred_usuario (token do Ricardo).')
    add('6 · Resultado', 'n8n-nodes-base.code', 2, {'mode': 'runOnceForEachItem', 'jsCode': RESULTADO}, 1920, 0)
    add('7 · Supabase resultado', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{dm.SB}/rest/v1/rpc/backoffice_acao_resultado',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': '={{ JSON.stringify($json) }}',
        'options': {'timeout': 20000}}, 2160, 0, credentials=sb_cred, onError='continueRegularOutput')

    conns = {}

    def liga(o, d, saida=0):
        c = conns.setdefault(o, {'main': []})['main']
        while len(c) <= saida:
            c.append([])
        c[saida].append({'node': d, 'type': 'main', 'index': 0})

    liga('1 · A cada 1 min', '2 · Supabase ações')
    liga('2 · Supabase ações', '3 · Etiquetas?')
    liga('3 · Etiquetas?', '3a · Chatwoot ler etiquetas', 0)
    liga('3 · Etiquetas?', '4 · Usuário?', 1)
    liga('3a · Chatwoot ler etiquetas', '3b · Montar etiquetas')
    liga('3b · Montar etiquetas', '3c · Leu as etiquetas?')
    liga('3c · Leu as etiquetas?', '4 · Usuário?', 0)
    liga('3c · Leu as etiquetas?', '6 · Resultado', 1)
    liga('4 · Usuário?', '5u · Chatwoot (usuário)', 0)
    liga('4 · Usuário?', '5b · Chatwoot (bot Mari)', 1)
    liga('5u · Chatwoot (usuário)', '6 · Resultado')
    liga('5b · Chatwoot (bot Mari)', '6 · Resultado')
    liga('6 · Resultado', '7 · Supabase resultado')
    # 1.440 execuções/dia: sucesso não fica salvo; erro fica (e vai para o Error Trigger do mari_principal).
    settings = {'executionOrder': 'v1', 'saveDataErrorExecution': 'all', 'saveDataSuccessExecution': 'none',
                'saveManualExecutions': True, 'timezone': 'America/Sao_Paulo'}
    if ids.get('workflow_id'):
        settings['errorWorkflow'] = ids['workflow_id']
    return {'name': WF_NOME, 'nodes': nodes, 'connections': conns, 'settings': settings}


def salvar(wf):
    dm.checar_sem_segredo(wf)
    keep = {k: wf[k] for k in ('name', 'nodes', 'connections', 'settings') if k in wf}
    keep['active'] = wf.get('active', False)
    with open(EXPORT, 'w', encoding='utf-8') as f:
        json.dump(keep, f, ensure_ascii=False, indent=2)
        f.write('\n')
    print(f'export: {os.path.relpath(EXPORT, REPO)} ({len(keep["nodes"])} nós, active={keep["active"]})')


def cmd_build():
    salvar(build(dm.ler_ids()))


def cmd_criar():
    ids = dm.ler_ids()
    if ids.get(ID_KEY):
        raise SystemExit(f'já existe {ID_KEY} {ids[ID_KEY]} — nada foi criado.')
    if any(w.get('name') == WF_NOME for w in dm.api('GET', '/workflows?limit=250').get('data', [])):
        raise SystemExit(f'já existe um workflow chamado {WF_NOME} no n8n — nada foi criado.')
    wf = build(ids)
    dm.checar_sem_segredo(wf)
    r = dm.api('POST', '/workflows', wf)   # a API cria sempre inativo
    ids[ID_KEY] = r['id']
    dm.gravar_ids(ids)
    print(f'criado: {WF_NOME} ({r["id"]}), active={r.get("active")}')
    cmd_exportar()


def cmd_estrutura():
    ids = dm.ler_ids()
    atual = dm.api('GET', f'/workflows/{ids[ID_KEY]}')
    os.makedirs(os.path.join(AQUI, 'backups'), exist_ok=True)
    bk = os.path.join(AQUI, 'backups', f"{WF_NOME}_{datetime.datetime.now():%d%m%y_%H%M%S}.json")
    with open(bk, 'w', encoding='utf-8') as f:
        json.dump(atual, f, ensure_ascii=False, indent=2)
    print('backup:', os.path.relpath(bk, REPO))
    dm.put(ids[ID_KEY], build(ids))
    print('ok (active =', dm.api('GET', f'/workflows/{ids[ID_KEY]}').get('active'), ')')
    cmd_exportar()


def cmd_ativar(ligar=True):
    ids = dm.ler_ids()
    dm.api('POST', f"/workflows/{ids[ID_KEY]}/{'activate' if ligar else 'deactivate'}")
    print('active:', dm.api('GET', f'/workflows/{ids[ID_KEY]}').get('active'))
    cmd_exportar()


def cmd_exportar():
    ids = dm.ler_ids()
    salvar(dm.api('GET', f'/workflows/{ids[ID_KEY]}'))


if __name__ == '__main__':
    acoes = {'build': cmd_build, 'criar': cmd_criar, 'estrutura': cmd_estrutura, 'ativar': cmd_ativar,
             'desativar': lambda: cmd_ativar(False), 'exportar': cmd_exportar}
    if len(sys.argv) < 2 or sys.argv[1] not in acoes:
        raise SystemExit('uso: build | criar | estrutura | ativar | desativar | exportar')
    acoes[sys.argv[1]]()

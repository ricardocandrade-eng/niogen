#!/usr/bin/env python3
# NIOGEN | n8n/deploy_mari_viabilidade.py | 12/11/2026 — Claude Code (achado 1 da 1ª auditoria da Mari; Ricardo: "Sim, ataca")
# Dois workflows n8n que levam o OPERADOR do portal à Mari, com a mesma decisão da tela Cobertura (Ricardo, 12/11 ~02h30):
#
#  "mari_viabilidade" (a cada 2 min, 7h–23h): pega 1 conversa com endereço confirmado (mari_viab_pendentes — tetos: 3 endereços
#   por conversa, 3 conversas por telefone em 7 dias), pede ao portal a viabilidade (edge credito-consulta, acao 'viabilidade' —
#   Etapas 0–2, sem CPF), espera (status a cada 12 s), consulta o DFV (edge dfv-consulta) e grava (mari_viab_gravar → decisão
#   portal decide / DFV resgata em mari_conversas.cobertura_decisao + operador_consultas + nio_viab_log). Portal ocupado →
#   volta para a fila; portal que demorou ou não decidiu → o DFV decide (como na tela).
#  "mari_duplicidade" (a cada 2 min, 7h–23h): pega 1 conversa com plano escolhido e CPF válido (mari_dup_pendentes — 1 por
#   conversa), pede ao portal a duplicidade de pedido (acao 'duplicidade' — Etapas 0–3 com o endereço padrão, sem contato, sem
#   crédito) e grava (mari_dup_gravar → mari_conversas.nio_pedido_aberto sim|nao + operador_consultas).
# A Mari lê cobertura_decisao e nio_pedido_aberto do estado (prompt Bloco 9). Nada sai para cliente daqui.
#
# Credenciais (só IDs/nomes): "Supabase Nio (service role)" (as edges aceitam a service role só para viabilidade, duplicidade
# e status — 0131), "MARI_TESTE_SECRET" (rota de teste). Chave do n8n: N8N_API_KEY_NIO.
#
# Uso: python n8n/deploy_mari_viabilidade.py [--dup] build | criar | estrutura | ativar | desativar | exportar | rodar
#      (--dup = o workflow mari_duplicidade)

import datetime
import json
import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_mari as dm   # noqa: E402

AQUI = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(AQUI)
DUP = '--dup' in sys.argv
if DUP:
    sys.argv.remove('--dup')
WF_NOME = 'mari_duplicidade' if DUP else 'mari_viabilidade'
ID_KEY = f'{WF_NOME}_workflow_id'
EXPORT = os.path.join(AQUI, f'{WF_NOME}.json')
ROTA_TESTE = f'niogen-{WF_NOME.replace("_", "-")}-teste'
EDGE_CRED = f'{dm.SB}/functions/v1/credito-consulta'
EDGE_DFV = f'{dm.SB}/functions/v1/dfv-consulta'
MAX_VOLTAS = 12 if DUP else 10       # duplicidade passa pela Receita (Etapa 3): mais lenta

JS_ESTADO = r"""
// Cabeça do laço: chega do "3 · Pedir" (1ª vez) ou do "7 · Status" (voltas). Decide: fim (gravar) ou esperar mais.
const r = $input.first().json || {};
const alvo = $('2 · Supabase pendentes').first().json;
const sc = r.statusCode || 0;
const b = (r.body && typeof r.body === 'object') ? r.body : (r.statusCode ? {} : r);
const volta = $runIndex;
let fim = false, saida = null, erro = null, ocupado = false;
if (sc && sc !== 200 && sc !== 202) {
  fim = true;
  if (sc === 429 || sc >= 500) { saida = { retry: true }; ocupado = true; }   // operador ocupado/fora: volta para a fila
  else { saida = { resultado: 'erro', motivo: 'HTTP ' + sc + ' ' + String(b.error || '').slice(0, 150) }; erro = saida.motivo; }
} else if (b.estado === 'pronto' || b.estado === 'erro') {
  fim = true; saida = b;
} else if (volta >= %MAX%) {
  fim = true; saida = { resultado: 'nao_classificado', motivo: 'o portal demorou mais que o n8n espera' };
}
return [{ json: { fim, ocupado, conversa_id: alvo.conversa_id, job_id: b.job_id || $json.job_id || null, saida, erro, volta } }];
"""


def build(ids):
    cred = ids.get('credenciais', {})
    sb_cred = {'supabaseApi': {'id': cred.get('supabase', ''), 'name': dm.CRED_SUPABASE}}
    te_cred = {'httpHeaderAuth': {'id': cred.get('teste', ''), 'name': dm.CRED_TESTE}}
    nodes = []

    def add(name, ntype, ver, params, x, y, **extra):
        n = {'parameters': params, 'name': name, 'type': ntype, 'typeVersion': ver, 'position': [x, y],
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/{WF_NOME}/{name}'))}
        n.update(extra)
        nodes.append(n)

    def http(name, url, body, x, y, full=False, timeout=30000, **extra):
        opts = {'timeout': timeout}
        if full:
            opts['response'] = {'response': {'fullResponse': True, 'neverError': True}}
        add(name, 'n8n-nodes-base.httpRequest', 4.2, {
            'method': 'POST', 'url': url, 'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
            'sendBody': True, 'specifyBody': 'json', 'jsonBody': body, 'options': opts}, x, y, credentials=sb_cred, **extra)

    def se(name, expr, x, y):
        add(name, 'n8n-nodes-base.if', 2, {
            'conditions': {'options': {'caseSensitive': True, 'leftValue': '', 'typeValidation': 'loose'},
                           'conditions': [{'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'{WF_NOME}/{name}')), 'leftValue': expr,
                                           'rightValue': '', 'operator': {'type': 'boolean', 'operation': 'true', 'singleValue': True}}],
                           'combinator': 'and'}, 'options': {}}, x, y)

    add('1 · a cada 2 min', 'n8n-nodes-base.scheduleTrigger', 1.2,
        {'rule': {'interval': [{'field': 'cronExpression', 'expression': ('1-59/2' if DUP else '*/2') + ' 7-23 * * *'}]}}, 0, 0)
    add('1t · rota de teste', 'n8n-nodes-base.webhook', 2,
        {'httpMethod': 'POST', 'path': ROTA_TESTE, 'authentication': 'headerAuth', 'responseMode': 'lastNode', 'options': {}},
        0, 200, credentials=te_cred, webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/{WF_NOME}/webhook')))
    if DUP:
        http('2 · Supabase pendentes', f'{dm.SB}/rest/v1/rpc/mari_dup_pendentes', '={{ JSON.stringify({ p_limite: 1 }) }}', 240, 100,
             retryOnFail=True, maxTries=2, waitBetweenTries=5000)
        http('3 · Pedir ao portal', EDGE_CRED, "={{ JSON.stringify({ acao: 'duplicidade', cpf: $json.cpf }) }}", 480, 100,
             full=True, onError='continueRegularOutput')
    else:
        http('2 · Supabase pendentes', f'{dm.SB}/rest/v1/rpc/mari_viab_pendentes', '={{ JSON.stringify({ p_limite: 1 }) }}', 240, 100,
             retryOnFail=True, maxTries=2, waitBetweenTries=5000)
        http('3 · Pedir ao portal', EDGE_CRED,
             "={{ JSON.stringify({ acao: 'viabilidade', endereco: { cep: $json.cep, numero: $json.numero, complemento: $json.complemento } }) }}",
             480, 100, full=True, onError='continueRegularOutput')
    add('4 · Estado', 'n8n-nodes-base.code', 2, {'jsCode': JS_ESTADO.replace('%MAX%', str(MAX_VOLTAS)).strip()}, 720, 100)
    se('5 · Terminou?', '={{ $json.fim }}', 940, 100)
    add('6 · Espera 12 s', 'n8n-nodes-base.wait', 1.1, {'amount': 12, 'unit': 'seconds'}, 1160, 260,
        webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/{WF_NOME}/espera')))
    http('7 · Status', EDGE_CRED, "={{ JSON.stringify({ acao: 'status', job_id: $json.job_id }) }}", 1380, 260, full=True,
         onError='continueRegularOutput')
    if DUP:
        http('8 · Supabase gravar', f'{dm.SB}/rest/v1/rpc/mari_dup_gravar',
             '={{ JSON.stringify({ p_conversa: $json.conversa_id, p_saida: $json.saida }) }}', 1160, 0,
             retryOnFail=True, maxTries=2, waitBetweenTries=5000)
    else:
        se('5b · Consultar o DFV?', '={{ !$json.ocupado }}', 1160, 0)
        a = "$('2 · Supabase pendentes').first().json"
        http('5c · DFV', EDGE_DFV,
             f"={{{{ JSON.stringify({{ cep: {a}.cep, numero: {a}.numero, complemento: {a}.complemento, uf: {a}.uf, municipio: {a}.municipio }}) }}}}",
             1380, -100, full=True, timeout=20000, onError='continueRegularOutput')
        http('8 · Supabase gravar', f'{dm.SB}/rest/v1/rpc/mari_viab_gravar',
             "={{ JSON.stringify({ p_conversa: $('4 · Estado').last().json.conversa_id, p_saida: $('4 · Estado').last().json.saida, "
             "p_dfv: ($json.statusCode === 200 && $json.body && typeof $json.body === 'object') ? $json.body : null, "
             "p_erro: $('4 · Estado').last().json.erro }) }}", 1600, 0, retryOnFail=True, maxTries=2, waitBetweenTries=5000)

    ligacoes = [('1 · a cada 2 min', '2 · Supabase pendentes'), ('1t · rota de teste', '2 · Supabase pendentes'),
                ('2 · Supabase pendentes', '3 · Pedir ao portal'), ('3 · Pedir ao portal', '4 · Estado'),
                ('4 · Estado', '5 · Terminou?'), ('6 · Espera 12 s', '7 · Status'), ('7 · Status', '4 · Estado')]
    if not DUP:
        ligacoes.append(('5c · DFV', '8 · Supabase gravar'))
    conns = {}
    for o, d in ligacoes:
        conns.setdefault(o, {'main': [[]]})['main'][0].append({'node': d, 'type': 'main', 'index': 0})
    destino_fim = '8 · Supabase gravar' if DUP else '5b · Consultar o DFV?'
    conns['5 · Terminou?'] = {'main': [[{'node': destino_fim, 'type': 'main', 'index': 0}],
                                       [{'node': '6 · Espera 12 s', 'type': 'main', 'index': 0}]]}
    if not DUP:   # operador ocupado: grava o "retry" sem DFV (a conversa volta para a fila)
        conns['5b · Consultar o DFV?'] = {'main': [[{'node': '5c · DFV', 'type': 'main', 'index': 0}],
                                                   [{'node': '8 · Supabase gravar', 'type': 'main', 'index': 0}]]}
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


def cmd_criar():
    ids = dm.ler_ids()
    if ids.get(ID_KEY):
        raise SystemExit(f'já existe {ID_KEY} {ids[ID_KEY]} — nada foi criado.')
    if any(w.get('name') == WF_NOME for w in dm.api('GET', '/workflows?limit=250').get('data', [])):
        raise SystemExit(f'já existe um workflow chamado {WF_NOME} no n8n — nada foi criado.')
    wf = build(ids)
    dm.checar_sem_segredo(wf)
    r = dm.api('POST', '/workflows', wf)
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
    dm.api('POST', f'/workflows/{ids[ID_KEY]}/{"activate" if ligar else "deactivate"}')
    print('active:', dm.api('GET', f'/workflows/{ids[ID_KEY]}').get('active'))
    cmd_exportar()


def cmd_exportar():
    salvar(dm.api('GET', f'/workflows/{dm.ler_ids()[ID_KEY]}'))


def cmd_rodar():
    import urllib.request
    import urllib.error
    segredo = dm.env_usuario('MARI_TESTE_SECRET')
    req = urllib.request.Request(f'{dm.N8N}/webhook/{ROTA_TESTE}', data=b'{}', method='POST',
                                 headers={dm.HEADER_TESTE: segredo, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            print(r.read().decode()[:1500])
    except urllib.error.HTTPError as e:
        raise SystemExit(f'HTTP {e.code}: {e.read().decode()[:800]}')


if __name__ == '__main__':
    acoes = {'build': lambda: salvar(build(dm.ler_ids())), 'criar': cmd_criar, 'estrutura': cmd_estrutura,
             'ativar': cmd_ativar, 'desativar': lambda: cmd_ativar(False), 'exportar': cmd_exportar, 'rodar': cmd_rodar}
    if len(sys.argv) < 2 or sys.argv[1] not in acoes:
        raise SystemExit('uso: [--dup] ' + ' | '.join(acoes))
    acoes[sys.argv[1]]()

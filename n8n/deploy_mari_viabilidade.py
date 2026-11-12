#!/usr/bin/env python3
# NIOGEN | n8n/deploy_mari_viabilidade.py | 12/11/2026 — Claude Code (achado 1 da 1ª auditoria da Mari; Ricardo: "Sim, ataca")
# Workflow n8n "mari_viabilidade": a cada 2 min (7h–23h) pega 1 conversa da Mari com endereço confirmado e sem viabilidade
# (mari_viab_pendentes, migration 0131), pede a viabilidade oficial ao operador do portal pela edge credito-consulta
# (acao 'viabilidade' — Etapas 0–2, SEM CPF, para no modal; cache 6 h; teto de 60/h dividido com a tela Cobertura), espera o
# resultado (status a cada 12 s, até ~2 min) e grava (mari_viab_gravar: mari_conversas.nio_viab_* + nio_viab_log).
# A Mari já lê nio_viab_resultado (Bloco 9) e o handoff já leva para a venda. Nada sai para cliente. Operador ocupado ou fora
# do ar → a conversa volta para a fila (retry), sem log.
#
# Credenciais (só IDs/nomes): "Supabase Nio (service role)" (a edge aceita a service role só para viabilidade/status — 0131),
# "MARI_TESTE_SECRET" (rota de teste). Chave do n8n: N8N_API_KEY_NIO.
#
# Uso: python n8n/deploy_mari_viabilidade.py build | criar | estrutura | ativar | desativar | exportar | rodar

import datetime
import json
import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_mari as dm   # noqa: E402

AQUI = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(AQUI)
EXPORT = os.path.join(AQUI, 'mari_viabilidade.json')
WF_NOME = 'mari_viabilidade'
ID_KEY = 'mari_viabilidade_workflow_id'
ROTA_TESTE = 'niogen-mari-viabilidade-teste'
EDGE = f'{dm.SB}/functions/v1/credito-consulta'
MAX_VOLTAS = 10          # 10 × 12 s ≈ 2 min esperando o operador

JS_ESTADO = r"""
// Cabeça do laço: chega do "3 · Pedir" (1ª vez) ou do "7 · Status" (voltas). Decide: fim (gravar) ou esperar mais.
const r = $input.first().json || {};
const alvo = $('2 · Supabase pendentes').first().json;
const sc = r.statusCode || 0;
const b = (r.body && typeof r.body === 'object') ? r.body : (r.statusCode ? {} : r);
const volta = $runIndex;
let fim = false, saida = null, erro = null;
if (sc && sc !== 200 && sc !== 202) {
  // 429 (fila/teto), 5xx, 503 (operador fora): volta para a fila. Outros 4xx: grava indisponível com o motivo.
  fim = true;
  if (sc === 429 || sc >= 500) saida = { retry: true };
  else { saida = { resultado: 'erro', motivo: 'HTTP ' + sc + ' ' + String(b.error || '').slice(0, 150) }; erro = saida.motivo; }
} else if (b.estado === 'pronto' || b.estado === 'erro') {
  fim = true; saida = b;
} else if (volta >= %MAX%) {
  fim = true; saida = { retry: true };    // o operador segue e guarda em cache 6 h: a próxima rodada pega pronto
}
return [{ json: { fim, conversa_id: alvo.conversa_id, job_id: b.job_id || $json.job_id || null, saida, erro, volta } }];
"""


def build(ids):
    cred = ids.get('credenciais', {})
    sb_cred = {'supabaseApi': {'id': cred.get('supabase', ''), 'name': dm.CRED_SUPABASE}}
    te_cred = {'httpHeaderAuth': {'id': cred.get('teste', ''), 'name': dm.CRED_TESTE}}
    nodes = []

    def add(name, ntype, ver, params, x, y, **extra):
        n = {'parameters': params, 'name': name, 'type': ntype, 'typeVersion': ver, 'position': [x, y],
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/mari_viabilidade/{name}'))}
        n.update(extra)
        nodes.append(n)

    def http(name, url, body, x, y, full=False, **extra):
        opts = {'timeout': 30000}
        if full:
            opts['response'] = {'response': {'fullResponse': True, 'neverError': True}}
        add(name, 'n8n-nodes-base.httpRequest', 4.2, {
            'method': 'POST', 'url': url, 'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
            'sendBody': True, 'specifyBody': 'json', 'jsonBody': body, 'options': opts}, x, y, credentials=sb_cred, **extra)

    add('1 · a cada 2 min', 'n8n-nodes-base.scheduleTrigger', 1.2,
        {'rule': {'interval': [{'field': 'cronExpression', 'expression': '*/2 7-23 * * *'}]}}, 0, 0)
    add('1t · rota de teste', 'n8n-nodes-base.webhook', 2,
        {'httpMethod': 'POST', 'path': ROTA_TESTE, 'authentication': 'headerAuth', 'responseMode': 'lastNode', 'options': {}},
        0, 200, credentials=te_cred, webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, 'niogen/mari_viabilidade/webhook')))
    http('2 · Supabase pendentes', f'{dm.SB}/rest/v1/rpc/mari_viab_pendentes', '={{ JSON.stringify({ p_limite: 1 }) }}', 240, 100,
         retryOnFail=True, maxTries=2, waitBetweenTries=5000)
    http('3 · Pedir viabilidade', EDGE,
         "={{ JSON.stringify({ acao: 'viabilidade', endereco: { cep: $json.cep, numero: $json.numero, complemento: $json.complemento } }) }}",
         480, 100, full=True, onError='continueRegularOutput')
    add('4 · Estado', 'n8n-nodes-base.code', 2, {'jsCode': JS_ESTADO.replace('%MAX%', str(MAX_VOLTAS)).strip()}, 720, 100)
    add('5 · Terminou?', 'n8n-nodes-base.if', 2, {
        'conditions': {'options': {'caseSensitive': True, 'leftValue': '', 'typeValidation': 'loose'},
                       'conditions': [{'id': str(uuid.uuid5(uuid.NAMESPACE_URL, 'mari_viab/fim')), 'leftValue': '={{ $json.fim }}',
                                       'rightValue': '', 'operator': {'type': 'boolean', 'operation': 'true', 'singleValue': True}}],
                       'combinator': 'and'}, 'options': {}}, 940, 100)
    add('6 · Espera 12 s', 'n8n-nodes-base.wait', 1.1, {'amount': 12, 'unit': 'seconds'}, 1160, 260,
        webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, 'niogen/mari_viabilidade/espera')))
    http('7 · Status', EDGE, "={{ JSON.stringify({ acao: 'status', job_id: $json.job_id }) }}", 1380, 260, full=True,
         onError='continueRegularOutput')
    http('8 · Supabase gravar', f'{dm.SB}/rest/v1/rpc/mari_viab_gravar',
         '={{ JSON.stringify({ p_conversa: $json.conversa_id, p_saida: $json.saida, p_erro: $json.erro }) }}', 1160, 0,
         retryOnFail=True, maxTries=2, waitBetweenTries=5000)

    ligacoes = [('1 · a cada 2 min', '2 · Supabase pendentes'), ('1t · rota de teste', '2 · Supabase pendentes'),
                ('2 · Supabase pendentes', '3 · Pedir viabilidade'), ('3 · Pedir viabilidade', '4 · Estado'),
                ('4 · Estado', '5 · Terminou?'), ('6 · Espera 12 s', '7 · Status'), ('7 · Status', '4 · Estado')]
    conns = {}
    for o, d in ligacoes:
        conns.setdefault(o, {'main': [[]]})['main'][0].append({'node': d, 'type': 'main', 'index': 0})
    conns['5 · Terminou?'] = {'main': [[{'node': '8 · Supabase gravar', 'type': 'main', 'index': 0}],
                                       [{'node': '6 · Espera 12 s', 'type': 'main', 'index': 0}]]}
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
        raise SystemExit('uso: ' + ' | '.join(acoes))
    acoes[sys.argv[1]]()

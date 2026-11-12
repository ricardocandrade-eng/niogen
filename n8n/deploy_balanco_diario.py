#!/usr/bin/env python3
# NIOGEN | n8n/deploy_balanco_diario.py | 11/11/2026 — Claude Code (Ricardo, 11/11 ~22h: balanço diário pela API do Claude, "n8n + API do Claude")
# Workflow n8n "balanco_diario": às 7h45 (seg–sáb, fuso de São Paulo) chama balanco_diario_entrada() no Supabase Nio (migration 0127 —
# números de ontem e as conversas com cliente esperando o time há mais de resumo_parada_horas, com as últimas falas), pede ao Claude
# (Opus 5.5, saída em JSON pelo schema abaixo) a situação, a ação e a resposta sugerida de cada uma, e grava em balanco_diario.
# Quem avisa é o resumo das 8h (resumo_diario): a linha "Paradas" do WhatsApp ganha " · balanço: N com resposta sugerida no Painel".
# Não fala com cliente: nada sai para WhatsApp/Chatwoot daqui. Sem conversa parada, grava a linha sem chamar o Claude.
#
# Credenciais (só IDs/nomes, nunca valores): "Supabase Nio (service role)", "Claude API Nio". Chave da API do n8n: N8N_API_KEY_NIO.
# Fallback de recusa do lado da API ligado (beta server-side-fallback-2026-07-01, fallbacks "default").
#
# Uso:
#   python n8n/deploy_balanco_diario.py build      # gera n8n/balanco_diario.json (export, sem segredos)
#   python n8n/deploy_balanco_diario.py criar      # cria o workflow INATIVO; falha se o nome já existe
#   python n8n/deploy_balanco_diario.py estrutura  # PUT do workflow inteiro, backup antes (mantém o active atual)
#   python n8n/deploy_balanco_diario.py ativar     # liga
#   python n8n/deploy_balanco_diario.py desativar  # desliga
#   python n8n/deploy_balanco_diario.py rodar      # roda agora pela rota de teste e mostra a linha gravada
#   python n8n/deploy_balanco_diario.py exportar   # baixa o estado atual e grava o export sanitizado

import datetime
import json
import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_mari as dm   # noqa: E402  (api, ids, checagem de segredo)

AQUI = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(AQUI)
EXPORT = os.path.join(AQUI, 'balanco_diario.json')
WF_NOME = 'balanco_diario'
ID_KEY = 'balanco_diario_workflow_id'
MODELO = 'claude-opus-5-5'
ROTA_TESTE = 'niogen-balanco-diario-teste'

SISTEMA = """Você ajuda o backoffice de uma revenda credenciada (PAP) da Nio Internet a não deixar cliente esperando.
Recebe, em JSON, as conversas de WhatsApp em que o cliente mandou a última mensagem e ninguém do time respondeu há horas.
Para cada conversa, leia as últimas falas e o resumo da Mari (a assistente de IA que atende primeiro) e devolva:
- situacao: o que está acontecendo, em uma frase curta (quem é, o que quer, onde travou).
- urgencia: "alta" (venda em risco, cliente irritado ou esperando muito), "media" ou "baixa" (só agradeceu, só confirmou).
- acao: o que o time deve fazer agora, em uma frase (ex.: consultar crédito com outro CPF, ouvir os áudios, confirmar o turno).
- resposta_sugerida: a mensagem pronta para colar no WhatsApp, em português do Brasil, curta, humana, sem formalidade excessiva,
  no máximo um emoji. Peça desculpas pela demora quando a espera passar de 2 horas.

Regras que a resposta NUNCA pode quebrar (contrato com a Nio):
- Nunca ofereça desconto, brinde, prazo ou benefício. Só cite plano e valor que já apareceram na conversa; na dúvida, não cite valor.
- Nunca prometa data ou horário de instalação: diga que o time confirma a data assim que a Nio liberar a agenda.
- A venda é 100 % remota: o pedido é aberto no sistema da Nio e a própria Nio manda o link da biometria por WhatsApp e e-mail.
- Cliente que já é Nio e quer suporte ou reclamar: somos revenda, não o suporte. Indique o App Nio, o atendimento 0800 001 1000,
  o WhatsApp oficial (21) 3605-1000 ou a Ouvidoria 0800 001 0646.
- Crédito aprovado "só no cartão" e cliente sem cartão: a saída possível é outra pessoa da casa ser a titular (com autorização dela).
- Não invente dado que não está na conversa. Se faltar informação para responder, a resposta pede essa informação ao cliente.
- [MIDIA:audio] é um áudio que você não ouviu: diga na ação que o time precisa ouvir antes de responder.

Também devolva resumo: 1 ou 2 frases para o dono da empresa, com os números do dia e o que mais pede atenção.
Ordene os itens da maior para a menor urgência."""

SCHEMA = {
    'type': 'object', 'additionalProperties': False, 'required': ['resumo', 'itens'],
    'properties': {
        'resumo': {'type': 'string'},
        'itens': {'type': 'array', 'items': {
            'type': 'object', 'additionalProperties': False,
            'required': ['conversa_id', 'nome', 'urgencia', 'situacao', 'acao', 'resposta_sugerida'],
            'properties': {
                'conversa_id': {'type': 'string'}, 'nome': {'type': 'string'},
                'urgencia': {'type': 'string', 'enum': ['alta', 'media', 'baixa']},
                'situacao': {'type': 'string'}, 'acao': {'type': 'string'}, 'resposta_sugerida': {'type': 'string'}}}}},
}

JS_MONTAR = r"""
const e = $input.first().json;
const conversas = e.conversas || [];
const pedido = {
  model: %MODELO%, max_tokens: 16000,
  fallbacks: 'default',
  output_config: { effort: 'medium', format: { type: 'json_schema', schema: %SCHEMA% } },
  system: %SISTEMA%,
  messages: [{ role: 'user', content: 'Agora: ' + e.agora + '. Parada = cliente esperando há mais de ' + e.horas_parada + ' h.\n'
    + 'Números: ' + JSON.stringify(e.numeros) + '\n\nConversas paradas:\n' + JSON.stringify(conversas) }],
};
return [{ json: { tem: conversas.length > 0, n: conversas.length, numeros: e.numeros, pedido } }];
"""

JS_LER = r"""
const m = $('3 · Montar pedido').first().json;
const r = $input.first().json || {};
let resumo = null, itens = [], erro = null;
if (r.error) erro = 'API do Claude: ' + (r.error.message || JSON.stringify(r.error)).slice(0, 300);
else if (r.stop_reason === 'refusal') erro = 'Claude recusou (' + ((r.stop_details || {}).category || 'sem categoria') + ')';
else if (r.stop_reason === 'max_tokens') erro = 'resposta cortada (max_tokens)';
else {
  const t = (r.content || []).find((b) => b.type === 'text');
  try { const j = JSON.parse(t ? t.text : ''); resumo = j.resumo; itens = j.itens || []; }
  catch (x) { erro = 'JSON inválido na resposta do Claude'; }
}
const u = r.usage || {};
return [{ json: { linha: { modelo: r.model || null, tokens_in: u.input_tokens || null, tokens_out: u.output_tokens || null,
  resumo, itens, erro } } }];
"""

JS_VAZIO = r"""
const m = $input.first().json;
const n = m.numeros || {};
return [{ json: { linha: { modelo: null, tokens_in: null, tokens_out: null, itens: [], erro: null,
  resumo: 'Nenhuma conversa parada. Ontem: ' + (n.leads_ontem ?? '?') + ' lead(s); Mari respondeu ' + (n.mari_respostas_24h ?? '?')
    + ' vez(es) em 24 h (média ' + (n.mari_latencia_media_s ?? '?') + ' s).' } } }];
"""


def js(t):
    return (t.replace('%MODELO%', json.dumps(MODELO)).replace('%SCHEMA%', json.dumps(SCHEMA, ensure_ascii=False))
             .replace('%SISTEMA%', json.dumps(SISTEMA, ensure_ascii=False))).strip()


def build(ids):
    cred = ids.get('credenciais', {})
    sb_cred = {'supabaseApi': {'id': cred.get('supabase', ''), 'name': dm.CRED_SUPABASE}}
    cl_cred = {'anthropicApi': {'id': cred.get('claude', ''), 'name': dm.CRED_CLAUDE}}
    te_cred = {'httpHeaderAuth': {'id': cred.get('teste', ''), 'name': dm.CRED_TESTE}}
    if not cred.get('claude'):
        raise SystemExit('credencial "Claude API Nio" ausente em mari_ids.json — nada gerado.')
    nodes = []

    def add(name, ntype, ver, params, x, y, **extra):
        n = {'parameters': params, 'name': name, 'type': ntype, 'typeVersion': ver, 'position': [x, y],
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/balanco_diario/{name}'))}
        n.update(extra)
        nodes.append(n)

    add('1 · 7h45 seg–sáb', 'n8n-nodes-base.scheduleTrigger', 1.2,
        {'rule': {'interval': [{'field': 'cronExpression', 'expression': '45 7 * * 1-6'}]}}, 0, 0,
        notes='Antes do resumo das 8h, que avisa no WhatsApp quantas respostas sugeridas há no Painel.', notesInFlow=True)
    add('1t · rota de teste', 'n8n-nodes-base.webhook', 2,
        {'httpMethod': 'POST', 'path': ROTA_TESTE, 'authentication': 'headerAuth', 'responseMode': 'lastNode', 'options': {}},
        0, 200, credentials=te_cred, webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, 'niogen/balanco_diario/webhook')))
    add('2 · Supabase entrada', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{dm.SB}/rest/v1/rpc/balanco_diario_entrada',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': '={{ JSON.stringify({}) }}',
        'options': {'timeout': 30000}}, 240, 100, credentials=sb_cred, retryOnFail=True, maxTries=2, waitBetweenTries=5000)
    add('3 · Montar pedido', 'n8n-nodes-base.code', 2, {'jsCode': js(JS_MONTAR)}, 480, 100)
    add('4 · Tem conversa parada?', 'n8n-nodes-base.if', 2, {
        'conditions': {'options': {'caseSensitive': True, 'leftValue': '', 'typeValidation': 'strict'},
                       'conditions': [{'id': str(uuid.uuid5(uuid.NAMESPACE_URL, 'balanco/tem')), 'leftValue': '={{ $json.tem }}',
                                       'rightValue': '', 'operator': {'type': 'boolean', 'operation': 'true', 'singleValue': True}}],
                       'combinator': 'and'}, 'options': {}}, 720, 100)
    add('5 · Claude', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': 'https://api.anthropic.com/v1/messages',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'anthropicApi',
        'sendHeaders': True,
        'headerParameters': {'parameters': [{'name': 'anthropic-version', 'value': '2023-06-01'},
                                            {'name': 'anthropic-beta', 'value': 'server-side-fallback-2026-07-01'}]},
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': '={{ JSON.stringify($json.pedido) }}',
        'options': {'timeout': 240000, 'response': {'response': {'neverError': True}}}}, 960, 0, credentials=cl_cred,
        onError='continueRegularOutput', retryOnFail=True, maxTries=2, waitBetweenTries=10000,
        notes='Opus 5.5, effort medium, saída JSON pelo schema. Thinking não é desligável neste modelo: o texto é o bloco type=text.',
        notesInFlow=True)
    add('6 · Ler resposta', 'n8n-nodes-base.code', 2, {'jsCode': js(JS_LER)}, 1200, 0)
    add('6b · Sem conversa parada', 'n8n-nodes-base.code', 2, {'jsCode': js(JS_VAZIO)}, 960, 220)
    add('7 · Supabase gravar', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{dm.SB}/rest/v1/balanco_diario',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'sendHeaders': True, 'headerParameters': {'parameters': [{'name': 'Prefer', 'value': 'return=representation'}]},
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': '={{ JSON.stringify($json.linha) }}',
        'options': {'timeout': 20000}}, 1440, 100, credentials=sb_cred, retryOnFail=True, maxTries=2, waitBetweenTries=5000)

    ligacoes = [('1 · 7h45 seg–sáb', '2 · Supabase entrada', 0), ('1t · rota de teste', '2 · Supabase entrada', 0),
                ('2 · Supabase entrada', '3 · Montar pedido', 0), ('3 · Montar pedido', '4 · Tem conversa parada?', 0),
                ('5 · Claude', '6 · Ler resposta', 0), ('6 · Ler resposta', '7 · Supabase gravar', 0),
                ('6b · Sem conversa parada', '7 · Supabase gravar', 0)]
    conns = {}
    for o, d, _ in ligacoes:
        conns.setdefault(o, {'main': [[]]})['main'][0].append({'node': d, 'type': 'main', 'index': 0})
    conns['4 · Tem conversa parada?'] = {'main': [[{'node': '5 · Claude', 'type': 'main', 'index': 0}],
                                                   [{'node': '6b · Sem conversa parada', 'type': 'main', 'index': 0}]]}
    settings = {'executionOrder': 'v1', 'saveDataErrorExecution': 'all', 'saveDataSuccessExecution': 'all',
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
    existentes = dm.api('GET', '/workflows?limit=250').get('data', [])
    if any(w.get('name') == WF_NOME for w in existentes):
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
    ids = dm.ler_ids()
    salvar(dm.api('GET', f'/workflows/{ids[ID_KEY]}'))


def cmd_rodar():
    import urllib.request
    import urllib.error
    segredo = dm.env_usuario('MARI_TESTE_SECRET')
    if not segredo:
        raise SystemExit('MARI_TESTE_SECRET ausente.')
    req = urllib.request.Request(f'{dm.N8N}/webhook/{ROTA_TESTE}', data=b'{}', method='POST',
                                 headers={dm.HEADER_TESTE: segredo, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            corpo = json.loads(r.read().decode() or 'null')
    except urllib.error.HTTPError as e:
        raise SystemExit(f'HTTP {e.code}: {e.read().decode()[:800]}')
    linha = corpo[0] if isinstance(corpo, list) and corpo else corpo
    print(json.dumps({k: linha.get(k) for k in ('id', 'dia', 'modelo', 'tokens_in', 'tokens_out', 'erro', 'resumo')},
                     ensure_ascii=False, indent=1))
    for i in linha.get('itens') or []:
        print(f"- [{i.get('urgencia')}] {i.get('nome')}: {i.get('situacao')}\n    ação: {i.get('acao')}\n    resposta: {i.get('resposta_sugerida')}")


if __name__ == '__main__':
    acoes = {'build': cmd_build, 'criar': cmd_criar, 'estrutura': cmd_estrutura, 'ativar': cmd_ativar,
             'desativar': lambda: cmd_ativar(False), 'exportar': cmd_exportar, 'rodar': cmd_rodar}
    if len(sys.argv) < 2 or sys.argv[1] not in acoes:
        raise SystemExit('uso: ' + ' | '.join(acoes))
    acoes[sys.argv[1]]()

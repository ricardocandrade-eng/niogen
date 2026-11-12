#!/usr/bin/env python3
# NIOGEN | n8n/deploy_auditoria_mari.py | 12/11/2026 — Claude Code (Ricardo, 12/11 ~01h20: auditoria das conversas da Mari, "pode ser via Sonnet")
# Workflow n8n "auditoria_mari": lê o comportamento da Mari nas conversas (falhas de prompt, contrato, venda perdida, cadência e
# templates, handoff, erros) e grava achados com evidência e a correção sugerida no prompt, em auditoria_mari (migration 0130).
#   · 7h30 seg–sáb: auditoria diária (desde o fim da última diária, até 72 h).
#   · a cada 2 min, 8h–22h: pega o pedido feito no NIOGEN (tela Mari › Auditoria / "Auditar esta conversa"); sem pedido, para no nó 3.
# O prompt da Mari em produção (mari/prompt_mari_v7.md, o mesmo do deploy_mari.py) vai embutido no system — redeploy quando o prompt mudar.
# Falas com CPF/telefone/e-mail mascarados no banco (_auditoria_mascarar). Nada sai para cliente.
#
# Credenciais (só IDs/nomes, nunca valores): "Supabase Nio (service role)", "Claude API Nio", "MARI_TESTE_SECRET". Chave do n8n: N8N_API_KEY_NIO.
#
# Uso:
#   python n8n/deploy_auditoria_mari.py build | criar | estrutura | ativar | desativar | exportar
#   python n8n/deploy_auditoria_mari.py rodar [diaria]   # rota de teste: "diaria" força a diária; sem nada, pega o próximo pedido

import datetime
import json
import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_mari as dm   # noqa: E402  (api, ids, checagem de segredo, ler_prompt)

AQUI = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(AQUI)
EXPORT = os.path.join(AQUI, 'auditoria_mari.json')
WF_NOME = 'auditoria_mari'
ID_KEY = 'auditoria_mari_workflow_id'
MODELO = 'claude-sonnet-5-5'
ROTA_TESTE = 'niogen-auditoria-mari-teste'

SISTEMA = """Você audita a Mari, assistente de IA que atende no WhatsApp os leads de uma revenda credenciada (PAP) da Nio Internet
(fibra). O objetivo da Mari é VENDA QUALIFICADA: cliente com cobertura, plano escolhido, dados completos e pedido aberto pelo time,
com a biometria disparada pela Nio. Você recebe o prompt de sistema que a Mari usa hoje e, em JSON, as conversas do período
(falas do lead, da Mari, do time humano e do sistema, com as tags que a Mari emitiu), os erros do fluxo e os números.

Procure, nesta ordem de importância:
1. venda_perdida — lead com intenção que esfriou por culpa da Mari: não respondeu a pergunta, insistiu no que o cliente já disse,
   encerrou na objeção sem contornar, demorou, mandou texto longo demais, fez handoff cedo/tarde demais, não retomou.
2. contrato — fala que quebra o contrato com a Nio: desconto, brinde, prazo ou benefício fora da tabela; promessa de data de
   instalação; preço diferente da tabela citada na conversa; venda a quem já é cliente Nio; biometria/visita em campo.
3. prompt — instrução do prompt que a Mari não seguiu, que se contradiz, que falta, ou que leva ao erro. Diga o trecho.
4. cadencia_template — toque da cadência (tags.cadencia F1/F2…) fora de hora, repetido, sem sentido para o momento da conversa,
   cliente que pediu para parar e foi tocado de novo, retomada que não aconteceu.
5. handoff — passou para humano sem motivo, deixou de passar quando devia (pedido de humano, reclamação, desconto, urgência),
   ou o time humano deixou o cliente sem resposta depois do handoff.
6. erro_tecnico — erros do fluxo que afetaram a conversa (filtro de saída, resposta vazia, falha da API, carrossel errado).
7. tom — robótico, frio, formal demais, repetitivo, emojis demais.

Regras da sua resposta:
- Só aponte o que tem evidência nas falas. Cite a fala (curta) e o conversa_id. Não invente. Junte casos iguais num achado só.
- Para cada achado, diga a correção: de preferência a mudança no prompt (o trecho atual e como deve ficar); se não for prompt,
  a mudança no fluxo ou no processo do time.
- [MIDIA:audio] é áudio que ninguém transcreveu — não conclua o conteúdo.
- Os textos [CPF], [telefone], [e-mail] são dados mascarados de propósito — não é falha.
- Falas com tags.simulado=true ou de telefones de teste podem ser testes do time: considere, mas diga se for o caso.
- Português do Brasil, direto, para o dono da empresa. No máximo 12 achados, do mais grave para o menos grave.
- resumo: 2 ou 3 frases com o estado geral e o que mais custa venda. bons: até 3 coisas que a Mari fez bem e devem ficar.
- nota: 0 a 10 para o atendimento da Mari no período."""

SCHEMA = {
    'type': 'object', 'additionalProperties': False, 'required': ['resumo', 'nota', 'achados', 'bons'],
    'properties': {
        'resumo': {'type': 'string'},
        'nota': {'type': 'integer'},
        'bons': {'type': 'array', 'items': {'type': 'string'}},
        'achados': {'type': 'array', 'items': {
            'type': 'object', 'additionalProperties': False,
            'required': ['gravidade', 'tipo', 'titulo', 'o_que_aconteceu', 'evidencia', 'conversa_ids', 'correcao', 'trecho_prompt'],
            'properties': {
                'gravidade': {'type': 'string', 'enum': ['alta', 'media', 'baixa']},
                'tipo': {'type': 'string', 'enum': ['venda_perdida', 'contrato', 'prompt', 'cadencia_template', 'handoff',
                                                    'erro_tecnico', 'tom']},
                'titulo': {'type': 'string'}, 'o_que_aconteceu': {'type': 'string'}, 'evidencia': {'type': 'string'},
                'conversa_ids': {'type': 'array', 'items': {'type': 'string'}},
                'correcao': {'type': 'string'}, 'trecho_prompt': {'type': 'string'}}}}},
}

JS_MODO = r"""
let diaria = false;
try { diaria = $('1 · 7h30 diária').isExecuted; } catch (e) { diaria = false; }
try { if ($('1t · rota de teste').isExecuted) diaria = !!(($('1t · rota de teste').first().json.body || {}).diaria); } catch (e) {}
return [{ json: { p_diaria: diaria } }];
"""

JS_MONTAR = r"""
const e = $input.first().json;
const numeros = e.numeros || {};
if (!e.tem_conversa) {
  return [{ json: { chamar: false, id: e.id, linha: { modelo: null, tokens_in: null, tokens_out: null, achados: [], numeros,
    resumo: 'Nenhuma conversa da Mari no período (' + e.janela + ').', erro: null } } }];
}
const alvo = e.conversa_id ? ('a conversa ' + e.conversa_id + ' (até 7 dias)') : ('as conversas de ' + e.janela);
const pedido = {
  model: %MODELO%, max_tokens: 16000,
  output_config: { effort: 'medium', format: { type: 'json_schema', schema: %SCHEMA% } },
  system: [{ type: 'text', text: %SISTEMA% },
           { type: 'text', text: '<prompt_da_mari versao="' + %VERSAO% + '">\n' + %PROMPT% + '\n</prompt_da_mari>' }],
  messages: [{ role: 'user', content: 'Audite ' + alvo + '.\nNúmeros: ' + JSON.stringify(numeros)
    + '\n\nErros do fluxo:\n' + JSON.stringify(e.erros || []) + '\n\nConversas:\n' + JSON.stringify(e.conversas || []) }],
};
return [{ json: { chamar: true, id: e.id, numeros, pedido } }];
"""

JS_LER = r"""
const m = $('4 · Montar pedido').first().json;
const r = $input.first().json || {};
let resumo = null, achados = [], erro = null, nota = null, bons = [];
if (r.error) erro = 'API do Claude: ' + (r.error.message || JSON.stringify(r.error)).slice(0, 300);
else if (r.stop_reason === 'refusal') erro = 'Claude recusou (' + ((r.stop_details || {}).category || 'sem categoria') + ')';
else if (r.stop_reason === 'max_tokens') erro = 'resposta cortada (max_tokens)';
else {
  const t = (r.content || []).find((b) => b.type === 'text');
  try { const j = JSON.parse(t ? t.text : ''); resumo = j.resumo; achados = j.achados || []; nota = j.nota; bons = j.bons || []; }
  catch (x) { erro = 'JSON inválido na resposta do Claude'; }
}
const u = r.usage || {};
return [{ json: { id: m.id, linha: { modelo: r.model || null, tokens_in: u.input_tokens || null, tokens_out: u.output_tokens || null,
  resumo, achados, erro, numeros: Object.assign({}, m.numeros, { nota, bons }) } } }];
"""


def js(t):
    return (t.replace('%MODELO%', json.dumps(MODELO)).replace('%SCHEMA%', json.dumps(SCHEMA, ensure_ascii=False))
             .replace('%SISTEMA%', json.dumps(SISTEMA, ensure_ascii=False))
             .replace('%VERSAO%', json.dumps(dm.PROMPT_VERSAO))
             .replace('%PROMPT%', json.dumps(dm.ler_prompt(), ensure_ascii=False))).strip()


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
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/auditoria_mari/{name}'))}
        n.update(extra)
        nodes.append(n)

    def se(name, expr, x, y):
        add(name, 'n8n-nodes-base.if', 2, {
            'conditions': {'options': {'caseSensitive': True, 'leftValue': '', 'typeValidation': 'loose'},
                           'conditions': [{'id': str(uuid.uuid5(uuid.NAMESPACE_URL, 'auditoria/' + name)), 'leftValue': expr,
                                           'rightValue': '', 'operator': {'type': 'boolean', 'operation': 'true', 'singleValue': True}}],
                           'combinator': 'and'}, 'options': {}}, x, y)

    def rpc(name, fn, body, x, y):
        add(name, 'n8n-nodes-base.httpRequest', 4.2, {
            'method': 'POST', 'url': f'{dm.SB}/rest/v1/rpc/{fn}',
            'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
            'sendBody': True, 'specifyBody': 'json', 'jsonBody': body,
            'options': {'timeout': 60000}}, x, y, credentials=sb_cred, retryOnFail=True, maxTries=2, waitBetweenTries=5000)

    add('1 · 7h30 diária', 'n8n-nodes-base.scheduleTrigger', 1.2,
        {'rule': {'interval': [{'field': 'cronExpression', 'expression': '30 7 * * 1-6'}]}}, 0, 0)
    add('1p · pedidos a cada 2 min', 'n8n-nodes-base.scheduleTrigger', 1.2,
        {'rule': {'interval': [{'field': 'cronExpression', 'expression': '*/2 8-22 * * *'}]}}, 0, 160,
        notes='Pedido feito no NIOGEN (auditoria_mari_pedir). Sem pedido, o nó 3 encerra sem chamar o Claude.', notesInFlow=True)
    add('1t · rota de teste', 'n8n-nodes-base.webhook', 2,
        {'httpMethod': 'POST', 'path': ROTA_TESTE, 'authentication': 'headerAuth', 'responseMode': 'lastNode', 'options': {}},
        0, 320, credentials=te_cred, webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, 'niogen/auditoria_mari/webhook')))
    add('1m · Modo', 'n8n-nodes-base.code', 2, {'jsCode': JS_MODO.strip()}, 220, 160)
    rpc('2 · Supabase próximo', 'auditoria_mari_proximo', '={{ JSON.stringify({ p_diaria: $json.p_diaria }) }}', 440, 160)
    se('3 · Tem auditoria?', '={{ $json.tem }}', 660, 160)
    add('4 · Montar pedido', 'n8n-nodes-base.code', 2, {'jsCode': js(JS_MONTAR)}, 880, 100)
    se('4b · Chamar o Claude?', '={{ $json.chamar }}', 1100, 100)
    add('5 · Claude', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': 'https://api.anthropic.com/v1/messages',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'anthropicApi',
        'sendHeaders': True, 'headerParameters': {'parameters': [{'name': 'anthropic-version', 'value': '2023-06-01'}]},
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': '={{ JSON.stringify($json.pedido) }}',
        'options': {'timeout': 300000, 'response': {'response': {'neverError': True}}}}, 1320, 0, credentials=cl_cred,
        onError='continueRegularOutput', retryOnFail=True, maxTries=2, waitBetweenTries=10000,
        notes='Sonnet 5.5, effort medium, saída JSON pelo schema; o texto é o bloco type=text.', notesInFlow=True)
    add('6 · Ler resposta', 'n8n-nodes-base.code', 2, {'jsCode': js(JS_LER)}, 1540, 0)
    rpc('7 · Supabase gravar', 'auditoria_mari_gravar', '={{ JSON.stringify({ p_id: $json.id, p_linha: $json.linha }) }}', 1760, 100)

    ligacoes = [('1 · 7h30 diária', '1m · Modo'), ('1p · pedidos a cada 2 min', '1m · Modo'), ('1t · rota de teste', '1m · Modo'),
                ('1m · Modo', '2 · Supabase próximo'), ('2 · Supabase próximo', '3 · Tem auditoria?'),
                ('4 · Montar pedido', '4b · Chamar o Claude?'), ('5 · Claude', '6 · Ler resposta'),
                ('6 · Ler resposta', '7 · Supabase gravar')]
    conns = {}
    for o, d in ligacoes:
        conns.setdefault(o, {'main': [[]]})['main'][0].append({'node': d, 'type': 'main', 'index': 0})
    conns['3 · Tem auditoria?'] = {'main': [[{'node': '4 · Montar pedido', 'type': 'main', 'index': 0}], []]}
    conns['4b · Chamar o Claude?'] = {'main': [[{'node': '5 · Claude', 'type': 'main', 'index': 0}],
                                               [{'node': '7 · Supabase gravar', 'type': 'main', 'index': 0}]]}
    # Sucesso não fica salvo (a enquete de 2 min gera ~450 execuções/dia); erro fica e vai ao Error Trigger do mari_principal.
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
    corpo = json.dumps({'diaria': 'diaria' in sys.argv[2:]}).encode()
    req = urllib.request.Request(f'{dm.N8N}/webhook/{ROTA_TESTE}', data=corpo, method='POST',
                                 headers={dm.HEADER_TESTE: segredo, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=400) as r:
            print(r.read().decode()[:1500])
    except urllib.error.HTTPError as e:
        raise SystemExit(f'HTTP {e.code}: {e.read().decode()[:800]}')


if __name__ == '__main__':
    acoes = {'build': cmd_build, 'criar': cmd_criar, 'estrutura': cmd_estrutura, 'ativar': cmd_ativar,
             'desativar': lambda: cmd_ativar(False), 'exportar': cmd_exportar, 'rodar': cmd_rodar}
    if len(sys.argv) < 2 or sys.argv[1] not in acoes:
        raise SystemExit('uso: ' + ' | '.join(acoes))
    acoes[sys.argv[1]]()

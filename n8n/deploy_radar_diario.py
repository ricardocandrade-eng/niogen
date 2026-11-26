#!/usr/bin/env python3
# NIOGEN | n8n/deploy_radar_diario.py | 26/11/2026 — Claude Code / Opus 5.5 (Radar Nio — migration 0413)
# Workflow n8n "radar_diario": todo dia às 05h30 (Brasília), antes do expediente da Mari, pede ao operador do portal UMA rodada
# do Dashboard só com as abas do radar (dashboard_config('radar')): os DADOS RESUMIDOS de cada gráfico (ou o texto da tela, quando o
# autor desligou a exportação) → radar_importar (nio_radar_leituras, um retrato por gráfico por dia) → dashboard_rodada_registrar
# (origem 'radar'). A rodada das 15h (dashboard_diario: OSAB + Faturas) não muda. Ricardo, 26/11: "Regra 5 liberada".
# Sessão expirada ou trava → a execução FALHA de propósito e a conferência (item 39) mostra.
# Não fala com cliente. Não guarda execução com sucesso. Sem dado de cliente.
#
# Uso:
#   python n8n/deploy_radar_diario.py build | criar | estrutura | ativar | desativar | exportar
#   python n8n/deploy_radar_diario.py rodar        # roda agora pela rota de teste (ignora o "ativo") e mostra o resumo
import datetime
import json
import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_mari as dm   # noqa: E402

AQUI = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(AQUI)
EXPORT = os.path.join(AQUI, 'radar_diario.json')
WF_NOME = 'radar_diario'
ID_KEY = 'radar_diario_workflow_id'
CRED_PORTAL = 'Portal Nio (operador)'
ROTA_TESTE = 'niogen-radar-teste'
OPERADOR = 'http://niogen-portal-tunel:8090'

JS_PEDIDO = r"""
// Config do banco → corpo do pedido. Agendado com a rotina desligada ("ativo": false) → para aqui, sem rodar.
const cfg = $input.first().json || {};
const teste = !!$('1t · rota de teste').isExecuted;
const regra = cfg.regra || {};
if (!teste && regra.ativo !== true) return [{ json: { parar: true } }];
return [{ json: { parar: false, origem: teste ? 'radar-teste' : 'radar', iniciada_em: new Date().toISOString(),
                  corpo: { abas: cfg.abas || [], meses: 1, origem: teste ? 'radar-teste' : 'radar' } } }];
"""

JS_ESTADO = r"""
// Cabeça do laço: chega do "4 · Pedir rodada" (1ª vez) ou do "7 · Status". Decide: fim ou esperar mais (até ~10 min).
const r = $input.first().json || {};
const sc = r.statusCode || 0;
const b = (r.body && typeof r.body === 'object') ? r.body : (r.statusCode ? {} : r);
const job = b.job_id || null;
let volta = 0;
try { const e = $('6 · Espera 20 s').last().json; if (e && job && e.job_id === job) volta = (e.volta || 0) + 1; } catch (e) { volta = 0; }
let fim = false, erro = null;
if (sc && sc !== 200 && sc !== 202) { fim = true; erro = 'HTTP ' + sc + ' ' + String(b.erro || '').slice(0, 160); }
else if (b.estado === 'pronto' || b.estado === 'erro') { fim = true; if (b.estado === 'erro') erro = String(b.motivo || 'erro').slice(0, 300); }
else if (volta >= 30) { fim = true; erro = 'o operador demorou mais que 10 min'; }
return [{ json: { fim, job_id: job, volta, erro, trava: !!b.trava, sessao_expirada: !!b.sessao_expirada,
                  radar: b.radar || [], abas: b.abas || {},
                  atualizado_painel: b.atualizado_painel || null, ms: b.ms || null } }];
"""

JS_RESUMO = r"""
// Junta o que voltou do operador e da gravação. Só contagens (o retrato inteiro fica em nio_radar_leituras).
const e = $('5 · Estado').last().json;
const p = $('3 · Montar pedido').first().json;
let g = null;
try { const x = $('8 · Gravar radar').first().json; g = x && (x.body !== undefined ? x.body : x); } catch (err) { g = null; }
const errG = g && (g.message || g.error) ? String(g.message || g.error).slice(0, 200) : null;
const resumo = { ms: e.ms,
  abas: Object.fromEntries(Object.entries(e.abas || {}).map(([k, v]) => [k, { modo: v.modo, ok: v.ok, visuais: v.visuais, lidos: v.lidos, erros: v.erros, erro: v.erro, segundos: v.segundos }])),
  radar: g ? { exportados: g.exportados, texto: g.texto, erros: g.erros, dia: g.dia, erro: errG } : null };
const erro = e.erro || errG || ((e.radar || []).length ? null : 'o operador não devolveu nenhuma aba do radar');
return [{ json: { dados: { ok: !erro, origem: p.origem, iniciada_em: p.iniciada_em, erro, resumo, mapa: [] },
                  erro, trava: e.trava, sessao_expirada: e.sessao_expirada } }];
"""

JS_FALHOU = r"""
const r = $('10 · Resumo').first().json;
if (r.trava) throw new Error('TRAVA do operador do Dashboard (radar) acionada — a rotina parou: ' + String(r.erro || '').slice(0, 200));
if (r.sessao_expirada) throw new Error('Radar: a sessão do login de gestão expirou — refazer o login no PC (python portal/dashboard_sessao.py).');
if (r.erro) throw new Error('Radar: ' + String(r.erro).slice(0, 300));
return [{ json: r.dados.resumo }];
"""


def build(ids):
    cred = ids.get('credenciais', {})
    if not cred.get('portal_operador'):
        raise SystemExit(f'credencial "{CRED_PORTAL}" ausente em mari_ids.json.')
    sb_cred = {'supabaseApi': {'id': cred.get('supabase', ''), 'name': dm.CRED_SUPABASE}}
    op_cred = {'httpHeaderAuth': {'id': cred['portal_operador'], 'name': CRED_PORTAL}}
    te_cred = {'httpHeaderAuth': {'id': cred.get('teste', ''), 'name': dm.CRED_TESTE}}
    nodes = []

    def add(name, ntype, ver, params, x, y, **extra):
        n = {'parameters': params, 'name': name, 'type': ntype, 'typeVersion': ver, 'position': [x, y],
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/radar_diario/{name}'))}
        n.update(extra)
        nodes.append(n)

    def sb(name, rpc, body, x, y, **extra):
        add(name, 'n8n-nodes-base.httpRequest', 4.2, {
            'method': 'POST', 'url': f'{dm.SB}/rest/v1/rpc/{rpc}',
            'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
            'sendBody': True, 'specifyBody': 'json', 'jsonBody': body,
            'options': {'timeout': 60000, 'response': {'response': {'fullResponse': True, 'neverError': True}}}},
            x, y, credentials=sb_cred, **extra)

    def op(name, method, url, x, y, body=None):
        p = {'method': method, 'url': url, 'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth',
             'options': {'timeout': 30000, 'response': {'response': {'fullResponse': True, 'neverError': True}}}}
        if body:
            p.update({'sendBody': True, 'specifyBody': 'json', 'jsonBody': body})
        add(name, 'n8n-nodes-base.httpRequest', 4.2, p, x, y, credentials=op_cred)

    def se(name, expr, x, y):
        add(name, 'n8n-nodes-base.if', 2, {
            'conditions': {'options': {'caseSensitive': True, 'leftValue': '', 'typeValidation': 'loose'},
                           'conditions': [{'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/radar_diario/{name}/c')),
                                           'leftValue': '={{ ' + expr + ' }}', 'rightValue': '',
                                           'operator': {'type': 'boolean', 'operation': 'true', 'singleValue': True}}],
                           'combinator': 'and'}, 'options': {}}, x, y)

    add('1 · todo dia 05h30', 'n8n-nodes-base.scheduleTrigger', 1.2,
        {'rule': {'interval': [{'field': 'cronExpression', 'expression': '30 5 * * *'}]}}, 0, 0)
    add('1t · rota de teste', 'n8n-nodes-base.webhook', 2,
        {'httpMethod': 'POST', 'path': ROTA_TESTE, 'authentication': 'headerAuth', 'responseMode': 'lastNode', 'options': {}},
        0, 200, credentials=te_cred, webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, 'niogen/radar_diario/webhook')))
    add('2 · Config', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{dm.SB}/rest/v1/rpc/dashboard_config',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': '={{ JSON.stringify({ p_rotina: "radar" }) }}', 'options': {'timeout': 30000}},
        220, 100, credentials=sb_cred, retryOnFail=True, maxTries=2, waitBetweenTries=3000)
    add('3 · Montar pedido', 'n8n-nodes-base.code', 2, {'jsCode': JS_PEDIDO.strip()}, 440, 100)
    se('3b · Rodar?', '$json.parar !== true', 660, 100)
    op('4 · Pedir rodada', 'POST', f'{OPERADOR}/dashboard', 880, 100, '={{ JSON.stringify($json.corpo) }}')
    add('5 · Estado', 'n8n-nodes-base.code', 2, {'jsCode': JS_ESTADO.strip()}, 1100, 100)
    se('5b · Terminou?', '$json.fim === true', 1320, 100)
    add('6 · Espera 20 s', 'n8n-nodes-base.wait', 1.1, {'amount': 20, 'unit': 'seconds'}, 1320, 320,
        webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, 'niogen/radar_diario/espera')))
    op('7 · Status', 'GET', "={{ '" + OPERADOR + "/dashboard/' + $json.job_id }}", 1100, 320)
    se('7b · Tem radar?', '($json.radar || []).length > 0', 1540, 100)
    sb('8 · Gravar radar', 'radar_importar',
       "={{ JSON.stringify({ p_dados: { radar: $('5 · Estado').last().json.radar } }) }}", 1760, 0)
    add('10 · Resumo', 'n8n-nodes-base.code', 2, {'jsCode': JS_RESUMO.strip()}, 2420, 100)
    sb('11 · Registrar rodada', 'dashboard_rodada_registrar', '={{ JSON.stringify({ p_dados: $json.dados }) }}', 2640, 100)
    add('12 · Falhou?', 'n8n-nodes-base.code', 2, {'jsCode': JS_FALHOU.strip()}, 2860, 100)

    def liga(*alvos):
        return {'main': [[{'node': a, 'type': 'main', 'index': 0}] if a else [] for a in alvos]}

    conns = {
        '1 · todo dia 05h30': liga('2 · Config'),
        '1t · rota de teste': liga('2 · Config'),
        '2 · Config': liga('3 · Montar pedido'),
        '3 · Montar pedido': liga('3b · Rodar?'),
        '3b · Rodar?': liga('4 · Pedir rodada', None),
        '4 · Pedir rodada': liga('5 · Estado'),
        '5 · Estado': liga('5b · Terminou?'),
        '5b · Terminou?': liga('7b · Tem radar?', '6 · Espera 20 s'),
        '6 · Espera 20 s': liga('7 · Status'),
        '7 · Status': liga('5 · Estado'),
        '7b · Tem radar?': liga('8 · Gravar radar', '10 · Resumo'),
        '8 · Gravar radar': liga('10 · Resumo'),
        '10 · Resumo': liga('11 · Registrar rodada'),
        '11 · Registrar rodada': liga('12 · Falhou?'),
    }
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
    if not segredo:
        raise SystemExit('MARI_TESTE_SECRET ausente.')
    req = urllib.request.Request(f'{dm.N8N}/webhook/{ROTA_TESTE}', data=b'{}', method='POST',
                                 headers={dm.HEADER_TESTE: segredo, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=900) as r:
            print(json.dumps(json.loads(r.read().decode() or 'null'), ensure_ascii=False, indent=1)[:6000])
    except urllib.error.HTTPError as e:
        raise SystemExit(f'HTTP {e.code}: {e.read().decode()[:800]}')


if __name__ == '__main__':
    acoes = {'build': cmd_build, 'criar': cmd_criar, 'estrutura': cmd_estrutura, 'ativar': cmd_ativar,
             'desativar': lambda: cmd_ativar(False), 'exportar': cmd_exportar, 'rodar': cmd_rodar}
    if len(sys.argv) < 2 or sys.argv[1] not in acoes:
        raise SystemExit('uso: ' + ' | '.join(acoes))
    acoes[sys.argv[1]]()

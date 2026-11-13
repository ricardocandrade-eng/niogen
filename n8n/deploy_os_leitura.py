#!/usr/bin/env python3
# NIOGEN | n8n/deploy_os_leitura.py | 13/11/2026 — Claude Code (docs/Prompt_operador_os_etapa3_131126_0300.md, etapa 3d)
# Workflow n8n "os_leitura": a ROTINA do Operador de OS. A cada 30 min (7h–20h30) pergunta ao Supabase quais OS ler agora
# (RPC os_fila), pede UMA POR VEZ a leitura ao operador do portal (POST /os pelo túnel, dentro da rede do n8n) e grava no
# NIOGEN só a leitura que veio (RPC os_registrar_leitura — leitura igual à anterior não grava nada).
#
#   Qual volta lê o quê (hora de Brasília):
#     07:00            → 'instaladas'  (instaladas há menos de 30 dias — pega cancelamento)        1× ao dia
#     08:00 13:00 18:00 → 'abertas'     (toda OS em andamento)                                       3× ao dia
#     as outras voltas → 'hoje'        (só OS com instalação marcada para hoje)                    a cada 30 min
#
# 13/11 (0173) — VARREDURA PEDIDA PELA TELA: um segundo gatilho, de 1 em 1 min (7h–21h), pergunta os_varredura_proxima(). Sem
# pedido, a execução acaba ali (uma leitura no banco, nenhuma gravação). Com pedido, roda a volta 'abertas' com teto de 40 OS
# e fecha com os_varredura_fechar(). A trava (uma por vez + intervalo) fica no banco, em os_varredura_pedir().
#
# O que o robô faz no portal está em portal/consulta_os.py (só "Filtros" e "Filtrar"; rede em lista branca; regra 5).
# Crédito e viabilidade da Mari têm prioridade: operador ocupado responde 429 e a OS fica para a próxima volta.
# TRAVA acionada no operador → a execução FALHA de propósito (aparece no pulso e para a volta).
# Não fala com cliente. Não guarda execução com sucesso (só erro), para não encher o n8n. Sem CPF em log: o CPF vai da
# os_fila direto para o operador, dentro da execução.
#
# Credenciais (só nomes/IDs): "Supabase Nio (service role)", "MARI_TESTE_SECRET" (rota de teste) e "Portal Nio (operador)"
# (httpHeaderAuth X-Portal-Secret; o valor sai do .env da VPS do operador direto para o n8n — nunca impresso nem gravado).
#
# Uso:
#   python n8n/deploy_os_leitura.py credencial  # cria "Portal Nio (operador)" no n8n (uma vez)
#   python n8n/deploy_os_leitura.py build       # gera n8n/os_leitura.json (export, sem segredos)
#   python n8n/deploy_os_leitura.py criar       # cria o workflow INATIVO
#   python n8n/deploy_os_leitura.py estrutura   # PUT do workflow inteiro, backup antes
#   python n8n/deploy_os_leitura.py ativar | desativar | exportar
#   python n8n/deploy_os_leitura.py rodar [hoje|abertas|instaladas]   # roda agora pela rota de teste e mostra o resumo

import datetime
import json
import os
import subprocess
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_mari as dm   # noqa: E402

AQUI = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(AQUI)
EXPORT = os.path.join(AQUI, 'os_leitura.json')
WF_NOME = 'os_leitura'
ID_KEY = 'os_leitura_workflow_id'
CRED_PORTAL = 'Portal Nio (operador)'
ROTA_TESTE = 'niogen-os-leitura-teste'
OPERADOR = 'http://niogen-portal-tunel:8090'     # túnel SSH até a VPS BR, só dentro da rede do n8n
VPS_BR = 'root@216.128.168.202'
LIMITE = 12                                      # no máximo 12 OS por volta agendada
LIMITE_VARREDURA = 40                            # varredura pedida pela tela: até 40 OS

JS_VOLTA = r"""
// Varredura pedida pela tela (vem do "2v"): { id } → todas as abertas. Rota de teste: { "tipo": "hoje" | "abertas" |
// "instaladas" }. Agendado: decide pela hora de Brasília.
const varredura = $json.id ? Number($json.id) : null;
const b = ($json.body && typeof $json.body === 'object') ? $json.body : {};
let tipo = varredura ? 'abertas' : (['hoje', 'abertas', 'instaladas'].includes(b.tipo) ? b.tipo : null);
if (!tipo) {
  const p = new Intl.DateTimeFormat('en-GB', { timeZone: 'America/Sao_Paulo', hour: '2-digit', minute: '2-digit', hour12: false }).formatToParts(new Date());
  const h = Number(p.find((x) => x.type === 'hour').value), m = Number(p.find((x) => x.type === 'minute').value);
  tipo = (h === 7 && m < 30) ? 'instaladas' : ([8, 13, 18].includes(h) && m < 30) ? 'abertas' : 'hoje';
}
return [{ json: { tipo, varredura, limite: varredura ? __LIMITE_VARREDURA__ : __LIMITE__ } }];
"""

JS_LIMITE = r"""
// Só linha com pedido e CPF; no máximo "limite" por volta (o resto fica para a próxima).
// Fila vazia: sai um item "vazio" para a volta chegar ao Resumo (e fechar a varredura, se havia uma pedida).
const fila = $input.all().filter((i) => i.json && i.json.pedido && i.json.cpf).slice(0, $('2 · Qual volta').first().json.limite);
return fila.length ? fila : [{ json: { vazio: true } }];
"""

JS_ESTADO = r"""
// Cabeça do laço de espera: chega do "6 · Pedir leitura" (1ª vez) ou do "9 · Status" (voltas). Decide: fim ou esperar mais.
const r = $input.first().json || {};
const alvo = $('5 · Uma por vez').first().json;
const sc = r.statusCode || 0;
const b = (r.body && typeof r.body === 'object') ? r.body : (r.statusCode ? {} : r);
const job = b.job_id || null;
let volta = 0;
try { const e = $('8b · Espera 6 s').last().json; if (e && job && e.job_id === job) volta = (e.volta || 0) + 1; } catch (e) { volta = 0; }
let fim = false, resultado = null, motivo = null;
if (sc && sc !== 200 && sc !== 202) {
  fim = true; resultado = sc === 429 ? 'ocupado' : 'erro'; motivo = 'HTTP ' + sc + ' ' + String(b.erro || '').slice(0, 120);
} else if (b.estado === 'pronto' || b.estado === 'erro') {
  fim = true; resultado = b.resultado || 'erro'; motivo = b.motivo ? String(b.motivo).slice(0, 200) : null;
} else if (volta >= 12) {
  fim = true; resultado = 'erro'; motivo = 'o portal demorou mais que o n8n espera';
}
if (b.trava) throw new Error('TRAVA do operador de OS acionada — a rotina parou: ' + String(b.motivo || '').slice(0, 200));
return [{ json: { fim, lida: resultado === 'lida' && !!b.leitura, resultado, motivo, pedido: alvo.pedido, job_id: job,
                  leitura: b.leitura || null, consultado_em: b.consultado_em || null, volta } }];
"""

JS_RESUMO = r"""
// Fim da volta: conta o que aconteceu (sem CPF). Nenhuma leitura boa e alguma falha de verdade → "falha": o "13" fecha a
// varredura (se havia) e o "14" derruba a execução de propósito, para aparecer no pulso.
const fins = [];
for (let i = 0; i < 400; i++) {
  let it = null;
  try { it = $('7 · Estado').all(0, i); } catch (e) { break; }
  if (!it || !it.length) break;
  for (const x of it) if (x.json && x.json.fim) fins.push(x.json);
}
const conta = (res) => fins.filter((f) => f.resultado === res).length;
const volta = $('2 · Qual volta').first().json;
const resumo = { ok: true, tipo: volta.tipo, varredura: volta.varredura || null, na_fila: $('4 · Limite').all().filter((i) => i.json && i.json.pedido).length, lidas: conta('lida'),
                 nao_encontradas: conta('nao_encontrada'), ocupado: conta('ocupado'), erros: conta('erro'),
                 motivos: [...new Set(fins.filter((f) => f.resultado === 'erro' && f.motivo).map((f) => f.motivo.slice(0, 120)))].slice(0, 3) };
resumo.falha = resumo.na_fila > 0 && resumo.lidas === 0 && resumo.erros > 0;
return [{ json: resumo }];
"""

JS_FALHOU = r"""
// Depois de fechar a varredura: volta sem nenhuma leitura boa derruba a execução (aparece no pulso).
const r = $('12 · Resumo').first().json;
if (r.falha) throw new Error('Operador de OS: nenhuma OS lida nesta volta (' + r.erros + ' com erro) — ' + ((r.motivos || [])[0] || 'sem motivo'));
return [{ json: r }];
"""


def build(ids):
    cred = ids.get('credenciais', {})
    if not cred.get('portal_operador'):
        raise SystemExit(f'credencial "{CRED_PORTAL}" ausente em mari_ids.json — rode "credencial" antes.')
    sb_cred = {'supabaseApi': {'id': cred.get('supabase', ''), 'name': dm.CRED_SUPABASE}}
    op_cred = {'httpHeaderAuth': {'id': cred['portal_operador'], 'name': CRED_PORTAL}}
    te_cred = {'httpHeaderAuth': {'id': cred.get('teste', ''), 'name': dm.CRED_TESTE}}
    nodes = []

    def add(name, ntype, ver, params, x, y, **extra):
        n = {'parameters': params, 'name': name, 'type': ntype, 'typeVersion': ver, 'position': [x, y],
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/os_leitura/{name}'))}
        n.update(extra)
        nodes.append(n)

    def sb(name, rpc, body, x, y, **extra):
        add(name, 'n8n-nodes-base.httpRequest', 4.2, {
            'method': 'POST', 'url': f'{dm.SB}/rest/v1/rpc/{rpc}',
            'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
            'sendBody': True, 'specifyBody': 'json', 'jsonBody': body, 'options': {'timeout': 30000}},
            x, y, credentials=sb_cred, retryOnFail=True, maxTries=2, waitBetweenTries=3000, **extra)

    def op(name, method, url, x, y, body=None):
        p = {'method': method, 'url': url, 'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth',
             'options': {'timeout': 30000, 'response': {'response': {'fullResponse': True, 'neverError': True}}}}
        if body:
            p.update({'sendBody': True, 'specifyBody': 'json', 'jsonBody': body})
        add(name, 'n8n-nodes-base.httpRequest', 4.2, p, x, y, credentials=op_cred)

    def se(name, campo, x, y):
        add(name, 'n8n-nodes-base.if', 2, {
            'conditions': {'options': {'caseSensitive': True, 'leftValue': '', 'typeValidation': 'loose'},
                           'conditions': [{'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/os_leitura/{name}/c')),
                                           'leftValue': '={{ $json.' + campo + ' }}', 'rightValue': '',
                                           'operator': {'type': 'boolean', 'operation': 'true', 'singleValue': True}}],
                           'combinator': 'and'}, 'options': {}}, x, y)

    add('1 · a cada 30 min', 'n8n-nodes-base.scheduleTrigger', 1.2,
        {'rule': {'interval': [{'field': 'cronExpression', 'expression': '0,30 7-20 * * *'}]}}, 0, 0)
    add('1t · rota de teste', 'n8n-nodes-base.webhook', 2,
        {'httpMethod': 'POST', 'path': ROTA_TESTE, 'authentication': 'headerAuth', 'responseMode': 'lastNode', 'options': {}},
        0, 200, credentials=te_cred, webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, 'niogen/os_leitura/webhook')))
    add('1v · a cada 1 min', 'n8n-nodes-base.scheduleTrigger', 1.2,
        {'rule': {'interval': [{'field': 'cronExpression', 'expression': '* 7-21 * * *'}]}}, -440, 400)
    sb('2v · Supabase varredura', 'os_varredura_proxima', '={{ JSON.stringify({}) }}', -220, 400)
    add('2w · Tem varredura?', 'n8n-nodes-base.if', 2, {
        'conditions': {'options': {'caseSensitive': True, 'leftValue': '', 'typeValidation': 'loose'},
                       'conditions': [{'id': str(uuid.uuid5(uuid.NAMESPACE_URL, 'niogen/os_leitura/2w/c')),
                                       'leftValue': '={{ Number($json.id) > 0 }}', 'rightValue': '',
                                       'operator': {'type': 'boolean', 'operation': 'true', 'singleValue': True}}],
                       'combinator': 'and'}, 'options': {}}, 0, 400)
    add('2 · Qual volta', 'n8n-nodes-base.code', 2,
        {'jsCode': JS_VOLTA.replace('__LIMITE_VARREDURA__', str(LIMITE_VARREDURA)).replace('__LIMITE__', str(LIMITE)).strip()}, 220, 100)
    sb('3 · Supabase fila', 'os_fila', '={{ JSON.stringify({ p_tipo: $json.tipo }) }}', 440, 100, alwaysOutputData=True)
    add('4 · Limite', 'n8n-nodes-base.code', 2, {'jsCode': JS_LIMITE.strip()}, 660, 100,
        alwaysOutputData=False)
    add('4b · Fila vazia?', 'n8n-nodes-base.if', 2, {
        'conditions': {'options': {'caseSensitive': True, 'leftValue': '', 'typeValidation': 'loose'},
                       'conditions': [{'id': str(uuid.uuid5(uuid.NAMESPACE_URL, 'niogen/os_leitura/4b/c')),
                                       'leftValue': '={{ $json.vazio === true }}', 'rightValue': '',
                                       'operator': {'type': 'boolean', 'operation': 'true', 'singleValue': True}}],
                       'combinator': 'and'}, 'options': {}}, 770, 300)
    add('5 · Uma por vez', 'n8n-nodes-base.splitInBatches', 3, {'batchSize': 1, 'options': {}}, 880, 100)
    op('6 · Pedir leitura', 'POST', f'{OPERADOR}/os', 1100, 200,
       "={{ JSON.stringify({ cpf: $json.cpf, os: $json.pedido, criada_em: $json.criada_em, origem: 'rotina' }) }}")
    add('7 · Estado', 'n8n-nodes-base.code', 2, {'jsCode': JS_ESTADO.strip()}, 1320, 200)
    se('8 · Terminou?', 'fim', 1540, 200)
    add('8b · Espera 6 s', 'n8n-nodes-base.wait', 1.1, {'amount': 6, 'unit': 'seconds'}, 1540, 400,
        webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, 'niogen/os_leitura/espera')))
    op('9 · Status', 'GET', "={{ '" + OPERADOR + "/os/' + $json.job_id }}", 1320, 400)
    se('10 · Lida?', 'lida', 1760, 200)
    sb('11 · Supabase gravar', 'os_registrar_leitura',
       "={{ JSON.stringify({ p_pedido: $json.pedido, p_origem: 'operador', p_dados: $json.leitura, p_referencia_em: $json.consultado_em }) }}",
       1980, 100)
    add('12 · Resumo', 'n8n-nodes-base.code', 2, {'jsCode': JS_RESUMO.strip()}, 1100, -60)
    sb('13 · Fechar varredura', 'os_varredura_fechar', '={{ JSON.stringify({ p_id: $json.varredura, p_resumo: $json }) }}', 1320, -60)
    add('14 · Falhou?', 'n8n-nodes-base.code', 2, {'jsCode': JS_FALHOU.strip()}, 1540, -60)

    def liga(*alvos):
        return {'main': [[{'node': a, 'type': 'main', 'index': 0}] if a else [] for a in alvos]}

    conns = {
        '1 · a cada 30 min': liga('2 · Qual volta'),
        '1t · rota de teste': liga('2 · Qual volta'),
        '1v · a cada 1 min': liga('2v · Supabase varredura'),
        '2v · Supabase varredura': liga('2w · Tem varredura?'),
        '2w · Tem varredura?': liga('2 · Qual volta', None),              # sem pedido: a execução acaba aqui
        '2 · Qual volta': liga('3 · Supabase fila'),
        '3 · Supabase fila': liga('4 · Limite'),
        '4 · Limite': liga('4b · Fila vazia?'),
        '4b · Fila vazia?': liga('12 · Resumo', '5 · Uma por vez'),
        '5 · Uma por vez': liga('12 · Resumo', '6 · Pedir leitura'),        # saída 0 = acabou · saída 1 = próxima OS
        '6 · Pedir leitura': liga('7 · Estado'),
        '7 · Estado': liga('8 · Terminou?'),
        '8 · Terminou?': liga('10 · Lida?', '8b · Espera 6 s'),
        '8b · Espera 6 s': liga('9 · Status'),
        '9 · Status': liga('7 · Estado'),
        '10 · Lida?': liga('11 · Supabase gravar', '5 · Uma por vez'),
        '11 · Supabase gravar': liga('5 · Uma por vez'),
        '12 · Resumo': liga('13 · Fechar varredura'),
        '13 · Fechar varredura': liga('14 · Falhou?'),
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


def cmd_credencial():
    ids = dm.ler_ids()
    cred = ids.setdefault('credenciais', {})
    if cred.get('portal_operador'):
        print(f'já existe: {CRED_PORTAL} ({cred["portal_operador"]}) — nada a fazer')
        return
    chave = os.path.join(os.path.expanduser('~'), '.ssh', 'id_ed25519_vero')
    r = subprocess.run(['ssh', '-i', chave, '-o', 'BatchMode=yes', VPS_BR,
                        "grep ^NIO_PORTAL_SERVICO_SECRET= /opt/niogen/portal/.env | cut -d= -f2-"],
                       capture_output=True, text=True, timeout=60)
    segredo = r.stdout.strip().strip('"').strip("'")
    if r.returncode != 0 or len(segredo) < 24:
        raise SystemExit('não consegui ler o segredo do operador na VPS — nada foi criado.')
    c = dm.api('POST', '/credentials', {'name': CRED_PORTAL, 'type': 'httpHeaderAuth',
                                        'data': {'name': 'X-Portal-Secret', 'value': segredo}})
    del segredo
    cred['portal_operador'] = c['id']
    dm.gravar_ids(ids)
    print(f'criada: {CRED_PORTAL} ({c["id"]})')


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
    tipo = sys.argv[2] if len(sys.argv) > 2 else 'hoje'
    req = urllib.request.Request(f'{dm.N8N}/webhook/{ROTA_TESTE}', data=json.dumps({'tipo': tipo}).encode(), method='POST',
                                 headers={dm.HEADER_TESTE: segredo, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            print(json.dumps(json.loads(r.read().decode() or 'null'), ensure_ascii=False, indent=1))
    except urllib.error.HTTPError as e:
        raise SystemExit(f'HTTP {e.code}: {e.read().decode()[:800]}')


if __name__ == '__main__':
    acoes = {'credencial': cmd_credencial, 'build': cmd_build, 'criar': cmd_criar, 'estrutura': cmd_estrutura,
             'ativar': cmd_ativar, 'desativar': lambda: cmd_ativar(False), 'exportar': cmd_exportar, 'rodar': cmd_rodar}
    if len(sys.argv) < 2 or sys.argv[1] not in acoes:
        raise SystemExit('uso: ' + ' | '.join(acoes))
    acoes[sys.argv[1]]()

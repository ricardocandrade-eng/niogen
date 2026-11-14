#!/usr/bin/env python3
# NIOGEN | n8n/deploy_meta_capi.py | 13/11/2026 — Claude Code (Opus 5)
# Build e deploy do workflow n8n "meta_capi_envio": o CAMINHO DE VOLTA dos resultados do NIOGEN para a Meta
# (API de Conversões para mensagens de negócios). De 5 em 5 min lê a fila meta_eventos pela RPC meta_capi_pendentes
# (migration 0186) e faz um POST por evento em /{dataset_id}/events; o resultado volta para a fila por meta_capi_marcar.
#
# FORA DA MARI, de propósito: a Mari nunca espera a Meta. Quem grava o pendente é gatilho do banco (0186).
#
# O que vai à Meta, e nada mais: ctwa_clid, o telefone com hash SHA-256 (calculado DENTRO do banco, na RPC) e, no
# Purchase, currency + value. Nunca nome, CPF, e-mail, endereço, CEP, cidade ou bairro — decisão do Ricardo de
# 06/11/2026 12h59, que não se reabre.
#
# Quatro eventos (13/11, depois de medir o volume de cada degrau em 14 dias):
#   ViewContent   — o CEP é de cidade atendida (degrau area_ok)   ~26/semana
#   QualifiedLead — a rua tem rede (degrau viavel)                ~21/semana  ← é o evento de otimização
#   LeadSubmitted — qualificada (degrau qualificada)               ~2/semana
#   Purchase      — OS gravada (decisão D3 do Ricardo, 12/11)      ~1/semana, só para medir
# Os quatro são nomes PADRÃO da API para mensagens de negócios (nada de evento personalizado).
# Sem ctwa_clid a linha nasce 'sem_clique' no banco e nunca chega aqui. Sem backfill.
#
# SEGREDO: nenhum. O token da WABA Nio fica só na credencial n8n "WABA Nio (Nio_API)" (httpHeaderAuth, Bearer), a mesma
# que a Mari já usa para a Cloud API. O ID do dataset não é segredo e mora em config_regras.meta_capi (regra 15).
#
# Uso:
#   python n8n/deploy_meta_capi.py build        # gera n8n/meta_capi_envio.json (export, sem segredos)
#   python n8n/deploy_meta_capi.py criar        # cria o workflow INATIVO; falha se o nome já existe
#   python n8n/deploy_meta_capi.py estrutura    # PUT do workflow inteiro, backup antes (mantém o active atual)
#   python n8n/deploy_meta_capi.py ativar       # liga o envio (schedule de 5 min)
#   python n8n/deploy_meta_capi.py desativar    # desliga o envio
#   python n8n/deploy_meta_capi.py rodar        # chama a rota de teste (POST com o header) e mostra o retorno
#   python n8n/deploy_meta_capi.py exportar     # baixa o estado atual e grava o export sanitizado

import datetime
import json
import os
import sys
import urllib.error
import urllib.request
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_mari as dm   # noqa: E402  (api, ids, checagem de segredo)

AQUI = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(AQUI)
EXPORT = os.path.join(AQUI, 'meta_capi_envio.json')
WF_NOME = 'meta_capi_envio'
ID_KEY = 'meta_capi_workflow_id'
SB = dm.SB
ROTA = 'niogen-meta-capi-envio'
LIMITE = 50          # eventos por rodada (a fila nunca passa de alguns por hora)

# Monta um item por evento, já com o corpo do POST. Nada de dado pessoal é criado aqui: o payload vem pronto do banco.
CODIGO_MONTAR = r"""
const r = $json || {};
const dataset = r.dataset_id;
const versao = r.graph_versao || 'v23.0';
const teste = r.test_event_code || null;
const eventos = Array.isArray(r.eventos) ? r.eventos : [];
if (!dataset) { throw new Error('config_regras.meta_capi sem dataset_id'); }

const saida = [];
for (const ev of eventos) {
  const fila = ev.fila || {};
  const evento = { ...ev };
  delete evento.fila;
  if (evento.custom_data === null) { delete evento.custom_data; }
  const corpo = { data: [evento], partner_agent: 'niogen' };
  if (teste) { corpo.test_event_code = teste; }
  saida.push({ json: {
    fila_id: fila.id,
    tentativas: fila.tentativas,
    event_name: evento.event_name,
    event_id: evento.event_id,
    url: 'https://graph.facebook.com/' + versao + '/' + dataset + '/events',
    corpo,
  } });
}
return saida;
"""


def build(ids):
    cred = ids.get('credenciais', {})
    sb_cred = {'supabaseApi': {'id': cred.get('supabase', ''), 'name': dm.CRED_SUPABASE}}
    te_cred = {'httpHeaderAuth': {'id': cred.get('teste', ''), 'name': dm.CRED_TESTE}}
    wa_cred = {'httpHeaderAuth': {'id': cred.get('waba', ''), 'name': dm.CRED_WABA}}
    nodes = []

    def add(name, ntype, ver, params, x, y, **extra):
        n = {'parameters': params, 'name': name, 'type': ntype, 'typeVersion': ver, 'position': [x, y],
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/{WF_NOME}/{name}'))}
        n.update(extra)
        nodes.append(n)

    add('1 · A cada 5 min', 'n8n-nodes-base.scheduleTrigger', 1.2,
        {'rule': {'interval': [{'field': 'minutes', 'minutesInterval': 5}]}}, 0, 0)
    add('1w · Rodar agora (teste)', 'n8n-nodes-base.webhook', 2, {
        'httpMethod': 'POST', 'path': ROTA, 'authentication': 'headerAuth',
        'responseMode': 'lastNode', 'options': {}}, 0, 220,
        credentials=te_cred, webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, 'niogen/' + ROTA)))

    # 2. A fila, já no formato do POST. O SHA-256 do telefone é calculado no banco e não é gravado em lugar nenhum.
    add('2 · Supabase pendentes', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{SB}/rest/v1/rpc/meta_capi_pendentes',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'sendBody': True, 'specifyBody': 'json',
        'jsonBody': '={{ JSON.stringify({ p_limite: %d }) }}' % LIMITE,
        'options': {'timeout': 20000}}, 240, 100, credentials=sb_cred,
        retryOnFail=True, maxTries=2, waitBetweenTries=5000)

    add('3 · Montar eventos', 'n8n-nodes-base.code', 2, {
        'mode': 'runOnceForAllItems', 'jsCode': CODIGO_MONTAR.strip()}, 480, 100)

    # 4. Um POST por evento. neverError + fullResponse: o status HTTP volta como dado, então um 400 de um evento não
    # derruba os outros nem apaga a resposta que precisa ser gravada na fila.
    add('4 · Meta evento', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': '={{ $json.url }}',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'httpHeaderAuth',
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': '={{ JSON.stringify($json.corpo) }}',
        'options': {'timeout': 20000, 'response': {'response': {'fullResponse': True, 'neverError': True}}}},
        720, 100, credentials=wa_cred)

    # 5. O resultado volta para a fila. meta_capi_marcar é o único caminho que muda o estado da linha (regra 3 do
    # sistema fechado) e já conta a tentativa; depois de 3, a RPC de pendentes para de devolver a linha.
    add('5 · Supabase marcar', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{SB}/rest/v1/rpc/meta_capi_marcar',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'sendBody': True, 'specifyBody': 'json',
        'jsonBody': (
            "={{ (() => { const c = $json.statusCode || 0; const b = $json.body || {};"
            " const ok = c >= 200 && c < 300 && (b.events_received || 0) > 0;"
            " return JSON.stringify({ p_id: $('3 · Montar eventos').item.json.fila_id,"
            " p_status: ok ? 'enviado' : 'erro', p_http: c,"
            " p_resposta: JSON.stringify(b).slice(0, 500),"
            " p_fbtrace: b.fbtrace_id || (b.error && b.error.fbtrace_id) || null }); })() }}"),
        'options': {'timeout': 20000}}, 960, 100, credentials=sb_cred)

    ligacoes = [
        ('1 · A cada 5 min', 0, '2 · Supabase pendentes'),
        ('1w · Rodar agora (teste)', 0, '2 · Supabase pendentes'),
        ('2 · Supabase pendentes', 0, '3 · Montar eventos'),
        ('3 · Montar eventos', 0, '4 · Meta evento'),
        ('4 · Meta evento', 0, '5 · Supabase marcar'),
    ]
    nomes = {n['name'] for n in nodes}
    conns = {}
    for o, i, d in ligacoes:
        assert o in nomes and d in nomes, (o, d)
        main = conns.setdefault(o, {'main': []})['main']
        while len(main) <= i:
            main.append([])
        main[i].append({'node': d, 'type': 'main', 'index': 0})

    # 288 rodadas/dia, quase todas sem nada para enviar: sucesso não fica salvo. Erro fica e cai no Error Trigger do
    # mari_principal (mari_erros); pela 0186 o pulso o classifica como 'outro_fluxo', não como falha da Mari.
    settings = {'executionOrder': 'v1', 'saveDataErrorExecution': 'all', 'saveDataSuccessExecution': 'none',
                'saveManualExecutions': True, 'timezone': 'America/Sao_Paulo'}
    if ids.get('workflow_id'):
        settings['errorWorkflow'] = ids['workflow_id']
    return {'name': WF_NOME, 'nodes': nodes, 'connections': conns, 'settings': settings}


def salvar_export(wf):
    dm.checar_sem_segredo(wf)
    with open(EXPORT, 'w', encoding='utf-8') as f:
        json.dump(wf, f, ensure_ascii=False, indent=2)
        f.write('\n')
    print(f'export: {os.path.relpath(EXPORT, REPO)} ({len(wf["nodes"])} nós)')


def achar_wf(ids):
    wid = ids.get(ID_KEY)
    if not wid:
        raise SystemExit(f'{ID_KEY} ausente em mari_ids.json — rode "criar" antes.')
    wf = dm.api('GET', f'/workflows/{wid}')
    if wf.get('name') != WF_NOME:
        raise SystemExit(f'o ID {wid} não é o {WF_NOME} (é "{wf.get("name")}") — abortado, nada foi alterado.')
    return wf


def backup(wf):
    os.makedirs(dm.BACKUP_DIR, exist_ok=True)
    p = os.path.join(dm.BACKUP_DIR, f'{WF_NOME}_{datetime.datetime.now().strftime("%d%m%y_%H%M%S")}.json')
    with open(p, 'w', encoding='utf-8') as f:
        json.dump(wf, f, ensure_ascii=False, indent=2)
    print(f'backup: {os.path.relpath(p, REPO)}')


def cmd_criar():
    ids = dm.ler_ids()
    if ids.get(ID_KEY):
        raise SystemExit(f'já existe {ID_KEY} {ids[ID_KEY]} — use "estrutura".')
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
    atual = achar_wf(ids)
    backup(atual)
    dm.put(ids[ID_KEY], build(ids))
    print('ok (active =', dm.api('GET', f'/workflows/{ids[ID_KEY]}').get('active'), ')')
    cmd_exportar()


def cmd_ativar(ligar=True):
    ids = dm.ler_ids()
    wf = achar_wf(ids)
    if bool(wf.get('active')) == ligar:
        print(f'{WF_NOME}: já active={ligar}')
        return
    r = dm.api('POST', f'/workflows/{ids[ID_KEY]}/{"activate" if ligar else "deactivate"}')
    print(f'{WF_NOME}: active={r.get("active")}')


def cmd_rodar():
    segredo = dm.env_usuario('MARI_TESTE_SECRET')
    if not segredo:
        raise SystemExit('MARI_TESTE_SECRET ausente.')
    req = urllib.request.Request(f'{dm.N8N}/webhook/{ROTA}', data=b'{}', method='POST',
                                 headers={dm.HEADER_TESTE: segredo, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            print(r.status, r.read().decode()[:1200])
    except urllib.error.HTTPError as e:
        raise SystemExit(f'HTTP {e.code}: {e.read().decode()[:1200]}')


def cmd_exportar():
    ids = dm.ler_ids()
    wf = achar_wf(ids)
    limpo = {'name': wf['name'], 'nodes': wf['nodes'], 'connections': wf['connections'],
             'settings': wf.get('settings', {}), 'active': wf.get('active')}
    salvar_export(limpo)


if __name__ == '__main__':
    cmds = {'build': lambda: salvar_export(build(dm.ler_ids())), 'criar': cmd_criar, 'estrutura': cmd_estrutura,
            'ativar': lambda: cmd_ativar(True), 'desativar': lambda: cmd_ativar(False), 'rodar': cmd_rodar,
            'exportar': cmd_exportar}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds:
        raise SystemExit('uso: build | criar | estrutura | ativar | desativar | rodar | exportar')
    cmds[sys.argv[1]]()

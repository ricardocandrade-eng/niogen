#!/usr/bin/env python3
# NIOGEN | n8n/deploy_meta_ads.py | 06/11/2026 — Claude Code (aba Desempenho da Meta Ads, depois do prompt 22)
# Build e deploy do workflow n8n "meta_ads_coleta": a cada 15 min lê da Graph API os insights por anúncio e dia
# (hoje e os 2 dias anteriores — a Meta ainda ajusta conversas atrasadas) e o status dos anúncios da CA
# act_764071346694892, e grava no Supabase Nio por meta_ads_gravar (migration 0034). A tela Meta Ads › Desempenho lê dali.
# 07/11: + conjunto × posicionamento × dia → meta_ads_gravar_posicionamentos (migration 0054), base do agente de Meta Ads.
# 09/11: + nós 9/9b/10 → saldo em aberto e limite de cobrança da conta (migration 0078, card "Saldo em aberto"). Só leitura.
# SÓ LEITURA na Meta: nenhum nó pausa, ativa ou muda verba. Mesmo padrão do deploy_cadencia.py: backup antes de
# qualquer PUT e este script só opera no workflow "meta_ads_coleta".
#
# Credenciais (só IDs, nunca valores): "Meta Ads Nio — NIOGEN" (facebookGraphApi, system user Nio_API, ads_read basta),
# "Supabase Nio (service role)", "MARI_TESTE_SECRET" (header da rota de teste). Chave da API do n8n: N8N_API_KEY_NIO.
#
# Uso:
#   python n8n/deploy_meta_ads.py build        # gera n8n/meta_ads_coleta.json (export, sem segredos)
#   python n8n/deploy_meta_ads.py criar        # cria o workflow INATIVO; falha se o nome já existe
#   python n8n/deploy_meta_ads.py estrutura    # PUT do workflow inteiro, backup antes (mantém o active atual)
#   python n8n/deploy_meta_ads.py ativar       # liga a coleta (schedule de 15 min)
#   python n8n/deploy_meta_ads.py desativar    # desliga a coleta
#   python n8n/deploy_meta_ads.py rodar        # chama a rota de teste (POST com o header) e mostra o retorno do Supabase
#   python n8n/deploy_meta_ads.py exportar     # baixa o estado atual e grava o export sanitizado

import datetime
import json
import os
import sys
import urllib.request
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_mari as dm   # noqa: E402  (api, ids, checagem de segredo)

AQUI = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(AQUI)
EXPORT = os.path.join(AQUI, 'meta_ads_coleta.json')
WF_NOME = 'meta_ads_coleta'
ID_KEY = 'meta_ads_workflow_id'
SB = dm.SB
CONTA = 'act_764071346694892'
GRAPH = 'https://graph.facebook.com/v24.0'
CRED_META = 'Meta Ads Nio — NIOGEN'
CRED_META_ID = '6gZXxn959udw7E6c'          # facebookGraphApi (ID do n8n, não é segredo)
ROTA = 'niogen-meta-ads-coleta'

CAMPOS_INSIGHTS = ','.join(['date_start', 'ad_id', 'ad_name', 'adset_id', 'adset_name', 'campaign_id', 'campaign_name',
                            'spend', 'impressions', 'reach', 'clicks', 'actions'])
CAMPOS_ADS = 'id,name,effective_status,adset_id,adset{name},campaign_id,campaign{name}'
CAMPOS_POSIC = ','.join(['date_start', 'adset_id', 'adset_name', 'campaign_id', 'campaign_name',
                         'spend', 'impressions', 'clicks', 'inline_link_clicks', 'actions'])
CAMPOS_SALDO = 'balance,amount_spent,spend_cap,currency,is_prepay_account'   # 0078: card "Saldo em aberto" (sem dados do cartão)
CAMPOS_CONJ = ('id,name,effective_status,campaign_id,campaign{name},targeting{publisher_platforms,facebook_positions,'
               'instagram_positions,whatsapp_positions,audience_network_positions,messenger_positions}')


def build(ids):
    cred = ids.get('credenciais', {})
    sb_cred = {'supabaseApi': {'id': cred.get('supabase', ''), 'name': dm.CRED_SUPABASE}}
    te_cred = {'httpHeaderAuth': {'id': cred.get('teste', ''), 'name': dm.CRED_TESTE}}
    fb_cred = {'facebookGraphApi': {'id': cred.get('meta_ads', CRED_META_ID), 'name': CRED_META}}
    nodes = []

    def add(name, ntype, ver, params, x, y, **extra):
        n = {'parameters': params, 'name': name, 'type': ntype, 'typeVersion': ver, 'position': [x, y],
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/meta_ads_coleta/{name}'))}
        n.update(extra)
        nodes.append(n)

    def graph(name, edge, query, x, y):
        add(name, 'n8n-nodes-base.httpRequest', 4.2, {
            'method': 'GET', 'url': f'{GRAPH}/{CONTA}/{edge}',
            'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'facebookGraphApi',
            'sendQuery': True, 'queryParameters': {'parameters': [{'name': k, 'value': v} for k, v in query]},
            'options': {'timeout': 30000}}, x, y, credentials=fb_cred,
            retryOnFail=True, maxTries=2, waitBetweenTries=5000)

    add('1 · A cada 15 min', 'n8n-nodes-base.scheduleTrigger', 1.2,
        {'rule': {'interval': [{'field': 'minutes', 'minutesInterval': 15}]}}, 0, 0)
    add('1w · Rodar agora (teste)', 'n8n-nodes-base.webhook', 2, {
        'httpMethod': 'POST', 'path': ROTA, 'authentication': 'headerAuth',
        'responseMode': 'lastNode', 'options': {}}, 0, 220,
        credentials=te_cred, webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, 'niogen/' + ROTA)))
    # Hoje e os 2 dias anteriores, no fuso do workflow (America/Sao_Paulo = fuso da conta de anúncios).
    janela = ("={{ JSON.stringify({ since: $now.setZone('America/Sao_Paulo').minus({ days: 2 }).toFormat('yyyy-MM-dd'), "
              "until: $now.setZone('America/Sao_Paulo').toFormat('yyyy-MM-dd') }) }}")
    graph('2 · Meta insights', 'insights', [
        ('level', 'ad'), ('time_increment', '1'), ('time_range', janela),
        ('fields', CAMPOS_INSIGHTS), ('limit', '500')], 240, 100)
    graph('3 · Meta anúncios', 'ads', [('fields', CAMPOS_ADS), ('limit', '200')], 480, 100)
    add('4 · Supabase gravar', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{SB}/rest/v1/rpc/meta_ads_gravar',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'sendBody': True, 'specifyBody': 'json',
        'jsonBody': "={{ JSON.stringify({ p_insights: $('2 · Meta insights').first().json.data || [], "
                    "p_anuncios: $json.data || [] }) }}",
        'options': {'timeout': 20000}}, 720, 100, credentials=sb_cred)
    # 07/11 (migration 0054): conjunto × posicionamento × dia — o corte que mostrou o Status do WhatsApp comendo 47 %
    # da verba sem conversa. Vem depois da gravação principal: se falhar, o desempenho por anúncio já foi gravado.
    graph('5 · Meta posicionamentos', 'insights', [
        ('level', 'adset'), ('breakdowns', 'publisher_platform,platform_position'), ('time_increment', '1'),
        ('time_range', janela), ('fields', CAMPOS_POSIC), ('limit', '500')], 960, 100)
    add('6 · Supabase posicionamentos', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{SB}/rest/v1/rpc/meta_ads_gravar_posicionamentos',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'sendBody': True, 'specifyBody': 'json',
        'jsonBody': "={{ JSON.stringify({ p_insights: $json.data || [] }) }}",
        'options': {'timeout': 20000}}, 1200, 100, credentials=sb_cred)
    # 07/11 (migration 0056): o posicionamento CONFIGURADO de cada conjunto — sem isso, um posicionamento já tirado
    # seguia como alerta ativo enquanto houvesse gasto dele nos 7 dias da janela.
    graph('7 · Meta conjuntos', 'adsets', [('fields', CAMPOS_CONJ), ('limit', '200')], 1440, 100)
    add('8 · Supabase conjuntos', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{SB}/rest/v1/rpc/meta_ads_gravar_conjuntos',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'sendBody': True, 'specifyBody': 'json',
        'jsonBody': "={{ JSON.stringify({ p_conjuntos: $json.data || [] }) }}",
        'options': {'timeout': 20000}}, 1680, 100, credentials=sb_cred)

    # 09/11 (migration 0078, card "Saldo em aberto"): saldo da conta e limite de cobrança do ciclo — SÓ LEITURA. Os três nós
    # seguem em frente mesmo com erro (onError=continueRegularOutput): sem permissão para o ciclo, o card mostra "limite: ver no BM";
    # a coleta de desempenho acima nunca falha por causa deles. O limite vem sempre da API (nunca de config).
    add('9 · Meta saldo', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'GET', 'url': f'{GRAPH}/{CONTA}',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'facebookGraphApi',
        'sendQuery': True, 'queryParameters': {'parameters': [{'name': 'fields', 'value': CAMPOS_SALDO}]},
        'options': {'timeout': 20000}}, 1920, 100, credentials=fb_cred, onError='continueRegularOutput', alwaysOutputData=True)
    add('9b · Meta ciclo de cobrança', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'GET', 'url': f'{GRAPH}/{CONTA}/adspaymentcycle',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'facebookGraphApi',
        'sendQuery': True, 'queryParameters': {'parameters': [{'name': 'fields', 'value': 'threshold_amount,created_time'}]},
        'options': {'timeout': 20000}}, 2160, 100, credentials=fb_cred, onError='continueRegularOutput', alwaysOutputData=True)
    add('10 · Supabase saldo', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{SB}/rest/v1/rpc/meta_ads_gravar_saldo',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'sendBody': True, 'specifyBody': 'json',
        'jsonBody': (f"={{{{ JSON.stringify({{ p_act: '{CONTA}', p_conta: $('9 · Meta saldo').first().json, "
                     "p_ciclo: $('9b · Meta ciclo de cobrança').first().json }) }}"),
        'options': {'timeout': 20000}}, 2400, 100, credentials=sb_cred, onError='continueRegularOutput')

    ligacoes = [
        ('1 · A cada 15 min', 0, '2 · Meta insights'),
        ('1w · Rodar agora (teste)', 0, '2 · Meta insights'),
        ('2 · Meta insights', 0, '3 · Meta anúncios'),
        ('3 · Meta anúncios', 0, '4 · Supabase gravar'),
        ('4 · Supabase gravar', 0, '5 · Meta posicionamentos'),
        ('5 · Meta posicionamentos', 0, '6 · Supabase posicionamentos'),
        ('6 · Supabase posicionamentos', 0, '7 · Meta conjuntos'),
        ('7 · Meta conjuntos', 0, '8 · Supabase conjuntos'),
        ('8 · Supabase conjuntos', 0, '9 · Meta saldo'),
        ('9 · Meta saldo', 0, '9b · Meta ciclo de cobrança'),
        ('9b · Meta ciclo de cobrança', 0, '10 · Supabase saldo'),
    ]
    nomes = {n['name'] for n in nodes}
    conns = {}
    for o, i, d in ligacoes:
        assert o in nomes and d in nomes, (o, d)
        main = conns.setdefault(o, {'main': []})['main']
        while len(main) <= i:
            main.append([])
        main[i].append({'node': d, 'type': 'main', 'index': 0})

    # Sucesso não fica salvo (96 execuções/dia); erro fica, e vai para o Error Trigger do mari_principal (mari_erros).
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
    ids.setdefault('credenciais', {}).setdefault('meta_ads', CRED_META_ID)
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
            print(r.status, r.read().decode()[:800])
    except urllib.error.HTTPError as e:
        raise SystemExit(f'HTTP {e.code}: {e.read().decode()[:800]}')


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

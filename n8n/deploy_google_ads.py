#!/usr/bin/env python3
# NIOGEN | n8n/deploy_google_ads.py | 23/11/2026 — Claude Code (Opus 5.5)
# Prompt docs/Prompt_tela_canais_google_ads_231126_1620.md (tela Canais + Google Ads no NIOGEN), espelho do deploy_meta_ads.py.
# Build e deploy do workflow n8n "google_ads_coleta": a cada 15 min lê da API do Google Ads (GAQL, googleAds:search) a conta
# 756-012-0293 — campanhas, desempenho por campanha e dia (hoje e os 2 dias anteriores), palavras-chave (status + 7 dias),
# orçamento da conta (pré-pago) e anúncios reprovados — e grava no Supabase Nio por google_ads_gravar (migration 0369).
# A aba Google Ads da tela Canais (docs/metaads.html#google) lê dali.
# SÓ LEITURA no Google: só googleAds:search. Nenhum nó chama :mutate, nada muda campanha, lance, orçamento ou palavra-chave.
#
# Acesso (Ricardo, 23/11): sem developer token — o nível de acesso fica no projeto do Google Cloud `niogen-514022` (API Google Ads
# ativada, nível Exploração). A credencial é OAuth2 do Google no n8n, com o cliente "n8n NIOGEN" que já existe nesse projeto e o
# escopo https://www.googleapis.com/auth/adwords; o n8n faz o consentimento e guarda o refresh token. Client id, secret e refresh
# token ficam SÓ no n8n (nunca em arquivo, repo, Drive, cartão ou log). Este script só guarda o ID da credencial (não é segredo).
#
# NASCE DESLIGADO até a credencial OAuth existir no n8n (etapa do Ricardo — o consentimento passa pelo navegador dele). Depois:
#   python n8n/deploy_google_ads.py credencial <id>   # grava o ID da credencial n8n em mari_ids.json
#   python n8n/deploy_google_ads.py estrutura         # PUT com a credencial
#   python n8n/deploy_google_ads.py rodar             # rota de teste: confere a 1ª leitura (e a versão da API, GADS_VERSAO)
#   python n8n/deploy_google_ads.py ativar            # liga a coleta de 15 min
#
# Uso:
#   python n8n/deploy_google_ads.py build        # gera n8n/google_ads_coleta.json (export, sem segredos)
#   python n8n/deploy_google_ads.py criar        # cria o workflow INATIVO; falha se o nome já existe
#   python n8n/deploy_google_ads.py estrutura    # PUT do workflow inteiro, backup antes (mantém o active atual)
#   python n8n/deploy_google_ads.py ativar       # liga (recusa sem credencial)
#   python n8n/deploy_google_ads.py desativar
#   python n8n/deploy_google_ads.py rodar        # POST na rota de teste com o header do MARI_TESTE_SECRET
#   python n8n/deploy_google_ads.py exportar

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
EXPORT = os.path.join(AQUI, 'google_ads_coleta.json')
WF_NOME = 'google_ads_coleta'
ID_KEY = 'google_ads_workflow_id'
CRED_KEY = 'google_ads'
SB = dm.SB
CONTA = '7560120293'                 # 756-012-0293 (Nio Internet)
# Versão da API do Google Ads: conferir na 1ª rodada (o Google aposenta versões com ~1 ano). Mudou → trocar aqui e "estrutura".
GADS_VERSAO = 'v25'
GADS = f'https://googleads.googleapis.com/{GADS_VERSAO}/customers/{CONTA}/googleAds:search'
# Se o login do OAuth enxergar a conta só pela MCC 404-290-1239 (vínculo pedido em 23/11), a API pede o cabeçalho
# login-customer-id com o id da MCC: preencher aqui (sem traços) e rodar "estrutura". Acesso direto à conta: deixar vazio.
LOGIN_CUSTOMER = ''
CRED_GOOGLE = 'Google Ads Nio — NIOGEN'   # googleOAuth2Api, escopo adwords, cliente "n8n NIOGEN" (projeto niogen-514022)
ROTA = 'niogen-google-ads-coleta'

# Hoje e os 2 dias anteriores, no fuso da conta (America/Sao_Paulo): __INI__/__FIM__ viram expressão do n8n no build.
JANELA_INI = "$now.setZone('America/Sao_Paulo').minus({ days: 2 }).toFormat('yyyy-MM-dd')"
JANELA_FIM = "$now.setZone('America/Sao_Paulo').toFormat('yyyy-MM-dd')"
CONSULTAS = [
    # (nó, GAQL, essencial?) — essencial que falha para a rodada (erro vai ao mari_erros pelo errorWorkflow); o resto segue.
    ('2 · Google campanhas',
     'SELECT campaign.id, campaign.name, campaign.status, campaign.primary_status, campaign.primary_status_reasons, '
     'campaign.advertising_channel_type, campaign.bidding_strategy_type, campaign.target_spend.cpc_bid_ceiling_micros, '
     'campaign_budget.amount_micros FROM campaign WHERE campaign.status != \'REMOVED\'', True),
    ('3 · Google dia a dia',
     'SELECT segments.date, campaign.id, campaign.name, metrics.impressions, metrics.clicks, metrics.cost_micros, '
     'metrics.conversions, metrics.search_impression_share, metrics.search_rank_lost_impression_share, '
     'metrics.search_budget_lost_impression_share FROM campaign '
     "WHERE segments.date BETWEEN '__INI__' AND '__FIM__'", True),
    ('4 · Google palavras',
     'SELECT campaign.id, ad_group.id, ad_group.name, ad_group_criterion.criterion_id, ad_group_criterion.keyword.text, '
     'ad_group_criterion.keyword.match_type, ad_group_criterion.status, ad_group_criterion.system_serving_status, '
     'ad_group_criterion.approval_status FROM ad_group_criterion '
     "WHERE ad_group_criterion.type = 'KEYWORD' AND ad_group_criterion.status != 'REMOVED'", False),
    ('5 · Google palavras 7 dias',
     'SELECT ad_group.id, ad_group_criterion.criterion_id, metrics.impressions, metrics.clicks, metrics.cost_micros, '
     'metrics.conversions FROM keyword_view WHERE segments.date DURING LAST_7_DAYS', False),
    ('6 · Google conta',
     'SELECT customer.id, customer.descriptive_name, customer.currency_code, customer.status FROM customer', False),
    ('7 · Google orçamento da conta',
     'SELECT account_budget.status, account_budget.approved_spending_limit_micros, account_budget.amount_served_micros '
     "FROM account_budget WHERE account_budget.status = 'APPROVED'", False),
    ('8 · Google anúncios',
     'SELECT ad_group_ad.ad.id, ad_group_ad.policy_summary.approval_status FROM ad_group_ad '
     "WHERE ad_group_ad.status = 'ENABLED'", False),
]

# O nó 9 junta as sete respostas no formato do google_ads_gravar (micros → reais). Resposta de nó que falhou chega sem "results".
NORMALIZAR = r"""
const r = (n) => { try { const j = $(n).first().json; return Array.isArray(j.results) ? j.results : []; } catch (e) { return []; } };
const m = (v) => (v == null ? null : Math.round(Number(v) / 10000) / 100);   // micros → reais (2 casas)
const camp = r('2 · Google campanhas').map((x) => ({
  id: String(x.campaign.id), conta_id: '__CONTA__', nome: x.campaign.name, status: x.campaign.status,
  status_veiculacao: x.campaign.primaryStatus || null, motivos_status: x.campaign.primaryStatusReasons || [],
  tipo: x.campaign.advertisingChannelType || null, estrategia_lances: x.campaign.biddingStrategyType || null,
  teto_cpc: m(x.campaign.targetSpend && x.campaign.targetSpend.cpcBidCeilingMicros),
  orcamento_diario: m(x.campaignBudget && x.campaignBudget.amountMicros),
}));
const diario = r('3 · Google dia a dia').map((x) => ({
  dia: x.segments.date, campanha_id: String(x.campaign.id), campanha_nome: x.campaign.name,
  impressoes: Number(x.metrics.impressions || 0), cliques: Number(x.metrics.clicks || 0), custo: m(x.metrics.costMicros) || 0,
  conversoes: Number(x.metrics.conversions || 0),
  parcela_impressoes: x.metrics.searchImpressionShare ?? null,
  parcela_perdida_classificacao: x.metrics.searchRankLostImpressionShare ?? null,
  parcela_perdida_orcamento: x.metrics.searchBudgetLostImpressionShare ?? null,
}));
const met = new Map();
r('5 · Google palavras 7 dias').forEach((x) => {
  const k = `${x.adGroup.id}|${x.adGroupCriterion.criterionId}`;
  const a = met.get(k) || { i: 0, c: 0, g: 0, v: 0 };
  a.i += Number(x.metrics.impressions || 0); a.c += Number(x.metrics.clicks || 0);
  a.g += Number(x.metrics.costMicros || 0); a.v += Number(x.metrics.conversions || 0); met.set(k, a);
});
const palavras = r('4 · Google palavras').map((x) => {
  const k = `${x.adGroup.id}|${x.adGroupCriterion.criterionId}`; const a = met.get(k) || { i: 0, c: 0, g: 0, v: 0 };
  return { grupo_id: String(x.adGroup.id), criterio_id: String(x.adGroupCriterion.criterionId), campanha_id: String(x.campaign.id),
    grupo_nome: x.adGroup.name, palavra: x.adGroupCriterion.keyword && x.adGroupCriterion.keyword.text,
    correspondencia: x.adGroupCriterion.keyword && x.adGroupCriterion.keyword.matchType, status: x.adGroupCriterion.status,
    status_veiculacao: x.adGroupCriterion.systemServingStatus || null, aprovacao: x.adGroupCriterion.approvalStatus || null,
    impressoes_7d: a.i, cliques_7d: a.c, custo_7d: m(a.g) || 0, conversoes_7d: a.v };
});
const cli = (r('6 · Google conta')[0] || {}).customer || {};
const orc = r('7 · Google orçamento da conta').map((x) => x.accountBudget || {});
const ads = r('8 · Google anúncios').map((x) => (x.adGroupAd && x.adGroupAd.policySummary && x.adGroupAd.policySummary.approvalStatus) || '');
const conta = { id: '__CONTA__', nome: cli.descriptiveName || null, moeda: cli.currencyCode || null, status: cli.status || null,
  limite_aprovado: orc.length ? m(orc.reduce((s, b) => s + Number(b.approvedSpendingLimitMicros || 0), 0)) : null,
  gasto_servido: orc.length ? m(orc.reduce((s, b) => s + Number(b.amountServedMicros || 0), 0)) : null,
  anuncios_reprovados: ads.filter((s) => s === 'DISAPPROVED').length,
  anuncios_limitados: ads.filter((s) => s === 'APPROVED_LIMITED' || s === 'AREA_OF_INTEREST_ONLY').length };
return [{ json: { p_campanhas: camp, p_diario: diario, p_palavras: palavras, p_conta: conta } }];
""".replace('__CONTA__', CONTA)


def build(ids):
    cred = ids.get('credenciais', {})
    sb_cred = {'supabaseApi': {'id': cred.get('supabase', ''), 'name': dm.CRED_SUPABASE}}
    te_cred = {'httpHeaderAuth': {'id': cred.get('teste', ''), 'name': dm.CRED_TESTE}}
    g_cred = {'googleOAuth2Api': {'id': cred.get(CRED_KEY, ''), 'name': CRED_GOOGLE}}
    nodes = []

    def add(name, ntype, ver, params, x, y, **extra):
        n = {'parameters': params, 'name': name, 'type': ntype, 'typeVersion': ver, 'position': [x, y],
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/google_ads_coleta/{name}'))}
        n.update(extra)
        nodes.append(n)

    add('1 · A cada 15 min', 'n8n-nodes-base.scheduleTrigger', 1.2,
        {'rule': {'interval': [{'field': 'minutes', 'minutesInterval': 15}]}}, 0, 0)
    add('1w · Rodar agora (teste)', 'n8n-nodes-base.webhook', 2, {
        'httpMethod': 'POST', 'path': ROTA, 'authentication': 'headerAuth',
        'responseMode': 'lastNode', 'options': {}}, 0, 220,
        credentials=te_cred, webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, 'niogen/' + ROTA)))
    x = 240
    for nome, gaql, essencial in CONSULTAS:
        extra = {} if essencial else {'onError': 'continueRegularOutput', 'alwaysOutputData': True}
        add(nome, 'n8n-nodes-base.httpRequest', 4.2, {
            'method': 'POST', 'url': GADS,
            'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'googleOAuth2Api',
            'sendBody': True, 'specifyBody': 'json',
            'jsonBody': ('={{ JSON.stringify({ query: ' + json.dumps(gaql).replace('__INI__', f'" + {JANELA_INI} + "')
                         .replace('__FIM__', f'" + {JANELA_FIM} + "') + ' }) }}') if '__INI__' in gaql
            else json.dumps({'query': gaql}, ensure_ascii=False),
            **({'sendHeaders': True, 'headerParameters': {'parameters': [{'name': 'login-customer-id', 'value': LOGIN_CUSTOMER}]}}
               if LOGIN_CUSTOMER else {}),
            'options': {'timeout': 30000}}, x, 100, **({'credentials': g_cred} if cred.get(CRED_KEY) else {}),
            retryOnFail=essencial, maxTries=2, waitBetweenTries=5000, **extra)
        x += 240
    add('9 · Normalizar', 'n8n-nodes-base.code', 2, {'jsCode': NORMALIZAR.strip()}, x, 100)
    add('10 · Supabase gravar', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{SB}/rest/v1/rpc/google_ads_gravar',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': '={{ JSON.stringify($json) }}',
        'options': {'timeout': 20000}}, x + 240, 100, credentials=sb_cred)

    seq = ['1 · A cada 15 min'] + [c[0] for c in CONSULTAS] + ['9 · Normalizar', '10 · Supabase gravar']
    ligacoes = list(zip(seq, seq[1:])) + [('1w · Rodar agora (teste)', CONSULTAS[0][0])]
    nomes = {n['name'] for n in nodes}
    conns = {}
    for o, d in ligacoes:
        assert o in nomes and d in nomes, (o, d)
        conns.setdefault(o, {'main': [[]]})['main'][0].append({'node': d, 'type': 'main', 'index': 0})

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


def cmd_credencial(cid):
    ids = dm.ler_ids()
    ids.setdefault('credenciais', {})[CRED_KEY] = cid
    dm.gravar_ids(ids)
    print(f'credencial {CRED_GOOGLE}: {cid} — rode "estrutura" e depois "rodar".')


def cmd_ativar(ligar=True):
    ids = dm.ler_ids()
    if ligar and not ids.get('credenciais', {}).get(CRED_KEY):
        raise SystemExit('sem credencial OAuth do Google Ads no n8n — crie-a (Ricardo) e rode "credencial <id>" + "estrutura" + "rodar".')
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
            'exportar': cmd_exportar, 'credencial': lambda: cmd_credencial(sys.argv[2])}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds or (sys.argv[1] == 'credencial' and len(sys.argv) < 3):
        raise SystemExit('uso: build | criar | estrutura | ativar | desativar | rodar | exportar | credencial <id>')
    cmds[sys.argv[1]]()

#!/usr/bin/env python3
# NIOGEN | n8n/deploy_ged360_biometria.py | 10/11/2026 — Claude Code (docs/Prompt_status_portal_extensao_101126_1106.md, parte A2)
# Workflow n8n "nio_ged360_biometria": a cada 15 min, 7h–22h, todos os dias (fuso de São Paulo):
#   login no GED360 / BrPronto (login TT837725 — Joysse) → Relatório Detalhado em CSV (Data de Envio dos últimos 15 dias)
#   → RPC ged360_registrar(p_linhas, p_erro) no Supabase Nio (tabela nio_biometria, casa pelo CPF, aplica o mapa).
# Regra 5 (exceção do Ricardo, 10/11 12h39): só login + Relatório Detalhado (leitura/CSV). Nenhuma outra tela, nenhum envio de
# link, nenhuma reanálise. Sem contornar bloqueio de IP. Senha SÓ na credencial do n8n "GED360 (TT837725)" (Custom Auth,
# o Ricardo grava). Nunca em arquivo, log, chat ou Supabase.
# 10/11 ~14h40 (1ª rodada): o login do GED360 é AJAX (login.js) e manda os campos CODIFICADOS — prkUsuario = btoa(usuário) e
# desSenha = btoa(encodeURIComponent(senha)); em texto puro a resposta é {"erro":"Falha ao tentar autenticar no sistema."}.
# A credencial guarda os valores já codificados: {"body": {"dominio": "1", "prkUsuario": "VFQ4Mzc3MjU=", "desSenha": "<btoa(encodeURIComponent(senha))>"}}.
# Falha (login, CSV, rede) → a RPC recebe p_erro e o Painel avisa depois de 2 rodadas seguidas. Nada de retry em laço.
#
# Credenciais (só nomes, nunca valores): "Supabase Nio (service role)", "GED360 (TT837725)". Chave da API do n8n: N8N_API_KEY_NIO.
#
# Uso:
#   python n8n/deploy_ged360_biometria.py teste_ip   # workflow temporário (webhook) faz GET no login do GED360 a partir da VPS e diz o HTTP; apaga depois
#   python n8n/deploy_ged360_biometria.py build      # gera n8n/ged360_biometria.json (export, sem segredos)
#   python n8n/deploy_ged360_biometria.py criar      # cria o workflow INATIVO
#   python n8n/deploy_ged360_biometria.py estrutura  # PUT do workflow inteiro, backup antes (mantém o active atual)
#   python n8n/deploy_ged360_biometria.py ativar     # liga (recusa se a credencial GED360 não existir)
#   python n8n/deploy_ged360_biometria.py exportar   # baixa o estado atual e grava o export sanitizado

import json
import os
import sys
import time
import urllib.request
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_mari as dm   # noqa: E402  (api, ids, checagem de segredo)

AQUI = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(AQUI)
EXPORT = os.path.join(AQUI, 'ged360_biometria.json')
WF_NOME = 'nio_ged360_biometria'
ID_KEY = 'ged360_biometria_workflow_id'
CRED_GED = 'GED360 (TT837725)'
BASE = 'https://ged360.niointernet.com.br/brprontopdv'
LOGIN_PAGINA = f'{BASE}/autenticacao/index'
LOGIN_POST = f'{BASE}/autenticacao/autenticar-usuario'
# Levantamento do Cowork (09/11): Relatórios › Detalhado = POST "relatorio-detalhado-de-digitalizacoes", CSV com vizualizacao=3.
RELATORIO = f'{BASE}/relatorio/relatorio-detalhado-de-digitalizacoes'
UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'

COOKIES_JS = r"""
// Junta os cookies de sessão (Set-Cookie) das respostas anteriores num cabeçalho Cookie. Nada é logado.
const jar = {};
for (const it of $input.all()) {
  const h = (it.json && it.json.headers) || {};
  let sc = h['set-cookie'] || h['Set-Cookie'] || [];
  if (!Array.isArray(sc)) sc = [sc];
  for (const c of sc) { const par = String(c).split(';')[0]; const i = par.indexOf('='); if (i > 0) jar[par.slice(0, i).trim()] = par.slice(i + 1).trim(); }
}
jar.cookieAceitaBrProntoPDV = 'true';   // o aceite de cookies que a tela de login exige (login.js)
const cookie = Object.entries(jar).map(([k, v]) => k + '=' + v).join('; ');
return [{ json: { cookie, tem_cookie: !!cookie } }];
"""

DATAS_JS = r"""
// Janela: Data de Envio dos últimos 15 dias (pega reanálise), no fuso de São Paulo, formato DD/MM/AAAA.
const fmt = (d) => d.toLocaleDateString('pt-BR', { timeZone: 'America/Sao_Paulo', day: '2-digit', month: '2-digit', year: 'numeric' });
const hoje = new Date();
const ini = new Date(hoje.getTime() - 15 * 86400000);
const prev = $('3 · Cookies da sessão').first().json.cookie || '';
const novos = ($input.first().json.headers || {})['set-cookie'] || [];
const jar = {};
for (const par of prev.split(';')) { const i = par.indexOf('='); if (i > 0) jar[par.slice(0, i).trim()] = par.slice(i + 1).trim(); }
for (const c of (Array.isArray(novos) ? novos : [novos])) { const par = String(c).split(';')[0]; const i = par.indexOf('='); if (i > 0) jar[par.slice(0, i).trim()] = par.slice(i + 1).trim(); }
const status = $input.first().json.statusCode;
// O login responde JSON: {"erro": "..."} = recusado (usuário/senha, conta bloqueada…). Sem "erro" = aceito.
let corpo = {};
try { corpo = JSON.parse(String($input.first().json.data || '{}')); } catch (e) { corpo = { erro: 'resposta do login não é JSON' }; }
const recusado = status >= 400 || !!corpo.erro;
return [{ json: { cookie: Object.entries(jar).map(([k, v]) => k + '=' + v).join('; '), ini: fmt(ini), fim: fmt(hoje),
  login_ok: !recusado, login_status: status, login_erro: corpo.erro ? String(corpo.erro).slice(0, 120) : null } }];
"""

CSV_JS = r"""
// CSV do Relatório Detalhado → linhas {protocolo, cpf_cnpj, data_envio, data_conferencia, tipo_servico, resultado}.
// Separador ; ou , (detecta), aspas, cabeçalho por nome. Nunca loga o conteúdo (CPF é dado do cliente da Nio).
const it = $input.first().json;
const dados = String(it.data == null ? '' : it.data);
const erro = (m) => [{ json: { p_linhas: [], p_erro: m } }];
const lg = $('5 · Datas e cookie').first().json;
if (!lg.login_ok) return erro('login recusado pelo GED360: ' + (lg.login_erro || ('HTTP ' + lg.login_status)));
if ((it.statusCode || 200) >= 300) return erro('relatório HTTP ' + it.statusCode + ((it.statusCode < 400) ? ' (redirecionou: sessão não autenticada ou endereço do relatório mudou)' : ''));
if (/<html|<form/i.test(dados.slice(0, 400))) return erro('relatório devolveu página HTML (sessão caiu ou tela mudou), não CSV');
const linhas = dados.replace(/^﻿/, '').split(/\r?\n/).filter((l) => l.trim());
if (!linhas.length) return [{ json: { p_linhas: [], p_erro: null } }];
const sep = (linhas[0].split(';').length >= linhas[0].split(',').length) ? ';' : ',';
const parse = (l) => { const out = []; let cur = '', q = false; for (let i = 0; i < l.length; i++) { const ch = l[i];
  if (q) { if (ch === '"') { if (l[i + 1] === '"') { cur += '"'; i++; } else q = false; } else cur += ch; }
  else if (ch === '"') q = true; else if (ch === sep) { out.push(cur); cur = ''; } else cur += ch; } out.push(cur); return out.map((s) => s.trim()); };
const norm = (s) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z]/g, '');
const cab = parse(linhas[0]).map(norm);
const col = (...nomes) => cab.findIndex((c) => nomes.some((n) => c.includes(n)));
const ix = { protocolo: col('protocolo'), cpf: col('cpf', 'cnpj'), envio: col('datadeenvio', 'envio'), conf: col('conferencia'),
  tipo: col('tipodeservico', 'servico'), resultado: col('resultado') };
if (ix.protocolo < 0 || ix.resultado < 0) return erro('CSV sem as colunas Protocolo/Resultado — cabeçalho mudou');
const out = [];
for (const l of linhas.slice(1)) {
  const c = parse(l);
  const g = (k) => (ix[k] >= 0 ? (c[ix[k]] || '') : '');
  if (!g('protocolo')) continue;
  out.push({ protocolo: g('protocolo'), cpf_cnpj: g('cpf'), data_envio: g('envio'), data_conferencia: g('conf'),
    tipo_servico: g('tipo'), resultado: g('resultado') });
}
return [{ json: { p_linhas: out, p_erro: null } }];
"""


def build(ids):
    cred = ids.get('credenciais', {})
    sb_cred = {'supabaseApi': {'id': cred.get('supabase', ''), 'name': dm.CRED_SUPABASE}}
    ged_cred = {'httpCustomAuth': {'id': cred.get('ged360', ''), 'name': CRED_GED}}
    nodes = []

    def add(name, ntype, ver, params, x, y, **extra):
        n = {'parameters': params, 'name': name, 'type': ntype, 'typeVersion': ver, 'position': [x, y],
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/ged360_biometria/{name}'))}
        n.update(extra)
        nodes.append(n)

    full = {'response': {'response': {'fullResponse': True, 'neverError': True, 'responseFormat': 'text'}},
            'redirect': {'redirect': {'followRedirects': False}}, 'timeout': 30000}
    add('1 · 15 min 7h–22h', 'n8n-nodes-base.scheduleTrigger', 1.2,
        {'rule': {'interval': [{'field': 'cronExpression', 'expression': '*/15 7-22 * * *'}]}}, 0, 0)
    add('2 · GED360 tela de login', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'GET', 'url': LOGIN_PAGINA, 'sendHeaders': True,
        'headerParameters': {'parameters': [{'name': 'User-Agent', 'value': UA}]}, 'options': full}, 220, 0,
        notes='Só pega o cookie de sessão. Nenhuma outra tela.', notesInFlow=True)
    add('3 · Cookies da sessão', 'n8n-nodes-base.code', 2, {'jsCode': COOKIES_JS}, 440, 0)
    add('4 · GED360 login', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': LOGIN_POST,
        'authentication': 'genericCredentialType', 'genericAuthType': 'httpCustomAuth',
        'sendHeaders': True, 'headerParameters': {'parameters': [
            {'name': 'User-Agent', 'value': UA}, {'name': 'Cookie', 'value': '={{ $json.cookie }}'},
            {'name': 'Referer', 'value': LOGIN_PAGINA}, {'name': 'X-Requested-With', 'value': 'XMLHttpRequest'},
            {'name': 'Accept', 'value': 'application/json, text/javascript, */*; q=0.01'},
            # a Custom Auth junta o body da credencial e, sem este cabeçalho, o n8n manda JSON; o GED360 só lê formulário
            {'name': 'Content-Type', 'value': 'application/x-www-form-urlencoded; charset=UTF-8'}]},
        'sendBody': True, 'contentType': 'form-urlencoded',
        'bodyParameters': {'parameters': [{'name': 'dominio', 'value': '1'}, {'name': 'redirect', 'value': ''}]},
        'options': full}, 660, 0, credentials=ged_cred,
        notes='Usuário e senha vêm SÓ da credencial "GED360 (TT837725)" (Custom Auth, body). Login a cada rodada (a sessão cai em < 1 h).',
        notesInFlow=True)
    add('5 · Datas e cookie', 'n8n-nodes-base.code', 2, {'jsCode': DATAS_JS}, 880, 0)
    add('6 · Relatório Detalhado (CSV)', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': RELATORIO, 'sendHeaders': True,
        'headerParameters': {'parameters': [{'name': 'User-Agent', 'value': UA}, {'name': 'Cookie', 'value': '={{ $json.cookie }}'}]},
        'sendBody': True, 'contentType': 'form-urlencoded',
        'bodyParameters': {'parameters': [
            {'name': 'dat_envio_inicial', 'value': '={{ $json.ini }}'}, {'name': 'dat_envio_final', 'value': '={{ $json.fim }}'},
            {'name': 'num_cpf', 'value': ''}, {'name': 'num_protocolo', 'value': ''}, {'name': 'vizualizacao', 'value': '3'}]},
        'options': {**full, 'redirect': {'redirect': {'followRedirects': False}}}}, 1100, 0,
        notes='Só leitura: Relatório Detalhado, exportação CSV nativa (vizualizacao=3).', notesInFlow=True)
    add('7 · CSV → linhas', 'n8n-nodes-base.code', 2, {'jsCode': CSV_JS}, 1320, 0)
    add('8 · Supabase ged360_registrar', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{dm.SB}/rest/v1/rpc/ged360_registrar',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'sendBody': True, 'specifyBody': 'json',
        'jsonBody': '={{ JSON.stringify({ p_linhas: $json.p_linhas, p_erro: $json.p_erro }) }}',
        'options': {'timeout': 30000}}, 1540, 0, credentials=sb_cred)

    ordem = ['1 · 15 min 7h–22h', '2 · GED360 tela de login', '3 · Cookies da sessão', '4 · GED360 login',
             '5 · Datas e cookie', '6 · Relatório Detalhado (CSV)', '7 · CSV → linhas', '8 · Supabase ged360_registrar']
    conns = {}
    for o, d in zip(ordem, ordem[1:]):
        conns.setdefault(o, {'main': [[]]})['main'][0].append({'node': d, 'type': 'main', 'index': 0})
    settings = {'executionOrder': 'v1', 'saveDataErrorExecution': 'all', 'saveDataSuccessExecution': 'none',
                'saveManualExecutions': True, 'timezone': 'America/Sao_Paulo'}
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


def cmd_teste_ip():
    """Workflow temporário: webhook → GET na tela de login do GED360 a partir da VPS do n8n → devolve o HTTP. Apaga no fim."""
    caminho = 'niogen-ged360-ip-' + uuid.uuid4().hex[:10]
    wf = {'name': 'TEMP teste IP GED360 (apagar)', 'settings': {'executionOrder': 'v1'}, 'connections': {
        'W': {'main': [[{'node': 'G', 'type': 'main', 'index': 0}]]}, 'G': {'main': [[{'node': 'R', 'type': 'main', 'index': 0}]]}},
        'nodes': [
            {'name': 'W', 'type': 'n8n-nodes-base.webhook', 'typeVersion': 2, 'position': [0, 0], 'webhookId': str(uuid.uuid4()),
             'parameters': {'path': caminho, 'httpMethod': 'GET', 'responseMode': 'responseNode'}},
            {'name': 'G', 'type': 'n8n-nodes-base.httpRequest', 'typeVersion': 4.2, 'position': [220, 0], 'parameters': {
                'method': 'GET', 'url': LOGIN_PAGINA, 'sendHeaders': True,
                'headerParameters': {'parameters': [{'name': 'User-Agent', 'value': UA}]},
                'options': {'response': {'response': {'fullResponse': True, 'neverError': True, 'responseFormat': 'text'}}, 'timeout': 30000}}},
            {'name': 'R', 'type': 'n8n-nodes-base.respondToWebhook', 'typeVersion': 1.1, 'position': [440, 0], 'parameters': {
                'respondWith': 'json', 'responseBody': "={{ JSON.stringify({ status: $json.statusCode, "
                "tem_form_login: /autenticar-usuario/.test(String($json.body || $json.data || '')), "
                "tamanho: String($json.body || $json.data || '').length }) }}"}}]}
    r = dm.api('POST', '/workflows', wf)
    wid = r['id']
    try:
        dm.api('POST', f'/workflows/{wid}/activate')
        time.sleep(2)
        with urllib.request.urlopen(f'{dm.N8N}/webhook/{caminho}', timeout=60) as resp:
            print('VPS do n8n → GED360:', resp.read().decode())
    finally:
        try:
            dm.api('POST', f'/workflows/{wid}/deactivate')
        finally:
            dm.api('DELETE', f'/workflows/{wid}')
            print('workflow temporário apagado:', wid)


def cmd_criar():
    ids = dm.ler_ids()
    if ids.get(ID_KEY):
        raise SystemExit(f'já existe {ID_KEY} {ids[ID_KEY]} — nada foi criado.')
    existentes = dm.api('GET', '/workflows?limit=250').get('data', [])
    if any(w.get('name') == WF_NOME for w in existentes):
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
    import datetime
    os.makedirs(os.path.join(AQUI, 'backups'), exist_ok=True)
    bk = os.path.join(AQUI, 'backups', f"{WF_NOME}_{datetime.datetime.now():%d%m%y_%H%M%S}.json")
    with open(bk, 'w', encoding='utf-8') as f:
        json.dump(atual, f, ensure_ascii=False, indent=2)
    print('backup:', os.path.relpath(bk, REPO))
    dm.put(ids[ID_KEY], build(ids))
    print('ok (active =', dm.api('GET', f'/workflows/{ids[ID_KEY]}').get('active'), ')')
    cmd_exportar()


def cmd_ativar():
    ids = dm.ler_ids()
    if not ids.get('credenciais', {}).get('ged360'):
        raise SystemExit('credencial "GED360 (TT837725)" ainda não registrada em mari_ids.json (credenciais.ged360) — nada ligado.')
    dm.api('POST', f'/workflows/{ids[ID_KEY]}/activate')
    print('ligado:', dm.api('GET', f'/workflows/{ids[ID_KEY]}').get('active'))
    cmd_exportar()


def cmd_exportar():
    ids = dm.ler_ids()
    salvar(dm.api('GET', f'/workflows/{ids[ID_KEY]}'))


if __name__ == '__main__':
    acoes = {'build': cmd_build, 'teste_ip': cmd_teste_ip, 'criar': cmd_criar, 'estrutura': cmd_estrutura,
             'ativar': cmd_ativar, 'exportar': cmd_exportar}
    if len(sys.argv) < 2 or sys.argv[1] not in acoes:
        raise SystemExit('uso: ' + ' | '.join(acoes))
    acoes[sys.argv[1]]()

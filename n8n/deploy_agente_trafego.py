#!/usr/bin/env python3
# NIOGEN | n8n/deploy_agente_trafego.py | 07/11/2026 — Claude Code, prompt 30 (rota do Agente de Tráfego)
# Workflow n8n "agente_trafego_snapshot": a cada 30 min (07h–23h) chama a RPC agente_trafego_retrato(14) (migration 0059) e
# grava o retrato agregado do funil (Meta × Mari × vendas, só contagens) em agente/funil_agente_trafego.json, na pasta do
# projeto Nio no Google Drive — a única coisa que a máquina do "Agente de Tráfego Nio" (tarefa agendada do claude.ai) alcança.
# Guarda também agente/funil_agente_trafego_DDMMAA.json (1 por dia, último retrato do dia) e manda para a lixeira os diários
# com mais de 30 dias. Nada de dado pessoal no arquivo; nenhum token no Drive (a credencial Google fica só no n8n).
#
# Drive pela API REST (nós HTTP com a credencial OAuth "Google Drive Nio (agente de tráfego)"):
#   procurar pelo nome na pasta → achou: PATCH do conteúdo (mesmo ID, o arquivo não se multiplica) · não achou: POST multipart.
#
# Uso:
#   python n8n/deploy_agente_trafego.py credencial <ID>  # guarda o ID da credencial Google Drive do n8n (vem da URL dela)
#   python n8n/deploy_agente_trafego.py build            # gera n8n/agente_trafego_snapshot.json (export, sem segredos)
#   python n8n/deploy_agente_trafego.py criar            # cria o workflow (INATIVO)
#   python n8n/deploy_agente_trafego.py ativar | desativar
#   python n8n/deploy_agente_trafego.py rodar            # POST na rota de teste (precisa estar ativo) e mostra o retorno
#   python n8n/deploy_agente_trafego.py estrutura        # PUT do workflow inteiro, backup antes
#   python n8n/deploy_agente_trafego.py exportar         # baixa o estado atual e grava o export sanitizado

import datetime
import json
import os
import sys
import urllib.error
import urllib.request
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_mari as dm   # noqa: E402  (api, ids, checagem de segredo, put)

AQUI = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(AQUI)
EXPORT = os.path.join(AQUI, 'agente_trafego_snapshot.json')
WF_NOME = 'agente_trafego_snapshot'
ID_KEY = 'agente_trafego_workflow_id'
SB = dm.SB
ROTA = 'niogen-agente-trafego-snapshot'
CRED_DRIVE = 'Google Drive Nio (agente de tráfego)'   # googleDriveOAuth2Api, conta dona do "Meu Drive"
PASTA = '1Xmwr5XHs-0nUYkkV2XyzEbL-6YnBDj9Q'           # Drive: Projetos Claude / (pasta do projeto Nio) / agente
JANELA_DIAS = 14
DRIVE = 'https://www.googleapis.com/drive/v3/files'
DRIVE_UP = 'https://www.googleapis.com/upload/drive/v3/files'

PREPARAR = r"""
// O retrato vem pronto do banco (agente_trafego_retrato). Aqui só vira texto e ganha os 2 nomes de arquivo.
const r = $input.first().json;
if (!r || !r.gerado_em || !r.totais) throw new Error('retrato vazio ou sem totais — nada foi gravado');
const txt = JSON.stringify(r, null, 2);
const dia = $now.setZone('America/Sao_Paulo').toFormat('ddMMyy');
return ['funil_agente_trafego.json', `funil_agente_trafego_${dia}.json`]
  .map((nome) => ({ json: { nome, conteudo: txt } }));
"""

MONTAR = r"""
// Achou o arquivo na pasta → troca só o conteúdo (mesmo ID). Não achou → cria com multipart (metadados + conteúdo).
const p = $('3 · Preparar arquivos').item.json;
const id = (($json.files || [])[0] || {}).id;
if (id) {
  return { json: { nome: p.nome, acao: 'atualizado', metodo: 'PATCH',
    url: `%UP%/${id}?uploadType=media&fields=id,name,modifiedTime`, tipo: 'application/json; charset=UTF-8', corpo: p.conteudo } };
}
const b = `niogen_${Date.now()}`;
const meta = JSON.stringify({ name: p.nome, parents: ['%PASTA%'], mimeType: 'application/json' });
const corpo = `--${b}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${meta}\r\n`
  + `--${b}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${p.conteudo}\r\n--${b}--`;
return { json: { nome: p.nome, acao: 'criado', metodo: 'POST',
  url: '%UP%?uploadType=multipart&fields=id,name,modifiedTime', tipo: `multipart/related; boundary=${b}`, corpo } };
""".replace('%UP%', DRIVE_UP).replace('%PASTA%', PASTA)

ANTIGOS = r"""
// Só os diários (funil_agente_trafego_DDMMAA.json) com mais de 30 dias; o arquivo principal nunca entra.
const arqs = $input.first().json.files || [];
return arqs.filter((f) => /^funil_agente_trafego_\d{6}\.json$/.test(f.name || ''))
  .map((f) => ({ json: { id: f.id, nome: f.name, modificado: f.modifiedTime } }));
"""


def build(ids):
    cred = ids.get('credenciais', {})
    if not cred.get('google_drive'):
        raise SystemExit('credencial Google Drive ausente em mari_ids.json — rode "credencial <ID>" (ID da URL da credencial no n8n).')
    sb_cred = {'supabaseApi': {'id': cred.get('supabase', ''), 'name': dm.CRED_SUPABASE}}
    te_cred = {'httpHeaderAuth': {'id': cred.get('teste', ''), 'name': dm.CRED_TESTE}}
    gd_cred = {'googleDriveOAuth2Api': {'id': cred['google_drive'], 'name': CRED_DRIVE}}
    nodes = []

    def add(name, ntype, ver, params, x, y, **extra):
        n = {'parameters': params, 'name': name, 'type': ntype, 'typeVersion': ver, 'position': [x, y],
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/{WF_NOME}/{name}'))}
        n.update(extra)
        nodes.append(n)

    def drive(name, params, x, y, **extra):
        p = {'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'googleDriveOAuth2Api',
             'options': {'timeout': 30000}}
        p.update(params)
        add(name, 'n8n-nodes-base.httpRequest', 4.2, p, x, y, credentials=gd_cred,
            retryOnFail=True, maxTries=3, waitBetweenTries=5000, **extra)

    add('1 · A cada 30 min (07h–23h)', 'n8n-nodes-base.scheduleTrigger', 1.2,
        {'rule': {'interval': [{'field': 'cronExpression', 'expression': '0,30 7-23 * * *'}]}}, 0, 0)
    add('1w · Rodar agora (teste)', 'n8n-nodes-base.webhook', 2, {
        # Responde na hora: o último nó (lixeira) quase sempre não tem item, e o "lastNode" daria 500 com tudo gravado.
        # A prova da rodada é o arquivo no Drive (modifiedTime); erro vai para mari_erros pelo errorWorkflow.
        'httpMethod': 'POST', 'path': ROTA, 'authentication': 'headerAuth',
        'responseMode': 'onReceived', 'options': {}}, 0, 220,
        credentials=te_cred, webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, 'niogen/' + ROTA)))
    add('2 · Supabase retrato', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{SB}/rest/v1/rpc/agente_trafego_retrato',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': json.dumps({'p_dias': JANELA_DIAS}),
        'options': {'timeout': 30000}}, 240, 100, credentials=sb_cred, retryOnFail=True, maxTries=3, waitBetweenTries=5000)
    add('3 · Preparar arquivos', 'n8n-nodes-base.code', 2, {'jsCode': PREPARAR.strip()}, 480, 100)
    drive('4 · Drive procurar', {
        'method': 'GET', 'url': DRIVE, 'sendQuery': True, 'queryParameters': {'parameters': [
            {'name': 'q', 'value': f"={{{{ \"name = '\" + $json.nome + \"' and '{PASTA}' in parents and trashed = false\" }}}}"},
            {'name': 'fields', 'value': 'files(id,name,modifiedTime)'},
            {'name': 'spaces', 'value': 'drive'}]}}, 720, 100)
    add('5 · Montar gravação', 'n8n-nodes-base.code', 2, {'mode': 'runOnceForEachItem', 'jsCode': MONTAR.strip()}, 960, 100)
    drive('6 · Drive gravar', {
        'method': '={{ $json.metodo }}', 'url': '={{ $json.url }}',
        'sendBody': True, 'contentType': 'raw', 'rawContentType': '={{ $json.tipo }}', 'body': '={{ $json.corpo }}'}, 1200, 100)
    drive('7 · Drive diários antigos', {
        'method': 'GET', 'url': DRIVE, 'sendQuery': True, 'queryParameters': {'parameters': [
            {'name': 'q', 'value': ("={{ \"name contains 'funil_agente_trafego_' and '" + PASTA + "' in parents and trashed = false"
                                    " and modifiedTime < '\" + $now.minus({ days: 30 }).toUTC().toISO() + \"'\" }}")},
            {'name': 'fields', 'value': 'files(id,name,modifiedTime)'},
            {'name': 'pageSize', 'value': '100'}]}}, 1440, 100, executeOnce=True)
    add('8 · Diários a apagar', 'n8n-nodes-base.code', 2, {'jsCode': ANTIGOS.strip()}, 1680, 100)
    # Lixeira, não exclusão definitiva (fica 30 dias recuperável no Drive).
    drive('9 · Drive lixeira', {
        'method': 'PATCH', 'url': f'={{{{ "{DRIVE}/" + $json.id }}}}',
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': '{"trashed": true}'}, 1920, 100)

    ligacoes = [
        ('1 · A cada 30 min (07h–23h)', '2 · Supabase retrato'),
        ('1w · Rodar agora (teste)', '2 · Supabase retrato'),
        ('2 · Supabase retrato', '3 · Preparar arquivos'),
        ('3 · Preparar arquivos', '4 · Drive procurar'),
        ('4 · Drive procurar', '5 · Montar gravação'),
        ('5 · Montar gravação', '6 · Drive gravar'),
        ('6 · Drive gravar', '7 · Drive diários antigos'),
        ('7 · Drive diários antigos', '8 · Diários a apagar'),
        ('8 · Diários a apagar', '9 · Drive lixeira'),
    ]
    nomes = {n['name'] for n in nodes}
    conns = {}
    for o, d in ligacoes:
        assert o in nomes and d in nomes, (o, d)
        conns.setdefault(o, {'main': [[]]})['main'][0].append({'node': d, 'type': 'main', 'index': 0})

    # Sucesso não fica salvo (34 execuções/dia); erro fica, e vai para o Error Trigger do mari_principal (mari_erros).
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


def cmd_credencial():
    if len(sys.argv) < 3 or not sys.argv[2].strip():
        raise SystemExit('uso: credencial <ID da credencial Google Drive no n8n>')
    ids = dm.ler_ids()
    ids.setdefault('credenciais', {})['google_drive'] = sys.argv[2].strip()
    dm.gravar_ids(ids)
    print(f'google_drive = {sys.argv[2].strip()} ({CRED_DRIVE})')


def cmd_criar():
    ids = dm.ler_ids()
    if ids.get(ID_KEY):
        raise SystemExit(f'já existe {ID_KEY} {ids[ID_KEY]} — use "estrutura".')
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
    backup(achar_wf(ids))
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
        with urllib.request.urlopen(req, timeout=120) as r:
            print(r.status, r.read().decode()[:800])
    except urllib.error.HTTPError as e:
        raise SystemExit(f'HTTP {e.code}: {e.read().decode()[:800]}')


def cmd_exportar():
    wf = achar_wf(dm.ler_ids())
    salvar_export({'name': wf['name'], 'nodes': wf['nodes'], 'connections': wf['connections'],
                   'settings': wf.get('settings', {}), 'active': wf.get('active')})


if __name__ == '__main__':
    cmds = {'credencial': cmd_credencial, 'build': lambda: salvar_export(build(dm.ler_ids())), 'criar': cmd_criar,
            'estrutura': cmd_estrutura, 'ativar': lambda: cmd_ativar(True), 'desativar': lambda: cmd_ativar(False),
            'rodar': cmd_rodar, 'exportar': cmd_exportar}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds:
        raise SystemExit('uso: credencial <ID> | build | criar | ativar | desativar | rodar | estrutura | exportar')
    cmds[sys.argv[1]]()

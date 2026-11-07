#!/usr/bin/env python3
# NIOGEN | n8n/deploy_cadencia.py | 04/11/2026 — Claude Code (prompt nº 11)
# Build e deploy do workflow n8n "mari_cadencia" (F1/F2 + D3/D7/D15 + avulsos). Mesmo padrão do deploy_mari.py:
# backup antes de qualquer PUT e este script SÓ opera no workflow "mari_cadencia" (não lê para escrita nem o
# mari_principal nem nada da Renata). A decisão de cada envio está no banco (mari_cadencia_candidatos);
# o workflow só executa. Monta e fica DESLIGADO: inativo no n8n + kill switch staticData._cadenciaAtiva = false.
# 07/11 (prompt 28): nós 6g/7 sem `disabled` (só rodam no modo chatwoot; no modo teste o 5s desvia antes), conta
# Chatwoot 195428 no c05, e o ramo 9 (interesse futuro: etiqueta + nota privada, 0052) — também só no modo chatwoot.
# Ligar continua sendo pela rota admin ({"admin":"modo chatwoot"} e {"admin":"ligar"}) + ativar no n8n, com o OK do Ricardo.
#
# Chave da API: N8N_API_KEY_NIO (ambiente ou variável de usuário do Windows). Nunca em arquivo.
#
# Uso:
#   python n8n/deploy_cadencia.py build          # gera n8n/mari_cadencia.json (export, sem segredos)
#   python n8n/deploy_cadencia.py credencial     # cria "Chatwoot Nio" (header api_access_token, valor a colar no painel)
#   python n8n/deploy_cadencia.py criar          # cria o workflow INATIVO; falha se o nome já existe
#   python n8n/deploy_cadencia.py estrutura      # PUT do workflow inteiro, backup antes (mantém o active atual)
#   python n8n/deploy_cadencia.py desativar      # garante inativo
#   python n8n/deploy_cadencia.py exportar       # baixa o estado atual e grava o export sanitizado
# (não há "ativar" aqui de propósito: ligar a cadência é decisão do Ricardo, junto com o modo chatwoot da Mari)

import datetime
import json
import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_mari as dm   # noqa: E402  (api, ids, checagem de segredo)

AQUI = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(AQUI)
JS_DIR = os.path.join(AQUI, 'cadencia')
EXPORT = os.path.join(AQUI, 'mari_cadencia.json')
WF_NOME = 'mari_cadencia'
SB = dm.SB
CRED_CHATWOOT = 'Chatwoot Nio'

CODE = {
    '2 · Interruptor': 'c02_interruptor.js',
    '3b · Itens': 'c03_itens.js',
    '5 · Montar envio': 'c05_montar.js',
    '6h · Guard Chatwoot': 'c06_guard.js',
    '7r · Resultado': 'c07_resultado.js',
    '9b · Itens futuro': 'c09b_futuro_itens.js',
    '9d · Montar etiquetas': 'c09d_futuro_etiquetas.js',
    '9h · Conferir': 'c09h_futuro_conferir.js',
}


def js(arq):
    with open(os.path.join(JS_DIR, arq), encoding='utf-8') as f:
        return f.read()


def build(ids):
    cred = ids.get('credenciais', {})
    sb_cred = {'supabaseApi': {'id': cred.get('supabase', ''), 'name': dm.CRED_SUPABASE}}
    te_cred = {'httpHeaderAuth': {'id': cred.get('teste', ''), 'name': dm.CRED_TESTE}}
    cw_cred = {'httpHeaderAuth': {'id': cred.get('chatwoot', ''), 'name': CRED_CHATWOOT}}
    nodes = []

    def add(name, ntype, ver, params, x, y, **extra):
        n = {'parameters': params, 'name': name, 'type': ntype, 'typeVersion': ver, 'position': [x, y],
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/mari_cadencia/{name}'))}
        n.update(extra)
        nodes.append(n)

    def code(name, x, y):
        add(name, 'n8n-nodes-base.code', 2, {'jsCode': js(CODE[name])}, x, y)

    def iff(name, expr, x, y):
        add(name, 'n8n-nodes-base.if', 2, {
            'conditions': {
                'options': {'caseSensitive': True, 'leftValue': '', 'typeValidation': 'loose'},
                'conditions': [{'id': str(uuid.uuid5(uuid.NAMESPACE_URL, 'cad/' + name)), 'leftValue': expr, 'rightValue': '',
                                'operator': {'type': 'boolean', 'operation': 'true', 'singleValue': True}}],
                'combinator': 'and'},
            'options': {}}, x, y)

    def rpc(name, fn, body_expr, x, y, **extra):
        add(name, 'n8n-nodes-base.httpRequest', 4.2, {
            'method': 'POST', 'url': f'{SB}/rest/v1/rpc/{fn}',
            'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
            'sendBody': True, 'specifyBody': 'json', 'jsonBody': body_expr,
            'options': {'timeout': 20000}}, x, y, credentials=sb_cred, **extra)

    add('1 · A cada 10 min', 'n8n-nodes-base.scheduleTrigger', 1.2,
        {'rule': {'interval': [{'field': 'minutes', 'minutesInterval': 10}]}}, 0, 0)
    add('1w · Admin cadência', 'n8n-nodes-base.webhook', 2, {
        'httpMethod': 'POST', 'path': 'mari-cadencia-admin', 'authentication': 'headerAuth',
        'responseMode': 'responseNode', 'options': {}}, 0, 300,
        credentials=te_cred, webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, 'niogen/mari-cadencia-admin')))
    code('2 · Interruptor', 220, 100)
    iff('2a · Admin?', '={{ $json.admin === true }}', 440, 100)
    add('2r · Responder admin', 'n8n-nodes-base.respondToWebhook', 1.1, {
        'respondWith': 'json', 'responseBody': '={{ JSON.stringify($json.resposta) }}', 'options': {}}, 660, 0)
    rpc('3 · Supabase candidatos', 'mari_cadencia_candidatos',
        '={{ JSON.stringify({ p_agora: $json.agora, p_canal: $json.canal, p_limite: $json.limite }) }}', 660, 200)
    code('3b · Itens', 880, 200)
    add('4 · Um por vez', 'n8n-nodes-base.splitInBatches', 3, {'batchSize': 1, 'options': {}}, 1100, 200)
    code('5 · Montar envio', 1320, 300)
    iff('5s · Sem envio real?', '={{ $json.semEnvio === true || !!$json.erro }}', 1540, 300)
    add('6g · Chatwoot conversa', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'GET',
        'url': '=https://app.chatwoot.com/api/v1/accounts/{{ $json.config.CHATWOOT_NIO_ACCOUNT }}/conversations/{{ $json.chatwootConversationId }}',
        'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth',
        'options': {'timeout': 10000}}, 1760, 500, credentials=cw_cred, onError='continueRegularOutput',
        notes='MODO CHATWOOT — guard: relê a conversa antes de enviar (só roda com _modoCadencia = chatwoot).')
    code('6h · Guard Chatwoot', 1980, 500)
    iff('6i · Parar escada?', '={{ $json.parar === true }}', 2200, 500)
    rpc('6p · Supabase parar', 'mari_cadencia_parar',
        '={{ JSON.stringify({ p_conversa: $json.conversaId, p_humano: !!$json.humano, p_time: !!$json.time, p_resolvida: !!$json.resolvida, p_nao_contatar: !!$json.naoContatar }) }}',
        2420, 400)
    iff('6e · Enviar?', '={{ $json.enviar === true }}', 2420, 600)
    add('7 · Chatwoot enviar', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST',
        'url': "={{ 'https://app.chatwoot.com/api/v1/accounts/' + $json.config.CHATWOOT_NIO_ACCOUNT + '/conversations/' + $json.chatwootConversationId + '/messages' }}",
        'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth',
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': '={{ JSON.stringify($json.corpo) }}',
        'options': {'timeout': 15000}}, 2640, 700, credentials=cw_cred, onError='continueRegularOutput',
        notes='MODO CHATWOOT — envio SEMPRE pela API do Chatwoot (bolha na conversa). Só roda com _modoCadencia = chatwoot.')
    code('7r · Resultado', 2860, 700)
    rpc('8 · Supabase registrar', 'mari_cadencia_registrar',
        '={{ JSON.stringify({ p_conversa: $json.conversaId, p_passo: $json.passo, '
        'p_ok: ($json.ok !== undefined ? $json.ok : !$json.erro), p_erro: $json.erro || null, '
        'p_texto: $json.texto || null, p_excecao: $json.excecao || null }) }}', 3080, 300)

    # ── 9 · Interesse futuro (prompt 28, 0052): etiqueta interesse-futuro + nota privada, só no modo chatwoot ──
    cw_base = "'https://app.chatwoot.com/api/v1/accounts/' + $json.conta + '/conversations/' + $json.cw"
    iff('9 · Futuro? (modo chatwoot)', "={{ $('2 · Interruptor').first().json.modo === 'chatwoot' }}", 660, 900)
    rpc('9a · Supabase futuro', 'mari_futuro_pendentes', '={{ JSON.stringify({ p_limite: 20 }) }}', 880, 900,
        onError='continueRegularOutput')
    code('9b · Itens futuro', 1100, 900)
    add('9c · Chatwoot ler', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'GET', 'url': '={{ ' + cw_base + ' }}',
        'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth',
        'options': {'timeout': 10000}}, 1320, 900, credentials=cw_cred, onError='continueRegularOutput')
    code('9d · Montar etiquetas', 1540, 900)
    iff('9e · Etiquetar?', '={{ $json.ok === true }}', 1760, 900)
    add('9f · Chatwoot etiquetas', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': '={{ ' + cw_base + " + '/labels' }}",
        'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth',
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': '={{ JSON.stringify({ labels: $json.labels }) }}',
        'options': {'timeout': 10000}}, 1980, 900, credentials=cw_cred, onError='continueRegularOutput',
        notes='POST /labels SUBSTITUI a lista: o 9d já mandou as atuais + interesse-futuro.')
    add('9g · Chatwoot nota', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST',
        'url': "={{ 'https://app.chatwoot.com/api/v1/accounts/' + $('9d · Montar etiquetas').item.json.conta + "
               "'/conversations/' + $('9d · Montar etiquetas').item.json.cw + '/messages' }}",
        'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth',
        'sendBody': True, 'specifyBody': 'json',
        'jsonBody': "={{ JSON.stringify({ content: $('9d · Montar etiquetas').item.json.nota, message_type: 'outgoing', private: true }) }}",
        'options': {'timeout': 10000}}, 2200, 900, credentials=cw_cred, onError='continueRegularOutput',
        notes='Nota PRIVADA (o cliente não vê).')
    code('9h · Conferir', 2420, 900)
    iff('9i · Marcar?', '={{ $json.marcar === true }}', 2640, 900)
    rpc('9j · Supabase marcar', 'mari_futuro_marcar',
        '={{ JSON.stringify({ p_conversa: $json.conversaId, p_para: $json.voltaEm }) }}', 2860, 900)

    ligacoes = [
        ('1 · A cada 10 min', 0, '2 · Interruptor'),
        ('1w · Admin cadência', 0, '2 · Interruptor'),
        ('2 · Interruptor', 0, '2a · Admin?'),
        ('2a · Admin?', 0, '2r · Responder admin'),
        ('2a · Admin?', 1, '3 · Supabase candidatos'),
        ('3 · Supabase candidatos', 0, '3b · Itens'),
        ('3b · Itens', 0, '4 · Um por vez'),
        ('4 · Um por vez', 1, '5 · Montar envio'),
        ('5 · Montar envio', 0, '5s · Sem envio real?'),
        ('5s · Sem envio real?', 0, '8 · Supabase registrar'),
        ('5s · Sem envio real?', 1, '6g · Chatwoot conversa'),
        ('6g · Chatwoot conversa', 0, '6h · Guard Chatwoot'),
        ('6h · Guard Chatwoot', 0, '6i · Parar escada?'),
        ('6i · Parar escada?', 0, '6p · Supabase parar'),
        ('6i · Parar escada?', 1, '6e · Enviar?'),
        ('6p · Supabase parar', 0, '4 · Um por vez'),
        ('6e · Enviar?', 0, '7 · Chatwoot enviar'),
        ('6e · Enviar?', 1, '8 · Supabase registrar'),
        ('7 · Chatwoot enviar', 0, '7r · Resultado'),
        ('7r · Resultado', 0, '8 · Supabase registrar'),
        ('8 · Supabase registrar', 0, '4 · Um por vez'),
        # ramo 9 (interesse futuro) — roda depois do ramo principal (executionOrder v1)
        ('2a · Admin?', 1, '9 · Futuro? (modo chatwoot)'),
        ('9 · Futuro? (modo chatwoot)', 0, '9a · Supabase futuro'),
        ('9a · Supabase futuro', 0, '9b · Itens futuro'),
        ('9b · Itens futuro', 0, '9c · Chatwoot ler'),
        ('9c · Chatwoot ler', 0, '9d · Montar etiquetas'),
        ('9d · Montar etiquetas', 0, '9e · Etiquetar?'),
        ('9e · Etiquetar?', 0, '9f · Chatwoot etiquetas'),
        ('9f · Chatwoot etiquetas', 0, '9g · Chatwoot nota'),
        ('9g · Chatwoot nota', 0, '9h · Conferir'),
        ('9h · Conferir', 0, '9i · Marcar?'),
        ('9i · Marcar?', 0, '9j · Supabase marcar'),
    ]
    nomes = {n['name'] for n in nodes}
    conns = {}
    for o, i, d in ligacoes:
        assert o in nomes and d in nomes, (o, d)
        main = conns.setdefault(o, {'main': []})['main']
        while len(main) <= i:
            main.append([])
        main[i].append({'node': d, 'type': 'main', 'index': 0})

    settings = {'executionOrder': 'v1', 'saveDataErrorExecution': 'all', 'saveDataSuccessExecution': 'all',
                'saveManualExecutions': True, 'timezone': 'America/Sao_Paulo'}
    if ids.get('workflow_id'):
        settings['errorWorkflow'] = ids['workflow_id']   # o Error Trigger do mari_principal grava em mari_erros
    return {'name': WF_NOME, 'nodes': nodes, 'connections': conns, 'settings': settings}


def salvar_export(wf):
    dm.checar_sem_segredo(wf)
    with open(EXPORT, 'w', encoding='utf-8') as f:
        json.dump(wf, f, ensure_ascii=False, indent=2)
        f.write('\n')
    print(f'export: {os.path.relpath(EXPORT, REPO)} ({len(wf["nodes"])} nós)')


def achar_wf(ids):
    wid = ids.get('cadencia_workflow_id')
    if not wid:
        raise SystemExit('cadencia_workflow_id ausente em mari_ids.json — rode "criar" antes.')
    wf = dm.api('GET', f'/workflows/{wid}')
    if wf.get('name') != WF_NOME:
        raise SystemExit(f'o ID {wid} não é o {WF_NOME} (é "{wf.get("name")}") — abortado, nada foi alterado.')
    return wf


def backup(wf):
    os.makedirs(dm.BACKUP_DIR, exist_ok=True)
    p = os.path.join(dm.BACKUP_DIR, f'mari_cadencia_{datetime.datetime.now().strftime("%d%m%y_%H%M%S")}.json')
    with open(p, 'w', encoding='utf-8') as f:
        json.dump(wf, f, ensure_ascii=False, indent=2)
    print(f'backup: {os.path.relpath(p, REPO)}')


def cmd_credencial():
    ids = dm.ler_ids()
    cred = ids.setdefault('credenciais', {})
    if cred.get('chatwoot'):
        print(f'já existe: {CRED_CHATWOOT} ({cred["chatwoot"]})')
        return
    r = dm.api('POST', '/credentials', {'name': CRED_CHATWOOT, 'type': 'httpHeaderAuth',
                                         'data': {'name': 'api_access_token', 'value': 'COLE_AQUI'}})
    cred['chatwoot'] = r['id']
    dm.gravar_ids(ids)
    print(f'criada: {CRED_CHATWOOT} ({r["id"]}) — colar o api_access_token da conta Nio no painel do n8n')


def cmd_criar():
    ids = dm.ler_ids()
    if ids.get('cadencia_workflow_id'):
        raise SystemExit(f'já existe cadencia_workflow_id {ids["cadencia_workflow_id"]} — use "estrutura".')
    existentes = dm.api('GET', '/workflows?limit=250').get('data', [])
    if any(w.get('name') == WF_NOME for w in existentes):
        raise SystemExit(f'já existe um workflow chamado {WF_NOME} no n8n — nada foi criado.')
    wf = build(ids)
    dm.checar_sem_segredo(wf)
    r = dm.api('POST', '/workflows', wf)
    ids['cadencia_workflow_id'] = r['id']
    dm.gravar_ids(ids)
    print(f'criado: {WF_NOME} ({r["id"]}), active={r.get("active")}')
    cmd_exportar()


def cmd_estrutura():
    ids = dm.ler_ids()
    atual = achar_wf(ids)
    backup(atual)
    dm.put(ids['cadencia_workflow_id'], build(ids))
    print('ok (active =', dm.api('GET', f'/workflows/{ids["cadencia_workflow_id"]}').get('active'), ')')
    cmd_exportar()


def cmd_desativar():
    ids = dm.ler_ids()
    wf = achar_wf(ids)
    if wf.get('active'):
        r = dm.api('POST', f'/workflows/{ids["cadencia_workflow_id"]}/deactivate')
        print(f'{WF_NOME}: active={r.get("active")}')
    else:
        print(f'{WF_NOME}: já inativo')


def cmd_exportar():
    ids = dm.ler_ids()
    wf = achar_wf(ids)
    sdg = (wf.get('staticData') or {}).get('global', {})
    limpo = {'name': wf['name'], 'nodes': wf['nodes'], 'connections': wf['connections'],
             'settings': wf.get('settings', {}), 'active': wf.get('active'),
             'staticData': {'_cadenciaAtiva': sdg.get('_cadenciaAtiva', False), '_modoCadencia': sdg.get('_modoCadencia', 'teste')}}
    salvar_export(limpo)


if __name__ == '__main__':
    cmds = {'build': lambda: salvar_export(build(dm.ler_ids())), 'credencial': cmd_credencial, 'criar': cmd_criar,
            'estrutura': cmd_estrutura, 'desativar': cmd_desativar, 'exportar': cmd_exportar}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds:
        raise SystemExit('uso: build | credencial | criar | estrutura | desativar | exportar')
    cmds[sys.argv[1]]()

#!/usr/bin/env python3
# NIOGEN | n8n/deploy_mari.py | 04/11/2026 — Claude Code (prompt nº 8)
# Build e deploy do workflow n8n "mari_principal" (Mari v1). Padrão deploy_node_only.py da Renata:
# backup antes de qualquer PUT, raio de ação mínimo, e este script SÓ opera no workflow "mari_principal"
# (a chave do n8n enxerga os workflows da Renata — nenhum deles é lido para escrita aqui).
#
# Chave da API: variável de ambiente N8N_API_KEY_NIO (ou a do perfil do usuário no Windows). Nunca em arquivo.
# Segredos das credenciais: nunca passam por aqui, exceto o MARI_TESTE_SECRET, gerado na criação e gravado
# só na credencial do n8n e na variável de ambiente do usuário (nunca impresso).
#
# Uso:
#   python n8n/deploy_mari.py build                 # gera n8n/mari_principal.json (export, sem segredos)
#   python n8n/deploy_mari.py credenciais           # cria as 3 credenciais (se ainda não existem em mari_ids.json)
#   python n8n/deploy_mari.py criar                 # cria o workflow (inativo); falha se o nome já existe
#   python n8n/deploy_mari.py codigo [--dry-run]    # deploy cirúrgico: só o jsCode dos nós Code muda (backup antes)
#   python n8n/deploy_mari.py estrutura             # PUT do workflow inteiro (nós + conexões), backup antes
#   python n8n/deploy_mari.py ativar | desativar    # liga/desliga o mari_principal (nada mais)
#   python n8n/deploy_mari.py exportar              # baixa o estado atual e grava o export sanitizado

import datetime
import json
import os
import re
import secrets
import sys
import urllib.error
import urllib.request
import uuid

if sys.platform == 'win32':
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

AQUI = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(AQUI)
JS_DIR = os.path.join(AQUI, 'mari')
BACKUP_DIR = os.path.join(AQUI, 'backups')
EXPORT = os.path.join(AQUI, 'mari_principal.json')
IDS = os.path.join(AQUI, 'mari_ids.json')            # IDs do workflow e das credenciais (não são segredo)
PROMPT_FILE = os.path.join(REPO, 'mari', 'prompt_mari_v2.md')
PROMPT_VERSAO = 'mari_v2'

N8N = 'https://n8n.ofertasverointernet.com.br'
WF_NOME = 'mari_principal'
SB = 'https://zlrfwbkblytnokuexjti.supabase.co'      # Supabase Nio (não é o da Vero)

CRED_SUPABASE = 'Supabase Nio (service role)'
CRED_CLAUDE = 'Claude API Nio'
CRED_TESTE = 'MARI_TESTE_SECRET'
CRED_CHATWOOT = 'Chatwoot Nio'                         # header api_access_token (conta "Nio Atendimento")
HEADER_TESTE = 'X-Mari-Secret'


# ─────────────────────────────── utilidades ───────────────────────────────

def env_usuario(nome):
    v = os.environ.get(nome)
    if v:
        return v
    if sys.platform == 'win32':
        import winreg
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, 'Environment') as h:
                return winreg.QueryValueEx(h, nome)[0]
        except OSError:
            return None
    return None


def gravar_env_usuario(nome, valor):
    if sys.platform != 'win32':
        raise SystemExit('Gravar variável de usuário só está implementado no Windows.')
    import winreg
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, 'Environment', 0, winreg.KEY_SET_VALUE) as h:
        winreg.SetValueEx(h, nome, 0, winreg.REG_SZ, valor)


def api(method, path, data=None):
    chave = env_usuario('N8N_API_KEY_NIO')
    if not chave:
        raise SystemExit('N8N_API_KEY_NIO ausente.')
    body = json.dumps(data, ensure_ascii=True).encode() if data is not None else None
    req = urllib.request.Request(f'{N8N}/api/v1{path}', data=body, method=method,
                                 headers={'X-N8N-API-KEY': chave, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raise SystemExit(f'[n8n] HTTP {e.code} em {method} {path}: {e.read().decode()[:600]}')


def ler_ids():
    if os.path.exists(IDS):
        with open(IDS, encoding='utf-8') as f:
            return json.load(f)
    return {}


def gravar_ids(d):
    with open(IDS, 'w', encoding='utf-8') as f:
        json.dump(d, f, ensure_ascii=False, indent=2)
        f.write('\n')


def ler_prompt():
    with open(PROMPT_FILE, encoding='utf-8') as f:
        s = f.read()
    ini, fim = '<!-- PROMPT:INICIO -->', '<!-- PROMPT:FIM -->'
    if ini not in s or fim not in s:
        raise SystemExit('prompt sem marcadores PROMPT:INICIO / PROMPT:FIM')
    corpo = s[s.index(ini) + len(ini):s.index(fim)]
    linhas = [l for l in corpo.split('\n') if not l.startswith('# DECISÃO PENDENTE')]
    texto = '\n'.join(linhas).strip() + '\n'
    if re.search(r'dharma', texto, re.I):
        raise SystemExit('o prompt contém "Dharma" — proibido (regra do Ricardo, 03/11).')
    for ph in ('{{DATA_HORA_ATUAL}}', '{{HORARIO_COMERCIAL}}', '{{ESTADO_ATUAL}}', '{{INTERNAL_DATA}}'):
        if ph not in texto:
            raise SystemExit(f'placeholder ausente no prompt: {ph}')
    return texto


def js(arquivo):
    with open(os.path.join(JS_DIR, arquivo), encoding='utf-8') as f:
        code = f.read()
    if arquivo == 'n05a_conteudo.js':
        code = code.replace('__PROMPT_MARI__', json.dumps(ler_prompt(), ensure_ascii=False))
        code = code.replace('__PROMPT_VERSAO__', json.dumps(PROMPT_VERSAO))
    return code


# ─────────────────────────────── o workflow ───────────────────────────────

# nome do nó Code → arquivo .js
CODE = {
    '2 · Entrada': 'n02_entrada.js',
    '2h · Guard humano': 'n02h_guard_humano.js',
    '3e · Espera lock': 'n03e_espera_lock.js',
    '4 · Preparar': 'n04_preparar.js',
    '2c · Mídia': 'n02c_midia.js',
    '5a · Conteúdo Mari': 'n05a_conteudo.js',
    '5b · Motor': 'n05b_motor.js',
    '5c · Pedido de correção': 'n05c_correcao.js',
    '7 · Extrair': 'n07_extrair.js',
    '7r · Extrair (correção)': 'n07_extrair.js',
    '7c · Anti-duplicata': 'n07c_duplicata.js',
    '10 · Salvar turno': 'n10_salvar.js',
    '11 · Saída': 'n11_saida.js',
    'E1 · Log erro': 'nE1_log_erro.js',
}


def build(ids):
    cred = ids.get('credenciais', {})
    sb_cred = {'supabaseApi': {'id': cred.get('supabase', ''), 'name': CRED_SUPABASE}}
    cl_cred = {'anthropicApi': {'id': cred.get('claude', ''), 'name': CRED_CLAUDE}}
    te_cred = {'httpHeaderAuth': {'id': cred.get('teste', ''), 'name': CRED_TESTE}}
    cw_cred = {'httpHeaderAuth': {'id': cred.get('chatwoot', ''), 'name': CRED_CHATWOOT}}

    nodes = []
    pos = {}

    def add(name, ntype, ver, params, x, y, **extra):
        n = {'parameters': params, 'name': name, 'type': ntype, 'typeVersion': ver, 'position': [x, y],
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/mari_principal/{name}'))}
        n.update(extra)
        nodes.append(n)
        pos[name] = (x, y)

    def code(name, x, y):
        add(name, 'n8n-nodes-base.code', 2, {'jsCode': js(CODE[name])}, x, y)

    def iff(name, expr, x, y):
        add(name, 'n8n-nodes-base.if', 2, {
            'conditions': {
                'options': {'caseSensitive': True, 'leftValue': '', 'typeValidation': 'strict'},
                'conditions': [{'id': str(uuid.uuid5(uuid.NAMESPACE_URL, name)), 'leftValue': expr, 'rightValue': '',
                                'operator': {'type': 'boolean', 'operation': 'true', 'singleValue': True}}],
                'combinator': 'and'},
            'options': {}}, x, y)

    def rpc(name, fn, body_expr, x, y, **extra):
        add(name, 'n8n-nodes-base.httpRequest', 4.2, {
            'method': 'POST', 'url': f'{SB}/rest/v1/rpc/{fn}',
            'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
            'sendBody': True, 'specifyBody': 'json', 'jsonBody': body_expr,
            'options': {'timeout': 20000}}, x, y, credentials=sb_cred, **extra)

    def claude(name, x, y):
        add(name, 'n8n-nodes-base.httpRequest', 4.2, {
            'method': 'POST', 'url': 'https://api.anthropic.com/v1/messages',
            'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'anthropicApi',
            'sendHeaders': True,
            'headerParameters': {'parameters': [{'name': 'anthropic-version', 'value': '2023-06-01'}]},
            'sendBody': True, 'specifyBody': 'json',
            # Guard de thinking OBRIGATÓRIO (Renata, 18/08): sem ele content[0] vira bloco de thinking.
            'jsonBody': '={{ JSON.stringify({ model: $json.model, max_tokens: $json.maxTokens, '
                        'thinking: { type: "disabled" }, system: $json.system, messages: $json.messages }) }}',
            'options': {'timeout': 90000}}, x, y, credentials=cl_cred,
            onError='continueRegularOutput', retryOnFail=True, maxTries=2, waitBetweenTries=3000)

    E = "$('3a · Supabase entrada').first().json"
    # ── entrada ──
    add('1 · Webhook Mari teste', 'n8n-nodes-base.webhook', 2, {
        'httpMethod': 'POST', 'path': 'mari-teste', 'authentication': 'headerAuth',
        'responseMode': 'responseNode', 'options': {}}, 0, 0,
        credentials=te_cred, webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, 'niogen/mari-teste')))
    add('1c · Webhook Chatwoot', 'n8n-nodes-base.webhook', 2, {
        'httpMethod': 'POST', 'path': 'mari-chatwoot', 'responseMode': 'responseNode', 'options': {}}, 0, 200,
        webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, 'niogen/mari-chatwoot')),
        notes='MODO CHATWOOT — webhook de conta do Chatwoot "Nio Atendimento". Origem validada no nó 2 · Entrada '
              '(header x-chatwoot-signature + conta/caixa da Nio). Só processa com staticData._modoMari = chatwoot.')
    # O n8n recusa webhook "onReceived" num workflow que tem Respond to Webhook (o 12t da rota de teste):
    # o 1c responde por este nó, na hora (200 sem corpo), e a execução segue para o 2 · Entrada.
    add('1r · OK Chatwoot', 'n8n-nodes-base.respondToWebhook', 1.1, {
        'respondWith': 'noData', 'options': {}}, 110, 300)
    code('2 · Entrada', 220, 100)
    iff('2e · Encerrar?', '={{ $json.encerrar === true }}', 440, 100)
    # Fala do consultor no Chatwoot → turno 'humano' no histórico (sem resposta; eco da Mari descartado no banco).
    iff('2x · Fala humana?', "={{ $json.registrar === 'humano' }}", 550, 350)
    rpc('2y · Supabase registrar humano', 'mari_registrar_turno',
        "={{ JSON.stringify({ p_telefone: $json.telefone, p_nome: $json.nome, p_texto: $json.texto, p_papel: 'humano', "
        "p_canal: $json.canal, p_chatwoot_conversation_id: $json.chatwootConversationId }) }}", 770, 550)
    iff('2m · Modo chatwoot?', "={{ $json.modo === 'chatwoot' }}", 660, 200)
    add('2g · Chatwoot conversa', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'GET',
        'url': "=https://app.chatwoot.com/api/v1/accounts/{{ $json.config.CHATWOOT_NIO_ACCOUNT }}/conversations/{{ $json.chatwootConversationId }}",
        'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth',
        'options': {'timeout': 10000}}, 880, 300, credentials=cw_cred, onError='continueRegularOutput',
        notes='MODO CHATWOOT — GET da conversa para o guard de humano/time/resolvida. Credencial "Chatwoot Nio".')
    code('2h · Guard humano', 1100, 200)
    iff('2i · Humano?', '={{ $json.humano === true }}', 1320, 200)
    # Mari calada (humano/time/resolvida): a fala do cliente entra no histórico mesmo assim, sem resposta.
    rpc('2r · Supabase registrar calado', 'mari_registrar_turno',
        "={{ JSON.stringify({ p_telefone: $json.telefone, p_nome: $json.nome, p_texto: $json.texto, p_papel: 'lead', "
        "p_canal: $json.canal, p_chatwoot_conversation_id: $json.chatwootConversationId }) }}", 1540, 100)

    rpc('3a · Supabase entrada', 'mari_entrada',
        "={{ JSON.stringify({ p_telefone: $json.telefone, p_nome: $json.nome, p_texto: $json.texto, p_canal: $json.canal, "
        "p_origem: $json.origem, p_chatwoot_conversation_id: $json.chatwootConversationId }) }}", 1540, 300)
    iff('3b · Silêncio?', '={{ $json.silencio === true }}', 1760, 300)
    add('3w · Debounce 2s', 'n8n-nodes-base.wait', 1.1, {'amount': 2, 'unit': 'seconds'}, 1980, 400,
        webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, 'niogen/mari/3w')))
    rpc('3c · Supabase consolidar', 'mari_consolidar',
        f"={{{{ JSON.stringify({{ p_conversa: {E}.conversa_id, p_ts: {E}.ts }}) }}}}", 2200, 400)
    iff('3d · Ok?', "={{ $json.resultado === 'ok' }}", 2420, 400)
    iff('3h · Ocupado?', "={{ $json.resultado === 'ocupado' }}", 2640, 600)
    code('3e · Espera lock', 2860, 700)
    iff('3f · Esgotou?', '={{ $json.esgotado === true }}', 3080, 700)
    add('3g · Espera 1s', 'n8n-nodes-base.wait', 1.1, {'amount': 1, 'unit': 'seconds'}, 3300, 800,
        webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, 'niogen/mari/3g')))

    # ── contexto + conteúdo + motor ──
    code('4 · Preparar', 2640, 300)
    iff('4m · Só mídia?', '={{ $json.soMidia === true }}', 2860, 300)
    code('2c · Mídia', 3080, 100)
    rpc('4b · Supabase contexto', 'mari_contexto',
        "={{ JSON.stringify({ p_conversa: $json.conversa_id, p_cep: $json.p_cep, p_numero: $json.p_numero, "
        "p_complemento: $json.p_complemento, p_viacep: $json.p_viacep }) }}", 3080, 400)
    code('5a · Conteúdo Mari', 3300, 400)
    code('5b · Motor', 3520, 400)
    claude('6 · Claude', 3740, 400)
    code('7 · Extrair', 3960, 400)
    iff('7d · Corrigir?', '={{ $json.corrigir === true }}', 4180, 400)
    code('5c · Pedido de correção', 4400, 600)
    claude('6r · Claude (correção)', 4620, 600)
    code('7r · Extrair (correção)', 4840, 600)
    add('7b · Supabase pendentes', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'GET',
        'url': f"={SB}/rest/v1/mari_turnos?conversa_id=eq.{{{{ $json.conversaId }}}}&pendente=is.true&select=id",
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'options': {'timeout': 10000}}, 5060, 400, credentials=sb_cred, alwaysOutputData=True)
    code('7c · Anti-duplicata', 5280, 400)
    iff('7e · Abortar?', '={{ $json.abortar === true }}', 5500, 400)
    rpc('7f · Supabase abortar', 'mari_abortar',
        "={{ JSON.stringify({ p_conversa: $json.conversaId, p_turno_ids: $json.turnoIds }) }}", 5720, 600)

    # ── salvar + handoff + saída ──
    code('10 · Salvar turno', 5720, 300)
    rpc('10b · Supabase salvar turno', 'mari_salvar_turno', '={{ JSON.stringify($json.body) }}', 5940, 300)
    iff('8 · É handoff?', "={{ $('10 · Salvar turno').first().json.temHandoff === true }}", 6160, 300)
    rpc('9 · Handoff', 'mari_handoff',
        "={{ JSON.stringify({ p_conversa: $('10 · Salvar turno').first().json.r.conversaId, "
        "p_motivo: $('10 · Salvar turno').first().json.r.handoff.motivo, "
        "p_lead: $('10 · Salvar turno').first().json.r.handoff.lead }) }}", 6380, 200)
    code('11 · Saída', 6600, 300)
    iff('11m · Modo teste?', "={{ $json.modo !== 'chatwoot' }}", 6820, 300)
    add('12t · Responder (teste)', 'n8n-nodes-base.respondToWebhook', 1.1, {
        'respondWith': 'json', 'responseBody': '={{ JSON.stringify($json.saida) }}', 'options': {}}, 7040, 200)
    iff('11c · Tem resposta?', "={{ ($json.resposta || '').length > 0 }}", 7040, 400)
    add('12c · Chatwoot enviar', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST',
        'url': "=https://app.chatwoot.com/api/v1/accounts/{{ $json.config.CHATWOOT_NIO_ACCOUNT }}/conversations/{{ $json.chatwootConversationId }}/messages",
        'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth',
        'sendBody': True, 'specifyBody': 'json',
        'jsonBody': "={{ JSON.stringify({ content: $json.resposta, message_type: 'outgoing', private: false }) }}",
        'options': {'timeout': 15000}}, 7260, 400, credentials=cw_cred,
        notes='MODO CHATWOOT — envio pela API do Chatwoot (bolha na conversa). Credencial "Chatwoot Nio".')

    # ── erros ──
    add('E · Error Trigger', 'n8n-nodes-base.errorTrigger', 1, {}, 0, 1000)
    code('E1 · Log erro', 220, 1000)
    add('E2 · Supabase mari_erros', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{SB}/rest/v1/mari_erros',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
        'sendHeaders': True, 'headerParameters': {'parameters': [{'name': 'Prefer', 'value': 'return=minimal'}]},
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': '={{ JSON.stringify($json.erroPayload) }}',
        'options': {}}, 440, 1000, credentials=sb_cred)

    # conexões: (origem, saída, destino)
    ligações = [
        ('1 · Webhook Mari teste', 0, '2 · Entrada'),
        ('1c · Webhook Chatwoot', 0, '1r · OK Chatwoot'),
        ('1r · OK Chatwoot', 0, '2 · Entrada'),
        ('2 · Entrada', 0, '2e · Encerrar?'),
        ('2e · Encerrar?', 0, '11 · Saída'),
        ('2e · Encerrar?', 1, '2x · Fala humana?'),
        ('2x · Fala humana?', 0, '2y · Supabase registrar humano'),
        ('2x · Fala humana?', 1, '2m · Modo chatwoot?'),
        ('2m · Modo chatwoot?', 0, '2g · Chatwoot conversa'),
        ('2m · Modo chatwoot?', 1, '2h · Guard humano'),
        ('2g · Chatwoot conversa', 0, '2h · Guard humano'),
        ('2h · Guard humano', 0, '2i · Humano?'),
        ('2i · Humano?', 0, '2r · Supabase registrar calado'),
        ('2r · Supabase registrar calado', 0, '11 · Saída'),
        ('2i · Humano?', 1, '3a · Supabase entrada'),
        ('3a · Supabase entrada', 0, '3b · Silêncio?'),
        ('3b · Silêncio?', 0, '11 · Saída'),
        ('3b · Silêncio?', 1, '3w · Debounce 2s'),
        ('3w · Debounce 2s', 0, '3c · Supabase consolidar'),
        ('3c · Supabase consolidar', 0, '3d · Ok?'),
        ('3d · Ok?', 0, '4 · Preparar'),
        ('3d · Ok?', 1, '3h · Ocupado?'),
        ('3h · Ocupado?', 0, '3e · Espera lock'),
        ('3h · Ocupado?', 1, '11 · Saída'),
        ('3e · Espera lock', 0, '3f · Esgotou?'),
        ('3f · Esgotou?', 0, '11 · Saída'),
        ('3f · Esgotou?', 1, '3g · Espera 1s'),
        ('3g · Espera 1s', 0, '3c · Supabase consolidar'),
        ('4 · Preparar', 0, '4m · Só mídia?'),
        ('4m · Só mídia?', 0, '2c · Mídia'),
        ('4m · Só mídia?', 1, '4b · Supabase contexto'),
        ('2c · Mídia', 0, '10 · Salvar turno'),
        ('4b · Supabase contexto', 0, '5a · Conteúdo Mari'),
        ('5a · Conteúdo Mari', 0, '5b · Motor'),
        ('5b · Motor', 0, '6 · Claude'),
        ('6 · Claude', 0, '7 · Extrair'),
        ('7 · Extrair', 0, '7d · Corrigir?'),
        ('7d · Corrigir?', 0, '5c · Pedido de correção'),
        ('7d · Corrigir?', 1, '7b · Supabase pendentes'),
        ('5c · Pedido de correção', 0, '6r · Claude (correção)'),
        ('6r · Claude (correção)', 0, '7r · Extrair (correção)'),
        ('7r · Extrair (correção)', 0, '7b · Supabase pendentes'),
        ('7b · Supabase pendentes', 0, '7c · Anti-duplicata'),
        ('7c · Anti-duplicata', 0, '7e · Abortar?'),
        ('7e · Abortar?', 0, '7f · Supabase abortar'),
        ('7e · Abortar?', 1, '10 · Salvar turno'),
        ('7f · Supabase abortar', 0, '11 · Saída'),
        ('10 · Salvar turno', 0, '10b · Supabase salvar turno'),
        ('10b · Supabase salvar turno', 0, '8 · É handoff?'),
        ('8 · É handoff?', 0, '9 · Handoff'),
        ('8 · É handoff?', 1, '11 · Saída'),
        ('9 · Handoff', 0, '11 · Saída'),
        ('11 · Saída', 0, '11m · Modo teste?'),
        ('11m · Modo teste?', 0, '12t · Responder (teste)'),
        ('11m · Modo teste?', 1, '11c · Tem resposta?'),
        ('11c · Tem resposta?', 0, '12c · Chatwoot enviar'),
        ('E · Error Trigger', 0, 'E1 · Log erro'),
        ('E1 · Log erro', 0, 'E2 · Supabase mari_erros'),
    ]
    nomes = {n['name'] for n in nodes}
    conns = {}
    for o, i, d in ligações:
        assert o in nomes and d in nomes, (o, d)
        main = conns.setdefault(o, {'main': []})['main']
        while len(main) <= i:
            main.append([])
        main[i].append({'node': d, 'type': 'main', 'index': 0})

    settings = {'executionOrder': 'v1', 'saveDataErrorExecution': 'all', 'saveDataSuccessExecution': 'all',
                'saveManualExecutions': True, 'timezone': 'America/Sao_Paulo'}
    if ids.get('workflow_id'):
        settings['errorWorkflow'] = ids['workflow_id']
    return {'name': WF_NOME, 'nodes': nodes, 'connections': conns, 'settings': settings}


# ─────────────────────────────── comandos ───────────────────────────────

def checar_sem_segredo(wf):
    s = json.dumps(wf, ensure_ascii=False)
    for padrao in (r'sk-ant-', r'sb_secret_', r'eyJhbGciOi', r'service_role"\s*:\s*"ey'):
        if re.search(padrao, s):
            raise SystemExit(f'export contém algo com cara de segredo ({padrao}) — abortado.')
    if re.search(r'dharma', s, re.I):
        raise SystemExit('export contém "Dharma" — abortado.')
    if 'zfunugupwvktcggvicuk' in s or '159121' in s:
        raise SystemExit('export contém ID da Vero (Supabase/Chatwoot) — abortado.')


def salvar_export(wf):
    checar_sem_segredo(wf)
    with open(EXPORT, 'w', encoding='utf-8') as f:
        json.dump(wf, f, ensure_ascii=False, indent=2)
        f.write('\n')
    print(f'export: {os.path.relpath(EXPORT, REPO)} ({len(wf["nodes"])} nós)')


def achar_wf(ids):
    wid = ids.get('workflow_id')
    if not wid:
        raise SystemExit('workflow_id ausente em mari_ids.json — rode "criar" antes.')
    wf = api('GET', f'/workflows/{wid}')
    if wf.get('name') != WF_NOME:
        raise SystemExit(f'o ID {wid} não é o {WF_NOME} (é "{wf.get("name")}") — abortado, nada foi alterado.')
    return wf


def backup(wf):
    os.makedirs(BACKUP_DIR, exist_ok=True)
    stamp = datetime.datetime.now().strftime('%d%m%y_%H%M%S')
    p = os.path.join(BACKUP_DIR, f'mari_principal_{stamp}.json')
    with open(p, 'w', encoding='utf-8') as f:
        json.dump(wf, f, ensure_ascii=False, indent=2)
    print(f'backup: {os.path.relpath(p, REPO)}')


def put(wf_id, wf):
    corpo = {'name': wf['name'], 'nodes': wf['nodes'], 'connections': wf['connections'],
             'settings': {k: v for k, v in wf.get('settings', {}).items()
                          if k in ('executionOrder', 'saveDataErrorExecution', 'saveDataSuccessExecution',
                                   'saveManualExecutions', 'timezone', 'errorWorkflow', 'saveExecutionProgress',
                                   'executionTimeout', 'callerPolicy')}}
    return api('PUT', f'/workflows/{wf_id}', corpo)


def cmd_credenciais():
    ids = ler_ids()
    cred = ids.setdefault('credenciais', {})
    if not cred.get('supabase'):
        r = api('POST', '/credentials', {'name': CRED_SUPABASE, 'type': 'supabaseApi',
                                         'data': {'host': SB, 'serviceRole': 'COLE_AQUI'}})
        cred['supabase'] = r['id']
        print(f'criada: {CRED_SUPABASE} ({r["id"]}) — colar a service role no painel do n8n')
    if not cred.get('claude'):
        r = api('POST', '/credentials', {'name': CRED_CLAUDE, 'type': 'anthropicApi',
                                         'data': {'apiKey': 'COLE_AQUI', 'url': 'https://api.anthropic.com'}})
        cred['claude'] = r['id']
        print(f'criada: {CRED_CLAUDE} ({r["id"]}) — colar a CLAUDE_API_KEY_NIO no painel do n8n')
    if not cred.get('teste'):
        segredo = secrets.token_urlsafe(32)
        r = api('POST', '/credentials', {'name': CRED_TESTE, 'type': 'httpHeaderAuth',
                                         'data': {'name': HEADER_TESTE, 'value': segredo}})
        cred['teste'] = r['id']
        gravar_env_usuario('MARI_TESTE_SECRET', segredo)
        del segredo
        print(f'criada: {CRED_TESTE} ({r["id"]}) — header {HEADER_TESTE}; valor gravado só na variável de usuário MARI_TESTE_SECRET')
    gravar_ids(ids)


def cmd_criar():
    ids = ler_ids()
    if ids.get('workflow_id'):
        raise SystemExit(f'já existe workflow_id {ids["workflow_id"]} em mari_ids.json — use "codigo" ou "estrutura".')
    existentes = api('GET', '/workflows?limit=250').get('data', [])
    if any(w.get('name') == WF_NOME for w in existentes):
        raise SystemExit(f'já existe um workflow chamado {WF_NOME} no n8n — nada foi criado.')
    wf = build(ids)
    checar_sem_segredo(wf)
    r = api('POST', '/workflows', wf)
    ids['workflow_id'] = r['id']
    gravar_ids(ids)
    print(f'criado: {WF_NOME} ({r["id"]}), active={r.get("active")}')
    # errorWorkflow = o próprio (precisa do ID) — PUT no workflow recém-criado, com backup.
    atual = achar_wf(ids)
    backup(atual)
    wf2 = build(ids)
    put(r['id'], wf2)
    print('errorWorkflow apontado para o próprio mari_principal')
    salvar_export(build(ids))


def cmd_codigo(dry):
    ids = ler_ids()
    wf = achar_wf(ids)
    mudou = []
    for n in wf['nodes']:
        arq = CODE.get(n.get('name'))
        if arq and n.get('type') == 'n8n-nodes-base.code':
            novo = js(arq)
            if n['parameters'].get('jsCode') != novo:
                mudou.append(n['name'])
                n['parameters']['jsCode'] = novo
    if not mudou:
        print('nada a fazer — produção já está com este código')
        return
    print('nós com código novo:', ', '.join(mudou))
    if dry:
        print('(dry-run: nada gravado)')
        return
    backup(api('GET', f'/workflows/{ids["workflow_id"]}'))
    ativo = wf.get('active')
    put(ids['workflow_id'], wf)
    if ativo and not api('GET', f'/workflows/{ids["workflow_id"]}').get('active'):
        api('POST', f'/workflows/{ids["workflow_id"]}/activate')
    print('ok')
    cmd_exportar()


def cmd_estrutura():
    ids = ler_ids()
    atual = achar_wf(ids)
    backup(atual)
    ativo = atual.get('active')
    put(ids['workflow_id'], build(ids))
    if ativo and not api('GET', f'/workflows/{ids["workflow_id"]}').get('active'):
        api('POST', f'/workflows/{ids["workflow_id"]}/activate')
    print('ok')
    cmd_exportar()


def cmd_ativar(ligar):
    ids = ler_ids()
    achar_wf(ids)
    r = api('POST', f'/workflows/{ids["workflow_id"]}/{"activate" if ligar else "deactivate"}')
    print(f'{WF_NOME}: active={r.get("active")}')


def cmd_exportar():
    ids = ler_ids()
    wf = achar_wf(ids)
    limpo = {'name': wf['name'], 'nodes': wf['nodes'], 'connections': wf['connections'],
             'settings': wf.get('settings', {}),
             'staticData': {'_modoMari': (wf.get('staticData') or {}).get('global', {}).get('_modoMari', 'teste')}}
    salvar_export(limpo)


if __name__ == '__main__':
    if len(sys.argv) < 2:
        raise SystemExit(__doc__ or 'ver cabeçalho')
    c = sys.argv[1]
    if c == 'build':
        salvar_export(build(ler_ids()))
    elif c == 'credenciais':
        cmd_credenciais()
    elif c == 'criar':
        cmd_criar()
    elif c == 'codigo':
        cmd_codigo('--dry-run' in sys.argv)
    elif c == 'estrutura':
        cmd_estrutura()
    elif c == 'ativar':
        cmd_ativar(True)
    elif c == 'desativar':
        cmd_ativar(False)
    elif c == 'exportar':
        cmd_exportar()
    else:
        raise SystemExit(f'comando desconhecido: {c}')

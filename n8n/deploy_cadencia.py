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
#   python n8n/deploy_cadencia.py credencial     # confere a credencial "Chatwoot Nio — Mari bot" (Agent Bot, 09/11)
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
CRED_CHATWOOT = 'Chatwoot Nio — Mari bot'   # 09/11 (pendência 33): Agent Bot "Mari" — a cadência fala como ela

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


JS_CUTUCADA_PEDIDO = r"""
// 0142: pedido ao Claude para a Mari escrever a cutucada (só texto; o filtro fica no 4e).
const c = $('4 · Um por vez').first().json;
const ctx = $input.first().json || {};
const sistema = `Você é a Mari, vendedora da Nio Internet (fibra) no WhatsApp. O cliente parou de responder e você vai mandar uma
CUTUCADA para trazê-lo de volta — curta, simpática e persuasiva, como uma boa vendedora que quer muito fechar com ele.
Regras (todas obrigatórias):
- No máximo 2 frases e 180 caracteres. Português do Brasil, natural, sem formalidade. No máximo 1 emoji.
- Termine com UMA pergunta fácil de responder, que puxe o próximo passo do que FALTA (CEP, número, operadora, escolher o plano, nome/CPF, e-mail, forma de pagamento, conferir os dados).
- Use o primeiro nome do cliente se vier no contexto. Pode citar a cidade e o plano escolhido.
- Um argumento por vez, só do que é verdade: preço fixo até 2030; roteador Wi-Fi incluído; atendimento rápido por aqui; é rapidinho (1–2 minutos).
- NUNCA: desconto, brinde, promoção, "última chance", "só hoje", prazo ou data de instalação, valor em R$, "cobertura confirmada", asterisco, nome de empresa que não seja Nio.
- Não repita nenhuma cutucada já enviada (lista no contexto) nem comece igual a elas. Não peça desculpa por insistir.
- Cutucada 5 é a última da janela: leve, sem pressão (ex.: deixar o atendimento separado e perguntar se quer seguir).
Responda SÓ com o texto da mensagem, sem aspas.`;
const pedido = {
  model: 'claude-sonnet-5-5', max_tokens: 400,
  output_config: { effort: 'low' },
  system: sistema,
  messages: [{ role: 'user', content: 'Contexto da conversa (JSON):\n' + JSON.stringify(ctx) }],
};
return [{ json: { pedido } }];
"""

JS_CUTUCADA_LER = r"""
// 0142: filtro da cutucada escrita pela Mari. Reprovou (ou a API falhou) → texto de reserva do banco. Sai o candidato do
// "4 · Um por vez" com o texto final — o 5 · Montar envio segue igual.
const c = { ...$('4 · Um por vez').first().json };
const r = $input.first().json || {};
let ctx = {};
try { ctx = $('4b · Supabase contexto').first().json || {}; } catch (e) { ctx = {}; }
const blocos = Array.isArray(r.content) ? r.content.filter((x) => x && x.type === 'text') : [];
let t = blocos.map((x) => x.text || '').join(' ').replace(/\s+/g, ' ').trim().replace(/^["“']|["”']$/g, '');
const norm = (x) => String(x || '').toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '');
const n = norm(t);
const ja = (Array.isArray(ctx.cutucadas_ja_enviadas) ? ctx.cutucadas_ja_enviadas : []).map(norm);
const ruim = !t || t.length < 12 || t.length > 260 || !t.includes('?') || t.includes('*') || /r\$\s*\d/.test(n)
  || /descont|gratis|gratuit|promo|brinde|ultima chance|so hoje|somente hoje|amanha|instala(cao|r)? (hoje|amanha|em )|prazo|cobertura confirmada|garanto|garantimos|combo|pacote|dh\x61rma|2028/.test(n)
  || ja.some((x) => x && (x === n || x.slice(0, 25) === n.slice(0, 25)))
  || r.stop_reason === 'refusal' || !!r.error;
if (!ruim) c.texto = t;
c.cutucada_ia = !ruim;
return [{ json: c }];
"""


def build(ids):
    cred = ids.get('credenciais', {})
    sb_cred = {'supabaseApi': {'id': cred.get('supabase', ''), 'name': dm.CRED_SUPABASE}}
    te_cred = {'httpHeaderAuth': {'id': cred.get('teste', ''), 'name': dm.CRED_TESTE}}
    cw_cred = {'httpHeaderAuth': {'id': cred.get('chatwoot_bot', ''), 'name': CRED_CHATWOOT}}
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

    # 08/11 (abertura B2, 0070): a cada 5 min (era 10) — o lembrete L15 sai entre 15 e 20 min depois da abertura.
    add('1 · A cada 5 min', 'n8n-nodes-base.scheduleTrigger', 1.2,
        {'rule': {'interval': [{'field': 'minutes', 'minutesInterval': 5}]}}, 0, 0)
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
    # ── 0141/0142 (Ricardo, 12/11): a Mari ESCREVE cada cutucada da janela (F1–F5): curta, persuasiva, com o contexto da
    # conversa. Filtro de saída aqui; reprovou ou a API falhou → vai o texto de reserva do banco (mari_cadencia_texto).
    cl_cred = {'anthropicApi': {'id': cred.get('claude', ''), 'name': dm.CRED_CLAUDE}}
    iff('4a · Escrever cutucada?',
        "={{ $json.acao === 'texto' && ['L15','F1','F2','F3','F4','F5'].includes($json.proximo_passo) "
        "&& $('2 · Interruptor').first().json.modo === 'chatwoot' && !String($json.telefone || '').startsWith('5500000000') }}",
        1210, 120)
    rpc('4b · Supabase contexto', 'mari_cutucada_contexto',
        '={{ JSON.stringify({ p_conversa: $json.conversa_id, p_passo: $json.proximo_passo }) }}', 1430, 40,
        onError='continueRegularOutput', alwaysOutputData=True)
    add('4c · Montar pedido', 'n8n-nodes-base.code', 2, {'jsCode': JS_CUTUCADA_PEDIDO}, 1650, 40)
    add('4d · Claude', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': 'https://api.anthropic.com/v1/messages',
        'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'anthropicApi',
        'sendHeaders': True, 'headerParameters': {'parameters': [{'name': 'anthropic-version', 'value': '2023-06-01'}]},
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': '={{ JSON.stringify($json.pedido) }}',
        'options': {'timeout': 45000, 'response': {'response': {'neverError': True}}}}, 1870, 40, credentials=cl_cred,
        onError='continueRegularOutput', alwaysOutputData=True)
    add('4e · Ler cutucada', 'n8n-nodes-base.code', 2, {'jsCode': JS_CUTUCADA_LER}, 2090, 40)
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
        ('1 · A cada 5 min', 0, '2 · Interruptor'),
        ('1w · Admin cadência', 0, '2 · Interruptor'),
        ('2 · Interruptor', 0, '2a · Admin?'),
        ('2a · Admin?', 0, '2r · Responder admin'),
        ('2a · Admin?', 1, '3 · Supabase candidatos'),
        ('3 · Supabase candidatos', 0, '3b · Itens'),
        ('3b · Itens', 0, '4 · Um por vez'),
        ('4 · Um por vez', 1, '4a · Escrever cutucada?'),
        ('4a · Escrever cutucada?', 0, '4b · Supabase contexto'),
        ('4a · Escrever cutucada?', 1, '5 · Montar envio'),
        ('4b · Supabase contexto', 0, '4c · Montar pedido'),
        ('4c · Montar pedido', 0, '4d · Claude'),
        ('4d · Claude', 0, '4e · Ler cutucada'),
        ('4e · Ler cutucada', 0, '5 · Montar envio'),
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
    # 09/11: a cadência usa a credencial do Agent Bot "Mari" (criada junto com o bot, token só no n8n). Nada a criar aqui.
    cred = dm.ler_ids().get('credenciais', {})
    if cred.get('chatwoot_bot'):
        print(f'já existe: {CRED_CHATWOOT} ({cred["chatwoot_bot"]})')
    else:
        raise SystemExit(f'{CRED_CHATWOOT} ausente em mari_ids.json — criar o Agent Bot e a credencial antes (Diário 09/11).')


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

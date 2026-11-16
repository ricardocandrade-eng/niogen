#!/usr/bin/env python3
# NIOGEN | n8n/deploy_fila_vero_disparo.py | 16/11/2026 — Claude Code (docs/Prompt_fila_vero_disparo_v2_131126_1600.md, migration 0242)
# Workflow n8n "fila_vero_disparo" — duas linhas:
#   A) a cada 5 min: fila_vero_rodada(10) (saídas automáticas, auto-respostas, cota do dia espalhada, só com fila_vero_ativo e na
#      janela seg–sex 9–21 · sáb 10–16, nunca domingo/feriado) → envia pelo número do disparo (1124589070738034), 1 a cada 20 s →
#      fila_vero_resultado (registra envio/falha; código de política/limite pausa o disparo) → aviso ao Ricardo se pausou.
#   B) de hora em hora (:07): lê a qualidade do número na Graph → fila_vero_guarda (YELLOW/RED/fora do ar pausa; às 8h roda a
#      rampa, o A/B e a trava da faixa B) → aviso ao Ricardo se houver alerta.
# Aviso: template alerta_fila_vero (UTILITY, WABA Nio, pelo número da Mari) para config_regras.resumo_destino_whatsapp.
# Desligar o disparo sem mexer no n8n: tela Fila Vero › Pausar (fila_vero_ligar) ou config_regras.fila_vero_ativo = false.
# Credenciais (só nomes/IDs): "Supabase Nio (service role)", "WABA Nio (Nio_API)". Chave da API do n8n: N8N_API_KEY_NIO.
#
# Uso:  python n8n/deploy_fila_vero_disparo.py criar | estrutura | ativar | desativar | exportar | build
import datetime
import json
import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_mari as dm   # noqa: E402

AQUI = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(AQUI)
EXPORT = os.path.join(AQUI, 'fila_vero_disparo.json')
WF_NOME = 'fila_vero_disparo'
ID_KEY = 'fila_vero_disparo_workflow_id'
PHONE_FILA = '1124589070738034'
PHONE_MARI = '1342993658907403'
GRAPH = 'https://graph.facebook.com/v21.0'

MONTAR = r"""
// Um item por envio. Template: nome + lugar no corpo, código da linha no botão URL. Texto: auto-resposta com o link da Mari.
const r = $input.first().json || {};
return (r.itens || []).map((i) => {
  const corpo = i.tipo === 'texto'
    ? { messaging_product: 'whatsapp', to: i.telefone, type: 'text', text: { body: i.texto, preview_url: false } }
    : { messaging_product: 'whatsapp', to: i.telefone, type: 'template', template: { name: i.template, language: { code: 'pt_BR' },
        components: [ { type: 'body', parameters: i.params.map((t) => ({ type: 'text', text: String(t) })) },
                      { type: 'button', sub_type: 'url', index: '0', parameters: [ { type: 'text', text: i.codigo } ] } ] } };
  return { json: { id: i.id, tipo: i.tipo, template: i.template || null, corpo } };
});
"""

JUNTAR = r"""
// Junta a resposta da Meta de cada envio com o item que saiu (mesma ordem).
const enviados = $('A3 · Montar envios').all();
const itens = $input.all().map((it, k) => {
  const o = enviados[k] ? enviados[k].json : {};
  const j = it.json || {};
  const wamid = j.messages && j.messages[0] ? j.messages[0].id : null;
  const e = j.error || {};
  return { id: o.id, tipo: o.tipo, template: o.template, wamid,
           erro_codigo: wamid ? null : String(e.code || '?'),
           erro_msg: wamid ? null : String((e.error_data && e.error_data.details) || e.message || '').slice(0, 250) };
});
return [{ json: { itens } }];
"""

AVISO = ("={{ JSON.stringify({ messaging_product: 'whatsapp', to: $('{dest}').first().json[0] ? "
         "String($('{dest}').first().json[0].valor).replace(/\\D/g, '') : String($('{dest}').first().json.valor || '').replace(/\\D/g, ''), "
         "type: 'template', template: { name: 'alerta_fila_vero', language: { code: 'pt_BR' }, components: [{ type: 'body', "
         "parameters: [{ type: 'text', text: String($('{src}').first().json.alerta).slice(0, 200) }] }] } }) }}")


def build(ids):
    cred = ids.get('credenciais', {})
    sb_cred = {'supabaseApi': {'id': cred.get('supabase', ''), 'name': dm.CRED_SUPABASE}}
    wa_cred = {'httpHeaderAuth': {'id': cred.get('waba', ''), 'name': dm.CRED_WABA}}
    nodes = []

    def add(name, ntype, ver, params, x, y, **extra):
        n = {'parameters': params, 'name': name, 'type': ntype, 'typeVersion': ver, 'position': [x, y],
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/{WF_NOME}/{name}'))}
        n.update(extra)
        nodes.append(n)

    def rpc(name, fn, body, x, y, **extra):
        add(name, 'n8n-nodes-base.httpRequest', 4.2, {
            'method': 'POST', 'url': f'{dm.SB}/rest/v1/rpc/{fn}',
            'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
            'sendBody': True, 'specifyBody': 'json', 'jsonBody': body, 'options': {'timeout': 30000}},
            x, y, credentials=sb_cred, **extra)

    def destino(name, x, y):
        add(name, 'n8n-nodes-base.httpRequest', 4.2, {
            'method': 'GET', 'url': f'{dm.SB}/rest/v1/config_regras?chave=eq.resumo_destino_whatsapp&select=valor',
            'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
            'options': {'timeout': 20000}}, x, y, credentials=sb_cred)

    def aviso(name, dest, src, x, y):
        add(name, 'n8n-nodes-base.httpRequest', 4.2, {
            'method': 'POST', 'url': f'{GRAPH}/{PHONE_MARI}/messages',
            'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth',
            'sendBody': True, 'specifyBody': 'json', 'jsonBody': AVISO.replace('{dest}', dest).replace('{src}', src),
            'options': {'timeout': 20000}}, x, y, credentials=wa_cred, onError='continueRegularOutput',
            notes='Template alerta_fila_vero só para o Ricardo. Nunca para cliente.', notesInFlow=True)

    def se_alerta(name, x, y):
        add(name, 'n8n-nodes-base.if', 2, {'conditions': {
            'options': {'caseSensitive': True, 'leftValue': '', 'typeValidation': 'loose'},
            'conditions': [{'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'{WF_NOME}/{name}/c')),
                            'leftValue': '={{ $json.alerta }}', 'rightValue': '',
                            'operator': {'type': 'string', 'operation': 'notEmpty', 'singleValue': True}}],
            'combinator': 'and'}, 'options': {}}, x, y)

    # ---- linha A: rodada a cada 5 min
    add('A1 · A cada 5 min', 'n8n-nodes-base.scheduleTrigger', 1.2,
        {'rule': {'interval': [{'field': 'minutes', 'minutesInterval': 5}]}}, 0, 0)
    rpc('A2 · Supabase rodada', 'fila_vero_rodada', '={{ JSON.stringify({ p_max: 10 }) }}', 220, 0)
    add('A3 · Montar envios', 'n8n-nodes-base.code', 2, {'jsCode': MONTAR.strip()}, 440, 0)
    add('A4 · WABA enviar (1 a cada 20 s)', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{GRAPH}/{PHONE_FILA}/messages',
        'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth',
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': '={{ JSON.stringify($json.corpo) }}',
        'options': {'timeout': 30000, 'batching': {'batch': {'batchSize': 1, 'batchInterval': 20000}},
                    'response': {'response': {'neverError': True}}}}, 660, 0, credentials=wa_cred,
        onError='continueRegularOutput', notes='Número do disparo 2888-0150 — nunca o da Mari.', notesInFlow=True)
    add('A5 · Juntar resultados', 'n8n-nodes-base.code', 2, {'jsCode': JUNTAR.strip()}, 880, 0)
    rpc('A6 · Supabase resultado', 'fila_vero_resultado', '={{ JSON.stringify({ p_itens: $json.itens }) }}', 1100, 0)
    se_alerta('A7 · Pausou?', 1320, 0)
    destino('A8 · Destino do aviso', 1540, -80)
    aviso('A9 · Aviso ao Ricardo', 'A8 · Destino do aviso', 'A6 · Supabase resultado', 1760, -80)

    # ---- linha B: guarda de hora em hora
    add('B1 · De hora em hora', 'n8n-nodes-base.scheduleTrigger', 1.2,
        {'rule': {'interval': [{'field': 'cronExpression', 'expression': '7 * * * *'}]}}, 0, 320)
    add('B2 · Graph qualidade do número', 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'GET', 'url': f'{GRAPH}/{PHONE_FILA}?fields=quality_rating,status,messaging_limit_tier,'
                                'whatsapp_business_manager_messaging_limit,verified_name,name_status',
        'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth',
        'options': {'timeout': 20000}}, 220, 320, credentials=wa_cred, retryOnFail=True, maxTries=3, waitBetweenTries=5000)
    rpc('B3 · Supabase guarda', 'fila_vero_guarda', '={{ JSON.stringify({ p_leitura: $json }) }}', 440, 320)
    se_alerta('B4 · Alerta?', 660, 320)
    destino('B5 · Destino do aviso', 880, 240)
    aviso('B6 · Aviso ao Ricardo', 'B5 · Destino do aviso', 'B3 · Supabase guarda', 1100, 240)

    ligacoes = [('A1 · A cada 5 min', 'A2 · Supabase rodada'), ('A2 · Supabase rodada', 'A3 · Montar envios'),
                ('A3 · Montar envios', 'A4 · WABA enviar (1 a cada 20 s)'), ('A4 · WABA enviar (1 a cada 20 s)', 'A5 · Juntar resultados'),
                ('A5 · Juntar resultados', 'A6 · Supabase resultado'), ('A6 · Supabase resultado', 'A7 · Pausou?'),
                ('A8 · Destino do aviso', 'A9 · Aviso ao Ricardo'),
                ('B1 · De hora em hora', 'B2 · Graph qualidade do número'), ('B2 · Graph qualidade do número', 'B3 · Supabase guarda'),
                ('B3 · Supabase guarda', 'B4 · Alerta?'), ('B5 · Destino do aviso', 'B6 · Aviso ao Ricardo')]
    conns = {}
    for o, d in ligacoes:
        conns.setdefault(o, {'main': [[]]})['main'][0].append({'node': d, 'type': 'main', 'index': 0})
    conns['A7 · Pausou?'] = {'main': [[{'node': 'A8 · Destino do aviso', 'type': 'main', 'index': 0}], []]}
    conns['B4 · Alerta?'] = {'main': [[{'node': 'B5 · Destino do aviso', 'type': 'main', 'index': 0}], []]}
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


def achar(ids):
    wid = ids.get(ID_KEY)
    if not wid:
        raise SystemExit(f'{ID_KEY} ausente em mari_ids.json — rode "criar".')
    wf = dm.api('GET', f'/workflows/{wid}')
    if wf.get('name') != WF_NOME:
        raise SystemExit(f'o ID {wid} não é o {WF_NOME} — abortado.')
    return wf


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
    print(f'criado: {WF_NOME} ({r["id"]}), inativo')
    cmd_exportar()


def cmd_estrutura():
    ids = dm.ler_ids()
    atual = achar(ids)
    os.makedirs(dm.BACKUP_DIR, exist_ok=True)
    p = os.path.join(dm.BACKUP_DIR, f'{WF_NOME}_{datetime.datetime.now():%d%m%y_%H%M%S}.json')
    with open(p, 'w', encoding='utf-8') as f:
        json.dump(atual, f, ensure_ascii=False, indent=2)
    print(f'backup: {os.path.relpath(p, REPO)}')
    dm.put(ids[ID_KEY], build(ids))
    cmd_exportar()


def cmd_ativar(ligar=True):
    ids = dm.ler_ids()
    achar(ids)
    r = dm.api('POST', f'/workflows/{ids[ID_KEY]}/{"activate" if ligar else "deactivate"}')
    print(f'{WF_NOME}: active={r.get("active")}')
    cmd_exportar()


def cmd_exportar():
    wf = achar(dm.ler_ids())
    salvar(wf)


if __name__ == '__main__':
    cmds = {'build': lambda: salvar(build(dm.ler_ids())), 'criar': cmd_criar, 'estrutura': cmd_estrutura,
            'ativar': cmd_ativar, 'desativar': lambda: cmd_ativar(False), 'exportar': cmd_exportar}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds:
        raise SystemExit('uso: ' + ' | '.join(cmds))
    cmds[sys.argv[1]]()

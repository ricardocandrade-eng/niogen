#!/usr/bin/env python3
# NIOGEN | n8n/deploy_indicacao.py | 13/11/2026 — Claude Code (Fable 5.2) · migration 0176_pos_instalacao_indicacao
# Workflow n8n "indicacao_rotina": a cada 10 min chama indicacao_tick() no Supabase Nio. O banco faz o que depende de hora
# (mensagem de pós-instalação, 2ª insistência, pedido da chave Pix — tudo pela fila chatwoot_acoes, que o backoffice_chatwoot
# executa) e devolve os INDICADOS A ABRIR: gente que nunca falou com a gente e ainda não tem conversa no Chatwoot.
# Para cada um: procura o contato pelo telefone → cria se não existe → cria a conversa na caixa da WABA Nio → devolve o id
# da conversa a indicacao_abertura_resultado, que cria o lead (origem "indicação") e enfileira o template nio_indicacao_contato.
# Aqui NÃO sai mensagem nenhuma: quem fala é a fila, como Mari (Agent Bot). Contato e conversa são criados com a credencial
# "Chatwoot Nio" (token de usuário; o bot não cria contato).
# Desligar sem mexer no n8n: config_regras.indicacao → "ligado": false (a rotina volta vazia) · "abrir_conversa": false (só
# não fala com o indicado; a indicação fica "recebida" na tela Pagamentos).
#
# Uso:
#   python n8n/deploy_indicacao.py build | criar | estrutura | ativar | desativar | exportar

import datetime
import json
import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_mari as dm   # noqa: E402

AQUI = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(AQUI)
EXPORT = os.path.join(AQUI, 'indicacao_rotina.json')
WF_NOME = 'indicacao_rotina'
ID_KEY = 'indicacao_rotina_workflow_id'

ACHOU = r"""// 4 · Achou o contato? — o Chatwoot busca por texto; confere pelos 8 últimos dígitos (com ou sem o 9).
const t = $('2 · Supabase rotina').item.json;
const fim = String(t.telefone || '').replace(/\D/g, '').slice(-8);
const lista = Array.isArray(($json || {}).payload) ? $json.payload : [];
const c = lista.find((p) => String(p.phone_number || '').replace(/\D/g, '').slice(-8) === fim);
return { json: { ...t, contact_id: c ? c.id : null } };
"""

CRIOU = r"""// 5m · Contato criado — a resposta traz payload.contact (ou payload direto, conforme a versão do Chatwoot).
const t = $('2 · Supabase rotina').item.json;
const p = ($json || {}).payload || {};
const id = (p.contact && p.contact.id) || p.id || null;
return { json: { ...t, contact_id: id, erroContato: id ? null : JSON.stringify($json.error || $json).slice(0, 300) } };
"""

RESULTADO = r"""// 7 · Resultado — ok = o Chatwoot devolveu o id da conversa nova.
const t = $('2 · Supabase rotina').item.json;
const id = ($json || {}).id || null;
const erro = id ? null : JSON.stringify(($json || {}).error || $json || {}).slice(0, 400);
return { json: { p_id: t.id, p_ok: !!id, p_chatwoot_conversation_id: id ? String(id) : null, p_erro: erro } };
"""


def build(ids):
    cred = ids.get('credenciais', {})
    if not cred.get('chatwoot'):
        raise SystemExit('credencial "Chatwoot Nio" ausente em mari_ids.json — nada gerado.')
    sb_cred = {'supabaseApi': {'id': cred.get('supabase', ''), 'name': dm.CRED_SUPABASE}}
    cw_usr = {'httpHeaderAuth': {'id': cred['chatwoot'], 'name': dm.CRED_CHATWOOT}}
    nodes = []

    def add(name, ntype, ver, params, x, y, **extra):
        n = {'parameters': params, 'name': name, 'type': ntype, 'typeVersion': ver, 'position': [x, y],
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/indicacao_rotina/{name}'))}
        n.update(extra)
        nodes.append(n)

    def rpc(name, fn, corpo, x, y):
        add(name, 'n8n-nodes-base.httpRequest', 4.2, {
            'method': 'POST', 'url': f'{dm.SB}/rest/v1/rpc/{fn}',
            'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
            'sendBody': True, 'specifyBody': 'json', 'jsonBody': corpo,
            'options': {'timeout': 20000}}, x, y, credentials=sb_cred, onError='continueRegularOutput')

    def cw(name, metodo, url, corpo, x, y, query=None):
        p = {'method': metodo, 'url': url, 'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth',
             'options': {'timeout': 15000}}
        if corpo:
            p.update({'sendBody': True, 'specifyBody': 'json', 'jsonBody': corpo})
        if query:
            p.update({'sendQuery': True, 'queryParameters': {'parameters': [{'name': k, 'value': v} for k, v in query.items()]}})
        add(name, 'n8n-nodes-base.httpRequest', 4.2, p, x, y, credentials=cw_usr, onError='continueRegularOutput')

    add('1 · A cada 10 min', 'n8n-nodes-base.scheduleTrigger', 1.2,
        {'rule': {'interval': [{'field': 'minutes', 'minutesInterval': 10}]}}, 0, 0)
    # Lista vazia = nenhum item = nada mais roda.
    rpc('2 · Supabase rotina', 'indicacao_tick', '={{ JSON.stringify({}) }}', 240, 0)
    cw('3 · Chatwoot buscar contato', 'GET', "={{ $json.base + '/contacts/search' }}", None, 480, 0,
       query={'q': '={{ $json.telefone }}'})
    add('4 · Achou o contato?', 'n8n-nodes-base.code', 2, {'mode': 'runOnceForEachItem', 'jsCode': ACHOU}, 720, 0)
    add('5 · Tem contato?', 'n8n-nodes-base.if', 2, {
        'conditions': {'options': {'caseSensitive': True, 'leftValue': '', 'typeValidation': 'strict'},
                       'conditions': [{'id': str(uuid.uuid5(uuid.NAMESPACE_URL, 'niogen/indicacao/tem')),
                                       'leftValue': '={{ !!$json.contact_id }}', 'rightValue': '',
                                       'operator': {'type': 'boolean', 'operation': 'true', 'singleValue': True}}],
                       'combinator': 'and'}, 'options': {}}, 960, 0)
    cw('5n · Chatwoot criar contato', 'POST', "={{ $json.base + '/contacts' }}",
       '={{ JSON.stringify({ inbox_id: $json.inbox_id, name: $json.nome, phone_number: $json.telefone }) }}', 1200, 160)
    add('5m · Contato criado', 'n8n-nodes-base.code', 2, {'mode': 'runOnceForEachItem', 'jsCode': CRIOU}, 1440, 160)
    cw('6 · Chatwoot criar conversa', 'POST', "={{ $json.base + '/conversations' }}",
       '={{ JSON.stringify({ inbox_id: $json.inbox_id, contact_id: $json.contact_id, status: "open" }) }}', 1680, 0)
    add('7 · Resultado', 'n8n-nodes-base.code', 2, {'mode': 'runOnceForEachItem', 'jsCode': RESULTADO}, 1920, 0)
    rpc('8 · Supabase resultado', 'indicacao_abertura_resultado', '={{ JSON.stringify($json) }}', 2160, 0)

    conns = {}

    def liga(o, d, saida=0):
        c = conns.setdefault(o, {'main': []})['main']
        while len(c) <= saida:
            c.append([])
        c[saida].append({'node': d, 'type': 'main', 'index': 0})

    liga('1 · A cada 10 min', '2 · Supabase rotina')
    liga('2 · Supabase rotina', '3 · Chatwoot buscar contato')
    liga('3 · Chatwoot buscar contato', '4 · Achou o contato?')
    liga('4 · Achou o contato?', '5 · Tem contato?')
    liga('5 · Tem contato?', '6 · Chatwoot criar conversa', 0)
    liga('5 · Tem contato?', '5n · Chatwoot criar contato', 1)
    liga('5n · Chatwoot criar contato', '5m · Contato criado')
    liga('5m · Contato criado', '6 · Chatwoot criar conversa')
    liga('6 · Chatwoot criar conversa', '7 · Resultado')
    liga('7 · Resultado', '8 · Supabase resultado')
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
    r = dm.api('POST', '/workflows', wf)   # a API cria sempre inativo
    ids = dm.ler_ids()                      # outra sessão pode ter gravado um id no meio
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
    dm.api('POST', f"/workflows/{ids[ID_KEY]}/{'activate' if ligar else 'deactivate'}")
    print('active:', dm.api('GET', f'/workflows/{ids[ID_KEY]}').get('active'))
    cmd_exportar()


def cmd_exportar():
    ids = dm.ler_ids()
    salvar(dm.api('GET', f'/workflows/{ids[ID_KEY]}'))


if __name__ == '__main__':
    acoes = {'build': cmd_build, 'criar': cmd_criar, 'estrutura': cmd_estrutura, 'ativar': cmd_ativar,
             'desativar': lambda: cmd_ativar(False), 'exportar': cmd_exportar}
    if len(sys.argv) < 2 or sys.argv[1] not in acoes:
        raise SystemExit('uso: build | criar | estrutura | ativar | desativar | exportar')
    acoes[sys.argv[1]]()

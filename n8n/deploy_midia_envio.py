#!/usr/bin/env python3
# NIOGEN | n8n/deploy_midia_envio.py | 12/11/2026 — Claude Code (docs/Prompt_mari_resposta_audio_121126_1800.md)
# Workflow n8n "mari_midia_envio": a Mari manda VOZ (OpenAI TTS → mensagem de voz do WhatsApp) ou IMAGEM (cartão do plano) a um
# cliente. Chamado pelo mari_principal (resposta em áudio) e pelo mari_cadencia (F2 imagem / F3 voz), com o header X-Mari-Secret.
#   voz:    TTS (credencial "Transcrição Nio", OGG/Opus) → bucket privado midia_conversas → upload na Graph API (/media) →
#           mensagem type audio com voice:true (confirmado em 12/11: chega como mensagem de voz).
#   imagem: Graph API type image com link (cartão já público do carrossel) e legenda.
#   depois: responde ao chamador (ok, wamid, caminho, erro) → grava em mari_midia_envios (mari_midia_registrar) → nota privada no
#           Chatwoot ("🔊 Mari mandou áudio…" / "🖼️ Mari mandou a imagem…"), para o time ver.
# Telefone de teste 5500000000xxx = simulado (gera a voz e sobe no bucket, não manda ao WhatsApp).
# Nada de segredo aqui: credenciais só por id/nome. Chave do n8n: N8N_API_KEY_NIO.
# Uso: python n8n/deploy_midia_envio.py build | criar | estrutura | ativar | exportar

import json
import os
import sys
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_mari as dm   # noqa: E402

AQUI = os.path.dirname(os.path.abspath(__file__))
WF_NOME = 'mari_midia_envio'
ID_KEY = 'midia_envio_workflow_id'
ROTA = 'mari-midia-envio'
EXPORT = os.path.join(AQUI, 'mari_midia_envio.json')
PNID = '1342993658907403'   # WABA Nio (INFRA §4)
CONTA_CW = '195428'

JS_PEDIDO = r"""
// Valida o pedido e monta o caminho no bucket. Telefone de teste (5500000000xxx) = simulado: não vai ao WhatsApp.
const b = $input.first().json.body || {};
const tel = String(b.telefone || '').replace(/\D/g, '');
const tipo = b.tipo === 'imagem' ? 'imagem' : 'voz';
const texto = String(b.texto || '').trim().slice(0, 1000);
const erro = !/^\d{12,13}$/.test(tel) ? 'telefone inválido' : !texto && tipo === 'voz' ? 'texto vazio' :
  tipo === 'imagem' && !/^https:\/\//.test(String(b.imagem_url || '')) ? 'imagem_url inválida' : null;
const pasta = String(b.chatwoot_conversa || b.conversa_id || 'sem-conversa').replace(/[^0-9A-Za-z_-]/g, '');
return [{ json: {
  tipo, telefone: tel, texto, erro,
  simular: tel.startsWith('5500000000') || b.simular === true,
  conversa_id: b.conversa_id || null, chatwoot_conversa: b.chatwoot_conversa ? String(b.chatwoot_conversa) : null,
  origem: ['resposta', 'cadencia', 'teste'].includes(b.origem) ? b.origem : 'resposta', passo: b.passo || null, ab: b.ab || null,
  imagem_url: b.imagem_url || null, plano: b.plano || null,
  voz: b.voz || 'marin', modelo: b.modelo || 'gpt-4o-mini-tts', instrucoes: b.instrucoes || '',
  caminho: `mari/${pasta}/mari_${Date.now()}.ogg`,
} }];
"""
JS_NOME = r"""
// O TTS devolve o arquivo sem nome: vira mari_<voz>.ogg / audio/ogg (o WhatsApp precisa do OGG/Opus para a mensagem de voz).
const it = $input.first();
const p = $('Pedido').first().json;
if (it.binary && it.binary.data) {
  it.binary.data.fileName = `mari_${p.voz}.ogg`; it.binary.data.mimeType = 'audio/ogg'; it.binary.data.fileExtension = 'ogg';
  return [{ json: { ...p, tts_ok: true }, binary: it.binary }];
}
return [{ json: { ...p, tts_ok: false, tts_erro: JSON.stringify(it.json && it.json.error || it.json || {}).slice(0, 200) } }];
"""
JS_REBINAR = r"""
// Depois de subir no bucket o item perde o arquivo: devolve o binário do TTS para o upload na Graph API.
const up = $input.first().json || {};
const n = $('Nome').first();
return [{ json: { ...n.json, bucket_ok: !!(up.Key || up.Id || up.key), bucket_erro: up.error ? String(up.error.message || up.error).slice(0, 200) : null },
          binary: n.binary }];
"""
JS_RESULTADO = r"""
// Junta o que aconteceu (só um dos caminhos rodou) e decide ok / erro / wamid.
const p = $('Pedido').first().json;
const run = (n) => { try { return $(n).isExecuted ? ($(n).first().json || {}) : null; } catch (e) { return null; } };
const errDe = (j) => j && j.error ? String(j.error.message || j.error.description || JSON.stringify(j.error)).slice(0, 300) : null;
let ok = false, wamid = null, erro = p.erro, caminho = null;
if (!erro && p.tipo === 'voz') {
  const nome = run('Nome') || {}, reb = run('Rebinar') || {}, up = run('Upload WA'), env = run('Enviar voz WA');
  if (!nome.tts_ok) erro = `voz não gerada: ${nome.tts_erro || 'sem resposta'}`;
  else {
    caminho = reb.bucket_ok ? p.caminho : null;
    if (p.simular) { ok = !!reb.bucket_ok; erro = ok ? null : `não subiu no bucket: ${reb.bucket_erro || '?'}`; }
    else if (!up || !up.id) erro = `upload no WhatsApp falhou: ${errDe(up) || 'sem id'}`;
    else if (!env || !env.messages || !env.messages[0]) erro = `envio da voz falhou: ${errDe(env) || 'sem id'}`;
    else { ok = true; wamid = env.messages[0].id; }
  }
} else if (!erro) {
  const env = run('Enviar imagem WA');
  if (p.simular) ok = true;
  else if (!env || !env.messages || !env.messages[0]) erro = `envio da imagem falhou: ${errDe(env) || 'sem id'}`;
  else { ok = true; wamid = env.messages[0].id; }
}
const curto = p.texto.length > 300 ? p.texto.slice(0, 300) + '…' : p.texto;
const nota = p.tipo === 'voz'
  ? `🔊 Mari mandou áudio${p.passo ? ` (${p.passo})` : ''}: «${curto}»`
  : `🖼️ Mari mandou a imagem${p.plano ? ` do ${p.plano}` : ''}${p.passo ? ` (${p.passo})` : ''}: «${curto}»`;
return [{ json: { ok, wamid, caminho, erro: ok ? null : erro, simulado: !!p.simular, tipo: p.tipo,
  registro: { conversa_id: p.conversa_id, origem: p.origem, passo: p.passo, tipo: p.tipo, texto: p.texto, caminho,
              imagem_url: p.tipo === 'imagem' ? p.imagem_url : null, ab: p.ab, ok, erro: ok ? null : erro, wamid },
  nota: ok && !p.simular && p.chatwoot_conversa ? nota : null, chatwoot_conversa: p.chatwoot_conversa } }];
"""


def build(ids):
    cred = ids['credenciais']
    sb = {'supabaseApi': {'id': cred['supabase'], 'name': dm.CRED_SUPABASE}}
    te = {'httpHeaderAuth': {'id': cred['teste'], 'name': dm.CRED_TESTE}}
    wa = {'httpHeaderAuth': {'id': cred['waba'], 'name': dm.CRED_WABA}}
    cw = {'httpHeaderAuth': {'id': cred['chatwoot_bot'], 'name': dm.CRED_CHATWOOT_BOT}}
    if not cred.get('transcricao'):
        raise SystemExit('credencial "Transcrição Nio" ausente em mari_ids.json')
    oa = {'openAiApi': {'id': cred['transcricao'], 'name': dm.CRED_TRANSCRICAO}}
    nodes = []

    def add(name, ntype, ver, params, x, y, **extra):
        n = {'parameters': params, 'name': name, 'type': ntype, 'typeVersion': ver, 'position': [x, y],
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/{WF_NOME}/{name}'))}
        n.update(extra)
        nodes.append(n)

    def code(name, js, x, y):
        add(name, 'n8n-nodes-base.code', 2, {'jsCode': js.strip()}, x, y)

    def iff(name, expr, x, y):
        add(name, 'n8n-nodes-base.if', 2, {'conditions': {
            'options': {'caseSensitive': True, 'leftValue': '', 'typeValidation': 'strict'},
            'conditions': [{'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'{WF_NOME}/{name}')), 'leftValue': expr, 'rightValue': '',
                            'operator': {'type': 'boolean', 'operation': 'true', 'singleValue': True}}], 'combinator': 'and'},
            'options': {}}, x, y)

    def http(name, x, y, params, credenciais, **extra):
        p = {'options': {'timeout': 60000}}
        p.update(params)
        add(name, 'n8n-nodes-base.httpRequest', 4.2, p, x, y, credentials=credenciais, onError='continueRegularOutput', **extra)

    add('Webhook', 'n8n-nodes-base.webhook', 2, {'httpMethod': 'POST', 'path': ROTA, 'authentication': 'headerAuth',
        'responseMode': 'responseNode', 'options': {}}, 0, 200, credentials=te,
        webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, f'niogen/{WF_NOME}/webhook')))
    code('Pedido', JS_PEDIDO, 220, 200)
    iff('Voz?', "={{ $json.tipo === 'voz' && !$json.erro }}", 440, 200)
    http('TTS', 660, 100, {'method': 'POST', 'url': 'https://api.openai.com/v1/audio/speech',
         'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'openAiApi', 'sendBody': True, 'specifyBody': 'json',
         'jsonBody': '={{ JSON.stringify({ model: $json.modelo, voice: $json.voz, input: $json.texto, instructions: $json.instrucoes || undefined, response_format: "opus" }) }}',
         'options': {'timeout': 60000, 'response': {'response': {'responseFormat': 'file', 'outputPropertyName': 'data'}}}}, oa)
    code('Nome', JS_NOME, 880, 100)
    http('Subir bucket', 1100, 100, {'method': 'POST',
         'url': f"={dm.SB}/storage/v1/object/midia_conversas/{{{{ $json.caminho }}}}",
         'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi',
         'sendHeaders': True, 'headerParameters': {'parameters': [{'name': 'x-upsert', 'value': 'true'}, {'name': 'Content-Type', 'value': 'audio/ogg'}]},
         'sendBody': True, 'contentType': 'binaryData', 'inputDataFieldName': 'data'}, sb)
    code('Rebinar', JS_REBINAR, 1320, 100)
    iff('Real voz?', '={{ !$json.simular && $json.tts_ok === true }}', 1540, 100)
    http('Upload WA', 1760, 0, {'method': 'POST', 'url': f'https://graph.facebook.com/v21.0/{PNID}/media',
         'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth', 'sendBody': True, 'contentType': 'multipart-form-data',
         'bodyParameters': {'parameters': [{'name': 'messaging_product', 'value': 'whatsapp'}, {'name': 'type', 'value': 'audio/ogg'},
                                           {'parameterType': 'formBinaryData', 'name': 'file', 'inputDataFieldName': 'data'}]}}, wa)
    http('Enviar voz WA', 1980, 0, {'method': 'POST', 'url': f'https://graph.facebook.com/v21.0/{PNID}/messages',
         'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth', 'sendBody': True, 'specifyBody': 'json',
         'jsonBody': "={{ JSON.stringify({ messaging_product: 'whatsapp', recipient_type: 'individual', to: $('Pedido').first().json.telefone, type: 'audio', audio: { id: $json.id, voice: true } }) }}"}, wa)
    iff('Real imagem?', "={{ !$json.erro && !$json.simular }}", 660, 300)
    http('Enviar imagem WA', 880, 300, {'method': 'POST', 'url': f'https://graph.facebook.com/v21.0/{PNID}/messages',
         'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth', 'sendBody': True, 'specifyBody': 'json',
         'jsonBody': "={{ JSON.stringify({ messaging_product: 'whatsapp', recipient_type: 'individual', to: $json.telefone, type: 'image', image: { link: $json.imagem_url, caption: $json.texto } }) }}"}, wa)
    code('Resultado', JS_RESULTADO, 2200, 200)
    add('Responder', 'n8n-nodes-base.respondToWebhook', 1.1, {'respondWith': 'json',
        'responseBody': '={{ JSON.stringify({ ok: $json.ok, wamid: $json.wamid, caminho: $json.caminho, erro: $json.erro, simulado: $json.simulado }) }}',
        'options': {}}, 2420, 200)
    http('Registrar', 2640, 200, {'method': 'POST', 'url': f'{dm.SB}/rest/v1/rpc/mari_midia_registrar',
         'authentication': 'predefinedCredentialType', 'nodeCredentialType': 'supabaseApi', 'sendBody': True, 'specifyBody': 'json',
         'jsonBody': "={{ JSON.stringify({ p: $('Resultado').first().json.registro }) }}"}, sb)
    iff('Nota?', "={{ !!$('Resultado').first().json.nota }}", 2860, 200)
    http('Nota Chatwoot', 3080, 100, {'method': 'POST',
         'url': f"=https://app.chatwoot.com/api/v1/accounts/{CONTA_CW}/conversations/{{{{ $('Resultado').first().json.chatwoot_conversa }}}}/messages",
         'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth', 'sendBody': True, 'specifyBody': 'json',
         'jsonBody': "={{ JSON.stringify({ content: $('Resultado').first().json.nota, message_type: 'outgoing', private: true }) }}"}, cw)

    lig = [('Webhook', 0, 'Pedido'), ('Pedido', 0, 'Voz?'), ('Voz?', 0, 'TTS'), ('Voz?', 1, 'Real imagem?'),
           ('TTS', 0, 'Nome'), ('Nome', 0, 'Subir bucket'), ('Subir bucket', 0, 'Rebinar'), ('Rebinar', 0, 'Real voz?'),
           ('Real voz?', 0, 'Upload WA'), ('Real voz?', 1, 'Resultado'), ('Upload WA', 0, 'Enviar voz WA'), ('Enviar voz WA', 0, 'Resultado'),
           ('Real imagem?', 0, 'Enviar imagem WA'), ('Real imagem?', 1, 'Resultado'), ('Enviar imagem WA', 0, 'Resultado'),
           ('Resultado', 0, 'Responder'), ('Responder', 0, 'Registrar'), ('Registrar', 0, 'Nota?'), ('Nota?', 0, 'Nota Chatwoot')]
    conns = {}
    for o, i, d in lig:
        m = conns.setdefault(o, {'main': []})['main']
        while len(m) <= i:
            m.append([])
        m[i].append({'node': d, 'type': 'main', 'index': 0})
    return {'name': WF_NOME, 'nodes': nodes, 'connections': conns,
            'settings': {'executionOrder': 'v1', 'saveDataErrorExecution': 'all', 'saveDataSuccessExecution': 'all', 'timezone': 'America/Sao_Paulo'}}


def salvar(wf):
    limpo = {k: wf[k] for k in ('name', 'nodes', 'connections', 'settings') if k in wf}
    dm.checar_sem_segredo(limpo)
    with open(EXPORT, 'w', encoding='utf-8') as f:
        json.dump(limpo, f, ensure_ascii=False, indent=2)
        f.write('\n')
    print(f'export: {os.path.relpath(EXPORT)} ({len(limpo["nodes"])} nós)')


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'build'
    ids = dm.ler_ids()
    if cmd == 'build':
        salvar(build(ids))
    elif cmd == 'criar':
        if ids.get(ID_KEY):
            raise SystemExit(f'já existe: {ids[ID_KEY]}')
        wf = build(ids)
        dm.checar_sem_segredo(wf)
        r = dm.api('POST', '/workflows', wf)
        ids[ID_KEY] = r['id']
        dm.gravar_ids(ids)
        print('criado', r['id'])
        salvar(wf)
    elif cmd == 'estrutura':
        atual = dm.api('GET', f'/workflows/{ids[ID_KEY]}')
        dm.WF_NOME = WF_NOME   # o backup sai com o nome deste workflow
        dm.backup(atual)
        wf = build(ids)
        dm.checar_sem_segredo(wf)
        dm.api('PUT', f'/workflows/{ids[ID_KEY]}', wf)
        print('ok')
        salvar(wf)
    elif cmd == 'ativar':
        dm.api('POST', f'/workflows/{ids[ID_KEY]}/activate')
        print('ativo')
    elif cmd == 'exportar':
        salvar(dm.api('GET', f'/workflows/{ids[ID_KEY]}'))
    else:
        raise SystemExit('uso: build | criar | estrutura | ativar | exportar')


if __name__ == '__main__':
    main()

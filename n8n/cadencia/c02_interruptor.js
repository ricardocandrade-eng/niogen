// NIOGEN | n8n/cadencia/c02_interruptor.js — nó "2 · Interruptor" do mari_cadencia (04/11/2026)
// Kill switch e modo da cadência (staticData). Padrão: DESLIGADA e em modo 'teste'.
//   _cadenciaAtiva  false | true      → false = a rodada para aqui (nada é lido nem enviado)
//   _modoCadencia   'teste' | 'chatwoot'
//       teste    → só conversas canal 'teste' (rota /webhook/mari-teste); envio SIMULADO (grava turno + toque)
//       chatwoot → só conversas canal 'whatsapp'; envio real pela API do Chatwoot (nós 6g/7 hoje desligados)
// Comandos pela rota admin (header X-Mari-Secret): ligar | desligar | modo teste | modo chatwoot | status
// Sem texto de negócio e sem segredo.

const sd = $getWorkflowStaticData('global');
if (sd._cadenciaAtiva === undefined) sd._cadenciaAtiva = false;
if (!sd._modoCadencia) sd._modoCadencia = 'teste';

const ex = (n) => { try { return $(n).isExecuted; } catch (e) { return false; } };
const estado = () => ({ ativa: sd._cadenciaAtiva, modo: sd._modoCadencia, ultima_rodada: sd._ultimaRodada || null });

if (ex('1w · Admin cadência')) {
  const body = $('1w · Admin cadência').first().json.body || {};
  const cmd = String(body.admin || '').toLowerCase().trim();
  if (cmd === 'ligar') sd._cadenciaAtiva = true;
  else if (cmd === 'desligar') sd._cadenciaAtiva = false;
  else if (cmd === 'modo teste' || cmd === 'modo chatwoot') sd._modoCadencia = cmd.split(' ')[1];
  else if (cmd !== 'status') return [{ json: { admin: true, resposta: { erro: 'use: ligar | desligar | modo teste | modo chatwoot | status' } } }];
  return [{ json: { admin: true, resposta: { admin: true, ...estado() } } }];
}

if (!sd._cadenciaAtiva) return [];   // kill switch: nada roda

sd._ultimaRodada = new Date().toISOString();
return [{ json: {
  admin: false,
  modo: sd._modoCadencia,
  canal: sd._modoCadencia === 'chatwoot' ? 'whatsapp' : 'teste',
  agora: sd._ultimaRodada,
  limite: 30,
} }];

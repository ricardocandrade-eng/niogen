// NIOGEN | supabase/functions/vigia-n8n/index.ts | 16/11/2026 12h40 — Claude Code (Opus 5.5) · migration 0230_vigia_n8n
// Vigia do n8n de FORA da VPS (queda de 16/11, ~10h45–12h16, VPS 45.32.161.130 sem pagamento: Mari, Live e Pulso pararam calados).
// Chamada a cada 2 min pelo pg_cron (job `vigia_n8n`). Lê o /healthz do n8n (config_regras.vigia_n8n.url), grava pela RPC
// vigia_n8n_registrar e, quando ela devolve um aviso (fora · lembrete · volta), manda direto pela API da Meta — sem n8n — o template
// UTILITY aprovado `alerta_mari_silencio` ao celular do Ricardo (config_regras.resumo_destino_whatsapp).
// Deploy com --no-verify-jwt: a função não recebe nem devolve dado; chamada a mais só faz mais uma leitura (o aviso sai na troca de
// estado, marcado na mesma transação). Segredo (Supabase › Edge Functions › Secrets): WABA_NIO_TOKEN. Phone id da Mari não é segredo.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const PHONE_ID = '1342993658907403';
const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const json = (c: unknown, s = 200) => new Response(JSON.stringify(c), { status: s, headers: { 'Content-Type': 'application/json' } });
// parâmetro de template: sem quebra de linha, tab ou 4+ espaços (regra da Meta)
const p = (s: unknown) => ({ type: 'text', text: String(s ?? '').replace(/\s+/g, ' ').trim().slice(0, 200) || '-' });

async function lerHealthz(url: string, timeoutMs: number) {
  const t0 = Date.now();
  const ctl = new AbortController();
  const tm = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const r = await fetch(url, { signal: ctl.signal });
    await r.body?.cancel();
    return { ok: r.status === 200, http: r.status, ms: Date.now() - t0, erro: r.status === 200 ? null : `HTTP ${r.status}` };
  } catch (e) {
    const erro = ctl.signal.aborted ? `sem resposta em ${Math.round(timeoutMs / 1000)} s` : String((e as Error)?.message || e);
    return { ok: false, http: null, ms: Date.now() - t0, erro };
  } finally {
    clearTimeout(tm);
  }
}

function textos(a: Record<string, unknown>) {
  if (a.acao === 'volta') return [a.minutos, 'n8n', 'n8n VOLTOU - conferir no Chatwoot as mensagens que chegaram na queda',
    `fora de ${a.desde} até ${a.ate}`];
  const tit = a.acao === 'lembrete' ? 'n8n AINDA FORA DO AR' : 'n8n FORA DO AR';
  return [a.minutos, 'n8n', `${tit} - Mari, cadência e Live parados (VPS 45.32.161.130)`, `healthz: ${a.erro ?? 'falhou'}`];
}

Deno.serve(async () => {
  const { data: cfgRow } = await sb.from('config_regras').select('valor').eq('chave', 'vigia_n8n').maybeSingle();
  const cfg = (cfgRow?.valor ?? {}) as Record<string, unknown>;
  if (cfg.ligado === false) return json({ ligado: false });
  const leitura = await lerHealthz(String(cfg.url || 'https://n8n.ofertasverointernet.com.br/healthz'), Number(cfg.timeout_ms) || 10000);

  const { data: a, error } = await sb.rpc('vigia_n8n_registrar',
    { p_ok: leitura.ok, p_http: leitura.http, p_ms: leitura.ms, p_erro: leitura.erro });
  if (error) return json({ leitura, erro: error.message }, 500);
  if (!a?.acao) return json({ leitura, acao: null });

  const token = Deno.env.get('WABA_NIO_TOKEN');
  const destino = String(a.destino || '').replace(/\D/g, '');
  let envio: string;
  if (!token || !destino) {
    envio = !token ? 'WABA_NIO_TOKEN ausente' : 'resumo_destino_whatsapp vazio';
  } else {
    const r = await fetch(`https://graph.facebook.com/v21.0/${PHONE_ID}/messages`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        messaging_product: 'whatsapp', to: destino, type: 'template',
        template: { name: 'alerta_mari_silencio', language: { code: 'pt_BR' },
          components: [{ type: 'body', parameters: textos(a).map(p) }] },
      }),
    });
    envio = r.ok ? 'ok' : `HTTP ${r.status} ${(await r.text()).slice(0, 300)}`;
  }
  if (envio !== 'ok') await sb.rpc('vigia_n8n_aviso_erro', { p_queda: a.queda_id, p_erro: envio });
  return json({ leitura, acao: a.acao, envio });
});

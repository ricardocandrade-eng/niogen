// NIOGEN | supabase/functions/dfv-consulta/index.ts | 11/11/2026 — Claude Code (docs/Prompt_operador_dfv_cobertura_111126_1520.md)
// Cobertura (DFV) ao vivo — CONSULTA-SÓ. Qualquer usuário logado do NIOGEN chama; nada é gravado.
// 1. confere que quem chama é usuário do NIOGEN (meu_perfil() com o JWT dele);
// 2. pergunta ao OPERADOR DFV na VPS (Chromium logado no painel "DFV Sudeste" da Nio) — server-to-server, com o
//    Bearer DFV_OP_TOKEN, que nunca chega ao navegador;
// 3. se o operador não responder em DFV_OP_TIMEOUT_MS (padrão 12 s) ou der erro, cai na RPC dfv_consultar (base congelada
//    de JF, nio_hp) com o JWT de quem chamou e devolve marcado { fonte: 'base_congelada' } — a tela nunca fica muda.
// Segredos (Supabase › Edge Functions › Secrets): DFV_OP_URL, DFV_OP_TOKEN. Nada no front, no repo ou no Drive.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const so = (s: unknown) => String(s ?? '').replace(/\D/g, '');

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Use POST.' }, 405);
  const t0 = Date.now();
  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
    // 12/11 (0131): o n8n mari_viabilidade chama com a service role (a chave do pedido segue adiante) — consulta-só, igual à tela.
    const chave = req.headers.get('apikey') || anon;
    const quem = createClient(url, chave, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
    const [{ data: perfil, error: ePerfil }, { data: servico }] = await Promise.all([quem.rpc('meu_perfil'), quem.rpc('sou_service_role')]);
    if (servico !== true && (ePerfil || !perfil)) return json({ error: 'Entre no NIOGEN para consultar.' }, 403);

    const b = await req.json().catch(() => ({}));
    const cep = so(b.cep);
    if (cep.length !== 8) return json({ error: 'Informe o CEP com 8 dígitos.' }, 400);
    const numero = String(b.numero ?? '').trim().slice(0, 20);
    const complemento = String(b.complemento ?? '').trim().slice(0, 60);
    const uf = String(b.uf ?? '').trim().toUpperCase().slice(0, 2);
    const municipio = String(b.municipio ?? '').trim().toUpperCase().slice(0, 80);
    if (b.forcar_base === true) return await congelada(quem, cep, numero, complemento, 'pedido da tela', t0);

    const opUrl = (Deno.env.get('DFV_OP_URL') ?? '').replace(/\/+$/, '');
    const opTok = Deno.env.get('DFV_OP_TOKEN') ?? '';
    const limite = Number(Deno.env.get('DFV_OP_TIMEOUT_MS') ?? '12000');
    if (!opUrl || !opTok) return await congelada(quem, cep, numero, complemento, 'operador não configurado', t0);

    const qs = new URLSearchParams({ cep, numero, complemento });
    if (uf) qs.set('uf', uf);
    if (municipio) qs.set('municipio', municipio);
    let motivo = '';
    try {
      const r = await fetch(`${opUrl}/dfv?${qs}`, {
        headers: { Authorization: `Bearer ${opTok}` }, signal: AbortSignal.timeout(limite),
      });
      const d = await r.json().catch(() => null);
      if (r.ok && d?.ok) {
        delete d.ok;
        return json({ ...d, ms_total: Date.now() - t0 });
      }
      motivo = r.ok && !d ? 'a rota do operador não respondeu como operador (proxy)'
        : `operador respondeu ${r.status}${d?.erro ? ` (${d.erro})` : ''}`;
    } catch (e) {
      motivo = (e as Error)?.name === 'TimeoutError' ? `operador sem resposta em ${Math.round(limite / 1000)} s` : 'operador fora do ar';
    }
    return await congelada(quem, cep, numero, complemento, motivo, t0);
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});

// Fallback: a mesma RPC de antes (nio_hp, foto de JF), com o JWT de quem chamou. Não grava nada.
// deno-lint-ignore no-explicit-any
async function congelada(quem: any, cep: string, numero: string, complemento: string, motivo: string, t0: number) {
  const { data, error } = await quem.rpc('dfv_consultar', { p_cep: cep, p_numero: numero, p_complemento: complemento || null });
  if (error) return json({ error: `Painel ao vivo indisponível (${motivo}) e base congelada com erro: ${error.message}` }, 502);
  const r = (data || [])[0] || null;
  return json({ fonte: 'base_congelada', motivo, particao: r?.particao ?? null, rpc: r, ms_total: Date.now() - t0 });
}

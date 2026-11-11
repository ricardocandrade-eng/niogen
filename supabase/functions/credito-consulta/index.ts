// NIOGEN | supabase/functions/credito-consulta/index.ts | 11/11/2026 — Claude Code (docs/Prompt_operador_credito_consulta_111126_1650.md)
// Consulta de crédito na Nio — CONSULTA-SÓ, ASSÍNCRONA. Só admin e backoffice (403 para os demais).
//   {acao: 'iniciar', cpf, endereco?, contato?, autorizado} → exige autorizado === true e CPF com dígito válido →
//        POST {CREDITO_OP_URL}/credito (X-Portal-Secret) → {job_id, posicao_fila, estado} (cache 24 h → já vem pronto)
//   {acao: 'status', job_id}                               → GET {CREDITO_OP_URL}/credito/{job_id}
// A consulta leva ~2 min no portal: a tela faz polling; esta função nunca segura a conexão aberta.
// Segredos (Supabase › Edge Functions › Secrets): CREDITO_OP_URL, NIO_PORTAL_SERVICO_SECRET. Nada no front nem no repo.
// Nada é gravado no Supabase nesta rodada. Log: usuário, ação, resultado, ms — nunca o CPF.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const so = (s: unknown) => String(s ?? '').replace(/\D/g, '');

function cpfValido(c: string) {
  if (c.length !== 11 || /^(\d)\1{10}$/.test(c)) return false;
  for (const n of [9, 10]) {
    let soma = 0;
    for (let i = 0; i < n; i++) soma += Number(c[i]) * (n + 1 - i);
    if (((soma * 10) % 11) % 10 !== Number(c[n])) return false;
  }
  return true;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Use POST.' }, 405);
  const t0 = Date.now();
  let usuario = '?';
  let acao = '?';
  const log = (resultado: string) => console.log(`credito-consulta · ${usuario} · ${acao} · ${resultado} · ${Date.now() - t0} ms`);
  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
    const quem = createClient(url, anon, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
    const [{ data: perfil, error: ePerfil }, { data: u }] = await Promise.all([quem.rpc('meu_perfil'), quem.auth.getUser()]);
    usuario = u?.user?.id?.slice(0, 8) ?? '?';
    if (ePerfil || !perfil) { log('403 sem login'); return json({ error: 'Entre no NIOGEN para consultar.' }, 403); }
    if (!['admin', 'backoffice'].includes(String(perfil))) { log(`403 perfil ${perfil}`); return json({ error: 'A consulta de crédito é só do backoffice.' }, 403); }

    const b = await req.json().catch(() => ({}));
    acao = String(b.acao ?? '');
    const opUrl = (Deno.env.get('CREDITO_OP_URL') ?? '').replace(/\/+$/, '');
    const segredo = Deno.env.get('NIO_PORTAL_SERVICO_SECRET') ?? '';
    if (!opUrl || !segredo) { log('503 nao_instalado'); return json({ error: 'Operador de crédito ainda não instalado.', nao_instalado: true }, 503); }
    const hdr = { 'X-Portal-Secret': segredo, 'Content-Type': 'application/json' };

    let r: Response;
    if (acao === 'iniciar') {
      if (b.autorizado !== true) { log('400 sem autorizacao'); return json({ error: 'Marque que o titular autorizou a consulta.' }, 400); }
      const cpf = so(b.cpf);
      if (!cpfValido(cpf)) { log('400 cpf invalido'); return json({ error: 'CPF inválido (confira os dígitos).' }, 400); }
      const corpo: Record<string, unknown> = { cpf, origem: `niogen:${perfil}` };
      const e = b.endereco ?? null;
      if (e && so(e.cep)) {
        if (so(e.cep).length !== 8) return json({ error: 'CEP do cliente com 8 dígitos.' }, 400);
        corpo.endereco = {
          cep: so(e.cep), numero: String(e.numero ?? '').trim().slice(0, 20),
          complemento: String(e.complemento ?? '').trim().slice(0, 60), referencia: String(e.referencia ?? '').trim().slice(0, 80),
        };
      }
      const c = b.contato ?? null;
      if (c && (so(c.celular) || String(c.email ?? '').trim())) {
        corpo.contato = { celular: so(c.celular), email: String(c.email ?? '').trim().slice(0, 120) };
      }
      r = await fetch(`${opUrl}/credito`, { method: 'POST', headers: hdr, body: JSON.stringify(corpo), signal: AbortSignal.timeout(15000) });
    } else if (acao === 'status') {
      const id = String(b.job_id ?? '');
      if (!/^[0-9a-f]{32}$/.test(id)) return json({ error: 'job inválido.' }, 400);
      r = await fetch(`${opUrl}/credito/${id}`, { headers: hdr, signal: AbortSignal.timeout(10000) });
    } else {
      return json({ error: 'acao deve ser iniciar ou status.' }, 400);
    }
    const d = await r.json().catch(() => null);
    if (!d) { log(`502 operador ${r.status} sem json`); return json({ error: `Operador respondeu ${r.status} sem JSON (rota do proxy?).` }, 502); }
    if (!r.ok || d.ok === false) {
      log(`${r.status} ${d.erro ?? ''}`);
      return json({ error: d.erro ?? `Operador respondeu ${r.status}.` }, r.status === 429 ? 429 : r.status === 400 ? 400 : 502);
    }
    delete d.ok;
    log(`${d.estado}${d.resultado ? ` ${d.resultado}` : ''}${d.cache ? ' cache' : ''}`);
    return json(d);
  } catch (e) {
    const m = (e as Error)?.name === 'TimeoutError' ? 'Operador de crédito sem resposta.' : 'Operador de crédito fora do ar.';
    log(`502 ${(e as Error)?.name}`);
    return json({ error: m }, 502);
  }
});

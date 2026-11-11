// NIOGEN | supabase/functions/parceiro-acesso/index.ts | 10/11/2026 — Claude Code (docs/Prompt_pocket_parceiro_101126_2025.md)
// Botão "Enviar acesso" da gaveta do parceiro (parceiros.html). Só o ADMIN logado chama.
// 1. confere que quem chama é admin (meu_perfil() com o JWT dele);
// 2. cria (uma vez) o login do Pocket do parceiro — e-mail técnico, nunca usado para enviar nada; app_metadata.tipo = 'parceiro'
//    (o trigger _usuario_novo não cria linha em `usuarios`, então o parceiro nunca enxerga o NIOGEN);
// 3. vincula parceiros.auth_user_id (RPC parceiro_vincular_login, só service role);
// 4. gera um magic link de uso único e devolve SÓ o token_hash. A tela monta o link do Pocket (…/parceiro/?acesso=<token>)
//    e abre o WhatsApp do Ricardo com a mensagem. O token vale pelo prazo do OTP do Supabase Auth (padrão 1 h) e uma vez só.
// A service role vem do ambiente da função (Supabase); nada de segredo no front, no repo ou no Drive.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Use POST.' }, 405);
  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
    const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

    const quem = createClient(url, anon, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
    const { data: perfil, error: ePerfil } = await quem.rpc('meu_perfil');
    if (ePerfil || perfil !== 'admin') return json({ error: 'Só o admin envia o acesso do parceiro.' }, 403);

    const { parceiro_id } = await req.json().catch(() => ({}));
    if (!parceiro_id || !/^[0-9a-f-]{36}$/i.test(parceiro_id)) return json({ error: 'Parceiro inválido.' }, 400);

    const adm = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: p, error: eP } = await adm.from('parceiros').select('id, nome, whatsapp, status, auth_user_id').eq('id', parceiro_id).maybeSingle();
    if (eP) return json({ error: eP.message }, 500);
    if (!p) return json({ error: 'Parceiro não encontrado.' }, 404);
    if (p.status !== 'ativo') return json({ error: 'Aprove o parceiro antes de enviar o acesso.' }, 400);

    let uid: string | null = p.auth_user_id;
    let email = `parceiro-${p.id}@parceiros.niogen.app`;
    if (uid) {
      const { data: u, error: eU } = await adm.auth.admin.getUserById(uid);
      if (eU || !u?.user) uid = null;
      else email = u.user.email ?? email;
    }
    if (!uid) {
      const { data: cu, error: eC } = await adm.auth.admin.createUser({
        email, email_confirm: true, app_metadata: { tipo: 'parceiro', parceiro_id: p.id }, user_metadata: { nome: p.nome },
      });
      if (eC || !cu?.user) return json({ error: `Não criou o login: ${eC?.message ?? 'erro'}` }, 500);
      uid = cu.user.id;
    }
    const { error: eV } = await adm.rpc('parceiro_vincular_login', { p_parceiro: p.id, p_auth: uid });
    if (eV) return json({ error: `Não vinculou o login: ${eV.message}` }, 500);

    const { data: lk, error: eL } = await adm.auth.admin.generateLink({ type: 'magiclink', email });
    if (eL || !lk?.properties?.hashed_token) return json({ error: `Não gerou o link: ${eL?.message ?? 'erro'}` }, 500);

    return json({ token_hash: lk.properties.hashed_token, whatsapp: p.whatsapp, nome: p.nome });
  } catch (e) {
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});

// NIOGEN | supabase/functions/nfse-emitir/index.ts | 23/11/2026 — Claude Code (Opus 5.5)
// Botão "Emitir NF" da Conciliação (0374). Ricardo, 23/11: "Um clique" e "Teste primeiro". SÓ ADMIN.
//   {acao: 'previa', documento, item}  → o que vai sair: ambiente (config_regras.nfse), nº da DPS que vai ser reservado, tomador,
//                                         descrição, valor, e-mail (para, cópias, título) — o serviço monta a partir da config dele.
//   {acao: 'emitir', documento, item}  → nfse_emissao_pedir (reserva o nº, com o usuário como autor) → serviço /emitir (assina,
//                                         confere se a DPS já virou nota, envia à Sefin, gera o PDF, manda o e-mail) → guarda PDF e
//                                         XML no bucket privado nfse → nfse_emissao_resultado (em produção vira a NF do pedido).
//   {acao: 'reenviar', id}              → serviço /email com o PDF guardado → nfse_emissao_resultado (enviada | erro_email).
//   {acao: 'pdf', id}                   → link assinado (10 min) do PDF.
// Segredos (Supabase › Edge Functions › Secrets): NFSE_SERVICO_URL (https://n8n.ofertasverointernet.com.br/niogen-nfse),
// NFSE_SERVICO_TOKEN. Nada no front nem no repo. Log: usuário, ação, resultado, ms.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const b64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Use POST.' }, 405);
  const t0 = Date.now();
  let usuario = '?';
  let acao = '?';
  const log = (r: string) => console.log(`nfse-emitir · ${usuario} · ${acao} · ${r} · ${Date.now() - t0} ms`);
  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    const quem = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
    const adm = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const [{ data: perfil }, { data: u }] = await Promise.all([quem.rpc('meu_perfil'), quem.auth.getUser()]);
    usuario = u?.user?.id?.slice(0, 8) ?? '?';
    if (perfil !== 'admin') { log(`403 ${perfil}`); return json({ error: 'Só admin emite NF.' }, 403); }
    const b = await req.json().catch(() => ({}));
    acao = String(b.acao ?? '');
    const svc = (Deno.env.get('NFSE_SERVICO_URL') ?? '').replace(/\/+$/, '');
    const tok = Deno.env.get('NFSE_SERVICO_TOKEN') ?? '';
    if (!svc || !tok) { log('503 nao_instalado'); return json({ error: 'O serviço de NFS-e ainda não foi instalado.', nao_instalado: true }, 503); }
    const chamar = async (rota: string, corpo: unknown, ms = 30000) => {
      const r = await fetch(`${svc}${rota}`, { method: 'POST', headers: { Authorization: `Bearer ${tok}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(corpo), signal: AbortSignal.timeout(ms) });
      const j = await r.json().catch(() => ({ erro: `serviço respondeu ${r.status}` }));
      if (!r.ok) throw new Error(String(j.erro ?? `serviço respondeu ${r.status}`));
      return j;
    };
    const cfgNfse = async () => ((await adm.from('config_regras').select('valor').eq('chave', 'nfse').maybeSingle()).data?.valor ?? {}) as
      { ambiente?: string; serie?: number; proximo?: Record<string, number> };
    const pedido = async (doc: string, item: string) => {
      const { data } = await adm.from('nio_extrato_pedidos').select('ciclo, ciclo_nio, valor, documento_compras, item')
        .eq('documento_compras', doc).limit(5);
      return (data ?? []).find((p) => String(p.item ?? '10') === item) ?? null;
    };

    if (acao === 'previa') {
      const doc = String(b.documento ?? '').trim();
      const item = String(b.item ?? '10');
      const [cfg, p] = await Promise.all([cfgNfse(), pedido(doc, item)]);
      if (!p) return json({ error: 'Pedido não encontrado no extrato.' }, 404);
      const amb = cfg.ambiente ?? 'restrita';
      const { data: ult } = await adm.from('nfse_emissoes').select('numero').eq('ambiente', amb).eq('serie', cfg.serie ?? 1)
        .order('numero', { ascending: false }).limit(1);
      const numero = Math.max((ult?.[0]?.numero ?? 0) + 1, cfg.proximo?.[amb] ?? 1);
      const pv = await chamar('/previa', { ambiente: amb, documento: doc, item, valor: p.valor, ciclo_nio: p.ciclo_nio });
      log(`previa ${amb}`);
      return json({ ...pv, serie: cfg.serie ?? 1, numero, ciclo_nio: p.ciclo_nio, documento: doc, item });
    }

    if (acao === 'emitir') {
      const doc = String(b.documento ?? '').trim();
      const item = String(b.item ?? '10');
      const { data: res, error: e1 } = await quem.rpc('nfse_emissao_pedir', { p_documento: doc, p_item: item });
      if (e1) { log(`recusado ${e1.message}`); return json({ error: e1.message }, 409); }
      const em = res as { id: string; ambiente: string; serie: number; numero: number; valor: number; ciclo_nio: string; competencia: string };
      let r: Record<string, any>;
      try {
        r = await chamar('/emitir', { ambiente: em.ambiente, serie: em.serie, numero: em.numero, valor: em.valor, competencia: em.competencia,
          documento: doc, item, ciclo_nio: em.ciclo_nio }, 120000);
      } catch (e) {
        // sem resposta: NÃO marca nada (a nota pode ter saído). Fica "pedida"; a conferência cobra depois de 10 min e o próximo
        // clique deste pedido REUSA o mesmo nº da DPS (nfse_emissao_pedir) — o serviço acha a DPS já processada e não duplica.
        log(`servico sem resposta ${(e as Error).message}`);
        return json({ error: `O serviço de NFS-e não respondeu (${(e as Error).message}). Espere 10 minutos e clique de novo: o NIOGEN usa o mesmo número e não emite em dobro.` }, 502);
      }
      if (!r.emitida) {
        await adm.rpc('nfse_emissao_resultado', { p_id: em.id, p_dados: { situacao: 'erro_emissao', erro: r.erro ?? 'recusada' } });
        log(`recusada ${String(r.erro).slice(0, 80)}`);
        return json({ emitida: false, ambiente: em.ambiente, numero: em.numero, erro: r.erro }, 200);
      }
      const base = `${em.ambiente}/${r.chave}`;
      const [up1, up2] = await Promise.all([
        adm.storage.from('nfse').upload(`${base}.pdf`, b64(r.pdf_b64), { contentType: 'application/pdf', upsert: true }),
        adm.storage.from('nfse').upload(`${base}.xml`, b64(r.xml_b64), { contentType: 'application/xml', upsert: true }),
      ]);
      const mail = r.email ?? {};
      await adm.rpc('nfse_emissao_resultado', { p_id: em.id, p_dados: {
        situacao: mail.enviado ? 'enviada' : 'erro_email', chave: r.chave, n_nfse: r.n_nfse, emitida_em: r.dh_proc,
        email_para: mail.para ?? null, email_enviado_em: mail.enviado ? mail.em : null,
        pdf_path: up1.error ? null : `${base}.pdf`, xml_path: up2.error ? null : `${base}.xml`, erro: mail.enviado ? null : mail.erro } });
      const { data: link } = await adm.storage.from('nfse').createSignedUrl(`${base}.pdf`, 600);
      log(`emitida ${em.ambiente} ${em.numero} email=${!!mail.enviado}`);
      return json({ emitida: true, ambiente: em.ambiente, numero: em.numero, chave: r.chave, n_nfse: r.n_nfse, ja_existia: !!r.ja_existia,
        email: { enviado: !!mail.enviado, para: mail.para ?? null, erro: mail.erro ?? null }, pdf: link?.signedUrl ?? null });
    }

    if (acao === 'reenviar' || acao === 'pdf') {
      const { data: e } = await adm.from('nfse_emissoes').select('*').eq('id', String(b.id ?? '')).maybeSingle();
      if (!e || !e.chave) return json({ error: 'Emissão não encontrada.' }, 404);
      if (acao === 'pdf') {
        const { data: link } = await adm.storage.from('nfse').createSignedUrl(e.pdf_path ?? `${e.ambiente}/${e.chave}.pdf`, 600);
        return json({ pdf: link?.signedUrl ?? null });
      }
      const { data: p } = await adm.from('nio_extrato_pedidos').select('ciclo_nio').eq('documento_compras', e.documento_compras).limit(1);
      let r: Record<string, any>;
      try {
        r = await chamar('/email', { ambiente: e.ambiente, chave: e.chave, ciclo_nio: p?.[0]?.ciclo_nio }, 90000);
      } catch (err) {
        await adm.rpc('nfse_emissao_resultado', { p_id: e.id, p_dados: { situacao: 'erro_email', erro: (err as Error).message } });
        log(`reenvio falhou`);
        return json({ error: `E-mail não saiu: ${(err as Error).message}` }, 502);
      }
      await adm.rpc('nfse_emissao_resultado', { p_id: e.id, p_dados: { situacao: 'enviada', email_para: r.para, email_enviado_em: r.em } });
      log('reenviado');
      return json({ enviado: true, para: r.para });
    }
    return json({ error: 'Ação desconhecida.' }, 400);
  } catch (e) {
    log(`500 ${(e as Error).message}`);
    return json({ error: (e as Error).message }, 500);
  }
});

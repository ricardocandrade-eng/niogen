-- NIOGEN | supabase/migrations/0331_previa_do_anuncio.sql | 20/11/2026 — Claude Code / Opus 5.5
-- Prompt docs/Prompt_conversa_sem_chatwoot_171126_1620.md, item 1 ("Prévia do anúncio que o cliente clicou"). Ricardo, 20/11 ~2h:
-- "Pode fazer a Etapa C e em seguida o prompt 2, direto, sem parar".
-- O que muda:
--   1. meta_ads_anuncios ganha a arte e o texto do anúncio (arte_url, arte_miniatura, texto, titulo_ad, criativo_id, criativo_em).
--   2. meta_ads_gravar_criativos(p_anuncios): o nó novo "4b · Supabase criativos" do meta_ads_coleta (a cada 15 min, só leitura na
--      Meta) grava ali o creative de cada anúncio (image_url / thumbnail_url, body, title). As URLs da Meta expiram: a coleta renova.
--   3. v_mari_conversa_anuncio ganha essas colunas no fim: a conversa e a ficha mostram de que anúncio o cliente veio (miniatura,
--      nome, 1ª linha do texto) lendo do banco — nunca chamando a Meta na abertura (regra 19). Sem referral, nada aparece.
--   Plano e preço do anúncio NÃO são resolvidos (decisão de 19/11: os anúncios da C3 não são de um plano só e o preço muda por cidade).
-- Regra 20: sem estado, sem situação; consequência nenhuma; fonte única = a Meta (pela coleta); não precisa de conferência nova
-- (a tela Meta Ads já confere a coleta). Desempenho: +1 leitura na rodada paralela da conversa (já existente), sem rodada nova.

begin;

alter table public.meta_ads_anuncios
  add column if not exists arte_url text,
  add column if not exists arte_miniatura text,
  add column if not exists texto text,
  add column if not exists titulo_ad text,
  add column if not exists criativo_id text,
  add column if not exists criativo_em timestamptz;

create or replace function public.meta_ads_gravar_criativos(p_anuncios jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with a as (
    select r ->> 'id' as ad_id, r -> 'creative' as cr
      from jsonb_array_elements(case when jsonb_typeof(p_anuncios) = 'array' then p_anuncios else '[]'::jsonb end) r
     where r ? 'creative'
  )
  update public.meta_ads_anuncios m
     set criativo_id = a.cr ->> 'id',
         arte_url = coalesce(nullif(a.cr ->> 'image_url', ''), nullif(a.cr ->> 'thumbnail_url', ''), m.arte_url),
         arte_miniatura = coalesce(nullif(a.cr ->> 'thumbnail_url', ''), nullif(a.cr ->> 'image_url', ''), m.arte_miniatura),
         texto = coalesce(nullif(a.cr ->> 'body', ''), m.texto),
         titulo_ad = coalesce(nullif(a.cr ->> 'title', ''), m.titulo_ad),
         criativo_em = now()
    from a
   where m.ad_id = a.ad_id
     and (m.criativo_em is null or m.criativo_em < now() - interval '6 hours'
          or m.criativo_id is distinct from a.cr ->> 'id' or m.texto is distinct from coalesce(nullif(a.cr ->> 'body', ''), m.texto));
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'criativos', n);
end $$;
revoke all on function public.meta_ads_gravar_criativos(jsonb) from public, anon, authenticated;
grant execute on function public.meta_ads_gravar_criativos(jsonb) to service_role;

create or replace view public.v_mari_conversa_anuncio
with (security_invoker = true) as
SELECT c.id AS conversa_id,
    c.telefone,
    c.created_at,
    c.origem,
    c.cep,
    c.dentro_area,
    c.handoff_motivo,
    c.handoff_em,
    c.venda_id,
    r.ad_id,
    r.ctwa_clid,
    r.titulo,
    r.recebido_em AS referral_em,
    a.ad_nome,
    a.adset_id,
    a.adset_nome,
    a.campanha_id,
    a.campanha_nome,
    v.status AS venda_status,
    v.motivo_saida,
    v.biometria_status,
    a.arte_url,
    a.arte_miniatura,
    a.texto AS anuncio_texto,
    a.titulo_ad,
    r.source_url
   FROM mari_conversas c
     JOIN LATERAL ( SELECT r_1.parceiro_id,
            r_1.wamid,
            r_1.telefone,
            r_1.phone_number_id,
            r_1.ad_id,
            r_1.source_type,
            r_1.ctwa_clid,
            r_1.source_url,
            r_1.titulo,
            r_1.recebido_em,
            r_1.gravado_em
           FROM meta_referrals r_1
          WHERE r_1.telefone = c.telefone AND r_1.ad_id IS NOT NULL AND r_1.recebido_em >= (c.created_at - '00:10:00'::interval) AND r_1.recebido_em <= (c.created_at + '00:10:00'::interval) AND NOT (EXISTS ( SELECT 1
                   FROM mari_conversas c2
                  WHERE c2.telefone = c.telefone AND c2.created_at > c.created_at AND c2.created_at <= (r_1.recebido_em + '00:02:00'::interval)))
          ORDER BY r_1.recebido_em
         LIMIT 1) r ON true
     LEFT JOIN meta_ads_anuncios a ON a.ad_id = r.ad_id
     LEFT JOIN vendas v ON v.id = c.venda_id;

grant select on public.v_mari_conversa_anuncio to authenticated;

commit;

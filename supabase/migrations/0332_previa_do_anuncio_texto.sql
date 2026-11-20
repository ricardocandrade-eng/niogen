-- NIOGEN | supabase/migrations/0332_previa_do_anuncio_texto.sql | 20/11/2026 — Claude Code / Opus 5.5
-- Ajuste da 0331: os anúncios da C3 usam arte por posicionamento (asset_feed_spec) — o texto vem em asset_feed_spec.bodies[0].text
-- (ou object_story_spec.link_data.message), não em creative.body. meta_ads_gravar_criativos lê os três, nessa ordem de preferência.
-- Regra 20: igual à 0331 (sem estado). Aplicada --sem-portao (Ricardo, 20/11 ~2h30).
begin;
create or replace function public.meta_ads_gravar_criativos(p_anuncios jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with a as (
    select r ->> 'id' as ad_id, r -> 'creative' as cr,
           coalesce(nullif(r -> 'creative' ->> 'body', ''),
                    nullif(r -> 'creative' -> 'asset_feed_spec' -> 'bodies' -> 0 ->> 'text', ''),
                    nullif(r -> 'creative' -> 'object_story_spec' -> 'link_data' ->> 'message', '')) as corpo,
           coalesce(nullif(r -> 'creative' ->> 'title', ''),
                    nullif(r -> 'creative' -> 'asset_feed_spec' -> 'titles' -> 0 ->> 'text', ''),
                    nullif(r -> 'creative' -> 'object_story_spec' -> 'link_data' ->> 'name', '')) as tit
      from jsonb_array_elements(case when jsonb_typeof(p_anuncios) = 'array' then p_anuncios else '[]'::jsonb end) r
     where r ? 'creative'
  )
  update public.meta_ads_anuncios m
     set criativo_id = a.cr ->> 'id',
         arte_url = coalesce(nullif(a.cr ->> 'image_url', ''), nullif(a.cr ->> 'thumbnail_url', ''), m.arte_url),
         arte_miniatura = coalesce(nullif(a.cr ->> 'thumbnail_url', ''), nullif(a.cr ->> 'image_url', ''), m.arte_miniatura),
         texto = coalesce(a.corpo, m.texto),
         titulo_ad = coalesce(a.tit, m.titulo_ad),
         criativo_em = now()
    from a
   where m.ad_id = a.ad_id;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'criativos', n);
end $$;
revoke all on function public.meta_ads_gravar_criativos(jsonb) from public, anon, authenticated;
grant execute on function public.meta_ads_gravar_criativos(jsonb) to service_role;
commit;

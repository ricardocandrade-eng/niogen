-- NIOGEN | supabase/migrations/0056_meta_ads_conjuntos.sql | 07/11/2026 — Claude Code (bloco "Saúde da campanha")
-- Por quê: o alerta de posicionamento (0054) olha 7 dias de histórico; um posicionamento já TIRADO dos conjuntos seguia
-- aparecendo como problema ativo (Status do WhatsApp, 07/11: gasto do próprio dia antes da troca valer). Pelo gasto não dá
-- para saber o que está configurado — esta tabela guarda o `targeting` atual de cada conjunto, coletado pelo n8n.
--   meta_ads_conjuntos — 1 linha por conjunto da CA: nome, campanha, status efetivo e as plataformas/posições configuradas.
--   meta_ads_gravar_conjuntos(p_conjuntos) — upsert, só service role (workflow meta_ads_coleta).
-- `publisher_platforms` vazio = posicionamento automático (a Meta escolhe tudo). Só leitura para o front.

create table if not exists public.meta_ads_conjuntos (
  parceiro_id          text not null default 'dharma',
  adset_id             text primary key,
  adset_nome           text,
  campanha_id          text,
  campanha_nome        text,
  status_efetivo       text,
  publisher_platforms  text[] not null default '{}',   -- vazio = automático
  posicoes             jsonb,                           -- facebook_positions, instagram_positions, whatsapp_positions…
  atualizado_em        timestamptz not null default now()
);
comment on table public.meta_ads_conjuntos is
  'Conjuntos da CA com o posicionamento configurado agora (targeting). Gravado só pelo n8n (meta_ads_coleta). publisher_platforms vazio = automático. 0056.';

alter table public.meta_ads_conjuntos enable row level security;
drop policy if exists meta_ads_conjuntos_ler on public.meta_ads_conjuntos;
create policy meta_ads_conjuntos_ler on public.meta_ads_conjuntos
  for select to authenticated using (public.meu_perfil() is not null);
revoke all on public.meta_ads_conjuntos from anon;
grant select on public.meta_ads_conjuntos to authenticated;
grant all on public.meta_ads_conjuntos to service_role;

create or replace function public.meta_ads_gravar_conjuntos(p_conjuntos jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_n int := 0;
begin
  if jsonb_typeof(coalesce(p_conjuntos, '[]'::jsonb)) <> 'array' then
    raise exception 'p_conjuntos precisa ser array (o "data" da Graph API)' using errcode = '22023';
  end if;

  insert into public.meta_ads_conjuntos as c
    (adset_id, adset_nome, campanha_id, campanha_nome, status_efetivo, publisher_platforms, posicoes, atualizado_em)
  select r ->> 'id', r ->> 'name', r ->> 'campaign_id', r -> 'campaign' ->> 'name', r ->> 'effective_status',
         coalesce(array(select jsonb_array_elements_text(r -> 'targeting' -> 'publisher_platforms')), '{}'),
         (select jsonb_object_agg(k, v) from jsonb_each(coalesce(r -> 'targeting', '{}'::jsonb)) as t(k, v)
           where k like '%\_positions' escape '\' and k not like 'effective\_%' escape '\'),
         now()
    from jsonb_array_elements(coalesce(p_conjuntos, '[]'::jsonb)) r
   where r ->> 'id' is not null
  on conflict (adset_id) do update set
    adset_nome = excluded.adset_nome, campanha_id = excluded.campanha_id, campanha_nome = excluded.campanha_nome,
    status_efetivo = excluded.status_efetivo, publisher_platforms = excluded.publisher_platforms,
    posicoes = excluded.posicoes, atualizado_em = now();
  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'conjuntos', v_n, 'em', now());
end $$;

revoke execute on function public.meta_ads_gravar_conjuntos(jsonb) from public, anon, authenticated;
grant execute on function public.meta_ads_gravar_conjuntos(jsonb) to service_role;

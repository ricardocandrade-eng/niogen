-- NIOGEN | supabase/migrations/0057_meta_referral.sql | 07/11/2026 — Claude Code (pedido do Ricardo: "ad_id dos anúncios")
-- Por quê: o Chatwoot não guarda o `referral` da 1ª mensagem que vem de anúncio (conferido 07/11 nas conversas #3/#4), então
-- a Mari nunca soube de qual anúncio veio cada conversa — e os gatilhos R1 (CEP válido por anúncio) e R3 (venda por conjunto)
-- da tela Meta Ads ficavam "sem dado". Caminho escolhido (C): o app NIOGEN se inscreve na WABA Nio com o callback no n8n e
-- recebe uma CÓPIA do webhook; o Chatwoot continua recebendo pelo app Renata Digital, sem mudança (regra 5: override da WABA).
--   1. meta_referrals — 1 linha por mensagem com referral: telefone, ad_id (source_id), ctwa_clid, título/URL do anúncio.
--      NADA do texto da mensagem é guardado (só o necessário para atribuir).
--   2. meta_referral_gravar(p_value) — recebe o `value` cru do webhook (entry[].changes[].value) e grava os referrals.
--      Só service role (workflow n8n meta_referral_entrada). Idempotente pelo wamid.
--   3. v_mari_conversa_anuncio — cada conversa da Mari ↔ o anúncio que a abriu (referral do mesmo telefone até 10 min antes ou
--      depois de a conversa nascer — a mensagem do anúncio é a que abre a conversa), com conjunto/campanha pela meta_ads_anuncios e a venda dela.
-- Base para a API de Conversões (prompt 23): o ctwa_clid fica guardado aqui; nada é enviado à Meta por esta migration.

create table if not exists public.meta_referrals (
  parceiro_id      text not null default 'dharma',
  wamid            text primary key,                -- id da mensagem no WhatsApp (dedup das reentregas da Meta)
  telefone         text not null,                   -- só dígitos, como em mari_conversas.telefone
  phone_number_id  text,                            -- número que recebeu (Mari = 1342993658907403)
  ad_id            text,                            -- referral.source_id quando source_type = 'ad'
  source_type      text,                            -- 'ad' | 'post'
  ctwa_clid        text,                            -- id do clique (API de Conversões)
  source_url       text,
  titulo           text,                            -- referral.headline
  recebido_em      timestamptz not null,            -- timestamp da mensagem (Meta)
  gravado_em       timestamptz not null default now()
);
create index if not exists meta_referrals_tel_idx on public.meta_referrals (telefone, recebido_em);
create index if not exists meta_referrals_ad_idx on public.meta_referrals (ad_id);
comment on table public.meta_referrals is
  'Referral do anúncio (clique para WhatsApp) por mensagem, vindo da cópia do webhook da WABA Nio no app NIOGEN (n8n meta_referral_entrada). Sem texto da mensagem. 0057.';

alter table public.meta_referrals enable row level security;
drop policy if exists meta_referrals_ler on public.meta_referrals;
create policy meta_referrals_ler on public.meta_referrals
  for select to authenticated using (public.meu_perfil() = any (array['admin', 'backoffice']));
revoke all on public.meta_referrals from anon;
grant select on public.meta_referrals to authenticated;
grant all on public.meta_referrals to service_role;

create or replace function public.meta_referral_gravar(p_value jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_n int := 0;
  v_msgs int := 0;
begin
  if jsonb_typeof(coalesce(p_value, '{}'::jsonb)) <> 'object' then
    raise exception 'p_value precisa ser o objeto "value" do webhook' using errcode = '22023';
  end if;
  v_msgs := coalesce(jsonb_array_length(p_value -> 'messages'), 0);

  insert into public.meta_referrals
    (wamid, telefone, phone_number_id, ad_id, source_type, ctwa_clid, source_url, titulo, recebido_em)
  select m ->> 'id', regexp_replace(m ->> 'from', '\D', '', 'g'), p_value -> 'metadata' ->> 'phone_number_id',
         case when m -> 'referral' ->> 'source_type' = 'ad' then m -> 'referral' ->> 'source_id' end,
         m -> 'referral' ->> 'source_type', m -> 'referral' ->> 'ctwa_clid', m -> 'referral' ->> 'source_url',
         left(m -> 'referral' ->> 'headline', 200), to_timestamp((m ->> 'timestamp')::bigint)
    from jsonb_array_elements(coalesce(p_value -> 'messages', '[]'::jsonb)) m
   where m ? 'referral' and m ->> 'id' is not null and m ->> 'from' is not null and m ->> 'timestamp' ~ '^\d+$'
  on conflict (wamid) do nothing;
  get diagnostics v_n = row_count;

  return jsonb_build_object('ok', true, 'mensagens', v_msgs, 'referrals', v_n);
end $$;

revoke execute on function public.meta_referral_gravar(jsonb) from public, anon, authenticated;
grant execute on function public.meta_referral_gravar(jsonb) to service_role;

create or replace view public.v_mari_conversa_anuncio
with (security_invoker = true) as
select c.id as conversa_id, c.telefone, c.created_at, c.origem, c.cep, c.dentro_area, c.handoff_motivo, c.handoff_em, c.venda_id,
       r.ad_id, r.ctwa_clid, r.titulo, r.recebido_em as referral_em,
       a.ad_nome, a.adset_id, a.adset_nome, a.campanha_id, a.campanha_nome,
       v.status as venda_status, v.motivo_saida, v.biometria_status
  from public.mari_conversas c
  join lateral (
    select * from public.meta_referrals r
     where r.telefone = c.telefone and r.ad_id is not null
       and r.recebido_em between c.created_at - interval '10 minutes' and c.created_at + interval '10 minutes'
     order by r.recebido_em
     limit 1
  ) r on true
  left join public.meta_ads_anuncios a on a.ad_id = r.ad_id
  left join public.vendas v on v.id = c.venda_id;

comment on view public.v_mari_conversa_anuncio is
  'Conversa da Mari ↔ anúncio que a abriu (referral do mesmo telefone até 10 min antes ou depois de a conversa nascer — é a mensagem que a abre), com conjunto/campanha e a venda. Base dos gatilhos R1/R3 da tela Meta Ads. 0057.';
grant select on public.v_mari_conversa_anuncio to authenticated;

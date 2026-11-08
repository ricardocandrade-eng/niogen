-- NIOGEN | supabase/migrations/0067_meta_referral_uma_conversa.sql | 08/11/2026 — Claude Code (Ricardo: "Sim, corrija")
-- Por quê: na 1ª prova do ad_id (08/11 10h12, AD_C2R_H1_sobe) a v_mari_conversa_anuncio ligou o mesmo clique a DUAS conversas
-- do mesmo telefone: a nova (aberta pelo anúncio, origem meta_ads) e a anterior (o "oi" de 10h03, origem direto, zerada por
-- #zerar) — a regra da 0057 casa por telefone ±10 min da criação da conversa, sem impedir que um referral sirva a mais de uma.
-- Em teste com #zerar isso dobra a contagem por anúncio (R1/R3 da tela Meta Ads e o retrato do Agente de Tráfego).
-- Regra nova (mesma nos dois lugares): o referral segue valendo para a conversa nascida até 10 min antes ou depois dele, MAS
-- só para a mais recente do telefone que já existia quando a mensagem do anúncio chegou (tolerância de 2 min para a conversa
-- ser criada depois da mensagem). Se o cliente clica no anúncio dentro de uma conversa ainda aberta, ela continua ligada
-- (nenhuma conversa mais nova) — igual a antes.
--   1. v_mari_conversa_anuncio — recriada (mesmas colunas, mesma ordem).
--   2. _agente_trafego_base(p_dias) — recriada a partir da 0059 (conferida idêntica ao banco por md5 em 08/11), só o lateral muda.
-- Nada de tabela, permissão ou dado muda. parceiro_id: sem tabela nova (regra 15).

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
       and not exists (select 1 from public.mari_conversas c2
                        where c2.telefone = c.telefone and c2.created_at > c.created_at
                          and c2.created_at <= r.recebido_em + interval '2 minutes')
     order by r.recebido_em
     limit 1
  ) r on true
  left join public.meta_ads_anuncios a on a.ad_id = r.ad_id
  left join public.vendas v on v.id = c.venda_id;

comment on view public.v_mari_conversa_anuncio is
  'Conversa da Mari ↔ anúncio que a abriu (referral do mesmo telefone até 10 min antes ou depois de a conversa nascer, e só para a conversa mais recente do telefone quando o clique chegou — 0067), com conjunto/campanha e a venda. Base dos gatilhos R1/R3 da tela Meta Ads. 0057/0067.';
grant select on public.v_mari_conversa_anuncio to authenticated;

create or replace function public._agente_trafego_base(p_dias int default 14)
returns table (
  parceiro_id text, dia date, origem text,
  campanha_id text, campanha_nome text, conjunto_id text, conjunto_nome text, ad_id text, ad_nome text,
  cidade text, cluster text,
  respondeu boolean, cep_informado boolean, cep_valido_area boolean, fora_area boolean, ja_cliente_nio boolean,
  sem_cobertura boolean, qualificada boolean, pedido_aberto boolean, biometria_aprovada boolean, instalada boolean,
  saida text, plano text, forma_pagamento text
)
language sql stable security definer set search_path = public as $$
  with janela as (
    select ((now() at time zone 'America/Sao_Paulo')::date - (greatest(1, least(coalesce(p_dias, 14), 90)) - 1)) as de
  )
  select 'dharma'::text,
         (c.created_at at time zone 'America/Sao_Paulo')::date,
         case when r.ad_id is not null then 'meta_ads' else coalesce(nullif(c.origem, ''), 'direto') end,
         a.campanha_id, a.campanha_nome, a.adset_id, a.adset_nome, r.ad_id, a.ad_nome,
         coalesce(nullif(trim(c.cidade), ''), 'sem cidade'),
         coalesce(nullif(c.cluster, ''), 'sem cluster'),
         coalesce(t.lead_msgs, 0) >= 2,
         c.cep is not null,
         c.cep is not null and c.dentro_area is true,
         c.dentro_area is false or c.elegibilidade = 'fora_area',
         c.handoff_motivo = 'ja_cliente_nio' or c.elegibilidade = 'ja_cliente',
         v.motivo_saida = 'Sem cobertura' or c.nio_viab_resultado in ('sem_viabilidade', 'indisponivel')
           or v.nio_viab_resultado in ('sem_viabilidade', 'indisponivel'),
         c.handoff_motivo = 'dados_completos',
         v.nio_pedido is not null
           or v.status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme'),
         v.biometria_status = 'aprovada',
         v.instalado_em is not null or v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme'),
         case when v.status = 'saida' then coalesce(nullif(v.motivo_saida, ''), 'saída sem motivo')
              when c.handoff_motivo is not null and c.handoff_motivo <> 'dados_completos' then c.handoff_motivo
              when c.elegibilidade is not null and c.elegibilidade <> 'ok' then c.elegibilidade end,
         nullif(c.plano_escolhido, ''),
         nullif(c.forma_pagamento, '')
    from public.mari_conversas c
    cross join janela j
    left join lateral (
      select count(*)::int as lead_msgs from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead'
    ) t on true
    left join lateral (
      select r.ad_id from public.meta_referrals r
       where r.telefone = c.telefone and r.ad_id is not null
         and r.recebido_em between c.created_at - interval '10 minutes' and c.created_at + interval '10 minutes'
         -- 0067: o clique é de UMA conversa só — a mais recente do telefone já aberta quando a mensagem do anúncio chegou
         and not exists (select 1 from public.mari_conversas c2
                          where c2.telefone = c.telefone and c2.created_at > c.created_at
                            and c2.created_at <= r.recebido_em + interval '2 minutes')
       order by r.recebido_em
       limit 1
    ) r on true
    left join public.meta_ads_anuncios a on a.ad_id = r.ad_id
    left join public.vendas v on v.id = c.venda_id
   where c.canal = 'whatsapp'
     and (c.created_at at time zone 'America/Sao_Paulo')::date >= j.de
$$;
revoke execute on function public._agente_trafego_base(int) from public, anon, authenticated;
grant execute on function public._agente_trafego_base(int) to service_role;
comment on function public._agente_trafego_base(int) is
  'Uma linha por conversa da Mari (WhatsApp) nos últimos p_dias, com o anúncio que a abriu e os marcos do funil. Sem dado pessoal. Só service_role. 0059 (referral de uma conversa só: 0067).';

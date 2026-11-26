-- NIOGEN | supabase/migrations/0409_agencia_sem_placar.sql | 25/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 25/11: "Acho que ela não precisa ter acesso ao Placar". O Placar (resultado da empresa inteira: vendas do mês, meta,
-- conversas do dia, gasto da conta) fecha para o perfil agencia também no banco — a tela já saiu do menu dela (commit b01c99f).
--  (1) placar_agencia() e placar_conversas_dia(): só admin e backoffice (a agência recebe nulo / nada).
--  (2) painel_meta_ritmo(): sai a exceção da agência (0361); segue para quem tem perfil e para o serviço.
--  (3) config_metas: sai a policy da agência.
--  (4) meta_ads_dia(): para a agência é SEMPRE o recorte das campanhas liberadas (antes, sem parâmetro, era a conta inteira, que só
--      o Placar usava).
--  (5) agencia_leituras_indevidas(): config_metas e as funções do Placar saem da lista do que a agência pode ler.
--  (6) Ricardo, 25/11: para a agência, nada de "pausar"/"tirar" — só números de referência como alvo ("Ela tem a autonomia dela").
--      Duas chaves novas em config_meta_ads_regras, que a tela Meta Ads mostra a ela ao lado do número atual.
--  (Os Bairros prioritários ficam com a agência: Ricardo, 25/11, "pode deixar, mas coloque uma explicação sobre como ela deve usar".)
-- Regra 20: (1)–(3) nenhum estado novo, só leitura fechada · (4) fonte única preservada (as mesmas funções) · (5) a conferência
-- agencia_leitura continua acusando qualquer abertura nova.
begin;

-- (1)
create or replace function public.placar_agencia()
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare r jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then   -- 0409: a agência não vê mais o Placar
    return null;
  end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.n), '[]'::jsonb) into r from (
    select row_number() over (order by coalesce(v.nio_os_em, v.vendido_em, v.criado_em) desc, v.id)::int as n,
           v.status,
           public._dia_sp_txt(v.criado_em) as criado_em,
           public._dia_sp_txt(v.vendido_em) as vendido_em,
           public._dia_sp_txt(v.nio_os_em) as nio_os_em,
           public._dia_sp_txt(v.instalado_em) as instalado_em,
           public._dia_sp_txt(v.instalacao_agendada_para) as instalacao_agendada_para,
           public._dia_sp_txt(v.cancelada_apos_instalar_em) as cancelada_apos_instalar_em,
           v.origem, v.plano_id, v.plano_nome, p.nome_curto as plano_nome_curto, v.forma_pagamento, v.cidade,
           o.estado as os_estado, o.agendamento_data as os_agendamento_data
      from public.v_vendas v
      left join public.config_planos p on p.id = v.plano_id
      left join lateral (
        select oa.estado, oa.agendamento_data from public.v_os_andamento oa
         where oa.venda_id = v.id
         order by coalesce(public._so_digitos(v.nio_os) <> '' and public._so_digitos(oa.pedido) = public._so_digitos(v.nio_os), false) desc,
                  oa.mudou_em desc nulls last
         limit 1) o on true
     where v.nio_os is not null) x;
  return r;
end $fn$;

create or replace function public.placar_conversas_dia(p_desde date)
returns table (dia date, conversas integer, qualificadas integer)
language sql stable security definer set search_path = public as $fn$
  with c as (
    select created_at, handoff_motivo, handoff_em from public.mari_conversas
     where created_at >= (p_desde::timestamp at time zone 'America/Sao_Paulo')
       and coalesce((select public.meu_perfil()), '') in ('admin', 'backoffice')   -- 0409: sem a agência
  ), a as (
    select (created_at at time zone 'America/Sao_Paulo')::date as dia, count(*)::int as n from c group by 1
  ), q as (
    select (handoff_em at time zone 'America/Sao_Paulo')::date as dia, count(*)::int as n from c
     where handoff_motivo = 'dados_completos' and handoff_em is not null group by 1
  )
  select coalesce(a.dia, q.dia), coalesce(a.n, 0), coalesce(q.n, 0) from a full join q on q.dia = a.dia
$fn$;

-- (2) painel_meta_ritmo: tira só a exceção da agência, na versão que estiver no ar
do $$
declare d text := pg_get_functiondef('public.painel_meta_ritmo'::regproc);
  a text := 'public.meu_perfil() is null and not public.sou_agencia() then';
begin
  if position(a in d) = 0 then
    if position('sou_agencia' in d) = 0 then return; end if;
    raise exception '0409: painel_meta_ritmo mudou — refazer a porta a partir da versão no ar';
  end if;
  execute replace(d, a, 'public.meu_perfil() is null then   -- 0409: a agência não vê a meta do mês');
end $$;

-- (3)
drop policy if exists config_metas_agencia on public.config_metas;

-- (6)
insert into public.config_meta_ads_regras (parceiro_id, chave, valor, descricao) values
  ('dharma', 'agencia_ref_custo_conversa', 15, 'Referência mostrada à agência: custo por conversa (R$) até este valor. Mesmo número do "bom" (conversa_custo_meta). Ricardo, 25/11'),
  ('dharma', 'agencia_ref_custo_venda', 100, 'Referência mostrada à agência: custo por venda com OS (R$) até este valor. Alvo do Ricardo desde 13/11: R$ 80 a R$ 100')
on conflict (parceiro_id, chave) do nothing;

-- (4)
create or replace function public.meta_ads_dia(p_agencia boolean default false)
returns table (dia date, gasto numeric, impressoes integer, cliques integer, conversas_meta integer, conversas_mari integer,
               com_cep integer, fora_area integer, qualificadas integer, atualizado_em timestamptz)
language plpgsql stable security definer set search_path = public as $fn$
#variable_conflict use_column
begin
  if public.meu_perfil() is null and not public.sou_agencia() then return; end if;
  -- sem o recorte: o dia a dia da conta inteira (Placar e Meta Ads do time). A agência recebe SEMPRE o recorte (0409).
  if not ((coalesce(p_agencia, false) or public.sou_agencia()) and public._agencia_recorte(true)) then
    return query select d.dia, d.gasto, d.impressoes, d.cliques, d.conversas_meta, d.conversas_mari, d.com_cep, d.fora_area, d.qualificadas, d.atualizado_em
                   from public.v_meta_ads_dia d;
    return;
  end if;
  return query
  with camp as (select public.agencia_campanhas() as id),
  meta as (
    select m.dia, sum(m.gasto) as gasto, sum(m.impressoes)::int as impressoes, sum(m.cliques)::int as cliques,
           sum(m.conversas)::int as conversas_meta, max(m.atualizado_em) as atualizado_em
      from public.meta_ads_diario m where m.campanha_id in (select id from camp) group by m.dia
  ), mari as (
    select (c.created_at at time zone 'America/Sao_Paulo')::date as dia, count(*)::int as conversas_mari,
           count(*) filter (where c.cep is not null)::int as com_cep,
           count(*) filter (where c.elegibilidade = 'fora_area' or c.dentro_area is false)::int as fora_area,
           count(*) filter (where c.handoff_motivo = 'dados_completos')::int as qualificadas
      from public.mari_conversas c join public.v_mari_conversa_anuncio a on a.conversa_id = c.id
     where c.origem = 'meta_ads' and c.canal = 'whatsapp' and a.campanha_id in (select id from camp)
     group by 1
  )
  select coalesce(m.dia, x.dia), coalesce(m.gasto, 0), coalesce(m.impressoes, 0), coalesce(m.cliques, 0), coalesce(m.conversas_meta, 0),
         coalesce(x.conversas_mari, 0), coalesce(x.com_cep, 0), coalesce(x.fora_area, 0), coalesce(x.qualificadas, 0), m.atualizado_em
    from meta m full join mari x on x.dia = m.dia;
end $fn$;

-- (5) — por padrão de texto (a versão no ar tem linhas em branco a mais entre os itens da lista)
do $$
declare d text := pg_get_functiondef('public.agencia_leituras_indevidas()'::regprocedure);
begin
  if position($q$'config_metas', $q$ in d) = 0 and position($q$'placar_agencia'$q$ in d) = 0 then return; end if;   -- já feito
  if position($q$'config_meta_ads_regras', 'config_metas', 'config_area', 'dfv_bairros_pronto']$q$ in d) = 0
     or d !~ $q$'placar_conversas_dia',\s*'placar_agencia', 'tabela_agencia', 'painel_meta_ritmo', 'agencia_leituras_indevidas',$q$ then
    raise exception '0409: agencia_leituras_indevidas mudou — refazer as listas a partir da versão no ar';
  end if;
  d := replace(d, $q$'config_meta_ads_regras', 'config_metas', 'config_area', 'dfv_bairros_pronto']$q$,
                  $q$'config_meta_ads_regras', 'config_area', 'dfv_bairros_pronto']$q$);   -- config_metas saiu com o Placar
  d := regexp_replace(d, $q$'placar_conversas_dia',\s*'placar_agencia', 'tabela_agencia', 'painel_meta_ritmo', 'agencia_leituras_indevidas',$q$,
                      $q$'tabela_agencia', 'agencia_leituras_indevidas',$q$);   -- as funções do Placar saíram
  execute d;
end $$;

commit;

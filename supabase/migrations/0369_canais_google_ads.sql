-- NIOGEN | supabase/migrations/0369_canais_google_ads.sql | 23/11/2026 — Claude Code (Opus 5.5)
-- Prompt docs/Prompt_tela_canais_google_ads_231126_1620.md (Ricardo, 23/11 16h17: "Todos os canais de qualificação remotos precisam
-- estar dentro do CRM, para eu acompanhar se está no ar, o custo, o retorno, etc, assim como a tela Meta Ads").
-- O Google Ads ganha o mesmo molde do Meta, peça por peça. A coleta (n8n google_ads_coleta) nasce DESLIGADA até sair o developer token.
--  (1) google_ads_campanhas · google_ads_diario · google_ads_palavras · google_ads_conta — com parceiro_id (regra 15). Leitura: quem
--      tem perfil; a agência lê campanhas, dia e palavras (mesmo critério de meta_ads_diario), não a conta (saldo é cobrança nossa).
--      Escrita: só service_role, por google_ads_gravar (uma porta).
--  (2) google_ads_gravar(campanhas, diario, palavras, conta): o n8n manda já normalizado (micros → reais). Só grava o que mudou;
--      google_ads_conta.coletado_em é o batimento da coleta (sempre atualizado).
--  (3) v_google_ads_dia (security_invoker) + google_ads_dia() (definer, para a tela e a agência): custo × conversas da Mari × vendas (OS).
--  (4) v_canal_custo_dia: soma o Google coletado. No dia em que há coleta (Meta ou Google), o digitado à mão daquele canal naquele dia é
--      IGNORADO, não somado (regra 20.4). canal_custo_gravar recusa digitar custo do Google num dia que já veio da coleta.
--  (5) canais_resumo / v_canais_7d (card "Canais · 7 dias" do Painel): + status (no_ar · sem_entrega · fora_do_ar · nunca_subiu),
--      subiu_em, retorno (comissão prevista ÷ gasto; vazio sem gasto) e aba (config_canais.aba: a aba da tela Canais, quando existe).
--      Ordem: no ar em cima, maior retorno, menor custo por venda instalada.
--  (6) status_operacao(): + selo "google" (só aparece quando a coleta já rodou uma vez): conta parada ou pré-pago no fim = falha;
--      nada no ar, anúncio reprovado, pré-pago perto do fim, coleta parada há mais de 45 min = alerta. Fora do pulso_operacao (a Live
--      não muda).
--  (7) agencia_leituras_indevidas(): as tabelas e a função novas que a agência lê entram na lista conferida.
-- A conferência (item novo em conferencia_itens) vem na 0370, por cima da 0368 de outra sessão (mesma função).
-- Regra 20: (1) nada cria ou muda situação de lead — é medição de mídia · (2) escrita só por google_ads_gravar (service_role); a tela
-- só lê · (3) nenhum botão novo; o custo à mão continua em Configurações › Canais · (4) o gasto do Google tem UMA fonte por dia (coleta
-- quando houver, senão o digitado); a conversão do Google nunca cria lead · (5) conferência na 0370.
begin;

-- ───────────── (1) tabelas ─────────────
alter table public.config_canais add column if not exists aba text;
comment on column public.config_canais.aba is '0369: aba da tela Canais (metaads.html#<aba>) que detalha o canal. Nulo = só no card do Painel.';
update public.config_canais set aba = 'meta' where canal = 'meta_ads' and aba is distinct from 'meta';
update public.config_canais set aba = 'google' where canal = 'google_ads' and aba is distinct from 'google';
update public.config_canais set nota = 'LP dharmatelecom.com.br/nio-internet/ · botões terminam em (GADS)/(GADS-PJ) · custo da coleta (google_ads_diario); sem coleta, à mão em Configurações › Canais'
 where canal = 'google_ads';

create table if not exists public.google_ads_campanhas (
  parceiro_id        text not null default 'dharma',
  campanha_id        text primary key,
  conta_id           text,
  nome               text,
  status             text,            -- ENABLED · PAUSED · REMOVED
  status_veiculacao  text,            -- primary_status: ELIGIBLE · LIMITED · NOT_ELIGIBLE · PAUSED · ENDED · PENDING …
  motivos_status     text[] not null default '{}',
  tipo               text,            -- SEARCH · PERFORMANCE_MAX · DISPLAY …
  orcamento_diario   numeric(12,2),
  estrategia_lances  text,            -- MAXIMIZE_CLICKS · MANUAL_CPC · MAXIMIZE_CONVERSIONS …
  teto_cpc           numeric(12,2),
  atualizado_em      timestamptz not null default now()
);
create table if not exists public.google_ads_diario (
  parceiro_id                    text not null default 'dharma',
  dia                            date not null,
  campanha_id                    text not null,
  campanha_nome                  text,
  impressoes                     int not null default 0,
  cliques                        int not null default 0,
  custo                          numeric(12,2) not null default 0,
  conversoes                     numeric(12,2) not null default 0,
  parcela_impressoes             numeric(6,4),   -- search_impression_share (0–1)
  parcela_perdida_classificacao  numeric(6,4),   -- search_rank_lost_impression_share
  parcela_perdida_orcamento      numeric(6,4),   -- search_budget_lost_impression_share
  atualizado_em                  timestamptz not null default now(),
  primary key (dia, campanha_id)
);
create table if not exists public.google_ads_palavras (
  parceiro_id        text not null default 'dharma',
  grupo_id           text not null,
  criterio_id        text not null,
  campanha_id        text,
  grupo_nome         text,
  palavra            text,
  correspondencia    text,            -- EXACT · PHRASE · BROAD
  status             text,            -- ENABLED · PAUSED · REMOVED
  status_veiculacao  text,            -- system_serving_status: ELIGIBLE · RARELY_SERVED (não qualificada: baixo volume)
  aprovacao          text,            -- approval_status
  impressoes_7d      int not null default 0,
  cliques_7d         int not null default 0,
  custo_7d           numeric(12,2) not null default 0,
  conversoes_7d      numeric(12,2) not null default 0,
  atualizado_em      timestamptz not null default now(),
  primary key (grupo_id, criterio_id)
);
create table if not exists public.google_ads_conta (
  parceiro_id          text not null default 'dharma',
  conta_id             text primary key,   -- sem traços (7560120293)
  nome                 text,
  moeda                text,
  status               text,               -- ENABLED · SUSPENDED · CANCELED · CLOSED
  limite_aprovado      numeric(12,2),      -- account_budget (pré-pago / orçamento da conta)
  gasto_servido        numeric(12,2),
  saldo                numeric(12,2),      -- limite − servido (nulo sem orçamento de conta)
  anuncios_reprovados  int not null default 0,
  anuncios_limitados   int not null default 0,
  coletado_em          timestamptz not null default now()
);
create index if not exists google_ads_diario_dia on public.google_ads_diario (dia);

alter table public.google_ads_campanhas enable row level security;
alter table public.google_ads_diario    enable row level security;
alter table public.google_ads_palavras  enable row level security;
alter table public.google_ads_conta     enable row level security;

drop policy if exists google_ads_campanhas_ler on public.google_ads_campanhas;
create policy google_ads_campanhas_ler on public.google_ads_campanhas for select to authenticated using ((select public.meu_perfil()) is not null);
drop policy if exists google_ads_campanhas_agencia on public.google_ads_campanhas;
create policy google_ads_campanhas_agencia on public.google_ads_campanhas for select to authenticated using ((select public.sou_agencia()));
drop policy if exists google_ads_diario_ler on public.google_ads_diario;
create policy google_ads_diario_ler on public.google_ads_diario for select to authenticated using ((select public.meu_perfil()) is not null);
drop policy if exists google_ads_diario_agencia on public.google_ads_diario;
create policy google_ads_diario_agencia on public.google_ads_diario for select to authenticated using ((select public.sou_agencia()));
drop policy if exists google_ads_palavras_ler on public.google_ads_palavras;
create policy google_ads_palavras_ler on public.google_ads_palavras for select to authenticated using ((select public.meu_perfil()) is not null);
drop policy if exists google_ads_palavras_agencia on public.google_ads_palavras;
create policy google_ads_palavras_agencia on public.google_ads_palavras for select to authenticated using ((select public.sou_agencia()));
drop policy if exists google_ads_conta_ler on public.google_ads_conta;
create policy google_ads_conta_ler on public.google_ads_conta for select to authenticated using ((select public.meu_perfil()) is not null);

grant select on public.google_ads_campanhas, public.google_ads_diario, public.google_ads_palavras, public.google_ads_conta to authenticated;
grant all on public.google_ads_campanhas, public.google_ads_diario, public.google_ads_palavras, public.google_ads_conta to service_role;

-- ───────────── (2) a porta de escrita ─────────────
create or replace function public.google_ads_gravar(p_campanhas jsonb default '[]', p_diario jsonb default '[]',
                                                    p_palavras jsonb default '[]', p_conta jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_c int := 0; v_d int := 0; v_p int := 0; v_conta text;
begin
  if auth.role() is distinct from 'service_role' and session_user = 'authenticator' then
    raise exception 'google_ads_gravar: só a coleta (service role) grava' using errcode = '42501';
  end if;
  if jsonb_typeof(coalesce(p_campanhas, '[]')) <> 'array' or jsonb_typeof(coalesce(p_diario, '[]')) <> 'array'
     or jsonb_typeof(coalesce(p_palavras, '[]')) <> 'array' then
    raise exception 'p_campanhas, p_diario e p_palavras precisam ser arrays' using errcode = '22023';
  end if;

  insert into public.google_ads_campanhas as t (campanha_id, conta_id, nome, status, status_veiculacao, motivos_status, tipo,
                                                orcamento_diario, estrategia_lances, teto_cpc, atualizado_em)
  select r->>'id', r->>'conta_id', r->>'nome', r->>'status', r->>'status_veiculacao',
         coalesce(array(select jsonb_array_elements_text(case when jsonb_typeof(r->'motivos_status') = 'array' then r->'motivos_status' else '[]' end)), '{}'),
         r->>'tipo', (r->>'orcamento_diario')::numeric, r->>'estrategia_lances', (r->>'teto_cpc')::numeric, now()
    from jsonb_array_elements(coalesce(p_campanhas, '[]')) r where r->>'id' is not null
  on conflict (campanha_id) do update set
    conta_id = excluded.conta_id, nome = excluded.nome, status = excluded.status, status_veiculacao = excluded.status_veiculacao,
    motivos_status = excluded.motivos_status, tipo = excluded.tipo, orcamento_diario = excluded.orcamento_diario,
    estrategia_lances = excluded.estrategia_lances, teto_cpc = excluded.teto_cpc, atualizado_em = now()
  where (t.conta_id, t.nome, t.status, t.status_veiculacao, t.motivos_status, t.tipo, t.orcamento_diario, t.estrategia_lances, t.teto_cpc)
        is distinct from (excluded.conta_id, excluded.nome, excluded.status, excluded.status_veiculacao, excluded.motivos_status,
                          excluded.tipo, excluded.orcamento_diario, excluded.estrategia_lances, excluded.teto_cpc);
  get diagnostics v_c = row_count;

  insert into public.google_ads_diario as t (dia, campanha_id, campanha_nome, impressoes, cliques, custo, conversoes,
                                             parcela_impressoes, parcela_perdida_classificacao, parcela_perdida_orcamento, atualizado_em)
  select (r->>'dia')::date, r->>'campanha_id', r->>'campanha_nome', coalesce((r->>'impressoes')::int, 0), coalesce((r->>'cliques')::int, 0),
         round(coalesce((r->>'custo')::numeric, 0), 2), round(coalesce((r->>'conversoes')::numeric, 0), 2),
         (r->>'parcela_impressoes')::numeric, (r->>'parcela_perdida_classificacao')::numeric, (r->>'parcela_perdida_orcamento')::numeric, now()
    from jsonb_array_elements(coalesce(p_diario, '[]')) r where r->>'dia' is not null and r->>'campanha_id' is not null
  on conflict (dia, campanha_id) do update set
    campanha_nome = excluded.campanha_nome, impressoes = excluded.impressoes, cliques = excluded.cliques, custo = excluded.custo,
    conversoes = excluded.conversoes, parcela_impressoes = excluded.parcela_impressoes,
    parcela_perdida_classificacao = excluded.parcela_perdida_classificacao, parcela_perdida_orcamento = excluded.parcela_perdida_orcamento,
    atualizado_em = now()
  where (t.campanha_nome, t.impressoes, t.cliques, t.custo, t.conversoes, t.parcela_impressoes, t.parcela_perdida_classificacao, t.parcela_perdida_orcamento)
        is distinct from (excluded.campanha_nome, excluded.impressoes, excluded.cliques, excluded.custo, excluded.conversoes,
                          excluded.parcela_impressoes, excluded.parcela_perdida_classificacao, excluded.parcela_perdida_orcamento);
  get diagnostics v_d = row_count;

  insert into public.google_ads_palavras as t (grupo_id, criterio_id, campanha_id, grupo_nome, palavra, correspondencia, status,
                                               status_veiculacao, aprovacao, impressoes_7d, cliques_7d, custo_7d, conversoes_7d, atualizado_em)
  select r->>'grupo_id', r->>'criterio_id', r->>'campanha_id', r->>'grupo_nome', r->>'palavra', r->>'correspondencia', r->>'status',
         r->>'status_veiculacao', r->>'aprovacao', coalesce((r->>'impressoes_7d')::int, 0), coalesce((r->>'cliques_7d')::int, 0),
         round(coalesce((r->>'custo_7d')::numeric, 0), 2), round(coalesce((r->>'conversoes_7d')::numeric, 0), 2), now()
    from jsonb_array_elements(coalesce(p_palavras, '[]')) r where r->>'grupo_id' is not null and r->>'criterio_id' is not null
  on conflict (grupo_id, criterio_id) do update set
    campanha_id = excluded.campanha_id, grupo_nome = excluded.grupo_nome, palavra = excluded.palavra, correspondencia = excluded.correspondencia,
    status = excluded.status, status_veiculacao = excluded.status_veiculacao, aprovacao = excluded.aprovacao,
    impressoes_7d = excluded.impressoes_7d, cliques_7d = excluded.cliques_7d, custo_7d = excluded.custo_7d,
    conversoes_7d = excluded.conversoes_7d, atualizado_em = now()
  where (t.campanha_id, t.grupo_nome, t.palavra, t.correspondencia, t.status, t.status_veiculacao, t.aprovacao,
         t.impressoes_7d, t.cliques_7d, t.custo_7d, t.conversoes_7d)
        is distinct from (excluded.campanha_id, excluded.grupo_nome, excluded.palavra, excluded.correspondencia, excluded.status,
                          excluded.status_veiculacao, excluded.aprovacao, excluded.impressoes_7d, excluded.cliques_7d,
                          excluded.custo_7d, excluded.conversoes_7d);
  get diagnostics v_p = row_count;

  -- a conta: sempre grava (o coletado_em é o batimento que o selo e a conferência leem)
  if jsonb_typeof(p_conta) = 'object' and coalesce(p_conta->>'id', '') <> '' then
    v_conta := regexp_replace(p_conta->>'id', '\D', '', 'g');
    insert into public.google_ads_conta (conta_id, nome, moeda, status, limite_aprovado, gasto_servido, saldo,
                                         anuncios_reprovados, anuncios_limitados, coletado_em)
    values (v_conta, p_conta->>'nome', p_conta->>'moeda', p_conta->>'status',
            round((p_conta->>'limite_aprovado')::numeric, 2), round((p_conta->>'gasto_servido')::numeric, 2),
            round((p_conta->>'limite_aprovado')::numeric - coalesce((p_conta->>'gasto_servido')::numeric, 0), 2),
            coalesce((p_conta->>'anuncios_reprovados')::int, 0), coalesce((p_conta->>'anuncios_limitados')::int, 0), now())
    on conflict (conta_id) do update set
      nome = excluded.nome, moeda = excluded.moeda, status = excluded.status, limite_aprovado = excluded.limite_aprovado,
      gasto_servido = excluded.gasto_servido, saldo = excluded.saldo, anuncios_reprovados = excluded.anuncios_reprovados,
      anuncios_limitados = excluded.anuncios_limitados, coletado_em = now();
  end if;

  return jsonb_build_object('ok', true, 'campanhas', v_c, 'dias', v_d, 'palavras', v_p, 'conta', v_conta, 'em', now());
end $$;
revoke execute on function public.google_ads_gravar(jsonb, jsonb, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.google_ads_gravar(jsonb, jsonb, jsonb, jsonb) to service_role;

-- ───────────── (3) o dia a dia do Google ─────────────
create or replace view public.v_google_ads_dia with (security_invoker = true) as
with g as (
  select d.dia, sum(d.custo) as custo, sum(d.impressoes)::int as impressoes, sum(d.cliques)::int as cliques,
         sum(d.conversoes) as conversoes_google, max(d.atualizado_em) as atualizado_em
    from public.google_ads_diario d group by d.dia
), mari as (
  select (c.created_at at time zone 'America/Sao_Paulo')::date as dia, count(*)::int as conversas_mari,
         count(*) filter (where coalesce(c.cep, '') <> '' and c.dentro_area is true)::int as com_cep,
         count(*) filter (where c.handoff_motivo = 'dados_completos')::int as qualificadas
    from public.mari_conversas c
   where c.origem = 'google_ads' and c.canal = 'whatsapp' and coalesce(c.funil_destino, '') <> 'teste_duplicada'
   group by 1
), venda as (   -- venda = OS gerada, pela data da OS (o mesmo critério da aba Meta Ads e da tela Vendas)
  select (v.nio_os_em at time zone 'America/Sao_Paulo')::date as dia, count(*)::int as vendas
    from public.vendas v
   where v.origem = 'google_ads' and coalesce(v.nio_os, '') <> '' and v.nio_os_em is not null
   group by 1
), dias as (select dia from g union select dia from mari union select dia from venda)
select d.dia, coalesce(g.custo, 0)::numeric(12,2) as custo, coalesce(g.impressoes, 0) as impressoes, coalesce(g.cliques, 0) as cliques,
       coalesce(g.conversoes_google, 0)::numeric(12,2) as conversoes_google,
       coalesce(m.conversas_mari, 0) as conversas_mari, coalesce(m.com_cep, 0) as com_cep, coalesce(m.qualificadas, 0) as qualificadas,
       coalesce(v.vendas, 0) as vendas, g.atualizado_em
  from dias d left join g on g.dia = d.dia left join mari m on m.dia = d.dia left join venda v on v.dia = d.dia;
grant select on public.v_google_ads_dia to authenticated, service_role;

-- A tela (e a agência, que não lê conversa nem venda) recebe o dia a dia já contado — nenhuma linha de cliente.
create or replace function public.google_ads_dia()
returns setof public.v_google_ads_dia language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') and not public.sou_agencia() then return; end if;
  return query select * from public.v_google_ads_dia order by dia;
end $$;
revoke execute on function public.google_ads_dia() from public, anon;
grant execute on function public.google_ads_dia() to authenticated, service_role;

-- ───────────── (4) custo por canal e dia: uma fonte por fato ─────────────
create or replace view public.v_canal_custo_dia with (security_invoker = true) as
 select 'dharma'::text as parceiro_id, 'meta_ads'::text as canal, d.dia, round(sum(d.gasto), 2)::numeric(12,2) as valor,
        'meta_ads_diario'::text as origem_do_dado
   from public.meta_ads_diario d group by d.dia
union all
 select g.parceiro_id, 'google_ads'::text, g.dia, round(sum(g.custo), 2)::numeric(12,2), 'google_ads_diario'::text
   from public.google_ads_diario g group by g.parceiro_id, g.dia
union all
 select c.parceiro_id, c.canal, c.dia, c.valor, c.origem_do_dado
   from public.canal_custo_dia c
  where not (c.canal = 'meta_ads' and exists (select 1 from public.meta_ads_diario m where m.dia = c.dia))
    and not (c.canal = 'google_ads' and exists (select 1 from public.google_ads_diario g where g.dia = c.dia and g.parceiro_id = c.parceiro_id));
grant select on public.v_canal_custo_dia to authenticated, service_role;

create or replace function public.canal_custo_gravar(p_canal text, p_dia date, p_valor numeric, p_obs text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  -- logado: só o admin (ou a chave de serviço); sem login (CLI do Claude Code) passa
  if coalesce(current_setting('request.jwt.claims', true), '') <> ''
     and coalesce((select public.meu_perfil()), '') <> 'admin'
     and coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') <> 'service_role' then
    raise exception 'Só o admin grava custo de canal.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.config_canais where canal = p_canal) then raise exception 'Canal desconhecido: %', p_canal; end if;
  if p_canal = 'meta_ads' then raise exception 'O custo da Meta vem sozinho da coleta (meta_ads_diario): não digite.'; end if;
  if p_dia is null or p_dia > (now() at time zone 'America/Sao_Paulo')::date then raise exception 'Informe um dia até hoje.'; end if;
  if p_valor is null then
    delete from public.canal_custo_dia where parceiro_id = 'dharma' and canal = p_canal and dia = p_dia;
    return jsonb_build_object('ok', true, 'apagado', true);
  end if;
  -- 0369: dia que a coleta do Google já trouxe não aceita custo digitado (uma fonte por fato)
  if p_canal = 'google_ads' and exists (select 1 from public.google_ads_diario where dia = p_dia) then
    raise exception 'O custo do Google em % já veio da coleta (google_ads_diario): não digite.', to_char(p_dia, 'DD/MM');
  end if;
  if p_valor < 0 then raise exception 'O valor não pode ser negativo.'; end if;
  insert into public.canal_custo_dia (canal, dia, valor, obs, gravado_por)
  values (p_canal, p_dia, round(p_valor, 2), nullif(btrim(coalesce(p_obs, '')), ''), auth.uid())
  on conflict (parceiro_id, canal, dia) do update set valor = excluded.valor, obs = excluded.obs, gravado_por = excluded.gravado_por, gravado_em = now();
  return jsonb_build_object('ok', true, 'canal', p_canal, 'dia', p_dia, 'valor', round(p_valor, 2));
end $$;

-- ───────────── (5) o card "Canais · 7 dias": + status, retorno e aba ─────────────
drop view if exists public.v_canais_7d;
drop function if exists public.canais_resumo(int);
create function public.canais_resumo(p_dias int default 7)
returns table(canal text, nome text, tipo text, ativo boolean, ordem int, conversas int, qualificados int, vendas int, instaladas int,
              gasto numeric, custo_conversa numeric, custo_venda numeric, custo_venda_instalada numeric, comissao_prevista numeric,
              status text, subiu_em date, retorno numeric, aba text)
language plpgsql stable security definer set search_path = public as $$
declare
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_de date := (now() at time zone 'America/Sao_Paulo')::date - (greatest(1, least(coalesce(p_dias, 7), 3650)) - 1);
  v_ts timestamptz := (v_de::timestamp at time zone 'America/Sao_Paulo');
begin
  if not public._os_pode_gravar() then raise exception 'Só admin ou backoffice.' using errcode = '42501'; end if;
  return query
  with cv as (
    select c.origem, count(*)::int as n,
           count(*) filter (where c.funil_etapa in ('qualificada', 'pedido', 'biometria', 'agendada', 'instalada')
                              and coalesce(c.funil_destino, '') not in ('ja_cliente_nio', 'credito_negado', 'teste_duplicada'))::int as q
      from public.mari_conversas c
     where c.canal = 'whatsapp' and c.created_at >= v_ts
       and coalesce(c.funil_destino, '') <> 'teste_duplicada' and coalesce(c.telefone, '') not like '5500000000%'
     group by c.origem
  ), vd as (
    select v.origem,
           count(*) filter (where v.criado_em >= v_ts and v.status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme'))::int as n,
           count(*) filter (where v.instalado_em >= v_ts and v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme'))::int as inst,
           coalesce(sum(v.comissao_prevista) filter (where v.criado_em >= v_ts
                      and v.status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme')), 0) as com
      from public.vendas v group by v.origem
  ), gs as (
    select x.canal, sum(x.valor) as g from public.v_canal_custo_dia x where x.dia >= v_de group by x.canal
  ), entrega as (   -- canal pago com coleta: gastou alguma coisa hoje ou ontem?
    select 'meta_ads'::text as canal, true as tem_coleta,
           coalesce(sum(d.gasto) filter (where d.dia >= v_hoje - 1), 0) > 0 as entregou
      from public.meta_ads_diario d where d.dia >= v_hoje - 7
    union all
    select 'google_ads', exists (select 1 from public.google_ads_conta),
           coalesce((select sum(g.custo) from public.google_ads_diario g where g.dia >= v_hoje - 1), 0) > 0
  ), base as (
    select k.canal, k.nome, k.tipo, k.ativo, k.ordem, k.subiu_em, k.aba,
           coalesce(cv.n, 0) as cn, coalesce(cv.q, 0) as cq, coalesce(vd.n, 0) as vn, coalesce(vd.inst, 0) as vi, gs.g,
           coalesce(vd.com, 0)::numeric as com,
           case when k.ativo and e.tem_coleta and not e.entregou then 'sem_entrega'
                when k.ativo then 'no_ar'
                when k.subiu_em is not null then 'fora_do_ar'
                else 'nunca_subiu' end as st
      from public.config_canais k
      left join cv on cv.origem = k.canal
      left join vd on vd.origem = k.canal
      left join gs on gs.canal = k.canal
      left join entrega e on e.canal = k.canal
     where k.tipo <> 'interno'
  )
  select b.canal, b.nome, b.tipo, b.ativo, b.ordem, b.cn, b.cq, b.vn, b.vi,
         b.g, round(b.g / nullif(b.cn, 0), 2), round(b.g / nullif(b.vn, 0), 2), round(b.g / nullif(b.vi, 0), 2), b.com,
         b.st, b.subiu_em,
         round(b.com / nullif(b.g, 0), 2),   -- retorno: vazio sem gasto (orgânico e indicação = indefinido, não infinito)
         b.aba
    from base b
   order by (b.st in ('no_ar', 'sem_entrega')) desc, round(b.com / nullif(b.g, 0), 2) desc nulls last,
            round(b.g / nullif(b.vi, 0), 2) nulls last, round(b.g / nullif(b.vn, 0), 2) nulls last,
            round(b.g / nullif(b.cn, 0), 2) nulls last, b.cn desc, b.ordem;
end $$;
revoke execute on function public.canais_resumo(int) from public, anon;
grant execute on function public.canais_resumo(int) to authenticated, service_role;
create view public.v_canais_7d as select * from public.canais_resumo(7);
grant select on public.v_canais_7d to authenticated, service_role;

-- ───────────── (6) selo do Google no menu ─────────────
create or replace function public._selo_google()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  c record; v_ativas int; v_campanhas int; v_media numeric; v_dias numeric; v_custo_hoje numeric;
  v_nivel text := 'ok'; v_texto text; v_mot text[] := '{}';
  v_atraso int := public._pulso_cfg('pulso_google_coleta_atraso_min', 45)::int;
  v_dias_alerta numeric := public._pulso_cfg('pulso_google_saldo_dias_alerta', 3);
begin
  select * into c from public.google_ads_conta order by coletado_em desc limit 1;
  if not found then return null; end if;   -- coleta nunca rodou: sem selo (a tela diz "Coleta não configurada")
  select count(*) filter (where status = 'ENABLED'), count(*) into v_ativas, v_campanhas from public.google_ads_campanhas;
  select round(avg(s), 2) into v_media from (select sum(custo) s from public.google_ads_diario
     where dia between (now() at time zone 'America/Sao_Paulo')::date - 7 and (now() at time zone 'America/Sao_Paulo')::date - 1 group by dia) x;
  select coalesce(sum(custo), 0) into v_custo_hoje from public.google_ads_diario where dia = (now() at time zone 'America/Sao_Paulo')::date;
  v_dias := case when c.saldo is not null and v_media > 0 then round(c.saldo / v_media, 1) end;

  if coalesce(c.status, 'ENABLED') <> 'ENABLED' then
    v_nivel := 'falha'; v_texto := 'Google: conta parada';
    v_mot := v_mot || format('conta do Google Ads %s — ver em Faturamento', lower(c.status));
  elsif c.saldo is not null and c.saldo <= 0 then
    v_nivel := 'falha'; v_texto := 'Google: sem saldo';
    v_mot := v_mot || 'o pré-pago acabou — os anúncios param até recarregar'::text;
  end if;
  if v_ativas = 0 then
    if v_nivel = 'ok' then v_nivel := 'alerta'; v_texto := 'Google: nada no ar'; end if;
    v_mot := v_mot || 'nenhuma campanha ativa'::text;
  end if;
  if c.anuncios_reprovados > 0 then
    if v_nivel = 'ok' then v_nivel := 'alerta'; v_texto := 'Google: reprovado'; end if;
    v_mot := v_mot || format('%s anúncio(s) reprovado(s)', c.anuncios_reprovados);
  end if;
  if v_dias is not null and v_dias < v_dias_alerta and c.saldo > 0 then
    if v_nivel = 'ok' then v_nivel := 'alerta'; v_texto := 'Google: saldo no fim'; end if;
    v_mot := v_mot || format('pré-pago de R$ %s dá ~%s dia(s) de gasto', replace(to_char(c.saldo, 'FM999G990D00'), '.', ','), replace(v_dias::text, '.', ','));
  end if;
  if c.coletado_em < now() - make_interval(mins => v_atraso) then
    if v_nivel = 'ok' then v_nivel := 'alerta'; v_texto := 'Google: sem leitura'; end if;
    v_mot := v_mot || format('coleta do Google parada desde %s — o status pode estar velho', to_char(c.coletado_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'));
  end if;
  v_mot := v_mot || format('%s de %s campanha(s) ativa(s) · R$ %s hoje', v_ativas, v_campanhas, replace(to_char(v_custo_hoje, 'FM999G990D00'), '.', ','));
  return jsonb_build_object('nivel', v_nivel, 'texto', coalesce(v_texto, format('Google %s no ar', v_ativas)),
                            'motivos', to_jsonb(v_mot), 'href', 'metaads.html#google');
end $$;
revoke execute on function public._selo_google() from public, anon, authenticated;
grant execute on function public._selo_google() to service_role;

create or replace function public.status_operacao()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(public.pulso_operacao()->'selos', '{}'::jsonb)
         || coalesce((select jsonb_build_object('google', g.s) from (select public._selo_google() as s) g where g.s is not null), '{}'::jsonb)
$$;

-- ───────────── (7) a agência lê o que a agência lê ─────────────
do $$
declare d text := pg_get_functiondef('public.agencia_leituras_indevidas()'::regprocedure);
begin
  if position('''config_area'', ''dfv_bairros_pronto'']' in d) = 0 or position('''placar_agencia'', ''tabela_agencia'', ''painel_meta_ritmo'', ''agencia_leituras_indevidas'']' in d) = 0 then
    raise exception '0369: agencia_leituras_indevidas mudou desde 23/11 — refazer o trecho (7) a partir da versão no ar';
  end if;
  d := replace(d, '''config_area'', ''dfv_bairros_pronto'']',
                  '''config_area'', ''dfv_bairros_pronto'', ''google_ads_campanhas'', ''google_ads_diario'', ''google_ads_palavras'']');
  d := replace(d, '''placar_agencia'', ''tabela_agencia'', ''painel_meta_ritmo'', ''agencia_leituras_indevidas'']',
                  '''placar_agencia'', ''tabela_agencia'', ''painel_meta_ritmo'', ''agencia_leituras_indevidas'', ''google_ads_dia'']');
  execute d;
end $$;

commit;

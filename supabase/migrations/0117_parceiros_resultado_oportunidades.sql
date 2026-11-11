-- NIOGEN | supabase/migrations/0117_parceiros_resultado_oportunidades.sql | 10/11/2026 — Claude Code (docs/Prompt_parceiros_admin_v2_101126_2150.md)
-- Tela Parceiros PAP por resultado + 🔥 oportunidades do canal. Não mexe nas regras de cálculo da 0115.
--  1. parceiro_canal_resumo(): os 4 números do topo (ativos · enviadas/instaladas no mês · margem do canal no mês · a pagar na próxima sexta).
--  2. parceiro_lista_admin(): por parceiro — nível do mês, faltam pontos, a receber na próxima sexta, garantia até, indevidas.
--  3. 🔥 oportunidades do canal P1–P5 (limiares e textos em config_regras.parceiro_oportunidades — nada fixo no código):
--     P1 perto do degrau · P2 sem venda enviada há N dias · P3 garantia em risco no fim do mês · P4 conferência atrasada ·
--     P5 cadastro aguardando aprovação. Log próprio parceiro_oportunidades_log (mostrada · enviada · dispensada), porque
--     o oportunidades_log da 0107 é preso a conversa da Mari. parceiro_oportunidades_abertas() devolve e grava "mostrada" (1/dia).
--     parceiro_oportunidades_resumo(dias): criadas × usadas × viraram venda instalada · subiram de degrau.
--  4. Boas-vindas desligado (substituído pela largada); largada padrão (valor e abatimento) em config_parceiros.
--  5. Calendário: `confirmado` passa a significar "a Nio pagou a quinta do ciclo" (Pagamentos mostra "aguardando a Nio pagar"
--     até marcar). Ciclos cuja quinta ainda não chegou voltam para false.
-- Regra 15: log com parceiro_id = tenant ('dharma'); o freelancer é parceiro_pap_id.

-- ════════════════ 4. boas-vindas off · largada padrão ════════════════
update public.config_parceiros set bonus_boas_vindas_valor = null, bonus_boas_vindas_prazo_dias = null;
alter table public.config_parceiros
  add column if not exists largada_valor_padrao       numeric(10, 2) not null default 300 check (largada_valor_padrao >= 0),
  add column if not exists largada_abatimento_padrao  numeric(10, 2) not null default 100 check (largada_abatimento_padrao > 0);
comment on column public.config_parceiros.largada_valor_padrao is 'Valor sugerido da largada em confiança na gaveta do parceiro (o admin confirma).';
comment on column public.config_parceiros.largada_abatimento_padrao is 'Abatimento por venda instalada que todo parceiro novo recebe (parceiros.largada_abatimento_por_venda).';

create or replace function public.parceiros_largada_padrao()
returns trigger language plpgsql set search_path = public as $$
begin
  new.largada_abatimento_por_venda := coalesce((select largada_abatimento_padrao from public.config_parceiros), new.largada_abatimento_por_venda);
  return new;
end;
$$;
revoke execute on function public.parceiros_largada_padrao() from public, anon, authenticated;
drop trigger if exists parceiros_largada_padrao on public.parceiros;
create trigger parceiros_largada_padrao before insert on public.parceiros
  for each row execute function public.parceiros_largada_padrao();

-- ════════════════ 5. calendário: confirmado = a Nio pagou ════════════════
update public.parceiro_calendario set confirmado = false where nio_paga_em >= (now() at time zone 'America/Sao_Paulo')::date;
comment on column public.parceiro_calendario.confirmado is
  'A Nio pagou a Dharma a quinta deste ciclo (marcado pelo admin). Até lá, Pagamentos mostra "aguardando a Nio pagar".';

-- ════════════════ 3. config das oportunidades do canal ════════════════
insert into public.config_regras (chave, valor, descricao, parceiro_id) values ('parceiro_oportunidades', $j${
  "ligado": true,
  "dispensa_horas": 24,
  "dispensa_motivos": [{"codigo": "ja_falei", "nome": "Já falei"}, {"codigo": "nao_vale", "nome": "Não vale"}, {"codigo": "depois", "nome": "Depois"}],
  "P1": {"ativo": true, "nome": "Perto do degrau", "pontos": 50, "faltam_max": 200,
         "texto": "Oi, {nome}! Aqui é da Dharma. Faltam só {faltam} pontos[ ({exemplo})] para você ganhar {premio} de ajuda de custo este mês. Bora fechar mais uma?"},
  "P2": {"ativo": true, "nome": "Parado sem enviar venda", "pontos": 30, "dias": 7, "valor_padrao": 350,
         "texto": "Oi, {nome}! Aqui é da Dharma. Faz {dias} dias que você não manda venda. Precisa de alguma ajuda? A tabela e o material estão no seu app."},
  "P3": {"ativo": true, "nome": "Garantia em risco", "pontos": 45, "dias_para_virar": 10,
         "texto": "Oi, {nome}! Aqui é da Dharma. Sua garantia de {piso} este mês vale com {minimo} pontos e você está com {pontos}. Faltam {faltam} pontos[ ({exemplo})] até o fim do mês."},
  "P4": {"ativo": true, "nome": "Conferência atrasada", "pontos": 60},
  "P5": {"ativo": true, "nome": "Cadastro esperando aprovação", "pontos": 40, "horas": 24}
}$j$::jsonb, 'Oportunidades do canal parceiro (0117): limiares, pontos e textos de P1–P5. Texto: {nome} {faltam} {exemplo} {premio} {dias} {piso} {minimo} {pontos}; trecho entre [ ] some sem a variável.', 'dharma')
on conflict (chave) do nothing;

-- ════════════════ log das oportunidades do canal ════════════════
create table if not exists public.parceiro_oportunidades_log (
  id               bigint generated always as identity primary key,
  parceiro_id      text not null default 'dharma',                         -- tenant (regra 15)
  parceiro_pap_id  uuid not null references public.parceiros (id) on delete cascade,
  venda_id         uuid references public.vendas (id) on delete cascade,
  codigo           text not null check (codigo in ('P1', 'P2', 'P3', 'P4', 'P5')),
  tipo             text not null check (tipo in ('mostrada', 'enviada', 'dispensada')),
  motivo           text,
  valor            numeric(10, 2),
  detalhe          jsonb not null default '{}'::jsonb,
  dia              date not null default (now() at time zone 'America/Sao_Paulo')::date,
  criado_por       uuid references public.usuarios (id) default auth.uid(),
  criado_em        timestamptz not null default now()
);
create unique index if not exists parceiro_oport_log_mostrada_uq
  on public.parceiro_oportunidades_log (codigo, parceiro_pap_id, coalesce(venda_id, '00000000-0000-0000-0000-000000000000'::uuid), dia) where tipo = 'mostrada';
create index if not exists parceiro_oport_log_idx on public.parceiro_oportunidades_log (parceiro_pap_id, criado_em desc);
alter table public.parceiro_oportunidades_log enable row level security;
drop policy if exists parceiro_oport_log_ler on public.parceiro_oportunidades_log;
create policy parceiro_oport_log_ler on public.parceiro_oportunidades_log
  for select to authenticated using (public.meu_perfil() in ('admin', 'backoffice'));
revoke all on public.parceiro_oportunidades_log from anon;

-- ════════════════ por parceiro (lista e oportunidades) ════════════════
-- Mês corrente: pontos, degrau, próximo, faltam, exemplo, garantia (mesma conta de parceiro_meus_pontos, sem depender do login).
create or replace function public.parceiro_situacao_mes(p_parceiro uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  cfg   public.config_parceiros%rowtype;
  mes   date := date_trunc('month', now() at time zone 'America/Sao_Paulo')::date;
  pts   numeric := public.parceiro_pontos_de(p_parceiro, date_trunc('month', now() at time zone 'America/Sao_Paulo')::date);
  atual record;
  prox  record;
  gar   date := public.parceiro_garantia_ate(p_parceiro);
  vale  boolean;
begin
  select * into cfg from public.config_parceiros;
  select d.pontos, d.premio, d.nome into atual from public.parceiro_degraus() d where d.pontos <= pts order by d.pontos desc limit 1;
  select d.pontos, d.premio, d.nome into prox  from public.parceiro_degraus() d where d.pontos > pts order by d.pontos limit 1;
  vale := gar is not null and mes <= gar and exists (
    select 1 from public.pontos_lancamentos x where x.parceiro_id = p_parceiro
       and x.competencia >= (mes - make_interval(months => cfg.garantia_meses))::date and x.competencia < mes
     group by x.competencia having sum(x.pontos) >= cfg.garantia_gatilho_pontos);
  return jsonb_build_object(
    'pontos', pts, 'nivel', atual.nome, 'nivel_premio', atual.premio,
    'proximo_nome', prox.nome, 'proximo_pontos', prox.pontos, 'proximo_premio', prox.premio,
    'faltam', case when prox.pontos is not null then prox.pontos - pts end,
    'exemplo', public.parceiro_exemplo_plano(p_parceiro, case when prox.pontos is not null then prox.pontos - pts end),
    'garantia_ate', gar, 'garantia_vale', coalesce(vale, false), 'garantia_piso', cfg.garantia_piso, 'garantia_min', cfg.garantia_min_pontos,
    'indevida_mes', public.parceiro_mes_com_indevida(p_parceiro, mes));
end;
$$;
revoke execute on function public.parceiro_situacao_mes(uuid) from public, anon, authenticated;

create or replace function public.parceiro_lista_admin()
returns table (parceiro_pap_id uuid, nivel text, pontos numeric, faltam numeric, proximo_premio numeric, exemplo text,
               proxima_sexta date, a_receber numeric, garantia_ate date, garantia_vale boolean, indevidas bigint,
               enviadas_mes bigint, instaladas_mes bigint)
language plpgsql stable security definer set search_path = public as $$
declare
  mes date := date_trunc('month', now() at time zone 'America/Sao_Paulo')::date;
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then return; end if;
  return query
  with s as (select p.id, public.parceiro_situacao_mes(p.id) as j from public.parceiros p where p.status <> 'desligado' or exists
               (select 1 from public.parceiro_pagamentos g where g.parceiro_id = p.id and g.status = 'previsto')),
  px as (select g.parceiro_id, min(g.vence_em) as sexta from public.parceiro_pagamentos g
          where g.status = 'previsto' and g.vence_em >= hoje group by g.parceiro_id)
  select s.id, s.j ->> 'nivel', (s.j ->> 'pontos')::numeric, (s.j ->> 'faltam')::numeric, (s.j ->> 'proximo_premio')::numeric, s.j ->> 'exemplo',
         px.sexta,
         (select sum(g.valor) from public.parceiro_pagamentos g where g.parceiro_id = s.id and g.status = 'previsto' and g.vence_em = px.sexta),
         (s.j ->> 'garantia_ate')::date, (s.j ->> 'garantia_vale')::boolean,
         (select count(*) from public.vendas v where v.parceiro_id = s.id and v.parceiro_indevida),
         (select count(*) from public.vendas v where v.parceiro_id = s.id and v.criado_em >= (mes::timestamp at time zone 'America/Sao_Paulo')),
         (select count(*) from public.vendas v where v.parceiro_id = s.id and v.nio_situacao = 'Concluído' and v.nio_venda_valida is true
             and v.instalado_em >= (mes::timestamp at time zone 'America/Sao_Paulo'))
    from s left join px on px.parceiro_id = s.id;
end;
$$;
revoke execute on function public.parceiro_lista_admin() from public, anon;
grant execute on function public.parceiro_lista_admin() to authenticated;

-- ════════════════ 1. topo = resultado ════════════════
create or replace function public.parceiro_canal_resumo()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  mes  date := date_trunc('month', now() at time zone 'America/Sao_Paulo')::date;
  ini  timestamptz := (date_trunc('month', now() at time zone 'America/Sao_Paulo'))::timestamp at time zone 'America/Sao_Paulo';
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  r    jsonb;
  sexta date;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin e backoffice.' using errcode = '42501';
  end if;
  select min(vence_em) into sexta from public.parceiro_pagamentos where status = 'previsto' and vence_em >= hoje;
  with inst as (
    select v.* from public.vendas v
     where v.origem = 'parceiro_pap' and not v.parceiro_indevida and v.nio_situacao = 'Concluído' and v.nio_venda_valida is true and v.instalado_em >= ini
  ), custo as (
    -- o que o canal paga pelas vendas instaladas no mês (comissão, boas-vindas, abatimento da largada); a ajuda de custo vem à parte
    select coalesce(sum(g.valor), 0) as v from public.parceiro_pagamentos g
     where g.status <> 'cancelado' and g.venda_id in (select id from inst)
  )
  select jsonb_build_object(
    'ativos', (select count(*) from public.parceiros where status = 'ativo'),
    'aguardando', (select count(*) from public.parceiros where status = 'aguardando'),
    'enviadas_mes', (select count(*) from public.vendas where origem = 'parceiro_pap' and criado_em >= ini),
    'instaladas_mes', (select count(*) from inst),
    'comissao_nio_mes', (select coalesce(sum(comissao_prevista), 0) from inst),
    'custo_parceiros_mes', (select v from custo),
    'ajuda_prevista_mes', (select coalesce(sum(public.parceiro_ajuda_prevista(p.id)), 0) from public.parceiros p where p.status <> 'desligado'),
    'proxima_sexta', sexta,
    'a_pagar_sexta', (select coalesce(sum(valor), 0) from public.parceiro_pagamentos where status = 'previsto' and vence_em = sexta),
    'parceiros_sexta', (select count(distinct parceiro_id) from public.parceiro_pagamentos where status = 'previsto' and vence_em = sexta),
    'nio_pagou_sexta', (select bool_and(confirmado) from public.parceiro_calendario where parceiro_id = 'dharma' and parceiro_recebe_em = sexta),
    'a_confirmar', (select coalesce(sum(valor), 0) from public.parceiro_pagamentos where status = 'previsto' and vence_em is null)
  ) into r;
  r := r || jsonb_build_object('margem_mes', (r ->> 'comissao_nio_mes')::numeric - (r ->> 'custo_parceiros_mes')::numeric - (r ->> 'ajuda_prevista_mes')::numeric);
  return r;
end;
$$;

-- Ajuda de custo que o mês corrente rende hoje (degrau ou piso da garantia; 0 com venda indevida). Mesma conta da apuração.
create or replace function public.parceiro_ajuda_prevista(p_parceiro uuid)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare
  s jsonb := public.parceiro_situacao_mes(p_parceiro);
begin
  if (s ->> 'indevida_mes')::boolean then return 0; end if;
  return greatest(coalesce((s ->> 'nivel_premio')::numeric, 0),
                  case when (s ->> 'garantia_vale')::boolean and (s ->> 'pontos')::numeric >= (s ->> 'garantia_min')::numeric
                       then (s ->> 'garantia_piso')::numeric else 0 end);
end;
$$;
revoke execute on function public.parceiro_ajuda_prevista(uuid) from public, anon, authenticated;
revoke execute on function public.parceiro_canal_resumo() from public, anon;
grant execute on function public.parceiro_canal_resumo() to authenticated;

-- ════════════════ 3. oportunidades do canal ════════════════
create or replace function public.parceiro_oportunidades_abertas()
returns table (codigo text, nome text, pontos int, parceiro_pap_id uuid, parceiro_nome text, whatsapp text, venda_id uuid,
               motivo text, valor numeric, acao text, texto_sugerido text, desde timestamptz)
language plpgsql security definer set search_path = public as $$
declare
  c    jsonb := coalesce(public.config_regra('parceiro_oportunidades', '{}'::jsonb), '{}'::jsonb);
  cfg  public.config_parceiros%rowtype;
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  fim  date := (date_trunc('month', now() at time zone 'America/Sao_Paulo') + interval '1 month - 1 day')::date;
  disp int := coalesce((c ->> 'dispensa_horas')::int, 24);
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') or not coalesce((c ->> 'ligado')::boolean, true) then return; end if;
  select * into cfg from public.config_parceiros;

  create temp table if not exists _pop (codigo text, nome text, pontos int, parceiro_pap_id uuid, parceiro_nome text, whatsapp text, venda_id uuid,
                                        motivo text, valor numeric, acao text, texto_sugerido text, desde timestamptz) on commit drop;
  truncate _pop;

  -- P1 · perto do próximo degrau
  if coalesce((c #>> '{P1,ativo}')::boolean, false) then
    insert into _pop
    select 'P1', c #>> '{P1,nome}', coalesce((c #>> '{P1,pontos}')::int, 0), p.id, p.nome, p.whatsapp, null,
           'Faltam ' || to_char((s ->> 'faltam')::numeric, 'FM999G990') || ' pts' || coalesce(' (' || (s ->> 'exemplo') || ')', '')
             || ' para ' || coalesce(s ->> 'proximo_nome', 'o próximo degrau') || ' · R$ ' || to_char((s ->> 'proximo_premio')::numeric, 'FM999G990') || ' de ajuda',
           (s ->> 'proximo_premio')::numeric - public.parceiro_ajuda_prevista(p.id),
           'whatsapp',
           public._oport_texto(c #>> '{P1,texto}', jsonb_build_object('nome', split_part(p.nome, ' ', 1), 'faltam', to_char((s ->> 'faltam')::numeric, 'FM999G990'),
             'exemplo', s ->> 'exemplo', 'premio', 'R$ ' || to_char((s ->> 'proximo_premio')::numeric, 'FM999G990'))),
           null
      from public.parceiros p cross join lateral (select public.parceiro_situacao_mes(p.id) as s) x
     where p.status = 'ativo' and (s ->> 'faltam') is not null and (s ->> 'pontos')::numeric > 0
       and (s ->> 'faltam')::numeric <= coalesce((c #>> '{P1,faltam_max}')::numeric, 200);
  end if;

  -- P2 · ativo sem venda enviada há N dias (conta da aprovação, para não acusar quem acabou de entrar)
  if coalesce((c #>> '{P2,ativo}')::boolean, false) then
    insert into _pop
    select 'P2', c #>> '{P2,nome}', coalesce((c #>> '{P2,pontos}')::int, 0), p.id, p.nome, p.whatsapp, null,
           case when u.ult is null then 'Nunca enviou venda · aprovado há ' || (hoje - (coalesce(p.aprovado_em, p.criado_em) at time zone 'America/Sao_Paulo')::date) || ' dias'
                else 'Sem enviar venda há ' || (hoje - (u.ult at time zone 'America/Sao_Paulo')::date) || ' dias' end,
           coalesce(u.media, (c #>> '{P2,valor_padrao}')::numeric),
           'whatsapp',
           public._oport_texto(c #>> '{P2,texto}', jsonb_build_object('nome', split_part(p.nome, ' ', 1),
             'dias', (hoje - (coalesce(u.ult, p.aprovado_em, p.criado_em) at time zone 'America/Sao_Paulo')::date)::text)),
           coalesce(u.ult, p.aprovado_em, p.criado_em)
      from public.parceiros p
      cross join lateral (select max(v.criado_em) as ult, avg(nullif(v.comissao_prevista, 0)) as media from public.vendas v where v.parceiro_id = p.id) u
     where p.status = 'ativo'
       and coalesce(u.ult, p.aprovado_em, p.criado_em) < now() - make_interval(days => coalesce((c #>> '{P2,dias}')::int, 7));
  end if;

  -- P3 · garantia ativa, abaixo do mínimo, faltando ≤ N dias para o mês virar
  if coalesce((c #>> '{P3,ativo}')::boolean, false) and (fim - hoje) <= coalesce((c #>> '{P3,dias_para_virar}')::int, 10) then
    insert into _pop
    select 'P3', c #>> '{P3,nome}', coalesce((c #>> '{P3,pontos}')::int, 0), p.id, p.nome, p.whatsapp, null,
           'Garantia de R$ ' || to_char(cfg.garantia_piso, 'FM999G990') || ' em risco: ' || to_char((s ->> 'pontos')::numeric, 'FM999G990') || ' de '
             || to_char(cfg.garantia_min_pontos, 'FM999G990') || ' pts · o mês vira em ' || (fim - hoje + 1) || ' dias',
           cfg.garantia_piso,
           'whatsapp',
           public._oport_texto(c #>> '{P3,texto}', jsonb_build_object('nome', split_part(p.nome, ' ', 1), 'piso', 'R$ ' || to_char(cfg.garantia_piso, 'FM999G990'),
             'minimo', to_char(cfg.garantia_min_pontos, 'FM999G990'), 'pontos', to_char((s ->> 'pontos')::numeric, 'FM999G990'),
             'faltam', to_char(cfg.garantia_min_pontos - (s ->> 'pontos')::numeric, 'FM999G990'),
             'exemplo', public.parceiro_exemplo_plano(p.id, cfg.garantia_min_pontos - (s ->> 'pontos')::numeric))),
           null
      from public.parceiros p cross join lateral (select public.parceiro_situacao_mes(p.id) as s) x
     where p.status = 'ativo' and (s ->> 'garantia_vale')::boolean and (s ->> 'pontos')::numeric < cfg.garantia_min_pontos;
  end if;

  -- P4 · venda de parceiro parada na conferência além do prazo (valor = comissão Nio da venda)
  if coalesce((c #>> '{P4,ativo}')::boolean, false) then
    insert into _pop
    select 'P4', c #>> '{P4,nome}', coalesce((c #>> '{P4,pontos}')::int, 0), p.id, p.nome, null, v.id,
           split_part(btrim(v.cliente_nome), ' ', 1) || coalesce(' · ' || v.bairro, '') || ' · conferência atrasada '
             || public._oport_dur(now() - v.conferencia_prazo_ate),
           v.comissao_prevista, 'venda', null, v.conferencia_prazo_ate
      from public.vendas v join public.parceiros p on p.id = v.parceiro_id
     where v.origem = 'parceiro_pap' and v.status = '0_qualificado' and v.conferencia_status = 'pendente' and v.conferencia_prazo_ate < now();
  end if;

  -- P5 · cadastro aguardando aprovação há mais de N horas
  if coalesce((c #>> '{P5,ativo}')::boolean, false) then
    insert into _pop
    select 'P5', c #>> '{P5,nome}', coalesce((c #>> '{P5,pontos}')::int, 0), p.id, p.nome, p.whatsapp, null,
           'Cadastro esperando aprovação há ' || public._oport_dur(now() - p.criado_em) || coalesce(' · ' || p.cidade, ''),
           coalesce((c #>> '{P2,valor_padrao}')::numeric, 0), 'parceiro', null, p.criado_em
      from public.parceiros p
     where p.status = 'aguardando' and p.criado_em < now() - make_interval(hours => coalesce((c #>> '{P5,horas}')::int, 24));
  end if;

  -- Fora o que foi enviado ou dispensado nas últimas N horas (mesmo parceiro, código e venda).
  delete from _pop o using public.parceiro_oportunidades_log l
   where l.tipo in ('enviada', 'dispensada') and l.codigo = o.codigo and l.parceiro_pap_id = o.parceiro_pap_id
     and l.venda_id is not distinct from o.venda_id and l.criado_em > now() - make_interval(hours => disp);

  insert into public.parceiro_oportunidades_log (parceiro_pap_id, venda_id, codigo, tipo, motivo, valor)
  select o.parceiro_pap_id, o.venda_id, o.codigo, 'mostrada', o.motivo, o.valor from _pop o
  on conflict do nothing;

  return query select * from _pop order by 3 desc, 9 desc nulls last;
end;
$$;
revoke execute on function public.parceiro_oportunidades_abertas() from public, anon;
grant execute on function public.parceiro_oportunidades_abertas() to authenticated;

create or replace function public.parceiro_oportunidade_registrar(p_parceiro uuid, p_codigo text, p_tipo text, p_venda uuid default null, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin e backoffice.' using errcode = '42501';
  end if;
  if p_tipo not in ('enviada', 'dispensada') then
    raise exception 'Tipo: enviada ou dispensada.' using errcode = 'P0001';
  end if;
  insert into public.parceiro_oportunidades_log (parceiro_pap_id, venda_id, codigo, tipo, motivo, detalhe)
  values (p_parceiro, p_venda, p_codigo, p_tipo, p_motivo,
          jsonb_build_object('situacao', public.parceiro_situacao_mes(p_parceiro)));
  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.parceiro_oportunidade_registrar(uuid, text, text, uuid, text) from public, anon;
grant execute on function public.parceiro_oportunidade_registrar(uuid, text, text, uuid, text) to authenticated;

-- Medida de 7 dias: criadas (mostradas) × usadas (enviadas) × viraram venda (parceiro enviou venda depois) ×
-- venda instalada · subiram de degrau depois de um aviso P1/P3.
create or replace function public.parceiro_oportunidades_resumo(p_dias int default 7)
returns jsonb language sql stable security definer set search_path = public as $$
  with u as (
    select l.* from public.parceiro_oportunidades_log l
     where l.tipo = 'enviada' and l.criado_em > now() - make_interval(days => p_dias)
       and coalesce(public.meu_perfil(), '') in ('admin', 'backoffice')
  )
  select jsonb_build_object(
    'dias', p_dias,
    'criadas', (select count(distinct (codigo, parceiro_pap_id, venda_id, dia)) from public.parceiro_oportunidades_log
                 where tipo = 'mostrada' and criado_em > now() - make_interval(days => p_dias)),
    'usadas', (select count(*) from u),
    'dispensadas', (select count(*) from public.parceiro_oportunidades_log where tipo = 'dispensada' and criado_em > now() - make_interval(days => p_dias)),
    'viraram_venda', (select count(*) from u where exists (select 1 from public.vendas v where v.parceiro_id = u.parceiro_pap_id and v.criado_em > u.criado_em)),
    'viraram_instalada', (select count(*) from u where exists (select 1 from public.vendas v where v.parceiro_id = u.parceiro_pap_id and v.criado_em > u.criado_em
                                                                  and v.nio_situacao = 'Concluído' and v.nio_venda_valida is true)),
    'subiram_degrau', (select count(*) from u where u.codigo in ('P1', 'P3')
                         and coalesce((public.parceiro_situacao_mes(u.parceiro_pap_id) ->> 'nivel_premio')::numeric, 0)
                             > coalesce((u.detalhe #>> '{situacao,nivel_premio}')::numeric, 0)),
    'por_codigo', (select coalesce(jsonb_object_agg(codigo, n), '{}'::jsonb) from (select codigo, count(*) n from u group by codigo) z))
$$;
revoke execute on function public.parceiro_oportunidades_resumo(int) from public, anon;
grant execute on function public.parceiro_oportunidades_resumo(int) to authenticated;

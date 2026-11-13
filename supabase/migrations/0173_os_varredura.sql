-- NIOGEN | 0173_os_varredura.sql | 13/11/2026 — Claude Code (Ricardo, 13/11: "Vamos fazer os dois" — Consultar OS agora + varredura)
-- Varredura das OS abertas, pedida pelo botão da tela Operações, com a TRAVA NO BANCO (Ricardo: "travar o botão para o
-- backoffice não ficar atualizando o tempo e consumindo banco de dados"):
--   • uma varredura por vez (pedida ou rodando) — vale para todo mundo, em qualquer aba;
--   • intervalo mínimo entre uma e outra: config_regras.os_varredura_intervalo_min (padrão 15 min);
--   • sem OS aberta para ler, não abre varredura.
-- Quem executa é a rotina os_leitura do n8n: a cada 1 min pergunta os_varredura_proxima() e, se há pedido, lê todas as
-- abertas (uma por vez, crédito e viabilidade na frente) e fecha com os_varredura_fechar(). São 2 gravações por varredura,
-- mais as leituras que MUDARAM (leitura igual não grava — 0168).
-- A consulta de UMA OS pela ficha não passa por aqui: vai direto ao operador pela edge function credito-consulta (ação 'os').

create table if not exists public.os_varreduras (
  id           bigint generated always as identity primary key,
  parceiro_id  text not null default 'dharma',
  estado       text not null default 'pedida' check (estado in ('pedida', 'rodando', 'terminada', 'falhou')),
  pedida_por   uuid references public.usuarios (id) default auth.uid(),
  pedida_em    timestamptz not null default now(),
  iniciada_em  timestamptz,
  terminada_em timestamptz,
  na_fila      int,
  lidas        int,
  erros        int,
  mudaram      int,
  resumo       jsonb
);
create index if not exists os_varreduras_recentes_idx on public.os_varreduras (parceiro_id, pedida_em desc);
comment on table public.os_varreduras is 'Cada varredura das OS abertas pedida pela tela Operações. Escrita só pelas funções os_varredura_*.';

alter table public.os_varreduras enable row level security;
drop policy if exists os_varreduras_ler on public.os_varreduras;
create policy os_varreduras_ler on public.os_varreduras for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));
revoke all on public.os_varreduras from anon, authenticated;
grant select on public.os_varreduras to authenticated;

insert into public.config_regras (chave, valor, descricao) values
  ('os_varredura_intervalo_min', '15'::jsonb,
   'Operações › Varrer OS abertas: minutos de espera entre uma varredura e a próxima (trava no banco, vale para todos). 0173.')
on conflict (chave) do nothing;

-- Quantas OS a varredura leria agora (as mesmas da os_fila('abertas'), sem devolver CPF).
create or replace function public._os_abertas_n() returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.vendas v
   where v.status in ('1_vendido', '2_aguardando_instalacao')
     and coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')) ~ '^\d{8}$'
     and length(regexp_replace(coalesce(v.cliente_cpf_cnpj, ''), '\D', '', 'g')) in (11, 14);
$$;
revoke all on function public._os_abertas_n() from public, anon, authenticated;

-- Estado do botão: pode varrer? por quê não? quando libera? como foi a última?
create or replace function public.os_varredura_estado(p_parceiro text default 'dharma')
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_int  int := greatest(coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'os_varredura_intervalo_min'), 15), 1);
  a      public.os_varreduras%rowtype;     -- em andamento
  u      public.os_varreduras%rowtype;     -- a última que terminou (ou falhou)
  v_n    int := public._os_abertas_n();
  v_lib  timestamptz;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    return jsonb_build_object('pode', false, 'motivo', 'perfil');
  end if;
  select * into a from public.os_varreduras
   where parceiro_id = p_parceiro and estado in ('pedida', 'rodando') and pedida_em > now() - interval '20 minutes'
   order by pedida_em desc limit 1;
  select * into u from public.os_varreduras
   where parceiro_id = p_parceiro and estado in ('terminada', 'falhou')
   order by coalesce(terminada_em, pedida_em) desc limit 1;
  v_lib := (select max(pedida_em) from public.os_varreduras where parceiro_id = p_parceiro) + make_interval(mins => v_int);
  return jsonb_strip_nulls(jsonb_build_object(
    'pode', a.id is null and v_n > 0 and (v_lib is null or v_lib <= now()),
    'motivo', case when a.id is not null then 'em_andamento' when v_n = 0 then 'sem_os' when v_lib > now() then 'intervalo' end,
    'abertas', v_n, 'intervalo_min', v_int,
    'libera_em', case when a.id is null and v_lib > now() then v_lib end,
    'andamento', case when a.id is not null then jsonb_build_object('id', a.id, 'estado', a.estado, 'pedida_em', a.pedida_em, 'iniciada_em', a.iniciada_em,
                        'por', (select split_part(nome, ' ', 1) from public.usuarios where id = a.pedida_por)) end,
    'ultima', case when u.id is not null then jsonb_build_object('id', u.id, 'estado', u.estado, 'terminada_em', coalesce(u.terminada_em, u.pedida_em),
                     'na_fila', u.na_fila, 'lidas', u.lidas, 'erros', u.erros, 'mudaram', u.mudaram,
                     'por', (select split_part(nome, ' ', 1) from public.usuarios where id = u.pedida_por)) end));
end;
$$;
revoke all on function public.os_varredura_estado(text) from public, anon;
grant execute on function public.os_varredura_estado(text) to authenticated;

-- O clique do botão. A trava é aqui: duas pessoas clicando ao mesmo tempo, só uma abre a varredura.
create or replace function public.os_varredura_pedir(p_parceiro text default 'dharma')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  e   jsonb;
  v_id bigint;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'A varredura das OS é só do backoffice.' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtext('os_varredura:' || p_parceiro));
  -- pedido que ninguém atendeu em 20 min (rotina desligada ou caída) deixa de segurar o botão
  update public.os_varreduras set estado = 'falhou', terminada_em = now(),
         resumo = coalesce(resumo, '{}'::jsonb) || jsonb_build_object('motivo', 'a rotina não respondeu em 20 min')
   where parceiro_id = p_parceiro and estado in ('pedida', 'rodando') and pedida_em <= now() - interval '20 minutes';
  e := public.os_varredura_estado(p_parceiro);
  if not coalesce((e ->> 'pode')::boolean, false) then
    return e || jsonb_build_object('ok', false);
  end if;
  insert into public.os_varreduras (parceiro_id) values (p_parceiro) returning id into v_id;
  return public.os_varredura_estado(p_parceiro) || jsonb_build_object('ok', true, 'id', v_id);
end;
$$;
revoke all on function public.os_varredura_pedir(text) from public, anon;
grant execute on function public.os_varredura_pedir(text) to authenticated;

-- A rotina pergunta de 1 em 1 min. Devolve {id: null} quando não há pedido (sem gravar nada).
create or replace function public.os_varredura_proxima(p_parceiro text default 'dharma')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id bigint;
begin
  if not public._os_pode_gravar() then raise exception 'Só a rotina do operador.' using errcode = '42501'; end if;
  select id into v_id from public.os_varreduras
   where parceiro_id = p_parceiro and estado = 'pedida' and pedida_em > now() - interval '20 minutes'
   order by pedida_em limit 1 for update skip locked;
  if v_id is null then return jsonb_build_object('id', null); end if;
  update public.os_varreduras set estado = 'rodando', iniciada_em = now() where id = v_id;
  return jsonb_build_object('id', v_id);
end;
$$;
revoke all on function public.os_varredura_proxima(text) from public, anon, authenticated;
grant execute on function public.os_varredura_proxima(text) to service_role;

-- Fim da volta. p_id nulo (volta agendada, sem varredura pedida) não faz nada.
create or replace function public.os_varredura_fechar(p_id bigint, p_resumo jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v public.os_varreduras%rowtype;
begin
  if not public._os_pode_gravar() then raise exception 'Só a rotina do operador.' using errcode = '42501'; end if;
  if p_id is null then return jsonb_build_object('ok', true, 'varredura', false); end if;
  select * into v from public.os_varreduras where id = p_id for update;
  if not found then return jsonb_build_object('ok', false); end if;
  update public.os_varreduras set
    estado = case when coalesce((p_resumo ->> 'falha')::boolean, false) then 'falhou' else 'terminada' end,
    terminada_em = now(),
    na_fila = (p_resumo ->> 'na_fila')::int, lidas = (p_resumo ->> 'lidas')::int, erros = (p_resumo ->> 'erros')::int,
    mudaram = (select count(distinct l.pedido) from public.os_leituras l
                where l.parceiro_id = v.parceiro_id and l.origem = 'operador' and l.lido_em >= coalesce(v.iniciada_em, v.pedida_em)),
    resumo = p_resumo
  where id = p_id;
  return jsonb_build_object('ok', true, 'varredura', true);
end;
$$;
revoke all on function public.os_varredura_fechar(bigint, jsonb) from public, anon, authenticated;
grant execute on function public.os_varredura_fechar(bigint, jsonb) to service_role;

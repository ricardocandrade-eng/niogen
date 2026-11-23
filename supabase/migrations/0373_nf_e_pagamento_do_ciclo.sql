-- NIOGEN | supabase/migrations/0373_nf_e_pagamento_do_ciclo.sql | 23/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 23/11: "Eu já emiti a nota fiscal" → "Não vem mais um novo extrato. Eles apenas enviam o extrato e essa informação"
-- (mensagem "Comissionamento por PDV" da Nio: pedido, item, valor, conferência da linha a linha e como emitir e enviar a NF).
-- Ou seja: a Nio NÃO devolve o andamento da NF nem do pagamento. O que acontece depois do extrato (NF emitida e enviada, pagamento
-- recebido) só o NIOGEN registra — à mão, por quem emitiu e por quem viu o dinheiro na conta.
--
-- O quê:
--   1. nio_ciclo_nf — uma linha por pedido de compra + item: NF (número, emissão, envio à Nio) e pagamento (data, valor).
--      Tabela própria (não colunas em nio_extrato_pedidos) porque reimportar o extrato troca as linhas do pedido.
--   2. _dias_uteis_somar(data, n) — n dias úteis depois (fim de semana e feriado nacional/MG fora), para a previsão de pagamento.
--   3. ciclo_nf_registrar / ciclo_pagamento_registrar — a única porta (admin/backoffice, com autor e hora). Pago o pedido inteiro do
--      ciclo, cada linha da Nio com venda ganha o lançamento 'pagamento' na razão → v_dinheiro passa a 'paga'.
--   4. v_conciliacao_ciclos — número/data da NF e o pagamento vêm daqui; previsão = envio + 10 dias úteis (contrato); coluna
--      'pedidos' com cada pedido/item para a tela.
--   5. conferencia_itens(): item 34 "NF e pagamento do ciclo" (injetado na versão no ar, como a 0370/0371/0372).
-- Regra 20: (1) sem estado de lead · (2) NF a emitir tem prazo (3 dias do extrato) e NF enviada tem prazo (10 dias úteis), os dois
-- viram atenção/falha na conferência · (3) só por função, com autor · (4) a Nio não informa NF nem pagamento: a fonte passa a ser
-- quem registra (o extrato segue a fonte do valor) · (5) item 33. Parceiro: parceiro_id. Tela Live: sem mudança.
begin;

create table if not exists public.nio_ciclo_nf (
  id                 uuid primary key default gen_random_uuid(),
  parceiro_id        text not null default 'dharma',
  ciclo              text not null,
  documento_compras  text not null,
  item               text not null default '10',
  nf_numero          text,
  nf_emitida_em      date,
  nf_enviada_em      date,
  nf_registrada_por  uuid,
  nf_registrada_em   timestamptz,
  pago_em            date,
  pago_valor         numeric(12, 2),
  pago_registrado_por uuid,
  pago_registrado_em timestamptz,
  obs                text,
  unique (parceiro_id, documento_compras, item)
);
alter table public.nio_ciclo_nf enable row level security;
drop policy if exists nio_ciclo_nf_ler on public.nio_ciclo_nf;
create policy nio_ciclo_nf_ler on public.nio_ciclo_nf for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));
revoke all on public.nio_ciclo_nf from anon, authenticated;
grant select on public.nio_ciclo_nf to authenticated;
grant all on public.nio_ciclo_nf to service_role;
comment on table public.nio_ciclo_nf is
  'NF e pagamento por pedido de compra da Nio (0373). A Nio não devolve esse andamento: registra quem emitiu a NF e quem viu o dinheiro. Grava só ciclo_nf_registrar / ciclo_pagamento_registrar.';

create or replace function public._dias_uteis_somar(p_data date, p_n int)
returns date language plpgsql stable set search_path = public as $$
declare d date := p_data; i int := 0;
begin
  if p_data is null then return null; end if;
  while i < greatest(p_n, 0) loop
    d := public.proximo_dia_util(d, '');
    i := i + 1;
  end loop;
  return d;
end;
$$;

create or replace function public.ciclo_nf_registrar(p_documento text, p_item text, p_numero text, p_emitida_em date, p_enviada_em date default null)
returns void language plpgsql security definer set search_path = public as $$
declare c text;
begin
  if auth.role() is distinct from 'service_role' and coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice registram a NF.' using errcode = '42501';
  end if;
  select ciclo into c from public.nio_extrato_pedidos
   where documento_compras = btrim(p_documento) and coalesce(item, '10') = coalesce(nullif(btrim(p_item), ''), '10') limit 1;
  if c is null then raise exception 'Pedido de compra % não está em nenhum extrato importado.', p_documento; end if;
  if nullif(btrim(coalesce(p_numero, '')), '') is null then raise exception 'Informe o número da NF.'; end if;
  if p_emitida_em is null or p_emitida_em > (now() at time zone 'America/Sao_Paulo')::date then raise exception 'Data de emissão inválida.'; end if;
  if p_enviada_em is not null and (p_enviada_em < p_emitida_em or p_enviada_em > (now() at time zone 'America/Sao_Paulo')::date) then
    raise exception 'O envio à Nio tem de ser entre a emissão e hoje.';
  end if;
  if exists (select 1 from public.nio_ciclo_nf where documento_compras = btrim(p_documento) and item = coalesce(nullif(btrim(p_item), ''), '10') and pago_em is not null) then
    raise exception 'Este pedido já tem pagamento registrado: a NF não muda mais.';
  end if;
  insert into public.nio_ciclo_nf (ciclo, documento_compras, item, nf_numero, nf_emitida_em, nf_enviada_em, nf_registrada_por, nf_registrada_em)
  values (c, btrim(p_documento), coalesce(nullif(btrim(p_item), ''), '10'), btrim(p_numero), p_emitida_em, p_enviada_em, auth.uid(), now())
  on conflict (parceiro_id, documento_compras, item) do update
     set nf_numero = excluded.nf_numero, nf_emitida_em = excluded.nf_emitida_em, nf_enviada_em = excluded.nf_enviada_em,
         nf_registrada_por = excluded.nf_registrada_por, nf_registrada_em = excluded.nf_registrada_em;
end;
$$;
revoke all on function public.ciclo_nf_registrar(text, text, text, date, date) from public, anon;
grant execute on function public.ciclo_nf_registrar(text, text, text, date, date) to authenticated, service_role;

create or replace function public.ciclo_pagamento_registrar(p_documento text, p_item text, p_pago_em date, p_valor numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r   public.nio_ciclo_nf;
  ped numeric;
  n   int := 0;
begin
  if auth.role() is distinct from 'service_role' and coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice registram o pagamento.' using errcode = '42501';
  end if;
  select * into r from public.nio_ciclo_nf where documento_compras = btrim(p_documento) and item = coalesce(nullif(btrim(p_item), ''), '10') for update;
  if r.id is null or r.nf_numero is null then raise exception 'Registre a NF deste pedido antes do pagamento.'; end if;
  if p_pago_em is null or p_pago_em < r.nf_emitida_em or p_pago_em > (now() at time zone 'America/Sao_Paulo')::date then
    raise exception 'Data do pagamento tem de ser entre a emissão da NF e hoje.';
  end if;
  if coalesce(p_valor, 0) <= 0 then raise exception 'Informe o valor que caiu na conta.'; end if;
  update public.nio_ciclo_nf set pago_em = p_pago_em, pago_valor = round(p_valor, 2), pago_registrado_por = auth.uid(), pago_registrado_em = now()
   where id = r.id;
  -- pedido inteiro do ciclo pago → cada linha da Nio com venda vira 'pagamento' na razão (a trilha da venda chega a 'paga')
  if not exists (select 1 from public.nio_extrato_pedidos p
                  where p.ciclo = r.ciclo
                    and not exists (select 1 from public.nio_ciclo_nf x where x.documento_compras = p.documento_compras
                                       and x.item = coalesce(p.item, '10') and x.pago_em is not null)) then
    delete from public.comissao_lancamentos where origem = 'manual' and tipo = 'pagamento' and ciclo = r.ciclo;
    insert into public.comissao_lancamentos (venda_id, tipo, sub, valor, ciclo, data_ref, origem, chave_nio, criado_por)
    select l.venda_id, 'pagamento', l.tipo, l.valor, l.ciclo, p_pago_em, 'manual',
           jsonb_build_object('documento_compras', r.documento_compras, 'nf', r.nf_numero, 'linha', l.chave_nio ->> 'linha'), auth.uid()
      from public.comissao_lancamentos l
     where l.origem = 'extrato' and l.ciclo = r.ciclo and l.venda_id is not null;
    get diagnostics n = row_count;
  end if;
  select sum(valor) into ped from public.nio_extrato_pedidos where documento_compras = r.documento_compras and coalesce(item, '10') = r.item;
  return jsonb_build_object('ciclo', r.ciclo, 'valor_pedido', ped, 'pago', round(p_valor, 2), 'bate', round(coalesce(ped, 0), 2) = round(p_valor, 2),
                            'lancamentos', n);
end;
$$;
revoke all on function public.ciclo_pagamento_registrar(text, text, date, numeric) from public, anon;
grant execute on function public.ciclo_pagamento_registrar(text, text, date, numeric) to authenticated, service_role;

-- a view da 0371 com a NF e o pagamento registrados aqui (colunas novas no fim)
create or replace view public.v_conciliacao_ciclos with (security_invoker = true) as
with p as (
  select p.*, coalesce(p.item, '10') as it, f.nf_numero, f.nf_emitida_em, f.nf_enviada_em, f.pago_em, f.pago_valor
    from public.nio_extrato_pedidos p
    left join public.nio_ciclo_nf f on f.documento_compras = p.documento_compras and f.item = coalesce(p.item, '10') and f.parceiro_id = p.parceiro_id
)
select p.ciclo, max(p.ciclo_nio) as ciclo_nio,
       string_agg(distinct p.documento_compras, ', ')                      as documento_compras,
       sum(p.valor)                                                         as valor_pedido,
       max(coalesce(p.status_ajustado, p.status))                           as status_pedido,
       coalesce(max(p.previsao_pg), public._dias_uteis_somar(max(p.nf_enviada_em), 10)) as previsao_pg,
       case when bool_and(p.pago_em is not null) then max(p.pago_em) else max(p.dt_compensacao) end as dt_compensacao,
       coalesce(string_agg(distinct p.nf_numero, ', '), string_agg(distinct p.numero_nf, ', ')) as numero_nf,
       (select sum(l.valor) from public.comissao_lancamentos l where l.origem = 'extrato' and l.ciclo = p.ciclo) as soma_linhas,
       max(i.criado_em)                                                     as importado_em,
       max(i.arquivo_nome)                                                  as arquivo,
       max(p.nf_emitida_em)                                                 as nf_emitida_em,
       max(p.nf_enviada_em)                                                 as nf_enviada_em,
       sum(p.pago_valor)                                                    as pago_valor,
       jsonb_agg(jsonb_build_object('documento_compras', p.documento_compras, 'item', p.it, 'valor', p.valor, 'nf_numero', p.nf_numero,
                                    'nf_emitida_em', p.nf_emitida_em, 'nf_enviada_em', p.nf_enviada_em, 'pago_em', p.pago_em,
                                    'pago_valor', p.pago_valor, 'previsao_pg', public._dias_uteis_somar(p.nf_enviada_em, 10))
                 order by p.documento_compras, p.it)                        as pedidos
  from p
  left join public.importacoes i on i.id = p.importacao_id
 group by p.ciclo;
revoke all on public.v_conciliacao_ciclos from anon;
grant select on public.v_conciliacao_ciclos to authenticated, service_role;

-- conferência: item 33
do $m$
declare
  d text := pg_get_functiondef('public.conferencia_itens(text)'::regprocedure);
  fim text := E'\n  return it;\nend';
  item text := $x$
  -- 34. 0373 — NF e pagamento do ciclo (a Nio não informa: o NIOGEN cobra)
  select count(*)::int, string_agg(p.ciclo_nio, ', ' order by p.ciclo) into n, ex
    from public.nio_extrato_pedidos p left join public.nio_ciclo_nf f on f.documento_compras = p.documento_compras and f.item = coalesce(p.item, '10')
   where f.nf_numero is null and p.criado_em < now() - interval '3 days';
  select count(*)::int into n2
    from public.nio_ciclo_nf f
   where f.pago_em is null and f.nf_enviada_em is not null
     and public._dias_uteis_somar(f.nf_enviada_em, 10) < (now() at time zone 'America/Sao_Paulo')::date;
  select count(*)::int into v_tot
    from public.nio_ciclo_nf f
   where f.pago_em is not null
     and round(f.pago_valor, 2) <> round((select sum(p.valor) from public.nio_extrato_pedidos p
                                           where p.documento_compras = f.documento_compras and coalesce(p.item, '10') = f.item), 2);
  select count(*)::int into v_soma from public.nio_ciclo_nf f where f.nf_numero is not null and f.nf_enviada_em is null and f.nf_emitida_em < (now() at time zone 'America/Sao_Paulo')::date - 2;
  it := it || jsonb_build_object('codigo', 'ciclo_nf_pagamento', 'nome', 'NF e pagamento do ciclo',
    'nivel', case when v_tot > 0 or n2 > 0 then 'falha' when n > 0 or v_soma > 0 then 'atencao' else 'ok' end,
    'n', n + n2 + v_tot + v_soma,
    'texto', case when n + n2 + v_tot + v_soma = 0
                  then case when exists (select 1 from public.nio_ciclo_nf where pago_em is null) then 'NF registrada e dentro do prazo de pagamento'
                            when exists (select 1 from public.nio_ciclo_nf) then 'todo pedido da Nio com NF e pagamento registrados'
                            else 'nenhum pedido da Nio aguardando NF' end
                  else concat_ws(' · ',
                         case when n > 0 then format('pedido sem NF registrada há mais de 3 dias: %s', ex) end,
                         case when v_soma > 0 then format('%s NF emitida e não marcada como enviada à Nio', v_soma) end,
                         case when n2 > 0 then format('%s pedido(s) com NF enviada há mais de 10 dias úteis e sem pagamento', n2) end,
                         case when v_tot > 0 then format('%s pagamento(s) diferente(s) do valor do pedido', v_tot) end) end,
    'fazer', case when v_tot > 0 then 'Conferir o extrato bancário e cobrar a diferença do Rogério (contestação na Conciliação).'
                  when n2 > 0 then 'Cobrar o Rogério: NF enviada e não paga no prazo (10 dias úteis). Caiu na conta? Registrar o pagamento na Conciliação.'
                  when n > 0 then 'Emitir a NF (dados na mensagem "Comissionamento por PDV" da Nio) e registrar na Conciliação › pé do ciclo.'
                  when v_soma > 0 then 'Enviar a NF à Nio por e-mail e marcar a data de envio na Conciliação.' end);
$x$;
begin
  if position('ciclo_nf_pagamento' in d) > 0 then
    raise notice '0373: o item ciclo_nf_pagamento já existe — nada a fazer';
    return;
  end if;
  if (length(d) - length(replace(d, fim, ''))) / length(fim) <> 1 then
    raise exception '0373: não achei um único "return it;" no fim de conferencia_itens — refazer a migration a partir da versão no ar';
  end if;
  execute replace(d, fim, item || fim);
end $m$;

commit;

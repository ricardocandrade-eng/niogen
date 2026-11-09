-- NIOGEN | supabase/migrations/0078_meta_ads_saldo.sql | 09/11/2026 — Claude Code (Prompt_metaads_card_saldo_081126_1400, item 6 da rodada noturna)
-- Por quê: o Ricardo quer ver na tela Meta Ads o saldo em aberto da CA Nio e quando/quanto a Meta vai cobrar, para não ser pego
--          de surpresa no cartão nem ter a conta parada por pagamento (pedido de 08/11 13h54).
-- O quê (só aditivo):
--   1. meta_ads_conta_saldo (uma linha por conta, parceiro_id): saldo, imposto estimado, limite de cobrança (SEMPRE o último lido da API,
--      nunca config — "isso altera a todo momento", Ricardo 08/11 13h59), próxima cobrança (data) e de onde veio a data (api | config).
--      Leitura: logado com perfil. Escrita: só service_role pela RPC.
--   2. meta_ads_gravar_saldo(p_act, p_conta, p_ciclo): recebe as respostas cruas da Graph API (nós 9/10 do meta_ads_coleta), converte
--      centavos → reais e faz upsert. Sem "balance" na resposta (token sem permissão, erro da Meta): não grava nada e devolve o motivo
--      — a coleta principal nunca falha por causa disso.
--   3. config_meta_ads_regras: meta_cobranca_dia_mensal 13 · meta_imposto_estimado_pct 13.81 · meta_cobranca_alerta_pct 85 ·
--      meta_cobranca_alerta_dias 2. O limite de cobrança NÃO entra em config.

create table if not exists public.meta_ads_conta_saldo (
  act_id               text primary key,
  parceiro_id          text not null default 'dharma',
  moeda                text,
  saldo                numeric not null,
  imposto_estimado     numeric,
  limite_cobranca      numeric,
  proxima_cobranca_em  date,
  fonte_data           text not null default 'config' check (fonte_data in ('api', 'config')),
  gasto_total          numeric,
  coletado_em          timestamptz not null default now()
);
alter table public.meta_ads_conta_saldo enable row level security;
drop policy if exists meta_ads_conta_saldo_ler on public.meta_ads_conta_saldo;
create policy meta_ads_conta_saldo_ler on public.meta_ads_conta_saldo for select to authenticated using (public.meu_perfil() is not null);
revoke all on public.meta_ads_conta_saldo from anon;
grant select on public.meta_ads_conta_saldo to authenticated;

insert into public.config_meta_ads_regras (parceiro_id, chave, valor, descricao) values
  ('dharma', 'meta_cobranca_dia_mensal', 13, 'Card Saldo em aberto: dia do mês da cobrança da Meta, usado só quando a API não traz a data (marcado "config" na tela)'),
  ('dharma', 'meta_imposto_estimado_pct', 13.81, 'Card Saldo em aberto: imposto estimado sobre o saldo (%), quando a API não traz (R$ 10,19 / R$ 73,78 no print de 08/11)'),
  ('dharma', 'meta_cobranca_alerta_pct', 85, 'Card Saldo em aberto pisca quando o saldo passa desta % do limite de cobrança lido da API'),
  ('dharma', 'meta_cobranca_alerta_dias', 2, 'Card Saldo em aberto pisca quando a próxima cobrança está a este número de dias ou menos')
on conflict do nothing;

create or replace function public.meta_ads_gravar_saldo(p_act text, p_conta jsonb, p_ciclo jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_saldo numeric; v_limite numeric; v_gasto numeric; v_pct numeric; v_dia int; v_prox date; v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_ciclo jsonb;
begin
  if p_conta is null or p_conta ? 'error' or not (p_conta ? 'balance') then
    return jsonb_build_object('ok', false, 'motivo', 'sem balance na resposta da Meta', 'erro', p_conta->'error'->>'message');
  end if;
  v_saldo := round((p_conta->>'balance')::numeric / 100, 2);
  v_gasto := case when p_conta ? 'amount_spent' then round((p_conta->>'amount_spent')::numeric / 100, 2) end;
  -- adspaymentcycle: {data:[{threshold_amount, ...}]} — o limite é o do ciclo mais recente; sem leitura fica nulo ("ver no BM").
  v_ciclo := case when jsonb_typeof(p_ciclo->'data') = 'array' then (select x from jsonb_array_elements(p_ciclo->'data') x
                                                                       order by x->>'created_time' desc nulls last limit 1) end;
  v_limite := case when v_ciclo ? 'threshold_amount' then round((v_ciclo->>'threshold_amount')::numeric / 100, 2) end;
  select valor into v_pct from public.config_meta_ads_regras where parceiro_id = 'dharma' and chave = 'meta_imposto_estimado_pct';
  select valor::int into v_dia from public.config_meta_ads_regras where parceiro_id = 'dharma' and chave = 'meta_cobranca_dia_mensal';
  if v_dia between 1 and 28 then
    v_prox := make_date(extract(year from v_hoje)::int, extract(month from v_hoje)::int, v_dia);
    if v_prox < v_hoje then v_prox := (v_prox + interval '1 month')::date; end if;
  end if;
  insert into public.meta_ads_conta_saldo as s (act_id, moeda, saldo, imposto_estimado, limite_cobranca, proxima_cobranca_em, fonte_data, gasto_total, coletado_em)
  values (p_act, p_conta->>'currency', v_saldo, case when v_pct is not null then round(v_saldo * v_pct / 100, 2) end,
          v_limite, v_prox, 'config', v_gasto, now())
  on conflict (act_id) do update set moeda = excluded.moeda, saldo = excluded.saldo, imposto_estimado = excluded.imposto_estimado,
    limite_cobranca = excluded.limite_cobranca, proxima_cobranca_em = excluded.proxima_cobranca_em, fonte_data = excluded.fonte_data,
    gasto_total = excluded.gasto_total, coletado_em = excluded.coletado_em;
  return jsonb_build_object('ok', true, 'saldo', v_saldo, 'limite', v_limite, 'proxima', v_prox, 'ciclo_lido', v_ciclo is not null,
    -- diagnóstico sem dado sensível: por que o limite não veio (mensagem de erro da Meta ou lista vazia)
    'ciclo_erro', p_ciclo->'error'->>'message', 'ciclo_itens', case when jsonb_typeof(p_ciclo->'data') = 'array' then jsonb_array_length(p_ciclo->'data') end,
    'ciclo_campos', case when v_ciclo is not null then (select jsonb_agg(k) from jsonb_object_keys(v_ciclo) k) end);
end $$;
revoke all on function public.meta_ads_gravar_saldo(text, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.meta_ads_gravar_saldo(text, jsonb, jsonb) to service_role;

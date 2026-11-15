-- NIOGEN | supabase/migrations/0222_retrato_caixas_sem_teste.sql | 15/11/2026 — Claude Code (Opus 5.5)
-- Correção da 0221: escada.caixas contava os testes (destino teste_duplicada) e a soma da janela não batia com escada.leads
-- (130 × 116). Agora usa o mesmo recorte da escada (_leads_resumo): sem teste_duplicada. Regra 20: leitura; sem estado novo.
begin;
create or replace function public._agente_trafego_caixas(p_de date)
returns jsonb language sql stable security definer set search_path = public as $$
  with cx(n) as (values (1), (2), (3), (4), (5), (6), (7)),
       l as materialized (select caixa, criado_em from public.v_lead_caixa where destino <> 'teste_duplicada')
  select jsonb_build_object(
    'janela', (select jsonb_object_agg(public._caixa_nome(cx.n), (select count(*) from l where l.caixa = cx.n
                                        and (l.criado_em at time zone 'America/Sao_Paulo')::date >= p_de)) from cx),
    'agora',  (select jsonb_object_agg(public._caixa_nome(cx.n), (select count(*) from l where l.caixa = cx.n)) from cx))
$$;
commit;

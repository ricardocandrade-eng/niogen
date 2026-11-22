-- NIOGEN | supabase/migrations/0358_live_carga.sql | 22/11/2026 — Claude Code (Opus 5.5)
-- Regra 19, debate da Live com o Ricardo (22/11 ~13h, "A + C: uma chamada, pacote menor"): a lista sem o retrato da aba levava
-- 2,1–2,2 s (orçamento ≤ 1,0 s) com o banco gastando ~0,4 s no total — o resto eram 9 idas e voltas a Oregon de uma vez (~0,3 s de
-- piso cada, enfileiradas, disputando a máquina Small). Medido logado e aquecido: jornada_live ~200 ms · live_na_mira 70 ms ·
-- live_conferir 53 ms · v_leads 30 ms · live_situacoes 4 ms · as outras 4 leituras 0–2 ms.
-- O que muda: live_carga() devolve num pacote só as 8 leituras da Live que não são a jornada (a jornada segue à parte: tem cache de
-- 45 s entre abas e o retrato da aba). Mesmas consultas, mesmos filtros e colunas que a fila.html fazia; SECURITY INVOKER — cada
-- leitura passa pelo RLS e pelas funções de sempre, com o perfil de quem chamou. Fora de admin/backoffice devolve null e a tela
-- usa o caminho antigo (as 8 chamadas).
-- "C" (pacote menor): medido e não feito — 231 linhas, ~60 kB por lista, comprimido na rede; o que pesava era a ida e volta.
-- Regra 20: só leitura, nenhum estado. (5) sem conferência nova.
-- Cenário X84 (o pacote é igual às leituras de antes).
begin;

create or replace function public.live_carga()
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare v_eu uuid := auth.uid();
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    return null;
  end if;
  return jsonb_build_object(
    'pendencias', coalesce((select jsonb_agg(to_jsonb(p) order by p.desde) from public.v_andamento_pendencias p), '[]'::jsonb),
    'leads', coalesce((select jsonb_agg(to_jsonb(l)) from (
        select conversa_id, venda_id, etapa, etapa_nome, status_nome, destino, saida_motivo, saida_nome, saida_sub
          from public.v_leads limit 3000) l), '[]'::jsonb),
    'mira', coalesce(public.live_na_mira(), '[]'::jsonb),
    'conferir', coalesce(public.live_conferir(), '[]'::jsonb),
    'os', coalesce((select jsonb_agg(to_jsonb(o)) from (
        select venda_id, estado_nome, status_ordem, status_agendamento, agendamento_data, janela, pendencia, acao, excecao, mudou_em
          from public.v_os_andamento where venda_id is not null) o), '[]'::jsonb),
    'vendas', coalesce((select jsonb_agg(to_jsonb(v)) from (
        select id, nio_os, nio_pedido, comissao_prevista
          from public.v_vendas where status in ('0_qualificado', '1_vendido', '2_aguardando_instalacao')) v), '[]'::jsonb),
    'feitos', (select count(*) from public.porta_sombra s
                where s.por = v_eu
                  and s.em >= (date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo')),
    'situacoes', coalesce(public.live_situacoes(), '[]'::jsonb));
end $$;
revoke all on function public.live_carga() from public, anon;
grant execute on function public.live_carga() to authenticated, service_role;

commit;

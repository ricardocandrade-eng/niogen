-- NIOGEN | supabase/migrations/0281_retomada_recusou_backfill.sql | 18/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 18/11 ("Sim, ligue"): a 0280 liga a Retomada nas Saídas "Recusou · desistiu" e "Recusou" sem motivo daqui para frente;
-- esta liga nas 4 conversas que já estavam assim, dadas pelo time (uma desistiu, uma venda "Desistiu", duas "perdida" sem motivo).
-- Fora: a que o Ricardo pediu para deixar de fora em 17/11 ("Agora não") e as recusas dadas pela própria Mari.
-- Cada uma: _retomada_iniciar (nota no Chatwoot; o D3 sai no próximo tique dentro do horário da Mari). Só liga se ainda vale
-- (sem Retomada aberta, _retomada_nao_liga vazia, Saída de recusa). Regra 20: nenhum estado novo; a Retomada tem fim (D15 + 48 h).
begin;

do $$
declare c public.mari_conversas; n int := 0;
begin
  for c in select * from public.mari_conversas m
            where m.id in ('2ab8c873-59e9-4ae7-8d5e-c61e35ba3ffe', '04f1241c-684f-480d-b554-6de02a04a019',
                           '36dfca57-7649-4ae0-ac6b-262d4ccdcf54', 'b85cfce7-068c-45cc-8ed8-d8e6d00f1424')
              and m.funil_destino = 'recusou' and not coalesce(m.nao_contatar, false)
              and (m.retomada_desde is null or m.retomada_fim_em is not null)
  loop
    if public._retomada_nao_liga(c) is null then
      perform public._retomada_iniciar(c, 'saida_recusou', 'Ricardo (18/11: ligar nos que já estavam em Recusou)');
      n := n + 1;
    end if;
  end loop;
  raise notice 'Retomada ligada em % conversas', n;
end $$;

commit;

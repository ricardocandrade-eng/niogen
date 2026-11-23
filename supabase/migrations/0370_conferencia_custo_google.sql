-- NIOGEN | supabase/migrations/0370_conferencia_custo_google.sql | 23/11/2026 — Claude Code (Opus 5.5)
-- Prompt docs/Prompt_tela_canais_google_ads_231126_1620.md, regra 20.5 ("a conta fecha todo dia") da 0369 (Google Ads no NIOGEN).
-- conferencia_itens(): item 31 "Custo do Google: uma fonte por dia" —
--   · falha: o gasto do Google que o card mostra (v_canal_custo_dia, 30 dias) não bate com a soma das fontes (coletado nos dias com
--     coleta + digitado só nos dias sem coleta);
--   · falha: a coleta já foi ligada (google_ads_conta tem linha) e não roda há mais de 2 h;
--   · atenção: dia com custo digitado E coletado (o digitado já é ignorado; apagar para não confundir).
-- Para não reescrever a função que outra sessão acabou de mexer (0368, item 30), o item é INJETADO na versão que estiver no ar,
-- antes do "return it;" final — a 0370 vale com ou sem a 0368 aplicada. Refazer a 0370 = conferir que o item não existe ainda.
-- Regra 20: (1)–(4) só leitura, sem estado novo · (5) é o próprio item. Tela Live: sem mudança (o Conferir só ganha uma linha).
begin;

do $m$
declare
  d text := pg_get_functiondef('public.conferencia_itens(text)'::regprocedure);
  fim text := E'\n  return it;\nend';
  item text := $x$
  -- 31. 0369/0370 — custo do Google: uma fonte por dia (coleta quando houver; o digitado só nos dias sem coleta)
  select (select round(coalesce(sum(valor), 0) * 100) from public.v_canal_custo_dia
           where canal = 'google_ads' and dia >= (now() at time zone 'America/Sao_Paulo')::date - 30),
         round(((select coalesce(sum(custo), 0) from public.google_ads_diario where dia >= (now() at time zone 'America/Sao_Paulo')::date - 30)
       + (select coalesce(sum(c.valor), 0) from public.canal_custo_dia c
           where c.canal = 'google_ads' and c.dia >= (now() at time zone 'America/Sao_Paulo')::date - 30
             and not exists (select 1 from public.google_ads_diario g where g.dia = c.dia))) * 100),
         (select count(*) from public.canal_custo_dia c
           where c.canal = 'google_ads' and exists (select 1 from public.google_ads_diario g where g.dia = c.dia))::int,
         (select string_agg(to_char(c.dia, 'DD/MM'), ', ' order by c.dia desc) from public.canal_custo_dia c
           where c.canal = 'google_ads' and exists (select 1 from public.google_ads_diario g where g.dia = c.dia))
    into v_tot, v_soma, n, ex;   -- v_tot e v_soma em centavos (são int na função)
  n2 := case when exists (select 1 from public.google_ads_conta)
                  and (select max(coletado_em) from public.google_ads_conta) < now() - interval '2 hours' then 1 else 0 end;
  it := it || jsonb_build_object('codigo', 'google_custo_fonte', 'nome', 'Custo do Google: uma fonte por dia',
    'nivel', case when v_tot <> v_soma or n2 > 0 then 'falha' when n > 0 then 'atencao' else 'ok' end, 'n', n + n2 + case when v_tot <> v_soma then 1 else 0 end,
    'texto', case when v_tot = v_soma and n2 = 0 and n = 0
                  then case when exists (select 1 from public.google_ads_conta) then 'o custo do Google do card bate com a coleta e o digitado; coleta em dia'
                            else 'coleta do Google ainda não ligada: o custo do card é o digitado à mão' end
                  else concat_ws(' · ',
                         case when v_tot <> v_soma then format('o card soma R$ %s e as fontes, R$ %s (30 dias)', round(v_tot / 100.0, 2), round(v_soma / 100.0, 2)) end,
                         case when n2 > 0 then format('a coleta do Google não roda desde %s',
                                                      to_char((select max(coletado_em) from public.google_ads_conta) at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI')) end,
                         case when n > 0 then format('%s dia(s) com custo digitado e coletado: %s (vale o coletado)', n, ex) end) end,
    'fazer', case when v_tot <> v_soma then 'Avisar o Claude Code: o custo do Google está somando errado (é defeito).'
                  when n2 > 0 then 'Ver no n8n o google_ads_coleta (credencial OAuth do Google vencida ou fluxo desligado) e avisar o Claude Code.'
                  when n > 0 then 'Admin: apagar o custo digitado desses dias em Configurações › Canais (o coletado já vale).' end);
$x$;
begin
  if position('google_custo_fonte' in d) > 0 then
    raise notice '0370: o item google_custo_fonte já existe — nada a fazer';
    return;
  end if;
  if (length(d) - length(replace(d, fim, ''))) / length(fim) <> 1 then
    raise exception '0370: não achei um único "return it;" no fim de conferencia_itens — refazer a migration a partir da versão no ar';
  end if;
  if position('v_tot ' in d) = 0 or position('v_soma ' in d) = 0 or position('n2 ' in d) = 0 or position(E'\n  ex ' in d) = 0 then
    raise exception '0370: conferencia_itens não declara mais v_tot, v_soma, n2 ou ex — refazer a migration';
  end if;
  execute replace(d, fim, item || fim);
end $m$;

commit;

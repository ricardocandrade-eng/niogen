-- NIOGEN | supabase/migrations/0441_conferencia_furos_da_live2.sql | 28/11/2026 — Claude Code (Fable 5.2)
-- Pendência "Live 2.0: o que ficou fora da 1ª entrega", item (1): os furos de cobertura da Live 2.0 (cliente esperando há
-- 10 min ou mais, no horário, FORA da fila — live2_furos, 0390) não tinham item na conferência diária (regra 20, item 5:
-- o que cria número novo ganha a sua conferência). Quem prova que "nada ficou de fora" só era visto por quem abria a aba.
-- O que muda: conferencia_itens() ganha o item "live2_furos":
--   falha    há furo ABERTO agora (alguém esperando fora da fila);
--   atenção  houve furo nas últimas 24 h, já fechado — ou a conferência de cobertura não roda há mais de 24 h
--            (ela roda quando alguém abre a Live 2.0; sem rodada, "zero furo" não prova nada);
--   ok       conferência rodou nas últimas 24 h e não achou furo.
-- Medido em 28/11 na produção: live2_furos com 0 linhas desde 25/11 e última rodada às 01h32 (0 esperando, 0 furos).
-- Regra 20: só leitura de live2_furos e live2_cobertura — nenhum estado, vez, prazo ou evento novo; é o item 5 da própria
-- regra. Regra 19: duas contagens em tabelas pequenas dentro de conferencia_itens (medir na cópia antes e depois).
-- Remendo da versão no ar, no padrão da 0435. Cenário X163.
begin;

do $$
declare d text := pg_get_functiondef('public.conferencia_itens'::regproc);
begin
  if position('''live2_furos''' in d) > 0 then return; end if;
  if regexp_count(d, E'\\r?\\n  return it;\\r?\\nend') <> 1 then
    raise exception '0441: conferencia_itens mudou — refazer o item dos furos da Live 2.0 a partir da versão no ar';
  end if;
  d := regexp_replace(d, E'\\r?\\n  return it;\\r?\\nend', E'
  -- 45. 0441 — Live 2.0: cliente esperando FORA da fila (furo de cobertura, 0390) e se a conferência de cobertura está rodando
  select count(*) filter (where f.fechado_em is null)::int,
         string_agg(coalesce(f.nome, ''sem nome'') || '' ('' || to_char(f.visto_em at time zone ''America/Sao_Paulo'', ''DD/MM HH24:MI'') || '')'', '', '' order by f.visto_em desc)
    into n, ex
    from public.live2_furos f
   where f.fechado_em is null or f.visto_em > now() - interval ''24 hours'';
  it := it || (
    select jsonb_build_object(''codigo'', ''live2_furos'', ''nome'', ''Live 2.0: ninguém esperando fora da fila'',
      ''nivel'', case when coalesce(n, 0) > 0 then ''falha''
                      when ex is not null or r.rodada_em is null or r.rodada_em < now() - interval ''24 hours'' then ''atencao''
                      else ''ok'' end,
      ''n'', coalesce(n, 0),
      ''texto'', case when coalesce(n, 0) > 0 then format(''%s cliente(s) esperando resposta fora da fila da Live 2.0: %s'', n, left(ex, 300))
                      when ex is not null then format(''nenhum furo aberto agora; nas últimas 24 h houve: %s'', left(ex, 300))
                      when r.rodada_em is null or r.rodada_em < now() - interval ''24 hours''
                        then ''a conferência de cobertura da Live 2.0 não roda há mais de 24 h (ela roda quando alguém abre a Live 2.0) — sem rodada, "zero furo" não prova nada''
                      else format(''nenhum furo nas últimas 24 h (última conferência %s)'', to_char(r.rodada_em at time zone ''America/Sao_Paulo'', ''DD/MM HH24:MI'')) end,
      ''fazer'', case when coalesce(n, 0) > 0 then ''Abrir a Live 2.0 › 7 dias › Furos, responder o cliente e avisar o Claude Code: a fila deixou alguém de fora.''
                      when ex is not null then ''Avisar o Claude Code: houve cliente fora da fila nas últimas 24 h (já resolvido) — ver por que a fila não o mostrou.''
                      when r.rodada_em is null or r.rodada_em < now() - interval ''24 hours'' then ''Abrir a Live 2.0 uma vez para a conferência de cobertura rodar.''
                      else null end)
      from (select max(c.rodada_em) as rodada_em from public.live2_cobertura c) r);

  return it;
end');
  execute d;
end $$;

commit;

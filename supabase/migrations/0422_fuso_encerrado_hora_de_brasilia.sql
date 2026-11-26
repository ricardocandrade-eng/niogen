-- NIOGEN | supabase/migrations/0422_fuso_encerrado_hora_de_brasilia.sql | 26/11/2026 — Claude Code (Fable 5.2)
-- Ricardo, 26/11/2026: "A ficha tem demorado 10 segundos aproximadamente para abrir, de qualquer cliente" → medido: a leitura
-- v_mari_quadro (dados coletados pela Mari) levava 9,2 s para UMA conversa. Ela avalia a cadência de todas as conversas, e a
-- 0418 (fuso por UF, 26/11 ~14h48) pôs area_fuso() em mari_no_horario, mari_proximo_horario e em 31 pontos da cadência — com
-- usuário logado (RLS) cada chamada de horário foi de ~1 ms para 20–55 ms.
-- Decisão do Ricardo: "Vamos encerrar o fuso e ajustar a janela para 7h-21h. Assim pode manter o toque das 9h e como esses
-- estados praticamente não teremos venda, o impacto e risco é muito pequeno."
-- O que muda:
--   1. mari_no_horario e mari_proximo_horario voltam a calcular em hora de Brasília (o texto da 0214).
--   2. mari_cadencia_avaliar e _retomada_tick voltam ao fuso fixo 'America/Sao_Paulo' e à cidade da conversa (desfaz o item 5
--      da 0418, pelo caminho inverso, sobre a versão no ar).
--   3. config_regras.mari_horario_toques: o valor NÃO muda (9h–21h, hora de Brasília, para todo mundo). A descrição passa a
--      dizer que em AC (−2 h) e em AM, RR, RO, MT e MS (−1 h) isso é 7h–19h e 8h–20h na hora do cliente — janela aceita
--      pelo Ricardo nesses 6 estados: 7h–21h locais.
-- O que fica: as 25 cidades das 6 UFs seguem LIGADAS (345 ativas); config_area.fuso, o trigger, area_fuso(), _cidade_toque(),
--   os dois mapas em config_regras e o item 42 da conferência ficam como dado da UF, sem efeito na hora do toque.
-- Regra 20: (1)–(3) nenhum estado, evento ou gravação de lead — muda só a hora em que o toque sai nos 6 estados (hoje com
--   zero conversas); (4) a janela volta a ter uma fonte só (mari_horario_toques); (5) a conferência da cadência já cobre.
-- Desempenho (regra 19), medido antes: v_mari_quadro de uma conversa 9,2 s; cadência inteira com RLS 8,3 s. Depois: no Diário.
-- Cenário: X142 (reescrito: hora de Brasília em todos os estados).
begin;

-- 1. As duas funções da janela, em hora de Brasília (como na 0214; mesma assinatura) ---------------------------------------------
create or replace function public.mari_no_horario(p_ts timestamp with time zone, p_cidade text default null)
returns boolean language sql stable set search_path to 'public' as $$
  select coalesce(l >= j.abre and l < j.fecha, false)
    from (select p_ts at time zone 'America/Sao_Paulo' as l) x,
         lateral public.mari_janela_toque((x.l)::date, p_cidade) j
$$;

create or replace function public.mari_proximo_horario(p_ts timestamp with time zone, p_cidade text default null)
returns timestamp with time zone language plpgsql stable set search_path to 'public' as $$
declare
  l timestamp := p_ts at time zone 'America/Sao_Paulo';
  j record; i int;
begin
  for i in 0..20 loop
    select * into j from public.mari_janela_toque(l::date + i, p_cidade);
    if j.abre is not null then
      if i = 0 then
        if l < j.fecha then return greatest(l, j.abre) at time zone 'America/Sao_Paulo'; end if;
      else
        return j.abre at time zone 'America/Sao_Paulo';
      end if;
    end if;
  end loop;
  return null;
end;
$$;

-- 2. Cadência e Retomada: de volta ao fuso fixo e à cidade da conversa (inverso do item 5 da 0418) ---------------------------------
do $$
declare d text; f text; k1 int; k2 int;
  a constant text := 'public.area_fuso(public._cidade_toque(c.cidade, c.telefone))';
  b constant text := ', public._cidade_toque(c.cidade, c.telefone))';
begin
  foreach f in array array['mari_cadencia_avaliar', '_retomada_tick'] loop
    d := pg_get_functiondef(('public.' || f)::regproc);
    if position('_cidade_toque' in d) = 0 then continue; end if;   -- já está em hora de Brasília
    k1 := (length(d) - length(replace(d, a, ''))) / length(a);
    k2 := (length(d) - length(replace(d, b, ''))) / length(b);
    if (f = 'mari_cadencia_avaliar' and (k1 <> 18 or k2 <> 13)) or (f = '_retomada_tick' and (k1 <> 2 or k2 <> 1)) then
      raise exception '0422: % mudou desde a 0418 (% fusos, % cidades do DDD) — refazer a partir da versão no ar', f, k1, k2;
    end if;
    d := replace(d, a, '''America/Sao_Paulo''');
    d := replace(d, b, ', c.cidade)');
    if position('_cidade_toque' in d) > 0 or position('area_fuso' in d) > 0 then
      raise exception '0422: sobrou fuso por cidade em %', f;
    end if;
    execute d;
  end loop;
end $$;

-- 3. A regra escrita onde ela mora ------------------------------------------------------------------------------------------------
update public.config_regras
   set descricao = 'Horário dos toques automáticos da Mari e das mensagens da fila, em HORA DE BRASÍLIA para todos os estados. todos_os_dias=true: todo dia, domingo e feriado inclusive, entre abre e fecha (Ricardo, 18/11/2026: "Horário do contrato: 9–21 seg–dom"). false = horário do time (mari_janela_dia). 0422 (Ricardo, 26/11/2026: "encerrar o fuso e ajustar a janela para 7h-21h"): não há mais fuso por cidade — no AC o toque chega 2 h mais cedo (7h–19h locais) e em AM, RR, RO, MT e MS 1 h mais cedo (8h–20h); janela aceita nesses 6 estados: 7h–21h locais.',
       atualizado_em = now()
 where chave = 'mari_horario_toques';

comment on function public.area_fuso(text) is '0418/0422: fuso IANA da cidade (config_area). Desde a 0422 NÃO entra na hora dos toques (tudo em hora de Brasília) — não chamar em função de horário: com RLS custa ~12 ms por chamada.';
comment on function public._cidade_toque(text, text) is '0418/0422: a cidade da conversa ou a cidade de referência do DDD. Sem uso desde a 0422 (toques em hora de Brasília).';
comment on column public.config_area.fuso is '0418: fuso IANA da cidade = o da UF (config_regras.area_fuso_uf). 0422: só informação — os toques saem em hora de Brasília em todos os estados.';

-- 4. Conferência final --------------------------------------------------------------------------------------------------------------
do $$
begin
  -- 01/12/2026 12h00 UTC = 9h em Brasília: dentro para todos, inclusive Cuiabá (8h locais) e Rio Branco (7h locais)
  if not public.mari_no_horario('2026-12-01 12:00+00', 'Juiz de Fora') or not public.mari_no_horario('2026-12-01 12:00+00', 'Cuiabá')
     or not public.mari_no_horario('2026-12-01 12:00+00', 'Rio Branco') or public.mari_no_horario('2026-12-02 00:30+00', 'Cuiabá')
     or public.mari_proximo_horario('2026-12-01 11:00+00', 'Rio Branco') <> '2026-12-01 12:00+00'
     or public.mari_proximo_horario('2026-12-01 11:00+00', 'Juiz de Fora') <> '2026-12-01 12:00+00' then
    raise exception '0422: a janela em hora de Brasília não bateu';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname in ('mari_cadencia_avaliar', '_retomada_tick', 'mari_no_horario', 'mari_proximo_horario')
                and p.prosrc ~ 'area_fuso|_cidade_toque') then
    raise exception '0422: ainda há função de horário com fuso por cidade';
  end if;
  if (select valor ->> 'abre' from public.config_regras where chave = 'mari_horario_toques') <> '09:00'
     or (select valor ->> 'fecha' from public.config_regras where chave = 'mari_horario_toques') <> '21:00' then
    raise exception '0422: mari_horario_toques não é 9h–21h';
  end if;
  if (select count(*) from public.config_area where ativo) <> 345 then
    raise exception '0422: esperava 345 cidades ativas, há %', (select count(*) from public.config_area where ativo);
  end if;
end $$;

commit;

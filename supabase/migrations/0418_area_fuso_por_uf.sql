-- NIOGEN | 0418_area_fuso_por_uf.sql | 26/11/2026 — Claude Code (Opus 5.5)
-- Pedido do Ricardo (26/11/2026, depois da 0417): "Coluna fuso por UF" — a saída escolhida para AC, AM, RR, RO, MT e MS.
-- A janela dos toques (9h–21h, todo dia — cláusula de contrato, config_regras.mari_horario_toques) passa a valer na HORA DO CLIENTE:
--   1. config_area.fuso (IANA), sempre o da UF (mapa em config_regras.area_fuso_uf; trigger preenche na carga e na troca de UF).
--   2. public.area_fuso(cidade): o fuso da cidade (America/Sao_Paulo quando não se sabe).
--   3. public._cidade_toque(cidade, telefone): sem cidade ainda (antes do CEP), o DDD dos 6 estados de outro fuso diz a cidade de
--      referência (config_regras.area_fuso_ddd_cidade: 65/66 Cuiabá, 67 Campo Grande, 68 Rio Branco, 69 Porto Velho, 92/97 Manaus,
--      95 Boa Vista). Qualquer outro DDD segue como hoje (Brasília).
--   4. mari_no_horario e mari_proximo_horario (mesma assinatura) calculam no fuso da cidade. Por elas passam a cadência, a Retomada,
--      a indicação, o aviso da cobertura, os cliques da Fila Vero e o motor da Mari (no_horario do contexto).
--   5. mari_cadencia_avaliar e _retomada_tick: as contas de dia e hora que usavam 'America/Sao_Paulo' direto (dia da instalação,
--      véspera de domingo 10h–16h, "hoje", "amanhã") usam o fuso do cliente, e as chamadas de horário levam a cidade do DDD
--      quando a conversa ainda não tem cidade. Para quem está no fuso de Brasília nada muda (o fuso é o mesmo).
--   6. Conferência item 42: fuso de cada cidade = fuso da UF.
--   7. Liga AC, AM, RR, RO, MT e MS (25 cidades) — o fuso era a única pendência (Ricardo, 26/11/2026).
-- Fica em Brasília, de propósito: horário do time (mari_atendimento_no_horario, time_horario — o time está em Brasília), Fila Vero
--   (só Juiz de Fora hoje: fila_vero_dentro_horario/rodada), painel ao vivo, parceiro (MG) e o relógio que a Mari lê no prompt.
-- Regra 20: (1)–(3) nenhuma gravação de estado de lead — muda só a hora em que o toque sai; (4) fuso é fato da UF, uma fonte
--   (config_regras.area_fuso_uf); (5) item 42.
begin;

-- 1. Mapas (configuração, não código) -------------------------------------------------------------------------------------------
insert into public.config_regras (chave, valor, descricao, parceiro_id) values
  ('area_fuso_uf', '{"AC": "America/Rio_Branco", "AM": "America/Manaus", "RR": "America/Boa_Vista", "RO": "America/Porto_Velho",
                     "MT": "America/Cuiaba", "MS": "America/Campo_Grande"}'::jsonb,
   '0418: fuso de cada UF que não é o de Brasília (as outras ficam em America/Sao_Paulo). Toques 9h–21h na hora do cliente.', 'dharma'),
  ('area_fuso_ddd_cidade', '{"65": "Cuiabá", "66": "Cuiabá", "67": "Campo Grande", "68": "Rio Branco", "69": "Porto Velho",
                             "92": "Manaus", "97": "Manaus", "95": "Boa Vista"}'::jsonb,
   '0418: conversa sem cidade ainda — o DDD dos estados de outro fuso diz a cidade de referência para a janela dos toques.', 'dharma')
on conflict (chave) do update set valor = excluded.valor, descricao = excluded.descricao;

-- 2. Coluna e trigger --------------------------------------------------------------------------------------------------------------
alter table public.config_area add column if not exists fuso text not null default 'America/Sao_Paulo';
comment on column public.config_area.fuso is '0418: fuso IANA da cidade = o da UF (config_regras.area_fuso_uf). Os toques 9h–21h valem nesta hora.';

create or replace function public._area_fuso_uf(p_uf text)
returns text language sql stable set search_path to 'public' as $$
  select coalesce((select valor ->> upper(btrim(p_uf)) from public.config_regras where chave = 'area_fuso_uf'), 'America/Sao_Paulo')
$$;

create or replace function public.config_area_fuso_trg()
returns trigger language plpgsql set search_path to 'public' as $$
begin
  new.fuso := public._area_fuso_uf(new.uf);
  perform now() at time zone new.fuso;   -- fuso inválido no mapa → erro aqui, não no toque
  return new;
end $$;
drop trigger if exists config_area_fuso on public.config_area;
create trigger config_area_fuso before insert or update of uf, fuso on public.config_area
  for each row execute function public.config_area_fuso_trg();

update public.config_area set fuso = public._area_fuso_uf(uf);

-- 3. Fuso da cidade e cidade do DDD ----------------------------------------------------------------------------------------------
create or replace function public.area_fuso(p_cidade text)
returns text language sql stable set search_path to 'public' as $$
  select coalesce((select a.fuso from public.config_area a
                    where a.bairro is null and public.area_norm(a.cidade) = public.area_norm(p_cidade)
                    order by a.ativo desc, a.id limit 1), 'America/Sao_Paulo')
$$;
comment on function public.area_fuso(text) is '0418: fuso IANA da cidade (config_area); America/Sao_Paulo quando a cidade não é conhecida.';

create or replace function public._cidade_toque(p_cidade text, p_telefone text)
returns text language sql stable set search_path to 'public' as $$
  select coalesce(nullif(btrim(p_cidade), ''),
                  (select r.valor ->> substr(t.n, 3, 2)
                     from public.config_regras r, (select public.tel_norm(p_telefone) as n) t
                    where r.chave = 'area_fuso_ddd_cidade' and t.n like '55%' and length(t.n) in (12, 13)))
$$;
comment on function public._cidade_toque(text, text) is '0418: a cidade da conversa ou, sem ela, a cidade de referência do DDD (só os estados de outro fuso).';

-- 4. As duas funções da janela, no fuso da cidade (mesma assinatura) --------------------------------------------------------------
create or replace function public.mari_no_horario(p_ts timestamp with time zone, p_cidade text default null)
returns boolean language sql stable set search_path to 'public' as $$
  select coalesce(l >= j.abre and l < j.fecha, false)
    from (select p_ts at time zone public.area_fuso(p_cidade) as l) x,
         lateral public.mari_janela_toque((x.l)::date, p_cidade) j
$$;

create or replace function public.mari_proximo_horario(p_ts timestamp with time zone, p_cidade text default null)
returns timestamp with time zone language plpgsql stable set search_path to 'public' as $$
declare
  fz text := public.area_fuso(p_cidade);
  l timestamp := p_ts at time zone fz;
  j record; i int;
begin
  for i in 0..20 loop
    select * into j from public.mari_janela_toque(l::date + i, p_cidade);
    if j.abre is not null then
      if i = 0 then
        if l < j.fecha then return greatest(l, j.abre) at time zone fz; end if;
      else
        return j.abre at time zone fz;
      end if;
    end if;
  end loop;
  return null;
end;
$$;

-- 5. Cadência e Retomada: contas de dia/hora no fuso do cliente; cidade do DDD quando a conversa não tem cidade ----------------
do $$
declare d text; k1 int; k2 int;
begin
  -- mari_cadencia_avaliar
  d := pg_get_functiondef('public.mari_cadencia_avaliar'::regproc);
  if position('_cidade_toque' in d) = 0 then
    k1 := (length(d) - length(replace(d, '''America/Sao_Paulo''', ''))) / length('''America/Sao_Paulo''');
    k2 := (length(d) - length(replace(d, ', c.cidade)', ''))) / length(', c.cidade)');
    if k1 <> 18 or k2 <> 13 then
      raise exception '0418: mari_cadencia_avaliar mudou (% fusos fixos, % chamadas com c.cidade; esperado 18 e 13) — refazer a partir da versão no ar', k1, k2;
    end if;
    d := replace(d, '''America/Sao_Paulo''', 'public.area_fuso(public._cidade_toque(c.cidade, c.telefone))');
    d := replace(d, ', c.cidade)', ', public._cidade_toque(c.cidade, c.telefone))');
    execute d;
  end if;
  -- _retomada_tick
  d := pg_get_functiondef('public._retomada_tick'::regproc);
  if position('_cidade_toque' in d) = 0 then
    k1 := (length(d) - length(replace(d, '''America/Sao_Paulo''', ''))) / length('''America/Sao_Paulo''');
    k2 := (length(d) - length(replace(d, ', c.cidade)', ''))) / length(', c.cidade)');
    if k1 <> 2 or k2 <> 1 then
      raise exception '0418: _retomada_tick mudou (% fusos fixos, % chamadas com c.cidade; esperado 2 e 1)', k1, k2;
    end if;
    d := replace(d, '''America/Sao_Paulo''', 'public.area_fuso(public._cidade_toque(c.cidade, c.telefone))');
    d := replace(d, ', c.cidade)', ', public._cidade_toque(c.cidade, c.telefone))');
    execute d;
  end if;
end $$;

-- 6. Conferência: item 42 ------------------------------------------------------------------------------------------------------
do $$
declare d text := pg_get_functiondef('public.conferencia_itens'::regproc);
begin
  if position('''area_fuso''' in d) > 0 then return; end if;
  if regexp_count(d, E'\\r?\\n  return it;\\r?\\nend') <> 1 then
    raise exception '0418: conferencia_itens mudou — refazer o item do fuso a partir da versão no ar';
  end if;
  d := regexp_replace(d, E'\\r?\\n  return it;\\r?\\nend', E'
  -- 42. 0418 — Área: o fuso de cada cidade é o da UF (os toques 9h–21h valem na hora do cliente)
  select count(*)::int, string_agg(a.uf || '' '' || a.cidade || '' ('' || a.fuso || '')'', '', '' order by a.uf, a.cidade) into n, ex
    from public.config_area a where a.fuso is distinct from public._area_fuso_uf(a.uf);
  it := it || jsonb_build_object(''codigo'', ''area_fuso'', ''nome'', ''Área: fuso de cada cidade = fuso da UF'',
    ''nivel'', case when n = 0 then ''ok'' else ''falha'' end, ''n'', n,
    ''texto'', case when n = 0 then format(''%s cidades fora do fuso de Brasília, todas com o fuso da UF'',
                                          (select count(*) from public.config_area where fuso <> ''America/Sao_Paulo''))
                    else format(''%s cidade(s) com fuso diferente do da UF: %s'', n, left(ex, 300)) end,
    ''fazer'', case when n = 0 then null else ''Avisar o Claude Code: corrigir config_area.fuso (o toque pode sair fora das 9h–21h do cliente).'' end);

  return it;
end');
  execute d;
end $$;

-- 7. Liga as 6 UFs --------------------------------------------------------------------------------------------------------------
select public._area_ativar(u, null, true,
         'Fuso resolvido (0418: toques 9h–21h na hora do cliente, coluna fuso por UF — Ricardo, 26/11/2026)', 'migration:0418')
  from unnest(array['AC', 'AM', 'RR', 'RO', 'MT', 'MS']) u;

-- 8. Conferência final ----------------------------------------------------------------------------------------------------------
do $$
begin
  if (select count(*) from public.config_area where ativo) <> 345 then
    raise exception '0418: esperava 345 cidades ativas, há %', (select count(*) from public.config_area where ativo);
  end if;
  if (select count(*) from public.config_area where fuso <> 'America/Sao_Paulo') <> 25 then
    raise exception '0418: esperava 25 cidades fora do fuso de Brasília, há %', (select count(*) from public.config_area where fuso <> 'America/Sao_Paulo');
  end if;
  -- 01/12/2026 12h00 UTC = 9h em Brasília = 8h em Cuiabá = 7h em Rio Branco
  if not public.mari_no_horario('2026-12-01 12:00+00', 'Juiz de Fora') or public.mari_no_horario('2026-12-01 12:00+00', 'Cuiabá')
     or public.mari_no_horario('2026-12-01 13:30+00', 'Rio Branco') or not public.mari_no_horario('2026-12-01 13:00+00', 'Cuiabá')
     or public.mari_proximo_horario('2026-12-01 11:00+00', 'Rio Branco') <> '2026-12-01 14:00+00'
     or public._cidade_toque(null, '5565999990000') <> 'Cuiabá' or public._cidade_toque(null, '5532999990000') is not null then
    raise exception '0418: a janela no fuso do cliente não bateu';
  end if;
  if position('''America/Sao_Paulo''' in pg_get_functiondef('public.mari_cadencia_avaliar'::regproc)) > 0 then
    raise exception '0418: mari_cadencia_avaliar ainda tem fuso fixo';
  end if;
end $$;

commit;

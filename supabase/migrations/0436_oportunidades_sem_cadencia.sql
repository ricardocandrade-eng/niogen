-- NIOGEN | supabase/migrations/0436_oportunidades_sem_cadencia.sql | 27/11/2026 21h59 — Claude Code (Fable 5.2)
-- Ricardo, 27/11: "Pode seguir com a oportunidades_abertas" (regra 19; sobra da lista da memória do banco).
-- Medido: oportunidades_abertas() leva ~2 s na produção (2,3 s às 19h31) e ~1,0–1,2 s na cópia local. O EXPLAIN mostra que
-- ~1,0 s dos 1,15 s é UMA chamada de mari_cadencia_avaliar() — a v_oportunidades lê a v_mari_quadro, que junta a v_mari_cadencia
-- (o motor da cadência avaliando as 240 conversas, uma a uma) só para preencher proximo_passo, proximo_em, pode_enviar, bloqueio,
-- contatos_hoje, contatos_mes e proximo_toque_em. A v_oportunidades NÃO usa nenhuma dessas colunas, e o banco não consegue cortar
-- um LEFT JOIN com função. É o mesmo defeito que a 0354 (22/11) tirou da jornada.
-- O que muda: a v_oportunidades passa a ler a v_mari_quadro_jornada (a v_mari_quadro sem a cadência, criada na 0354) no lugar da
-- v_mari_quadro. Só esse nome muda (definição recriada da que está no ar). O motor da cadência não é tocado; a tela Mari e a
-- cadência seguem lendo a v_mari_quadro.
-- Conferido na cópia: as 19 colunas que a v_oportunidades usa do quadro são idênticas nas duas views (286 linhas, zero
-- diferenças) e a v_oportunidades devolve o mesmo antes e depois.
-- Desempenho, antes → depois (cópia): oportunidades_abertas() 1,19 s · 0,96 s → 0,17 s · 0,12 s · 0,11 s. Plano 11,2 → 10,7 MB.
-- Sistema fechado (regra 20): não cria estado, evento, tabela nem número novo — as cinco regras não se aplicam. Sem parceiro
-- novo (regra 15). Memória (regra 19): a LATERAL da view segue com OFFSET 0 (0432); o X154 continua valendo. Cenário X158, que
-- também cobra que as duas views do quadro não se afastem nas colunas usadas.

begin;

do $$
declare
  v_def  text := pg_get_viewdef('public.v_oportunidades'::regclass, true);
  v_novo text;
  v_opt  text;
begin
  if position('FROM v_mari_quadro_jornada q' in v_def) > 0 and position('FROM v_mari_quadro q' in v_def) = 0 then
    return;   -- já aplicada
  end if;
  if (length(v_def) - length(replace(v_def, 'FROM v_mari_quadro q', ''))) / length('FROM v_mari_quadro q') <> 1 then
    raise exception '0436: "FROM v_mari_quadro q" não aparece uma única vez na v_oportunidades — a view mudou; rever a migration';
  end if;
  -- as colunas que a v_oportunidades usa do quadro têm de existir, com o mesmo tipo, na view sem cadência
  if exists (
    select 1
      from unnest(array['id', 'alertas', 'cidade', 'cluster', 'coluna', 'itens_total', 'itens_validados', 'nome', 'plano_escolhido', 'plano_nome',
                        'segmento', 'teste', 'trava_cliente_nio', 'trava_endereco_nio', 'trava_viabilidade', 'ultima_em', 'ultima_quem', 'venda_id', 'vez']) col
      left join pg_attribute a on a.attrelid = 'public.v_mari_quadro'::regclass and a.attname = col and a.attnum > 0
      left join pg_attribute b on b.attrelid = 'public.v_mari_quadro_jornada'::regclass and b.attname = col and b.attnum > 0
     where a.atttypid is null or b.atttypid is null or a.atttypid <> b.atttypid) then
    raise exception '0436: v_mari_quadro e v_mari_quadro_jornada não têm as mesmas colunas usadas pela v_oportunidades';
  end if;
  v_novo := replace(v_def, 'FROM v_mari_quadro q', 'FROM v_mari_quadro_jornada q');
  select coalesce(' with (' || array_to_string(c.reloptions, ', ') || ')', '') into v_opt
    from pg_class c where c.oid = 'public.v_oportunidades'::regclass;
  execute 'create or replace view public.v_oportunidades' || v_opt || ' as ' || v_novo;
  if pg_get_viewdef('public.v_oportunidades'::regclass, true) ~ 'v_mari_quadro\M(?!_jornada)' then
    raise exception '0436: a v_oportunidades continua lendo a v_mari_quadro';
  end if;
end $$;

comment on view public.v_oportunidades is
  '0436: lê a v_mari_quadro_jornada (quadro da Mari SEM a cadência) — a v_mari_quadro chama mari_cadencia_avaliar() (~1 s para todas as conversas) só para colunas que as oportunidades não usam. Não voltar para a v_mari_quadro; se precisar de coluna da cadência aqui, buscar só ela.';

commit;

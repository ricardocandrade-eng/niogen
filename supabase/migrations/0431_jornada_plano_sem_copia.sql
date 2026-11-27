-- NIOGEN | supabase/migrations/0431_jornada_plano_sem_copia.sql | 27/11/2026 19h06 — Claude Code (Fable 5.2)
-- Ricardo, 27/11: "Niogen com muito erro desse: TypeError: Failed to fetch" → "Só na correção da consulta".
-- O que houve: o Postgres da produção (máquina de 2 GB) ficou sem memória e reiniciou 7 vezes entre 17h33 e 18h55; a cada
-- reinício as telas dão "Failed to fetch" e os fluxos do n8n dão "Service unavailable" (L-462 e L-463 ficaram sem a Mari).
-- Medido na cópia local: só MONTAR O PLANO de "select * from v_jornada" gasta 68 MB, e uma chamada de live2_fila() chega a
-- ~196 MB. Motivo: a v_jornada lê a v_jornada_base e o planejador "abre" a view de baixo dentro da de cima — cada coluna da
-- base (um CASE de centenas de linhas) é copiada inteira em cada lugar em que a de cima a usa. O mesmo acontece dentro da
-- base, entre os blocos conv → sinal → vend → vr.
-- O que muda (só a forma de planejar; nenhuma coluna, regra ou linha muda):
--   1. v_jornada passa a ler "(select * from v_jornada_base offset 0)": a base é calculada uma vez e a de cima lê o resultado.
--   2. v_jornada_base: os blocos conv, sinal, vend e vr viram "AS MATERIALIZED" — cada um é calculado uma vez.
-- Medido na cópia (153 linhas, resultado idêntico linha a linha): plano da v_jornada 68 MB → 23 MB (base 20 → 12 MB),
-- pico de live2_fila() 196 → 130 MB, tempo 180 → 140 ms. Cenário X153.
-- A definição é a que está no banco (pg_get_viewdef), para não trazer de volta texto antigo de migration; cada troca confere
-- que achou exatamente um lugar, e as opções da view (security_invoker) são mantidas. Rodar duas vezes não muda nada.
-- Sistema fechado (regra 20): não cria estado, evento, tabela nem número novo — as cinco regras não se aplicam. Sem parceiro
-- novo (regra 15). Desempenho (regra 19): é o próprio assunto; números acima.

begin;

do $$
declare
  v_def  text;
  v_novo text;
  v_opt  text;
  v_bloco text;
begin
  -- 1) v_jornada_base: blocos calculados uma vez
  v_def := pg_get_viewdef('public.v_jornada_base'::regclass, true);
  v_novo := v_def;
  foreach v_bloco in array array['conv', 'sinal', 'vend', 'vr'] loop
    if position('), ' || v_bloco || ' AS MATERIALIZED (' in v_novo) > 0 then
      continue;
    end if;
    if (length(v_novo) - length(replace(v_novo, '), ' || v_bloco || ' AS (', ''))) / length('), ' || v_bloco || ' AS (') <> 1 then
      raise exception '0431: bloco "%" da v_jornada_base não encontrado uma única vez — a view mudou; rever a migration', v_bloco;
    end if;
    v_novo := replace(v_novo, '), ' || v_bloco || ' AS (', '), ' || v_bloco || ' AS MATERIALIZED (');
  end loop;
  if v_novo <> v_def then
    select coalesce(' with (' || array_to_string(c.reloptions, ', ') || ')', '') into v_opt
      from pg_class c where c.oid = 'public.v_jornada_base'::regclass;
    execute 'create or replace view public.v_jornada_base' || v_opt || ' as ' || v_novo;
  end if;

  -- 2) v_jornada: lê a base já calculada
  v_def := pg_get_viewdef('public.v_jornada'::regclass, true);
  if v_def !~ 'FROM v_jornada_base\s+OFFSET 0\)\s+j' then
    if (length(v_def) - length(replace(v_def, 'FROM v_jornada_base j', ''))) / length('FROM v_jornada_base j') <> 1 then
      raise exception '0431: "FROM v_jornada_base j" não encontrado uma única vez na v_jornada — a view mudou; rever a migration';
    end if;
    v_novo := replace(v_def, 'FROM v_jornada_base j', 'FROM ( SELECT * FROM v_jornada_base OFFSET 0) j');
    select coalesce(' with (' || array_to_string(c.reloptions, ', ') || ')', '') into v_opt
      from pg_class c where c.oid = 'public.v_jornada'::regclass;
    execute 'create or replace view public.v_jornada' || v_opt || ' as ' || v_novo;
  end if;
end $$;

comment on view public.v_jornada is
  '0431: lê a v_jornada_base por subconsulta com OFFSET 0 — a base é calculada uma vez. Sem isso o planejador copia cada coluna da base (CASE de centenas de linhas) em cada uso e o plano gasta 68 MB (27/11/2026: Postgres sem memória). Não tirar o OFFSET 0.';

commit;

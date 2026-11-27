-- NIOGEN | supabase/migrations/0432_views_da_live_plano_sem_copia.sql | 27/11/2026 19h35 — Claude Code (Fable 5.2)
-- Ricardo, 27/11, depois da 0431: "Não é melhor já fazer essa correção? Quero postergar ao máximo novas despesas com upgrade".
-- Continuação da 0431 (Postgres da produção sem memória, "Failed to fetch"). A 0431 tirou a cópia entre v_jornada e
-- v_jornada_base; sobrou a mesma cópia DENTRO das views, nas subconsultas "LATERAL ( SELECT … ) x" encadeadas: o planejador abre
-- cada uma dentro da seguinte e a expressão de cima (um CASE longo) é repetida em cada lugar que a usa.
-- O que muda (só a forma de planejar; nenhuma coluna, regra ou linha muda): toda subconsulta LATERAL das seis views que a Live
-- lê ganha "OFFSET 0" no fim — o Postgres passa a calcular cada uma uma vez por linha, em vez de copiar a expressão.
--   v_leads · v_mari_quadro · v_mari_quadro_jornada · v_jornada_base · v_jornada · v_oportunidades
-- Subconsulta que já termina em LIMIT ou OFFSET 0 fica como está.
-- Medido na cópia local (resultado idêntico linha a linha nas seis views):
--   plano da v_leads 14,5 → 3,6 MB · v_jornada 23 → 17 MB (68 antes da 0431) · v_jornada_base 12 → 10 MB
--   pico de live2_fila() 130 → 105 MB (196 antes da 0431) · live_conferir() 66 → 49 MB · v_leads 15 → 8 ms
-- A definição é a que está no banco (pg_get_viewdef); as opções de cada view (security_invoker) são mantidas; rodar duas
-- vezes não muda nada. Cenário X154.
-- Sistema fechado (regra 20): não cria estado, evento, tabela nem número novo — as cinco regras não se aplicam. Sem parceiro
-- novo (regra 15). Desempenho (regra 19): é o próprio assunto; números acima.

begin;

-- põe "OFFSET 0" antes do parêntese que fecha cada "… LATERAL ( SELECT …" (inclusive as de dentro)
create function pg_temp._lateral_offset0(p_def text) returns text
language plpgsql as $f$
declare
  v_out  text := p_def;
  v_pos  int := 1;       -- de onde procurar a próxima LATERAL
  v_rel  int;
  v_a    int;            -- posição do "(" da subconsulta
  v_b    int;            -- posição do ")" que casa
  v_n    int;
  v_k    int;
  v_ch   text;
  v_str  boolean;
  v_len  int;
begin
  loop
    v_rel := position('LATERAL ( SELECT' in substr(v_out, v_pos));
    exit when v_rel = 0;
    v_a := v_pos + v_rel - 1 + length('LATERAL ');
    -- acha o ")" que casa, pulando o que está entre aspas simples
    v_n := 0; v_k := v_a; v_str := false; v_b := 0; v_len := length(v_out);
    while v_k <= v_len loop
      v_ch := substr(v_out, v_k, 1);
      if v_str then
        if v_ch = '''' then
          if substr(v_out, v_k + 1, 1) = '''' then v_k := v_k + 1; else v_str := false; end if;
        end if;
      elsif v_ch = '''' then v_str := true;
      elsif v_ch = '(' then v_n := v_n + 1;
      elsif v_ch = ')' then
        v_n := v_n - 1;
        if v_n = 0 then v_b := v_k; exit; end if;
      end if;
      v_k := v_k + 1;
    end loop;
    if v_b = 0 then
      raise exception '0432: parêntese sem par na definição da view';
    end if;
    if substr(v_out, v_a, v_b - v_a) !~ '(LIMIT \d+|OFFSET 0)\s*$' then
      v_out := substr(v_out, 1, v_b - 1) || E'\n OFFSET 0' || substr(v_out, v_b);
    end if;
    v_pos := v_a + 1;
  end loop;
  return v_out;
end $f$;

do $$
declare
  v_view text;
  v_def  text;
  v_novo text;
  v_opt  text;
begin
  -- de baixo para cima: quem é lida primeiro, depois quem a lê
  foreach v_view in array array['v_leads', 'v_mari_quadro', 'v_mari_quadro_jornada', 'v_jornada_base', 'v_jornada', 'v_oportunidades'] loop
    v_def := pg_get_viewdef(('public.' || v_view)::regclass, true);
    v_novo := pg_temp._lateral_offset0(v_def);
    if v_novo <> v_def then
      select coalesce(' with (' || array_to_string(c.reloptions, ', ') || ')', '') into v_opt
        from pg_class c where c.oid = ('public.' || v_view)::regclass;
      execute 'create or replace view public.' || v_view || v_opt || ' as ' || v_novo;
    end if;
  end loop;
  -- a 0431 tem de continuar de pé
  if pg_get_viewdef('public.v_jornada'::regclass, true) !~ 'FROM v_jornada_base\s+OFFSET 0\)\s+j' then
    raise exception '0432: a v_jornada perdeu o OFFSET 0 da 0431';
  end if;
end $$;

drop function pg_temp._lateral_offset0(text);

commit;

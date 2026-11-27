-- NIOGEN | supabase/migrations/0434_live2_fila_conferencia_antes.sql | 27/11/2026 20h18 — Claude Code (Fable 5.2)
-- Ricardo, 27/11: "Pode seguir com a segunda etapa nas funções" (depois de "Quero postergar ao máximo novas despesas com upgrade").
-- Terceira parte do conserto da memória do Postgres (0431 e 0432 cuidaram das views).
-- Medido na cópia depois da 0432: uma chamada de live2_fila() ainda chegava a 105 MB. O plano da consulta principal gasta 28 MB e
-- o da live_conferir() 18 MB — o resto é EMPILHAMENTO: a fila chamava live_conferir() e _live2_reforco() de dentro da própria
-- consulta, então a memória das três ficava de pé ao mesmo tempo. (Pôr OFFSET 0 nas LATERAL das funções não muda nada: medido.)
-- O que muda: live2_fila() calcula a conferência e o reforço ANTES, cada um no seu comando, guarda em variável e a consulta
-- principal lê a variável. São as mesmas funções, chamadas uma vez cada, no mesmo retrato do banco (a função é STABLE) — o
-- resultado é idêntico (comparado na cópia, tirando só o carimbo de hora).
-- Medido na cópia: pico de live2_fila() 105 → 73 MB (196 antes da 0431); fila + jornada + oportunidades na mesma conexão: 73 MB.
-- Remendo sobre a definição que está no banco (pg_get_functiondef), com cada troca conferindo que achou um lugar só; rodar duas
-- vezes não muda nada. live2_fila não é função da porta em sombra (só lê). Cenário X156.
-- Sistema fechado (regra 20): não cria estado, evento, tabela nem número novo — as cinco regras não se aplicam. Sem parceiro
-- novo (regra 15). Desempenho (regra 19): é o próprio assunto; tempo na cópia 350 → 380 ms (dentro da variação).

begin;

do $$
declare
  v_oid oid := 'public.live2_fila()'::regprocedure;
  v_def text := pg_get_functiondef(v_oid);
  v_novo text;
  -- conta quantas vezes um trecho aparece
  v_n int;
  v_troca text[];
  v_trocas text[][] := array[
    -- [ o que procurar , pelo que trocar ]
    ['v_res   jsonb;',
     'v_res   jsonb;' || E'\n' || '  v_conf  jsonb;   -- 0434: a conferência, calculada antes da consulta principal' || E'\n' || '  v_ref   jsonb;   -- 0434: o reforço, idem'],
    ['with j as materialized (',
     '-- 0434: conferência e reforço saem ANTES, cada um no seu comando — dentro da consulta a memória das três empilhava (27/11/2026)' || E'\n' ||
     '  v_conf := coalesce(public.live_conferir(), ''[]''::jsonb);' || E'\n' ||
     '  v_ref := coalesce(public._live2_reforco(), ''[]''::jsonb);' || E'\n\n' ||
     '  with j as materialized ('],
    ['jsonb_to_recordset(coalesce(public.live_conferir(), ''[]''::jsonb))', 'jsonb_to_recordset(v_conf)'],
    ['coalesce(public._live2_reforco(), ''[]''::jsonb),', 'v_ref,']
  ];
begin
  if position('v_conf := coalesce(public.live_conferir()' in v_def) > 0 then
    return;   -- já aplicada
  end if;
  v_novo := v_def;
  foreach v_troca slice 1 in array v_trocas loop
    v_n := (length(v_novo) - length(replace(v_novo, v_troca[1], ''))) / length(v_troca[1]);
    if v_n <> 1 then
      raise exception '0434: trecho "%" aparece % vez(es) na live2_fila (esperado 1) — a função mudou; rever a migration', v_troca[1], v_n;
    end if;
    v_novo := replace(v_novo, v_troca[1], v_troca[2]);
  end loop;
  execute v_novo;
  -- conferência do remendo: as duas chamadas saíram de dentro da consulta
  if (select prosrc from pg_proc where oid = v_oid) ~ 'jsonb_to_recordset\(coalesce\(public\.live_conferir\(\)' then
    raise exception '0434: a live_conferir() continua dentro da consulta';
  end if;
end $$;

commit;

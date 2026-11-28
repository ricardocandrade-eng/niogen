-- NIOGEN | supabase/migrations/0442_fila_vero_espera_nao_e_sem_caixa.sql | 28/11/2026 — Claude Code (Fable 5.2)
-- Ricardo, 28/11 (print da tela da Mari com 6 leads em "Sem caixa: ninguém vai falar com o cliente"): "todos sem cadência ligada
-- e com a conversa aberta, sem saída. Acredito que isso seja um furo, não?" → "Sim, corrigir".
-- O que houve: os 6 são da Fila Vero — clicaram na oferta, receberam o template da Mari e nunca escreveram (a janela de 24 h não
-- abriu, por isso não há cadência). Eles TÊM saída: Saída "Sem resposta" automática 2 dias depois do template, do Enviei ou da
-- data do Adiar (fila_vero_clique_encerrar, 0285/0426), e depois dela a Retomada. Mas a caixa da v_jornada só conhece três
-- esperas (cliente escreveu por último · próximo toque da cadência · Retomada aberta) e jogava esse grupo na caixa 5, com o
-- alarme e "precisa de ação hoje". Na Live 2.0 isso virava tarefa "decidir" para um lead que já estava tratado.
-- O que muda (só a v_jornada; nenhuma coluna nova):
--   1. bloco novo "fve": a data da Saída automática do lead da Fila Vero que clicou e não escreveu — a MESMA conta e as mesmas
--      condições de fila_vero_clique_encerrar (prazos em config_regras: fila_vero_clique.sem_resposta_dias, fila_vero_fora.dias).
--   2. caixa: com essa data no futuro (ou vencida há menos de 1 h) o lead é caixa 1 (Mari conduzindo), não 5.
--      Vencida há mais de 1 h e o lead ainda aqui = a Saída automática não rodou → volta a ser caixa 5, com o alarme (regra 20).
--   3. texto e nível: "Fila Vero: clicou na oferta e não respondeu · chamar por fora pela Live 2.0 | chamado por fora em DD/MM ·
--      sai sozinho em DD/MM HH:MI se não responder", nível "espera".
-- Efeito na Live 2.0 (live2_fila lê a caixa): esse lead deixa de entrar como tarefa "decidir"; o cartão "Chamar por fora"
-- (fonte própria, 1 h depois do template) não muda; no radar ele conta em "com a Mari".
-- A definição é a que está no banco (pg_get_viewdef), no padrão da 0431; cada troca confere que achou exatamente um lugar.
-- Rodar duas vezes não muda nada. O OFFSET 0 da 0431 é mantido, e o bloco novo fecha com LIMIT 1 (regra 19, memória).
-- Sistema fechado (regra 20): (1) etapa, situação, vez e prazo não mudam — o prazo é a Saída automática, agora escrita na tela;
-- (2) saída automática já existe, e o alarme volta se ela falhar; (3) nenhum estado gravado; (4) fonte única: fila_vero e
-- config_regras, as mesmas da função que dá a Saída; (5) conferência: não cria estado nem número novo — o guarda é o próprio
-- alarme da caixa 5. Regra 15: prazos em config. Cenário X164.
begin;

do $mig$
declare
  v_def  text;
  v_novo text;
  v_opt  text;
begin
  v_def := pg_get_viewdef('public.v_jornada'::regclass, true);
  if position(' fve ON true' in v_def) > 0 then
    return;
  end if;
  v_novo := v_def;

  -- 1) o bloco da espera da Fila Vero, antes do bloco da caixa
  if regexp_count(v_novo, 'CROSS JOIN LATERAL \( SELECT\s+CASE\s+WHEN j\.precisa_acao OR a\.usa OR COALESCE\(p\.sobe, false\) THEN 2') <> 1 then
    raise exception '0442: bloco da caixa (cx) não encontrado uma única vez na v_jornada — a view mudou; rever a migration';
  end if;
  v_novo := regexp_replace(v_novo,
    '(CROSS JOIN LATERAL \( SELECT\s+CASE\s+WHEN j\.precisa_acao OR a\.usa OR COALESCE\(p\.sobe, false\) THEN 2)',
    $t$LEFT JOIN LATERAL ( SELECT GREATEST(fv.clique_msg_em + make_interval(days => fc.d_clique), fv.fora_enviado_em + make_interval(days => fc.d_fora), mc.espera_ate + make_interval(days => fc.d_fora)) AS sai_em,
            fv.fora_enviado_em
           FROM fila_vero fv
             CROSS JOIN ( SELECT COALESCE(((( SELECT r1.valor FROM config_regras r1 WHERE r1.chave = 'fila_vero_clique'::text)) ->> 'sem_resposta_dias'::text)::integer, 2) AS d_clique,
                    GREATEST(COALESCE(((( SELECT r2.valor FROM config_regras r2 WHERE r2.chave = 'fila_vero_fora'::text)) ->> 'dias'::text)::integer, 2), 1) AS d_fora) fc
          WHERE fv.conversa_id = mc.id AND fv.clique_msg_em IS NOT NULL AND fv.respondeu_em IS NULL
            AND NOT (EXISTS ( SELECT 1 FROM mari_turnos t WHERE t.conversa_id = mc.id AND t.papel = 'lead'::text))
          ORDER BY fv.clique_msg_em DESC
         LIMIT 1) fve ON true
     \1$t$);

  -- 2) a caixa: espera da Fila Vero com a Saída automática marcada = Mari conduzindo
  if regexp_count(v_novo, 'ELSE 5\s+END AS n') <> 1 then
    raise exception '0442: "ELSE 5 END AS n" não encontrado uma única vez na v_jornada — a view mudou; rever a migration';
  end if;
  v_novo := regexp_replace(v_novo, 'ELSE 5(\s+END AS n)',
    $t$WHEN fve.sai_em > (now() - '01:00:00'::interval) THEN 1
                    ELSE 5\1$t$);

  -- 3) nível e texto
  if regexp_count(v_novo, $t$WHEN cx\.n = 5 THEN 'hoje'::text$t$) <> 1
     or regexp_count(v_novo, $t$WHEN cx\.n = 5 THEN 'Sem caixa: $t$) <> 1 then
    raise exception '0442: nível ou texto da caixa 5 não encontrado uma única vez na v_jornada — a view mudou; rever a migration';
  end if;
  v_novo := replace(v_novo, $t$WHEN cx.n = 5 THEN 'hoje'::text$t$,
    $t$WHEN cx.n = 1 AND fve.sai_em IS NOT NULL THEN 'espera'::text
            WHEN cx.n = 5 THEN 'hoje'::text$t$);
  v_novo := replace(v_novo, $t$WHEN cx.n = 5 THEN 'Sem caixa: $t$,
    $t$WHEN cx.n = 1 AND fve.sai_em IS NOT NULL THEN ('Fila Vero: clicou na oferta e não respondeu · '::text ||
                CASE
                    WHEN fve.fora_enviado_em IS NOT NULL THEN 'chamado por fora em '::text || to_char((fve.fora_enviado_em AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text)
                    ELSE 'chamar por fora pela Live 2.0'::text
                END) || ' · sai sozinho em '::text || to_char((fve.sai_em AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM HH24:MI'::text) || ' se não responder'::text
            WHEN cx.n = 5 THEN 'Sem caixa: $t$);

  select coalesce(' with (' || array_to_string(c.reloptions, ', ') || ')', '') into v_opt
    from pg_class c where c.oid = 'public.v_jornada'::regclass;
  execute 'create or replace view public.v_jornada' || v_opt || ' as ' || v_novo;
end $mig$;

comment on view public.v_jornada is
  '0431: lê a v_jornada_base por subconsulta com OFFSET 0 — a base é calculada uma vez. Sem isso o planejador copia cada coluna da base (CASE de centenas de linhas) em cada uso e o plano gasta 68 MB (27/11/2026: Postgres sem memória). Não tirar o OFFSET 0. · 0442: bloco fve = data da Saída automática do lead da Fila Vero que clicou e não escreveu (mesma conta de fila_vero_clique_encerrar); com ela marcada o lead é caixa 1, não 5; vencida há mais de 1 h, o alarme da caixa 5 volta.';

commit;

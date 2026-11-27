-- NIOGEN | supabase/migrations/0429_live2_venda_tratada_sai_da_fila.sql | 27/11/2026 — Claude Code (Fable 5.2)
-- Ricardo, 27/11: "Tela Live 2.0 — Os dois clientes foram tratados já e não tem saída da Live" → "Os 4".
-- Casos: L-449 (o time respondeu e marcou "sem viabilidade"; a venda continuou como "Responder", urgente, sem saída no cartão),
-- L-82 (espera um pedido de outra revenda; o Adiar de 24 h trazia a venda de volta todo dia) e L-70 (🔥 "Quase pronto: 9/9
-- dados" com o crédito negado).
-- O que muda:
--  (1) live2_fila(): venda SEM pedido na Nio, com "sem viabilidade" gravado À MÃO pelo time e sem cliente esperando resposta
--      vira Decidir, sem urgência, com o botão principal "Registrar a Saída" já no motivo Fachada não atendida. "Sem viabilidade"
--      lido pelo robô não entra aqui: o time ainda confere à mão. O cliente escreveu → volta a ser Responder.
--  (2) live2_fila(): o Adiar passa a valer para a linha Decidir que nasce de "time agora" (recusa do cliente, 0398, e este caso).
--      Antes o botão aparecia, gravava a baixa e a linha não saía da fila, porque a origem dela era "responder".
--  (3) config_regras.live2_pesos.pausa_max_dias = 30 (era 7): o Adiar da linha de venda aceita data. Continua com data de volta
--      e continua voltando na hora se o cliente escrever.
--  (4) v_oportunidades: O4 (Quase pronto) e O5 (Viabilidade ok + endereço livre) não contam conversa com crédito negado.
-- A Saída de venda no próprio cartão é só tela (live2.html): usa o mesmo formulário da ficha e a mesma lead_sair.
-- Regra 20: (1) etapa, situação, vez e prazo não mudam — muda só como a fila MOSTRA a tarefa; (2) ninguém parado em silêncio:
-- a linha continua na fila até a Saída ou até a data do Adiar, que tem teto (30 dias) e volta sozinha; (3) nenhum estado novo:
-- a Saída é a lead_sair de sempre, o Adiar é a live2_baixa de sempre; (4) fonte única: vendas.nio_viab_resultado/origem;
-- (5) conferência: sem item novo — não há estado, tabela nem número novo. Regra 15: o teto do Adiar é config.
-- Regras de ouro 2 e 10: nenhum evento novo na porta. live2_fila e v_oportunidades são remendadas da versão no ar.
-- Cenário X151.
begin;

-- ───────────── (3) o teto do Adiar ─────────────
update public.config_regras
   set valor = jsonb_set(coalesce(valor, '{}'::jsonb), '{pausa_max_dias}', '30'::jsonb)
 where chave = 'live2_pesos';

-- ───────────── (1) e (2) a fila única (remendo da live2_fila no ar) ─────────────
do $mig$
declare
  d  text := pg_get_functiondef('public.live2_fila()'::regprocedure);
  nl text := E'\n';
begin
  if position('semviab' in d) > 0 then
    raise notice '0429: live2_fila já trata a venda sem viabilidade';
    return;
  end if;
  if regexp_count(d, E' as recusa,\\r?\\n') <> 1
     or regexp_count(d, E'p\\.risco, p\\.risco_tipo\\r?\\n      from pes1 p\\r?\\n') <> 1
     or regexp_count(d, E'p\\.tipo <> ''responder'' and p\\.baixa_ate is not null') <> 1
     or regexp_count(d, E'when o\\.recusa then ''decidir''\\r?\\n') <> 1
     or regexp_count(d, E'''DD/MM HH24:MI''\\)\\) else o\\.oque end as oque,') <> 1
     or regexp_count(d, E'case when o\\.recusa then (1|coalesce)') <> 3
     or regexp_count(d, E'or o\\.recusa or o\\.risco\\)') <> 1
     or regexp_count(d, E'o\\.cobranca, o\\.recusa, o\\.risco,\\r?\\n') <> 1
     or regexp_count(d, E'''principal'', true\\)\\) else ''\\[\\]''::jsonb end \\|\\|\\r?\\n\\s+case when o\\.cobranca then') <> 1 then
    raise exception '0429: não achei os pontos de encaixe em live2_fila';
  end if;

  -- pes1a: a marca. Venda sem pedido, "sem viabilidade" gravado à mão pelo time, e o cliente não está esperando resposta.
  d := regexp_replace(d, E'( as recusa,)(\\r?\\n)',
    E'\\1\\2' ||
    $ins$           -- 0429: venda sem pedido na Nio, "sem viabilidade" marcado à mão pelo time, e o cliente não espera resposta → decidir a Saída
           coalesce(p.vend is not null and not coalesce(x.ult_lead > x.ult_time, false)
                    and exists (select 1 from public.vendas v0 where v0.id = p.vend and v0.status = '0_qualificado'
                                   and v0.nio_viab_resultado = 'sem_viabilidade' and v0.nio_viab_origem = 'manual'
                                   and coalesce(btrim(v0.nio_pedido), '') = ''), false) as semviab,$ins$ || nl);

  -- pes2: leva a marca adiante
  d := regexp_replace(d, E'(p\\.risco, p\\.risco_tipo)(\\r?\\n      from pes1 p\\r?\\n)', E'\\1, p.semviab\\2');

  -- pes2: o Adiar vale para a linha Decidir que nasce de "time agora" (recusa e sem viabilidade) — nunca com cliente esperando
  d := replace(d, $a$p.tipo <> 'responder' and p.baixa_ate is not null$a$,
                  $b$(p.tipo <> 'responder' or ((p.recusa or p.semviab) and not coalesce(p.ult_lead > p.ult_time, false))) and p.baixa_ate is not null$b$);

  -- linhas: tipo, texto, urgência, motivos e a marca
  d := regexp_replace(d, E'(when o\\.recusa then ''decidir'')(\\r?\\n)',
    E'\\1\\2' || $ins$                when o.semviab then 'decidir'$ins$ || nl);
  d := replace(d, $a$'DD/MM HH24:MI')) else o.oque end as oque,$a$,
    $b$'DD/MM HH24:MI'))
                when o.semviab then 'Sem viabilidade no portal (marcado pelo time) · registrar a Saída, ou adiar com data se pediu o cadastro da fachada à Nio'
                else o.oque end as oque,$b$);
  d := regexp_replace(d, E'case when o\\.recusa then (1|coalesce)', E'case when o.recusa or o.semviab then \\1', 'g');
  d := replace(d, $a$or o.recusa or o.risco)$a$, $b$or o.recusa or o.risco or o.semviab)$b$);
  d := regexp_replace(d, E'(o\\.cobranca, o\\.recusa, o\\.risco,)(\\r?\\n)', E'\\1 o.semviab,\\2');

  -- linhas: o botão principal
  d := regexp_replace(d, E'(''principal'', true\\)\\) else ''\\[\\]''::jsonb end \\|\\|)(\\r?\\n)(\\s+case when o\\.cobranca then)',
    E'\\1\\2' ||
    $ins$           case when o.semviab and not o.recusa
                then jsonb_build_array(jsonb_build_object('a', 'saida', 'rotulo', 'Registrar a Saída', 'principal', true, 'pre', 'fachada_nao_atendida'))
                else '[]'::jsonb end ||$ins$ || E'\\2\\3');
  execute d;
end $mig$;

-- ───────────── (4) 🔥 Quase pronto e Viabilidade ok: não com crédito negado (remendo da view no ar) ─────────────
do $mig$
declare
  d   text := pg_get_viewdef('public.v_oportunidades'::regclass, true);
  cnd text := $c$NOT (EXISTS ( SELECT 1 FROM mari_conversas mcn WHERE mcn.id = b.conversa_id AND mcn.credito_resultado ~ '^negado')) AND $c$;
begin
  if position('mcn.credito_resultado' in d) > 0 then
    raise notice '0429: v_oportunidades já deixa o crédito negado fora da O4 e da O5';
    return;
  end if;
  if regexp_count(d, E'WHEN ''O4''::text THEN b\\.itens_validados >= ') <> 1
     or regexp_count(d, E'WHEN ''O5''::text THEN b\\.trava_viabilidade = ') <> 1 then
    raise exception '0429: não achei as regras O4 e O5 em v_oportunidades';
  end if;
  d := replace(d, $a$WHEN 'O4'::text THEN b.itens_validados >= $a$, $b$WHEN 'O4'::text THEN $b$ || cnd || $e$b.itens_validados >= $e$);
  d := replace(d, $a$WHEN 'O5'::text THEN b.trava_viabilidade = $a$, $b$WHEN 'O5'::text THEN $b$ || cnd || $e$b.trava_viabilidade = $e$);
  execute 'create or replace view public.v_oportunidades with (security_invoker = true) as ' || d;
end $mig$;

commit;

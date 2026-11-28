-- NIOGEN | supabase/migrations/0437_reforco_travou_e_cidade_do_cadastro.sql | 27/11/2026 — Claude Code (Fable 5.2)
-- Ricardo, 27/11, caso L-456: "Pelas regras tudo bem, não deveria ir para Live. Mas estou pensando se nesses casos eles não
-- deveriam ter ido pra Live, nem que seja para a aba Reforço." → "Sim, os dois, mas precisa consertar a Mari também."
-- O caso: lead da Fila Vero (cadastro: Juiz de Fora) respondeu "Rua das perolas ,Marilândia" ao pedido de rua e bairro. A Mari
-- não tinha cidade de partida para a busca de rua (só lead de anúncio tinha), recebeu "rua sem cidade", tomou o bairro por um
-- município do Espírito Santo e o cliente parou de responder. Nenhum sinal do Reforço cobre quem trava antes do CEP.
-- O que muda:
--  (1) _live2_reforco(): sinal novo "travou" — conversa com a Mari, janela de 24 h aberta, SEM CEP, o cliente já escreveu algo
--      além da 1ª mensagem e dos botões (≥ travou_letras letras), a Mari falou por último e o cliente está calado há ≥ travou_min.
--      É o último na ordem (depois de escorregou, objeção, quente, pronto e sumiu). Medido em 27/11: ~2 conversas por dia.
--  (2) mari_contexto(): devolve "cidade_cadastro" — a cidade do cadastro da Fila Vero do lead — só quando a conversa veio da
--      Fila Vero e ainda não tem cidade. O nó 4 · Preparar usa como cidade de partida da busca de rua (a Mari confirma rua,
--      bairro e CEP com o cliente, como em toda busca).
-- Regra 20: (1) etapa, situação, vez e prazo não mudam — Reforço não é tarefa; (2) ninguém parado em silêncio: é justamente o
-- que o sinal mostra, e a cadência da Mari segue igual; (3) nenhum estado novo — Soprar e Assumir são os de sempre; (4) fonte
-- única: a conversa (mari_turnos) e o cadastro (fila_vero.cidade); (5) conferência: sem item novo — não há estado nem número
-- novo; o desfecho do sinal entra em reforco_resultado como os outros. Regra 15: os dois limiares são config (reforco_sinais).
-- Regras de ouro 2 e 10: nenhum evento novo na porta. As duas funções são remendadas da versão no ar. Cenário X159.
begin;

update public.config_regras
   set valor = coalesce(valor, '{}'::jsonb) || jsonb_build_object('travou_min', 20, 'travou_letras', 12)
 where chave = 'reforco_sinais' and not (coalesce(valor, '{}'::jsonb) ? 'travou_min');

create index if not exists fila_vero_conversa_idx on public.fila_vero (conversa_id) where conversa_id is not null;

-- ───────────── (1) o sinal "travou" (remendo da _live2_reforco no ar) ─────────────
do $mig$
declare
  d  text := pg_get_functiondef('public._live2_reforco()'::regprocedure);
  nl text := E'\n';
begin
  if position('s_travou' in d) > 0 then
    raise notice '0437: _live2_reforco já tem o sinal travou';
    return;
  end if;
  if regexp_count(d, E'c\\.dados, c\\.ultima_msg_lead_at, c\\.ultima_msg_mari_at,\\r?\\n') <> 1
     or regexp_count(d, E'''sumiu_max_min''\\)::int, 180\\)\\)\\) as s_sumiu\\r?\\n') <> 1
     or regexp_count(d, E'when s\\.s_pronto then ''pronto'' else ''sumiu'' end') <> 1
     or regexp_count(d, E'case when s\\.s_sumiu then ''sumiu'' end\\], null\\)') <> 1
     or regexp_count(d, E'else ''Viu os planos e ficou calado'' end') <> 1
     or regexp_count(d, E'when s\\.s_pronto then 3 else 4 end') <> 1
     or regexp_count(d, E'or s\\.s_pronto or s\\.s_sumiu;') <> 1 then
    raise exception '0437: não achei os pontos de encaixe em _live2_reforco';
  end if;
  d := regexp_replace(d, E'(c\\.dados, c\\.ultima_msg_lead_at, c\\.ultima_msg_mari_at,)(\\r?\\n)', E'\\1 c.cep as cep_conv,\\2');
  d := regexp_replace(d, E'(''sumiu_max_min''\\)::int, 180\\)\\)\\) as s_sumiu)(\\r?\\n)',
    E'\\1,' || E'\\2' ||
    $ins$           -- 0437 (L-456): o cliente já deu alguma coisa do endereço, ainda não há CEP, a Mari falou por último e ele se calou
           (coalesce(b.cep_conv, '') = '' and b.ultima_msg_mari_at >= b.ultima_msg_lead_at
             and b.ultima_msg_lead_at < now() - make_interval(mins => coalesce((p ->> 'travou_min')::int, 20))
             and exists (select 1 from public.mari_turnos t
                          where t.conversa_id = b.id and t.papel = 'lead'
                            and length(btrim(coalesce(t.texto, ''))) >= coalesce((p ->> 'travou_letras')::int, 12)
                            and t.texto !~ '^\s*(🏡|🏢|🏠)'
                            and t.created_at > (select min(t0.created_at) from public.mari_turnos t0
                                                 where t0.conversa_id = b.id and t0.papel = 'lead'))) as s_travou$ins$ || nl);
  d := replace(d, $a$when s.s_pronto then 'pronto' else 'sumiu' end$a$, $b$when s.s_pronto then 'pronto' when s.s_sumiu then 'sumiu' else 'travou' end$b$);
  d := replace(d, $a$case when s.s_sumiu then 'sumiu' end], null)$a$, $b$case when s.s_sumiu then 'sumiu' end, case when s.s_travou then 'travou' end], null)$b$);
  d := replace(d, $a$else 'Viu os planos e ficou calado' end$a$,
                  $b$when s.s_sumiu then 'Viu os planos e ficou calado' else 'Deu o endereço e a conversa parou antes do CEP' end$b$);
  d := replace(d, $a$when s.s_pronto then 3 else 4 end$a$, $b$when s.s_pronto then 3 when s.s_sumiu then 4 else 5 end$b$);
  d := replace(d, $a$or s.s_pronto or s.s_sumiu;$a$, $b$or s.s_pronto or s.s_sumiu or s.s_travou;$b$);
  execute d;
end $mig$;

-- ───────────── (2) a cidade do cadastro da Fila Vero no contexto da Mari (remendo da mari_contexto no ar) ─────────────
do $mig$
declare
  d  text := pg_get_functiondef('public.mari_contexto(uuid,text,text,text,jsonb)'::regprocedure);
  nl text := E'\n';
begin
  if position('cidade_cadastro' in d) > 0 then
    raise notice '0437: mari_contexto já devolve a cidade do cadastro';
    return;
  end if;
  if regexp_count(d, E'''no_horario'', public\\.mari_atendimento_no_horario\\(now\\(\\), v_conv\\.cidade\\),\\r?\\n') <> 1 then
    raise exception '0437: não achei o ponto de encaixe em mari_contexto';
  end if;
  d := regexp_replace(d, E'(''no_horario'', public\\.mari_atendimento_no_horario\\(now\\(\\), v_conv\\.cidade\\),)(\\r?\\n)',
    E'\\1\\2' ||
    $ins$    -- 0437 (L-456): lead da Fila Vero ainda sem cidade — a cidade do cadastro dele é a cidade de partida da busca de rua
    'cidade_cadastro', case when v_conv.origem = 'fila_vero' and coalesce(btrim(v_conv.cidade), '') = '' then (
      select nullif(initcap(lower(btrim(regexp_replace(fv.cidade, '\s+-\s+[A-Za-z]{2}\s*$', '')))), '')
        from public.fila_vero fv
       where fv.conversa_id = v_conv.id and coalesce(btrim(fv.cidade), '') <> ''
       limit 1) end,$ins$ || nl);
  execute d;
end $mig$;

commit;

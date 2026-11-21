-- NIOGEN | supabase/migrations/0343_unidade_do_cliente_na_lista.sql | 21/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 21/11 ("Sim, as três"; conversa L-222, #202): a cliente confirmou CEP e número às 23h23, a fila da viabilidade
-- (mari_viab_pendentes) pegou a conversa na hora — antes do complemento — e o operador consultou o portal SEM unidade
-- ('escolher', informada vazia). A cliente disse "Casa a" às 23h24; o resultado chegou às 23h26 com a lista Casa A · Casa B ·
-- Casa C e a mari_viab_gravar abriu "unidade a confirmar" mesmo com a unidade dela NA lista. A Mari perguntou de novo duas vezes
-- (uma no meio da resposta sobre o chip) e a Live ganhou uma conferência à toa.
-- Agora: viável + unidade a confirmar, mas o complemento que a conversa JÁ tem bate com uma unidade da lista (mesma escrita, sem
-- acento, maiúscula, espaço ou pontuação) → a conferência não abre (e a aberta fecha); cobertura_detalhe.unidade_cliente guarda a
-- unidade da lista que bateu. Unidade fora da lista ou sem complemento: igual a antes (0233). As abertas hoje que já batem fecham.
-- Corpo de mari_viab_gravar = produção (pg_get_functiondef em 21/11, md5 63f822484c30745a55f1e93aba862228), só os trechos 0343.
-- Regra 20: (1) etapa/status/destino/vez/prazo não mudam — só deixa de abrir uma conferência sem motivo · (2) a conferência que
-- não abre não deixa ninguém parado (a Mari segue) · (3) quem abre/fecha continua sendo a mari_viab_gravar (função do banco) ·
-- (4) a lista vem do portal; o complemento, da conversa — nenhuma fonte nova · (5) a conferência 20 (unidade a confirmar) de
-- conferencia_itens continua contando as abertas. Cenário X68. Desempenho: sem impacto (1 conversa por chamada).
begin;

create or replace function public._unidade_chave(p text)
returns text language sql immutable set search_path = public as $$
  select regexp_replace(translate(lower(coalesce(p, '')), 'áàâãäéèêëíìîïóòôõöúùûüç', 'aaaaaeeeeiiiiooooouuuuc'), '[^a-z0-9]', '', 'g')
$$;
comment on function public._unidade_chave(text) is '0343: chave para comparar a unidade do cliente com a lista do portal ("Casa a" = "CASA A").';
revoke all on function public._unidade_chave(text) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.mari_viab_gravar(p_conversa uuid, p_saida jsonb, p_dfv jsonb DEFAULT NULL::jsonb, p_erro text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_res text; v_op text := p_saida->>'resultado'; v_dfv text; v_dec text; c record; v_conf text;
        v_uac jsonb := p_saida -> 'unidade_a_confirmar';   -- 0233: viável na fachada com a unidade emprestada
        v_bateu text;                                      -- 0343: a unidade da lista que bate com o complemento da conversa
begin
  if coalesce(p_saida->>'retry', '') = 'true' and p_dfv is null then
    update public.mari_conversas set nio_viab_em = null, viab_consultas = greatest(viab_consultas - 1, 0)
     where id = p_conversa and nio_viab_resultado is null;
    return jsonb_build_object('ok', true, 'resultado', 'de_volta_na_fila');
  end if;
  if coalesce(p_saida->>'retry', '') = 'true' then v_op := null; end if;   -- portal não decidiu; o DFV pode decidir
  -- 0343: viável na fachada, mas o cliente já deu uma unidade que ESTÁ na lista (o complemento chegou depois da consulta)
  if v_op = 'viavel' and v_uac is not null and jsonb_typeof(p_saida->'opcoes'->'lista') = 'array' then
    select u into v_bateu
      from public.mari_conversas mc, jsonb_array_elements_text(p_saida->'opcoes'->'lista') u
     where mc.id = p_conversa and public._unidade_chave(mc.complemento) <> ''
       and public._unidade_chave(u) = public._unidade_chave(mc.complemento)
     limit 1;
  end if;
  v_res := case v_op when 'viavel' then 'viavel' when 'sem_viabilidade' then 'sem_viabilidade'
                     when 'complemento_fora_lista' then 'nao_encontrado' else 'indisponivel' end;
  v_dfv := public._dfv_veredito(p_dfv);
  v_dec := public.cobertura_decidir(v_op, v_dfv);   -- rua_divergente = portal não decidiu: o DFV decide (a Mari segue o fluxo normal)
  -- 0202: portal em outra rua, ou portal "sem viabilidade" com a própria fachada viável no DFV → o time confere a rua
  v_conf := case when v_op = 'rua_divergente' then 'rua_divergente'
                 when v_op = 'sem_viabilidade' and p_dfv ->> 'match' = 'exato' and coalesce(p_dfv ->> 'fonte', '') <> 'base_congelada'
                 then 'portal_nao_dfv_exato' end;
  update public.mari_conversas set nio_viab_resultado = v_res,
         nio_viab_velocidade = case when v_res = 'viavel' then nullif(p_saida->>'velocidade', '') end,
         nio_viab_em = now(), cobertura_decisao = v_dec, cobertura_em = now(),
         cobertura_detalhe = jsonb_strip_nulls(jsonb_build_object(
           'portal', v_op, 'dfv', v_dfv, 'velocidade', p_saida->>'velocidade',
           'portal_texto', p_saida->'endereco'->>'viabilidade', 'portal_motivo', p_saida->>'motivo',
           'unidades', case when v_op = 'complemento_fora_lista' or v_uac is not null then p_saida->'opcoes'->'lista' end,
           'unidade_a_confirmar', case when v_uac is not null and v_bateu is null then true end,   -- 0343: bateu → não há o que confirmar
           'unidade_cliente', v_bateu,                                                          -- 0343
           'dfv_fachadas_cep', p_dfv->'total_fachadas_no_cep', 'dfv_fonte', coalesce(p_dfv->>'fonte', case when p_dfv is not null then 'ao_vivo' end),
           'dfv_match', p_dfv->>'match', 'portal_endereco', p_saida->'endereco'->>'resolvido', 'conferir_rua', v_conf))
   where id = p_conversa
  returning id, cep, numero, complemento, venda_id into c;
  if c.id is null then return jsonb_build_object('ok', false, 'motivo', 'conversa não encontrada'); end if;
  if v_conf is not null then
    perform public._cobertura_rua_marcar(p_conversa, v_conf, p_saida->'endereco'->>'resolvido', p_saida->'endereco'->>'esperado',
                                         p_dfv->'fachada'->>'logradouro', 'mari_viab_gravar');
  elsif v_op is not null then   -- o portal decidiu de novo sem conflito: a conferência pendente fecha sozinha
    update public.mari_conversas set rua_conferir_em = null where id = p_conversa and rua_conferir_em is not null;
  end if;
  -- 0233: unidade a confirmar. Viável com a unidade emprestada → o cliente escolhe (a Mari mostra a lista); o portal sem
  -- NENHUMA unidade cadastrada → o time pede o cadastro à Nio. A unidade do cliente bateu → a conferência fecha sozinha.
  if v_op = 'viavel' and v_uac is not null and v_bateu is null then   -- 0343: só quando a unidade do cliente não está na lista
    perform public._cobertura_unidade_marcar(p_conversa, 'escolher', p_saida->'opcoes'->'lista', v_uac->>'informada', v_uac->>'usada', 'mari_viab_gravar');
  elsif v_op = 'complemento_fora_lista' and p_saida->'opcoes'->>'situacao' = 'nenhuma' then
    perform public._cobertura_unidade_marcar(p_conversa, 'sem_cadastro', '[]'::jsonb, c.complemento, null, 'mari_viab_gravar');
  elsif v_op = 'viavel' then
    update public.mari_conversas set unidade_conferir_em = null where id = p_conversa and unidade_conferir_em is not null;
  end if;
  insert into public.nio_viab_log (origem, conversa_id, cep, numero, complemento, saida, resultado, erro)
  values ('mari', p_conversa, c.cep, c.numero, c.complemento, p_saida - 'cpf_mascara', v_res,
          coalesce(p_erro, case when v_res = 'indisponivel' then left(coalesce(p_saida->>'motivo', v_op, 'portal não decidiu'), 300) end));
  insert into public.operador_consultas (tipo, origem, conversa_id, venda_id, cep, numero, complemento, resultado, decisao, detalhe, ms)
  values ('viabilidade', 'mari', p_conversa, c.venda_id, c.cep, c.numero, c.complemento, coalesce(v_op, 'nao_decidiu'), v_dec,
          jsonb_build_object('portal', p_saida - 'cpf_mascara' - 'pedido_portal', 'dfv_veredito', v_dfv), nullif(p_saida->>'ms', '')::int);
  if p_dfv is not null then
    insert into public.operador_consultas (tipo, origem, conversa_id, venda_id, cep, numero, complemento, resultado, decisao, detalhe)
    values ('dfv', 'mari', p_conversa, c.venda_id, c.cep, c.numero, c.complemento, v_dfv, v_dec, p_dfv - 'opcoes' - 'unidades');
  end if;
  return jsonb_build_object('ok', true, 'resultado', v_res, 'operador', v_op, 'dfv', v_dfv, 'decisao', v_dec, 'conferir_rua', v_conf,
                            'unidade_cliente', v_bateu);
end $function$;

-- As abertas hoje ("escolher") cuja unidade do cliente já está na lista: fecham (é o caso L-222). Sem disparar nada além
-- dos gatilhos de sempre; cobertura_detalhe ganha unidade_cliente e perde unidade_a_confirmar.
update public.mari_conversas mc
   set unidade_conferir_em = null,
       cobertura_detalhe = (mc.cobertura_detalhe - 'unidade_a_confirmar') || jsonb_build_object('unidade_cliente', b.u)
  from (select m.id, (select u from jsonb_array_elements_text(m.cobertura_detalhe->'unidades') u
                       where public._unidade_chave(u) = public._unidade_chave(m.complemento) limit 1) as u
          from public.mari_conversas m
         where m.unidade_conferir_em is not null and m.unidade_conferir->>'motivo' = 'escolher'
           and jsonb_typeof(m.cobertura_detalhe->'unidades') = 'array' and public._unidade_chave(m.complemento) <> '') b
 where b.id = mc.id and b.u is not null;

commit;

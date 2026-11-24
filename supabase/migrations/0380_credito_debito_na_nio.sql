-- NIOGEN | supabase/migrations/0380_credito_debito_na_nio.sql | 24/11/2026 — Claude Code / Opus 5.5
-- Caso L-70 (24/11): o portal respondeu o crédito com o popup "Crédito negado · CPF/CNPJ com débito na
-- Nio." (print do Ricardo). Virava negado comum: o NIOGEN mandou ao cliente a oferta do CPF de um parente e a Mari passou ao time
-- "pra fazer o pedido no CPF do novo titular" — ele não tinha outro. O Ricardo assumiu, viu no portal a negociação (com o
-- desconto da Nio) e ofereceu quitar hoje. Ricardo: "Vamos deixar a Mari seguir o atendimento
-- normal, sem negar a venda e conduz ao humano, para que ele entre no mérito e tente conduzir de forma mais natural."
-- O que muda:
--   mari_conversas.credito_resultado aceita 'negado_debito' (robô portal/credito.py; extensão 0.11.3 só avisa e para).
--   _credito_categoria ....... na venda, negado_debito = 'negado' (os 4 valores da venda não mudam).
--   _credito_avisar .......... sem mudança: negado_debito cai no "resultado sem aviso automático" — o cliente NÃO recebe o negado
--                              nem a oferta do parente (o espelho para a venda grava 'negado' com credito.espelho, sem aviso).
--   mari_credito_gravar ...... aceita; nota no Chatwoot SEMPRE (como o antifraude) com o que fazer; guarda o texto do popup.
--   lead_registrar_consulta .. a ficha grava "negado — CPF com débito na Nio".
--   A Mari (n07, mesmo commit): na próxima fala do cliente segue sem falar de crédito e passa ao time (pedido_humano).
-- Regra 20: (1) nenhuma situação nova — com a Mari, o lead vai ao time pelo handoff (vez time, prazo da escada); com o time, segue
-- em Qualificado · rodar crédito (vez time) · (2) ninguém parado: nota na hora + handoff na próxima fala; cadência segue tocando
-- enquanto a Mari conduz · (3) estado só por funções do banco (mari_credito_gravar, lead_registrar_consulta, mari_handoff) ·
-- (4) fonte: o popup do portal da Nio · (5) sem número novo: o crédito da conversa e da venda já é conferido (item 25 — a categoria
-- de negado_debito é 'negado', igual à venda). Cenário X104. Desempenho: sem impacto em tela.
-- Medir em 7 dias: leads com negado_debito; quantos quitaram e viraram pedido (crédito novo aprovado na mesma conversa).

begin;
set local lock_timeout = '8s';

alter table public.mari_conversas drop constraint if exists mari_conversas_credito_resultado_check;
alter table public.mari_conversas add constraint mari_conversas_credito_resultado_check
  check (credito_resultado is null or credito_resultado in ('aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'pendente',
                                                            'negado', 'negado_antifraude', 'negado_debito', 'pedido_em_andamento', 'nao_decidiu'));

CREATE OR REPLACE FUNCTION public._credito_categoria(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  select case
    when p in ('aprovado', 'aprovado_todas', 'aprovado_parcial') then 'aprovado'
    when p in ('so_cartao', 'aprovado_cartao') then 'so_cartao'
    when p in ('negado', 'negado_antifraude', 'negado_debito') then 'negado'   -- 0380: na venda, débito na Nio é negado
    when p = 'pendente' then 'pendente'
  end
$function$;

CREATE OR REPLACE FUNCTION public.mari_credito_gravar(p_conversa uuid, p_saida jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_op text := p_saida->>'resultado'; v text; c record; v_formas text; v_fp text; v_fazer text;
        v_end text := case when p_saida->'endereco'->>'origem' = 'cliente' then 'cliente' when p_saida->'endereco'->>'origem' = 'padrao' then 'padrao' end;
begin
  if coalesce(p_saida->>'retry', '') = 'true' then
    update public.mari_conversas set credito_em = null, credito_consultas = greatest(credito_consultas - 1, 0)
     where id = p_conversa and credito_resultado is null;
    return jsonb_build_object('ok', true, 'resultado', 'de_volta_na_fila');
  end if;
  v := case when v_op in ('aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'pendente', 'negado', 'negado_antifraude', 'negado_debito', 'pedido_em_andamento')
            then v_op else 'nao_decidiu' end;
  update public.mari_conversas set credito_resultado = v, credito_em = now(), credito_endereco = v_end,
         credito_formas = case when jsonb_typeof(p_saida->'formas_liberadas') = 'array' then p_saida->'formas_liberadas' end,
         nio_pedido_aberto = case when v = 'pedido_em_andamento' then 'sim' when v in ('aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'negado', 'negado_antifraude', 'negado_debito') then 'nao' else nio_pedido_aberto end   -- 0313: crédito decidido = o pedido de lá caiu
   where id = p_conversa returning id, venda_id, credito_autorizado_em, credito_autorizacao_frase, chatwoot_conversation_id, status,
                                   forma_pagamento, credito_consultas into c;
  if c.id is null then return jsonb_build_object('ok', false, 'motivo', 'conversa não encontrada'); end if;
  insert into public.operador_consultas (tipo, origem, conversa_id, venda_id, cpf_mascara, resultado, detalhe, ms)
  values ('credito', 'mari', p_conversa, c.venda_id, p_saida->>'cpf_mascara', coalesce(v_op, 'erro'),
          jsonb_strip_nulls(jsonb_build_object('formas', p_saida->'formas_liberadas', 'motivo', p_saida->>'motivo',
            'cache', p_saida->'cache', 'etapa_parada', p_saida->'etapa_parada', 'endereco', v_end,
            -- 0380: o que o portal escreveu no popup (sem número), para a ficha mostrar o motivo do negado
            'popup', left(regexp_replace(nullif(btrim(coalesce(p_saida->'popup'->>'texto', '')), ''), '\d[\d.\-/ ]{5,}\d', '<num>', 'g'), 300),
            'autorizado_em', c.credito_autorizado_em, 'autorizacao_frase', c.credito_autorizacao_frase)),
          nullif(p_saida->>'ms', '')::int);
  -- 0140: o resultado chegou depois do handoff (a nota da Mari já foi) → nota interna no Chatwoot pela fila do NIOGEN.
  if c.chatwoot_conversation_id is not null and (c.status = 'handoff_realizado' or c.venda_id is not null or v in ('negado_antifraude', 'negado_debito')) then   -- 0212/0380: antifraude e débito sempre viram nota
    v_formas := (select string_agg(case upper(x) when 'BOLETO' then 'boleto' when 'CREDITO' then 'cartão' when 'DACC' then 'débito em conta' else lower(x) end, ', ')
                   from jsonb_array_elements_text(case when jsonb_typeof(p_saida->'formas_liberadas') = 'array' then p_saida->'formas_liberadas' else '[]'::jsonb end) x);
    v_fp := case c.forma_pagamento when 'boleto' then 'boleto' when 'cartao' then 'cartão' when 'debito' then 'débito em conta' end;
    v_fazer := case
      when v = 'negado_antifraude' then 'NÃO consultar outro CPF. Perguntar ao cliente se a Nio do endereço é dele (ou de alguém da casa) ou de outro morador que se mudou; gravar a resposta na ficha › Crédito (Antifraude).'
      when v = 'negado_debito' then 'CPF COM DÉBITO NA NIO (fatura antiga em aberto). O cliente NÃO foi avisado do negado: a Mari segue e passa para você. Ver no portal o valor da negociação (a Nio dá desconto) e oferecer quitar hoje; pagou → consultar o crédito de novo (ficha › Crédito) e fazer o pedido. Não quis quitar → outra pessoa da casa como titular.'
      when v = 'pedido_em_andamento' then 'NÃO abrir outro pedido: conferir no portal o pedido que já existe no CPF (recompra = multa R$ 500).'
      when v_end = 'padrao' and v like 'aprovado%' then 'Consultar o crédito de novo no endereço do cliente (ficha › Crédito) antes de abrir o pedido.'
      when v = 'nao_decidiu' then 'Consultar o crédito na ficha (Crédito) — o portal não decidiu.'
      when v = 'pendente' then 'Aguardar a resposta da Nio (até 24 h) e avisar o cliente; não abrir o pedido antes.'
      when v = 'negado' and coalesce(c.credito_consultas, 0) >= 2 then 'Ver com o cliente outra pessoa da casa como titular; sem saída, encerrar pela Saída.'
      when v = 'negado' then 'Oferecer outra pessoa da casa como titular (CPF do parente → 1 nova consulta).'
      when v = 'aprovado_cartao' and coalesce(c.forma_pagamento, '') <> 'cartao' then 'Só o cartão foi liberado: confirmar se o cliente paga no cartão; se não, outra pessoa da casa como titular.'
      when v = 'aprovado_parcial' and c.forma_pagamento in ('boleto', 'cartao', 'debito')
           and not coalesce(p_saida->'formas_liberadas', '[]'::jsonb) ? (case c.forma_pagamento when 'boleto' then 'BOLETO' when 'cartao' then 'CREDITO' else 'DACC' end)
        then 'A forma escolhida (' || v_fp || ') não foi liberada: combinar com o cliente uma das liberadas (' || coalesce(v_formas, '?') || ').'
      else 'O crédito já está gravado na venda (0330). Abrir o pedido no portal' || coalesce(' no ' || v_fp, '') || '; o NIOGEN já avisou o cliente do crédito (e pediu o plano/forma, se faltava). A biometria sai quando o pedido é feito no portal.' end;
    insert into public.chatwoot_acoes (grupo, ordem, momento, venda_id, conversa_id, chatwoot_conversation_id, tipo, payload, status)
    values (gen_random_uuid(), 1, 'credito', c.venda_id, p_conversa, c.chatwoot_conversation_id, 'nota',
            jsonb_build_object('content', '💳 Crédito chegou (consulta automática da Mari'
              || coalesce(', ' || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), '') || '): '
              || case v when 'aprovado_todas' then 'APROVADO — todas as formas'
                        when 'aprovado_parcial' then 'APROVADO — ' || coalesce(v_formas, 'formas: ?')
                        when 'aprovado_cartao' then 'APROVADO SÓ NO CARTÃO'
                        when 'pendente' then 'PENDENTE (a Nio responde em até 24 h)'
                        when 'negado' then case when coalesce(c.credito_consultas, 0) >= 2 then 'NEGADO nos 2 CPFs (titular e parente)' else 'NEGADO neste CPF' end
                        when 'negado_antifraude' then 'NEGADO — CRITÉRIOS ANTIFRAUDE (a Nio vê Nio neste endereço)'
                        when 'negado_debito' then 'NEGADO — CPF COM DÉBITO NA NIO'
                        when 'pedido_em_andamento' then 'já existe PEDIDO NIO EM ANDAMENTO no CPF'
                        else 'o portal não decidiu' end
              -- 0204: lido no endereço padrão → não vale para o endereço do cliente
              || case when v_end = 'padrao' and v like 'aprovado%' then ' · ⚠ lido no endereço PADRÃO, não no do cliente' else '' end
              || E'\n👉 Fazer agora: ' || v_fazer), 'pendente');
  end if;
  return jsonb_build_object('ok', true, 'resultado', v, 'endereco', v_end);
end $function$;

CREATE OR REPLACE FUNCTION public.lead_registrar_consulta(p_conversa uuid, p_tipo text, p_resultado text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c    public.mari_conversas;
  rot  text;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  if c.venda_id is not null then raise exception 'Este lead já tem venda: registre na venda.'; end if;

  if p_tipo = 'viabilidade' then
    if p_resultado <> 'viavel' then
      raise exception 'Por aqui só se grava "viável". Sem viabilidade: use Saída › Fachada não atendida.';
    end if;
    update public.mari_conversas
       set nio_viab_resultado = 'viavel', nio_viab_em = now(),
           cobertura_decisao = 'viavel', cobertura_em = now(),
           cobertura_detalhe = coalesce(cobertura_detalhe, '{}'::jsonb) || jsonb_build_object('portal', 'viavel', 'registrado_na_ficha', true),
           rua_conferir_em = null   -- 0202: viável registrado na ficha = rua conferida
     where id = c.id;
    insert into public.operador_consultas (tipo, origem, usuario_id, conversa_id, cep, numero, complemento, resultado, decisao, detalhe)
    values ('viabilidade', 'tela', auth.uid(), c.id, c.cep, c.numero, c.complemento, 'viavel', 'viavel', jsonb_build_object('registrado_na_ficha', true));
    rot := 'viabilidade: viável';

  elsif p_tipo = 'credito' then
    if p_resultado not in ('aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'pendente', 'negado', 'negado_antifraude', 'negado_debito', 'pedido_em_andamento') then
      raise exception 'Resultado de crédito desconhecido: %', p_resultado;
    end if;
    update public.mari_conversas
       set credito_resultado = p_resultado, credito_em = now(),
           nio_pedido_aberto = case when p_resultado = 'pedido_em_andamento' then 'sim' when p_resultado in ('aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'negado', 'negado_antifraude', 'negado_debito') then 'nao' else nio_pedido_aberto end   -- 0313
     where id = c.id;
    insert into public.operador_consultas (tipo, origem, usuario_id, conversa_id, resultado, detalhe)
    values ('credito', 'tela', auth.uid(), c.id, p_resultado, jsonb_build_object('registrado_na_ficha', true));
    rot := 'crédito: ' || case p_resultado when 'aprovado_todas' then 'aprovado' when 'aprovado_parcial' then 'aprovado (parcial)'
                                           when 'aprovado_cartao' then 'aprovado só no cartão' when 'pendente' then 'pendente'
                                           when 'negado' then 'negado' when 'negado_antifraude' then 'negado por critérios antifraude — conferir com o cliente'
                                           when 'negado_debito' then 'negado — CPF com débito na Nio: oferecer quitar e consultar de novo' else 'já tem pedido em andamento' end;
  else
    raise exception 'Tipo desconhecido: %', p_tipo;
  end if;

  return jsonb_build_object('ok', true, 'resumo', '✓ registrado no lead — ' || rot);
end;
$function$;

commit;

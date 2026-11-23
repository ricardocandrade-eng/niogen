-- NIOGEN | supabase/migrations/0366_credito_cartao_golpe.sql | 23/11/2026 — Claude Code / Opus 5.5
-- Caso L-248 (23/11, conversa 219, OS 12274715 — time conduzindo, crédito e viabilidade pelo NIOGEN). Ricardo:
--  1) "Nesse balão não pode falar ainda de biometria, porque ele ainda não havia escolhido o plano e nem a forma de pagamento" — a
--     biometria só é enviada quando o pedido é feito no portal. → bo_credito_aprovado deixa de dizer "o próximo passo é a biometria";
--     sem plano ou forma combinados sai bo_credito_aprovado_falta, que pede o que falta (as formas que o crédito liberou).
--  2) "retire essa parte do alerta e deixe apenas para o final, com o pedido concluído, numa nova mensagem após a confirmação do
--     pedido" → o alerta de golpe sai de bo_instalacao_confirmada e dos três avisos da biometria (o L-248 o leu duas vezes) e vira
--     bo_alerta_golpe: UMA vez por conversa, mensagem própria, logo depois da confirmação da instalação (botão Agendar ou cadência C2).
--  3) "Avalie uma forma de enviar automaticamente a instrução sobre o pagamento no cartão. Tive que explicar" → OS gravada com
--     forma cartão e biometria aprovada (o que vier por último) = a Nio manda o link do cadastro do cartão: bo_cartao_link sai na
--     hora (pré-reserva, nada cobrado hoje, sem o cadastro não instala). Antes o aviso (mari_cartao_aviso) só saía pela cadência,
--     depois da agenda — e no L-248 nem saiu, porque a extensão gravou "boleto" (corrigido na extensão 0.10.x, mesmo commit).
--     Marca cartao_avisado_em: a cadência pula o CARTAO e segue com o lembrete CARTAO2 (24 h ou véspera).
--  4) A nota do time no crédito automático dizia "o cliente já foi avisado do crédito e do link da biometria" — falso; corrigida.
-- Regra 20: (1) nenhuma situação nova; vez e prazo seguem os da venda · (2) nenhum estado muda aqui — só avisos e as marcas
-- cartao_avisado_em / dados.credito_aprovado_avisado, como na 0327 · (3) consequência na fila chatwoot_acoes · (4) fontes: crédito e
-- OS do portal (operador/extensão), agenda da porta/cadência · (5) cenário X92; a fila já é conferida (R3, R7).
-- Regra de ouro 6: avisos da venda saem também com pessoa na conversa (em nome dela — _bo_mensagem); Saída e Não contatar barram;
-- nunca repetidos; fora da janela de 24 h o golpe e o cartão não entram na fila (o cartão fica para a cadência, que tem template).
-- Desempenho: sem impacto em tela. Medir em 7 dias: vendas no cartão com "cadastrei" antes da véspera; mensagens do time explicando
-- o cartão à mão (hoje: L-248); aviso de crédito com "biometria" antes do pedido → 0.

begin;

-- 1. textos: o alerta de golpe sai dos avisos da biometria e da instalação
update public.config_mari_textos set texto = $t$Instalação agendada para {dia}, {periodo} ✅

O técnico da Nio vai até aí nesse período; é importante ter alguém maior de idade em casa. Se precisar remarcar, é só me avisar por aqui 😊$t$
 where chave = 'bo_instalacao_confirmada';
update public.config_mari_textos set texto = $t$Pronto, seu pedido foi aberto! 😊

A Nio acabou de te mandar o link da biometria por WhatsApp e por e-mail. Ele pede os 5 primeiros números do seu CPF e uma selfie: tira sem óculos, num lugar bem iluminado, e libera a câmera quando o celular pedir.

É rapidinho, uns 2 minutos. Me avisa quando terminar?$t$
 where chave = 'bo_pedido_biometria';
update public.config_mari_textos set texto = $t$Pronto, seu pedido foi aberto e a instalação ficou pré-agendada para {dia}, {periodo} 😊

Agora falta só a biometria: a Nio acabou de te mandar o link por WhatsApp e por e-mail. Ele pede os 5 primeiros números do seu CPF e uma selfie: tira sem óculos, num lugar bem iluminado, e libera a câmera quando o celular pedir. É rapidinho, uns 2 minutos, e é ela que confirma a visita do técnico.

Me avisa quando terminar?$t$
 where chave = 'bo_os_biometria';
update public.config_mari_textos set texto = $t$Oi! A Nio acabou de te mandar o link da biometria por WhatsApp e por e-mail 😊 Ele pede os 5 primeiros números do seu CPF e uma selfie: tira sem óculos, num lugar bem iluminado, e libera a câmera quando o celular pedir.

É rapidinho, uns 2 minutos. Me avisa quando terminar?$t$
 where chave = 'bo_ged_biometria';

-- 2. textos novos (e o aprovado sem "o próximo passo é a biometria")
insert into public.config_mari_textos (chave, texto) values
('bo_credito_aprovado', $t$Boa notícia! ✅ A análise de crédito da Nio aprovou o seu pedido{forma}.

Agora a gente faz o seu pedido na Nio. Na hora, a própria Nio te manda o link da biometria por WhatsApp e por e-mail — te aviso por aqui 😊$t$),
('bo_credito_aprovado_falta', $t$Boa notícia! ✅ A análise de crédito da Nio aprovou o seu pedido{forma}.

Pra eu fazer o seu pedido, me confirma {falta}?$t$),
('bo_alerta_golpe', $t$⚠️ Um cuidado importante: a Nio não migra clientes para outra operadora. Se alguém disser que o seu pedido foi cancelado, que não tem disponibilidade ou pedir para você escolher TIM, Claro ou Vivo, é golpe: não responda e não clique em link. Sobre o seu pedido, fale só por este número ou pelos canais oficiais da Nio.$t$),
('bo_cartao_link', $t$Como você escolheu pagar no cartão de crédito 💳, a Nio te manda um link, por WhatsApp e por e-mail, para cadastrar o cartão. É por ali, no ambiente da própria Nio, que você coloca os dados: por aqui a gente nunca pede esses números.

Fica tranquilo: nada é cobrado hoje. O cadastro só faz uma pré-reserva do valor da fatura. E é ele que libera a visita do técnico — sem o cadastro, a Nio não faz a instalação. Me avisa quando fizer? 😊$t$)
on conflict (chave) do update set texto = excluded.texto;

-- 3. _credito_avisar (= produção + o aviso que pede plano/forma)
CREATE OR REPLACE FUNCTION public._credito_avisar(p_conversa uuid, p_venda uuid, p_res text, p_formas jsonb, p_origem text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c       public.mari_conversas;
  v       public.vendas;
  g       uuid := gen_random_uuid();
  v_fp    text;
  v_fpcod text;
  v_lib   text[];
  v_chave text;
  v_flag  text;
  v_vars  jsonb := '{}'::jsonb;
  r       jsonb;
  v_formas_txt text;
  v_plano text;
  v_arr   text[];
  v_falta text;
begin
  if p_conversa is not null then
    select * into c from public.mari_conversas where id = p_conversa;
  else
    select * into c from public.mari_conversas where venda_id = p_venda and canal = 'whatsapp' order by created_at desc limit 1;
  end if;
  if c.id is null then return jsonb_build_object('aviso', null, 'motivo', 'sem conversa'); end if;
  if p_venda is not null then select * into v from public.vendas where id = p_venda;
  elsif c.venda_id is not null then select * into v from public.vendas where id = c.venda_id; end if;

  if c.canal <> 'whatsapp' or coalesce(c.chatwoot_conversation_id, '') = '' or coalesce(c.telefone, '') like '5500000000%' then
    return jsonb_build_object('aviso', null, 'motivo', 'sem canal');
  end if;
  -- Saída barra (regra de ouro 6). Não contatar barra dentro do _bo_mensagem (fica "bloqueada", visível na fila).
  if coalesce(v.status, '') = 'saida' or c.saida_motivo is not null or c.quadro_encerrada_motivo is not null
     or (c.funil_destino is not null and c.funil_destino not in ('em_andamento')) then
    return jsonb_build_object('aviso', null, 'motivo', 'em Saída');
  end if;
  -- crédito lido no endereço PADRÃO não vale para o do cliente (0204): o time consulta de novo antes de avisar.
  if p_venda is null and coalesce(c.credito_endereco, '') = 'padrao' and p_res like 'aprovado%' then
    return jsonb_build_object('aviso', null, 'motivo', 'crédito lido no endereço padrão');
  end if;
  -- uma vez: o mesmo aviso (mesmo resultado) nos últimos 30 min não sai de novo — Mari e botão gravando o mesmo crédito.
  if exists (select 1 from public.chatwoot_acoes a
              where a.conversa_id = c.id and a.tipo = 'mensagem' and a.payload ->> 'rotulo' = 'aviso do crédito: ' || p_res
                and a.criada_em > now() - interval '30 minutes' and a.status <> 'cancelada') then
    return jsonb_build_object('aviso', null, 'motivo', 'já avisado');
  end if;

  -- o botão/extensão grava "aprovado" na venda, mas a consulta da Mari (mais detalhada) já disse SÓ CARTÃO ou PARCIAL nesta conversa:
  -- não avisa "aprovado" — a extensão grava "aprovado" sem ler o popup em um caminho (content.js r.e5). Fica a palavra da Mari.
  if p_venda is not null and p_res = 'aprovado' and coalesce(c.credito_resultado, '') in ('aprovado_cartao', 'aprovado_parcial') then
    return jsonb_build_object('aviso', null, 'motivo', 'a venda diz aprovado, a consulta da Mari disse ' || c.credito_resultado || ' — vale a da Mari');
  end if;
  -- a forma que o cliente escolheu durante a conversa (Ricardo); sem ela, a da venda.
  v_fp := coalesce(nullif(c.forma_pagamento, ''), nullif(v.forma_pagamento, ''));
  v_fpcod := case v_fp when 'boleto' then 'BOLETO' when 'cartao' then 'CREDITO' when 'debito' then 'DACC' end;
  v_lib := array(select upper(x) from jsonb_array_elements_text(case when jsonb_typeof(p_formas) = 'array' then p_formas else '[]'::jsonb end) x);

  if p_res in ('aprovado_todas', 'aprovado')
     or (p_res = 'aprovado_parcial' and (v_fpcod is null or v_fpcod = any (v_lib)))
     or (p_res in ('aprovado_cartao', 'so_cartao') and v_fp = 'cartao') then
    v_chave := 'bo_credito_aprovado'; v_flag := 'credito_aprovado_avisado';
    v_vars := jsonb_build_object('forma', case v_fp when 'boleto' then ', no boleto' when 'cartao' then ', no cartão de crédito'
                                                    when 'debito' then ', no débito em conta' else '' end);
    -- 0366 (L-248, Ricardo 23/11): "Nesse balão não pode falar ainda de biometria, porque ele ainda não havia escolhido o plano e nem
    -- a forma de pagamento" — a biometria só sai quando o time faz o pedido no portal. Sem plano ou sem forma, o aviso pede o que falta.
    v_plano := coalesce(nullif(btrim(coalesce(c.plano_escolhido, '')), ''), v.plano_id::text);
    if v_fp is null or v_plano is null then
      v_arr := array(select case x when 'BOLETO' then 'boleto' when 'CREDITO' then 'cartão de crédito' when 'DACC' then 'débito em conta' else lower(x) end
                       from unnest(case when coalesce(array_length(v_lib, 1), 0) = 0 or p_res in ('aprovado_todas', 'aprovado')
                                        then array['BOLETO', 'CREDITO', 'DACC'] else v_lib end) x order by x);
      v_formas_txt := case when array_length(v_arr, 1) > 1
                           then array_to_string(v_arr[1:array_length(v_arr, 1) - 1], ', ') || ' ou ' || v_arr[array_length(v_arr, 1)]
                           else v_arr[1] end;
      v_falta := case when v_fp is null and v_plano is null then 'o plano e a forma de pagamento (' || v_formas_txt || ')'
                      when v_fp is null then 'a forma de pagamento: ' || v_formas_txt
                      else 'o plano que você escolheu' end;
      v_chave := 'bo_credito_aprovado_falta';
      v_vars := v_vars || jsonb_build_object('falta', v_falta);
    end if;
  elsif p_res = 'aprovado_parcial' then
    v_formas_txt := (select string_agg(case x when 'BOLETO' then 'boleto' when 'CREDITO' then 'cartão de crédito' when 'DACC' then 'débito em conta'
                                              else lower(x) end, ' ou ' order by x) from unnest(v_lib) x);
    if v_formas_txt is null then return jsonb_build_object('aviso', null, 'motivo', 'aprovado parcial sem formas'); end if;
    v_chave := 'bo_credito_forma'; v_flag := 'credito_forma_avisado';
    v_vars := jsonb_build_object('forma', case v_fp when 'boleto' then 'no boleto' when 'cartao' then 'no cartão' else 'no débito em conta' end,
                                 'formas', v_formas_txt);
  elsif p_res in ('aprovado_cartao', 'so_cartao') then
    v_chave := 'bo_credito_cartao'; v_flag := 'credito_cartao_avisado';
  elsif p_res = 'negado' then
    if coalesce(c.credito_consultas, 0) >= 2 then
      return jsonb_build_object('aviso', null, 'motivo', 'negado na 2ª consulta: o time vê com o cliente');
    end if;
    v_chave := 'bo_credito_negado'; v_flag := 'credito_negado_avisado';
  elsif p_res = 'pendente' then
    v_chave := 'bo_credito_pendente'; v_flag := 'credito_pendente_avisado';
  else
    return jsonb_build_object('aviso', null, 'motivo', 'resultado sem aviso automático: ' || coalesce(p_res, '?'));
  end if;
  -- uma vez por conversa: este aviso já saiu (pela Mari ou pelo botão, a qualquer tempo) → não sai de novo. Ex.: a Mari consulta e dá
  -- só cartão; horas depois o BKO grava o mesmo "só cartão" na ficha ou na extensão → nada sai. Resultado novo (negado → parente
  -- aprovado) tem aviso próprio.
  if coalesce((c.dados ->> v_flag)::boolean, false) then
    return jsonb_build_object('aviso', null, 'motivo', 'este resultado já foi avisado nesta conversa');
  end if;

  r := public._bo_mensagem(g, 1, 'credito', coalesce(p_venda, c.venda_id), c, v_chave, v_vars, null, null, 'aviso do crédito: ' || p_res);
  -- a nota "📣 já avisou" só na consulta automática da Mari: no botão, quem clicou já sabe e a porta já deixa a nota dela (H5).
  if r ->> 'status' = 'pendente' and p_origem = 'mari' then
    perform public._bo_enfileirar(g, 2, 'credito', coalesce(p_venda, c.venda_id), c, 'nota', jsonb_build_object('content',
      '📣 O NIOGEN já avisou o cliente do crédito (' || case v_chave when 'bo_credito_aprovado' then 'aprovado' || replace(v_vars ->> 'forma', ',', '')
        when 'bo_credito_aprovado_falta' then 'aprovado' || replace(v_vars ->> 'forma', ',', '') || ' — pediu ' || (v_vars ->> 'falta')
        when 'bo_credito_forma' then 'aprovado, mas a forma escolhida não foi liberada — ofereceu ' || (v_vars ->> 'formas')
        when 'bo_credito_cartao' then 'só no cartão — ofereceu cartão ou outra pessoa da casa como titular'
        when 'bo_credito_negado' then 'negado — ofereceu um parente ou familiar como titular'
        else 'pendente — a Nio responde em até 24 h' end
      || '). Não precisa repetir: siga com a resposta dele.'));
  end if;
  -- a Mari não repete (o 7 · Extrair lê estas flags); no negado com a Mari atendendo, ela passa ao time na próxima fala do cliente.
  if r ->> 'status' in ('pendente', 'repetida') then
    update public.mari_conversas
       set dados = coalesce(dados, '{}'::jsonb) || jsonb_build_object(v_flag, true)
                   || case when v_chave = 'bo_credito_negado' then jsonb_build_object('credito_negado_sistema', true) else '{}'::jsonb end
     where id = c.id;
  end if;
  return jsonb_build_object('aviso', v_chave, 'status', r ->> 'status', 'motivo', r ->> 'motivo', 'origem', p_origem);
end $function$;
revoke all on function public._credito_avisar(uuid, uuid, text, jsonb, text) from public, anon, authenticated;

-- 4. mari_credito_gravar (= produção + a nota do time sem "já avisado da biometria")
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
  v := case when v_op in ('aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'pendente', 'negado', 'negado_antifraude', 'pedido_em_andamento')
            then v_op else 'nao_decidiu' end;
  update public.mari_conversas set credito_resultado = v, credito_em = now(), credito_endereco = v_end,
         credito_formas = case when jsonb_typeof(p_saida->'formas_liberadas') = 'array' then p_saida->'formas_liberadas' end,
         nio_pedido_aberto = case when v = 'pedido_em_andamento' then 'sim' when v in ('aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'negado', 'negado_antifraude') then 'nao' else nio_pedido_aberto end   -- 0313: crédito decidido = o pedido de lá caiu
   where id = p_conversa returning id, venda_id, credito_autorizado_em, credito_autorizacao_frase, chatwoot_conversation_id, status,
                                   forma_pagamento, credito_consultas into c;
  if c.id is null then return jsonb_build_object('ok', false, 'motivo', 'conversa não encontrada'); end if;
  insert into public.operador_consultas (tipo, origem, conversa_id, venda_id, cpf_mascara, resultado, detalhe, ms)
  values ('credito', 'mari', p_conversa, c.venda_id, p_saida->>'cpf_mascara', coalesce(v_op, 'erro'),
          jsonb_strip_nulls(jsonb_build_object('formas', p_saida->'formas_liberadas', 'motivo', p_saida->>'motivo',
            'cache', p_saida->'cache', 'etapa_parada', p_saida->'etapa_parada', 'endereco', v_end,
            'autorizado_em', c.credito_autorizado_em, 'autorizacao_frase', c.credito_autorizacao_frase)),
          nullif(p_saida->>'ms', '')::int);
  -- 0140: o resultado chegou depois do handoff (a nota da Mari já foi) → nota interna no Chatwoot pela fila do NIOGEN.
  if c.chatwoot_conversation_id is not null and (c.status = 'handoff_realizado' or c.venda_id is not null or v = 'negado_antifraude') then   -- 0212: antifraude sempre vira nota
    v_formas := (select string_agg(case upper(x) when 'BOLETO' then 'boleto' when 'CREDITO' then 'cartão' when 'DACC' then 'débito em conta' else lower(x) end, ', ')
                   from jsonb_array_elements_text(case when jsonb_typeof(p_saida->'formas_liberadas') = 'array' then p_saida->'formas_liberadas' else '[]'::jsonb end) x);
    v_fp := case c.forma_pagamento when 'boleto' then 'boleto' when 'cartao' then 'cartão' when 'debito' then 'débito em conta' end;
    v_fazer := case
      when v = 'negado_antifraude' then 'NÃO consultar outro CPF. Perguntar ao cliente se a Nio do endereço é dele (ou de alguém da casa) ou de outro morador que se mudou; gravar a resposta na ficha › Crédito (Antifraude).'
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
                        when 'pedido_em_andamento' then 'já existe PEDIDO NIO EM ANDAMENTO no CPF'
                        else 'o portal não decidiu' end
              -- 0204: lido no endereço padrão → não vale para o endereço do cliente
              || case when v_end = 'padrao' and v like 'aprovado%' then ' · ⚠ lido no endereço PADRÃO, não no do cliente' else '' end
              || E'\n👉 Fazer agora: ' || v_fazer), 'pendente');
  end if;
  return jsonb_build_object('ok', true, 'resultado', v, 'endereco', v_end);
end $function$;

-- 5. alerta de golpe: uma vez por conversa, mensagem própria, logo depois da confirmação da instalação.
--    Dispara quando a confirmação é registrada (instalacao_avisada_em): pelo botão Agendar (a porta grava depois de pôr a confirmação
--    na fila — esta entra depois dela, id maior) ou pela cadência C2 (gravada depois do envio).
create or replace function public._golpe_avisar()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_status text;
begin
  if new.canal <> 'whatsapp' or coalesce(new.chatwoot_conversation_id, '') = '' or coalesce(new.telefone, '') like '5500000000%'
     or coalesce(new.nao_contatar, false) then return null; end if;
  if new.saida_motivo is not null or new.quadro_encerrada_motivo is not null
     or (new.funil_destino is not null and new.funil_destino not in ('em_andamento')) then return null; end if;
  if new.venda_id is not null then
    select status into v_status from public.vendas where id = new.venda_id;
    if coalesce(v_status, '') = 'saida' then return null; end if;
  end if;
  -- janela de 24 h fechada: a confirmação foi por template; o alerta não vira pendência de "mandar à mão".
  if new.ultima_msg_lead_at is null or now() >= new.ultima_msg_lead_at + interval '23 hours' then return null; end if;
  if exists (select 1 from public.chatwoot_acoes a
              where a.conversa_id = new.id and a.tipo = 'mensagem' and a.payload ->> 'texto_chave' = 'bo_alerta_golpe'
                and a.status in ('pendente', 'executando', 'feita')) then return null; end if;
  perform public._bo_mensagem(gen_random_uuid(), 1, 'agendar', new.venda_id, new, 'bo_alerta_golpe', '{}'::jsonb, null, null,
                              'alerta de golpe (depois da instalação)');
  return null;
exception when others then
  insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
  values (new.id, '0366 · alerta de golpe', sqlerrm, jsonb_build_object('instalacao_avisada_em', new.instalacao_avisada_em));
  return null;
end $$;
revoke all on function public._golpe_avisar() from public, anon, authenticated;

drop trigger if exists mari_conversas_golpe_aviso on public.mari_conversas;
create trigger mari_conversas_golpe_aviso after update of instalacao_avisada_em on public.mari_conversas
  for each row when (new.instalacao_avisada_em is not null and new.instalacao_avisada_em is distinct from old.instalacao_avisada_em)
  execute function public._golpe_avisar();

-- 6. instrução do cartão: OS gravada no cartão + biometria aprovada (o que vier por último) → a Nio manda o link do cadastro.
create or replace function public._cartao_avisar_venda()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  c public.mari_conversas;
  r jsonb;
begin
  if new.cartao_pago_em is not null then return null; end if;
  -- OS em rascunho/cancelada (Draft — reemitir o pedido para trocar o pagamento, 0278): espera; quando ela voltar a valer, a
  -- cadência (CARTAO) avisa.
  if exists (select 1 from public.os_andamento oa where oa.pedido = btrim(coalesce(new.nio_pedido, new.nio_os))
               and oa.estado in ('rascunho', 'cancelada', 'cancelando', 'reprovada')) then return null; end if;
  -- a Consulta OS já passou de "Aguardando Pagamento" = o cartão já foi cadastrado (mesma regra da cadência, 0278)
  if exists (select 1 from public.os_andamento oa where oa.pedido = btrim(coalesce(new.nio_pedido, new.nio_os)) and oa.estado is not null
               and oa.estado not in ('aguardando_pagamento', 'rascunho', 'cancelada', 'cancelando', 'reprovada')) then return null; end if;
  select * into c from public.mari_conversas where venda_id = new.id and canal = 'whatsapp' order by created_at desc limit 1;
  if c.id is null or coalesce(c.chatwoot_conversation_id, '') = '' or coalesce(c.telefone, '') like '5500000000%'
     or coalesce(c.nao_contatar, false) then return null; end if;
  if c.saida_motivo is not null or c.quadro_encerrada_motivo is not null
     or (c.funil_destino is not null and c.funil_destino not in ('em_andamento')) then return null; end if;
  -- já avisado nesta OS (reemitir o pedido troca a OS e avisa de novo)
  if c.cartao_avisado_em is not null and old.nio_os is not distinct from new.nio_os then return null; end if;
  -- janela fechada: fica com a cadência (CARTAO, por template, depois da agenda).
  if c.ultima_msg_lead_at is null or now() >= c.ultima_msg_lead_at + interval '23 hours' then return null; end if;
  r := public._bo_mensagem(gen_random_uuid(), 1, 'os', new.id, c, 'bo_cartao_link', '{}'::jsonb, null, null,
                           'instrução do cadastro do cartão');
  if r ->> 'status' in ('pendente', 'repetida') then
    update public.mari_conversas set cartao_avisado_em = now() where id = c.id;
  end if;
  return null;
exception when others then
  insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
  values (c.id, '0366 · instrução do cartão', sqlerrm, jsonb_build_object('venda_id', new.id));
  return null;
end $$;
revoke all on function public._cartao_avisar_venda() from public, anon, authenticated;

drop trigger if exists vendas_cartao_aviso on public.vendas;
create trigger vendas_cartao_aviso after update of nio_os, forma_pagamento, biometria_status on public.vendas
  for each row when (new.forma_pagamento = 'cartao' and new.nio_os is not null and new.biometria_status = 'validada' and new.status <> 'saida'
                     and (old.forma_pagamento is distinct from 'cartao' or old.nio_os is distinct from new.nio_os
                          or old.biometria_status is distinct from 'validada'))
  execute function public._cartao_avisar_venda();

commit;

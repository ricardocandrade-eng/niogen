-- NIOGEN | supabase/migrations/0378_saida_cidade_nao_atendida_texto.sql | 24/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 24/11 (conversa L-276, Nelma, #241): "Pode subir para a produção e criar uma mensagem com a saída 'Cidade não atendida'
-- exclusiva pra ela". A Saída "Cidade não atendida" mandava o texto da Fachada ("a fibra ainda não chega no seu endereço… me manda
-- o CEP de outro endereço") — para quem está em Cabo Frio/RJ isso sugere que outro endereço na mesma cidade pode dar.
-- O que muda:
--  (1) config_mari_textos: saida_cidade_nao_atendida e saida_cidade_nao_atendida_indicacao (com o pedido de indicação, como a 0303).
--  (2) _saida_cidade_do_lead(c): a cidade que se diz ao cliente — mari_conversas.cidade (do CEP) ou a cidade_detectada que a Mari
--      marcou no turno (pelo texto); sem nenhuma, "a sua cidade".
--  (3) _porta_sair (= versão no ar): Saída cidade_nao_atendida usa o texto novo; fachada_nao_atendida não muda.
--  (4) _porta_volta_sem_cobertura (= versão no ar): o cliente que volta a escrever depois da Saída por cidade recebe o texto da cidade;
--      o "não repete em 12 h" vale para os dois textos com indicação.
-- Regra 20: (1) sem estado novo — situação, vez e prazo da Saída não mudam; (2) mesma porta (lead_sair → _porta_sair); (3) autor e
-- motivo como antes, na nota; (4) fonte: config_mari_textos; a cidade vem de mari_conversas/mari_turnos; (5) sem número novo — a
-- conferência da Saída é a de sempre; cenário X102. Desempenho: sem impacto (1 subconsulta indexada por conversa, só na Saída).
-- Medir em 7 dias: Saídas "Cidade não atendida" com o texto novo e quantas voltam com CEP de outra cidade.
begin;

insert into public.config_mari_textos (chave, texto) values
  ('saida_cidade_nao_atendida', 'Oi, {nome}! Por enquanto a Nio atende só algumas cidades de Minas, e {cidade} ainda não está entre elas 😕 Por isso não conseguimos abrir o pedido. Se você tiver um endereço numa cidade de Minas, me manda o CEP e o número que a gente confere.'),
  ('saida_cidade_nao_atendida_indicacao', 'Oi, {nome}! Por enquanto a Nio atende só algumas cidades de Minas, e {cidade} ainda não está entre elas 😕 Por isso não conseguimos abrir o pedido. Se você tiver um endereço numa cidade de Minas, me manda o CEP e o número que a gente confere.

E se você conhece alguém em Minas onde a Nio já chega (um parente, um amigo, um colega), me passa o nome e o WhatsApp da pessoa. Se ela instalar a Nio, você ganha R$ 100 no Pix 😉')
on conflict (chave) do update set texto = excluded.texto;

create or replace function public._saida_cidade_do_lead(c public.mari_conversas)
returns text language sql stable security definer set search_path = public as $fn$
  select coalesce(
    nullif(btrim(c.cidade), ''),
    (select nullif(btrim(t.tags ->> 'cidade_detectada'), '') from public.mari_turnos t
      where t.conversa_id = c.id and t.papel = 'mari' and nullif(btrim(t.tags ->> 'cidade_detectada'), '') is not null
      order by t.created_at desc limit 1),
    'a sua cidade');
$fn$;
revoke all on function public._saida_cidade_do_lead(public.mari_conversas) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public._porta_sair(c mari_conversas, v vendas, p_codigo text, p_dados jsonb, p_quem text, p_pede_sub boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  k       public.config_lead;
  sub     text := nullif(btrim(coalesce(p_dados ->> 'sub', '')), '');
  volta   date := nullif(p_dados ->> 'volta', '')::date;
  obs     text := nullif(btrim(coalesce(p_dados ->> 'obs', '')), '');
  cancelou boolean := (p_dados ->> 'cancelou_portal')::boolean;
  aberto  boolean := false;
  quadro  text;
  nc_novo boolean := false;
  feito   text[] := '{}';
  nota    text;
  agora_t text := to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI');
  c2      public.mari_conversas;
  msg     jsonb;
  v_ind   text;   -- 0303: null = pode pedir indicação na mesma mensagem
begin
  select * into k from public.config_lead where parceiro_id = 'dharma' and tipo = 'saida' and codigo = p_codigo;
  if not found then raise exception 'Motivo de saída desconhecido: %', p_codigo; end if;
  if p_pede_sub and k.codigo = 'recusou' and sub is null then
    raise exception 'Diga o porquê da recusa: preço, concorrente, momento, desistiu ou outro.';
  end if;
  if volta is not null and volta <= (now() at time zone 'America/Sao_Paulo')::date then raise exception 'A data de volta precisa ser futura.'; end if;

  -- efeito 1 (venda) e 5
  if v.id is not null then
    if v.instalado_em is not null or v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') then
      raise exception 'Venda instalada não vai para Saída. Cancelamento depois de instalar vem do OSAB.';
    end if;
    aberto := nullif(btrim(v.nio_pedido), '') is not null or nullif(btrim(v.nio_os), '') is not null;
    if aberto and cancelou is null then
      raise exception 'Esta venda tem pedido aberto na Nio. Diga se o pedido já foi cancelado no portal.';
    end if;
    update public.vendas
       set status = 'saida', motivo_saida = k.nome || coalesce(' · ' || sub, '') || coalesce(' — ' || obs, ''),
           interesse_futuro_em = volta, saida_motivo = k.codigo, saida_sub = sub
     where id = v.id;
    if aberto and cancelou then
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (v.id, 'cancelado_no_portal', jsonb_build_object('quando', 'na saída'), auth.uid());
    end if;
  elsif k.codigo in ('reprovado_biometria', 'nio_nao_instalou', 'venda_indevida_fraude') then
    raise exception 'Esse motivo só vale para lead com venda.';
  end if;
  feito := feito || ('Saída · ' || k.nome)::text;
  if aberto and cancelou then feito := feito || 'pedido cancelado no portal (confirmado)'::text;
  elsif aberto then feito := feito || 'falta cancelar o pedido na Nio — a linha fica na Live até confirmar'::text; end if;

  if c.id is not null then
    -- efeito 1 (conversa, junto com a venda)
    quadro := case k.codigo when 'cidade_nao_atendida' then 'fora_area' when 'fachada_nao_atendida' then 'sem_cobertura'
                            when 'nao_contatar' then 'recusou' else k.codigo end;
    nc_novo := k.codigo = 'nao_contatar' and not coalesce(c.nao_contatar, false);
    update public.mari_conversas
       set funil_destino = public._porta_destino_de(k.codigo),
           funil_detalhe = case when k.codigo = 'nao_contatar' then 'não contatar' else 'Saída: ' || k.nome end,
           funil_destino_em = now(), funil_alerta = null, funil_alerta_em = null,
           saida_motivo = k.codigo, saida_sub = sub, saida_volta_em = volta, saida_em = now(),
           quadro_encerrada_motivo = case when v.id is null then quadro else quadro_encerrada_motivo end,
           quadro_encerrada_em = case when v.id is null then now() else quadro_encerrada_em end,
           quadro_encerrada_por = case when v.id is null then auth.uid() else quadro_encerrada_por end,
           nao_contatar = coalesce(nao_contatar, false) or k.codigo = 'nao_contatar',
           credito_resultado = case when k.codigo = 'credito_negado' then 'negado' else credito_resultado end,
           credito_em = case when k.codigo = 'credito_negado' then coalesce(credito_em, now()) else credito_em end,
           processando_ate = null,
           acompanhada_por = null, acompanhada_em = null, acompanhada_visto_em = null   -- 0279: Saída sai do Na mira
     where id = c.id;
    if nc_novo then
      insert into public.mari_turnos (conversa_id, papel, texto, pendente) values (c.id, 'sistema', '[não contatar — saída registrada no NIOGEN]', false);
    end if;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[Saída "' || k.nome || '" registrada no NIOGEN por ' || p_quem || ' — vez de ninguém, sem dono'
            || case when k.codigo = 'nao_contatar' then '; ninguém fala com o cliente]'
                    when public.lead_situacao('x', 'saida', k.codigo, false, null) = 'saida_pode_voltar' then '; se o cliente escrever, a Mari responde]'
                    else ']' end, false);
    -- efeitos 2 e 3
    perform public._porta_soltar(c.id, 'Saída "' || k.nome || '" registrada no NIOGEN');
    feito := feito || 'vez de ninguém, sem dono'::text || 'cadência parada'::text;

  -- 0303 (Ricardo, 18/11 ~23h: "pode incluir o crédito negado também"): Saída "Crédito negado" avisa com educação e pede indicação
  -- na mesma mensagem — só para quem pode receber o pedido; fora disso nada sai, como antes.
  if k.codigo = 'credito_negado' and c.id is not null and coalesce((public._ind_cfg() ->> 'pedir_sem_compra')::boolean, false) then
    select * into c2 from public.mari_conversas where id = c.id;
    if public._ind_pode_pedir(c2) is null then
      msg := public._bo_mensagem(gen_random_uuid(), 1, 'saida', v.id, c2, 'saida_credito_indicacao',
               jsonb_build_object('nome', coalesce(nullif(split_part(btrim(coalesce(c2.dados ->> 'nome', '')), ' ', 1), ''), 'tudo bem')),
               null, null, 'aviso de Saída por crédito negado (com pedido de indicação)');
      if msg ->> 'motivo' is null and coalesce(msg ->> 'status', '') <> 'repetida' then
        insert into public.indicacao_pedidos (conversa_id, venda_id, motivo, sub) values (c2.id, v.id, 'saida_credito', k.codigo);
        feito := feito || 'cliente avisado do crédito e convidado a indicar'::text;
      else
        feito := feito || ('aviso do crédito não saiu (' || coalesce(msg ->> 'motivo', msg ->> 'status', '?') || ')')::text;
      end if;
    end if;
  end if;
    -- efeito 4
    nota := case when k.codigo = 'nao_contatar' then '🚫 Saída · ' || k.nome || ' — ' || p_quem || ', ' || agora_t || '. Ninguém fala com este cliente.'
                 when public.lead_situacao('x', 'saida', k.codigo, false, null) = 'saida_pode_voltar'
                   then '⛔ Saída · ' || k.nome || ' — ' || p_quem || ', ' || agora_t || '. Sem dono. Se o cliente escrever de novo, a Mari responde.'
                 else '⛔ Saída · ' || k.nome || ' — ' || p_quem || ', ' || agora_t || '. Saída definitiva: não reabre.' end;
    feito := feito || public._porta_projetar(c.id, 'saida', nota);
    -- 0279 (caso Felix, 18/11): Saída por falta de cobertura avisa o cliente na hora — antes ninguém contava e ele achava que o pedido andava.
    if k.codigo in ('fachada_nao_atendida', 'cidade_nao_atendida') and not coalesce(c.nao_contatar, false) then
      select * into c from public.mari_conversas where id = c.id;
      v_ind := case when coalesce((public._ind_cfg() ->> 'pedir_sem_compra')::boolean, false) then public._ind_pode_pedir(c) else 'desligado' end;
      -- 0378 (L-276, Ricardo 24/11: "criar uma mensagem com a saída 'Cidade não atendida' exclusiva pra ela"): cidade fora da área
      -- tem texto próprio (a cidade, não a rua); fachada continua com o texto de sempre.
      msg := public._bo_mensagem(gen_random_uuid(), 1, 'saida', v.id, c,
               case when k.codigo = 'cidade_nao_atendida'
                    then case when v_ind is null then 'saida_cidade_nao_atendida_indicacao' else 'saida_cidade_nao_atendida' end
                    else case when v_ind is null then 'saida_sem_cobertura_indicacao' else 'saida_sem_cobertura' end end,   -- 0303
               jsonb_build_object('nome', coalesce(nullif(split_part(btrim(coalesce(c.dados ->> 'nome', '')), ' ', 1), ''), 'tudo bem'),
                                  'cidade', public._saida_cidade_do_lead(c)),
               null, null, case when k.codigo = 'cidade_nao_atendida' then 'aviso de Saída por cidade não atendida' else 'aviso de Saída por falta de cobertura' end);
      if msg ->> 'motivo' is null and coalesce(msg ->> 'status', '') <> 'repetida' then
        update public.mari_conversas set dados = coalesce(dados, '{}'::jsonb) || jsonb_build_object('cobertura_avisada_em', now()) where id = c.id;
        feito := feito || case when k.codigo = 'cidade_nao_atendida' then 'cliente avisado: a cidade não é atendida' else 'cliente avisado: a Nio não chega no endereço' end;
        if v_ind is null then   -- 0303: o pedido de indicação foi na mesma mensagem
          insert into public.indicacao_pedidos (conversa_id, venda_id, motivo, sub) values (c.id, v.id, 'saida_sem_cobertura', k.codigo);
          feito := feito || 'pediu indicação na mesma mensagem'::text;
        end if;
      else
        feito := feito || ('aviso ao cliente não saiu (' || coalesce(msg ->> 'motivo', msg ->> 'status', '?') || '): mande à mão')::text;
      end if;
    end if;
  end if;
  -- 0274 (casos Janaina e Greiciele, Ricardo 18/11): "Sem resposta" sem Retomada feita desde a última fala do cliente → a Mari
  -- faz a Retomada (D3 → Ligar → D7 → D15). Se o cliente responder, reabre como sempre; se não, no fim a Saída fica.
  -- 0280 (Ricardo, 18/11: "Liga a Retomada para desistiu e sem motivo"): Saída "Recusou · desistiu" e "Recusou" sem motivo também
  -- passam pela Retomada (config_retomada: recusou:desistiu e recusou: ligam; preço, concorrente e outro não; momento tem a data de volta).
  if (k.codigo = 'sem_resposta' or (k.codigo = 'recusou' and coalesce(sub, '') in ('', 'desistiu'))) and c.id is not null then
    select * into c2 from public.mari_conversas where id = c.id;
    if (c2.retomada_desde is null or (c2.retomada_fim_em is not null and c2.retomada_desde < coalesce(c2.ultima_msg_lead_at, '-infinity'::timestamptz)))
       and public._retomada_nao_liga(c2) is null then
      perform public._retomada_iniciar(c2, case when k.codigo = 'recusou' then 'saida_recusou' else 'saida_sem_resposta' end, p_quem);
      feito := feito || 'a Mari faz a Retomada (D3 → Ligar → D7 → D15); se ninguém responder, a Saída fica'::text;
    end if;
  end if;
  if volta is not null then feito := feito || ('volta para a Live em ' || to_char(volta, 'DD/MM'))::text; end if;
  return jsonb_build_object('ok', true, 'feito', to_jsonb(feito), 'pedido_aberto', aberto and not coalesce(cancelou, false),
                            'resumo', '✓ ' || array_to_string(feito, ' · '));
end $function$;

CREATE OR REPLACE FUNCTION public._porta_volta_sem_cobertura(c mari_conversas, p_texto text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  msg jsonb; feito text[] := '{}';
  r   jsonb;   -- 0303
begin
  -- 0303: o aviso da Saída pediu indicação e o cliente mandou um WhatsApp → anota a indicação e agradece (a conversa volta a fechar)
  r := public._ind_resposta_saida(c, p_texto);
  if r is not null then return r; end if;
  if coalesce(p_texto, '') ~ '[0-9]{5}-?[0-9]{3}' then
    -- mandou um CEP: pode ser outro endereço (venda!) → o time refaz a viabilidade; a conversa fica aberta com a nota
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[cliente mandou um CEP depois da Saída por falta de cobertura — com o time: refazer a viabilidade]', false);
    feito := feito || 'CEP novo: com o time'::text
             || public._porta_projetar(c.id, 'cliente_voltou', '📍 O cliente mandou um CEP depois da Saída por falta de cobertura. Refaça a viabilidade com o endereço novo; se for viável, use Reabrir. A Mari não responde.', 'open');
  else
    -- qualquer outra fala: a resposta honesta (não repete em 12 h) e a conversa volta a fechar — a Mari não responde
    if exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'mensagem'
                and a.status in ('pendente', 'executando', 'feita')
                and a.payload ->> 'texto_chave' in ('saida_sem_cobertura_indicacao', 'saida_cidade_nao_atendida_indicacao')   -- 0378
                and a.criada_em > now() - interval '12 hours') then
      msg := jsonb_build_object('status', 'repetida');   -- 0303: o aviso da Saída (texto com o pedido de indicação) saiu há menos de 12 h
    else
      -- 0378: quem saiu por cidade não atendida recebe o texto da cidade, não o da rua
      msg := public._bo_mensagem(gen_random_uuid(), 1, 'cliente_voltou', c.venda_id, c,
               case when c.saida_motivo = 'cidade_nao_atendida' then 'saida_cidade_nao_atendida' else 'saida_sem_cobertura' end,
               jsonb_build_object('nome', public.mari_cadencia_nome(c), 'cidade', public._saida_cidade_do_lead(c)), null, null,
               case when c.saida_motivo = 'cidade_nao_atendida' then 'aviso de cidade não atendida (cliente voltou)' else 'aviso de falta de cobertura (cliente voltou)' end);
    end if;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[cliente voltou a escrever depois da Saída por falta de cobertura — não reabre; '
            || case when msg ->> 'status' = 'repetida' then 'o aviso já saiu nas últimas 12 h' else 'resposta: a Nio ainda não chega no endereço' end || ']', false);
    feito := feito || 'cliente avisado: a Nio não chega no endereço'::text
             || public._porta_projetar(c.id, 'cliente_voltou', '📍 O cliente voltou a escrever depois da Saída por falta de cobertura. A Mari não reabre; ele recebeu a resposta de que a Nio ainda não chega no endereço. Se mandar outro endereço (CEP), a conversa abre para você.');
    -- fecha de novo depois da resposta (como o refechar da 0249: não confia no espelho do Chatwoot, que pode chegar depois)
    if not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'resolver' and a.status in ('pendente', 'executando')) then
      perform public._bo_enfileirar(gen_random_uuid(), 1, 'refechar', c.venda_id, c, 'resolver', jsonb_build_object('status', 'resolved'),
                                    now() + interval '2 minutes');
    end if;
  end if;
  return jsonb_build_object('ok', true, 'feito', to_jsonb(feito), 'resumo', '✓ ' || array_to_string(feito, ' · '));
end $function$;

do $chk$
begin
  if (select count(*) from public.config_mari_textos where chave in ('saida_cidade_nao_atendida', 'saida_cidade_nao_atendida_indicacao')) <> 2 then
    raise exception '0378: textos novos não entraram';
  end if;
  if position('saida_cidade_nao_atendida' in pg_get_functiondef('public._porta_sair'::regproc)) = 0
     or position('saida_cidade_nao_atendida' in pg_get_functiondef('public._porta_volta_sem_cobertura'::regproc)) = 0 then
    raise exception '0378: funções não trocaram';
  end if;
end $chk$;

commit;

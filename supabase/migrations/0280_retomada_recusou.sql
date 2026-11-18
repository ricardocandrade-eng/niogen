-- NIOGEN | supabase/migrations/0280_retomada_recusou.sql | 18/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 18/11 (caso Silvanio, Saída "Recusou · desistiu" com a cadência parada): "Liga a Retomada para desistiu e sem motivo".
-- Até aqui a Saída "Recusou" nunca ligava a Retomada (0274: só "Sem resposta"; "recusou:momento" tem a data de volta).
--  (1) config_retomada: recusou:desistiu e recusou: (sem motivo) ligam; a linha "recusou" (preço, concorrente, outro) continua não ligando.
--  (2) _porta_sair: Saída "Recusou" desistiu ou sem motivo, dada pelo time, liga a Retomada (D3 → Ligar → D7 → D15), como a "Sem resposta";
--      se o cliente responder, reabre como sempre; se não, a Saída "Recusou" fica.
--  (3) _retomada_iniciar: a nota diz a origem (Saída "Recusou").
--  (4) limpeza: quem foi para a Saída antes da 0279 sai do "👀 Acompanhar" (caso souzalucimar no Na mira).
-- Recusa dada pela própria Mari (o cliente disse "não quero") não entra: não passa por _porta_sair.
-- Regra 20: (1) nenhuma situação nova (Saída com Retomada já existe); (2) a Retomada tem fim (D15 + 48 h); (3) pela porta, com autor;
-- (4) a Saída é do time; (5) conferência: cenário X23 no portão. Tela Live: sem mudança (o item "Retomada · ligar" já existe).
begin;

insert into public.config_retomada (chave, liga, nome, nota, ordem) values
  ('recusou:desistiu', true, 'Recusou: desistiu', 'Ricardo, 18/11: liga', 31),
  ('recusou:',         true, 'Recusou sem motivo', 'Ricardo, 18/11: liga', 32)
on conflict (chave) do update set liga = excluded.liga, nome = excluded.nome, nota = excluded.nota, ordem = excluded.ordem;
update public.config_retomada set nome = 'Recusou (preço, concorrente, outro)', nota = 'decisão de 18/11: não liga (desistiu e sem motivo ligam — 0280)'
 where chave = 'recusou';

-- (4) limpeza (0279 em diante a Saída já desliga o "👀 Acompanhar"): quem foi para a Saída antes continua no Na mira — sai agora
update public.mari_conversas set acompanhada_por = null, acompanhada_em = null, acompanhada_visto_em = null
 where acompanhada_por is not null and coalesce(funil_destino, 'em_andamento') not in ('em_andamento', 'instalada');

create or replace function public._retomada_iniciar(c public.mari_conversas, p_origem text, p_quem text default null) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare g uuid := gen_random_uuid(); dono text := nullif(btrim(coalesce(c.chatwoot_agente, '')), '');
begin
  update public.mari_conversas
     set retomada_desde = now(), retomada_origem = p_origem, retomada_passo = null, retomada_passo_em = null,
         retomada_fim_em = null, retomada_fim = null, retomada_dono = dono
   where id = c.id;
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[Retomada: o cliente parou de responder' || case p_origem when 'time_sem_resposta' then ' ao time' else '' end
          || ' — a Mari retoma o contato (D3 → Ligar → D7 → D15)' || coalesce('; dono guardado: ' || dono, '')
          || coalesce('; pedido por ' || p_quem, '') || ']', false);
  if c.canal = 'whatsapp' and coalesce(c.chatwoot_conversation_id, '') <> '' and coalesce(c.telefone, '') not like '5500000000%' then
    perform public._bo_enfileirar(g, 1, 'retomada', c.venda_id, c, 'nota', jsonb_build_object('content',
      '↩ Retomada: ' || case p_origem when 'time_sem_resposta' then 'o cliente não responde ao time há 24 h úteis'
                                      when 'saida_recusou' then 'Saída "Recusou"' || coalesce(' · ' || c.saida_sub, ' (sem motivo)')
                                      else 'Saída "Sem resposta"' end
      || ' — a Mari manda o D3 agora (em horário), o D7 e o D15; no D3 + 1 dia o NIOGEN pede para ligar. '
      || case when dono is not null then 'Se o cliente responder, a conversa volta para ' || dono || '.'
              else 'Se o cliente responder, a Mari atende.' end));
  end if;
  return jsonb_build_object('ok', true, 'origem', p_origem);
end $$;

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
    -- efeito 4
    nota := case when k.codigo = 'nao_contatar' then '🚫 Saída · ' || k.nome || ' — ' || p_quem || ', ' || agora_t || '. Ninguém fala com este cliente.'
                 when public.lead_situacao('x', 'saida', k.codigo, false, null) = 'saida_pode_voltar'
                   then '⛔ Saída · ' || k.nome || ' — ' || p_quem || ', ' || agora_t || '. Sem dono. Se o cliente escrever de novo, a Mari responde.'
                 else '⛔ Saída · ' || k.nome || ' — ' || p_quem || ', ' || agora_t || '. Saída definitiva: não reabre.' end;
    feito := feito || public._porta_projetar(c.id, 'saida', nota);
    -- 0279 (caso Felix, 18/11): Saída por falta de cobertura avisa o cliente na hora — antes ninguém contava e ele achava que o pedido andava.
    if k.codigo in ('fachada_nao_atendida', 'cidade_nao_atendida') and not coalesce(c.nao_contatar, false) then
      select * into c from public.mari_conversas where id = c.id;
      msg := public._bo_mensagem(gen_random_uuid(), 1, 'saida', v.id, c, 'saida_sem_cobertura',
               jsonb_build_object('nome', coalesce(nullif(split_part(btrim(coalesce(c.dados ->> 'nome', '')), ' ', 1), ''), 'tudo bem')),
               null, null, 'aviso de Saída por falta de cobertura');
      if msg ->> 'motivo' is null and coalesce(msg ->> 'status', '') <> 'repetida' then
        update public.mari_conversas set dados = coalesce(dados, '{}'::jsonb) || jsonb_build_object('cobertura_avisada_em', now()) where id = c.id;
        feito := feito || 'cliente avisado: a Nio não chega no endereço'::text;
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

commit;

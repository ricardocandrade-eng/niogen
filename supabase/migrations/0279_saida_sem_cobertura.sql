-- NIOGEN | supabase/migrations/0279_saida_sem_cobertura.sql | 18/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 18/11: "Sim, construa". Dois casos de hoje com a mesma raiz — a Saída por falta de cobertura não era tratada como tal:
--  · Felix: o time deu Saída "Fachada não atendida" (17/11 13h45) sem ninguém avisar o cliente; ele escreveu "Vou ter internet esta
--    semana?", a Saída "pode voltar" reabriu a venda com a Mari e ela prometeu instalação a partir de 21/11 (sem viabilidade).
--  · Danizinha: em Saída "sem cobertura" e mesmo assim na Live como 🔥 Oportunidade ("Janela de 24 h fecha em 2 h").
-- O que muda:
--  (1) _porta_sair: Saída "Fachada não atendida" ou "Cidade não atendida" manda ao cliente, na hora, a mensagem saida_sem_cobertura
--      (com a janela aberta; fechada → o resumo diz "mande à mão"). Marca dados.cobertura_avisada_em.
--  (2) mari_entrada__nucleo: cliente que escreve depois dessa Saída NÃO reabre e a Mari fica calada → evento cliente_escreveu:sem_cobertura.
--  (3) _porta_volta_sem_cobertura: o cliente recebe a resposta honesta (não repete em 12 h) e a conversa volta a fechar em 2 min; se
--      ele mandou um CEP (outro endereço = pode ser venda), a conversa fica aberta para o time refazer a viabilidade. O lead continua
--      em Saída (o Reabrir do time continua exigindo viabilidade, 0227 D5).
--  (4) v_oportunidades: lead em Saída não vira oportunidade na Live (casos Danizinha, Julia, Julio — só o filtro; a tela não muda).
--  (5) _porta_sair: a Saída desliga o "👀 Acompanhar" (caso souzalucimar: em Saída "Sem resposta" e ainda no Na mira da Live).
-- Regra 20: (1) nenhuma situação nova; (2) CEP novo vai ao time com a nota (conversa aberta); (3) tudo pela porta, com evento e
-- autor; (4) a cobertura vem da viabilidade do portal gravada pelo time; (5) conferência: cenário X22 no portão. Tela Live: só o filtro
-- das oportunidades e o Na mira (Saída não aparece) — sem mudança de tela.
begin;

insert into public.config_mari_textos (chave, texto) values
  ('saida_sem_cobertura', 'Oi, {nome}! Conferimos no sistema da Nio e, infelizmente, a fibra ainda não chega no seu endereço — por isso não conseguimos abrir o pedido agora. Desculpe a espera 🙏 Se você tiver outro endereço para instalar, me manda o CEP e o número que a gente confere.')
on conflict (chave) do update set texto = excluded.texto;

insert into public.config_evento (codigo, nome, funcao, quem, nota) values
  ('cliente_escreveu:sem_cobertura', 'Cliente escreveu depois da Saída por falta de cobertura', 'mari_entrada', 'cliente', '0279: não reabre; aviso uma vez, depois o time')
on conflict (codigo) do update set nome = excluded.nome, funcao = excluded.funcao, quem = excluded.quem, nota = excluded.nota;

insert into public.config_transicao (evento, de, para, aceito, frase, nota, exige) values
  ('cliente_escreveu:sem_cobertura', 'saida_pode_voltar', '{=}', true, null, '0279 (caso Felix): Saída por cobertura não reabre com a Mari', null)
on conflict (evento, de) do update set para = excluded.para, aceito = excluded.aceito, frase = excluded.frase, nota = excluded.nota, exige = excluded.exige;

create or replace function public._porta_volta_sem_cobertura(c public.mari_conversas, p_texto text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  msg jsonb; feito text[] := '{}';
begin
  if coalesce(p_texto, '') ~ '[0-9]{5}-?[0-9]{3}' then
    -- mandou um CEP: pode ser outro endereço (venda!) → o time refaz a viabilidade; a conversa fica aberta com a nota
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[cliente mandou um CEP depois da Saída por falta de cobertura — com o time: refazer a viabilidade]', false);
    feito := feito || 'CEP novo: com o time'::text
             || public._porta_projetar(c.id, 'cliente_voltou', '📍 O cliente mandou um CEP depois da Saída por falta de cobertura. Refaça a viabilidade com o endereço novo; se for viável, use Reabrir. A Mari não responde.', 'open');
  else
    -- qualquer outra fala: a resposta honesta (não repete em 12 h) e a conversa volta a fechar — a Mari não responde
    msg := public._bo_mensagem(gen_random_uuid(), 1, 'cliente_voltou', c.venda_id, c, 'saida_sem_cobertura',
             jsonb_build_object('nome', public.mari_cadencia_nome(c)), null, null, 'aviso de falta de cobertura (cliente voltou)');
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
end $$;
revoke execute on function public._porta_volta_sem_cobertura(public.mari_conversas, text) from public, anon, authenticated;

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
  if k.codigo = 'sem_resposta' and c.id is not null then
    select * into c2 from public.mari_conversas where id = c.id;
    if (c2.retomada_desde is null or (c2.retomada_fim_em is not null and c2.retomada_desde < coalesce(c2.ultima_msg_lead_at, '-infinity'::timestamptz)))
       and public._retomada_nao_liga(c2) is null then
      perform public._retomada_iniciar(c2, 'saida_sem_resposta', p_quem);
      feito := feito || 'a Mari faz a Retomada (D3 → Ligar → D7 → D15); se ninguém responder, a Saída fica'::text;
    end if;
  end if;
  if volta is not null then feito := feito || ('volta para a Live em ' || to_char(volta, 'DD/MM'))::text; end if;
  return jsonb_build_object('ok', true, 'feito', to_jsonb(feito), 'pedido_aberto', aberto and not coalesce(cancelou, false),
                            'resumo', '✓ ' || array_to_string(feito, ' · '));
end $function$;


create or replace function public.porta(p_evento text, p_conversa uuid, p_venda uuid, p_dados jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c       public.mari_conversas;
  v       public.vendas;
  r       record;
  antes   text;
  fam     text := split_part(coalesce(p_evento, ''), ':', 1);
  arg     text := nullif(split_part(coalesce(p_evento, ''), ':', 2), '');
  cliente boolean := p_evento = 'cliente_escreveu';
  quem    text;
  v_opt   timestamptz;
  res     jsonb;
  saidas  jsonb := '{"perdida": "recusou", "recusou": "recusou", "fora_area": "cidade_nao_atendida", "sem_cobertura": "fachada_nao_atendida",
                     "ja_cliente": "ja_cliente_nio", "ja_cliente_nio": "ja_cliente_nio", "credito_negado": "credito_negado",
                     "sem_resposta": "sem_resposta", "teste_duplicada": "teste_duplicada"}'::jsonb;   -- silenciar:<motivo antigo> → motivo de Saída
begin
  if p_conversa is not null then
    select * into c from public.mari_conversas where id = p_conversa for update;
    if not found then raise exception 'Conversa não encontrada.'; end if;
  end if;
  if coalesce(p_venda, c.venda_id) is not null then
    select * into v from public.vendas where id = coalesce(p_venda, c.venda_id) for update;
    if not found then raise exception 'Venda não encontrada.'; end if;
    if c.id is null then
      select * into c from public.mari_conversas where venda_id = v.id and canal = 'whatsapp' order by created_at desc limit 1;
    end if;
  end if;
  if v.id is null and c.id is null then raise exception 'Informe a conversa ou a venda.'; end if;
  quem := coalesce((select u.nome from public.usuarios u where u.id = auth.uid()),
                   case when cliente then 'o cliente' when auth.role() = 'service_role' then 'o sistema' else 'alguém do time' end);

  -- a tabela manda: recusa com a frase, ou segue
  antes := public._porta_situacao(c.id, v.id);
  select * into r from public.porta_prever(antes, p_evento);
  if r.aceito is not true then
    if cliente then return jsonb_build_object('ok', false, 'situacao', antes, 'frase', r.frase); end if;
    raise exception '%', coalesce(r.frase, 'Esta ação não vale nesta situação (' || antes || ').');
  end if;
  if r.exige = 'admin' and coalesce(public.meu_perfil(), '') <> 'admin' then
    raise exception '%', r.frase using errcode = '42501';
  end if;
  if r.exige = 'cliente_escreveu_depois' and c.id is not null then
    select max(t.created_at) into v_opt from public.mari_turnos t
     where t.conversa_id = c.id and t.papel = 'sistema' and t.texto like '[não contatar — cliente escreveu:%';
    if v_opt is not null and not exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead' and t.created_at > v_opt) then
      raise exception '%', r.frase;
    end if;
  end if;

  perform set_config('porta.aplicando', '1', true);   -- os gatilhos antigos do funil não decidem por cima da porta
  if fam = 'saida' then
    res := public._porta_sair(c, v, arg, p_dados, quem, true);
  elsif fam = 'silenciar' and arg = 'suporte_nio' then
    res := public._porta_silenciar(c, quem, false);
  elsif fam = 'silenciar' and arg = 'reativar' then
    res := public._porta_reativar(c, quem);
  elsif fam = 'silenciar' and saidas ? arg then
    res := public._porta_sair(c, v, saidas ->> arg, p_dados, quem, false);
  elsif fam = 'reabrir' then
    res := public._porta_reabrir(c, v, quem, false, coalesce(c.nao_contatar, false));
  elsif fam = 'nao_contatar' then
    res := public._porta_nao_contatar(c, v, p_dados ->> 'origem');
  elsif fam = 'prazo' and arg = 'esperando_fechar' then          -- 0266 (C10)
    res := public._porta_esperando_fechar(c);
  elsif fam = 'prazo' and arg = 'handoff_sem_resposta' then      -- 0266 (C4)
    res := public._porta_handoff_devolver(c);
  elsif cliente and p_dados ->> 'acao' = 'fim_espera' and antes = 'em_espera' then   -- 0266 (C11)
    res := public._porta_fim_espera(c);
  elsif fam = 'cliente_escreveu' and arg = 'sem_cobertura' then   -- 0279 (caso Felix): Saída por cobertura não reabre
    res := public._porta_volta_sem_cobertura(c, p_dados ->> 'texto');
  elsif cliente and p_dados ->> 'acao' = 'reabrir' and antes = 'saida_pode_voltar' then
    res := public._porta_reabrir(c, v, quem, true, false);
  elsif cliente and p_dados ->> 'acao' = 'silenciar' and antes = 'cliente_nio' then
    res := public._porta_silenciar(c, quem, true);
  else
    perform set_config('porta.aplicando', '', true);
    if cliente then return jsonb_build_object('ok', false, 'situacao', antes); end if;
    raise exception 'Evento ainda não passa pela porta: %', p_evento;
  end if;
  perform set_config('porta.aplicando', '', true);
  return res;
end $$;
revoke execute on function public.porta(text, uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.porta(text, uuid, uuid, jsonb) to service_role;

CREATE OR REPLACE FUNCTION public.mari_entrada__nucleo(p_telefone text, p_nome text, p_texto text, p_canal text DEFAULT 'teste'::text, p_origem text DEFAULT NULL::text, p_chatwoot_conversation_id text DEFAULT NULL::text, p_midia jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_tel  text := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  v_conv public.mari_conversas;
  v_ts   timestamptz := clock_timestamp();
  v_orig text := case when p_origem in ('meta_ads', 'instagram', 'facebook', 'site', 'fila_vero', 'indicacao', 'direto', 'teste') then p_origem end;
  v_cw   text := nullif(btrim(coalesce(p_chatwoot_conversation_id, '')), '');
  v_pos  boolean;
  v_opt  boolean;
  v_sil  boolean := false;   -- 0261: silenciada (cliente Nio)
  v_cob  boolean := false;   -- 0279: volta depois de Saída por falta de cobertura (a Mari não responde)
  v_g    uuid;   -- 0155: cliente pediu para parar (SAIR, PARAR…)
  v_posv boolean;   -- 0155: cliente já instalado → pós-venda, com o time
begin
  if v_tel !~ '^\d{10,15}$' then
    raise exception 'telefone inválido' using errcode = '22023';
  end if;

  select * into v_conv from public.mari_conversas
   where telefone = v_tel and canal = p_canal and status in ('ativo', 'handoff_realizado')
   for update;

  -- 0155 (D2): quem saiu pelo fim da cadência (encerrado_ia) e volta a escrever reaproveita a mesma linha, no mesmo degrau.
  if not found then
    update public.mari_conversas m
       set status = 'ativo', etapa = 'retomada', cadencia_passo = 'nenhum', cadencia_proximo_em = null,
           ciclo_anterior = jsonb_strip_nulls(jsonb_build_object('motivo', m.handoff_motivo, 'em', m.handoff_em, 'encerrado_em', now(),
                              'origem', 'cliente voltou depois do fim da cadência', 'venda_id', m.venda_id)),
           ciclos_encerrados = coalesce(m.ciclos_encerrados, 0) + 1,
           handoff_motivo = null, handoff_em = null, handoff_briefing = null, chatwoot_resolvida = false, processando_ate = null,
           chatwoot_conversation_id = coalesce(v_cw, m.chatwoot_conversation_id)
     where m.id = (select x.id from public.mari_conversas x
                    where x.telefone = v_tel and x.canal = p_canal and x.status = 'encerrado_ia'
                    order by x.updated_at desc limit 1)
    returning * into v_conv;
    if found then
      insert into public.mari_turnos (conversa_id, papel, texto, pendente)
      values (v_conv.id, 'sistema', '[cliente voltou depois do fim da cadência — a conversa segue de onde parou]', false);
    end if;
  end if;

  if not found then
    insert into public.mari_conversas (telefone, nome_contato, canal, origem, chatwoot_conversation_id)
    values (v_tel, nullif(btrim(p_nome), ''), p_canal,
            coalesce(v_orig, case when p_canal = 'teste' then 'teste' else 'direto' end),
            p_chatwoot_conversation_id)
    returning * into v_conv;
  elsif v_conv.origem = 'direto' and v_orig in ('meta_ads', 'instagram', 'facebook', 'site', 'fila_vero', 'indicacao') then
    -- 0033: conversa que já existia sem origem conhecida ganha a 1ª origem identificada (link (IG)/(FB) ou anúncio).
    update public.mari_conversas set origem = v_orig where id = v_conv.id returning * into v_conv;
  end if;

  if v_conv.status = 'handoff_realizado' and p_canal = 'whatsapp' and v_cw is not null
        and v_conv.chatwoot_conversation_id is distinct from v_cw then
    perform public._mari_fechar_ciclo(v_conv.id, 'nova conversa no Chatwoot (' || v_cw || ')');
    update public.mari_conversas set chatwoot_conversation_id = v_cw
     where id = v_conv.id returning * into v_conv;
  end if;
  -- 0259 (A4, conferência da sombra): também com a conversa ATIVA (ex.: Saída "pode voltar", que fica ativa) — o cliente escreveu
  -- numa conversa nova do Chatwoot e o NIOGEN seguia mandando etiquetas, notas, mensagens e "resolver" na antiga, já resolvida.
  if p_canal = 'whatsapp' and v_cw is not null and v_conv.chatwoot_conversation_id is distinct from v_cw then
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (v_conv.id, 'sistema', '[o cliente escreveu numa conversa nova do Chatwoot (' || v_cw || ', antes ' || coalesce(v_conv.chatwoot_conversation_id, '—')
            || ') — o NIOGEN passa a usar a nova]', false);
    update public.mari_conversas set chatwoot_conversation_id = v_cw, chatwoot_status = 'open', chatwoot_agente = null, chatwoot_time = null,
           chatwoot_etiquetas = '{}'
     where id = v_conv.id returning * into v_conv;
  end if;

  -- 0167 (Ricardo, 13/11; conversa #86): a Mari avisou "sem cobertura" e convidou o cliente a mandar o CEP ou o número certo.
  -- Se ele volta a escrever e ninguém do time assumiu, a conversa reabre na etapa do endereço para a Mari conferir de novo —
  -- até 3 voltas por conversa. dados.sem_cobertura_avisado guarda a hora do veredito: enquanto o endereço for o mesmo, a Mari
  -- sabe que já avisou e não repete; endereço novo zera o veredito (gatilho da 0133) e a consulta sai de novo.
  if v_conv.status = 'handoff_realizado' and v_conv.handoff_motivo = 'sem_cobertura' and v_conv.cobertura_decisao = 'sem_cobertura'
     and v_conv.cobertura_em is not null
     and not coalesce(v_conv.humano_atribuido, false) and v_conv.chatwoot_agente is null and not coalesce(v_conv.nao_contatar, false)
     and coalesce(case when v_conv.dados->>'sem_cobertura_voltas' ~ '^[0-9]+$' then (v_conv.dados->>'sem_cobertura_voltas')::int end, 0) < 3
     and not public._mari_optout(p_texto)
     and not exists (select 1 from public.mari_turnos t
                      where t.conversa_id = v_conv.id and t.papel = 'humano' and t.created_at > v_conv.handoff_em) then
    update public.mari_conversas m
       set status = 'ativo', etapa = 'endereco', handoff_motivo = null, handoff_em = null, handoff_briefing = null,
           chatwoot_resolvida = false,
           dados = coalesce(m.dados, '{}'::jsonb) || jsonb_build_object(
             'sem_cobertura_avisado', floor(extract(epoch from m.cobertura_em))::bigint,
             'sem_cobertura_voltas', coalesce(case when m.dados->>'sem_cobertura_voltas' ~ '^[0-9]+$' then (m.dados->>'sem_cobertura_voltas')::int end, 0) + 1)
     where m.id = v_conv.id
    returning * into v_conv;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (v_conv.id, 'sistema', '[cliente voltou a escrever depois do aviso de sem cobertura — a Mari confere o endereço de novo]', false);
  end if;

  -- 0189 (Ricardo, 13/11; conversa #39, Waldir): saiu por recusa (ou por sem contato), clicou no anúncio de novo e a Mari
  -- ficou muda. Recusa não é pedido de parar: quem volta a escrever reabre na retomada, com a Mari. Não reabre se alguém do
  -- time é o dono, se o time falou nas últimas 12 h, se o cliente pediu para parar, nem na despedida logo depois da saída.
  if v_conv.status = 'handoff_realizado' and v_conv.handoff_motivo in ('recusa_compra', 'sem_contato')
     and not coalesce(v_conv.humano_atribuido, false) and v_conv.chatwoot_agente is null and not coalesce(v_conv.nao_contatar, false)
     and not public._mari_optout(p_texto)
     and coalesce(v_conv.handoff_em, '-infinity') < now() - interval '30 minutes'
     and not exists (select 1 from public.mari_turnos t
                      where t.conversa_id = v_conv.id and t.papel = 'humano' and t.created_at > now() - interval '12 hours') then
    perform public._mari_fechar_ciclo(v_conv.id, 'cliente voltou a escrever depois da saída');
    update public.mari_conversas set chatwoot_resolvida = false where id = v_conv.id returning * into v_conv;
  end if;

  -- 0265 (passo 5): a volta do cliente em Saída passa pela porta. "Pode voltar" (recusou, sem resposta…) e escreveu de verdade
  -- (não só "ok, obrigado") mais de 30 min depois da Saída → reabre onde parou, com a Mari. Definitiva, Não contatar e cliente
  -- Nio não reabrem (a tabela diz). Era o ramo "cliente voltou a escrever" do _funil_antes, que saiu.
  -- 0279 (caso Felix, 18/11): Saída dada pelo time por falta de cobertura (fachada ou cidade não atendida) NÃO reabre com a Mari —
  -- ela voltava sem saber o motivo e prometia instalação. O cliente recebe a verdade uma vez; se insistir, a conversa vai ao time.
  if coalesce(v_conv.saida_motivo, '') in ('fachada_nao_atendida', 'cidade_nao_atendida')
     and coalesce(v_conv.funil_destino, 'em_andamento') <> 'em_andamento'
     and not coalesce(v_conv.nao_contatar, false) and not public._mari_optout(p_texto)
     and public._porta_situacao(v_conv.id, null::uuid) = 'saida_pode_voltar' then
    v_cob := true;
    if p_midia is not null or not public._saida_so_confirmacao(p_texto) then
      perform public.porta('cliente_escreveu:sem_cobertura', v_conv.id, null::uuid, jsonb_build_object('texto', p_texto));
      select * into v_conv from public.mari_conversas where id = v_conv.id;
    end if;
  end if;

  if not v_cob and coalesce(v_conv.funil_destino, 'em_andamento') not in ('em_andamento', 'instalada', 'teste_duplicada')
     and not coalesce(v_conv.nao_contatar, false) and not public._mari_optout(p_texto)
     and (p_midia is not null or not public._saida_so_confirmacao(p_texto))
     and coalesce(v_conv.saida_em, v_conv.funil_destino_em, '-infinity') < now() - interval '30 minutes'   -- 0189: despedida não reabre
     and public._porta_situacao(v_conv.id, null::uuid) = 'saida_pode_voltar' then
    perform public.porta('cliente_escreveu', v_conv.id, null::uuid, jsonb_build_object('acao', 'reabrir'));
    select * into v_conv from public.mari_conversas where id = v_conv.id;
  end if;

  -- 0261 (Ricardo, 17/11: "Cliente já é Nio, em qualquer situação, educadamente a Mari encerra a conversa, pedindo para procurar os
  -- canais oficiais. Se depois de alguns minutos o cliente insistir, silencie a conversa. Somos uma revenda da Nio"): conversa em
  -- "já é cliente Nio" em que já houve a despedida (a própria Mari deu a Saída, ou falamos depois dela) e o cliente escreve de novo → silenciada.
  if coalesce(v_conv.funil_destino, '') = 'ja_cliente_nio' and coalesce(v_conv.quadro_encerrada_motivo, '') <> 'suporte_nio'
     and (v_conv.handoff_motivo = 'ja_cliente_nio' or v_conv.ciclo_anterior ->> 'motivo' = 'ja_cliente_nio'   -- a Mari se despediu ao dar a Saída
          or exists (select 1 from public.mari_turnos t where t.conversa_id = v_conv.id and t.papel in ('mari', 'humano')
                      and t.created_at > coalesce(v_conv.funil_destino_em, v_conv.handoff_em, v_conv.created_at))) then
    -- 0265: o silêncio é da porta (cliente_escreveu em "Cliente Nio")
    perform public.porta('cliente_escreveu', v_conv.id, null::uuid, jsonb_build_object('acao', 'silenciar'));
    select * into v_conv from public.mari_conversas where id = v_conv.id;
  end if;
  -- 0261: silenciada (cliente Nio) = a Mari não responde, e o time também não (situação 15: ninguém)
  v_sil := coalesce(v_conv.quadro_encerrada_motivo, '') = 'suporte_nio' or v_cob;

  v_pos := public._mari_pos_handoff(v_conv);

  -- 0250 (H2): Não contatar gravado no NIOGEN cala a Mari, mesmo que tirem a etiqueta à mão no Chatwoot
  v_opt  := public._mari_optout(p_texto) or coalesce(v_conv.nao_contatar, false);
  v_posv := coalesce(v_conv.funil_destino, '') = 'instalada';

  insert into public.mari_turnos (conversa_id, papel, texto, pendente, midia)
  values (v_conv.id, 'lead', coalesce(p_texto, ''), (v_conv.status = 'ativo' or v_pos) and not v_opt and not v_posv and not v_sil, public._midia_ok(p_midia));

  update public.mari_conversas
     set ultima_entrada_ts = v_ts,
         ultima_msg_lead_at = now(),
         nome_contato = coalesce(nome_contato, nullif(btrim(p_nome), '')),
         -- 0155: a trava "resolvida" da cadência cai quando o cliente escreve e a conversa segue em andamento
         chatwoot_resolvida = case when coalesce(funil_destino, 'em_andamento') = 'em_andamento' then false else chatwoot_resolvida end
   where id = v_conv.id;

  if v_opt and not coalesce(v_conv.nao_contatar, false) then perform public.conversa_nao_contatar(v_conv.id, 'cliente escreveu: ' || left(btrim(coalesce(p_texto, '')), 40)); end if;
  if v_posv and not v_opt then perform public._mari_pos_venda(v_conv.id); end if;

  return jsonb_build_object(
    'conversa_id', v_conv.id,
    'ts', v_ts,
    'status', v_conv.status,
    'silencio', (v_conv.status <> 'ativo' and not v_pos) or v_opt or v_posv or v_sil,
    'optout', v_opt, 'pos_venda', v_posv,   -- em handoff: humano conduz, Mari calada (salvo a janela 0061)
    'pos_handoff', v_pos,
    'nova', v_conv.created_at >= now() - interval '1 second');
end;
$function$;

create or replace view public.v_oportunidades with (security_invoker = true) as
 WITH cfg AS (
         SELECT COALESCE((g.p ->> 'ligado'::text)::boolean, true) AS ligado,
            COALESCE((g.p ->> 'max_dia'::text)::integer, 5) AS max_dia,
            COALESCE((g.p ->> 'max_por_conversa_dia'::text)::integer, 1) AS max_conv,
            COALESCE((g.p ->> 'max_parado_dias'::text)::numeric, 7::numeric) AS max_dias,
            COALESCE((g.p ->> 'janela_horas'::text)::numeric, 23::numeric) AS janela_h,
            g.p ->> 'template'::text AS tpl,
            COALESCE(g.p -> 'fora_do_teto'::text, '["O7", "O8", "O9"]'::jsonb) AS fora,
            (now() AT TIME ZONE 'America/Sao_Paulo'::text)::date AS hoje
           FROM ( SELECT COALESCE(( SELECT config_oportunidades.parametros
                           FROM config_oportunidades
                          WHERE config_oportunidades.codigo = 'geral'::text), '{}'::jsonb) AS p) g
        ), regra AS (
         SELECT config_oportunidades.codigo,
            config_oportunidades.nome,
            config_oportunidades.pontos,
            config_oportunidades.ordem,
            config_oportunidades.parametros AS p
           FROM config_oportunidades
          WHERE config_oportunidades.ativo AND config_oportunidades.codigo <> 'geral'::text
        ), tpl AS (
         SELECT t.nome
           FROM config_templates_waba t,
            cfg cfg_1
          WHERE t.uso = 'oportunidade'::text AND t.status = 'APPROVED'::text AND (cfg_1.tpl IS NULL OR t.nome = cfg_1.tpl)
          ORDER BY t.nome
         LIMIT 1
        ), feitas_hoje AS (
         SELECT l.conversa_id,
            count(*) AS n
           FROM oportunidades_log l,
            cfg cfg_1
          WHERE (l.tipo = ANY (ARRAY['enviada'::text, 'dispensada'::text])) AND (l.criado_em AT TIME ZONE 'America/Sao_Paulo'::text)::date = cfg_1.hoje
          GROUP BY l.conversa_id
        ), eu AS (
         SELECT NULLIF(split_part(btrim(u.nome), ' '::text, 1), ''::text) AS nome
           FROM usuarios u
          WHERE u.id = auth.uid()
        ), base AS (
         SELECT q.id AS conversa_id,
            q.nome,
            q.cidade,
            q.cluster,
            q.segmento,
            q.coluna,
            q.plano_escolhido,
            q.plano_nome,
            q.itens_validados,
            q.itens_total,
            q.alertas,
            q.trava_viabilidade,
            q.trava_endereco_nio,
            q.ultima_em AS parado_desde,
            c.ultima_msg_lead_at,
            c.forma_pagamento,
            c.dados,
            c.chatwoot_conversation_id,
            c.telefone,
            ( SELECT s.evento FROM porta_sombra s WHERE s.conversa_id = c.id AND (s.evento = ANY (ARRAY['mari_passou:interesse_caindo'::text, 'mari_passou:multiplos_decisores'::text])) ORDER BY s.em DESC LIMIT 1) AS c3_evento,
            ( SELECT max(s.em) FROM porta_sombra s WHERE s.conversa_id = c.id AND (s.evento = ANY (ARRAY['mari_passou:interesse_caindo'::text, 'mari_passou:multiplos_decisores'::text]))) AS c3_em,
            COALESCE(NULLIF(split_part(btrim(c.dados ->> 'nome'::text), ' '::text, 1), ''::text),
                CASE
                    WHEN c.nome_confiavel THEN NULLIF(split_part(btrim(c.nome_contato), ' '::text, 1), ''::text)
                    ELSE NULL::text
                END) AS primeiro_nome,
            ( SELECT mari_cadencia_nome(mc.*) FROM mari_conversas mc WHERE mc.id = c.id) AS nome_template,
            c.ultima_msg_lead_at + cfg_1.janela_h::double precision * '01:00:00'::interval AS janela_fecha_em,
            minutos_uteis(q.ultima_em, now(), q.cidade) AS min_uteis,
            (EXISTS ( SELECT 1
                   FROM mari_turnos t
                  WHERE t.conversa_id = q.id AND t.papel = 'mari'::text AND t.tags ? 'carrossel'::text)) AS viu_planos
           FROM v_mari_quadro q
             JOIN mari_conversas c ON c.id = q.id
             CROSS JOIN cfg cfg_1
          WHERE cfg_1.ligado AND NOT q.teste AND (q.coluna = ANY (ARRAY['novo'::text, 'qualificando'::text, 'planos'::text, 'dados'::text, 'retomada'::text])) AND q.vez = 'cliente'::text AND COALESCE(q.ultima_quem, ''::text) <> 'humano'::text AND q.venda_id IS NULL AND c.canal = 'whatsapp'::text AND COALESCE(c.chatwoot_conversation_id, ''::text) <> ''::text AND NOT COALESCE(c.nao_contatar, false) AND COALESCE(c.funil_destino, 'em_andamento'::text) = 'em_andamento'::text AND NOT COALESCE(c.humano_atribuido, false) AND c.chatwoot_agente IS NULL AND (c.espera_ate IS NULL OR c.espera_ate <= now()) AND q.trava_cliente_nio <> 'bloqueia'::text AND q.trava_viabilidade <> 'bloqueia'::text AND q.trava_endereco_nio <> 'bloqueia'::text AND q.ultima_em > (now() - cfg_1.max_dias::double precision * '1 day'::interval) AND COALESCE(( SELECT f.n
                   FROM feitas_hoje f
                  WHERE f.conversa_id = q.id), 0::bigint) < cfg_1.max_conv AND NOT (EXISTS ( SELECT 1
                   FROM oportunidades_log l
                  WHERE l.conversa_id = q.id AND l.tipo = 'enviada'::text AND l.criado_em > COALESCE(c.ultima_msg_lead_at, '-infinity'::timestamp with time zone)))
        ), bate AS (
         SELECT b.conversa_id,
            b.nome,
            b.cidade,
            b.cluster,
            b.segmento,
            b.coluna,
            b.plano_escolhido,
            b.plano_nome,
            b.itens_validados,
            b.itens_total,
            b.alertas,
            b.trava_viabilidade,
            b.trava_endereco_nio,
            b.parado_desde,
            b.ultima_msg_lead_at,
            b.forma_pagamento,
            b.dados,
            b.chatwoot_conversation_id,
            b.telefone,
            b.primeiro_nome,
            b.nome_template,
            b.janela_fecha_em,
            b.min_uteis,
            b.viu_planos,
            r.codigo,
            r.pontos,
            r.ordem
           FROM base b
             JOIN regra r ON
                CASE r.codigo
                    WHEN 'O1'::text THEN b.janela_fecha_em > now() AND b.janela_fecha_em <= (now() + COALESCE((r.p ->> 'fecha_em_horas'::text)::numeric, 4::numeric)::double precision * '01:00:00'::interval) AND (b.itens_validados >= COALESCE((r.p ->> 'termometro_min'::text)::integer, 2) OR b.viu_planos OR b.coluna = 'planos'::text)
                    WHEN 'O2'::text THEN b.coluna = 'planos'::text AND b.min_uteis::numeric >= (COALESCE((r.p ->> 'min_horas_uteis'::text)::numeric, 2::numeric) * 60::numeric) AND b.parado_desde >= (now() - COALESCE((r.p ->> 'max_horas'::text)::numeric, 48::numeric)::double precision * '01:00:00'::interval)
                    WHEN 'O3'::text THEN ((b.dados ->> 'objecao'::text IN ( SELECT jsonb_array_elements_text(COALESCE(r.p -> 'objecoes'::text, '[]'::jsonb)) AS jsonb_array_elements_text)) OR b.alertas && (ARRAY( SELECT jsonb_array_elements_text(COALESCE(r.p -> 'alertas'::text, '[]'::jsonb)) AS jsonb_array_elements_text))) AND b.min_uteis::numeric >= (COALESCE((r.p ->> 'min_horas_uteis'::text)::numeric, 1::numeric) * 60::numeric)
                    WHEN 'O4'::text THEN b.itens_validados >= COALESCE((r.p ->> 'termometro_min'::text)::integer, 6) AND b.min_uteis::numeric >= (COALESCE((r.p ->> 'min_horas_uteis'::text)::numeric, 1::numeric) * 60::numeric)
                    WHEN 'O5'::text THEN b.trava_viabilidade = 'ok'::text AND b.trava_endereco_nio = 'ok'::text AND b.min_uteis::numeric >= (COALESCE((r.p ->> 'min_horas_uteis'::text)::numeric, 1::numeric) * 60::numeric)
                    WHEN 'O10'::text THEN b.c3_em IS NOT NULL AND b.c3_em > (now() - COALESCE((r.p ->> 'dias'::text)::numeric, 3::numeric)::double precision * '1 day'::interval)
                    ELSE false
                END
        ), agg AS (
         SELECT bate.conversa_id,
            (array_agg(bate.codigo ORDER BY bate.pontos DESC, bate.ordem))[1] AS codigo,
            array_agg(bate.codigo ORDER BY bate.pontos DESC, bate.ordem) AS regras,
            sum(bate.pontos)::integer AS pontos
           FROM bate
          GROUP BY bate.conversa_id
        ), linha AS (
         SELECT a.conversa_id,
            a.codigo,
            a.regras,
            a.pontos,
            b.nome,
            b.primeiro_nome,
            b.nome_template,
            b.cidade,
            b.coluna,
            b.parado_desde,
            b.janela_fecha_em,
            b.chatwoot_conversation_id,
            b.itens_validados,
            b.itens_total,
            b.telefone,
            COALESCE(b.plano_nome, pv.plano) AS plano,
            pv.valor AS valor_mes,
                CASE
                    WHEN b.janela_fecha_em > now() THEN 'livre'::text
                    WHEN (EXISTS ( SELECT 1
                       FROM tpl)) THEN 'template'::text
                    ELSE 'ligar'::text
                END AS canal,
            ( SELECT t.nome
                   FROM tpl t) AS template,
                CASE a.codigo
                    WHEN 'O1'::text THEN ('Janela de 24 h fecha em '::text || _oport_dur(b.janela_fecha_em - now())) ||
                    CASE
                        WHEN b.coluna = 'planos'::text OR b.viu_planos THEN ' · já viu os planos'::text
                        ELSE ''::text
                    END
                    WHEN 'O2'::text THEN ('Viu os planos há '::text || _oport_dur(now() - b.parado_desde)) || ' e não escolheu'::text
                    WHEN 'O3'::text THEN (
                    CASE
                        WHEN 'desconto'::text = ANY (b.alertas) THEN 'Pediu desconto'::text
                        ELSE 'Objeção: '::text || COALESCE(
                        CASE b.dados ->> 'objecao'::text
                            WHEN 'preco'::text THEN 'achou caro'::text
                            WHEN 'pensar'::text THEN 'vai pensar'::text
                            WHEN 'consultar_alguem'::text THEN 'vai ver com alguém'::text
                            WHEN 'ja_tem'::text THEN 'já tem internet'::text
                            WHEN 'marca'::text THEN 'não conhece a Nio'::text
                            WHEN 'sem_5g'::text THEN 'não precisa do 5G'::text
                            ELSE NULL::text
                        END, b.dados ->> 'objecao'::text)
                    END || ' · sem resposta há '::text) || _oport_dur(now() - b.parado_desde)
                    WHEN 'O4'::text THEN (((('Quase pronto: '::text || b.itens_validados) || '/'::text) || b.itens_total) || ' dados · parou há '::text) || _oport_dur(now() - b.parado_desde)
                    WHEN 'O5'::text THEN 'Viabilidade ok e endereço livre · parou há '::text || _oport_dur(now() - b.parado_desde)
                    WHEN 'O10'::text THEN (CASE b.c3_evento WHEN 'mari_passou:multiplos_decisores'::text THEN 'Vai decidir com outra pessoa'::text ELSE 'Interesse caindo'::text END || ' · a Mari segue · sem resposta há '::text) || _oport_dur(now() - b.parado_desde)
                    ELSE NULL::text
                END ||
                CASE
                    WHEN a.codigo <> 'O1'::text AND ('O1'::text = ANY (a.regras)) THEN ' · janela fecha em '::text || _oport_dur(b.janela_fecha_em - now())
                    ELSE ''::text
                END AS motivo
           FROM agg a
             JOIN base b ON b.conversa_id = a.conversa_id
             LEFT JOIN LATERAL _oport_plano(b.plano_escolhido, b.forma_pagamento, b.cluster, b.segmento) pv(plano, valor) ON true
        ), regra_v AS (
         SELECT config_oportunidades.codigo,
            config_oportunidades.pontos,
            config_oportunidades.ordem,
            config_oportunidades.parametros AS p
           FROM config_oportunidades
          WHERE config_oportunidades.ativo AND (config_oportunidades.codigo = ANY (ARRAY['O6'::text, 'O7'::text, 'O8'::text, 'O9'::text]))
        ), vbase AS (
         SELECT v.id AS venda_id,
            v.status,
            v.cliente_nome,
            v.cidade,
            v.motivo_saida,
            v.interesse_futuro_em,
            v.comissao_prevista,
            v.valor_mensal,
            v.instalacao_agendada_para,
            v.instalacao_turno,
            v.agendamento_registrado_em,
            v.dfv_hp_livre,
            v.conferencia_motivo,
            COALESCE(pl.nome_curto, pl.nome) AS plano_nome,
            c.id AS conversa_id,
            c.chatwoot_conversation_id,
            c.telefone,
            COALESCE(NULLIF(split_part(btrim(v.cliente_nome), ' '::text, 1), ''::text), 'tudo bem'::text) AS primeiro_nome,
            mari_cadencia_nome(ROW(c.id, c.telefone, c.nome_contato, c.nome_confiavel, c.canal, c.chatwoot_conversation_id, c.status, c.etapa, c.cep, c.numero, c.complemento, c.endereco_cep, c.cidade, c.uf, c.cluster, c.dentro_area, c.segmento, c.mei, c.elegibilidade, c.dfv_resultado, c.dfv_detalhe, c.plano_escolhido, c.forma_pagamento, c.visita_preferencia, c.dados, c.lgpd_enviada, c.upsell_oferecido, c.nao_contatar, c.ultima_msg_lead_at, c.followup_next_at, c.followup_count, c.agendamento_retorno, c.origem, c.handoff_motivo, c.handoff_em, c.venda_id, c.ultima_entrada_ts, c.processando_ate, c.created_at, c.updated_at, c.ultima_msg_mari_at, c.cadencia_passo, c.cadencia_passo_em, c.cadencia_proximo_em, c.cadencia_retorno_em, c.visita_confirmada_para, c.humano_atribuido, c.time_atribuido, c.chatwoot_resolvida, c.handoff_briefing, c.nio_viab_resultado, c.nio_viab_velocidade, c.nio_viab_interesse_id, c.nio_viab_em, c.instalacao_preferencia, c.nio_viab_endereco_portal, c.bio_lembrete_em, c.instalacao_avisada_para, c.instalacao_avisada_em, c.instalacao_lembrada_para, c.ciclos_encerrados, c.ciclo_anterior, c.chatwoot_status, c.chatwoot_agente, c.chatwoot_time, c.chatwoot_etiquetas, c.chatwoot_sync_em, c.etiqueta_futuro_em, c.etiqueta_futuro_para, c.quadro_encerrada_motivo, c.quadro_encerrada_em, c.quadro_encerrada_por, c.espera_ate, c.espera_motivo, c.espera_em, c.espera_por, NULL::text, NULL::jsonb, NULL::timestamp with time zone, NULL::integer, NULL::text, NULL::timestamp with time zone, NULL::integer, NULL::timestamp with time zone, NULL::text, NULL::timestamp with time zone, NULL::text, NULL::jsonb, NULL::timestamp with time zone, NULL::integer, NULL::timestamp with time zone, NULL::uuid, NULL::text, NULL::text, NULL::text, NULL::timestamp with time zone, NULL::text, NULL::text, NULL::timestamp with time zone, NULL::text, NULL::text, NULL::date, NULL::timestamp with time zone, NULL::timestamp with time zone, NULL::timestamp with time zone, NULL::timestamp with time zone, NULL::jsonb, NULL::timestamp with time zone, NULL::timestamp with time zone, NULL::uuid, NULL::text, NULL::uuid, NULL::timestamp with time zone, NULL::timestamp with time zone, NULL::text, NULL::timestamp with time zone, NULL::jsonb, NULL::jsonb, NULL::timestamp with time zone, NULL::timestamp with time zone, NULL::uuid, NULL::timestamp with time zone, NULL::text, NULL::text, NULL::timestamp with time zone, NULL::timestamp with time zone, NULL::text, NULL::text)) AS nome_template,
            c.ultima_msg_lead_at + cfg_1.janela_h::double precision * '01:00:00'::interval AS janela_fecha_em,
            _oport_chave_motivo(v.motivo_saida, v.saida_motivo, v.saida_sub, v.interesse_futuro_em) AS chave_motivo,
            COALESCE(( SELECT max(e.criado_em) AS max
                   FROM eventos_venda e
                  WHERE e.venda_id = v.id AND e.tipo = 'status'::text AND (e.detalhe ->> 'para'::text) = 'saida'::text), v.criado_em) AS saida_em,
            ic.resposta AS confirmacao
           FROM vendas v
             JOIN LATERAL ( SELECT c2.id,
                    c2.telefone,
                    c2.nome_contato,
                    c2.nome_confiavel,
                    c2.canal,
                    c2.chatwoot_conversation_id,
                    c2.status,
                    c2.etapa,
                    c2.cep,
                    c2.numero,
                    c2.complemento,
                    c2.endereco_cep,
                    c2.cidade,
                    c2.uf,
                    c2.cluster,
                    c2.dentro_area,
                    c2.segmento,
                    c2.mei,
                    c2.elegibilidade,
                    c2.dfv_resultado,
                    c2.dfv_detalhe,
                    c2.plano_escolhido,
                    c2.forma_pagamento,
                    c2.visita_preferencia,
                    c2.dados,
                    c2.lgpd_enviada,
                    c2.upsell_oferecido,
                    c2.nao_contatar,
                    c2.ultima_msg_lead_at,
                    c2.followup_next_at,
                    c2.followup_count,
                    c2.agendamento_retorno,
                    c2.origem,
                    c2.handoff_motivo,
                    c2.handoff_em,
                    c2.venda_id,
                    c2.ultima_entrada_ts,
                    c2.processando_ate,
                    c2.created_at,
                    c2.updated_at,
                    c2.ultima_msg_mari_at,
                    c2.cadencia_passo,
                    c2.cadencia_passo_em,
                    c2.cadencia_proximo_em,
                    c2.cadencia_retorno_em,
                    c2.visita_confirmada_para,
                    c2.humano_atribuido,
                    c2.time_atribuido,
                    c2.chatwoot_resolvida,
                    c2.handoff_briefing,
                    c2.nio_viab_resultado,
                    c2.nio_viab_velocidade,
                    c2.nio_viab_interesse_id,
                    c2.nio_viab_em,
                    c2.instalacao_preferencia,
                    c2.nio_viab_endereco_portal,
                    c2.bio_lembrete_em,
                    c2.instalacao_avisada_para,
                    c2.instalacao_avisada_em,
                    c2.instalacao_lembrada_para,
                    c2.ciclos_encerrados,
                    c2.ciclo_anterior,
                    c2.chatwoot_status,
                    c2.chatwoot_agente,
                    c2.chatwoot_time,
                    c2.chatwoot_etiquetas,
                    c2.chatwoot_sync_em,
                    c2.etiqueta_futuro_em,
                    c2.etiqueta_futuro_para,
                    c2.quadro_encerrada_motivo,
                    c2.quadro_encerrada_em,
                    c2.quadro_encerrada_por,
                    c2.espera_ate,
                    c2.espera_motivo,
                    c2.espera_em,
                    c2.espera_por
                   FROM mari_conversas c2
                  WHERE c2.venda_id = v.id AND c2.canal = 'whatsapp'::text AND COALESCE(c2.chatwoot_conversation_id, ''::text) <> ''::text
                  ORDER BY c2.updated_at DESC NULLS LAST
                 LIMIT 1) c ON true
             LEFT JOIN config_planos pl ON pl.id = v.plano_id
             LEFT JOIN v_instalacao_confirmacao ic ON ic.venda_id = v.id
             CROSS JOIN cfg cfg_1
          WHERE cfg_1.ligado AND (v.status = ANY (ARRAY['saida'::text, '2_aguardando_instalacao'::text])) AND NOT COALESCE(c.nao_contatar, false) AND COALESCE(c.telefone, ''::text) !~~ '5500000000%'::text AND COALESCE(( SELECT f.n
                   FROM feitas_hoje f
                  WHERE f.conversa_id = c.id), 0::bigint) < cfg_1.max_conv
        ), vbate AS (
         SELECT b.venda_id,
            b.status,
            b.cliente_nome,
            b.cidade,
            b.motivo_saida,
            b.interesse_futuro_em,
            b.comissao_prevista,
            b.valor_mensal,
            b.instalacao_agendada_para,
            b.instalacao_turno,
            b.agendamento_registrado_em,
            b.dfv_hp_livre,
            b.conferencia_motivo,
            b.plano_nome,
            b.conversa_id,
            b.chatwoot_conversation_id,
            b.telefone,
            b.primeiro_nome,
            b.nome_template,
            b.janela_fecha_em,
            b.chave_motivo,
            b.saida_em,
            b.confirmacao,
            r.codigo,
            r.pontos,
            r.ordem,
            x.volta_em
           FROM vbase b
             CROSS JOIN regra_v r
             CROSS JOIN LATERAL ( SELECT
                        CASE
                            WHEN r.codigo = 'O6'::text THEN
                            CASE
                                WHEN b.interesse_futuro_em IS NOT NULL THEN ((b.interesse_futuro_em::timestamp without time zone + '09:00:00'::interval) AT TIME ZONE 'America/Sao_Paulo'::text)
                                ELSE b.saida_em + (((r.p -> 'dias'::text) ->> b.chave_motivo)::numeric)::double precision * '1 day'::interval
                            END
                            ELSE NULL::timestamp with time zone
                        END AS volta_em) x
             CROSS JOIN cfg cfg_1
          WHERE
                CASE r.codigo
                    WHEN 'O6'::text THEN b.status = 'saida'::text AND (r.p -> 'dias'::text) ? b.chave_motivo AND NOT (COALESCE(b.motivo_saida, ''::text) IN ( SELECT jsonb_array_elements_text(COALESCE(r.p -> 'nunca'::text, '[]'::jsonb)) AS jsonb_array_elements_text)) AND (COALESCE(b.conferencia_motivo, ''::text) <> ALL (ARRAY['ja_cliente_nio'::text, 'suspeita_fraude'::text, 'ja_tem_pedido_nio'::text])) AND (b.dfv_hp_livre IS NULL OR b.dfv_hp_livre > 0) AND x.volta_em IS NOT NULL AND now() >= x.volta_em AND now() < (x.volta_em + COALESCE((r.p ->> 'max_dias_depois'::text)::numeric, 30::numeric)::double precision * '1 day'::interval) AND NOT (EXISTS ( SELECT 1
                       FROM oportunidades_log l
                      WHERE l.conversa_id = b.conversa_id AND l.codigo = 'O6'::text AND l.tipo = 'enviada'::text))
                    WHEN 'O7'::text THEN b.status = '2_aguardando_instalacao'::text AND (b.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text)::date = (cfg_1.hoje + 1) AND (now() AT TIME ZONE 'America/Sao_Paulo'::text)::time without time zone >= COALESCE((r.p ->> 'hora'::text)::time without time zone, '20:00:00'::time without time zone) AND b.confirmacao IS NULL
                    ELSE false
                END
        ), vagg AS (
         SELECT vbate.conversa_id,
            (array_agg(vbate.codigo ORDER BY vbate.pontos DESC, vbate.ordem))[1] AS codigo,
            array_agg(vbate.codigo ORDER BY vbate.pontos DESC, vbate.ordem) AS regras,
            sum(vbate.pontos)::integer AS pontos
           FROM vbate
          GROUP BY vbate.conversa_id
        ), vlinha AS (
         SELECT a.conversa_id,
            a.codigo,
            a.regras,
            a.pontos,
            b.cliente_nome AS nome,
            b.primeiro_nome,
            b.nome_template,
            b.cidade,
                CASE
                    WHEN b.status = 'saida'::text THEN 'saida'::text
                    ELSE 'instalacao'::text
                END AS coluna,
                CASE
                    WHEN a.codigo = 'O6'::text THEN b.saida_em
                    ELSE COALESCE(b.agendamento_registrado_em, b.instalacao_agendada_para)
                END AS parado_desde,
            b.janela_fecha_em,
            b.chatwoot_conversation_id,
            NULL::bigint AS itens_validados,
            NULL::bigint AS itens_total,
            b.telefone,
            b.plano_nome AS plano,
            b.valor_mensal AS valor_mes,
                CASE
                    WHEN a.codigo <> 'O6'::text THEN 'ligar'::text
                    WHEN b.janela_fecha_em > now() THEN 'livre'::text
                    WHEN (EXISTS ( SELECT 1
                       FROM tpl)) THEN 'template'::text
                    ELSE 'ligar'::text
                END AS canal,
            ( SELECT t.nome
                   FROM tpl t) AS template,
                CASE a.codigo
                    WHEN 'O6'::text THEN ((('Saída há '::text || _oport_dur(now() - b.saida_em)) || ' · '::text) || lower(COALESCE(b.chave_motivo, 'sem motivo'::text))) || COALESCE((' · R$ '::text || _oport_reais(b.comissao_prevista)) || ' de comissão se voltar'::text, ''::text)
                    WHEN 'O7'::text THEN (('Instala amanhã ('::text ||
                    CASE
                        WHEN COALESCE(b.instalacao_turno,
                        CASE
                            WHEN EXTRACT(hour FROM (b.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text)) >= 12::numeric THEN 'tarde'::text
                            ELSE 'manha'::text
                        END) = 'tarde'::text THEN '13–17h'::text
                        ELSE '8–12h'::text
                    END) || ') e não confirmou a visita · ligar hoje'::text) || COALESCE((' · R$ '::text || _oport_reais(b.comissao_prevista)) || ' de comissão em jogo'::text, ''::text)
                    ELSE NULL::text
                END AS motivo
           FROM vagg a
             JOIN LATERAL ( SELECT vb.venda_id,
                    vb.status,
                    vb.cliente_nome,
                    vb.cidade,
                    vb.motivo_saida,
                    vb.interesse_futuro_em,
                    vb.comissao_prevista,
                    vb.valor_mensal,
                    vb.instalacao_agendada_para,
                    vb.instalacao_turno,
                    vb.agendamento_registrado_em,
                    vb.dfv_hp_livre,
                    vb.conferencia_motivo,
                    vb.plano_nome,
                    vb.conversa_id,
                    vb.chatwoot_conversation_id,
                    vb.telefone,
                    vb.primeiro_nome,
                    vb.nome_template,
                    vb.janela_fecha_em,
                    vb.chave_motivo,
                    vb.saida_em,
                    vb.confirmacao,
                    vb.codigo,
                    vb.pontos,
                    vb.ordem,
                    vb.volta_em
                   FROM vbate vb
                  WHERE vb.conversa_id = a.conversa_id AND vb.codigo = a.codigo
                 LIMIT 1) b ON true
        ), todas AS (
         SELECT linha.conversa_id,
            linha.codigo,
            linha.regras,
            linha.pontos,
            linha.nome,
            linha.primeiro_nome,
            linha.nome_template,
            linha.cidade,
            linha.coluna,
            linha.parado_desde,
            linha.janela_fecha_em,
            linha.chatwoot_conversation_id,
            linha.itens_validados,
            linha.itens_total,
            linha.telefone,
            linha.plano,
            linha.valor_mes,
            linha.canal,
            linha.template,
            linha.motivo
           FROM linha
        UNION ALL
         SELECT vlinha.conversa_id,
            vlinha.codigo,
            vlinha.regras,
            vlinha.pontos,
            vlinha.nome,
            vlinha.primeiro_nome,
            vlinha.nome_template,
            vlinha.cidade,
            vlinha.coluna,
            vlinha.parado_desde,
            vlinha.janela_fecha_em,
            vlinha.chatwoot_conversation_id,
            vlinha.itens_validados,
            vlinha.itens_total,
            vlinha.telefone,
            vlinha.plano,
            vlinha.valor_mes,
            vlinha.canal,
            vlinha.template,
            vlinha.motivo
           FROM vlinha
        ), numerada AS (
         SELECT l.conversa_id,
            l.codigo,
            l.regras,
            l.pontos,
            l.nome,
            l.primeiro_nome,
            l.nome_template,
            l.cidade,
            l.coluna,
            l.parado_desde,
            l.janela_fecha_em,
            l.chatwoot_conversation_id,
            l.itens_validados,
            l.itens_total,
            l.telefone,
            l.plano,
            l.valor_mes,
            l.canal,
            l.template,
            l.motivo,
            row_number() OVER (ORDER BY l.pontos DESC, l.janela_fecha_em, l.parado_desde) AS n,
            row_number() OVER (PARTITION BY ((l.codigo IN ( SELECT jsonb_array_elements_text(cfg_n.fora) AS x))) ORDER BY l.pontos DESC, l.janela_fecha_em, l.parado_desde) AS nc
           FROM todas l
             CROSS JOIN cfg cfg_n
        )
 SELECT 'dharma'::text AS parceiro_id,
    n.conversa_id,
    n.codigo,
    n.regras,
    n.pontos,
    n.nome,
    n.cidade,
    n.coluna,
    n.motivo,
    n.plano,
    n.valor_mes,
    n.janela_fecha_em,
    n.canal,
    n.template,
    n.parado_desde,
    n.chatwoot_conversation_id,
        CASE n.canal
            WHEN 'livre'::text THEN _oport_texto(( SELECT x.texto
               FROM config_mari_textos x
              WHERE x.chave = ('op_'::text || n.codigo)), jsonb_build_object('nome', n.primeiro_nome, 'cidade', n.cidade, 'plano', n.plano, 'valor', _oport_reais(n.valor_mes), 'agente', COALESCE(( SELECT eu.nome
               FROM eu), 'o time'::text)))
            WHEN 'template'::text THEN mari_render_template(n.template, jsonb_build_array(n.nome_template, COALESCE(( SELECT eu.nome
               FROM eu), 'o time'::text)))
            ELSE NULL::text
        END AS texto_sugerido,
    n.n AS ordem,
    n.telefone
   FROM numerada n,
    cfg
  WHERE (n.codigo IN ( SELECT jsonb_array_elements_text(cfg.fora) AS x)) OR n.nc::numeric <= GREATEST(cfg.max_dia::numeric - COALESCE(( SELECT count(*)::numeric AS count
           FROM oportunidades_log lq
          WHERE (lq.tipo = ANY (ARRAY['enviada'::text, 'dispensada'::text])) AND (lq.criado_em AT TIME ZONE 'America/Sao_Paulo'::text)::date = cfg.hoje AND NOT (COALESCE(lq.codigo, ''::text) IN ( SELECT jsonb_array_elements_text(cfg.fora) AS x))), 0::numeric), 0::numeric);

commit;

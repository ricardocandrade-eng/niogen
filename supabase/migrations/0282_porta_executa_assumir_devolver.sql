-- NIOGEN | supabase/migrations/0282_porta_executa_assumir_devolver.sql | 18/11/2026 — Claude Code (Opus 5.5)
-- Reta final, item 5 (seção 17 do diagnóstico): a porta deixa de só conferir e passa a EXECUTAR Assumir, Devolver para a Mari
-- e o "assumir antes" do Responder. O efeito é o mesmo de antes (corpo movido, não reescrito); muda quem faz.
--  (1) peças novas da porta: _porta_assumir (botão Assumir e Responder sem dono) e _porta_devolver (Devolver para a Mari),
--      com os corpos que estavam em backoffice_momento__nucleo (ramos assumir/devolver_mari) e backoffice_responder__nucleo (0275).
--  (2) porta() despacha momento:assumir, momento:devolver_mari e time_respondeu para elas. Esses eventos não mudam o destino:
--      rodam SEM porta.aplicando (que cala os ramos antigos do _funil_antes) — os gatilhos seguem como antes.
--  (3) os núcleos ficam validar + porta (R11: só os __nucleo mudam; as cascas da 0263 continuam anotando na sombra).
-- Os outros botões da ficha (viabilidade…agendar) continuam com o corpo deles e só conferem (_porta_conferir): passá-los pela
-- porta exige conferir antes os ramos venda/quadro do _funil_antes — fica para a limpeza (item 7).
-- Regra 20: (1) nenhuma situação nova; (2) sem estado novo; (3) agora a função do banco que muda o dono é a porta, com autor
-- (turno do sistema + nota); (4) dono do Chatwoot sai do NIOGEN, como antes; (5) conferência: cenário X24 + R12 (porta × tabela).
-- Tela: sem mudança (mesmas respostas, mesmas frases). Guia do backoffice: sem impacto. Desempenho: sem impacto (mesmas consultas).
-- Funções partem da versão NO AR em 18/11 ~11h (pg_get_functiondef da produção), não dos arquivos antigos.
begin;

-- ── (1) as peças ──
create or replace function public._porta_assumir(c public.mari_conversas, v public.vendas, p_dados jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  via     text := coalesce(p_dados ->> 'via', 'momento');          -- momento (botão Assumir) | responder (Responder sem dono)
  g       uuid := coalesce(nullif(p_dados ->> 'grupo', '')::uuid, gen_random_uuid());
  o       int  := coalesce((p_dados ->> 'ordem')::int, 0);
  quem    text;
  agente  int;
  v_time  int  := (public._bo_cfg('chatwoot_time_backoffice', '15102') #>> '{}')::int;
  agora_t text := to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI');
  tem_cw  boolean := c.id is not null and c.canal = 'whatsapp' and coalesce(c.chatwoot_conversation_id, '') <> ''
                     and c.telefone not like '5500000000%';
  feito   text[] := '{}';
begin
  if c.id is null then raise exception 'Esta venda não tem conversa no Chatwoot para assumir.'; end if;
  select nome, chatwoot_agente_id into quem, agente from public.usuarios where id = auth.uid();
  quem := coalesce(quem, 'time');

  -- Responder: sem dono → assume antes (a Mari cala, a cadência para); com dono, nada (0275)
  if via = 'responder' then
    if c.chatwoot_agente is not null or coalesce(c.humano_atribuido, false) then
      return jsonb_build_object('ok', true, 'assumiu', false, 'acoes', o);
    end if;
    perform public.mari_cadencia_parar(c.id, p_humano => true);
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[assumida no NIOGEN por ' || quem || ' ao responder — cadência parada]', false);
    o := o + 1;
    perform public._bo_enfileirar(g, o, 'assumir', c.venda_id, c, 'atribuir',
      case when agente is not null then jsonb_build_object('assignee_id', agente) else jsonb_build_object('team_id', v_time) end);
    return jsonb_build_object('ok', true, 'assumiu', true, 'acoes', o);
  end if;

  -- botão Assumir (backoffice_momento)
  if exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'atribuir'
              and a.status in ('pendente', 'executando', 'feita') and a.criada_em > now() - interval '10 minutes') then
    return jsonb_build_object('ok', true, 'repetida', true, 'acoes', 0);
  end if;
  perform public.mari_cadencia_parar(c.id, p_humano => true);
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[assumida no NIOGEN por ' || quem || ' — cadência parada]', false);
  if v.id is not null and v.vendedor_id is null then
    update public.vendas set vendedor_id = auth.uid() where id = v.id;
  end if;
  if tem_cw then
    o := o + 1;
    perform public._bo_enfileirar(g, o, 'assumir', v.id, c, 'atribuir',
      case when agente is not null then jsonb_build_object('assignee_id', agente) else jsonb_build_object('team_id', v_time) end);
    o := o + 1;
    perform public._bo_enfileirar(g, o, 'assumir', v.id, c, 'nota',
      jsonb_build_object('content', '👤 Assumida no NIOGEN por ' || quem || ' às ' || agora_t || '.'));
    feito := feito || array[case when agente is not null then 'conversa atribuída a você' else 'conversa no time backoffice' end, 'nota']::text[];
  end if;
  feito := feito || 'Mari calada · cadência parada'::text;
  return jsonb_build_object('ok', true, 'assumiu', true, 'acoes', o, 'feito', to_jsonb(feito));
end $function$;

create or replace function public._porta_devolver(c public.mari_conversas, v public.vendas, p_dados jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  g       uuid := coalesce(nullif(p_dados ->> 'grupo', '')::uuid, gen_random_uuid());
  o       int  := coalesce((p_dados ->> 'ordem')::int, 0);
  quem    text := coalesce((select u.nome from public.usuarios u where u.id = auth.uid()), 'time');
  agora_t text := to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI');
  tem_cw  boolean := c.id is not null and c.canal = 'whatsapp' and coalesce(c.chatwoot_conversation_id, '') <> ''
                     and c.telefone not like '5500000000%';
  feito   text[] := '{}';
begin
  if c.id is null then raise exception 'Esta venda não tem conversa da Mari.'; end if;
  update public.mari_conversas set humano_atribuido = false, time_atribuido = false where id = c.id;
  -- 0155: em handoff a Mari fica calada; devolver fecha o ciclo (status ativo, etapa retomada) sem marcar "resolvida"
  if c.status = 'handoff_realizado' then
    perform public._mari_fechar_ciclo(c.id, 'devolvida para a Mari no NIOGEN por ' || quem);
  end if;
  update public.mari_conversas set chatwoot_resolvida = false where id = c.id and coalesce(funil_destino, 'em_andamento') = 'em_andamento';
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[devolvida para a Mari no NIOGEN por ' || quem || ']', false);
  if tem_cw then
    o := o + 1;
    perform public._bo_enfileirar(g, o, 'devolver_mari', v.id, c, 'etiquetas',
      jsonb_build_object('add', '[]'::jsonb, 'remove', jsonb_build_array('handoff-venda', 'handoff-humano')));
    o := o + 1; perform public._bo_enfileirar(g, o, 'devolver_mari', v.id, c, 'desatribuir', jsonb_build_object('assignee_id', null));
    o := o + 1; perform public._bo_enfileirar(g, o, 'devolver_mari', v.id, c, 'desatribuir', jsonb_build_object('team_id', null));
    o := o + 1;
    perform public._bo_enfileirar(g, o, 'devolver_mari', v.id, c, 'nota',
      jsonb_build_object('content', '↩ Devolvida para a Mari por ' || quem || ' às ' || agora_t || ' — a Mari continua.'));
    feito := feito || 'atribuição removida'::text || 'nota'::text;
  end if;
  return jsonb_build_object('ok', true, 'acoes', o, 'feito', to_jsonb(feito));
end $function$;

revoke execute on function public._porta_assumir(public.mari_conversas, public.vendas, jsonb) from public, anon, authenticated;
revoke execute on function public._porta_devolver(public.mari_conversas, public.vendas, jsonb) from public, anon, authenticated;

-- ── (2) a porta despacha (versão no ar + o despacho da 0282) ──
CREATE OR REPLACE FUNCTION public.porta(p_evento text, p_conversa uuid, p_venda uuid, p_dados jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  -- 0282 (reta final 5): Assumir, Devolver para a Mari e o "assumir antes" do Responder são executados aqui. Não mudam o
  -- destino do lead, então rodam SEM porta.aplicando: os gatilhos antigos do funil seguem calculando etapa e handoff como antes.
  if p_evento in ('momento:assumir', 'time_respondeu') then
    return public._porta_assumir(c, v, coalesce(p_dados, '{}'::jsonb)
             || jsonb_build_object('via', case when p_evento = 'time_respondeu' then 'responder' else 'momento' end));
  elsif p_evento = 'momento:devolver_mari' then
    return public._porta_devolver(c, v, coalesce(p_dados, '{}'::jsonb));
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
end $function$;

-- ── (3) os núcleos: validar + porta ──
CREATE OR REPLACE FUNCTION public.backoffice_responder__nucleo(p_conversa uuid, p_texto text, p_nota boolean DEFAULT false, p_template text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c        public.mari_conversas;
  g        uuid := gen_random_uuid();
  o        int := 0;
  quem     text;
  agente   int;
  v_time   int := (public._bo_cfg('chatwoot_time_backoffice', '15102') #>> '{}')::int;
  txt      text := btrim(coalesce(p_texto, ''));
  aid      bigint;
  assumiu  boolean := false;
  ult_lead timestamptz;
  ult_out  timestamptz;
  resposta boolean;
  v_tq     record;
  v_fila_d int; v_fila_m int;
  v_prox   timestamptz;
  v_tpl    public.config_templates_waba;
  v_pay    jsonb;
  v_nome   text;
  v_porta  jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice responde pelo NIOGEN.' using errcode = '42501';
  end if;
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  if c.canal <> 'whatsapp' or coalesce(c.chatwoot_conversation_id, '') = '' then raise exception 'Esta conversa não está no Chatwoot.'; end if;
  if c.telefone like '5500000000%' then raise exception 'Telefone de teste: nada vai ao Chatwoot.'; end if;
  if p_template is null and txt = '' then raise exception 'Escreva a mensagem.'; end if;
  if length(txt) > 4000 then raise exception 'Mensagem longa demais (máx. 4.000 caracteres).'; end if;
  select nome, chatwoot_agente_id into quem, agente from public.usuarios where id = auth.uid();
  quem := coalesce(quem, 'time');

  -- Nota privada: só o time vê; não é contato com o cliente.
  if coalesce(p_nota, false) then
    if txt = '' then raise exception 'Escreva a nota.'; end if;
    aid := public._bo_enfileirar(g, 1, 'nota', c.venda_id, c, 'nota', jsonb_build_object('content', txt, 'como', 'humano'));
    return jsonb_build_object('ok', true, 'acao_id', aid, 'nota', true, 'resumo', '✓ nota privada salva no Chatwoot (só o time vê)');
  end if;
  -- 0275 (mapa situação × botão): a porta confere antes de falar com o cliente (Não contatar recusa; Cliente Nio só o admin).
  -- 0282 (reta final 5): e executa — sem dono, a porta assume antes (a Mari cala, a cadência para, atribuição na fila).
  -- Se uma conferência abaixo recusar, a transação desfaz o assumir junto.
  v_porta := public.porta('time_respondeu', c.id, null::uuid, jsonb_build_object('grupo', g, 'ordem', o));
  o := coalesce((v_porta ->> 'acoes')::int, o);
  assumiu := coalesce((v_porta ->> 'assumiu')::boolean, false);

  if coalesce(c.nao_contatar, false) then raise exception 'O cliente pediu para não ser contatado.'; end if;
  -- 0095 (Ricardo, 09/11): atendimento pelo NIOGEN SEM limite de horário e SEM teto de mensagens. Só se registra se foi
  -- resposta a quem falou por último (contato receptivo) ou contato ativo — para a medição, não para bloquear.
  select max(t.created_at) filter (where t.papel = 'lead'), max(t.created_at) filter (where t.papel in ('mari', 'humano'))
    into ult_lead, ult_out from public.mari_turnos t where t.conversa_id = c.id;
  resposta := ult_lead is not null and ult_lead > now() - interval '24 hours'
              and (ult_lead > coalesce(ult_out, '-infinity'::timestamptz)
                   or exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'mensagem'
                               and a.payload ->> 'conta' = 'nao' and a.criada_em > ult_lead and a.criada_em > now() - interval '30 minutes'));
  -- Janela de 24 h: é regra do WhatsApp (a Meta recusa texto livre depois dela), não do contrato. Fechada → só template aprovado.
  if p_template is not null then
    select * into v_tpl from public.config_templates_waba where nome = p_template and status = 'APPROVED' and nome like 'nio\_%';
    if v_tpl.nome is null then raise exception 'Template não aprovado: %', p_template; end if;
    if (select count(*) from regexp_matches(coalesce(v_tpl.corpo, ''), '\{\{[0-9]+\}\}', 'g')) > 1 then
      raise exception 'Este template precisa de mais dados; mande pelo Chatwoot.';
    end if;
    v_nome := public.mari_cadencia_nome(c);
    v_pay := jsonb_build_object('content', public.mari_render_template(v_tpl.nome, jsonb_build_array(v_nome)), 'content_type', 'text',
      'message_type', 'outgoing', 'private', false, 'template', v_tpl.nome,
      'template_params', jsonb_build_object('name', v_tpl.nome, 'category', v_tpl.categoria, 'language', v_tpl.idioma,
        'processed_params', jsonb_build_object('body', jsonb_build_object('1', v_nome))));
  else
    if ult_lead is null or now() >= ult_lead + interval '23 hours' then
      raise exception 'A janela de 24 h fechou: só template aprovado. Escolha um em "Respostas rápidas › Templates".' using errcode = 'P0001';
    end if;
    v_pay := jsonb_build_object('content', txt, 'message_type', 'outgoing', 'private', false);
  end if;
  v_pay := v_pay || jsonb_build_object('como', 'humano', 'conta', case when resposta then 'nao' else 'sim' end, 'rotulo', 'resposta do time');

  -- (0282) o "sem dono → assume antes" agora é da porta (_porta_assumir, lá em cima)
  o := o + 1;
  aid := public._bo_enfileirar(g, o, 'responder', c.venda_id, c, 'mensagem', v_pay);
  return jsonb_build_object('ok', true, 'acao_id', aid, 'resposta', resposta, 'assumiu', assumiu,
    'resumo', '✓ mensagem enviada' || case when assumiu then ' · conversa assumida (a Mari calou)' else '' end);
end;
$function$;

CREATE OR REPLACE FUNCTION public.backoffice_momento__nucleo(p_venda uuid, p_momento text, p_dados jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  d        jsonb := coalesce(p_dados, '{}'::jsonb);
  v        public.vendas;
  c        public.mari_conversas;
  tem_cw   boolean := false;
  g        uuid := gen_random_uuid();
  o        int := 0;
  quem     text;
  agente   int;
  v_time   int := (public._bo_cfg('chatwoot_time_backoffice', '15102') #>> '{}')::int;
  agora_t  text := to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI');
  feito    text[] := '{}';
  aviso    text;
  msg      jsonb;
  quando   timestamptz;
  v_res    text;
  v_dia    date;
  v_per    text;
  v_ts     timestamptz;
  v_turno  text;
  v_diatxt text;
  v_pertxt text;
  v_ped    text;
  v_os     text;
  v_tinha  boolean;
  v_igual  boolean := false;   -- 0251 (D14): reagendar para o mesmo dia e turno não muda nada
  v_forma  text;
  semana   text[] := array['segunda-feira','terça-feira','quarta-feira','quinta-feira','sexta-feira','sábado','domingo'];
  r        jsonb;
  v_bio    public.nio_biometria;   -- 0246: biometria que o GED360 já viu antes da OS
begin
  -- 0268 (passo 5): a porta responde antes — recusa da tabela para aqui com a frase; sem regra passa e fica anotada
  -- 0282 (reta final 5): Assumir e Devolver para a Mari a porta confere E executa, mais abaixo
  if coalesce(p_momento, '') not in ('assumir', 'devolver_mari') then
    perform public._porta_conferir('momento:' || coalesce(p_momento, '') || coalesce(':' || nullif(p_dados ->> 'resultado', ''), ''), nullif(p_dados ->> 'conversa_id', '')::uuid, p_venda);
  end if;
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice usa os botões da venda.' using errcode = '42501';
  end if;
  if p_momento = 'reagendar' then p_momento := 'agendar'; end if;   -- 0096: agendar e reagendar são o mesmo passo
  if p_momento not in ('assumir', 'viabilidade', 'credito', 'pedido', 'biometria', 'os', 'agendar', 'os_agendar', 'parar', 'devolver_mari') then
    raise exception 'Momento desconhecido: %', p_momento;
  end if;
  select nome, chatwoot_agente_id into quem, agente from public.usuarios where id = auth.uid();
  quem := coalesce(quem, 'time');

  if p_venda is not null then
    select * into v from public.vendas where id = p_venda for update;
    if not found then raise exception 'Venda não encontrada.'; end if;
    select * into c from public.mari_conversas
     where venda_id = p_venda and canal = 'whatsapp' and coalesce(chatwoot_conversation_id, '') <> ''
     order by created_at desc limit 1;
  elsif d ? 'conversa_id' then
    select * into c from public.mari_conversas where id = (d ->> 'conversa_id')::uuid;
    if not found then raise exception 'Conversa não encontrada.'; end if;
    if c.venda_id is not null then select * into v from public.vendas where id = c.venda_id; end if;
  else
    raise exception 'Informe a venda ou a conversa.';
  end if;
  if p_momento in ('viabilidade', 'credito', 'pedido', 'biometria', 'os', 'agendar', 'os_agendar') and v.id is null then
    raise exception 'Este botão precisa de uma venda.';
  end if;
  tem_cw := c.id is not null and c.canal = 'whatsapp' and coalesce(c.chatwoot_conversation_id, '') <> ''
            and c.telefone not like '5500000000%';

  -- ── assumir (0282: quem executa é a porta — _porta_assumir) ──
  if p_momento = 'assumir' then
    if c.id is null then raise exception 'Esta venda não tem conversa no Chatwoot para assumir.'; end if;
    r := public.porta('momento:assumir', c.id, v.id, jsonb_build_object('grupo', g, 'ordem', o));
    if coalesce((r ->> 'repetida')::boolean, false) then
      return jsonb_build_object('ok', true, 'momento', p_momento, 'acoes', 0, 'feito', jsonb_build_array('já assumida há instantes'),
                                'resumo', '✓ esta conversa já foi assumida há instantes — nada repetido', 'venda_id', v.id, 'conversa_id', c.id);
    end if;
    o := coalesce((r ->> 'acoes')::int, o);
    feito := feito || array(select jsonb_array_elements_text(coalesce(r -> 'feito', '[]'::jsonb)));

  -- ── viabilidade (portal) ──
  elsif p_momento = 'viabilidade' then
    v_res := nullif(d ->> 'resultado', '');
    if v_res is not null and v_res not in ('viavel', 'sem_viabilidade', 'nao_encontrado') then
      raise exception 'Resultado do portal inválido.';
    end if;
    update public.vendas set
      nio_viab_resultado = v_res, nio_viab_origem = case when v_res is null then null else 'manual' end,
      nio_viab_em = case when v_res is null then null else now() end,
      nio_viab_velocidade = nullif(btrim(coalesce(d ->> 'velocidade', '')), ''),
      nio_viab_interesse_id = nullif(btrim(coalesce(d ->> 'interesse', '')), ''),
      nio_viab_endereco_portal = nullif(btrim(coalesce(d ->> 'endereco_portal', '')), '')
    where id = v.id;
    feito := feito || 'viabilidade gravada'::text;
    if tem_cw and v_res is not null then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota', jsonb_build_object('content',
        '📍 Viabilidade no portal: ' || case v_res when 'viavel' then 'Viável' when 'sem_viabilidade' then 'Sem viabilidade' else 'Endereço não encontrado' end
        || coalesce(' (' || nullif(btrim(coalesce(d ->> 'velocidade', '')), '') || ')', '') || ' — ' || quem || ', ' || agora_t || '.'));
      feito := feito || 'nota'::text;
    end if;
    if v_res in ('sem_viabilidade', 'nao_encontrado') then
      aviso := 'Tente variações de CEP, rua e número. Se só a Nio pode confirmar, abra a pendência "Nio confirmar viabilidade".';
    end if;

  -- ── pedido gravado no portal (etapa 3): SÓ o pedido; a Nio manda o link da biometria (0089) ──
  elsif p_momento = 'pedido' then
    v_ped := btrim(coalesce(d ->> 'pedido', ''));
    if v_ped !~ '^[A-Za-z0-9._/-]{4,40}$' then
      raise exception 'Número do pedido inválido: use só letras, números, ponto, barra ou hífen (4 a 40 caracteres).' using errcode = '22023';
    end if;
    if v.status = 'saida' then raise exception 'A venda está em Saída; reabra pela ficha antes de registrar o pedido.'; end if;
    if v.status <> '0_qualificado' then raise exception 'O pedido já foi gravado e a venda já andou.'; end if;
    if d ? 'link' and coalesce(d ->> 'link', '') <> '' and (d ->> 'link') !~* '^https?://' then
      raise exception 'O link da biometria tem que começar com https://';
    end if;
    if v.nio_pedido is not distinct from v_ped then
      update public.vendas set credito_resultado = coalesce(nullif(d ->> 'credito', ''), credito_resultado),
             biometria_link = coalesce(nullif(btrim(coalesce(d ->> 'link', '')), ''), biometria_link) where id = v.id;
      return jsonb_build_object('ok', true, 'momento', p_momento, 'acoes', 0, 'feito', jsonb_build_array('pedido já estava gravado'),
                                'resumo', '✓ pedido nº ' || v_ped || ' já estava gravado — nada foi reenviado ao cliente', 'venda_id', v.id);
    end if;
    -- O trigger 0032 carimba nio_pedido_em e a biometria pendente (as 24 h / 72 h contam dali).
    update public.vendas set
      nio_pedido = v_ped,
      credito_resultado = coalesce(nullif(d ->> 'credito', ''), credito_resultado),
      biometria_link = coalesce(nullif(btrim(coalesce(d ->> 'link', '')), ''), biometria_link)
    where id = v.id;
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (v.id, 'pedido_aberto_portal', jsonb_build_object('origem', coalesce(nullif(d ->> 'origem', ''), 'ficha'), 'pedido', v_ped), auth.uid());
    feito := feito || 'pedido gravado · etapa Pedido · biometria'::text;
    if not (v.nio_viab_resultado = 'viavel' and v.nio_viab_em >= now() - interval '7 days') then
      aviso := 'Registre a viabilidade do portal (Viável): sem ela a venda não conta.';
    end if;
    if tem_cw then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas', jsonb_build_object('add', jsonb_build_array('biometria-pendente')));
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', '🧾 Pedido nº ' || v_ped || ' aberto às ' || agora_t || ' — ' || quem || '. A Nio manda o link da biometria ao cliente.'));
      if coalesce((d ->> 'sem_aviso')::boolean, false) then
        feito := feito || 'etiqueta'::text || 'nota'::text || 'sem aviso ao cliente (o time já avisou)'::text;   -- 0092
      else
        o := o + 1;
        msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_pedido_biometria', '{}'::jsonb,
                                   'nio_lembrete_biometria_v2', jsonb_build_array(public.mari_cadencia_nome(c)), 'aviso do pedido (biometria)');
        feito := feito || 'etiqueta'::text || 'nota'::text;
      end if;
    end if;

  -- ── crédito no portal (0092: registrado da extensão, na etapa do cadastro) ──
  elsif p_momento = 'credito' then
    v_res := d ->> 'resultado';
    if v_res not in ('aprovado', 'so_cartao', 'pendente', 'negado') then raise exception 'Crédito: use aprovado, só cartão, pendente ou negado.'; end if;
    if v.status = 'saida' then raise exception 'A venda está em Saída.'; end if;
    v_tinha := coalesce(v.credito_resultado, '') in ('aprovado', 'so_cartao') or coalesce(btrim(v.nio_pedido), '') <> '';
    update public.vendas set credito_resultado = v_res where id = v.id;
    feito := feito || ('crédito ' || case v_res when 'aprovado' then 'aprovado' when 'so_cartao' then 'aprovado só no cartão' when 'pendente' then 'pendente' else 'negado' end)::text;
    -- 0247 (Ricardo, 16/11): ordem do portal = crédito → biometria (link da Nio, aprovada) → forma de pagamento → agenda → OS.
    if v_res in ('aprovado', 'so_cartao') and v.status = '0_qualificado' and not v_tinha then
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (v.id, 'credito_aprovado_portal', jsonb_build_object('origem', coalesce(nullif(d ->> 'origem', ''), 'ficha'), 'resultado', v_res), auth.uid());
      feito := feito || 'próximo: a biometria (link da Nio); aprovada, forma de pagamento, agenda e OS no portal'::text;
      if not (v.nio_viab_resultado = 'viavel' and v.nio_viab_em >= now() - interval '7 days') then
        aviso := 'Registre a viabilidade do portal (Viável): sem ela a venda não conta.';
      end if;
    end if;
    if v_res = 'negado' then
      if not exists (select 1 from public.venda_pendencias where venda_id = v.id and encerrada_em is null)
         and exists (select 1 from public.config_motivos_pendencia where codigo = 'credito_outro_cpf' and ativo) then
        v_dia := (now() at time zone 'America/Sao_Paulo')::date + 1;
        while extract(isodow from v_dia) = 7 loop v_dia := v_dia + 1; end loop;
        perform public.pendencia_abrir(v.id, 'credito_outro_cpf', null, v_dia);
        feito := feito || 'pendência aberta (outro CPF)'::text;
      end if;
    end if;
    -- 0246 (caso Queroly, 16/11): o mesmo resultado gravado de novo (ficha e depois extensão) não repete a nota.
    if tem_cw and v_res = coalesce(v.credito_resultado, '') and exists (
         select 1 from public.chatwoot_acoes pa where pa.venda_id = v.id and pa.momento = 'credito' and pa.tipo = 'nota'
            and pa.status <> 'cancelada' and pa.criada_em > now() - interval '12 hours') then
      feito := feito || 'nota já estava no Chatwoot'::text;
    elsif tem_cw then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota', jsonb_build_object('content',
        '💳 Crédito no portal: ' || case v_res when 'aprovado' then 'aprovado — próximo: biometria (link da Nio); aprovada, forma de pagamento, agenda e OS' when 'so_cartao' then 'aprovado só no cartão — próximo: biometria; aprovada, agenda e OS (cartão)' when 'pendente' then 'pendente (24 h)' else 'negado — pedido outro CPF' end
        || ' — ' || quem || ', ' || agora_t || '.'));
      feito := feito || 'nota'::text;
      if v_res = 'negado' then
        o := o + 1;
        -- 0224 (Ricardo, caso Lucas Heleno 15/11): conversa com uma pessoa do time ou pedido já feito nas últimas 24 h → sem mensagem
        -- automática (saía na voz da Mari no meio da conversa do time e repetia depois do "não aprovou").
        if coalesce(c.humano_atribuido, false) or coalesce(c.time_atribuido, false) or c.chatwoot_agente is not null or v.status = 'saida'
           or exists (select 1 from public.chatwoot_acoes pa where pa.venda_id = v.id and pa.payload ->> 'rotulo' = 'pedido de outro CPF'
                       and pa.status <> 'cancelada' and pa.criada_em > now() - interval '24 hours') then
          aviso := concat_ws(' ', aviso, 'A conversa está com você (ou o pedido de outro CPF já saiu hoje): fale com o cliente pela conversa.');
        else
          msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_credito_negado', '{}'::jsonb, null, null, 'pedido de outro CPF');
        end if;
      end if;
    end if;
    if v_res = 'so_cartao' and coalesce(v.forma_pagamento, '') <> 'cartao' then
      aviso := 'Aprovado só no cartão: troque a forma de pagamento na ficha (Detalhes › Plano, valor e pagamento › Trocar).';
    end if;

  -- ── biometria (Validada · Risco · Negado) — etapa 3 ──
  elsif p_momento = 'biometria' then
    if coalesce(btrim(v.nio_pedido), '') = '' and coalesce(v.credito_resultado, '') not in ('aprovado', 'so_cartao') then
      raise exception 'Grave antes o crédito aprovado: a biometria vem do link que a Nio manda depois do crédito.';
    end if;
    v_res := d ->> 'resultado';
    if v_res = 'validada' then
      update public.vendas set biometria_status = 'validada' where id = v.id;
      -- 0191: a mensagem ao cliente sai pela cadência da Mari (cartão: aviso do cadastro do cartão; boleto: confirmação da instalação).
      feito := feito || case when v.forma_pagamento = 'cartao'
                             then 'biometria validada · a Nio manda o link do cartão e a Mari avisa o cliente'
                             else 'biometria validada · a Mari confirma a instalação ao cliente' end::text;
      if tem_cw then
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas', jsonb_build_object('remove', jsonb_build_array('biometria-pendente')));
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
          jsonb_build_object('content', '✅ Biometria validada — ' || quem || ', ' || agora_t || '. '
            || case when v.forma_pagamento = 'cartao' then 'Cartão: a Nio manda o link do cadastro do cartão; a visita depende dele.'
                    else 'A Mari confirma a instalação ao cliente.' end));
        feito := feito || 'etiqueta'::text || 'nota'::text;
      end if;
    elsif v_res = 'risco' then
      update public.vendas set biometria_status = 'com_risco' where id = v.id;
      feito := feito || 'biometria com risco'::text;
      if tem_cw then
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
          jsonb_build_object('content', '⚠️ Biometria com risco — ' || quem || ', ' || agora_t || '. Conferir no portal (só cartão?).'));
        feito := feito || 'nota'::text;
      end if;
    elsif v_res = 'negado' then
      update public.vendas set credito_resultado = 'negado' where id = v.id;
      feito := feito || 'crédito negado'::text;
      if not exists (select 1 from public.venda_pendencias where venda_id = v.id and encerrada_em is null)
         and exists (select 1 from public.config_motivos_pendencia where codigo = 'credito_outro_cpf' and ativo) then
        v_dia := (now() at time zone 'America/Sao_Paulo')::date + 1;
        while extract(isodow from v_dia) = 7 loop v_dia := v_dia + 1; end loop;
        perform public.pendencia_abrir(v.id, 'credito_outro_cpf', null, v_dia);
        feito := feito || 'pendência aberta (outro CPF)'::text;
      end if;
      if tem_cw then
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
          jsonb_build_object('content', '✕ Crédito negado no CPF do cliente — ' || quem || ', ' || agora_t || '. Pedido outro CPF (pendência aberta).'));
        o := o + 1;
        -- 0224 (Ricardo, caso Lucas Heleno 15/11): conversa com uma pessoa do time ou pedido já feito nas últimas 24 h → sem mensagem
        -- automática (saía na voz da Mari no meio da conversa do time e repetia depois do "não aprovou").
        if coalesce(c.humano_atribuido, false) or coalesce(c.time_atribuido, false) or c.chatwoot_agente is not null or v.status = 'saida'
           or exists (select 1 from public.chatwoot_acoes pa where pa.venda_id = v.id and pa.payload ->> 'rotulo' = 'pedido de outro CPF'
                       and pa.status <> 'cancelada' and pa.criada_em > now() - interval '24 hours') then
          aviso := concat_ws(' ', aviso, 'A conversa está com você (ou o pedido de outro CPF já saiu hoje): fale com o cliente pela conversa.');
        else
          msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_credito_negado', '{}'::jsonb, null, null, 'pedido de outro CPF');
        end if;
        feito := feito || 'nota'::text;
      end if;
    elsif v_res = 'dispensada' then
      -- 0196 (Ricardo, 14/11): com o sistema de biometria fora do ar a Nio libera a venda sem biometria. Vale como aprovada
      -- (comissão normal; no cartão, o link do cadastro do cartão sai logo). O time marca por venda, com motivo e autor.
      if coalesce(btrim(v.nio_os), '') = '' and coalesce(v.credito_resultado, '') not in ('aprovado', 'so_cartao') then
        raise exception 'A dispensa da biometria é depois do crédito aprovado.';
      end if;
      if v.biometria_status = 'validada' then raise exception 'A biometria desta venda já está validada.'; end if;
      update public.vendas set biometria_status = 'validada', biometria_dispensada_em = now(), biometria_dispensada_por = auth.uid(),
             biometria_dispensa_motivo = coalesce(nullif(btrim(d ->> 'motivo'), ''), 'sistema de biometria da Nio fora do ar')
       where id = v.id;
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (v.id, 'biometria_dispensada', jsonb_build_object('motivo', coalesce(nullif(btrim(d ->> 'motivo'), ''), 'sistema de biometria da Nio fora do ar'),
              'queda_id', (select q.id from public.biometria_quedas q where q.fim is null order by q.inicio desc limit 1)), auth.uid());
      feito := feito || case when v.forma_pagamento = 'cartao'
                             then 'biometria dispensada pela Nio · a Mari avisa do cadastro do cartão'
                             else 'biometria dispensada pela Nio · a Mari confirma a instalação' end::text;
      if tem_cw then
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas', jsonb_build_object('remove', jsonb_build_array('biometria-pendente')));
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
          jsonb_build_object('content', '🟢 Biometria dispensada pela Nio (sistema de biometria fora do ar) — ' || quem || ', ' || agora_t || '. Vale como aprovada.'));
        feito := feito || 'etiqueta'::text || 'nota'::text;
      end if;
    else
      raise exception 'Biometria: use validada, dispensada, risco ou negado.';
    end if;

  -- ── 0096 (Ricardo, 09/11: "São etapas diferentes"): OS aberta no portal = VENDA (etapa 4). Agendar vem depois. ──
  elsif p_momento = 'os' then
    v_os := btrim(coalesce(d ->> 'os', ''));
    if v_os !~ '^[A-Za-z0-9._/-]{3,40}$' then
      raise exception 'Nº do pedido (OS) inválido: use só letras, números, ponto, barra ou hífen.' using errcode = '22023';
    end if;
    -- 0277 (caso Queroly, 18/11): REEMITIR O PEDIDO. A Nio não deixa trocar a forma de pagamento de uma OS aberta: o time cancela a OS
    -- no portal (fica "Draft") e emite um pedido novo, que gera OS e agenda novas; a biometria aprovada vale. Só o admin (porta, 0275:
    -- "Só o admin corrige a OS depois de gravada"). Troca a OS, guarda a antiga no histórico, apaga a agenda velha (a nova vem da
    -- Consulta OS, que passa a ler a OS nova) e volta a venda para "falta agendar".
    if v.status in ('1_vendido', '2_aguardando_instalacao') and v.instalado_em is null
       and coalesce(btrim(v.nio_os), '') <> '' and btrim(v.nio_os) <> v_os then
      declare
        os_antiga    text := btrim(v.nio_os);
        forma_antiga text := v.forma_pagamento;
        ag_antiga    timestamptz := v.instalacao_agendada_para;
      begin
        v_forma := nullif(btrim(coalesce(d ->> 'forma', '')), '');
        if v_forma is not null and v_forma not in ('boleto', 'cartao', 'dacc') then raise exception 'Forma de pagamento inválida.'; end if;
        if v.credito_resultado = 'so_cartao' and coalesce(v_forma, v.forma_pagamento, '') <> 'cartao' then
          raise exception 'O crédito foi aprovado só no cartão: a forma de pagamento da OS tem de ser cartão.' using errcode = 'P0001';
        end if;
        if exists (select 1 from public.vendas x where x.id <> v.id and (x.nio_os = v_os or x.nio_pedido = v_os)) then
          raise exception 'A OS % já está em outra venda.', v_os using errcode = 'P0001';
        end if;
        perform set_config('niogen.transicao_ok', 'reemitir', true);   -- "aguardando instalação" → "vendida, falta agendar"
        update public.vendas set nio_os = v_os, nio_pedido = v_os, status = '1_vendido',
               forma_pagamento = coalesce(v_forma, forma_pagamento),
               instalacao_agendada_para = null, instalacao_turno = null, nio_situacao = null,
               nio_pendencia_cod = null, nio_pendencia_desc = null, cartao_pago_em = null
         where id = v.id returning * into v;
        perform set_config('niogen.transicao_ok', '', true);
        insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
        values (v.id, 'os_reemitida', jsonb_strip_nulls(jsonb_build_object('os_antiga', os_antiga, 'os', v_os,
                  'forma_antiga', forma_antiga, 'forma', v.forma_pagamento, 'agenda_antiga', ag_antiga,
                  'motivo', nullif(btrim(coalesce(d ->> 'motivo', '')), ''), 'origem', coalesce(nullif(d ->> 'origem', ''), 'ficha'))), auth.uid());
        feito := feito || ('pedido reemitido · OS ' || os_antiga || ' → ' || v_os
                           || case when forma_antiga is distinct from v.forma_pagamento then ' · pagamento ' || coalesce(forma_antiga, '—') || ' → ' || v.forma_pagamento else '' end
                           || ' · a agenda nova vem da Consulta OS')::text;
        if tem_cw then
          o := o + 1;
          perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
            jsonb_build_object('content', '🔁 Pedido reemitido: OS ' || os_antiga || ' cancelada no portal → nova OS nº ' || v_os
              || case when forma_antiga is distinct from v.forma_pagamento then ' (pagamento: ' || coalesce(forma_antiga, '—') || ' → ' || v.forma_pagamento || ')' else '' end
              || '. Biometria mantida. A agenda nova vem da Consulta OS — ' || quem || ', ' || agora_t || '.'));
          feito := feito || 'nota'::text;
        end if;
      end;
    else
      if v.status <> '0_qualificado' then raise exception 'A OS já foi gravada nesta venda.'; end if;
      -- Uma atualização só: se a trava recusar (falta pedido, biometria, viabilidade…), nada fica gravado e a mensagem volta.
      -- 0247: "Gravar venda" = só o nº da OS (e a forma de pagamento do portal, se mudou). A agenda vem da Consulta OS (operador).
      v_forma := nullif(btrim(coalesce(d ->> 'forma', '')), '');
      if v_forma is not null and v_forma not in ('boleto', 'cartao', 'dacc') then raise exception 'Forma de pagamento inválida.'; end if;
      -- 0256: o GED360 é lido ANTES de gravar a OS — a trava da biometria (vendas_transicao) já enxerga a aprovação que ele viu.
      v_bio := public._ged360_da_venda(v.id);
      if v_bio.protocolo is not null then
        update public.vendas set biometria_link_enviado_em = coalesce(least(v_bio.primeira_leitura, v_bio.data_envio), biometria_link_enviado_em)
         where id = v.id;
        perform public._ged360_aplicar(v_bio);
        select * into v from public.vendas where id = v.id;
      end if;
      update public.vendas set nio_os = v_os, nio_pedido = v_os, status = '1_vendido', forma_pagamento = coalesce(v_forma, forma_pagamento)
       where id = v.id returning * into v;
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (v.id, 'os_aberta_portal', jsonb_build_object('os', v_os, 'forma', v.forma_pagamento, 'origem', coalesce(nullif(d ->> 'origem', ''), 'ficha')), auth.uid());
      feito := feito || ('VENDA · pedido (OS) ' || v_os || ' · a agenda vem da Consulta OS')::text;
      -- 0246 (caso Queroly, 16/11): o portal pode mandar a biometria ANTES da OS. Se o GED360 já viu o link, a hora é a dele,
      -- a aprovação vale agora e o cliente não recebe "a Nio acabou de te mandar o link".
      if v_bio.protocolo is not null then
        feito := feito || ('o link da biometria saiu às ' || to_char(least(v_bio.primeira_leitura, v_bio.data_envio) at time zone 'America/Sao_Paulo', 'HH24:MI')
                           || case when v.biometria_status = 'validada' then ' · aprovada' else '' end)::text;
      end if;
      if tem_cw then
        if v.biometria_status is distinct from 'validada' then
          o := o + 1;
          perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas', jsonb_build_object('add', jsonb_build_array('biometria-pendente')));
        end if;
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
          jsonb_build_object('content', '🧾 Pedido (OS) nº ' || v_os || ' aberto no portal — VENDA. '
            || case when v.biometria_status = 'validada' then 'Biometria já aprovada. '
                    when v_bio.protocolo is not null then 'O link da biometria já tinha saído. '
                    else 'A Nio manda o link da biometria. ' end
            || 'A agenda vem da Consulta OS (o robô lê em instantes) — ' || quem || ', ' || agora_t || '.'));
        feito := feito || 'nota'::text;
        if coalesce((d ->> 'sem_aviso')::boolean, false) or v.biometria_status = 'validada' or v_bio.protocolo is not null then
          feito := feito || 'sem aviso da biometria ao cliente'::text;
        else
          o := o + 1;
          msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_pedido_biometria', '{}'::jsonb,
                                     'nio_lembrete_biometria_v2', jsonb_build_array(public.mari_cadencia_nome(c)), 'aviso do link da biometria');
        end if;
      end if;
    end if;

  -- ── OS + agendamento juntos (0089, mantido para quem já usa) · agendar / reagendar (depois da OS) ──
  elsif p_momento in ('os_agendar', 'agendar') then
    v_dia := nullif(d ->> 'dia', '')::date;
    v_per := coalesce(nullif(d ->> 'periodo', ''), '08:00');
    if v_dia is null then raise exception 'Informe o dia da instalação.'; end if;
    if v_per not in ('08:00', '13:00') then raise exception 'Período inválido.'; end if;
    if v_dia < (now() at time zone 'America/Sao_Paulo')::date then raise exception 'O dia da instalação já passou.'; end if;
    v_ts := (v_dia::text || ' ' || v_per || ':00')::timestamp at time zone 'America/Sao_Paulo';
    v_turno := case when v_per = '13:00' then 'tarde' else 'manha' end;
    if p_momento = 'os_agendar' then
      v_os := btrim(coalesce(d ->> 'os', ''));
      if v_os !~ '^[A-Za-z0-9._/-]{3,40}$' then
        raise exception 'Nº do pedido (OS) inválido: use só letras, números, ponto, barra ou hífen.' using errcode = '22023';
      end if;
      if v.status <> '0_qualificado' then raise exception 'A OS já foi aberta: use Reagendar.'; end if;
      -- 0191 (Ricardo, 14/11): a forma de pagamento escolhida no portal vem junto (pode ter mudado da conversa).
      v_forma := nullif(btrim(coalesce(d ->> 'forma', '')), '');
      if v_forma is not null and v_forma not in ('boleto', 'cartao', 'dacc') then raise exception 'Forma de pagamento inválida.'; end if;
      -- 0256: o GED360 é lido ANTES de gravar a OS — a trava da biometria (vendas_transicao) já enxerga a aprovação que ele viu.
      v_bio := public._ged360_da_venda(v.id);
      if v_bio.protocolo is not null then
        update public.vendas set biometria_link_enviado_em = coalesce(least(v_bio.primeira_leitura, v_bio.data_envio), biometria_link_enviado_em)
         where id = v.id;
        perform public._ged360_aplicar(v_bio);
        select * into v from public.vendas where id = v.id;
      end if;
      -- Uma atualização só: se a trava recusar (falta crédito, viabilidade…), nada fica gravado e a mensagem volta.
      update public.vendas set
        nio_os = v_os, nio_pedido = v_os, instalacao_agendada_para = v_ts, instalacao_turno = v_turno,
        forma_pagamento = coalesce(v_forma, forma_pagamento),
        nio_pendencia_cod = null, nio_pendencia_desc = null, status = '2_aguardando_instalacao'
      where id = v.id
      returning * into v;
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (v.id, 'os_aberta_portal', jsonb_build_object('os', v_os, 'dia', v_dia, 'turno', v_turno, 'forma', v.forma_pagamento,
              'origem', coalesce(nullif(d ->> 'origem', ''), 'ficha')), auth.uid());
      feito := feito || ('VENDA · OS ' || v_os || ' · instalação ' || to_char(v_dia, 'DD/MM') || ' ' || case v_turno when 'tarde' then 'tarde' else 'manhã' end
                         || ' · a Nio manda o link da biometria')::text;
    else
      if v.status not in ('1_vendido', '2_aguardando_instalacao') then
        raise exception 'Agendar é depois da OS: grave antes o nº do pedido (OS) do portal.';
      end if;
      v_tinha := v.instalacao_agendada_para is not null;
      v_igual := v.instalacao_agendada_para = v_ts and coalesce(v.instalacao_turno, '') = v_turno and v.status = '2_aguardando_instalacao';
      update public.vendas set
        instalacao_agendada_para = v_ts, instalacao_turno = v_turno, nio_pendencia_cod = null, nio_pendencia_desc = null,
        status = case when status = '1_vendido' then '2_aguardando_instalacao' else status end
      where id = v.id
      returning * into v;
      feito := feito || (case when v_igual then 'nada mudou: a instalação já estava em ' else 'instalação ' || case when v_tinha then 'reagendada ' else 'agendada ' end end
                         || to_char(v_dia, 'DD/MM') || ' ' || case v_turno when 'tarde' then 'tarde' else 'manhã' end
                         || case when v_igual then ' — nada foi ao cliente' else '' end)::text;
    end if;
    if tem_cw and p_momento = 'os_agendar' then
      -- 0191: OS gravada = a Nio manda o link da biometria. O aviso ao cliente é o da biometria (com a data pré-agendada);
      -- a confirmação da instalação (C2) sai pela cadência depois da biometria aprovada (no cartão, depois do cadastro do cartão).
      v_diatxt := semana[extract(isodow from v_dia)::int] || ', ' || to_char(v_dia, 'DD/MM');
      v_pertxt := case v_turno when 'tarde' then 'tarde, 13h às 17h' else 'manhã, 8h às 12h' end;
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas',
        case when v.biometria_status = 'validada' then jsonb_build_object('add', jsonb_build_array('instalacao-agendada'), 'remove', jsonb_build_array('biometria-pendente'))
             else jsonb_build_object('add', jsonb_build_array('biometria-pendente', 'instalacao-agendada')) end);
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', '🧾 OS nº ' || v_os || ' aberta — VENDA. Instalação pré-agendada: ' || v_diatxt || ', ' || v_pertxt
          || case when v.biometria_status = 'validada' then '. Biometria já aprovada' when v_bio.protocolo is not null then '. O link da biometria já tinha saído'
                  else '. A Nio manda o link da biometria' end
          || case when v.forma_pagamento = 'cartao' then '; depois dela, o link do cadastro do cartão' else '' end
          || ' — ' || quem || ', ' || agora_t || '.'));
      feito := feito || 'etiqueta'::text || 'nota'::text;
      if coalesce((d ->> 'sem_aviso')::boolean, false) or v_bio.protocolo is not null then
        feito := feito || case when v_bio.protocolo is not null then 'sem aviso da biometria (o link já tinha saído; a confirmação da instalação sai pela cadência)'
                               else 'sem aviso ao cliente (o time já avisou)' end::text;
      else
        o := o + 1;
        msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_os_biometria',
                 jsonb_build_object('dia', v_diatxt, 'periodo', v_pertxt),
                 'nio_lembrete_biometria_v2', jsonb_build_array(public.mari_cadencia_nome(c)), 'aviso da OS e da biometria');
        -- 0254 (D13): não resolve mais (ver o agendar abaixo).
      end if;
    elsif tem_cw and not v_igual then
      v_diatxt := semana[extract(isodow from v_dia)::int] || ', ' || to_char(v_dia, 'DD/MM');
      v_pertxt := case v_turno when 'tarde' then 'tarde, 13h às 17h' else 'manhã, 8h às 12h' end;
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas',
        jsonb_build_object('add', jsonb_build_array('instalacao-agendada'), 'remove', jsonb_build_array('biometria-pendente')));
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', case when p_momento = 'os_agendar' then '📅 OS nº ' || v_os || ' aberta e instalação agendada: ' when v_tinha then '📅 Instalação reagendada: ' else '📅 Instalação agendada: ' end
          || v_diatxt || ', ' || v_pertxt || ' — ' || quem || ', ' || agora_t || '.'));
      o := o + 1;
      msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_instalacao_confirmada',
               jsonb_build_object('dia', v_diatxt, 'periodo', v_pertxt),
               'nio_instalacao_agendada',
               jsonb_build_array(public.mari_cadencia_nome(c), v_diatxt, v_pertxt,
                 concat_ws(', ', nullif(btrim(v.logradouro), ''), nullif(btrim(v.numero), ''), nullif(btrim(v.complemento), ''), nullif(btrim(v.bairro), ''))),
               'confirmação da instalação');
      feito := feito || 'etiqueta'::text || 'nota'::text;
      if msg ->> 'status' = 'pendente' then
        update public.mari_conversas set instalacao_avisada_para = v_ts, instalacao_avisada_em = (msg ->> 'quando')::timestamptz
         where id = c.id;
        -- 0254 (D13): agendar NÃO resolve mais a conversa. A 0085 resolvia para a 24387 tirar o dono; desde a regra
        -- "resolvida sem Saída reabre" (venda viva) o Chatwoot reabria 1 min depois e a 24389/24390 devolviam o time — o fim era
        -- o mesmo, mas a pessoa que conduzia perdia a conversa e ficava a nota "o NIOGEN reabriu". Agora o dono fica.
      end if;
    end if;

  -- ── cliente pediu para parar ──
  elsif p_momento = 'parar' then
    if c.id is null then raise exception 'Esta venda não tem conversa da Mari.'; end if;
    perform public.mari_cadencia_parar(c.id, p_resolvida => not (v.id is not null and v.status <> 'saida'), p_nao_contatar => true);
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[cliente pediu para parar — marcado no NIOGEN por ' || quem || ']', false);
    feito := feito || 'não contatar'::text;
    if tem_cw then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas', jsonb_build_object('add', jsonb_build_array('nao-contatar')));
      o := o + 1;
      -- 0252 (H1): com venda viva a venda segue — a conversa fica com o time, aberta, sem mensagem automática nenhuma.
      if v.id is not null and v.status <> 'saida' then
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
          jsonb_build_object('content', '🚫 Cliente pediu para parar — ' || quem || ', ' || agora_t || '. A venda SEGUE: nenhuma mensagem automática '
            || '(nem aviso da venda). Falar com o cliente só se ele escrever. Se ele quiser desistir da compra, use Saída ▾.'));
        feito := feito || 'etiqueta'::text || 'nota'::text || 'a venda segue, sem mensagens'::text;
      else
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
          jsonb_build_object('content', '🚫 Cliente pediu para parar — ' || quem || ', ' || agora_t || '. Nunca mais chamar.'));
        o := o + 1; perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'resolver', jsonb_build_object('status', 'resolved'));
        feito := feito || 'etiqueta'::text || 'nota'::text || 'conversa resolvida'::text;
      end if;
    end if;

  -- ── devolver para a Mari (0282: quem executa é a porta — _porta_devolver) ──
  elsif p_momento = 'devolver_mari' then
    if c.id is null then raise exception 'Esta venda não tem conversa da Mari.'; end if;
    r := public.porta('momento:devolver_mari', c.id, v.id, jsonb_build_object('grupo', g, 'ordem', o));
    o := coalesce((r ->> 'acoes')::int, o);
    feito := feito || array(select jsonb_array_elements_text(coalesce(r -> 'feito', '[]'::jsonb)));
  end if;

  if msg is not null then
    if msg ->> 'status' = 'repetida' then
      feito := feito || 'mensagem ao cliente não repetida (a mesma já saiu nas últimas 12 h)'::text;
    elsif msg ->> 'status' = 'pendente' then
      quando := (msg ->> 'quando')::timestamptz;
      feito := feito || ('mensagem ao cliente' || case when quando > now() + interval '2 minutes'
                then ' — sai ' || case when (quando at time zone 'America/Sao_Paulo')::date = (now() at time zone 'America/Sao_Paulo')::date
                                       then 'às ' else to_char(quando at time zone 'America/Sao_Paulo', 'DD/MM') || ' às ' end
                     || to_char(quando at time zone 'America/Sao_Paulo', 'HH24:MI') else '' end
                || case when msg ->> 'template' is not null then ' (template ' || (msg ->> 'template') || ')' else '' end)::text;
    else
      aviso := concat_ws(' ', aviso, 'A mensagem ao cliente NÃO saiu (' || (msg ->> 'motivo') || '): mande à mão pelo Chatwoot — está no Live.');
    end if;
  end if;
  if c.id is not null and not tem_cw and c.telefone like '5500000000%' then
    aviso := concat_ws(' ', aviso, 'Telefone de teste: nada foi ao Chatwoot.');
  elsif c.id is null and p_momento in ('pedido', 'os', 'os_agendar', 'agendar', 'biometria') then
    aviso := concat_ws(' ', aviso, 'Venda sem conversa no Chatwoot: avise o cliente por ligação.');
  end if;

  r := jsonb_strip_nulls(jsonb_build_object('ok', true, 'momento', p_momento, 'grupo', g, 'acoes', o,
         'feito', to_jsonb(feito), 'resumo', '✓ ' || array_to_string(feito, ', '), 'aviso', aviso,
         'mensagem', msg - 'texto', 'venda_id', v.id, 'conversa_id', c.id));
  if v.id is not null then
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (v.id, 'backoffice', jsonb_strip_nulls(jsonb_build_object('momento', p_momento, 'resumo', r ->> 'resumo', 'aviso', aviso,
            'mensagem', msg ->> 'status', 'resultado', d ->> 'resultado')), auth.uid());
  end if;
  return r;
end;
$function$;

commit;

-- NIOGEN | supabase/migrations/0335_time_traz_de_volta_e_fecha_com_o_tempo.sql | 20/11/2026 — Claude Code (Opus 5.5)
-- Achado da sombra do projetor (19–20/11): o time conversando com lead fora do andamento — Chatwoot 189 (Saída sem cobertura, ~12
-- respostas do Ricardo à tarde) e 138 (instalado que voltou a escrever). A situação pedia conversa fechada e sem dono; o projetor,
-- quando mandar, fecharia no meio do papo. Ricardo, 20/11: "Traz de volta e com o tempo, pode fechar, caso fique aberto".
-- O que muda:
-- (1) backoffice_responder: o time escreve a um lead na Saída "Recusou" ou "Sem resposta" → Reabrir pela porta (sem cobertura e fora
--     da área seguem na Saída: pedem nova viabilidade e o Reabrir à mão) e a Saída de antes fica guardada (volta_time_em/_saida).
--     O lead vai para "Com o time · esperando o cliente" (o time falou por último, 0310).
-- (2) _porta_prazos: (a) voltou e o cliente não respondeu em 24 h (volta_time_horas) → evento prazo:volta_saida pela porta → a mesma
--     Saída (motivo e porquê de antes). O cliente respondeu → a marca sai e segue o fluxo normal. (b) conversa aberta no Chatwoot com
--     o lead fora do andamento (instalado, Saída, cliente Nio, não contatar) e 24 h sem ninguém falar (fora_fechar_horas) → evento
--     prazo:fora_fechar → fecha e tira o dono, situação "=". Fica de fora a teste_duplicada (a conversa nº 1).
-- (3) _conversas_volta_mari (0227/0322) não devolve à Mari quem voltou da Saída com o time (o prazo dele decide).
-- (4) Projetor em sombra: fora do andamento com fala do time nas últimas 24 h, abrir e pôr dono não é contrário e
--     ficar aberto/com dono não é falta.
-- Funções recriadas da versão no ar (pg_get_functiondef de 20/11 ~11h30), só com os trechos marcados "0335".
-- Cenários X61 (volta e, sem resposta, fecha), X62 (volta e o cliente responde), X63 (sem cobertura e instalado: ficam, a conversa
-- fecha com o tempo).
-- Regra 20: (1) duas colunas novas em mari_conversas, escritas só aqui; (2) destino (reabrir/voltar à Saída) só pela porta, com
--     anotação; dono e Chatwoot pela fila (_porta_projetar); (3) tela: nada novo (o lead aparece na Live como esperando o cliente);
--     (4) desempenho: dois laços no tique de prazos, limitados a 30.
begin;

alter table public.mari_conversas
  add column if not exists volta_time_em timestamptz,
  add column if not exists volta_time_saida jsonb;
comment on column public.mari_conversas.volta_time_em is '0335: o time escreveu ao lead na Saída e ele voltou; sem resposta em N h, volta à Saída';
comment on column public.mari_conversas.volta_time_saida is '0335: a Saída de antes (motivo, sub, em) para a volta';

insert into public.config_transicao (evento, de, para, aceito, frase, nota) values
  ('time_respondeu', 'saida_pode_voltar', array['=', 'time_esperando', 'time_agora'], true, null,
   '0335: o time escreve → o lead volta (ou fica, pela trava D5)'),
  ('prazo:volta_saida', 'andamento', array['saida_pode_voltar'], true, null,
   '0335: voltou com o time e o cliente não respondeu → a mesma Saída'),
  ('prazo:fora_fechar', '*', array['='], true, null,
   '0335: conversa aberta fora do andamento, parada → fecha e tira o dono')
on conflict (evento, de) do update set para = excluded.para, aceito = excluded.aceito, frase = excluded.frase, nota = excluded.nota;

create or replace function public._porta_volta_saida(c public.mari_conversas) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s jsonb := coalesce(c.volta_time_saida, '{}'::jsonb); v public.vendas; r jsonb;
begin
  if coalesce(s ->> 'motivo', '') = '' then raise exception 'Sem a Saída de antes para voltar.'; end if;
  select * into v from public.vendas where id = c.venda_id;
  r := public._porta_sair(c, v, s ->> 'motivo', jsonb_strip_nulls(jsonb_build_object('sub', s ->> 'sub')),
                          'NIOGEN (o time escreveu e o cliente não respondeu)', false);
  update public.mari_conversas set volta_time_em = null, volta_time_saida = null where id = c.id;
  return r;
end $$;
revoke all on function public._porta_volta_saida(public.mari_conversas) from public, anon, authenticated;

create or replace function public._porta_fora_fechar(c public.mari_conversas) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s text := public._porta_situacao(c.id, null::uuid); g uuid := gen_random_uuid(); feito text[];
begin
  feito := public._porta_projetar(c.id, 'fora_fechar',
             '🔒 NIOGEN · conversa parada fora do andamento: fechada no Chatwoot e sem dono. Se o cliente escrever, ela reabre.', 'resolved');
  if s = 'instalada' and (c.chatwoot_agente is not null or c.chatwoot_time is not null) then   -- _porta_projetar só tira o dono na Saída
    perform public._porta_ordem(g, 2, 'fora_fechar', c, 'desatribuir', jsonb_build_object('assignee_id', null));
    perform public._porta_ordem(g, 3, 'fora_fechar', c, 'desatribuir', jsonb_build_object('team_id', null));
    feito := feito || 'sem pessoa e sem time'::text;
  end if;
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[conversa parada fora do andamento — fechada no Chatwoot e sem dono]', false);
  return jsonb_build_object('ok', true, 'feito', to_jsonb(feito), 'resumo', '✓ conversa fechada (parada fora do andamento)');
end $$;
revoke all on function public._porta_fora_fechar(public.mari_conversas) from public, anon, authenticated;

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
  v_vs     jsonb;
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
  -- 0335 (Ricardo, 20/11: "Traz de volta e com o tempo, pode fechar"): o time escreve a um lead da Saída que pode voltar →
  -- o lead volta (Reabrir pela porta) e
  -- guarda a Saída de antes; se o cliente não responder em N h, _porta_prazos devolve à mesma Saída.
  if coalesce(c.funil_destino, 'em_andamento') <> 'em_andamento' and coalesce(c.saida_motivo, '') in ('recusou', 'sem_resposta')
     and not coalesce(c.nao_contatar, false)
     and public._porta_situacao(c.id, null::uuid) = 'saida_pode_voltar' then
    v_vs := jsonb_strip_nulls(jsonb_build_object('motivo', c.saida_motivo, 'sub', c.saida_sub, 'em', c.saida_em));
    begin
      perform public.porta('reabrir', c.id, c.venda_id, '{}'::jsonb);
      update public.mari_conversas set volta_time_em = now(), volta_time_saida = v_vs where id = c.id returning * into c;
    exception when others then
      null;   -- a trava da 0227 (D5) não deixou: o lead fica na Saída e a conversa fica aberta com o time (fecha com o tempo)
    end;
  end if;
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
  ged     text;
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
  -- 0287: botão da ficha (momento) e Mover do admin sem regra na tabela passam (como o _porta_conferir fazia) — a casca anota o buraco
  if r.aceito is false or (r.aceito is null and fam not in ('momento', 'mover_admin')) then
    if cliente then return jsonb_build_object('ok', false, 'situacao', antes, 'frase', r.frase); end if;
    raise exception '%', coalesce(r.frase, 'Esta ação não vale nesta situação (' || antes || ').');
  end if;
  if r.exige = 'admin' and coalesce(public.meu_perfil(), '') <> 'admin' then
    raise exception '%', r.frase using errcode = '42501';
  end if;
  -- 0298 (fase 2, passo 6 — D11, D15, E7: "só admin, com motivo"): ação que só o admin faz exige o motivo. Vale o que veio nos dados
  -- (Mover do admin) ou o que a tela preparou há pouco (porta_motivo_preparar). Sem motivo, a tela pede e repete (MOTIVO_ADMIN).
  if r.exige = 'admin' then
    declare v_mot text := btrim(coalesce(p_dados ->> 'motivo', ''));
            v_mid bigint;
    begin
      if length(v_mot) < 5 then
        select pm.id, pm.motivo into v_mid, v_mot from public.porta_motivos pm
         where pm.por = auth.uid() and pm.usado_em is null and pm.criado_em > now() - interval '5 minutes'
         order by pm.id desc limit 1;
        if v_mid is not null then
          update public.porta_motivos set usado_em = now(), evento = p_evento where id = v_mid;
        end if;
      end if;
      if length(btrim(coalesce(v_mot, ''))) < 5 then
        raise exception 'MOTIVO_ADMIN: %', coalesce(r.frase, 'Esta ação é só do admin') || ' — escreva o motivo (pelo menos 5 letras).'
          using errcode = 'P0001';
      end if;
      perform set_config('porta.motivo', left(btrim(v_mot), 500), true);
    end;
  end if;
  if r.exige = 'ged_sem_leitura' and coalesce(public.meu_perfil(), '') <> 'admin' then   -- 0272, trazido do _porta_conferir (0287)
    ged := public._ged_fresco(v.id);
    if ged is not null then raise exception '%', r.frase || ' (GED360: ' || ged || ')'; end if;
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
  -- 0287: os botões da venda (momento:*) também — viabilidade, crédito, pedido, biometria, OS, agendar, parar. Eles mudam a venda e
  -- o destino sai dos gatilhos de sempre (_funil_venda_mudou → _funil_antes), por isso também rodam SEM porta.aplicando.
  if p_evento = 'time_respondeu' then
    return public._porta_assumir(c, v, coalesce(p_dados, '{}'::jsonb) || jsonb_build_object('via', 'responder'));
  elsif p_evento = 'soprar' then   -- 0299: o time fala na voz da Mari; situação, dono e vez não mudam
    return public._porta_soprar(c, coalesce(p_dados, '{}'::jsonb));
  elsif fam = 'retomada_ligacao' then   -- 0315: o time registra a ligação da Retomada; situação, dono e vez não mudam
    return public._porta_retomada_ligacao(c, arg, coalesce(p_dados, '{}'::jsonb));
  elsif p_evento = 'aviso_sem_cobertura' then   -- 0325: aviso ao cliente da viabilidade sem cobertura; situação, dono e vez não mudam
    return public._porta_aviso_sem_cobertura(c);
  elsif fam = 'janela_acao' then   -- 0324: venda com a janela fechada — ligação ou template; situação, dono e vez não mudam
    return public._porta_janela_acao(c, arg, coalesce(p_dados, '{}'::jsonb));
  elsif p_evento = 'volta_adiar' then   -- 0318: Hora de voltar → mais N dias; situação, dono e vez não mudam
    return public._porta_volta_adiar(c, v, coalesce(p_dados, '{}'::jsonb));
  elsif fam = 'momento' then
    -- mesmos argumentos que o núcleo recebeu (venda e/ou conversa), para a peça achar a mesma conversa de antes
    return public._porta_momento(p_venda, arg, coalesce(p_dados, '{}'::jsonb)
             || case when p_conversa is not null then jsonb_build_object('conversa_id', p_conversa) else '{}'::jsonb end);
  elsif fam = 'mover_admin' then   -- 0288: o Mover do admin (a venda muda; o destino sai do gatilho vendas_porta)
    return public._porta_mover(v, arg, coalesce(p_dados, '{}'::jsonb));
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
  elsif fam = 'prazo' and arg = 'volta_saida' then               -- 0335: voltou com o time e o cliente não respondeu
    res := public._porta_volta_saida(c);
  elsif fam = 'prazo' and arg = 'fora_fechar' then               -- 0335: conversa aberta fora do andamento, parada há N h
    res := public._porta_fora_fechar(c);
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

CREATE OR REPLACE FUNCTION public._porta_prazos(p_agora timestamp with time zone DEFAULT now())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c     public.mari_conversas;
  ult   record;
  antes text;
  r     jsonb;
  n     int := 0;
  v_min int := coalesce(nullif(public._bo_cfg('esperando_fechar_min', '60'::jsonb) #>> '{}', '')::int, 60);
  v_h   numeric := coalesce(nullif(public._bo_cfg('handoff_sem_resposta_horas_uteis', '24'::jsonb) #>> '{}', '')::numeric, 24);
  v_vh  int := coalesce(nullif(public._bo_cfg('volta_time_horas', '24'::jsonb) #>> '{}', '')::int, 24);     -- 0335
  v_fh  int := coalesce(nullif(public._bo_cfg('fora_fechar_horas', '24'::jsonb) #>> '{}', '')::int, 24);    -- 0335
  v_ult timestamptz;
begin
  -- C10: o time falou por último, com uma pessoa dona, e o cliente não respondeu → fecha no Chatwoot com o dono guardado.
  -- Só com as automações do Chatwoot desligadas (a 24387 tirava o dono de toda conversa resolvida).
  if public._bo_cfg('chatwoot_automacoes', '"ligadas"'::jsonb) #>> '{}' = 'desligadas' then
    for c in
      select m.* from public.mari_conversas m
       where m.canal = 'whatsapp' and coalesce(m.chatwoot_conversation_id, '') <> '' and coalesce(m.telefone, '') not like '5500000000%'
         and coalesce(m.chatwoot_status, 'open') = 'open' and coalesce(m.funil_destino, 'em_andamento') = 'em_andamento'
         and (m.chatwoot_agente is not null or coalesce(m.humano_atribuido, false))
         and m.espera_ate is null and not coalesce(m.nao_contatar, false)
         and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.status in ('pendente', 'executando'))
       limit 30
       for update of m skip locked
    loop
      select t.papel, t.created_at into ult from public.mari_turnos t
       where t.conversa_id = c.id and t.papel in ('lead', 'mari', 'humano') order by t.created_at desc limit 1;
      if ult.papel is distinct from 'humano' or ult.created_at > p_agora - make_interval(mins => v_min) then continue; end if;
      begin
        antes := public._porta_situacao(c.id, null::uuid);
        r := public.porta('prazo:esperando_fechar', c.id, null::uuid, '{}'::jsonb);
        perform public._porta_anotar('prazo:esperando_fechar', '_porta_prazos', c.id, null::uuid, antes, r);
        n := n + 1;
      exception when others then
        insert into public.mari_erros (no_n8n, mensagem) values ('_porta_prazos', 'C10 ' || c.id::text || ': ' || sqlerrm);
      end;
    end loop;
  end if;

  -- C4: handoff para o time sem resposta em N horas úteis → a Mari volta
  for c in
    select m.* from public.mari_conversas m
     where m.status = 'handoff_realizado' and m.handoff_motivo in ('pedido_humano', 'objecao', 'urgencia_alta')
       and m.venda_id is null and coalesce(m.funil_destino, 'em_andamento') = 'em_andamento' and m.espera_ate is null
       and (coalesce(m.time_atribuido, false) or m.chatwoot_time is not null)
       and m.chatwoot_agente is null and not coalesce(m.humano_atribuido, false)
       and not exists (select 1 from public.mari_turnos t where t.conversa_id = m.id and t.papel = 'humano' and t.created_at > m.handoff_em)
       and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.status in ('pendente', 'executando'))
       and public._horas_uteis(m.handoff_em, p_agora) >= v_h
     limit 30
     for update of m skip locked
  loop
    begin
      antes := public._porta_situacao(c.id, null::uuid);
      r := public.porta('prazo:handoff_sem_resposta', c.id, null::uuid, '{}'::jsonb);
      perform public._porta_anotar('prazo:handoff_sem_resposta', '_porta_prazos', c.id, null::uuid, antes, r);
      n := n + 1;
    exception when others then
      insert into public.mari_erros (no_n8n, mensagem) values ('_porta_prazos', 'C4 ' || c.id::text || ': ' || sqlerrm);
    end;
  end loop;
  -- 0335: o time escreveu a um lead da Saída e ele voltou; o cliente não respondeu em N h → volta para a mesma Saída.
  -- O cliente respondeu, o lead saiu por outro caminho ou há pedido/OS na Nio → a marca sai e segue o fluxo normal.
  for c in
    select m.* from public.mari_conversas m where m.volta_time_em is not null limit 30 for update of m skip locked
  loop
    begin
      if coalesce(c.funil_destino, 'em_andamento') <> 'em_andamento'
         or exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead' and t.created_at > c.volta_time_em)
         or exists (select 1 from public.vendas v where v.id = c.venda_id
                     and (nullif(btrim(v.nio_pedido), '') is not null or nullif(btrim(v.nio_os), '') is not null)) then
        update public.mari_conversas set volta_time_em = null, volta_time_saida = null where id = c.id;
        continue;
      end if;
      select max(t.created_at) into v_ult from public.mari_turnos t where t.conversa_id = c.id and t.papel in ('lead', 'mari', 'humano');
      if greatest(c.volta_time_em, coalesce(v_ult, c.volta_time_em)) > p_agora - make_interval(hours => v_vh) then continue; end if;
      if exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.status in ('pendente', 'executando')) then continue; end if;
      antes := public._porta_situacao(c.id, null::uuid);
      r := public.porta('prazo:volta_saida', c.id, null::uuid, '{}'::jsonb);
      perform public._porta_anotar('prazo:volta_saida', '_porta_prazos', c.id, null::uuid, antes, r);
      n := n + 1;
    exception when others then
      insert into public.mari_erros (no_n8n, mensagem) values ('_porta_prazos', 'volta_saida ' || c.id::text || ': ' || sqlerrm);
      update public.mari_conversas set volta_time_em = null, volta_time_saida = null where id = c.id;   -- não tenta de novo a cada minuto
    end;
  end loop;

  -- 0335: conversa aberta no Chatwoot com o lead fora do andamento (instalado, Saída, cliente Nio) e N h sem ninguém falar →
  -- fecha e tira o dono (o que a situação pede). Enquanto há conversa, o projetor deixa aberta (_projetor_sombra_julgar).
  for c in
    select m.* from public.mari_conversas m
     where m.canal = 'whatsapp' and coalesce(m.chatwoot_conversation_id, '') <> '' and coalesce(m.telefone, '') not like '5500000000%'
       and coalesce(m.chatwoot_status, 'open') = 'open'
       and coalesce(m.funil_destino, 'em_andamento') not in ('em_andamento', 'teste_duplicada')
       and not exists (select 1 from public.mari_turnos t where t.conversa_id = m.id and t.papel in ('lead', 'mari', 'humano')
                        and t.created_at > p_agora - make_interval(hours => v_fh))
       and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.status in ('pendente', 'executando'))
     limit 30
     for update of m skip locked
  loop
    begin
      antes := public._porta_situacao(c.id, null::uuid);
      if antes not in ('instalada', 'saida_pode_voltar', 'saida_definitiva', 'cliente_nio', 'nao_contatar') then continue; end if;
      r := public.porta('prazo:fora_fechar', c.id, null::uuid, '{}'::jsonb);
      perform public._porta_anotar('prazo:fora_fechar', '_porta_prazos', c.id, null::uuid, antes, r);
      n := n + 1;
    exception when others then
      insert into public.mari_erros (no_n8n, mensagem) values ('_porta_prazos', 'fora_fechar ' || c.id::text || ': ' || sqlerrm);
    end;
  end loop;

  -- 0274: a Retomada (começa quando o cliente some do time; manda D3/D7/D15 pela fila do NIOGEN)
  begin
    n := n + public._retomada_tick(p_agora);
  exception when others then
    insert into public.mari_erros (no_n8n, mensagem) values ('_retomada_tick', sqlerrm);
  end;
  -- 0294: a situação gravada acompanha o que muda só com o tempo (espera que vence…) — fora da conta de n
  begin
    perform public._lead_estado_tick(p_agora);
  exception when others then
    insert into public.mari_erros (no_n8n, mensagem) values ('_lead_estado_tick', sqlerrm);
  end;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION public._conversas_volta_mari()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c   public.mari_conversas;
  g   uuid;
  n   int := 0;
begin
  for c in
    select m.* from public.mari_conversas m
     where m.canal = 'whatsapp' and m.chatwoot_conversation_id is not null
       and (m.chatwoot_status = 'resolved' or (m.chatwoot_status = 'snoozed' and m.funil_destino in ('ja_cliente_nio', 'ja_cliente')))
       and (m.chatwoot_time is not null or m.chatwoot_agente is not null or coalesce(m.humano_atribuido, false) or coalesce(m.time_atribuido, false))
       and not coalesce(m.nao_contatar, false)
       and m.volta_time_em is null   -- 0335: voltou da Saída com o time; o prazo dele decide
       and not (coalesce(m.chatwoot_etiquetas, '{}') && array['nao-contatar', 'suporte-nio'])
       and coalesce(m.quadro_encerrada_motivo, '') <> 'suporte_nio'
       and (coalesce(m.funil_destino, '') not in ('ja_cliente_nio', 'ja_cliente', 'instalada')
            -- 0227 (D2): já é cliente Nio fica com o time enquanto há conversa; 72 h sem ninguém falar → o ciclo fecha
            -- (se voltar a escrever, a Mari vê a Saída e passa para o time — cliente Nio é humano)
            or (m.funil_destino in ('ja_cliente_nio', 'ja_cliente')
                and greatest(m.ultima_msg_lead_at, m.ultima_msg_mari_at, m.created_at) < now() - interval '72 hours'
                and not exists (select 1 from public.mari_turnos t2 where t2.conversa_id = m.id and t2.papel = 'humano'
                                 and t2.created_at > now() - interval '72 hours')))
       and (m.venda_id is null or exists (select 1 from public.vendas v where v.id = m.venda_id and v.status = 'saida'))
       and greatest(m.ultima_msg_lead_at, m.ultima_msg_mari_at, m.created_at) < now() - interval '24 hours'
       and not exists (select 1 from public.mari_turnos t where t.conversa_id = m.id and t.papel = 'humano'
                        and t.created_at > now() - interval '24 hours')
       and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.momento = 'volta_mari'
                        and a.criada_em > greatest(m.ultima_msg_lead_at, m.ultima_msg_mari_at, m.created_at))
     limit 20
     for update skip locked
  loop
    g := gen_random_uuid();
    update public.mari_conversas set humano_atribuido = false, time_atribuido = false, chatwoot_agente = null, chatwoot_time = null
     where id = c.id;
    if c.status = 'handoff_realizado' then
      perform public._mari_fechar_ciclo(c.id, 'janela de 24 h fechada com o time — volta para a Mari');
    end if;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[janela de 24 h fechada com o time e sem venda viva — a conversa volta para a Mari; se o cliente escrever, ela atende]', false);
    perform public._bo_enfileirar(g, 1, 'volta_mari', c.venda_id, c, 'etiquetas',
      jsonb_build_object('add', '[]'::jsonb, 'remove', jsonb_build_array('handoff-venda', 'handoff-humano')));
    perform public._bo_enfileirar(g, 2, 'volta_mari', c.venda_id, c, 'desatribuir', jsonb_build_object('assignee_id', null));
    perform public._bo_enfileirar(g, 3, 'volta_mari', c.venda_id, c, 'desatribuir', jsonb_build_object('team_id', null));
    perform public._bo_enfileirar(g, 4, 'volta_mari', c.venda_id, c, 'nota',
      jsonb_build_object('content', '↩ NIOGEN · janela de 24 h fechada sem venda viva: a conversa volta para a Mari. Se o cliente voltar a escrever, ela atende. Para seguir com o time, assuma de novo.'));
    -- o enfileirar toca a conversa; a marca de "já devolvida" é a própria ação volta_mari (não repete até alguém falar de novo)
    n := n + 1;
  end loop;

  -- 0322 (Ricardo, 19/11: "a janela de 24 h fechou… eles precisam voltar para a Mari e para a cadência"): lead SEM venda que o time
  -- assumiu, o TIME falou por último e a janela do CLIENTE fechou (24 h desde a última mensagem dele) → volta para a Mari
  -- pela mesma peça do botão "Devolver para a Mari", anotada na porta. Venda em potencial (crédito aprovado, etapa qualificada,
  -- pedido ou biometria) fica com o time — o "Parada com dono" do Conferir cobra.
  for c in
    select m.* from public.mari_conversas m
     cross join lateral (select t.papel from public.mari_turnos t
                          where t.conversa_id = m.id and t.papel in ('lead', 'mari', 'humano') order by t.created_at desc limit 1) u
     where m.canal = 'whatsapp' and coalesce(m.chatwoot_conversation_id, '') <> '' and coalesce(m.telefone, '') not like '5500000000%'
       and m.venda_id is null and coalesce(m.funil_destino, 'em_andamento') = 'em_andamento'
       and (coalesce(m.humano_atribuido, false) or coalesce(m.time_atribuido, false) or m.chatwoot_agente is not null or m.chatwoot_time is not null)
       and coalesce(m.chatwoot_status, 'open') <> 'snoozed'
       and not coalesce(m.nao_contatar, false)
       and m.volta_time_em is null   -- 0335: voltou da Saída com o time; o prazo dele decide
       and not (coalesce(m.chatwoot_etiquetas, '{}') && array['nao-contatar', 'suporte-nio'])
       and coalesce(m.quadro_encerrada_motivo, '') <> 'suporte_nio'
       and (m.espera_ate is null or m.espera_ate <= now())
       and coalesce(m.funil_etapa, '') not in ('qualificada', 'pedido', 'biometria', 'agendada', 'instalada')
       and not coalesce(m.credito_resultado ~ '^(aprovado|cartao)', false)
       and u.papel = 'humano'   -- o TIME falou por último (num handoff a última é da Mari e quem espera é o cliente: não volta)
       and coalesce((select max(t.created_at) from public.mari_turnos t where t.conversa_id = m.id and t.papel = 'lead'), m.created_at)
           < now() - interval '24 hours'
       and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.status in ('pendente', 'executando'))
     limit 20
     for update of m skip locked
  loop
    declare v_a text; r jsonb;
    begin
      v_a := public._porta_situacao(c.id, null::uuid);
      r := public._porta_devolver(c, null::public.vendas, jsonb_build_object(
             'por', 'NIOGEN (janela de 24 h fechada)',
             'nota', '↩ NIOGEN · o cliente não responde há mais de 24 h e a janela do WhatsApp fechou: a conversa volta para a Mari e a cadência dela segue. Se ele escrever, a Mari atende. Para seguir com o time, assuma de novo.'));
      perform public._porta_anotar('momento:devolver_mari', 'janela_fechada', c.id, null::uuid, v_a, r);
      n := n + 1;
    end;
  end loop;
  return n;
end;
$function$;

CREATE OR REPLACE FUNCTION public._projetor_sombra_julgar()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c public.mari_conversas; s text; cs public.config_situacao; r public.projetor_sombra; e jsonb;
  st text; ag text; tm text; etq jsonb; v text; mot text; quero jsonb; antes jsonb; adds jsonb; rems jsonb; e2 record;
  tem_agendada_resolver boolean := false;
  quente boolean := false;   -- 0335
begin
  if not exists (select 1 from public.projetor_sombra p where p.tx = new.tx and p.conversa_id is not distinct from new.conversa_id
                  and p.veredito = 'pendente') then
    return null;   -- outra linha desta transação já julgou esta conversa
  end if;
  begin
    select * into c from public.mari_conversas where id = new.conversa_id;
    s := case when c.id is null then '(sem conversa)' else public._porta_situacao(c.id, null::uuid) end;
    select * into cs from public.config_situacao where codigo = s;
    -- 0335: fora do andamento com o time falando nas últimas 24 h → aberta e com dono pode
    quente := c.id is not null and s in ('instalada', 'saida_pode_voltar', 'saida_definitiva', 'cliente_nio')
              and (exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'humano'
                            and t.created_at > now() - interval '24 hours')
                   or exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'mensagem'
                               and coalesce(a.payload ->> 'como', '') = 'humano' and a.status in ('pendente', 'executando', 'feita')
                               and a.criada_em > now() - interval '24 hours'));   -- a mensagem do time ainda na fila
    e := case when c.id is null then '{"add":[],"remove":[]}'::jsonb else public._projetor_etiquetas(c, s) end;
    -- o Chatwoot no fim da transação: o espelho de agora + as ordens desta transação que ainda não saíram
    st := coalesce(c.chatwoot_status, 'open'); ag := c.chatwoot_agente; tm := c.chatwoot_time;
    etq := to_jsonb(coalesce(c.chatwoot_etiquetas, '{}'::text[]));

    for r in select * from public.projetor_sombra p where p.tx = new.tx and p.conversa_id is not distinct from new.conversa_id
               and p.veredito = 'pendente' order by p.id loop
      antes := coalesce(r.cw_antes, '{}'::jsonb); v := 'igual'; mot := null;
      if exists (select 1 from public.projetor_sombra p where p.tx = r.tx and p.conversa_id is not distinct from r.conversa_id
                   and p.id < r.id and p.acao_id is not null and p.tipo = r.tipo and p.payload = r.payload) then
        v := 'repetida'; mot := 'a mesma ordem já entrou nesta transação';
      elsif r.executar_apos > r.em + interval '1 minute' then
        v := 'agendada'; mot := 'sai às ' || to_char(r.executar_apos at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || ': julgar na hora';
      elsif r.tipo = 'resolver' then
        if cs.cw_status is not null and not ((r.payload ->> 'status') = any (cs.cw_status)) and not (quente and r.payload ->> 'status' = 'open') then
          v := 'contraria'; mot := 'situação ' || s || ' pede ' || array_to_string(cs.cw_status, '/') || ', a ordem põe ' || (r.payload ->> 'status');
        elsif antes ->> 'status' = r.payload ->> 'status' then
          v := 'a_mais'; mot := 'o Chatwoot já estava ' || (r.payload ->> 'status');
        end if;
      elsif r.tipo = 'atribuir' then
        if cs.dono = 'nenhum' and not quente then v := 'contraria'; mot := 'situação ' || s || ' é sem dono, a ordem põe dono'; end if;
      elsif r.tipo = 'desatribuir' then
        if r.payload ? 'team_id' and cs.dono = 'time' and (r.payload ->> 'team_id') is null then
          v := 'contraria'; mot := 'situação ' || s || ' é com o time, a ordem tira o time';
        elsif (r.payload ? 'assignee_id' and antes ->> 'agente' is null) or (r.payload ? 'team_id' and antes ->> 'time' is null) then
          v := 'a_mais'; mot := 'já estava sem ' || case when r.payload ? 'team_id' then 'time' else 'pessoa' end;
        end if;
      elsif r.tipo = 'etiquetas' then
        adds := coalesce(r.payload -> 'add', '[]'::jsonb); rems := coalesce(r.payload -> 'remove', '[]'::jsonb);
        if exists (select 1 from jsonb_array_elements_text(adds) x where (e -> 'remove') ? x)
           or exists (select 1 from jsonb_array_elements_text(rems) x where (e -> 'add') ? x) then
          v := 'contraria'; mot := 'situação ' || s || ' pede etiquetas ' || e::text;
        elsif not exists (select 1 from jsonb_array_elements_text(adds) x where not (coalesce(antes -> 'etiquetas', '[]'::jsonb) ? x))
          and not exists (select 1 from jsonb_array_elements_text(rems) x where coalesce(antes -> 'etiquetas', '[]'::jsonb) ? x) then
          v := 'a_mais'; mot := 'as etiquetas já estavam assim';
        end if;
      end if;
      update public.projetor_sombra set veredito = v, motivo = mot, situacao = s where id = r.id;
    end loop;

    -- o Chatwoot depois das ordens que ainda não saíram (desta e de transações anteriores; a que saiu já está no espelho)
    for e2 in select a.tipo, a.payload, a.executar_apos from public.chatwoot_acoes a
               where a.conversa_id = c.id and a.status in ('pendente', 'executando') order by a.id loop
      if e2.executar_apos > now() + interval '1 minute' then
        if e2.tipo = 'resolver' then tem_agendada_resolver := true; end if;
        continue;
      end if;
      if e2.tipo = 'resolver' then st := coalesce(e2.payload ->> 'status', st);
      elsif e2.tipo = 'atribuir' then
        if e2.payload ? 'assignee_id' then ag := coalesce(e2.payload ->> 'assignee_id', ag); end if;
        if e2.payload ? 'team_id' then tm := coalesce(e2.payload ->> 'team_id', tm); end if;
      elsif e2.tipo = 'desatribuir' then
        if e2.payload ? 'assignee_id' then ag := null; end if;
        if e2.payload ? 'team_id' then tm := null; end if;
      elsif e2.tipo = 'etiquetas' then
        etq := (select coalesce(jsonb_agg(distinct x), '[]'::jsonb) from (
                  select x from jsonb_array_elements_text(etq) x where not (coalesce(e2.payload -> 'remove', '[]'::jsonb) ? x)
                  union select x from jsonb_array_elements_text(coalesce(e2.payload -> 'add', '[]'::jsonb)) x) z);
      end if;
    end loop;

    -- o que a situação pede e nenhuma ordem pediu (o projetor mandaria) — só conversa de WhatsApp com Chatwoot, como no projetor
    if c.id is not null and coalesce(c.canal, '') = 'whatsapp' and coalesce(c.chatwoot_conversation_id, '') <> ''
       and coalesce(c.telefone, '') not like '5500000000%' then
      if cs.cw_status is not null and not (st = any (cs.cw_status)) and not tem_agendada_resolver and not quente then
        quero := jsonb_build_object('status', cs.cw_status[1]);
        insert into public.projetor_sombra (tx, conversa_id, momento, tipo, payload, situacao, veredito, motivo, mandaria)
        values (new.tx, c.id, 'projetor', 'resolver', null, s, 'falta', 'situação ' || s || ' pede ' || array_to_string(cs.cw_status, '/')
                || ', o Chatwoot fica ' || st, quero);
      end if;
      if cs.dono = 'nenhum' and (ag is not null or tm is not null) and not quente then
        insert into public.projetor_sombra (tx, conversa_id, momento, tipo, payload, situacao, veredito, motivo, mandaria)
        values (new.tx, c.id, 'projetor', 'desatribuir', null, s, 'falta', 'situação ' || s || ' é sem dono, o Chatwoot fica com '
                || concat_ws(' e ', case when ag is not null then 'pessoa' end, case when tm is not null then 'time' end),
                jsonb_build_object('assignee_id', null, 'team_id', null));
      end if;
      quero := jsonb_build_object(
        'add', (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements_text(e -> 'add') x where not (etq ? x)),
        'remove', (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements_text(e -> 'remove') x where etq ? x));
      if jsonb_array_length(quero -> 'add') > 0 or jsonb_array_length(quero -> 'remove') > 0 then
        insert into public.projetor_sombra (tx, conversa_id, momento, tipo, payload, situacao, veredito, motivo, mandaria)
        values (new.tx, c.id, 'projetor', 'etiquetas', null, s, 'falta', 'situação ' || s || ' pede outras etiquetas', quero);
      end if;
    end if;
  exception when others then
    update public.projetor_sombra set veredito = 'erro', motivo = left(sqlerrm, 300)
     where tx = new.tx and conversa_id is not distinct from new.conversa_id and veredito = 'pendente';
  end;
  return null;
exception when others then
  return null;   -- nunca derruba a transação de verdade
end $function$;

select public.porta_divergencias_rever();

commit;

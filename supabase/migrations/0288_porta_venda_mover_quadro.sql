-- NIOGEN | supabase/migrations/0288_porta_venda_mover_quadro.sql | 18/11/2026 — Claude Code (Opus 5.5)
-- Porta, passo seguinte, peça 2 de 3 — o que ainda mudava o lead por fora da porta passa por ela.
--  (a) VENDA MUDOU POR FORA (robôs da Nio: OSAB, portal, GED360, Consulta OS; Mover do admin; parceiro): uma peça da porta,
--      _porta_venda_mudou (gatilho vendas_porta), substitui os gatilhos vendas_funil (_funil_venda_mudou) e vendas_saida_devolve
--      (_venda_saida_devolve). Venda foi para Saída → a conversa recebe o destino do motivo; saiu da Saída → volta a "em andamento";
--      a Saída "dura" (instalada, já cliente, fora da área, sem cobertura, Não contatar, teste) vence como antes (mesma ordem do
--      config_funil). Projeta no Chatwoot, solta o dono (o que o vendas_saida_devolve fazia) e anota na sombra. A Nio continua
--      sendo a fonte: nada é recusado. Mudou outra coisa da venda → só recalcula a etapa, como antes.
--      Mudança feita pela própria porta (porta.aplicando) → só a etapa: a porta já cuidou do resto.
--  (b) MOVER DO ADMIN: _porta_mover executa (o núcleo valida e chama a porta).
--  (c) QUADRO DA TELA MARI — "Encerrada" (Ricardo, 18/11: "Vira Saída da porta"): mari_quadro_mover passa a usar a Saída da conversa
--      da ficha (backoffice_conversa_saida → porta 'silenciar:<motivo>') e "Não contatar" (conversa_nao_contatar → porta). Mesmo
--      motivo; agora com projeção no Chatwoot, Retomada quando o motivo liga ("Perdida" = Recusou sem motivo, 0280) e a recusa da
--      tabela (conversa com venda: usar a Saída da venda).
--  (d) ABERTURA "Sou cliente Nio" (achado no levantamento): a Saída "Já é cliente Nio" gravada pelo gatilho da abertura passa pela
--      porta ('silenciar:ja_cliente'). Recusa ou erro não derruba a gravação da Mari: fica em mari_erros.
-- Os ramos antigos do _funil_antes (venda, reabrir, quadro) e as funções _funil_venda_mudou/_venda_saida_devolve ficam sem uso e
-- saem na peça 3.
-- Regra 20: (1) nenhuma situação nova; (2) sem estado novo; (3) agora toda mudança de destino tem função da porta e autor (robô = "o
-- sistema"); (4) a Nio segue fonte da venda; (5) cenário X26 + R10/R12. Tela: mari.html sem mudança de código (mesma resposta).
-- Guia do backoffice: atualizar a linha do Quadro (Encerrada = Saída). Desempenho: sem impacto.
begin;

-- ── (a) a venda mudou por fora ──
create or replace function public._porta_venda_mudou()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare
  c      public.mari_conversas;
  d      jsonb;
  saiu   boolean := new.status = 'saida' and (old.status is distinct from 'saida' or new.motivo_saida is distinct from old.motivo_saida);
  voltou boolean := old.status = 'saida' and new.status is distinct from 'saida';
  alvo   text; det text; antes text; ant_dest text;
begin
  if not (new.status is distinct from old.status or new.motivo_saida is distinct from old.motivo_saida
     or new.nio_pedido is distinct from old.nio_pedido or new.nio_os is distinct from old.nio_os
     or new.biometria_status is distinct from old.biometria_status
     or new.instalacao_agendada_para is distinct from old.instalacao_agendada_para
     or new.instalado_em is distinct from old.instalado_em or new.nio_viab_resultado is distinct from old.nio_viab_resultado) then
    return null;
  end if;

  -- a própria porta mudou a venda, ou não é Saída nem volta: só a etapa (o _funil_antes recalcula, como sempre)
  if coalesce(current_setting('porta.aplicando', true), '') = '1' or not (saiu or voltou) then
    update public.mari_conversas set funil_evento = 'recalc' where venda_id = new.id;
    return null;
  end if;

  for c in select * from public.mari_conversas m where m.venda_id = new.id loop
    d := public._funil_calcular(c);
    if saiu then
      alvo := d ->> 'venda'; det := d ->> 'venda_det';
    else
      alvo := 'em_andamento'; det := 'venda reativada';
    end if;
    -- a Saída dura vence (mesma regra do _funil_antes: na volta sempre; na Saída quando vem antes na ordem)
    if d ->> 'duro' is not null and (voltou or alvo is null
        or public._funil_ordem('destino', d ->> 'duro') <= public._funil_ordem('destino', alvo)) then
      alvo := d ->> 'duro'; det := d ->> 'duro_det';
    end if;
    ant_dest := coalesce(c.funil_destino, 'em_andamento');
    antes := public._porta_situacao(c.id, null::uuid);

    perform set_config('porta.aplicando', '1', true);
    if alvo is not null and alvo is distinct from c.funil_destino then
      update public.mari_conversas
         set funil_evento = null, funil_destino = alvo, funil_detalhe = det, funil_destino_em = now(),
             chatwoot_resolvida = case when alvo = 'em_andamento' then false else chatwoot_resolvida end,
             funil_alerta = case when alvo <> 'em_andamento' then null else funil_alerta end,
             funil_alerta_em = case when alvo <> 'em_andamento' then null else funil_alerta_em end
       where id = c.id;
    else
      update public.mari_conversas set funil_evento = 'recalc' where id = c.id;   -- só a etapa
    end if;
    perform set_config('porta.aplicando', '', true);

    if alvo is not null and alvo is distinct from ant_dest then
      perform public._porta_projetar(c.id, 'destino');
      perform public._porta_anotar('funil:' || alvo, 'vendas_porta', c.id, new.id, antes,
        jsonb_build_object('ok', true, 'resumo', ant_dest || ' → ' || alvo || coalesce(' (' || det || ')', '')));
    end if;

    -- venda em Saída: ninguém fica com a conversa (o que o vendas_saida_devolve fazia)
    if saiu and c.canal = 'whatsapp'
       and (coalesce(c.humano_atribuido, false) or coalesce(c.time_atribuido, false) or c.chatwoot_agente is not null
            or c.chatwoot_time is not null or c.status = 'handoff_realizado') then
      perform public._porta_soltar(c.id, 'venda em Saída (' || coalesce(new.motivo_saida, 'sem motivo') || ')');
      insert into public.mari_turnos (conversa_id, papel, texto, pendente)
      values (c.id, 'sistema', '[venda em Saída — ' || coalesce(new.motivo_saida, 'sem motivo') || ' — vez de ninguém, sem dono]', false);
      perform public._porta_projetar(c.id, 'saida_devolver',
        '↩ Venda em Saída (' || coalesce(new.motivo_saida, 'sem motivo') || ') — sem dono. Se o cliente escrever, a Mari responde.');
    end if;
  end loop;
  return null;
exception when others then
  perform set_config('porta.aplicando', '', true);
  insert into public.mari_erros (no_n8n, mensagem) values ('_porta_venda_mudou', new.id::text || ': ' || sqlerrm);
  return null;
end $function$;

drop trigger if exists vendas_funil on public.vendas;
drop trigger if exists vendas_saida_devolve on public.vendas;
drop trigger if exists vendas_porta on public.vendas;
create trigger vendas_porta after update on public.vendas for each row execute function public._porta_venda_mudou();

-- ── (b) Mover do admin ──
create or replace function public._porta_mover(v public.vendas, p_destino text, p_dados jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare m text := btrim(coalesce(p_dados ->> 'motivo', ''));
begin
  if v.id is null then raise exception 'Venda não encontrada.' using errcode = 'P0001'; end if;
  if v.status = p_destino then return jsonb_build_object('ok', true, 'mudou', false); end if;
  if v.status = 'saida' then raise exception 'A venda está em Saída: reabra pela ficha.' using errcode = 'P0001'; end if;
  perform set_config('niogen.transicao_ok', 'admin', true);
  update public.vendas set status = p_destino where id = v.id;
  perform set_config('niogen.transicao_ok', '', true);
  insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
  values (v.id, 'movida_admin', jsonb_build_object('de', v.status, 'para', p_destino, 'motivo', left(m, 400)), auth.uid());
  return jsonb_build_object('ok', true, 'mudou', true, 'de', v.status, 'para', p_destino);
end $function$;
revoke execute on function public._porta_mover(public.vendas, text, jsonb) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.venda_mover_admin__nucleo(p_venda uuid, p_destino text, p_motivo text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare m text := btrim(coalesce(p_motivo, ''));
begin
  -- 0288: validar + porta (a porta confere a tabela e executa em _porta_mover)
  if public.meu_perfil() is distinct from 'admin' then
    raise exception 'Só o admin move a venda fora do caminho natural.' using errcode = '42501';
  end if;
  if length(m) < 5 then raise exception 'Diga o motivo (pelo menos 5 letras).' using errcode = 'P0001'; end if;
  if p_destino not in ('0_qualificado', '1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio') then
    raise exception 'Destino inválido. A Saída é pelo botão Saída.' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.vendas where id = p_venda) then raise exception 'Venda não encontrada.' using errcode = 'P0001'; end if;
  return public.porta('mover_admin:' || p_destino, null::uuid, p_venda, jsonb_build_object('motivo', m));
end;
$function$;

-- ── (c) Quadro da tela Mari: Encerrada = a Saída da conversa da ficha ──
CREATE OR REPLACE FUNCTION public.mari_quadro_mover(p_conversa uuid, p_destino text, p_motivo text DEFAULT NULL::text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  c      public.mari_conversas;
  v_col  public.config_mari_colunas;
  v_mot  jsonb;
  nc     boolean;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin e backoffice mexem nas conversas da Mari.' using errcode = '42501';
  end if;
  select * into v_col from public.config_mari_colunas where codigo = p_destino and ativo;
  if not found or not v_col.aceita_arrastar then
    return jsonb_build_object('ok', false, 'erro', 'A etapa vem da Mari: só dá para arrastar para Com humano ou Encerrada.');
  end if;
  select * into c from public.mari_conversas where id = p_conversa;
  if not found then return jsonb_build_object('ok', false, 'erro', 'Conversa não encontrada.'); end if;
  if p_destino = 'humano' then   -- o mesmo Assumir da ficha (porta)
    return public.backoffice_momento(null, 'assumir', jsonb_build_object('conversa_id', p_conversa))
           || jsonb_build_object('ok', true, 'destino', 'humano', 'chatwoot_conversation_id', c.chatwoot_conversation_id);
  end if;
  select m into v_mot from jsonb_array_elements(coalesce(v_col.motivos, '[]'::jsonb)) m where m ->> 'codigo' = p_motivo;
  if v_mot is null then return jsonb_build_object('ok', false, 'erro', 'Escolha o motivo do encerramento.'); end if;
  nc := coalesce((v_mot ->> 'nao_contatar')::boolean, false);
  -- 0288 (Ricardo, 18/11: "Vira Saída da porta"): a mesma Saída da conversa da ficha — a porta grava, projeta e recusa com a frase
  if nc then
    perform public.conversa_nao_contatar(p_conversa, 'quadro');
  else
    perform public.backoffice_conversa_saida(p_conversa, p_motivo);
  end if;
  return jsonb_build_object('ok', true, 'destino', 'encerrada', 'motivo', p_motivo, 'nao_contatar', nc,
                            'chatwoot_conversation_id', c.chatwoot_conversation_id);
end;
$function$;

-- ── (d) abertura "Sou cliente Nio": a Saída pela porta ──
CREATE OR REPLACE FUNCTION public._abertura_cliente_depois()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (new.id, 'sistema', '[Saída "Já é cliente Nio" — o cliente tocou "Sou cliente Nio" na abertura; a Mari mandou para o App Nio / 0800. Se ele escrever de novo, volta para a Mari]', false);
  -- 0288: a Saída é da porta (destino, nota e Chatwoot saem dela); recusa ou erro não derruba a gravação da Mari
  begin
    perform public.porta('silenciar:ja_cliente', new.id, null::uuid, jsonb_build_object('origem', 'abertura'));
  exception when others then
    insert into public.mari_erros (conversa_id, no_n8n, mensagem) values (new.id, '_abertura_cliente_depois', 'porta: ' || sqlerrm);
  end;
  return null;
end $function$;

-- ── (e) a porta despacha o Mover ──
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

commit;

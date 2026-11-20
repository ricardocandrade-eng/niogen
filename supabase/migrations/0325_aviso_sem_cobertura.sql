-- NIOGEN | supabase/migrations/0325_aviso_sem_cobertura.sql | 19/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 19/11: "Aproveita e analisa antes o caso da cliente Kell Gomes. Ela está sem viabilidade e foi pra Live" → análise →
-- "Vamos tratar o furo da Kell".
-- Caso Kell (L-208, Ibirité, Chatwoot 189): 14:03 a Mari mostrou os planos ("A Nio atende Ibirité… a disponibilidade exata na sua
-- rua o nosso time confirma" — regra V7: plano antes do portal); 14:04 a viabilidade automática deu SEM COBERTURA (DFV sem fachada,
-- portal "Sem viabilidade técnica") e o lead foi para Saída "Fachada não atendida" — sem nenhuma mensagem à cliente. A Mari só fala
-- quando o cliente escreve, e o aviso saida_sem_cobertura (0279/0303) só sai quando o TIME registra a Saída. Resultado: a cliente
-- ficou com os planos na mão e, depois, o time ofereceu plano a quem a Nio não atende.
-- O que muda:
--  (1) config_evento + config_transicao: "aviso_sem_cobertura" (sistema), qualquer situação ("=").
--  (2) _porta_aviso_sem_cobertura(c): manda ao cliente a mesma mensagem da Saída por cobertura (com o pedido de indicação quando
--      pode — 0303), marca dados.cobertura_avisada_em e dados.sem_cobertura_avisado (= hora do veredito: a Mari sabe que já avisou
--      se ele voltar — 0167), deixa turno de sistema e nota no Chatwoot. Se a mensagem não puder sair, a nota diz "avise à mão".
--  (3) _cobertura_avisa_veredito(): varredura a cada 1 min (dentro de backoffice_acoes_proximas). Pega quem tem veredito "sem
--      cobertura" há 2 min a 12 h, destino sem_cobertura, janela aberta, ninguém do time com a conversa (com o time, quem avisa é o
--      time — a Live mostra ⛔), sem Mari pensando, sem mensagem na fila, e que ainda não foi avisado deste veredito (nem pela Mari).
--  (3b) Ricardo, 19/11 ("Aqui deveria ter uma mensagem automática" — sobre os 11 clientes dos últimos 30 dias com veredito sem
--      cobertura e ninguém falou depois): com a janela fechada, o aviso sai pelo template nio_sem_cobertura (UTILITY, submetido à
--      Meta pelo n8n/waba_templates_indicacao.py). Até a Meta aprovar, quem está com a janela fechada fica na fila da varredura
--      (não é marcado) e sai sozinho no dia da aprovação. Vale para vereditos de até 30 dias em que ninguém falou depois.
--  (4) porta(): ramo aviso_sem_cobertura. backoffice_acoes_proximas: chama a varredura. Recriadas da versão no ar.
-- Regra 20: (1) sem estado novo — situação "="; (2) passa pela porta com evento declarado; (3) autor "NIOGEN (viabilidade)" na nota
-- e no porta_sombra; (4) fonte única: cobertura_decisao (a mesma que leva à Saída); (5) conferência: a varredura marca a tentativa e
-- a nota diz o resultado; cenário X53.
begin;

insert into public.config_templates_waba (nome, categoria, idioma, corpo, botoes, status, uso) values
  ('nio_sem_cobertura', 'UTILITY', 'pt_BR',
   'Oi, {{1}}! Aqui é a Mari, da Nio 👋' || chr(10) || chr(10) || 'Conferimos no sistema da Nio e, infelizmente, a fibra ainda não chega no seu endereço — por isso não conseguimos abrir o seu pedido agora. Desculpe a demora em avisar 🙏' || chr(10) || chr(10) || 'Se você tiver outro endereço para instalar, me manda o CEP e o número que a gente confere.',
   '[]'::jsonb, 'PENDING', 'SEM_COBERTURA')
on conflict (nome) do nothing;

insert into public.config_evento (codigo, funcao, nome, nota, quem) values
  ('aviso_sem_cobertura', '_cobertura_avisa_veredito', 'Aviso ao cliente: a viabilidade deu sem cobertura',
   'a varredura avisa quem ficou sem aviso; situação, dono e vez não mudam (0325)', 'sistema')
on conflict (codigo) do update set nome = excluded.nome, funcao = excluded.funcao, quem = excluded.quem, nota = excluded.nota;

delete from public.config_transicao where evento = 'aviso_sem_cobertura';
insert into public.config_transicao (evento, de, para, aceito, frase, nota, exige) values
  ('aviso_sem_cobertura', '*', array['='], true, null, 'Ricardo 19/11 (caso Kell): viabilidade sem cobertura avisa o cliente; nada mais muda', null);

create or replace function public._porta_aviso_sem_cobertura(c public.mari_conversas)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_ind text;
  msg   jsonb;
  ch    text;
  ver   bigint := floor(extract(epoch from c.cobertura_em))::bigint;
  rua   text := coalesce(c.cobertura_detalhe ->> 'portal_endereco', c.endereco_cep ->> 'logradouro', 'o endereço');
  g     uuid := gen_random_uuid();
begin
  if c.id is null then raise exception 'Conversa não encontrada.'; end if;
  if coalesce(c.cobertura_decisao, '') <> 'sem_cobertura' then
    return jsonb_build_object('ok', false, 'resumo', 'a viabilidade não está como sem cobertura');
  end if;
  if coalesce(c.nao_contatar, false) then
    return jsonb_build_object('ok', false, 'resumo', 'Não contatar');
  end if;
  -- marca a tentativa antes de tudo: a varredura não repete este veredito, saia ou não a mensagem
  update public.mari_conversas set dados = coalesce(dados, '{}'::jsonb) || jsonb_build_object('cobertura_aviso_tentado', ver) where id = c.id;
  v_ind := case when coalesce((public._ind_cfg() ->> 'pedir_sem_compra')::boolean, false) then public._ind_pode_pedir(c) else 'desligado' end;
  ch := case when v_ind is null then 'saida_sem_cobertura_indicacao' else 'saida_sem_cobertura' end;
  msg := public._bo_mensagem(g, 1, 'saida', c.venda_id, c, ch,
           jsonb_build_object('nome', coalesce(nullif(split_part(btrim(coalesce(c.dados ->> 'nome', '')), ' ', 1), ''), 'tudo bem')),
           'nio_sem_cobertura', jsonb_build_array(coalesce(nullif(split_part(btrim(coalesce(c.dados ->> 'nome', '')), ' ', 1), ''), 'tudo bem')),
           'aviso automático: a viabilidade deu sem cobertura');
  if msg ->> 'motivo' is null and coalesce(msg ->> 'status', '') <> 'repetida' then
    update public.mari_conversas
       set dados = coalesce(dados, '{}'::jsonb) || jsonb_build_object('cobertura_avisada_em', now(), 'sem_cobertura_avisado', ver)
     where id = c.id;
    if v_ind is null and msg ->> 'template' is null then   -- o template não pede indicação
      insert into public.indicacao_pedidos (conversa_id, venda_id, motivo, sub) values (c.id, c.venda_id, 'saida_sem_cobertura', 'fachada_nao_atendida');
    end if;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[⛔ a viabilidade da Nio deu sem cobertura em ' || rua || ' — o NIOGEN avisou o cliente'
                            || case when v_ind is null and msg ->> 'template' is null then ' e pediu indicação' else '' end
                            || case when msg ->> 'template' is not null then ' pelo template (janela fechada)' else '' end || ' (0325)]', false);
    perform public._bo_enfileirar(g, 2, 'saida', c.venda_id, c, 'nota',
      jsonb_build_object('content', '⛔ NIOGEN (viabilidade) · sem cobertura em ' || rua || ': o cliente foi avisado que a fibra ainda não chega'
        || case when v_ind is null and msg ->> 'template' is null then ' e convidado a indicar' else '' end
        || case when msg ->> 'template' is not null then ' (pelo template — a janela tinha fechado)' else '' end
        || '. Se ele mandar outro CEP, refaça a viabilidade.'));
    return jsonb_build_object('ok', true, 'resumo', 'cliente avisado: a Nio não chega no endereço');
  end if;
  perform public._bo_enfileirar(g, 2, 'saida', c.venda_id, c, 'nota',
    jsonb_build_object('content', '⛔ NIOGEN (viabilidade) · sem cobertura em ' || rua || ' — o aviso ao cliente NÃO saiu ('
      || coalesce(msg ->> 'motivo', msg ->> 'status', '?') || '): avise à mão.'));
  return jsonb_build_object('ok', false, 'resumo', 'aviso não saiu: ' || coalesce(msg ->> 'motivo', msg ->> 'status', '?'));
end $$;
revoke all on function public._porta_aviso_sem_cobertura(public.mari_conversas) from public, anon, authenticated;

create or replace function public._cobertura_avisa_veredito() returns int
language plpgsql security definer set search_path = public as $$
declare
  c   public.mari_conversas;
  v_a text;
  r   jsonb;
  n   int := 0;
begin
  for c in
    select m.* from public.mari_conversas m
     where m.canal = 'whatsapp' and coalesce(m.chatwoot_conversation_id, '') <> '' and coalesce(m.telefone, '') not like '5500000000%'
       and m.cobertura_decisao = 'sem_cobertura' and m.funil_destino = 'sem_cobertura'
       and m.cobertura_em between now() - interval '30 days' and now() - interval '2 minutes'    -- 2 min: a Mari pode estar dizendo
       and not coalesce(m.nao_contatar, false)
       and (m.ultima_msg_lead_at > now() - interval '23 hours'                                  -- janela aberta: texto livre
            or exists (select 1 from public.config_templates_waba w where w.nome = 'nio_sem_cobertura' and w.status = 'APPROVED'))   -- fechada: só com o template
       and not exists (select 1 from public.mari_turnos t where t.conversa_id = m.id and t.papel = 'mari' and t.created_at > m.cobertura_em)   -- a Mari falou depois: ela soube
       and not (m.humano_atribuido or m.time_atribuido or m.chatwoot_agente is not null)        -- com o time, avisa o time (⛔ na Live)
       and not (m.status = 'handoff_realizado' and m.handoff_motivo = 'sem_cobertura')          -- a Mari já passou dizendo
       and coalesce(m.dados ->> 'sem_cobertura_avisado', '') <> floor(extract(epoch from m.cobertura_em))::bigint::text
       and coalesce(m.dados ->> 'cobertura_aviso_tentado', '') <> floor(extract(epoch from m.cobertura_em))::bigint::text
       and (m.dados ->> 'cobertura_avisada_em' is null or (m.dados ->> 'cobertura_avisada_em')::timestamptz < m.cobertura_em)
       and not exists (select 1 from public.mari_turnos t where t.conversa_id = m.id and t.pendente)
       and not exists (select 1 from public.mari_turnos t where t.conversa_id = m.id and t.papel = 'humano' and t.created_at > m.cobertura_em)
       and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.tipo = 'mensagem' and a.status in ('pendente', 'executando'))
     order by m.cobertura_em
     limit 20
     for update skip locked
  loop
    v_a := public._porta_situacao(c.id, null::uuid);
    perform set_config('porta.dentro', 'aviso_sem_cobertura', true);
    r := public.porta('aviso_sem_cobertura', c.id, null::uuid, '{}'::jsonb);
    perform set_config('porta.dentro', '', true);
    perform public._porta_anotar('aviso_sem_cobertura', 'sem_cobertura_auto', c.id, null::uuid, v_a, r);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public._cobertura_avisa_veredito() from public, anon, authenticated;

-- backoffice_acoes_proximas (= versão no ar) + a varredura
CREATE OR REPLACE FUNCTION public.backoffice_acoes_proximas(p_limite integer DEFAULT 20)
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  a      public.chatwoot_acoes;
  c      public.mari_conversas;
  conta  text := public._bo_cfg('chatwoot_conta', '195428') #>> '{}';
  usr    jsonb := public._bo_cfg('backoffice_cred_usuario', '[]'::jsonb);
  base   text;
  n      int := 0;
begin
  if not coalesce((public._bo_cfg('backoffice_chatwoot_ligado', 'true') #>> '{}')::boolean, true) then return; end if;
  -- 0200: resolvida com o time e janela de 24 h fechada → volta para a Mari (varredura barata, a cada rodada de 1 min).
  begin perform public._conversas_volta_mari(); exception when others then
    insert into public.mari_erros (no_n8n, mensagem) values ('_conversas_volta_mari', sqlerrm); end;
  -- 0325 (caso Kell): viabilidade sem cobertura depois dos planos — avisa o cliente que ficou sem aviso.
  begin perform public._cobertura_avisa_veredito(); exception when others then
    insert into public.mari_erros (no_n8n, mensagem) values ('_cobertura_avisa_veredito', sqlerrm); end;
  -- 0229 (revisão dos fluxos, M8): mensagem presa em 'executando' cujo ECO já chegou na conversa saiu de verdade (o n8n só não
  -- conseguiu avisar o banco): fecha como feita, sem reenviar. Casos Joao 11/11 e Michele 13/11 — a mesma resposta 2×, 10 min depois.
  update public.chatwoot_acoes q set status = 'feita', feita_em = coalesce(q.feita_em, now()),
         erro = 'confirmada pelo eco da conversa (o n8n não avisou o banco)'
   where q.status = 'executando' and q.pega_em < now() - interval '10 minutes' and q.tipo = 'mensagem'
     and nullif(btrim(q.payload ->> 'content'), '') is not null
     and exists (select 1 from public.mari_turnos t where t.conversa_id = q.conversa_id and t.papel in ('humano', 'mari')
                  and t.texto = q.payload ->> 'content' and t.created_at >= q.pega_em - interval '1 minute');
  -- 'executando' preso há mais de 10 min (execução caiu no meio) volta para a fila.
  update public.chatwoot_acoes set status = case when tentativas < 3 then 'pendente' else 'erro' end,
         erro = coalesce(erro, 'execução interrompida')
   where status = 'executando' and pega_em < now() - interval '10 minutes';
  for a in
    select x.* from public.chatwoot_acoes x
     where x.status = 'pendente' and x.executar_apos <= now()
       -- 0083: o clique inteiro sai na mesma rodada (o n8n executa etiquetas primeiro e o resto na ordem do id). Só espera
       -- quando uma ação anterior do grupo ainda vai sair mais tarde (mensagem fora do horário) ou está numa rodada anterior.
       and not exists (select 1 from public.chatwoot_acoes y
                        where y.grupo = x.grupo and y.ordem < x.ordem
                          and (y.status = 'executando' or (y.status = 'pendente' and y.executar_apos > now())))
     order by x.executar_apos, x.grupo, x.ordem
     limit greatest(1, least(coalesce(p_limite, 20), 50))
     for update skip locked
  loop
    select * into c from public.mari_conversas where id = a.conversa_id;
    if a.tipo = 'mensagem' and coalesce(c.nao_contatar, false) then
      update public.chatwoot_acoes set status = 'cancelada', erro = 'cliente pediu para não ser contatado', feita_em = now() where id = a.id;
      continue;
    end if;
    update public.chatwoot_acoes set status = 'executando', tentativas = tentativas + 1, pega_em = now() where id = a.id;
    base := 'https://app.chatwoot.com/api/v1/accounts/' || conta || '/conversations/' || a.chatwoot_conversation_id;
    n := n + 1;
    return next jsonb_build_object(
      'id', a.id, 'tipo', a.tipo, 'momento', a.momento,
      'usuario', (usr ? a.tipo) or coalesce(a.payload ->> 'como', '') = 'humano',   -- 0090: resposta do time sai como pessoa
      'url_base', base,
      'url', base || case a.tipo when 'atribuir' then '/assignments' when 'desatribuir' then '/assignments'
                                 when 'etiquetas' then '/labels' when 'resolver' then '/toggle_status' else '/messages' end,
      'corpo', case a.tipo
                 when 'nota' then jsonb_build_object('content', a.payload ->> 'content', 'message_type', 'outgoing', 'private', true)
                 when 'mensagem' then (a.payload - 'texto_chave' - 'rotulo' - 'template' - 'motivo' - 'como' - 'conta')
                 when 'etiquetas' then '{}'::jsonb
                 else a.payload end,
      'add', coalesce(a.payload -> 'add', '[]'::jsonb), 'remove', coalesce(a.payload -> 'remove', '[]'::jsonb));
  end loop;
  return;
end;
$function$;

-- porta (= versão no ar, 0324) + o ramo aviso_sem_cobertura
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

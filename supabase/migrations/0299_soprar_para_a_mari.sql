-- NIOGEN | supabase/migrations/0299_soprar_para_a_mari.sql | 18/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 18/11 ~21h: "Faz só o soprar pra Mari agora." Ponderação 3 de 16/11 (docs/DIAGNOSTICO_orquestra_dos_fluxos…, seção 10):
-- "Na conversa, o time escreve uma mensagem que chega ao cliente e fica gravada como fala da Mari: ela mantém o contexto, o dono
-- não muda, ninguém precisa assumir e devolver. Entra como evento próprio ("sopro") na porta nova, com cenário no portão. Fora da
-- janela de 24 h o botão fica desligado e diz por quê."
-- Como: a fila do Chatwoot já manda mensagem na voz da Mari (é assim que a cadência sai: sem "como: humano" → token do bot) e, no
-- "feita", grava o turno como fala da Mari (backoffice_acao_resultado, 0229). O sopro usa esse trilho — o n8n não muda (nem o
-- mari_principal: o portão da Mari não se aplica). A Mari lê os turnos dela, então o contexto segue com ela.
--  (1) config_evento + config_transicao: evento "soprar". Vale com a Mari atendendo (grupo andamento, sem dono); recusa com o time
--      (responda direto), em Saída (reabra antes); Não contatar, Cliente Nio, Saída definitiva e Instalada já recusam pelo '*'.
--  (2) porta(): o evento "soprar" executa _porta_soprar (situação, dono e vez não mudam — roda sem porta.aplicando).
--  (3) _porta_soprar: confere quem (admin/backoffice), dono (só sem dono: a Mari atende), janela de 24 h e Não contatar; enfileira a
--      mensagem na voz da Mari (momento 'sopro', rótulo "soprado por <nome>").
--  (4) mari_soprar(p_conversa, p_texto): a casca que a tela chama (anota o evento na porta, como as outras).
--  (5) backoffice_acao_resultado: o sopro feito grava o contato como BO_SOPRO e o turno da Mari com tags {backoffice:'sopro', por}.
-- Recriadas da versão no ar: porta (= 0298) e backoffice_acao_resultado (= 0229, conferida igual à produção).
-- Regra 20: (1) sem estado novo (situação "=" ); (2) passa pela porta; (3) autor gravado (criada_por na fila, "por" no turno);
-- (4) sem fonte nova; (5) cenário X33. Guia: "Pela Mari" no compositor.
begin;

insert into public.config_evento (codigo, funcao, nome, nota, quem) values
  ('soprar', 'mari_soprar', 'Soprar para a Mari', 'o time escreve, sai como fala da Mari; dono, vez e situação não mudam (0299)', 'time')
on conflict do nothing;

delete from public.config_transicao where evento = 'soprar';
insert into public.config_transicao (evento, de, para, aceito, frase, nota, exige) values
  ('soprar', 'andamento', array['='], true, null, 'Ricardo 16/11 (ponderação 3): sai como fala da Mari, sem assumir; só com a Mari atendendo (sem dono)', null),
  ('soprar', 'time_agora', null, false, 'A conversa está com o time: responda direto (soprar é para quando a Mari atende).', '0299', null),
  ('soprar', 'time_esperando', null, false, 'A conversa está com o time: responda direto (soprar é para quando a Mari atende).', '0299', null),
  ('soprar', 'saida', null, false, 'Em Saída a Mari não fala: reabra antes de soprar.', '0299', null);

create or replace function public._porta_soprar(c public.mari_conversas, p_dados jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  txt      text := btrim(coalesce(p_dados ->> 'texto', ''));
  quem     text;
  ult_lead timestamptz;
  aid      bigint;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice sopra para a Mari.' using errcode = '42501';
  end if;
  if c.canal <> 'whatsapp' or coalesce(c.chatwoot_conversation_id, '') = '' then raise exception 'Esta conversa não está no Chatwoot.'; end if;
  if c.telefone like '5500000000%' then raise exception 'Telefone de teste: nada vai ao Chatwoot.'; end if;
  if coalesce(c.nao_contatar, false) then raise exception 'O cliente pediu para não ser contatado.'; end if;
  if txt = '' then raise exception 'Escreva a mensagem.'; end if;
  if length(txt) > 4000 then raise exception 'Mensagem longa demais (máx. 4.000 caracteres).'; end if;
  -- só com a Mari atendendo: com dono (pessoa ou time), quem fala é o dono — responder direto
  if coalesce(c.humano_atribuido, false) or c.chatwoot_agente is not null
     or (c.chatwoot_time is not null and coalesce(c.chatwoot_status, 'open') <> 'resolved') then
    raise exception 'A conversa está com o time (%): responda direto (soprar é para quando a Mari atende).',
      coalesce(c.chatwoot_agente, 'assumida') using errcode = 'P0001';
  end if;
  -- janela de 24 h (regra do WhatsApp): o sopro é texto livre, não tem template
  select max(t.created_at) into ult_lead from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead';
  if ult_lead is null or now() >= ult_lead + interval '23 hours' then
    raise exception 'A janela de 24 h fechou: a Mari não pode falar texto livre. Use Responder com um template aprovado.' using errcode = 'P0001';
  end if;
  quem := coalesce((select u.nome from public.usuarios u where u.id = auth.uid()), 'time');
  aid := public._bo_enfileirar(gen_random_uuid(), 1, 'sopro', c.venda_id, c, 'mensagem',
           jsonb_build_object('content', txt, 'message_type', 'outgoing', 'private', false,
                              'rotulo', 'soprado por ' || quem, 'motivo', 'sopro'));
  return jsonb_build_object('ok', true, 'acao_id', aid, 'sopro', true,
    'resumo', '✓ soprado: sai como fala da Mari (a Mari segue com a conversa)');
end $$;
revoke all on function public._porta_soprar(public.mari_conversas, jsonb) from public, anon, authenticated;

create or replace function public.mari_soprar(p_conversa uuid, p_texto text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; v_a text;
begin
  -- casca da porta (como backoffice_responder): anota o evento; quem decide e executa é a porta
  perform set_config('porta.dentro', 'mari_soprar', true);
  v_a := public._porta_situacao(p_conversa, null::uuid);
  r := public.porta('soprar', p_conversa, null::uuid, jsonb_build_object('texto', p_texto));
  perform set_config('porta.dentro', '', true);
  perform public._porta_anotar('soprar', 'mari_soprar', p_conversa, null::uuid, v_a, r);
  return r;
end $$;
revoke all on function public.mari_soprar(uuid, text) from public, anon;
grant execute on function public.mari_soprar(uuid, text) to authenticated;

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

create or replace function public.backoffice_acao_resultado(p_id bigint, p_ok boolean, p_erro text default null)
returns jsonb language plpgsql set search_path = public as $$
declare
  a public.chatwoot_acoes;
  c public.mari_conversas;
begin
  select * into a from public.chatwoot_acoes where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'erro', 'ação inexistente'); end if;
  -- 0229 (M8): o n8n agora repete este aviso quando o Supabase falha; o 2º "feita" não grava contato nem turno de novo.
  if a.status = 'feita' then return jsonb_build_object('ok', true, 'registrado', 'já estava feita'); end if;
  if not coalesce(p_ok, false) then
    update public.chatwoot_acoes
       set status = case when tentativas >= 3 then 'erro' else 'pendente' end,
           executar_apos = case when tentativas >= 3 then executar_apos else now() + interval '2 minutes' end,
           erro = left(coalesce(p_erro, 'sem detalhe'), 500)
     where id = p_id;
    if a.tentativas >= 3 then
      insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
      values (a.conversa_id, 'backoffice_chatwoot', 'ação ' || a.tipo || ' (' || a.momento || ') falhou 3×: ' || left(coalesce(p_erro, ''), 300),
              jsonb_build_object('acao_id', a.id));
    end if;
    return jsonb_build_object('ok', true, 'registrado', 'erro');
  end if;
  update public.chatwoot_acoes set status = 'feita', erro = null, feita_em = now() where id = p_id;
  if a.tipo = 'mensagem' then
    select * into c from public.mari_conversas where id = a.conversa_id;
    if a.payload ->> 'como' = 'humano' then
      -- 0090: resposta do time pela caixa do NIOGEN. Receptivo (respondeu a quem falou por último) não conta no teto.
      -- O turno 'humano' quem grava é o motor da Mari (o Chatwoot avisa a fala do usuário) — não duplica aqui.
      insert into public.contatos_cliente (venda_id, conversa_id, telefone, canal, direcao, por, em, toque, tipo, resumo)
      values (a.venda_id, a.conversa_id, c.telefone, 'whatsapp', 'saida', 'vendedor', now(), 'BO_RESPOSTA',
              case when a.payload ->> 'conta' = 'nao' then 'receptivo' else 'ativo' end,
              'NIOGEN · resposta do time' || coalesce(' · template ' || (a.payload ->> 'template'), ''));
    else
      -- 0299: o sopro é resposta do time na voz da Mari — conta como receptivo e o turno guarda quem soprou
      insert into public.contatos_cliente (venda_id, conversa_id, telefone, canal, direcao, por, em, toque, tipo, resumo)
      values (a.venda_id, a.conversa_id, c.telefone, 'whatsapp', 'saida', 'vendedor', now(), 'BO_' || upper(a.momento),
              case when a.momento = 'sopro' then 'receptivo' else 'ativo' end,
              'NIOGEN · ' || coalesce(a.payload ->> 'rotulo', a.momento) || coalesce(' · template ' || (a.payload ->> 'template'), ''));
      insert into public.mari_turnos (conversa_id, papel, texto, tags, created_at)
      values (a.conversa_id, 'mari', coalesce(a.payload ->> 'content', ''),
              jsonb_build_object('backoffice', a.momento, 'acao_id', a.id)
              || case when a.momento = 'sopro' then jsonb_build_object('por', a.criada_por) else '{}'::jsonb end, now());
    end if;
  end if;
  return jsonb_build_object('ok', true, 'registrado', 'feita');
end;
$$;

commit;

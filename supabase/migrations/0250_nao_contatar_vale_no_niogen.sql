-- NIOGEN | supabase/migrations/0250_nao_contatar_vale_no_niogen.sql | 17/11/2026 — Claude Code (Opus 5.5)
-- Portão dos fluxos (tests/fluxos), defeitos H2 e A6 — Ricardo, 17/11: "Sim" (passos 1 e 2 do caminho para o 100%).
--   H2: alguém tirou a etiqueta nao-contatar à mão no Chatwoot → a Mari respondeu a quem pediu para parar (mari_entrada só
--       olhava o texto; o guard do n8n olha a etiqueta). Agora:
--       (1) mari_entrada: coluna nao_contatar cala a Mari (silêncio, turno não pendente) — o texto "PARAR" continua marcando;
--       (2) _nao_contatar_etiqueta: gatilho também em chatwoot_etiquetas — sumiu a etiqueta de quem é Não contatar → a fila
--           recoloca (sem nota nova) e fica um turno de sistema. Liberar o contato só pelo NIOGEN.
--   A6: cliente de Não contatar escreve de novo → o Chatwoot reabre e ficava Aberta para sempre (_saidas_fechar só fecha se o
--       cliente só confirmou/despediu). (3) _saidas_fechar: Não contatar fecha 5 min depois, seja o que for (situação 14).
-- Regra 20: nenhum estado novo; Chatwoot só pela fila. Nada no n8n. Cenários: H2, A6 + os 22 do portão.
begin;

CREATE OR REPLACE FUNCTION public.mari_entrada(p_telefone text, p_nome text, p_texto text, p_canal text DEFAULT 'teste'::text, p_origem text DEFAULT NULL::text, p_chatwoot_conversation_id text DEFAULT NULL::text, p_midia jsonb DEFAULT NULL::jsonb)
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
  v_opt  boolean;   -- 0155: cliente pediu para parar (SAIR, PARAR…)
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

  v_pos := public._mari_pos_handoff(v_conv);

  -- 0250 (H2): Não contatar gravado no NIOGEN cala a Mari, mesmo que tirem a etiqueta à mão no Chatwoot
  v_opt  := public._mari_optout(p_texto) or coalesce(v_conv.nao_contatar, false);
  v_posv := coalesce(v_conv.funil_destino, '') = 'instalada';

  insert into public.mari_turnos (conversa_id, papel, texto, pendente, midia)
  values (v_conv.id, 'lead', coalesce(p_texto, ''), (v_conv.status = 'ativo' or v_pos) and not v_opt and not v_posv, public._midia_ok(p_midia));

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
    'silencio', (v_conv.status <> 'ativo' and not v_pos) or v_opt or v_posv,
    'optout', v_opt, 'pos_venda', v_posv,   -- em handoff: humano conduz, Mari calada (salvo a janela 0061)
    'pos_handoff', v_pos,
    'nova', v_conv.created_at >= now() - interval '1 second');
end;
$function$;

CREATE OR REPLACE FUNCTION public._nao_contatar_etiqueta()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_recoloca boolean;
begin
  if not coalesce(new.nao_contatar, false) then return null; end if;
  -- 0250 (H2): também quando alguém tira a etiqueta à mão no Chatwoot — o NIOGEN manda (regra de ouro 4); liberar é pelo NIOGEN
  v_recoloca := coalesce(old.nao_contatar, false);
  if v_recoloca and not ('nao-contatar' = any (coalesce(old.chatwoot_etiquetas, '{}'::text[]))) then return null; end if;
  -- 0227 (D9): a exceção da recusa saiu — desde a 0189 só quem pede para parar fica "não contatar", e aí a etiqueta vale sempre
  if coalesce(new.canal, '') <> 'whatsapp' or coalesce(new.chatwoot_conversation_id, '') = '' or coalesce(new.telefone, '') like '5500000000%' then return null; end if;
  if 'nao-contatar' = any (coalesce(new.chatwoot_etiquetas, '{}'::text[])) then return null; end if;
  if exists (select 1 from public.chatwoot_acoes a where a.conversa_id = new.id and a.tipo = 'etiquetas'
               and a.payload -> 'add' ? 'nao-contatar'
               and (a.status in ('pendente', 'executando') or (not v_recoloca and a.criada_em > now() - interval '10 minutes'))) then return null; end if;
  if v_recoloca then
    perform public._bo_enfileirar(gen_random_uuid(), 1, 'nao_contatar', new.venda_id, new, 'etiquetas',
      jsonb_build_object('add', jsonb_build_array('nao-contatar')));
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (new.id, 'sistema', '[etiqueta nao-contatar tirada no Chatwoot — recolocada: o cliente pediu para parar (0250)]', false);
    return null;
  end if;
  perform public._bo_enfileirar(gen_random_uuid(), 1, 'nao_contatar', new.venda_id, new, 'etiquetas',
    jsonb_build_object('add', jsonb_build_array('nao-contatar')));
  perform public._bo_enfileirar(gen_random_uuid(), 2, 'nao_contatar', new.venda_id, new, 'nota',
    jsonb_build_object('content', '🚫 Não contatar: o cliente pediu para parar. A Mari e os lembretes param de vez. Nunca mais chamar.'));
  return null;
exception when others then
  insert into public.mari_erros (conversa_id, no_n8n, mensagem) values (new.id, '_nao_contatar_etiqueta', sqlerrm);
  return null;
end;
$function$;

drop trigger if exists mari_conversas_nao_contatar_etiqueta on public.mari_conversas;
create trigger mari_conversas_nao_contatar_etiqueta after update of nao_contatar, chatwoot_etiquetas on public.mari_conversas
  for each row execute function public._nao_contatar_etiqueta();

CREATE OR REPLACE FUNCTION public._saidas_fechar(p_agora timestamp with time zone DEFAULT now())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c     public.mari_conversas;
  ult   record;
  nosso timestamptz;
  n     int := 0;
begin
  for c in
    select m.* from public.mari_conversas m
     where m.canal = 'whatsapp' and m.chatwoot_conversation_id is not null
       and coalesce(m.chatwoot_status, 'open') = 'open'
       and coalesce(m.funil_destino, 'em_andamento') not in ('em_andamento', 'instalada', 'teste_duplicada')   -- duplicada: várias linhas da mesma conversa
       and coalesce(m.quadro_encerrada_motivo, '') <> 'suporte_nio'
       and m.chatwoot_agente is null and not coalesce(m.humano_atribuido, false) and not coalesce(m.time_atribuido, false)
       and (m.venda_id is null or exists (select 1 from public.vendas v where v.id = m.venda_id and v.status = 'saida'))
       and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.status in ('pendente', 'executando'))
     limit 30
     for update of m skip locked
  loop
    select t.papel, t.created_at into ult from public.mari_turnos t
     where t.conversa_id = c.id and t.papel in ('lead', 'mari', 'humano') order by t.created_at desc limit 1;
    if ult.papel is null or ult.created_at > p_agora - interval '5 minutes' then continue; end if;
    -- 0250 (A6): Não contatar não reabre (situação 14: vez de ninguém) — fecha seja o que for que o cliente escreveu
    if ult.papel = 'lead' and not coalesce(c.nao_contatar, false) then
      select max(t.created_at) into nosso from public.mari_turnos t where t.conversa_id = c.id and t.papel in ('mari', 'humano');
      if nosso is null then continue; end if;
      if exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead' and t.created_at > nosso
                    and (t.midia is not null or not public._saida_so_confirmacao(t.texto))) then continue; end if;
    end if;
    perform public._bo_enfileirar(gen_random_uuid(), 1, 'saida_fechar', c.venda_id, c, 'resolver', jsonb_build_object('status', 'resolved'));
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[Saída aberta sem ninguém com o que fazer (' || case when coalesce(c.nao_contatar, false) then 'Não contatar não reabre (0250)'
            when ult.papel = 'lead' then 'o cliente só confirmou ou se despediu'
            else 'a última fala é nossa' end || ') — resolvida no Chatwoot (0249); se ele escrever, reabre]', false);
    n := n + 1;
  end loop;
  return n;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('_saidas_fechar', sqlerrm);
  return n;
end $function$;

commit;

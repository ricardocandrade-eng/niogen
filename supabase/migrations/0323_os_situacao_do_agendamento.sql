-- NIOGEN | supabase/migrations/0323_os_situacao_do_agendamento.sql | 19/11/2026 — Claude Code (Opus 5.5)
-- Ricardo, 19/11 (caso Queroly, L-156, OS 12205921): "Esse status Situação do agendamento pode ser muito bem usado por nós…
-- sinalizado dentro do Niogen de forma clara, na ficha e talvez ir até pra Live, com botão 'Ciente'. Talvez sinalizar tbem o cliente."
-- Decisões dele no mesmo dia: avisos na Live para Em deslocamento, Agendamento Cancelado, Não atribuído tarde e Atribuído/Em
-- execução; cliente avisado automático no "Em deslocamento"; leitura a cada 15 min no dia (n8n/os_leitura.json).
--
-- O operador de OS já grava a Situação do agendamento (os_andamento.status_agendamento) a cada leitura; os textos vistos desde
-- 13/11 são: Não atribuído → Atribuído → Em deslocamento → Em execução → Concluído com sucesso, e Agendamento Cancelado.
--   (1) config_os_estados ganha aviso · aviso_texto: a tradução de cada Situação para o aviso do dia (texto na língua do time,
--       {janela} e {data} trocados na hora). Sem aviso = só informação na ficha.
--   (2) _os_agenda_aviso(os_andamento): o aviso que vale AGORA para a OS — só no dia da visita (cancelada: também a de ontem);
--       "Não atribuído" só depois da metade da janela.
--   (3) os_andamento ganha agenda_ciente_chave/_em/_por; os_agenda_ciente(p_pedido) = botão "Ciente" (admin/backoffice): a linha
--       some até a Situação mudar de novo; evento os_agenda_ciente na venda, com autor.
--   (4) Gatilho em os_andamento: a Situação virou "Em deslocamento" no dia da visita → nota no Chatwoot e mensagem ao cliente
--       (bo_os_a_caminho; fora da janela de 24 h, template nio_tecnico_a_caminho) — uma vez por venda e data. Não contatar e janela
--       sem template aprovado barram dentro do _bo_mensagem (fica "bloqueada", visível na fila). Venda em Saída não avisa.
--   (5) live_conferir: item (i3) 'os_agenda'. Recriada da versão no ar (pg_get_functiondef, 19/11/2026) — só entra o (i3).
-- Regra 20: (1) nenhuma situação de lead nova — o aviso é derivado da OS, com vez (time) e prazo (o dia da visita); (2) nada
-- parado: cada aviso some sozinho quando o dia passa ou a OS muda, ou com o Ciente; (3) o lead não muda de estado aqui; o Ciente
-- e a mensagem são registros com autor (eventos_venda, chatwoot_acoes); (4) fonte: a Consulta OS da Nio (operador); (5) conferência:
-- a mensagem fica na fila chatwoot_acoes (bloqueada aparece na Live › Conferir pelo item acao_falhou/bloqueio já existente) e o
-- aviso é recalculado a cada leitura. Cenário X51.
-- Medição (7 dias): instalações do dia com "Em deslocamento" visto → cliente avisado (mensagem feita) em 100 %; visitas canceladas
-- pela Nio remarcadas no mesmo dia.
begin;

-- ── (1) tradução da Situação do agendamento ──
alter table public.config_os_estados
  add column if not exists aviso       text check (aviso in ('sem_tecnico', 'tecnico', 'a_caminho', 'instalando', 'cancelado')),
  add column if not exists aviso_texto text;
comment on column public.config_os_estados.aviso is
  '0323: aviso do dia que esta Situação do agendamento gera na Live › Conferir (nulo = só informação). Só vale para campo status_agendamento.';

insert into public.config_os_estados (campo, texto, estado, vez, origem, aviso, aviso_texto, observacao) values
  ('status_agendamento', 'Não atribuído', 'agendada', 'nio', 'seed', 'sem_tecnico',
   'Ainda sem técnico na Nio e mais da metade do período ({janela}) já passou — avise o cliente e acompanhe; se não vier, remarque no portal',
   '0323: visto na Consulta OS em 18/11/2026'),
  ('status_agendamento', 'Atribuído', 'agendada', 'nio', 'seed', 'tecnico',
   'Técnico definido pela Nio para hoje ({janela}) — confirme com o cliente que vai ter alguém maior de idade em casa',
   '0323: visto na Consulta OS em 18/11/2026'),
  ('status_agendamento', 'Em deslocamento', 'em_campo', 'nio', 'seed', 'a_caminho',
   '🚚 Técnico a caminho ({janela}) — o NIOGEN avisou o cliente pelo WhatsApp; confira se ele respondeu',
   '0323: visto na Consulta OS em 18/11/2026'),
  ('status_agendamento', 'Em execução', 'em_campo', 'nio', 'seed', 'instalando',
   '🔧 Técnico instalando agora — concluída, a venda vira Instalada sozinha',
   '0323: visto na Consulta OS em 18/11/2026'),
  ('status_agendamento', 'Agendamento Cancelado', 'pendencia_cliente', 'time', 'seed', 'cancelado',
   '⚠ A Nio cancelou a visita de {data} — ligue para o cliente agora e remarque no portal',
   '0323: visto na Consulta OS em 18/11/2026 (junto com Pendência Cliente)')
on conflict (parceiro_id, campo, texto_norm) do update
  set estado = excluded.estado, vez = excluded.vez, origem = 'seed', aviso = excluded.aviso, aviso_texto = excluded.aviso_texto,
      observacao = excluded.observacao;
update public.config_os_estados set observacao = coalesce(observacao, '') || ' · 0323: visto também com a OS já concluída (fim da visita)'
 where campo = 'status_agendamento' and texto = 'Concluído com sucesso' and coalesce(observacao, '') not like '%0323%';

-- ── (3) Ciente ──
alter table public.os_andamento
  add column if not exists agenda_ciente_chave text,
  add column if not exists agenda_ciente_em    timestamptz,
  add column if not exists agenda_ciente_por   uuid;
comment on column public.os_andamento.agenda_ciente_chave is
  '0323: retrato (status_agendamento|data) no "Ciente" da Live › Conferir › Agenda da Nio. Enquanto a Situação for a mesma, a linha fica escondida.';

-- ── (2) o aviso que vale agora ──
create or replace function public._os_agenda_aviso(a public.os_andamento)
returns table (aviso text, chave text, texto text, desde timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare
  hoje  date := (now() at time zone 'America/Sao_Paulo')::date;
  cfg   public.config_os_estados;
  m     text[];
  v_ini time;
  v_fim time;
  v_jan text;
begin
  if a.status_agendamento is null or a.agendamento_data is null then return; end if;
  cfg := public._os_traduzir(a.parceiro_id, 'status_agendamento', a.status_agendamento);
  if cfg.aviso is null then return; end if;
  if cfg.aviso = 'cancelado' then
    if a.agendamento_data < hoje - 1 then return; end if;
  elsif a.agendamento_data <> hoje then
    return;
  end if;
  v_jan := coalesce(nullif(btrim(a.janela), ''), 'período da Nio');
  if cfg.aviso = 'sem_tecnico' then
    m := regexp_match(coalesce(a.janela, ''), '(\d{1,2}:\d{2})\D+(\d{1,2}:\d{2})');
    if m is null then return; end if;
    v_ini := m[1]::time; v_fim := m[2]::time;
    if (now() at time zone 'America/Sao_Paulo')::time < v_ini + (v_fim - v_ini) / 2 then return; end if;
  end if;
  aviso := cfg.aviso;
  chave := concat_ws('|', a.status_agendamento, a.agendamento_data);
  texto := replace(replace(coalesce(cfg.aviso_texto, a.status_agendamento), '{janela}', replace(v_jan, ' - ', '–')),
                   '{data}', to_char(a.agendamento_data, 'DD/MM'));
  select min(l.lido_em) into desde from public.os_leituras l
   where l.parceiro_id = a.parceiro_id and l.pedido = a.pedido and l.status_agendamento = a.status_agendamento
     and l.lido_em > coalesce((select max(l2.lido_em) from public.os_leituras l2
                                where l2.parceiro_id = a.parceiro_id and l2.pedido = a.pedido and l2.status_agendamento is not null
                                  and l2.status_agendamento is distinct from a.status_agendamento), '-infinity');
  desde := coalesce(desde, a.mudou_em);
  return next;
end $$;
revoke all on function public._os_agenda_aviso(public.os_andamento) from public, anon;
grant execute on function public._os_agenda_aviso(public.os_andamento) to authenticated;

create or replace function public.os_agenda_ciente(p_pedido text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  a public.os_andamento;
  s record;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into a from public.os_andamento where pedido = p_pedido;
  if not found then raise exception 'OS % não encontrada.', p_pedido using errcode = 'P0001'; end if;
  select * into s from public._os_agenda_aviso(a);
  if s.aviso is null then raise exception 'Esta OS não tem aviso da agenda agora. Atualize a tela.' using errcode = 'P0001'; end if;
  update public.os_andamento set agenda_ciente_chave = s.chave, agenda_ciente_em = now(), agenda_ciente_por = auth.uid()
   where pedido = p_pedido;
  if a.venda_id is not null then
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (a.venda_id, 'os_agenda_ciente', jsonb_build_object('pedido', p_pedido, 'situacao', a.status_agendamento, 'aviso', s.aviso), auth.uid());
  end if;
  return jsonb_build_object('ok', true, 'resumo', 'Ciente · a linha volta se a Situação do agendamento mudar na Nio');
end $$;
revoke all on function public.os_agenda_ciente(text) from public, anon;
grant execute on function public.os_agenda_ciente(text) to authenticated;

-- ── (4) Em deslocamento → avisar o cliente ──
insert into public.config_mari_textos (chave, texto) values
  ('bo_os_a_caminho', E'Oi! O técnico da Nio já está a caminho para instalar a sua internet 🚚 (período {janela}).\n\nFica atento ao telefone e ao interfone; é importante ter alguém maior de idade em casa. Qualquer coisa, me chama por aqui 😊')
on conflict (chave) do update set texto = excluded.texto;

insert into public.config_templates_waba (nome, categoria, corpo, botoes, rodape, meta_id, status, uso) values
  ('nio_tecnico_a_caminho', 'UTILITY',
   E'Oi, {{1}}! É a Mari, da Nio 👋 O técnico da Nio já está a caminho para instalar a sua internet (período {{2}}).\n\nFica atento ao telefone e ao interfone; é importante ter alguém maior de idade em casa. Qualquer coisa, me chama por aqui 😊',
   '["Estou em casa", "Não vou estar"]', null, null, 'PENDING', 'OS_A_CAMINHO (0323)')
on conflict (nome) do nothing;

create or replace function public._os_agenda_avisar_cliente()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  cfg public.config_os_estados;
  v   public.vendas;
  c   public.mari_conversas;
  g   uuid := gen_random_uuid();
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  jan text;
begin
  if new.venda_id is null or new.status_agendamento is null
     or (tg_op = 'UPDATE' and new.status_agendamento is not distinct from old.status_agendamento) then return new; end if;
  if new.agendamento_data is distinct from hoje then return new; end if;
  cfg := public._os_traduzir(new.parceiro_id, 'status_agendamento', new.status_agendamento);
  if cfg.aviso is distinct from 'a_caminho' then return new; end if;
  select * into v from public.vendas where id = new.venda_id;
  if not found or v.status not in ('1_vendido', '2_aguardando_instalacao') then return new; end if;
  if exists (select 1 from public.chatwoot_acoes a
              where a.venda_id = v.id and a.tipo = 'mensagem' and a.payload ->> 'texto_chave' = 'bo_os_a_caminho'
                and a.payload ->> 'data_visita' = new.agendamento_data::text) then return new; end if;
  select * into c from public.mari_conversas
   where venda_id = v.id and canal = 'whatsapp' and coalesce(chatwoot_conversation_id, '') <> ''
   order by created_at desc limit 1;
  if c.id is null then return new; end if;
  jan := replace(coalesce(nullif(btrim(new.janela), ''), 'combinado'), ' - ', ' às ');
  perform public._bo_enfileirar(g, 1, 'instalacao', v.id, c, 'nota', jsonb_build_object('content',
    '🚚 Consulta OS: o técnico da Nio está em deslocamento (OS ' || new.pedido || ', período ' || jan || '). O cliente foi avisado.'));
  perform public._bo_mensagem(g, 2, 'instalacao', v.id, c, 'bo_os_a_caminho', jsonb_build_object('janela', jan),
                              'nio_tecnico_a_caminho', jsonb_build_array(public.mari_cadencia_nome(c), jan), 'técnico a caminho (Consulta OS)');
  update public.chatwoot_acoes set payload = payload || jsonb_build_object('data_visita', new.agendamento_data::text)
   where grupo = g and tipo = 'mensagem';
  insert into public.eventos_venda (venda_id, tipo, detalhe)
  values (v.id, 'os_a_caminho', jsonb_build_object('pedido', new.pedido, 'janela', new.janela, 'aviso_cliente', true));
  return new;
end $$;
revoke all on function public._os_agenda_avisar_cliente() from public, anon, authenticated;

drop trigger if exists os_andamento_agenda_avisa on public.os_andamento;
create trigger os_andamento_agenda_avisa after insert or update of status_agendamento on public.os_andamento
  for each row execute function public._os_agenda_avisar_cliente();

-- ── (5) live_conferir com o item (i3) ──
CREATE OR REPLACE FUNCTION public.live_conferir()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_horas numeric := coalesce((select (valor #>> '{}')::numeric from public.config_regras where chave = 'envelhecimento_dono_horas'), 24);
  v_docs  int := coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'prazo_docs_dias'), 15);
  r jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then return '[]'::jsonb; end if;
  with nomes as (
    select c.id, c.venda_id,
           coalesce(nullif(btrim(c.dados ->> 'nome'), ''), nullif(btrim(c.nome_contato), ''), 'Contato') as nome,
           c.chatwoot_agente, c.funil_alerta, c.funil_alerta_em, coalesce(c.nao_contatar, false) as nao_contatar
      from public.mari_conversas c
     where c.canal = 'whatsapp' and coalesce(c.telefone, '') not like '5500000000%'
  ),
  itens as (
    -- (a) ação do Chatwoot que falhou 3 vezes e não foi refeita depois
    select 'acao_falhou' as tipo, a.id::text as chave, a.conversa_id, a.venda_id, n.nome, a.criada_em as desde, 1 as ordem,
           format('O Chatwoot não obedeceu: %s%s', case a.tipo when 'resolver' then 'resolver / reabrir' when 'etiquetas' then 'etiqueta'
                    when 'atribuir' then 'atribuir' when 'desatribuir' then 'tirar a atribuição' when 'nota' then 'nota privada'
                    when 'mensagem' then 'mensagem ao cliente' else a.tipo end,
                  coalesce(' — ' || left(a.erro, 120), '')) as texto
      from public.chatwoot_acoes a
      left join nomes n on n.id = a.conversa_id
     where a.status = 'erro' and a.criada_em > now() - interval '7 days'
       and not exists (select 1 from public.chatwoot_acoes b where b.conversa_id = a.conversa_id and b.tipo = a.tipo
                         and b.status = 'feita' and b.criada_em > a.criada_em)
    union all
    -- (b) conversa mexida direto no Chatwoot
    select 'fora_niogen', n.id::text, n.id, n.venda_id, n.nome, n.funil_alerta_em, 2,
           case n.funil_alerta
             when 'resolvida_fora_niogen' then 'Resolvida direto no Chatwoot, sem destino — registre a Saída (ou reabra)'
             when 'mensagem_fora_niogen' then case when n.nao_contatar   -- 0183
               then 'O time respondeu direto no Chatwoot a quem pediu para NÃO ser contatado — não escrever de novo; abrir a conversa no NIOGEN e conferir'
               else 'Respondida direto no Chatwoot — responda pelo NIOGEN para a venda andar' end
             when 'atribuida_fora_niogen' then 'Atribuída direto no Chatwoot a ' || coalesce(n.chatwoot_agente, 'alguém') || ' — a Mari calou; assuma pelo NIOGEN ou devolva para a Mari'
             else 'Adiada direto no Chatwoot — some da fila sem data de volta; use ⏸ Aguardar no NIOGEN' end
      from nomes n where n.funil_alerta is not null
    union all
    -- (c) conversa em andamento com dono e sem nenhuma fala há mais de N horas
    select case when c.status = 'handoff_realizado' and c.chatwoot_agente is null and not c.humano_atribuido then 'handoff_parado' else 'dono_parado' end,
           c.id::text, c.id, c.venda_id, n.nome, u.ult, 3,
           format(case when c.status = 'handoff_realizado' and c.chatwoot_agente is null and not c.humano_atribuido
                       then 'Passada pela Mari%s e ninguém pegou há %s — assumir, devolver para a Mari ou registrar a Saída'
                       else 'Com %s e parada há %s — retomar, devolver para a Mari ou registrar a Saída' end,
                  case when c.status = 'handoff_realizado' and c.chatwoot_agente is null and not c.humano_atribuido then ''
                       else coalesce(c.chatwoot_agente, 'o time') end,
                  case when now() - u.ult >= interval '48 hours' then floor(extract(epoch from now() - u.ult) / 86400)::int || ' dias'
                       else floor(extract(epoch from now() - u.ult) / 3600)::int || ' h' end)
      from public.mari_conversas c
      join nomes n on n.id = c.id
      left join public.vendas v on v.id = c.venda_id
      cross join lateral (select max(t.created_at) as ult from public.mari_turnos t
                           where t.conversa_id = c.id and t.papel in ('lead', 'mari', 'humano')) u
     where coalesce(c.funil_destino, 'em_andamento') = 'em_andamento'
       and (c.humano_atribuido or c.time_atribuido or c.chatwoot_agente is not null or c.status = 'handoff_realizado')   -- 0155
       and not coalesce(c.nao_contatar, false)
       and c.quadro_encerrada_motivo is null
       and (c.espera_ate is null or c.espera_ate <= now())
       and coalesce(c.chatwoot_status, 'open') <> 'snoozed'
       and (v.id is null or v.status in ('0_qualificado', '1_vendido'))
       and not exists (select 1 from public.venda_pendencias vp where vp.venda_id = c.venda_id and vp.encerrada_em is null)
       and u.ult is not null and u.ult < now() - make_interval(mins => (v_horas * 60)::int)
    union all
    -- (d) documentos à Nio: 15 dias depois da instalação
    select 'docs_prazo', v.id::text, null::uuid, v.id, coalesce(nullif(btrim(v.cliente_nome), ''), 'Cliente'), v.instalado_em, 4,
           case when v.instalado_em + make_interval(days => v_docs) < now()
                  then format('Documentos à Nio ATRASADOS — o prazo era %s', to_char((v.instalado_em + make_interval(days => v_docs)) at time zone 'America/Sao_Paulo', 'DD/MM'))
                else format('Documentos à Nio até %s (%s dias depois da instalação)',
                            to_char((v.instalado_em + make_interval(days => v_docs)) at time zone 'America/Sao_Paulo', 'DD/MM'), v_docs) end
      from public.vendas v
     where v.status in ('3_instalado', '4_ativo_provisorio') and v.instalado_em is not null and v.docs_entregues_em is null
       and v.instalado_em > now() - interval '90 days'
    union all
    -- (e) 0155: cliente já instalado escreveu e ninguém do time respondeu — pós-venda
    select 'pos_venda', c.id::text, c.id, c.venda_id, n.nome, u.ult_lead, 2,
           'Cliente já instalado escreveu — é pós-venda: responda você (a Mari não responde cliente instalado)'
      from public.mari_conversas c
      join nomes n on n.id = c.id
      cross join lateral (select max(t.created_at) filter (where t.papel = 'lead') as ult_lead,
                                 max(t.created_at) filter (where t.papel = 'humano') as ult_hum
                            from public.mari_turnos t where t.conversa_id = c.id) u
     where c.funil_destino = 'instalada' and u.ult_lead is not null and u.ult_lead > now() - interval '14 days'
       and u.ult_lead > coalesce(u.ult_hum, '-infinity') and u.ult_lead > coalesce(c.dispensada_em, '-infinity')
    union all
    -- (f) 0157: saiu com pedido ou OS aberta na Nio e ninguém confirmou o cancelamento no portal
    select 'cancelar_nio', v.id::text, null::uuid, v.id, coalesce(nullif(btrim(v.cliente_nome), ''), 'Cliente'), ev.em, 2,
           -- 0271 (passo 6, Live): prazo de 24 h úteis a contar da Saída e dono = quem deu a Saída. Vencido = "VENCIDO" no texto (a Live acende).
           case when public._horas_uteis(ev.em, now()) >= 24 then 'VENCIDO · ' else 'prazo: faltam ' || greatest(1, ceil(24 - public._horas_uteis(ev.em, now())))::int || ' h úteis · ' end
             || 'Saiu com pedido aberto na Nio' || coalesce(' (nº ' || coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')) || ')', '')
             || coalesce(' · Saída dada por ' || ev.quem, '')
             || ' — cancele no portal e confirme aqui. Pedido vivo trava o CPF e o endereço (recompra = multa de R$ 500)'
      from public.vendas v
      cross join lateral (select e.criado_em as em, (select split_part(btrim(u.nome), ' ', 1) from public.usuarios u where u.id = e.criado_por) as quem
                            from public.eventos_venda e where e.venda_id = v.id and e.tipo = 'status' order by e.criado_em desc limit 1) ev
     where v.status = 'saida' and v.instalado_em is null
       and (nullif(btrim(v.nio_pedido), '') is not null or nullif(btrim(v.nio_os), '') is not null)
       and coalesce(v.motivo_saida, '') not ilike 'Nio:%'
       and v.criado_em > now() - interval '90 days'
       and not exists (select 1 from public.eventos_venda e where e.venda_id = v.id and e.tipo = 'cancelado_no_portal')
    union all
    -- (g) 0157 (D1): qualificado em andamento, sem fala do cliente há mais de N dias
    select case when l.tem_pedido_nio then 'silencio_com_pedido' else 'silencio_qualificado' end,
           l.lead_id, l.conversa_id, l.venda_id, l.nome, l.ultima_msg_lead_at, 3,
           case when l.tem_pedido_nio
                then format('Sem resposta do cliente há %s dias e com pedido aberto na Nio — insistir (ligar) ou cancelar na Nio e registrar a Saída',
                            floor(extract(epoch from now() - l.ultima_msg_lead_at) / 86400)::int)
                else format('Qualificado e sem resposta do cliente há %s dias — retomar ou registrar a Saída · Sem resposta',
                            floor(extract(epoch from now() - l.ultima_msg_lead_at) / 86400)::int) end
      from public.v_leads l
     where l.destino = 'em_andamento' and l.etapa in ('qualificado', 'instalacao') and l.status <> 'aguardando_instalacao'
       and not l.em_espera and l.venda_id is not null
       and l.ultima_msg_lead_at is not null
       and l.ultima_msg_lead_at < now() - make_interval(days => coalesce((select (valor #>> '{}')::int from public.config_regras where chave = 'saida_silencio_dias'), 15))    union all
    -- (h) 0157: saída com data de volta que chegou (recusou · momento, fachada em revisão) — vale também para conversa sem venda
    select 'volta_hoje', l.lead_id, l.conversa_id, l.venda_id, l.nome, l.volta_em::timestamptz, 3,
           format('Combinou voltar em %s (%s%s) — retomar o contato ou reabrir', to_char(l.volta_em, 'DD/MM'), l.saida_nome, coalesce(' · ' || l.saida_sub, ''))
      from public.v_leads l
     where l.destino = 'saida' and l.volta_em is not null
       and l.volta_em <= (now() at time zone 'America/Sao_Paulo')::date and l.volta_em > (now() at time zone 'America/Sao_Paulo')::date - 30
       and l.saida_motivo <> 'nao_contatar'
    union all
    -- (i) 0168: exceção da OS na Nio (Operador de OS e OSAB), com o valor em jogo e a ação
    select 'os_excecao', a.pedido, null::uuid, a.venda_id,
           coalesce(nullif(btrim(v.cliente_nome), ''), 'OS ' || a.pedido), coalesce(a.excecao_desde, a.mudou_em), 1,
           format('OS %s na Nio: %s%s%s — %s', a.pedido, coalesce(a.status_ordem, 'sem status'),
                  coalesce(' · ' || nullif(btrim(a.motivo_cancelamento), ''), ''),
                  case when coalesce(v.comissao_prevista, 0) > 0
                       then ' · R$ ' || replace(to_char(v.comissao_prevista, 'FM999990.00'), '.', ',') || ' de comissão em jogo' else '' end,
                  coalesce(a.acao, 'conferir na Consulta OS'))
      from public.os_andamento a
      left join public.vendas v on v.id = a.venda_id
     where a.excecao
       and a.excecao_vista_chave is distinct from concat_ws('|', a.estado, a.status_ordem, a.acao)   -- 0318: Visto até a OS mudar
    union all
    -- (i3) 0323: Situação do agendamento no dia da visita (sem técnico tarde, técnico definido, a caminho, instalando, cancelada)
    --       — "Ciente" esconde até a Situação mudar; a visita cancelada com a OS já em exceção fica só na linha da exceção
    select 'os_agenda', a.pedido, null::uuid, a.venda_id,
           coalesce(nullif(btrim(v.cliente_nome), ''), 'OS ' || a.pedido), s.desde,
           case when s.aviso in ('cancelado', 'sem_tecnico') then 1 else 2 end,
           s.texto
      from public.os_andamento a
      join public.vendas v on v.id = a.venda_id
      cross join lateral public._os_agenda_aviso(a) s
     where v.status in ('1_vendido', '2_aguardando_instalacao')
       and a.agenda_ciente_chave is distinct from s.chave
       and not (s.aviso = 'cancelado' and a.excecao and a.excecao_vista_chave is distinct from concat_ws('|', a.estado, a.status_ordem, a.acao))
    union all
    -- (i2) 0196: biometria da Nio fora do ar (suspeita automática pelo GED360 ou marcada pelo time)
    select 'biometria_fora', q.id::text, null::uuid, null::uuid, 'Biometria da Nio', q.inicio, 1,
           format('%s desde %s%s · %s venda(s) esperando a biometria — peça à Nio a dispensa e marque "Nio dispensou" em cada ficha; quando voltar, marque "Voltou" (Operações › Biometria)',
                  case when q.confirmada_em is null then 'Biometria da Nio parece fora do ar (GED360 sem biometria nova há ' || q.horas_sem_envio || ' h no horário comercial · confirme no grupo)'
                       else 'Biometria da Nio FORA DO AR' end,
                  to_char(q.inicio at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
                  case when q.origem = 'manual' then ' (marcada por ' || coalesce((select u.nome from public.usuarios u where u.id = q.aberta_por), 'time') || ')' else '' end,
                  (select count(*) from public.vendas v where v.status in ('1_vendido', '2_aguardando_instalacao') and v.biometria_status in ('pendente', 'com_risco')))
      from public.biometria_quedas q
     where q.fim is null
    union all
    -- (j) 0175: a conta de hoje não fechou (conferência diária, etapa 6) — uma linha por falha
    select 'conta_nao_fecha', x ->> 'codigo', null::uuid, null::uuid, 'Conferência do dia', c.rodada_em, 1,
           format('A conta não fecha — %s: %s%s', x ->> 'nome', x ->> 'texto', coalesce(' → ' || nullif(x ->> 'fazer', ''), ''))
      from public.conferencias_diarias c
      cross join lateral jsonb_array_elements(c.itens) x
     where c.dia = (now() at time zone 'America/Sao_Paulo')::date and x ->> 'nivel' = 'falha'
       and not (coalesce(c.vistos, '{}'::jsonb) ? (x ->> 'codigo'))   -- 0318: Visto hoje
    union all
    -- (k) 0182: risco de recompra — venda em andamento com CPF ou endereço repetido (só aviso; decisão do Ricardo, 13/11)
    select 'risco_recompra', rr.venda_id::text, null::uuid, rr.venda_id, coalesce(nullif(btrim(rr.cliente_nome), ''), 'Cliente'), rr.criado_em, 2,
           format('Risco de recompra — %s%s — conferir no portal ANTES de gravar o pedido e marcar "Conferi" na ficha (cliente ou endereço já na base = estorno de 100 %%; recompra = multa de R$ 500)',
                  rr.motivo, case when coalesce(rr.comissao_prevista, 0) > 0
                                  then ' · R$ ' || replace(to_char(rr.comissao_prevista, 'FM999990.00'), '.', ',') || ' de comissão em jogo' else '' end)
      from public.v_venda_risco_recompra rr
    union all
    -- (l) 0202: o portal consultou outra rua (ou disse "sem viabilidade" com a fachada viável no DFV) — o time confere a rua
    select 'conferir_rua', c.id::text, c.id, c.venda_id, n.nome, c.rua_conferir_em,
           case when c.rua_conferir_em < now() - interval '4 hours' then 1 else 2 end,
           format('%s — cliente: %s, nº %s · portal: %s%s. Refaça na Cobertura escolhendo a rua do cliente e marque "Conferi"%s',
                  case c.rua_conferir ->> 'motivo' when 'rua_divergente' then 'O portal consultou OUTRA RUA'
                       else 'O portal disse sem viabilidade, mas a fachada está viável no DFV' end,
                  coalesce(nullif(c.rua_conferir ->> 'esperada', ''), c.endereco_cep ->> 'logradouro', '?'), coalesce(c.numero, '?'),
                  coalesce(nullif(split_part(c.rua_conferir ->> 'portal', ',', 1), ''), '?'),
                  coalesce(' · DFV: ' || nullif(c.rua_conferir ->> 'dfv', ''), ''),
                  case when c.rua_conferir_em < now() - interval '4 hours' then ' · PRAZO DE 4 h VENCIDO' else ' (prazo: 4 h)' end)
      from public.mari_conversas c
      join nomes n on n.id = c.id
     where c.rua_conferir_em is not null and coalesce(c.funil_destino, 'em_andamento') = 'em_andamento'   -- 0274: Saída sai do Conferir
    union all
    -- (n) 0233: unidade a confirmar — o portal tem lista fechada de unidades e a do cliente não bate (ou ele disse "nenhuma
    -- dessas", ou o endereço não tem nenhuma cadastrada). Dono: backoffice. Prazo: 4 h.
    select 'conferir_unidade', c.id::text, c.id, c.venda_id, n.nome, c.unidade_conferir_em,
           case when c.unidade_conferir_em < now() - interval '4 hours' or c.unidade_conferir ->> 'motivo' <> 'escolher' then 1 else 2 end,
           format('%s · %s, nº %s%s',
                  case c.unidade_conferir ->> 'motivo'
                       when 'escolher' then format('Unidade a confirmar — viável no endereço; o cliente disse "%s" e o portal tem: %s. A Mari está perguntando qual é; se ele não escolher, confirme com ele. No pedido, escolha a unidade DELE (nunca outra)',
                                                   coalesce(nullif(c.unidade_conferir ->> 'informada', ''), 'nada'), coalesce(nullif(c.unidade_conferir ->> 'lista_txt', ''), '?'))
                       when 'nenhuma' then format('Unidade fora do cadastro da Nio — o cliente disse que a unidade dele não é nenhuma de: %s. Peça à Nio o cadastro da unidade (formulário) e marque "Conferi"',
                                                  coalesce(nullif(c.unidade_conferir ->> 'lista_txt', ''), '?'))
                       else format('Endereço sem unidade cadastrada na Nio (complemento "%s") — peça à Nio o cadastro da unidade (formulário) e marque "Conferi"',
                                   coalesce(nullif(c.unidade_conferir ->> 'informada', ''), c.complemento, '?')) end,
                  coalesce(c.endereco_cep ->> 'logradouro', 'CEP ' || c.cep, '?'), coalesce(c.numero, '?'),
                  case when c.unidade_conferir_em < now() - interval '4 hours' then ' · PRAZO DE 4 h VENCIDO' else ' (prazo: 4 h)' end)
      from public.mari_conversas c
      join nomes n on n.id = c.id
     where c.unidade_conferir_em is not null and coalesce(c.funil_destino, 'em_andamento') = 'em_andamento'   -- 0274
    union all
    -- (o) 0274: Retomada — o D3 saiu há 1 dia e o cliente não respondeu: o time liga (nunca automático). Some quando o D7 sai.
    select 'retomada_ligar', c.id::text, c.id, c.venda_id, n.nome, c.retomada_passo_em + interval '1 day', 2,
           format('Retomada: a Mari mandou o D3 em %s e o cliente não respondeu — ligue para %s. Se não atender, o D7 sai em %s',
                  to_char(c.retomada_passo_em at time zone 'America/Sao_Paulo', 'DD/MM'), c.telefone,
                  to_char(public._retomada_quando(c, 'D7') at time zone 'America/Sao_Paulo', 'DD/MM'))
      from public.mari_conversas c
      join nomes n on n.id = c.id
     where c.retomada_desde is not null and c.retomada_fim_em is null and c.retomada_passo = 'D3'
       and c.retomada_passo_em < now() - interval '1 day' and not coalesce(c.nao_contatar, false)
       and not exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'humano' and t.created_at > c.retomada_passo_em)
       and (c.retomada_ligacao_em is null or c.retomada_ligacao_em < c.retomada_passo_em)   -- 0315: ligação registrada tira a linha
    union all
    -- (m) 0210: o robô do GED360 está barrado (2+ leituras seguidas com erro) — sem ele ninguém fica sabendo da biometria
    select 'ged360_barrado', 'ged360', null::uuid, null::uuid, 'Robô do GED360', g.desde, 1,
           case when g.erro ilike '%simult%'
                then format('O robô do GED360 não lê desde %s: alguém entrou no GED360 com o login do robô ("logins simultâneos"). Saia do GED360 e use "⟳ Consultar no GED360" na ficha — sem o robô, biometria aprovada não avisa ninguém',
                            to_char(g.desde at time zone 'America/Sao_Paulo', 'HH24:MI'))
                else format('O robô do GED360 não lê desde %s (%s leituras com erro: %s) — biometria aprovada não avisa ninguém até voltar',
                            to_char(g.desde at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), g.n, left(g.erro, 120)) end
      from (select (select min(l.lida_em) from public.ged360_leituras l
                     where not l.ok and l.lida_em > coalesce((select max(k.lida_em) from public.ged360_leituras k where k.ok), '-infinity')) as desde,
                   (select count(*) from public.ged360_leituras l
                     where not l.ok and l.lida_em > coalesce((select max(k.lida_em) from public.ged360_leituras k where k.ok), '-infinity')) as n,
                   (select l.erro from public.ged360_leituras l order by l.lida_em desc limit 1) as erro,
                   (select l.ok from public.ged360_leituras l order by l.lida_em desc limit 1) as ultima_ok) g
     where g.ultima_ok = false and g.n >= 2
  )
  select coalesce(jsonb_agg(jsonb_build_object('tipo', tipo, 'chave', chave, 'conversa_id', conversa_id, 'venda_id', venda_id,
                                               'nome', nome, 'desde', desde, 'texto', texto) order by ordem, desde), '[]'::jsonb)
    into r from itens;
  return r;
end;
$function$;

revoke all on function public.live_conferir() from public, anon;
grant execute on function public.live_conferir() to authenticated;

commit;

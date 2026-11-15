-- NIOGEN | supabase/migrations/0210_titular_diferente_e_ged360_barrado.sql | 15/11/2026 — Claude Code (Opus 5.5)
-- Caso Grace (15/11): crédito negado no CPF dela; o pedido saiu no CPF do Caique (parente) com o contato dela; o portal não deixa
-- abrir a OS antes da biometria e guarda o pedido como "Interesse" (Histórico › Interesse) para continuar depois.
-- Ricardo, 15/11: "nesses casos a Mari deve seguir e o caso cair para o BKO tratar com o cliente e fazer o novo pedido manualmente"
-- e "uma coisa que incomoda é ter que ficar indo ao GED para consultar se aprovou a biometria".
-- O que muda:
--   vendas ...................... contato_nome / contato_relacao (quem conversa, quando NÃO é o titular), titular_anterior (jsonb),
--                                 titular_trocado_em/por, nio_interesse / nio_interesse_em (nº do Interesse salvo no portal).
--                                 cliente_nome e cliente_cpf_cnpj continuam sendo SEMPRE o titular (o que a Nio registra) — assim
--                                 GED360, OS, OSAB, recompra e comissão casam pelo CPF sem mexer em nada.
--   venda_trocar_titular() ...... admin/backoffice: troca o titular com parentesco e motivo, guarda o anterior, solta as biometrias
--                                 do CPF antigo e o crédito volta a "não gravado" (ou o resultado informado).
--   venda_gravar_interesse() .... admin/backoffice: grava o nº do Interesse do portal (pedido parado esperando a biometria).
--   _ged360_aplicar ............. biometria APROVADA numa venda sem pedido e com Interesse → alerta "agora": abrir o Interesse e gerar a OS.
--   live_conferir ............... (m) robô do GED360 barrado (2+ leituras seguidas com erro) — "login simultâneo" diz para sair do GED.
-- Regra 20: (1) a venda com Interesse tem etapa e dono (BKO) e o prazo é o alerta da biometria; (2) Interesse sem biometria aprovada
-- segue nos alertas de biometria (link expirado etc.); robô barrado vira linha no Conferir até voltar; (3) titular e Interesse mudam
-- só por função, com motivo e autor (eventos_venda); (4) pedido e biometria seguem vindo da Nio (portal e GED360); (5) conferencia_itens
-- não ganha item novo: robô barrado já aparece no Conferir enquanto dura (some quando volta a ler), e a venda com titular trocado
-- passa pelas mesmas conferências de qualquer venda (pedido, OS, biometria).

begin;
set local lock_timeout = '8s';

alter table public.vendas
  add column if not exists contato_nome       text,
  add column if not exists contato_relacao    text,
  add column if not exists titular_anterior   jsonb,
  add column if not exists titular_trocado_em timestamptz,
  add column if not exists titular_trocado_por uuid,
  add column if not exists nio_interesse      text,
  add column if not exists nio_interesse_em   timestamptz;

comment on column public.vendas.contato_nome is '0210: quem conversa com a gente quando NÃO é o titular (cliente_nome é sempre o titular da Nio).';
comment on column public.vendas.nio_interesse is '0210: nº do Interesse salvo no portal PAP (pedido parado esperando a biometria; a OS sai depois).';

-- ───────────────────────── trocar o titular ─────────────────────────
create or replace function public.venda_trocar_titular(p_venda uuid, p_nome text, p_cpf text, p_relacao text,
                                                       p_motivo text default null, p_credito text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v    public.vendas;
  doc  text := public._so_digitos(p_cpf);
  nome text := upper(btrim(regexp_replace(coalesce(p_nome, ''), '\s+', ' ', 'g')));
  rel  text := btrim(coalesce(p_relacao, ''));
  soltas int := 0;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice troca o titular.' using errcode = '42501';
  end if;
  if not public._cpf_ok(doc) then raise exception 'CPF do novo titular inválido (confira os dígitos).' using errcode = 'P0001'; end if;
  if length(nome) < 5 or nome !~ ' ' then raise exception 'Nome completo do novo titular (como saiu na Receita).' using errcode = 'P0001'; end if;
  if length(rel) < 2 then raise exception 'Diga o parentesco do titular com quem conversa (pai, mãe, filho, cônjuge…).' using errcode = 'P0001'; end if;
  if p_credito is not null and p_credito not in ('aprovado_todas', 'aprovado_cartao', 'aprovado_parcial', 'pendente', 'negado') then
    raise exception 'Resultado de crédito inválido.' using errcode = 'P0001';
  end if;
  select * into v from public.vendas where id = p_venda for update;
  if not found then raise exception 'Venda não encontrada.' using errcode = 'P0001'; end if;
  if v.status = 'saida' then raise exception 'A venda está em Saída: reabra pela ficha.' using errcode = 'P0001'; end if;
  if public._so_digitos(v.cliente_cpf_cnpj) = doc then raise exception 'Esse já é o CPF do titular desta venda.' using errcode = 'P0001'; end if;

  update public.vendas set
    titular_anterior = jsonb_build_object('nome', v.cliente_nome, 'cpf_cnpj', v.cliente_cpf_cnpj, 'credito', v.credito_resultado,
                                          'credito_em', v.credito_em, 'ate', now()),
    contato_nome = coalesce(contato_nome, v.cliente_nome),
    contato_relacao = rel,
    cliente_nome = nome,
    cliente_cpf_cnpj = doc,
    credito_resultado = p_credito,
    credito_em = case when p_credito is null then null else now() end,
    titular_trocado_em = now(),
    titular_trocado_por = auth.uid()
  where id = v.id;

  -- As biometrias do CPF antigo deixam de valer para esta venda (o próximo GED360 casa as do titular novo pelo CPF).
  update public.nio_biometria set venda_id = null where venda_id = v.id and cpf_cnpj is distinct from doc;
  get diagnostics soltas = row_count;

  insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
  values (v.id, 'titular_trocado', jsonb_build_object('de', v.cliente_nome, 'para', nome, 'relacao', rel,
          'motivo', nullif(btrim(coalesce(p_motivo, '')), ''), 'credito', p_credito, 'biometrias_soltas', soltas), auth.uid());

  -- Casa já as biometrias do titular novo que o GED360 leu antes da troca (o mapa aplica na próxima leitura).
  update public.nio_biometria set venda_id = v.id, ultima_leitura = now()
   where venda_id is null and cpf_cnpj = doc and data_envio > now() - interval '15 days';

  return jsonb_build_object('ok', true, 'titular', nome, 'contato', coalesce(v.contato_nome, v.cliente_nome), 'relacao', rel);
end;
$$;
revoke all on function public.venda_trocar_titular(uuid, text, text, text, text, text) from public, anon;
grant execute on function public.venda_trocar_titular(uuid, text, text, text, text, text) to authenticated;

-- ───────────────────────── nº do Interesse do portal ─────────────────────────
create or replace function public.venda_gravar_interesse(p_venda uuid, p_numero text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v   public.vendas;
  num text := public._so_digitos(p_numero);
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice grava o Interesse.' using errcode = '42501';
  end if;
  if num <> '' and length(num) < 10 then raise exception 'Nº do Interesse incompleto (é o número longo do Histórico de Pedidos).' using errcode = 'P0001'; end if;
  select * into v from public.vendas where id = p_venda for update;
  if not found then raise exception 'Venda não encontrada.' using errcode = 'P0001'; end if;
  update public.vendas set nio_interesse = nullif(num, ''), nio_interesse_em = case when num = '' then null else now() end where id = v.id;
  insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
  values (v.id, 'interesse_portal', jsonb_build_object('de', v.nio_interesse, 'para', nullif(num, '')), auth.uid());
  return jsonb_build_object('ok', true, 'interesse', nullif(num, ''));
end;
$$;
revoke all on function public.venda_gravar_interesse(uuid, text) from public, anon;
grant execute on function public.venda_gravar_interesse(uuid, text) to authenticated;

-- ───────────────────────── biometria aprovada com o pedido parado no Interesse ─────────────────────────
CREATE OR REPLACE FUNCTION public._ged360_aplicar(p_b nio_biometria)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  cfg public.config_biometria_resultado;
  v   public.vendas;
  feito text := null;
begin
  select * into cfg from public.config_biometria_resultado where parceiro_id = p_b.parceiro_id and resultado = p_b.resultado;
  if not found then
    return jsonb_build_object('alerta', null, 'nivel', null, 'feito', 'desconhecido');
  end if;
  -- "Concluído" sem Data da Conferência = ainda esperando a Nio; com conferência e sem regra própria, também espera (não chuta).
  if cfg.acao in ('espera') then
    return jsonb_build_object('alerta', null, 'nivel', null, 'feito', 'espera');
  end if;
  if cfg.acao = 'alerta' then
    return jsonb_build_object('alerta', cfg.texto, 'nivel', cfg.nivel, 'feito', 'alerta');
  end if;
  if p_b.venda_id is null then
    return jsonb_build_object('alerta', null, 'nivel', null, 'feito', null);
  end if;
  select * into v from public.vendas where id = p_b.venda_id for update;
  if not found or v.status = 'saida' then return jsonb_build_object('alerta', null, 'nivel', null, 'feito', null); end if;
  if cfg.acao = 'aprovada' then
    if v.biometria_status is distinct from 'validada' then
      if coalesce(btrim(v.nio_pedido), '') = '' then
        -- 0210: pedido parado no Interesse do portal → é a hora de voltar nele e gerar a OS.
        if coalesce(btrim(v.nio_interesse), '') <> '' then
          return jsonb_build_object('alerta', format('Biometria APROVADA · abrir o Interesse %s no portal (Histórico de Pedidos › tipo Interesse) e gerar a OS', v.nio_interesse),
                                    'nivel', 'agora', 'feito', null);
        end if;
        return jsonb_build_object('alerta', 'Biometria aprovada no GED360, mas a venda está sem o nº do pedido · gravar o pedido',
                                  'nivel', 'hoje', 'feito', null);
      end if;
      update public.vendas set biometria_status = 'validada' where id = v.id;
      insert into public.eventos_venda (venda_id, tipo, detalhe)
      values (v.id, 'biometria_validada', jsonb_build_object('origem', 'ged360', 'protocolo', p_b.protocolo, 'resultado', p_b.resultado));
      feito := 'biometria validada (GED360)';
    end if;
    return jsonb_build_object('alerta', null, 'nivel', null, 'feito', feito);
  end if;
  if cfg.acao = 'risco' then
    -- Não regride: antes da instalação (0191: a OS vem antes da biometria), e só se o GED360 disse isso DEPOIS de alguém marcar validada.
    if v.status in ('0_qualificado', '1_vendido', '2_aguardando_instalacao') and (v.biometria_status is distinct from 'validada' or v.biometria_validada_em < p_b.resultado_desde)
       and v.biometria_status is distinct from 'com_risco' then
      update public.vendas set biometria_status = 'com_risco' where id = v.id;
      feito := 'biometria com risco (GED360)';
    end if;
    return jsonb_build_object('alerta', cfg.texto, 'nivel', cfg.nivel, 'feito', feito);
  end if;
  return jsonb_build_object('alerta', null, 'nivel', null, 'feito', null);
end;
$function$;
revoke all on function public._ged360_aplicar(public.nio_biometria) from public, anon, authenticated;

-- ───────────────────────── Conferir: robô do GED360 barrado ─────────────────────────
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
           'Saiu com pedido aberto na Nio' || coalesce(' (nº ' || coalesce(nullif(btrim(v.nio_os), ''), nullif(btrim(v.nio_pedido), '')) || ')', '')
             || ' — cancele no portal e confirme aqui. Pedido vivo trava o CPF e o endereço (recompra = multa de R$ 500)'
      from public.vendas v
      cross join lateral (select max(e.criado_em) as em from public.eventos_venda e where e.venda_id = v.id and e.tipo = 'status') ev
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
     where c.rua_conferir_em is not null
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

commit;

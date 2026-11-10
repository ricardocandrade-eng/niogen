-- NIOGEN | supabase/migrations/0110_oportunidade_template_ligar.sql | 10/11/2026 — Claude Code
-- Conserto do prompt docs/Prompt_mari_ao_vivo_oportunidades_101126_1400.md (Ricardo, 10/11 16h02 e 16h16):
--   1. Textos sugeridos op_O1…op_O5: a pessoa assina só com o primeiro nome, SEM empresa — nunca "Dharma" e sem marca Nio.
--   2. Template da oportunidade ≠ template da cadência: a oportunidade NUNCA usa 24h/D3/D7/D15. Template novo
--      nio_oportunidade_retomada (uso = 'oportunidade', {{1}} nome do cliente, {{2}} primeiro nome do agente, sem marca, botões
--      "Quero continuar" · "Agora não"), registrado aqui como PENDING sem meta_id — quem submete é n8n/waba_template_oportunidade.py.
--   3. canal: livre (janela aberta) · template (janela fechada E template de uso 'oportunidade' APPROVED) · ligar (o resto:
--      aparece no Live com "Ligar" e o telefone, sem mensagem). RPC oportunidade_ligar registra a ligação (enviada, canal ligar).
--   4. Coordenação com a cadência: o time mandou (ou ligou) pela oportunidade hoje e o cliente não respondeu → nenhum toque
--      automático no mesmo dia; o próximo vai para o dia útil seguinte (mari_cadencia_avaliar, só um bloco a mais antes das regras
--      duras; recriada a partir da definição viva). Cliente respondeu → a regra de sempre.

-- ─────────────────────────────────────────────────────────────── 1. textos sem empresa
update public.config_mari_textos set texto = v.texto, atualizado_em = now()
  from (values
    ('op_O1', 'Oi[, {nome}]! Aqui é {agente}, que está cuidando do seu pedido de internet fibra 😊 Ficou alguma dúvida que eu possa resolver agora?'),
    ('op_O2', 'Oi[, {nome}]! Aqui é {agente}, que está cuidando do seu pedido de internet fibra 😊 Vi que você olhou os planos[ — o {plano} sai por R$ {valor}/mês, com preço fixo até 2030]. Qual deles faz mais sentido pra sua casa?'),
    ('op_O3', 'Oi[, {nome}]! Aqui é {agente}, que está cuidando do seu pedido de internet fibra. Entendo querer pensar com calma 😊 O preço é o da tabela, igual pra todo mundo, e fica fixo até 2030. Posso te ajudar a escolher o plano que cabe melhor no seu bolso?'),
    ('op_O4', 'Oi[, {nome}]! Aqui é {agente}, que está cuidando do seu pedido de internet fibra 😊 Falta pouquinho pra fechar[ o {plano}]. Posso seguir com você agora pra terminar?'),
    ('op_O5', 'Oi[, {nome}]! Aqui é {agente}, que está cuidando do seu pedido de internet fibra 😊 Boa notícia: seu endereço[ em {cidade}] tem fibra disponível. Quer que eu te mostre os planos e já deixe seu pedido encaminhado?')
  ) as v(chave, texto)
 where config_mari_textos.chave = v.chave;

-- ─────────────────────────────────────────────────────────────── 2. template próprio da oportunidade
insert into public.config_templates_waba (nome, categoria, idioma, corpo, botoes, rodape, meta_id, status, uso)
values ('nio_oportunidade_retomada', 'MARKETING', 'pt_BR',
        'Oi, {{1}}! Aqui é {{2}}, que está cuidando do seu pedido de internet fibra 😊' || chr(10) || chr(10)
        || 'Vi que a gente parou no meio da conversa. Quer continuar de onde paramos? É rapidinho.',
        '["Quero continuar", "Agora não"]'::jsonb, 'Responda SAIR para não receber mensagens.', null, 'PENDING', 'oportunidade')
on conflict (nome) do nothing;

update public.config_oportunidades
   set parametros = parametros || '{"template": "nio_oportunidade_retomada"}'::jsonb, atualizado_em = now(),
       descricao = replace(descricao, 'template (aprovado, 1 variável, usado com a janela fechada)',
                           'template (só de uso ''oportunidade'' e APPROVED; {{1}} cliente, {{2}} agente; sem ele, a janela fechada vira "ligar")')
 where codigo = 'geral';

-- ─────────────────────────────────────────────────────────────── 3. v_oportunidades (canal ligar, telefone, template de 2 variáveis)
create or replace view public.v_oportunidades with (security_invoker = true) as
with cfg as (
  select coalesce((g.p ->> 'ligado')::boolean, true)           as ligado,
         coalesce((g.p ->> 'max_dia')::int, 5)                  as max_dia,
         coalesce((g.p ->> 'max_por_conversa_dia')::int, 1)     as max_conv,
         coalesce((g.p ->> 'max_parado_dias')::numeric, 7)      as max_dias,
         coalesce((g.p ->> 'janela_horas')::numeric, 23)        as janela_h,
         g.p ->> 'template'                                     as tpl,
         (now() at time zone 'America/Sao_Paulo')::date         as hoje
    from (select coalesce((select parametros from public.config_oportunidades where codigo = 'geral'), '{}'::jsonb) as p) g
), regra as (
  select codigo, nome, pontos, ordem, parametros as p from public.config_oportunidades where ativo and codigo <> 'geral'
), tpl as (
  -- 0110: só template de uso 'oportunidade' (nunca os da cadência) e APPROVED.
  select t.nome from public.config_templates_waba t, cfg
   where t.uso = 'oportunidade' and t.status = 'APPROVED' and (cfg.tpl is null or t.nome = cfg.tpl)
   order by t.nome limit 1
), feitas_hoje as (
  select l.conversa_id, count(*) as n
    from public.oportunidades_log l, cfg
   where l.tipo in ('enviada', 'dispensada') and (l.criado_em at time zone 'America/Sao_Paulo')::date = cfg.hoje
   group by l.conversa_id
), eu as (
  select nullif(split_part(btrim(u.nome), ' ', 1), '') as nome from public.usuarios u where u.id = auth.uid()
), base as (
  select q.id as conversa_id, q.nome, q.cidade, q.cluster, q.segmento, q.coluna, q.plano_escolhido, q.plano_nome,
         q.itens_validados, q.itens_total, q.alertas, q.trava_viabilidade, q.trava_endereco_nio,
         q.ultima_em as parado_desde, c.ultima_msg_lead_at, c.forma_pagamento, c.dados, c.chatwoot_conversation_id, c.telefone,
         coalesce(nullif(split_part(btrim(c.dados ->> 'nome'), ' ', 1), ''),
                  case when c.nome_confiavel then nullif(split_part(btrim(c.nome_contato), ' ', 1), '') end) as primeiro_nome,
         public.mari_cadencia_nome(c) as nome_template,
         c.ultima_msg_lead_at + cfg.janela_h * interval '1 hour' as janela_fecha_em,
         public.minutos_uteis(q.ultima_em, now(), q.cidade) as min_uteis,
         exists (select 1 from public.mari_turnos t where t.conversa_id = q.id and t.papel = 'mari' and t.tags ? 'carrossel') as viu_planos
    from public.v_mari_quadro q
    join public.mari_conversas c on c.id = q.id
    cross join cfg
   where cfg.ligado
     and not q.teste
     and q.coluna in ('novo', 'qualificando', 'planos', 'dados', 'retomada')
     and q.vez = 'cliente' and coalesce(q.ultima_quem, '') <> 'humano'
     and q.venda_id is null
     and c.canal = 'whatsapp' and coalesce(c.chatwoot_conversation_id, '') <> ''
     and not coalesce(c.nao_contatar, false) and not coalesce(c.humano_atribuido, false) and c.chatwoot_agente is null
     and (c.espera_ate is null or c.espera_ate <= now())
     and q.trava_cliente_nio <> 'bloqueia' and q.trava_viabilidade <> 'bloqueia' and q.trava_endereco_nio <> 'bloqueia'
     and q.ultima_em > now() - cfg.max_dias * interval '1 day'
     and coalesce((select f.n from feitas_hoje f where f.conversa_id = q.id), 0) < cfg.max_conv
     and not exists (select 1 from public.oportunidades_log l
                      where l.conversa_id = q.id and l.tipo = 'enviada' and l.criado_em > coalesce(c.ultima_msg_lead_at, '-infinity'::timestamptz))
), bate as (
  select b.*, r.codigo, r.pontos, r.ordem
    from base b
    join regra r on case r.codigo
      when 'O1' then b.janela_fecha_em > now()
                 and b.janela_fecha_em <= now() + coalesce((r.p ->> 'fecha_em_horas')::numeric, 4) * interval '1 hour'
                 and (b.itens_validados >= coalesce((r.p ->> 'termometro_min')::int, 2) or b.viu_planos or b.coluna = 'planos')
      when 'O2' then b.coluna = 'planos'
                 and b.min_uteis >= coalesce((r.p ->> 'min_horas_uteis')::numeric, 2) * 60
                 and b.parado_desde >= now() - coalesce((r.p ->> 'max_horas')::numeric, 48) * interval '1 hour'
      when 'O3' then ((b.dados ->> 'objecao') in (select jsonb_array_elements_text(coalesce(r.p -> 'objecoes', '[]'::jsonb)))
                      or b.alertas && array(select jsonb_array_elements_text(coalesce(r.p -> 'alertas', '[]'::jsonb))))
                 and b.min_uteis >= coalesce((r.p ->> 'min_horas_uteis')::numeric, 1) * 60
      when 'O4' then b.itens_validados >= coalesce((r.p ->> 'termometro_min')::int, 6)
                 and b.min_uteis >= coalesce((r.p ->> 'min_horas_uteis')::numeric, 1) * 60
      when 'O5' then b.trava_viabilidade = 'ok' and b.trava_endereco_nio = 'ok'
                 and b.min_uteis >= coalesce((r.p ->> 'min_horas_uteis')::numeric, 1) * 60
      else false end
), agg as (
  select conversa_id,
         (array_agg(codigo order by pontos desc, ordem))[1] as codigo,
         array_agg(codigo order by pontos desc, ordem) as regras,
         sum(pontos)::int as pontos
    from bate group by conversa_id
), linha as (
  select a.conversa_id, a.codigo, a.regras, a.pontos, b.nome, b.primeiro_nome, b.nome_template, b.cidade, b.coluna,
         b.parado_desde, b.janela_fecha_em, b.chatwoot_conversation_id, b.itens_validados, b.itens_total, b.telefone,
         coalesce(b.plano_nome, pv.plano) as plano, pv.valor as valor_mes,
         case
           when b.janela_fecha_em > now() then 'livre'
           when exists (select 1 from tpl) then 'template'
           else 'ligar'
         end as canal,
         (select t.nome from tpl t) as template,
         case a.codigo
           when 'O1' then 'Janela de 24 h fecha em ' || public._oport_dur(b.janela_fecha_em - now())
                          || case when b.coluna = 'planos' or b.viu_planos then ' · já viu os planos' else '' end
           when 'O2' then 'Viu os planos há ' || public._oport_dur(now() - b.parado_desde) || ' e não escolheu'
           when 'O3' then case when 'desconto' = any (b.alertas) then 'Pediu desconto'
                               else 'Objeção: ' || coalesce(case b.dados ->> 'objecao' when 'preco' then 'achou caro' when 'pensar' then 'vai pensar'
                                    when 'consultar_alguem' then 'vai ver com alguém' when 'ja_tem' then 'já tem internet'
                                    when 'marca' then 'não conhece a Nio' when 'sem_5g' then 'não precisa do 5G' end, b.dados ->> 'objecao') end
                          || ' · sem resposta há ' || public._oport_dur(now() - b.parado_desde)
           when 'O4' then 'Quase pronto: ' || b.itens_validados || '/' || b.itens_total || ' dados · parou há ' || public._oport_dur(now() - b.parado_desde)
           when 'O5' then 'Viabilidade ok e endereço livre · parou há ' || public._oport_dur(now() - b.parado_desde)
         end
         || case when a.codigo <> 'O1' and 'O1' = any (a.regras) then ' · janela fecha em ' || public._oport_dur(b.janela_fecha_em - now()) else '' end
         as motivo
    from agg a
    join base b on b.conversa_id = a.conversa_id
    left join lateral public._oport_plano(b.plano_escolhido, b.forma_pagamento, b.cluster, b.segmento) pv on true
), numerada as (
  select l.*, row_number() over (order by l.pontos desc, l.janela_fecha_em nulls last, l.parado_desde) as n
    from linha l
)
select 'dharma'::text as parceiro_id, n.conversa_id, n.codigo, n.regras, n.pontos, n.nome, n.cidade, n.coluna, n.motivo,
       n.plano, n.valor_mes, n.janela_fecha_em, n.canal, n.template, n.parado_desde, n.chatwoot_conversation_id,
       case n.canal
         when 'livre' then public._oport_texto((select x.texto from public.config_mari_textos x where x.chave = 'op_' || n.codigo),
              jsonb_build_object('nome', n.primeiro_nome, 'cidade', n.cidade, 'plano', n.plano, 'valor', public._oport_reais(n.valor_mes),
                                 'agente', coalesce((select eu.nome from eu), 'o time')))
         when 'template' then public.mari_render_template(n.template, jsonb_build_array(n.nome_template, coalesce((select eu.nome from eu), 'o time')))
       end as texto_sugerido,
       n.n as ordem,
       n.telefone
  from numerada n, cfg
 where n.n <= greatest(cfg.max_dia - coalesce((select sum(f.n) from feitas_hoje f), 0), 0);

-- ─────────────────────────────────────────────────────────────── 3b. enviar: template só de oportunidade (2 variáveis); ligar não manda
create or replace function public.oportunidade_enviar(p_conversa uuid, p_texto text, p_assumir boolean default false, p_template text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o        record;
  c        public.mari_conversas;
  g        uuid := gen_random_uuid();
  quem     text;
  txt      text := btrim(coalesce(p_texto, ''));
  ult_lead timestamptz;
  v_tpl    public.config_templates_waba;
  v_pay    jsonb;
  v_nome   text;
  aid      bigint;
  r        jsonb;
  agora_t  text := to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI');
  ag       int;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice manda mensagem pelo NIOGEN.' using errcode = '42501';
  end if;
  select * into o from public.v_oportunidades where conversa_id = p_conversa;
  if not found then
    raise exception 'Esta oportunidade não está mais aberta (o cliente respondeu, alguém já mandou ou a janela fechou). Atualize a tela.';
  end if;
  if o.canal = 'ligar' then
    raise exception 'A janela de 24 h fechou e o template da oportunidade ainda não foi aprovado: ligue para o cliente.';
  end if;
  select nome, chatwoot_agente_id into quem, ag from public.usuarios where id = auth.uid();
  quem := coalesce(nullif(split_part(btrim(quem), ' ', 1), ''), 'time');

  select * into c from public.mari_conversas where id = p_conversa for update;
  if c.canal <> 'whatsapp' or coalesce(c.chatwoot_conversation_id, '') = '' then raise exception 'Esta conversa não está no Chatwoot.'; end if;
  if c.telefone like '5500000000%' then raise exception 'Telefone de teste: nada vai ao Chatwoot.'; end if;
  if coalesce(c.nao_contatar, false) then raise exception 'O cliente pediu para não ser contatado.'; end if;
  if p_template is null and txt = '' then raise exception 'Escreva a mensagem.'; end if;
  if length(txt) > 4000 then raise exception 'Mensagem longa demais (máx. 4.000 caracteres).'; end if;
  select max(t.created_at) into ult_lead from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead';

  if p_template is not null then
    -- 0110: só o template da oportunidade (nunca os da cadência 24h/D3/D7/D15).
    select * into v_tpl from public.config_templates_waba where nome = p_template and status = 'APPROVED' and uso = 'oportunidade';
    if v_tpl.nome is null then raise exception 'Template não aprovado para oportunidade: %', p_template; end if;
    v_nome := public.mari_cadencia_nome(c);
    v_pay := jsonb_build_object('content', public.mari_render_template(v_tpl.nome, jsonb_build_array(v_nome, quem)), 'content_type', 'text',
      'message_type', 'outgoing', 'private', false, 'template', v_tpl.nome,
      'template_params', jsonb_build_object('name', v_tpl.nome, 'category', v_tpl.categoria, 'language', v_tpl.idioma,
        'processed_params', jsonb_build_object('body', jsonb_build_object('1', v_nome, '2', quem))));
  else
    if ult_lead is null or now() >= ult_lead + interval '23 hours' then
      raise exception 'A janela de 24 h fechou: só o template da oportunidade (ou ligar).' using errcode = 'P0001';
    end if;
    v_pay := jsonb_build_object('content', txt, 'message_type', 'outgoing', 'private', false);
  end if;
  v_pay := v_pay || jsonb_build_object('como', 'humano', 'conta', 'sim', 'rotulo', 'oportunidade 🔥', 'oportunidade', o.codigo);

  if coalesce(p_assumir, false) then
    -- Mandar e assumir: atribui a quem mandou (a Mari cala, a cadência para) e manda.
    perform public.mari_cadencia_parar(c.id, p_humano => true);
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[🔥 assumida no NIOGEN por ' || quem || ' ao mandar a oportunidade — cadência parada]', false);
    perform public._bo_enfileirar(g, 1, 'oportunidade', c.venda_id, c, 'atribuir',
      case when ag is not null then jsonb_build_object('assignee_id', ag)
           else jsonb_build_object('team_id', (public._bo_cfg('chatwoot_time_backoffice', '15102') #>> '{}')::int) end);
    aid := public._bo_enfileirar(g, 2, 'oportunidade', c.venda_id, c, 'mensagem', v_pay);
    perform public._bo_enfileirar(g, 3, 'oportunidade', c.venda_id, c, 'nota',
      jsonb_build_object('content', '🔥 Assumida por ' || quem || ' às ' || agora_t || ' (' || coalesce(o.motivo, o.codigo) || ').'));
    r := jsonb_build_object('ok', true, 'acao_id', aid, 'assumiu', true, 'resumo', '✓ mensagem enviada · conversa assumida (a Mari calou)');
  else
    aid := public._bo_enfileirar(g, 1, 'oportunidade', c.venda_id, c, 'mensagem', v_pay);
    perform public._bo_enfileirar(g, 2, 'oportunidade', c.venda_id, c, 'nota',
      jsonb_build_object('content', '🔥 Esquentada por ' || quem || ' às ' || agora_t || ' (' || coalesce(o.motivo, o.codigo) || ') — a Mari segue.'));
    perform public._bo_enfileirar(g, 3, 'oportunidade', c.venda_id, c, 'desatribuir', jsonb_build_object('assignee_id', null));
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[🔥 esquentada no NIOGEN por ' || quem || ' — a Mari segue]', false);
    r := jsonb_build_object('ok', true, 'acao_id', aid, 'assumiu', false, 'resumo', '✓ mensagem enviada · a Mari segue a conversa');
  end if;

  insert into public.oportunidades_log (conversa_id, codigo, tipo, motivo, assumiu, canal, valor_mes, pontos, detalhe)
  values (p_conversa, o.codigo, 'enviada', o.motivo, coalesce(p_assumir, false), case when p_template is null then 'livre' else 'template' end,
          o.valor_mes, o.pontos,
          jsonb_strip_nulls(jsonb_build_object('regras', to_jsonb(o.regras), 'template', p_template,
            'editado', case when p_template is null then txt is distinct from btrim(coalesce(o.texto_sugerido, '')) end,
            'acao_id', r ->> 'acao_id')));
  return r || jsonb_build_object('oportunidade', o.codigo);
end $$;
revoke all on function public.oportunidade_enviar(uuid, text, boolean, text) from public, anon;
grant execute on function public.oportunidade_enviar(uuid, text, boolean, text) to authenticated;

-- Ligar: registra a ligação (enviada, canal ligar) + nota no Chatwoot; não manda nada ao cliente.
create or replace function public.oportunidade_ligar(p_conversa uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o       record;
  c       public.mari_conversas;
  quem    text;
  agora_t text := to_char(now() at time zone 'America/Sao_Paulo', 'HH24:MI');
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into o from public.v_oportunidades where conversa_id = p_conversa;
  if not found then raise exception 'Esta oportunidade não está mais aberta. Atualize a tela.'; end if;
  select * into c from public.mari_conversas where id = p_conversa;
  if coalesce(c.nao_contatar, false) then raise exception 'O cliente pediu para não ser contatado.'; end if;
  select nome into quem from public.usuarios where id = auth.uid();
  quem := coalesce(nullif(split_part(btrim(quem), ' ', 1), ''), 'time');
  if coalesce(c.chatwoot_conversation_id, '') <> '' and c.telefone not like '5500000000%' then
    perform public._bo_enfileirar(gen_random_uuid(), 1, 'oportunidade', c.venda_id, c, 'nota',
      jsonb_build_object('content', '📞 Ligação de ' || quem || ' às ' || agora_t || ' (🔥 ' || coalesce(o.motivo, o.codigo) || '). Anote o resultado aqui.'));
  end if;
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[📞 ligação pela oportunidade — ' || quem || ']', false);
  insert into public.oportunidades_log (conversa_id, codigo, tipo, motivo, assumiu, canal, valor_mes, pontos, detalhe)
  values (p_conversa, o.codigo, 'enviada', o.motivo, false, 'ligar', o.valor_mes, o.pontos, jsonb_build_object('regras', to_jsonb(o.regras)));
  return jsonb_build_object('ok', true, 'telefone', c.telefone, 'resumo', '📞 Ligação registrada · anote o resultado na conversa');
end $$;
revoke all on function public.oportunidade_ligar(uuid) from public, anon;
grant execute on function public.oportunidade_ligar(uuid) to authenticated;

-- A RPC rápida (0108) devolve a linha da view: recriada para pegar a coluna nova (telefone).
drop function if exists public.oportunidades_abertas();
create function public.oportunidades_abertas()
returns setof public.v_oportunidades
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    return;
  end if;
  return query select * from public.v_oportunidades order by ordem;
end $$;
revoke all on function public.oportunidades_abertas() from public, anon;
grant execute on function public.oportunidades_abertas() to authenticated;

-- ─────────────────────────────────────────────────────────────── 4. cadência: nada no mesmo dia da mensagem do time
do $mig$
declare
  def    text;
  ancora text := '    -- ── regras duras do envio: horário, teto, filtro de texto ──';
  bloco  text := $b$    -- 0110 (Ricardo, 10/11 16h02): o time mandou (ou ligou) pela 🔥 oportunidade HOJE e o cliente ainda não respondeu →
    -- nenhum toque automático no mesmo dia (nunca dois toques num dia: um do humano e um da Mari); o próximo vai para o dia
    -- útil seguinte. Retorno pedido pelo cliente (v_exc) segue valendo. Cliente respondeu → L passa da mensagem e a regra é a de sempre.
    if v_bloq is null and v_passo is not null and v_exc is null and v_acao in ('texto', 'template')
       and exists (select 1 from public.oportunidades_log ol
                    where ol.conversa_id = c.id and ol.tipo = 'enviada'
                      and ol.criado_em > coalesce(L, '-infinity'::timestamptz)
                      and (ol.criado_em at time zone 'America/Sao_Paulo')::date = (p_agora at time zone 'America/Sao_Paulo')::date) then
      v_bloq := 'o time falou com o cliente hoje (🔥 oportunidade): o toque vai para o próximo dia útil';
      v_at := greatest(v_at, public.mari_proximo_horario(((p_agora at time zone 'America/Sao_Paulo')::date + 1)::timestamp at time zone 'America/Sao_Paulo', c.cidade));
    end if;

$b$;
begin
  def := pg_get_functiondef('public.mari_cadencia_avaliar(timestamptz, uuid)'::regprocedure);
  if position('0110 (Ricardo, 10/11 16h02)' in def) > 0 then
    raise notice 'mari_cadencia_avaliar já tem o bloco da 0110';
    return;
  end if;
  if position(ancora in def) = 0 then
    raise exception 'âncora "regras duras do envio" não encontrada em mari_cadencia_avaliar — nada alterado';
  end if;
  execute replace(def, ancora, bloco || ancora);
end $mig$;

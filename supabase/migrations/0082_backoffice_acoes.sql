-- NIOGEN | supabase/migrations/0082_backoffice_acoes.sql | 09/11/2026 — Claude Code
-- Prompt docs/Prompt_fluxo_unico_backoffice_091126_1000.md (Fase 1 + view da Fase 2).
-- Fluxo único do backoffice: cada MOMENTO da venda é um botão no NIOGEN; o banco grava a venda e enfileira o que tem que
-- acontecer no Chatwoot (outbox), e o workflow n8n `backoffice_chatwoot` executa a cada 1 min com o token do bot Mari.
--
--   1. usuarios.chatwoot_agente_id (D2: Assumir atribui ao agente do Chatwoot ligado ao usuário; sem vínculo = time backoffice).
--   2. chatwoot_acoes (outbox; parceiro_id — regra 15). Front só LÊ (admin/backoffice); escreve só pelas RPCs; executa só service_role.
--   3. config_regras: backoffice_chatwoot_ligado (interruptor), chatwoot_conta, chatwoot_time_backoffice, backoffice_cred_usuario.
--   4. config_mari_textos: bo_pedido_biometria · bo_credito_negado · bo_instalacao_confirmada (textos do guia §3.1 e §3.5).
--   5. backoffice_momento(venda, momento, dados) — SECURITY DEFINER, admin/backoffice. Momentos: assumir · viabilidade · pedido ·
--      biometria · agendar · parar · devolver_mari. Faz na mesma transação o update da venda (os mesmos campos que a ficha grava;
--      as travas continuam nos triggers), o evento, a parada da cadência e a fila do Chatwoot.
--   6. Freio do contrato em toda MENSAGEM: horário (mari_proximo_horario → executar_apos), 2/dia e 15/mês (mesma contagem da
--      cadência + o que já está na fila), janela de 24 h (fechada → template aprovado; sem template → status 'bloqueada' e a linha
--      aparece na Fila como "mandar à mão").
--   7. backoffice_acoes_proximas / backoffice_acao_resultado (n8n, service_role) e backoffice_acao_manual (Fila: "já mandei").
--   8. v_fila_backoffice (security_invoker): conversas esperando o time + mensagens "mandar à mão". As vendas da Fila vêm da v_funil
--      pela mesma regra de próximo passo da tela Vendas (NG.proximoPasso) — a regra não é duplicada em SQL.

-- ───────────────────────── 1. agente do Chatwoot por usuário ─────────────────────────
alter table public.usuarios add column if not exists chatwoot_agente_id integer;
comment on column public.usuarios.chatwoot_agente_id is
  'id do agente (user) na conta Chatwoot da Nio. Assumir atribui a ele; nulo = atribui ao time backoffice (0082).';
-- Ricardo (os dois logins dele) = usuário 170307 no Chatwoot (INFRA §5).
update public.usuarios set chatwoot_agente_id = 170307 where nome = 'Ricardo Andrade' and chatwoot_agente_id is null;

-- ───────────────────────── 2. outbox ─────────────────────────
create table if not exists public.chatwoot_acoes (
  id                        bigserial primary key,
  parceiro_id               text not null default 'dharma',
  grupo                     uuid not null,                       -- um clique = um grupo; executa na ordem
  ordem                     int  not null default 0,
  momento                   text not null,
  venda_id                  uuid references public.vendas(id) on delete set null,
  conversa_id               uuid references public.mari_conversas(id) on delete set null,
  chatwoot_conversation_id  text not null,
  tipo                      text not null check (tipo in ('atribuir', 'etiquetas', 'nota', 'mensagem', 'resolver', 'desatribuir')),
  payload                   jsonb not null default '{}'::jsonb,
  criada_por                uuid,
  criada_em                 timestamptz not null default now(),
  executar_apos             timestamptz not null default now(),
  status                    text not null default 'pendente'
                            check (status in ('pendente', 'executando', 'feita', 'erro', 'bloqueada', 'manual', 'cancelada')),
  erro                      text,
  tentativas                int not null default 0,
  pega_em                   timestamptz,                         -- quando o executor pegou (destrava se cair no meio)
  feita_em                  timestamptz
);
create index if not exists chatwoot_acoes_fila_idx on public.chatwoot_acoes (status, executar_apos) where status in ('pendente', 'executando');
create index if not exists chatwoot_acoes_venda_idx on public.chatwoot_acoes (venda_id, criada_em desc);
create index if not exists chatwoot_acoes_bloq_idx on public.chatwoot_acoes (criada_em desc) where status = 'bloqueada';

alter table public.chatwoot_acoes enable row level security;
drop policy if exists chatwoot_acoes_ler on public.chatwoot_acoes;
create policy chatwoot_acoes_ler on public.chatwoot_acoes for select to authenticated
  using (coalesce(public.meu_perfil(), '') in ('admin', 'backoffice'));
revoke all on public.chatwoot_acoes from anon, authenticated;
grant select on public.chatwoot_acoes to authenticated;
grant all on public.chatwoot_acoes to service_role;
grant usage, select on sequence public.chatwoot_acoes_id_seq to service_role;

-- ───────────────────────── 3. config (regra 15: nada fixo no código) ─────────────────────────
insert into public.config_regras (chave, valor, descricao, parceiro_id) values
  ('backoffice_chatwoot_ligado', 'true'::jsonb, 'Interruptor do executor n8n backoffice_chatwoot (0082). false = a fila acumula e nada vai ao Chatwoot.', 'dharma'),
  ('chatwoot_conta', '195428'::jsonb, 'Conta Chatwoot da Nio (0082).', 'dharma'),
  ('chatwoot_time_backoffice', '15102'::jsonb, 'Time backoffice no Chatwoot: Assumir sem agente vinculado atribui a ele (0082).', 'dharma'),
  ('backoffice_cred_usuario', '[]'::jsonb, 'Tipos de ação que o executor manda com o token do Ricardo (credencial "Chatwoot Nio") em vez do bot Mari — só se o bot for recusado (0082).', 'dharma')
on conflict (chave) do nothing;

-- ───────────────────────── 4. textos (cópia exata do guia §3.1 e §3.5; confirmação sem prometer nada além da data) ─────────────────────────
insert into public.config_mari_textos (chave, texto) values
  ('bo_pedido_biometria', E'Pronto, seu pedido foi aberto! 😊\n\nA Nio acabou de te mandar o link da biometria por WhatsApp e por e-mail. Ele pede os 5 primeiros números do seu CPF e uma selfie: tira sem óculos, num lugar bem iluminado, e libera a câmera quando o celular pedir.\n\nÉ rapidinho, uns 2 minutos. Me avisa quando terminar?'),
  ('bo_credito_negado', E'Não conseguimos a aprovação no seu CPF no sistema neste momento.\n\nVocê teria outro CPF (de um familiar ou amigo) para tentarmos a aprovação e dar andamento ao seu pedido?'),
  ('bo_instalacao_confirmada', E'Instalação agendada para {dia}, {periodo} ✅\n\nO técnico da Nio vai até aí nesse período; é importante ter alguém maior de idade em casa. Se precisar remarcar, é só me avisar por aqui 😊')
on conflict (chave) do nothing;

-- ───────────────────────── helpers ─────────────────────────
create or replace function public._bo_cfg(p_chave text, p_padrao jsonb)
returns jsonb language sql stable set search_path = public as $$
  select coalesce((select valor from public.config_regras where chave = p_chave), p_padrao)
$$;

-- Enfileira uma ação (sem regra; quem chama decide).
create or replace function public._bo_enfileirar(p_grupo uuid, p_ordem int, p_momento text, p_venda uuid, c public.mari_conversas,
                                                 p_tipo text, p_payload jsonb, p_quando timestamptz default now(),
                                                 p_status text default 'pendente', p_erro text default null)
returns bigint language plpgsql set search_path = public as $$
declare v_id bigint;
begin
  insert into public.chatwoot_acoes (grupo, ordem, momento, venda_id, conversa_id, chatwoot_conversation_id, tipo, payload,
                                     criada_por, executar_apos, status, erro)
  values (p_grupo, p_ordem, p_momento, p_venda, c.id, c.chatwoot_conversation_id, p_tipo, coalesce(p_payload, '{}'::jsonb),
          auth.uid(), coalesce(p_quando, now()), p_status, p_erro)
  returning id into v_id;
  return v_id;
end;
$$;

-- Mensagem ao cliente com o freio do contrato. Devolve {status, quando, motivo, template, texto}.
-- status: 'pendente' (sai em `quando`) · 'bloqueada' (mandar à mão: aparece na Fila).
create or replace function public._bo_mensagem(p_grupo uuid, p_ordem int, p_momento text, p_venda uuid, c public.mari_conversas,
                                               p_chave text, p_vars jsonb, p_template text default null, p_tpl_params jsonb default null,
                                               p_rotulo text default null)
returns jsonb language plpgsql set search_path = public as $$
declare
  v_txt    text;
  v_quando timestamptz;
  v_tq     record;
  v_fila_d int; v_fila_m int;
  v_janela boolean;
  v_motivo text;
  v_tpl    public.config_templates_waba;
  v_pay    jsonb;
  k        text;
begin
  select texto into v_txt from public.config_mari_textos where chave = p_chave;
  if v_txt is null then raise exception 'Texto % não está em config_mari_textos.', p_chave; end if;
  for k in select jsonb_object_keys(coalesce(p_vars, '{}'::jsonb)) loop
    v_txt := replace(v_txt, '{' || k || '}', coalesce(p_vars ->> k, ''));
  end loop;

  v_quando := public.mari_proximo_horario(now(), c.cidade);
  if c.nao_contatar then
    v_motivo := 'cliente pediu para não ser contatado';
  elsif v_quando is null then
    v_motivo := 'sem horário de contato nos próximos dias';
  else
    -- 2/dia e 15/mês: o que já saiu (contatos_cliente, mesma contagem da cadência) + o que já está na fila para o mesmo telefone.
    select * into v_tq from public.mari_toques(c.telefone, v_quando);
    select count(*) filter (where (a.executar_apos at time zone 'America/Sao_Paulo')::date = (v_quando at time zone 'America/Sao_Paulo')::date),
           count(*) filter (where date_trunc('month', a.executar_apos at time zone 'America/Sao_Paulo') = date_trunc('month', v_quando at time zone 'America/Sao_Paulo'))
      into v_fila_d, v_fila_m
      from public.chatwoot_acoes a join public.mari_conversas c2 on c2.id = a.conversa_id
     where a.tipo = 'mensagem' and a.status in ('pendente', 'executando') and public.tel_norm(c2.telefone) = public.tel_norm(c.telefone);
    if coalesce(v_tq.hoje, 0) + v_fila_d >= 2 then v_motivo := 'teto do contrato: já são 2 contatos neste dia';
    elsif coalesce(v_tq.mes, 0) + v_fila_m >= 15 then v_motivo := 'teto do contrato: já são 15 contatos neste mês';
    end if;
  end if;

  -- Janela de 24 h (a cadência usa 23 h de folga): aberta se a mensagem SAIR antes de fechar.
  v_janela := c.ultima_msg_lead_at is not null and coalesce(v_quando, now()) < c.ultima_msg_lead_at + interval '23 hours';
  v_pay := jsonb_build_object('content', v_txt, 'message_type', 'outgoing', 'private', false, 'texto_chave', p_chave,
                              'rotulo', coalesce(p_rotulo, p_chave));
  if v_motivo is null and not v_janela then
    if p_template is not null then
      select * into v_tpl from public.config_templates_waba where nome = p_template and status = 'APPROVED';
    end if;
    if v_tpl.nome is null then
      v_motivo := 'janela de 24 h fechada e sem template aprovado para esta mensagem';
    else
      v_txt := public.mari_render_template(v_tpl.nome, p_tpl_params);
      v_pay := v_pay || jsonb_build_object('content', v_txt, 'content_type', 'text', 'template', v_tpl.nome,
        'template_params', jsonb_build_object('name', v_tpl.nome, 'category', v_tpl.categoria, 'language', v_tpl.idioma,
          'processed_params', jsonb_build_object('body',
            coalesce((select jsonb_object_agg((o)::text, e) from jsonb_array_elements_text(coalesce(p_tpl_params, '[]'::jsonb))
                       with ordinality as t(e, o)), '{}'::jsonb))));
    end if;
  end if;

  if v_motivo is not null then
    perform public._bo_enfileirar(p_grupo, p_ordem, p_momento, p_venda, c, 'mensagem', v_pay || jsonb_build_object('motivo', v_motivo),
                                  now(), 'bloqueada', v_motivo);
    return jsonb_build_object('status', 'bloqueada', 'motivo', v_motivo, 'texto', v_txt);
  end if;
  perform public._bo_enfileirar(p_grupo, p_ordem, p_momento, p_venda, c, 'mensagem', v_pay, v_quando);
  return jsonb_build_object('status', 'pendente', 'quando', v_quando, 'template', v_pay ->> 'template', 'texto', v_txt);
end;
$$;

-- ───────────────────────── 5. o botão de cada momento ─────────────────────────
create or replace function public.backoffice_momento(p_venda uuid, p_momento text, p_dados jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
  semana   text[] := array['segunda-feira','terça-feira','quarta-feira','quinta-feira','sexta-feira','sábado','domingo'];
  r        jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice usa os botões da venda.' using errcode = '42501';
  end if;
  if p_momento not in ('assumir', 'viabilidade', 'pedido', 'biometria', 'agendar', 'parar', 'devolver_mari') then
    raise exception 'Momento desconhecido: %', p_momento;
  end if;
  select nome, chatwoot_agente_id into quem, agente from public.usuarios where id = auth.uid();
  quem := coalesce(quem, 'time');

  -- Venda (opcional: assumir/parar/devolver também valem para conversa sem venda) e conversa do Chatwoot.
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
  if p_momento in ('viabilidade', 'pedido', 'biometria', 'agendar') and v.id is null then
    raise exception 'Este botão precisa de uma venda.';
  end if;
  tem_cw := c.id is not null and c.canal = 'whatsapp' and coalesce(c.chatwoot_conversation_id, '') <> ''
            and c.telefone not like '5500000000%';

  -- ── assumir ──
  if p_momento = 'assumir' then
    if c.id is null then raise exception 'Esta venda não tem conversa no Chatwoot para assumir.'; end if;
    perform public.mari_cadencia_parar(c.id, p_humano => true);
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[assumida no NIOGEN por ' || quem || ' — cadência parada]', false);
    if v.id is not null and v.vendedor_id is null then
      update public.vendas set vendedor_id = auth.uid() where id = v.id;   -- D2: o dono fica registrado na venda
    end if;
    if tem_cw then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'atribuir',
        case when agente is not null then jsonb_build_object('assignee_id', agente) else jsonb_build_object('team_id', v_time) end);
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', '👤 Assumida no NIOGEN por ' || quem || ' às ' || agora_t || '.'));
      feito := feito || array[case when agente is not null then 'conversa atribuída a você' else 'conversa no time backoffice' end, 'nota']::text[];
    end if;
    feito := feito || 'cadência parada'::text;

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

  -- ── pedido aberto no portal ──
  elsif p_momento = 'pedido' then
    v_ped := btrim(coalesce(d ->> 'pedido', ''));
    if v_ped !~ '^[A-Za-z0-9._/-]{4,40}$' then
      raise exception 'Número do pedido inválido: use só letras, números, ponto, barra ou hífen (4 a 40 caracteres).' using errcode = '22023';
    end if;
    if v.status = 'saida' then raise exception 'A venda está em Saída; reabra pela ficha antes de registrar o pedido.'; end if;
    if d ? 'link' and coalesce(d ->> 'link', '') <> '' and (d ->> 'link') !~* '^https?://' then
      raise exception 'O link da biometria tem que começar com https://';
    end if;
    if v.nio_pedido is not distinct from v_ped then
      -- Mesmo nº de novo (2º clique, extensão depois da ficha): não manda nada ao cliente outra vez.
      update public.vendas set credito_resultado = coalesce(nullif(d ->> 'credito', ''), credito_resultado),
             biometria_link = coalesce(nullif(btrim(coalesce(d ->> 'link', '')), ''), biometria_link) where id = v.id;
      return jsonb_build_object('ok', true, 'momento', p_momento, 'acoes', 0, 'feito', jsonb_build_array('pedido já estava gravado'),
                                'resumo', '✓ pedido nº ' || v_ped || ' já estava gravado — nada foi reenviado ao cliente', 'venda_id', v.id);
    end if;
    -- Os mesmos campos do formulário "Pedido no portal" (o trigger 0032 carimba biometria pendente e a contagem).
    update public.vendas set
      nio_pedido = v_ped,
      credito_resultado = coalesce(nullif(d ->> 'credito', ''), credito_resultado),
      biometria_link = coalesce(nullif(btrim(coalesce(d ->> 'link', '')), ''), biometria_link)
    where id = v.id;
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (v.id, 'pedido_aberto_portal', jsonb_build_object('origem', coalesce(nullif(d ->> 'origem', ''), 'ficha'), 'pedido', v_ped), auth.uid());
    feito := feito || 'pedido gravado'::text;
    if tem_cw then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas', jsonb_build_object('add', jsonb_build_array('biometria-pendente')));
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', '🧾 Pedido nº ' || v_ped || ' aberto às ' || agora_t || ' — ' || quem || '. A Nio manda o link da biometria ao cliente.'));
      o := o + 1;
      msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_pedido_biometria', '{}'::jsonb,
                                 'nio_lembrete_biometria_v2', jsonb_build_array(public.mari_cadencia_nome(c)), 'aviso do pedido (biometria)');
      feito := feito || 'etiqueta'::text || 'nota'::text;
    end if;

  -- ── biometria (Validada · Risco · Negado) ──
  elsif p_momento = 'biometria' then
    v_res := d ->> 'resultado';
    if v_res = 'validada' then
      update public.vendas set biometria_status = 'validada' where id = v.id;
      feito := feito || 'biometria validada'::text;
      -- Validada + pedido + viabilidade → Vendido (as travas são do trigger; se recusar, a biometria fica gravada e o aviso volta).
      if v.status = '0_qualificado' then
        begin
          update public.vendas set status = '1_vendido' where id = v.id;
          feito := feito || 'venda → Vendido'::text;
        exception when others then
          aviso := 'Biometria gravada, mas a venda não passou para Vendido: ' || sqlerrm;
        end;
      end if;
      if tem_cw then
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
          jsonb_build_object('content', '✅ Biometria validada — ' || quem || ', ' || agora_t || '. Próximo: agendar a instalação (contrato: até 4 h).'));
        feito := feito || 'nota'::text;
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
      -- Pendência "Crédito negado · aguardando outro CPF" (quem destrava: o cliente), revisar no próximo dia útil.
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
        msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_credito_negado', '{}'::jsonb, null, null, 'pedido de outro CPF');
        feito := feito || 'nota'::text;
      end if;
    else
      raise exception 'Biometria: use validada, risco ou negado.';
    end if;

  -- ── agendar (ou reagendar) a instalação ──
  elsif p_momento = 'agendar' then
    v_dia := nullif(d ->> 'dia', '')::date;
    v_per := coalesce(nullif(d ->> 'periodo', ''), '08:00');
    if v_dia is null then raise exception 'Informe a data da instalação.'; end if;
    if v_per not in ('08:00', '13:00') then raise exception 'Período inválido.'; end if;
    v_ts := (v_dia::text || ' ' || v_per || ':00')::timestamp at time zone 'America/Sao_Paulo';
    v_turno := case when v_per = '13:00' then 'tarde' else 'manha' end;
    -- Os mesmos campos do formulário "Agendar instalação" (limpa a pendência da Nio; Vendido → Aguardando).
    update public.vendas set
      instalacao_agendada_para = v_ts, instalacao_turno = v_turno, nio_pendencia_cod = null, nio_pendencia_desc = null,
      status = case when status = '1_vendido' then '2_aguardando_instalacao' else status end
    where id = v.id
    returning * into v;
    feito := feito || ('instalação ' || to_char(v_dia, 'DD/MM') || ' ' || case v_turno when 'tarde' then 'tarde' else 'manhã' end)::text;
    if v.status = '0_qualificado' then
      aviso := 'A data ficou gravada, mas a venda ainda está em Qualificado (falta biometria validada + pedido + viabilidade para Vendido).';
    end if;
    if tem_cw then
      v_diatxt := semana[extract(isodow from v_dia)::int] || ', ' || to_char(v_dia, 'DD/MM');
      v_pertxt := case v_turno when 'tarde' then 'tarde, 13h às 17h' else 'manhã, 8h às 12h' end;
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas',
        jsonb_build_object('add', jsonb_build_array('instalacao-agendada'), 'remove', jsonb_build_array('biometria-pendente')));
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', '📅 Instalação agendada: ' || v_diatxt || ', ' || v_pertxt || ' — ' || quem || ', ' || agora_t || '.'));
      o := o + 1;
      msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_instalacao_confirmada',
               jsonb_build_object('dia', v_diatxt, 'periodo', v_pertxt),
               'nio_instalacao_agendada',
               jsonb_build_array(public.mari_cadencia_nome(c), v_diatxt, v_pertxt,
                 concat_ws(', ', nullif(btrim(v.logradouro), ''), nullif(btrim(v.numero), ''), nullif(btrim(v.complemento), ''), nullif(btrim(v.bairro), ''))),
               'confirmação da instalação');
      feito := feito || 'etiqueta'::text || 'nota'::text;
      -- O aviso C2 da cadência (INSTALACAO) já é esta mensagem: marca como dado para não sair em dobro.
      if msg ->> 'status' = 'pendente' then
        update public.mari_conversas set instalacao_avisada_para = v_ts, instalacao_avisada_em = (msg ->> 'quando')::timestamptz
         where id = c.id;
        -- D3: depois da confirmação, tira a atribuição e resolve (na mesma hora da mensagem).
        quando := (msg ->> 'quando')::timestamptz;
        o := o + 1; perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'desatribuir', jsonb_build_object('assignee_id', null), quando);
        o := o + 1; perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'desatribuir', jsonb_build_object('team_id', null), quando);
        o := o + 1; perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'resolver', jsonb_build_object('status', 'resolved'), quando);
        feito := feito || 'conversa resolvida'::text;
      end if;
    end if;

  -- ── cliente pediu para parar ──
  elsif p_momento = 'parar' then
    if c.id is null then raise exception 'Esta venda não tem conversa da Mari.'; end if;
    perform public.mari_cadencia_parar(c.id, p_resolvida => true, p_nao_contatar => true);
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[cliente pediu para parar — marcado no NIOGEN por ' || quem || ']', false);
    feito := feito || 'não contatar'::text;
    if tem_cw then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas', jsonb_build_object('add', jsonb_build_array('nao-contatar')));
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', '🚫 Cliente pediu para parar — ' || quem || ', ' || agora_t || '. Nunca mais chamar.'));
      o := o + 1; perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'resolver', jsonb_build_object('status', 'resolved'));
      feito := feito || 'etiqueta'::text || 'nota'::text || 'conversa resolvida'::text;
    end if;

  -- ── devolver para a Mari ──
  elsif p_momento = 'devolver_mari' then
    if c.id is null then raise exception 'Esta venda não tem conversa da Mari.'; end if;
    update public.mari_conversas set humano_atribuido = false, time_atribuido = false where id = c.id;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[devolvida para a Mari no NIOGEN por ' || quem || ']', false);
    if tem_cw then
      o := o + 1; perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'desatribuir', jsonb_build_object('assignee_id', null));
      o := o + 1; perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'desatribuir', jsonb_build_object('team_id', null));
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', '↩ Devolvida para a Mari por ' || quem || ' às ' || agora_t || ' — a Mari continua.'));
      feito := feito || 'atribuição removida'::text || 'nota'::text;
    end if;
  end if;

  -- Mensagem: o que aconteceu com ela entra no resumo.
  if msg is not null then
    if msg ->> 'status' = 'pendente' then
      quando := (msg ->> 'quando')::timestamptz;
      feito := feito || ('mensagem ao cliente' || case when quando > now() + interval '2 minutes'
                then ' — sai ' || case when (quando at time zone 'America/Sao_Paulo')::date = (now() at time zone 'America/Sao_Paulo')::date
                                       then 'às ' else to_char(quando at time zone 'America/Sao_Paulo', 'DD/MM') || ' às ' end
                     || to_char(quando at time zone 'America/Sao_Paulo', 'HH24:MI') else '' end
                || case when msg ->> 'template' is not null then ' (template ' || (msg ->> 'template') || ')' else '' end)::text;
    else
      aviso := concat_ws(' ', aviso, 'A mensagem ao cliente NÃO saiu (' || (msg ->> 'motivo') || '): mande à mão pelo Chatwoot — está na Fila.');
    end if;
  end if;
  if c.id is not null and not tem_cw and c.telefone like '5500000000%' then
    aviso := concat_ws(' ', aviso, 'Telefone de teste: nada foi ao Chatwoot.');
  elsif c.id is null and p_momento in ('pedido', 'agendar', 'biometria') then
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
$$;
revoke all on function public.backoffice_momento(uuid, text, jsonb) from public, anon;
grant execute on function public.backoffice_momento(uuid, text, jsonb) to authenticated;
revoke all on function public._bo_mensagem(uuid, int, text, uuid, public.mari_conversas, text, jsonb, text, jsonb, text) from public, anon, authenticated;
revoke all on function public._bo_enfileirar(uuid, int, text, uuid, public.mari_conversas, text, jsonb, timestamptz, text, text) from public, anon, authenticated;

-- ───────────────────────── 7. executor (n8n, service_role) ─────────────────────────
-- Pega as ações vencidas, na ordem do grupo (uma ação só sai quando as anteriores do mesmo grupo terminaram), marca 'executando'
-- e devolve o pedido HTTP pronto. Mensagem é conferida de novo (não contatar / conversa resolvida por outro caminho).
create or replace function public.backoffice_acoes_proximas(p_limite int default 20)
returns setof jsonb
language plpgsql
set search_path = public
as $$
declare
  a      public.chatwoot_acoes;
  c      public.mari_conversas;
  conta  text := public._bo_cfg('chatwoot_conta', '195428') #>> '{}';
  usr    jsonb := public._bo_cfg('backoffice_cred_usuario', '[]'::jsonb);
  base   text;
  n      int := 0;
begin
  if not coalesce((public._bo_cfg('backoffice_chatwoot_ligado', 'true') #>> '{}')::boolean, true) then return; end if;
  -- 'executando' preso há mais de 10 min (execução caiu no meio) volta para a fila.
  update public.chatwoot_acoes set status = case when tentativas < 3 then 'pendente' else 'erro' end,
         erro = coalesce(erro, 'execução interrompida')
   where status = 'executando' and pega_em < now() - interval '10 minutes';
  for a in
    select x.* from public.chatwoot_acoes x
     where x.status = 'pendente' and x.executar_apos <= now()
       and not exists (select 1 from public.chatwoot_acoes y
                        where y.grupo = x.grupo and y.ordem < x.ordem and y.status in ('pendente', 'executando'))
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
      'usuario', usr ? a.tipo,
      'url_base', base,
      'url', base || case a.tipo when 'atribuir' then '/assignments' when 'desatribuir' then '/assignments'
                                 when 'etiquetas' then '/labels' when 'resolver' then '/toggle_status' else '/messages' end,
      'corpo', case a.tipo
                 when 'nota' then jsonb_build_object('content', a.payload ->> 'content', 'message_type', 'outgoing', 'private', true)
                 when 'mensagem' then (a.payload - 'texto_chave' - 'rotulo' - 'template' - 'motivo')
                 when 'etiquetas' then '{}'::jsonb
                 else a.payload end,
      'add', coalesce(a.payload -> 'add', '[]'::jsonb), 'remove', coalesce(a.payload -> 'remove', '[]'::jsonb));
  end loop;
  return;
end;
$$;

create or replace function public.backoffice_acao_resultado(p_id bigint, p_ok boolean, p_erro text default null)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  a public.chatwoot_acoes;
  c public.mari_conversas;
begin
  select * into a from public.chatwoot_acoes where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'erro', 'ação inexistente'); end if;
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
    -- Conta no teto do contrato (2/dia · 15/mês) e aparece no histórico da conversa como fala da Mari (o bot assina).
    insert into public.contatos_cliente (venda_id, conversa_id, telefone, canal, direcao, por, em, toque, tipo, resumo)
    values (a.venda_id, a.conversa_id, c.telefone, 'whatsapp', 'saida', 'backoffice', now(), 'BO_' || upper(a.momento), 'ativo',
            'NIOGEN · ' || coalesce(a.payload ->> 'rotulo', a.momento) || coalesce(' · template ' || (a.payload ->> 'template'), ''));
    insert into public.mari_turnos (conversa_id, papel, texto, tags, created_at)
    values (a.conversa_id, 'mari', coalesce(a.payload ->> 'content', ''), jsonb_build_object('backoffice', a.momento, 'acao_id', a.id), now());
  end if;
  return jsonb_build_object('ok', true, 'registrado', 'feita');
end;
$$;
revoke all on function public.backoffice_acoes_proximas(int) from public, anon, authenticated;
revoke all on function public.backoffice_acao_resultado(bigint, boolean, text) from public, anon, authenticated;
grant execute on function public.backoffice_acoes_proximas(int) to service_role;
grant execute on function public.backoffice_acao_resultado(bigint, boolean, text) to service_role;

-- Fila: "já mandei à mão" (mensagem bloqueada) — conta no teto e sai da Fila. "Descartar" = não vai mandar.
create or replace function public.backoffice_acao_manual(p_id bigint, p_enviei boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.chatwoot_acoes;
  c public.mari_conversas;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into a from public.chatwoot_acoes where id = p_id and status = 'bloqueada' for update;
  if not found then raise exception 'Esta linha já saiu da Fila.'; end if;
  update public.chatwoot_acoes set status = case when p_enviei then 'manual' else 'cancelada' end, feita_em = now() where id = p_id;
  if p_enviei then
    select * into c from public.mari_conversas where id = a.conversa_id;
    insert into public.contatos_cliente (venda_id, conversa_id, telefone, canal, direcao, por, em, toque, tipo, resumo)
    values (a.venda_id, a.conversa_id, c.telefone, 'whatsapp', 'saida', 'backoffice', now(), 'BO_' || upper(a.momento), 'ativo',
            'enviado à mão pelo Chatwoot · ' || coalesce(a.payload ->> 'rotulo', a.momento));
  end if;
  if a.venda_id is not null then
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (a.venda_id, 'backoffice', jsonb_build_object('momento', a.momento,
            'resumo', case when p_enviei then '✓ mensagem enviada à mão' else 'mensagem descartada' end), auth.uid());
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.backoffice_acao_manual(bigint, boolean) from public, anon;
grant execute on function public.backoffice_acao_manual(bigint, boolean) to authenticated;

-- ───────────────────────── 8. Fila ("Minha vez") ─────────────────────────
create or replace view public.v_fila_backoffice with (security_invoker = true) as
with conv as (
  select id from public.v_mari_aguardando_humano
  union
  select id from public.v_mari_sem_resposta
)
select 'conversa'::text                                   as tipo,
       c.id::text                                         as chave,
       c.id                                               as conversa_id,
       c.venda_id,
       c.chatwoot_conversation_id,
       coalesce(nullif(initcap(split_part(btrim(coalesce(c.dados ->> 'nome', '')), ' ', 1)), ''),
                nullif(split_part(btrim(coalesce(c.nome_contato, '')), ' ', 1), ''), 'Contato') as nome,
       c.cidade,
       c.handoff_motivo                                   as motivo,
       coalesce(c.ultima_msg_lead_at, c.handoff_em, c.updated_at) as desde,
       exists (select 1 from public.v_mari_sem_resposta s where s.id = c.id) as sem_resposta,
       (c.chatwoot_agente is not null or coalesce(c.humano_atribuido, false)) as assumida,
       c.chatwoot_agente,
       null::bigint                                       as acao_id,
       null::text                                         as texto,
       null::text                                         as erro,
       'dharma'::text                                     as parceiro_id
  from conv join public.mari_conversas c on c.id = conv.id
union all
select 'manual', 'acao:' || a.id, a.conversa_id, a.venda_id, a.chatwoot_conversation_id,
       coalesce(nullif(split_part(btrim(coalesce(v.cliente_nome, '')), ' ', 1), ''),
                nullif(initcap(split_part(btrim(coalesce(c.dados ->> 'nome', '')), ' ', 1)), ''), 'Contato'),
       coalesce(v.cidade, c.cidade), a.payload ->> 'rotulo', a.criada_em, false, true, null,
       a.id, a.payload ->> 'content', a.erro, a.parceiro_id
  from public.chatwoot_acoes a
  left join public.vendas v on v.id = a.venda_id
  left join public.mari_conversas c on c.id = a.conversa_id
 where a.status = 'bloqueada' and a.criada_em > now() - interval '7 days';
grant select on public.v_fila_backoffice to authenticated;

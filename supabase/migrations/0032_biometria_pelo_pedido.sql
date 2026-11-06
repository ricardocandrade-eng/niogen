-- NIOGEN | supabase/migrations/0032_biometria_pelo_pedido.sql | 05/11/2026 — Claude Code (prompt 19)
-- Fato novo (Ricardo, 05/11 18h53): o link da biometria é enviado PELA NIO, por e-mail e WhatsApp, na hora em que o
-- pedido é concluído no portal PAP. A Dharma não manda link nenhum; o backoffice só avisa e orienta o cliente.
--   1. vendas.nio_pedido_em: hora em que o backoffice registrou o nº do pedido no NIOGEN.
--   2. vendas_antes_biometria: registrar o pedido = a Nio mandou o link → biometria pendente e a contagem 24/72 h e o
--      D+1 a partir da hora do pedido (biometria_link_enviado_em = nio_pedido_em). O trigger passa a olhar nio_pedido.
--   3. mari_registrar_turno: a captura do link ged360 colado no Chatwoot (0027) vira só fallback — com pedido
--      registrado, não muda nada que o pedido definiu (só guarda o link como referência, se a venda não tiver).
--   4. mari_handoff: próximo passo da nota = abrir pedido e registrar o nº → a Nio dispara o link → avisar o cliente.
--   5. C1 v2 nio_lembrete_biometria_v2 (UTILITY, sem botão de link) no BIO1; o C1 com botão fica DISABLED ("não usar").
-- Não apaga histórico. A cadência continua DESLIGADA. Número 0029 reservado ao prompt 17 (ainda não escrito).
-- v_funil não muda: a ficha mostra a hora do pedido por biometria_link_enviado_em (= nio_pedido_em).

-- ─────────────────────────────── 1. vendas ───────────────────────────────
alter table public.vendas add column if not exists nio_pedido_em timestamptz;
comment on column public.vendas.nio_pedido_em is
  'Hora em que o nº do pedido do portal PAP foi registrado no NIOGEN. A Nio dispara o link da biometria (e-mail + WhatsApp) nessa hora: a contagem 24/72 h e o D+1 partem daqui.';
comment on column public.vendas.biometria_link_enviado_em is
  'Hora em que a Nio mandou o link da biometria = hora do pedido (0032). Fallback: link ged360 colado no Chatwoot sem pedido registrado (0027).';
comment on column public.vendas.biometria_link is
  'Link da biometria, só referência (quem manda é a Nio, por e-mail e WhatsApp). Nunca reaproveitar.';

-- ─────────────────────── 2. trigger: pedido registrado = link da Nio ───────────────────────
create or replace function public.vendas_antes_biometria()
returns trigger language plpgsql set search_path = public as $$
begin
  -- 0032 (prompt 19): o link da biometria é disparado PELA NIO (e-mail + WhatsApp) na hora em que o pedido é concluído
  -- no portal. Registrar o nº do pedido no NIOGEN = a Nio mandou o link: carimba nio_pedido_em e, em Qualificado com
  -- biometria ainda não iniciada, a biometria fica pendente e as 24 h / 72 h e o D+1 contam dali
  -- (biometria_link_enviado_em = hora do pedido). Pedido trocado (novo pedido = novo link da Nio) recomeça a contagem.
  if coalesce(btrim(new.nio_pedido), '') <> ''
     and (tg_op = 'INSERT' or new.nio_pedido is distinct from old.nio_pedido) then
    if tg_op = 'INSERT' then
      new.nio_pedido_em := coalesce(new.nio_pedido_em, now());
    elsif new.nio_pedido_em is not distinct from old.nio_pedido_em then
      new.nio_pedido_em := now();
    end if;
    if new.status = '0_qualificado' and coalesce(new.biometria_status, 'nao_enviada') in ('nao_enviada', 'pendente', 'com_risco') then
      if coalesce(new.biometria_status, 'nao_enviada') = 'nao_enviada' then
        new.biometria_status := 'pendente';
      end if;
      new.biometria_link_enviado_em := new.nio_pedido_em;
    end if;
  end if;

  new.biometria_status := case new.biometria_status
    when 'agendada' then 'pendente' when 'aprovada' then 'validada' when 'reprovada' then 'com_risco'
    else new.biometria_status end;

  if tg_op = 'INSERT' or new.biometria_status is distinct from old.biometria_status then
    if new.biometria_status is not null then
      new.biometria_em := now();
    end if;
    if new.biometria_status = 'validada' then
      new.biometria_validada_em := coalesce(new.biometria_validada_em, now());
    end if;
    if new.biometria_status in ('pendente', 'com_risco', 'validada') then
      new.biometria_link_enviado_em := coalesce(new.biometria_link_enviado_em, now());
    end if;
  end if;

  if new.credito_resultado is not null
     and (tg_op = 'INSERT' or new.credito_resultado is distinct from old.credito_resultado) then
    new.credito_em := now();
  end if;

  if new.nio_viab_resultado is not null
     and (tg_op = 'INSERT' or new.nio_viab_resultado is distinct from old.nio_viab_resultado) then
    new.nio_viab_em := coalesce(new.nio_viab_em, now());
  end if;
  return new;
end;
$$;

drop trigger if exists vendas_antes_biometria on public.vendas;
create trigger vendas_antes_biometria
  before insert or update of biometria_status, credito_resultado, nio_viab_resultado, nio_pedido on public.vendas
  for each row execute function public.vendas_antes_biometria();
revoke execute on function public.vendas_antes_biometria() from public, anon, authenticated;

-- ─────────────────────── 3. link colado no Chatwoot = só fallback ───────────────────────
create or replace function public.mari_registrar_turno(
  p_telefone text, p_nome text, p_texto text, p_papel text, p_canal text default 'whatsapp',
  p_chatwoot_conversation_id text default null)
returns jsonb language plpgsql set search_path = public as $$
declare
  v_tel  text := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  v_txt  text := btrim(coalesce(p_texto, ''));
  v_conv public.mari_conversas;
  v_link text;
  v_venda record;
  v_capt text;
begin
  if p_papel not in ('lead', 'humano') then
    raise exception 'papel inválido: % (use lead | humano)', p_papel using errcode = '22023';
  end if;
  if v_tel !~ '^\d{10,15}$' then
    raise exception 'telefone inválido' using errcode = '22023';
  end if;
  if v_txt = '' then
    return jsonb_build_object('ignorado', true, 'motivo', 'texto vazio');
  end if;

  select * into v_conv from public.mari_conversas
   where telefone = v_tel and canal = p_canal and status in ('ativo', 'handoff_realizado')
   for update;

  if not found then
    insert into public.mari_conversas (telefone, nome_contato, canal, origem, chatwoot_conversation_id)
    values (v_tel, nullif(btrim(p_nome), ''), p_canal,
            case when p_canal = 'teste' then 'teste' else 'direto' end, p_chatwoot_conversation_id)
    returning * into v_conv;
  end if;

  if p_papel = 'humano' then
    if exists (select 1 from public.mari_turnos
                where conversa_id = v_conv.id and papel = 'mari'
                  and (btrim(texto) = v_txt or position(v_txt in texto) > 0)
                  and created_at > now() - interval '10 minutes') then
      return jsonb_build_object('ignorado', true, 'motivo', 'eco da Mari', 'conversa_id', v_conv.id);
    end if;
    if exists (select 1 from public.mari_turnos
                where conversa_id = v_conv.id and papel = 'humano'
                  and btrim(texto) = v_txt and created_at > now() - interval '1 minute') then
      return jsonb_build_object('ignorado', true, 'motivo', 'repetido', 'conversa_id', v_conv.id);
    end if;
  end if;

  insert into public.mari_turnos (conversa_id, papel, texto, pendente, tags)
  values (v_conv.id, p_papel, v_txt, false, jsonb_build_object('sem_resposta', true));

  if p_papel = 'lead' then
    update public.mari_conversas
       set ultima_msg_lead_at = now(),
           nome_contato = coalesce(nome_contato, nullif(btrim(p_nome), ''))
     where id = v_conv.id;
  end if;

  -- 0027: link da biometria mandado pelo atendente → venda da conversa.
  if p_papel = 'humano' then
    v_link := substring(v_txt from '(https://ged360\.niointernet\.com\.br/brprontopdv/pdv-mobile/biometria/login/[A-Za-z0-9_-]+)');
    if v_link is not null then
      select v.id, v.status, v.biometria_status, v.biometria_link, v.nio_pedido into v_venda
        from public.vendas v where v.id = v_conv.venda_id for update;
      if not found then
        v_capt := 'conversa sem venda no NIOGEN';
      elsif v_venda.status <> '0_qualificado' or v_venda.biometria_status = 'validada' then
        v_capt := 'venda já passou da biometria';
      elsif v_venda.biometria_link is not distinct from v_link and v_venda.biometria_status in ('pendente', 'com_risco') then
        v_capt := 'mesmo link já registrado';
      elsif coalesce(btrim(v_venda.nio_pedido), '') <> '' then
        -- 0032: o pedido já definiu a biometria (pendente) e a contagem (hora do pedido). O link colado só fica
        -- guardado como referência, se a venda ainda não tiver um; nada mais muda.
        if v_venda.biometria_link is null then
          update public.vendas set biometria_link = v_link where id = v_venda.id;
          insert into public.eventos_venda (venda_id, tipo, detalhe)
          values (v_venda.id, 'biometria_link', jsonb_build_object(
            'origem', 'chatwoot', 'conversa_id', v_conv.id, 'so_referencia', true));
          v_capt := 'link guardado (o pedido já define a contagem)';
        else
          v_capt := 'pedido já registrado (link não muda a contagem)';
        end if;
      else
        -- 0032: fallback — sem nº do pedido no NIOGEN, o link colado ainda marca a biometria pendente e a contagem.
        update public.vendas
           set biometria_link = v_link,
               biometria_status = case when biometria_status = 'com_risco' then 'com_risco' else 'pendente' end,
               biometria_link_enviado_em = now()
         where id = v_venda.id;
        insert into public.eventos_venda (venda_id, tipo, detalhe)
        values (v_venda.id, 'biometria_link', jsonb_build_object(
          'origem', 'chatwoot', 'conversa_id', v_conv.id, 'reenvio', v_venda.biometria_link is not null));
        v_capt := case when v_venda.biometria_link is null then 'link registrado' else 'link trocado (reenvio)' end;
      end if;
    end if;
  end if;

  return jsonb_strip_nulls(jsonb_build_object('ignorado', false, 'conversa_id', v_conv.id, 'papel', p_papel,
                                              'biometria_link', v_capt));
end;
$$;

-- ─────────────────────── 4. nota do handoff ───────────────────────
create or replace function public.mari_handoff(p_conversa uuid, p_motivo text, p_lead jsonb default '{}'::jsonb)
returns jsonb language plpgsql set search_path = public as $$
declare
  c        public.mari_conversas;
  l        jsonb := coalesce(p_lead, '{}'::jsonb);
  d        jsonb;
  v_plano  public.config_planos;
  v_venda  uuid;
  v_motivo text;
  v_seg    text;
  v_forma  text;
  v_orig   text;
  v_cpf    text;
  v_tel    text;
  v_cluster text;
  v_dfv    jsonb;
  v_brief  text;
  v_obs    text;
  v_inst   text;
  v_viab   text;
  v_vnota  text;
  v_prox   text;
  v_endp   text;
  v_exist  uuid;   -- 0030: venda que já existe (duplicidade) — o link vai na nota do Chatwoot
begin
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then return jsonb_build_object('ok', false, 'motivo_recusa', 'conversa inexistente'); end if;

  -- Guard-rail 10: não repetir handoff.
  if c.status <> 'ativo' then
    return jsonb_build_object('ok', true, 'repetido', true, 'venda_id', c.venda_id);
  end if;

  d := c.dados || coalesce(l -> 'dados', '{}'::jsonb);
  v_inst := coalesce(nullif(btrim(c.instalacao_preferencia), ''), nullif(btrim(l ->> 'instalacao_preferencia'), ''));
  v_viab := coalesce(c.nio_viab_resultado, nullif(l ->> 'nio_viab_resultado', ''));
  if v_viab not in ('viavel', 'sem_viabilidade', 'nao_encontrado', 'posse', 'indisponivel') then v_viab := null; end if;
  v_endp := coalesce(nullif(btrim(c.nio_viab_endereco_portal), ''), nullif(btrim(l ->> 'nio_viab_endereco_portal'), ''));

  -- Nota da viabilidade oficial (nunca nega venda): viável = atendido; o resto = conferir à mão antes do pedido.
  v_vnota := case
    when v_viab = 'viavel' then 'portal: viável' || coalesce(' · até ' || coalesce(c.nio_viab_velocidade, l ->> 'nio_viab_velocidade'), '')
    when v_viab = 'posse' then 'portal: posse (endereço com Nio ativo) — cliente disse que não tem; conferir manualmente antes de abrir o pedido'
    when v_viab is not null then 'portal: ' || v_viab || ' — conferir manualmente (variações de CEP/rua/número) antes de abrir o pedido'
    else 'portal: não consultado — conferir manualmente (variações de CEP/rua/número) antes de abrir o pedido' end
    || coalesce(' · endereço como a Nio cadastrou: ' || v_endp, '');

  -- Próximo passo do humano (venda remota, 05/11; 0032: o link da biometria é da Nio): sempre o mesmo texto.
  v_prox := case when p_motivo = 'dados_completos' then
    'Próximo passo: abrir pedido no portal PAP'
    || case when coalesce(c.nio_viab_interesse_id, l ->> 'nio_viab_interesse_id') is not null
            then ' (interesse ' || coalesce(c.nio_viab_interesse_id, l ->> 'nio_viab_interesse_id') || ' já criado na viabilidade)' else '' end
    || ' e registrar o nº do pedido no NIOGEN → a Nio dispara o link da biometria (WhatsApp + e-mail) → avisar o cliente nesta conversa → agendar a instalação ('
    || coalesce(v_inst, 'preferência não informada') || ').' end;

  update public.mari_conversas set
    status = 'handoff_realizado', etapa = 'handoff', handoff_motivo = p_motivo, handoff_em = now(),
    handoff_briefing = concat_ws(E'\n', coalesce(nullif(btrim(l ->> 'briefing'), ''), handoff_briefing),
                                 case when p_motivo = 'dados_completos' or v_viab is not null then v_vnota end, v_prox),
    dados = d, processando_ate = null,
    instalacao_preferencia = coalesce(v_inst, instalacao_preferencia),
    nao_contatar = nao_contatar or p_motivo = 'recusa_compra',
    agendamento_retorno = coalesce((l ->> 'agendamento_retorno')::timestamptz, agendamento_retorno)
  where id = p_conversa
  returning * into c;

  if p_motivo <> 'dados_completos' then
    return jsonb_build_object('ok', true, 'venda_id', null);
  end if;

  -- Pré-condições da venda (ordem: elegibilidade, área, plano, dados mínimos, duplicidade). Viabilidade NÃO entra.
  v_cluster := public.cluster_da_area(c.cidade, c.uf, c.endereco_cep ->> 'bairro');
  v_cpf := regexp_replace(coalesce(d ->> 'cpf', ''), '\D', '', 'g');
  v_tel := regexp_replace(coalesce(d ->> 'telefone', c.telefone), '\D', '', 'g');
  select * into v_plano from public.config_planos where codigo = c.plano_escolhido;

  -- 0030: a mesma regra de duplicidade de sempre, agora guardando QUAL venda já existe (a mais recente).
  select v.id into v_exist from public.vendas v
   where v.status <> 'saida'
     and ((v_cpf <> '' and regexp_replace(coalesce(v.cliente_cpf_cnpj, ''), '\D', '', 'g') = v_cpf)
       or (regexp_replace(coalesce(v.cep, ''), '\D', '', 'g') = c.cep
           and lower(btrim(coalesce(v.numero, ''))) = lower(btrim(c.numero))
           and lower(btrim(coalesce(v.complemento, ''))) = lower(btrim(coalesce(c.complemento, '')))))
   order by v.criado_em desc
   limit 1;

  v_motivo := case
    when coalesce(c.elegibilidade, '') <> 'ok' then 'elegibilidade não confirmada (' || coalesce(c.elegibilidade, 'vazia') || ')'
    when v_cluster is null then 'fora da área de atuação (' || coalesce(c.cidade, 'cidade desconhecida') || ')'
    when v_plano.id is null then 'plano não escolhido'
    when coalesce(btrim(d ->> 'nome'), '') = '' then 'nome do cliente ausente'
    when c.cep is null or c.numero is null then 'endereço incompleto'
    when v_exist is not null
      then 'duplicidade: CPF ou endereço já tem venda ativa no NIOGEN'
  end;

  if v_motivo is null then
    v_seg := case when c.segmento = 'empresas' then case when c.mei then 'MEI' else 'NMEI' end else 'PF' end;
    v_forma := coalesce(c.forma_pagamento, l ->> 'forma_pagamento');
    v_forma := case v_forma when 'debito' then 'dacc' when 'debito_automatico' then 'dacc' else v_forma end;
    if v_forma not in ('boleto', 'cartao', 'dacc') then v_forma := null; end if;
    v_orig := case when c.origem in ('meta_ads', 'site', 'fila_vero', 'indicacao') then c.origem else 'outro' end;
    v_dfv := c.dfv_detalhe;

    v_brief := coalesce(l ->> 'briefing', '');
    v_obs := concat_ws(E'\n',
      'Mari (' || c.canal || ') — handoff dados_completos em ' || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
      'Plano: ' || v_plano.nome || ' · forma: ' || coalesce(v_forma, '?'),
      'Instalação: preferência ' || coalesce(v_inst, '?') || ' (data o nosso time confirma)',
      'Viabilidade Nio — ' || v_vnota,
      'DFV: ' || case coalesce(c.dfv_resultado, '')
                   when 'viavel' then 'viável'
                   when 'viavel_predio' then 'viável (prédio) — conferir unidade'
                   when 'endereco_ocupado' then 'indica Nio ativo no endereço — confirmar com o cliente e no portal antes de abrir o pedido'
                   else 'conferir manualmente antes de abrir o pedido' end,
      nullif(v_brief, ''),
      v_prox);

    begin
      insert into public.vendas (
        status, origem, origem_ref, cliente_nome, cliente_cpf_cnpj, cliente_whatsapp, cliente_email, segmento,
        cep, logradouro, numero, complemento, bairro, cidade, uf, plano_id, forma_pagamento,
        trava_area, trava_cpf_valido, trava_contato_confirmado, observacoes,
        dfv_viabilidade, dfv_resultado, dfv_hp_livre, dfv_hcs, dfv_faixa_credito, dfv_classificacao,
        dfv_particao, dfv_origem, dfv_consultado_em,
        instalacao_preferencia, biometria_status,
        nio_viab_resultado, nio_viab_velocidade, nio_viab_interesse_id, nio_viab_em, nio_viab_origem, nio_viab_endereco_portal)
      values (
        '0_qualificado', v_orig, 'mari:' || c.id, btrim(d ->> 'nome'), nullif(v_cpf, ''), v_tel, nullif(btrim(d ->> 'email'), ''), v_seg,
        c.cep, c.endereco_cep ->> 'logradouro', c.numero, c.complemento,
        coalesce(c.endereco_cep ->> 'bairro', v_dfv ->> 'bairro'), c.cidade, c.uf, v_plano.id, v_forma,
        true, case when v_cpf <> '' then public.mari_cpf_valido(v_cpf) end,
        case when coalesce((d ->> 'telefone_confirmado')::boolean, false) or v_tel <> '' then true end, v_obs,
        case c.dfv_resultado
          when 'viavel' then 'viavel' when 'viavel_predio' then 'viavel_predio'
          when 'endereco_ocupado' then 'sem_viabilidade' when 'sem_porta_livre' then 'sem_viabilidade'
          when 'nao_encontrado' then 'nao_encontrado'
          else 'nao_consultado' end,
        case when c.dfv_resultado in ('viavel', 'viavel_predio', 'endereco_ocupado', 'sem_porta_livre', 'nao_encontrado') then c.dfv_resultado end,
        (v_dfv ->> 'hp_livre')::int, (v_dfv ->> 'hc_tot')::int,
        public.dfv_faixa_codigo(v_dfv ->> 'faixa_credito'),
        case when v_dfv ->> 'classificacao' in ('ALTO', 'MEDIO', 'BAIXO') then v_dfv ->> 'classificacao' end,
        (v_dfv ->> 'particao')::date,
        case when c.dfv_resultado in ('viavel', 'viavel_predio', 'endereco_ocupado', 'sem_porta_livre', 'nao_encontrado') then 'auto' end,
        case when c.dfv_resultado in ('viavel', 'viavel_predio', 'endereco_ocupado', 'sem_porta_livre', 'nao_encontrado') then now() end,
        v_inst, 'nao_enviada',
        v_viab, coalesce(c.nio_viab_velocidade, l ->> 'nio_viab_velocidade'),
        coalesce(c.nio_viab_interesse_id, l ->> 'nio_viab_interesse_id'),
        case when v_viab is not null then coalesce(c.nio_viab_em, now()) end,
        case when v_viab is not null then 'mari' end,
        v_endp)
      returning id into v_venda;

      insert into public.eventos_venda (venda_id, tipo, detalhe)
      values (v_venda, 'mari_handoff', jsonb_strip_nulls(jsonb_build_object(
        'conversa_id', c.id, 'motivo', p_motivo, 'canal', c.canal, 'briefing', nullif(v_brief, ''),
        'instalacao_preferencia', v_inst, 'nio_viab_resultado', v_viab, 'dfv_resultado', c.dfv_resultado)));

      update public.mari_conversas set venda_id = v_venda where id = p_conversa;
    exception when others then
      v_motivo := sqlerrm;
    end;
  end if;

  if v_motivo is not null then
    insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
    values (p_conversa, 'mari_handoff', 'venda não criada: ' || v_motivo,
            jsonb_strip_nulls(jsonb_build_object('lead', l, 'dados', d, 'venda_existente_id', case when v_motivo like 'duplicidade%' then v_exist end)));
    return jsonb_build_object('ok', false, 'venda_id', null, 'motivo_recusa', v_motivo,
                              'venda_existente_id', case when v_motivo like 'duplicidade%' then v_exist end);
  end if;

  return jsonb_build_object('ok', true, 'venda_id', v_venda);
end;
$$;

-- ─────────────────────── 5. C1 v2 (sem botão de link) ───────────────────────
insert into public.config_templates_waba (nome, categoria, corpo, botoes, rodape, meta_id, status, uso) values
  ('nio_lembrete_biometria_v2', 'UTILITY',
   E'Oi, {{1}}! É a Mari, da Nio 👋\n\nSeu pedido de internet já foi aberto e só falta a biometria. A própria Nio te mandou o link por WhatsApp e por e-mail; se não achar o e-mail, confere também a caixa de spam.\n\nÉ rapidinho, você faz pelo celular. Se tiver qualquer dificuldade, me chama por aqui que o nosso time ajuda 😊',
   '["Preciso de ajuda"]', null, null, 'PENDING', 'BIO1')
on conflict (nome) do update set corpo = excluded.corpo, botoes = excluded.botoes, categoria = excluded.categoria,
  uso = excluded.uso, atualizado_em = now();

update public.config_templates_waba set
  status = 'DISABLED',
  uso = 'NÃO USAR — substituído pelo nio_lembrete_biometria_v2 em 05/11 (o link da biometria é da Nio; não há link nosso para o botão)',
  atualizado_em = now()
where nome = 'nio_lembrete_biometria';

create or replace function public.mari_cadencia_avaliar(p_agora timestamptz default now(), p_conversa uuid default null)
returns table(conversa_id uuid, telefone text, canal text, chatwoot_conversation_id text, status text, etapa text,
              passo_atual text, passo_em timestamptz, proximo_passo text, proximo_em timestamptz, pode_enviar boolean,
              bloqueio text, acao text, template text, categoria text, params jsonb, texto text, excecao text,
              janela_aberta boolean, janela_fecha_em timestamptz, toques_hoje integer, toques_mes integer,
              ligar_sugerido boolean, venda_id uuid)
language plpgsql stable set search_path = public as $$
declare
  c        public.mari_conversas;
  v_tq     record;
  L        timestamptz;   -- última msg do lead
  M        timestamptz;   -- última msg da Mari
  B        timestamptz;   -- base dos D (lead, retorno ou 1º contato)
  f1_at    timestamptz; f2_at timestamptz; f2_ate timestamptz; a_ant timestamptz;
  d3_at    timestamptz; d7_at timestamptz; d15_at timestamptz; enc_at timestamptz;
  seq      text[]; ats timestamptz[]; validos timestamptz[];
  idx_atual int; i int; alvo int; prox int;
  v_passo  text; v_at timestamptz; v_bloq text; v_acao text; v_tpl text; v_cat text; v_params jsonb; v_txt text;
  v_exc    text; v_pode boolean; v_janela boolean; v_lig boolean;
  v_venda  record; vis_dia date; vis_ini timestamptz; v_proib text;
  v_turno  text; v_dia date;
  semana   text[] := array['segunda-feira','terça-feira','quarta-feira','quinta-feira','sexta-feira','sábado','domingo'];
begin
  for c in
    select * from public.mari_conversas mc
     where (p_conversa is null or mc.id = p_conversa)
       and mc.canal in ('teste', 'whatsapp')
       and (mc.status = 'ativo'
            or (mc.status = 'handoff_realizado' and mc.venda_id is not null))   -- biometria pendente / instalação agendada
     order by mc.updated_at desc
  loop
    v_passo := null; v_at := null; v_bloq := null; v_acao := null; v_tpl := null; v_cat := null;
    v_params := null; v_txt := null; v_exc := null; v_pode := false; v_lig := false;
    L := c.ultima_msg_lead_at; M := c.ultima_msg_mari_at;
    v_janela := L is not null and p_agora < L + interval '23 hours';
    select * into v_tq from public.mari_toques(c.telefone, p_agora);

    -- ── paradas absolutas ──
    if c.nao_contatar then v_bloq := 'cliente pediu para não ser contatado';
    elsif c.humano_atribuido then v_bloq := 'humano atribuído no Chatwoot';
    elsif c.time_atribuido then v_bloq := 'time atribuído no Chatwoot';
    elsif c.chatwoot_resolvida then v_bloq := 'conversa resolvida no Chatwoot';
    elsif c.canal = 'whatsapp' and c.telefone like '5500000000%' then v_bloq := 'telefone de teste';
    end if;

    if c.status = 'handoff_realizado' then
      -- ── venda remota (05/11): biometria pendente e instalação agendada ──
      if v_bloq is not null then continue; end if;
      select v.id, v.status, v.biometria_status, v.biometria_link, v.biometria_link_enviado_em,
             v.instalacao_agendada_para, v.instalacao_turno, v.logradouro, v.numero, v.complemento, v.bairro
        into v_venda
        from public.vendas v
       where v.id = c.venda_id and v.status <> 'saida';
      if not found then continue; end if;

      if v_venda.status = '0_qualificado' and v_venda.biometria_status = 'pendente' and v_venda.biometria_link_enviado_em is not null then
        if c.bio_lembrete_em is null or c.bio_lembrete_em < v_venda.biometria_link_enviado_em then
          -- BIO1: D+1 do link, uma vez só. 0032: o link é da Nio (WhatsApp + e-mail, na hora do pedido) — a contagem parte
          -- da hora do pedido e o lembrete é o C1 v2 (sem botão de link): lembra que a Nio mandou, conferir o spam, ajuda por aqui.
          v_passo := 'BIO1';
          v_at := public.mari_proximo_horario(v_venda.biometria_link_enviado_em + interval '1 day', c.cidade);
          v_tpl := 'nio_lembrete_biometria_v2';
          v_params := jsonb_build_array(public.mari_cadencia_nome(c));
          v_txt := public.mari_render_template(v_tpl, v_params);
          if v_janela then
            v_acao := 'texto'; v_tpl := null;   -- texto livre (janela de 24 h): o mesmo texto do C1 v2
          else
            v_acao := 'template'; v_cat := 'UTILITY';
          end if;
          if p_agora < v_at then v_bloq := 'aguardando o D+1 do link da biometria (hora do pedido)';
          end if;
        else
          -- BIO3: D+3 sem biometria → o humano liga. Nunca automático.
          v_passo := 'BIO3'; v_acao := 'ligar';
          v_at := v_venda.biometria_link_enviado_em + interval '3 days';
          v_lig := p_agora >= v_at;
          v_bloq := case when p_agora < v_at then 'aguardando o D+3 do link da biometria (hora do pedido)'
                         else 'D+3 sem biometria: o nosso time liga para o cliente (nunca automático)' end;
        end if;
      elsif v_venda.status = '2_aguardando_instalacao' and v_venda.instalacao_agendada_para > p_agora then
        v_dia := (v_venda.instalacao_agendada_para at time zone 'America/Sao_Paulo')::date;
        v_turno := coalesce(v_venda.instalacao_turno,
                            case when extract(hour from v_venda.instalacao_agendada_para at time zone 'America/Sao_Paulo') >= 12
                                 then 'tarde' else 'manha' end);
        if c.instalacao_avisada_para is distinct from v_venda.instalacao_agendada_para then
          -- C2: assim que agendar (ou reagendar).
          v_passo := 'INSTALACAO'; v_at := p_agora;
          v_params := jsonb_build_array(
            public.mari_cadencia_nome(c),
            semana[extract(isodow from v_dia)::int] || ', ' || to_char(v_dia, 'DD/MM'),
            case v_turno when 'tarde' then 'tarde, 13h às 17h' else 'manhã, 8h às 12h' end,
            concat_ws(', ', nullif(btrim(v_venda.logradouro), ''), nullif(btrim(v_venda.numero), ''),
                      nullif(btrim(v_venda.complemento), ''), nullif(btrim(v_venda.bairro), '')));
          v_tpl := 'nio_instalacao_agendada';
        elsif c.instalacao_lembrada_para is distinct from v_venda.instalacao_agendada_para then
          -- C3: véspera (dia permitido anterior).
          vis_dia := v_dia - 1;
          while not public.mari_dia_permitido(vis_dia, c.cidade) loop vis_dia := vis_dia - 1; end loop;
          vis_ini := public.mari_proximo_horario((vis_dia::timestamp) at time zone 'America/Sao_Paulo', c.cidade);
          v_passo := 'VESPERA'; v_at := vis_ini;
          v_params := jsonb_build_array(public.mari_cadencia_nome(c), to_char(v_dia, 'DD/MM'),
                                        case v_turno when 'tarde' then 'tarde' else 'manhã' end);
          v_tpl := 'nio_lembrete_instalacao';
          if p_agora < v_at then v_bloq := 'aguardando a véspera da instalação';
          elsif p_agora > v_venda.instalacao_agendada_para - interval '2 hours' then v_bloq := 'instalação próxima demais';
          elsif c.instalacao_avisada_em > p_agora - interval '12 hours' then v_bloq := 'o aviso do agendamento (C2) saiu há menos de 12 h';
          end if;
        else
          continue;
        end if;
        v_txt := public.mari_render_template(v_tpl, v_params);
        if v_janela then v_acao := 'texto'; v_tpl := null; else v_acao := 'template'; v_cat := 'UTILITY'; end if;
      else
        continue;   -- nada a fazer nesta conversa em handoff
      end if;
    elsif v_bloq is null and c.status = 'ativo' then
      -- ── retorno pedido pelo cliente: prioridade, pode sair fora do horário ──
      if c.agendamento_retorno is not null
         and c.agendamento_retorno > coalesce(L, c.created_at)
         and (c.cadencia_retorno_em is null or c.cadencia_retorno_em < c.agendamento_retorno) then
        v_passo := 'RETORNO'; v_at := c.agendamento_retorno; v_exc := 'pedido do cliente';
        if v_janela then
          v_acao := 'texto';
          v_txt := 'Oi' || case when public.mari_cadencia_nome(c) <> 'tudo bem' then ', ' || public.mari_cadencia_nome(c) else '' end
                   || '! Como combinamos, estou passando pra gente retomar. Quer seguir de onde paramos? 😊';
        else
          v_acao := 'template'; v_tpl := 'nio_retomada_lead_d3'; v_cat := 'MARKETING';
          v_params := jsonb_build_array(public.mari_cadencia_nome(c), public.mari_cadencia_contexto(c));
          v_txt := public.mari_render_template(v_tpl, v_params);
        end if;
        if p_agora < v_at then v_bloq := 'retorno agendado pelo cliente'; end if;
      elsif c.processando_ate is not null and c.processando_ate > p_agora then
        v_bloq := 'Mari respondendo agora';
      elsif L is null and c.origem not in ('meta_ads', 'site', 'indicacao') then
        continue;   -- sem mensagem do lead e sem origem de formulário: não há escada
      elsif L is not null and (M is null or M < L) and c.cadencia_passo = 'nenhum' then
        v_bloq := 'aguardando a Mari responder';
      else
        -- ── a escada ──
        B := greatest(coalesce(L, '-infinity'::timestamptz), coalesce(c.cadencia_retorno_em, '-infinity'::timestamptz));
        if L is null then
          B := coalesce((select min(cc.em) from public.contatos_cliente cc where cc.conversa_id = c.id and cc.toque = 'P1'),
                        c.cadencia_passo_em, c.created_at);
          seq := array['P1', 'D7', 'D15', 'ENCERRAR'];
          ats := array[c.created_at, B + interval '7 days', B + interval '15 days', null];
          validos := array[B + interval '7 days', B + interval '15 days', 'infinity'::timestamptz, 'infinity'::timestamptz];
        else
          f1_at := M + interval '60 minutes';
          if c.cadencia_retorno_em is not null or not public.mari_no_horario(f1_at, c.cidade) or f1_at >= L + interval '20 hours' then
            f1_at := null;
          end if;
          f2_at := public.mari_proximo_horario(L + interval '20 hours', c.cidade);
          f2_ate := L + interval '23 hours';
          if c.cadencia_retorno_em is not null then
            f2_at := null;
          elsif f2_at is null or f2_at >= f2_ate then
            a_ant := public.mari_ultimo_horario(L + interval '20 hours', c.cidade);
            if a_ant is not null and a_ant >= greatest(M, coalesce(c.cadencia_passo_em, M), coalesce(f1_at, M)) + interval '30 minutes' then
              f2_at := a_ant; f2_ate := least(L + interval '23 hours', a_ant + interval '15 minutes');
            else
              f2_at := null;
            end if;
          end if;
          d3_at := B + interval '3 days'; d7_at := B + interval '7 days'; d15_at := B + interval '15 days';
          seq := array['F1', 'F2', 'D3', 'D7', 'D15', 'ENCERRAR'];
          ats := array[f1_at, f2_at, d3_at, d7_at, d15_at, null];
          validos := array[least(L + interval '20 hours', coalesce(f2_at, 'infinity')), f2_ate, d7_at, d15_at,
                           'infinity'::timestamptz, 'infinity'::timestamptz];
        end if;
        if c.cadencia_passo = 'D15' then
          ats[array_length(seq, 1)] := c.cadencia_passo_em + interval '48 hours';
        end if;

        idx_atual := coalesce(array_position(seq, c.cadencia_passo), 0);
        if c.cadencia_passo = 'F2' and seq[1] = 'P1' then idx_atual := 1; end if;
        alvo := null; prox := null;
        for i in (idx_atual + 1)..array_length(seq, 1) loop
          if ats[i] is null then continue; end if;
          if seq[i] in ('F1', 'F2') and ats[i] <= p_agora and not public.mari_no_horario(p_agora, c.cidade) then continue; end if;
          if ats[i] <= p_agora and p_agora < validos[i] then alvo := i;
          elsif ats[i] > p_agora and prox is null then prox := i;
          end if;
        end loop;

        if alvo is not null then
          v_passo := seq[alvo]; v_at := ats[alvo];
        elsif prox is not null then
          v_passo := seq[prox]; v_at := ats[prox]; v_bloq := 'aguardando';
        else
          continue;
        end if;

        if v_passo in ('F1', 'F2') then
          v_acao := 'texto'; v_txt := public.mari_cadencia_texto(c, v_passo);
        elsif v_passo = 'ENCERRAR' then
          v_acao := 'encerrar'; v_txt := null;
        else
          v_acao := 'template';
          v_tpl := case v_passo when 'P1' then 'nio_primeiro_contato' when 'D3' then 'nio_retomada_lead_d3'
                                when 'D7' then 'nio_retomada_lead_d7' else 'nio_retomada_lead_d15' end;
          v_cat := 'MARKETING';
          v_params := case when v_tpl = 'nio_retomada_lead_d3'
                           then jsonb_build_array(public.mari_cadencia_nome(c), public.mari_cadencia_contexto(c))
                           else jsonb_build_array(public.mari_cadencia_nome(c)) end;
          v_txt := public.mari_render_template(v_tpl, v_params);
        end if;
        if v_passo in ('F1', 'F2') and not v_janela then v_bloq := 'janela de 24 h fechada'; end if;
        v_lig := c.cadencia_passo = 'D3' and p_agora >= c.cadencia_passo_em + interval '1 day' and p_agora < B + interval '6 days';
      end if;
    end if;

    if v_passo is null then
      if v_bloq is null then continue; end if;
    end if;

    -- ── regras duras do envio: horário, teto, filtro de texto ──
    if v_bloq is null and v_acao not in ('encerrar', 'ligar') then
      if v_exc is null and not public.mari_no_horario(p_agora, c.cidade) then
        v_bloq := 'fora do horário';
        v_at := greatest(v_at, public.mari_proximo_horario(p_agora, c.cidade));
      elsif v_tq.hoje >= 2 then
        v_bloq := 'limite do dia (2 toques)';
        v_at := greatest(v_at, public.mari_proximo_horario(((p_agora at time zone 'America/Sao_Paulo')::date + 1)::timestamp at time zone 'America/Sao_Paulo', c.cidade));
      elsif v_tq.mes >= 15 then
        v_bloq := 'limite do mês (15 toques)';
      elsif v_acao = 'template' and not exists (select 1 from public.config_templates_waba t where t.nome = v_tpl and t.status = 'APPROVED') then
        v_bloq := 'template não aprovado';
      else
        v_proib := public.mari_texto_proibido(v_txt);
        if v_proib is not null then v_bloq := 'texto reprovado no filtro (' || v_proib || ')'; end if;
      end if;
    end if;
    v_pode := v_passo is not null and v_bloq is null and v_acao is distinct from 'ligar';

    conversa_id := c.id; telefone := c.telefone; canal := c.canal; chatwoot_conversation_id := c.chatwoot_conversation_id;
    status := c.status; etapa := c.etapa; passo_atual := c.cadencia_passo; passo_em := c.cadencia_passo_em;
    proximo_passo := v_passo; proximo_em := v_at; pode_enviar := v_pode; bloqueio := v_bloq; acao := v_acao;
    template := v_tpl; categoria := v_cat; params := v_params; texto := v_txt; excecao := v_exc;
    janela_aberta := v_janela; janela_fecha_em := case when L is not null then L + interval '24 hours' end;
    toques_hoje := v_tq.hoje; toques_mes := v_tq.mes; ligar_sugerido := v_lig; venda_id := c.venda_id;
    return next;
  end loop;
end;
$$;

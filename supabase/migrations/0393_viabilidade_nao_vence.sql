-- NIOGEN | supabase/migrations/0393_viabilidade_nao_vence.sql | 25/11/2026 — Claude Code (Fable 5.2)
-- Ricardo, 25/11/2026: "não existe essa regra de viabilidade vencer com 7 dias. Se o endereço passa fibra hoje, passará sempre.
-- E mesmo eu tentando fazer a viabilidade de novo, o banco não deixou gravar."
-- O que havia (caso L-153): a 0048 (06/11) passou a exigir a viabilidade do portal "Viável e com menos de 7 dias". Depois de 7 dias
-- a ficha dizia "vencida: consulte de novo", mas a porta recusa regravar a viabilidade depois do crédito ("A viabilidade já foi
-- registrada nesta venda", config_transicao, 0275). O sistema pedia uma coisa que ele mesmo não aceitava.
-- O que muda: a validade de 7 dias sai dos cinco lugares do banco. Viável no portal vale enquanto o endereço for o mesmo
-- (mudou número ou complemento, a viabilidade já é apagada por _mari_viab_endereco_mudou / vendas_carimba_viab_por — isso fica).
--   1. vendas_antes_status   — a trava de virar venda exige só "Viável"; a frase perde o "menos de 7 dias".
--   2. _porta_momento        — os dois avisos "Registre a viabilidade" só saem quando ela não é Viável.
--   3. v_vendas e v_funil    — nio_viab_ok = Viável (e o viab_ok composto acompanha).
--   4. v_jornada_base        — viab_ok = Viável; some o alarme "Viabilidade vencida (> 7 dias)".
-- O que NÃO muda: a validade de 7 dias da PISTA do DFV (dfv_ok) — o Ricardo falou da viabilidade do portal; a recusa de regravar a
-- viabilidade depois do crédito (agora coerente: registrada uma vez, vale).
-- Definições tiradas da produção em 25/11/2026 (pg_get_functiondef / pg_get_viewdef) e alteradas só nesses pontos.
-- Regra 20: nenhum estado, evento ou tabela novos (1–5 não se aplicam); regra de ouro 9: _porta_momento e vendas_antes_status não são
-- casca da porta. Cenário X124.

begin;

--───────────── 1. a trava de virar venda ─────────────
CREATE OR REPLACE FUNCTION public.vendas_antes_status()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  mudou   boolean := tg_op = 'INSERT' or new.status is distinct from old.status;
  vendida boolean := new.status in ('1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio', '5_comissao_firme');
  entrou  boolean;
begin
  if not mudou then
    return new;
  end if;
  entrou := vendida and (tg_op = 'INSERT' or old.status in ('0_qualificado', 'saida'));

  -- 0191: VENDA = crédito → OS aberta no portal (já com a agenda). A biometria e o cartão vêm depois.
  if entrou and coalesce(btrim(new.nio_pedido), '') = '' then
    raise exception 'Ainda não é venda: falta o nº do pedido (OS) do portal.' using errcode = 'P0001';
  end if;
  if entrou and new.credito_resultado = 'negado' then
    raise exception 'Ainda não é venda: o crédito foi negado. Tente outro CPF (pendência) ou encerre.' using errcode = 'P0001';
  end if;
  -- 0191 (Ricardo, 14/11): no portal a OS sai ANTES da biometria (forma de pagamento → agenda → OS → link da biometria).
  -- Gravar a OS = VENDA; a biometria vem depois. Reprovada → Saída · Reprovado na biometria.
  if entrou and coalesce(btrim(new.nio_os), '') = '' then
    raise exception 'Ainda não é venda: falta o nº do pedido (OS) do portal.' using errcode = 'P0001';
  end if;
  if new.status = '2_aguardando_instalacao' and new.instalacao_agendada_para is null then
    raise exception 'Falta o dia e o período da instalação.' using errcode = 'P0001';
  end if;
  -- Viabilidade (0048; 0393): só a do PORTAL PAP, Viável. Não vence (Ricardo, 25/11). O DFV é pista e não libera.
  if entrou and new.nio_viab_resultado is distinct from 'viavel' then
    raise exception 'Ainda não é venda: falta a viabilidade do portal PAP (Viável). Registre na ficha. O DFV é só pista.'
      using errcode = 'P0001';
  end if;

  if new.status = 'saida' and coalesce(btrim(new.motivo_saida), '') = '' then
    raise exception 'Saída exige motivo.' using errcode = 'P0001';
  end if;

  if new.status = '1_vendido' then
    new.vendido_em := coalesce(new.vendido_em, now());
  elsif new.status = '2_aguardando_instalacao' then
    new.vendido_em := coalesce(new.vendido_em, now());
    new.agendamento_registrado_em := coalesce(new.agendamento_registrado_em, now());
  elsif new.status = '3_instalado' then
    new.instalado_em := coalesce(new.instalado_em, now());
  elsif new.status = '4_ativo_provisorio' then
    new.ativado_em := coalesce(new.ativado_em, now());
  end if;
  return new;
end;
$function$;

-- ───────────── 2. os avisos da porta ─────────────
CREATE OR REPLACE FUNCTION public._porta_momento(p_venda uuid, p_momento text, p_dados jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_os     text;
  v_tinha  boolean;
  v_igual  boolean := false;   -- 0251 (D14): reagendar para o mesmo dia e turno não muda nada
  v_forma  text;
  semana   text[] := array['segunda-feira','terça-feira','quarta-feira','quinta-feira','sexta-feira','sábado','domingo'];
  r        jsonb;
  v_bio    public.nio_biometria;   -- 0246: biometria que o GED360 já viu antes da OS
begin
  -- 0287: peça da porta. Quem chega aqui já passou pela tabela (porta) e pelo perfil (backoffice_momento__nucleo).
  if p_momento = 'reagendar' then p_momento := 'agendar'; end if;   -- 0096: agendar e reagendar são o mesmo passo
  if p_momento not in ('assumir', 'viabilidade', 'credito', 'pedido', 'biometria', 'os', 'agendar', 'os_agendar', 'parar', 'devolver_mari') then
    raise exception 'Momento desconhecido: %', p_momento;
  end if;
  select nome, chatwoot_agente_id into quem, agente from public.usuarios where id = auth.uid();
  quem := coalesce(quem, 'time');

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
  if p_momento in ('viabilidade', 'credito', 'pedido', 'biometria', 'os', 'agendar', 'os_agendar') and v.id is null then
    raise exception 'Este botão precisa de uma venda.';
  end if;
  tem_cw := c.id is not null and c.canal = 'whatsapp' and coalesce(c.chatwoot_conversation_id, '') <> ''
            and c.telefone not like '5500000000%';

  -- ── assumir (0282: quem executa é a porta — _porta_assumir) ──
  if p_momento = 'assumir' then
    if c.id is null then raise exception 'Esta venda não tem conversa no Chatwoot para assumir.'; end if;
    r := public._porta_assumir(c, v, jsonb_build_object('grupo', g, 'ordem', o, 'via', 'momento'));
    if coalesce((r ->> 'repetida')::boolean, false) then
      return jsonb_build_object('ok', true, 'momento', p_momento, 'acoes', 0, 'feito', jsonb_build_array('já assumida há instantes'),
                                'resumo', '✓ esta conversa já foi assumida há instantes — nada repetido', 'venda_id', v.id, 'conversa_id', c.id);
    end if;
    o := coalesce((r ->> 'acoes')::int, o);
    feito := feito || array(select jsonb_array_elements_text(coalesce(r -> 'feito', '[]'::jsonb)));

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

  -- ── pedido gravado no portal (etapa 3): SÓ o pedido; a Nio manda o link da biometria (0089) ──
  elsif p_momento = 'pedido' then
    v_ped := btrim(coalesce(d ->> 'pedido', ''));
    if v_ped !~ '^[A-Za-z0-9._/-]{4,40}$' then
      raise exception 'Número do pedido inválido: use só letras, números, ponto, barra ou hífen (4 a 40 caracteres).' using errcode = '22023';
    end if;
    if v.status = 'saida' then raise exception 'A venda está em Saída; reabra pela ficha antes de registrar o pedido.'; end if;
    if v.status <> '0_qualificado' then raise exception 'O pedido já foi gravado e a venda já andou.'; end if;
    if d ? 'link' and coalesce(d ->> 'link', '') <> '' and (d ->> 'link') !~* '^https?://' then
      raise exception 'O link da biometria tem que começar com https://';
    end if;
    if v.nio_pedido is not distinct from v_ped then
      update public.vendas set credito_resultado = coalesce(nullif(d ->> 'credito', ''), credito_resultado),
             biometria_link = coalesce(nullif(btrim(coalesce(d ->> 'link', '')), ''), biometria_link) where id = v.id;
      return jsonb_build_object('ok', true, 'momento', p_momento, 'acoes', 0, 'feito', jsonb_build_array('pedido já estava gravado'),
                                'resumo', '✓ pedido nº ' || v_ped || ' já estava gravado — nada foi reenviado ao cliente', 'venda_id', v.id);
    end if;
    -- O trigger 0032 carimba nio_pedido_em e a biometria pendente (as 24 h / 72 h contam dali).
    update public.vendas set
      nio_pedido = v_ped,
      credito_resultado = coalesce(nullif(d ->> 'credito', ''), credito_resultado),
      biometria_link = coalesce(nullif(btrim(coalesce(d ->> 'link', '')), ''), biometria_link)
    where id = v.id;
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (v.id, 'pedido_aberto_portal', jsonb_build_object('origem', coalesce(nullif(d ->> 'origem', ''), 'ficha'), 'pedido', v_ped), auth.uid());
    feito := feito || 'pedido gravado · etapa Pedido · biometria'::text;
    if v.nio_viab_resultado is distinct from 'viavel' then
      aviso := 'Registre a viabilidade do portal (Viável): sem ela a venda não conta.';
    end if;
    if tem_cw then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas', jsonb_build_object('add', jsonb_build_array('biometria-pendente')));
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', '🧾 Pedido nº ' || v_ped || ' aberto às ' || agora_t || ' — ' || quem || '. A Nio manda o link da biometria ao cliente.'));
      if coalesce((d ->> 'sem_aviso')::boolean, false) then
        feito := feito || 'etiqueta'::text || 'nota'::text || 'sem aviso ao cliente (o time já avisou)'::text;   -- 0092
      else
        o := o + 1;
        msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_pedido_biometria', '{}'::jsonb,
                                   'nio_lembrete_biometria_v2', jsonb_build_array(public.mari_cadencia_nome(c)), 'aviso do pedido (biometria)');
        feito := feito || 'etiqueta'::text || 'nota'::text;
      end if;
    end if;

  -- ── crédito no portal (0092: registrado da extensão, na etapa do cadastro) ──
  elsif p_momento = 'credito' then
    v_res := d ->> 'resultado';
    if v_res not in ('aprovado', 'so_cartao', 'pendente', 'negado') then raise exception 'Crédito: use aprovado, só cartão, pendente ou negado.'; end if;
    if v.status = 'saida' then raise exception 'A venda está em Saída.'; end if;
    v_tinha := coalesce(v.credito_resultado, '') in ('aprovado', 'so_cartao') or coalesce(btrim(v.nio_pedido), '') <> '';
    update public.vendas set credito_resultado = v_res where id = v.id;
    feito := feito || ('crédito ' || case v_res when 'aprovado' then 'aprovado' when 'so_cartao' then 'aprovado só no cartão' when 'pendente' then 'pendente' else 'negado' end)::text;
    -- 0247 (Ricardo, 16/11): ordem do portal = crédito → biometria (link da Nio, aprovada) → forma de pagamento → agenda → OS.
    if v_res in ('aprovado', 'so_cartao') and v.status = '0_qualificado' and not v_tinha then
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (v.id, 'credito_aprovado_portal', jsonb_build_object('origem', coalesce(nullif(d ->> 'origem', ''), 'ficha'), 'resultado', v_res), auth.uid());
      feito := feito || 'próximo: a biometria (link da Nio); aprovada, forma de pagamento, agenda e OS no portal'::text;
      if v.nio_viab_resultado is distinct from 'viavel' then
        aviso := 'Registre a viabilidade do portal (Viável): sem ela a venda não conta.';
      end if;
    end if;
    if v_res = 'negado' then
      if not exists (select 1 from public.venda_pendencias where venda_id = v.id and encerrada_em is null)
         and exists (select 1 from public.config_motivos_pendencia where codigo = 'credito_outro_cpf' and ativo) then
        v_dia := (now() at time zone 'America/Sao_Paulo')::date + 1;
        while extract(isodow from v_dia) = 7 loop v_dia := v_dia + 1; end loop;
        perform public.pendencia_abrir(v.id, 'credito_outro_cpf', null, v_dia);
        feito := feito || 'pendência aberta (outro CPF)'::text;
      end if;
    end if;
    -- 0246 (caso Queroly, 16/11): o mesmo resultado gravado de novo (ficha e depois extensão) não repete a nota.
    if tem_cw and v_res = coalesce(v.credito_resultado, '') and exists (
         select 1 from public.chatwoot_acoes pa where pa.venda_id = v.id and pa.momento = 'credito' and pa.tipo = 'nota'
            and pa.status <> 'cancelada' and pa.criada_em > now() - interval '12 hours') then
      feito := feito || 'nota já estava no Chatwoot'::text;
    elsif tem_cw then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota', jsonb_build_object('content',
        '💳 Crédito no portal: ' || case v_res when 'aprovado' then 'aprovado — próximo: biometria (link da Nio); aprovada, forma de pagamento, agenda e OS' when 'so_cartao' then 'aprovado só no cartão — próximo: biometria; aprovada, agenda e OS (cartão)' when 'pendente' then 'pendente (24 h)' else 'negado — pedido outro CPF' end
        || ' — ' || quem || ', ' || agora_t || '.'));
      feito := feito || 'nota'::text;
      if v_res = 'negado' then
        o := o + 1;
        -- 0224 (Ricardo, caso Lucas Heleno 15/11): conversa com uma pessoa do time ou pedido já feito nas últimas 24 h → sem mensagem
        -- automática (saía na voz da Mari no meio da conversa do time e repetia depois do "não aprovou").
        if coalesce(c.humano_atribuido, false) or coalesce(c.time_atribuido, false) or c.chatwoot_agente is not null or v.status = 'saida'
           or exists (select 1 from public.chatwoot_acoes pa where pa.venda_id = v.id and pa.payload ->> 'rotulo' = 'pedido de outro CPF'
                       and pa.status <> 'cancelada' and pa.criada_em > now() - interval '24 hours') then
          aviso := concat_ws(' ', aviso, 'A conversa está com você (ou o pedido de outro CPF já saiu hoje): fale com o cliente pela conversa.');
        else
          msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_credito_negado', '{}'::jsonb, null, null, 'pedido de outro CPF');
        end if;
      end if;
    end if;
    if v_res = 'so_cartao' and coalesce(v.forma_pagamento, '') <> 'cartao' then
      aviso := 'Aprovado só no cartão: troque a forma de pagamento na ficha (Detalhes › Plano, valor e pagamento › Trocar).';
    end if;

  -- ── biometria (Validada · Risco · Negado) — etapa 3 ──
  elsif p_momento = 'biometria' then
    if coalesce(btrim(v.nio_pedido), '') = '' and coalesce(v.credito_resultado, '') not in ('aprovado', 'so_cartao') then
      raise exception 'Grave antes o crédito aprovado: a biometria vem do link que a Nio manda depois do crédito.';
    end if;
    v_res := d ->> 'resultado';
    if v_res = 'validada' then
      update public.vendas set biometria_status = 'validada' where id = v.id;
      -- 0191: a mensagem ao cliente sai pela cadência da Mari (cartão: aviso do cadastro do cartão; boleto: confirmação da instalação).
      feito := feito || case when v.forma_pagamento = 'cartao'
                             then 'biometria validada · a Nio manda o link do cartão e a Mari avisa o cliente'
                             else 'biometria validada · a Mari confirma a instalação ao cliente' end::text;
      if tem_cw then
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas', jsonb_build_object('remove', jsonb_build_array('biometria-pendente')));
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
          jsonb_build_object('content', '✅ Biometria validada — ' || quem || ', ' || agora_t || '. '
            || case when v.forma_pagamento = 'cartao' then 'Cartão: a Nio manda o link do cadastro do cartão; a visita depende dele.'
                    else 'A Mari confirma a instalação ao cliente.' end));
        feito := feito || 'etiqueta'::text || 'nota'::text;
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
        -- 0224 (Ricardo, caso Lucas Heleno 15/11): conversa com uma pessoa do time ou pedido já feito nas últimas 24 h → sem mensagem
        -- automática (saía na voz da Mari no meio da conversa do time e repetia depois do "não aprovou").
        if coalesce(c.humano_atribuido, false) or coalesce(c.time_atribuido, false) or c.chatwoot_agente is not null or v.status = 'saida'
           or exists (select 1 from public.chatwoot_acoes pa where pa.venda_id = v.id and pa.payload ->> 'rotulo' = 'pedido de outro CPF'
                       and pa.status <> 'cancelada' and pa.criada_em > now() - interval '24 hours') then
          aviso := concat_ws(' ', aviso, 'A conversa está com você (ou o pedido de outro CPF já saiu hoje): fale com o cliente pela conversa.');
        else
          msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_credito_negado', '{}'::jsonb, null, null, 'pedido de outro CPF');
        end if;
        feito := feito || 'nota'::text;
      end if;
    elsif v_res = 'dispensada' then
      -- 0196 (Ricardo, 14/11): com o sistema de biometria fora do ar a Nio libera a venda sem biometria. Vale como aprovada
      -- (comissão normal; no cartão, o link do cadastro do cartão sai logo). O time marca por venda, com motivo e autor.
      if coalesce(btrim(v.nio_os), '') = '' and coalesce(v.credito_resultado, '') not in ('aprovado', 'so_cartao') then
        raise exception 'A dispensa da biometria é depois do crédito aprovado.';
      end if;
      if v.biometria_status = 'validada' then raise exception 'A biometria desta venda já está validada.'; end if;
      update public.vendas set biometria_status = 'validada', biometria_dispensada_em = now(), biometria_dispensada_por = auth.uid(),
             biometria_dispensa_motivo = coalesce(nullif(btrim(d ->> 'motivo'), ''), 'sistema de biometria da Nio fora do ar')
       where id = v.id;
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (v.id, 'biometria_dispensada', jsonb_build_object('motivo', coalesce(nullif(btrim(d ->> 'motivo'), ''), 'sistema de biometria da Nio fora do ar'),
              'queda_id', (select q.id from public.biometria_quedas q where q.fim is null order by q.inicio desc limit 1)), auth.uid());
      feito := feito || case when v.forma_pagamento = 'cartao'
                             then 'biometria dispensada pela Nio · a Mari avisa do cadastro do cartão'
                             else 'biometria dispensada pela Nio · a Mari confirma a instalação' end::text;
      if tem_cw then
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas', jsonb_build_object('remove', jsonb_build_array('biometria-pendente')));
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
          jsonb_build_object('content', '🟢 Biometria dispensada pela Nio (sistema de biometria fora do ar) — ' || quem || ', ' || agora_t || '. Vale como aprovada.'));
        feito := feito || 'etiqueta'::text || 'nota'::text;
      end if;
    else
      raise exception 'Biometria: use validada, dispensada, risco ou negado.';
    end if;

  -- ── 0096 (Ricardo, 09/11: "São etapas diferentes"): OS aberta no portal = VENDA (etapa 4). Agendar vem depois. ──
  elsif p_momento = 'os' then
    v_os := btrim(coalesce(d ->> 'os', ''));
    if v_os !~ '^[A-Za-z0-9._/-]{3,40}$' then
      raise exception 'Nº do pedido (OS) inválido: use só letras, números, ponto, barra ou hífen.' using errcode = '22023';
    end if;
    -- 0277 (caso Queroly, 18/11): REEMITIR O PEDIDO. A Nio não deixa trocar a forma de pagamento de uma OS aberta: o time cancela a OS
    -- no portal (fica "Draft") e emite um pedido novo, que gera OS e agenda novas; a biometria aprovada vale. Só o admin (porta, 0275:
    -- "Só o admin corrige a OS depois de gravada"). Troca a OS, guarda a antiga no histórico, apaga a agenda velha (a nova vem da
    -- Consulta OS, que passa a ler a OS nova) e volta a venda para "falta agendar".
    if v.status in ('1_vendido', '2_aguardando_instalacao') and v.instalado_em is null
       and coalesce(btrim(v.nio_os), '') <> '' and btrim(v.nio_os) <> v_os then
      declare
        os_antiga    text := btrim(v.nio_os);
        forma_antiga text := v.forma_pagamento;
        ag_antiga    timestamptz := v.instalacao_agendada_para;
      begin
        v_forma := nullif(btrim(coalesce(d ->> 'forma', '')), '');
        if v_forma is not null and v_forma not in ('boleto', 'cartao', 'dacc') then raise exception 'Forma de pagamento inválida.'; end if;
        if v.credito_resultado = 'so_cartao' and coalesce(v_forma, v.forma_pagamento, '') <> 'cartao' then
          raise exception 'O crédito foi aprovado só no cartão: a forma de pagamento da OS tem de ser cartão.' using errcode = 'P0001';
        end if;
        if exists (select 1 from public.vendas x where x.id <> v.id and (x.nio_os = v_os or x.nio_pedido = v_os)) then
          raise exception 'A OS % já está em outra venda.', v_os using errcode = 'P0001';
        end if;
        perform set_config('niogen.transicao_ok', 'reemitir', true);   -- "aguardando instalação" → "vendida, falta agendar"
        update public.vendas set nio_os = v_os, nio_pedido = v_os, status = '1_vendido',
               forma_pagamento = coalesce(v_forma, forma_pagamento),
               instalacao_agendada_para = null, instalacao_turno = null, nio_situacao = null,
               nio_pendencia_cod = null, nio_pendencia_desc = null, cartao_pago_em = null
         where id = v.id returning * into v;
        perform set_config('niogen.transicao_ok', '', true);
        insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
        values (v.id, 'os_reemitida', jsonb_strip_nulls(jsonb_build_object('os_antiga', os_antiga, 'os', v_os,
                  'forma_antiga', forma_antiga, 'forma', v.forma_pagamento, 'agenda_antiga', ag_antiga,
                  'motivo', nullif(btrim(coalesce(d ->> 'motivo', '')), ''), 'origem', coalesce(nullif(d ->> 'origem', ''), 'ficha'))), auth.uid());
        feito := feito || ('pedido reemitido · OS ' || os_antiga || ' → ' || v_os
                           || case when forma_antiga is distinct from v.forma_pagamento then ' · pagamento ' || coalesce(forma_antiga, '—') || ' → ' || v.forma_pagamento else '' end
                           || ' · a agenda nova vem da Consulta OS')::text;
        if tem_cw then
          o := o + 1;
          perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
            jsonb_build_object('content', '🔁 Pedido reemitido: OS ' || os_antiga || ' cancelada no portal → nova OS nº ' || v_os
              || case when forma_antiga is distinct from v.forma_pagamento then ' (pagamento: ' || coalesce(forma_antiga, '—') || ' → ' || v.forma_pagamento || ')' else '' end
              || '. Biometria mantida. A agenda nova vem da Consulta OS — ' || quem || ', ' || agora_t || '.'));
          feito := feito || 'nota'::text;
        end if;
      end;
    else
      if v.status <> '0_qualificado' then raise exception 'A OS já foi gravada nesta venda.'; end if;
      -- Uma atualização só: se a trava recusar (falta pedido, biometria, viabilidade…), nada fica gravado e a mensagem volta.
      -- 0247: "Gravar venda" = só o nº da OS (e a forma de pagamento do portal, se mudou). A agenda vem da Consulta OS (operador).
      v_forma := nullif(btrim(coalesce(d ->> 'forma', '')), '');
      if v_forma is not null and v_forma not in ('boleto', 'cartao', 'dacc') then raise exception 'Forma de pagamento inválida.'; end if;
      -- 0256: o GED360 é lido ANTES de gravar a OS — a trava da biometria (vendas_transicao) já enxerga a aprovação que ele viu.
      v_bio := public._ged360_da_venda(v.id);
      if v_bio.protocolo is not null then
        update public.vendas set biometria_link_enviado_em = coalesce(least(v_bio.primeira_leitura, v_bio.data_envio), biometria_link_enviado_em)
         where id = v.id;
        perform public._ged360_aplicar(v_bio);
        select * into v from public.vendas where id = v.id;
      end if;
      update public.vendas set nio_os = v_os, nio_pedido = v_os, status = '1_vendido', forma_pagamento = coalesce(v_forma, forma_pagamento)
       where id = v.id returning * into v;
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (v.id, 'os_aberta_portal', jsonb_build_object('os', v_os, 'forma', v.forma_pagamento, 'origem', coalesce(nullif(d ->> 'origem', ''), 'ficha')), auth.uid());
      feito := feito || ('VENDA · pedido (OS) ' || v_os || ' · a agenda vem da Consulta OS')::text;
      -- 0246 (caso Queroly, 16/11): o portal pode mandar a biometria ANTES da OS. Se o GED360 já viu o link, a hora é a dele,
      -- a aprovação vale agora e o cliente não recebe "a Nio acabou de te mandar o link".
      if v_bio.protocolo is not null then
        feito := feito || ('o link da biometria saiu às ' || to_char(least(v_bio.primeira_leitura, v_bio.data_envio) at time zone 'America/Sao_Paulo', 'HH24:MI')
                           || case when v.biometria_status = 'validada' then ' · aprovada' else '' end)::text;
      end if;
      if tem_cw then
        if v.biometria_status is distinct from 'validada' then
          o := o + 1;
          perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas', jsonb_build_object('add', jsonb_build_array('biometria-pendente')));
        end if;
        o := o + 1;
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
          jsonb_build_object('content', '🧾 Pedido (OS) nº ' || v_os || ' aberto no portal — VENDA. '
            || case when v.biometria_status = 'validada' then 'Biometria já aprovada. '
                    when v_bio.protocolo is not null then 'O link da biometria já tinha saído. '
                    else 'A Nio manda o link da biometria. ' end
            || 'A agenda vem da Consulta OS (o robô lê em instantes) — ' || quem || ', ' || agora_t || '.'));
        feito := feito || 'nota'::text;
        if coalesce((d ->> 'sem_aviso')::boolean, false) or v.biometria_status = 'validada' or v_bio.protocolo is not null then
          feito := feito || 'sem aviso da biometria ao cliente'::text;
        else
          o := o + 1;
          msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_pedido_biometria', '{}'::jsonb,
                                     'nio_lembrete_biometria_v2', jsonb_build_array(public.mari_cadencia_nome(c)), 'aviso do link da biometria');
        end if;
      end if;
    end if;

  -- ── OS + agendamento juntos (0089, mantido para quem já usa) · agendar / reagendar (depois da OS) ──
  elsif p_momento in ('os_agendar', 'agendar') then
    v_dia := nullif(d ->> 'dia', '')::date;
    v_per := coalesce(nullif(d ->> 'periodo', ''), '08:00');
    if v_dia is null then raise exception 'Informe o dia da instalação.'; end if;
    if v_per not in ('08:00', '13:00') then raise exception 'Período inválido.'; end if;
    if v_dia < (now() at time zone 'America/Sao_Paulo')::date then raise exception 'O dia da instalação já passou.'; end if;
    v_ts := (v_dia::text || ' ' || v_per || ':00')::timestamp at time zone 'America/Sao_Paulo';
    v_turno := case when v_per = '13:00' then 'tarde' else 'manha' end;
    if p_momento = 'os_agendar' then
      v_os := btrim(coalesce(d ->> 'os', ''));
      if v_os !~ '^[A-Za-z0-9._/-]{3,40}$' then
        raise exception 'Nº do pedido (OS) inválido: use só letras, números, ponto, barra ou hífen.' using errcode = '22023';
      end if;
      if v.status <> '0_qualificado' then raise exception 'A OS já foi aberta: use Reagendar.'; end if;
      -- 0191 (Ricardo, 14/11): a forma de pagamento escolhida no portal vem junto (pode ter mudado da conversa).
      v_forma := nullif(btrim(coalesce(d ->> 'forma', '')), '');
      if v_forma is not null and v_forma not in ('boleto', 'cartao', 'dacc') then raise exception 'Forma de pagamento inválida.'; end if;
      -- 0256: o GED360 é lido ANTES de gravar a OS — a trava da biometria (vendas_transicao) já enxerga a aprovação que ele viu.
      v_bio := public._ged360_da_venda(v.id);
      if v_bio.protocolo is not null then
        update public.vendas set biometria_link_enviado_em = coalesce(least(v_bio.primeira_leitura, v_bio.data_envio), biometria_link_enviado_em)
         where id = v.id;
        perform public._ged360_aplicar(v_bio);
        select * into v from public.vendas where id = v.id;
      end if;
      -- Uma atualização só: se a trava recusar (falta crédito, viabilidade…), nada fica gravado e a mensagem volta.
      update public.vendas set
        nio_os = v_os, nio_pedido = v_os, instalacao_agendada_para = v_ts, instalacao_turno = v_turno,
        forma_pagamento = coalesce(v_forma, forma_pagamento),
        nio_pendencia_cod = null, nio_pendencia_desc = null, status = '2_aguardando_instalacao'
      where id = v.id
      returning * into v;
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (v.id, 'os_aberta_portal', jsonb_build_object('os', v_os, 'dia', v_dia, 'turno', v_turno, 'forma', v.forma_pagamento,
              'origem', coalesce(nullif(d ->> 'origem', ''), 'ficha')), auth.uid());
      feito := feito || ('VENDA · OS ' || v_os || ' · instalação ' || to_char(v_dia, 'DD/MM') || ' ' || case v_turno when 'tarde' then 'tarde' else 'manhã' end
                         || ' · a Nio manda o link da biometria')::text;
    else
      if v.status not in ('1_vendido', '2_aguardando_instalacao') then
        raise exception 'Agendar é depois da OS: grave antes o nº do pedido (OS) do portal.';
      end if;
      v_tinha := v.instalacao_agendada_para is not null;
      v_igual := v.instalacao_agendada_para = v_ts and coalesce(v.instalacao_turno, '') = v_turno and v.status = '2_aguardando_instalacao';
      update public.vendas set
        instalacao_agendada_para = v_ts, instalacao_turno = v_turno, nio_pendencia_cod = null, nio_pendencia_desc = null,
        status = case when status = '1_vendido' then '2_aguardando_instalacao' else status end
      where id = v.id
      returning * into v;
      feito := feito || (case when v_igual then 'nada mudou: a instalação já estava em ' else 'instalação ' || case when v_tinha then 'reagendada ' else 'agendada ' end end
                         || to_char(v_dia, 'DD/MM') || ' ' || case v_turno when 'tarde' then 'tarde' else 'manhã' end
                         || case when v_igual then ' — nada foi ao cliente' else '' end)::text;
    end if;
    if tem_cw and p_momento = 'os_agendar' then
      -- 0191: OS gravada = a Nio manda o link da biometria. O aviso ao cliente é o da biometria (com a data pré-agendada);
      -- a confirmação da instalação (C2) sai pela cadência depois da biometria aprovada (no cartão, depois do cadastro do cartão).
      v_diatxt := semana[extract(isodow from v_dia)::int] || ', ' || to_char(v_dia, 'DD/MM');
      v_pertxt := case v_turno when 'tarde' then 'tarde, 13h às 17h' else 'manhã, 8h às 12h' end;
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas',
        case when v.biometria_status = 'validada' then jsonb_build_object('add', jsonb_build_array('instalacao-agendada'), 'remove', jsonb_build_array('biometria-pendente'))
             else jsonb_build_object('add', jsonb_build_array('biometria-pendente', 'instalacao-agendada')) end);
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', '🧾 OS nº ' || v_os || ' aberta — VENDA. Instalação pré-agendada: ' || v_diatxt || ', ' || v_pertxt
          || case when v.biometria_status = 'validada' then '. Biometria já aprovada' when v_bio.protocolo is not null then '. O link da biometria já tinha saído'
                  else '. A Nio manda o link da biometria' end
          || case when v.forma_pagamento = 'cartao' then '; depois dela, o link do cadastro do cartão' else '' end
          || ' — ' || quem || ', ' || agora_t || '.'));
      feito := feito || 'etiqueta'::text || 'nota'::text;
      if coalesce((d ->> 'sem_aviso')::boolean, false) or v_bio.protocolo is not null then
        feito := feito || case when v_bio.protocolo is not null then 'sem aviso da biometria (o link já tinha saído; a confirmação da instalação sai pela cadência)'
                               else 'sem aviso ao cliente (o time já avisou)' end::text;
      else
        o := o + 1;
        msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_os_biometria',
                 jsonb_build_object('dia', v_diatxt, 'periodo', v_pertxt),
                 'nio_lembrete_biometria_v2', jsonb_build_array(public.mari_cadencia_nome(c)), 'aviso da OS e da biometria');
        -- 0254 (D13): não resolve mais (ver o agendar abaixo).
      end if;
    elsif tem_cw and not v_igual then
      v_diatxt := semana[extract(isodow from v_dia)::int] || ', ' || to_char(v_dia, 'DD/MM');
      v_pertxt := case v_turno when 'tarde' then 'tarde, 13h às 17h' else 'manhã, 8h às 12h' end;
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas',
        jsonb_build_object('add', jsonb_build_array('instalacao-agendada'), 'remove', jsonb_build_array('biometria-pendente')));
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', case when p_momento = 'os_agendar' then '📅 OS nº ' || v_os || ' aberta e instalação agendada: ' when v_tinha then '📅 Instalação reagendada: ' else '📅 Instalação agendada: ' end
          || v_diatxt || ', ' || v_pertxt || ' — ' || quem || ', ' || agora_t || '.'));
      o := o + 1;
      msg := public._bo_mensagem(g, o, p_momento, v.id, c, 'bo_instalacao_confirmada',
               jsonb_build_object('dia', v_diatxt, 'periodo', v_pertxt),
               'nio_instalacao_agendada',
               jsonb_build_array(public.mari_cadencia_nome(c), v_diatxt, v_pertxt,
                 concat_ws(', ', nullif(btrim(v.logradouro), ''), nullif(btrim(v.numero), ''), nullif(btrim(v.complemento), ''), nullif(btrim(v.bairro), ''))),
               'confirmação da instalação');
      feito := feito || 'etiqueta'::text || 'nota'::text;
      if msg ->> 'status' = 'pendente' then
        update public.mari_conversas set instalacao_avisada_para = v_ts, instalacao_avisada_em = (msg ->> 'quando')::timestamptz
         where id = c.id;
        -- 0254 (D13): agendar NÃO resolve mais a conversa. A 0085 resolvia para a 24387 tirar o dono; desde a regra
        -- "resolvida sem Saída reabre" (venda viva) o Chatwoot reabria 1 min depois e a 24389/24390 devolviam o time — o fim era
        -- o mesmo, mas a pessoa que conduzia perdia a conversa e ficava a nota "o NIOGEN reabriu". Agora o dono fica.
      end if;
    end if;

  -- ── cliente pediu para parar ──
  elsif p_momento = 'parar' then
    if c.id is null then raise exception 'Esta venda não tem conversa da Mari.'; end if;
    perform public.mari_cadencia_parar(c.id, p_resolvida => not (v.id is not null and v.status <> 'saida'), p_nao_contatar => true);
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[cliente pediu para parar — marcado no NIOGEN por ' || quem || ']', false);
    feito := feito || 'não contatar'::text;
    if tem_cw then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas', jsonb_build_object('add', jsonb_build_array('nao-contatar')));
      o := o + 1;
      -- 0252 (H1): com venda viva a venda segue — a conversa fica com o time, aberta, sem mensagem automática nenhuma.
      if v.id is not null and v.status <> 'saida' then
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
          jsonb_build_object('content', '🚫 Cliente pediu para parar — ' || quem || ', ' || agora_t || '. A venda SEGUE: nenhuma mensagem automática '
            || '(nem aviso da venda). Falar com o cliente só se ele escrever. Se ele quiser desistir da compra, use Saída ▾.'));
        feito := feito || 'etiqueta'::text || 'nota'::text || 'a venda segue, sem mensagens'::text;
      else
        perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
          jsonb_build_object('content', '🚫 Cliente pediu para parar — ' || quem || ', ' || agora_t || '. Nunca mais chamar.'));
        o := o + 1; perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'resolver', jsonb_build_object('status', 'resolved'));
        feito := feito || 'etiqueta'::text || 'nota'::text || 'conversa resolvida'::text;
      end if;
    end if;

  -- ── devolver para a Mari (0282: quem executa é a porta — _porta_devolver) ──
  elsif p_momento = 'devolver_mari' then
    if c.id is null then raise exception 'Esta venda não tem conversa da Mari.'; end if;
    r := public._porta_devolver(c, v, jsonb_build_object('grupo', g, 'ordem', o));
    o := coalesce((r ->> 'acoes')::int, o);
    feito := feito || array(select jsonb_array_elements_text(coalesce(r -> 'feito', '[]'::jsonb)));
  end if;

  if msg is not null then
    if msg ->> 'status' = 'repetida' then
      feito := feito || 'mensagem ao cliente não repetida (a mesma já saiu nas últimas 12 h)'::text;
    elsif msg ->> 'status' = 'pendente' then
      quando := (msg ->> 'quando')::timestamptz;
      feito := feito || ('mensagem ao cliente' || case when quando > now() + interval '2 minutes'
                then ' — sai ' || case when (quando at time zone 'America/Sao_Paulo')::date = (now() at time zone 'America/Sao_Paulo')::date
                                       then 'às ' else to_char(quando at time zone 'America/Sao_Paulo', 'DD/MM') || ' às ' end
                     || to_char(quando at time zone 'America/Sao_Paulo', 'HH24:MI') else '' end
                || case when msg ->> 'template' is not null then ' (template ' || (msg ->> 'template') || ')' else '' end)::text;
    else
      aviso := concat_ws(' ', aviso, 'A mensagem ao cliente NÃO saiu (' || (msg ->> 'motivo') || '): mande à mão pelo Chatwoot — está no Live.');
    end if;
  end if;
  if c.id is not null and not tem_cw and c.telefone like '5500000000%' then
    aviso := concat_ws(' ', aviso, 'Telefone de teste: nada foi ao Chatwoot.');
  elsif c.id is null and p_momento in ('pedido', 'os', 'os_agendar', 'agendar', 'biometria') then
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
$function$;

-- ───────────── 3. as views das vendas e do funil ─────────────
create or replace view public.v_vendas with (security_invoker=true) as
 SELECT v.id,
    v.criado_em,
    v.criado_por,
    v.status,
    v.motivo_saida,
    v.interesse_futuro_em,
    v.origem,
    v.origem_ref,
    v.cliente_nome,
    v.cliente_cpf_cnpj,
    v.cliente_whatsapp,
    v.cliente_email,
    v.segmento,
    v.cep,
    v.logradouro,
    v.numero,
    v.complemento,
    v.bairro,
    v.cidade,
    v.uf,
    v.plano_id,
    v.forma_pagamento,
    v.vencimento_dia,
    v.comissao_prevista,
    v.comissao_paga,
    v.ciclo_pago,
    v.estorno_previsto,
    v.nio_pedido,
    v.nio_contrato,
    v.nio_situacao,
    v.nio_pendencia_cod,
    v.nio_pendencia_desc,
    v.biometria_status,
    v.biometria_em,
    v.vendido_em,
    v.agendamento_registrado_em,
    v.instalacao_agendada_para,
    v.instalado_em,
    v.ativado_em,
    v.docs_entregues_em,
    v.vendedor_id,
    v.trava_cobertura,
    v.trava_area,
    v.trava_sem_produto_ativo,
    v.trava_sem_cancelamento_30d,
    v.trava_cpf_valido,
    v.trava_contato_confirmado,
    v.nio_osab_em,
    v.nio_venda_valida,
    v.valor_mensal,
    v.comissao_nominal,
    v.comissao_adicionais,
    v.bonus_transicao_previsto,
    v.bonus_nmei_previsto,
    v.bonus_m10_potencial,
    v.primeiro_vencimento,
    v.dfv_viabilidade,
    v.dfv_consultado_em,
    v.dfv_consultado_por,
    v.dfv_faixa_credito,
    v.dfv_classificacao,
    v.dfv_hp_livre,
    v.dfv_hcs,
    v.dfv_dispensado,
    v.dfv_dispensa_motivo,
    v.dfv_origem,
    v.dfv_resultado,
    v.dfv_particao,
    p.nome AS plano_nome,
    p.familia AS plano_familia,
    p.velocidade AS plano_velocidade,
    p.preco AS plano_preco,
    p.codigo AS plano_codigo,
    p.portfolio AS plano_portfolio,
    p.variante AS plano_variante,
    p.cluster AS plano_cluster,
    p.preco_cartao AS plano_preco_cartao,
    p.taxa_a_vista AS plano_taxa_a_vista,
    p.isencao_meses AS plano_isencao_meses,
    u.nome AS vendedor_nome,
        CASE
            WHEN v.status = '0_qualificado'::text AND v.biometria_status = 'validada'::text THEN round(EXTRACT(epoch FROM now() - v.biometria_validada_em) / 3600::numeric, 2)
            WHEN v.status = '1_vendido'::text AND v.agendamento_registrado_em IS NULL THEN round(EXTRACT(epoch FROM now() - GREATEST(v.biometria_validada_em, v.vendido_em)) / 3600::numeric, 2)
            ELSE NULL::numeric
        END AS horas_sem_agendamento,
        CASE
            WHEN v.status = '0_qualificado'::text AND COALESCE(btrim(v.nio_pedido), ''::text) <> ''::text AND v.biometria_status IS DISTINCT FROM 'validada'::text THEN round(EXTRACT(epoch FROM now() - COALESCE(v.biometria_link_enviado_em, v.nio_pedido_em, v.criado_em)) / 86400::numeric, 2)
            ELSE NULL::numeric
        END AS dias_esperando_biometria,
    v.instalado_em + make_interval(days => COALESCE(( SELECT (r.valor #>> '{}'::text[])::integer AS int4
           FROM config_regras r
          WHERE r.chave = 'prazo_docs_dias'::text), 15)) AS docs_prazo_em,
    COALESCE(v.ativado_em, v.instalado_em) + '30 days'::interval AS firme_em,
    (v.dfv_viabilidade = ANY (ARRAY['viavel'::text, 'viavel_predio'::text])) AND v.dfv_consultado_em >= (now() - '7 days'::interval) AS dfv_ok,
        CASE
            WHEN v.dfv_consultado_em IS NOT NULL THEN floor(EXTRACT(epoch FROM now() - v.dfv_consultado_em) / 86400::numeric)::integer
            ELSE NULL::integer
        END AS dfv_dias,
    COALESCE(v.ativado_em, v.instalado_em) + '180 days'::interval AS downgrade_ate,
    v.nio_viab_resultado,
    v.nio_viab_velocidade,
    v.nio_viab_interesse_id,
    v.nio_viab_endereco_id,
    v.nio_viab_em,
    v.nio_viab_origem,
    v.credito_resultado,
    v.credito_em,
    v.biometria_link,
    v.biometria_link_enviado_em,
    v.biometria_validada_em,
    v.instalacao_preferencia,
    v.instalacao_turno,
    v.nio_viab_resultado = 'viavel'::text AS nio_viab_ok,
    v.nio_viab_resultado = 'viavel'::text OR (v.dfv_viabilidade = ANY (ARRAY['viavel'::text, 'viavel_predio'::text])) AND v.dfv_consultado_em >= (now() - '7 days'::interval) OR COALESCE(v.dfv_dispensado, false) AS viab_ok,
        CASE
            WHEN (v.status = ANY (ARRAY['0_qualificado'::text, '1_vendido'::text])) AND (v.biometria_status = ANY (ARRAY['pendente'::text, 'com_risco'::text])) AND v.biometria_link_enviado_em IS NOT NULL THEN round(EXTRACT(epoch FROM now() - v.biometria_link_enviado_em) / 3600::numeric, 1)
            ELSE NULL::numeric
        END AS horas_biometria_pendente,
        CASE
            WHEN v.status = '0_qualificado'::text AND v.credito_resultado = 'pendente'::text AND v.credito_em IS NOT NULL THEN round(EXTRACT(epoch FROM now() - v.credito_em) / 3600::numeric, 1)
            ELSE NULL::numeric
        END AS horas_credito_pendente,
    COALESCE(v.biometria_validada_em, v.vendido_em) AS agendar_desde,
    v.nio_viab_endereco_portal,
    v.parceiro_id,
    pa.nome AS parceiro_nome,
    v.conferencia_status,
    v.conferencia_motivo,
    v.conferencia_prazo_ate,
    pe.id AS pend_id,
    pe.motivo AS pend_motivo,
    pm.nome AS pend_motivo_nome,
    pe.descricao AS pend_descricao,
    pe.quem_destrava AS pend_quem,
    pe.aberta_em AS pend_desde,
    pe.revisar_em AS pend_revisar_em,
    pe.revisoes AS pend_revisoes,
    pm.saida_sugerida AS pend_saida_sugerida,
    v.nio_os,
    v.nio_os_em,
    jornada_etapa(v.status, v.nio_pedido, v.credito_resultado) AS jornada_etapa,
    v.saida_motivo,
    v.saida_sub,
    v.cancelada_apos_instalar_em,
    v.cancelada_apos_instalar_motivo,
    v.nio_pedido_em,
    v.ponto_referencia,
    v.nio_viab_por,
    COALESCE(v.biometria_validada_em, v.vendido_em) + make_interval(secs => (3600::numeric * COALESCE(( SELECT (r.valor #>> '{}'::text[])::numeric AS "numeric"
           FROM config_regras r
          WHERE r.chave = 'prazo_agendar_horas'::text), 4::numeric))::double precision) AS agendar_ate,
    COALESCE(( SELECT (r.valor #>> '{}'::text[])::numeric AS "numeric"
           FROM config_regras r
          WHERE r.chave = 'prazo_agendar_horas'::text), 4::numeric) AS prazo_agendar_horas,
    COALESCE(( SELECT (r.valor #>> '{}'::text[])::integer AS int4
           FROM config_regras r
          WHERE r.chave = 'prazo_docs_dias'::text), 15) AS prazo_docs_dias
   FROM vendas v
     LEFT JOIN config_planos p ON p.id = v.plano_id
     LEFT JOIN usuarios u ON u.id = v.vendedor_id
     LEFT JOIN parceiros pa ON pa.id = v.parceiro_id
     LEFT JOIN venda_pendencias pe ON pe.venda_id = v.id AND pe.encerrada_em IS NULL
     LEFT JOIN config_motivos_pendencia pm ON pm.codigo = pe.motivo;

create or replace view public.v_funil with (security_invoker=true) as
 SELECT v.id,
    v.criado_em,
    v.criado_por,
    v.status,
    v.motivo_saida,
    v.interesse_futuro_em,
    v.origem,
    v.origem_ref,
    v.cliente_nome,
    v.cliente_cpf_cnpj,
    v.cliente_whatsapp,
    v.cliente_email,
    v.segmento,
    v.cep,
    v.logradouro,
    v.numero,
    v.complemento,
    v.bairro,
    v.cidade,
    v.uf,
    v.plano_id,
    v.forma_pagamento,
    v.vencimento_dia,
    v.comissao_prevista,
    v.comissao_paga,
    v.ciclo_pago,
    v.estorno_previsto,
    v.nio_pedido,
    v.nio_contrato,
    v.nio_situacao,
    v.nio_pendencia_cod,
    v.nio_pendencia_desc,
    v.biometria_status,
    v.biometria_em,
    v.vendido_em,
    v.agendamento_registrado_em,
    v.instalacao_agendada_para,
    v.instalado_em,
    v.ativado_em,
    v.docs_entregues_em,
    v.vendedor_id,
    v.trava_cobertura,
    v.trava_area,
    v.trava_sem_produto_ativo,
    v.trava_sem_cancelamento_30d,
    v.trava_cpf_valido,
    v.trava_contato_confirmado,
    v.nio_osab_em,
    v.nio_venda_valida,
    v.valor_mensal,
    v.comissao_nominal,
    v.comissao_adicionais,
    v.bonus_transicao_previsto,
    v.bonus_nmei_previsto,
    v.bonus_m10_potencial,
    v.primeiro_vencimento,
    v.dfv_viabilidade,
    v.dfv_consultado_em,
    v.dfv_consultado_por,
    v.dfv_faixa_credito,
    v.dfv_classificacao,
    v.dfv_hp_livre,
    v.dfv_hcs,
    v.dfv_dispensado,
    v.dfv_dispensa_motivo,
    v.dfv_origem,
    v.dfv_resultado,
    v.dfv_particao,
    p.nome AS plano_nome,
    p.familia AS plano_familia,
    p.velocidade AS plano_velocidade,
    p.preco AS plano_preco,
    p.codigo AS plano_codigo,
    p.portfolio AS plano_portfolio,
    p.variante AS plano_variante,
    p.cluster AS plano_cluster,
    p.preco_cartao AS plano_preco_cartao,
    p.taxa_a_vista AS plano_taxa_a_vista,
    p.isencao_meses AS plano_isencao_meses,
    u.nome AS vendedor_nome,
        CASE
            WHEN v.status = '0_qualificado'::text AND v.biometria_status = 'validada'::text THEN round(EXTRACT(epoch FROM now() - v.biometria_validada_em) / 3600::numeric, 2)
            WHEN v.status = '1_vendido'::text AND v.agendamento_registrado_em IS NULL THEN round(EXTRACT(epoch FROM now() - GREATEST(v.biometria_validada_em, v.vendido_em)) / 3600::numeric, 2)
            ELSE NULL::numeric
        END AS horas_sem_agendamento,
        CASE
            WHEN v.status = '0_qualificado'::text AND COALESCE(btrim(v.nio_pedido), ''::text) <> ''::text AND v.biometria_status IS DISTINCT FROM 'validada'::text THEN round(EXTRACT(epoch FROM now() - COALESCE(v.biometria_link_enviado_em, v.nio_pedido_em, v.criado_em)) / 86400::numeric, 2)
            ELSE NULL::numeric
        END AS dias_esperando_biometria,
    v.instalado_em + '15 days'::interval AS docs_prazo_em,
    COALESCE(v.ativado_em, v.instalado_em) + '30 days'::interval AS firme_em,
    (v.dfv_viabilidade = ANY (ARRAY['viavel'::text, 'viavel_predio'::text])) AND v.dfv_consultado_em >= (now() - '7 days'::interval) AS dfv_ok,
        CASE
            WHEN v.dfv_consultado_em IS NOT NULL THEN floor(EXTRACT(epoch FROM now() - v.dfv_consultado_em) / 86400::numeric)::integer
            ELSE NULL::integer
        END AS dfv_dias,
    COALESCE(v.ativado_em, v.instalado_em) + '180 days'::interval AS downgrade_ate,
    v.nio_viab_resultado,
    v.nio_viab_velocidade,
    v.nio_viab_interesse_id,
    v.nio_viab_endereco_id,
    v.nio_viab_em,
    v.nio_viab_origem,
    v.credito_resultado,
    v.credito_em,
    v.biometria_link,
    v.biometria_link_enviado_em,
    v.biometria_validada_em,
    v.instalacao_preferencia,
    v.instalacao_turno,
    v.nio_viab_resultado = 'viavel'::text AS nio_viab_ok,
    v.nio_viab_resultado = 'viavel'::text OR (v.dfv_viabilidade = ANY (ARRAY['viavel'::text, 'viavel_predio'::text])) AND v.dfv_consultado_em >= (now() - '7 days'::interval) OR COALESCE(v.dfv_dispensado, false) AS viab_ok,
        CASE
            WHEN (v.status = ANY (ARRAY['0_qualificado'::text, '1_vendido'::text])) AND (v.biometria_status = ANY (ARRAY['pendente'::text, 'com_risco'::text])) AND v.biometria_link_enviado_em IS NOT NULL THEN round(EXTRACT(epoch FROM now() - v.biometria_link_enviado_em) / 3600::numeric, 1)
            ELSE NULL::numeric
        END AS horas_biometria_pendente,
        CASE
            WHEN v.status = '0_qualificado'::text AND v.credito_resultado = 'pendente'::text AND v.credito_em IS NOT NULL THEN round(EXTRACT(epoch FROM now() - v.credito_em) / 3600::numeric, 1)
            ELSE NULL::numeric
        END AS horas_credito_pendente,
    COALESCE(v.biometria_validada_em, v.vendido_em) AS agendar_desde,
    v.nio_viab_endereco_portal,
    v.parceiro_id,
    pa.nome AS parceiro_nome,
    v.conferencia_status,
    v.conferencia_motivo,
    v.conferencia_prazo_ate,
    pe.id AS pend_id,
    pe.motivo AS pend_motivo,
    pm.nome AS pend_motivo_nome,
    pe.descricao AS pend_descricao,
    pe.quem_destrava AS pend_quem,
    pe.aberta_em AS pend_desde,
    pe.revisar_em AS pend_revisar_em,
    pe.revisoes AS pend_revisoes,
    pm.saida_sugerida AS pend_saida_sugerida,
    v.nio_os,
    v.nio_os_em,
    jornada_etapa(v.status, v.nio_pedido, v.credito_resultado) AS jornada_etapa
   FROM vendas v
     LEFT JOIN config_planos p ON p.id = v.plano_id
     LEFT JOIN usuarios u ON u.id = v.vendedor_id
     LEFT JOIN parceiros pa ON pa.id = v.parceiro_id
     LEFT JOIN venda_pendencias pe ON pe.venda_id = v.id AND pe.encerrada_em IS NULL
     LEFT JOIN config_motivos_pendencia pm ON pm.codigo = pe.motivo;

-- ───────────── 4. a jornada ─────────────
create or replace view public.v_jornada_base with (security_invoker=true) as
 SELECT j.tipo,
    j.chave,
    j.venda_id,
    j.conversa_id,
    j.chatwoot_conversation_id,
    j.nome,
    j.cidade,
    j.plano,
    j.origem,
    j.etapa,
    j.etapa_nome,
    j.precisa_acao OR x.furo OR x.prov_vencido OR x.conf_vencida AS precisa_acao,
        CASE
            WHEN x.furo THEN 'agora'::text
            WHEN (x.prov_vencido OR x.conf_vencida) AND j.nivel <> 'agora'::text THEN 'hoje'::text
            ELSE j.nivel
        END AS nivel,
        CASE
            WHEN x.furo AND j.nivel <> 'agora'::text THEN ('Passado pela Mari sem dono há '::text ||
            CASE
                WHEN y.min < 60 THEN y.min || ' min'::text
                ELSE (y.min / 60) || ' h'::text
            END) || ' (horário de atendimento) · assumir'::text
            WHEN x.conf_vencida AND j.nivel <> 'agora'::text THEN ('Cliente confirmou há '::text || (z.conf_min / 60)) || ' h · dar o retorno prometido'::text
            WHEN x.prov_vencido AND j.nivel <> 'agora'::text THEN ('Trocar nº provisório do pedido ('::text || y.pedido) || ') pelo nº real do portal'::text
            WHEN x.confirmou AND j.tipo = 'conversa'::text AND NOT j.precisa_acao THEN 'Cliente confirmou · aguardando você'::text
            ELSE j.o_que_fazer
        END AS o_que_fazer,
        CASE
            WHEN x.furo AND j.nivel <> 'agora'::text THEN 'assumir'::text
            WHEN x.conf_vencida AND j.nivel <> 'agora'::text THEN 'responder'::text
            WHEN x.prov_vencido AND j.nivel <> 'agora'::text THEN 'abrir'::text
            ELSE j.botao
        END AS botao,
        CASE
            WHEN x.furo AND j.nivel <> 'agora'::text THEN y.handoff_em
            WHEN x.conf_vencida AND j.nivel <> 'agora'::text THEN z.conf_desde
            WHEN x.prov_vencido AND j.nivel <> 'agora'::text THEN y.pedido_em
            WHEN x.confirmou AND j.tipo = 'conversa'::text AND NOT j.precisa_acao THEN z.conf_desde
            ELSE j.desde
        END AS desde,
    j.dono_tipo,
    j.dono_nome,
    j.pendencia,
    j.acao_id,
    j.status_venda,
    j.parceiro_id,
    y.min AS sem_dono_min,
    y.prov AS pedido_provisorio,
    x.confirmou AND NOT x.conf_vencida AS cliente_confirmou,
    z.conf_desde AS confirmou_em
   FROM ( WITH cfg AS (
                 SELECT COALESCE(( SELECT (config_regras.valor #>> '{}'::text[])::integer AS int4
                           FROM config_regras
                          WHERE config_regras.chave = 'prazo_docs_dias'::text), 15) AS d_docs,
                    (now() AT TIME ZONE 'America/Sao_Paulo'::text)::date AS hoje
                ), conv AS (
                 SELECT q.id,
                    q.venda_id,
                    q.nome,
                    q.cidade,
                    q.origem,
                    q.plano_nome,
                    q.coluna,
                    q.itens_total,
                    q.itens_validados,
                    q.chatwoot_conversation_id,
                    q.ultima_em,
                    q.janela_24h_fecha_em,
                    q.contatos_hoje,
                    q.contatos_mes,
                    c_1.chatwoot_agente,
                    c_1.chatwoot_time,
                    c_1.chatwoot_status,
                    COALESCE(c_1.humano_atribuido, false) AS humano_atribuido,
                    COALESCE(c_1.nao_contatar, false) AS nao_contatar,
                    c_1.status AS conv_status,
                    c_1.handoff_motivo,
                    c_1.handoff_em,
                    l.ult_lead,
                    l.ult_resp,
                    l.ult_humano,
                    s.minutos AS sem_resp_min,
                    s.desde AS sem_resp_desde,
                    al.tipo AS alerta,
                    al.em AS alerta_em,
                    bl.id AS bloq_id,
                    bl.motivo AS bloq_motivo,
                    bl.criada_em AS bloq_em
                   FROM v_mari_quadro_jornada q
                     JOIN mari_conversas c_1 ON c_1.id = q.id
                     CROSS JOIN LATERAL ( SELECT max(t.created_at) FILTER (WHERE t.papel = 'lead'::text) AS ult_lead,
                            GREATEST(max(t.created_at) FILTER (WHERE t.papel = ANY (ARRAY['mari'::text, 'humano'::text])), ( SELECT max(a.criada_em) AS max
                                   FROM chatwoot_acoes a
                                  WHERE a.conversa_id = q.id AND a.tipo = 'mensagem'::text AND (a.payload ->> 'como'::text) = 'humano'::text AND (a.status = ANY (ARRAY['pendente'::text, 'executando'::text, 'feita'::text]))), c_1.dispensada_em) AS ult_resp,
                            GREATEST(max(t.created_at) FILTER (WHERE t.papel = 'humano'::text), ( SELECT max(a.criada_em) AS max
                                   FROM chatwoot_acoes a
                                  WHERE a.conversa_id = q.id AND a.tipo = 'mensagem'::text AND (a.payload ->> 'como'::text) = 'humano'::text AND (a.status = ANY (ARRAY['pendente'::text, 'executando'::text, 'feita'::text])))) AS ult_humano
                           FROM mari_turnos t
                          WHERE t.conversa_id = q.id) l
                     LEFT JOIN v_mari_sem_resposta s ON s.id = q.id
                     LEFT JOIN LATERAL ( SELECT
                                CASE
                                    WHEN t.texto ~* '(migra[çc][ãa]o|migrar|operadora parceira|outra operadora|desligamento|(pedido|contrato|instala[çc][ãa]o) (foi )?cancelad|\m(tim|claro|vivo)\M ?(ou|,|/) ?\m(tim|claro|vivo)\M)'::text THEN 'golpe'::text
                                    WHEN t.texto ~* '(reclama|sem internet|internet (caiu|parou|lenta|ruim|n[aã]o funciona)|t[eé]cnico n[aã]o (veio|apareceu)|j[aá] sou cliente)'::text THEN 'reclamacao'::text
                                    WHEN t.texto ~* '(descont|abaixa\w* (o |esse )?(pre[cç]o|valor)|mais barat|faz (um |por )?menos)'::text THEN 'desconto'::text
                                    ELSE 'nao_pedi'::text
                                END AS tipo,
                            t.created_at AS em
                           FROM mari_turnos t
                          WHERE t.conversa_id = q.id AND t.papel = 'lead'::text AND t.created_at > (now() - '7 days'::interval) AND t.created_at > COALESCE(l.ult_humano, '-infinity'::timestamp with time zone) AND (t.texto ~* '(migra[çc][ãa]o|migrar|operadora parceira|outra operadora|desligamento|(pedido|contrato|instala[çc][ãa]o) (foi )?cancelad|\m(tim|claro|vivo)\M ?(ou|,|/) ?\m(tim|claro|vivo)\M)'::text OR t.texto ~* '(reclama|sem internet|internet (caiu|parou|lenta|ruim|n[aã]o funciona)|t[eé]cnico n[aã]o (veio|apareceu)|j[aá] sou cliente|descont|abaixa\w* (o |esse )?(pre[cç]o|valor)|mais barat|faz (um |por )?menos|n[aã]o (pedi|solicitei|autorizei)|como (vc|voc[eê]s?) (conseguiu|pegou|achou) meu|n[aã]o me (mande|chame|ligue))'::text)
                          ORDER BY t.created_at DESC
                         LIMIT 1) al ON true
                     LEFT JOIN LATERAL ( SELECT a.id,
                            COALESCE(a.payload ->> 'rotulo'::text, a.momento) || COALESCE(' — '::text || a.erro, ''::text) AS motivo,
                            a.criada_em
                           FROM chatwoot_acoes a
                          WHERE a.conversa_id = q.id AND a.status = 'bloqueada'::text AND a.criada_em > (now() - '7 days'::interval)
                          ORDER BY a.criada_em
                         LIMIT 1) bl ON true
                  WHERE c_1.canal = 'whatsapp'::text AND COALESCE(c_1.telefone, ''::text) !~~ '5500000000%'::text
                ), sinal AS (
                 SELECT cv.id,
                    cv.venda_id,
                    cv.nome,
                    cv.cidade,
                    cv.origem,
                    cv.plano_nome,
                    cv.coluna,
                    cv.itens_total,
                    cv.itens_validados,
                    cv.chatwoot_conversation_id,
                    cv.ultima_em,
                    cv.janela_24h_fecha_em,
                    cv.contatos_hoje,
                    cv.contatos_mes,
                    cv.chatwoot_agente,
                    cv.chatwoot_time,
                    cv.chatwoot_status,
                    cv.humano_atribuido,
                    cv.nao_contatar,
                    cv.conv_status,
                    cv.handoff_motivo,
                    cv.handoff_em,
                    cv.ult_lead,
                    cv.ult_resp,
                    cv.ult_humano,
                    cv.sem_resp_min,
                    cv.sem_resp_desde,
                    cv.alerta,
                    cv.alerta_em,
                    cv.bloq_id,
                    cv.bloq_motivo,
                    cv.bloq_em,
                        CASE
                            WHEN cv.nao_contatar OR cv.coluna = 'encerrada'::text THEN NULL::text
                            WHEN cv.bloq_id IS NOT NULL THEN ('Mensagem não saiu ('::text || cv.bloq_motivo) || ') · mandar à mão'::text
                            WHEN cv.sem_resp_min IS NOT NULL THEN ('Cliente sem resposta há '::text || cv.sem_resp_min) || ' min (a Mari não respondeu)'::text
                            WHEN cv.alerta = 'golpe'::text THEN 'Cliente citou migração, cancelamento ou outra operadora · possível golpe · humano agora'::text
                            WHEN cv.alerta = 'reclamacao'::text THEN 'Reclamação ou já cliente Nio · humano agora'::text
                            WHEN cv.alerta = 'desconto'::text THEN 'Pediu desconto · humano responde (só a tabela da Nio)'::text
                            WHEN cv.alerta = 'nao_pedi'::text THEN '"Não pedi contato" · humano responde e encerra'::text
                            WHEN cv.conv_status = 'handoff_realizado'::text AND (COALESCE(cv.handoff_motivo, ''::text) <> ALL (ARRAY['dados_completos'::text, 'recusa_compra'::text, 'sem_cobertura'::text, 'fora_de_area'::text, 'sem_contato'::text])) AND COALESCE(cv.ult_humano, '-infinity'::timestamp with time zone) < COALESCE(cv.handoff_em, '-infinity'::timestamp with time zone) THEN 'Pediu um consultor · ninguém do time falou ainda'::text
                            WHEN (cv.conv_status = 'handoff_realizado'::text OR cv.humano_atribuido OR cv.chatwoot_agente IS NOT NULL) AND cv.ult_lead > COALESCE(cv.ult_resp, '-infinity'::timestamp with time zone) AND cv.ult_lead > (now() - '7 days'::interval) AND cliente_confirmou_desde(cv.id, cv.ult_resp) IS NULL THEN
                            CASE
                                WHEN cv.coluna = 'retomada'::text THEN 'Voltou a falar depois do time · responder'::text
                                WHEN cv.conv_status = 'handoff_realizado'::text AND (cv.handoff_motivo = ANY (ARRAY['recusa_compra'::text, 'sem_cobertura'::text, 'fora_de_area'::text, 'ja_cliente_nio'::text, 'sem_contato'::text])) THEN ('Voltou a escrever depois de sair ('::text ||
                                CASE cv.handoff_motivo
                                    WHEN 'sem_cobertura'::text THEN 'sem cobertura'::text
                                    WHEN 'fora_de_area'::text THEN 'fora da área'::text
                                    WHEN 'recusa_compra'::text THEN 'recusou'::text
                                    WHEN 'ja_cliente_nio'::text THEN 'já é cliente Nio'::text
                                    ELSE 'sem contato'::text
                                END) || ') · responder'::text
                                ELSE 'Cliente escreveu · responder'::text
                            END
                            ELSE NULL::text
                        END AS alerta_txt,
                        CASE
                            WHEN cv.bloq_id IS NOT NULL THEN cv.bloq_em
                            WHEN cv.sem_resp_min IS NOT NULL THEN cv.sem_resp_desde
                            WHEN cv.alerta IS NOT NULL THEN cv.alerta_em
                            WHEN cv.conv_status = 'handoff_realizado'::text AND (cv.handoff_motivo = ANY (ARRAY['recusa_compra'::text, 'sem_cobertura'::text, 'fora_de_area'::text, 'ja_cliente_nio'::text, 'sem_contato'::text])) THEN cv.ult_lead
                            WHEN cv.conv_status = 'handoff_realizado'::text AND COALESCE(cv.ult_humano, '-infinity'::timestamp with time zone) < COALESCE(cv.handoff_em, '-infinity'::timestamp with time zone) THEN cv.handoff_em
                            ELSE cv.ult_lead
                        END AS alerta_desde,
                        CASE
                            WHEN cv.nao_contatar THEN NULL::text
                            WHEN cv.chatwoot_agente IS NOT NULL THEN 'pessoa'::text
                            WHEN cv.humano_atribuido THEN 'pessoa'::text
                            WHEN cv.chatwoot_status = 'resolved'::text THEN NULL::text
                            WHEN cv.chatwoot_time IS NOT NULL THEN 'time'::text
                            ELSE 'mari'::text
                        END AS dono_tipo,
                        CASE
                            WHEN cv.nao_contatar THEN NULL::text
                            WHEN cv.chatwoot_agente IS NOT NULL THEN cv.chatwoot_agente
                            WHEN cv.humano_atribuido THEN 'time (assumida)'::text
                            WHEN cv.chatwoot_status = 'resolved'::text THEN NULL::text
                            WHEN cv.chatwoot_time IS NOT NULL THEN 'time '::text || cv.chatwoot_time
                            ELSE 'Mari'::text
                        END AS dono_nome
                   FROM conv cv
                ), vend AS (
                 SELECT v.id,
                    v.criado_em,
                    v.criado_por,
                    v.status,
                    v.motivo_saida,
                    v.interesse_futuro_em,
                    v.origem,
                    v.origem_ref,
                    v.cliente_nome,
                    v.cliente_cpf_cnpj,
                    v.cliente_whatsapp,
                    v.cliente_email,
                    v.segmento,
                    v.cep,
                    v.logradouro,
                    v.numero,
                    v.complemento,
                    v.bairro,
                    v.cidade,
                    v.uf,
                    v.plano_id,
                    v.forma_pagamento,
                    v.vencimento_dia,
                    v.comissao_prevista,
                    v.comissao_paga,
                    v.ciclo_pago,
                    v.estorno_previsto,
                    v.nio_pedido,
                    v.nio_contrato,
                    v.nio_situacao,
                    v.nio_pendencia_cod,
                    v.nio_pendencia_desc,
                    v.biometria_status,
                    v.biometria_em,
                    v.vendido_em,
                    v.agendamento_registrado_em,
                    v.instalacao_agendada_para,
                    v.instalado_em,
                    v.ativado_em,
                    v.docs_entregues_em,
                    v.vendedor_id,
                    v.trava_cobertura,
                    v.trava_area,
                    v.trava_sem_produto_ativo,
                    v.trava_sem_cancelamento_30d,
                    v.trava_cpf_valido,
                    v.trava_contato_confirmado,
                    v.nio_osab_em,
                    v.nio_venda_valida,
                    v.valor_mensal,
                    v.comissao_nominal,
                    v.comissao_adicionais,
                    v.bonus_transicao_previsto,
                    v.bonus_nmei_previsto,
                    v.bonus_m10_potencial,
                    v.primeiro_vencimento,
                    v.dfv_viabilidade,
                    v.dfv_consultado_em,
                    v.dfv_consultado_por,
                    v.dfv_faixa_credito,
                    v.dfv_classificacao,
                    v.dfv_hp_livre,
                    v.dfv_hcs,
                    v.dfv_dispensado,
                    v.dfv_dispensa_motivo,
                    v.dfv_origem,
                    v.dfv_resultado,
                    v.dfv_particao,
                    v.observacoes,
                    v.nio_viab_resultado,
                    v.nio_viab_velocidade,
                    v.nio_viab_interesse_id,
                    v.nio_viab_endereco_id,
                    v.nio_viab_em,
                    v.nio_viab_origem,
                    v.credito_resultado,
                    v.credito_em,
                    v.biometria_link,
                    v.biometria_link_enviado_em,
                    v.biometria_validada_em,
                    v.instalacao_preferencia,
                    v.instalacao_turno,
                    v.nio_viab_endereco_portal,
                    v.nio_pedido_em,
                    v.parceiro_id,
                    v.conferencia_status,
                    v.conferencia_motivo,
                    v.conferencia_obs,
                    v.conferencia_em,
                    v.conferencia_por,
                    v.conferencia_prazo_ate,
                    v.nio_viab_por,
                    v.ponto_referencia,
                    v.nio_os,
                    v.nio_os_em,
                    jornada_etapa(v.status, v.nio_pedido, v.credito_resultado) AS etapa,
                    p.nome_curto AS plano_curto,
                    u.nome AS vendedor_nome,
                    pe.id AS pend_id,
                    pe.revisar_em AS pend_revisar,
                    pe.aberta_em AS pend_desde,
                    pm.nome AS pend_nome,
                        CASE pe.quem_destrava
                            WHEN 'nio'::text THEN 'Nio'::text
                            WHEN 'rogerio'::text THEN 'Rogério'::text
                            WHEN 'cliente'::text THEN 'cliente'::text
                            ELSE 'nosso time'::text
                        END AS pend_quem,
                    s.id AS conv_id,
                    s.chatwoot_conversation_id AS cw_id,
                    s.alerta_txt,
                    s.alerta_desde,
                    s.bloq_id,
                    s.dono_tipo AS conv_dono_tipo,
                    s.dono_nome AS conv_dono_nome,
                    s.id IS NOT NULL AND COALESCE(s.chatwoot_conversation_id, ''::text) <> ''::text AND COALESCE(s.dono_tipo, 'mari'::text) = 'mari'::text AND NOT s.nao_contatar AS sem_dono,
                    COALESCE(v.nio_viab_resultado = 'viavel'::text, false) AS viab_ok
                   FROM vendas v
                     LEFT JOIN config_planos p ON p.id = v.plano_id
                     LEFT JOIN usuarios u ON u.id = v.vendedor_id
                     LEFT JOIN venda_pendencias pe ON pe.venda_id = v.id AND pe.encerrada_em IS NULL
                     LEFT JOIN config_motivos_pendencia pm ON pm.codigo = pe.motivo
                     LEFT JOIN LATERAL ( SELECT x_1.id,
                            x_1.venda_id,
                            x_1.nome,
                            x_1.cidade,
                            x_1.origem,
                            x_1.plano_nome,
                            x_1.coluna,
                            x_1.itens_total,
                            x_1.itens_validados,
                            x_1.chatwoot_conversation_id,
                            x_1.ultima_em,
                            x_1.janela_24h_fecha_em,
                            x_1.contatos_hoje,
                            x_1.contatos_mes,
                            x_1.chatwoot_agente,
                            x_1.chatwoot_time,
                            x_1.chatwoot_status,
                            x_1.humano_atribuido,
                            x_1.nao_contatar,
                            x_1.conv_status,
                            x_1.handoff_motivo,
                            x_1.handoff_em,
                            x_1.ult_lead,
                            x_1.ult_resp,
                            x_1.ult_humano,
                            x_1.sem_resp_min,
                            x_1.sem_resp_desde,
                            x_1.alerta,
                            x_1.alerta_em,
                            x_1.bloq_id,
                            x_1.bloq_motivo,
                            x_1.bloq_em,
                            x_1.alerta_txt,
                            x_1.alerta_desde,
                            x_1.dono_tipo,
                            x_1.dono_nome
                           FROM sinal x_1
                          WHERE x_1.venda_id = v.id
                          ORDER BY x_1.ultima_em DESC NULLS LAST
                         LIMIT 1) s ON true
                ), vr AS (
                 SELECT vd.id,
                    vd.criado_em,
                    vd.criado_por,
                    vd.status,
                    vd.motivo_saida,
                    vd.interesse_futuro_em,
                    vd.origem,
                    vd.origem_ref,
                    vd.cliente_nome,
                    vd.cliente_cpf_cnpj,
                    vd.cliente_whatsapp,
                    vd.cliente_email,
                    vd.segmento,
                    vd.cep,
                    vd.logradouro,
                    vd.numero,
                    vd.complemento,
                    vd.bairro,
                    vd.cidade,
                    vd.uf,
                    vd.plano_id,
                    vd.forma_pagamento,
                    vd.vencimento_dia,
                    vd.comissao_prevista,
                    vd.comissao_paga,
                    vd.ciclo_pago,
                    vd.estorno_previsto,
                    vd.nio_pedido,
                    vd.nio_contrato,
                    vd.nio_situacao,
                    vd.nio_pendencia_cod,
                    vd.nio_pendencia_desc,
                    vd.biometria_status,
                    vd.biometria_em,
                    vd.vendido_em,
                    vd.agendamento_registrado_em,
                    vd.instalacao_agendada_para,
                    vd.instalado_em,
                    vd.ativado_em,
                    vd.docs_entregues_em,
                    vd.vendedor_id,
                    vd.trava_cobertura,
                    vd.trava_area,
                    vd.trava_sem_produto_ativo,
                    vd.trava_sem_cancelamento_30d,
                    vd.trava_cpf_valido,
                    vd.trava_contato_confirmado,
                    vd.nio_osab_em,
                    vd.nio_venda_valida,
                    vd.valor_mensal,
                    vd.comissao_nominal,
                    vd.comissao_adicionais,
                    vd.bonus_transicao_previsto,
                    vd.bonus_nmei_previsto,
                    vd.bonus_m10_potencial,
                    vd.primeiro_vencimento,
                    vd.dfv_viabilidade,
                    vd.dfv_consultado_em,
                    vd.dfv_consultado_por,
                    vd.dfv_faixa_credito,
                    vd.dfv_classificacao,
                    vd.dfv_hp_livre,
                    vd.dfv_hcs,
                    vd.dfv_dispensado,
                    vd.dfv_dispensa_motivo,
                    vd.dfv_origem,
                    vd.dfv_resultado,
                    vd.dfv_particao,
                    vd.observacoes,
                    vd.nio_viab_resultado,
                    vd.nio_viab_velocidade,
                    vd.nio_viab_interesse_id,
                    vd.nio_viab_endereco_id,
                    vd.nio_viab_em,
                    vd.nio_viab_origem,
                    vd.credito_resultado,
                    vd.credito_em,
                    vd.biometria_link,
                    vd.biometria_link_enviado_em,
                    vd.biometria_validada_em,
                    vd.instalacao_preferencia,
                    vd.instalacao_turno,
                    vd.nio_viab_endereco_portal,
                    vd.nio_pedido_em,
                    vd.parceiro_id,
                    vd.conferencia_status,
                    vd.conferencia_motivo,
                    vd.conferencia_obs,
                    vd.conferencia_em,
                    vd.conferencia_por,
                    vd.conferencia_prazo_ate,
                    vd.nio_viab_por,
                    vd.ponto_referencia,
                    vd.nio_os,
                    vd.nio_os_em,
                    vd.etapa,
                    vd.plano_curto,
                    vd.vendedor_nome,
                    vd.pend_id,
                    vd.pend_revisar,
                    vd.pend_desde,
                    vd.pend_nome,
                    vd.pend_quem,
                    vd.conv_id,
                    vd.cw_id,
                    vd.alerta_txt,
                    vd.alerta_desde,
                    vd.bloq_id,
                    vd.conv_dono_tipo,
                    vd.conv_dono_nome,
                    vd.sem_dono,
                    vd.viab_ok,
                    cfg.d_docs,
                        CASE
                            WHEN vd.status = 'saida'::text THEN jsonb_build_array('fora', COALESCE(vd.motivo_saida, 'Saída'::text) || COALESCE(' · volta '::text || to_char(vd.interesse_futuro_em::timestamp with time zone, 'DD/MM'::text), ''::text), NULL::unknown, NULL::unknown)
                            WHEN vd.alerta_txt IS NOT NULL THEN jsonb_build_array('agora', vd.alerta_txt,
                            CASE
                                WHEN vd.bloq_id IS NOT NULL THEN 'manual'::text
                                WHEN vd.sem_dono THEN 'assumir'::text
                                ELSE 'responder'::text
                            END, vd.alerta_desde)
                            WHEN vd.pend_id IS NOT NULL AND vd.pend_revisar <= cfg.hoje THEN jsonb_build_array('agora', (('⏰ Revisar hoje: '::text || COALESCE(vd.pend_nome, 'pendência'::text)) || ' · '::text) || vd.pend_quem, 'pendencia', vd.pend_desde)
                            WHEN vd.pend_id IS NOT NULL THEN jsonb_build_array('espera', (((('⏸ Aguardando '::text || vd.pend_quem) || ' · '::text) || COALESCE(vd.pend_nome, 'pendência'::text)) || ' · revisar '::text) || to_char(vd.pend_revisar::timestamp with time zone, 'DD/MM'::text), 'pendencia', vd.pend_desde)
                            WHEN vd.nio_venda_valida = false THEN jsonb_build_array('agora', 'A Nio marcou a venda como inválida · avisar o Ricardo', 'abrir', vd.nio_osab_em)
                            WHEN vd.etapa = 2 AND vd.origem = 'parceiro_pap'::text AND vd.conferencia_status = 'pendente'::text THEN jsonb_build_array(
                            CASE
                                WHEN vd.conferencia_prazo_ate < now() THEN 'agora'::text
                                ELSE 'hoje'::text
                            END, 'Conferir a venda do parceiro', 'conferencia', vd.criado_em)
                            WHEN vd.etapa = 2 AND vd.origem = 'parceiro_pap'::text AND (vd.conferencia_status = ANY (ARRAY['devolvida'::text, 'reprovada'::text])) THEN jsonb_build_array('espera',
                            CASE vd.conferencia_status
                                WHEN 'devolvida'::text THEN 'Devolvida ao parceiro · esperando correção'::text
                                ELSE 'Reprovada na conferência'::text
                            END, 'abrir', vd.criado_em)
                            WHEN vd.etapa = 2 AND vd.credito_resultado = 'negado'::text THEN jsonb_build_array('agora', 'Crédito negado · pedir outro CPF (pendência) ou encerrar', 'abrir', vd.credito_em)
                            WHEN vd.etapa = 2 AND NOT vd.viab_ok THEN jsonb_build_array('hoje',
                            CASE
                                WHEN vd.nio_viab_resultado = ANY (ARRAY['sem_viabilidade'::text, 'nao_encontrado'::text, 'posse'::text]) THEN ('Portal: '::text ||
                                CASE vd.nio_viab_resultado
                                    WHEN 'sem_viabilidade'::text THEN 'sem viabilidade'::text
                                    WHEN 'nao_encontrado'::text THEN 'endereço não encontrado'::text
                                    ELSE 'endereço já tem Nio'::text
                                END) || ' · conferir no DFV: endereço viável a até 200 m → formulário da Nio + pendência'::text
                                                                ELSE 'Consultar a viabilidade no portal'::text
                            END,
                            CASE
                                WHEN vd.sem_dono THEN 'assumir'::text
                                ELSE 'viabilidade'::text
                            END, vd.criado_em)
                            WHEN vd.etapa = 2 AND vd.credito_resultado = 'pendente'::text THEN jsonb_build_array('hoje', 'Crédito pendente na Nio · conferir no portal e gravar o resultado',
                            CASE
                                WHEN vd.sem_dono THEN 'assumir'::text
                                ELSE 'credito'::text
                            END, COALESCE(vd.credito_em, vd.nio_viab_em, vd.criado_em))
                            WHEN vd.etapa = 2 THEN jsonb_build_array('hoje', 'Viável · rodar o crédito no portal e gravar o resultado',
                            CASE
                                WHEN vd.sem_dono THEN 'assumir'::text
                                ELSE 'credito'::text
                            END, COALESCE(vd.nio_viab_em, vd.criado_em))
                            WHEN vd.etapa = 3 AND vd.credito_resultado = 'negado'::text THEN jsonb_build_array('agora', 'Crédito negado · pedir outro CPF (pendência) ou encerrar', 'biometria', vd.credito_em)
                            WHEN vd.etapa = 3 AND vd.biometria_status = 'com_risco'::text THEN jsonb_build_array('hoje', 'Biometria com risco · conferir no portal', 'biometria', COALESCE(vd.biometria_em, vd.credito_em, vd.criado_em))
                            WHEN vd.etapa = 3 AND vd.biometria_status = 'pendente'::text THEN jsonb_build_array(
                            CASE
                                WHEN COALESCE(vd.biometria_link_enviado_em, vd.credito_em, vd.criado_em) < (now() - '72:00:00'::interval) THEN 'agora'::text
                                WHEN COALESCE(vd.biometria_link_enviado_em, vd.credito_em, vd.criado_em) < (now() - '24:00:00'::interval) THEN 'hoje'::text
                                ELSE 'espera'::text
                            END, ('Crédito aprovado · esperando a biometria do cliente · link da Nio há '::text || _h_txt(COALESCE(vd.biometria_link_enviado_em, vd.credito_em, vd.criado_em))) || ' · a OS vem depois da biometria aprovada'::text, 'biometria', COALESCE(vd.biometria_link_enviado_em, vd.credito_em, vd.criado_em))
                            WHEN vd.etapa = 3 AND (COALESCE(vd.biometria_status, ''::text) <> ALL (ARRAY['validada'::text, 'dispensada'::text])) THEN jsonb_build_array(
                            CASE
                                WHEN COALESCE(vd.credito_em, vd.nio_pedido_em, vd.criado_em) < (now() - '02:00:00'::interval) THEN 'agora'::text
                                ELSE 'hoje'::text
                            END, 'Crédito aprovado · no portal, Continuar manda a biometria ao cliente · a OS vem depois da biometria aprovada'::text, 'abrir', COALESCE(vd.credito_em, vd.nio_pedido_em, vd.criado_em))
                            WHEN vd.etapa = 3 THEN jsonb_build_array(
                            CASE
                                WHEN COALESCE(vd.credito_em, vd.nio_pedido_em, vd.criado_em) < (now() - '02:00:00'::interval) THEN 'agora'::text
                                ELSE 'hoje'::text
                            END, 'Biometria aprovada · no portal: forma de pagamento, agenda e OS · gravar a OS e a data'::text, 'os', COALESCE(vd.credito_em, vd.nio_pedido_em, vd.criado_em))
                            WHEN vd.etapa = 4 AND vd.instalacao_agendada_para IS NULL THEN jsonb_build_array('agora', 'OS aberta sem data · gravar a agenda do portal · há '::text || _h_txt(COALESCE(vd.biometria_validada_em, vd.vendido_em)), 'agendar', COALESCE(vd.biometria_validada_em, vd.vendido_em))
                            WHEN vd.etapa = 4 AND (vd.nio_pendencia_cod IS NOT NULL OR vd.nio_pendencia_desc IS NOT NULL) THEN jsonb_build_array('hoje', "left"('Pendência Nio · '::text || concat_ws(' · '::text, vd.nio_pendencia_cod, vd.nio_pendencia_desc), 90) || ' · reagendar'::text, 'agendar', COALESCE(vd.nio_osab_em, vd.agendamento_registrado_em))
                            WHEN vd.etapa = 4 AND vd.biometria_status = 'com_risco'::text THEN jsonb_build_array('hoje', 'Biometria com risco · conferir no portal', 'biometria', vd.biometria_em)
                            WHEN vd.etapa = 4 AND vd.biometria_status = 'pendente'::text AND (EXISTS ( SELECT 1
                               FROM biometria_quedas q
                              WHERE q.fim IS NULL)) THEN jsonb_build_array('hoje', 'Biometria da Nio fora do ar · pedir à Nio a dispensa e marcar "Nio dispensou" na ficha'::text, 'biometria', COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em))
                            WHEN vd.etapa = 4 AND vd.biometria_status = 'pendente'::text AND (EXISTS ( SELECT 1
                               FROM biometria_quedas q
                              WHERE q.fim IS NOT NULL AND q.fim > (now() - '48:00:00'::interval) AND COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em) < q.fim)) THEN jsonb_build_array('agora', ('A biometria da Nio voltou · cliente esperando há '::text || _h_txt(COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em))) || ' · conferir o link (pedir novo se expirou) e falar com ele'::text, 'biometria', COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em))
                            WHEN vd.etapa = 4 AND vd.biometria_status = 'pendente'::text AND COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em) < (now() - '72:00:00'::interval) THEN jsonb_build_array('agora', ('Biometria pendente há '::text || _h_txt(COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em))) || ' · ligar para o cliente'::text, 'biometria', COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em))
                            WHEN vd.etapa = 4 AND vd.biometria_status = 'pendente'::text AND COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em) < (now() - '24:00:00'::interval) THEN jsonb_build_array('hoje', ('Biometria pendente há '::text || _h_txt(COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em))) || ' · a Mari lembrou; consultar e falar com o cliente'::text, 'biometria', COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em))
                            WHEN vd.etapa = 4 AND vd.biometria_status = 'pendente'::text THEN jsonb_build_array('espera', 'Esperando a biometria do cliente · link da Nio há '::text || _h_txt(COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em)), 'biometria', COALESCE(vd.biometria_link_enviado_em, vd.nio_os_em, vd.vendido_em))
                            WHEN vd.etapa = 4 AND vd.forma_pagamento = 'cartao'::text AND vd.biometria_status = 'validada'::text AND NOT (EXISTS ( SELECT 1
                               FROM os_andamento oa
                              WHERE oa.venda_id = vd.id AND oa.estado IS NOT NULL AND oa.estado <> 'aguardando_pagamento'::text AND oa.mudou_em > vd.biometria_validada_em)) AND (vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text)::date < cfg.hoje THEN jsonb_build_array('agora', ('Visita de '::text || to_char((vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text)) || ' não aconteceu: cartão não cadastrado · falar com o cliente e reagendar no portal'::text, 'cartao', vd.instalacao_agendada_para)
                            WHEN vd.etapa = 4 AND vd.forma_pagamento = 'cartao'::text AND vd.biometria_status = 'validada'::text AND NOT (EXISTS ( SELECT 1
                               FROM os_andamento oa
                              WHERE oa.venda_id = vd.id AND oa.estado IS NOT NULL AND oa.estado <> 'aguardando_pagamento'::text AND oa.mudou_em > vd.biometria_validada_em)) AND (vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text)::date = cfg.hoje THEN jsonb_build_array('agora', 'Visita HOJE e o cartão não foi cadastrado · ligar agora: sem o cadastro no link da Nio não há instalação'::text, 'cartao', vd.biometria_validada_em)
                            WHEN vd.etapa = 4 AND vd.forma_pagamento = 'cartao'::text AND vd.biometria_status = 'validada'::text AND NOT (EXISTS ( SELECT 1
                               FROM os_andamento oa
                              WHERE oa.venda_id = vd.id AND oa.estado IS NOT NULL AND oa.estado <> 'aguardando_pagamento'::text AND oa.mudou_em > vd.biometria_validada_em)) AND vd.biometria_validada_em < (now() - '48:00:00'::interval) THEN jsonb_build_array('agora', ('Cartão sem cadastro há '::text || _h_txt(vd.biometria_validada_em)) || ' · ligar: sem o cadastro no link da Nio não há instalação'::text, 'cartao', vd.biometria_validada_em)
                            WHEN vd.etapa = 4 AND vd.forma_pagamento = 'cartao'::text AND vd.biometria_status = 'validada'::text AND NOT (EXISTS ( SELECT 1
                               FROM os_andamento oa
                              WHERE oa.venda_id = vd.id AND oa.estado IS NOT NULL AND oa.estado <> 'aguardando_pagamento'::text AND oa.mudou_em > vd.biometria_validada_em)) AND (vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text)::date <= (cfg.hoje + 1) THEN jsonb_build_array('hoje', ('Visita amanhã ('::text || to_char((vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text)) || ') e o cartão não foi cadastrado · falar com o cliente: sem o cadastro a Nio não instala'::text, 'cartao', vd.biometria_validada_em)
                            WHEN vd.etapa = 4 AND vd.forma_pagamento = 'cartao'::text AND vd.biometria_status = 'validada'::text AND NOT (EXISTS ( SELECT 1
                               FROM os_andamento oa
                              WHERE oa.venda_id = vd.id AND oa.estado IS NOT NULL AND oa.estado <> 'aguardando_pagamento'::text AND oa.mudou_em > vd.biometria_validada_em)) THEN jsonb_build_array('espera', ('Biometria aprovada · esperando o cliente cadastrar o cartão no link da Nio (visita '::text || to_char((vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text)) || ' depende disso; a Mari avisou)'::text, 'cartao', vd.biometria_validada_em)
                            WHEN vd.etapa = 4 AND (vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text)::date < cfg.hoje THEN jsonb_build_array('hoje', ('Instalação era '::text || to_char((vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text)) || ' e a Nio não deu baixa · conferir no portal'::text, 'agendar', vd.instalacao_agendada_para)
                            WHEN vd.etapa = 4 THEN jsonb_build_array('espera', (('Instalação '::text || to_char((vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text)) ||
                            CASE
                                WHEN COALESCE(vd.instalacao_turno, ''::text) = 'tarde'::text OR EXTRACT(hour FROM (vd.instalacao_agendada_para AT TIME ZONE 'America/Sao_Paulo'::text)) >= 12::numeric THEN ' à tarde'::text
                                ELSE ' de manhã'::text
                            END) || ' · com a Nio'::text, 'agendar', vd.agendamento_registrado_em)
                            WHEN vd.etapa = 5 AND vd.status = '3_instalado'::text AND vd.docs_entregues_em IS NULL AND vd.instalado_em IS NOT NULL THEN jsonb_build_array(
                            CASE
                                WHEN (vd.instalado_em + make_interval(days => cfg.d_docs)) < now() THEN 'agora'::text
                                ELSE 'hoje'::text
                            END, ((('Documentos à Nio · prazo '::text || to_char(((vd.instalado_em + make_interval(days => cfg.d_docs)) AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text)) || ' ('::text) || cfg.d_docs) || ' dias)'::text, 'docs', vd.instalado_em)
                            ELSE jsonb_build_array('ok', 'Instalada · conta na meta', 'abrir', COALESCE(vd.ativado_em, vd.instalado_em))
                        END AS r
                   FROM vend vd
                     CROSS JOIN cfg
                )
         SELECT 'venda'::text AS tipo,
            vr.id::text AS chave,
            vr.id AS venda_id,
            vr.conv_id AS conversa_id,
            vr.cw_id AS chatwoot_conversation_id,
            vr.cliente_nome AS nome,
            vr.cidade,
            COALESCE(vr.plano_curto, ''::text) AS plano,
            vr.origem,
            vr.etapa,
            jornada_nome(vr.etapa) AS etapa_nome,
            (vr.r ->> 0) = ANY (ARRAY['agora'::text, 'hoje'::text]) AS precisa_acao,
            vr.r ->> 0 AS nivel,
            vr.r ->> 1 AS o_que_fazer,
            vr.r ->> 2 AS botao,
            NULLIF(vr.r ->> 3, ''::text)::timestamp with time zone AS desde,
            COALESCE(vr.conv_dono_tipo,
                CASE
                    WHEN vr.vendedor_id IS NOT NULL THEN 'pessoa'::text
                    ELSE NULL::text
                END) AS dono_tipo,
            COALESCE(vr.conv_dono_nome, vr.vendedor_nome) AS dono_nome,
            vr.pend_id IS NOT NULL AS pendencia,
            vr.bloq_id AS acao_id,
            vr.status AS status_venda,
            'dharma'::text AS parceiro_id
           FROM vr
        UNION ALL
         SELECT 'conversa'::text AS tipo,
            'c:'::text || s.id::text AS chave,
            NULL::uuid AS venda_id,
            s.id AS conversa_id,
            s.chatwoot_conversation_id,
            COALESCE(NULLIF(initcap(split_part(btrim(COALESCE(s.nome, ''::text)), ' '::text, 1)), ''::text), 'Contato'::text) AS nome,
            s.cidade,
            COALESCE(s.plano_nome, ''::text) AS plano,
            s.origem,
            1 AS etapa,
            jornada_nome(1) AS etapa_nome,
                CASE
                    WHEN e.ativa AND e.espera_ate > now() AND s.bloq_id IS NULL THEN false
                    WHEN e.ativa AND e.espera_ate <= now() THEN true
                    ELSE s.alerta_txt IS NOT NULL OR s.coluna = 'completo'::text
                END AS precisa_acao,
                CASE
                    WHEN e.ativa AND e.espera_ate > now() AND s.bloq_id IS NULL THEN 'espera'::text
                    WHEN e.ativa AND e.espera_ate <= now() THEN 'hoje'::text
                    WHEN s.alerta_txt IS NOT NULL OR s.coluna = 'completo'::text THEN 'agora'::text
                    ELSE 'espera'::text
                END AS nivel,
                CASE
                    WHEN e.ativa AND e.espera_ate > now() AND s.bloq_id IS NULL THEN (('⏸ Aguardando · '::text || COALESCE(e.espera_motivo, 'cliente'::text)) || ' · até '::text) || to_char((e.espera_ate AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text)
                    WHEN e.ativa AND e.espera_ate <= now() THEN ((('Retomar · '::text || COALESCE(e.espera_motivo, 'cliente'::text)) || ' (combinado para '::text) || to_char((e.espera_ate AT TIME ZONE 'America/Sao_Paulo'::text), 'DD/MM'::text)) || ')'::text
                    WHEN s.alerta_txt IS NOT NULL THEN s.alerta_txt
                    WHEN s.coluna = 'completo'::text THEN 'Dados completos e a venda não nasceu · ver o erro na tela Mari'::text
                    WHEN s.dono_tipo = ANY (ARRAY['pessoa'::text, 'time'::text]) THEN ('Com '::text || s.dono_nome) || ' · esperando o cliente'::text
                    ELSE ((('Mari atendendo · '::text || COALESCE(s.itens_validados, 0::bigint)) || '/'::text) || COALESCE(s.itens_total, 0::bigint)) || ' dados'::text
                END AS o_que_fazer,
                CASE
                    WHEN s.bloq_id IS NOT NULL THEN 'manual'::text
                    WHEN s.dono_tipo = 'mari'::text OR s.dono_tipo IS NULL THEN 'assumir'::text
                    ELSE 'responder'::text
                END AS botao,
                CASE
                    WHEN e.ativa AND e.espera_ate > now() AND s.bloq_id IS NULL OR e.ativa AND e.espera_ate <= now() THEN e.espera_ate
                    WHEN s.alerta_txt IS NOT NULL THEN s.alerta_desde
                    WHEN s.coluna = 'completo'::text THEN s.handoff_em
                    ELSE s.ultima_em
                END AS desde,
            s.dono_tipo,
            s.dono_nome,
            COALESCE(e.ativa AND e.espera_ate > now() AND s.bloq_id IS NULL, false) AS pendencia,
            s.bloq_id AS acao_id,
            NULL::text AS status_venda,
            'dharma'::text AS parceiro_id
           FROM sinal s
             LEFT JOIN LATERAL ( SELECT me.espera_ate,
                    me.espera_motivo,
                    me.espera_ate IS NOT NULL AND COALESCE(s.ult_lead, '-infinity'::timestamp with time zone) <= me.espera_em AS ativa
                   FROM mari_conversas me
                  WHERE me.id = s.id) e ON true
          WHERE s.venda_id IS NULL AND s.coluna <> 'encerrada'::text) j
     LEFT JOIN mari_conversas c ON c.id = j.conversa_id
     LEFT JOIN vendas vv ON vv.id = j.venda_id
     CROSS JOIN LATERAL ( SELECT
                CASE
                    WHEN c.handoff_em IS NOT NULL AND c.handoff_em > (now() - '30 days'::interval) AND (c.status = 'handoff_realizado'::text OR j.venda_id IS NOT NULL) AND (COALESCE(c.handoff_motivo, ''::text) <> ALL (ARRAY['recusa_compra'::text, 'sem_cobertura'::text, 'fora_de_area'::text, 'sem_contato'::text, 'ja_cliente_nio'::text])) AND COALESCE(j.dono_tipo, 'mari'::text) <> 'pessoa'::text AND NOT COALESCE(c.nao_contatar, false) AND (j.nivel <> ALL (ARRAY['ok'::text, 'fora'::text])) AND NOT j.pendencia AND COALESCE(j.status_venda, ''::text) <> 'saida'::text THEN minutos_uteis(c.handoff_em, now(), c.cidade)
                    ELSE NULL::integer
                END AS min,
            c.handoff_em,
            COALESCE(vv.nio_pedido, ''::text) ~~* 'PROV-%'::text AS prov,
            vv.nio_pedido AS pedido,
            COALESCE(vv.nio_pedido_em, vv.criado_em) AS pedido_em) y
     CROSS JOIN LATERAL ( SELECT q.conf_desde,
                CASE
                    WHEN q.conf_desde IS NOT NULL THEN minutos_uteis(q.conf_desde, now(), c.cidade)
                    ELSE NULL::integer
                END AS conf_min
           FROM ( SELECT
                        CASE
                            WHEN c.id IS NOT NULL AND (c.status = 'handoff_realizado'::text OR COALESCE(c.humano_atribuido, false) OR c.chatwoot_agente IS NOT NULL) AND NOT COALESCE(c.nao_contatar, false) AND NOT j.pendencia AND (j.nivel <> ALL (ARRAY['ok'::text, 'fora'::text])) AND COALESCE(j.status_venda, ''::text) <> 'saida'::text THEN cliente_confirmou_desde(c.id, NULL::timestamp with time zone)
                            ELSE NULL::timestamp with time zone
                        END AS conf_desde) q) z
     CROSS JOIN LATERAL ( SELECT COALESCE(y.min, 0) > 30 AS furo,
            COALESCE(y.prov AND COALESCE(j.status_venda, ''::text) <> 'saida'::text AND y.pedido_em < (now() - '24:00:00'::interval), false) AS prov_vencido,
            z.conf_desde IS NOT NULL AS confirmou,
            COALESCE(z.conf_desde IS NOT NULL AND NOT j.precisa_acao AND z.conf_min >= COALESCE(( SELECT (config_regras.valor #>> '{}'::text[])::integer AS int4
                   FROM config_regras
                  WHERE config_regras.chave = 'confirmacao_retorno_min'::text), 240), false) AS conf_vencida) x;

commit;

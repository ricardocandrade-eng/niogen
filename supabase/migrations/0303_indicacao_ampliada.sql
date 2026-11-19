-- NIOGEN | supabase/migrations/0303_indicacao_ampliada.sql | 18/11/2026 — Claude Code (Opus 5.5)
-- Prompt docs/Prompt_medidor_canais_indicacao_181126_2155.md, parte B (Dia 1 do projeto "1 canal por dia"): indicação é o canal
-- que é só código. Até aqui só o cliente instalado era convidado a indicar (0176). Agora:
--  (1) Quem NÃO comprou porque a Nio não chega: a Saída "Fachada não atendida" / "Cidade não atendida" já avisa o cliente na hora
--      (0279). O pedido de indicação vai DENTRO dessa mesma mensagem (texto saida_sem_cobertura_indicacao) — nenhum toque novo
--      (regra de ouro 6). Se o cliente responder com nome e WhatsApp, a indicação é anotada (indicacoes, sem venda de quem indicou),
--      ele recebe o "Anotado, obrigada!" e a Mari abre a conversa do indicado como já faz (origem indicacao).
--      Crédito negado (Ricardo, 18/11 ~23h: "pode incluir o crédito negado também"): a Saída, que não mandava nada, passa a avisar com
--      educação e pedir indicação na mesma mensagem (saida_credito_indicacao), só para quem pode receber o pedido.
--  (2) Varredura da base instalada: 1 toque por cliente, só quem instalou há ≥ 60 dias e não recebeu pedido de indicação nos
--      últimos 60; horário 6h–0h (mari_no_horario), Não contatar e opt-out respeitados; liga/desliga em config_regras.indicacao
--      (varredura_ligada). Sai pelo template nio_indicacao_base, que só a Meta aprova — até aprovar, nada sai.
--  (3) Pix intocado: R$ 100, 10 dias depois da instalação do indicado, pago à mão pelo Ricardo; não vale indicar a si mesmo
--      (para quem não comprou, a trava confere o CPF e o endereço da conversa dele).
-- Nunca pede a quem está em luto ou urgência, Não contatar, cliente Nio, fraude ou teste (_ind_pode_pedir).
-- Regra 20: (1) nenhuma situação nova; o lead indicado nasce como qualquer lead da Mari · (2) pedido aberto fecha sozinho na
-- validade (7 dias) pela rotina indicacao_rotina · (3) o pedido é consequência da Saída, que passa pela porta; a tela não grava
-- nada · (4) conversa → NIOGEN; venda e instalação do indicado → a Nio · (5) item indicacao_pedidos na conferência (0302).
begin;


-- ───────────────────────── 1. tabelas, config e textos ─────────────────────────
alter table public.indicacoes alter column indicador_venda_id drop not null;   -- quem indicou pode não ter comprado (Saída sem cobertura)
alter table public.indicacoes add column if not exists pedido_id uuid;

create table if not exists public.indicacao_pedidos (
  id            uuid primary key default gen_random_uuid(),
  parceiro_id   text not null default 'dharma',
  conversa_id   uuid references public.mari_conversas (id) on delete set null,
  venda_id      uuid references public.vendas (id) on delete set null,
  motivo        text not null check (motivo in ('saida_sem_cobertura', 'saida_credito', 'varredura')),
  sub           text,                                   -- fachada_nao_atendida | cidade_nao_atendida | credito_negado
  estado        text not null default 'pediu' check (estado in ('pediu', 'recebeu', 'encerrada', 'sem_resposta', 'pulado')),
  pedido_em     timestamptz not null default now(),
  respondeu_em  timestamptz,
  insistencias  int not null default 0,
  tratado_em    timestamptz,                            -- = now() da transação em que a automação respondeu (o pós-venda não dispara)
  encerrada_em  timestamptz,
  resposta      text,
  criado_em     timestamptz not null default now()
);
create index if not exists indicacao_pedidos_conversa_idx on public.indicacao_pedidos (conversa_id) where estado = 'pediu';
create index if not exists indicacao_pedidos_venda_idx on public.indicacao_pedidos (venda_id, pedido_em);
comment on table public.indicacao_pedidos is
  'Pedido de indicação a quem não comprou (Saída sem cobertura) e da varredura da base instalada (0303). Escrita só pelas '
  'funções (_porta_sair, _porta_volta_sem_cobertura, indicacao_tick, gatilho mari_turnos_pos_instalacao). pulado = a varredura '
  'olhou e não pediu (sem conversa, Não contatar…), para não olhar de novo.';
alter table public.indicacao_pedidos enable row level security;
drop policy if exists indicacao_pedidos_ler on public.indicacao_pedidos;
create policy indicacao_pedidos_ler on public.indicacao_pedidos for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));
revoke all on public.indicacao_pedidos from anon, authenticated;
grant select on public.indicacao_pedidos to authenticated;
grant all on public.indicacao_pedidos to service_role;

update public.config_regras
   set valor = valor || jsonb_build_object('pedir_sem_compra', true, 'varredura_ligada', true, 'varredura_dias', 60, 'varredura_lote', 10)
 where chave = 'indicacao' and not (valor ? 'varredura_ligada');

insert into public.config_mari_textos (chave, texto) values
  ('saida_sem_cobertura_indicacao', 'Oi, {nome}! Conferimos no sistema da Nio e, infelizmente, a fibra ainda não chega no seu endereço — por isso não conseguimos abrir o pedido agora. Desculpe a espera 🙏 Se você tiver outro endereço para instalar, me manda o CEP e o número que a gente confere.

E se você conhece alguém num lugar onde a Nio já chega (um parente, um amigo de outro bairro, um colega), me passa o nome e o WhatsApp da pessoa. Se ela instalar a Nio, você ganha R$ 100 no Pix 😉')
on conflict (chave) do update set texto = excluded.texto;

-- Ricardo, 18/11 ~23h: "Sim, pode incluir o crédito negado também" — a Saída "Crédito negado" (que não mandava nada) passa a avisar
-- com educação e pedir indicação na mesma mensagem, só para quem pode receber o pedido (_ind_pode_pedir).
insert into public.config_mari_textos (chave, texto) values
  ('saida_credito_indicacao', 'Oi, {nome}! Infelizmente o sistema da Nio não aprovou o crédito para abrir o pedido agora — sinto muito 🙏 Se mais pra frente quiser tentar de novo, é só me chamar por aqui.

E se você conhece alguém que também quer internet fibra boa, me passa o nome e o WhatsApp da pessoa. Se ela instalar a Nio, você ganha R$ 100 no Pix 😉')
on conflict (chave) do update set texto = excluded.texto;

insert into public.config_templates_waba (nome, categoria, idioma, corpo, botoes, status, uso) values
  ('nio_indicacao_base', 'MARKETING', 'pt_BR',
   'Oi, {{1}}! Aqui é a Mari, da Nio 😊 Espero que a sua internet esteja ótima! Você conhece alguém que também quer internet fibra boa? Me manda o nome e o WhatsApp da pessoa por aqui. Se ela instalar a Nio, você ganha R$ 100 no Pix 🎉',
   '[]'::jsonb, 'PENDING', 'INDICACAO_BASE')
on conflict (nome) do nothing;

-- ───────────────────────── 2. miúdos ─────────────────────────
-- Pode pedir indicação a esta conversa? null = pode; senão o porquê.
create or replace function public._ind_pode_pedir(c public.mari_conversas)
returns text language sql stable security definer set search_path = public as $$
  select case
    when c.id is null then 'sem conversa'
    when not coalesce((public._ind_cfg() ->> 'ligado')::boolean, false) then 'indicação desligada'
    when coalesce(c.nao_contatar, false) then 'não contatar'
    when coalesce(c.telefone, '') like '5500000000%' or coalesce(c.origem, '') = 'teste' or coalesce(c.canal, '') <> 'whatsapp'
         or coalesce(c.funil_destino, '') = 'teste_duplicada' then 'teste'
    when coalesce(c.funil_destino, '') in ('ja_cliente_nio', 'ja_cliente') or coalesce(c.quadro_encerrada_motivo, '') = 'suporte_nio' then 'cliente Nio'
    when c.antifraude_situacao is not null or coalesce(c.saida_motivo, '') = 'venda_indevida_fraude'
         or exists (select 1 from public.vendas v where v.id = c.venda_id and coalesce(v.saida_motivo, '') = 'venda_indevida_fraude') then 'fraude'
    when exists (select 1 from public.mari_turnos t
                  where t.conversa_id = c.id and t.papel = 'lead' and t.created_at > now() - interval '30 days'
                    and public._ind_norm(t.texto) ~ '(falec|luto|velori|enterr|obito|morreu|urgen|emergen|hospital|internad|uti )') then 'luto ou urgência'
    else null end
$$;
revoke all on function public._ind_pode_pedir(public.mari_conversas) from public, anon, authenticated;

-- Tem um WhatsApp na fala? (≥ 10 dígitos seguidos, ou celular de 9 dígitos). Um CEP sozinho (8 dígitos) não conta.
create or replace function public._ind_tem_telefone(p_texto text)
returns boolean language sql immutable as $$
  select coalesce(p_texto, '') ~ '(\d[\s().-]{0,2}){10,}' or coalesce(p_texto, '') ~ '(?<!\d)9\d{4}[\s.-]?\d{4}(?!\d)'
$$;

-- Anota as indicações de uma fala (o miolo do gatilho da 0176, agora também para quem não comprou). Não manda mensagem.
create or replace function public._ind_receber(c public.mari_conversas, p_texto text, p_pos uuid, p_pedido uuid, p_venda uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  tels jsonb; e jsonb; v_nome text; v_ok int := 0; v_ja int := 0; v_nomes text[] := '{}';
  v_ddd text := substr(public._tel_chave(c.telefone), 1, 2);
begin
  tels := public._ind_telefones(p_texto, v_ddd);
  if jsonb_array_length(tels) = 0 then return jsonb_build_object('achou', 0, 'ok', 0, 'ja', 0); end if;
  v_nome := case when jsonb_array_length(tels) = 1 then public._ind_nome(p_texto) end;
  for e in select * from jsonb_array_elements(tels) loop
    if (e ->> 'chave') = public._tel_chave(c.telefone)
       or exists (select 1 from public.indicacoes x where x.tel_chave = e ->> 'chave' and x.estado <> 'invalida')
       or exists (select 1 from public.vendas v where public._tel_chave(v.cliente_whatsapp) = e ->> 'chave') then
      v_ja := v_ja + 1;
      continue;
    end if;
    insert into public.indicacoes (pos_instalacao_id, pedido_id, indicador_venda_id, indicador_conversa_id, indicado_nome, indicado_telefone,
                                   tel_chave, texto_original, conversa_id, estado, contatada_em, motivo)
    select p_pos, p_pedido, p_venda, c.id, v_nome, e ->> 'tel', e ->> 'chave', left(p_texto, 500), m.id,
           case when m.id is null then 'recebida' else 'contatada' end, case when m.id is null then null else now() end,
           case when m.id is null then null else 'já estava em atendimento com a Mari' end
      from (select 1) z
      left join lateral (select mc.id from public.mari_conversas mc
                          where public._tel_chave(mc.telefone) = e ->> 'chave' and mc.canal = 'whatsapp'
                            and mc.status in ('ativo', 'handoff_realizado') limit 1) m on true;
    v_ok := v_ok + 1;
    v_nomes := v_nomes || coalesce(public._ind_primeiro_nome(v_nome), 'a pessoa');
  end loop;
  return jsonb_build_object('achou', jsonb_array_length(tels), 'ok', v_ok, 'ja', v_ja,
                            'nome', case when v_ok = 1 then v_nomes[1] else 'cada uma dessas pessoas' end);
end $$;
revoke all on function public._ind_receber(public.mari_conversas, text, uuid, uuid, uuid) from public, anon, authenticated;

-- Resposta ao pedido feito no aviso da Saída (cobertura ou crédito): com um WhatsApp na fala, anota, agradece e a conversa volta a
-- fechar. Devolve null quando não tratou (sem pedido aberto ou sem telefone) — aí segue o caminho de sempre.
create or replace function public._ind_resposta_saida(c public.mari_conversas, p_texto text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare pe public.indicacao_pedidos; r jsonb; msg jsonb; feito text[] := '{}';
begin
  if not public._ind_tem_telefone(p_texto) then return null; end if;
  select * into pe from public.indicacao_pedidos x
   where x.conversa_id = c.id and x.motivo in ('saida_sem_cobertura', 'saida_credito') and x.estado = 'pediu'
     and x.pedido_em > now() - make_interval(days => coalesce((public._ind_cfg() ->> 'validade_resposta_dias')::int, 7))
   order by x.pedido_em desc limit 1 for update;
  if pe.id is null then return null; end if;
  r := public._ind_receber(c, p_texto, null, pe.id, c.venda_id);
  if coalesce((r ->> 'achou')::int, 0) = 0 then return null; end if;
  c.ultima_msg_lead_at := now();   -- a fala que chegou agora abre a janela de 24 h
  msg := public._bo_mensagem(gen_random_uuid(), 1, 'indicacao_obrigado', c.venda_id, c,
           case when (r ->> 'ok')::int > 0 then 'indicacao_obrigado' else 'indicacao_ja' end, jsonb_build_object('nome', r ->> 'nome'),
           null, null, 'indicação recebida (Saída)');
  update public.indicacao_pedidos set estado = 'recebeu', respondeu_em = now(), resposta = left(p_texto, 300), tratado_em = now() where id = pe.id;
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[cliente indicou ' || ((r ->> 'ok')::int) || ' pessoa(s) depois da Saída — a Mari agradeceu e fala com quem foi indicado]', false);
  feito := feito || ('indicação anotada: ' || (r ->> 'ok') || ' nova(s), ' || (r ->> 'ja') || ' já conhecida(s)')::text
           || public._porta_projetar(c.id, 'cliente_voltou', '🎁 O cliente (em Saída) indicou alguém. A Mari agradeceu e abre a conversa do indicado. Ninguém precisa responder.');
  if not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'resolver' and a.status in ('pendente', 'executando')) then
    perform public._bo_enfileirar(gen_random_uuid(), 1, 'refechar', c.venda_id, c, 'resolver', jsonb_build_object('status', 'resolved'),
                                  now() + interval '2 minutes');
  end if;
  return jsonb_build_object('ok', true, 'feito', to_jsonb(feito), 'resumo', '✓ ' || array_to_string(feito, ' · '));
end $$;
revoke all on function public._ind_resposta_saida(public.mari_conversas, text) from public, anon, authenticated;

-- Resposta ao pedido da varredura (cliente instalado). Chamada pelo gatilho mari_turnos_pos_instalacao quando não há pós-instalação aberta.
create or replace function public._ind_varredura_resposta(c public.mari_conversas, t public.mari_turnos)
returns void language plpgsql security definer set search_path = public as $$
declare pe public.indicacao_pedidos; r jsonb; v_t text; cfg jsonb := public._ind_cfg();
begin
  if not coalesce((cfg ->> 'ligado')::boolean, false) then return; end if;
  select * into pe from public.indicacao_pedidos x
   where x.conversa_id = c.id and x.motivo = 'varredura' and x.estado = 'pediu' order by x.pedido_em desc limit 1 for update;
  if pe.id is null then return; end if;
  c.ultima_msg_lead_at := now();   -- a fala que chegou agora abre a janela de 24 h
  v_t := public._ind_norm(t.texto);
  if public._ind_tem_telefone(t.texto) then
    r := public._ind_receber(c, t.texto, null, pe.id, c.venda_id);
  end if;
  if coalesce((r ->> 'achou')::int, 0) > 0 then
    perform public._bo_mensagem(gen_random_uuid(), 1, 'indicacao_obrigado', c.venda_id, c,
              case when (r ->> 'ok')::int > 0 then 'indicacao_obrigado' else 'indicacao_ja' end, jsonb_build_object('nome', r ->> 'nome'));
    update public.indicacao_pedidos set estado = 'recebeu', respondeu_em = now(), resposta = left(t.texto, 300), tratado_em = now() where id = pe.id;
  elsif t.midia is not null or v_t ~ '(problema|ruim|pessim|horrivel|lent[ao]|caindo|caiu|sem sinal|sem internet|nao funciona|travando|oscila|reclam|cancel|fatura|boleto|cobranca|tecnico)' then
    -- assunto de suporte ou mídia: o pedido acaba e o pós-venda de sempre chama o time
    update public.indicacao_pedidos set estado = 'encerrada', respondeu_em = now(), encerrada_em = now(), resposta = left(t.texto, 300) where id = pe.id;
  elsif pe.insistencias = 0 then
    perform public._bo_mensagem(gen_random_uuid(), 1, 'indicacao_insistir', c.venda_id, c, 'indicacao_insistir', '{}'::jsonb);
    update public.indicacao_pedidos set insistencias = 1, respondeu_em = now(), resposta = left(t.texto, 300), tratado_em = now() where id = pe.id;
  else
    update public.indicacao_pedidos set estado = 'encerrada', encerrada_em = now(), resposta = left(t.texto, 300), tratado_em = now() where id = pe.id;
  end if;
  if exists (select 1 from public.indicacao_pedidos x where x.id = pe.id and x.tratado_em = now()) then
    update public.mari_conversas set dispensada_em = now() where id = c.id;   -- a linha "pós-venda" do Live não acende
  end if;
end $$;
revoke all on function public._ind_varredura_resposta(public.mari_conversas, public.mari_turnos) from public, anon, authenticated;

-- ───────────────────────── 3. funções de hoje + a troca da 0303 ─────────────────────────

CREATE OR REPLACE FUNCTION public._porta_sair(c mari_conversas, v vendas, p_codigo text, p_dados jsonb, p_quem text, p_pede_sub boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  k       public.config_lead;
  sub     text := nullif(btrim(coalesce(p_dados ->> 'sub', '')), '');
  volta   date := nullif(p_dados ->> 'volta', '')::date;
  obs     text := nullif(btrim(coalesce(p_dados ->> 'obs', '')), '');
  cancelou boolean := (p_dados ->> 'cancelou_portal')::boolean;
  aberto  boolean := false;
  quadro  text;
  nc_novo boolean := false;
  feito   text[] := '{}';
  nota    text;
  agora_t text := to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI');
  c2      public.mari_conversas;
  msg     jsonb;
  v_ind   text;   -- 0303: null = pode pedir indicação na mesma mensagem
begin
  select * into k from public.config_lead where parceiro_id = 'dharma' and tipo = 'saida' and codigo = p_codigo;
  if not found then raise exception 'Motivo de saída desconhecido: %', p_codigo; end if;
  if p_pede_sub and k.codigo = 'recusou' and sub is null then
    raise exception 'Diga o porquê da recusa: preço, concorrente, momento, desistiu ou outro.';
  end if;
  if volta is not null and volta <= (now() at time zone 'America/Sao_Paulo')::date then raise exception 'A data de volta precisa ser futura.'; end if;

  -- efeito 1 (venda) e 5
  if v.id is not null then
    if v.instalado_em is not null or v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') then
      raise exception 'Venda instalada não vai para Saída. Cancelamento depois de instalar vem do OSAB.';
    end if;
    aberto := nullif(btrim(v.nio_pedido), '') is not null or nullif(btrim(v.nio_os), '') is not null;
    if aberto and cancelou is null then
      raise exception 'Esta venda tem pedido aberto na Nio. Diga se o pedido já foi cancelado no portal.';
    end if;
    update public.vendas
       set status = 'saida', motivo_saida = k.nome || coalesce(' · ' || sub, '') || coalesce(' — ' || obs, ''),
           interesse_futuro_em = volta, saida_motivo = k.codigo, saida_sub = sub
     where id = v.id;
    if aberto and cancelou then
      insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
      values (v.id, 'cancelado_no_portal', jsonb_build_object('quando', 'na saída'), auth.uid());
    end if;
  elsif k.codigo in ('reprovado_biometria', 'nio_nao_instalou', 'venda_indevida_fraude') then
    raise exception 'Esse motivo só vale para lead com venda.';
  end if;
  feito := feito || ('Saída · ' || k.nome)::text;
  if aberto and cancelou then feito := feito || 'pedido cancelado no portal (confirmado)'::text;
  elsif aberto then feito := feito || 'falta cancelar o pedido na Nio — a linha fica na Live até confirmar'::text; end if;

  if c.id is not null then
    -- efeito 1 (conversa, junto com a venda)
    quadro := case k.codigo when 'cidade_nao_atendida' then 'fora_area' when 'fachada_nao_atendida' then 'sem_cobertura'
                            when 'nao_contatar' then 'recusou' else k.codigo end;
    nc_novo := k.codigo = 'nao_contatar' and not coalesce(c.nao_contatar, false);
    update public.mari_conversas
       set funil_destino = public._porta_destino_de(k.codigo),
           funil_detalhe = case when k.codigo = 'nao_contatar' then 'não contatar' else 'Saída: ' || k.nome end,
           funil_destino_em = now(), funil_alerta = null, funil_alerta_em = null,
           saida_motivo = k.codigo, saida_sub = sub, saida_volta_em = volta, saida_em = now(),
           quadro_encerrada_motivo = case when v.id is null then quadro else quadro_encerrada_motivo end,
           quadro_encerrada_em = case when v.id is null then now() else quadro_encerrada_em end,
           quadro_encerrada_por = case when v.id is null then auth.uid() else quadro_encerrada_por end,
           nao_contatar = coalesce(nao_contatar, false) or k.codigo = 'nao_contatar',
           credito_resultado = case when k.codigo = 'credito_negado' then 'negado' else credito_resultado end,
           credito_em = case when k.codigo = 'credito_negado' then coalesce(credito_em, now()) else credito_em end,
           processando_ate = null,
           acompanhada_por = null, acompanhada_em = null, acompanhada_visto_em = null   -- 0279: Saída sai do Na mira
     where id = c.id;
    if nc_novo then
      insert into public.mari_turnos (conversa_id, papel, texto, pendente) values (c.id, 'sistema', '[não contatar — saída registrada no NIOGEN]', false);
    end if;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[Saída "' || k.nome || '" registrada no NIOGEN por ' || p_quem || ' — vez de ninguém, sem dono'
            || case when k.codigo = 'nao_contatar' then '; ninguém fala com o cliente]'
                    when public.lead_situacao('x', 'saida', k.codigo, false, null) = 'saida_pode_voltar' then '; se o cliente escrever, a Mari responde]'
                    else ']' end, false);
    -- efeitos 2 e 3
    perform public._porta_soltar(c.id, 'Saída "' || k.nome || '" registrada no NIOGEN');
    feito := feito || 'vez de ninguém, sem dono'::text || 'cadência parada'::text;

  -- 0303 (Ricardo, 18/11 ~23h: "pode incluir o crédito negado também"): Saída "Crédito negado" avisa com educação e pede indicação
  -- na mesma mensagem — só para quem pode receber o pedido; fora disso nada sai, como antes.
  if k.codigo = 'credito_negado' and c.id is not null and coalesce((public._ind_cfg() ->> 'pedir_sem_compra')::boolean, false) then
    select * into c2 from public.mari_conversas where id = c.id;
    if public._ind_pode_pedir(c2) is null then
      msg := public._bo_mensagem(gen_random_uuid(), 1, 'saida', v.id, c2, 'saida_credito_indicacao',
               jsonb_build_object('nome', coalesce(nullif(split_part(btrim(coalesce(c2.dados ->> 'nome', '')), ' ', 1), ''), 'tudo bem')),
               null, null, 'aviso de Saída por crédito negado (com pedido de indicação)');
      if msg ->> 'motivo' is null and coalesce(msg ->> 'status', '') <> 'repetida' then
        insert into public.indicacao_pedidos (conversa_id, venda_id, motivo, sub) values (c2.id, v.id, 'saida_credito', k.codigo);
        feito := feito || 'cliente avisado do crédito e convidado a indicar'::text;
      else
        feito := feito || ('aviso do crédito não saiu (' || coalesce(msg ->> 'motivo', msg ->> 'status', '?') || ')')::text;
      end if;
    end if;
  end if;
    -- efeito 4
    nota := case when k.codigo = 'nao_contatar' then '🚫 Saída · ' || k.nome || ' — ' || p_quem || ', ' || agora_t || '. Ninguém fala com este cliente.'
                 when public.lead_situacao('x', 'saida', k.codigo, false, null) = 'saida_pode_voltar'
                   then '⛔ Saída · ' || k.nome || ' — ' || p_quem || ', ' || agora_t || '. Sem dono. Se o cliente escrever de novo, a Mari responde.'
                 else '⛔ Saída · ' || k.nome || ' — ' || p_quem || ', ' || agora_t || '. Saída definitiva: não reabre.' end;
    feito := feito || public._porta_projetar(c.id, 'saida', nota);
    -- 0279 (caso Felix, 18/11): Saída por falta de cobertura avisa o cliente na hora — antes ninguém contava e ele achava que o pedido andava.
    if k.codigo in ('fachada_nao_atendida', 'cidade_nao_atendida') and not coalesce(c.nao_contatar, false) then
      select * into c from public.mari_conversas where id = c.id;
      v_ind := case when coalesce((public._ind_cfg() ->> 'pedir_sem_compra')::boolean, false) then public._ind_pode_pedir(c) else 'desligado' end;
      msg := public._bo_mensagem(gen_random_uuid(), 1, 'saida', v.id, c,
               case when v_ind is null then 'saida_sem_cobertura_indicacao' else 'saida_sem_cobertura' end,   -- 0303
               jsonb_build_object('nome', coalesce(nullif(split_part(btrim(coalesce(c.dados ->> 'nome', '')), ' ', 1), ''), 'tudo bem')),
               null, null, 'aviso de Saída por falta de cobertura');
      if msg ->> 'motivo' is null and coalesce(msg ->> 'status', '') <> 'repetida' then
        update public.mari_conversas set dados = coalesce(dados, '{}'::jsonb) || jsonb_build_object('cobertura_avisada_em', now()) where id = c.id;
        feito := feito || 'cliente avisado: a Nio não chega no endereço'::text;
        if v_ind is null then   -- 0303: o pedido de indicação foi na mesma mensagem
          insert into public.indicacao_pedidos (conversa_id, venda_id, motivo, sub) values (c.id, v.id, 'saida_sem_cobertura', k.codigo);
          feito := feito || 'pediu indicação na mesma mensagem'::text;
        end if;
      else
        feito := feito || ('aviso ao cliente não saiu (' || coalesce(msg ->> 'motivo', msg ->> 'status', '?') || '): mande à mão')::text;
      end if;
    end if;
  end if;
  -- 0274 (casos Janaina e Greiciele, Ricardo 18/11): "Sem resposta" sem Retomada feita desde a última fala do cliente → a Mari
  -- faz a Retomada (D3 → Ligar → D7 → D15). Se o cliente responder, reabre como sempre; se não, no fim a Saída fica.
  -- 0280 (Ricardo, 18/11: "Liga a Retomada para desistiu e sem motivo"): Saída "Recusou · desistiu" e "Recusou" sem motivo também
  -- passam pela Retomada (config_retomada: recusou:desistiu e recusou: ligam; preço, concorrente e outro não; momento tem a data de volta).
  if (k.codigo = 'sem_resposta' or (k.codigo = 'recusou' and coalesce(sub, '') in ('', 'desistiu'))) and c.id is not null then
    select * into c2 from public.mari_conversas where id = c.id;
    if (c2.retomada_desde is null or (c2.retomada_fim_em is not null and c2.retomada_desde < coalesce(c2.ultima_msg_lead_at, '-infinity'::timestamptz)))
       and public._retomada_nao_liga(c2) is null then
      perform public._retomada_iniciar(c2, case when k.codigo = 'recusou' then 'saida_recusou' else 'saida_sem_resposta' end, p_quem);
      feito := feito || 'a Mari faz a Retomada (D3 → Ligar → D7 → D15); se ninguém responder, a Saída fica'::text;
    end if;
  end if;
  if volta is not null then feito := feito || ('volta para a Live em ' || to_char(volta, 'DD/MM'))::text; end if;
  return jsonb_build_object('ok', true, 'feito', to_jsonb(feito), 'pedido_aberto', aberto and not coalesce(cancelou, false),
                            'resumo', '✓ ' || array_to_string(feito, ' · '));
end $function$;

CREATE OR REPLACE FUNCTION public._porta_volta_sem_cobertura(c mari_conversas, p_texto text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  msg jsonb; feito text[] := '{}';
  r   jsonb;   -- 0303
begin
  -- 0303: o aviso da Saída pediu indicação e o cliente mandou um WhatsApp → anota a indicação e agradece (a conversa volta a fechar)
  r := public._ind_resposta_saida(c, p_texto);
  if r is not null then return r; end if;
  if coalesce(p_texto, '') ~ '[0-9]{5}-?[0-9]{3}' then
    -- mandou um CEP: pode ser outro endereço (venda!) → o time refaz a viabilidade; a conversa fica aberta com a nota
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[cliente mandou um CEP depois da Saída por falta de cobertura — com o time: refazer a viabilidade]', false);
    feito := feito || 'CEP novo: com o time'::text
             || public._porta_projetar(c.id, 'cliente_voltou', '📍 O cliente mandou um CEP depois da Saída por falta de cobertura. Refaça a viabilidade com o endereço novo; se for viável, use Reabrir. A Mari não responde.', 'open');
  else
    -- qualquer outra fala: a resposta honesta (não repete em 12 h) e a conversa volta a fechar — a Mari não responde
    if exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'mensagem'
                and a.status in ('pendente', 'executando', 'feita') and a.payload ->> 'texto_chave' = 'saida_sem_cobertura_indicacao'
                and a.criada_em > now() - interval '12 hours') then
      msg := jsonb_build_object('status', 'repetida');   -- 0303: o aviso da Saída (texto com o pedido de indicação) saiu há menos de 12 h
    else
      msg := public._bo_mensagem(gen_random_uuid(), 1, 'cliente_voltou', c.venda_id, c, 'saida_sem_cobertura',
               jsonb_build_object('nome', public.mari_cadencia_nome(c)), null, null, 'aviso de falta de cobertura (cliente voltou)');
    end if;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[cliente voltou a escrever depois da Saída por falta de cobertura — não reabre; '
            || case when msg ->> 'status' = 'repetida' then 'o aviso já saiu nas últimas 12 h' else 'resposta: a Nio ainda não chega no endereço' end || ']', false);
    feito := feito || 'cliente avisado: a Nio não chega no endereço'::text
             || public._porta_projetar(c.id, 'cliente_voltou', '📍 O cliente voltou a escrever depois da Saída por falta de cobertura. A Mari não reabre; ele recebeu a resposta de que a Nio ainda não chega no endereço. Se mandar outro endereço (CEP), a conversa abre para você.');
    -- fecha de novo depois da resposta (como o refechar da 0249: não confia no espelho do Chatwoot, que pode chegar depois)
    if not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'resolver' and a.status in ('pendente', 'executando')) then
      perform public._bo_enfileirar(gen_random_uuid(), 1, 'refechar', c.venda_id, c, 'resolver', jsonb_build_object('status', 'resolved'),
                                    now() + interval '2 minutes');
    end if;
  end if;
  return jsonb_build_object('ok', true, 'feito', to_jsonb(feito), 'resumo', '✓ ' || array_to_string(feito, ' · '));
end $function$;

CREATE OR REPLACE FUNCTION public.mari_entrada__nucleo(p_telefone text, p_nome text, p_texto text, p_canal text DEFAULT 'teste'::text, p_origem text DEFAULT NULL::text, p_chatwoot_conversation_id text DEFAULT NULL::text, p_midia jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_tel  text := regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g');
  v_conv public.mari_conversas;
  v_ts   timestamptz := clock_timestamp();
  v_orig text := case when exists (select 1 from public.config_canais k where k.canal = p_origem) then p_origem end;   -- 0302: lista em config_canais
  v_cw   text := nullif(btrim(coalesce(p_chatwoot_conversation_id, '')), '');
  v_pos  boolean;
  v_opt  boolean;
  v_sil  boolean := false;   -- 0261: silenciada (cliente Nio)
  v_cob  boolean := false;   -- 0279: volta depois de Saída por falta de cobertura (a Mari não responde)
  v_g    uuid;   -- 0155: cliente pediu para parar (SAIR, PARAR…)
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
            coalesce(v_orig, case when p_canal = 'teste' then 'teste' else public._origem_sem_marca(v_tel) end),   -- 0302: nunca mais 'direto' por falta de marca
            p_chatwoot_conversation_id)
    returning * into v_conv;
  elsif v_conv.origem in ('direto', 'desconhecida') and v_orig is not null and v_orig not in ('direto', 'desconhecida', 'teste') then   -- 0302
    -- 0033: conversa que já existia sem origem conhecida ganha a 1ª origem identificada (link (IG)/(FB) ou anúncio).
    update public.mari_conversas set origem = v_orig where id = v_conv.id returning * into v_conv;
  end if;

  if v_conv.status = 'handoff_realizado' and p_canal = 'whatsapp' and v_cw is not null
        and v_conv.chatwoot_conversation_id is distinct from v_cw then
    perform public._mari_fechar_ciclo(v_conv.id, 'nova conversa no Chatwoot (' || v_cw || ')');
    update public.mari_conversas set chatwoot_conversation_id = v_cw
     where id = v_conv.id returning * into v_conv;
  end if;
  -- 0259 (A4, conferência da sombra): também com a conversa ATIVA (ex.: Saída "pode voltar", que fica ativa) — o cliente escreveu
  -- numa conversa nova do Chatwoot e o NIOGEN seguia mandando etiquetas, notas, mensagens e "resolver" na antiga, já resolvida.
  if p_canal = 'whatsapp' and v_cw is not null and v_conv.chatwoot_conversation_id is distinct from v_cw then
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (v_conv.id, 'sistema', '[o cliente escreveu numa conversa nova do Chatwoot (' || v_cw || ', antes ' || coalesce(v_conv.chatwoot_conversation_id, '—')
            || ') — o NIOGEN passa a usar a nova]', false);
    update public.mari_conversas set chatwoot_conversation_id = v_cw, chatwoot_status = 'open', chatwoot_agente = null, chatwoot_time = null,
           chatwoot_etiquetas = '{}'
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

  -- 0265 (passo 5): a volta do cliente em Saída passa pela porta. "Pode voltar" (recusou, sem resposta…) e escreveu de verdade
  -- (não só "ok, obrigado") mais de 30 min depois da Saída → reabre onde parou, com a Mari. Definitiva, Não contatar e cliente
  -- Nio não reabrem (a tabela diz). Era o ramo "cliente voltou a escrever" do _funil_antes, que saiu.
  -- 0279 (caso Felix, 18/11): Saída dada pelo time por falta de cobertura (fachada ou cidade não atendida) NÃO reabre com a Mari —
  -- ela voltava sem saber o motivo e prometia instalação. O cliente recebe a verdade uma vez; se insistir, a conversa vai ao time.
  if coalesce(v_conv.saida_motivo, '') in ('fachada_nao_atendida', 'cidade_nao_atendida')
     and coalesce(v_conv.funil_destino, 'em_andamento') <> 'em_andamento'
     and not coalesce(v_conv.nao_contatar, false) and not public._mari_optout(p_texto)
     and public._porta_situacao(v_conv.id, null::uuid) = 'saida_pode_voltar' then
    v_cob := true;
    if p_midia is not null or not public._saida_so_confirmacao(p_texto) then
      perform public.porta('cliente_escreveu:sem_cobertura', v_conv.id, null::uuid, jsonb_build_object('texto', p_texto));
      select * into v_conv from public.mari_conversas where id = v_conv.id;
    end if;
  end if;

  -- 0303: Saída "Crédito negado" pediu indicação e o cliente mandou um WhatsApp → anota e agradece; a venda não reabre e a Mari fica calada
  if coalesce(v_conv.saida_motivo, '') = 'credito_negado' and coalesce(v_conv.funil_destino, 'em_andamento') <> 'em_andamento'
     and not coalesce(v_conv.nao_contatar, false) and public._ind_tem_telefone(p_texto)
     and public._ind_resposta_saida(v_conv, p_texto) is not null then
    v_cob := true;
    select * into v_conv from public.mari_conversas where id = v_conv.id;
  end if;

  if not v_cob and coalesce(v_conv.funil_destino, 'em_andamento') not in ('em_andamento', 'instalada', 'teste_duplicada')
     and not coalesce(v_conv.nao_contatar, false) and not public._mari_optout(p_texto)
     and (p_midia is not null or not public._saida_so_confirmacao(p_texto))
     and coalesce(v_conv.saida_em, v_conv.funil_destino_em, '-infinity') < now() - interval '30 minutes'   -- 0189: despedida não reabre
     and public._porta_situacao(v_conv.id, null::uuid) = 'saida_pode_voltar' then
    perform public.porta('cliente_escreveu', v_conv.id, null::uuid, jsonb_build_object('acao', 'reabrir'));
    select * into v_conv from public.mari_conversas where id = v_conv.id;
  end if;

  -- 0261 (Ricardo, 17/11: "Cliente já é Nio, em qualquer situação, educadamente a Mari encerra a conversa, pedindo para procurar os
  -- canais oficiais. Se depois de alguns minutos o cliente insistir, silencie a conversa. Somos uma revenda da Nio"): conversa em
  -- "já é cliente Nio" em que já houve a despedida (a própria Mari deu a Saída, ou falamos depois dela) e o cliente escreve de novo → silenciada.
  if coalesce(v_conv.funil_destino, '') = 'ja_cliente_nio' and coalesce(v_conv.quadro_encerrada_motivo, '') <> 'suporte_nio'
     and (v_conv.handoff_motivo = 'ja_cliente_nio' or v_conv.ciclo_anterior ->> 'motivo' = 'ja_cliente_nio'   -- a Mari se despediu ao dar a Saída
          or exists (select 1 from public.mari_turnos t where t.conversa_id = v_conv.id and t.papel in ('mari', 'humano')
                      and t.created_at > coalesce(v_conv.funil_destino_em, v_conv.handoff_em, v_conv.created_at))) then
    -- 0265: o silêncio é da porta (cliente_escreveu em "Cliente Nio")
    perform public.porta('cliente_escreveu', v_conv.id, null::uuid, jsonb_build_object('acao', 'silenciar'));
    select * into v_conv from public.mari_conversas where id = v_conv.id;
  end if;
  -- 0261: silenciada (cliente Nio) = a Mari não responde, e o time também não (situação 15: ninguém)
  v_sil := coalesce(v_conv.quadro_encerrada_motivo, '') = 'suporte_nio' or v_cob;

  v_pos := public._mari_pos_handoff(v_conv);

  -- 0250 (H2): Não contatar gravado no NIOGEN cala a Mari, mesmo que tirem a etiqueta à mão no Chatwoot
  v_opt  := public._mari_optout(p_texto) or coalesce(v_conv.nao_contatar, false);
  v_posv := coalesce(v_conv.funil_destino, '') = 'instalada';

  insert into public.mari_turnos (conversa_id, papel, texto, pendente, midia)
  values (v_conv.id, 'lead', coalesce(p_texto, ''), (v_conv.status = 'ativo' or v_pos) and not v_opt and not v_posv and not v_sil, public._midia_ok(p_midia));

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
    'silencio', (v_conv.status <> 'ativo' and not v_pos) or v_opt or v_posv or v_sil,
    'optout', v_opt, 'pos_venda', v_posv,   -- em handoff: humano conduz, Mari calada (salvo a janela 0061)
    'pos_handoff', v_pos,
    'nova', v_conv.created_at >= now() - interval '1 second');
end;
$function$;

CREATE OR REPLACE FUNCTION public.mari_turnos_pos_instalacao()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  cfg   jsonb;
  c     public.mari_conversas;
  p     public.pos_instalacao;
  i     public.indicacoes;
  t     text;
  tels  jsonb;
  e     jsonb;
  v_nome text;
  v_ok  int := 0;
  v_ja  int := 0;
  v_nomes text[] := '{}';
  v_reclama boolean;
  v_nega    boolean;
  v_sim     boolean;
  v_tratou  boolean := false;
  v_ddd text;
begin
  if new.papel <> 'lead' then return new; end if;
  select * into c from public.mari_conversas where id = new.conversa_id;
  if c.id is null then return new; end if;

  -- (0) o indicado respondeu por uma conversa diferente da que abrimos (telefone com/sem o 9): a indicação acompanha a conversa viva
  if coalesce(c.funil_destino, '') <> 'instalada' then
    select * into i from public.indicacoes x
     where x.tel_chave = public._tel_chave(c.telefone) and x.estado in ('recebida', 'contatada') and x.conversa_id is distinct from c.id
     limit 1;
    if i.id is not null then
      update public.indicacoes set conversa_id = c.id, estado = 'contatada', contatada_em = coalesce(contatada_em, now()) where id = i.id;
      update public.mari_conversas set origem = 'indicacao' where id = c.id and origem in ('direto', 'desconhecida');   -- 0302
      update public.mari_conversas m set status = 'encerrado_humano'
       where m.id = i.conversa_id and m.status in ('ativo', 'handoff_realizado')
         and not exists (select 1 from public.mari_turnos tt where tt.conversa_id = m.id and tt.papel = 'lead');
    end if;
    return new;
  end if;

  -- (1) cliente instalado respondendo ao pós-instalação
  select * into p from public.pos_instalacao x where x.conversa_id = c.id and x.estado in ('enviada', 'pediu')
   order by x.criado_em desc limit 1 for update;
  if p.id is null then
    perform public._ind_varredura_resposta(c, new);   -- 0303: resposta ao pedido da varredura da base instalada
    return new;
  end if;
  -- 0226 (M4): uma pessoa/o time atendendo o cliente instalado → as respostas automáticas da indicação não saem
  if coalesce(c.humano_atribuido, false) or coalesce(c.time_atribuido, false) or c.chatwoot_agente is not null then return new; end if;
  cfg := public._ind_cfg();
  if not coalesce((cfg ->> 'ligado')::boolean, false) then return new; end if;

  t := public._ind_norm(new.texto);
  v_reclama := t ~ coalesce(cfg ->> 're_reclama',
    '(problema|ruim|pessim|horrivel|lent[ao]|caindo|caiu|cai toda|sem sinal|sem internet|nao funciona|nao esta funcionando|travando|oscila|reclam|cancel|demor|errad|insatisf|decep|arrepend|defeito|quebr|fatura|boleto|cobranca|procon|anatel|tecnico nao|nao veio|nao instal)');
  v_nega := t ~ coalesce(cfg ->> 're_nega', '(^| )(nao|nem|mais ou menos|pouco|nada)( |$)');
  v_sim := length(t) <= 80 and t ~ coalesce(cfg ->> 're_sim',
    '^(sim|s|ss|ok|blz|top|show|super|beleza|certinho|excelente)( |$)|^(tudo certo|deu tudo certo|deu certo|tudo otimo|tudo ok|tudo bem|tudo perfeito|tudo joia|tudo show|tudo certinho|otim[oa]|perfeit[oa]|maravilh|muito bo[am]|mto bo[am]|bom demais|gostei|adorei|amei|funcionando|esta otim|ta otim|satisfeit|foi sim|deu sim|com certeza)');
  c.ultima_msg_lead_at := now();   -- a mari_entrada só grava isto depois: a fala que chegou agora abre a janela de 24 h

  if p.estado = 'enviada' then
    if v_reclama or v_nega then
      update public.pos_instalacao set estado = 'insatisfeito', respondeu_em = now(), resposta = left(new.texto, 300), encerrada_em = now() where id = p.id;
      perform public._bo_mensagem(gen_random_uuid(), 1, 'pos_instalacao', p.venda_id, c, 'indicacao_problema', '{}'::jsonb);
      -- não marca "tratado": o pós-venda de sempre (etiqueta, nota e linha no Live) chama o time
    elsif v_sim then
      update public.pos_instalacao set estado = 'pediu', respondeu_em = now(), pediu_em = now(), resposta = left(new.texto, 300) where id = p.id;
      perform public._bo_mensagem(gen_random_uuid(), 1, 'indicacao_pedido', p.venda_id, c, 'indicacao_pedido', '{}'::jsonb);
      v_tratou := true;
    else
      update public.pos_instalacao set estado = 'com_time', respondeu_em = now(), resposta = left(new.texto, 300), encerrada_em = now() where id = p.id;
    end if;

  else   -- 'pediu': esperando o contato
    v_ddd := substr(public._tel_chave(c.telefone), 1, 2);
    tels := public._ind_telefones(new.texto, v_ddd);
    if jsonb_array_length(tels) > 0 then
      v_nome := case when jsonb_array_length(tels) = 1 then public._ind_nome(new.texto) end;
      for e in select * from jsonb_array_elements(tels) loop
        if (e ->> 'chave') = public._tel_chave(c.telefone)
           or exists (select 1 from public.indicacoes x where x.tel_chave = e ->> 'chave' and x.estado <> 'invalida')
           or exists (select 1 from public.vendas v where public._tel_chave(v.cliente_whatsapp) = e ->> 'chave') then
          v_ja := v_ja + 1;
          continue;
        end if;
        insert into public.indicacoes (pos_instalacao_id, indicador_venda_id, indicador_conversa_id, indicado_nome, indicado_telefone,
                                       tel_chave, texto_original, conversa_id, estado, contatada_em, motivo)
        select p.id, p.venda_id, c.id, v_nome, e ->> 'tel', e ->> 'chave', left(new.texto, 500), m.id,
               case when m.id is null then 'recebida' else 'contatada' end, case when m.id is null then null else now() end,
               case when m.id is null then null else 'já estava em atendimento com a Mari' end
          from (select 1) z
          left join lateral (select mc.id from public.mari_conversas mc
                              where public._tel_chave(mc.telefone) = e ->> 'chave' and mc.canal = 'whatsapp'
                                and mc.status in ('ativo', 'handoff_realizado') limit 1) m on true;
        v_ok := v_ok + 1;
        v_nomes := v_nomes || coalesce(public._ind_primeiro_nome(v_nome), 'a pessoa');
      end loop;
      if v_ok > 0 then
        perform public._bo_mensagem(gen_random_uuid(), 1, 'indicacao_obrigado', p.venda_id, c, 'indicacao_obrigado',
                                    jsonb_build_object('nome', case when v_ok = 1 then v_nomes[1] else 'cada uma dessas pessoas' end));
      else
        perform public._bo_mensagem(gen_random_uuid(), 1, 'indicacao_obrigado', p.venda_id, c, 'indicacao_ja', '{}'::jsonb);
      end if;
      update public.pos_instalacao set resposta = left(new.texto, 300) where id = p.id;
      v_tratou := true;
    elsif v_reclama or new.midia is not null then
      update public.pos_instalacao set estado = 'com_time', encerrada_em = now(), resposta = left(new.texto, 300) where id = p.id;
    elsif p.insistencias = 0 then
      update public.pos_instalacao set insistencias = 1, insistiu_em = now() where id = p.id;
      perform public._bo_mensagem(gen_random_uuid(), 1, 'indicacao_insistir', p.venda_id, c, 'indicacao_insistir', '{}'::jsonb);
      v_tratou := true;
    else
      update public.pos_instalacao set estado = 'encerrada', encerrada_em = now() where id = p.id;
      v_tratou := true;   -- já insistimos uma vez e o cliente não tem quem indicar: encerra sem chamar o time
    end if;
  end if;

  if v_tratou then
    update public.pos_instalacao set tratado_em = now() where id = p.id;
    update public.mari_conversas set dispensada_em = now() where id = c.id;   -- a linha "pós-venda" do Live não acende
  end if;
  return new;
exception when others then
  insert into public.mari_erros (conversa_id, no_n8n, mensagem) values (new.conversa_id, 'mari_turnos_pos_instalacao', sqlerrm);
  return new;   -- nunca derruba a gravação da fala do cliente
end $function$;

CREATE OR REPLACE FUNCTION public._mari_pos_venda(p_conversa uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c public.mari_conversas;
begin
  if exists (select 1 from public.pos_instalacao x where x.conversa_id = p_conversa and x.tratado_em = now())
     or exists (select 1 from public.indicacao_pedidos x where x.conversa_id = p_conversa and x.tratado_em = now()) then return; end if;   -- 0176 · 0303   -- 0176
  select * into c from public.mari_conversas where id = p_conversa;
  if not found or coalesce(c.canal, '') <> 'whatsapp' or coalesce(c.chatwoot_conversation_id, '') = '' or coalesce(c.telefone, '') like '5500000000%' then return; end if;
  if exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.momento = 'pos_venda' and a.criada_em > now() - interval '20 hours') then return; end if;
  perform public._bo_enfileirar(gen_random_uuid(), 1, 'pos_venda', c.venda_id, c, 'etiquetas', jsonb_build_object('add', jsonb_build_array('pos-venda')));
  perform public._bo_enfileirar(gen_random_uuid(), 2, 'pos_venda', c.venda_id, c, 'nota',
    jsonb_build_object('content', '🏠 Pós-venda: cliente já instalado escreveu. A Mari não responde cliente instalado — responda pelo NIOGEN (Live › Conferir).'));
exception when others then
  insert into public.mari_erros (conversa_id, no_n8n, mensagem) values (p_conversa, '_mari_pos_venda', sqlerrm);
end;
$function$;

CREATE OR REPLACE FUNCTION public.indicacao_tick(p_agora timestamp with time zone DEFAULT now())
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  g     uuid;
  cfg   jsonb := public._ind_cfg();
  p     public.pos_instalacao;
  i     public.indicacoes;
  c     public.mari_conversas;
  v     public.vendas;
  ind   public.vendas;
  v_id  bigint;
  conta text := public._bo_cfg('chatwoot_conta', '195428') #>> '{}';
begin
  perform public._instaladas_fechar(p_agora);   -- 0244: roda mesmo com a indicação desligada
  perform public._saidas_fechar(p_agora);       -- 0249: Saída aberta sem ninguém com o que fazer
  perform public._porta_prazos(p_agora);        -- 0266: prazos do time pela porta (C10 fecha com dono guardado · C4 handoff sem resposta)
  if not coalesce((cfg ->> 'ligado')::boolean, false) then return; end if;

  -- validade
  update public.pos_instalacao set estado = 'sem_resposta', encerrada_em = p_agora
   where estado = 'enviada' and enviada_em < p_agora - make_interval(days => coalesce((cfg ->> 'validade_resposta_dias')::int, 7));
  update public.pos_instalacao set estado = 'encerrada', encerrada_em = p_agora
   where estado = 'pediu' and pediu_em < p_agora - make_interval(hours => coalesce((cfg ->> 'validade_pedido_horas')::int, 48));

  update public.indicacao_pedidos set estado = 'sem_resposta', encerrada_em = p_agora   -- 0303
   where estado = 'pediu' and pedido_em < p_agora - make_interval(days => coalesce((cfg ->> 'validade_resposta_dias')::int, 7));

  -- (1) mensagem de pós-instalação
  for p in select * from public.pos_instalacao where estado = 'agendada' and enviar_em <= p_agora order by enviar_em limit 20 for update skip locked loop
    select * into v from public.vendas where id = p.venda_id;
    if v.status not in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme')
       or v.instalado_em < p_agora - make_interval(days => coalesce((cfg ->> 'janela_instalacao_dias')::int, 3)) then
      update public.pos_instalacao set estado = 'expirada', encerrada_em = p_agora where id = p.id;
      continue;
    end if;
    select * into c from public.mari_conversas
     where id = coalesce(p.conversa_id, (select m.id from public.mari_conversas m where m.venda_id = v.id order by m.updated_at desc limit 1));
    if c.id is null or coalesce(c.canal, '') <> 'whatsapp' or coalesce(c.chatwoot_conversation_id, '') = '' then
      update public.pos_instalacao set estado = 'sem_conversa', encerrada_em = p_agora where id = p.id;
      continue;
    end if;
    if coalesce(c.nao_contatar, false) then
      update public.pos_instalacao set estado = 'encerrada', encerrada_em = p_agora, resposta = 'cliente pediu para não ser contatado' where id = p.id;
      continue;
    end if;
    if not public.mari_no_horario(p_agora, coalesce(v.cidade, c.cidade)) then continue; end if;
    -- 0243: instalou = o ciclo da venda fechou e o dono sai (regra do "dono da conversa", 0227). A 0226 (M4) esperava enquanto
    -- houvesse pessoa/time atribuído, mas nada tirava o time depois da instalação: a mensagem nunca saía e expirava em 3 dias
    -- (caso Ivon, 16/11). Agora só espera quem está falando de verdade (fala do time nas últimas 2 h); senão o dono sai, com nota.
    if coalesce(c.humano_atribuido, false) or coalesce(c.time_atribuido, false) or c.chatwoot_agente is not null then
      if exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'humano'
                  and t.created_at > p_agora - interval '2 hours') then continue; end if;
      g := gen_random_uuid();
      -- 0248: as etiquetas de handoff saem ANTES do time — as automações 24389/24390 do Chatwoot reatribuem o time backoffice
      -- sempre que uma conversa com handoff-venda/handoff-humano é atualizada (a resposta do cliente trazia o time de volta).
      perform public._bo_enfileirar(g, 1, 'pos_instalacao', v.id, c, 'etiquetas',
        jsonb_build_object('add', '[]'::jsonb, 'remove', jsonb_build_array('handoff-venda', 'handoff-humano')));
      perform public._bo_enfileirar(g, 2, 'pos_instalacao', v.id, c, 'desatribuir', jsonb_build_object('assignee_id', null));
      perform public._bo_enfileirar(g, 3, 'pos_instalacao', v.id, c, 'desatribuir', jsonb_build_object('team_id', null));
      perform public._bo_enfileirar(g, 4, 'pos_instalacao', v.id, c, 'nota', jsonb_build_object('content',
        '🏠 NIOGEN · cliente instalado: a venda fechou e a conversa sai do time. A mensagem de pós-instalação (App Nio + indicação) '
        || 'sai agora pela automação. Se o cliente escrever, a nota de pós-venda avisa — responda pelo NIOGEN.'));
      update public.mari_conversas set humano_atribuido = false, time_atribuido = false, chatwoot_agente = null, chatwoot_time = null
       where id = c.id;
      insert into public.mari_turnos (conversa_id, papel, texto, pendente)
      values (c.id, 'sistema', '[cliente instalado — a conversa saiu do time (pós-instalação, 0243); a mensagem de pós-instalação foi enfileirada]', false);
      select * into c from public.mari_conversas where id = c.id;
    end if;
    v_id := public._ind_template(c, v.id, 'pos_instalacao', 'nio_pos_instalacao',
                                 jsonb_build_array(coalesce(public._ind_primeiro_nome(coalesce(v.cliente_nome, c.nome_contato)), 'tudo bem')));
    if v_id is null then continue; end if;   -- template ainda não aprovado: tenta na próxima volta
    update public.pos_instalacao set estado = 'enviada', enviada_em = p_agora, conversa_id = c.id where id = p.id;
  end loop;

  -- (2) insistir uma vez com quem recebeu o pedido e ficou em silêncio (só com a janela de 24 h aberta)
  for p in select * from public.pos_instalacao
            where estado = 'pediu' and insistencias = 0
              and pediu_em <= p_agora - make_interval(mins => coalesce((cfg ->> 'insistir_apos_min')::int, 120))
            limit 20 for update skip locked loop
    select * into c from public.mari_conversas where id = p.conversa_id;
    if c.id is null or coalesce(c.nao_contatar, false) or c.ultima_msg_lead_at is null
       or p_agora >= c.ultima_msg_lead_at + interval '23 hours' then
      update public.pos_instalacao set insistencias = 1 where id = p.id;   -- janela fechou: não insiste por template
      continue;
    end if;
    if not public.mari_no_horario(p_agora, c.cidade) then continue; end if;
    if coalesce(c.humano_atribuido, false) or coalesce(c.time_atribuido, false) or c.chatwoot_agente is not null then continue; end if;   -- 0226 (M4)
    perform public._bo_mensagem(gen_random_uuid(), 1, 'indicacao_insistir', p.venda_id, c, 'indicacao_insistir', '{}'::jsonb);
    update public.pos_instalacao set insistencias = 1, insistiu_em = p_agora where id = p.id;
  end loop;

  -- (2b) 0303: varredura da base instalada — 1 toque por cliente a cada varredura_dias pedindo indicação (template nio_indicacao_base;
  -- só a Meta aprova: até lá, nada sai). Quem não pode receber vira 'pulado' para a varredura não olhar de novo.
  if coalesce((cfg ->> 'varredura_ligada')::boolean, false)
     and exists (select 1 from public.config_templates_waba where nome = 'nio_indicacao_base' and status = 'APPROVED') then
    for v in select vv.* from public.vendas vv
              where vv.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') and vv.cancelada_apos_instalar_em is null
                and vv.instalado_em <= p_agora - make_interval(days => coalesce((cfg ->> 'varredura_dias')::int, 60))
                and not exists (select 1 from public.indicacao_pedidos x where x.venda_id = vv.id
                                 and x.pedido_em > p_agora - make_interval(days => coalesce((cfg ->> 'varredura_dias')::int, 60)))
                and not exists (select 1 from public.pos_instalacao pp where pp.venda_id = vv.id
                                 and coalesce(pp.pediu_em, pp.enviada_em) > p_agora - make_interval(days => coalesce((cfg ->> 'varredura_dias')::int, 60)))
              order by vv.instalado_em limit coalesce((cfg ->> 'varredura_lote')::int, 10) loop
      select * into c from public.mari_conversas m where m.venda_id = v.id and m.canal = 'whatsapp' order by m.updated_at desc limit 1;
      if c.id is null or coalesce(c.chatwoot_conversation_id, '') = '' or public._ind_pode_pedir(c) is not null then
        insert into public.indicacao_pedidos (conversa_id, venda_id, motivo, estado, encerrada_em, resposta)
        values (c.id, v.id, 'varredura', 'pulado', p_agora, coalesce(public._ind_pode_pedir(c), 'sem conversa no Chatwoot'));
        continue;
      end if;
      if not public.mari_no_horario(p_agora, coalesce(v.cidade, c.cidade)) then continue; end if;
      if exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'humano'
                  and t.created_at > p_agora - interval '2 hours') then continue; end if;   -- alguém do time falando: espera
      v_id := public._ind_template(c, v.id, 'indicacao_varredura', 'nio_indicacao_base',
                                   jsonb_build_array(coalesce(public._ind_primeiro_nome(coalesce(v.cliente_nome, c.nome_contato)), 'tudo bem')));
      if v_id is null then continue; end if;
      insert into public.indicacao_pedidos (conversa_id, venda_id, motivo) values (c.id, v.id, 'varredura');
      insert into public.mari_turnos (conversa_id, papel, texto, pendente)
      values (c.id, 'sistema', '[varredura da base instalada: a Mari pediu uma indicação (template nio_indicacao_base, 0303)]', false);
    end loop;
  end if;

  -- (3) prêmio previsto e sem chave Pix: pede a chave a quem indicou (template)
  for i in select * from public.indicacoes where premio_status = 'previsto' and pix_chave is null and pix_pedido_em is null
            limit 20 for update skip locked loop
    select * into c from public.mari_conversas where id = i.indicador_conversa_id;
    select * into ind from public.vendas where id = i.indicador_venda_id;
    if c.id is null or not public.mari_no_horario(p_agora, coalesce(ind.cidade, c.cidade)) then continue; end if;
    v_id := public._ind_template(c, i.indicador_venda_id, 'indicacao_premio', 'nio_indicacao_premio',
              jsonb_build_array(coalesce(public._ind_primeiro_nome(coalesce(ind.cliente_nome, c.nome_contato)), 'tudo bem'),
                                coalesce(public._ind_primeiro_nome(coalesce(i.indicado_nome,
                                  (select vv.cliente_nome from public.vendas vv where vv.id = i.venda_id))), 'Quem você indicou')));
    if v_id is null then continue; end if;
    update public.indicacoes set pix_pedido_em = p_agora where id = i.id;
  end loop;

  -- (4) indicados a abrir no Chatwoot (a rotina cria contato + conversa e chama indicacao_abertura_resultado)
  if not coalesce((cfg ->> 'abrir_conversa')::boolean, false)
     or not exists (select 1 from public.config_templates_waba where nome = 'nio_indicacao_contato' and status = 'APPROVED') then
    return;
  end if;
  for i in select * from public.indicacoes x
            where x.estado = 'recebida' and x.tentativas < 3
              and (x.tentativa_em is null or x.tentativa_em < p_agora - interval '30 minutes')
            order by x.criado_em limit 10 for update skip locked loop
    select * into ind from public.vendas where id = i.indicador_venda_id;
    if not public.mari_no_horario(p_agora, ind.cidade) then continue; end if;
    update public.indicacoes set tentativas = tentativas + 1, tentativa_em = p_agora where id = i.id;
    return next jsonb_build_object(
      'id', i.id,
      -- 0178: sem nome, o contato nasce com o telefone (como todo contato novo do WhatsApp) — a Mari não chama ninguém de "Indicação"
      'nome', coalesce(i.indicado_nome, '+' || i.indicado_telefone),
      'telefone', '+' || i.indicado_telefone,
      'inbox_id', coalesce((cfg ->> 'inbox_id')::int, 153431),
      'base', 'https://app.chatwoot.com/api/v1/accounts/' || conta);
  end loop;
  return;
end $function$;

CREATE OR REPLACE FUNCTION public.vendas_pos_instalacao()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  cfg  jsonb := public._ind_cfg();
  i    public.indicacoes;
  ind  public.vendas;
  v_ch text := public._tel_chave(new.cliente_whatsapp);
  v_instalou boolean := new.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') and new.instalado_em is not null;
begin
  -- (a) instalou → entra na fila da mensagem (uma vez por venda)
  if v_instalou and (tg_op = 'INSERT' or old.status not in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') or old.instalado_em is null) then
    insert into public.pos_instalacao (venda_id, conversa_id, enviar_em)
    values (new.id, (select c.id from public.mari_conversas c where c.venda_id = new.id order by c.updated_at desc limit 1),
            now() + make_interval(mins => coalesce((cfg ->> 'espera_min')::int, 60)))
    on conflict (venda_id) do nothing;
  end if;

  -- (b) esta venda é de alguém indicado?
  select * into i from public.indicacoes x
   where x.estado in ('recebida', 'contatada', 'em_venda')
     and (x.venda_id = new.id or (x.venda_id is null and v_ch is not null and x.tel_chave = v_ch))
   order by (x.venda_id = new.id) desc nulls last, x.criado_em limit 1;
  if i.id is null or i.indicador_venda_id = new.id then return null; end if;

  select * into ind from public.vendas where id = i.indicador_venda_id;
  if ind.id is null and i.indicador_conversa_id is not null then   -- 0303: quem indicou não comprou — a trava confere com a conversa dele
    select m.dados ->> 'cpf', m.cep, m.numero, m.complemento into ind.cliente_cpf_cnpj, ind.cep, ind.numero, ind.complemento
      from public.mari_conversas m where m.id = i.indicador_conversa_id;
  end if;
  -- trava: não vale indicar a si mesmo (mesmo CPF/CNPJ ou mesmo endereço)
  if (regexp_replace(coalesce(new.cliente_cpf_cnpj, ''), '\D', '', 'g') <> ''
        and regexp_replace(coalesce(new.cliente_cpf_cnpj, ''), '\D', '', 'g') = regexp_replace(coalesce(ind.cliente_cpf_cnpj, ''), '\D', '', 'g'))
     or (regexp_replace(coalesce(new.cep, ''), '\D', '', 'g') <> '' and btrim(coalesce(new.numero, '')) <> ''
        and regexp_replace(coalesce(new.cep, ''), '\D', '', 'g') = regexp_replace(coalesce(ind.cep, ''), '\D', '', 'g')
        and lower(btrim(new.numero)) = lower(btrim(coalesce(ind.numero, '')))
        and lower(btrim(coalesce(new.complemento, ''))) = lower(btrim(coalesce(ind.complemento, '')))) then
    update public.indicacoes set estado = 'invalida', venda_id = new.id, motivo = 'mesmo CPF ou mesmo endereço de quem indicou',
           premio_status = case when premio_status = 'pago' then premio_status else 'nenhum' end
     where id = i.id;
    return null;
  end if;

  if v_instalou then
    update public.indicacoes
       set estado = 'instalada', venda_id = new.id, instalado_em = new.instalado_em,
           premio_status = 'previsto', premio_valor = coalesce((cfg ->> 'premio_valor')::numeric, 100),
           premio_vence_em = ((new.instalado_em at time zone 'America/Sao_Paulo')::date + coalesce((cfg ->> 'premio_dias')::int, 10))
     where id = i.id;
    insert into public.eventos_venda (venda_id, tipo, detalhe, parceiro_id)
    values (coalesce(i.indicador_venda_id, new.id), 'indicacao_premio', jsonb_build_object('indicacao_id', i.id, 'venda_indicada', new.id,
            'valor', coalesce((cfg ->> 'premio_valor')::numeric, 100)), 'dharma');
  elsif new.status in ('1_vendido', '2_aguardando_instalacao') then
    update public.indicacoes set estado = 'em_venda', venda_id = new.id where id = i.id;
  end if;
  return null;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('vendas_pos_instalacao', sqlerrm);
  return null;   -- nunca derruba a gravação da venda
end $function$;

CREATE OR REPLACE FUNCTION public.indicacao_abertura_resultado(p_id uuid, p_ok boolean, p_chatwoot_conversation_id text DEFAULT NULL::text, p_erro text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  i    public.indicacoes;
  c    public.mari_conversas;
  ind  public.vendas;
  v_cw text := nullif(btrim(coalesce(p_chatwoot_conversation_id, '')), '');
  v_tel text;
  v_id bigint;
begin
  select * into i from public.indicacoes where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'erro', 'indicação inexistente'); end if;
  if i.estado <> 'recebida' then return jsonb_build_object('ok', true, 'registrado', 'já tratada'); end if;
  if not coalesce(p_ok, false) or v_cw is null then
    update public.indicacoes set motivo = left(coalesce(p_erro, 'sem detalhe'), 300),
           estado = case when tentativas >= 3 then 'erro' else estado end where id = p_id;
    if i.tentativas >= 3 then
      insert into public.mari_erros (no_n8n, mensagem, payload)
      values ('indicacao_rotina', 'não abri a conversa do indicado (3×): ' || left(coalesce(p_erro, ''), 300), jsonb_build_object('indicacao_id', p_id));
    end if;
    return jsonb_build_object('ok', true, 'registrado', 'erro');
  end if;

  select * into ind from public.vendas where id = i.indicador_venda_id;
  if ind.id is null then   -- 0303: quem indicou não comprou — o nome vem da conversa dele
    select coalesce(nullif(btrim(m.dados ->> 'nome'), ''), m.nome_contato) into ind.cliente_nome from public.mari_conversas m where m.id = i.indicador_conversa_id;
  end if;
  -- 0178: o telefone fica como está no contato do Chatwoot (com o 9): é assim que a resposta do indicado chega à mari_entrada,
  -- e ela cai na MESMA conversa (com o histórico do primeiro contato). O formato sem o 9 abria uma conversa nova.
  v_tel := i.indicado_telefone;
  select * into c from public.mari_conversas m
   where m.canal = 'whatsapp' and m.status in ('ativo', 'handoff_realizado')
     and (m.chatwoot_conversation_id = v_cw or public._tel_chave(m.telefone) = i.tel_chave)
   order by (m.chatwoot_conversation_id = v_cw) desc limit 1;
  if c.id is null then
    insert into public.mari_conversas (telefone, nome_contato, canal, origem, chatwoot_conversation_id, cadencia_passo, cadencia_passo_em)
    values (v_tel, i.indicado_nome, 'whatsapp', 'indicacao', v_cw, 'P1', now())
    returning * into c;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[lead indicado por ' || coalesce(nullif(btrim(ind.cliente_nome), ''), 'um cliente') ||
            ' (' || case when i.indicador_venda_id is null then 'não comprou: a Nio não chega no endereço dele' else 'cliente já instalado' end || ') — a Mari fez o primeiro contato por template citando quem indicou]', false);
    v_id := public._ind_template(c, null, 'indicacao', 'nio_indicacao_contato',
              jsonb_build_array(coalesce(public._ind_primeiro_nome(i.indicado_nome), 'tudo bem'),
                                coalesce(public._ind_primeiro_nome(ind.cliente_nome), 'Um cliente nosso')));
    -- conta como o P1 da cadência: ela segue com D7 e D15 sozinha, sem repetir o primeiro contato
    insert into public.contatos_cliente (conversa_id, telefone, canal, direcao, por, em, toque, tipo, resumo)
    values (c.id, c.telefone, 'whatsapp', 'saida', 'mari', now(), 'P1', 'ativo', 'Indicação · primeiro contato (template nio_indicacao_contato)');
  end if;
  update public.indicacoes set estado = 'contatada', conversa_id = c.id, contatada_em = now(), motivo = null where id = p_id;
  return jsonb_build_object('ok', true, 'registrado', 'contatada', 'conversa_id', c.id, 'acao_id', v_id);
end $function$;

-- v_indicacoes: quem indicou sem ter comprado também aparece (a tela Pagamentos lia só quem tinha venda)
create or replace view public.v_indicacoes with (security_invoker = true) as
 SELECT i.id,
    i.parceiro_id,
    i.criado_em,
    i.estado,
    i.motivo,
    i.indicador_venda_id,
    COALESCE(vi.cliente_nome, NULLIF(btrim(ic.dados ->> 'nome'::text), ''::text), ic.nome_contato) AS indicador_nome,
    COALESCE(vi.cliente_whatsapp, ic.telefone) AS indicador_whatsapp,
    i.indicador_conversa_id,
    i.indicado_nome,
    i.indicado_telefone,
    i.conversa_id,
    i.venda_id,
    vd.cliente_nome AS indicado_cliente_nome,
    vd.status AS indicado_venda_status,
    vd.comissao_prevista AS indicado_comissao,
    i.contatada_em,
    i.instalado_em,
    (COALESCE((vd.nio_situacao = 'Concluído'::text), false) OR (EXISTS ( SELECT 1
           FROM eventos_venda e
          WHERE ((e.venda_id = i.venda_id) AND (e.tipo = 'os_instalada'::text))))) AS confirmada_nio,
    COALESCE(((vd.status = 'saida'::text) OR (vd.cancelada_apos_instalar_em IS NOT NULL)), false) AS indicado_saiu,
    i.premio_status,
    i.premio_valor,
    i.premio_vence_em,
    i.pix_chave,
    i.pix_pedido_em,
    i.pago_em,
    i.comprovante_path,
    i.obs,
        CASE
            WHEN (i.premio_status = 'pago'::text) THEN 'pago'::text
            WHEN (i.premio_status = 'cancelado'::text) THEN 'cancelado'::text
            WHEN (i.estado = 'invalida'::text) THEN 'invalida'::text
            WHEN ((i.premio_status = 'previsto'::text) AND ((vd.status = 'saida'::text) OR (vd.cancelada_apos_instalar_em IS NOT NULL))) THEN 'indicado_saiu'::text
            WHEN ((i.premio_status = 'previsto'::text) AND (NOT (COALESCE((vd.nio_situacao = 'Concluído'::text), false) OR (EXISTS ( SELECT 1
               FROM eventos_venda e
              WHERE ((e.venda_id = i.venda_id) AND (e.tipo = 'os_instalada'::text))))))) THEN 'aguarda_nio'::text
            WHEN ((i.premio_status = 'previsto'::text) AND (i.premio_vence_em > ((now() AT TIME ZONE 'America/Sao_Paulo'::text))::date)) THEN 'aguarda_prazo'::text
            WHEN ((i.premio_status = 'previsto'::text) AND (COALESCE(i.pix_chave, ''::text) = ''::text)) THEN 'falta_pix'::text
            WHEN (i.premio_status = 'previsto'::text) THEN 'a_pagar'::text
            WHEN (i.estado = 'em_venda'::text) THEN 'em_venda'::text
            WHEN (i.estado = 'contatada'::text) THEN 'contatada'::text
            WHEN (i.estado = 'erro'::text) THEN 'erro'::text
            ELSE 'recebida'::text
        END AS situacao
   FROM (((indicacoes i
     LEFT JOIN vendas vi ON ((vi.id = i.indicador_venda_id)))
     LEFT JOIN mari_conversas ic ON ((ic.id = i.indicador_conversa_id)))
     LEFT JOIN vendas vd ON ((vd.id = i.venda_id)));

commit;

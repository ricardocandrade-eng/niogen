-- NIOGEN | supabase/migrations/0268_porta_passos_da_venda.sql | 17/11/2026 — Claude Code (Opus 5.5)
-- Passo 5 do caminho (porta única), 3º grupo: PASSOS DA VENDA e ROBÔS DA NIO — Ricardo, 17/11: "Sim, construa".
-- (1) Botões da ficha e da extensão (backoffice_momento, lead_virar_venda, venda_trocar_titular, venda_mover_admin,
--     lead_antifraude_decidir): antes de fazer qualquer coisa perguntam à porta (_porta_conferir). Recusa da tabela = o time vê a
--     frase e nada muda; exige admin = só o admin. Combinação SEM regra passa e fica anotada (não trava venda; a conferência mostra
--     o buraco e a tabela é completada). O que cada botão faz não muda: a sombra mostrou 12/12 eventos de acordo na produção.
-- (2) Robôs da Nio (OSAB, portal, GED360) e mudanças de destino fora da porta (fim da cadência, handoff de saída da Mari, regra
--     dura): NUNCA recusados — a Nio é a fonte da verdade de pedido, OS e instalação (regra 20, item 4). Mas cada mudança passa a
--     ficar anotada em porta_sombra (antes, depois, quem — o nome da função que rodou), com eventos nio:* e funil:*.
-- (3) Tabela: viabilidade vale em Saída (o Reabrir pede "refaça a viabilidade"); crédito com resultado fora dos quatro conhecidos
--     fica onde está; linhas nio:* e funil:* para conferir os robôs.
-- Regra 20: nenhum estado novo; toda mudança de lead deste grupo vira evento anotado com autor; conferência: R12 do portão
-- (bloqueio para os botões) e R10 (aviso para os robôs) + v_porta_divergencias na produção. Tela Live: sem mudança.
begin;

-- ── (1) a tabela ──
insert into public.config_evento (codigo, nome, funcao, quem, nota) values
  ('nio:*',   'Fato da Nio (robô OSAB, portal, GED360)', '_porta_robo_depois',  'Nio',     'só anota — a Nio é a fonte da verdade'),
  ('funil:*', 'Destino mudou fora da porta (cadência, handoff, regra dura)', '_porta_funil_depois', 'sistema', 'só anota até o grupo passar pela porta')
on conflict (codigo) do update set nome = excluded.nome, funcao = excluded.funcao, quem = excluded.quem, nota = excluded.nota;

insert into public.config_transicao (evento, de, para, aceito, frase, nota, exige) values
  ('momento:viabilidade:*', 'saida', '{=}', true, null, '0268: refazer a viabilidade antes de reabrir (0227 D5)', null),
  ('momento:credito:*', 'andamento', '{=,qualificado_credito,qualificado_biometria,qualificado_os,em_espera}', true, null, '0268: resultado fora dos quatro conhecidos', null),
  ('nio:instalada', '*', '{instalada}', true, null, 'OSAB/portal: instalou', null),
  ('nio:saida', '*', '{saida_definitiva,saida_pode_voltar,cliente_nio,=}', true, null, 'OSAB/portal/GED360: cancelou ou reprovou', null),
  ('nio:biometria:validada', 'andamento', '{=,qualificado_os,instalacao_agendar,instalacao_aguardando}', true, null, 'GED360/portal: biometria aprovada', null),
  ('nio:biometria:*', '*', '{=}', true, null, 'GED360: risco ou pendente — a etapa fica', null),
  ('nio:status:*', '*', '{=,andamento}', true, null, 'outra mudança de status vinda da Nio', null),
  ('funil:sem_resposta',     'andamento', '{saida_pode_voltar}', true, null, 'fim da cadência', null),
  ('funil:recusou',          'andamento', '{saida_pode_voltar,nao_contatar}', true, null, 'Mari: recusa · Não contatar sem venda', null),
  ('funil:fora_area',        'andamento', '{saida_pode_voltar}', true, null, 'regra dura: CEP fora da área', null),
  ('funil:sem_cobertura',    'andamento', '{saida_pode_voltar}', true, null, 'regra dura: sem cobertura', null),
  ('funil:ja_cliente_nio',   'andamento', '{cliente_nio}', true, null, 'regra dura / Mari: já é cliente Nio', null),
  ('funil:credito_negado',   'andamento', '{saida_definitiva}', true, null, null, null),
  ('funil:reprovado_biometria', 'andamento', '{saida_definitiva}', true, null, null, null),
  ('funil:teste_duplicada',  '*', '{saida_definitiva}', true, null, 'telefone ou canal de teste', null),
  ('funil:instalada',        '*', '{instalada}', true, null, null, null),
  ('funil:em_andamento',     'saida', '{andamento}', true, null, 'a regra dura deixou de valer / venda reativada', null),
  ('funil:em_andamento',     '*', '{andamento}', true, null, null, null),
  ('funil:*',                'saida', '{saida_pode_voltar,saida_definitiva,cliente_nio,nao_contatar}', true, null, 'troca de motivo de Saída', null)
on conflict (evento, de) do update set para = excluded.para, aceito = excluded.aceito, frase = excluded.frase, nota = excluded.nota, exige = excluded.exige;

-- ── (2) a pergunta à porta, para os botões que ainda fazem o próprio trabalho ──
create or replace function public._porta_conferir(p_evento text, p_conversa uuid, p_venda uuid)
returns void language plpgsql stable security definer set search_path = public as $$
declare antes text; r record;
begin
  antes := public._porta_situacao(p_conversa, p_venda);
  select * into r from public.porta_prever(antes, p_evento);
  if r.aceito is false then
    raise exception '%', coalesce(r.frase, 'Esta ação não vale nesta situação.');
  end if;
  if r.aceito and r.exige = 'admin' and coalesce(public.meu_perfil(), '') <> 'admin' then
    raise exception '%', r.frase using errcode = '42501';
  end if;
  -- sem regra (r.aceito is null): passa — a casca anota e a conferência mostra o buraco
end $$;
revoke execute on function public._porta_conferir(text, uuid, uuid) from public, anon, authenticated;

-- ── (3) robôs: cada mudança vinda de fora da porta fica anotada ──
create or replace function public._porta_quem_rodou() returns text language sql stable as $$
  select coalesce(substring(current_query() from 'public\.([a-z_0-9]+)\s*\('), 'fora da porta')
$$;

create or replace function public._porta_fora(p_tipo text) returns boolean language sql stable as $$
  -- verdadeiro quando a mudança NÃO veio da porta nem de uma casca (essas já anotam) nem de outro gatilho
  select coalesce(current_setting('porta.dentro', true), '') = '' and coalesce(current_setting('porta.aplicando', true), '') = ''
     and pg_trigger_depth() <= case when p_tipo = 'venda' then 1 else 1 end
$$;

create or replace function public._porta_robo_antes()
returns trigger language plpgsql security definer set search_path = public as $$
declare m jsonb;
begin
  if not public._porta_fora('venda') then return new; end if;
  if new.status is not distinct from old.status and new.biometria_status is not distinct from old.biometria_status
     and new.instalado_em is not distinct from old.instalado_em then
    return new;
  end if;
  m := coalesce(nullif(current_setting('porta.antes_venda', true), '')::jsonb, '{}'::jsonb);
  perform set_config('porta.antes_venda', (m || jsonb_build_object(new.id::text, public._porta_situacao(null::uuid, new.id)))::text, true);
  return new;
exception when others then
  return new;   -- a sombra nunca derruba o robô
end $$;

create or replace function public._porta_robo_depois()
returns trigger language plpgsql security definer set search_path = public as $$
declare m jsonb; antes text; ev text; c uuid;
begin
  m := coalesce(nullif(current_setting('porta.antes_venda', true), '')::jsonb, '{}'::jsonb);
  antes := m ->> new.id::text;
  if antes is null then return null; end if;
  perform set_config('porta.antes_venda', (m - new.id::text)::text, true);
  ev := case
    when new.instalado_em is not null or new.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') then 'nio:instalada'
    when new.status = 'saida' and old.status is distinct from 'saida' then 'nio:saida'
    when new.biometria_status is distinct from old.biometria_status then 'nio:biometria:' || coalesce(new.biometria_status, '')
    else 'nio:status:' || coalesce(new.status, '') end;
  select m2.id into c from public.mari_conversas m2 where m2.venda_id = new.id and m2.canal = 'whatsapp' order by m2.created_at desc limit 1;
  perform public._porta_anotar(ev, public._porta_quem_rodou(), c, new.id, antes,
    jsonb_build_object('ok', true, 'resumo', coalesce(old.status, '') || ' → ' || coalesce(new.status, '')
                       || case when new.biometria_status is distinct from old.biometria_status then ' · biometria ' || coalesce(new.biometria_status, '') else '' end));
  return null;
exception when others then
  return null;
end $$;

drop trigger if exists vendas_zz_porta_antes on public.vendas;
create trigger vendas_zz_porta_antes before update on public.vendas for each row execute function public._porta_robo_antes();
drop trigger if exists vendas_zz_porta_depois on public.vendas;
create trigger vendas_zz_porta_depois after update on public.vendas for each row execute function public._porta_robo_depois();

create or replace function public._porta_funil_antes()
returns trigger language plpgsql security definer set search_path = public as $$
declare m jsonb;
begin
  -- roda depois do _funil_antes (ordem alfabética: "zz"), quando o destino novo já está calculado
  if new.funil_destino is not distinct from old.funil_destino or not public._porta_fora('conversa') then return new; end if;
  if coalesce(new.canal, '') = 'teste' or coalesce(new.telefone, '') like '5500000000%' then return new; end if;
  m := coalesce(nullif(current_setting('porta.antes_conversa', true), '')::jsonb, '{}'::jsonb);
  perform set_config('porta.antes_conversa', (m || jsonb_build_object(new.id::text, public._porta_situacao(new.id, null::uuid)))::text, true);
  return new;
exception when others then
  return new;
end $$;

create or replace function public._porta_funil_depois()
returns trigger language plpgsql security definer set search_path = public as $$
declare m jsonb; antes text;
begin
  m := coalesce(nullif(current_setting('porta.antes_conversa', true), '')::jsonb, '{}'::jsonb);
  antes := m ->> new.id::text;
  if antes is null then return null; end if;
  perform set_config('porta.antes_conversa', (m - new.id::text)::text, true);
  perform public._porta_anotar('funil:' || coalesce(new.funil_destino, 'em_andamento'), public._porta_quem_rodou(), new.id, null::uuid, antes,
    jsonb_build_object('ok', true, 'resumo', coalesce(old.funil_destino, 'em_andamento') || ' → ' || coalesce(new.funil_destino, 'em_andamento')
                       || coalesce(' (' || new.funil_detalhe || ')', '')));
  return null;
exception when others then
  return null;
end $$;

drop trigger if exists mari_conversas_zz_porta_antes on public.mari_conversas;
create trigger mari_conversas_zz_porta_antes before update on public.mari_conversas for each row execute function public._porta_funil_antes();
drop trigger if exists mari_conversas_zz_porta_depois on public.mari_conversas;
create trigger mari_conversas_zz_porta_depois after update on public.mari_conversas for each row execute function public._porta_funil_depois();

revoke execute on function public._porta_robo_antes() from public, anon, authenticated;
revoke execute on function public._porta_robo_depois() from public, anon, authenticated;
revoke execute on function public._porta_funil_antes() from public, anon, authenticated;
revoke execute on function public._porta_funil_depois() from public, anon, authenticated;

-- ── (4) os botões perguntam à porta antes (o resto de cada função é o de sempre) ──

CREATE OR REPLACE FUNCTION public.backoffice_momento__nucleo(p_venda uuid, p_momento text, p_dados jsonb DEFAULT '{}'::jsonb)
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
  -- 0268 (passo 5): a porta responde antes — recusa da tabela para aqui com a frase; sem regra passa e fica anotada
  perform public._porta_conferir('momento:' || coalesce(p_momento, '') || coalesce(':' || nullif(p_dados ->> 'resultado', ''), ''), nullif(p_dados ->> 'conversa_id', '')::uuid, p_venda);
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice usa os botões da venda.' using errcode = '42501';
  end if;
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

  -- ── assumir ──
  if p_momento = 'assumir' then
    if c.id is null then raise exception 'Esta venda não tem conversa no Chatwoot para assumir.'; end if;
    if exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'atribuir'
                and a.status in ('pendente', 'executando', 'feita') and a.criada_em > now() - interval '10 minutes') then
      return jsonb_build_object('ok', true, 'momento', p_momento, 'acoes', 0, 'feito', jsonb_build_array('já assumida há instantes'),
                                'resumo', '✓ esta conversa já foi assumida há instantes — nada repetido', 'venda_id', v.id, 'conversa_id', c.id);
    end if;
    perform public.mari_cadencia_parar(c.id, p_humano => true);
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[assumida no NIOGEN por ' || quem || ' — cadência parada]', false);
    if v.id is not null and v.vendedor_id is null then
      update public.vendas set vendedor_id = auth.uid() where id = v.id;
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
    feito := feito || 'Mari calada · cadência parada'::text;

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
    if not (v.nio_viab_resultado = 'viavel' and v.nio_viab_em >= now() - interval '7 days') then
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
      if not (v.nio_viab_resultado = 'viavel' and v.nio_viab_em >= now() - interval '7 days') then
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

  -- ── devolver para a Mari ──
  elsif p_momento = 'devolver_mari' then
    if c.id is null then raise exception 'Esta venda não tem conversa da Mari.'; end if;
    update public.mari_conversas set humano_atribuido = false, time_atribuido = false where id = c.id;
    -- 0155: em handoff a Mari fica calada; devolver fecha o ciclo (status ativo, etapa retomada) sem marcar "resolvida"
    if c.status = 'handoff_realizado' then
      perform public._mari_fechar_ciclo(c.id, 'devolvida para a Mari no NIOGEN por ' || quem);
    end if;
    update public.mari_conversas set chatwoot_resolvida = false where id = c.id and coalesce(funil_destino, 'em_andamento') = 'em_andamento';
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[devolvida para a Mari no NIOGEN por ' || quem || ']', false);
    if tem_cw then
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'etiquetas',
        jsonb_build_object('add', '[]'::jsonb, 'remove', jsonb_build_array('handoff-venda', 'handoff-humano')));
      o := o + 1; perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'desatribuir', jsonb_build_object('assignee_id', null));
      o := o + 1; perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'desatribuir', jsonb_build_object('team_id', null));
      o := o + 1;
      perform public._bo_enfileirar(g, o, p_momento, v.id, c, 'nota',
        jsonb_build_object('content', '↩ Devolvida para a Mari por ' || quem || ' às ' || agora_t || ' — a Mari continua.'));
      feito := feito || 'atribuição removida'::text || 'nota'::text;
    end if;
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

CREATE OR REPLACE FUNCTION public.lead_virar_venda__nucleo(p_conversa uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c public.mari_conversas;
  r jsonb;
  quem text;
begin
  -- 0268 (passo 5): a porta responde antes — recusa da tabela para aqui com a frase; sem regra passa e fica anotada
  perform public._porta_conferir('virar_venda', p_conversa, null::uuid);
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  if c.venda_id is not null then
    return jsonb_build_object('ok', true, 'venda_id', c.venda_id, 'repetido', true);
  end if;
  if coalesce(c.funil_destino, 'em_andamento') not in ('em_andamento') then
    raise exception 'O lead está em Saída (%). Reabra antes de virar venda.', c.funil_destino;
  end if;
  quem := coalesce((select u.nome from public.usuarios u where u.id = auth.uid()), 'alguém do time');
  -- mari_handoff só cria a venda com a conversa 'ativo'; handoff anterior sem venda (pedido de humano, crédito) volta a 'ativo'
  if c.status <> 'ativo' then
    update public.mari_conversas set status = 'ativo' where id = c.id;
  end if;
  r := public.mari_handoff(c.id, 'dados_completos',
         jsonb_build_object('briefing', 'Venda aberta no NIOGEN por ' || quem || ' (lead conduzido pelo time).'));
  if not coalesce((r ->> 'ok')::boolean, false) or r ->> 'venda_id' is null then
    raise exception 'A venda não foi criada: %.', coalesce(r ->> 'motivo_recusa', 'motivo desconhecido');
  end if;
  insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
  values ((r ->> 'venda_id')::uuid, 'virou_venda_niogen', jsonb_build_object('conversa_id', c.id, 'por', quem), auth.uid());
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[venda aberta no NIOGEN por ' || quem || ']', false);
  return jsonb_build_object('ok', true, 'venda_id', r ->> 'venda_id');
end $function$;

CREATE OR REPLACE FUNCTION public.venda_trocar_titular__nucleo(p_venda uuid, p_nome text, p_cpf text, p_relacao text, p_motivo text DEFAULT NULL::text, p_credito text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v    public.vendas;
  doc  text := public._so_digitos(p_cpf);
  nome text := upper(btrim(regexp_replace(coalesce(p_nome, ''), '\s+', ' ', 'g')));
  rel  text := btrim(coalesce(p_relacao, ''));
  soltas int := 0;
begin
  -- 0268 (passo 5): a porta responde antes — recusa da tabela para aqui com a frase; sem regra passa e fica anotada
  perform public._porta_conferir('trocar_titular', null::uuid, p_venda);
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice troca o titular.' using errcode = '42501';
  end if;
  if not public._cpf_ok(doc) then raise exception 'CPF do novo titular inválido (confira os dígitos).' using errcode = 'P0001'; end if;
  if length(nome) < 5 or nome !~ ' ' then raise exception 'Nome completo do novo titular (como saiu na Receita).' using errcode = 'P0001'; end if;
  if length(rel) < 2 then raise exception 'Diga o parentesco do titular com quem conversa (pai, mãe, filho, cônjuge…).' using errcode = 'P0001'; end if;
  if p_credito is not null and p_credito not in ('aprovado', 'so_cartao', 'pendente', 'negado') then
    raise exception 'Resultado de crédito inválido.' using errcode = 'P0001';
  end if;
  select * into v from public.vendas where id = p_venda for update;
  if not found then raise exception 'Venda não encontrada.' using errcode = 'P0001'; end if;
  if v.status = 'saida' then raise exception 'A venda está em Saída: reabra pela ficha.' using errcode = 'P0001'; end if;
  -- 0256 (D16, Ricardo 17/11): depois da OS, trocar o titular é Saída desta venda e venda nova (a OS é do CPF antigo)
  if v.status <> '0_qualificado' or nullif(btrim(coalesce(v.nio_os, '')), '') is not null then
    raise exception 'Depois da OS não se troca o titular: dê Saída nesta venda (cancelando a OS no portal) e abra uma venda nova com o novo titular.' using errcode = 'P0001';
  end if;
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

  -- 0255 (B10): titular novo com crédito aprovado → a pendência "outro CPF" destravou (antes ficava aberta: cadência pausada e cobrança na Live)
  if p_credito in ('aprovado', 'so_cartao') then
    with f as (
      update public.venda_pendencias
         set encerrada_em = now(), encerrada_por = auth.uid(), resultado = 'destravou',
             nota_encerramento = 'titular trocado para ' || nome || ' com crédito ' || p_credito
       where venda_id = v.id and motivo = 'credito_outro_cpf' and encerrada_em is null
      returning id, aberta_em)
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    select v.id, 'pendencia', jsonb_build_object('acao', 'encerrada', 'pendencia_id', f.id, 'motivo', 'credito_outro_cpf',
           'resultado', 'destravou', 'nota', 'titular novo com crédito ' || p_credito,
           'dias', ((now() at time zone 'America/Sao_Paulo')::date - (f.aberta_em at time zone 'America/Sao_Paulo')::date)), auth.uid()
      from f;
  end if;

  return jsonb_build_object('ok', true, 'titular', nome, 'contato', coalesce(v.contato_nome, v.cliente_nome), 'relacao', rel);
end;
$function$;

CREATE OR REPLACE FUNCTION public.venda_mover_admin__nucleo(p_venda uuid, p_destino text, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v public.vendas%rowtype;
  m text := btrim(coalesce(p_motivo, ''));
begin
  -- 0268 (passo 5): a porta responde antes — recusa da tabela para aqui com a frase; sem regra passa e fica anotada
  perform public._porta_conferir('mover_admin:' || coalesce(p_destino, ''), null::uuid, p_venda);
  if public.meu_perfil() is distinct from 'admin' then
    raise exception 'Só o admin move a venda fora do caminho natural.' using errcode = '42501';
  end if;
  if length(m) < 5 then raise exception 'Diga o motivo (pelo menos 5 letras).' using errcode = 'P0001'; end if;
  if p_destino not in ('0_qualificado', '1_vendido', '2_aguardando_instalacao', '3_instalado', '4_ativo_provisorio') then
    raise exception 'Destino inválido. A Saída é pelo botão Saída.' using errcode = 'P0001';
  end if;
  select * into v from public.vendas where id = p_venda for update;
  if not found then raise exception 'Venda não encontrada.' using errcode = 'P0001'; end if;
  if v.status = p_destino then return jsonb_build_object('ok', true, 'mudou', false); end if;
  if v.status = 'saida' then raise exception 'A venda está em Saída: reabra pela ficha.' using errcode = 'P0001'; end if;
  perform set_config('niogen.transicao_ok', 'admin', true);
  update public.vendas set status = p_destino where id = p_venda;
  perform set_config('niogen.transicao_ok', '', true);
  insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
  values (p_venda, 'movida_admin', jsonb_build_object('de', v.status, 'para', p_destino, 'motivo', left(m, 400)), auth.uid());
  return jsonb_build_object('ok', true, 'mudou', true, 'de', v.status, 'para', p_destino);
end;
$function$;

CREATE OR REPLACE FUNCTION public.lead_antifraude_decidir__nucleo(p_conversa uuid, p_decisao text, p_obs text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c     public.mari_conversas;
  quem  text;
  obs   text := nullif(btrim(coalesce(p_obs, '')), '');
  para  text;
  rot   text;
  r     jsonb := null;
begin
  -- 0268 (passo 5): a porta responde antes — recusa da tabela para aqui com a frase; sem regra passa e fica anotada
  perform public._porta_conferir('antifraude:' || coalesce(p_decisao, ''), p_conversa, null::uuid);
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  if c.antifraude_situacao is null then raise exception 'Este lead não tem antifraude em aberto.'; end if;
  if p_decisao not in ('dele', 'outro_morador', 'cobrar', 'liberado', 'recusado') then
    raise exception 'Decisão desconhecida: %', p_decisao;
  end if;
  if p_decisao in ('liberado', 'recusado') and c.antifraude_situacao <> 'defesa' then
    raise exception 'Liberado ou recusado é a resposta da Nio à defesa: primeiro marque "é de outro morador".';
  end if;
  if p_decisao = 'outro_morador' and coalesce(length(obs), 0) < 10 then
    raise exception 'Diga o que foi enviado à Nio e por onde (ex.: "comprovante de residência e contrato de aluguel, e-mail ao Rogério").';
  end if;
  select nome into quem from public.usuarios where id = auth.uid();
  quem := coalesce(quem, 'time');

  para := case p_decisao when 'outro_morador' then 'defesa' when 'cobrar' then c.antifraude_situacao else null end;
  rot  := case p_decisao when 'dele' then 'a Nio do endereço é do cliente (ou da casa) → Já é cliente Nio'
                         when 'outro_morador' then 'Nio de outro morador → defesa na Nio'
                         when 'cobrar' then 'cliente ainda não respondeu → segue conferindo'
                         when 'liberado' then 'a Nio liberou na defesa → consultar o crédito de novo'
                         else 'a Nio recusou a defesa → Já é cliente Nio' end;

  update public.mari_conversas
     set antifraude_situacao = para,
         antifraude_em = now(),
         antifraude_hist = antifraude_hist || jsonb_build_array(jsonb_build_object(
           'em', now(), 'por', quem, 'de', c.antifraude_situacao, 'para', coalesce(para, p_decisao), 'obs', obs)),
         -- liberado: o crédito volta a "não consultado" (consultar de novo no endereço do cliente)
         credito_resultado = case when p_decisao = 'liberado' then null else credito_resultado end,
         credito_em = case when p_decisao = 'liberado' then null else credito_em end
   where id = c.id;

  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[antifraude no NIOGEN por ' || quem || ': ' || rot || coalesce(' — ' || obs, '') || ']', false);

  if p_decisao in ('dele', 'recusado') then
    r := public.lead_sair(c.id, null, 'ja_cliente_nio',
                          case when p_decisao = 'dele' then 'antifraude — Nio do cliente' else 'antifraude — defesa recusada' end,
                          null, obs, null);
  end if;

  return jsonb_build_object('ok', true, 'resumo', '✓ antifraude: ' || rot, 'saida', r);
end $function$;

commit;

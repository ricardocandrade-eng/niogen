-- NIOGEN | supabase/migrations/0064_venda_pendencias.sql | 08/11/2026 — Claude Code (docs/Prompt_pendencias_venda_081126_0005.md)
-- Por quê: venda que depende de um terceiro (ex.: a Nio confirmar um pedido em aberto no endereço — caso do Leandro, 08/11)
-- ficava em "Precisam de ação" sem ninguém saber o motivo. Agora a venda FICA NA ETAPA e ganha uma PENDÊNCIA
-- (motivo, quem destrava, revisar em, desde). Não é coluna nova no quadro e nada muda de etapa sozinho.
-- Decisões do Ricardo (08/11 00h00): só admin/backoffice abre e encerra (a Mari não); na data de revisão o aviso vai para todos.
-- O quê:
--   1. config_motivos_pendencia (lista de motivos em config, regra 15) + seed.
--   2. venda_pendencias (1 aberta por venda — índice único parcial), RLS: lê quem vê a venda; escreve só pelas funções.
--   3. RPCs pendencia_abrir / pendencia_adiar / pendencia_encerrar (SECURITY DEFINER, checam admin/backoffice) → eventos_venda.
--   4. Trigger: venda que vai para Saída encerra a pendência aberta (resultado 'saida') — a etapa segue o fluxo da ficha.
--   5. View v_pendencias_abertas (security_invoker) e colunas pend_* no FIM da v_funil (create or replace só acrescenta).
--   6. mari_cadencia_avaliar: venda com pendência aberta pausa toda a cadência (F1/F2/D3/D7/D15 e BIO1/INSTALACAO/VESPERA).
-- parceiro_id (regra 15) = o operador do NIOGEN ('dharma'); não confundir com vendas.parceiro_id (Parceiro PAP).

-- ───────────────────────── 1. motivos ─────────────────────────
create table if not exists public.config_motivos_pendencia (
  codigo          text primary key,
  nome            text not null,
  quem_destrava   text not null check (quem_destrava in ('nio', 'rogerio', 'cliente', 'interno')),
  -- motivo de Saída sugerido quando a pendência confirma o pior (texto exato da lista de motivos de Saída da ficha)
  saida_sugerida  text,
  exige_descricao boolean not null default false,
  ativo           boolean not null default true,
  ordem           int not null default 0,
  parceiro_id     text not null default 'dharma'
);
comment on table public.config_motivos_pendencia is 'Motivos de pendência com terceiro ("Em espera") — 0064. saida_sugerida = motivo_saida sugerido no atalho de encerramento.';

insert into public.config_motivos_pendencia (codigo, nome, quem_destrava, saida_sugerida, exige_descricao, ordem) values
  ('pedido_aberto_endereco', 'Pedido em aberto no endereço',             'nio',     'Já é cliente Nio', false, 1),
  ('viabilidade_confirmar',  'Confirmar viabilidade com a Nio',          'nio',     null,               false, 2),
  ('area_confirmar',         'Confirmar área de atuação',                'rogerio', null,               false, 3),
  ('cadastro_nio',           'Cadastro travado no portal (CPF/crédito)', 'nio',     null,               false, 4),
  ('outro',                  'Outro motivo',                             'interno', null,               true,  9)
on conflict (codigo) do nothing;

alter table public.config_motivos_pendencia enable row level security;
drop policy if exists config_motivos_pendencia_ler on public.config_motivos_pendencia;
create policy config_motivos_pendencia_ler on public.config_motivos_pendencia for select to authenticated using (true);
revoke all on public.config_motivos_pendencia from anon, authenticated;
grant select on public.config_motivos_pendencia to authenticated;

-- ───────────────────────── 2. pendências ─────────────────────────
create table if not exists public.venda_pendencias (
  id                uuid primary key default gen_random_uuid(),
  venda_id          uuid not null references public.vendas (id) on delete cascade,
  parceiro_id       text not null default 'dharma',
  motivo            text not null references public.config_motivos_pendencia (codigo),
  descricao         text,
  quem_destrava     text not null check (quem_destrava in ('nio', 'rogerio', 'cliente', 'interno')),
  aberta_em         timestamptz not null default now(),
  aberta_por        uuid references public.usuarios (id),
  revisar_em        date not null,
  revisoes          int not null default 0,
  encerrada_em      timestamptz,
  encerrada_por     uuid references public.usuarios (id),
  resultado         text check (resultado in ('destravou', 'saida', 'cancelada')),
  nota_encerramento text,
  constraint venda_pendencias_encerramento check ((encerrada_em is null) = (resultado is null))
);
comment on table public.venda_pendencias is 'Pendência com terceiro numa venda ("Em espera", 0064). Escrita só pelas funções pendencia_*.';
create unique index if not exists venda_pendencias_uma_aberta on public.venda_pendencias (venda_id) where encerrada_em is null;
create index if not exists venda_pendencias_venda_idx on public.venda_pendencias (venda_id, aberta_em desc);

alter table public.venda_pendencias enable row level security;
drop policy if exists venda_pendencias_ler on public.venda_pendencias;
-- Lê quem enxerga a venda (o RLS de vendas vale dentro do exists): todo logado, cada um no seu alcance.
create policy venda_pendencias_ler on public.venda_pendencias for select to authenticated
  using (exists (select 1 from public.vendas v where v.id = venda_pendencias.venda_id));
revoke all on public.venda_pendencias from anon, authenticated;
grant select on public.venda_pendencias to authenticated;

-- ───────────────────────── 3. funções ─────────────────────────
create or replace function public._pendencia_pode()
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice abre, adia ou encerra pendência.' using errcode = '42501';
  end if;
end;
$$;
revoke execute on function public._pendencia_pode() from public, anon, authenticated;

create or replace function public.pendencia_abrir(p_venda uuid, p_motivo text, p_descricao text, p_revisar_em date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_st   text;
  m      public.config_motivos_pendencia;
  p      public.venda_pendencias;
  v_desc text := nullif(btrim(coalesce(p_descricao, '')), '');
begin
  perform public._pendencia_pode();
  select status into v_st from public.vendas where id = p_venda;
  if v_st is null then raise exception 'Venda não encontrada.'; end if;
  if v_st in ('saida', '4_ativo_provisorio', '5_comissao_firme') then
    raise exception 'Pendência só em venda aberta (Qualificado a Instalado).';
  end if;
  select * into m from public.config_motivos_pendencia where codigo = p_motivo and ativo;
  if m.codigo is null then raise exception 'Motivo de pendência inválido.'; end if;
  if m.exige_descricao and v_desc is null then raise exception 'Este motivo exige a descrição.'; end if;
  if p_revisar_em is null then raise exception 'Informe a data de revisão.'; end if;
  if p_revisar_em < v_hoje then raise exception 'A data de revisão não pode ser no passado.'; end if;
  if exists (select 1 from public.venda_pendencias where venda_id = p_venda and encerrada_em is null) then
    raise exception 'Esta venda já tem uma pendência aberta: adie ou encerre a atual.';
  end if;
  insert into public.venda_pendencias (venda_id, motivo, descricao, quem_destrava, aberta_por, revisar_em)
  values (p_venda, m.codigo, v_desc, m.quem_destrava, auth.uid(), p_revisar_em)
  returning * into p;
  insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
  values (p_venda, 'pendencia', jsonb_build_object('acao', 'aberta', 'pendencia_id', p.id, 'motivo', m.codigo, 'nome', m.nome,
          'quem', m.quem_destrava, 'revisar_em', p_revisar_em, 'descricao', v_desc), auth.uid());
  return to_jsonb(p);
end;
$$;

create or replace function public.pendencia_adiar(p_id uuid, p_novo_revisar_em date, p_nota text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  p      public.venda_pendencias;
  v_de   date;
begin
  perform public._pendencia_pode();
  select * into p from public.venda_pendencias where id = p_id for update;
  if p.id is null then raise exception 'Pendência não encontrada.'; end if;
  if p.encerrada_em is not null then raise exception 'Esta pendência já foi encerrada.'; end if;
  if p_novo_revisar_em is null or p_novo_revisar_em < v_hoje then raise exception 'Escolha uma nova data de revisão (hoje ou depois).'; end if;
  v_de := p.revisar_em;
  update public.venda_pendencias set revisar_em = p_novo_revisar_em, revisoes = revisoes + 1 where id = p_id returning * into p;
  insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
  values (p.venda_id, 'pendencia', jsonb_build_object('acao', 'adiada', 'pendencia_id', p.id, 'motivo', p.motivo, 'de', v_de,
          'para', p_novo_revisar_em, 'revisoes', p.revisoes, 'nota', nullif(btrim(coalesce(p_nota, '')), '')), auth.uid());
  return to_jsonb(p);
end;
$$;

-- resultado = 'saida' só registra: a mudança de etapa para Saída segue o fluxo atual da ficha (formulário de Saída).
create or replace function public.pendencia_encerrar(p_id uuid, p_resultado text, p_nota text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  p public.venda_pendencias;
begin
  perform public._pendencia_pode();
  if p_resultado is null or p_resultado not in ('destravou', 'saida', 'cancelada') then
    raise exception 'Resultado inválido (destravou, saida ou cancelada).';
  end if;
  select * into p from public.venda_pendencias where id = p_id for update;
  if p.id is null then raise exception 'Pendência não encontrada.'; end if;
  if p.encerrada_em is not null then raise exception 'Esta pendência já foi encerrada.'; end if;
  update public.venda_pendencias
     set encerrada_em = now(), encerrada_por = auth.uid(), resultado = p_resultado,
         nota_encerramento = nullif(btrim(coalesce(p_nota, '')), '')
   where id = p_id returning * into p;
  insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
  values (p.venda_id, 'pendencia', jsonb_build_object('acao', 'encerrada', 'pendencia_id', p.id, 'motivo', p.motivo,
          'resultado', p_resultado, 'nota', p.nota_encerramento,
          'dias', ((now() at time zone 'America/Sao_Paulo')::date - (p.aberta_em at time zone 'America/Sao_Paulo')::date)), auth.uid());
  return to_jsonb(p);
end;
$$;

revoke execute on function public.pendencia_abrir(uuid, text, text, date) from public, anon;
revoke execute on function public.pendencia_adiar(uuid, date, text) from public, anon;
revoke execute on function public.pendencia_encerrar(uuid, text, text) from public, anon;
grant execute on function public.pendencia_abrir(uuid, text, text, date) to authenticated;
grant execute on function public.pendencia_adiar(uuid, date, text) to authenticated;
grant execute on function public.pendencia_encerrar(uuid, text, text) to authenticated;

-- ───────────────────────── 4. Saída encerra a pendência ─────────────────────────
create or replace function public.vendas_saida_encerra_pendencia()
returns trigger language plpgsql security definer set search_path = public as $$
declare p public.venda_pendencias;
begin
  for p in update public.venda_pendencias
              set encerrada_em = now(), encerrada_por = auth.uid(), resultado = 'saida',
                  nota_encerramento = 'Venda encerrada (Saída: ' || coalesce(new.motivo_saida, 'sem motivo') || ')'
            where venda_id = new.id and encerrada_em is null
        returning * loop
    insert into public.eventos_venda (venda_id, tipo, detalhe, criado_por)
    values (new.id, 'pendencia', jsonb_build_object('acao', 'encerrada', 'pendencia_id', p.id, 'motivo', p.motivo,
            'resultado', 'saida', 'nota', p.nota_encerramento, 'automatica', true), auth.uid());
  end loop;
  return null;
end;
$$;
revoke execute on function public.vendas_saida_encerra_pendencia() from public, anon, authenticated;
drop trigger if exists vendas_saida_encerra_pendencia on public.vendas;
create trigger vendas_saida_encerra_pendencia after update of status on public.vendas
  for each row when (new.status = 'saida' and old.status is distinct from 'saida')
  execute function public.vendas_saida_encerra_pendencia();

-- ───────────────────────── 5. views ─────────────────────────
create or replace view public.v_pendencias_abertas with (security_invoker = true) as
select p.id, p.venda_id, v.cliente_nome, v.status as etapa, v.vendedor_id,
       p.motivo, m.nome as motivo_nome, m.saida_sugerida, p.descricao, p.quem_destrava as quem,
       p.aberta_em as desde, p.aberta_por,
       ((now() at time zone 'America/Sao_Paulo')::date - (p.aberta_em at time zone 'America/Sao_Paulo')::date) as dias_parada,
       p.revisar_em,
       p.revisar_em <= (now() at time zone 'America/Sao_Paulo')::date as vencida,
       p.revisoes
  from public.venda_pendencias p
  join public.vendas v on v.id = p.venda_id
  join public.config_motivos_pendencia m on m.codigo = p.motivo
 where p.encerrada_em is null;
revoke all on public.v_pendencias_abertas from anon;
grant select on public.v_pendencias_abertas to authenticated;

-- v_funil: as colunas da pendência aberta no FIM (no máximo 1 por venda, pelo índice único parcial).
create or replace view public.v_funil
with (security_invoker = true) as
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
            WHEN v.status = '1_vendido'::text AND v.agendamento_registrado_em IS NULL AND v.vendido_em IS NOT NULL THEN round(EXTRACT(epoch FROM now() - v.vendido_em) / 3600::numeric, 2)
            ELSE NULL::numeric
        END AS horas_sem_agendamento,
        CASE
            WHEN v.status = '0_qualificado'::text AND v.biometria_status IS DISTINCT FROM 'validada'::text THEN round(EXTRACT(epoch FROM now() - v.criado_em) / 86400::numeric, 2)
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
    v.nio_viab_resultado = 'viavel'::text AND v.nio_viab_em >= (now() - '7 days'::interval) AS nio_viab_ok,
    v.nio_viab_resultado = 'viavel'::text AND v.nio_viab_em >= (now() - '7 days'::interval) OR (v.dfv_viabilidade = ANY (ARRAY['viavel'::text, 'viavel_predio'::text])) AND v.dfv_consultado_em >= (now() - '7 days'::interval) OR COALESCE(v.dfv_dispensado, false) AS viab_ok,
        CASE
            WHEN v.status = '0_qualificado'::text AND (v.biometria_status = ANY (ARRAY['pendente'::text, 'com_risco'::text])) AND v.biometria_link_enviado_em IS NOT NULL THEN round(EXTRACT(epoch FROM now() - v.biometria_link_enviado_em) / 3600::numeric, 1)
            ELSE NULL::numeric
        END AS horas_biometria_pendente,
        CASE
            WHEN v.status = '0_qualificado'::text AND v.credito_resultado = 'pendente'::text AND v.credito_em IS NOT NULL THEN round(EXTRACT(epoch FROM now() - v.credito_em) / 3600::numeric, 1)
            ELSE NULL::numeric
        END AS horas_credito_pendente,
    GREATEST(v.biometria_validada_em, v.vendido_em) AS agendar_desde,
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
    pm.saida_sugerida AS pend_saida_sugerida
   FROM vendas v
     LEFT JOIN config_planos p ON p.id = v.plano_id
     LEFT JOIN usuarios u ON u.id = v.vendedor_id
     LEFT JOIN parceiros pa ON pa.id = v.parceiro_id
     LEFT JOIN venda_pendencias pe ON pe.venda_id = v.id AND pe.encerrada_em IS NULL
     LEFT JOIN config_motivos_pendencia pm ON pm.codigo = pe.motivo;

-- ───────────────────────── 6. cadência: pendência aberta pausa tudo ─────────────────────────
-- Corpo igual ao do banco em 08/11 (última versão, 0053) + a parada absoluta 'venda em espera'.
CREATE OR REPLACE FUNCTION public.mari_cadencia_avaliar(p_agora timestamp with time zone DEFAULT now(), p_conversa uuid DEFAULT NULL::uuid)
 RETURNS TABLE(conversa_id uuid, telefone text, canal text, chatwoot_conversation_id text, status text, etapa text, passo_atual text, passo_em timestamp with time zone, proximo_passo text, proximo_em timestamp with time zone, pode_enviar boolean, bloqueio text, acao text, template text, categoria text, params jsonb, texto text, excecao text, janela_aberta boolean, janela_fecha_em timestamp with time zone, toques_hoje integer, toques_mes integer, ligar_sugerido boolean, venda_id uuid)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
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
    -- 0064 (08/11): venda "Em espera" (pendência com terceiro aberta) pausa toda a cadência até a pendência ser encerrada.
    elsif c.venda_id is not null and exists (select 1 from public.venda_pendencias vp
                                              where vp.venda_id = c.venda_id and vp.encerrada_em is null) then
      v_bloq := 'venda em espera (pendência com terceiro)';
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
      -- 0050 (Ricardo, 06/11): venda em Saída não recebe nada da cadência ("Interesse futuro" vira etiqueta no
      -- Chatwoot, 0052; "Sem cobertura" não ganha nada).
      if c.venda_id is not null and exists (select 1 from public.vendas vs where vs.id = c.venda_id and vs.status = 'saida') then
        continue;
      end if;
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
          -- 0050 (Ricardo, 06/11): F2 no MESMO dia, ~4 h depois da última fala da Mari (cutucada discreta, dentro do
          -- horário). Caiu fora do horário → próximo horário, se ainda dentro da janela; senão a regra antiga (fim do
          -- horário anterior às 20 h do lead). Continua valendo o teto do contrato: 2 toques/dia, 15/mês por telefone.
          -- 0053: a base do F2 é a última fala REAL da Mari (sem tags.cadencia) — o turno do próprio F1 carimba
          -- ultima_msg_mari_at (gatilho da 0018) e empurrava o F2 para ~4 h depois do F1.
          f2_at := coalesce((select max(t.created_at) from public.mari_turnos t
                              where t.conversa_id = c.id and t.papel = 'mari'
                                and coalesce(t.tags ->> 'cadencia', '') = ''), M) + interval '4 hours';
          f2_ate := L + interval '23 hours';
          if c.cadencia_retorno_em is not null then
            f2_at := null;
          elsif not public.mari_no_horario(f2_at, c.cidade) then
            f2_at := public.mari_proximo_horario(f2_at, c.cidade);
          end if;
          if c.cadencia_retorno_em is not null then
            null;
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
        -- 0050 (Ricardo, 06/11): venda já criada NUNCA sai sozinha e não recebe a escada de templates de lead —
        -- só as cutucadas F1/F2 dentro da janela; o resto é do backoffice, pela venda.
        if c.venda_id is not null and v_passo not in ('F1', 'F2') then
          v_bloq := 'venda criada: o backoffice segue pela venda (a cadência não manda D3/D7/D15 nem encerra)';
        end if;
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
$function$;

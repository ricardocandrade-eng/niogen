-- NIOGEN | 0274_retomada.sql | 18/11/2026 — Claude Code
-- Resumo: a RETOMADA (Ricardo, 18/11: "São clientes que podem reesquentar. Não pode ligar cadência para clientes Nio, sem
-- viabilidade, reprovados o crédito, etc."). Casos Janaina, Greiciele, Felix, Kika e Lucas.
--   1. Cliente parou de responder ao time por 24 h úteis (lead sem venda) → a Mari faz a Retomada pela fila do NIOGEN
--      (D3 → Ligar → D7 → D15). Se ele responder: com o dono ainda guardado, o Chatwoot devolve ao mesmo dono; se a conversa já
--      tinha voltado para a Mari (0227, 24 h sem ninguém), a Mari atende. No fim sem resposta, a Saída "Sem resposta" sai pela porta.
--   2. "Sem resposta" dado pelo time sem Retomada feita → a Retomada começa; a Saída fica no fim (se o cliente responder, reabre).
--   3. config_retomada: quem liga e quem não liga (Ricardo controla). Não liga: cliente Nio, sem viabilidade, fora da área, crédito
--      negado, biometria reprovada, fraude, teste, Não contatar, Nio não instalou, Recusou (preço/concorrente/desistiu/outro).
--   4. "vou ver / depois te mando" → 24 h sem cutucada (config_regras.retomada_pausa_regex).
--   5. Lembrete automático da venda (biometria voltou, BIO1, lembrete do cartão, véspera) espera 2 h depois de alguém do time falar.
--   6. Lead em Saída sai do Conferir (rua e unidade); a Live pede para ligar no D3 + 1 dia (retomada_ligar).
-- A Retomada não passa pelo n8n: sai pela fila de ações do Chatwoot (como a 🔥 e o pós-instalação), porque o guard do n8n cala a
-- Mari com dono ou com a conversa resolvida — e é justamente assim que o dono fica guardado.
begin;

-- ── 1. quem pode receber a Retomada (Ricardo controla) ──
create table if not exists public.config_retomada (
  chave  text primary key,
  liga   boolean not null,
  nome   text not null,
  nota   text,
  ordem  int not null default 100
);
alter table public.config_retomada enable row level security;
drop policy if exists config_retomada_ler on public.config_retomada;
create policy config_retomada_ler on public.config_retomada for select to authenticated using (true);
grant select on public.config_retomada to authenticated;
grant all on public.config_retomada to service_role;
insert into public.config_retomada (chave, liga, nome, nota, ordem) values
  ('parou_com_o_time',      true,  'Parou de responder ao time',           'o time falou por último e o cliente sumiu por 24 h úteis', 10),
  ('sem_resposta',          true,  'Saída: Sem resposta',                  'o time deu "Sem resposta" — a Retomada vem antes da Saída ficar', 20),
  ('recusou:momento',       true,  'Recusou: não é o momento',             'pode reesquentar', 30),
  ('recusou',               false, 'Recusou (preço, concorrente, desistiu, outro)', 'decisão de 18/11: não liga', 40),
  ('cidade_nao_atendida',   false, 'Cidade não atendida', null, 50),
  ('fachada_nao_atendida',  false, 'Sem viabilidade / fachada não atendida', null, 51),
  ('ja_cliente_nio',        false, 'Já é cliente Nio', null, 52),
  ('credito_negado',        false, 'Crédito negado', null, 53),
  ('reprovado_biometria',   false, 'Reprovado na biometria', null, 54),
  ('nio_nao_instalou',      false, 'Nio não instalou', null, 55),
  ('nao_contatar',          false, 'Não contatar', null, 56),
  ('venda_indevida_fraude', false, 'Venda indevida ou fraude', null, 57),
  ('teste_duplicada',       false, 'Teste ou duplicada', null, 58)
on conflict (chave) do nothing;

insert into public.config_regras (chave, valor, descricao)
select x.chave, x.valor, x.descricao from (values
  ('retomada_time_horas_uteis', '24'::jsonb, '0274: horas úteis sem o cliente responder ao time até a Mari fazer a Retomada'),
  ('retomada_time_max_dias', '7'::jsonb, '0274: a Retomada pelo silêncio com o time só começa se a última fala do time tem até N dias (não acorda lead antigo)'),
  ('aviso_venda_espera_horas', '2'::jsonb, '0274: o lembrete automático da venda (biometria, lembrete do cartão, véspera) espera N h depois de alguém do time falar'),
  ('retomada_pausa_regex', to_jsonb('(vou ver|vou verificar|vou conversar|vou falar com|vou pensar|vou consultar|vou olhar|preciso ver com|tenho que ver com|depois (eu )?te (mando|falo|aviso|chamo|respondo|retorno)|te (mando|falo|aviso|chamo|respondo|retorno) depois|mais tarde (eu )?te)'::text),
   '0274 (caso Kika): fala do cliente que pausa as cutucadas da Mari por 24 h')
) as x(chave, valor, descricao)
where not exists (select 1 from public.config_regras r where r.chave = x.chave);

-- ── 2. o estado da Retomada na conversa ──
alter table public.mari_conversas
  add column if not exists retomada_desde    timestamptz,
  add column if not exists retomada_origem   text,
  add column if not exists retomada_passo    text,
  add column if not exists retomada_passo_em timestamptz,
  add column if not exists retomada_fim_em   timestamptz,
  add column if not exists retomada_fim      text,
  add column if not exists retomada_dono     text;
create index if not exists mari_conversas_retomada_aberta on public.mari_conversas (retomada_desde) where retomada_desde is not null and retomada_fim_em is null;

-- ── 3. pode ligar? null = liga; senão, o porquê ──
create or replace function public._retomada_nao_liga(c public.mari_conversas) returns text
language plpgsql stable security definer set search_path to 'public' as $$
declare v public.vendas; k text; r public.config_retomada;
begin
  if c.id is null then return 'sem conversa'; end if;
  if coalesce(c.nao_contatar, false) then return 'Não contatar'; end if;
  if c.canal <> 'whatsapp' or coalesce(c.chatwoot_conversation_id, '') = '' or coalesce(c.telefone, '') like '5500000000%' then
    return 'fora do WhatsApp';
  end if;
  if c.venda_id is not null then select * into v from public.vendas where id = c.venda_id; end if;
  if v.id is not null and (v.instalado_em is not null or v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme')) then
    return 'venda instalada';
  end if;
  -- regras duras, valham ou não como Saída
  k := case when c.credito_resultado = 'negado' then 'credito_negado'
            when v.biometria_status in ('reprovada', 'negada', 'negado') then 'reprovado_biometria'
            when c.funil_destino = 'fora_area' then 'cidade_nao_atendida'
            when c.funil_destino = 'sem_cobertura' then 'fachada_nao_atendida'
            when c.funil_destino in ('ja_cliente_nio', 'credito_negado', 'reprovado_biometria', 'teste_duplicada') then c.funil_destino end;
  if k is null and c.saida_motivo is not null then
    k := case when exists (select 1 from public.config_retomada x where x.chave = c.saida_motivo || ':' || coalesce(c.saida_sub, ''))
              then c.saida_motivo || ':' || c.saida_sub else c.saida_motivo end;
  end if;
  if k is null then return null; end if;
  select * into r from public.config_retomada where chave = k;
  if r.chave is null or r.liga then return null; end if;
  return r.nome;
end $$;

-- ── 4. começar ──
create or replace function public._retomada_iniciar(c public.mari_conversas, p_origem text, p_quem text default null) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare g uuid := gen_random_uuid(); dono text := nullif(btrim(coalesce(c.chatwoot_agente, '')), '');
begin
  update public.mari_conversas
     set retomada_desde = now(), retomada_origem = p_origem, retomada_passo = null, retomada_passo_em = null,
         retomada_fim_em = null, retomada_fim = null, retomada_dono = dono
   where id = c.id;
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[Retomada: o cliente parou de responder' || case p_origem when 'time_sem_resposta' then ' ao time' else '' end
          || ' — a Mari retoma o contato (D3 → Ligar → D7 → D15)' || coalesce('; dono guardado: ' || dono, '')
          || coalesce('; pedido por ' || p_quem, '') || ']', false);
  if c.canal = 'whatsapp' and coalesce(c.chatwoot_conversation_id, '') <> '' and coalesce(c.telefone, '') not like '5500000000%' then
    perform public._bo_enfileirar(g, 1, 'retomada', c.venda_id, c, 'nota', jsonb_build_object('content',
      '↩ Retomada: ' || case p_origem when 'time_sem_resposta' then 'o cliente não responde ao time há 24 h úteis'
                                      else 'Saída "Sem resposta"' end
      || ' — a Mari manda o D3 agora (em horário), o D7 e o D15; no D3 + 1 dia o NIOGEN pede para ligar. '
      || case when dono is not null then 'Se o cliente responder, a conversa volta para ' || dono || '.'
              else 'Se o cliente responder, a Mari atende.' end));
  end if;
  return jsonb_build_object('ok', true, 'origem', p_origem);
end $$;

-- ── 5. fechar ──
create or replace function public._retomada_fechar(c public.mari_conversas, p_motivo text) returns void
language plpgsql security definer set search_path to 'public' as $$
declare antes text; r jsonb; g uuid := gen_random_uuid();
begin
  update public.mari_conversas set retomada_fim_em = now(), retomada_fim = p_motivo where id = c.id;
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[Retomada terminou: ' || p_motivo || ']', false);
  if p_motivo <> 'sem resposta' then return; end if;
  if coalesce(c.funil_destino, 'em_andamento') = 'em_andamento' then
    -- veio do "cliente sumiu do time": no fim, a Saída "Sem resposta" (pela porta)
    begin
      antes := public._porta_situacao(c.id, null::uuid);
      r := public.porta('saida:sem_resposta', c.id, null::uuid, '{"obs": "Retomada sem resposta (D3, D7, D15)"}'::jsonb);
      perform public._porta_anotar('saida:sem_resposta', '_retomada_tick', c.id, null::uuid, antes, r);
    exception when others then
      insert into public.mari_erros (conversa_id, no_n8n, mensagem) values (c.id, '_retomada_fechar', 'Saída no fim da Retomada: ' || sqlerrm);
      insert into public.mari_turnos (conversa_id, papel, texto, pendente)
      values (c.id, 'sistema', '[Retomada sem resposta: a Saída não foi gravada sozinha (' || left(sqlerrm, 150) || ') — o time decide]', false);
    end;
  elsif c.canal = 'whatsapp' and coalesce(c.chatwoot_conversation_id, '') <> '' and coalesce(c.telefone, '') not like '5500000000%' then
    perform public._bo_enfileirar(g, 1, 'retomada', c.venda_id, c, 'nota',
      jsonb_build_object('content', '⛔ Retomada sem resposta (D3, D7, D15) — a Saída "Sem resposta" fica. Se o cliente escrever, a Mari responde.'));
  end if;
end $$;

-- ── 6. o relógio da Retomada (chamado pela varredura de 10 min: indicacao_tick → _porta_prazos) ──
create or replace function public._retomada_tick(p_agora timestamptz default now()) returns int
language plpgsql security definer set search_path to 'public' as $$
declare
  c      public.mari_conversas;
  ult    record;
  n      int := 0;
  v_h    numeric := coalesce(nullif(public._bo_cfg('retomada_time_horas_uteis', '24'::jsonb) #>> '{}', '')::numeric, 24);
  v_max  int := coalesce(nullif(public._bo_cfg('retomada_time_max_dias', '7'::jsonb) #>> '{}', '')::int, 7);
  prox   text; quando timestamptz; motivo text;
  teto   record; tq record;
  v_tpl  public.config_templates_waba;
  v_nome text; params jsonb; pay jsonb;
begin
  -- (a) começa: o time falou por último, lead sem venda, e o cliente não respondeu em N horas úteis. Com ou sem dono: desde a 0227
  -- o lead sem venda volta para a Mari em 24 h (_conversas_volta_mari), mas a conversa fica resolvida e a escada do n8n não toca nela.
  for c in
    select m.* from public.mari_conversas m
     cross join lateral (select t.papel, t.created_at from public.mari_turnos t
                          where t.conversa_id = m.id and t.papel in ('lead', 'mari', 'humano') order by t.created_at desc limit 1) u
     where m.canal = 'whatsapp' and coalesce(m.chatwoot_conversation_id, '') <> '' and coalesce(m.telefone, '') not like '5500000000%'
       and m.venda_id is null and coalesce(m.funil_destino, 'em_andamento') = 'em_andamento'
       and m.espera_ate is null and not coalesce(m.nao_contatar, false)
       and m.status in ('ativo', 'handoff_realizado')
       -- só onde a escada do n8n não toca: conversa resolvida/adiada ou com dono/time (aberta e sem dono, a escada normal já segue)
       and (coalesce(m.chatwoot_resolvida, false) or coalesce(m.chatwoot_status, 'open') <> 'open'
            or m.chatwoot_agente is not null or m.chatwoot_time is not null or coalesce(m.humano_atribuido, false) or coalesce(m.time_atribuido, false))
       and (m.retomada_desde is null or (m.retomada_fim_em is not null and m.retomada_desde < coalesce(m.ultima_msg_lead_at, '-infinity'::timestamptz)))
       and u.papel = 'humano' and u.created_at > p_agora - make_interval(days => v_max)
       and public._horas_uteis(u.created_at, p_agora) >= v_h
       and public._retomada_nao_liga(m) is null
       and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.status in ('pendente', 'executando'))
     limit 30
     for update of m skip locked
  loop
    perform public._retomada_iniciar(c, 'time_sem_resposta', null);
    n := n + 1;
  end loop;

  -- (b) anda: D3 (já) → Ligar (D3 + 1 dia, na Live) → D7 (+4 dias) → D15 (+12 dias) → fim (D15 + 48 h)
  select * into teto from public.contato_teto();
  for c in
    select m.* from public.mari_conversas m
     where m.retomada_desde is not null and m.retomada_fim_em is null
       and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.status in ('pendente', 'executando'))
     order by coalesce(m.retomada_passo_em, m.retomada_desde)
     limit 200
     for update of m skip locked
  loop
    if c.ultima_msg_lead_at > c.retomada_desde then perform public._retomada_fechar(c, 'respondeu'); continue; end if;
    motivo := public._retomada_nao_liga(c);
    if motivo is not null then perform public._retomada_fechar(c, 'não liga: ' || motivo); continue; end if;
    prox := case coalesce(c.retomada_passo, '') when '' then 'D3' when 'D3' then 'D7' when 'D7' then 'D15' when 'D15' then 'FIM' end;
    if prox is null then continue; end if;
    quando := case prox when 'D3' then c.retomada_desde when 'D7' then c.retomada_desde + interval '4 days'
                        when 'D15' then c.retomada_desde + interval '12 days' else c.retomada_passo_em + interval '48 hours' end;
    if p_agora < quando then continue; end if;
    if prox = 'FIM' then perform public._retomada_fechar(c, 'sem resposta'); n := n + 1; continue; end if;
    -- regras do envio: horário do contrato, nada no dia em que o time falou, teto, template aprovado
    if not public.mari_no_horario(p_agora, c.cidade) then continue; end if;
    if exists (select 1 from public.mari_turnos th where th.conversa_id = c.id and th.papel = 'humano'
                and (th.created_at at time zone 'America/Sao_Paulo')::date = (p_agora at time zone 'America/Sao_Paulo')::date) then continue; end if;
    select * into tq from public.mari_toques(c.telefone, p_agora);
    if (teto.dia is not null and tq.hoje >= teto.dia) or (teto.mes is not null and tq.mes >= teto.mes) then continue; end if;
    select * into v_tpl from public.config_templates_waba
     where nome = case prox when 'D3' then 'nio_retomada_lead_d3' when 'D7' then 'nio_retomada_lead_d7' else 'nio_retomada_lead_d15' end
       and status = 'APPROVED';
    if v_tpl.nome is null then continue; end if;
    v_nome := public.mari_cadencia_nome(c);
    params := case when prox = 'D3' then jsonb_build_array(v_nome, public.mari_cadencia_contexto(c)) else jsonb_build_array(v_nome) end;
    pay := jsonb_build_object('content', public.mari_render_template(v_tpl.nome, params), 'content_type', 'text',
      'message_type', 'outgoing', 'private', false, 'rotulo', 'Retomada ' || prox, 'texto_chave', 'retomada_' || lower(prox),
      'template', v_tpl.nome,
      'template_params', jsonb_build_object('name', v_tpl.nome, 'category', v_tpl.categoria, 'language', v_tpl.idioma,
        'processed_params', jsonb_build_object('body',
          coalesce((select jsonb_object_agg((o)::text, e) from jsonb_array_elements_text(params) with ordinality as t(e, o)), '{}'::jsonb))));
    perform public._bo_enfileirar(gen_random_uuid(), 1, 'retomada', c.venda_id, c, 'mensagem', pay);
    update public.mari_conversas set retomada_passo = prox, retomada_passo_em = p_agora where id = c.id;
    n := n + 1;
  end loop;
  return n;
end $$;

revoke all on function public._retomada_nao_liga(public.mari_conversas) from public, anon, authenticated;
revoke all on function public._retomada_iniciar(public.mari_conversas, text, text) from public, anon, authenticated;
revoke all on function public._retomada_fechar(public.mari_conversas, text) from public, anon, authenticated;
revoke all on function public._retomada_tick(timestamptz) from public, anon, authenticated;
grant execute on function public._retomada_nao_liga(public.mari_conversas) to service_role;
grant execute on function public._retomada_iniciar(public.mari_conversas, text, text) to service_role;
grant execute on function public._retomada_fechar(public.mari_conversas, text) to service_role;
grant execute on function public._retomada_tick(timestamptz) to service_role;

CREATE OR REPLACE FUNCTION public.mari_cadencia_avaliar(p_agora timestamp with time zone DEFAULT now(), p_conversa uuid DEFAULT NULL::uuid)
 RETURNS TABLE(conversa_id uuid, telefone text, canal text, chatwoot_conversation_id text, status text, etapa text, passo_atual text, passo_em timestamp with time zone, proximo_passo text, proximo_em timestamp with time zone, pode_enviar boolean, bloqueio text, acao text, template text, categoria text, params jsonb, texto text, excecao text, janela_aberta boolean, janela_fecha_em timestamp with time zone, toques_hoje integer, toques_mes integer, ligar_sugerido boolean, venda_id uuid)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  c        public.mari_conversas;
  v_tq     record;
  v_teto   record;   -- 0102: config_regras.contato_teto_dia/_mes (nulo = sem teto)
  L        timestamptz;   -- última msg do lead
  M        timestamptz;   -- última msg da Mari
  B        timestamptz;   -- base dos D (lead, retorno ou 1º contato)
  f1_at    timestamptz; f_base timestamptz; f_ant timestamptz; fats timestamptz[]; fval timestamptz[]; k int; k2 int; f2_at timestamptz; f2_ate timestamptz; a_ant timestamptz;
  d3_at    timestamptz; d7_at timestamptz; d15_at timestamptz; enc_at timestamptz;
  seq      text[]; ats timestamptz[]; validos timestamptz[];
  idx_atual int; i int; alvo int; prox int;
  v_passo  text; v_at timestamptz; v_bloq text; v_acao text; v_tpl text; v_cat text; v_params jsonb; v_txt text;
  v_exc    text; v_pode boolean; v_janela boolean; v_lig boolean;
  v_venda  record; vis_dia date; vis_ini timestamptz; v_proib text;
  v_turno  text; v_dia date;
  v_dom    boolean;   -- 0209: véspera no domingo/feriado (exceção do Ricardo, 15/11)
  v_inst   boolean;
  v_bio    boolean;   -- 0253 (D9): venda com biometria pendente e link já enviado — o lembrete é aviso da venda
  v_volta  timestamptz;   -- 0196   -- 0114: venda com instalação agendada (aviso/lembrete são da venda, não da conversa)
  v_hum    timestamptz;   -- 0274: última fala do time
  v_aviso_h numeric := coalesce(nullif(public._bo_cfg('aviso_venda_espera_horas', '2'::jsonb) #>> '{}', '')::numeric, 2);
  v_pausa  text := nullif(public._bo_cfg('retomada_pausa_regex', 'null'::jsonb) #>> '{}', '');
  l15_at   timestamptz; v_ab_em timestamptz; v_ab_tags jsonb;   -- 0070: lembrete leve da abertura B2
  semana   text[] := array['segunda-feira','terça-feira','quarta-feira','quinta-feira','sexta-feira','sábado','domingo'];
begin
  select * into v_teto from public.contato_teto();
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
    -- 0274: a Retomada (D3 → Ligar → D7 → D15) sai pela fila do NIOGEN, não pela escada do n8n
    elsif c.retomada_desde is not null and c.retomada_fim_em is null then v_bloq := 'Retomada pelo NIOGEN (D3 → Ligar → D7 → D15)';
    elsif c.humano_atribuido then v_bloq := 'humano atribuído no Chatwoot';
    elsif c.time_atribuido then v_bloq := 'time atribuído no Chatwoot';
    elsif c.chatwoot_resolvida then v_bloq := 'conversa resolvida no Chatwoot';
    -- 0227 (D10): ⏸ Aguardar pausa a cadência até a data (se o cliente escrever, a Mari responde normalmente)
    elsif c.espera_ate is not null and c.espera_ate > p_agora then
      v_bloq := 'em espera (⏸) até ' || to_char(c.espera_ate at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI');
    -- 0227 (D5): destino de saída pela regra (CEP fora da área, sem cobertura, já é cliente Nio) não recebe toque
    elsif c.funil_destino in ('fora_area', 'sem_cobertura', 'ja_cliente_nio') then
      v_bloq := 'destino de saída pela regra (' || c.funil_destino || ')';
    elsif c.canal = 'whatsapp' and c.telefone like '5500000000%' then v_bloq := 'telefone de teste';
    -- 0064 (08/11): venda "Em espera" (pendência com terceiro aberta) pausa toda a cadência até a pendência ser encerrada.
    elsif c.venda_id is not null and exists (select 1 from public.venda_pendencias vp
                                              where vp.venda_id = c.venda_id and vp.encerrada_em is null) then
      v_bloq := 'venda em espera (pendência com terceiro)';
    end if;
    -- 0114 (Ricardo, 10/11 ~20h40 "Sim, faça os dois"): o aviso do agendamento (C2) e o lembrete da véspera (C3) são da VENDA —
    -- saem com a conversa em qualquer estado (ativa ou em handoff), com humano/time atribuído, resolvida no Chatwoot ou com
    -- pendência aberta. Só "não contatar" e telefone de teste param.
    v_inst := c.venda_id is not null and exists (select 1 from public.vendas vi where vi.id = c.venda_id
                and vi.status = '2_aguardando_instalacao' and vi.instalacao_agendada_para > p_agora);
    -- 0253 (D9, regra de ouro 6: "aviso da venda sai sempre; só Saída e Não contatar barram"): o lembrete da biometria também.
    -- Antes, com o time atribuído (o normal depois do handoff de venda), o BIO1 ficava barrado e nunca saía.
    v_bio := c.venda_id is not null and exists (select 1 from public.vendas vb where vb.id = c.venda_id
               and vb.status in ('0_qualificado', '1_vendido', '2_aguardando_instalacao')
               and vb.biometria_status = 'pendente' and vb.biometria_link_enviado_em is not null);
    if (v_inst or v_bio) and not coalesce(c.nao_contatar, false) and not (c.canal = 'whatsapp' and c.telefone like '5500000000%') then
      v_bloq := null;
    end if;
    if c.status = 'handoff_realizado' or v_inst or v_bio then
      -- ── venda remota (05/11): biometria pendente e instalação agendada ──
      if v_bloq is not null then continue; end if;
      select v.id, v.status, v.biometria_status, v.biometria_link, v.biometria_link_enviado_em, v.forma_pagamento, v.biometria_validada_em,
             exists (select 1 from public.os_andamento oa where oa.venda_id = v.id and oa.estado is not null
                       and oa.estado <> 'aguardando_pagamento' and oa.mudou_em > v.biometria_validada_em) as cartao_ok,
             v.instalacao_agendada_para, v.instalacao_turno, v.logradouro, v.numero, v.complemento, v.bairro
        into v_venda
        from public.vendas v
       where v.id = c.venda_id and v.status <> 'saida';
      if not found then continue; end if;
      -- 0191: a biometria vem DEPOIS da OS — os lembretes valem também com a venda já contada (Ativação/Agenda).
      if v_venda.status in ('0_qualificado', '1_vendido', '2_aguardando_instalacao') and v_venda.biometria_status = 'pendente' and v_venda.biometria_link_enviado_em is not null then
        select q.fim into v_volta from public.biometria_quedas q
         where q.fim is not null and q.fim > p_agora - interval '48 hours' and q.inicio > v_venda.biometria_link_enviado_em - interval '15 days'
           and v_venda.biometria_link_enviado_em < q.fim
         order by q.fim desc limit 1;
        if v_volta is not null and (c.bio_volta_em is null or c.bio_volta_em < v_volta) then
          -- 0196: a biometria da Nio voltou depois de uma queda e este cliente ficou esperando: a Mari avisa (só na janela de 24 h).
          v_passo := 'BIOVOLTA'; v_at := v_volta;
          select replace(t.texto, '{nome}', public.mari_cadencia_nome(c)) into v_txt from public.config_mari_textos t where t.chave = 'mari_bio_voltou';
          v_acao := 'texto'; v_tpl := null;
          if not v_janela then v_bloq := 'janela de 24 h fechada: o time fala com o cliente (Live)'; end if;
        elsif c.bio_lembrete_em is null or c.bio_lembrete_em < v_venda.biometria_link_enviado_em then
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
      elsif v_venda.status = '2_aguardando_instalacao' and v_venda.instalacao_agendada_para > p_agora
            and v_venda.biometria_status = 'validada' then   -- 0191: confirmação da instalação só depois da biometria aprovada
        v_dia := (v_venda.instalacao_agendada_para at time zone 'America/Sao_Paulo')::date;
        v_turno := coalesce(v_venda.instalacao_turno,
                            case when extract(hour from v_venda.instalacao_agendada_para at time zone 'America/Sao_Paulo') >= 12
                                 then 'tarde' else 'manha' end);
        if v_venda.forma_pagamento = 'cartao' and not v_venda.cartao_ok and c.cartao_avisado_em is null then
          -- 0191 (Ricardo, 14/11): cartão — biometria aprovada, a Nio manda o link do cadastro do cartão. A Mari avisa com jeitinho.
          v_passo := 'CARTAO'; v_at := p_agora;
          v_params := jsonb_build_array(public.mari_cadencia_nome(c),
            semana[extract(isodow from v_dia)::int] || ', ' || to_char(v_dia, 'DD/MM'),
            case v_turno when 'tarde' then 'tarde, 13h às 17h' else 'manhã, 8h às 12h' end);
          select replace(replace(replace(t.texto, '{nome}', v_params ->> 0), '{dia}', v_params ->> 1), '{periodo}', v_params ->> 2)
            into v_txt from public.config_mari_textos t where t.chave = 'mari_cartao_aviso';
          if v_janela then v_acao := 'texto'; v_tpl := null;
          else v_acao := 'template'; v_tpl := 'nio_cartao_cadastro'; v_cat := 'UTILITY'; end if;
        elsif v_venda.forma_pagamento = 'cartao' and not v_venda.cartao_ok and c.cartao_lembrete_em is null then
          -- 0191: 24 h sem o cadastro do cartão → um lembrete gentil. 48 h → o time liga (v_jornada / Live).
          v_passo := 'CARTAO2';
          -- 0198 (Ricardo/Rogério, 14/11): a Nio agenda mesmo sem o cartão, mas sem o cadastro NÃO instala — o lembrete sai
          -- em 24 h ou na véspera da visita, o que vier primeiro (nunca antes de 2 h do aviso).
          vis_dia := v_dia - 1;
          while not public.mari_dia_toque(vis_dia, c.cidade) loop vis_dia := vis_dia - 1; end loop;
          v_at := greatest(c.cartao_avisado_em + interval '2 hours',
                    least(public.mari_proximo_horario(c.cartao_avisado_em + interval '24 hours', c.cidade),
                          public.mari_proximo_horario((vis_dia::timestamp) at time zone 'America/Sao_Paulo', c.cidade)));
          v_params := jsonb_build_array(public.mari_cadencia_nome(c),
            semana[extract(isodow from v_dia)::int] || ', ' || to_char(v_dia, 'DD/MM'),
            case v_turno when 'tarde' then 'tarde, 13h às 17h' else 'manhã, 8h às 12h' end);
          select replace(replace(replace(t.texto, '{nome}', v_params ->> 0), '{dia}', v_params ->> 1), '{periodo}', v_params ->> 2)
            into v_txt from public.config_mari_textos t where t.chave = 'mari_cartao_lembrete';
          if v_janela then v_acao := 'texto'; v_tpl := null;
          else v_acao := 'template'; v_tpl := 'nio_cartao_cadastro'; v_cat := 'UTILITY'; end if;
          if p_agora < v_at then v_bloq := 'aguardando o lembrete do cartão (24 h ou a véspera da visita)'; end if;
        elsif v_venda.forma_pagamento = 'cartao' and not v_venda.cartao_ok then
          continue;   -- 0191: lembrete já saiu; esperando o cadastro do cartão (48 h → o time liga)
        elsif c.instalacao_avisada_para is distinct from v_venda.instalacao_agendada_para then
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
          while not public.mari_dia_toque(vis_dia, c.cidade) loop vis_dia := vis_dia - 1; end loop;
          -- 0209 (Ricardo, 15/11: "nesse caso, pode abrir uma exceção e enviar no domingo"): se o aviso do agendamento (C2) saiu
          -- no dia da véspera permitida ou depois (ex.: instalação na segunda agendada no sábado à tarde), a véspera não teria dia
          -- nenhum — então ela sai no dia anterior à instalação mesmo sendo domingo/feriado, das 10h às 16h.
          v_dom := c.instalacao_avisada_em is not null
                   and vis_dia <= (c.instalacao_avisada_em at time zone 'America/Sao_Paulo')::date
                   and (v_dia - 1) > (c.instalacao_avisada_em at time zone 'America/Sao_Paulo')::date;
          if v_dom then vis_dia := v_dia - 1; end if;
          vis_ini := case when v_dom then (vis_dia::timestamp + time '10:00') at time zone 'America/Sao_Paulo'
                          else public.mari_proximo_horario((vis_dia::timestamp) at time zone 'America/Sao_Paulo', c.cidade) end;
          v_passo := 'VESPERA'; v_at := vis_ini;
          v_params := jsonb_build_array(public.mari_cadencia_nome(c), to_char(v_dia, 'DD/MM'),
                                        case v_turno when 'tarde' then 'tarde' else 'manhã' end);
          v_tpl := 'nio_lembrete_instalacao';
          if p_agora < v_at then v_bloq := 'aguardando a véspera da instalação';
          -- 0114: o texto diz "é amanhã" — nunca sai no próprio dia da instalação.
          elsif (p_agora at time zone 'America/Sao_Paulo')::date >= v_dia then v_bloq := 'a véspera passou (o lembrete diz "amanhã")';
          elsif p_agora > v_venda.instalacao_agendada_para - interval '2 hours' then v_bloq := 'instalação próxima demais';
          elsif c.instalacao_avisada_em > p_agora - interval '12 hours' then v_bloq := 'o aviso do agendamento (C2) saiu há menos de 12 h';
          elsif v_dom and p_agora >= (vis_dia::timestamp + time '16:00') at time zone 'America/Sao_Paulo' then v_bloq := 'a véspera passou (o lembrete diz "amanhã")';
          elsif v_dom then v_exc := 'véspera no domingo/feriado: sem outro dia antes da instalação';   -- passa pela regra do horário (só 10h–16h, acima)
          end if;
        else
          continue;
        end if;
        if v_passo in ('INSTALACAO', 'VESPERA') then
        v_txt := public.mari_render_template(v_tpl, v_params);
        -- 0114: aviso e lembrete da instalação saem SEMPRE como template (com os botões Confirmo/Tudo certo · Preciso remarcar),
        -- mesmo com a janela aberta — a resposta ao botão é o que preenche "Confirmou?" (0112).
        v_acao := 'template'; v_cat := 'UTILITY';
        end if;
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
      -- 0199 (trava A): a resposta do TIME também é resposta. Antes, o time respondia, devolvia para a Mari e a escada nunca
      -- recomeçava (M < L para sempre) — Leandro e Lucia Dias parados em silêncio.
      elsif L is not null and (M is null or M < L) and c.cadencia_passo = 'nenhum'
            and not exists (select 1 from public.mari_turnos th where th.conversa_id = c.id and th.papel = 'humano' and th.created_at >= L) then
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
          -- 0141 (Ricardo, 12/11): 5 cutucadas na janela de 24 h, em QUALQUER etapa: 15 min, 1 h, 3 h e 6 h depois da última fala
          -- REAL da Mari e a última chamada ~20 h depois da mensagem do cliente. Fora do horário do contrato (seg–sex 9–21, sáb
          -- 10–16, nunca domingo/feriado) vai para a abertura seguinte, com no mínimo 45 min entre duas, se ainda couber na janela
          -- (até L + 23 h); senão é pulada. O cliente respondeu → L muda e a escada recomeça. Substitui L15/F1/F2.
          -- 0199: a última fala real é da Mari OU do time (a cutucada não sai 15 min depois de uma fala velha da Mari
          -- quando o time acabou de responder).
          f_base := coalesce((select max(t.created_at) from public.mari_turnos t
                               where t.conversa_id = c.id and t.papel in ('mari', 'humano') and coalesce(t.tags ->> 'cadencia', '') = ''), M);
          fats := array[f_base + interval '15 minutes', f_base + interval '1 hour', f_base + interval '3 hours',
                        f_base + interval '6 hours', L + interval '20 hours'];
          -- 0274 (caso Kika, Ricardo 18/11): o cliente disse "vou ver / depois te mando" → 24 h sem cutucada (a escada segue no D3)
          if v_pausa is not null and exists (select 1 from public.mari_turnos tl where tl.conversa_id = c.id and tl.papel = 'lead'
                                               and tl.created_at > L - interval '10 minutes' and tl.texto ~* v_pausa) then
            for k in 1..5 loop
              if fats[k] < L + interval '24 hours' then fats[k] := null; end if;
            end loop;
          end if;
          f_ant := null;
          for k in 1..5 loop
            if c.cadencia_retorno_em is not null then fats[k] := null; continue; end if;
            if f_ant is not null and fats[k] < f_ant + interval '45 minutes' then fats[k] := f_ant + interval '45 minutes'; end if;
            if not public.mari_no_horario(fats[k], c.cidade) then fats[k] := public.mari_proximo_horario(fats[k], c.cidade); end if;
            if fats[k] is null or fats[k] >= L + interval '23 hours' then fats[k] := null; else f_ant := fats[k]; end if;
          end loop;
          fval := array[null, null, null, null, null]::timestamptz[];
          for k in 1..5 loop
            fval[k] := L + interval '23 hours';
            if k < 5 then
              for k2 in (k + 1)..5 loop
                if fats[k2] is not null then fval[k] := least(fats[k2], fval[k]); exit; end if;
              end loop;
            end if;
          end loop;
          d3_at := B + interval '3 days'; d7_at := B + interval '7 days'; d15_at := B + interval '15 days';
          seq := array['F1', 'F2', 'F3', 'F4', 'F5', 'D3', 'D7', 'D15', 'ENCERRAR'];
          ats := array[fats[1], fats[2], fats[3], fats[4], fats[5], d3_at, d7_at, d15_at, null];
          validos := array[fval[1], fval[2], fval[3], fval[4], fval[5], d7_at, d15_at,
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
          if seq[i] in ('L15', 'F1', 'F2', 'F3', 'F4', 'F5') and ats[i] <= p_agora and not public.mari_no_horario(p_agora, c.cidade) then continue; end if;
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
        if v_passo in ('L15', 'F1', 'F2', 'F3', 'F4', 'F5') then
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
        if v_passo in ('L15', 'F1', 'F2', 'F3', 'F4', 'F5') and not v_janela then v_bloq := 'janela de 24 h fechada'; end if;
        -- 0050 (Ricardo, 06/11): venda já criada NUNCA sai sozinha e não recebe a escada de templates de lead —
        -- só as cutucadas F1/F2 dentro da janela; o resto é do backoffice, pela venda.
        if c.venda_id is not null and v_passo not in ('L15', 'F1', 'F2', 'F3', 'F4', 'F5') then
          v_bloq := 'venda criada: o backoffice segue pela venda (a cadência não manda D3/D7/D15 nem encerra)';
        end if;
        v_lig := c.cadencia_passo = 'D3' and p_agora >= c.cadencia_passo_em + interval '1 day' and p_agora < B + interval '6 days';
      end if;
    end if;
    if v_passo is null then
      if v_bloq is null then continue; end if;
    end if;
    -- 0110 (Ricardo, 10/11 16h02): o time mandou (ou ligou) pela 🔥 oportunidade HOJE e o cliente ainda não respondeu →
    -- nenhum toque automático no mesmo dia (nunca dois toques num dia: um do humano e um da Mari); o próximo vai para o dia
    -- útil seguinte. Retorno pedido pelo cliente (v_exc) segue valendo. Cliente respondeu → L passa da mensagem e a regra é a de sempre.
    if v_bloq is null and v_passo is not null and v_exc is null and v_acao in ('texto', 'template')
       and v_passo not in ('INSTALACAO', 'VESPERA', 'CARTAO', 'CARTAO2', 'BIOVOLTA')   -- 0114: aviso/lembrete da instalação não são toque de venda
       and (exists (select 1 from public.oportunidades_log ol
                    where ol.conversa_id = c.id and ol.tipo = 'enviada'
                      and ol.criado_em > coalesce(L, '-infinity'::timestamptz)
                      and (ol.criado_em at time zone 'America/Sao_Paulo')::date = (p_agora at time zone 'America/Sao_Paulo')::date)
            -- 0226 (M7): vale para QUALQUER fala do time hoje (NIOGEN ou Chatwoot), não só o 🔥
            or exists (select 1 from public.mari_turnos th
                        where th.conversa_id = c.id and th.papel = 'humano'
                          and th.created_at > coalesce(L, '-infinity'::timestamptz)
                          and (th.created_at at time zone 'America/Sao_Paulo')::date = (p_agora at time zone 'America/Sao_Paulo')::date)) then
      v_bloq := 'o time falou com o cliente hoje (🔥 oportunidade): o toque vai para o próximo dia útil';
      v_at := greatest(v_at, public.mari_proximo_horario(((p_agora at time zone 'America/Sao_Paulo')::date + 1)::timestamp at time zone 'America/Sao_Paulo', c.cidade));
    end if;
    -- 0274 (caso Lucas, Ricardo 18/11): o LEMBRETE automático da venda espera 2 h depois de alguém do time falar com o cliente.
    -- O aviso imediato do que o time acabou de fazer (INSTALACAO com os botões, CARTAO com o link) sai na hora, como antes (E1, E2).
    if v_bloq is null and v_passo in ('BIO1', 'BIOVOLTA', 'CARTAO2', 'VESPERA') then
      select max(th.created_at) into v_hum from public.mari_turnos th where th.conversa_id = c.id and th.papel = 'humano';
      if v_hum is not null and v_hum > p_agora - make_interval(hours => v_aviso_h::int) then
        v_bloq := 'o time falou com o cliente há menos de ' || v_aviso_h::int || ' h: o aviso da venda espera';
        v_at := greatest(v_at, v_hum + make_interval(hours => v_aviso_h::int));
      end if;
    end if;
    -- ── regras duras do envio: horário, teto, filtro de texto ──
    if v_bloq is null and v_acao not in ('encerrar', 'ligar') then
      -- 0226 (M5): o retorno pedido pelo cliente também respeita a madrugada (só o horário, não as outras regras)
      if (v_exc is null or v_passo = 'RETORNO') and not public.mari_no_horario(p_agora, c.cidade) then
        v_bloq := 'fora do horário';
        v_at := greatest(v_at, public.mari_proximo_horario(p_agora, c.cidade));
      elsif v_teto.dia is not null and v_tq.hoje >= v_teto.dia then
        v_bloq := 'limite do dia (' || v_teto.dia || ' toques)';
        v_at := greatest(v_at, public.mari_proximo_horario(((p_agora at time zone 'America/Sao_Paulo')::date + 1)::timestamp at time zone 'America/Sao_Paulo', c.cidade));
      elsif v_teto.mes is not null and v_tq.mes >= v_teto.mes then
        v_bloq := 'limite do mês (' || v_teto.mes || ' toques)';
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
           processando_ate = null
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
    -- efeito 4
    nota := case when k.codigo = 'nao_contatar' then '🚫 Saída · ' || k.nome || ' — ' || p_quem || ', ' || agora_t || '. Ninguém fala com este cliente.'
                 when public.lead_situacao('x', 'saida', k.codigo, false, null) = 'saida_pode_voltar'
                   then '⛔ Saída · ' || k.nome || ' — ' || p_quem || ', ' || agora_t || '. Sem dono. Se o cliente escrever de novo, a Mari responde.'
                 else '⛔ Saída · ' || k.nome || ' — ' || p_quem || ', ' || agora_t || '. Saída definitiva: não reabre.' end;
    feito := feito || public._porta_projetar(c.id, 'saida', nota);
  end if;
  -- 0274 (casos Janaina e Greiciele, Ricardo 18/11): "Sem resposta" sem Retomada feita desde a última fala do cliente → a Mari
  -- faz a Retomada (D3 → Ligar → D7 → D15). Se o cliente responder, reabre como sempre; se não, no fim a Saída fica.
  if k.codigo = 'sem_resposta' and c.id is not null then
    select * into c2 from public.mari_conversas where id = c.id;
    if (c2.retomada_desde is null or (c2.retomada_fim_em is not null and c2.retomada_desde < coalesce(c2.ultima_msg_lead_at, '-infinity'::timestamptz)))
       and public._retomada_nao_liga(c2) is null then
      perform public._retomada_iniciar(c2, 'saida_sem_resposta', p_quem);
      feito := feito || 'a Mari faz a Retomada (D3 → Ligar → D7 → D15); se ninguém responder, a Saída fica'::text;
    end if;
  end if;
  if volta is not null then feito := feito || ('volta para a Live em ' || to_char(volta, 'DD/MM'))::text; end if;
  return jsonb_build_object('ok', true, 'feito', to_jsonb(feito), 'pedido_aberto', aberto and not coalesce(cancelou, false),
                            'resumo', '✓ ' || array_to_string(feito, ' · '));
end $function$;

CREATE OR REPLACE FUNCTION public._porta_prazos(p_agora timestamp with time zone DEFAULT now())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c     public.mari_conversas;
  ult   record;
  antes text;
  r     jsonb;
  n     int := 0;
  v_min int := coalesce(nullif(public._bo_cfg('esperando_fechar_min', '60'::jsonb) #>> '{}', '')::int, 60);
  v_h   numeric := coalesce(nullif(public._bo_cfg('handoff_sem_resposta_horas_uteis', '24'::jsonb) #>> '{}', '')::numeric, 24);
begin
  -- C10: o time falou por último, com uma pessoa dona, e o cliente não respondeu → fecha no Chatwoot com o dono guardado.
  -- Só com as automações do Chatwoot desligadas (a 24387 tirava o dono de toda conversa resolvida).
  if public._bo_cfg('chatwoot_automacoes', '"ligadas"'::jsonb) #>> '{}' = 'desligadas' then
    for c in
      select m.* from public.mari_conversas m
       where m.canal = 'whatsapp' and coalesce(m.chatwoot_conversation_id, '') <> '' and coalesce(m.telefone, '') not like '5500000000%'
         and coalesce(m.chatwoot_status, 'open') = 'open' and coalesce(m.funil_destino, 'em_andamento') = 'em_andamento'
         and (m.chatwoot_agente is not null or coalesce(m.humano_atribuido, false))
         and m.espera_ate is null and not coalesce(m.nao_contatar, false)
         and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.status in ('pendente', 'executando'))
       limit 30
       for update of m skip locked
    loop
      select t.papel, t.created_at into ult from public.mari_turnos t
       where t.conversa_id = c.id and t.papel in ('lead', 'mari', 'humano') order by t.created_at desc limit 1;
      if ult.papel is distinct from 'humano' or ult.created_at > p_agora - make_interval(mins => v_min) then continue; end if;
      begin
        antes := public._porta_situacao(c.id, null::uuid);
        r := public.porta('prazo:esperando_fechar', c.id, null::uuid, '{}'::jsonb);
        perform public._porta_anotar('prazo:esperando_fechar', '_porta_prazos', c.id, null::uuid, antes, r);
        n := n + 1;
      exception when others then
        insert into public.mari_erros (no_n8n, mensagem) values ('_porta_prazos', 'C10 ' || c.id::text || ': ' || sqlerrm);
      end;
    end loop;
  end if;

  -- C4: handoff para o time sem resposta em N horas úteis → a Mari volta
  for c in
    select m.* from public.mari_conversas m
     where m.status = 'handoff_realizado' and m.handoff_motivo in ('pedido_humano', 'objecao', 'urgencia_alta')
       and m.venda_id is null and coalesce(m.funil_destino, 'em_andamento') = 'em_andamento' and m.espera_ate is null
       and (coalesce(m.time_atribuido, false) or m.chatwoot_time is not null)
       and m.chatwoot_agente is null and not coalesce(m.humano_atribuido, false)
       and not exists (select 1 from public.mari_turnos t where t.conversa_id = m.id and t.papel = 'humano' and t.created_at > m.handoff_em)
       and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = m.id and a.status in ('pendente', 'executando'))
       and public._horas_uteis(m.handoff_em, p_agora) >= v_h
     limit 30
     for update of m skip locked
  loop
    begin
      antes := public._porta_situacao(c.id, null::uuid);
      r := public.porta('prazo:handoff_sem_resposta', c.id, null::uuid, '{}'::jsonb);
      perform public._porta_anotar('prazo:handoff_sem_resposta', '_porta_prazos', c.id, null::uuid, antes, r);
      n := n + 1;
    exception when others then
      insert into public.mari_erros (no_n8n, mensagem) values ('_porta_prazos', 'C4 ' || c.id::text || ': ' || sqlerrm);
    end;
  end loop;
  -- 0274: a Retomada (começa quando o cliente some do time; manda D3/D7/D15 pela fila do NIOGEN)
  begin
    n := n + public._retomada_tick(p_agora);
  exception when others then
    insert into public.mari_erros (no_n8n, mensagem) values ('_retomada_tick', sqlerrm);
  end;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION public._porta_turno_cliente()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare antes text; r jsonb; dentro boolean := coalesce(current_setting('porta.dentro', true), '') <> '';
begin
  -- 0274: o cliente respondeu durante a Retomada → ela fecha (a conversa segue com quem tinha: dono guardado ou a Mari)
  update public.mari_conversas set retomada_fim_em = now(), retomada_fim = 'respondeu'
   where id = new.conversa_id and retomada_desde is not null and retomada_fim_em is null and new.created_at >= retomada_desde;
  if found then
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (new.conversa_id, 'sistema', '[o cliente respondeu à Retomada — ela fecha; a conversa segue com quem tinha]', false);
  end if;
  if not exists (select 1 from public.mari_conversas m where m.id = new.conversa_id and m.espera_ate is not null and m.espera_ate > now()) then
    return null;
  end if;
  antes := public._porta_situacao(new.conversa_id, null::uuid);
  r := public.porta('cliente_escreveu', new.conversa_id, null::uuid, '{"acao": "fim_espera"}'::jsonb);
  if not dentro then   -- pela mari_entrada a casca já anota o evento
    perform public._porta_anotar('cliente_escreveu', '_porta_turno_cliente', new.conversa_id, null::uuid, antes, r);
  end if;
  return null;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('_porta_turno_cliente', new.conversa_id::text || ': ' || sqlerrm);
  return null;
end $function$;

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
                  to_char((c.retomada_desde + interval '4 days') at time zone 'America/Sao_Paulo', 'DD/MM'))
      from public.mari_conversas c
      join nomes n on n.id = c.id
     where c.retomada_desde is not null and c.retomada_fim_em is null and c.retomada_passo = 'D3'
       and c.retomada_passo_em < now() - interval '1 day' and not coalesce(c.nao_contatar, false)
       and not exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'humano' and t.created_at > c.retomada_passo_em)
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

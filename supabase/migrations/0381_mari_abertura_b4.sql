-- NIOGEN | supabase/migrations/0381_mari_abertura_b4.sql | 24/11/2026 — Claude Code / Opus 5.5
-- Prompt docs/Prompt_mari_abertura_b4_241126_1125.md (Cowork), autorizado pelo Ricardo em 24/11 15h09 (as 4 partes), 15h24 ("Sim, sem
-- portão" para o que mexe no mari_principal) e, nesta sessão, nas 3 perguntas: Parte 1 junto com a publicação da Mari; Parte 4 por 3
-- templates novos na Meta; BYAF do lembrete em texto, sem botões.
-- Etapa 0 (lida nesta sessão, meta_ads): B3 44 conversas, sem toque 21 (48 %) × B2 46/145 (32 %); CEP 75 % × 73 %; venda 16 % × 17 %.
-- A B3 não derrubou o "sem toque" — o ganho esperado da B4 segue de pé. 🔥 Oportunidades: 10–17/11 37 enviadas → 12 responderam; 18–24/11
-- 17 mostradas, 4 enviadas, 0 responderam (o uso caiu ~90 %). "Retomada · ligar": 48 marcadas "pular" (não estão acumulando).
--
-- O que muda (o motor 5b lê config_mari_textos a cada mensagem; o código novo do 5b/7/12 sobe junto, pelo deploy_mari):
--   1. Textos da abertura B4 (abertura_versao = 'b4_241126'): âncora pelo gancho do anúncio (1ª mensagem, texto) + corpo com o preço
--      "a partir de" do plano de entrada (só com referral de conjunto mapeado em abertura_preco_conjuntos; o valor sai de config_planos
--      pelo cluster do conjunto, em tempo de execução) e os botões 🏡 Pra minha casa · 🏪 Pro comércio · 🏠 Sou cliente Nio (2ª mensagem,
--      depois da pausa abertura_pausa_s). Sem referral: âncora padrão e corpo SEM preço. Prova social do viável (viabilidade_prova_social).
--      BYAF na 1ª cutucada de quem não deu endereço (abertura_lembrete_byaf).
--   2. _retomada_variante(c, nome): a variante do D3 pela etapa gravada — nunca deu endereço · viu os planos (cidade e "a partir de" do
--      cluster dele, só se viu os planos) · faltam os dados. Os 3 templates nascem PENDING (não saem antes de a Meta aprovar; até lá vale o
--      nio_retomada_lead_d3). O D7 e o D15 não mudam: repetir o texto do D3 no D7 quebraria a regra de ouro 6 (nunca repetida).
--      _retomada_tick e mari_cadencia_avaliar (a escada do n8n) escolhem pela mesma função. Desliga: retomada_variantes = 'nao'.
--   3. mari_cadencia_texto: F1 da conversa com abertura e sem endereço = abertura_lembrete_byaf (o 4a da mari_cadencia deixa esse texto
--      sair como está, sem o Claude reescrever).
--   4. mari_contexto: devolve 'anuncio' (referral da 0057: ad_id, ad_nome, adset_id, título) enquanto a Mari não falou.
--   5. _credito_avisar: o aviso de crédito aprovado pede também a preferência de período quando falta (Parte 3). Desliga:
--      credito_pede_periodo = 'nao'.
-- Volta sem deploy: abertura_versao = 'b3_191126' e abertura_botoes = 'rua,planos,cliente' (o 5b volta à B3 inteira); as funções voltam
-- pela versão de produção anterior (a deste arquivo é ela + os trechos marcados "0381").
-- Regra 15: textos, botões, pausa, conjuntos e o preço em config; templates em config_templates_waba (tabela global, sem parceiro_id —
-- como as outras linhas dela). Regra 20: (1) nenhuma situação nova; vez e prazo de sempre · (2) nenhuma função de estado muda (nenhuma
-- destas está em config_evento.funcao); dados.abertura_botao é registro, não estado · (3) consequência: a mesma fila (chatwoot_acoes) ·
-- (4) fonte única: conversa → NIOGEN; preço → config_planos · (5) conferência: nada novo — v_mari_abertura já separa por versão e a
-- Retomada já é conferida. Cenário X105. Desempenho: o 'anuncio' só é lido antes da 1ª fala da Mari (1 linha por telefone, índice
-- meta_referrals_tel_idx); nenhuma tela muda.
-- Medir em 7 dias (01/12), por abertura_versao: % que toca botão (B2 68 %, B3 52 %), % com CEP ou rua (B2 73 %, B3 75 %), venda com OS;
-- resposta à 1ª cutucada (BYAF) e ao D3 por variante (base D3 6 %, D7 11 %).

begin;

do $$
begin
  if (select texto from public.config_mari_textos where chave = 'abertura_versao') is distinct from 'b3_191126' then
    raise exception 'abertura_versao não é b3_191126 — alguém mudou a abertura; conferir antes';
  end if;
end $$;

-- 1. textos da abertura B4 e companhia (antes: abertura_versao = 'b3_191126', abertura_botoes = 'rua,planos,cliente'; o resto é novo)
insert into public.config_mari_textos (chave, texto) values
('abertura_botao_casa', $t$🏡 Pra minha casa$t$),
('abertura_botao_comercio', $t$🏪 Pro comércio$t$),
-- Parte 1 da abertura (sai na hora, texto). Gancho = o pedaço _H1_/_HA_… do nome do anúncio (mapa abaixo).
('abertura_ancora_padrao', $t$Oi! Tudo bem? 👋$t$),
('abertura_ancora_anuncio', $t$Oi! Vi que você chegou pelo nosso anúncio 👋$t$),
('abertura_ancora_2030', $t$Oi! Vi que você chegou pelo anúncio do preço travado até 2030 👋$t$),
('abertura_ancora_ainda', $t$Oi! Vi que você chegou pelo anúncio da fibra da Nio 👋$t$),
('abertura_ancora_rua', $t$Oi! Vi que você quer conferir se a fibra da Nio chega na sua rua 👋$t$),
('abertura_ancora_pordia', $t$Oi! Vi que você chegou pelo anúncio da fibra de 600 Mega 👋$t$),
('abertura_ancora_giga', $t$Oi! Vi que você chegou pelo anúncio do 1 Giga com 5G no celular 👋$t$),
('abertura_ancora_mapa', $t$H1=2030,HA=ainda,HB=rua,H2=pordia,H5=giga$t$),
-- Parte 2 (com os botões, depois da pausa). {preco_entrada} = o plano de varejo mais barato do cluster do conjunto (Regular: R$ 110).
('abertura_corpo_b4', $t$Aqui é a Mari, da Nio 😊

A fibra de 600 Mega sai a partir de R$ {preco_entrada}, e o valor que você fechar agora fica travado até janeiro de 2030, sem reajuste todo ano.$t$),
('abertura_corpo_b4_sem_preco', $t$Aqui é a Mari, da Nio 😊

Os planos de fibra vão de 600 Mega a 1 Giga, e o valor que você fechar agora fica travado até janeiro de 2030, sem reajuste todo ano.$t$),
('abertura_pergunta_b4', $t$Já abri aqui o mapa da Nio pra conferir seu endereço — me diz só uma coisa antes:$t$),
-- os botões não saíram (erro da Meta): o corpo + este pedido vão em texto pelo Chatwoot
('abertura_fallback_pedido', $t$Me manda a rua e o bairro (ou o CEP, se souber de cabeça) que em 1 minuto eu te digo se a fibra já passa na sua porta 😉$t$),
-- conjuntos (adset_id) cujas cidades são todas de um cluster — só eles levam preço na abertura. CJ_C3_MG, CJ_REGULAR, CJ_JF.
('abertura_preco_conjuntos', $t$120257957894920211=regular,120257741890120211=regular,120257741889280211=regular$t$),
('abertura_pausa_s', '6'),
('abertura_resp_casa', $t$Perfeito, residencial então.

Tô com o mapa aberto aqui — me manda a rua e o bairro (ou o CEP, se souber de cabeça) que em 1 minuto eu te digo se a fibra já passa na sua porta 😉$t$),
('abertura_resp_comercio', $t$Perfeito, pro seu comércio então.

Tô com o mapa aberto aqui — me manda a rua e o bairro do comércio (ou o CEP, se souber de cabeça) que em 1 minuto eu te digo se a fibra já passa na porta 😉$t$),
('abertura_lembrete_byaf', $t$Oi! É a Mari aqui da Nio. Só passando pra saber se você quer que eu confira o seu endereço — se não for o momento, sem problema nenhum, só me avisa 😊$t$),
-- 1.3: prova social no viável ({bairro} da viabilidade/CEP; sem bairro, "aí"). Vazio = desligado.
('viabilidade_prova_social', $t$Boa notícia: passa fibra {no_bairro} ✅ A rede da Nio já está puxada aí, e toda semana tem instalação nova no seu bairro 🙌$t$),
('retomada_variantes', 'sim'),
('credito_pede_periodo', 'sim')
on conflict (chave) do update set texto = excluded.texto;

update public.config_mari_textos set texto = 'casa,comercio,cliente' where chave = 'abertura_botoes';
update public.config_mari_textos set texto = 'b4_241126' where chave = 'abertura_versao';

-- 2. templates da Retomada por etapa (Parte 4). Submetidos por n8n/waba_template_retomada_b4.py; saem só com status APPROVED.
insert into public.config_templates_waba (nome, categoria, idioma, corpo, botoes, rodape, status, uso) values
('nio_retomada_d3_endereco', 'MARKETING', 'pt_BR', $t$Oi, {{1}}! É a Mari, da Nio 👋

Fiquei de conferir se a fibra da Nio passa na sua rua. Me manda a rua e o bairro (ou o CEP) que eu vejo em 1 minuto.

Se não for o momento, sem problema: é só me avisar 😊$t$, '["Quero ver a rua", "Depois eu vejo"]'::jsonb, null, 'PENDING',
 'D3 da Retomada/cadência — lead que nunca deu endereço (0381, B4 Parte 4)'),
('nio_retomada_d3_planos', 'MARKETING', 'pt_BR', $t$Oi, {{1}}! É a Mari, da Nio 👋

Ficou alguma dúvida sobre {{2}}, ou era outra coisa? Te ajudo a escolher por aqui.

Se não for o momento, sem problema: é só me avisar 😊$t$, '["Quero seguir", "Depois eu vejo"]'::jsonb, null, 'PENDING',
 'D3 da Retomada/cadência — lead que deu endereço e não escolheu plano; {{2}} = os planos da cidade dele (0381)'),
('nio_retomada_d3_dados', 'MARKETING', 'pt_BR', $t$Oi, {{1}}! É a Mari, da Nio 👋

Faltam só os seus dados pra eu fechar o seu pedido da Nio. Quer seguir?

Se não for o momento, sem problema: é só me avisar 😊$t$, '["Quero seguir", "Depois eu vejo"]'::jsonb, null, 'PENDING',
 'D3 da Retomada/cadência — lead que escolheu o plano e não passou os dados (0381)')
on conflict (nome) do nothing;

-- 3. a variante do D3 pela etapa gravada (nunca por adivinhação)
create or replace function public._retomada_variante(c public.mari_conversas, p_nome text)
returns table (tpl text, params jsonb)
language sql stable set search_path to 'public' as $$
  with e as (
    select case
      when coalesce((select t.texto from public.config_mari_textos t where t.chave = 'retomada_variantes'), 'sim') = 'nao' then null
      when c.cep is null and coalesce(c.dados ->> 'rua_informada', '') = '' then 'endereco'
      when nullif(btrim(coalesce(c.plano_escolhido, '')), '') is not null or c.funil_etapa = 'qualificada' then 'dados'
      else 'planos' end as etapa
  ), p as (
    -- o "a partir de" só para quem VIU os planos, com o preço do cluster dele (Regular × BTU), da tabela vigente
    select min(cp.preco) as preco from public.config_planos cp
     where c.funil_etapa = 'viu_planos' and c.cluster is not null and cp.ativo and cp.cluster = c.cluster and cp.portfolio = 'varejo'
       and coalesce(cp.variante, '') not ilike '%nfid%' and (cp.vigencia_fim is null or cp.vigencia_fim >= current_date)
  )
  select case e.etapa when 'endereco' then 'nio_retomada_d3_endereco' when 'planos' then 'nio_retomada_d3_planos'
                      when 'dados' then 'nio_retomada_d3_dados' end,
         case when e.etapa = 'planos' then jsonb_build_array(p_nome,
                case when c.cidade is null then 'os planos de fibra da Nio'
                     when p.preco is null then 'os planos de fibra em ' || c.cidade
                     else 'os planos de fibra em ' || c.cidade || ', a partir de R$ '
                          || case when p.preco = trunc(p.preco) then trunc(p.preco)::text else replace(p.preco::text, '.', ',') end || ' por mês' end)
              when e.etapa is not null then jsonb_build_array(p_nome) end
    from e cross join p
   where e.etapa is not null
$$;
revoke all on function public._retomada_variante(public.mari_conversas, text) from public, anon, authenticated;
comment on function public._retomada_variante(public.mari_conversas, text) is
  'Variante do D3 (Retomada e escada do n8n) pela etapa gravada: endereco · planos · dados. 0381 (B4, Parte 4). Desliga: config_mari_textos.retomada_variantes = nao.';

-- 4. funções de produção + os trechos "0381"

CREATE OR REPLACE FUNCTION public._retomada_tick(p_agora timestamp with time zone DEFAULT now())
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c      public.mari_conversas;
  ult    record;
  n      int := 0;
  v_h    numeric := coalesce(nullif(public._bo_cfg('retomada_time_horas_uteis', '24'::jsonb) #>> '{}', '')::numeric, 24);
  v_max  int := coalesce(nullif(public._bo_cfg('retomada_time_max_dias', '7'::jsonb) #>> '{}', '')::int, 7);
  prox   text; quando timestamptz; motivo text;
  teto   record; tq record;
  v_tpl  public.config_templates_waba;
  v_nome text; params jsonb; pay jsonb; v_clique boolean; v_tnome text;
  v_vtpl text; v_vpar jsonb;   -- 0381: variante do D3 pela etapa
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

  -- (b) anda (0305): o relógio conta da base (_retomada_base): D3 = base + 3 dias → Ligar (D3 + 1 dia, na Live) → D7 = base + 7 dias
  --     (≥ D3 + 4) → D15 = base + 15 dias (≥ D7 + 8) → fim (D15 + 48 h). Retomada pelo time: base = abertura − 3 dias (D3 na hora).
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
    quando := public._retomada_quando(c, prox);
    if p_agora < quando then continue; end if;
    if prox = 'FIM' then perform public._retomada_fechar(c, 'sem resposta'); n := n + 1; continue; end if;
    -- regras do envio: horário do contrato, nada no dia em que o time falou, teto, template aprovado
    if not public.mari_no_horario(p_agora, c.cidade) then continue; end if;
    if exists (select 1 from public.mari_turnos th where th.conversa_id = c.id and th.papel = 'humano'
                and (th.created_at at time zone 'America/Sao_Paulo')::date = (p_agora at time zone 'America/Sao_Paulo')::date) then continue; end if;
    select * into tq from public.mari_toques(c.telefone, p_agora);
    if (teto.dia is not null and tq.hoje >= teto.dia) or (teto.mes is not null and tq.mes >= teto.mes) then continue; end if;
    -- 0305: quem só tocou em "Quero ver a oferta" (Fila Vero) e nunca escreveu recebe o D3 do clique, nunca o "parou no meio"
    v_clique := prox = 'D3' and public._retomada_so_clicou(c);
    v_tnome := case when v_clique then 'nio_retomada_clique_d3' when prox = 'D3' then 'nio_retomada_lead_d3'
                    when prox = 'D7' then 'nio_retomada_lead_d7' else 'nio_retomada_lead_d15' end;
    -- 0381 (B4, Parte 4): o D3 de quem conversou sai pela variante da etapa gravada (nunca deu endereço · viu os planos · faltam os
    -- dados), quando o template dela já foi aprovado pela Meta; sem aprovação (ou retomada_variantes = 'nao'), o de sempre.
    v_vtpl := null; v_vpar := null;
    if prox = 'D3' and not v_clique then
      select vr.tpl, vr.params into v_vtpl, v_vpar from public._retomada_variante(c, public.mari_cadencia_nome(c)) vr;
      if v_vtpl is not null and exists (select 1 from public.config_templates_waba w where w.nome = v_vtpl and w.status = 'APPROVED') then
        v_tnome := v_vtpl;
      else
        v_vtpl := null; v_vpar := null;
      end if;
    end if;
    v_tpl := null;
    select * into v_tpl from public.config_templates_waba where nome = v_tnome and status = 'APPROVED';
    if v_tpl.nome is null then
      if v_clique then
        -- o template do clique ainda não foi aprovado pela Meta: o D3 não sai e a Retomada segue para o D7 na data certa
        update public.mari_conversas set retomada_passo = 'D3', retomada_passo_em = p_agora where id = c.id;
        insert into public.mari_turnos (conversa_id, papel, texto, pendente)
        values (c.id, 'sistema', '[Retomada: o D3 de quem só clicou na oferta não saiu — o template nio_retomada_clique_d3 ainda não foi aprovado pela Meta; segue o D7]', false);
        n := n + 1;
      end if;
      continue;
    end if;
    v_nome := public.mari_cadencia_nome(c);
    params := case when v_vtpl is not null then v_vpar
                   when prox = 'D3' and not v_clique then jsonb_build_array(v_nome, public.mari_cadencia_contexto(c)) else jsonb_build_array(v_nome) end;
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
end $function$;

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
  v_vtpl   text; v_vpar jsonb;   -- 0381: variante do D3 pela etapa
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
    -- 0379 (agenda de retornos): a espera não segura o RETORNO combinado que chegou a hora (a Mari chama; a espera segue até 2 h depois)
    elsif c.espera_ate is not null and c.espera_ate > p_agora
          and not (c.agendamento_retorno is not null and c.agendamento_retorno <= p_agora
                   and c.agendamento_retorno > coalesce(c.ultima_msg_lead_at, c.created_at)
                   and (c.cadencia_retorno_em is null or c.cadencia_retorno_em < c.agendamento_retorno)) then
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
                       and oa.pedido = btrim(v.nio_pedido)   -- 0278: só a OS atual (a OS cancelada de um pedido reemitido não conta)
                       and oa.estado not in ('aguardando_pagamento', 'rascunho', 'cancelada', 'cancelando', 'reprovada')
                       and oa.mudou_em > v.biometria_validada_em) as cartao_ok,
             v.nio_pedido,
             (select oa.estado from public.os_andamento oa where oa.pedido = btrim(v.nio_pedido)
                and oa.estado in ('rascunho', 'cancelada', 'cancelando', 'reprovada') limit 1) as os_parada,
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
          -- 0381 (B4, Parte 4): D3 pela variante da etapa, se o template dela já foi aprovado (igual ao _retomada_tick).
          if v_passo = 'D3' then
            select vr.tpl, vr.params into v_vtpl, v_vpar from public._retomada_variante(c, public.mari_cadencia_nome(c)) vr;
            if v_vtpl is not null and exists (select 1 from public.config_templates_waba w where w.nome = v_vtpl and w.status = 'APPROVED') then
              v_tpl := v_vtpl; v_params := v_vpar;
            end if;
          end if;
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
    -- 0278 (caso de 18/11, troca da forma de pagamento): a Consulta OS diz que a OS da venda foi cancelada ou virou rascunho no portal
    -- (o time está reemitindo o pedido) → nenhum aviso da venda sai com dado velho. Volta sozinho quando a OS nova é gravada
    -- (Reemitir pedido) ou a OS volta a andar. O motivo aparece na trilha dos lembretes da ficha.
    if v_bloq is null and v_passo in ('BIO1', 'BIO3', 'BIOVOLTA', 'CARTAO', 'CARTAO2', 'INSTALACAO', 'VESPERA') then
      -- (v_venda só existe no ramo da venda; estes passos só nascem lá)
      if v_venda.os_parada is not null then
        v_bloq := 'a OS ' || coalesce(v_venda.nio_pedido, '') || ' está '
               || case v_venda.os_parada when 'rascunho' then 'em rascunho (Draft)' when 'cancelando' then 'em cancelamento' else v_venda.os_parada end
               || ' no portal: o aviso da venda espera a OS nova (ficha › Reemitir pedido)';
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

CREATE OR REPLACE FUNCTION public.mari_cadencia_texto(c mari_conversas, p_passo text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$

  select case

    -- 0141/0142: F3/F4 reaproveitam o F1/F2 da etapa; F5 é a última chamada da janela (reserva — o texto normal vem da Mari).

    when p_passo = 'F5' then 'Vou deixar o seu atendimento separado até amanhã 😊 Quer que eu siga com o seu pedido?'

    when p_passo in ('F3', 'F4') then public.mari_cadencia_texto(c, case p_passo when 'F3' then 'F1' else 'F2' end)

    when p_passo = 'L15' then coalesce((select t.texto from public.config_mari_textos t where t.chave = 'abertura_lembrete'),

                                       'Se ficar mais fácil, me manda só o nome da rua e o bairro 😉')

    -- sem CEP: abertura B2 pede só o CEP (ou rua e bairro); sem B2, CEP e número

    when c.cep is null and coalesce(c.dados ->> 'abertura', '') <> '' then case p_passo

      -- 0381 (B4, 1.4): BYAF — vira decisão, não repete o pedido. Sem a chave, o texto de antes.
      when 'F1' then coalesce(nullif((select t.texto from public.config_mari_textos t where t.chave = 'abertura_lembrete_byaf'), ''),
                              'Conseguiu achar o CEP? Com ele (ou a rua e o bairro) eu já te mostro os planos da sua região 😊')

      else 'Passando aqui rapidinho: se me mandar o CEP (ou a rua e o bairro), te mostro os planos da sua região 😊' end

    when c.cep is null then case p_passo

      when 'F1' then 'Conseguiu ver o CEP e o número da casa? Com eles eu já te mostro as opções 😊'

      else 'Passando aqui rapidinho: se me mandar o CEP e o número, te mostro os planos da sua região 😊' end

    when nullif(btrim(coalesce(c.numero, '')), '') is null then case p_passo

      when 'F1' then 'Só falta o número da casa pra eu te mostrar as opções daí 😊'

      else 'Passando aqui rapidinho: me manda o número da casa que eu já te mostro os planos da sua região 😊' end

    when c.elegibilidade is null and c.complemento is null and coalesce(c.dados ->> 'referencia', '') = ''

         and coalesce(c.dados ->> 'complemento_ok', '') = '' then case p_passo

      when 'F1' then 'Tem complemento (casa A ou B, apto, bloco) ou um ponto de referência perto da sua casa? Com isso eu já sigo 😊'

      else 'Passando aqui rapidinho: me conta se tem complemento ou um ponto de referência perto da sua casa, que eu sigo com as opções 😊' end

    when c.elegibilidade is null then case p_passo

      when 'F1' then 'Só falta essa: hoje você usa internet de qual operadora? Com isso eu já te mostro as opções 😊'

      else 'Passando aqui rapidinho: me conta qual operadora você usa hoje que eu sigo com as opções 😊' end

    when c.plano_escolhido is null then case p_passo

      when 'F1' then 'Ficou alguma dúvida sobre os planos? Se quiser, te ajudo a escolher 😊'

      else 'Separei as opções da sua região. Qual delas te chamou mais atenção? 😊' end

    when coalesce(c.etapa, '') <> 'resumo' then case p_passo   -- plano escolhido: falta dado (mesmo com a etapa atrasada)

      when 'F1' then 'Estamos quase lá! Falta só ' || public.mari_cadencia_campo_falta(c) || ' pra eu adiantar seu pedido 😊'

      else 'Seu pedido está quase pronto — me passa ' || public.mari_cadencia_campo_falta(c) || ' quando puder? 😊' end

    else case p_passo   -- resumo (e qualquer etapa nova)

      when 'F1' then 'Conseguiu conferir os dados? Se estiver tudo certo, é só me confirmar 😊'

      else 'Seus dados estão prontos pra seguir — me confirma que está tudo certo? 😊' end

  end

$function$;

CREATE OR REPLACE FUNCTION public.mari_contexto(p_conversa uuid, p_cep text DEFAULT NULL::text, p_numero text DEFAULT NULL::text, p_complemento text DEFAULT NULL::text, p_viacep jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_conv    public.mari_conversas;
  v_cluster text;
  v_planos  jsonb;
  v_dfv     record;
  v_dfvj    jsonb;
  v_cep     text := nullif(regexp_replace(coalesce(p_cep, ''), '\D', '', 'g'), '');
begin
  select * into v_conv from public.mari_conversas where id = p_conversa;
  if not found then return jsonb_build_object('erro', 'conversa inexistente'); end if;

  -- CEP novo: troca o endereço (e zera o que dependia dele).
  if v_cep is not null and v_cep is distinct from v_conv.cep then
    update public.mari_conversas
       set cep = v_cep, numero = null, complemento = null, endereco_cep = null, cidade = null, uf = null,
           cluster = null, dentro_area = null, dfv_resultado = null, dfv_detalhe = null
     where id = p_conversa;
  end if;

  if p_viacep is not null and not coalesce((p_viacep ->> 'erro')::boolean, false) and v_cep is not null then
    update public.mari_conversas
       set endereco_cep = p_viacep,
           cidade = p_viacep ->> 'localidade',
           uf = p_viacep ->> 'uf'
     where id = p_conversa;
  end if;

  if nullif(btrim(coalesce(p_numero, '')), '') is not null then
    update public.mari_conversas set numero = btrim(p_numero) where id = p_conversa
       and numero is distinct from btrim(p_numero);
  end if;
  if p_complemento is not null then
    update public.mari_conversas set complemento = nullif(btrim(p_complemento), '') where id = p_conversa;
  end if;

  select * into v_conv from public.mari_conversas where id = p_conversa;

  if v_conv.cidade is not null then
    v_cluster := public.cluster_da_area(v_conv.cidade, v_conv.uf, v_conv.endereco_cep ->> 'bairro');
    update public.mari_conversas
       set cluster = v_cluster, dentro_area = v_cluster is not null
     where id = p_conversa;
  end if;

  -- DFV (base só de JF): uma vez por endereço.
  if v_conv.cep is not null and v_conv.numero is not null
     and lower(coalesce(v_conv.cidade, '')) = 'juiz de fora'
     and (v_conv.dfv_resultado is null or p_numero is not null or p_complemento is not null) then
    begin
      select * into v_dfv from public.dfv_consultar(v_conv.cep, v_conv.numero, v_conv.complemento);
      v_dfvj := jsonb_strip_nulls(jsonb_build_object(
        'resultado', v_dfv.resultado, 'hp_livre', v_dfv.hp_livre, 'hc_tot', v_dfv.hc_tot, 'hp_tot', v_dfv.hp_tot,
        'tipo_edificacao', v_dfv.tipo_edificacao, 'faixa_credito', v_dfv.faixa_credito,
        'classificacao', v_dfv.classificacao, 'bairro', v_dfv.bairro, 'particao', v_dfv.particao,
        'opcoes', v_dfv.opcoes));
    exception when others then
      v_dfvj := jsonb_build_object('resultado', 'erro', 'erro', sqlerrm);
      insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
      values (p_conversa, 'mari_contexto/dfv', sqlerrm, jsonb_build_object('cep', v_conv.cep, 'numero', v_conv.numero));
    end;
    update public.mari_conversas set dfv_resultado = v_dfvj ->> 'resultado', dfv_detalhe = v_dfvj where id = p_conversa;
  end if;

  select * into v_conv from public.mari_conversas where id = p_conversa;

  if v_conv.cluster is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
             'codigo', codigo, 'nome', nome, 'portfolio', portfolio, 'variante', variante,
             'velocidade_mb', velocidade_mb, 'wifi', wifi, 'internet_5g', internet_5g, 'inclusos', to_jsonb(inclusos),
             'preco', preco, 'preco_cartao', preco_cartao, 'taxa_habilitacao', taxa_habilitacao,
             'isencao_meses', isencao_meses) order by portfolio desc, variante, preco), '[]'::jsonb)
      into v_planos
      from public.config_planos
     where ativo and cluster = v_conv.cluster
       and (vigencia_fim is null or vigencia_fim >= current_date);
  end if;

  return jsonb_build_object(
    'conversa', to_jsonb(v_conv) - 'processando_ate' - 'ultima_entrada_ts',
    'planos', coalesce(v_planos, '[]'::jsonb),
    -- 0099: horário do contrato agora (seg–sex 9–21, sáb 10–16, sem domingo nem feriado da cidade) — prazo do consultor.
    'no_horario', public.mari_atendimento_no_horario(now(), v_conv.cidade),
    -- 0381 (B4): o anúncio que abriu a conversa (referral da 0057), só enquanto a Mari não falou — a abertura ancora no gancho e
    -- só cita o preço "a partir de" com o conjunto mapeado em config_mari_textos.abertura_preco_conjuntos.
    'anuncio', case when v_conv.ultima_msg_mari_at is null then (
      select jsonb_build_object('ad_id', r.ad_id, 'ad_nome', a.ad_nome, 'adset_id', a.adset_id, 'titulo', r.titulo)
        from public.meta_referrals r
        left join lateral (select x.ad_nome, x.adset_id from public.v_mari_conversa_anuncio x where x.ad_id = r.ad_id and x.ad_nome is not null limit 1) a on true
       where r.telefone = v_conv.telefone and r.source_type = 'ad' and r.ad_id is not null
         and r.recebido_em between v_conv.created_at - interval '10 minutes' and now() + interval '1 minute'
       order by r.recebido_em desc limit 1) end);
end;
$function$;

CREATE OR REPLACE FUNCTION public._credito_avisar(p_conversa uuid, p_venda uuid, p_res text, p_formas jsonb, p_origem text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c       public.mari_conversas;
  v       public.vendas;
  g       uuid := gen_random_uuid();
  v_fp    text;
  v_fpcod text;
  v_lib   text[];
  v_chave text;
  v_flag  text;
  v_vars  jsonb := '{}'::jsonb;
  r       jsonb;
  v_formas_txt text;
  v_plano text;
  v_arr   text[];
  v_falta text;
  v_per   text;   -- 0381: preferência de período da instalação
begin
  if p_conversa is not null then
    select * into c from public.mari_conversas where id = p_conversa;
  else
    select * into c from public.mari_conversas where venda_id = p_venda and canal = 'whatsapp' order by created_at desc limit 1;
  end if;
  if c.id is null then return jsonb_build_object('aviso', null, 'motivo', 'sem conversa'); end if;
  if p_venda is not null then select * into v from public.vendas where id = p_venda;
  elsif c.venda_id is not null then select * into v from public.vendas where id = c.venda_id; end if;

  if c.canal <> 'whatsapp' or coalesce(c.chatwoot_conversation_id, '') = '' or coalesce(c.telefone, '') like '5500000000%' then
    return jsonb_build_object('aviso', null, 'motivo', 'sem canal');
  end if;
  -- Saída barra (regra de ouro 6). Não contatar barra dentro do _bo_mensagem (fica "bloqueada", visível na fila).
  if coalesce(v.status, '') = 'saida' or c.saida_motivo is not null or c.quadro_encerrada_motivo is not null
     or (c.funil_destino is not null and c.funil_destino not in ('em_andamento')) then
    return jsonb_build_object('aviso', null, 'motivo', 'em Saída');
  end if;
  -- crédito lido no endereço PADRÃO não vale para o do cliente (0204): o time consulta de novo antes de avisar.
  if p_venda is null and coalesce(c.credito_endereco, '') = 'padrao' and p_res like 'aprovado%' then
    return jsonb_build_object('aviso', null, 'motivo', 'crédito lido no endereço padrão');
  end if;
  -- uma vez: o mesmo aviso (mesmo resultado) nos últimos 30 min não sai de novo — Mari e botão gravando o mesmo crédito.
  if exists (select 1 from public.chatwoot_acoes a
              where a.conversa_id = c.id and a.tipo = 'mensagem' and a.payload ->> 'rotulo' = 'aviso do crédito: ' || p_res
                and a.criada_em > now() - interval '30 minutes' and a.status <> 'cancelada') then
    return jsonb_build_object('aviso', null, 'motivo', 'já avisado');
  end if;

  -- o botão/extensão grava "aprovado" na venda, mas a consulta da Mari (mais detalhada) já disse SÓ CARTÃO ou PARCIAL nesta conversa:
  -- não avisa "aprovado" — a extensão grava "aprovado" sem ler o popup em um caminho (content.js r.e5). Fica a palavra da Mari.
  if p_venda is not null and p_res = 'aprovado' and coalesce(c.credito_resultado, '') in ('aprovado_cartao', 'aprovado_parcial') then
    return jsonb_build_object('aviso', null, 'motivo', 'a venda diz aprovado, a consulta da Mari disse ' || c.credito_resultado || ' — vale a da Mari');
  end if;
  -- a forma que o cliente escolheu durante a conversa (Ricardo); sem ela, a da venda.
  v_fp := coalesce(nullif(c.forma_pagamento, ''), nullif(v.forma_pagamento, ''));
  v_fpcod := case v_fp when 'boleto' then 'BOLETO' when 'cartao' then 'CREDITO' when 'debito' then 'DACC' end;
  v_lib := array(select upper(x) from jsonb_array_elements_text(case when jsonb_typeof(p_formas) = 'array' then p_formas else '[]'::jsonb end) x);

  if p_res in ('aprovado_todas', 'aprovado')
     or (p_res = 'aprovado_parcial' and (v_fpcod is null or v_fpcod = any (v_lib)))
     or (p_res in ('aprovado_cartao', 'so_cartao') and v_fp = 'cartao') then
    v_chave := 'bo_credito_aprovado'; v_flag := 'credito_aprovado_avisado';
    v_vars := jsonb_build_object('forma', case v_fp when 'boleto' then ', no boleto' when 'cartao' then ', no cartão de crédito'
                                                    when 'debito' then ', no débito em conta' else '' end);
    -- 0366 (L-248, Ricardo 23/11): "Nesse balão não pode falar ainda de biometria, porque ele ainda não havia escolhido o plano e nem
    -- a forma de pagamento" — a biometria só sai quando o time faz o pedido no portal. Sem plano ou sem forma, o aviso pede o que falta.
    v_plano := coalesce(nullif(btrim(coalesce(c.plano_escolhido, '')), ''), v.plano_id::text);
    -- 0381 (B4, Parte 3): o link da biometria sai no "Continuar" do crédito, antes da agenda — o aviso pede também a preferência de
    -- período quando falta (só preferência; quem confirma a data é o time). Desliga sem deploy: credito_pede_periodo = 'nao'.
    v_per := case when coalesce((select t.texto from public.config_mari_textos t where t.chave = 'credito_pede_periodo'), 'sim') = 'nao' then 'x'
                  else nullif(btrim(coalesce(c.instalacao_preferencia, v.instalacao_preferencia, v.instalacao_turno, '')), '') end;
    if v_fp is null or v_plano is null or v_per is null then
      v_arr := array(select case x when 'BOLETO' then 'boleto' when 'CREDITO' then 'cartão de crédito' when 'DACC' then 'débito em conta' else lower(x) end
                       from unnest(case when coalesce(array_length(v_lib, 1), 0) = 0 or p_res in ('aprovado_todas', 'aprovado')
                                        then array['BOLETO', 'CREDITO', 'DACC'] else v_lib end) x order by x);
      v_formas_txt := case when array_length(v_arr, 1) > 1
                           then array_to_string(v_arr[1:array_length(v_arr, 1) - 1], ', ') || ' ou ' || v_arr[array_length(v_arr, 1)]
                           else v_arr[1] end;
      v_falta := case when v_fp is null and v_plano is null then 'o plano e a forma de pagamento (' || v_formas_txt || ')'
                      when v_fp is null then 'a forma de pagamento: ' || v_formas_txt
                      when v_plano is null then 'o plano que você escolheu' end;
      if v_per is null then
        v_falta := case when v_falta is null then 'se prefere a instalação de manhã ou à tarde'
                        else replace(v_falta, 'o plano e a forma', 'o plano, a forma') || ' e se prefere a instalação de manhã ou à tarde' end;
      end if;
      v_chave := 'bo_credito_aprovado_falta';
      v_vars := v_vars || jsonb_build_object('falta', v_falta);
    end if;
  elsif p_res = 'aprovado_parcial' then
    v_formas_txt := (select string_agg(case x when 'BOLETO' then 'boleto' when 'CREDITO' then 'cartão de crédito' when 'DACC' then 'débito em conta'
                                              else lower(x) end, ' ou ' order by x) from unnest(v_lib) x);
    if v_formas_txt is null then return jsonb_build_object('aviso', null, 'motivo', 'aprovado parcial sem formas'); end if;
    v_chave := 'bo_credito_forma'; v_flag := 'credito_forma_avisado';
    v_vars := jsonb_build_object('forma', case v_fp when 'boleto' then 'no boleto' when 'cartao' then 'no cartão' else 'no débito em conta' end,
                                 'formas', v_formas_txt);
  elsif p_res in ('aprovado_cartao', 'so_cartao') then
    v_chave := 'bo_credito_cartao'; v_flag := 'credito_cartao_avisado';
  elsif p_res = 'negado' then
    if coalesce(c.credito_consultas, 0) >= 2 then
      return jsonb_build_object('aviso', null, 'motivo', 'negado na 2ª consulta: o time vê com o cliente');
    end if;
    v_chave := 'bo_credito_negado'; v_flag := 'credito_negado_avisado';
  elsif p_res = 'pendente' then
    v_chave := 'bo_credito_pendente'; v_flag := 'credito_pendente_avisado';
  else
    return jsonb_build_object('aviso', null, 'motivo', 'resultado sem aviso automático: ' || coalesce(p_res, '?'));
  end if;
  -- uma vez por conversa: este aviso já saiu (pela Mari ou pelo botão, a qualquer tempo) → não sai de novo. Ex.: a Mari consulta e dá
  -- só cartão; horas depois o BKO grava o mesmo "só cartão" na ficha ou na extensão → nada sai. Resultado novo (negado → parente
  -- aprovado) tem aviso próprio.
  if coalesce((c.dados ->> v_flag)::boolean, false) then
    return jsonb_build_object('aviso', null, 'motivo', 'este resultado já foi avisado nesta conversa');
  end if;

  r := public._bo_mensagem(g, 1, 'credito', coalesce(p_venda, c.venda_id), c, v_chave, v_vars, null, null, 'aviso do crédito: ' || p_res);
  -- a nota "📣 já avisou" só na consulta automática da Mari: no botão, quem clicou já sabe e a porta já deixa a nota dela (H5).
  if r ->> 'status' = 'pendente' and p_origem = 'mari' then
    perform public._bo_enfileirar(g, 2, 'credito', coalesce(p_venda, c.venda_id), c, 'nota', jsonb_build_object('content',
      '📣 O NIOGEN já avisou o cliente do crédito (' || case v_chave when 'bo_credito_aprovado' then 'aprovado' || replace(v_vars ->> 'forma', ',', '')
        when 'bo_credito_aprovado_falta' then 'aprovado' || replace(v_vars ->> 'forma', ',', '') || ' — pediu ' || (v_vars ->> 'falta')
        when 'bo_credito_forma' then 'aprovado, mas a forma escolhida não foi liberada — ofereceu ' || (v_vars ->> 'formas')
        when 'bo_credito_cartao' then 'só no cartão — ofereceu cartão ou outra pessoa da casa como titular'
        when 'bo_credito_negado' then 'negado — ofereceu um parente ou familiar como titular'
        else 'pendente — a Nio responde em até 24 h' end
      || '). Não precisa repetir: siga com a resposta dele.'));
  end if;
  -- a Mari não repete (o 7 · Extrair lê estas flags); no negado com a Mari atendendo, ela passa ao time na próxima fala do cliente.
  if r ->> 'status' in ('pendente', 'repetida') then
    update public.mari_conversas
       set dados = coalesce(dados, '{}'::jsonb) || jsonb_build_object(v_flag, true)
                   || case when v_chave = 'bo_credito_negado' then jsonb_build_object('credito_negado_sistema', true) else '{}'::jsonb end
     where id = c.id;
  end if;
  return jsonb_build_object('aviso', v_chave, 'status', r ->> 'status', 'motivo', r ->> 'motivo', 'origem', p_origem);
end $function$;

-- 5. conferência do que esta migration tinha de deixar
do $$
begin
  if (select count(*) from public.config_mari_textos
       where (chave = 'abertura_versao' and texto = 'b4_241126')
          or (chave = 'abertura_botoes' and texto = 'casa,comercio,cliente')
          or (chave = 'abertura_corpo_b4' and texto like '%{preco_entrada}%')
          or (chave = 'abertura_lembrete_byaf' and texto like '%se não for o momento%')) <> 4 then
    raise exception '0381: textos da abertura B4 não ficaram como esperado';
  end if;
  if (select count(*) from public.config_templates_waba where nome like 'nio_retomada_d3_%' and status = 'PENDING') <> 3 then
    raise exception '0381: os 3 templates da Retomada por etapa não estão como PENDING';
  end if;
  if position('_retomada_variante' in pg_get_functiondef('public._retomada_tick'::regproc)) = 0
     or position('_retomada_variante' in pg_get_functiondef('public.mari_cadencia_avaliar'::regproc)) = 0
     or position('abertura_lembrete_byaf' in pg_get_functiondef('public.mari_cadencia_texto'::regproc)) = 0
     or position('''anuncio''' in pg_get_functiondef('public.mari_contexto'::regproc)) = 0
     or position('credito_pede_periodo' in pg_get_functiondef('public._credito_avisar'::regproc)) = 0 then
    raise exception '0381: alguma função não ficou com o trecho novo';
  end if;
end $$;

commit;

-- NIOGEN | supabase/migrations/0383_volta_ao_time_e_pedido_nio.sql | 24/11/2026 — Claude Code (Opus 5.5)
-- Caso L-82 (Michele, Chatwoot #76): Saída "Nio não instalou" em 20/11 (o pedido de outra revenda trava o endereço). Em 24/11 ela
-- escreveu "Oiii" e a Mari respondeu com o quadro de condições, aceitou "o outro foi dado baixa" (não foi), disse "vou tentar abrir o
-- seu pedido agora" e só passou ao time na 3ª resposta. A situação "Saída definitiva" dizia "resposta curta, sem venda", mas quem
-- garantia era uma linha do prompt. Ricardo, 24/11: "Sim, repasse direto e demais ajustes. Inclusive o Niogen precisa ter como motivo
-- de saída, além de já cliente Nio, outras duas, Já tem pedido Nio CPF e Já tem pedido Nio no endereço. Inclusive o operador da VPS e
-- Extensão precisam identificar isso para registrar corretamente".
-- O que muda:
--  (1) Saída: motivos novos "Já tem pedido Nio no CPF" (pedido_nio_cpf) e "Já tem pedido Nio no endereço" (pedido_nio_endereco) — situação
--      "Saída — pode voltar" (volta quando o pedido de lá cair), destino da conversa novo pedido_nio (etiqueta saida-pedido-nio). Não são
--      "cliente Nio" (não silenciam — 0313). "Já é cliente Nio" deixa de citar o pedido em andamento na ajuda.
--  (2) Repasse direto (porta 'cliente_escreveu:ao_time' → _porta_volta_ao_time): quem escreve em Saída definitiva, em Saída "Já tem
--      pedido Nio" ou com a venda na OS/instalação (conversa de volta à Mari) não fala com a Mari. Sai a fala fixa volta_ao_time (no
--      máximo 1 a cada 12 h, pela fila do NIOGEN) e a conversa abre no Chatwoot com nota para o time; situação, dono e vez não mudam.
--      "Ok/obrigado/confirmo" fica em silêncio. Instalada continua com o pós-venda de sempre (0176).
--  (3) Portal: popup "já existe um pedido (Nova Fibra) em andamento para o endereço informado" — antes lido como "sem viabilidade"
--      (a Mari dizia que a rede não chega) — vira o resultado pedido_endereco: mari_viab_gravar marca nio_pedido_aberto = 'endereco'
--      (o DFV decide a cobertura); mari_credito_gravar e lead_registrar_consulta gravam credito_resultado = 'pedido_endereco'.
--      O popup do CPF ("para este cliente") segue pedido_em_andamento (nio_pedido_aberto = 'sim').
-- Regra 20: (1) nenhuma situação nova; os motivos caem em "Saída — pode voltar", com vez e prazo da Saída; (2) a volta do cliente passa
-- pela porta (evento novo em config_transicao, 6 situações, para = a mesma); (3) consequência em fila (chatwoot_acoes: mensagem, nota,
-- abrir), autor "o sistema"; (4) fonte: o portal (operador/extensão) para o pedido; a conversa para a volta; (5) sem número novo — a
-- conferência da Saída e da conversa aberta fora do andamento (0335) é a de sempre. Cenário X106. Desempenho: 1 chamada a
-- _porta_situacao por mensagem de cliente que não está em andamento com a Mari ativa (índice por conversa).
-- Medir em 7 dias: voltas com volta_ao_time × respostas do time; Saídas com os motivos novos; leituras pedido_endereco do operador.
begin;

-- ── 1. restrições: valores novos
alter table public.mari_conversas drop constraint if exists mari_conversas_funil_destino_check;
alter table public.mari_conversas add constraint mari_conversas_funil_destino_check check (funil_destino is null or funil_destino = any (array[
  'em_andamento', 'instalada', 'reprovado_biometria', 'credito_negado', 'ja_cliente_nio', 'fora_area', 'sem_cobertura', 'recusou',
  'sem_resposta', 'teste_duplicada', 'pedido_nio']));
alter table public.mari_conversas drop constraint if exists mari_conversas_credito_resultado_check;
alter table public.mari_conversas add constraint mari_conversas_credito_resultado_check check (credito_resultado is null or credito_resultado = any (array[
  'aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'pendente', 'negado', 'negado_antifraude', 'negado_debito', 'pedido_em_andamento',
  'pedido_endereco', 'nao_decidiu']));
alter table public.mari_conversas drop constraint if exists mari_conversas_nio_pedido_aberto_check;
alter table public.mari_conversas add constraint mari_conversas_nio_pedido_aberto_check check (nio_pedido_aberto is null or nio_pedido_aberto = any (array[
  'sim', 'nao', 'endereco']));

-- ── 2. os motivos de Saída (a lista única da ficha, da tela Leads e das contas) e o destino da conversa
update public.config_lead set ordem = ordem + 2 where parceiro_id = 'dharma' and tipo = 'saida' and ordem >= 4;
insert into public.config_lead (parceiro_id, tipo, codigo, nome, ordem, volta, etiqueta, ajuda) values
  ('dharma', 'saida', 'pedido_nio_cpf', 'Já tem pedido Nio no CPF', 4, 'quando o pedido de lá cair', 'saida-pedido-nio',
   'O portal diz que já existe pedido Nio em andamento no CPF do cliente (de outra revenda ou da própria Nio). Abrir outro é recompra: multa de R$ 500. Quando o pedido de lá for cancelado, reconsulte o crédito e use Reabrir.'),
  ('dharma', 'saida', 'pedido_nio_endereco', 'Já tem pedido Nio no endereço', 5, 'quando o pedido de lá cair', 'saida-pedido-nio',
   'O portal diz que já existe pedido Nio em andamento no endereço (outra revenda ou a própria Nio) — vale até para outro CPF. Quando o pedido de lá for cancelado, reconsulte a viabilidade e use Reabrir.')
on conflict (parceiro_id, tipo, codigo) do update set nome = excluded.nome, ordem = excluded.ordem, volta = excluded.volta,
  etiqueta = excluded.etiqueta, ajuda = excluded.ajuda;
update public.config_lead
   set ajuda = 'O cliente ou o endereço já tem Nio ATIVA (instalada). Vender aqui dá estorno de 100 % e multa de R$ 500. Pedido Nio ainda em andamento não é este motivo: use "Já tem pedido Nio no CPF" ou "no endereço".'
 where parceiro_id = 'dharma' and tipo = 'saida' and codigo = 'ja_cliente_nio';

insert into public.config_funil (parceiro_id, tipo, codigo, nome, ordem, saida, etiqueta)
select 'dharma', 'destino', 'pedido_nio', 'Já tem pedido Nio', coalesce(max(ordem), 0) + 1, true, 'saida-pedido-nio'
  from public.config_funil where parceiro_id = 'dharma' and tipo = 'destino'
on conflict (parceiro_id, tipo, codigo) do update set nome = excluded.nome, saida = excluded.saida, etiqueta = excluded.etiqueta;

-- o motivo da conversa sem venda (quadro_encerrada_motivo = o código) volta ao destino certo no recálculo do funil
CREATE OR REPLACE FUNCTION public._funil_destino_quadro(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  select case p
    when 'perdida' then 'recusou' when 'ja_cliente' then 'ja_cliente_nio' when 'suporte_nio' then 'ja_cliente_nio'
    when 'fora_area' then 'fora_area' when 'sem_cobertura' then 'sem_cobertura' when 'recusou' then 'recusou'
    when 'credito_negado' then 'credito_negado' when 'sem_resposta' then 'sem_resposta' when 'teste_duplicada' then 'teste_duplicada'
    when 'ja_cliente_nio' then 'ja_cliente_nio'
    when 'pedido_nio_cpf' then 'pedido_nio' when 'pedido_nio_endereco' then 'pedido_nio' when 'pedido_nio' then 'pedido_nio' end   -- 0383
$function$;

-- ── 3. a fala fixa e a peça da porta
insert into public.config_mari_textos (chave, texto) values
  ('volta_ao_time', 'Oi, {nome}! 💚 Recebi sua mensagem e já chamei o nosso time, que acompanha o seu caso. Alguém da equipe te responde por aqui.')
on conflict (chave) do update set texto = excluded.texto;

CREATE OR REPLACE FUNCTION public._porta_volta_ao_time(c mari_conversas, p_texto text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  s     text := public._porta_situacao(c.id, null::uuid);
  sn    text := coalesce((select nome from public.config_situacao where codigo = public._porta_situacao(c.id, null::uuid)), s);
  viva  boolean := s in ('qualificado_os', 'instalacao_agendar', 'instalacao_aguardando', 'instalacao_pendencia');
  c2    public.mari_conversas := c;
  msg   jsonb;
  feito text[] := '{}';
begin
  -- 0383 (L-82): a fala do cliente acabou de chegar — a janela de 24 h está aberta (o mari_entrada só grava a hora depois)
  c2.ultima_msg_lead_at := now();
  msg := public._bo_mensagem(gen_random_uuid(), 1, 'cliente_voltou', c.venda_id, c2, 'volta_ao_time',
           jsonb_build_object('nome', public.mari_cadencia_nome(c)), null, null, 'volta ao time (' || sn || ')');
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (c.id, 'sistema', '[cliente escreveu em "' || sn || '" — a Mari não responde (0383); '
          || case when msg ->> 'status' = 'repetida' then 'a fala de volta ao time já saiu nas últimas 12 h'
                  when msg ->> 'motivo' is not null then 'a fala de volta ao time não saiu (' || (msg ->> 'motivo') || ')'
                  else 'ele recebeu "já chamei o time"' end
          || '; a conversa abre para o time]', false);
  if msg ->> 'motivo' is null and coalesce(msg ->> 'status', '') <> 'repetida' then
    feito := feito || 'cliente recebeu "já chamei o time"'::text;
  end if;
  feito := feito || public._porta_projetar(c.id, 'cliente_voltou',
    '🔔 O cliente voltou a escrever (' || sn || '). A Mari NÃO responde neste caso — ele recebeu "já chamei o time". '
    || case when viva then 'É pós-venda: leia a conversa e responda pelo NIOGEN.'
            else 'Leia o histórico (o que já foi tentado) e responda; se for venda nova, use Reabrir na ficha.' end,
    'open');
  return jsonb_build_object('ok', true, 'situacao', s, 'feito', to_jsonb(feito), 'resumo', '✓ ' || array_to_string(feito, ' · '));
end $function$;
-- peça interna da porta: só a porta (security definer) chama — nenhum login executa direto (X87/X88)
revoke all on function public._porta_volta_ao_time(public.mari_conversas, text) from public, anon, authenticated;

-- ── 4. a tabela da porta: a volta ao time vale nestas 6 situações e não muda a situação
insert into public.config_transicao (evento, de, para, aceito, frase, nota, exige)
select 'cliente_escreveu:ao_time', s, array['='], true, null,
       '0383 (L-82): a Mari não responde; fala fixa "já chamei o time" (12 h) e a conversa abre para o time', null
  from unnest(array['saida_definitiva', 'saida_pode_voltar', 'qualificado_os', 'instalacao_agendar', 'instalacao_aguardando', 'instalacao_pendencia']) s
on conflict (evento, de) do update set para = excluded.para, aceito = excluded.aceito, nota = excluded.nota;
-- a Saída com os motivos novos vale onde a de "Fachada não atendida" vale (andamento e pode voltar → pode voltar)
insert into public.config_transicao (evento, de, para, aceito, frase, nota, exige)
select 'saida:' || m, t.de, t.para, t.aceito, t.frase, '0383: como saida:fachada_nao_atendida', t.exige
  from public.config_transicao t, unnest(array['pedido_nio_cpf', 'pedido_nio_endereco']) m
 where t.evento = 'saida:fachada_nao_atendida'
on conflict (evento, de) do update set para = excluded.para, aceito = excluded.aceito, nota = excluded.nota;
update public.config_transicao set nota = 'a Mari não responde: fala fixa e a conversa abre para o time (0383, cliente_escreveu:ao_time)'
 where evento = 'cliente_escreveu' and de = 'saida_definitiva';
update public.config_situacao set mari = 'não responde: fala fixa e o time (0383)' where codigo = 'saida_definitiva';
update public.config_situacao set mari = 'não responde: fala fixa e o time (0383)'
 where codigo in ('qualificado_os', 'instalacao_agendar', 'instalacao_aguardando', 'instalacao_pendencia');

-- ── 5. funções no ar com a mudança (versões de 24/11, lidas da produção)
CREATE OR REPLACE FUNCTION public.lead_situacao(p_status text, p_destino text, p_saida_motivo text, p_em_espera boolean, p_vez text, p_com_dono boolean)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  select case
    when p_destino = 'instalada' then 'instalada'
    when p_destino = 'teste_duplicada' then 'saida_definitiva'
    when p_destino = 'saida' then case
      when p_saida_motivo = 'nao_contatar' then 'nao_contatar'
      when p_saida_motivo = 'ja_cliente_nio' then 'cliente_nio'
      when p_saida_motivo in ('credito_negado', 'reprovado_biometria', 'nio_nao_instalou', 'venda_indevida_fraude', 'teste_duplicada') then 'saida_definitiva'
      when p_saida_motivo in ('recusou', 'sem_resposta', 'fachada_nao_atendida', 'cidade_nao_atendida',
                            'pedido_nio_cpf', 'pedido_nio_endereco') then 'saida_pode_voltar'   -- 0383: volta quando o pedido de lá cair
      end
    when p_destino = 'em_andamento' then case
      when coalesce(p_em_espera, false) then 'em_espera'
      when p_status in ('pendencia_nio', 'defesa_nio') then 'instalacao_pendencia'
      when p_status in ('aguardando_instalacao', 'aguarda_cartao') then 'instalacao_aguardando'
      when p_status in ('agendar', 'remarcar') then 'instalacao_agendar'
      when p_status = 'abrir_os' then 'qualificado_os'
      when p_status = 'aguarda_biometria' then 'qualificado_biometria'
      when p_status in ('rodar_credito', 'fazer_pedido') then 'qualificado_credito'
      when p_status = 'pediu_humano' then case
        when p_vez = 'cliente' and coalesce(p_com_dono, false) then 'time_esperando'   -- 0334 (caso 184): o time respondeu
        else 'time_agora' end
      when p_status in ('conferir_200m', 'antifraude_conferir') then 'time_agora'
      when p_status in ('nova', 'respondeu', 'consultando_cep', 'viu_planos') then case
        when p_vez = 'time' then 'time_agora'
        when coalesce(p_com_dono, false) then 'time_esperando'   -- 0266 (C10): o time é dono e a vez é do cliente
        else 'mari_atendendo' end
      end
    end
$function$;

CREATE OR REPLACE FUNCTION public._porta_destino_de(p_codigo text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  select case p_codigo
    when 'cidade_nao_atendida' then 'fora_area' when 'fachada_nao_atendida' then 'sem_cobertura'
    when 'ja_cliente_nio' then 'ja_cliente_nio' when 'credito_negado' then 'credito_negado'
    when 'pedido_nio_cpf' then 'pedido_nio' when 'pedido_nio_endereco' then 'pedido_nio'   -- 0383
    when 'reprovado_biometria' then 'reprovado_biometria' when 'sem_resposta' then 'sem_resposta'
    when 'teste_duplicada' then 'teste_duplicada' else 'recusou' end   -- recusou, não contatar, Nio não instalou, fraude
$function$;

CREATE OR REPLACE FUNCTION public.funil_destino_de_motivo(p_motivo text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  select case
    when p_motivo is null or btrim(p_motivo) = '' then 'recusou'
    when lower(p_motivo) ~ 'biometria' then 'reprovado_biometria'
    when lower(p_motivo) ~ 'cr[eé]dito' then 'credito_negado'
    when lower(p_motivo) ~ 'j[aá] tem pedido nio' then 'pedido_nio'                                  -- 0383
    when lower(p_motivo) ~ '(cliente nio|pedido na nio|cancelou a nio)' then 'ja_cliente_nio'
    when lower(p_motivo) ~ '(fora d[ae] [aá]rea|cidade n[aã]o atendida)' then 'fora_area'              -- 0157: nomes da lista única
    when lower(p_motivo) ~ '(cobertura|fachada n[aã]o atendida)' then 'sem_cobertura'
    when lower(p_motivo) ~ '(sem contato|n[aã]o atende|sem resposta)' then 'sem_resposta'
    when lower(p_motivo) ~ '(duplic|teste)' then 'teste_duplicada'
    else 'recusou'   -- Recusou, Desistiu, Preço, Concorrente, Interesse futuro, Não contatar, Nio não instalou, Venda indevida ou fraude, outro
  end
$function$;

CREATE OR REPLACE FUNCTION public.porta(p_evento text, p_conversa uuid, p_venda uuid, p_dados jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c       public.mari_conversas;
  v       public.vendas;
  r       record;
  antes   text;
  fam     text := split_part(coalesce(p_evento, ''), ':', 1);
  arg     text := nullif(split_part(coalesce(p_evento, ''), ':', 2), '');
  cliente boolean := p_evento = 'cliente_escreveu';
  quem    text;
  v_opt   timestamptz;
  res     jsonb;
  ged     text;
  saidas  jsonb := '{"perdida": "recusou", "recusou": "recusou", "fora_area": "cidade_nao_atendida", "sem_cobertura": "fachada_nao_atendida",
                     "ja_cliente": "ja_cliente_nio", "ja_cliente_nio": "ja_cliente_nio", "credito_negado": "credito_negado",
                     "sem_resposta": "sem_resposta", "teste_duplicada": "teste_duplicada"}'::jsonb;   -- silenciar:<motivo antigo> → motivo de Saída
begin
  if p_conversa is not null then
    select * into c from public.mari_conversas where id = p_conversa for update;
    if not found then raise exception 'Conversa não encontrada.'; end if;
  end if;
  if coalesce(p_venda, c.venda_id) is not null then
    select * into v from public.vendas where id = coalesce(p_venda, c.venda_id) for update;
    if not found then raise exception 'Venda não encontrada.'; end if;
    if c.id is null then
      select * into c from public.mari_conversas where venda_id = v.id and canal = 'whatsapp' order by created_at desc limit 1;
    end if;
  end if;
  if v.id is null and c.id is null then raise exception 'Informe a conversa ou a venda.'; end if;
  quem := coalesce((select u.nome from public.usuarios u where u.id = auth.uid()),
                   case when cliente then 'o cliente' when auth.role() = 'service_role' then 'o sistema' else 'alguém do time' end);

  -- a tabela manda: recusa com a frase, ou segue
  antes := public._porta_situacao(c.id, v.id);
  select * into r from public.porta_prever(antes, p_evento);
  -- 0287: botão da ficha (momento) e Mover do admin sem regra na tabela passam (como o _porta_conferir fazia) — a casca anota o buraco
  if r.aceito is false or (r.aceito is null and fam not in ('momento', 'mover_admin')) then
    if cliente then return jsonb_build_object('ok', false, 'situacao', antes, 'frase', r.frase); end if;
    raise exception '%', coalesce(r.frase, 'Esta ação não vale nesta situação (' || antes || ').');
  end if;
  if r.exige = 'admin' and coalesce(public.meu_perfil(), '') <> 'admin' then
    raise exception '%', r.frase using errcode = '42501';
  end if;
  -- 0298 (fase 2, passo 6 — D11, D15, E7: "só admin, com motivo"): ação que só o admin faz exige o motivo. Vale o que veio nos dados
  -- (Mover do admin) ou o que a tela preparou há pouco (porta_motivo_preparar). Sem motivo, a tela pede e repete (MOTIVO_ADMIN).
  if r.exige = 'admin' then
    declare v_mot text := btrim(coalesce(p_dados ->> 'motivo', ''));
            v_mid bigint;
    begin
      if length(v_mot) < 5 then
        select pm.id, pm.motivo into v_mid, v_mot from public.porta_motivos pm
         where pm.por = auth.uid() and pm.usado_em is null and pm.criado_em > now() - interval '5 minutes'
         order by pm.id desc limit 1;
        if v_mid is not null then
          update public.porta_motivos set usado_em = now(), evento = p_evento where id = v_mid;
        end if;
      end if;
      if length(btrim(coalesce(v_mot, ''))) < 5 then
        raise exception 'MOTIVO_ADMIN: %', coalesce(r.frase, 'Esta ação é só do admin') || ' — escreva o motivo (pelo menos 5 letras).'
          using errcode = 'P0001';
      end if;
      perform set_config('porta.motivo', left(btrim(v_mot), 500), true);
    end;
  end if;
  if r.exige = 'ged_sem_leitura' and coalesce(public.meu_perfil(), '') <> 'admin' then   -- 0272, trazido do _porta_conferir (0287)
    ged := public._ged_fresco(v.id);
    if ged is not null then raise exception '%', r.frase || ' (GED360: ' || ged || ')'; end if;
  end if;
  if r.exige = 'cliente_escreveu_depois' and c.id is not null then
    select max(t.created_at) into v_opt from public.mari_turnos t
     where t.conversa_id = c.id and t.papel = 'sistema' and t.texto like '[não contatar — cliente escreveu:%';
    if v_opt is not null and not exists (select 1 from public.mari_turnos t where t.conversa_id = c.id and t.papel = 'lead' and t.created_at > v_opt) then
      raise exception '%', r.frase;
    end if;
  end if;

  -- 0282 (reta final 5): Assumir, Devolver para a Mari e o "assumir antes" do Responder são executados aqui. Não mudam o
  -- destino do lead, então rodam SEM porta.aplicando: os gatilhos antigos do funil seguem calculando etapa e handoff como antes.
  -- 0287: os botões da venda (momento:*) também — viabilidade, crédito, pedido, biometria, OS, agendar, parar. Eles mudam a venda e
  -- o destino sai dos gatilhos de sempre (_funil_venda_mudou → _funil_antes), por isso também rodam SEM porta.aplicando.
  if p_evento = 'time_respondeu' then
    return public._porta_assumir(c, v, coalesce(p_dados, '{}'::jsonb) || jsonb_build_object('via', 'responder'));
  elsif p_evento = 'soprar' then   -- 0299: o time fala na voz da Mari; situação, dono e vez não mudam
    return public._porta_soprar(c, coalesce(p_dados, '{}'::jsonb));
  elsif fam = 'retomada_ligacao' then   -- 0315: o time registra a ligação da Retomada; situação, dono e vez não mudam
    return public._porta_retomada_ligacao(c, arg, coalesce(p_dados, '{}'::jsonb));
  elsif p_evento = 'aviso_sem_cobertura' then   -- 0325: aviso ao cliente da viabilidade sem cobertura; situação, dono e vez não mudam
    return public._porta_aviso_sem_cobertura(c);
  elsif fam = 'janela_acao' then   -- 0324: venda com a janela fechada — ligação ou template; situação, dono e vez não mudam
    return public._porta_janela_acao(c, arg, coalesce(p_dados, '{}'::jsonb));
  elsif p_evento = 'volta_adiar' then   -- 0318: Hora de voltar → mais N dias; situação, dono e vez não mudam
    return public._porta_volta_adiar(c, v, coalesce(p_dados, '{}'::jsonb));
  elsif fam = 'momento' then
    -- mesmos argumentos que o núcleo recebeu (venda e/ou conversa), para a peça achar a mesma conversa de antes
    return public._porta_momento(p_venda, arg, coalesce(p_dados, '{}'::jsonb)
             || case when p_conversa is not null then jsonb_build_object('conversa_id', p_conversa) else '{}'::jsonb end);
  elsif fam = 'mover_admin' then   -- 0288: o Mover do admin (a venda muda; o destino sai do gatilho vendas_porta)
    return public._porta_mover(v, arg, coalesce(p_dados, '{}'::jsonb));
  end if;

  perform set_config('porta.aplicando', '1', true);   -- os gatilhos antigos do funil não decidem por cima da porta
  if fam = 'saida' then
    res := public._porta_sair(c, v, arg, p_dados, quem, true);
  elsif fam = 'silenciar' and arg = 'suporte_nio' then
    res := public._porta_silenciar(c, quem, false);
  elsif fam = 'silenciar' and arg = 'reativar' then
    res := public._porta_reativar(c, quem);
  elsif fam = 'silenciar' and saidas ? arg then
    res := public._porta_sair(c, v, saidas ->> arg, p_dados, quem, false);
  elsif fam = 'reabrir' then
    res := public._porta_reabrir(c, v, quem, false, coalesce(c.nao_contatar, false));
  elsif fam = 'nao_contatar' then
    res := public._porta_nao_contatar(c, v, p_dados ->> 'origem');
  elsif fam = 'prazo' and arg = 'esperando_fechar' then          -- 0266 (C10)
    res := public._porta_esperando_fechar(c);
  elsif fam = 'prazo' and arg = 'handoff_sem_resposta' then      -- 0266 (C4)
    res := public._porta_handoff_devolver(c);
  elsif fam = 'prazo' and arg = 'volta_saida' then               -- 0335: voltou com o time e o cliente não respondeu
    res := public._porta_volta_saida(c);
  elsif fam = 'prazo' and arg = 'fora_fechar' then               -- 0335: conversa aberta fora do andamento, parada há N h
    res := public._porta_fora_fechar(c);
  elsif cliente and p_dados ->> 'acao' = 'fim_espera' and antes = 'em_espera' then   -- 0266 (C11)
    res := public._porta_fim_espera(c);
  elsif fam = 'cliente_escreveu' and arg = 'sem_cobertura' then   -- 0279 (caso Felix): Saída por cobertura não reabre
    res := public._porta_volta_sem_cobertura(c, p_dados ->> 'texto');
  elsif fam = 'cliente_escreveu' and arg = 'ao_time' then         -- 0383 (L-82, Michele): a Mari não responde; fala fixa e o time
    res := public._porta_volta_ao_time(c, p_dados ->> 'texto');
  elsif cliente and p_dados ->> 'acao' = 'reabrir' and antes = 'saida_pode_voltar' then
    res := public._porta_reabrir(c, v, quem, true, false);
  elsif cliente and p_dados ->> 'acao' = 'silenciar' and antes = 'cliente_nio' then
    res := public._porta_silenciar(c, quem, true);
  else
    perform set_config('porta.aplicando', '', true);
    if cliente then return jsonb_build_object('ok', false, 'situacao', antes); end if;
    raise exception 'Evento ainda não passa pela porta: %', p_evento;
  end if;
  perform set_config('porta.aplicando', '', true);
  return res;
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

  -- 0383 (L-82, Michele, #76 — Ricardo, 24/11: "Sim, repasse direto"): quem volta a escrever em Saída definitiva, em Saída
  -- "Já tem pedido Nio" (CPF ou endereço) ou com a venda na OS/instalação NÃO fala com a Mari: o contexto está no que o time fez
  -- (outros CPFs, protocolos, o pedido de outra revenda) e o modelo reabria a venda e prometia o que não pode. O cliente recebe uma
  -- fala fixa (uma vez a cada 12 h) e a conversa abre para o time com nota; a situação não muda. "Ok/obrigado" fica só em silêncio.
  if not v_cob and coalesce(v_conv.canal, '') = 'whatsapp' and not coalesce(v_conv.nao_contatar, false) and not public._mari_optout(p_texto)
     and coalesce(v_conv.funil_destino, '') <> 'teste_duplicada'
     and (v_conv.status = 'ativo' or coalesce(v_conv.funil_destino, 'em_andamento') <> 'em_andamento') then
    declare v_s text := public._porta_situacao(v_conv.id, null::uuid);
    begin
      if v_s = 'saida_definitiva'
         or (v_s = 'saida_pode_voltar' and coalesce(v_conv.saida_motivo, '') in ('pedido_nio_cpf', 'pedido_nio_endereco'))
         or (v_conv.status = 'ativo' and v_s in ('qualificado_os', 'instalacao_agendar', 'instalacao_aguardando', 'instalacao_pendencia')) then
        v_cob := true;
        if p_midia is not null or not (public._saida_so_confirmacao(p_texto) or public._norm_resposta(p_texto) in ('confirmo', 'tudo certo')) then
          perform public.porta('cliente_escreveu:ao_time', v_conv.id, null::uuid, jsonb_build_object('texto', p_texto));
          select * into v_conv from public.mari_conversas where id = v_conv.id;
        end if;
      end if;
    end;
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

CREATE OR REPLACE FUNCTION public.mari_viab_gravar(p_conversa uuid, p_saida jsonb, p_dfv jsonb DEFAULT NULL::jsonb, p_erro text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_res text; v_op text := p_saida->>'resultado'; v_dfv text; v_dec text; c record; v_conf text;
        v_uac jsonb := p_saida -> 'unidade_a_confirmar';   -- 0233: viável na fachada com a unidade emprestada
        v_bateu text;                                      -- 0343: a unidade da lista que bate com o complemento da conversa
begin
  if coalesce(p_saida->>'retry', '') = 'true' and p_dfv is null then
    update public.mari_conversas set nio_viab_em = null, viab_consultas = greatest(viab_consultas - 1, 0)
     where id = p_conversa and nio_viab_resultado is null;
    return jsonb_build_object('ok', true, 'resultado', 'de_volta_na_fila');
  end if;
  if coalesce(p_saida->>'retry', '') = 'true' then v_op := null; end if;   -- portal não decidiu; o DFV pode decidir
  -- 0343: viável na fachada, mas o cliente já deu uma unidade que ESTÁ na lista (o complemento chegou depois da consulta)
  if v_op = 'viavel' and v_uac is not null and jsonb_typeof(p_saida->'opcoes'->'lista') = 'array' then
    select u into v_bateu
      from public.mari_conversas mc, jsonb_array_elements_text(p_saida->'opcoes'->'lista') u
     where mc.id = p_conversa and public._unidade_chave(mc.complemento) <> ''
       and public._unidade_chave(u) = public._unidade_chave(mc.complemento)
     limit 1;
  end if;
  -- 0383 (Michele, L-82): popup "já existe um pedido (Nova Fibra) em andamento para o endereço" — a rede chega; o que trava é o
  -- pedido de lá. O portal não decidiu a viabilidade (o DFV decide) e a conversa fica marcada: nio_pedido_aberto = 'endereco'.
  v_res := case v_op when 'viavel' then 'viavel' when 'sem_viabilidade' then 'sem_viabilidade'
                     when 'complemento_fora_lista' then 'nao_encontrado' else 'indisponivel' end;
  v_dfv := public._dfv_veredito(p_dfv);
  v_dec := public.cobertura_decidir(v_op, v_dfv);   -- rua_divergente = portal não decidiu: o DFV decide (a Mari segue o fluxo normal)
  -- 0202: portal em outra rua, ou portal "sem viabilidade" com a própria fachada viável no DFV → o time confere a rua
  v_conf := case when v_op = 'rua_divergente' then 'rua_divergente'
                 when v_op = 'sem_viabilidade' and p_dfv ->> 'match' = 'exato' and coalesce(p_dfv ->> 'fonte', '') <> 'base_congelada'
                 then 'portal_nao_dfv_exato' end;
  update public.mari_conversas set nio_viab_resultado = v_res,
         nio_viab_velocidade = case when v_res = 'viavel' then nullif(p_saida->>'velocidade', '') end,
         nio_viab_em = now(), cobertura_decisao = v_dec, cobertura_em = now(),
         cobertura_detalhe = jsonb_strip_nulls(jsonb_build_object(
           'portal', v_op, 'dfv', v_dfv, 'velocidade', p_saida->>'velocidade',
           'portal_texto', p_saida->'endereco'->>'viabilidade', 'portal_motivo', p_saida->>'motivo',
           'unidades', case when v_op = 'complemento_fora_lista' or v_uac is not null then p_saida->'opcoes'->'lista' end,
           'unidade_a_confirmar', case when v_uac is not null and v_bateu is null then true end,   -- 0343: bateu → não há o que confirmar
           'unidade_cliente', v_bateu,                                                          -- 0343
           'dfv_fachadas_cep', p_dfv->'total_fachadas_no_cep', 'dfv_fonte', coalesce(p_dfv->>'fonte', case when p_dfv is not null then 'ao_vivo' end),
           'dfv_match', p_dfv->>'match', 'portal_endereco', p_saida->'endereco'->>'resolvido', 'conferir_rua', v_conf))
   where id = p_conversa
  returning id, cep, numero, complemento, venda_id into c;
  if c.id is null then return jsonb_build_object('ok', false, 'motivo', 'conversa não encontrada'); end if;
  if v_op = 'pedido_endereco' then   -- 0383
    update public.mari_conversas set nio_pedido_aberto = 'endereco', nio_pedido_aberto_em = now(),
           cobertura_detalhe = coalesce(cobertura_detalhe, '{}'::jsonb) || jsonb_build_object('pedido_endereco', true)
     where id = p_conversa;
  end if;
  if v_conf is not null then
    perform public._cobertura_rua_marcar(p_conversa, v_conf, p_saida->'endereco'->>'resolvido', p_saida->'endereco'->>'esperado',
                                         p_dfv->'fachada'->>'logradouro', 'mari_viab_gravar');
  elsif v_op is not null then   -- o portal decidiu de novo sem conflito: a conferência pendente fecha sozinha
    update public.mari_conversas set rua_conferir_em = null where id = p_conversa and rua_conferir_em is not null;
  end if;
  -- 0233: unidade a confirmar. Viável com a unidade emprestada → o cliente escolhe (a Mari mostra a lista); o portal sem
  -- NENHUMA unidade cadastrada → o time pede o cadastro à Nio. A unidade do cliente bateu → a conferência fecha sozinha.
  if v_op = 'viavel' and v_uac is not null and v_bateu is null then   -- 0343: só quando a unidade do cliente não está na lista
    perform public._cobertura_unidade_marcar(p_conversa, 'escolher', p_saida->'opcoes'->'lista', v_uac->>'informada', v_uac->>'usada', 'mari_viab_gravar');
  elsif v_op = 'complemento_fora_lista' and p_saida->'opcoes'->>'situacao' = 'nenhuma' then
    perform public._cobertura_unidade_marcar(p_conversa, 'sem_cadastro', '[]'::jsonb, c.complemento, null, 'mari_viab_gravar');
  elsif v_op = 'viavel' then
    update public.mari_conversas set unidade_conferir_em = null where id = p_conversa and unidade_conferir_em is not null;
  end if;
  insert into public.nio_viab_log (origem, conversa_id, cep, numero, complemento, saida, resultado, erro)
  values ('mari', p_conversa, c.cep, c.numero, c.complemento, p_saida - 'cpf_mascara', v_res,
          coalesce(p_erro, case when v_res = 'indisponivel' and v_op is distinct from 'pedido_endereco' then left(coalesce(p_saida->>'motivo', v_op, 'portal não decidiu'), 300) end));
  insert into public.operador_consultas (tipo, origem, conversa_id, venda_id, cep, numero, complemento, resultado, decisao, detalhe, ms)
  values ('viabilidade', 'mari', p_conversa, c.venda_id, c.cep, c.numero, c.complemento, coalesce(v_op, 'nao_decidiu'), v_dec,
          jsonb_build_object('portal', p_saida - 'cpf_mascara' - 'pedido_portal', 'dfv_veredito', v_dfv), nullif(p_saida->>'ms', '')::int);
  if p_dfv is not null then
    insert into public.operador_consultas (tipo, origem, conversa_id, venda_id, cep, numero, complemento, resultado, decisao, detalhe)
    values ('dfv', 'mari', p_conversa, c.venda_id, c.cep, c.numero, c.complemento, v_dfv, v_dec, p_dfv - 'opcoes' - 'unidades');
  end if;
  return jsonb_build_object('ok', true, 'resultado', v_res, 'operador', v_op, 'dfv', v_dfv, 'decisao', v_dec, 'conferir_rua', v_conf,
                            'unidade_cliente', v_bateu);
end $function$;

CREATE OR REPLACE FUNCTION public.mari_credito_gravar(p_conversa uuid, p_saida jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_op text := p_saida->>'resultado'; v text; c record; v_formas text; v_fp text; v_fazer text;
        v_end text := case when p_saida->'endereco'->>'origem' = 'cliente' then 'cliente' when p_saida->'endereco'->>'origem' = 'padrao' then 'padrao' end;
begin
  if coalesce(p_saida->>'retry', '') = 'true' then
    update public.mari_conversas set credito_em = null, credito_consultas = greatest(credito_consultas - 1, 0)
     where id = p_conversa and credito_resultado is null;
    return jsonb_build_object('ok', true, 'resultado', 'de_volta_na_fila');
  end if;
  v := case when v_op in ('aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'pendente', 'negado', 'negado_antifraude', 'negado_debito', 'pedido_em_andamento', 'pedido_endereco')   -- 0383
            then v_op else 'nao_decidiu' end;
  update public.mari_conversas set credito_resultado = v, credito_em = now(), credito_endereco = v_end,
         credito_formas = case when jsonb_typeof(p_saida->'formas_liberadas') = 'array' then p_saida->'formas_liberadas' end,
         nio_pedido_aberto = case when v = 'pedido_em_andamento' then 'sim' when v = 'pedido_endereco' then 'endereco' when v in ('aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'negado', 'negado_antifraude', 'negado_debito') then 'nao' else nio_pedido_aberto end   -- 0313: crédito decidido = o pedido de lá caiu
   where id = p_conversa returning id, venda_id, credito_autorizado_em, credito_autorizacao_frase, chatwoot_conversation_id, status,
                                   forma_pagamento, credito_consultas into c;
  if c.id is null then return jsonb_build_object('ok', false, 'motivo', 'conversa não encontrada'); end if;
  insert into public.operador_consultas (tipo, origem, conversa_id, venda_id, cpf_mascara, resultado, detalhe, ms)
  values ('credito', 'mari', p_conversa, c.venda_id, p_saida->>'cpf_mascara', coalesce(v_op, 'erro'),
          jsonb_strip_nulls(jsonb_build_object('formas', p_saida->'formas_liberadas', 'motivo', p_saida->>'motivo',
            'cache', p_saida->'cache', 'etapa_parada', p_saida->'etapa_parada', 'endereco', v_end,
            -- 0380: o que o portal escreveu no popup (sem número), para a ficha mostrar o motivo do negado
            'popup', left(regexp_replace(nullif(btrim(coalesce(p_saida->'popup'->>'texto', '')), ''), '\d[\d.\-/ ]{5,}\d', '<num>', 'g'), 300),
            'autorizado_em', c.credito_autorizado_em, 'autorizacao_frase', c.credito_autorizacao_frase)),
          nullif(p_saida->>'ms', '')::int);
  -- 0140: o resultado chegou depois do handoff (a nota da Mari já foi) → nota interna no Chatwoot pela fila do NIOGEN.
  if c.chatwoot_conversation_id is not null and (c.status = 'handoff_realizado' or c.venda_id is not null or v in ('negado_antifraude', 'negado_debito')) then   -- 0212/0380: antifraude e débito sempre viram nota
    v_formas := (select string_agg(case upper(x) when 'BOLETO' then 'boleto' when 'CREDITO' then 'cartão' when 'DACC' then 'débito em conta' else lower(x) end, ', ')
                   from jsonb_array_elements_text(case when jsonb_typeof(p_saida->'formas_liberadas') = 'array' then p_saida->'formas_liberadas' else '[]'::jsonb end) x);
    v_fp := case c.forma_pagamento when 'boleto' then 'boleto' when 'cartao' then 'cartão' when 'debito' then 'débito em conta' end;
    v_fazer := case
      when v = 'negado_antifraude' then 'NÃO consultar outro CPF. Perguntar ao cliente se a Nio do endereço é dele (ou de alguém da casa) ou de outro morador que se mudou; gravar a resposta na ficha › Crédito (Antifraude).'
      when v = 'negado_debito' then 'CPF COM DÉBITO NA NIO (fatura antiga em aberto). O cliente NÃO foi avisado do negado: a Mari segue e passa para você. Ver no portal o valor da negociação (a Nio dá desconto) e oferecer quitar hoje pelo Nio Negocia (https://negociacao.niointernet.com.br/negociar/); pagou → consultar o crédito de novo (ficha › Crédito) e fazer o pedido. Não quis quitar → outra pessoa da casa como titular.'
      when v = 'pedido_em_andamento' then 'NÃO abrir outro pedido: conferir no portal o pedido que já existe no CPF (recompra = multa R$ 500).'
      when v = 'pedido_endereco' then 'NÃO abrir outro pedido: já existe pedido Nio em andamento NO ENDEREÇO (outra revenda ou a Nio). Perguntar ao cliente de quem é; se não for seguir, é Saída › Já tem pedido Nio no endereço.'
      when v_end = 'padrao' and v like 'aprovado%' then 'Consultar o crédito de novo no endereço do cliente (ficha › Crédito) antes de abrir o pedido.'
      when v = 'nao_decidiu' then 'Consultar o crédito na ficha (Crédito) — o portal não decidiu.'
      when v = 'pendente' then 'Aguardar a resposta da Nio (até 24 h) e avisar o cliente; não abrir o pedido antes.'
      when v = 'negado' and coalesce(c.credito_consultas, 0) >= 2 then 'Ver com o cliente outra pessoa da casa como titular; sem saída, encerrar pela Saída.'
      when v = 'negado' then 'Oferecer outra pessoa da casa como titular (CPF do parente → 1 nova consulta).'
      when v = 'aprovado_cartao' and coalesce(c.forma_pagamento, '') <> 'cartao' then 'Só o cartão foi liberado: confirmar se o cliente paga no cartão; se não, outra pessoa da casa como titular.'
      when v = 'aprovado_parcial' and c.forma_pagamento in ('boleto', 'cartao', 'debito')
           and not coalesce(p_saida->'formas_liberadas', '[]'::jsonb) ? (case c.forma_pagamento when 'boleto' then 'BOLETO' when 'cartao' then 'CREDITO' else 'DACC' end)
        then 'A forma escolhida (' || v_fp || ') não foi liberada: combinar com o cliente uma das liberadas (' || coalesce(v_formas, '?') || ').'
      else 'O crédito já está gravado na venda (0330). Abrir o pedido no portal' || coalesce(' no ' || v_fp, '') || '; o NIOGEN já avisou o cliente do crédito (e pediu o plano/forma, se faltava). A biometria sai quando o pedido é feito no portal.' end;
    insert into public.chatwoot_acoes (grupo, ordem, momento, venda_id, conversa_id, chatwoot_conversation_id, tipo, payload, status)
    values (gen_random_uuid(), 1, 'credito', c.venda_id, p_conversa, c.chatwoot_conversation_id, 'nota',
            jsonb_build_object('content', '💳 Crédito chegou (consulta automática da Mari'
              || coalesce(', ' || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), '') || '): '
              || case v when 'aprovado_todas' then 'APROVADO — todas as formas'
                        when 'aprovado_parcial' then 'APROVADO — ' || coalesce(v_formas, 'formas: ?')
                        when 'aprovado_cartao' then 'APROVADO SÓ NO CARTÃO'
                        when 'pendente' then 'PENDENTE (a Nio responde em até 24 h)'
                        when 'negado' then case when coalesce(c.credito_consultas, 0) >= 2 then 'NEGADO nos 2 CPFs (titular e parente)' else 'NEGADO neste CPF' end
                        when 'negado_antifraude' then 'NEGADO — CRITÉRIOS ANTIFRAUDE (a Nio vê Nio neste endereço)'
                        when 'negado_debito' then 'NEGADO — CPF COM DÉBITO NA NIO'
                        when 'pedido_em_andamento' then 'já existe PEDIDO NIO EM ANDAMENTO no CPF'
                        when 'pedido_endereco' then 'já existe PEDIDO NIO EM ANDAMENTO no ENDEREÇO'
                        else 'o portal não decidiu' end
              -- 0204: lido no endereço padrão → não vale para o endereço do cliente
              || case when v_end = 'padrao' and v like 'aprovado%' then ' · ⚠ lido no endereço PADRÃO, não no do cliente' else '' end
              || E'\n👉 Fazer agora: ' || v_fazer), 'pendente');
  end if;
  return jsonb_build_object('ok', true, 'resultado', v, 'endereco', v_end);
end $function$;

CREATE OR REPLACE FUNCTION public.lead_registrar_consulta(p_conversa uuid, p_tipo text, p_resultado text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c    public.mari_conversas;
  rot  text;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  if c.venda_id is not null then raise exception 'Este lead já tem venda: registre na venda.'; end if;

  if p_tipo = 'viabilidade' then
    if p_resultado <> 'viavel' then
      raise exception 'Por aqui só se grava "viável". Sem viabilidade: use Saída › Fachada não atendida.';
    end if;
    update public.mari_conversas
       set nio_viab_resultado = 'viavel', nio_viab_em = now(),
           cobertura_decisao = 'viavel', cobertura_em = now(),
           cobertura_detalhe = coalesce(cobertura_detalhe, '{}'::jsonb) || jsonb_build_object('portal', 'viavel', 'registrado_na_ficha', true),
           rua_conferir_em = null   -- 0202: viável registrado na ficha = rua conferida
     where id = c.id;
    insert into public.operador_consultas (tipo, origem, usuario_id, conversa_id, cep, numero, complemento, resultado, decisao, detalhe)
    values ('viabilidade', 'tela', auth.uid(), c.id, c.cep, c.numero, c.complemento, 'viavel', 'viavel', jsonb_build_object('registrado_na_ficha', true));
    rot := 'viabilidade: viável';

  elsif p_tipo = 'credito' then
    if p_resultado not in ('aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'pendente', 'negado', 'negado_antifraude', 'negado_debito', 'pedido_em_andamento', 'pedido_endereco') then   -- 0383
      raise exception 'Resultado de crédito desconhecido: %', p_resultado;
    end if;
    update public.mari_conversas
       set credito_resultado = p_resultado, credito_em = now(),
           nio_pedido_aberto = case when p_resultado = 'pedido_em_andamento' then 'sim' when p_resultado = 'pedido_endereco' then 'endereco' when p_resultado in ('aprovado_todas', 'aprovado_parcial', 'aprovado_cartao', 'negado', 'negado_antifraude', 'negado_debito') then 'nao' else nio_pedido_aberto end   -- 0313
     where id = c.id;
    insert into public.operador_consultas (tipo, origem, usuario_id, conversa_id, resultado, detalhe)
    values ('credito', 'tela', auth.uid(), c.id, p_resultado, jsonb_build_object('registrado_na_ficha', true));
    rot := 'crédito: ' || case p_resultado when 'aprovado_todas' then 'aprovado' when 'aprovado_parcial' then 'aprovado (parcial)'
                                           when 'aprovado_cartao' then 'aprovado só no cartão' when 'pendente' then 'pendente'
                                           when 'negado' then 'negado' when 'negado_antifraude' then 'negado por critérios antifraude — conferir com o cliente'
                                           when 'negado_debito' then 'negado — CPF com débito na Nio: oferecer quitar e consultar de novo'
                                           when 'pedido_endereco' then 'já tem pedido Nio em andamento no endereço' else 'já tem pedido Nio em andamento no CPF' end;
  else
    raise exception 'Tipo desconhecido: %', p_tipo;
  end if;

  return jsonb_build_object('ok', true, 'resumo', '✓ registrado no lead — ' || rot);
end;
$function$;

CREATE OR REPLACE FUNCTION public._conversa_refechar()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c public.mari_conversas;
begin
  select * into c from public.mari_conversas where id = new.conversa_id;
  if c.id is null or c.canal <> 'whatsapp' or c.chatwoot_conversation_id is null then return null; end if;
  -- silenciada: o cliente escreveu e o Chatwoot reabriu → adia de novo (não volta para o Live; fica em Conversas › Todas)
  if new.papel = 'lead' and coalesce(c.quadro_encerrada_motivo, '') = 'suporte_nio' then
    if not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'resolver'
                    and a.status in ('pendente', 'executando') and a.payload ->> 'status' = 'snoozed') then
      perform public._bo_enfileirar(gen_random_uuid(), 1, 'silenciar', null, c, 'resolver', jsonb_build_object('status', 'snoozed'),
                                    now() + interval '1 minute');
    end if;
    return null;
  end if;
  -- Saída (fora instalada, que tem o pós-venda) e nós respondemos: resolve de novo
  if new.papel in ('mari', 'humano')
     and coalesce(c.funil_destino, 'em_andamento') not in ('em_andamento', 'instalada')
     and coalesce(c.quadro_encerrada_motivo, '') <> 'suporte_nio'
     -- 0249: não olha o chatwoot_status do espelho — o aviso de reabertura do Chatwoot pode chegar DEPOIS da nossa resposta
     -- (caso Carlos Alberto, 16/11 21h20: resolvida 21h19, cliente escreveu, Mari respondeu, espelho ainda "resolved" → ficou aberta)
     and c.chatwoot_agente is null and not coalesce(c.humano_atribuido, false)
     -- 0383 (L-82): a Mari está calada; fala nossa na última hora depois da volta ao time é o eco do "já chamei o time" — fica aberta
     and not (new.papel = 'mari' and exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.momento = 'cliente_voltou'
                                               and a.tipo = 'mensagem' and a.payload ->> 'texto_chave' = 'volta_ao_time'
                                               and a.criada_em > now() - interval '1 hour'))
     and (c.venda_id is null or exists (select 1 from public.vendas v where v.id = c.venda_id and v.status = 'saida'))
     -- 0350: telefone de teste fica sempre em teste_duplicada (fora das contas) — isso não é Saída; só a venda em Saída fecha
     and (not (c.funil_destino = 'teste_duplicada' and public._telefone_de_teste(c.telefone, c.canal))
          or exists (select 1 from public.vendas v where v.id = c.venda_id and v.status = 'saida'))
     and not exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.tipo = 'resolver'
                      and a.status in ('pendente', 'executando')) then
    perform public._bo_enfileirar(gen_random_uuid(), 1, 'refechar', c.venda_id, c, 'resolver', jsonb_build_object('status', 'resolved'),
                                  now() + interval '2 minutes');
  end if;
  return null;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('_conversa_refechar', sqlerrm);
  return null;
end;
$function$;


do $chk$
begin
  if (select count(*) from public.config_lead where parceiro_id = 'dharma' and tipo = 'saida' and codigo in ('pedido_nio_cpf', 'pedido_nio_endereco')) <> 2 then
    raise exception '0383: motivos novos não entraram';
  end if;
  if public.lead_situacao('x', 'saida', 'pedido_nio_endereco', false, null) <> 'saida_pode_voltar' then
    raise exception '0383: lead_situacao não trocou';
  end if;
  if public._porta_destino_de('pedido_nio_cpf') <> 'pedido_nio' or public.funil_destino_de_motivo('Já tem pedido Nio no endereço') <> 'pedido_nio' then
    raise exception '0383: destino não trocou';
  end if;
  if position('ao_time' in pg_get_functiondef('public.porta'::regproc)) = 0
     or position('cliente_escreveu:ao_time' in pg_get_functiondef('public.mari_entrada__nucleo'::regproc)) = 0
     or position('pedido_endereco' in pg_get_functiondef('public.mari_viab_gravar'::regproc)) = 0
     or position('pedido_endereco' in pg_get_functiondef('public.mari_credito_gravar'::regproc)) = 0
     or position('pedido_endereco' in pg_get_functiondef('public.lead_registrar_consulta'::regproc)) = 0 then
    raise exception '0383: funções não trocaram';
  end if;
  if (select count(*) from public.config_transicao where evento = 'cliente_escreveu:ao_time') <> 6 then
    raise exception '0383: tabela da porta sem as 6 linhas';
  end if;
end $chk$;

commit;

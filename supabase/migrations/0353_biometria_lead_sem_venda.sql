-- NIOGEN | supabase/migrations/0353_biometria_lead_sem_venda.sql | 22/11/2026 — Claude Code (Fable 5.2)
-- Caso L-219 (Chatwoot 199, 22/11) — Ricardo: "O fluxo da biometria ainda não está redondo. Fiz esse pedido manualmente, usando a
-- extensão, mas tive que enviar a mensagem da biometria manualmente."
-- O que aconteceu: lead conduzido pelo time, SEM venda no NIOGEN. O crédito foi gravado no lead pela ficha (10h42) e o aviso do
-- crédito saiu sozinho, prometendo "te aviso por aqui assim que [o link da biometria] sair". O pedido foi feito à mão no portal; o
-- GED360 leu o link às 10h49 — e ninguém avisou: o aviso do link (0320) e a biometria aprovada só existem para VENDA
-- (_ged360_aplicar exige venda_id; o GED360 só casa CPF com vendas). O time mandou a mensagem à mão às 10h51. E o lead não tinha
-- como virar venda: a porta recusava "Virar venda" em qualificado_credito com "Este lead já é venda." (0275) — falso para o lead
-- que chegou ali só pelo crédito gravado na conversa.
-- O que muda:
--  (1) GED360 × lead sem venda (_ged360_lead, chamado pelo ged360_registrar): biometria de um CPF que é lead nosso em andamento,
--      sem venda e com crédito aprovado →
--        · link visto (LINK ENVIADO, EM ANÁLISE, CONCLUÍDO…): nota interna + aviso ao cliente (bo_ged_biometria; fora da janela,
--          template nio_lembrete_biometria_v2), UMA vez por conversa;
--        · aprovada (DOC. APTO PARA VENDA, APROVADO): nota interna "vire venda e grave a OS" + alerta na leitura (nível agora). Sem
--          mensagem ao cliente (como na venda: quem fala é o time, com a agenda).
--      Não repete: marca em mari_conversas.dados (bio_ged_link, bio_ged_aprovada = protocolo). Saída e Não contatar barram
--      (Saída aqui; Não contatar dentro do _bo_mensagem). O robô do GED360 roda 7h–22h, a cada 15 min.
--  (2) _ged360_aplicar: o "já avisei" passa a olhar também a conversa (o aviso pode ter saído antes de o lead virar venda).
--  (3) Porta: virar_venda em qualificado_credito passa a ser aceito (lead sem venda com crédito aprovado). Lead que já é venda:
--      o núcleo devolve a mesma venda (repetido), sem criar outra — a tela só mostra o botão para conversa sem venda.
--  (4) lead_virar_venda__nucleo (lead conduzido pelo time): diz de uma vez o que falta gravar na ficha (plano, nome do titular,
--      endereço) e, com o crédito aprovado no portal e a elegibilidade ainda vazia (só a Mari a gravava), grava 'ok' — antes o
--      Virar venda parava em "elegibilidade não confirmada (vazia)" e não havia tela para resolver. 'ja_cliente' e 'fora_area'
--      gravados pela Mari continuam barrando; área, duplicidade e as demais travas do handoff não mudam.
--      Ao virar venda, a leitura do GED360 deste CPF casa com a venda e vale na hora (aprovada → a OS já pode ser gravada).
--  (5) lead_dados_do_portal(conversa, campos): a extensão (0.10.0) manda o que o humano digitou/escolheu no pedido do portal
--      (nome, complemento, número, rua, referência, e-mail, plano, forma) e a função grava SÓ o que está vazio na ficha do lead,
--      com autor e turno de sistema; CPF diferente do lead = recusa tudo; não zera a viabilidade (o pedido acabou de dar viável).
--      Ricardo, 22/11: "Esses dados não deveriam ter sido escritos pelo Portal enquanto o pedido é realizado?" → "Sim, fazer".
-- Regra 20: (1) nenhuma situação nova: o lead segue em qualificado_credito, vez do time, prazo da escada; (2) ninguém parado em
-- silêncio: o cliente recebe o aviso que foi prometido e o time recebe a nota/alerta da aprovação; (3) estado não muda aqui — só
-- aviso, nota e marca; virar venda continua pela porta (lead_virar_venda); (4) fonte: o GED360 da Nio; (5) sem número novo: a
-- leitura sem venda com alerta já aparece na pendência "biometria sem venda". Regra de ouro 6: aviso da venda sai sempre, em nome
-- de quem atende; nunca repetido; nunca de madrugada (horário do robô). Cenário X79 (vermelho antes desta migration).
-- Desempenho: sem impacto em tela (o laço novo roda no robô, sobre as leituras sem venda dos últimos 5 min).
-- Medição (7 dias): leads sem venda com biometria no GED360 e sem aviso ao cliente → 0; vendas 'virou_venda_niogen' que saíram
-- de qualificado_credito.
begin;

-- (3) a porta deixa o lead sem venda, com crédito aprovado, virar venda
update public.config_transicao
   set aceito = true, para = array['qualificado_credito', 'qualificado_biometria', 'qualificado_os']::text[], frase = null,
       nota = '0353 (L-219): lead sem venda com crédito aprovado vira venda (antes: 0275 recusava "já é venda")'
 where evento = 'virar_venda' and de = 'qualificado_credito';
do $$ begin
  if (select count(*) from public.config_transicao where evento = 'virar_venda' and de = 'qualificado_credito' and aceito) <> 1 then
    raise exception '0353: esperava 1 linha aceita de virar_venda em qualificado_credito';
  end if;
end $$;

-- (1) o GED360 fala com o lead sem venda
create or replace function public._ged360_lead(p_b public.nio_biometria)
returns jsonb language plpgsql security definer set search_path = public as $function$
declare
  cfg public.config_biometria_resultado;
  c   public.mari_conversas;
  g   uuid := gen_random_uuid();
  r   jsonb;
begin
  if p_b.venda_id is not null or coalesce(p_b.cpf_cnpj, '') = '' then return null; end if;
  select * into cfg from public.config_biometria_resultado where parceiro_id = p_b.parceiro_id and resultado = p_b.resultado;
  if not found or cfg.acao not in ('espera', 'aprovada') or p_b.resultado = 'AGUARDANDO ENVIO' then return null; end if;
  -- o lead: conversa de WhatsApp sem venda, em andamento, com o crédito aprovado gravado (o pedido no portal é nosso) e o mesmo CPF
  select * into c from public.mari_conversas m
   where m.venda_id is null and m.canal = 'whatsapp' and coalesce(m.chatwoot_conversation_id, '') <> ''
     and public._so_digitos(m.dados ->> 'cpf') = p_b.cpf_cnpj
     and coalesce(m.funil_destino, 'em_andamento') = 'em_andamento' and m.saida_motivo is null and m.quadro_encerrada_motivo is null
     and coalesce(m.credito_resultado, '') ~ '^(aprovado|cartao)' and m.credito_em is not null
     and coalesce(p_b.data_envio, p_b.primeira_leitura) > m.created_at - interval '1 hour'   -- folga: o GED360 dá o envio só até o minuto
   order by m.credito_em desc
   limit 1
   for update;
  if c.id is null then return null; end if;

  if cfg.acao = 'aprovada' then
    if c.dados ? 'bio_ged_aprovada' then return null; end if;
    perform public._bo_enfileirar(g, 1, 'biometria', null, c, 'nota', jsonb_build_object('content',
      '✅ Biometria aprovada no GED360 (' || p_b.resultado || ', protocolo ' || coalesce(p_b.protocolo, '?') || '). '
      || 'Este lead ainda não é venda no NIOGEN: clique em Virar venda (na ficha ou na extensão) e grave a OS e a agenda.'));
    update public.mari_conversas
       set dados = coalesce(dados, '{}'::jsonb) || jsonb_build_object('bio_ged_aprovada', coalesce(p_b.protocolo, '?'))
     where id = c.id;
    return jsonb_build_object('alerta', 'Biometria APROVADA · lead sem venda: Virar venda e gravar a OS e a agenda', 'nivel', 'agora',
                              'feito', 'lead sem venda: biometria aprovada (nota ao time)');
  end if;

  -- link visto: avisa o cliente uma vez (não repete se já avisou, nem depois da aprovada)
  if c.dados ? 'bio_ged_link' or c.dados ? 'bio_ged_aprovada' then return null; end if;
  perform public._bo_enfileirar(g, 1, 'biometria', null, c, 'nota', jsonb_build_object('content',
    '🔗 GED360: a Nio mandou o link da biometria (' || p_b.resultado || ', protocolo ' || coalesce(p_b.protocolo, '?') || ', envio '
    || coalesce(to_char(p_b.data_envio at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), '?') || '). '
    || 'Este lead ainda não é venda no NIOGEN: quando a biometria aprovar, vire venda para gravar a OS e a agenda.'));
  if not exists (select 1 from public.chatwoot_acoes a
                  where a.conversa_id = c.id and a.tipo = 'mensagem' and a.status in ('pendente', 'executando', 'feita')
                    and a.payload ->> 'texto_chave' in ('bo_pedido_biometria', 'bo_os_biometria', 'bo_ged_biometria')) then
    r := public._bo_mensagem(g, 2, 'biometria', null, c, 'bo_ged_biometria', '{}'::jsonb,
                             'nio_lembrete_biometria_v2', jsonb_build_array(public.mari_cadencia_nome(c)), 'aviso do link da biometria (GED360, lead sem venda)');
  end if;
  update public.mari_conversas
     set dados = coalesce(dados, '{}'::jsonb) || jsonb_build_object('bio_ged_link', coalesce(p_b.protocolo, '?'))
   where id = c.id;
  return jsonb_build_object('alerta', null, 'nivel', null,
                            'feito', 'lead sem venda: link da biometria visto' || case when r is not null then ' · aviso ao cliente (' || coalesce(r ->> 'status', '?') || ')' else '' end);
end $function$;

revoke all on function public._ged360_lead(public.nio_biometria) from public, anon, authenticated;

-- (2) o "já avisei" da venda olha também a conversa
CREATE OR REPLACE FUNCTION public._ged360_aplicar(p_b nio_biometria)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  cfg public.config_biometria_resultado;
  v   public.vendas;
  feito text := null;
  c     public.mari_conversas;
  g     uuid := gen_random_uuid();
  v_alerta text;
  v_nivel  text;
begin
  select * into cfg from public.config_biometria_resultado where parceiro_id = p_b.parceiro_id and resultado = p_b.resultado;
  if not found then
    return jsonb_build_object('alerta', null, 'nivel', null, 'feito', 'desconhecido');
  end if;
  -- "Concluído" sem Data da Conferência = ainda esperando a Nio; com conferência e sem regra própria, também espera (não chuta).
  if cfg.acao in ('espera') then
    -- 0247 (Ricardo, 16/11: "a biometria aprovada é uma etapa anterior à criação da OS"): o link saiu (LINK ENVIADO, EM ANÁLISE…)
    -- → a biometria fica pendente já no Qualificado e os lembretes (BIO1/BIO3) contam do link, não da OS.
    if p_b.venda_id is not null and p_b.resultado <> 'AGUARDANDO ENVIO' then
      update public.vendas set biometria_status = 'pendente',
             biometria_link_enviado_em = coalesce(least(p_b.primeira_leitura, p_b.data_envio), now())
       where id = p_b.venda_id and status in ('0_qualificado', '1_vendido', '2_aguardando_instalacao')
         and coalesce(biometria_status, 'nao_enviada') = 'nao_enviada';
      if found then
        -- 0321 (casos L-203 e L-209, 19/11): o link sai do portal na etapa do crédito (0247), sem Pedido gravado — o aviso ao
        -- cliente só saía pelo Pedido/OS. Agora o GED360, ao ver o link pela 1ª vez, deixa nota e avisa o cliente UMA vez:
        -- não repete se o aviso da biometria já saiu (Pedido, OS ou leitura anterior); Saída fica fora (filtro acima);
        -- Não contatar e janela sem template barram dentro do _bo_mensagem (fica "bloqueada", visível na fila).
        select * into v from public.vendas where id = p_b.venda_id;
        select * into c from public.mari_conversas
         where venda_id = v.id and canal = 'whatsapp' and coalesce(chatwoot_conversation_id, '') <> ''
         order by created_at desc limit 1;
        if c.id is not null then
          perform public._bo_enfileirar(g, 1, 'biometria', v.id, c, 'etiquetas', jsonb_build_object('add', jsonb_build_array('biometria-pendente')));
          perform public._bo_enfileirar(g, 2, 'biometria', v.id, c, 'nota', jsonb_build_object('content',
            '🔗 GED360: a Nio mandou o link da biometria (' || p_b.resultado || ', protocolo ' || coalesce(p_b.protocolo, '?') || ', envio '
            || coalesce(to_char(p_b.data_envio at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'), '?') || '). '
            || 'Aguardando o cliente fazer; aprovada, o NIOGEN marca sozinho.'));
          if not exists (select 1 from public.chatwoot_acoes a
                          -- 0353: o aviso pode ter saído quando o lead ainda não era venda (fica só com a conversa)
                          where (a.venda_id = v.id or a.conversa_id = c.id) and a.tipo = 'mensagem' and a.status in ('pendente', 'executando', 'feita')
                            and a.payload ->> 'texto_chave' in ('bo_pedido_biometria', 'bo_os_biometria', 'bo_ged_biometria')) then
            perform public._bo_mensagem(g, 3, 'biometria', v.id, c, 'bo_ged_biometria', '{}'::jsonb,
                                        'nio_lembrete_biometria_v2', jsonb_build_array(public.mari_cadencia_nome(c)), 'aviso do link da biometria (GED360)');
            return jsonb_build_object('alerta', null, 'nivel', null, 'feito', 'biometria pendente (link da Nio visto no GED360) · aviso ao cliente');
          end if;
        end if;
        return jsonb_build_object('alerta', null, 'nivel', null, 'feito', 'biometria pendente (link da Nio visto no GED360)');
      end if;
    end if;
    return jsonb_build_object('alerta', null, 'nivel', null, 'feito', 'espera');
  end if;
  if cfg.acao = 'alerta' then
    return jsonb_build_object('alerta', cfg.texto, 'nivel', cfg.nivel, 'feito', 'alerta');
  end if;
  if p_b.venda_id is null then
    return jsonb_build_object('alerta', null, 'nivel', null, 'feito', null);
  end if;
  select * into v from public.vendas where id = p_b.venda_id for update;
  if not found or v.status = 'saida' then return jsonb_build_object('alerta', null, 'nivel', null, 'feito', null); end if;
  if cfg.acao = 'aprovada' then
    if v.biometria_status is distinct from 'validada' then
      -- 0247: a biometria vem ANTES da OS — aprovada sem OS vale na hora; o próximo passo é a OS no portal.
      if coalesce(btrim(v.nio_os), '') = '' then
        v_nivel := 'agora';
        v_alerta := case when coalesce(btrim(v.nio_interesse), '') <> ''   -- 0210: pedido parado no Interesse do portal
                         then format('Biometria APROVADA · abrir o Interesse %s no portal (Histórico de Pedidos › tipo Interesse) e gerar a OS', v.nio_interesse)
                         else 'Biometria APROVADA · seguir no portal: forma de pagamento, agenda e OS → Gravar venda' end;
      end if;
      update public.vendas set biometria_status = 'validada' where id = v.id;
      insert into public.eventos_venda (venda_id, tipo, detalhe)
      values (v.id, 'biometria_validada', jsonb_build_object('origem', 'ged360', 'protocolo', p_b.protocolo, 'resultado', p_b.resultado));
      feito := 'biometria validada (GED360)';
      -- 0246 (caso Queroly): a etiqueta biometria-pendente ficava no Chatwoot depois da aprovação lida pelo GED360.
      select * into c from public.mari_conversas
       where venda_id = v.id and canal = 'whatsapp' and coalesce(chatwoot_conversation_id, '') <> ''
       order by created_at desc limit 1;
      if c.id is not null then
        perform public._bo_enfileirar(g, 1, 'biometria', v.id, c, 'etiquetas', jsonb_build_object('remove', jsonb_build_array('biometria-pendente')));
        perform public._bo_enfileirar(g, 2, 'biometria', v.id, c, 'nota', jsonb_build_object('content',
          '✅ Biometria aprovada no GED360 (' || p_b.resultado || ', protocolo ' || coalesce(p_b.protocolo, '?') || '). '
          || case when coalesce(btrim(v.nio_os), '') = '' then 'Próximo: forma de pagamento, agenda e OS no portal → Gravar venda no NIOGEN.'
                  when v.forma_pagamento = 'cartao' then 'Cartão: a Nio manda o link do cadastro do cartão; a visita depende dele.'
                  else 'A Mari confirma a instalação ao cliente.' end));
      end if;
    end if;
    return jsonb_build_object('alerta', v_alerta, 'nivel', v_nivel, 'feito', feito);
  end if;
  if cfg.acao = 'risco' then
    -- Não regride: antes da instalação (0191: a OS vem antes da biometria), e só se o GED360 disse isso DEPOIS de alguém marcar validada.
    if v.status in ('0_qualificado', '1_vendido', '2_aguardando_instalacao') and (v.biometria_status is distinct from 'validada' or v.biometria_validada_em < p_b.resultado_desde)
       and v.biometria_status is distinct from 'com_risco' then
      update public.vendas set biometria_status = 'com_risco' where id = v.id;
      feito := 'biometria com risco (GED360)';
    end if;
    return jsonb_build_object('alerta', cfg.texto, 'nivel', cfg.nivel, 'feito', feito);
  end if;
  return jsonb_build_object('alerta', null, 'nivel', null, 'feito', null);
end;
$function$;

-- (1) o robô passa a chamar o _ged360_lead para as leituras sem venda
CREATE OR REPLACE FUNCTION public.ged360_registrar(p_linhas jsonb, p_erro text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r     jsonb;
  prot  text;
  res   text;
  ant   public.nio_biometria;
  b     public.nio_biometria;
  ap    jsonb;
  novo  boolean;
  n     int := 0;
  mud   int := 0;
  vid   uuid;
  desc_ text[] := '{}';
begin
  if p_erro is not null then
    insert into public.ged360_leituras (ok, erro) values (false, left(p_erro, 300));
    return jsonb_build_object('ok', false, 'erro', p_erro);
  end if;
  for r in select * from jsonb_array_elements(coalesce(p_linhas, '[]'::jsonb)) loop
    prot := btrim(coalesce(r ->> 'protocolo', ''));
    res := upper(btrim(regexp_replace(coalesce(r ->> 'resultado', ''), '\s+', ' ', 'g')));
    if prot = '' then continue; end if;
    n := n + 1;
    select * into ant from public.nio_biometria where parceiro_id = 'dharma' and protocolo = prot for update;
    novo := not found;
    insert into public.nio_biometria as t (protocolo, cpf_cnpj, data_envio, data_conferencia, tipo_servico, resultado, desconhecido)
    values (prot, public._so_digitos(r ->> 'cpf_cnpj'), public._br_ts(r ->> 'data_envio'), public._br_ts(r ->> 'data_conferencia'),
            nullif(btrim(r ->> 'tipo_servico'), ''), nullif(res, ''),
            nullif(res, '') is not null and not exists (select 1 from public.config_biometria_resultado c where c.parceiro_id = 'dharma' and c.resultado = res))
    on conflict (parceiro_id, protocolo) do update set
      cpf_cnpj = coalesce(excluded.cpf_cnpj, t.cpf_cnpj), data_envio = coalesce(excluded.data_envio, t.data_envio),
      data_conferencia = coalesce(excluded.data_conferencia, t.data_conferencia), tipo_servico = excluded.tipo_servico,
      resultado_desde = case when t.resultado is distinct from excluded.resultado then now() else t.resultado_desde end,
      resultado = coalesce(excluded.resultado, t.resultado), desconhecido = excluded.desconhecido, ultima_leitura = now()
    returning * into b;
    if b.desconhecido and (novo or ant.resultado is distinct from b.resultado) then
      desc_ := desc_ || b.resultado;
    end if;
  end loop;

  -- Casar pelo CPF (só dígitos) com a venda de pedido aberto (antes da instalação); nunca pelo nome.
  update public.nio_biometria nb set venda_id = x.venda_id
  from (select distinct on (nb2.id) nb2.id, v.id as venda_id
          from public.nio_biometria nb2
          join public.vendas v on public._so_digitos(v.cliente_cpf_cnpj) = nb2.cpf_cnpj
         where nb2.venda_id is null and nb2.cpf_cnpj is not null and v.status in ('0_qualificado', '1_vendido', '2_aguardando_instalacao')
         order by nb2.id, v.criado_em desc) x
  where nb.id = x.id;

  -- Para cada venda, vale o protocolo de Data de Envio mais recente; aplica o mapa quando o resultado mudou (ou casou agora).
  for b in
    select distinct on (venda_id) * from public.nio_biometria
     where venda_id is not null and (ultima_leitura > now() - interval '5 minutes')
     order by venda_id, data_envio desc nulls last, id desc
  loop
    if b.desconhecido then continue; end if;
    if exists (select 1 from public.eventos_venda e where e.venda_id = b.venda_id and e.tipo = 'biometria_ged360'
                and e.detalhe ->> 'protocolo' = b.protocolo and e.detalhe ->> 'para' = b.resultado) then
      continue;   -- já aplicado
    end if;
    mud := mud + 1;
    insert into public.eventos_venda (venda_id, tipo, detalhe)
    values (b.venda_id, 'biometria_ged360', jsonb_build_object('protocolo', b.protocolo, 'para', b.resultado,
            'envio', b.data_envio, 'conferencia', b.data_conferencia));
    ap := public._ged360_aplicar(b);
    update public.nio_biometria set alerta = ap ->> 'alerta', alerta_nivel = ap ->> 'nivel',
      alerta_em = case when ap ->> 'alerta' is null then null else now() end, alerta_visto_em = null
    where id = b.id;
  end loop;
  -- 0353 (caso L-219): biometria de um CPF que é LEAD SEM VENDA nosso (crédito aprovado pelo time, pedido feito no portal).
  -- Vale o protocolo de envio mais recente de cada CPF; o _ged360_lead decide (e não repete: marca em dados da conversa).
  for b in
    select distinct on (nb.cpf_cnpj) nb.* from public.nio_biometria nb
     where nb.venda_id is null and nb.cpf_cnpj is not null and not coalesce(nb.desconhecido, false)
       and nb.ultima_leitura > now() - interval '5 minutes'
       and coalesce(nb.data_envio, nb.primeira_leitura) > now() - interval '3 days'
       and exists (select 1 from public.mari_conversas m
                    where m.venda_id is null and m.credito_em is not null and public._so_digitos(m.dados ->> 'cpf') = nb.cpf_cnpj)
     order by nb.cpf_cnpj, nb.data_envio desc nulls last, nb.id desc
  loop
    ap := public._ged360_lead(b);
    if ap is null then continue; end if;
    mud := mud + 1;
    if ap ->> 'alerta' is not null then
      update public.nio_biometria set alerta = ap ->> 'alerta', alerta_nivel = ap ->> 'nivel', alerta_em = now(), alerta_visto_em = null
       where id = b.id;
    end if;
  end loop;

  -- Sem venda: os alertas valem igual (pendência "biometria sem venda" mostra o resultado).
  update public.nio_biometria nb set alerta = c.texto, alerta_nivel = c.nivel, alerta_em = coalesce(nb.alerta_em, now())
    from public.config_biometria_resultado c
   where nb.venda_id is null and c.parceiro_id = nb.parceiro_id and c.resultado = nb.resultado and c.acao in ('alerta', 'risco')
     and nb.alerta is null and nb.alerta_visto_em is null;

  if array_length(desc_, 1) > 0 then
    insert into public.mari_erros (no_n8n, mensagem, payload)
    values ('ged360_desconhecido', 'GED360: resultado novo fora do mapa (config_biometria_resultado) — completar o mapa',
            jsonb_build_object('resultados', to_jsonb(desc_)));
  end if;
  insert into public.ged360_leituras (ok, linhas, mudancas) values (true, n, mud);
  perform public.biometria_queda_conferir();   -- 0196: radar da biometria da Nio fora do ar
  return jsonb_build_object('ok', true, 'linhas', n, 'mudancas', mud, 'desconhecidos', to_jsonb(desc_));
end;
$function$;

-- (4) Virar venda do lead conduzido pelo time
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
  b public.nio_biometria;   -- 0353
  ap jsonb;   -- 0353
  falta text[];   -- 0353
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
  -- 0353 (caso L-219): lead conduzido pelo time. (a) diz de uma vez o que falta gravar na ficha (antes: uma recusa por clique);
  -- (b) a elegibilidade só a Mari gravava (pergunta "já é cliente Nio?") — com o crédito APROVADO no portal nesta conversa e a
  -- elegibilidade ainda vazia, vale 'ok' (o portal não aprova crédito de quem já tem Nio ou pedido em andamento). Nunca troca
  -- um 'ja_cliente' ou 'fora_area' que a Mari gravou.
  falta := array_remove(array[
    case when not exists (select 1 from public.config_planos p where p.codigo = c.plano_escolhido) then 'plano' end,
    case when coalesce(btrim(c.dados ->> 'nome'), '') = '' then 'nome do titular' end,
    case when c.cep is null or c.numero is null then 'endereço (CEP e número)' end], null);
  if coalesce(array_length(falta, 1), 0) > 0 then
    raise exception 'Para virar venda falta gravar na ficha do lead: %.', array_to_string(falta, ', ');
  end if;
  if c.elegibilidade is null and coalesce(c.credito_resultado, '') ~ '^(aprovado|cartao)' then
    update public.mari_conversas set elegibilidade = 'ok' where id = c.id;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[elegibilidade confirmada pelo crédito aprovado no portal — lead conduzido pelo time (' || quem || ')]', false);
  end if;
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
  -- 0353 (caso L-219): o GED360 já leu a biometria deste CPF enquanto o lead não era venda → casa a leitura com a venda nova e
  -- aplica na hora (pendente, aprovada, risco), sem esperar a próxima rodada do robô. Aprovada = a OS já pode ser gravada.
  update public.nio_biometria nb set venda_id = (r ->> 'venda_id')::uuid
   where nb.venda_id is null and coalesce(nb.cpf_cnpj, '') <> '' and nb.cpf_cnpj = public._so_digitos(c.dados ->> 'cpf')
     and coalesce(nb.data_envio, nb.primeira_leitura) > c.created_at - interval '1 hour';
  select * into b from public.nio_biometria
   where venda_id = (r ->> 'venda_id')::uuid and not coalesce(desconhecido, false)
   order by data_envio desc nulls last, id desc limit 1;
  if b.id is not null then
    insert into public.eventos_venda (venda_id, tipo, detalhe)
    values (b.venda_id, 'biometria_ged360', jsonb_build_object('protocolo', b.protocolo, 'para', b.resultado,
            'envio', b.data_envio, 'conferencia', b.data_conferencia));
    ap := public._ged360_aplicar(b);
    update public.nio_biometria set alerta = ap ->> 'alerta', alerta_nivel = ap ->> 'nivel',
      alerta_em = case when ap ->> 'alerta' is null then null else now() end, alerta_visto_em = null
    where id = b.id;
  end if;
  return jsonb_build_object('ok', true, 'venda_id', r ->> 'venda_id', 'biometria', ap ->> 'feito');
end $function$;

-- (5) o que o humano digitou no pedido do portal volta para a ficha do lead (extensão 0.10.0)
create or replace function public.lead_dados_do_portal(p_conversa uuid, p_campos jsonb)
returns jsonb language plpgsql security definer set search_path = public as $function$
declare
  c       public.mari_conversas;
  a       public.mari_conversas;   -- como estava (para devolver a viabilidade que o gatilho de endereço zera)
  quem    text;
  mud     text[] := '{}';
  fora    text[] := '{}';
  v_txt   text;
  v_dig   text;
  v_dados jsonb;
  v_plano public.config_planos;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  if c.venda_id is not null then return jsonb_build_object('ok', true, 'mudou', '[]'::jsonb, 'resumo', 'Já é venda: nada gravado no lead'); end if;
  if p_campos is null or jsonb_typeof(p_campos) <> 'object' then return jsonb_build_object('ok', true, 'mudou', '[]'::jsonb, 'resumo', 'Nada lido'); end if;
  a := c;
  v_dados := coalesce(c.dados, '{}'::jsonb);

  -- o pedido aberto no portal é deste lead? CPF diferente do gravado = outra pessoa na tela: nada é gravado
  v_dig := regexp_replace(coalesce(p_campos ->> 'cpf', ''), '\D', '', 'g');
  if v_dig <> '' and coalesce(public._so_digitos(v_dados ->> 'cpf'), '') <> '' and public._so_digitos(v_dados ->> 'cpf') <> v_dig then
    raise exception 'O CPF do pedido aberto no portal não é o deste lead: nada foi gravado.';
  end if;
  if v_dig <> '' and coalesce(public._so_digitos(v_dados ->> 'cpf'), '') = '' then
    if (length(v_dig) = 11 and public._cpf_ok(v_dig)) or length(v_dig) = 14 then
      v_dados := v_dados || jsonb_build_object('cpf', v_dig); mud := array_append(mud, 'CPF');
    end if;
  end if;

  -- só o que está VAZIO na ficha: o portal completa, nunca troca o que alguém gravou
  v_txt := nullif(btrim(p_campos ->> 'nome'), '');
  if v_txt is not null and coalesce(btrim(v_dados ->> 'nome'), '') = '' and v_txt ~ '\S+\s+\S+' then
    v_dados := v_dados || jsonb_build_object('nome', left(v_txt, 120)); mud := array_append(mud, 'nome');
  end if;
  v_txt := nullif(lower(btrim(p_campos ->> 'email')), '');
  if v_txt is not null and coalesce(btrim(v_dados ->> 'email'), '') = '' and v_txt ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    v_dados := v_dados || jsonb_build_object('email', v_txt); mud := array_append(mud, 'e-mail');
  end if;
  v_txt := nullif(btrim(p_campos ->> 'numero'), '');
  if v_txt is not null and coalesce(btrim(c.numero), '') = '' then c.numero := left(v_txt, 20); mud := array_append(mud, 'número'); end if;
  v_txt := nullif(btrim(p_campos ->> 'complemento'), '');
  if v_txt is not null and coalesce(btrim(c.complemento), '') = '' then c.complemento := left(v_txt, 60); mud := array_append(mud, 'complemento'); end if;
  v_txt := nullif(btrim(p_campos ->> 'rua'), '');
  if v_txt is not null and coalesce(btrim(v_dados ->> 'rua_confirmada'), '') = '' and coalesce(btrim(c.endereco_cep ->> 'logradouro'), '') = '' then
    v_dados := v_dados || jsonb_build_object('rua_confirmada', left(v_txt, 120)); mud := array_append(mud, 'rua');
  end if;
  v_txt := nullif(btrim(p_campos ->> 'referencia'), '');
  if v_txt is not null and coalesce(btrim(v_dados ->> 'referencia'), '') = '' then
    v_dados := v_dados || jsonb_build_object('referencia', left(v_txt, 120)); mud := array_append(mud, 'referência');
  end if;
  v_txt := nullif(btrim(p_campos ->> 'plano'), '');
  if v_txt is not null and coalesce(btrim(c.plano_escolhido), '') = '' then
    select * into v_plano from public.config_planos where codigo = v_txt and ativo;
    if not found then fora := array_append(fora, 'plano fora da tabela vigente');
    elsif c.cluster is not null and v_plano.cluster is distinct from c.cluster then fora := array_append(fora, 'plano de outra faixa de preço');
    else c.plano_escolhido := v_txt; mud := array_append(mud, 'plano'); end if;
  end if;
  v_txt := nullif(btrim(p_campos ->> 'forma'), '');
  if v_txt is not null and coalesce(btrim(c.forma_pagamento), '') = '' and v_txt in ('boleto', 'cartao', 'dacc') then
    c.forma_pagamento := v_txt; mud := array_append(mud, 'pagamento');
  end if;

  if array_length(mud, 1) is null then
    return jsonb_build_object('ok', true, 'mudou', '[]'::jsonb, 'fora', to_jsonb(fora), 'resumo', 'Nada novo para gravar');
  end if;

  update public.mari_conversas
     set dados = v_dados, numero = c.numero, complemento = c.complemento,
         plano_escolhido = c.plano_escolhido, forma_pagamento = c.forma_pagamento
   where id = p_conversa;
  -- número/complemento novos disparam o gatilho que zera a viabilidade (_mari_viab_endereco_mudou). Aqui o dado veio do PEDIDO
  -- no portal, que acabou de dar viável exatamente para este endereço: a viabilidade gravada continua valendo.
  if a.nio_viab_em is not null and (c.numero is distinct from a.numero or c.complemento is distinct from a.complemento) then
    update public.mari_conversas
       set nio_viab_em = a.nio_viab_em, nio_viab_resultado = a.nio_viab_resultado, nio_viab_velocidade = a.nio_viab_velocidade,
           cobertura_decisao = a.cobertura_decisao, cobertura_detalhe = a.cobertura_detalhe, cobertura_em = a.cobertura_em,
           rua_conferir_em = a.rua_conferir_em, unidade_conferir_em = a.unidade_conferir_em
     where id = p_conversa;
  end if;

  select nome into quem from public.usuarios where id = auth.uid();
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (p_conversa, 'sistema', '[dados lidos do pedido no portal (extensão, ' || coalesce(quem, 'time') || '): ' || array_to_string(mud, ', ') || ']', false);

  return jsonb_build_object('ok', true, 'mudou', to_jsonb(mud), 'fora', to_jsonb(fora),
                            'resumo', '✓ Gravado na ficha (do portal): ' || array_to_string(mud, ', '));
end $function$;

revoke all on function public.lead_dados_do_portal(uuid, jsonb) from public, anon;
grant execute on function public.lead_dados_do_portal(uuid, jsonb) to authenticated;

commit;

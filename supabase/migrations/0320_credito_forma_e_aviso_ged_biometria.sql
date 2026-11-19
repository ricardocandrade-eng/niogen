-- NIOGEN | supabase/migrations/0320_credito_forma_e_aviso_ged_biometria.sql | 19/11/2026 — Claude Code (Opus 5.5)
-- Caso L-203 (Chatwoot 185, 19/11): o crédito foi gravado "só cartão" (portal 15h37: "Elegível apenas para a forma de pagamento:
-- Cartão de Crédito") e o portal respondeu às 15h49 "Elegível para todas as formas de pagamento". O backoffice tentou gravar
-- "aprovado" e a porta recusou: "O crédito já foi aprovado. Para outro CPF, use Trocar o titular." — o mapa da 0275 recusa
-- QUALQUER crédito depois do degrau do crédito, inclusive a troca da forma de pagamento.
-- O que muda: em qualificado_biometria e qualificado_os (crédito aprovado, OS ainda não gravada) os eventos
-- momento:credito:aprovado e momento:credito:so_cartao passam a ser aceitos e ficam na mesma situação ("="). Negado, pendente e
-- o '*' seguem recusados (outro CPF = Trocar o titular); da OS em diante (instalacao_*) nada muda.
-- O núcleo (_porta_momento, crédito) já trata a troca: com o crédito aprovado antes (v_tinha) não repete o evento
-- credito_aprovado_portal nem o "próximo passo"; só regrava credito_resultado e põe a nota interna no Chatwoot (sem mensagem
-- ao cliente). Aprovado só no cartão continua avisando para trocar a forma de pagamento.
-- Regra 20: (1) nenhuma situação nova; (2) nada fica parado — a situação não muda; (3) a mudança passa pela porta
-- (backoffice_momento → porta → _porta_momento), com autor; (4) fonte única: o resultado do portal, gravado pelo BKO;
-- (5) conferência: cenário X48 no portão.
-- Medição (7 dias): recusas "O crédito já foi aprovado" para aprovado/so_cartao em qualificado_biometria/os → 0.
-- ── Parte 2 (antes 0321): o GED360 avisa o cliente do link da biometria ──
-- Casos L-203 (Chatwoot 185) e L-209 (Chatwoot 191), 19/11 — Ricardo: "verifica porque a mensagem falando da biometria não foi
-- enviado pro cliente" · "Sim, fazer os dois". Na ordem do portal desde a 0247 (crédito → Continuar manda o link da biometria →
-- forma de pagamento → agenda → OS), o link sai ANTES de qualquer Pedido/OS gravado no NIOGEN. O aviso ao cliente
-- (bo_pedido_biometria / bo_os_biometria) só saía nesses dois botões; o GED360 via "LINK ENVIADO", deixava a biometria pendente
-- e não avisava ninguém.
-- O que muda: _ged360_aplicar, no ramo "espera" em que a biometria acabou de ficar pendente pelo GED360, enfileira etiqueta
-- biometria-pendente, nota interna e a mensagem nova bo_ged_biometria (fora da janela: template nio_lembrete_biometria_v2) — uma
-- vez por venda: não sai se qualquer aviso da biometria (pedido, OS ou GED) já está na fila ou saiu.
-- Texto novo bo_ged_biometria: o de bo_pedido_biometria sem "seu pedido foi aberto" (nesta ordem o pedido ainda não existe).
-- Regra 20: (1) nenhuma situação nova; (2) nada parado — a vez do cliente agora tem o aviso que a justifica; (3) estado não muda
-- aqui (a biometria pendente já era do GED360); consequência na tabela chatwoot_acoes; (4) fonte: o GED360 da Nio; (5) cenário X49
-- no portão. Regra de ouro 6: Não contatar barra; nunca repetido; o robô do GED360 roda 7h–22h (sem madrugada).
-- Medição (7 dias): venda com biometria pendente pelo GED360 e sem nenhum aviso da biometria ao cliente → 0.
begin;

update public.config_transicao
   set aceito = true, para = array['=']::text[], frase = null,
       nota = '0320 (L-203): trocar a forma do crédito aprovado antes da OS (antes: 0275 recusava)'
 where evento in ('momento:credito:aprovado', 'momento:credito:so_cartao')
   and de in ('qualificado_biometria', 'qualificado_os');

do $$ begin
  if (select count(*) from public.config_transicao
       where evento in ('momento:credito:aprovado', 'momento:credito:so_cartao')
         and de in ('qualificado_biometria', 'qualificado_os') and aceito) <> 4 then
    raise exception '0320: esperava 4 linhas aceitas em config_transicao';
  end if;
end $$;



insert into public.config_mari_textos (chave, texto) values
  ('bo_ged_biometria', E'Oi! A Nio acabou de te mandar o link da biometria por WhatsApp e por e-mail 😊 Ele pede os 5 primeiros números do seu CPF e uma selfie: tira sem óculos, num lugar bem iluminado, e libera a câmera quando o celular pedir.

É rapidinho, uns 2 minutos. Me avisa quando terminar?

⚠️ Importante: a Nio não troca você de operadora. Se alguém disser que seu pedido foi cancelado, que não tem disponibilidade ou pedir para você escolher TIM, Claro ou Vivo, é golpe: não responda e não clique em link. Sobre o seu pedido, fale só por este número ou pelos canais oficiais da Nio.')
on conflict (chave) do update set texto = excluded.texto;

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
                          where a.venda_id = v.id and a.tipo = 'mensagem' and a.status in ('pendente', 'executando', 'feita')
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

commit;

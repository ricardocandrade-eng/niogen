-- NIOGEN | supabase/migrations/0327_credito_aviso_automatico.sql | 19/11/2026 — Claude Code / Opus 5.5
-- Ricardo, 19/11 ~23h: "A mensagem do 'só cartão' não pode ser enviada automaticamente pela Mari, assim que o Portal retorna com a
-- análise?" → "Na verdade a notícia, seja qual for, deve ser automática: negado, só cartão e se for aprovado vai com a forma que ele
-- escolheu durante a conversa". Casos: L-64 (biometria validada, desistiu: "não uso cartão"), L-95 e L-158 — o time deu a notícia do
-- só cartão e ninguém ofereceu outro titular. E com a Mari atendendo, o resultado do portal só chegava ao cliente na PRÓXIMA mensagem
-- dele (o mari_credito_gravar só deixava nota; a Mari fala do crédito quando o cliente escreve).
-- O que muda: o resultado do crédito, venha da consulta automática da Mari (mari_credito_gravar → mari_conversas.credito_resultado)
-- ou do botão do backoffice (backoffice_momento 'credito' → vendas.credito_resultado), avisa o cliente NA HORA, uma vez:
--   · aprovado (todas, ou a forma escolhida está entre as liberadas) → bo_credito_aprovado, com a forma escolhida na conversa
--   · aprovado parcial sem a forma escolhida                         → bo_credito_forma (diz as formas liberadas)
--   · só cartão e a forma escolhida não é cartão                      → bo_credito_cartao (cartão, ou outra pessoa da casa titular)
--     (só cartão e o cliente já escolheu cartão = aprovado no cartão)
--   · negado, 1ª consulta                                            → bo_credito_negado (outro titular: parente ou familiar)
--   · pendente                                                       → bo_credito_pendente (a Nio responde em até 24 h)
--   Ficam sem aviso automático (o time trata, a nota já diz o que fazer): negado na 2ª consulta, antifraude, pedido em andamento,
--   "o portal não decidiu" e o crédito lido no endereço PADRÃO.
-- Regra de ouro 6: aviso da venda sai sempre, também com uma pessoa na conversa (sai em nome dela — _bo_mensagem, 0226); só Saída e
-- Não contatar barram; nunca repetido (o mesmo aviso nos últimos 30 min não sai de novo, e o _bo_mensagem barra o mesmo texto em 12 h);
-- fora da janela de 24 h fica "bloqueada" na fila (sem template). Madrugada: o portal só responde a consulta que a Mari dispara, e
-- a Mari não roda toque de madrugada — o aviso acompanha o crédito.
-- A Mari não repete: o aviso marca em dados as flags que o 7 · Extrair já lê (credito_cartao_avisado · credito_negado_avisado) e as
-- novas (credito_aprovado_avisado · credito_forma_avisado · credito_pendente_avisado). No negado com a Mari atendendo, a passagem ao
-- time (pedido_humano) acontece na próxima fala do cliente (7 · Extrair, flag credito_negado_sistema) — o handoff no Chatwoot é do n8n.
-- Regra 20: (1) nenhuma situação nova; a vez segue com o cliente, que agora sabe o que responder · (2) estado não muda aqui — só o
-- aviso e as flags; o crédito continua gravado pelas funções de sempre · (3) consequência na tabela chatwoot_acoes (fila) ·
-- (4) fonte: o portal da Nio (operador ou extensão) · (5) cenário X54 no portão; a fila já é conferida (R3, R7).
-- Desempenho: sem impacto em tela. Medir em 7 dias: vendas com crédito "só cartão" que viram Saída por "não tenho cartão" → 0;
-- tempo entre o crédito gravado e a próxima mensagem do cliente (hoje: só quando ele escreve).

begin;

insert into public.config_mari_textos (chave, texto) values
('bo_credito_aprovado', $t$Boa notícia! ✅ A análise de crédito da Nio aprovou o seu pedido{forma}.

O próximo passo é a biometria: o link chega da própria Nio, por WhatsApp e por e-mail. Te aviso por aqui assim que sair 😊$t$),
('bo_credito_forma', $t$Boa notícia! ✅ A análise de crédito da Nio aprovou o seu pedido, mas para o seu CPF o pagamento {forma} não foi liberado.

Dá pra seguir com {formas}. Qual fica melhor pra você?$t$),
('bo_credito_cartao', $t$A análise de crédito da Nio saiu: o seu pedido foi aprovado para pagamento no cartão de crédito 💳

Se você paga no cartão, é só me confirmar que a gente segue. Se não usa cartão, outra pessoa da casa pode ser a titular do pedido (é ela quem faz a biometria): me manda o nome completo e o CPF dela que a gente consulta de novo 😊$t$),
('bo_credito_pendente', $t$A análise de crédito da Nio ficou em avaliação: eles respondem em até 24 horas.

Assim que sair, te aviso por aqui 😊$t$)
on conflict (chave) do update set texto = excluded.texto;

-- antes: 'Não conseguimos a aprovação no seu CPF no sistema neste momento.\n\nVocê teria outro CPF (de um familiar ou amigo) para tentarmos a aprovação e dar andamento ao seu pedido?'
-- agora o mesmo texto da Mari (7 · Extrair, 0138): o titular é quem faz a biometria — fonte única para o botão e para o aviso.
update public.config_mari_textos set texto = $t$Poxa, a análise de crédito da Nio não aprovou o pedido neste CPF 😕

Mas dá pra fazer no CPF de um parente ou familiar: ele fica como titular do pedido e é ele quem faz a biometria (o link chega no celular e no e-mail que ficarem no pedido). Pode me mandar o nome completo, o CPF e o parentesco dele?$t$
 where chave = 'bo_credito_negado';

create or replace function public._credito_avisar(p_conversa uuid, p_venda uuid, p_res text, p_formas jsonb, p_origem text)
returns jsonb language plpgsql security definer set search_path = public as $$
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
end $$;
revoke all on function public._credito_avisar(uuid, uuid, text, jsonb, text) from public, anon, authenticated;

create or replace function public._credito_avisar_conversa()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public._credito_avisar(new.id, null, new.credito_resultado, new.credito_formas, 'mari');
  return null;
exception when others then
  insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
  values (new.id, '0327 · aviso do crédito', sqlerrm, jsonb_build_object('resultado', new.credito_resultado));
  return null;
end $$;
revoke all on function public._credito_avisar_conversa() from public, anon, authenticated;

create or replace function public._credito_avisar_venda()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public._credito_avisar(null, new.id, new.credito_resultado, null, 'botao');
  return null;
exception when others then
  insert into public.mari_erros (conversa_id, no_n8n, mensagem, payload)
  values (null, '0327 · aviso do crédito (venda)', sqlerrm, jsonb_build_object('venda_id', new.id, 'resultado', new.credito_resultado));
  return null;
end $$;
revoke all on function public._credito_avisar_venda() from public, anon, authenticated;

drop trigger if exists mari_conversas_credito_aviso on public.mari_conversas;
create trigger mari_conversas_credito_aviso after update of credito_resultado on public.mari_conversas
  for each row when (new.credito_resultado is distinct from old.credito_resultado and new.credito_resultado is not null)
  execute function public._credito_avisar_conversa();

drop trigger if exists vendas_credito_aviso on public.vendas;
create trigger vendas_credito_aviso after update of credito_resultado on public.vendas
  for each row when (new.credito_resultado is distinct from old.credito_resultado and new.credito_resultado is not null)
  execute function public._credito_avisar_venda();

commit;

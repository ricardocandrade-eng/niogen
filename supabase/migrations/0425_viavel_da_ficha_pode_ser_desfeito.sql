-- NIOGEN | supabase/migrations/0425_viavel_da_ficha_pode_ser_desfeito.sql | 26/11/2026 — Claude Code (Fable 5.2)
-- Ricardo, 26/11 ~22h (caso L-434): "Esse lead não tem viabilidade e sem querer eu marquei a mão como 'viável' e agora não consigo
-- corrigir mais. Se for falha, já inclui no mesmo pacote a correção."
-- O que houve: às 21h44 o robô do portal respondeu "sem viabilidade" (DFV: sem) e a conversa ficou "sem cobertura"; às 21h53 o
-- botão 'Registrar "viável" à mão' gravou viável por cima, sem aviso, e daí em diante a ficha diz "Nada a fazer" e esconde os
-- botões. lead_registrar_consulta só aceitava "viável": não havia caminho de volta (só trocar o endereço).
-- O que muda:
--   1. lead_registrar_consulta(conversa, 'viabilidade', 'desfazer'): só para o viável gravado pela ficha (registrado_na_ficha).
--      Volta ao que o robô respondeu por último para o MESMO endereço (resultado, decisão, data); sem resposta do robô, volta a
--      "não consultado" e o robô consulta. Recusa quando o robô também disse viável (aí é Saída › Fachada não atendida).
--      A etapa do funil é recalculada (o viável falso sai do funil) e o desfazer fica registrado em operador_consultas.
--   2. A ficha (front) mostra "Corrigir" no viável da ficha e pede confirmação antes de gravar viável por cima de um "não" do portal.
-- Regra 20: (1) etapa/situação continuam vindo dos gatilhos; (2) ninguém parado: a decisão volta a pedir ação do time;
-- (3) muda só por esta função, com autor (operador_consultas); (4) fonte = o portal, lido pelo robô; (5) conferência: não cria
-- estado nem número novo. Regra 15: sem tabela nova. Desempenho: sem impacto (uma leitura por clique).
-- Cenário: X148. A função não é casca da porta (sem __nucleo).

begin;

CREATE OR REPLACE FUNCTION public.lead_registrar_consulta(p_conversa uuid, p_tipo text, p_resultado text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c    public.mari_conversas;
  rot  text;
  o    public.operador_consultas;   -- 0425: a última resposta do robô do portal para este endereço
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  select * into c from public.mari_conversas where id = p_conversa for update;
  if not found then raise exception 'Conversa não encontrada.'; end if;
  if c.venda_id is not null then raise exception 'Este lead já tem venda: registre na venda.'; end if;

  if p_tipo = 'viabilidade' and p_resultado = 'desfazer' then
    -- 0425 (L-434): o "viável" gravado pela ficha por engano volta ao que o robô do portal respondeu para o mesmo endereço.
    if c.cobertura_decisao is distinct from 'viavel' or coalesce(c.cobertura_detalhe ->> 'registrado_na_ficha', '') <> 'true' then
      raise exception 'Não há "viável" registrado pela ficha para desfazer neste lead.';
    end if;
    select * into o from public.operador_consultas
     where conversa_id = c.id and tipo = 'viabilidade' and origem = 'mari'
       and cep is not distinct from c.cep and numero is not distinct from c.numero and complemento is not distinct from c.complemento
     order by criado_em desc, id desc limit 1;
    if o.id is not null and o.resultado = 'viavel' then
      raise exception 'O robô do portal também respondeu "viável" para este endereço. Sem viabilidade de verdade: use Saída › Fachada não atendida.';
    end if;
    if o.id is not null then
      update public.mari_conversas
         set nio_viab_resultado = case o.resultado when 'sem_viabilidade' then 'sem_viabilidade'
                                                   when 'complemento_fora_lista' then 'nao_encontrado' else 'indisponivel' end,
             nio_viab_em = o.criado_em, cobertura_decisao = o.decisao, cobertura_em = o.criado_em,
             cobertura_detalhe = (c.cobertura_detalhe - 'registrado_na_ficha' - 'portal')
                                 || case when o.resultado = 'nao_decidiu' then '{}'::jsonb else jsonb_build_object('portal', o.resultado) end
                                 || jsonb_build_object('viavel_desfeito_em', now()),
             funil_etapa = null   -- a etapa "só sobe"; aqui ela é recalculada pelo gatilho, para o viável falso não ficar no funil
       where id = c.id;
      rot := 'viável desfeito: voltou ao que o portal respondeu (' || case o.decisao when 'sem_cobertura' then 'sem cobertura'
               when 'elegivel_200m' then 'portal disse não, casa viável perto' when 'unidade_fora_lista' then 'unidade fora da lista'
               else 'o portal não decidiu' end || ')';
    else
      -- nenhuma resposta do robô para este endereço: volta a "não consultado" e o robô consulta (fila mari_viab_pendentes)
      update public.mari_conversas
         set nio_viab_resultado = null, nio_viab_em = null, nio_viab_velocidade = null, cobertura_decisao = null, cobertura_em = null,
             cobertura_detalhe = nullif(c.cobertura_detalhe - 'registrado_na_ficha' - 'portal', '{}'::jsonb),
             funil_etapa = null
       where id = c.id;
      rot := 'viável desfeito: o endereço voltou a "não consultado"';
    end if;
    insert into public.operador_consultas (tipo, origem, usuario_id, conversa_id, cep, numero, complemento, resultado, decisao, detalhe)
    values ('viabilidade', 'tela', auth.uid(), c.id, c.cep, c.numero, c.complemento, 'desfeito', o.decisao,
            jsonb_build_object('desfez_viavel_da_ficha', true, 'voltou_para_consulta', o.id));
    return jsonb_build_object('ok', true, 'resumo', '✓ ' || rot, 'decisao', o.decisao);
  end if;

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

commit;

-- NIOGEN | supabase/migrations/0367_ged360_linha_decisiva.sql | 23/11/2026 — Claude Code / Opus 5.5
-- Ricardo, 23/11: "Investiga por que o GED360 não marcou a biometria sozinho" → "Sim, corrija".
-- Causa (L-248, protocolo 1598269): o Relatório Detalhado do GED360 traz DUAS linhas por protocolo — BIOMETRIA ("CONCLUÍDO") e
-- DOCUMENTOSCOPIA ("DOC. APTO PARA VENDA", conferência 12:03:32). nio_biometria guarda um resultado por protocolo e o
-- ged360_registrar gravava linha a linha: a ÚLTIMA do CSV vencia, e a ordem muda entre leituras. Às 12:04 venceu o CONCLUÍDO
-- (espera) e a aprovação só apareceu às 13:15; às 16:10 os 12 protocolos com duas linhas (38 linhas para 26 protocolos) trocaram de
-- uma vez — o "ALERTA DE RISCO" do L-262 virou "Concluído". No histórico, CONCLUÍDO → APTO levou de 15 min a ~4 dias.
-- O que muda: antes de gravar, as linhas do mesmo protocolo viram uma só — a mais decisiva (risco > alerta > aprovada > espera).
-- Regra 20: (1) nenhuma situação nova · (2) o estado segue mudando pelas mesmas funções (_ged360_aplicar), só com a linha certa ·
-- (3) consequência igual (fila) · (4) fonte única: o GED360 · (5) cenário X93; a leitura já é conferida (ged360_leituras).
-- Desempenho: sem impacto em tela (rotina de 5 min, ~40 linhas). Medir em 7 dias: biometria validada pelo GED360 × marcada à mão;
-- minutos entre a conferência da Nio e a validação no NIOGEN.

begin;

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
  -- 0367 (caso L-248, 23/11): o CSV traz mais de uma linha por protocolo (BIOMETRIA "CONCLUÍDO" + DOCUMENTOSCOPIA "DOC. APTO PARA
  -- VENDA"; ou "ALERTA DE RISCO" + "CONCLUÍDO"). A tabela guarda um resultado por protocolo e a última linha do CSV vencia — a ordem
  -- muda entre leituras: a aprovação ficava escondida e o resultado trocava. Agora vale a linha mais decisiva do protocolo:
  -- risco > alerta > aprovada > espera > fora do mapa; empate → a de conferência/envio mais recente, depois a última do CSV.
  for r in
    select x.e from (
      select t.e, row_number() over (
               partition by btrim(coalesce(t.e ->> 'protocolo', ''))
               order by case c.acao when 'risco' then 1 when 'alerta' then 2 when 'aprovada' then 3 when 'espera' then 4 else 5 end,
                        public._br_ts(t.e ->> 'data_conferencia') desc nulls last, public._br_ts(t.e ->> 'data_envio') desc nulls last,
                        t.o desc) as rn
        from jsonb_array_elements(coalesce(p_linhas, '[]'::jsonb)) with ordinality as t(e, o)
        left join public.config_biometria_resultado c
          on c.parceiro_id = 'dharma' and c.resultado = upper(btrim(regexp_replace(coalesce(t.e ->> 'resultado', ''), '\s+', ' ', 'g')))
    ) x where x.rn = 1
  loop
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

commit;

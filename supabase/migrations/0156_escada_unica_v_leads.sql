-- NIOGEN | supabase/migrations/0156_escada_unica_v_leads.sql | 12/11/2026 — Claude Code (Fable 5.2)
-- Especificação: docs/Prompt_escada_unica_banco_121126_2210.md (Drive) · Plano: docs/PLANO_sistema_fechado_etapas_121126_2135.md, etapa 2.
-- Resultado buscado: um lugar só para saber onde cada lead está e de quem é a vez.
--
-- ESTA É A PARTE 2a (ADITIVA): nada do que existe muda de nome. As colunas funil_etapa / funil_destino da conversa (0147),
-- as etiquetas saida-* e o retrato do Agente de Tráfego seguem iguais. A escada nova é uma CAMADA por cima:
--   1. config_lead — as 6 etapas, os status (com a vez, o prazo e o texto do balão ⓘ) e a lista única de motivos de saída.
--   2. v_leads — uma linha por lead (conversa e/ou venda) com etapa · status · destino · vez · prazo · em espera · saída.
--   3. leads_conferencia() — a conta que tem de fechar todo dia (soma dos destinos = total; lead sem vez; atrasados).
-- Fica para a 2b: saída única (lead_sair / lead_reabrir), motivo do OSAB → lista única, quem sai sozinho (D1),
-- instalada que cancela depois, e os consumidores passarem a ler daqui.
-- A view antiga v_funil (vendas) NÃO é tocada.

-- ───────────────────────── 1. config ─────────────────────────
create table if not exists public.config_lead (
  parceiro_id  text not null default 'dharma',
  tipo         text not null check (tipo in ('etapa', 'status', 'saida')),
  codigo       text not null,
  nome         text not null,
  ordem        int  not null,
  etapa        text,                 -- status: a etapa a que pertence
  vez          text check (vez is null or vez in ('mari', 'time', 'cliente', 'nio')),
  prazo_horas  numeric,              -- status: prazo da vez, em horas (null = sem relógio)
  volta        text,                 -- saída: se e quando o lead pode voltar
  etiqueta     text,                 -- saída: etiqueta do Chatwoot (hoje a da 0147)
  ajuda        text,                 -- texto do balão ⓘ: o que é e o que fazer
  primary key (parceiro_id, tipo, codigo)
);
alter table public.config_lead enable row level security;
drop policy if exists config_lead_ler on public.config_lead;
create policy config_lead_ler on public.config_lead for select to authenticated using (true);
revoke all on public.config_lead from anon;
grant select on public.config_lead to authenticated;
grant all on public.config_lead to service_role;
comment on table public.config_lead is
  'Escada única do lead (0156): 6 etapas, status com a vez e o prazo, e a lista única de motivos de saída. O campo ajuda é o texto do balão ⓘ.';

insert into public.config_lead (tipo, codigo, nome, ordem, etapa, vez, prazo_horas, volta, etiqueta, ajuda) values
  ('etapa', 'atendimento',     'Atendimento',     1, null, null, null, null, null, 'O cliente chegou e a Mari está conversando. Ainda não sabemos o endereço.'),
  ('etapa', 'viabilidade',     'Viabilidade',     2, null, null, null, null, null, 'Temos o CEP e estamos vendo se a Nio atende a cidade e a fachada.'),
  ('etapa', 'pre_qualificado', 'Pré-qualificado', 3, null, null, null, null, null, 'O endereço é atendido e o cliente viu os planos. Falta ele escolher e mandar os dados.'),
  ('etapa', 'qualificado',     'Qualificado',     4, null, null, null, null, null, 'Dados completos, endereço viável, não é cliente Nio e crédito não negado. Daqui até a OS é trabalho do time.'),
  ('etapa', 'instalacao',      'Instalação',      5, null, null, null, null, null, 'A OS está aberta na Nio: é venda. Falta a Nio instalar.'),
  ('etapa', 'instalada',       'Instalada',       6, null, null, null, null, null, 'A Nio instalou. Conta na meta e gera comissão.'),

  ('status', 'nova',                  'Nova',                     1, 'atendimento',     'mari',    null, null, null, 'O cliente mandou a primeira mensagem. A Mari responde sozinha — nada a fazer.'),
  ('status', 'respondeu',             'Respondeu',                2, 'atendimento',     'mari',    null, null, null, 'O cliente está conversando com a Mari. Nada a fazer, a não ser que ela peça uma pessoa.'),
  ('status', 'consultando_cep',       'Consultando CEP',          3, 'viabilidade',     'mari',    null, null, null, 'A Mari tem o CEP e está consultando a cobertura no portal e no DFV. Nada a fazer.'),
  ('status', 'viu_planos',            'Viu os planos',            4, 'pre_qualificado', 'cliente', null, null, null, 'O cliente viu os planos e ainda não escolheu. A vez é dele; a Mari lembra sozinha. Se parou há dias, vale uma mensagem sua.'),
  ('status', 'rodar_credito',         'Rodar crédito',            5, 'qualificado',     'time',    2,    null, null, 'Falta a análise de crédito. A Mari consulta sozinha quando tem CPF e e-mail; se ela já passou a venda, consulte você (botão Consultar crédito) e grave o resultado.'),
  ('status', 'fazer_pedido',          'Fazer o pedido no portal', 6, 'qualificado',     'time',    2,    null, null, 'Crédito aprovado e a biometria ainda não foi enviada. A vez é sua: faça o pedido no portal PAP até o Resumo e confirme — é o clique que manda o link da biometria ao cliente.'),
  ('status', 'aguarda_biometria',     'Aguarda biometria',        7, 'qualificado',     'cliente', 24,   null, null, 'A Nio mandou o link da biometria e o cliente ainda não fez. A vez é dele. Depois de 24 h avise; depois de 72 h ligue.'),
  ('status', 'abrir_os',              'Abrir a OS',               8, 'qualificado',     'time',    4,    null, null, 'Biometria validada. A vez é sua e o contrato dá 4 horas: abra a OS no portal e grave o número aqui.'),
  ('status', 'agendar',               'Agendar',                  9, 'instalacao',      'time',    4,    null, null, 'A OS está aberta e a instalação não tem data. A vez é sua, dentro das 4 horas do contrato: combine dia e período com o cliente, agende no portal e grave aqui.'),
  ('status', 'aguardando_instalacao', 'Aguardando instalação',   10, 'instalacao',      'nio',     null, null, null, 'Instalação com data marcada. A vez é da Nio. Na véspera o cliente recebe a confirmação sozinho.'),
  ('status', 'pendencia_nio',         'Pendência da Nio',        11, 'instalacao',      'time',    24,   null, null, 'A Nio apontou uma pendência na OS (cliente ausente, endereço, técnica). Veja o motivo na ficha e resolva com o cliente ou com a Nio.'),
  ('status', 'instalada',             'Instalada',               12, 'instalada',       null,      null, null, null, 'Instalada. Falta só entregar os documentos à Nio em até 15 dias.'),

  ('saida', 'cidade_nao_atendida',   'Cidade não atendida',     1, null, null, null, 'só com endereço novo',        'saida-fora-area',     'A cidade do cliente não está na área da Dharma. Se ele mandar outro endereço, a conversa reabre.'),
  ('saida', 'fachada_nao_atendida',  'Fachada não atendida',    2, null, null, null, 'revisão em 90 dias',          'saida-sem-cobertura', 'A cidade é atendida, mas a rua ou o prédio não tem rede. Vale rever em 90 dias: a rede cresce.'),
  ('saida', 'ja_cliente_nio',        'Já é cliente Nio',        3, null, null, null, 'quando o pedido antigo cair', 'saida-ja-cliente',    'O cliente ou o endereço já tem Nio, ou há pedido Nio em andamento que não é nosso. Vender aqui dá estorno de 100 % e multa de R$ 500.'),
  ('saida', 'recusou',               'Recusou',                 4, null, null, null, 'na data combinada',           'saida-recusou',       'O cliente não quis: preço, concorrente, momento ou desistiu. Se ele deu uma data, o lead volta para a Live nesse dia.'),
  ('saida', 'credito_negado',        'Crédito negado',          5, null, null, null, 'não',                         'saida-credito',       'Crédito negado no CPF do cliente e também no segundo CPF tentado.'),
  ('saida', 'reprovado_biometria',   'Reprovado na biometria',  6, null, null, null, 'não',                         'saida-biometria',     'A Nio reprovou a biometria e não houve como refazer.'),
  ('saida', 'nio_nao_instalou',      'Nio não instalou',        7, null, null, null, 'não',                         null,                  'A Nio cancelou a OS: inviabilidade técnica ou pendência sem solução. Não foi escolha do cliente.'),
  ('saida', 'sem_resposta',          'Sem resposta',            8, null, null, null, 'quando escrever',             'saida-sem-resposta',  'O cliente parou de responder e os lembretes acabaram. Se ele escrever, a conversa volta de onde parou.'),
  ('saida', 'nao_contatar',          'Não contatar',            9, null, null, null, 'nunca',                       'nao-contatar',        'O cliente pediu para parar. Nunca mais chamar, nem por campanha.'),
  ('saida', 'venda_indevida_fraude', 'Venda indevida ou fraude', 10, null, null, null, 'nunca',                     null,                  'O cliente diz que não pediu, o cadastro está errado ou há sinal de fraude. É multa no contrato: avise o Ricardo.'),
  ('saida', 'teste_duplicada',       'Teste ou duplicada',     11, null, null, null, 'fora da conta',               null,                  'Número de teste ou conversa repetida. Não entra em nenhuma conta.')
on conflict (parceiro_id, tipo, codigo) do update
  set nome = excluded.nome, ordem = excluded.ordem, etapa = excluded.etapa, vez = excluded.vez, prazo_horas = excluded.prazo_horas,
      volta = excluded.volta, etiqueta = excluded.etiqueta, ajuda = excluded.ajuda;

-- ───────────────────────── 2. v_leads ─────────────────────────
-- Uma linha por lead. Conversa e venda entram juntas; venda sem conversa entra sozinha; segunda conversa da mesma venda fica de fora.
-- security_invoker: quem não lê mari_conversas (vendedor, parceiro) vê só os leads das vendas que já enxerga.
create or replace view public.v_leads with (security_invoker = true) as
with par as (
  select c.id as conversa_id, v.id as venda_id,
         row_number() over (partition by coalesce(v.id::text, c.id::text) order by c.ultima_msg_lead_at desc nulls last, c.created_at desc) as rn
    from (select * from public.mari_conversas where canal = 'whatsapp') c
    full join public.vendas v on v.id = c.venda_id
)
select
  coalesce(p.venda_id::text, 'c:' || p.conversa_id::text)                                             as lead_id,
  p.conversa_id, p.venda_id, 'dharma'::text                                                           as parceiro_id,
  coalesce(nullif(btrim(v.cliente_nome), ''), nullif(btrim(c.dados ->> 'nome'), ''), nullif(btrim(c.nome_contato), ''), 'Contato') as nome,
  coalesce(c.telefone, v.cliente_whatsapp)                                                            as telefone,
  coalesce(nullif(btrim(v.cidade), ''), nullif(btrim(c.cidade), ''))                                  as cidade,
  coalesce(nullif(c.origem, ''), nullif(v.origem, ''))                                                as origem,
  coalesce(pl.nome_curto, pl.nome, nullif(c.plano_escolhido, ''))                                     as plano,
  v.valor_mensal, v.comissao_prevista,
  e.etapa, ce.ordem                                                                                   as etapa_ordem, ce.nome as etapa_nome,
  s.status, cs.nome                                                                                   as status_nome, cs.ajuda as status_ajuda,
  d.destino,
  case when d.destino <> 'em_andamento' then null
       when s.vez = 'mari' and (coalesce(c.humano_atribuido, false) or coalesce(c.time_atribuido, false)
                                or c.status = 'handoff_realizado' or c.chatwoot_agente is not null) then 'time'
       else s.vez end                                                                                 as vez,
  case when d.destino <> 'em_andamento' then null
       when s.status = 'aguardando_instalacao' then v.instalacao_agendada_para
       when s.base_em is not null and cs.prazo_horas is not null then s.base_em + make_interval(mins => (cs.prazo_horas * 60)::int)
       end                                                                                            as prazo_em,
  (d.destino = 'em_andamento' and s.status <> 'aguardando_instalacao' and s.base_em is not null and cs.prazo_horas is not null
     and s.base_em + make_interval(mins => (cs.prazo_horas * 60)::int) < now() and esp.motivo is null) as atrasado,
  (d.destino = 'em_andamento' and esp.motivo is not null)                                             as em_espera,
  esp.motivo as espera_motivo, esp.quem as espera_quem, esp.revisar_em as espera_revisar_em,
  case when d.destino = 'saida' then e.etapa end                                                      as etapa_parou,
  sm.saida_motivo, cm.nome as saida_nome, cm.ajuda as saida_ajuda,
  case when d.destino = 'saida' then coalesce(case when v.status = 'saida' then nullif(btrim(v.motivo_saida), '') end, c.funil_detalhe) end as saida_sub,
  case when d.destino = 'saida' then v.interesse_futuro_em end                                        as volta_em,
  coalesce(u.nome, c.chatwoot_agente, case when coalesce(c.time_atribuido, false) or coalesce(c.humano_atribuido, false) then 'time' end,
           case when d.destino = 'em_andamento' and c.id is not null then 'Mari' end)                 as dono,
  v.vendedor_id,
  coalesce(c.created_at, v.criado_em)                                                                 as criado_em,
  greatest(c.ultima_msg_lead_at, c.ultima_msg_mari_at, c.funil_destino_em, v.criado_em)               as ultima_em,
  c.funil_etapa as funil_etapa_antiga, c.funil_destino as funil_destino_antigo, v.status as venda_status
from par p
left join public.mari_conversas c on c.id = p.conversa_id
left join public.vendas v on v.id = p.venda_id
left join public.config_planos pl on pl.id = v.plano_id
left join public.usuarios u on u.id = v.vendedor_id
-- sinais da venda
cross join lateral (select
    coalesce(v.instalado_em is not null or v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme'), false) as instalada,
    coalesce(nullif(btrim(v.nio_os), '') is not null or v.status in ('1_vendido', '2_aguardando_instalacao'), false)       as tem_os,
    coalesce(v.credito_resultado in ('aprovado', 'so_cartao'), false) or coalesce(c.credito_resultado ~ '^(aprovado|cartao)', false) as credito_ok
  ) f
-- etapa: a mais alta entre o que a venda mostra e o que a conversa alcançou (só sobe)
cross join lateral (select case greatest(
      -- venda com conversa: quem diz se qualificou é a conversa (viável, não é cliente Nio, crédito não negado — regra da 0147)
      case when f.instalada then 6 when f.tem_os then 5 when v.id is not null and c.id is null then 4 else 0 end,
      case coalesce(c.funil_etapa, 'nova')
        when 'instalada' then 6 when 'agendada' then 5
        when 'qualificada' then 4 when 'pedido' then 4 when 'biometria' then 4
        when 'viu_planos' then 3
        when 'cep' then 2 when 'area_ok' then 2 when 'viavel' then 2
        else 1 end)
    when 6 then 'instalada' when 5 then 'instalacao' when 4 then 'qualificado' when 3 then 'pre_qualificado' when 2 then 'viabilidade' else 'atendimento' end as etapa
  ) e
-- destino: um só
cross join lateral (select case
    when c.funil_destino = 'teste_duplicada' then 'teste_duplicada'
    when f.instalada then 'instalada'
    when c.id is not null then case coalesce(c.funil_destino, 'em_andamento') when 'em_andamento' then 'em_andamento' when 'instalada' then 'instalada' else 'saida' end
    when v.status = 'saida' then 'saida'
    else 'em_andamento' end as destino
  ) d
-- status, a vez de partida e a hora em que o relógio começou
cross join lateral (select x.status, x.base_em, k.vez
    from (select
      case e.etapa
        when 'instalada' then 'instalada'
        when 'instalacao' then case when nullif(btrim(v.nio_pendencia_cod), '') is not null then 'pendencia_nio'
                                    when v.instalacao_agendada_para is null then 'agendar' else 'aguardando_instalacao' end
        when 'qualificado' then case when v.biometria_status = 'validada' then 'abrir_os'
                                     when v.biometria_status in ('pendente', 'com_risco') then 'aguarda_biometria'
                                     when f.credito_ok then 'fazer_pedido' else 'rodar_credito' end
        when 'pre_qualificado' then 'viu_planos'
        when 'viabilidade' then 'consultando_cep'
        else case when coalesce(c.funil_etapa, 'nova') = 'nova' then 'nova' else 'respondeu' end end as status,
      case e.etapa
        when 'instalacao' then case when nullif(btrim(v.nio_pendencia_cod), '') is not null then v.nio_osab_em
                                    when v.instalacao_agendada_para is null then greatest(v.biometria_validada_em, v.vendido_em, v.nio_os_em) end
        when 'qualificado' then case when v.biometria_status = 'validada' then v.biometria_validada_em
                                     when v.biometria_status in ('pendente', 'com_risco') then coalesce(v.biometria_link_enviado_em, v.credito_em)
                                     when f.credito_ok then coalesce(v.credito_em, c.credito_em, c.handoff_em)
                                     else coalesce(c.handoff_em, v.criado_em) end
        else case when c.status = 'handoff_realizado' then c.handoff_em end end as base_em) x
    left join public.config_lead k on k.parceiro_id = 'dharma' and k.tipo = 'status' and k.codigo = x.status
  ) s
-- em espera: atravessa a escada (pendência da venda ou ⏸ Aguardar da conversa)
left join lateral (
    select pe.motivo, pe.quem_destrava as quem, pe.revisar_em::timestamptz as revisar_em
      from public.venda_pendencias pe where pe.venda_id = v.id and pe.encerrada_em is null
    union all
    select coalesce(c.espera_motivo, 'aguardando'), 'cliente', c.espera_ate where c.espera_ate is not null and c.espera_ate > now()
    limit 1) esp on true
-- motivo de saída na lista única
cross join lateral (select case when d.destino = 'teste_duplicada' then 'teste_duplicada' when d.destino <> 'saida' then null
    when v.status = 'saida' and v.motivo_saida ilike 'Nio:%' then
      case when v.motivo_saida ~* '(indevida|errada|duplicad|j[aá] possui)' then 'venda_indevida_fraude'
           when v.motivo_saida ~* '(desist|concorr)' then 'recusou' else 'nio_nao_instalou' end
    when v.status = 'saida' and v.motivo_saida ~* 'fraude' then 'venda_indevida_fraude'
    else case coalesce(c.funil_destino, public.funil_destino_de_motivo(v.motivo_saida))
           when 'fora_area' then 'cidade_nao_atendida'
           when 'sem_cobertura' then 'fachada_nao_atendida'
           when 'recusou' then case when coalesce(c.nao_contatar, false) and c.funil_detalhe = 'não contatar' then 'nao_contatar' else 'recusou' end
           when 'teste_duplicada' then 'teste_duplicada'
           else coalesce(c.funil_destino, public.funil_destino_de_motivo(v.motivo_saida)) end end as saida_motivo
  ) sm
left join public.config_lead ce on ce.parceiro_id = 'dharma' and ce.tipo = 'etapa'  and ce.codigo = e.etapa
left join public.config_lead cs on cs.parceiro_id = 'dharma' and cs.tipo = 'status' and cs.codigo = s.status
left join public.config_lead cm on cm.parceiro_id = 'dharma' and cm.tipo = 'saida'  and cm.codigo = sm.saida_motivo
where p.rn = 1;

revoke all on public.v_leads from anon;
grant select on public.v_leads to authenticated, service_role;
comment on view public.v_leads is
  'Escada única (0156): uma linha por lead (conversa e/ou venda) com etapa · status · destino · vez · prazo · em espera · saída. Camada sobre funil_* (0147) e vendas; não substitui a v_funil das vendas.';

-- ───────────────────────── 3. a conta que tem de fechar ─────────────────────────
create or replace function public.leads_conferencia()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if auth.role() is distinct from 'service_role' and coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  with l as (select * from public.v_leads),
       reais as (select * from l where destino <> 'teste_duplicada')
  select jsonb_build_object(
    'gerado_em', now(),
    'total', (select count(*) from l),
    'reais', (select count(*) from reais),
    'por_destino', (select jsonb_object_agg(destino, n) from (select destino, count(*) n from l group by 1) x),
    'soma_fecha', (select count(*) from l) = (select coalesce(sum(n), 0) from (select count(*) n from l group by destino) x),
    'chegaram_ate', (select jsonb_object_agg(codigo, n order by ordem) from (
        select k.codigo, k.ordem, (select count(*) from reais r where r.etapa_ordem >= k.ordem) n
          from public.config_lead k where k.tipo = 'etapa' and k.parceiro_id = 'dharma') x),
    'em_andamento_por_status', (select jsonb_object_agg(status, n) from (select status, count(*) n from reais where destino = 'em_andamento' group by 1) x),
    'em_andamento_por_vez', (select jsonb_object_agg(coalesce(vez, 'sem_vez'), n) from (select vez, count(*) n from reais where destino = 'em_andamento' group by 1) x),
    'saidas_por_motivo', (select jsonb_object_agg(coalesce(saida_motivo, 'sem_motivo'), n) from (select saida_motivo, count(*) n from reais where destino = 'saida' group by 1) x),
    'saidas_por_etapa', (select jsonb_object_agg(etapa_parou, n) from (select etapa_parou, count(*) n from reais where destino = 'saida' group by 1) x),
    'sem_vez', (select count(*) from reais where destino = 'em_andamento' and vez is null),
    'sem_status', (select count(*) from reais where status is null),
    'saida_sem_motivo', (select count(*) from reais where destino = 'saida' and saida_motivo is null),
    'atrasados', (select count(*) from reais where atrasado),
    'em_espera', (select count(*) from reais where em_espera),
    'qualificados', (select count(*) from reais where etapa_ordem >= 4 and coalesce(saida_motivo, '') not in ('ja_cliente_nio', 'credito_negado'))
  ) into r;
  return r;
end;
$$;
revoke all on function public.leads_conferencia() from public, anon;
grant execute on function public.leads_conferencia() to authenticated, service_role;

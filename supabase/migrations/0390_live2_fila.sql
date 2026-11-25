-- NIOGEN | supabase/migrations/0390_live2_fila.sql | 24/11/2026 — Claude Code (Fable 5.2)
-- Live 2.0, passo 1 (Ricardo, 24/11: "Consegue tocar tudo, sem minha intervenção?" · "Ao final pode rodar o portão e publicar").
-- A Live de hoje junta sete fontes no navegador e cada tipo de linha tem os seus botões. Aqui nasce a FILA ÚNICA, montada no banco:
--   live2_fila()  → uma linha por lead, em seis tipos de tarefa (responder · venda · agenda · ligar · nio · decidir), já na ordem
--                   (vale × etapa × urgência), com os botões que o banco aceita em cada linha; a conta que fecha (todo lead vivo num
--                   lugar só); o radar (o que não pede ninguém agora); os avisos de sistema (que saem da fila e vão para o Pulso).
--   live2_cobertura_conferir() → compara a fila com quem está esperando resposta (v_conversas.cliente_esperando): cliente esperando
--                   há 10 min ou mais, no horário, fora da fila = furo gravado em live2_furos. É a prova de que nada ficou de fora.
-- O que NÃO muda: nenhuma regra de entrada é reescrita. A fila LÊ as fontes que a Live atual já usa — v_jornada (alarmes e caixas),
-- lead_estado (situação gravada, vez e prazo), live_conferir() e v_andamento_pendencias — e só junta, classifica e ordena. Por isso a
-- fila da 2.0 nunca tem menos do que o "Para fazer + Conferir + Andamento na Nio" da Live atual. fila.html, v_jornada e
-- live_conferir não são tocados.
-- Regra 20: (1) cada linha traz etapa, situação, vez e prazo lidos do banco; (2) lead sem lugar aparece na conta e furo vira alarme;
-- (3) só leitura — a tela não grava estado, cada botão chama a função da porta que já existe; (4) nenhum fato novo; (5) a conferência
-- é a própria live2_cobertura_conferir (o item em conferencia_itens() fica como pendência: a função tem 49 kB e outra sessão a
-- editava hoje). Regra 15: tabelas com parceiro_id; pesos em config_regras.live2_pesos. Regras de ouro 2 e 10: nenhum evento novo.
-- Cenários X120 (fila, tipos e baixa) e X121 (conta e cobertura).
begin;

insert into public.config_regras (chave, valor)
values ('live2_pesos', jsonb_build_object(
  'vale_padrao', 380,
  'etapa', jsonb_build_object('saida', 1, 'conversa', 1, 'viu_planos', 2, 'qualificado', 5, 'pedido', 6, 'instalacao', 6, 'instalada', 2),
  'urgencia', jsonb_build_object('cliente_esperando', 4, 'agora', 3, 'hoje', 2, 'sem_prazo', 1),
  'cobertura_min', 10, 'hora_ini', 9, 'hora_fim', 21))
on conflict (chave) do nothing;

-- ───────────── furos de cobertura ─────────────
create table if not exists public.live2_furos (
  id          bigint generated always as identity primary key,
  parceiro_id text not null default 'dharma',
  conversa_id uuid not null,
  nome        text,
  desde       timestamptz not null,          -- quando o cliente começou a esperar
  visto_em    timestamptz not null default now(),
  fechado_em  timestamptz,                   -- a conversa entrou na fila ou foi respondida
  unique (conversa_id, desde)
);
create index if not exists live2_furos_abertos on public.live2_furos (visto_em) where fechado_em is null;
alter table public.live2_furos enable row level security;
drop policy if exists live2_furos_ler on public.live2_furos;
create policy live2_furos_ler on public.live2_furos for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));
revoke insert, update, delete on public.live2_furos from anon, authenticated;

create table if not exists public.live2_cobertura (
  parceiro_id text primary key default 'dharma',
  rodada_em   timestamptz not null default now(),
  esperando   int not null default 0,
  furos       int not null default 0
);
alter table public.live2_cobertura enable row level security;
drop policy if exists live2_cobertura_ler on public.live2_cobertura;
create policy live2_cobertura_ler on public.live2_cobertura for select to authenticated
  using ((select public.meu_perfil()) in ('admin', 'backoffice'));
revoke insert, update, delete on public.live2_cobertura from anon, authenticated;

-- ───────────── de cada fonte para um dos seis tipos ─────────────
create or replace function public._live2_tipo_botao(p_botao text) returns text language sql immutable as $$
  select case
    when p_botao in ('assumir', 'responder', 'manual') then 'responder'
    when p_botao in ('viabilidade', 'pedido', 'credito', 'biometria', 'os', 'os_agendar', 'cartao') then 'venda'
    when p_botao in ('agendar', 'reagendar') then 'agenda'
    when p_botao in ('docs', 'pendencia', 'conferencia') then 'nio'
    else 'decidir' end
$$;

create or replace function public._live2_tipo_situacao(p_situacao text) returns text language sql immutable as $$
  select case p_situacao
    when 'time_agora' then 'responder'
    when 'qualificado_credito' then 'venda'
    when 'qualificado_os' then 'venda'
    when 'instalacao_agendar' then 'agenda'
    when 'instalacao_pendencia' then 'nio'
    else 'decidir' end
$$;

-- 'sistema' = não é tarefa sobre um cliente: sai da fila e vai para o Pulso (Ricardo, 24/11: "Vão para o Pulso")
create or replace function public._live2_tipo_conferir(p_tipo text) returns text language sql immutable as $$
  select case
    when p_tipo in ('pos_venda') then 'responder'
    when p_tipo in ('janela_fechada', 'retomada_ligar', 'retorno_agora') then 'ligar'
    when p_tipo in ('docs_prazo', 'cancelar_nio', 'os_excecao', 'os_agenda', 'risco_recompra', 'conferir_rua', 'conferir_unidade') then 'nio'
    when p_tipo in ('dono_parado', 'handoff_parado', 'silencio_com_pedido', 'silencio_qualificado', 'volta_hoje', 'retorno_sugerido') then 'decidir'
    else 'sistema' end
$$;

-- ───────────── os botões de cada linha (regra de ouro 3: a tela só mostra o que o banco manda) ─────────────
-- Cada botão: {a: 'abrir' | 'assumir' | 'rpc' | 'tel', rotulo, ...}. 'rpc' traz fn e args; 'confirma' pede o OK antes;
-- 'pede' abre uma pergunta e põe a resposta em args[pede.arg]; 'depois' = 'abrir' abre o cliente quando a função volta.
create or replace function public._live2_acoes(p_fonte text, p_sub text, p_chave text, p_conversa uuid, p_venda uuid,
                                               p_tipo text, p_botao text, p_tel text, p_extra jsonb default null)
returns jsonb language plpgsql immutable as $$
declare
  a    jsonb := '[]'::jsonb;
  tel  text := regexp_replace(coalesce(p_tel, ''), '\D', '', 'g');
  rot  text;
  conv jsonb := to_jsonb(p_conversa);
  vend jsonb := to_jsonb(p_venda);
begin
  if p_fonte in ('jornada', 'situacao', 'prazo') then
    rot := case p_tipo
      when 'responder' then 'Responder'
      when 'venda' then case p_botao when 'credito' then 'Rodar crédito' when 'pedido' then 'Gravar pedido' when 'viabilidade' then 'Viabilidade'
                                     when 'biometria' then 'Biometria' when 'os' then 'OS e agenda' when 'os_agendar' then 'OS e agenda'
                                     when 'cartao' then 'Cartão' else 'Fechar venda' end
      when 'agenda' then case p_botao when 'reagendar' then 'Reagendar' else 'Agendar' end
      when 'nio' then case p_botao when 'docs' then 'Documentos' else 'Abrir pendência' end
      else 'Abrir e decidir' end;
    if p_botao = 'assumir' then
      a := a || jsonb_build_object('a', 'assumir', 'rotulo', 'Assumir e responder', 'principal', true);
    else
      a := a || jsonb_build_object('a', 'abrir', 'rotulo', rot, 'principal', true);
    end if;
    return a;
  end if;

  if p_fonte = 'andamento' then
    if p_sub = 'casar_pedido' then
      select coalesce(jsonb_agg(jsonb_build_object('a', 'rpc', 'fn', 'portal_pedido_casar',
               'args', jsonb_build_object('p_pedido', p_chave, 'p_venda', s ->> 'venda_id'),
               'rotulo', 'Casar com ' || coalesce(s ->> 'nome', 'venda'),
               'confirma', format('Casar o pedido %s do portal com a venda de %s? O status do portal passa a valer para essa venda.', p_chave, coalesce(s ->> 'nome', '?')))), '[]'::jsonb)
        into a from jsonb_array_elements(coalesce(p_extra, '[]'::jsonb)) s;
    else
      a := a || jsonb_build_object('a', 'rpc', 'fn', 'andamento_alerta_visto', 'rotulo', 'Visto',
                                   'args', jsonb_build_object('p_origem', 'ged360', 'p_chave', p_chave));
    end if;
    return a;
  end if;

  -- fonte 'conferir' (e os avisos de sistema)
  if tel <> '' and p_sub in ('janela_fechada', 'retomada_ligar', 'retorno_agora') then
    a := a || jsonb_build_object('a', 'tel', 'rotulo', 'Ligar', 'tel', case when length(tel) <= 11 then '55' || tel else tel end, 'principal', true);
  end if;
  if p_sub = 'janela_fechada' then
    a := a || jsonb_build_object('a', 'rpc', 'fn', 'venda_janela', 'rotulo', 'Atendeu', 'depois', 'abrir',
                                 'args', jsonb_build_object('p_conversa', conv, 'p_acao', 'atendeu', 'p_motivo', null))
           || jsonb_build_object('a', 'rpc', 'fn', 'venda_janela', 'rotulo', 'Não atendeu', 'leve', true,
                                 'args', jsonb_build_object('p_conversa', conv, 'p_acao', 'nao_atendeu', 'p_motivo', null))
           || jsonb_build_object('a', 'rpc', 'fn', 'venda_janela', 'rotulo', 'Mandar template', 'leve', true,
                                 'confirma', 'A janela de 24 h fechou: só sai o template aprovado do degrau. Mandar?',
                                 'args', jsonb_build_object('p_conversa', conv, 'p_acao', 'template', 'p_motivo', null));
  elsif p_sub = 'retomada_ligar' then
    a := a || jsonb_build_object('a', 'rpc', 'fn', 'retomada_ligacao', 'rotulo', 'Atendeu', 'depois', 'abrir',
                                 'args', jsonb_build_object('p_conversa', conv, 'p_resultado', 'atendeu', 'p_motivo', null))
           || jsonb_build_object('a', 'rpc', 'fn', 'retomada_ligacao', 'rotulo', 'Não atendeu', 'leve', true,
                                 'args', jsonb_build_object('p_conversa', conv, 'p_resultado', 'nao_atendeu', 'p_motivo', null))
           || jsonb_build_object('a', 'rpc', 'fn', 'retomada_ligacao', 'rotulo', 'Pular', 'leve', true,
                                 'pede', jsonb_build_object('arg', 'p_motivo', 'titulo', 'Pular a ligação — por quê?',
                                   'opcoes', jsonb_build_array('Telefone inválido', 'Já falei por mensagem', 'Não vale ligar', 'Outro')),
                                 'args', jsonb_build_object('p_conversa', conv, 'p_resultado', 'pular', 'p_motivo', null));
  elsif p_sub = 'retorno_agora' then
    a := a || jsonb_build_object('a', 'abrir', 'rotulo', 'Abrir o cliente', 'leve', true)
           || jsonb_build_object('a', 'rpc', 'fn', 'retorno_fechar', 'rotulo', 'Feito ✓',
                                 'args', jsonb_build_object('p_retorno', p_chave, 'p_como', 'feito', 'p_motivo', null))
           || jsonb_build_object('a', 'rpc', 'fn', 'retorno_fechar', 'rotulo', 'Descartar', 'leve', true,
                                 'pede', jsonb_build_object('arg', 'p_motivo', 'titulo', 'Descartar este retorno — por quê? (opcional)', 'livre', true),
                                 'args', jsonb_build_object('p_retorno', p_chave, 'p_como', 'descartar', 'p_motivo', null));
  elsif p_sub = 'retorno_sugerido' then
    a := a || jsonb_build_object('a', 'rpc', 'fn', 'retorno_fechar', 'rotulo', 'Marcar o retorno', 'principal', true,
                                 'args', jsonb_build_object('p_retorno', p_chave, 'p_como', 'confirmar', 'p_motivo', null))
           || jsonb_build_object('a', 'rpc', 'fn', 'retorno_fechar', 'rotulo', 'Não era retorno', 'leve', true,
                                 'args', jsonb_build_object('p_retorno', p_chave, 'p_como', 'descartar', 'p_motivo', null));
  elsif p_sub in ('dono_parado', 'handoff_parado') then
    a := a || jsonb_build_object('a', 'abrir', 'rotulo', 'Abrir e decidir', 'principal', true)
           || jsonb_build_object('a', 'rpc', 'fn', 'backoffice_momento', 'rotulo', 'Devolver à Mari', 'leve', true,
                                 'confirma', 'Devolver esta conversa para a Mari? Ela retoma, sem dono.',
                                 'args', jsonb_build_object('p_venda', vend, 'p_momento', 'devolver_mari', 'p_dados', jsonb_build_object('conversa_id', conv)));
  elsif p_sub = 'pos_venda' then
    a := a || jsonb_build_object('a', 'abrir', 'rotulo', 'Responder', 'principal', true)
           || jsonb_build_object('a', 'rpc', 'fn', 'backoffice_conversa_dispensar', 'rotulo', 'Nada a responder', 'leve', true,
                                 'args', jsonb_build_object('p_conversa', conv));
  elsif p_sub in ('silencio_com_pedido', 'silencio_qualificado') then
    a := a || jsonb_build_object('a', 'abrir', 'rotulo', 'Abrir e decidir', 'principal', true)
           || jsonb_build_object('a', 'rpc', 'fn', 'lead_sair', 'rotulo', 'Saída · Sem resposta', 'leve', true,
                                 'confirma', 'Registrar a Saída · Sem resposta desta venda? Se o cliente escrever de novo, ela volta.',
                                 'args', jsonb_build_object('p_conversa', null, 'p_venda', vend, 'p_motivo', 'sem_resposta'));
  elsif p_sub = 'volta_hoje' then
    a := a || jsonb_build_object('a', 'rpc', 'fn', 'lead_reabrir', 'rotulo', 'Reabrir', 'principal', true,
                                 'confirma', 'Reabrir este lead? Sai da Saída e volta para o time.',
                                 'args', jsonb_build_object('p_conversa', case when p_venda is null then conv else 'null'::jsonb end, 'p_venda', vend))
           || jsonb_build_object('a', 'rpc', 'fn', 'lead_volta_adiar', 'rotulo', '+7 dias', 'leve', true,
                                 'args', jsonb_build_object('p_conversa', conv, 'p_venda', vend, 'p_dias', 7));
  elsif p_sub = 'os_excecao' then
    a := a || jsonb_build_object('a', 'abrir', 'rotulo', 'Abrir pendência', 'principal', true)
           || jsonb_build_object('a', 'rpc', 'fn', 'os_excecao_visto', 'rotulo', 'Visto', 'leve', true, 'args', jsonb_build_object('p_pedido', p_chave));
  elsif p_sub = 'os_agenda' then
    a := a || jsonb_build_object('a', 'abrir', 'rotulo', 'Abrir o cliente', 'leve', true)
           || jsonb_build_object('a', 'rpc', 'fn', 'os_agenda_ciente', 'rotulo', 'Ciente', 'principal', true, 'args', jsonb_build_object('p_pedido', p_chave));
  elsif p_sub = 'docs_prazo' then
    a := a || jsonb_build_object('a', 'abrir', 'rotulo', 'Abrir o cliente', 'leve', true)
           || jsonb_build_object('a', 'rpc', 'fn', 'venda_docs_entregues', 'rotulo', 'Documentos entregues', 'principal', true, 'args', jsonb_build_object('p_venda', vend));
  elsif p_sub = 'cancelar_nio' then
    a := a || jsonb_build_object('a', 'abrir', 'rotulo', 'Abrir o cliente', 'leve', true)
           || jsonb_build_object('a', 'rpc', 'fn', 'venda_cancelada_no_portal', 'rotulo', 'Cancelei no portal', 'principal', true,
                                 'confirma', 'Confirma que o pedido desta venda já foi cancelado no portal da Nio?',
                                 'args', jsonb_build_object('p_venda', vend));
  elsif p_sub = 'conferir_rua' then
    a := a || jsonb_build_object('a', 'abrir', 'rotulo', 'Conferir a rua', 'principal', true, 'etapa', 'viab')
           || jsonb_build_object('a', 'rpc', 'fn', 'cobertura_rua_conferida', 'rotulo', 'Conferi', 'leve', true, 'args', jsonb_build_object('p_conversa', conv));
  elsif p_sub = 'conferir_unidade' then
    a := a || jsonb_build_object('a', 'abrir', 'rotulo', 'Conferir a unidade', 'principal', true, 'etapa', 'viab')
           || jsonb_build_object('a', 'rpc', 'fn', 'cobertura_unidade_conferida', 'rotulo', 'Conferi', 'leve', true, 'args', jsonb_build_object('p_conversa', conv));
  elsif p_sub = 'acao_falhou' then
    a := a || jsonb_build_object('a', 'rpc', 'fn', 'chatwoot_acao_retentar', 'rotulo', 'Repetir', 'args', jsonb_build_object('p_id', p_chave::bigint))
           || jsonb_build_object('a', 'rpc', 'fn', 'chatwoot_acao_dispensar', 'rotulo', 'Dispensar', 'leve', true, 'args', jsonb_build_object('p_id', p_chave::bigint));
  elsif p_sub = 'fora_niogen' then
    a := a || jsonb_build_object('a', 'abrir', 'rotulo', 'Abrir o cliente')
           || jsonb_build_object('a', 'rpc', 'fn', 'conversa_alerta_visto', 'rotulo', 'Visto', 'leve', true, 'args', jsonb_build_object('p_conversa', conv));
  elsif p_sub = 'conta_nao_fecha' then
    a := a || jsonb_build_object('a', 'rpc', 'fn', 'conferencia_visto', 'rotulo', 'Visto hoje', 'leve', true, 'args', jsonb_build_object('p_codigo', p_chave));
  elsif p_conversa is not null or p_venda is not null then
    a := a || jsonb_build_object('a', 'abrir', 'rotulo', 'Abrir o cliente', 'principal', true);
  end if;
  return a;
end $$;

-- o Reforço entra na 0391; até lá a faixa vem vazia
create or replace function public._live2_reforco() returns jsonb language sql stable as $$ select '[]'::jsonb $$;

-- ───────────── a fila única ─────────────
create or replace function public.live2_fila()
returns jsonb
language plpgsql
stable security definer
set search_path = public
as $$
declare
  v_p     jsonb := coalesce((select valor from public.config_regras where chave = 'live2_pesos'), '{}'::jsonb);
  v_pad   numeric := coalesce((v_p ->> 'vale_padrao')::numeric, 380);
  v_hoje  date := (now() at time zone 'America/Sao_Paulo')::date;
  v_res   jsonb;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    return null;
  end if;

  with j as materialized (
    select distinct on (k) x.*
      from (select coalesce(vj.venda_id::text, 'c:' || vj.conversa_id::text) as k, vj.* from public.v_jornada vj) x
     where x.k is not null
     order by x.k, x.precisa_acao desc
  ),
  est as materialized (
    select coalesce(e.venda_id::text, 'c:' || e.conversa_id::text) as k, e.conversa_id, e.venda_id, e.situacao, e.vez, e.prazo_em, e.em,
           s.nome as sit_nome, s.o_que_fazer as sit_fazer
      from public.lead_estado e
      left join public.config_situacao s on s.codigo = e.situacao
  ),
  conf as materialized (
    select x.tipo, x.chave, x.conversa_id, x.venda_id, x.nome, x.desde, x.texto, public._live2_tipo_conferir(x.tipo) as t6
      from jsonb_to_recordset(coalesce(public.live_conferir(), '[]'::jsonb))
           as x(tipo text, chave text, conversa_id uuid, venda_id uuid, nome text, desde timestamptz, texto text)
  ),
  cand as (
    -- (1) alarmes da jornada (o "Para fazer" de hoje)
    select j.k, j.conversa_id, j.venda_id,
           case when j.caixa = 5 or j.o_que_fazer like 'Resolvida no Chatwoot%' then 'decidir' else public._live2_tipo_botao(j.botao) end as tipo,
           'jornada'::text as fonte, j.botao as sub, null::text as chave, j.nome, j.o_que_fazer as oque, j.desde, null::timestamptz as prazo_em,
           case when j.caixa <> 5 and public._live2_tipo_botao(j.botao) = 'responder' then 4 when j.nivel = 'agora' then 3 when j.nivel = 'hoje' then 2 else 1 end as urg,
           null::jsonb as extra, 1 as pri
      from j where j.precisa_acao
    union all
    -- (2) a vez é do time na situação gravada
    select e.k, e.conversa_id, e.venda_id, public._live2_tipo_situacao(e.situacao), 'situacao', e.situacao, null, null,
           coalesce(case when e.situacao = 'time_agora' and e.venda_id is null and e.conversa_id is not null
                         then public._cutucada_texto(e.conversa_id) end, e.sit_fazer, e.sit_nome),
           coalesce(e.prazo_em, e.em), e.prazo_em,
           case when e.situacao = 'time_agora' then 4 when e.prazo_em is not null and e.prazo_em <= now() then 3 else 2 end,
           null::jsonb, 2
      from est e where e.vez = 'time' and e.k is not null
    union all
    -- (3) prazo gravado vencido há mais de 1 h, com a vez de outro: ninguém parado em silêncio
    select e.k, e.conversa_id, e.venda_id, 'decidir', 'prazo', e.situacao, null, null,
           format('Prazo vencido em "%s" — retomar com data ou dar Saída', coalesce(e.sit_nome, e.situacao)),
           e.prazo_em, e.prazo_em, 2, null::jsonb, 4
      from est e
     where coalesce(e.vez, '') <> 'time' and e.k is not null and e.prazo_em < now() - interval '1 hour'
       and e.situacao in ('time_esperando', 'qualificado_biometria', 'em_espera')
    union all
    -- (4) avisos do Conferir que são tarefa sobre um cliente
    select coalesce(c.venda_id::text, 'c:' || c.conversa_id::text), c.conversa_id, c.venda_id, c.t6, 'conferir', c.tipo, c.chave, c.nome, c.texto,
           c.desde, null::timestamptz,
           case when c.tipo = 'retorno_agora' or c.texto ~* '(VENCIDO|ATRASAD|cancelou|sem técnico)' then 3 else 2 end,
           null::jsonb, 3
      from conf c where c.t6 <> 'sistema' and (c.conversa_id is not null or c.venda_id is not null)
    union all
    -- (5) andamento na Nio sem venda (pedido do portal a casar, biometria sem dono)
    select 'p:' || p.tipo || ':' || p.chave, null::uuid, null::uuid, 'nio', 'andamento', p.tipo, p.chave,
           case when p.tipo = 'casar_pedido' then coalesce(p.nome, 'Cliente') else 'Protocolo ' || p.chave end,
           case when p.tipo = 'casar_pedido' then format('Pedido %s do portal (%s) sem venda no NIOGEN — escolha a venda certa', p.chave, p.rotulo)
                else coalesce(p.alerta, format('Biometria %s (GED360: %s) sem venda aberta no NIOGEN — confira de quem é', p.chave, p.rotulo)) end,
           p.desde, null::timestamptz, case when p.alerta is not null then 3 else 2 end,
           case when p.tipo = 'casar_pedido' then p.sugestoes else null end, 5
      from public.v_andamento_pendencias p
  ),
  -- o lead de cada chave: nome, cidade, plano, etapa e de quem é
  info as (
    select q.k,
           coalesce(jj.conversa_id, q.conversa_id, mcv.id) as conversa_id,
           coalesce(jj.venda_id, q.venda_id) as venda_id,
           coalesce(jj.nome, q.nome, 'Cliente') as nome,
           coalesce(jj.cidade, mc.cidade, vv.cidade) as cidade,
           coalesce(jj.plano, pl.nome_curto, pl.nome) as plano,
           jj.etapa, jj.etapa_nome, jj.caixa, jj.dono_nome,
           mc.telefone, mc.funil_etapa,
           ee.situacao, ee.sit_nome, ee.vez,
           coalesce(nullif(vv.comissao_prevista, 0), pl.comissao + coalesce(bo.valor, 0)) as vale
      from (select k, max(conversa_id::text)::uuid as conversa_id, max(venda_id::text)::uuid as venda_id, max(nome) as nome from cand group by k) q
      left join j jj on jj.k = q.k
      left join public.vendas vv on vv.id = coalesce(jj.venda_id, q.venda_id)
      left join lateral (select m.id from public.mari_conversas m where m.venda_id = vv.id order by m.updated_at desc limit 1) mcv
             on coalesce(jj.conversa_id, q.conversa_id) is null and vv.id is not null
      left join public.mari_conversas mc on mc.id = coalesce(jj.conversa_id, q.conversa_id, mcv.id)
      left join public.config_planos pl on (vv.plano_id is not null and pl.id = vv.plano_id) or (vv.plano_id is null and pl.codigo = mc.plano_escolhido)
      left join lateral (select b.valor from public.config_bonus b where b.tipo = 'transicao' and b.cluster = pl.cluster
                           and b.valido_de <= v_hoje and (b.valido_ate is null or b.valido_ate >= v_hoje) limit 1) bo on true
      left join lateral (select e.situacao, e.sit_nome, e.vez from est e where e.k = q.k limit 1) ee on true
  ),
  pes as (
    select c.*, i.nome as lead_nome, i.cidade, i.plano, i.etapa, i.etapa_nome, i.caixa, i.dono_nome, i.telefone, i.funil_etapa,
           i.situacao, i.sit_nome, i.vez, i.vale, i.conversa_id as conv, i.venda_id as vend,
           case when i.etapa in (3) then coalesce((v_p #>> '{etapa,pedido}')::numeric, 6)
                when i.etapa = 4 then coalesce((v_p #>> '{etapa,instalacao}')::numeric, 6)
                when i.etapa = 2 or (coalesce(i.etapa, 1) = 1 and i.funil_etapa in ('qualificada', 'biometria', 'agendada')) then coalesce((v_p #>> '{etapa,qualificado}')::numeric, 5)
                when i.etapa = 5 then coalesce((v_p #>> '{etapa,instalada}')::numeric, 2)
                when coalesce(i.etapa, 1) = 1 and i.funil_etapa in ('viu_planos', 'viavel') then coalesce((v_p #>> '{etapa,viu_planos}')::numeric, 2)
                when i.etapa = 0 then coalesce((v_p #>> '{etapa,saida}')::numeric, 1)
                else coalesce((v_p #>> '{etapa,conversa}')::numeric, 1) end as pe,
           case c.urg when 4 then coalesce((v_p #>> '{urgencia,cliente_esperando}')::numeric, 4)
                      when 3 then coalesce((v_p #>> '{urgencia,agora}')::numeric, 3)
                      when 2 then coalesce((v_p #>> '{urgencia,hoje}')::numeric, 2)
                      else coalesce((v_p #>> '{urgencia,sem_prazo}')::numeric, 1) end as pu
      from cand c join info i on i.k = c.k
  ),
  ord as (
    select p.*, row_number() over (partition by p.k order by p.urg desc, p.pri) as rn from pes p
  ),
  linhas as (
    select o.k, o.conv as conversa_id, o.vend as venda_id, o.tipo, o.fonte, o.sub, o.lead_nome as nome, o.cidade, o.plano, o.etapa, o.etapa_nome,
           o.situacao, o.sit_nome, o.vez, o.caixa, o.dono_nome, o.oque, o.desde, o.urg, o.pe, o.pu,
           coalesce(o.vale, v_pad) as vale, (o.vale is null) as vale_estimado,
           round(coalesce(o.vale, v_pad) * o.pe * o.pu) as pontos,
           coalesce(o.prazo_em, (select min(x.prazo_em) from pes x where x.k = o.k)) as prazo_em,
           (select coalesce(jsonb_agg(distinct x.oque), '[]'::jsonb) from pes x where x.k = o.k and x.oque is distinct from o.oque and x.oque is not null) as motivos,
           (select coalesce(jsonb_agg(distinct x.fonte || coalesce(':' || x.sub, '')), '[]'::jsonb) from pes x where x.k = o.k) as fontes,
           -- os botões: os da linha escolhida primeiro, depois os dos outros avisos do mesmo lead (sem repetir "abrir")
           (select coalesce(jsonb_agg(b.b order by b.o1, b.o2), '[]'::jsonb)
              from (select distinct on (coalesce(b0 ->> 'fn', b0 ->> 'a') || coalesce(b0 -> 'args' ->> 'p_acao', '') || coalesce(b0 -> 'args' ->> 'p_resultado', '') || coalesce(b0 -> 'args' ->> 'p_como', '') || coalesce(b0 -> 'args' ->> 'p_venda', ''))
                           b0 as b, case when x.k is not null and x.fonte = o.fonte and x.sub is not distinct from o.sub then 0 else 1 end as o1, t.ord as o2
                      from pes x
                      cross join lateral jsonb_array_elements(public._live2_acoes(x.fonte, x.sub, x.chave, o.conv, o.vend, x.tipo, x.sub, o.telefone, x.extra)) with ordinality t(b0, ord)
                     where x.k = o.k
                     order by coalesce(b0 ->> 'fn', b0 ->> 'a') || coalesce(b0 -> 'args' ->> 'p_acao', '') || coalesce(b0 -> 'args' ->> 'p_resultado', '') || coalesce(b0 -> 'args' ->> 'p_como', '') || coalesce(b0 -> 'args' ->> 'p_venda', ''),
                              case when x.fonte = o.fonte and x.sub is not distinct from o.sub then 0 else 1 end, t.ord) b) as acoes
      from ord o where o.rn = 1
  ),
  fila as (
    select l.*, uf.texto as ultima_fala, uf.created_at as ultima_fala_em,
           -- Adiar = Em espera com data (backoffice_conversa_espera), que só vale para conversa sem venda; venda adia pela Pendência da ficha
           (l.conversa_id is not null and l.venda_id is null and coalesce(l.caixa, 0) between 1 and 5 and coalesce(l.situacao, '') not in ('em_espera')) as pode_adiar,
           ((l.conversa_id is not null or l.venda_id is not null) and coalesce(l.caixa, 0) between 1 and 5) as pode_sair
      from linhas l
      left join lateral (select left(regexp_replace(coalesce(t.texto, ''), '\s+', ' ', 'g'), 220) as texto, t.created_at
                           from public.mari_turnos t where t.conversa_id = l.conversa_id and t.papel = 'lead'
                          order by t.created_at desc limit 1) uf on l.conversa_id is not null
  ),
  vivos as (select j.* from j where j.caixa between 1 and 5),
  fora as (select v.* from vivos v where not exists (select 1 from fila f where f.k = v.k))
  select jsonb_build_object(
    'carimbo', now(),
    'pesos', v_p,
    'fila', coalesce((select jsonb_agg(jsonb_build_object(
               'k', f.k, 'conversa_id', f.conversa_id, 'venda_id', f.venda_id, 'tipo', f.tipo, 'fonte', f.fonte, 'sub', f.sub,
               'nome', f.nome, 'cidade', f.cidade, 'plano', f.plano, 'etapa', f.etapa, 'etapa_nome', f.etapa_nome,
               'situacao', f.situacao, 'situacao_nome', f.sit_nome, 'vez', coalesce(f.vez, 'time'), 'dono', f.dono_nome,
               'oque', f.oque, 'motivos', f.motivos, 'fontes', f.fontes, 'desde', f.desde, 'prazo_em', f.prazo_em,
               'urg', f.urg, 'pe', f.pe, 'pu', f.pu, 'vale', f.vale, 'vale_estimado', f.vale_estimado, 'pontos', f.pontos,
               'ultima_fala', f.ultima_fala, 'ultima_fala_em', f.ultima_fala_em,
               'acoes', f.acoes, 'pode_adiar', f.pode_adiar, 'pode_sair', f.pode_sair)
               order by f.pontos desc, f.desde nulls last, f.k) from fila f), '[]'::jsonb),
    'conta', jsonb_build_object(
      'vivos', (select count(*) from vivos),
      'na_fila', (select count(*) from vivos v where exists (select 1 from fila f where f.k = v.k)),
      'com_mari', (select count(*) from fora where caixa = 1),
      'esperando_cliente', (select count(*) from fora where caixa = 3),
      'esperando_nio', (select count(*) from fora where caixa = 4),
      'sem_lugar', (select count(*) from fora where caixa not in (1, 3, 4)),
      'tarefas', (select count(*) from fila),
      'tarefas_de_encerrados', (select count(*) from fila f where not exists (select 1 from vivos v where v.k = f.k)),
      'em_jogo', (select coalesce(sum(f.vale), 0) from fila f where exists (select 1 from vivos v where v.k = f.k))),
    'radar', jsonb_build_object(
      'com_mari', coalesce((select jsonb_agg(x order by x ->> 'desde' desc) from (select jsonb_build_object('k', k, 'nome', nome, 'cidade', cidade, 'plano', plano,
                    'etapa_nome', etapa_nome, 'oque', o_que_fazer, 'desde', desde, 'proximo_toque_em', proximo_toque_em) x from fora where caixa = 1 order by desde desc nulls last limit 60) y), '[]'::jsonb),
      'esperando_cliente', coalesce((select jsonb_agg(jsonb_build_object('k', k, 'nome', nome, 'cidade', cidade, 'plano', plano,
                    'etapa_nome', etapa_nome, 'oque', o_que_fazer, 'desde', desde, 'dono', dono_nome) order by desde) from fora where caixa = 3), '[]'::jsonb),
      'esperando_nio', coalesce((select jsonb_agg(jsonb_build_object('k', k, 'nome', nome, 'cidade', cidade, 'plano', plano,
                    'etapa_nome', etapa_nome, 'oque', o_que_fazer, 'desde', desde) order by desde) from fora where caixa = 4), '[]'::jsonb),
      'sem_lugar', coalesce((select jsonb_agg(jsonb_build_object('k', k, 'nome', nome, 'etapa_nome', etapa_nome, 'oque', o_que_fazer, 'desde', desde)) from fora where caixa not in (1, 3, 4)), '[]'::jsonb)),
    'sistema', coalesce((select jsonb_agg(jsonb_build_object('tipo', c.tipo, 'chave', c.chave, 'nome', c.nome, 'texto', c.texto, 'desde', c.desde,
                    'k', coalesce(c.venda_id::text, 'c:' || c.conversa_id::text),
                    'acoes', public._live2_acoes('conferir', c.tipo, c.chave, c.conversa_id, c.venda_id, 'sistema', null, null, null)) order by c.desde)
                  from conf c where c.t6 = 'sistema' or (c.conversa_id is null and c.venda_id is null)), '[]'::jsonb),
    'reforco', coalesce(public._live2_reforco(), '[]'::jsonb),
    'feitos', (select count(*) from public.porta_sombra s where s.por = auth.uid()
                and s.em >= (date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo')),
    'cobertura', jsonb_build_object(
      'rodada_em', (select c.rodada_em from public.live2_cobertura c where c.parceiro_id = 'dharma'),
      'esperando', (select c.esperando from public.live2_cobertura c where c.parceiro_id = 'dharma'),
      'furos', coalesce((select jsonb_agg(jsonb_build_object('conversa_id', f.conversa_id, 'nome', f.nome, 'desde', f.desde) order by f.desde)
                           from public.live2_furos f where f.fechado_em is null), '[]'::jsonb)))
    into v_res;
  return v_res;
end $$;

revoke all on function public.live2_fila() from public, anon;
grant execute on function public.live2_fila() to authenticated, service_role;
revoke all on function public._live2_reforco() from public, anon, authenticated;   -- só por dentro da live2_fila
revoke all on function public._live2_acoes(text, text, text, uuid, uuid, text, text, text, jsonb) from public, anon;
grant execute on function public._live2_acoes(text, text, text, uuid, uuid, text, text, text, jsonb) to authenticated, service_role;

-- ───────────── a conferência de cobertura ─────────────
-- Chamada pela tela (ao abrir e a cada 5 min), com o perfil de quem está olhando: confere exatamente a fila que a pessoa vê.
create or replace function public.live2_cobertura_conferir()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_p    jsonb := coalesce((select valor from public.config_regras where chave = 'live2_pesos'), '{}'::jsonb);
  v_min  int := coalesce((v_p ->> 'cobertura_min')::int, 10);
  v_hora int := extract(hour from now() at time zone 'America/Sao_Paulo')::int;
  v_f    jsonb;
  v_esp  int := 0;
  v_fur  int := 0;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then
    raise exception 'Só admin ou backoffice.' using errcode = '42501';
  end if;
  v_f := public.live2_fila();

  create temp table if not exists _l2_esp (conversa_id uuid, nome text, desde timestamptz, na_fila boolean) on commit drop;
  truncate _l2_esp;
  insert into _l2_esp
  select c.id, c.nome, c.ult_lead,
         exists (select 1 from jsonb_array_elements(v_f -> 'fila') x
                  where x ->> 'conversa_id' = c.id::text or (c.venda_id is not null and x ->> 'venda_id' = c.venda_id::text))
    from public.v_conversas c
   where c.cliente_esperando and not c.encerrada and coalesce(c.esperando_min, 0) >= v_min;
  select count(*), count(*) filter (where not na_fila) into v_esp, v_fur from _l2_esp;

  -- fora do horário de atendimento ninguém do time está na fila: não vira furo (a espera segue contada na medição)
  if v_hora >= coalesce((v_p ->> 'hora_ini')::int, 9) and v_hora < coalesce((v_p ->> 'hora_fim')::int, 21) then
    insert into public.live2_furos (conversa_id, nome, desde)
    select e.conversa_id, e.nome, e.desde from _l2_esp e where not e.na_fila
    on conflict (conversa_id, desde) do nothing;
  else
    v_fur := 0;
  end if;
  update public.live2_furos f set fechado_em = now()
   where f.fechado_em is null
     and not exists (select 1 from _l2_esp e where e.conversa_id = f.conversa_id and e.desde = f.desde and not e.na_fila);

  insert into public.live2_cobertura (parceiro_id, rodada_em, esperando, furos) values ('dharma', now(), v_esp, v_fur)
  on conflict (parceiro_id) do update set rodada_em = excluded.rodada_em, esperando = excluded.esperando, furos = excluded.furos;

  return jsonb_build_object('rodada_em', now(), 'esperando', v_esp,
    'furos', coalesce((select jsonb_agg(jsonb_build_object('conversa_id', f.conversa_id, 'nome', f.nome, 'desde', f.desde) order by f.desde)
                         from public.live2_furos f where f.fechado_em is null), '[]'::jsonb));
end $$;

revoke all on function public.live2_cobertura_conferir() from public, anon;
grant execute on function public.live2_cobertura_conferir() to authenticated;

commit;

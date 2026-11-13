-- NIOGEN | supabase/migrations/0176_pos_instalacao_indicacao.sql | 13/11/2026 — Claude Code (Fable 5.2)
-- Ricardo, 13/11/2026: "quando uma venda é instalada, a Mari manda sozinha uma mensagem que agradece, passa o suporte da Nio,
-- pergunta se está satisfeito e, logo em seguida, pede uma indicação. Indicou e o indicado instalou → Pix de R$ 100."
-- Decisões dele no mesmo dia: (1) Pix autorizado (risco de contrato assumido) · (2) suporte = só o App Nio · (3) textos aprovados ·
-- (4) a Mari cuida sozinha · (5) a Mari fala com o indicado citando quem indicou · (6) prêmio só depois de instalado, pago 10 dias
-- depois · (7) template pedindo a chave Pix; a resposta vai para o time · insistir pela indicação uma 2ª vez · travas: não vale
-- indicar a si mesmo (mesmo CPF ou endereço) e o indicado passa pelas travas normais.
--
-- Como funciona (nada aqui mexe na mari_entrada, no mari_principal nem na mari_cadencia_avaliar):
--   1. Gatilho em vendas: instalou (leitura da OS, OSAB ou à mão) → 1 linha em pos_instalacao (uma por venda, para sempre).
--   2. indicacao_tick() — chamada pela rotina n8n indicacao_rotina a cada 10 min — manda o template nio_pos_instalacao no horário
--      do contrato (mari_no_horario), pela fila que já existe (chatwoot_acoes → backoffice_chatwoot, fala como Mari).
--   3. Gatilho em mari_turnos (fala do cliente): "Tudo certo" → pede a indicação · "Tive um problema" → time (pós-venda de sempre)
--      · contato recebido (nome + WhatsApp) → linha em indicacoes · sem contato → insiste 1 vez. O que não entende vai para o time.
--   4. A rotina n8n abre a conversa do indicado no Chatwoot; indicacao_abertura_resultado cria a conversa (origem 'indicacao',
--      degrau P1 já dado: a cadência segue com D7 e D15 sozinha) e manda o template nio_indicacao_contato.
--   5. O indicado instalou → prêmio 'previsto' (vence em instalação + 10 dias) e template pedindo a chave Pix a quem indicou.
--      O Pix é pago à mão pelo Ricardo; a tela Pagamentos mostra o que há a pagar e registra o pago.
-- Dois interruptores em config_regras.indicacao: "ligado" (tudo) e "abrir_conversa" (falar com o indicado). Nascem DESLIGADOS.
-- Regra 15: tabelas com parceiro_id, valores e textos em config. RLS: admin e backoffice leem; escrita só pelas funções.

-- ───────────────────────── 1. config, textos e templates ─────────────────────────
insert into public.config_regras (chave, valor, descricao, parceiro_id) values
  ('indicacao', jsonb_build_object(
      'ligado', false, 'abrir_conversa', false,
      'premio_valor', 100, 'premio_dias', 10,
      'espera_min', 60, 'janela_instalacao_dias', 3, 'validade_resposta_dias', 7, 'validade_pedido_horas', 48,
      'insistir_apos_min', 120, 'inbox_id', 153431),
   'Pós-instalação com indicação (0176). ligado = a rotina manda mensagens; abrir_conversa = a Mari fala com o indicado. '
   'premio_valor em R$, premio_dias depois da instalação do indicado; espera_min entre a instalação lida e a mensagem.', 'dharma')
on conflict (chave) do nothing;

insert into public.config_mari_textos (chave, texto) values
  ('indicacao_pedido',   'Que bom! 🎉 Conhece alguém que também quer internet boa? Me passa o nome e o WhatsApp. Se a pessoa instalar a Nio, você ganha R$ 100 no Pix.'),
  ('indicacao_insistir', 'Pode ser um vizinho, um parente ou um colega de trabalho 😉 Cada pessoa que instalar a Nio pela sua indicação vale R$ 100 no Pix pra você. Lembra de alguém? É só me mandar o nome e o WhatsApp.'),
  ('indicacao_obrigado', 'Anotado, obrigada! 🙌 Vou falar com {nome}. Assim que a instalação acontecer, te aviso por aqui e combino o seu Pix de R$ 100. Se lembrar de mais alguém, é só mandar.'),
  ('indicacao_ja',       'Obrigada! Esse contato já está com a gente 😊 Se lembrar de mais alguém, é só me mandar o nome e o WhatsApp.'),
  ('indicacao_problema', 'Poxa, sinto muito por isso. Já avisei o nosso time, que vai falar com você por aqui.')
on conflict (chave) do nothing;

insert into public.config_templates_waba (nome, categoria, idioma, corpo, botoes, status, uso) values
  ('nio_pos_instalacao', 'UTILITY', 'pt_BR',
   'Oi, {{1}}! É a Mari, da Nio 😊 Sua internet foi instalada. Obrigada por escolher a gente! Se precisar de suporte, é só chamar pelo App Nio. Me conta: deu tudo certo com a instalação?',
   '["Tudo certo", "Tive um problema"]'::jsonb, 'PENDING', 'POS_INSTALACAO'),
  ('nio_indicacao_contato', 'MARKETING', 'pt_BR',
   'Oi, {{1}}! Aqui é a Mari, da Nio 👋 {{2}} me passou seu contato e disse que você pode gostar da internet fibra da Nio. Posso ver a disponibilidade no seu endereço?',
   '[]'::jsonb, 'PENDING', 'INDICACAO'),
  ('nio_indicacao_premio', 'UTILITY', 'pt_BR',
   'Boa notícia, {{1}}! {{2}} instalou a Nio pela sua indicação e você ganhou R$ 100 🎉 Me passa a sua chave Pix? O pagamento sai em até 10 dias.',
   '[]'::jsonb, 'PENDING', 'INDICACAO_PREMIO')
on conflict (nome) do nothing;

-- ───────────────────────── 2. tabelas ─────────────────────────
create table if not exists public.pos_instalacao (
  id            uuid primary key default gen_random_uuid(),
  parceiro_id   text not null default 'dharma',
  venda_id      uuid not null unique references public.vendas (id) on delete cascade,
  conversa_id   uuid references public.mari_conversas (id) on delete set null,
  estado        text not null default 'agendada'
                check (estado in ('agendada', 'enviada', 'pediu', 'insatisfeito', 'com_time', 'sem_resposta', 'encerrada', 'sem_conversa', 'expirada')),
  enviar_em     timestamptz not null,
  enviada_em    timestamptz,
  respondeu_em  timestamptz,
  pediu_em      timestamptz,
  insistencias  int not null default 0,
  insistiu_em   timestamptz,
  tratado_em    timestamptz,          -- = now() da transação em que a automação respondeu a fala (o pós-venda do time não dispara)
  encerrada_em  timestamptz,
  resposta      text,
  criado_em     timestamptz not null default now()
);
create index if not exists pos_instalacao_conversa_idx on public.pos_instalacao (conversa_id) where estado in ('enviada', 'pediu');
create index if not exists pos_instalacao_fila_idx on public.pos_instalacao (enviar_em) where estado = 'agendada';
comment on table public.pos_instalacao is
  'Mensagem de pós-instalação (0176): uma linha por venda instalada. Escrita só pelos gatilhos e por indicacao_tick().';

create table if not exists public.indicacoes (
  id                   uuid primary key default gen_random_uuid(),
  parceiro_id          text not null default 'dharma',
  pos_instalacao_id    uuid references public.pos_instalacao (id) on delete set null,
  indicador_venda_id   uuid not null references public.vendas (id) on delete cascade,
  indicador_conversa_id uuid references public.mari_conversas (id) on delete set null,
  indicado_nome        text,
  indicado_telefone    text not null check (indicado_telefone ~ '^\d{12,13}$'),   -- 55 + DDD + número, como o cliente passou
  tel_chave            text not null,                                             -- DDD + 8 últimos dígitos (ignora o 9)
  texto_original       text,
  estado               text not null default 'recebida'
                       check (estado in ('recebida', 'contatada', 'em_venda', 'instalada', 'invalida', 'erro')),
  motivo               text,
  conversa_id          uuid references public.mari_conversas (id) on delete set null,   -- a conversa do indicado
  venda_id             uuid references public.vendas (id) on delete set null,           -- a venda do indicado
  tentativas           int not null default 0,
  tentativa_em         timestamptz,
  criado_em            timestamptz not null default now(),
  contatada_em         timestamptz,
  instalado_em         timestamptz,
  premio_status        text not null default 'nenhum' check (premio_status in ('nenhum', 'previsto', 'pago', 'cancelado')),
  premio_valor         numeric(10, 2),
  premio_vence_em      date,
  pix_chave            text,
  pix_gravada_em       timestamptz,
  pix_gravada_por      uuid,
  pix_pedido_em        timestamptz,
  pago_em              timestamptz,
  pago_por             uuid,
  comprovante_path     text,
  obs                  text
);
create unique index if not exists indicacoes_tel_uidx on public.indicacoes (parceiro_id, tel_chave) where estado <> 'invalida';
create index if not exists indicacoes_indicador_idx on public.indicacoes (indicador_venda_id);
create index if not exists indicacoes_venda_idx on public.indicacoes (venda_id) where venda_id is not null;
comment on table public.indicacoes is
  'Indicação de cliente instalado (0176): quem indicou, quem foi indicado, o que virou e o Pix de prêmio. O Pix é pago à mão '
  'pelo Ricardo; aqui só fica o que há a pagar e o que foi pago. Escrita só pelas funções indicacao_*.';

alter table public.pos_instalacao enable row level security;
alter table public.indicacoes enable row level security;
drop policy if exists pos_instalacao_ler on public.pos_instalacao;
create policy pos_instalacao_ler on public.pos_instalacao for select to authenticated
  using (coalesce(public.meu_perfil(), '') in ('admin', 'backoffice'));
drop policy if exists indicacoes_ler on public.indicacoes;
create policy indicacoes_ler on public.indicacoes for select to authenticated
  using (coalesce(public.meu_perfil(), '') in ('admin', 'backoffice'));
revoke all on public.pos_instalacao, public.indicacoes from anon, authenticated;
grant select on public.pos_instalacao, public.indicacoes to authenticated;
grant all on public.pos_instalacao, public.indicacoes to service_role;

-- ───────────────────────── 3. miúdos ─────────────────────────
create or replace function public._ind_cfg() returns jsonb language sql stable set search_path = public as $$
  select coalesce((select valor from public.config_regras where chave = 'indicacao'), '{}'::jsonb)
$$;

-- DDD + 8 últimos dígitos: a mesma pessoa com ou sem o 9, com ou sem o 55.
create or replace function public._tel_chave(p text) returns text language sql immutable as $$
  select case when length(d) >= 10 then substr(d, 1, 2) || right(d, 8) end
    from (select case when length(x) >= 12 and x like '55%' then substr(x, 3) else x end as d
            from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') as x) a) b
$$;

-- Telefone no formato em que o WhatsApp entrega (o mesmo de mari_conversas.telefone): DDD 11–28 com o 9, os demais sem.
create or replace function public._tel_wa(p text) returns text language sql immutable as $$
  select case when k is null then null
              when substr(k, 1, 2)::int between 11 and 28 and substr(k, 3, 1) in ('6', '7', '8', '9') then '55' || substr(k, 1, 2) || '9' || substr(k, 3)
              else '55' || k end
    from (select public._tel_chave(p) as k) a
$$;

create or replace function public._ind_norm(p text) returns text language sql immutable as $$
  select btrim(regexp_replace(regexp_replace(translate(lower(coalesce(p, '')), 'áàâãäéèêëíìîïóòôõöúùûüç', 'aaaaaeeeeiiiiooooouuuuc'),
                                             '[^a-z0-9 ]', ' ', 'g'), '\s+', ' ', 'g'))
$$;

create or replace function public._ind_primeiro_nome(p text) returns text language sql immutable as $$
  select nullif(initcap(split_part(btrim(coalesce(p, '')), ' ', 1)), '')
$$;

-- Telefones citados numa fala: [{tel: '55DDDnúmero', chave}]. Sem DDD, usa o DDD de quem indicou.
create or replace function public._ind_telefones(p_texto text, p_ddd text) returns jsonb
language plpgsql immutable as $$
declare m text[]; r jsonb := '[]'::jsonb; n text; t text := coalesce(p_texto, '');
begin
  for m in select regexp_matches(t, '(?<!\d)(?:\+?55[\s.-]*)?\(?0?(\d{2})\)?[\s.-]*(9?)[\s.-]*(\d{4})[\s.-]*(\d{4})(?!\d)', 'g') loop
    n := m[1] || m[2] || m[3] || m[4];
    if m[2] = '' and substr(m[3], 1, 1) in ('6', '7', '8', '9') then n := m[1] || '9' || m[3] || m[4]; end if;
    r := r || jsonb_build_object('tel', '55' || n, 'chave', public._tel_chave(n));
  end loop;
  if jsonb_array_length(r) = 0 and coalesce(p_ddd, '') ~ '^\d{2}$' then
    for m in select regexp_matches(t, '(?:^|\D)(9?)[\s.-]*(\d{4})[\s.-]*(\d{4})(?!\d)', 'g') loop
      n := p_ddd || case when m[1] = '9' or substr(m[2], 1, 1) in ('6', '7', '8', '9') then '9' else '' end || m[2] || m[3];
      r := r || jsonb_build_object('tel', '55' || n, 'chave', public._tel_chave(n));
    end loop;
  end if;
  return r;
end $$;

-- Nome do indicado: o que sobra da fala sem os números e sem as palavras de enchimento (até 3 palavras). Vazio = não deu para saber.
create or replace function public._ind_nome(p_texto text) returns text language plpgsql immutable as $$
declare s text; w text; saida text[] := '{}';
begin
  s := regexp_replace(coalesce(p_texto, ''), '[\d()+.\-_:;,!?/\\"*]+', ' ', 'g');
  for w in select x from regexp_split_to_table(btrim(s), '\s+') x loop
    if length(w) < 2 or w !~ '^[A-Za-zÀ-ÿ'']+$' then continue; end if;
    if public._ind_norm(w) = any (array['do','da','de','dos','das','meu','minha','nome','dele','dela','numero','whatsapp','whats','zap','wpp','tel',
        'telefone','celular','contato','amigo','amiga','vizinho','vizinha','irmao','irma','primo','prima','tio','tia','pai','mae','cunhado',
        'cunhada','colega','esposa','esposo','marido','filho','filha','sogro','sogra','segue','aqui','esse','essa','este','esta','pode','ser',
        'tem','tenho','sim','claro','chama','ele','ela','anota','ai','um','uma','que','quer','tambem','internet','fala','falar','com','para',
        'pra','sr','sra','dona','seu','ola','oi','bom','boa','dia','tarde','noite','obrigado','obrigada','vou','indicar','indico','indicacao',
        'conheco','trabalho','la','no','na','em','eh','mari','nio','fibra','se','chamar','procurar','so','ja']) then continue; end if;
    saida := saida || initcap(w);
    exit when array_length(saida, 1) >= 3;
  end loop;
  return nullif(array_to_string(saida, ' '), '');
end $$;

revoke all on function public._ind_cfg(), public._tel_chave(text), public._tel_wa(text), public._ind_norm(text),
  public._ind_primeiro_nome(text), public._ind_telefones(text, text), public._ind_nome(text) from public, anon;
grant execute on function public._ind_cfg(), public._tel_chave(text), public._tel_wa(text), public._ind_norm(text),
  public._ind_primeiro_nome(text), public._ind_telefones(text, text), public._ind_nome(text) to authenticated, service_role;

-- Template pela fila do Chatwoot (sempre template: tem botões / a janela costuma estar fechada). Devolve o id da ação, ou null
-- se o template ainda não está APPROVED na Meta ou o cliente pediu para não ser contatado.
create or replace function public._ind_template(c public.mari_conversas, p_venda uuid, p_momento text, p_template text, p_params jsonb)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_tpl public.config_templates_waba; v_txt text;
begin
  if c.id is null or coalesce(c.chatwoot_conversation_id, '') = '' or coalesce(c.nao_contatar, false) then return null; end if;
  select * into v_tpl from public.config_templates_waba where nome = p_template and status = 'APPROVED';
  if v_tpl.nome is null then return null; end if;
  v_txt := public.mari_render_template(v_tpl.nome, p_params);
  return public._bo_enfileirar(gen_random_uuid(), 1, p_momento, p_venda, c, 'mensagem',
    jsonb_build_object('content', v_txt, 'message_type', 'outgoing', 'private', false, 'content_type', 'text',
      'rotulo', p_momento, 'template', v_tpl.nome,
      'template_params', jsonb_build_object('name', v_tpl.nome, 'category', v_tpl.categoria, 'language', v_tpl.idioma,
        'processed_params', jsonb_build_object('body',
          coalesce((select jsonb_object_agg((o)::text, e) from jsonb_array_elements_text(coalesce(p_params, '[]'::jsonb))
                     with ordinality as t(e, o)), '{}'::jsonb)))));
end $$;
revoke all on function public._ind_template(public.mari_conversas, uuid, text, text, jsonb) from public, anon, authenticated;

-- ───────────────────────── 4. venda instalada → fila; venda do indicado → prêmio ─────────────────────────
create or replace function public.vendas_pos_instalacao() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  cfg  jsonb := public._ind_cfg();
  i    public.indicacoes;
  ind  public.vendas;
  v_ch text := public._tel_chave(new.cliente_whatsapp);
  v_instalou boolean := new.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') and new.instalado_em is not null;
begin
  -- (a) instalou → entra na fila da mensagem (uma vez por venda)
  if v_instalou and (tg_op = 'INSERT' or old.status not in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') or old.instalado_em is null) then
    insert into public.pos_instalacao (venda_id, conversa_id, enviar_em)
    values (new.id, (select c.id from public.mari_conversas c where c.venda_id = new.id order by c.updated_at desc limit 1),
            now() + make_interval(mins => coalesce((cfg ->> 'espera_min')::int, 60)))
    on conflict (venda_id) do nothing;
  end if;

  -- (b) esta venda é de alguém indicado?
  select * into i from public.indicacoes x
   where x.estado in ('recebida', 'contatada', 'em_venda')
     and (x.venda_id = new.id or (x.venda_id is null and v_ch is not null and x.tel_chave = v_ch))
   order by (x.venda_id = new.id) desc nulls last, x.criado_em limit 1;
  if i.id is null or i.indicador_venda_id = new.id then return null; end if;

  select * into ind from public.vendas where id = i.indicador_venda_id;
  -- trava: não vale indicar a si mesmo (mesmo CPF/CNPJ ou mesmo endereço)
  if (regexp_replace(coalesce(new.cliente_cpf_cnpj, ''), '\D', '', 'g') <> ''
        and regexp_replace(coalesce(new.cliente_cpf_cnpj, ''), '\D', '', 'g') = regexp_replace(coalesce(ind.cliente_cpf_cnpj, ''), '\D', '', 'g'))
     or (regexp_replace(coalesce(new.cep, ''), '\D', '', 'g') <> '' and btrim(coalesce(new.numero, '')) <> ''
        and regexp_replace(coalesce(new.cep, ''), '\D', '', 'g') = regexp_replace(coalesce(ind.cep, ''), '\D', '', 'g')
        and lower(btrim(new.numero)) = lower(btrim(coalesce(ind.numero, '')))
        and lower(btrim(coalesce(new.complemento, ''))) = lower(btrim(coalesce(ind.complemento, '')))) then
    update public.indicacoes set estado = 'invalida', venda_id = new.id, motivo = 'mesmo CPF ou mesmo endereço de quem indicou',
           premio_status = case when premio_status = 'pago' then premio_status else 'nenhum' end
     where id = i.id;
    return null;
  end if;

  if v_instalou then
    update public.indicacoes
       set estado = 'instalada', venda_id = new.id, instalado_em = new.instalado_em,
           premio_status = 'previsto', premio_valor = coalesce((cfg ->> 'premio_valor')::numeric, 100),
           premio_vence_em = ((new.instalado_em at time zone 'America/Sao_Paulo')::date + coalesce((cfg ->> 'premio_dias')::int, 10))
     where id = i.id;
    insert into public.eventos_venda (venda_id, tipo, detalhe, parceiro_id)
    values (i.indicador_venda_id, 'indicacao_premio', jsonb_build_object('indicacao_id', i.id, 'venda_indicada', new.id,
            'valor', coalesce((cfg ->> 'premio_valor')::numeric, 100)), 'dharma');
  elsif new.status in ('1_vendido', '2_aguardando_instalacao') then
    update public.indicacoes set estado = 'em_venda', venda_id = new.id where id = i.id;
  end if;
  return null;
exception when others then
  insert into public.mari_erros (no_n8n, mensagem) values ('vendas_pos_instalacao', sqlerrm);
  return null;   -- nunca derruba a gravação da venda
end $$;
revoke all on function public.vendas_pos_instalacao() from public, anon, authenticated;
drop trigger if exists vendas_pos_instalacao on public.vendas;
create trigger vendas_pos_instalacao after insert or update of status, instalado_em, cliente_whatsapp on public.vendas
  for each row execute function public.vendas_pos_instalacao();

-- ───────────────────────── 5. a fala do cliente ─────────────────────────
create or replace function public.mari_turnos_pos_instalacao() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  cfg   jsonb;
  c     public.mari_conversas;
  p     public.pos_instalacao;
  i     public.indicacoes;
  t     text;
  tels  jsonb;
  e     jsonb;
  v_nome text;
  v_ok  int := 0;
  v_ja  int := 0;
  v_nomes text[] := '{}';
  v_reclama boolean;
  v_nega    boolean;
  v_sim     boolean;
  v_tratou  boolean := false;
  v_ddd text;
begin
  if new.papel <> 'lead' then return new; end if;
  select * into c from public.mari_conversas where id = new.conversa_id;
  if c.id is null then return new; end if;

  -- (0) o indicado respondeu por uma conversa diferente da que abrimos (telefone com/sem o 9): a indicação acompanha a conversa viva
  if coalesce(c.funil_destino, '') <> 'instalada' then
    select * into i from public.indicacoes x
     where x.tel_chave = public._tel_chave(c.telefone) and x.estado in ('recebida', 'contatada') and x.conversa_id is distinct from c.id
     limit 1;
    if i.id is not null then
      update public.indicacoes set conversa_id = c.id, estado = 'contatada', contatada_em = coalesce(contatada_em, now()) where id = i.id;
      update public.mari_conversas set origem = 'indicacao' where id = c.id and origem = 'direto';
      update public.mari_conversas m set status = 'encerrado_humano'
       where m.id = i.conversa_id and m.status in ('ativo', 'handoff_realizado')
         and not exists (select 1 from public.mari_turnos tt where tt.conversa_id = m.id and tt.papel = 'lead');
    end if;
    return new;
  end if;

  -- (1) cliente instalado respondendo ao pós-instalação
  select * into p from public.pos_instalacao x where x.conversa_id = c.id and x.estado in ('enviada', 'pediu')
   order by x.criado_em desc limit 1 for update;
  if p.id is null then return new; end if;
  cfg := public._ind_cfg();
  if not coalesce((cfg ->> 'ligado')::boolean, false) then return new; end if;

  t := public._ind_norm(new.texto);
  v_reclama := t ~ coalesce(cfg ->> 're_reclama',
    '(problema|ruim|pessim|horrivel|lent[ao]|caindo|caiu|cai toda|sem sinal|sem internet|nao funciona|nao esta funcionando|travando|oscila|reclam|cancel|demor|errad|insatisf|decep|arrepend|defeito|quebr|fatura|boleto|cobranca|procon|anatel|tecnico nao|nao veio|nao instal)');
  v_nega := t ~ coalesce(cfg ->> 're_nega', '(^| )(nao|nem|mais ou menos|pouco|nada)( |$)');
  v_sim := length(t) <= 80 and t ~ coalesce(cfg ->> 're_sim',
    '^(sim|s|ss|ok|blz|top|show|super|beleza|certinho|excelente)( |$)|^(tudo certo|deu tudo certo|deu certo|tudo otimo|tudo ok|tudo bem|tudo perfeito|tudo joia|tudo show|tudo certinho|otim[oa]|perfeit[oa]|maravilh|muito bo[am]|mto bo[am]|bom demais|gostei|adorei|amei|funcionando|esta otim|ta otim|satisfeit|foi sim|deu sim|com certeza)');
  c.ultima_msg_lead_at := now();   -- a mari_entrada só grava isto depois: a fala que chegou agora abre a janela de 24 h

  if p.estado = 'enviada' then
    if v_reclama or v_nega then
      update public.pos_instalacao set estado = 'insatisfeito', respondeu_em = now(), resposta = left(new.texto, 300), encerrada_em = now() where id = p.id;
      perform public._bo_mensagem(gen_random_uuid(), 1, 'pos_instalacao', p.venda_id, c, 'indicacao_problema', '{}'::jsonb);
      -- não marca "tratado": o pós-venda de sempre (etiqueta, nota e linha no Live) chama o time
    elsif v_sim then
      update public.pos_instalacao set estado = 'pediu', respondeu_em = now(), pediu_em = now(), resposta = left(new.texto, 300) where id = p.id;
      perform public._bo_mensagem(gen_random_uuid(), 1, 'indicacao_pedido', p.venda_id, c, 'indicacao_pedido', '{}'::jsonb);
      v_tratou := true;
    else
      update public.pos_instalacao set estado = 'com_time', respondeu_em = now(), resposta = left(new.texto, 300), encerrada_em = now() where id = p.id;
    end if;

  else   -- 'pediu': esperando o contato
    v_ddd := substr(public._tel_chave(c.telefone), 1, 2);
    tels := public._ind_telefones(new.texto, v_ddd);
    if jsonb_array_length(tels) > 0 then
      v_nome := case when jsonb_array_length(tels) = 1 then public._ind_nome(new.texto) end;
      for e in select * from jsonb_array_elements(tels) loop
        if (e ->> 'chave') = public._tel_chave(c.telefone)
           or exists (select 1 from public.indicacoes x where x.tel_chave = e ->> 'chave' and x.estado <> 'invalida')
           or exists (select 1 from public.vendas v where public._tel_chave(v.cliente_whatsapp) = e ->> 'chave') then
          v_ja := v_ja + 1;
          continue;
        end if;
        insert into public.indicacoes (pos_instalacao_id, indicador_venda_id, indicador_conversa_id, indicado_nome, indicado_telefone,
                                       tel_chave, texto_original, conversa_id, estado, contatada_em, motivo)
        select p.id, p.venda_id, c.id, v_nome, e ->> 'tel', e ->> 'chave', left(new.texto, 500), m.id,
               case when m.id is null then 'recebida' else 'contatada' end, case when m.id is null then null else now() end,
               case when m.id is null then null else 'já estava em atendimento com a Mari' end
          from (select 1) z
          left join lateral (select mc.id from public.mari_conversas mc
                              where public._tel_chave(mc.telefone) = e ->> 'chave' and mc.canal = 'whatsapp'
                                and mc.status in ('ativo', 'handoff_realizado') limit 1) m on true;
        v_ok := v_ok + 1;
        v_nomes := v_nomes || coalesce(public._ind_primeiro_nome(v_nome), 'a pessoa');
      end loop;
      if v_ok > 0 then
        perform public._bo_mensagem(gen_random_uuid(), 1, 'indicacao_obrigado', p.venda_id, c, 'indicacao_obrigado',
                                    jsonb_build_object('nome', case when v_ok = 1 then v_nomes[1] else 'cada uma dessas pessoas' end));
      else
        perform public._bo_mensagem(gen_random_uuid(), 1, 'indicacao_obrigado', p.venda_id, c, 'indicacao_ja', '{}'::jsonb);
      end if;
      update public.pos_instalacao set resposta = left(new.texto, 300) where id = p.id;
      v_tratou := true;
    elsif v_reclama or new.midia is not null then
      update public.pos_instalacao set estado = 'com_time', encerrada_em = now(), resposta = left(new.texto, 300) where id = p.id;
    elsif p.insistencias = 0 then
      update public.pos_instalacao set insistencias = 1, insistiu_em = now() where id = p.id;
      perform public._bo_mensagem(gen_random_uuid(), 1, 'indicacao_insistir', p.venda_id, c, 'indicacao_insistir', '{}'::jsonb);
      v_tratou := true;
    else
      update public.pos_instalacao set estado = 'encerrada', encerrada_em = now() where id = p.id;
      v_tratou := true;   -- já insistimos uma vez e o cliente não tem quem indicar: encerra sem chamar o time
    end if;
  end if;

  if v_tratou then
    update public.pos_instalacao set tratado_em = now() where id = p.id;
    update public.mari_conversas set dispensada_em = now() where id = c.id;   -- a linha "pós-venda" do Live não acende
  end if;
  return new;
exception when others then
  insert into public.mari_erros (conversa_id, no_n8n, mensagem) values (new.conversa_id, 'mari_turnos_pos_instalacao', sqlerrm);
  return new;   -- nunca derruba a gravação da fala do cliente
end $$;
revoke all on function public.mari_turnos_pos_instalacao() from public, anon, authenticated;
drop trigger if exists mari_turnos_pos_instalacao on public.mari_turnos;
create trigger mari_turnos_pos_instalacao after insert on public.mari_turnos
  for each row when (new.papel = 'lead') execute function public.mari_turnos_pos_instalacao();

-- O pós-venda de sempre (0155) não dispara quando a automação acabou de responder esta fala. Resto igual ao da 0155.
create or replace function public._mari_pos_venda(p_conversa uuid)
returns void language plpgsql security definer set search_path = public as $$
declare c public.mari_conversas;
begin
  if exists (select 1 from public.pos_instalacao x where x.conversa_id = p_conversa and x.tratado_em = now()) then return; end if;   -- 0176
  select * into c from public.mari_conversas where id = p_conversa;
  if not found or coalesce(c.canal, '') <> 'whatsapp' or coalesce(c.chatwoot_conversation_id, '') = '' or coalesce(c.telefone, '') like '5500000000%' then return; end if;
  if exists (select 1 from public.chatwoot_acoes a where a.conversa_id = c.id and a.momento = 'pos_venda' and a.criada_em > now() - interval '20 hours') then return; end if;
  perform public._bo_enfileirar(gen_random_uuid(), 1, 'pos_venda', c.venda_id, c, 'etiquetas', jsonb_build_object('add', jsonb_build_array('pos-venda')));
  perform public._bo_enfileirar(gen_random_uuid(), 2, 'pos_venda', c.venda_id, c, 'nota',
    jsonb_build_object('content', '🏠 Pós-venda: cliente já instalado escreveu. A Mari não responde cliente instalado — responda pelo NIOGEN (Live › Conferir).'));
exception when others then
  insert into public.mari_erros (conversa_id, no_n8n, mensagem) values (p_conversa, '_mari_pos_venda', sqlerrm);
end;
$$;
revoke all on function public._mari_pos_venda(uuid) from public, anon, authenticated;
grant execute on function public._mari_pos_venda(uuid) to service_role;

-- ───────────────────────── 6. a rotina (n8n indicacao_rotina, a cada 10 min) ─────────────────────────
-- Faz o que depende de hora e devolve as conversas a ABRIR no Chatwoot (indicados que nunca falaram com a gente).
create or replace function public.indicacao_tick(p_agora timestamptz default now())
returns setof jsonb language plpgsql security definer set search_path = public as $$
declare
  cfg   jsonb := public._ind_cfg();
  p     public.pos_instalacao;
  i     public.indicacoes;
  c     public.mari_conversas;
  v     public.vendas;
  ind   public.vendas;
  v_id  bigint;
  conta text := public._bo_cfg('chatwoot_conta', '195428') #>> '{}';
begin
  if not coalesce((cfg ->> 'ligado')::boolean, false) then return; end if;

  -- validade
  update public.pos_instalacao set estado = 'sem_resposta', encerrada_em = p_agora
   where estado = 'enviada' and enviada_em < p_agora - make_interval(days => coalesce((cfg ->> 'validade_resposta_dias')::int, 7));
  update public.pos_instalacao set estado = 'encerrada', encerrada_em = p_agora
   where estado = 'pediu' and pediu_em < p_agora - make_interval(hours => coalesce((cfg ->> 'validade_pedido_horas')::int, 48));

  -- (1) mensagem de pós-instalação
  for p in select * from public.pos_instalacao where estado = 'agendada' and enviar_em <= p_agora order by enviar_em limit 20 for update skip locked loop
    select * into v from public.vendas where id = p.venda_id;
    if v.status not in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme')
       or v.instalado_em < p_agora - make_interval(days => coalesce((cfg ->> 'janela_instalacao_dias')::int, 3)) then
      update public.pos_instalacao set estado = 'expirada', encerrada_em = p_agora where id = p.id;
      continue;
    end if;
    select * into c from public.mari_conversas
     where id = coalesce(p.conversa_id, (select m.id from public.mari_conversas m where m.venda_id = v.id order by m.updated_at desc limit 1));
    if c.id is null or coalesce(c.canal, '') <> 'whatsapp' or coalesce(c.chatwoot_conversation_id, '') = '' then
      update public.pos_instalacao set estado = 'sem_conversa', encerrada_em = p_agora where id = p.id;
      continue;
    end if;
    if coalesce(c.nao_contatar, false) then
      update public.pos_instalacao set estado = 'encerrada', encerrada_em = p_agora, resposta = 'cliente pediu para não ser contatado' where id = p.id;
      continue;
    end if;
    if not public.mari_no_horario(p_agora, coalesce(v.cidade, c.cidade)) then continue; end if;
    v_id := public._ind_template(c, v.id, 'pos_instalacao', 'nio_pos_instalacao',
                                 jsonb_build_array(coalesce(public._ind_primeiro_nome(coalesce(v.cliente_nome, c.nome_contato)), 'tudo bem')));
    if v_id is null then continue; end if;   -- template ainda não aprovado: tenta na próxima volta
    update public.pos_instalacao set estado = 'enviada', enviada_em = p_agora, conversa_id = c.id where id = p.id;
  end loop;

  -- (2) insistir uma vez com quem recebeu o pedido e ficou em silêncio (só com a janela de 24 h aberta)
  for p in select * from public.pos_instalacao
            where estado = 'pediu' and insistencias = 0
              and pediu_em <= p_agora - make_interval(mins => coalesce((cfg ->> 'insistir_apos_min')::int, 120))
            limit 20 for update skip locked loop
    select * into c from public.mari_conversas where id = p.conversa_id;
    if c.id is null or coalesce(c.nao_contatar, false) or c.ultima_msg_lead_at is null
       or p_agora >= c.ultima_msg_lead_at + interval '23 hours' then
      update public.pos_instalacao set insistencias = 1 where id = p.id;   -- janela fechou: não insiste por template
      continue;
    end if;
    if not public.mari_no_horario(p_agora, c.cidade) then continue; end if;
    perform public._bo_mensagem(gen_random_uuid(), 1, 'indicacao_insistir', p.venda_id, c, 'indicacao_insistir', '{}'::jsonb);
    update public.pos_instalacao set insistencias = 1, insistiu_em = p_agora where id = p.id;
  end loop;

  -- (3) prêmio previsto e sem chave Pix: pede a chave a quem indicou (template)
  for i in select * from public.indicacoes where premio_status = 'previsto' and pix_chave is null and pix_pedido_em is null
            limit 20 for update skip locked loop
    select * into c from public.mari_conversas where id = i.indicador_conversa_id;
    select * into ind from public.vendas where id = i.indicador_venda_id;
    if c.id is null or not public.mari_no_horario(p_agora, coalesce(ind.cidade, c.cidade)) then continue; end if;
    v_id := public._ind_template(c, i.indicador_venda_id, 'indicacao_premio', 'nio_indicacao_premio',
              jsonb_build_array(coalesce(public._ind_primeiro_nome(coalesce(ind.cliente_nome, c.nome_contato)), 'tudo bem'),
                                coalesce(public._ind_primeiro_nome(coalesce(i.indicado_nome,
                                  (select vv.cliente_nome from public.vendas vv where vv.id = i.venda_id))), 'Quem você indicou')));
    if v_id is null then continue; end if;
    update public.indicacoes set pix_pedido_em = p_agora where id = i.id;
  end loop;

  -- (4) indicados a abrir no Chatwoot (a rotina cria contato + conversa e chama indicacao_abertura_resultado)
  if not coalesce((cfg ->> 'abrir_conversa')::boolean, false)
     or not exists (select 1 from public.config_templates_waba where nome = 'nio_indicacao_contato' and status = 'APPROVED') then
    return;
  end if;
  for i in select * from public.indicacoes x
            where x.estado = 'recebida' and x.tentativas < 3
              and (x.tentativa_em is null or x.tentativa_em < p_agora - interval '30 minutes')
            order by x.criado_em limit 10 for update skip locked loop
    select * into ind from public.vendas where id = i.indicador_venda_id;
    if not public.mari_no_horario(p_agora, ind.cidade) then continue; end if;
    update public.indicacoes set tentativas = tentativas + 1, tentativa_em = p_agora where id = i.id;
    return next jsonb_build_object(
      'id', i.id,
      'nome', coalesce(i.indicado_nome, 'Indicação de ' || coalesce(public._ind_primeiro_nome(ind.cliente_nome), 'cliente')),
      'telefone', '+' || i.indicado_telefone,
      'inbox_id', coalesce((cfg ->> 'inbox_id')::int, 153431),
      'base', 'https://app.chatwoot.com/api/v1/accounts/' || conta);
  end loop;
  return;
end $$;
revoke all on function public.indicacao_tick(timestamptz) from public, anon, authenticated;
grant execute on function public.indicacao_tick(timestamptz) to service_role;

-- A rotina abriu (ou não) a conversa do indicado no Chatwoot.
create or replace function public.indicacao_abertura_resultado(p_id uuid, p_ok boolean, p_chatwoot_conversation_id text default null, p_erro text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  i    public.indicacoes;
  c    public.mari_conversas;
  ind  public.vendas;
  v_cw text := nullif(btrim(coalesce(p_chatwoot_conversation_id, '')), '');
  v_tel text;
  v_id bigint;
begin
  select * into i from public.indicacoes where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'erro', 'indicação inexistente'); end if;
  if i.estado <> 'recebida' then return jsonb_build_object('ok', true, 'registrado', 'já tratada'); end if;
  if not coalesce(p_ok, false) or v_cw is null then
    update public.indicacoes set motivo = left(coalesce(p_erro, 'sem detalhe'), 300),
           estado = case when tentativas >= 3 then 'erro' else estado end where id = p_id;
    if i.tentativas >= 3 then
      insert into public.mari_erros (no_n8n, mensagem, payload)
      values ('indicacao_rotina', 'não abri a conversa do indicado (3×): ' || left(coalesce(p_erro, ''), 300), jsonb_build_object('indicacao_id', p_id));
    end if;
    return jsonb_build_object('ok', true, 'registrado', 'erro');
  end if;

  select * into ind from public.vendas where id = i.indicador_venda_id;
  v_tel := public._tel_wa(i.indicado_telefone);
  select * into c from public.mari_conversas m
   where m.canal = 'whatsapp' and m.status in ('ativo', 'handoff_realizado')
     and (m.chatwoot_conversation_id = v_cw or public._tel_chave(m.telefone) = i.tel_chave)
   order by (m.chatwoot_conversation_id = v_cw) desc limit 1;
  if c.id is null then
    insert into public.mari_conversas (telefone, nome_contato, canal, origem, chatwoot_conversation_id, cadencia_passo, cadencia_passo_em)
    values (v_tel, i.indicado_nome, 'whatsapp', 'indicacao', v_cw, 'P1', now())
    returning * into c;
    insert into public.mari_turnos (conversa_id, papel, texto, pendente)
    values (c.id, 'sistema', '[lead indicado por ' || coalesce(nullif(btrim(ind.cliente_nome), ''), 'um cliente') ||
            ' (cliente já instalado) — a Mari fez o primeiro contato por template citando quem indicou]', false);
    v_id := public._ind_template(c, null, 'indicacao', 'nio_indicacao_contato',
              jsonb_build_array(coalesce(public._ind_primeiro_nome(i.indicado_nome), 'tudo bem'),
                                coalesce(public._ind_primeiro_nome(ind.cliente_nome), 'Um cliente nosso')));
    -- conta como o P1 da cadência: ela segue com D7 e D15 sozinha, sem repetir o primeiro contato
    insert into public.contatos_cliente (conversa_id, telefone, canal, direcao, por, em, toque, tipo, resumo)
    values (c.id, c.telefone, 'whatsapp', 'saida', 'mari', now(), 'P1', 'ativo', 'Indicação · primeiro contato (template nio_indicacao_contato)');
  end if;
  update public.indicacoes set estado = 'contatada', conversa_id = c.id, contatada_em = now(), motivo = null where id = p_id;
  return jsonb_build_object('ok', true, 'registrado', 'contatada', 'conversa_id', c.id, 'acao_id', v_id);
end $$;
revoke all on function public.indicacao_abertura_resultado(uuid, boolean, text, text) from public, anon, authenticated;
grant execute on function public.indicacao_abertura_resultado(uuid, boolean, text, text) to service_role;

-- ───────────────────────── 7. o que a tela usa ─────────────────────────
create or replace function public.indicacao_gravar_pix(p_id uuid, p_chave text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then raise exception 'Só admin e backoffice.' using errcode = '42501'; end if;
  if coalesce(btrim(p_chave), '') = '' then raise exception 'Informe a chave Pix.' using errcode = '22023'; end if;
  update public.indicacoes set pix_chave = btrim(p_chave), pix_gravada_em = now(), pix_gravada_por = auth.uid()
   where id = p_id and premio_status <> 'pago';
  if not found then raise exception 'Indicação inexistente ou já paga.' using errcode = '22023'; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.indicacao_pagar(p_id uuid, p_comprovante text default null, p_obs text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i public.indicacoes;
begin
  if coalesce(public.meu_perfil(), '') <> 'admin' then raise exception 'Só o admin marca o Pix como pago.' using errcode = '42501'; end if;
  select * into i from public.indicacoes where id = p_id for update;
  if not found or i.premio_status <> 'previsto' then raise exception 'Não há prêmio previsto nesta indicação.' using errcode = '22023'; end if;
  if coalesce(i.pix_chave, '') = '' then raise exception 'Grave a chave Pix antes de marcar como pago.' using errcode = '22023'; end if;
  update public.indicacoes set premio_status = 'pago', pago_em = now(), pago_por = auth.uid(),
         comprovante_path = nullif(btrim(coalesce(p_comprovante, '')), ''), obs = coalesce(nullif(btrim(coalesce(p_obs, '')), ''), obs)
   where id = p_id;
  insert into public.eventos_venda (venda_id, tipo, detalhe, parceiro_id)
  values (i.indicador_venda_id, 'indicacao_pix_pago', jsonb_build_object('indicacao_id', i.id, 'valor', i.premio_valor), 'dharma');
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.indicacao_cancelar_premio(p_id uuid, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if coalesce(public.meu_perfil(), '') <> 'admin' then raise exception 'Só o admin cancela um prêmio.' using errcode = '42501'; end if;
  if coalesce(btrim(p_motivo), '') = '' then raise exception 'Diga o motivo.' using errcode = '22023'; end if;
  update public.indicacoes set premio_status = 'cancelado', obs = btrim(p_motivo) where id = p_id and premio_status = 'previsto';
  if not found then raise exception 'Não há prêmio previsto nesta indicação.' using errcode = '22023'; end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.indicacao_gravar_pix(uuid, text), public.indicacao_pagar(uuid, text, text), public.indicacao_cancelar_premio(uuid, text) from public, anon;
grant execute on function public.indicacao_gravar_pix(uuid, text), public.indicacao_pagar(uuid, text, text), public.indicacao_cancelar_premio(uuid, text) to authenticated;

create or replace view public.v_indicacoes with (security_invoker = true) as
select i.id, i.parceiro_id, i.criado_em, i.estado, i.motivo,
       i.indicador_venda_id, vi.cliente_nome as indicador_nome, vi.cliente_whatsapp as indicador_whatsapp, i.indicador_conversa_id,
       i.indicado_nome, i.indicado_telefone, i.conversa_id, i.venda_id,
       vd.cliente_nome as indicado_cliente_nome, vd.status as indicado_venda_status, vd.comissao_prevista as indicado_comissao,
       i.contatada_em, i.instalado_em,
       (coalesce(vd.nio_situacao = 'Concluído', false)
         or exists (select 1 from public.eventos_venda e where e.venda_id = i.venda_id and e.tipo = 'os_instalada')) as confirmada_nio,
       coalesce(vd.status = 'saida' or vd.cancelada_apos_instalar_em is not null, false) as indicado_saiu,
       i.premio_status, i.premio_valor, i.premio_vence_em, i.pix_chave, i.pix_pedido_em, i.pago_em, i.comprovante_path, i.obs,
       case
         when i.premio_status = 'pago' then 'pago'
         when i.premio_status = 'cancelado' then 'cancelado'
         when i.estado = 'invalida' then 'invalida'
         when i.premio_status = 'previsto' and (vd.status = 'saida' or vd.cancelada_apos_instalar_em is not null) then 'indicado_saiu'
         when i.premio_status = 'previsto'
              and not (coalesce(vd.nio_situacao = 'Concluído', false)
                       or exists (select 1 from public.eventos_venda e where e.venda_id = i.venda_id and e.tipo = 'os_instalada')) then 'aguarda_nio'
         when i.premio_status = 'previsto' and i.premio_vence_em > (now() at time zone 'America/Sao_Paulo')::date then 'aguarda_prazo'
         when i.premio_status = 'previsto' and coalesce(i.pix_chave, '') = '' then 'falta_pix'
         when i.premio_status = 'previsto' then 'a_pagar'
         when i.estado = 'em_venda' then 'em_venda'
         when i.estado = 'contatada' then 'contatada'
         when i.estado = 'erro' then 'erro'
         else 'recebida'
       end as situacao
  from public.indicacoes i
  join public.vendas vi on vi.id = i.indicador_venda_id
  left join public.vendas vd on vd.id = i.venda_id;

-- Medida (regra 18): total e últimos 7 dias, numa linha.
create or replace view public.v_indicacao_resumo with (security_invoker = true) as
select
  (select count(*) from public.pos_instalacao where enviada_em is not null)                                             as enviadas,
  (select count(*) from public.pos_instalacao where enviada_em > now() - interval '7 days')                             as enviadas_7d,
  (select count(*) from public.pos_instalacao where pediu_em is not null)                                               as satisfeitos,
  (select count(*) from public.pos_instalacao where estado = 'insatisfeito')                                            as problemas,
  (select count(*) from public.pos_instalacao where estado = 'com_time')                                                as com_time,
  (select count(*) from public.pos_instalacao where pediu_em is not null)                                               as pedidas,
  (select count(*) from public.pos_instalacao where pediu_em > now() - interval '7 days')                               as pedidas_7d,
  (select count(*) from public.indicacoes where estado <> 'invalida')                                                   as recebidas,
  (select count(*) from public.indicacoes where estado <> 'invalida' and criado_em > now() - interval '7 days')         as recebidas_7d,
  (select count(*) from public.indicacoes where venda_id is not null and estado <> 'invalida')                          as viraram_venda,
  (select count(*) from public.indicacoes where estado = 'instalada')                                                   as instaladas,
  (select coalesce(sum(v.comissao_prevista), 0) from public.indicacoes i join public.vendas v on v.id = i.venda_id
    where i.estado = 'instalada')                                                                                       as comissao_gerada,
  (select coalesce(sum(premio_valor), 0) from public.indicacoes where premio_status = 'previsto')                       as pix_devido,
  (select coalesce(sum(premio_valor), 0) from public.indicacoes where premio_status = 'pago')                           as pix_pago;

revoke all on public.v_indicacoes, public.v_indicacao_resumo from anon, authenticated;
grant select on public.v_indicacoes, public.v_indicacao_resumo to authenticated, service_role;

-- NIOGEN | supabase/migrations/0427_indicacao_reconhecida_e_registrada.sql | 26/11/2026 — Claude Code (Fable 5.2)
-- Ricardo, 26/11 ~22h50: "Hoje recebemos a primeira indicação vinda de um cliente que comprou. A lead L-156 indicou a L-397.
-- (…) a Mari não soube reconhecer que poderia vir da 156 uma indicação e nem sobre como proceder. E precisamos também criar um
-- controle dessas indicações, para efetuar o pagamento."
-- O que aconteceu (lido nas duas conversas):
--   · L-156 respondeu ao pedido da varredura só com o NOME da indicada, sem WhatsApp. A regra só via indicação com telefone na
--     fala: o pedido foi encerrado calado e nada ficou gravado.
--   · L-397 chegou sozinha dizendo "a minha prima me passou seu contato". A conversa ficou com origem "desconhecida" e sem
--     vínculo com quem indicou.
--   · O controle do Pix já existia (0176: tabela indicacoes, Pagamentos › Indicações), mas com 0 linhas — só entrava por
--     "nome + WhatsApp".
-- O que muda:
--   1. indicacao_pistas: o que se sabe de uma indicação antes de ela existir — o nome que o indicador deu sem telefone
--      ('nome_do_indicado') e o lead que disse ter sido indicado ('disse_indicado').
--   2. Nome sem telefone (pós-instalação e varredura): a Mari responde pedindo o WhatsApp ou que a pessoa chame e diga quem
--      indicou (texto indicacao_pedir_whats) e guarda o nome. O pedido continua aberto para o telefone que vier depois.
--   3. Lead novo que diz "fulano me indicou / me passou seu contato": origem vira Indicação e o banco procura quem indicou
--      (nome guardado no item 2 que bate com o nome do lead; ou nome citado que bate com UM cliente instalado). Achou um só →
--      vincula sozinho. Não achou → fica a pista aberta, que a conferência diária cobra.
--   4. indicacao_registrar(conversa do indicado, quem indicou, confirmar): o time registra ou corrige à mão pela ficha
--      (admin/backoffice). Sem confirmar, só devolve o que vai acontecer (regra de ouro 3).
--   5. Conferência: item "Indicação: lead que disse ter sido indicado sem quem indicou".
-- Regras de ouro: nenhuma situação de lead muda aqui (só mari_conversas.origem e a tabela indicacoes, escrita só por função);
-- o prêmio continua nascendo do gatilho vendas_pos_instalacao (instalou → previsto, 10 dias) e pago à mão pelo Ricardo.
-- Subida sem portão por ordem do Ricardo (26/11 ~23h20: "Suba o que precisa subir, sem rodar o portão… depois rodarei um
-- portão para validar todas as migrations"). Cenário X150 escrito, não rodado.

begin;

-- ───────────────────────── 1. tabela ─────────────────────────
create table if not exists public.indicacao_pistas (
  id                uuid primary key default gen_random_uuid(),
  parceiro_id       text not null default 'dharma',
  tipo              text not null check (tipo in ('nome_do_indicado', 'disse_indicado')),
  conversa_id       uuid not null references public.mari_conversas (id) on delete cascade,   -- de quem falou
  venda_id          uuid references public.vendas (id) on delete set null,
  pedido_id         uuid,
  pos_instalacao_id uuid,
  nome              text,          -- nome_do_indicado: o nome que o indicador deu
  nome_chave        text,          -- 1º nome, sem acento e com grafia dobrada (Keroly = Queroly)
  texto             text,
  estado            text not null default 'aberta' check (estado in ('aberta', 'vinculada', 'descartada')),
  indicacao_id      uuid references public.indicacoes (id) on delete set null,
  criado_em         timestamptz not null default now(),
  resolvida_em      timestamptz
);
create index if not exists indicacao_pistas_conversa_idx on public.indicacao_pistas (conversa_id, tipo) where estado = 'aberta';
create index if not exists indicacao_pistas_nome_idx on public.indicacao_pistas (nome_chave) where estado = 'aberta' and tipo = 'nome_do_indicado';
comment on table public.indicacao_pistas is
  'Pistas de indicação (0427): o nome que o indicador deu sem telefone e o lead que disse ter sido indicado. Viram linha em '
  'indicacoes quando casam (sozinhas ou pelo botão "indicado por" da ficha). Escrita só pelas funções _ind_*.';
alter table public.indicacao_pistas enable row level security;
drop policy if exists indicacao_pistas_ler on public.indicacao_pistas;
create policy indicacao_pistas_ler on public.indicacao_pistas for select to authenticated
  using ((select coalesce(public.meu_perfil(), '')) in ('admin', 'backoffice'));
revoke all on public.indicacao_pistas from anon, authenticated;
grant select on public.indicacao_pistas to authenticated;
grant all on public.indicacao_pistas to service_role;

insert into public.config_mari_textos (chave, texto)
values ('indicacao_pedir_whats',
        'Anotei aqui: {nome} 😊 Agora me manda o WhatsApp dessa pessoa por aqui. Se preferir, pede pra ela me chamar neste número e dizer que foi você quem indicou — assim a indicação fica no seu nome.')
on conflict (chave) do nothing;

-- ───────────────────────── 2. miúdos ─────────────────────────
-- 1º nome com a grafia dobrada: Keroly = Queroly = Kerolly; Rayra = Raira.
create or replace function public._ind_nome_chave(p text) returns text language sql immutable as $$
  select nullif(regexp_replace(regexp_replace(regexp_replace(
           replace(replace(replace(replace(replace(split_part(public._ind_norm(p), ' ', 1), 'qu', 'k'), 'ph', 'f'), 'y', 'i'), 'w', 'v'), 'h', ''),
           'c([aou])', 'k\1', 'g'), '(.)\1', '\1', 'g'), '[^a-z]', '', 'g'), '')
$$;

-- A fala é só um nome de pessoa? ("Rayra Piranha" sim; "Blz", "vou ver", "não conheço ninguém" não.)
create or replace function public._ind_so_nome(p_texto text) returns text language plpgsql immutable as $$
declare t text := public._ind_norm(p_texto); n text;
begin
  if p_texto is null or length(btrim(p_texto)) > 40 or p_texto ~ '[\d?@]' then return null; end if;
  if t = '' or array_length(regexp_split_to_array(t, ' '), 1) > 4 then return null; end if;
  if t ~ ('(^| )(sim|ss|ok|okay|blz|blza|beleza|top|show|certo|certinho|ta|tabom|bom|boa|valeu|vlw|obrigad[oa]|brigad[oa]|nao|ninguem|nenhum|nenhuma|nada'
       || '|depois|agora|vou|vamos|ver|pensar|talvez|pode|claro|kk+|rs+|ha(ha)+|oi|ola|tudo|momento|ainda|joia|perfeito|otimo|otima|combinado|entendi'
       || '|legal|bacana|massa|tranquilo|fechado|deixa|comigo|conheco|lembro|lembrar|aviso|avisar|falo|falar|passo|passar|mando|mandar|envio'
       || '|qualquer|coisa|sei|acho|quando|tiver|tenho|hoje|amanha|ja|aguarda|aguarde|espera|pera|calma|certeza|deus|amem|gratidao|opa|eai|fala'
       || '|bem|mal|mais|menos|muito|pouco|aqui|ai|la|isso|esse|essa|ele|ela|eu|voce|vc|tu|nos|me|te|se|que|como|onde|qual|quem|por|para|pra'
       || '|com|sem|mas|e|ou|um|uma|o|a|os|as|no|na|internet|nio|fibra|wifi|pix|dinheiro|reais|verdade|serio|lado|frente|casa|rua|trabalho'
       || '|servico|igreja|familia|pessoal|gente|todo|todos|mundo|alguem|alguns|varios|amigos|amigas|vizinhos|parentes|colegas|dia|tarde|noite)( |$)') then
    return null;
  end if;
  n := public._ind_nome(p_texto);
  if n is null or length(split_part(n, ' ', 1)) < 3 then return null; end if;
  return n;
end $$;

-- ───────────────────────── 3. o vínculo (uma porta só para a máquina e para o botão) ─────────────────────────
create or replace function public._ind_vincular(p_indicador uuid, p_indicado uuid, p_como text, p_texto text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  ci public.mari_conversas; cd public.mari_conversas; i public.indicacoes; v public.vendas; vi public.vendas;
  cfg jsonb := public._ind_cfg();
  v_ch text; v_tel text; v_nome text; v_novo boolean := false;
begin
  select * into ci from public.mari_conversas where id = p_indicador;
  select * into cd from public.mari_conversas where id = p_indicado;
  if ci.id is null or cd.id is null then raise exception 'Conversa não encontrada.' using errcode = '22023'; end if;
  v_ch := public._tel_chave(cd.telefone);
  v_tel := regexp_replace(coalesce(cd.telefone, ''), '\D', '', 'g');
  if v_tel !~ '^\d{12,13}$' then v_tel := public._tel_wa(cd.telefone); end if;
  if v_ch is null or v_tel is null then raise exception 'O indicado não tem WhatsApp válido na conversa.' using errcode = '22023'; end if;
  if ci.id = cd.id or public._tel_chave(ci.telefone) = v_ch then
    raise exception 'Não vale indicar a si mesmo.' using errcode = '22023';
  end if;
  select * into vi from public.vendas where id = ci.venda_id;
  select * into v from public.vendas where id = cd.venda_id;
  if v.id is not null and vi.id is not null
     and regexp_replace(coalesce(v.cliente_cpf_cnpj, ''), '\D', '', 'g') <> ''
     and regexp_replace(coalesce(v.cliente_cpf_cnpj, ''), '\D', '', 'g') = regexp_replace(coalesce(vi.cliente_cpf_cnpj, ''), '\D', '', 'g') then
    raise exception 'Mesmo CPF de quem indicou: não vale indicar a si mesmo.' using errcode = '22023';
  end if;
  v_nome := coalesce(nullif(btrim(coalesce(v.cliente_nome, '')), ''), nullif(btrim(coalesce(cd.dados ->> 'nome', '')), ''));

  select * into i from public.indicacoes x where x.tel_chave = v_ch and x.estado <> 'invalida' limit 1 for update;
  if i.id is not null then
    if i.indicador_conversa_id = ci.id then
      update public.indicacoes set conversa_id = cd.id, venda_id = coalesce(venda_id, v.id) where id = i.id;
      return jsonb_build_object('ok', true, 'ja', true, 'indicacao_id', i.id);
    end if;
    if i.premio_status in ('previsto', 'pago') then
      raise exception 'Este indicado já tem prêmio % para outra pessoa. Cancele o prêmio em Pagamentos › Indicações antes de trocar.', i.premio_status
        using errcode = '22023';
    end if;
    update public.indicacoes
       set indicador_conversa_id = ci.id, indicador_venda_id = ci.venda_id, conversa_id = cd.id, venda_id = coalesce(venda_id, v.id),
           indicado_nome = coalesce(indicado_nome, v_nome), motivo = left(p_como, 200),
           estado = case when estado in ('recebida', 'erro') then 'contatada' else estado end, contatada_em = coalesce(contatada_em, now())
     where id = i.id
    returning * into i;
  else
    insert into public.indicacoes (indicador_venda_id, indicador_conversa_id, indicado_nome, indicado_telefone, tel_chave, texto_original,
                                   conversa_id, venda_id, estado, contatada_em, motivo)
    values (ci.venda_id, ci.id, v_nome, v_tel, v_ch, left(p_texto, 500), cd.id, v.id, 'contatada', now(), left(p_como, 200))
    returning * into i;
    v_novo := true;
  end if;

  -- a venda do indicado já andou: põe a indicação no ponto certo (o mesmo que o gatilho vendas_pos_instalacao faz daqui em diante)
  if v.id is not null and v.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') and v.instalado_em is not null then
    update public.indicacoes
       set estado = 'instalada', venda_id = v.id, instalado_em = v.instalado_em, premio_status = 'previsto',
           premio_valor = coalesce((cfg ->> 'premio_valor')::numeric, 100),
           premio_vence_em = ((v.instalado_em at time zone 'America/Sao_Paulo')::date + coalesce((cfg ->> 'premio_dias')::int, 10))
     where id = i.id and premio_status = 'nenhum';
    if found then
      insert into public.eventos_venda (venda_id, tipo, detalhe, parceiro_id)
      values (coalesce(ci.venda_id, v.id), 'indicacao_premio', jsonb_build_object('indicacao_id', i.id, 'venda_indicada', v.id,
              'valor', coalesce((cfg ->> 'premio_valor')::numeric, 100)), 'dharma');
    end if;
  elsif v.id is not null and v.status in ('1_vendido', '2_aguardando_instalacao') then
    update public.indicacoes set estado = 'em_venda', venda_id = v.id where id = i.id and estado in ('recebida', 'contatada');
  end if;

  update public.mari_conversas set origem = 'indicacao' where id = cd.id and coalesce(origem, 'desconhecida') in ('direto', 'desconhecida');
  update public.indicacao_pistas set estado = 'vinculada', indicacao_id = i.id, resolvida_em = now()
   where estado = 'aberta'
     and ((conversa_id = cd.id and tipo = 'disse_indicado')
       or (conversa_id = ci.id and tipo = 'nome_do_indicado' and nome_chave is not null
           and nome_chave in (public._ind_nome_chave(v_nome), public._ind_nome_chave(cd.nome_contato))));
  insert into public.mari_turnos (conversa_id, papel, texto, pendente)
  values (cd.id, 'sistema', '[indicação: este lead foi indicado por L-' || ci.lead_numero || ' — ' || p_como || ']', false),
         (ci.id, 'sistema', '[indicação: este cliente indicou L-' || cd.lead_numero || ' — ' || p_como
                 || '. Se o indicado instalar, entra o Pix em Pagamentos › Indicações]', false);
  return jsonb_build_object('ok', true, 'novo', v_novo, 'indicacao_id', i.id);
end $$;
revoke all on function public._ind_vincular(uuid, uuid, text, text) from public, anon, authenticated;

-- Quem indicou este lead? Devolve a conversa do indicador só quando há UM candidato.
create or replace function public._ind_casar(cd public.mari_conversas) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  ks text[]; ps public.indicacao_pistas; v_ids uuid[]; toks text[];
begin
  ks := array_remove(array[public._ind_nome_chave(cd.dados ->> 'nome'), public._ind_nome_chave(cd.nome_contato)], null);
  -- A. um indicador deu este nome (sem telefone) nos últimos 7 dias
  if array_length(ks, 1) > 0 then
    select array_agg(distinct x.conversa_id) into v_ids from public.indicacao_pistas x
     where x.tipo = 'nome_do_indicado' and x.estado = 'aberta' and x.criado_em > now() - interval '7 days'
       and x.nome_chave = any (ks) and x.conversa_id <> cd.id;
    if array_length(v_ids, 1) = 1 then return v_ids[1]; end if;
    if array_length(v_ids, 1) > 1 then return null; end if;   -- dois indicadores deram o mesmo nome: o time decide
  end if;
  -- B. o lead citou o nome de quem indicou e ele bate com UM cliente instalado (primeiro os que receberam pedido há pouco)
  select * into ps from public.indicacao_pistas x where x.conversa_id = cd.id and x.tipo = 'disse_indicado' and x.estado = 'aberta'
   order by x.criado_em desc limit 1;
  if ps.id is null then return null; end if;
  select array_agg(distinct public._ind_nome_chave(w)) into toks
    from regexp_split_to_table(public._ind_norm(ps.texto), ' ') w where length(w) >= 4;
  if toks is null then return null; end if;
  select array_agg(distinct m.id) into v_ids
    from public.vendas vv join public.mari_conversas m on m.venda_id = vv.id
   where vv.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') and m.id <> cd.id
     and public._ind_nome_chave(vv.cliente_nome) = any (toks)
     and (exists (select 1 from public.indicacao_pedidos p where p.conversa_id = m.id and p.pedido_em > now() - interval '7 days')
       or exists (select 1 from public.pos_instalacao p where p.conversa_id = m.id and coalesce(p.pediu_em, p.enviada_em) > now() - interval '7 days')
       or exists (select 1 from public.indicacao_pistas p where p.conversa_id = m.id and p.criado_em > now() - interval '7 days'));
  if array_length(v_ids, 1) = 1 then return v_ids[1]; end if;
  if array_length(v_ids, 1) > 1 then return null; end if;
  select array_agg(distinct m.id) into v_ids
    from public.vendas vv join public.mari_conversas m on m.venda_id = vv.id
   where vv.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme') and m.id <> cd.id
     and public._ind_nome_chave(vv.cliente_nome) = any (toks);
  if array_length(v_ids, 1) = 1 then return v_ids[1]; end if;
  return null;
end $$;
revoke all on function public._ind_casar(public.mari_conversas) from public, anon, authenticated;

-- Fala de um lead que ainda não instalou: ele disse que foi indicado? Guarda a pista e tenta achar quem indicou.
create or replace function public._ind_indicado_fala(c public.mari_conversas, t public.mari_turnos) returns void
language plpgsql security definer set search_path = public as $$
declare ps public.indicacao_pistas; v_ind uuid; v_t text;
begin
  if not coalesce((public._ind_cfg() ->> 'ligado')::boolean, false) or coalesce(c.canal, '') <> 'whatsapp' then return; end if;
  if exists (select 1 from public.indicacoes x
              where (x.conversa_id = c.id or x.tel_chave = public._tel_chave(c.telefone)) and x.estado <> 'invalida') then return; end if;
  select * into ps from public.indicacao_pistas x where x.conversa_id = c.id and x.tipo = 'disse_indicado' and x.estado = 'aberta'
   order by x.criado_em desc limit 1;
  if ps.id is null then
    v_t := public._ind_norm(t.texto);
    if v_t !~ ('(me indicou|me indicaram|indicou (voce|vc|vcs|voces|a nio|o seu|seu)|indicacao d[aeo] |por indicacao|fui indicad|foi indicad'
            || '|passou (o )?(seu|teu|esse|este) (contato|numero|whats|whatsapp|zap|telefone)|me passou o (contato|numero|whats|whatsapp|zap)'
            || '|me recomendou|recomendou (voce|vc|vcs|voces|a nio)|me falou (de voce|de vc|de vcs|de voces|da nio)'
            || '|peguei (o )?(seu|teu) (contato|numero)|me mandou (o )?(seu|teu) (contato|numero))') then
      return;
    end if;
    insert into public.indicacao_pistas (tipo, conversa_id, venda_id, texto) values ('disse_indicado', c.id, c.venda_id, left(t.texto, 500))
    returning * into ps;
    update public.mari_conversas set origem = 'indicacao' where id = c.id and coalesce(origem, 'desconhecida') in ('direto', 'desconhecida');
  elsif ps.criado_em < now() - interval '7 days' then
    return;   -- pista velha: só o time resolve (conferência)
  end if;
  c.dados := (select m.dados from public.mari_conversas m where m.id = c.id);
  v_ind := public._ind_casar(c);
  if v_ind is not null then
    perform public._ind_vincular(v_ind, c.id, 'reconhecida sozinha pela conversa', ps.texto);
  end if;
end $$;
revoke all on function public._ind_indicado_fala(public.mari_conversas, public.mari_turnos) from public, anon, authenticated;

-- O indicador respondeu ao pedido só com um nome. true = a automação respondeu (pedido segue aberto para o telefone).
create or replace function public._ind_nome_sem_telefone(c public.mari_conversas, t public.mari_turnos, p_pedido uuid, p_pos uuid, p_venda uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare n text; k text; v_alvo uuid[]; v_humano boolean;
begin
  if t.midia is not null then return false; end if;
  n := public._ind_so_nome(t.texto);
  if n is null then return false; end if;
  k := public._ind_nome_chave(n);
  if k is null then return false; end if;
  -- "Rayra Piranha" e logo depois "Rayra": é a mesma pessoa, não responde duas vezes
  if exists (select 1 from public.indicacao_pistas x where x.conversa_id = c.id and x.tipo = 'nome_do_indicado'
              and x.nome_chave = k and x.criado_em > now() - interval '30 minutes') then
    return true;
  end if;
  insert into public.indicacao_pistas (tipo, conversa_id, venda_id, pedido_id, pos_instalacao_id, nome, nome_chave, texto)
  values ('nome_do_indicado', c.id, p_venda, p_pedido, p_pos, n, k, left(t.texto, 500));
  -- a pessoa já chegou dizendo que foi indicada? (só vincula se houver uma só)
  select array_agg(m.id) into v_alvo from public.mari_conversas m
   where m.id <> c.id and m.created_at > now() - interval '7 days' and coalesce(m.funil_destino, '') <> 'instalada'
     and k in (public._ind_nome_chave(m.dados ->> 'nome'), public._ind_nome_chave(m.nome_contato))
     and exists (select 1 from public.indicacao_pistas x where x.conversa_id = m.id and x.tipo = 'disse_indicado' and x.estado = 'aberta');
  if array_length(v_alvo, 1) = 1 then
    perform public._ind_vincular(c.id, v_alvo[1], 'reconhecida sozinha pela conversa', t.texto);
  end if;
  v_humano := coalesce(c.humano_atribuido, false) or coalesce(c.time_atribuido, false) or c.chatwoot_agente is not null;
  if v_humano then return false; end if;   -- 0226 (M4): com o time na conversa, a automação não fala; o nome fica guardado
  perform public._bo_mensagem(gen_random_uuid(), 1, 'indicacao_insistir', p_venda, c, 'indicacao_pedir_whats',
                              jsonb_build_object('nome', public._ind_primeiro_nome(n)));
  return true;
end $$;
revoke all on function public._ind_nome_sem_telefone(public.mari_conversas, public.mari_turnos, uuid, uuid, uuid) from public, anon, authenticated;

-- ───────────────────────── 4. remendos nas funções no ar ─────────────────────────
do $$
declare d text;
begin
  -- 4a. gatilho da fala do cliente: lead que não instalou → reconhece "fui indicado"; no pedido do pós-instalação → nome sem telefone
  d := pg_get_functiondef('public.mari_turnos_pos_instalacao'::regproc);
  if position('_ind_indicado_fala' in d) = 0 then
    if regexp_count(d, E'tt\\.papel = ''lead''\\);\\s+end if;\\s+return new;') <> 1 or regexp_count(d, E'\\n    elsif p\\.insistencias = 0 then') <> 1 then
      raise exception '0427: mari_turnos_pos_instalacao mudou — refazer o remendo a partir da versão no ar';
    end if;
    d := regexp_replace(d, E'(tt\\.papel = ''lead''\\);\\s+end if;)(\\s+return new;)',
           E'\\1\n    if i.id is null then perform public._ind_indicado_fala(c, new); end if;   -- 0427\\2');
    d := regexp_replace(d, E'\\n    elsif p\\.insistencias = 0 then',
           E'\n    elsif public._ind_nome_sem_telefone(c, new, null, p.id, p.venda_id) then   -- 0427: nome sem telefone\n      update public.pos_instalacao set resposta = left(new.texto, 300) where id = p.id;\n      v_tratou := true;\n    elsif p.insistencias = 0 then');
    execute d;
  end if;
  -- 4b. resposta ao pedido da varredura: nome sem telefone não encerra calado
  d := pg_get_functiondef('public._ind_varredura_resposta'::regproc);
  if position('_ind_nome_sem_telefone' in d) = 0 then
    if regexp_count(d, E'\\n  elsif pe\\.insistencias = 0 then') <> 1 then
      raise exception '0427: _ind_varredura_resposta mudou — refazer o remendo a partir da versão no ar';
    end if;
    d := regexp_replace(d, E'\\n  elsif pe\\.insistencias = 0 then',
           E'\n  elsif public._ind_nome_sem_telefone(c, t, pe.id, null, c.venda_id) then   -- 0427: nome sem telefone\n    update public.indicacao_pedidos set respondeu_em = now(), resposta = left(t.texto, 300), tratado_em = now() where id = pe.id;\n  elsif pe.insistencias = 0 then');
    execute d;
  end if;
end $$;

-- ───────────────────────── 5. o botão da ficha ─────────────────────────
create or replace function public.indicacao_registrar(p_indicado_conversa uuid, p_indicador text, p_confirmar boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  cd public.mari_conversas; ci public.mari_conversas; vi public.vendas; i public.indicacoes;
  cfg jsonb := public._ind_cfg(); v_dig text := regexp_replace(coalesce(p_indicador, ''), '\D', '', 'g');
  v_quem text; v_nome_i text; v_nome_d text; r jsonb; v_inst boolean; v_aviso text;
begin
  if (select coalesce(public.meu_perfil(), '')) not in ('admin', 'backoffice') then
    raise exception 'Só admin e backoffice registram indicação.' using errcode = '42501';
  end if;
  select * into cd from public.mari_conversas where id = p_indicado_conversa;
  if cd.id is null then raise exception 'Conversa do indicado não encontrada.' using errcode = '22023'; end if;
  if v_dig = '' then raise exception 'Diga quem indicou: o número do lead (L-156) ou o WhatsApp.' using errcode = '22023'; end if;
  if length(v_dig) <= 6 then
    select * into ci from public.mari_conversas where lead_numero = v_dig::int limit 1;
  else
    select m.* into ci from public.mari_conversas m left join public.vendas vv on vv.id = m.venda_id
     where public._tel_chave(m.telefone) = public._tel_chave(v_dig)
     order by (vv.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme')) desc nulls last, m.updated_at desc limit 1;
  end if;
  if ci.id is null then raise exception 'Não achei quem indicou com "%". Use o número do lead (L-156) ou o WhatsApp.', p_indicador using errcode = '22023'; end if;
  select * into vi from public.vendas where id = ci.venda_id;
  v_inst := vi.id is not null and vi.status in ('3_instalado', '4_ativo_provisorio', '5_comissao_firme');
  v_nome_i := coalesce(nullif(btrim(coalesce(vi.cliente_nome, '')), ''), nullif(btrim(coalesce(ci.dados ->> 'nome', '')), ''), ci.nome_contato, 'sem nome');
  v_nome_d := coalesce(nullif(btrim(coalesce(cd.dados ->> 'nome', '')), ''), cd.nome_contato, 'sem nome');
  select * into i from public.indicacoes x where x.tel_chave = public._tel_chave(cd.telefone) and x.estado <> 'invalida' limit 1;
  v_aviso := case when i.id is not null and i.indicador_conversa_id is distinct from ci.id
                  then 'Este lead já estava como indicado por outra pessoa: o registro troca quem indicou.' end;
  if not coalesce(p_confirmar, false) then
    return jsonb_build_object('ok', true, 'previa', true,
      'indicador', 'L-' || ci.lead_numero || ' · ' || v_nome_i, 'indicado', 'L-' || cd.lead_numero || ' · ' || v_nome_d,
      'indicador_instalado', v_inst, 'premio', coalesce((cfg ->> 'premio_valor')::numeric, 100),
      'premio_dias', coalesce((cfg ->> 'premio_dias')::int, 10), 'aviso', v_aviso,
      'resumo', format('L-%s (%s) veio por indicação de L-%s (%s). Se L-%s instalar, entra um Pix de R$ %s a pagar a quem indicou, %s dias depois da instalação (Pagamentos › Indicações). Nenhuma mensagem sai para o cliente.',
                       cd.lead_numero, v_nome_d, ci.lead_numero, v_nome_i, cd.lead_numero,
                       coalesce((cfg ->> 'premio_valor')::numeric, 100), coalesce((cfg ->> 'premio_dias')::int, 10)));
  end if;
  v_quem := coalesce((select u.nome from public.usuarios u where u.id = auth.uid()), 'o time');
  r := public._ind_vincular(ci.id, cd.id, 'registrada no NIOGEN por ' || v_quem, null);
  return r || jsonb_build_object('resumo', format('Indicação registrada: L-%s veio por indicação de L-%s (%s)', cd.lead_numero, ci.lead_numero, v_nome_i));
end $$;
revoke all on function public.indicacao_registrar(uuid, text, boolean) from public, anon;
grant execute on function public.indicacao_registrar(uuid, text, boolean) to authenticated, service_role;

-- ───────────────────────── 6. conferência ─────────────────────────
do $$
declare d text := pg_get_functiondef('public.conferencia_itens'::regproc);
begin
  if position('''indicacao_sem_indicador''' in d) > 0 then return; end if;
  if regexp_count(d, E'\\r?\\n  return it;\\r?\\nend') <> 1 then
    raise exception '0427: conferencia_itens mudou — refazer o item da indicação a partir da versão no ar';
  end if;
  d := regexp_replace(d, E'\\r?\\n  return it;\\r?\\nend', E'
  -- 0427 — Indicação: lead que disse ter sido indicado e ainda não tem quem indicou (o Pix depende desse vínculo — caso L-397)
  select count(*)::int, string_agg(''L-'' || c.lead_numero, '', '' order by c.lead_numero) into n, ex
    from public.indicacao_pistas ipx join public.mari_conversas c on c.id = ipx.conversa_id
   where ipx.tipo = ''disse_indicado'' and ipx.estado = ''aberta''
     and ipx.criado_em < now() - interval ''2 hours'' and ipx.criado_em > now() - interval ''30 days'';
  it := it || jsonb_build_object(''codigo'', ''indicacao_sem_indicador'', ''nome'', ''Indicação: todo lead indicado tem quem indicou'',
    ''nivel'', case when n = 0 then ''ok'' else ''atencao'' end, ''n'', n,
    ''texto'', case when n = 0 then ''nenhum lead que disse ter sido indicado está sem quem indicou''
                    else format(''%s lead(s) disseram que foram indicados e não têm quem indicou: %s'', n, left(ex, 300)) end,
    ''fazer'', case when n = 0 then null else ''Abrir a ficha do lead › "＋ indicado por" e registrar quem indicou (pergunte ao cliente se preciso). Sem isso o Pix de quem indicou não aparece em Pagamentos.'' end);

  return it;
end');
  execute d;
end $$;

-- ───────────────────────── 7. uma vez agora: a indicação que deu origem a isto ─────────────────────────
-- L-156 indicou L-397 em 26/11 (Ricardo confirmou com a cliente na conversa: "Rayra é uma indicação sua?" — "Sim").
do $$
declare a uuid; b uuid; r jsonb;
begin
  select id into a from public.mari_conversas where lead_numero = 156;
  select id into b from public.mari_conversas where lead_numero = 397;
  if a is null or b is null then return; end if;   -- banco sem esses leads (cópia limpa): nada a fazer
  if exists (select 1 from public.indicacoes x where x.conversa_id = b and x.estado <> 'invalida') then return; end if;
  insert into public.indicacao_pistas (tipo, conversa_id, texto) values ('disse_indicado', b, 'A minha prima me passou seu contato');
  r := public._ind_vincular(a, b, 'registrada pelo Claude Code a pedido do Ricardo (26/11)', null);
  raise notice '0427: L-156 → L-397 registrada: %', r;
end $$;

-- ───────────────────────── 8. conferência final ─────────────────────────
do $$
begin
  if public._ind_nome_chave('Keroly') is distinct from public._ind_nome_chave('Queroly') then raise exception '0427: a chave do nome não dobra Keroly/Queroly'; end if;
  if public._ind_so_nome('Rayra Piranha') is null or public._ind_so_nome('Blz') is not null or public._ind_so_nome('vou ver') is not null
     or public._ind_so_nome('Não conheço ninguém') is not null then
    raise exception '0427: _ind_so_nome não separa nome de resposta curta';
  end if;
  if position('_ind_indicado_fala' in pg_get_functiondef('public.mari_turnos_pos_instalacao'::regproc)) = 0
     or position('_ind_nome_sem_telefone' in pg_get_functiondef('public.mari_turnos_pos_instalacao'::regproc)) = 0
     or position('_ind_nome_sem_telefone' in pg_get_functiondef('public._ind_varredura_resposta'::regproc)) = 0
     or position('indicacao_sem_indicador' in pg_get_functiondef('public.conferencia_itens'::regproc)) = 0 then
    raise exception '0427: um dos remendos não entrou';
  end if;
end $$;

commit;

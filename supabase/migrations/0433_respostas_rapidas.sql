-- NIOGEN | supabase/migrations/0433_respostas_rapidas.sql | 27/11/2026 — Claude Code (Fable 5.2)
-- Pedido do Ricardo, 27/11: "Preciso criar uma forma de incluir respostas automáticas no Niogen. Vejo que já tem ali algumas que
-- não sei de onde vem exatamente, junto com os templates da Meta. Eu preciso cadastrar mais" → "Sim, constrói".
-- (Prompt de 18/11: docs/Prompt_respostas_rapidas_tela_181126_1320.md, na pasta da governança.)
-- Antes: as respostas rápidas do menu da conversa eram linhas rr_* de config_mari_textos, no formato "Rótulo::texto", gravadas por
-- migration (0090, 0093) — sem tela, ninguém cadastrava. Agora:
--  (1) config_respostas_rapidas: uma linha por resposta (rótulo, texto, ordem, ativo, quem criou/alterou), com parceiro_id (regra 15).
--      Quem tem perfil admin/backoffice lê; NINGUÉM grava direto — só as funções abaixo.
--  (2) respostas_rapidas(p_todas): a lista que a conversa lê (só as ativas) e que Configurações › Textos lê (todas).
--      resposta_rapida_salvar(id, rótulo, texto, ordem, ativo): cria ou edita — só admin. resposta_rapida_apagar(id): desativa, não apaga.
--      Cada gravação deixa linha em config_respostas_rapidas_hist (quem, quando, o antes e o depois).
--  (3) respostas_rapidas_uso + resposta_rapida_usada(id, conversa, ação, texto): a tela avisa, DEPOIS do envio, que a mensagem saiu
--      de uma resposta rápida (e se foi editada antes de sair). É registro para medir; o envio continua em backoffice_responder.
--  (4) as rr_* de hoje são copiadas para a tabela, na ordem das chaves, e saem de config_mari_textos (fonte única). Nenhum fluxo do
--      n8n, a Mari ou outra função lê rr_* — o único leitor era docs/assets/conversa.js.
-- Regra 20 / regras de ouro: não cria, não muda e não lê situação de lead (1, 7); a tela não grava nada direto (2); Salvar e Desativar
-- só para admin e a recusa vem do banco com a frase (3); não toca Chatwoot, dono, etiqueta nem lembrete (4, 5); resposta rápida é
-- texto que a PESSOA envia, nenhuma mensagem automática nasce aqui (6); a extensão não muda (8); cenário X155 (9).
-- (10) Declaração: resposta_rapida_salvar / _apagar / _usada NÃO criam evento de lead e valem em qualquer situação; não desencadeiam nada.
-- Conferência diária (regra 5 das cinco): não ganha item — é texto de configuração, sem estado nem prazo para fechar.
-- Desempenho: a conversa troca 1 leitura (config_mari_textos) por 1 RPC, guardada em memória pela aba — nenhuma chamada a mais.
-- Medição (7 dias, em 04/12): no fim deste arquivo.
begin;

-- ───────────── (1) a tabela ─────────────
create table if not exists public.config_respostas_rapidas (
  id            bigint generated always as identity primary key,
  parceiro_id   text not null default 'dharma',
  rotulo        text not null check (char_length(btrim(rotulo)) between 1 and 40),
  texto         text not null check (char_length(btrim(texto)) between 1 and 1000),
  ordem         int  not null default 0,
  ativo         boolean not null default true,
  criada_por    uuid,
  criada_em     timestamptz not null default now(),
  alterada_por  uuid,
  alterada_em   timestamptz not null default now()
);
comment on table public.config_respostas_rapidas is '0433: respostas rápidas do menu da conversa. Cadastro em Configurações › Textos (só admin, pelas funções resposta_rapida_*). Desativar não apaga.';
create unique index if not exists config_respostas_rapidas_rotulo on public.config_respostas_rapidas (parceiro_id, lower(btrim(rotulo))) where ativo;
alter table public.config_respostas_rapidas enable row level security;
drop policy if exists config_respostas_rapidas_ler on public.config_respostas_rapidas;
create policy config_respostas_rapidas_ler on public.config_respostas_rapidas for select to authenticated
  using (coalesce((select public.meu_perfil()), '') in ('admin', 'backoffice'));
revoke all on public.config_respostas_rapidas from anon;
revoke insert, update, delete, truncate on public.config_respostas_rapidas from authenticated;
grant select on public.config_respostas_rapidas to authenticated;

create table if not exists public.config_respostas_rapidas_hist (
  id           bigint generated always as identity primary key,
  parceiro_id  text not null default 'dharma',
  resposta_id  bigint not null references public.config_respostas_rapidas (id),
  acao         text not null check (acao in ('migrar', 'criar', 'editar', 'desativar', 'religar')),
  antes        jsonb,
  depois       jsonb,
  por          uuid,
  em           timestamptz not null default now()
);
comment on table public.config_respostas_rapidas_hist is '0433: quem criou, editou ou desativou cada resposta rápida, com o antes e o depois.';
alter table public.config_respostas_rapidas_hist enable row level security;
drop policy if exists config_respostas_rapidas_hist_ler on public.config_respostas_rapidas_hist;
create policy config_respostas_rapidas_hist_ler on public.config_respostas_rapidas_hist for select to authenticated
  using (coalesce((select public.meu_perfil()), '') = 'admin');
revoke all on public.config_respostas_rapidas_hist from anon;
revoke insert, update, delete, truncate on public.config_respostas_rapidas_hist from authenticated;
grant select on public.config_respostas_rapidas_hist to authenticated;

create table if not exists public.respostas_rapidas_uso (
  id           bigint generated always as identity primary key,
  parceiro_id  text not null default 'dharma',
  resposta_id  bigint not null references public.config_respostas_rapidas (id),
  conversa_id  uuid,
  acao_id      bigint,
  usuario_id   uuid,
  editada      boolean not null default false,
  enviada_em   timestamptz not null default now()
);
comment on table public.respostas_rapidas_uso is '0433: cada mensagem do time que saiu de uma resposta rápida (editada = o texto foi mexido antes de enviar). Registro para medir, não é estado.';
create index if not exists respostas_rapidas_uso_quando on public.respostas_rapidas_uso (parceiro_id, enviada_em desc);
alter table public.respostas_rapidas_uso enable row level security;
drop policy if exists respostas_rapidas_uso_ler on public.respostas_rapidas_uso;
create policy respostas_rapidas_uso_ler on public.respostas_rapidas_uso for select to authenticated
  using (coalesce((select public.meu_perfil()), '') = 'admin');
revoke all on public.respostas_rapidas_uso from anon;
revoke insert, update, delete, truncate on public.respostas_rapidas_uso from authenticated;
grant select on public.respostas_rapidas_uso to authenticated;

-- ───────────── (2) ler, salvar, desativar ─────────────
create or replace function public.respostas_rapidas(p_todas boolean default false)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when coalesce((select public.meu_perfil()), '') in ('admin', 'backoffice') then
    coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'rotulo', r.rotulo, 'texto', r.texto, 'ordem', r.ordem, 'ativo', r.ativo,
                                                  'alterada_em', r.alterada_em, 'alterada_por', u.nome,
                                                  'usos_30d', (select count(*) from public.respostas_rapidas_uso s
                                                                where s.resposta_id = r.id and s.enviada_em > now() - interval '30 days'))
                               order by r.ativo desc, r.ordem, r.id)
                from public.config_respostas_rapidas r
                left join public.usuarios u on u.id = r.alterada_por
               where r.parceiro_id = 'dharma' and (r.ativo or coalesce(p_todas, false))), '[]'::jsonb)
  else '[]'::jsonb end
$$;
revoke all on function public.respostas_rapidas(boolean) from public, anon;
grant execute on function public.respostas_rapidas(boolean) to authenticated;

create or replace function public.resposta_rapida_salvar(p_id bigint, p_rotulo text, p_texto text, p_ordem int default null, p_ativo boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_rot text := btrim(coalesce(p_rotulo, ''));
  v_txt text := btrim(coalesce(p_texto, ''), E' \t\r\n');
  v_ativo boolean := coalesce(p_ativo, true);
  a public.config_respostas_rapidas;
  r public.config_respostas_rapidas;
begin
  if coalesce(public.meu_perfil(), '') <> 'admin' then raise exception 'Só o admin cadastra ou altera resposta rápida.' using errcode = '42501'; end if;
  if v_rot = '' then raise exception 'Escreva o rótulo: é o nome que aparece no menu da conversa.' using errcode = '22023'; end if;
  if char_length(v_rot) > 40 then raise exception 'O rótulo tem % caracteres; o máximo é 40.', char_length(v_rot) using errcode = '22023'; end if;
  if v_txt = '' then raise exception 'Escreva o texto da resposta.' using errcode = '22023'; end if;
  if char_length(v_txt) > 1000 then raise exception 'O texto tem % caracteres; o máximo é 1000.', char_length(v_txt) using errcode = '22023'; end if;
  if p_id is not null then
    select * into a from public.config_respostas_rapidas where id = p_id and parceiro_id = 'dharma' for update;
    if a.id is null then raise exception 'Resposta rápida não encontrada.' using errcode = 'P0002'; end if;
  end if;
  if v_ativo and exists (select 1 from public.config_respostas_rapidas x
                          where x.parceiro_id = 'dharma' and x.ativo and lower(btrim(x.rotulo)) = lower(v_rot) and x.id is distinct from p_id) then
    raise exception 'Já existe uma resposta rápida ativa com o rótulo "%". Escolha outro nome ou edite a que já existe.', v_rot using errcode = '23505';
  end if;
  if p_id is null then
    insert into public.config_respostas_rapidas (rotulo, texto, ordem, ativo, criada_por, alterada_por)
    values (v_rot, v_txt,
            coalesce(p_ordem, (select coalesce(max(ordem), 0) + 1 from public.config_respostas_rapidas where parceiro_id = 'dharma' and ativo)),
            v_ativo, auth.uid(), auth.uid())
    returning * into r;
    insert into public.config_respostas_rapidas_hist (resposta_id, acao, depois, por) values (r.id, 'criar', to_jsonb(r), auth.uid());
  else
    update public.config_respostas_rapidas
       set rotulo = v_rot, texto = v_txt, ordem = coalesce(p_ordem, ordem), ativo = v_ativo, alterada_por = auth.uid(), alterada_em = now()
     where id = p_id returning * into r;
    insert into public.config_respostas_rapidas_hist (resposta_id, acao, antes, depois, por)
    values (r.id, case when a.ativo and not r.ativo then 'desativar' when not a.ativo and r.ativo then 'religar' else 'editar' end,
            to_jsonb(a), to_jsonb(r), auth.uid());
  end if;
  return to_jsonb(r);
end $$;
revoke all on function public.resposta_rapida_salvar(bigint, text, text, int, boolean) from public, anon;
grant execute on function public.resposta_rapida_salvar(bigint, text, text, int, boolean) to authenticated;

create or replace function public.resposta_rapida_apagar(p_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  a public.config_respostas_rapidas;
  r public.config_respostas_rapidas;
begin
  if coalesce(public.meu_perfil(), '') <> 'admin' then raise exception 'Só o admin desativa resposta rápida.' using errcode = '42501'; end if;
  select * into a from public.config_respostas_rapidas where id = p_id and parceiro_id = 'dharma' for update;
  if a.id is null then raise exception 'Resposta rápida não encontrada.' using errcode = 'P0002'; end if;
  if not a.ativo then return to_jsonb(a); end if;
  update public.config_respostas_rapidas set ativo = false, alterada_por = auth.uid(), alterada_em = now() where id = p_id returning * into r;
  insert into public.config_respostas_rapidas_hist (resposta_id, acao, antes, depois, por) values (r.id, 'desativar', to_jsonb(a), to_jsonb(r), auth.uid());
  return to_jsonb(r);
end $$;
revoke all on function public.resposta_rapida_apagar(bigint) from public, anon;
grant execute on function public.resposta_rapida_apagar(bigint) to authenticated;

-- ───────────── (3) o uso ─────────────
create or replace function public.resposta_rapida_usada(p_id bigint, p_conversa uuid, p_acao_id bigint default null, p_texto text default null)
returns void language plpgsql security definer set search_path = public as $$
declare r public.config_respostas_rapidas;
begin
  if coalesce(public.meu_perfil(), '') not in ('admin', 'backoffice') then raise exception 'Sem acesso.' using errcode = '42501'; end if;
  select * into r from public.config_respostas_rapidas where id = p_id and parceiro_id = 'dharma';
  if r.id is null then return; end if;
  insert into public.respostas_rapidas_uso (resposta_id, conversa_id, acao_id, usuario_id, editada)
  values (r.id, p_conversa, p_acao_id, auth.uid(),
          p_texto is not null and btrim(p_texto, E' \t\r\n') is distinct from btrim(r.texto, E' \t\r\n'));
end $$;
revoke all on function public.resposta_rapida_usada(bigint, uuid, bigint, text) from public, anon;
grant execute on function public.resposta_rapida_usada(bigint, uuid, bigint, text) to authenticated;

-- ───────────── (4) as de hoje vêm para a tabela e saem da fonte antiga ─────────────
with antigas as (
  select chave, texto, position('::' in texto) as p, row_number() over (order by chave) as n
    from public.config_mari_textos
   where chave like 'rr\_%'
), novas as (
  insert into public.config_respostas_rapidas (rotulo, texto, ordem)
  select left(btrim(case when p > 0 then left(texto, p - 1) else regexp_replace(chave, '^rr_\d*_?', '') end), 40),
         left(btrim(case when p > 0 then substr(texto, p + 2) else texto end, E' \t\r\n'), 1000),
         n
    from antigas
   where not exists (select 1 from public.config_respostas_rapidas)   -- rodar de novo não duplica
     and btrim(case when p > 0 then substr(texto, p + 2) else texto end, E' \t\r\n') <> ''
   order by n
  returning *
)
insert into public.config_respostas_rapidas_hist (resposta_id, acao, depois)
select id, 'migrar', to_jsonb(novas) from novas;

delete from public.config_mari_textos
 where chave like 'rr\_%'
   and exists (select 1 from public.config_respostas_rapidas);

-- Medição (rodar em 04/12, 7 dias depois):
--   select (select count(*) from public.respostas_rapidas_uso where enviada_em > now() - interval '7 days') as saiu_de_resposta_rapida,
--          (select count(*) filter (where editada) from public.respostas_rapidas_uso where enviada_em > now() - interval '7 days') as editadas_antes_de_enviar,
--          (select count(*) from public.chatwoot_acoes where tipo = 'mensagem' and criada_por is not null and criada_em > now() - interval '7 days') as mensagens_do_time,
--          (select count(*) from public.config_respostas_rapidas_hist where acao in ('criar', 'editar') and em > now() - interval '7 days') as criadas_ou_editadas_na_tela;
--   meta: criadas_ou_editadas_na_tela >= 1 (se for 0, a tela não resolveu nada).
commit;
